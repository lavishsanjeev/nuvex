import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../telegram/telegram_media_service.dart';
import '../database/remote_file.dart';
import 'video_prefetch_manager.dart';
import 'video_range_cache_manager.dart';

/// Active video streaming session authorized on the local proxy.
class _ActiveStreamSession {
  final RemoteFile file;
  final String token;
  final DateTime createdAt;
  int? lastRequestedStart;
  int? lastRequestedEnd;
  int activeRequestId = 0;

  _ActiveStreamSession({
    required this.file,
    required this.token,
    required this.createdAt,
  });
}

/// Lightweight localhost HTTP streaming proxy for instant video playback in Nuvex.
///
/// Strictly conforms to Task 8 requirements:
/// - Binds strictly to 127.0.0.1 (loopbackIPv4)
/// - Uses an ephemeral port
/// - Generates high-entropy per-session access tokens (Random.secure)
/// - Requires valid session token for all video requests (rejects unauthorized with 403)
/// - Never exposes arbitrary local filesystem paths
/// - Only serves explicitly registered RemoteFile instances
/// - Supports HEAD requests
/// - Supports GET with Range headers (bytes=start-end, bytes=start-)
/// - Returns correct 200, 206, and 416 responses
/// - Accurately sets Content-Length, Content-Range, Content-Type, and Accept-Ranges headers
/// - Handles client disconnects (seek/pause) gracefully
/// - Reuses verified complete local originals directly with zero network requests
/// - Streams uncached ranges via VideoRangeCacheManager and TelegramMediaService
class VideoStreamingProxy {
  final TelegramMediaService _mediaService;
  final VideoRangeCacheManager _cacheManager;
  final bool enablePreload;

  HttpServer? _server;
  final Map<int, _ActiveStreamSession> _sessions = {};
  final Random _secureRandom = Random.secure();
  Completer<void>? _startingCompleter;

  TelegramMediaService get mediaService => _mediaService;
  VideoRangeCacheManager get cacheManager => _cacheManager;

  VideoStreamingProxy({
    TelegramMediaService? mediaService,
    VideoRangeCacheManager? cacheManager,
    this.enablePreload = true,
  }) : _mediaService = mediaService ?? TelegramMediaService(),
       _cacheManager = cacheManager ?? VideoRangeCacheManager.instance;

  static final VideoStreamingProxy instance = VideoStreamingProxy();

  /// Indicates whether the local HTTP server is running.
  bool get isRunning => _server != null;

  /// Returns the ephemeral port of the running proxy.
  int? get port => _server?.port;

  /// Ensures the localhost HTTP server is running on an ephemeral port.
  Future<void> ensureStarted() async {
    if (_server != null) return;
    if (_startingCompleter != null) return _startingCompleter!.future;

    _startingCompleter = Completer<void>();
    try {
      // Bind strictly to 127.0.0.1 with ephemeral port (0)
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      server.listen(
        _handleRequest,
        onError: (error) {
          debugPrint('[PROXY] Server error: $error');
        },
      );
      debugPrint(
        '[PROXY] Local streaming proxy started on 127.0.0.1:${server.port}',
      );
      _startingCompleter!.complete();
    } catch (e) {
      _startingCompleter!.completeError(e);
      _startingCompleter = null;
      rethrow;
    }
  }

  /// Generates a cryptographically secure 256-bit hexadecimal token.
  String _generateSecureToken() {
    final values = List<int>.generate(32, (_) => _secureRandom.nextInt(256));
    return sha256.convert(values).toString();
  }

  /// Registers a [file] for streaming and returns its authenticated streaming URL.
  String registerFile(RemoteFile file) {
    if (_server == null) {
      throw StateError(
        'VideoStreamingProxy has not been started. Call ensureStarted() first.',
      );
    }

    final token = _generateSecureToken();
    _sessions[file.telegramMessageId] = _ActiveStreamSession(
      file: file,
      token: token,
      createdAt: DateTime.now(),
    );

    // Proactively preload metadata (head + tail) in parallel for instant startup
    if (enablePreload) {
      _cacheManager.preloadMetadataRanges(
        file: file,
        mediaService: _mediaService,
      );
    }

    return 'http://127.0.0.1:${_server!.port}/video/${file.telegramMessageId}?token=$token';
  }

  /// Unregisters an active streaming session when the viewer moves away or disposes.
  void unregisterFile(int messageId) {
    final session = _sessions.remove(messageId);
    session?.activeRequestId++;
    if (VideoPrefetchManager.instance.currentFile?.telegramMessageId ==
        messageId) {
      VideoPrefetchManager.instance.stop();
    }
  }

  /// Stops the localhost HTTP proxy server and clears all active sessions.
  Future<void> stop() async {
    _sessions.clear();
    if (_server != null) {
      await _server!.close(force: true);
      _server = null;
      _startingCompleter = null;
      debugPrint('[PROXY] Local streaming proxy stopped');
    }
  }

  /// Resolves an appropriate video/* MIME type for the media file.
  String _resolveMimeType(RemoteFile file) {
    if (file.mimeType.isNotEmpty && file.mimeType.startsWith('video/')) {
      return file.mimeType;
    }
    final name = file.name.toLowerCase();
    if (name.endsWith('.mp4')) return 'video/mp4';
    if (name.endsWith('.mov')) return 'video/quicktime';
    if (name.endsWith('.mkv')) return 'video/x-matroska';
    if (name.endsWith('.webm')) return 'video/webm';
    if (name.endsWith('.avi')) return 'video/x-msvideo';
    if (name.endsWith('.3gp')) return 'video/3gpp';
    if (name.endsWith('.ts')) return 'video/mp2t';
    return 'video/mp4';
  }

  /// Main request dispatcher for incoming HTTP requests.
  Future<void> _handleRequest(HttpRequest request) async {
    final uri = request.uri;
    debugPrint('[STREAM_REQUEST] ${request.method} ${uri.path}');
    bool responseStarted = false;
    try {
      final pathSegments = uri.pathSegments;

      // 1. Validate route: strictly /video/<messageId>
      if (pathSegments.length != 2 || pathSegments[0] != 'video') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      final messageId = int.tryParse(pathSegments[1]);
      if (messageId == null) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }

      // 2. Validate session existence
      final session = _sessions[messageId];
      if (session == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      // 3. Security: enforce per-session access token
      final requestedToken = uri.queryParameters['token'];
      if (requestedToken == null || requestedToken != session.token) {
        request.response.statusCode = HttpStatus.forbidden;
        request.response.write('Forbidden: Invalid or missing token');
        await request.response.close();
        return;
      }

      // 4. Method validation: support GET and HEAD only
      final method = request.method.toUpperCase();
      if (method != 'GET' && method != 'HEAD') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
        return;
      }

      // 5. Serve media session
      responseStarted = true;
      await _serveVideo(request, session.file, isHead: method == 'HEAD');
    } catch (e, stack) {
      debugPrint('[STREAM_ERROR] Uncaught proxy handler error: $e\n$stack');
      if (!responseStarted) {
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
        } catch (_) {}
      }
    }
  }

  /// Serves media bytes supporting HTTP Range requests, HEAD requests, and verified local files.
  Future<void> _serveVideo(
    HttpRequest request,
    RemoteFile file, {
    required bool isHead,
  }) async {
    final response = request.response;
    bool clientDisconnected = false;

    // Track client disconnection early via response.done
    response.done
        .then((_) {
          clientDisconnected = true;
        })
        .catchError((e) {
          clientDisconnected = true;
          debugPrint(
            '[STREAM_CLIENT_DISCONNECTED] Socket closed by client: $e',
          );
        });

    final totalSize = file.sizeBytes;
    final mimeType = _resolveMimeType(file);

    // Standard media headers
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.headers.set(HttpHeaders.contentTypeHeader, mimeType);
    response.headers.set(
      'content-disposition',
      'inline; filename="${Uri.encodeComponent(file.name)}"',
    );
    try {
      response.bufferOutput = false;
    } catch (_) {}

    // Check if a verified COMPLETE original exists locally
    final verifiedLocalPath = _getVerifiedCompleteLocalOriginal(file);

    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);

    int start;
    int end;

    // Case A: No Range requested — Full File (HTTP 200 OK)
    if (rangeHeader == null) {
      debugPrint(
        '[STREAM_RANGE] Full file requested for ${file.name} (size: $totalSize)',
      );
      response.statusCode = HttpStatus.ok;
      if (totalSize > 0) {
        response.headers.set(
          HttpHeaders.contentLengthHeader,
          totalSize.toString(),
        );
      }

      if (isHead) {
        debugPrint(
          '[STREAM_RESPONSE_CLOSE] HEAD 200 OK headers sent for ${file.name}',
        );
        await response.close();
        return;
      }

      start = 0;
      end = totalSize > 0 ? totalSize - 1 : 0;
    } else {
      // Case B: Range requested (HTTP 206 Partial Content or HTTP 416 Not Satisfiable)
      debugPrint(
        '[STREAM RANGE requested] $rangeHeader for ${file.name} (size: $totalSize)',
      );

      final rangeRegex = RegExp(r'^bytes\s*=\s*(\d*)\s*-\s*(\d*)$');
      final match = rangeRegex.firstMatch(rangeHeader.trim());

      if (match == null) {
        debugPrint(
          '[STREAM_ERROR] Malformed or unsupported range: $rangeHeader',
        );
        await _sendRangeNotSatisfiable(response, totalSize);
        return;
      }

      final startStr = match.group(1);
      final endStr = match.group(2);

      if (startStr == null || startStr.isEmpty) {
        // Suffix range: bytes=-500 (last 500 bytes)
        if (endStr == null || endStr.isEmpty) {
          await _sendRangeNotSatisfiable(response, totalSize);
          return;
        }
        final suffix = int.tryParse(endStr) ?? 0;
        if (suffix <= 0) {
          await _sendRangeNotSatisfiable(response, totalSize);
          return;
        }
        start = max(0, totalSize - suffix);
        end = totalSize > 0 ? totalSize - 1 : 0;
      } else {
        start = int.tryParse(startStr) ?? -1;
        if (start < 0) {
          await _sendRangeNotSatisfiable(response, totalSize);
          return;
        }
        if (endStr != null && endStr.isNotEmpty) {
          end = int.tryParse(endStr) ?? -1;
          if (end < 0) {
            await _sendRangeNotSatisfiable(response, totalSize);
            return;
          }
        } else {
          // bytes=start-
          end = totalSize > 0 ? totalSize - 1 : start;
        }
      }

      // Range validation
      if (start < 0 || (totalSize > 0 && start >= totalSize) || start > end) {
        debugPrint(
          '[STREAM_ERROR] Range out of satisfiable bounds: $start-$end / $totalSize',
        );
        await _sendRangeNotSatisfiable(response, totalSize);
        return;
      }

      if (totalSize > 0 && end >= totalSize) {
        end = totalSize - 1;
      }

      final contentLength = end - start + 1;

      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$totalSize',
      );
      response.headers.set(
        HttpHeaders.contentLengthHeader,
        contentLength.toString(),
      );

      debugPrint('[PROXY] request range=$start-$end');
      debugPrint(
        '[STREAM_RANGE] Range: $rangeHeader -> bytes $start-$end/$totalSize (len: $contentLength)',
      );

      VideoPrefetchManager.instance.onPlaybackRangeRequested(
        file: file,
        start: start,
        end: end,
      );

      // Flush HTTP 206 headers over loopback socket immediately so ExoPlayer
      // completes connection handshaking with 0 latency while chunks stream.
      try {
        await response.flush();
      } catch (_) {}

      if (isHead) {
        debugPrint(
          '[STREAM_RESPONSE_CLOSE] HEAD 206 Partial Content headers sent for ${file.name}',
        );
        await response.close();
        return;
      }
    }

    // BODY WRITING: Exactly ONE body-writing path using response.add(chunk) and await response.close().
    // NEVER use addStream() or pipe().
    if (verifiedLocalPath != null) {
      // 1. Local complete file path
      RandomAccessFile? raf;
      try {
        final ioFile = File(verifiedLocalPath);
        raf = await ioFile.open(mode: FileMode.read);
        await raf.setPosition(start);

        int remaining = end - start + 1;
        const int bufferSize = 64 * 1024; // 64 KB read buffer
        bool firstChunk = true;

        while (remaining > 0 && !clientDisconnected) {
          final toRead = min(remaining, bufferSize);
          final bytes = await raf.read(toRead);
          if (bytes.isEmpty) break;

          // [STREAM_CHUNK_WRITE] high-frequency per-chunk log omitted for UI performance
          response.add(bytes);

          if (firstChunk) {
            firstChunk = false;
            debugPrint(
              '[STREAM_DIAGNOSTIC] First local bytes sent: ${bytes.length} bytes',
            );
          }

          remaining -= bytes.length;
        }
      } catch (e, stack) {
        clientDisconnected = true;
        debugPrint(
          '[STREAM_CLIENT_DISCONNECTED] Local file streaming aborted: $e\n$stack',
        );
      } finally {
        try {
          await raf?.close();
        } catch (_) {}
        if (!clientDisconnected) {
          try {
            debugPrint(
              '[STREAM_RESPONSE_CLOSE] Local file stream completed: $start-$end',
            );
            await response.close();
          } catch (e, stack) {
            debugPrint(
              '[STREAM_ERROR] Error closing local response: $e\n$stack',
            );
          }
        }
      }
      return;
    }

    // 2. Cache / Telegram range streaming path
    final chunkSize = VideoRangeCacheManager.chunkSize; // 1 MB (1048576 bytes)
    final startChunk = start ~/ chunkSize;
    final endChunk = end ~/ chunkSize;
    bool firstChunkLogged = false;

    // Track sequential vs seek positions to avoid canceling prefetch on normal continuous playback
    final session = _sessions[file.telegramMessageId];
    final currentRequestId = session != null ? ++session.activeRequestId : 0;
    final prevStart = session?.lastRequestedStart;
    final prevEnd = session?.lastRequestedEnd;
    session?.lastRequestedStart = start;
    session?.lastRequestedEnd = end;

    if (prevEnd != null) {
      // Check for genuine discontinuity (seek):
      // Sequential/adjacent requests will have start within a reasonable window of prevEnd
      // (within 2 chunks forward or overlapping backward within 1 chunk)
      final forwardGap = start - prevEnd;
      final isSequentialOrAdjacent =
          (forwardGap >= -chunkSize && forwardGap <= 2 * chunkSize) ||
          (prevStart != null && (start - prevStart).abs() <= chunkSize);

      if (!isSequentialOrAdjacent) {
        debugPrint(
          '[PERF_SEEK] Genuine seek detected: jump from byte $prevEnd to $start (chunk $startChunk) for #${file.telegramMessageId}',
        );
        _cacheManager.cancelPrefetch(file.telegramMessageId);
      } else {
        debugPrint(
          '[PERF_STREAM] Sequential/adjacent range: start=$start (chunk $startChunk), prevEnd=$prevEnd for #${file.telegramMessageId}',
        );
      }
    } else if (start > 2 * chunkSize) {
      debugPrint(
        '[PERF_SEEK] Initial playback starting at non-zero offset: byte $start (chunk $startChunk) for #${file.telegramMessageId}',
      );
      _cacheManager.cancelPrefetch(file.telegramMessageId);
    }

    try {
      for (int c = startChunk; c <= endChunk; c++) {
        if (clientDisconnected ||
            (session != null && session.activeRequestId != currentRequestId)) {
          debugPrint(
            '[STREAM_CLIENT_DISCONNECTED] Client disconnected or request superseded ($currentRequestId vs ${session?.activeRequestId}), halting chunk loop at $c',
          );
          break;
        }

        final trace = _cacheManager.getOrCreateTrace(
          messageId: file.telegramMessageId,
          chunkIndex: c,
          byteOffset: c * chunkSize,
          requestedSize: chunkSize,
          isPlaybackRequest: true,
        );

        if (_cacheManager.isChunkCached(file.telegramMessageId, c)) {
          final cStart = c * chunkSize;
          final cEnd = min(totalSize, (c + 1) * chunkSize) - 1;
          debugPrint('[PREFETCH] cache hit $cStart-$cEnd');
        }

        // 1. Dispatch/register active playback chunk FIRST with highest priority
        final playbackChunkFuture = _cacheManager.getChunk(
          file: file,
          chunkIndex: c,
          mediaService: _mediaService,
          isPlaybackRequest: true,
          trace: trace,
        );

        // 2. Schedule continuous background prefetch ahead of the active playhead
        // (the active playback request is already in-flight and holds MTProto priority)
        _cacheManager.prefetchAhead(
          file: file,
          currentChunk: c,
          mediaService: _mediaService,
        );

        final chunk = await playbackChunkFuture;
        final chunkCompletionTime = DateTime.now();

        if (clientDisconnected ||
            (session != null && session.activeRequestId != currentRequestId)) {
          debugPrint(
            '[STREAM_CLIENT_DISCONNECTED] Client disconnected after fetching chunk $c',
          );
          break;
        }

        if (chunk.isEmpty) {
          debugPrint(
            '[STREAM_CHUNK_FETCH] Chunk $c returned empty, terminating range',
          );
          break;
        }

        final chunkStartByte = c * chunkSize;
        final chunkEndByte = chunkStartByte + chunk.length - 1;

        final sliceStart = max(0, start - chunkStartByte);
        final sliceEnd = min(chunk.length, end - chunkStartByte + 1);

        if (sliceStart < sliceEnd && sliceStart < chunk.length) {
          final slice = chunk.sublist(sliceStart, sliceEnd);
          // [STREAM_CHUNK_WRITE] high-frequency slice log omitted for UI performance

          response.add(slice);
          try {
            await response.flush();
          } catch (e) {
            clientDisconnected = true;
            debugPrint(
              '[STREAM_CLIENT_DISCONNECTED] Socket flush failed/closed: $e',
            );
            break;
          }
          final proxySentTime = DateTime.now();
          trace.timeFromChunkCompletionToProxyMs = proxySentTime
              .difference(chunkCompletionTime)
              .inMilliseconds;
          trace.totalEndToEndLatencyMs = proxySentTime
              .difference(trace.traceStartTime)
              .inMilliseconds;
          trace.logSummary();

          if (!firstChunkLogged) {
            firstChunkLogged = true;
            debugPrint(
              '[STREAM_DIAGNOSTIC] First successful response bytes sent: ${slice.length} bytes for #${file.telegramMessageId}',
            );
          }
        }

        if (chunkEndByte >= end) {
          break;
        }
      }
    } catch (e, stack) {
      clientDisconnected = true;
      debugPrint(
        '[STREAM_CLIENT_DISCONNECTED] Stream interrupted or client abort: $e\n$stack',
      );
    } finally {
      if (!clientDisconnected) {
        try {
          debugPrint(
            '[STREAM_RESPONSE_CLOSE] Completed range $start-$end for #${file.telegramMessageId}',
          );
          await response.close();
        } catch (e, stack) {
          debugPrint('[STREAM_ERROR] Error closing response: $e\n$stack');
        }
      }
    }
  }

  Future<void> _sendRangeNotSatisfiable(
    HttpResponse response,
    int totalSize,
  ) async {
    try {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */$totalSize',
      );
      await response.close();
    } catch (_) {}
  }

  /// Returns the path if [file.localPath] points to a verified COMPLETE original file,
  /// strictly conforming to Rule 5:
  /// - Exists on disk
  /// - Non-empty and exact match to file.sizeBytes
  /// - Never mistaking a partial/range-cache file or thumbnail for a complete original
  String? _getVerifiedCompleteLocalOriginal(RemoteFile file) {
    final path = file.localPath;
    if (path == null || path.isEmpty) return null;
    if (path == file.thumbnailPath) return null;
    if (path.contains('nuvex_thumbs') || path.contains('nuvex_stream_cache')) {
      return null;
    }

    final ioFile = File(path);
    if (!ioFile.existsSync()) return null;

    final length = ioFile.lengthSync();
    if (length <= 0) return null;

    if (file.sizeBytes > 0 && length != file.sizeBytes) {
      return null;
    }

    return path;
  }
}
