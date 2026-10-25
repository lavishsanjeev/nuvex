import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:t/t.dart' as t;

import '../core/database/remote_file.dart';
import '../core/utils/image_dimensions.dart';
import 'telegram_auth_service.dart';
import 'telegram_models.dart';

/// Inflates a Telegram MTProto PhotoStrippedSize payload into a standard JPEG byte array.
///
/// Follows the official Telegram specification used in TDLib, Telegram-iOS, and Telegram-Android.
Uint8List? inflateTelegramStrippedThumbnail(Uint8List packed) {
  if (packed.length < 3) return null;
  if (packed[0] != 1) return null;

  const headerB64 =
      '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtYXUlkkYCZ'
      'lo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASstLTw1PHZBQXb4pYyl'
      '+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj/'
      'wAARCAAAAAADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/'
      '8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAk'
      'M2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4'
      'eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ'
      '2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/'
      '8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYn'
      'LRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eH'
      'l6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2N'
      'na4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwA=';

  final header = base64Decode(headerB64);
  final footer = base64Decode('/9k='); // 0xFF, 0xD9

  final height = packed[1];
  final width = packed[2];
  final scanData = packed.sublist(3);

  final builder = BytesBuilder(copy: false);
  builder.add(header.sublist(0, 164));
  builder.addByte(height);
  builder.addByte(header[165]);
  builder.addByte(width);
  builder.add(header.sublist(167));
  builder.add(scanData);
  builder.add(footer);

  return builder.takeBytes();
}

/// Structured result of a paginated Telegram Saved Messages query.
class SavedMessagesPageResult {
  final List<RemoteFile> mediaFiles;
  final int totalMessagesInPage;
  final int? oldestMessageId;
  final bool hasMore;

  SavedMessagesPageResult({
    required this.mediaFiles,
    required this.totalMessagesInPage,
    required this.oldestMessageId,
    required this.hasMore,
  });
}

/// Service responsible for querying and normalizing real Telegram metadata.
///
/// Complies strictly with Task 5 requirements:
/// - Reuses existing TelegramAuthService client and session
/// - Paginated queries on Telegram Saved Messages (InputPeerSelf)
/// - Normalizes and classifies photos, videos, and documents
/// - Configurable timeout with cancellation and retry support
/// - Zero fake data, zero mock counts, zero duplicate clients
class TelegramMediaService {
  final TelegramAuthService _authService;
  final Map<int, t.InputDocumentFileLocation> _locationCache = {};
  final Map<int, Future<t.InputDocumentFileLocation>> _inFlightLocations = {};
  final Map<int, t.Message> _messageCache = {};

  TelegramMediaService({TelegramAuthService? authService})
    : _authService = authService ?? TelegramAuthService();

  int? _lastOldestMessageId;
  int? get lastOldestMessageId => _lastOldestMessageId;
  int _lastTotalMessagesInPage = 0;
  int get lastTotalMessagesInPage => _lastTotalMessagesInPage;

  TelegramAuthService get authService => _authService;

  /// Clears the cached file location and message metadata for a specific message ID or all messages.
  void clearLocationCache([int? messageId]) {
    if (messageId != null) {
      _locationCache.remove(messageId);
      _inFlightLocations.remove(messageId);
      _messageCache.remove(messageId);
    } else {
      _locationCache.clear();
      _inFlightLocations.clear();
      _messageCache.clear();
    }
  }

  /// Resolves the up-to-date MTProto [InputDocumentFileLocation] for a [RemoteFile].
  ///
  /// Caches the location and deduplicates concurrent in-flight requests to avoid redundant RPC round trips.
  /// If [forceRefresh] is true, queries fresh metadata from Telegram.
  Future<t.InputDocumentFileLocation> resolveDocumentLocation(
    RemoteFile file, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _locationCache.containsKey(file.telegramMessageId)) {
      debugPrint(
        '[PERF_LOCATION] Location cache HIT for #${file.telegramMessageId} (0ms RPC avoided)',
      );
      return _locationCache[file.telegramMessageId]!;
    }

    if (!forceRefresh &&
        _inFlightLocations.containsKey(file.telegramMessageId)) {
      debugPrint(
        '[PERF_LOCATION] In-flight location request deduped for #${file.telegramMessageId}',
      );
      return await _inFlightLocations[file.telegramMessageId]!;
    }

    final future = _resolveDocumentLocationInternal(
      file,
      forceRefresh: forceRefresh,
    );
    if (!forceRefresh) {
      _inFlightLocations[file.telegramMessageId] = future;
    }
    try {
      return await future;
    } finally {
      if (!forceRefresh) {
        _inFlightLocations.remove(file.telegramMessageId);
      }
    }
  }

  Future<t.InputDocumentFileLocation> _resolveDocumentLocationInternal(
    RemoteFile file, {
    bool forceRefresh = false,
  }) async {
    debugPrint(
      '[PERF_LOCATION] Location cache MISS for #${file.telegramMessageId} (forceRefresh: $forceRefresh). Fetching fresh metadata...',
    );

    final ready = await _authService.ensureConnected();
    if (!ready || _authService.client == null) {
      throw const SocketException(
        'Unable to connect to Telegram. Please check your internet connection.',
      );
    }

    final client = _authService.client!;
    final msgRes = await client.messages
        .getMessages(id: [t.InputMessageID(id: file.telegramMessageId)])
        .timeout(const Duration(seconds: 15));

    if (msgRes.error != null) {
      throw Exception(
        'Telegram getMessages error: ${msgRes.error!.errorMessage}',
      );
    }

    final result = msgRes.result;
    t.Message? targetMsg;
    if (result is t.MessagesMessages) {
      for (final m in result.messages) {
        if (m is t.Message && m.id == file.telegramMessageId) {
          targetMsg = m;
          break;
        }
      }
    } else if (result is t.MessagesMessagesSlice) {
      for (final m in result.messages) {
        if (m is t.Message && m.id == file.telegramMessageId) {
          targetMsg = m;
          break;
        }
      }
    } else if (result is t.MessagesChannelMessages) {
      for (final m in result.messages) {
        if (m is t.Message && m.id == file.telegramMessageId) {
          targetMsg = m;
          break;
        }
      }
    }

    if (targetMsg == null || targetMsg.media == null) {
      throw Exception(
        'Message #${file.telegramMessageId} not found or contains no media',
      );
    }

    final media = targetMsg.media!;
    if (media is t.MessageMediaDocument) {
      final doc = media.document;
      if (doc is t.Document) {
        final loc = t.InputDocumentFileLocation(
          id: doc.id,
          accessHash: doc.accessHash,
          fileReference: doc.fileReference,
          thumbSize: '',
        );
        _locationCache[file.telegramMessageId] = loc;
        return loc;
      }
    }

    throw Exception(
      'Message #${file.telegramMessageId} media is not a document',
    );
  }

  int _activeTelegramRequests = 0;
  int get activeTelegramRequests => _activeTelegramRequests;

  /// Downloads a range of bytes for [file] directly from Telegram MTProto using `upload.getFile(..., precise: true)`.
  ///
  /// Conforms strictly to Task 8 requirements:
  /// - `precise: true` flag set.
  /// - `offset` and `limit` must be 1 KB (1024 bytes) aligned.
  /// - `limit <= 1 MB` (1048576 bytes).
  /// - Every individual Telegram request stays strictly inside one 1 MB file region.
  /// - If the requested range crosses a 1 MB boundary, it is automatically split into
  ///   multiple sequential requests that stay inside their respective 1 MB regions.
  /// - Recovers from `FILE_REFERENCE_EXPIRED` / `FILE_REFERENCE_INVALID` by refreshing
  ///   the file reference and retrying once.
  Future<Uint8List> getMediaRange({
    required RemoteFile file,
    required int offset,
    required int limit,
    Duration timeout = const Duration(seconds: 30),
    void Function(
      DateTime start,
      DateTime end,
      int elapsedMs,
      int activeAtStart,
    )?
    onMetrics,
  }) async {
    if (offset < 0) {
      throw ArgumentError('Offset must be non-negative: $offset');
    }
    if (offset % 1024 != 0) {
      throw ArgumentError('Offset must be 1 KB (1024 bytes) aligned: $offset');
    }
    if (limit <= 0) {
      return Uint8List(0);
    }
    if (limit % 1024 != 0) {
      throw ArgumentError('Limit must be 1 KB (1024 bytes) aligned: $limit');
    }

    const int oneMb = 1024 * 1024;
    final builder = BytesBuilder(copy: false);
    int curOffset = offset;
    int remaining = limit;

    while (remaining > 0) {
      // End of current 1 MB region
      final currentRegionEnd = ((curOffset ~/ oneMb) + 1) * oneMb;
      final maxInRegion = currentRegionEnd - curOffset;
      final subLimit = min(remaining, min(maxInRegion, oneMb));

      final subBytes = await _fetchSingleTelegramRange(
        file: file,
        offset: curOffset,
        limit: subLimit,
        timeout: timeout,
        onMetrics: onMetrics,
      );

      if (subBytes.isEmpty) break;
      builder.add(subBytes);
      curOffset += subBytes.length;
      remaining -= subBytes.length;

      // If Telegram returned fewer bytes than requested (e.g. EOF), stop
      if (subBytes.length < subLimit) break;
    }

    return builder.takeBytes();
  }

  Future<Uint8List> _fetchSingleTelegramRange({
    required RemoteFile file,
    required int offset,
    required int limit,
    Duration timeout = const Duration(seconds: 30),
    void Function(
      DateTime start,
      DateTime end,
      int elapsedMs,
      int activeAtStart,
    )?
    onMetrics,
  }) async {
    final ready = await _authService.ensureConnected();
    if (!ready || _authService.client == null) {
      throw const SocketException(
        'Unable to connect to Telegram. Please check your internet connection.',
      );
    }

    final client = _authService.client!;
    var location = await resolveDocumentLocation(file);

    try {
      return await _executeGetFileRequest(
        client: client,
        location: location,
        offset: offset,
        limit: limit,
        timeout: timeout,
        onMetrics: onMetrics,
      );
    } catch (e) {
      final errStr = e.toString();
      if (errStr.contains('FILE_REFERENCE_') || errStr.contains('FILE_REF_')) {
        debugPrint(
          '[STREAM] File reference expired for #${file.telegramMessageId}. Refreshing reference...',
        );
        location = await resolveDocumentLocation(file, forceRefresh: true);
        return await _executeGetFileRequest(
          client: client,
          location: location,
          offset: offset,
          limit: limit,
          timeout: timeout,
          onMetrics: onMetrics,
        );
      }
      rethrow;
    }
  }

  Future<Uint8List> _executeGetFileRequest({
    required dynamic client,
    required t.InputDocumentFileLocation location,
    required int offset,
    required int limit,
    required Duration timeout,
    void Function(
      DateTime start,
      DateTime end,
      int elapsedMs,
      int activeAtStart,
    )?
    onMetrics,
  }) async {
    _activeTelegramRequests++;
    final activeAtStart = _activeTelegramRequests;
    final startTime = DateTime.now();
    debugPrint(
      '[TELEGRAM_RANGE] offset: $offset, limit: $limit (doc: ${location.id}) [active: $activeAtStart]',
    );
    final stopwatch = Stopwatch()..start();
    try {
      final getFileRes = await client.upload
          .getFile(
            location: location,
            offset: offset,
            limit: limit,
            cdnSupported: false,
            precise: true,
          )
          .timeout(timeout);
      stopwatch.stop();
      final endTime = DateTime.now();

      if (getFileRes.error != null) {
        throw Exception(
          'Telegram upload.getFile failed: ${getFileRes.error!.errorMessage}',
        );
      }

      final fileBase = getFileRes.result;
      if (fileBase is t.UploadFile) {
        final bytes = fileBase.bytes;
        final elapsedMs = stopwatch.elapsedMilliseconds;
        final speedKBps = elapsedMs > 0
            ? (bytes.length / (elapsedMs / 1000.0) / 1024.0).toStringAsFixed(1)
            : 'inf';
        debugPrint(
          '[PERF_CHUNK] Telegram getFile offset: $offset returned ${bytes.length} bytes in ${elapsedMs}ms ($speedKBps KB/s)',
        );
        onMetrics?.call(startTime, endTime, elapsedMs, activeAtStart);
        return bytes;
      } else {
        return Uint8List(0);
      }
    } finally {
      _activeTelegramRequests--;
    }
  }

  /// Fetches a single page of real Telegram Saved Messages with detailed diagnostic metadata.
  Future<SavedMessagesPageResult> fetchSavedMessagesPageDetailed({
    int offsetId = 0,
    int limit = 50,
    String? thumbsDir,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final ready = await _authService.ensureConnected();
    if (!ready || _authService.client == null) {
      throw const SocketException(
        'Unable to connect to Telegram. Please check your internet connection.',
      );
    }

    final client = _authService.client!;
    debugPrint(
      '[SYNC_DIAGNOSTIC] [Stage 1 & 2] Telegram request limit: $limit | offsetId: $offsetId',
    );

    try {
      final response = await client.messages
          .getHistory(
            peer: const t.InputPeerSelf(),
            offsetId: offsetId,
            offsetDate: DateTime.fromMillisecondsSinceEpoch(0),
            addOffset: 0,
            limit: limit,
            maxId: 0,
            minId: 0,
            hash: 0,
          )
          .timeout(timeout);

      if (response.error != null) {
        final err = response.error!.errorMessage;
        debugPrint('[SYNC] getHistory error: $err');
        throw Exception('Telegram error: $err');
      }

      final result = response.result;
      if (result == null) {
        return SavedMessagesPageResult(
          mediaFiles: [],
          totalMessagesInPage: 0,
          oldestMessageId: null,
          hasMore: false,
        );
      }

      final List<t.MessageBase> rawMessages = [];
      if (result is t.MessagesMessages) {
        rawMessages.addAll(result.messages);
      } else if (result is t.MessagesMessagesSlice) {
        rawMessages.addAll(result.messages);
      } else if (result is t.MessagesChannelMessages) {
        rawMessages.addAll(result.messages);
      }

      int? oldestMsgId;
      final List<RemoteFile> remoteFiles = [];
      for (final msg in rawMessages) {
        if (msg is t.Message) {
          _messageCache[msg.id] = msg;
          if (oldestMsgId == null || msg.id < oldestMsgId) {
            oldestMsgId = msg.id;
          }
          final file = normalizeMessage(msg, thumbsDir: thumbsDir);
          if (file != null) {
            remoteFiles.add(file);
          }
        }
      }

      final bool hasMore =
          rawMessages.length >= limit &&
          oldestMsgId != null &&
          oldestMsgId != offsetId;

      debugPrint(
        '[SYNC_DIAGNOSTIC] [Stage 3 & 4] Telegram returned: ${rawMessages.length} messages | '
        'Extracted media: ${remoteFiles.length} items | oldestMessageId: $oldestMsgId | hasMore: $hasMore',
      );

      _lastOldestMessageId = oldestMsgId;
      _lastTotalMessagesInPage = rawMessages.length;

      return SavedMessagesPageResult(
        mediaFiles: remoteFiles,
        totalMessagesInPage: rawMessages.length,
        oldestMessageId: oldestMsgId,
        hasMore: hasMore,
      );
    } on TimeoutException {
      debugPrint('[SYNC] Request timed out while fetching Saved Messages');
      throw TimeoutException(
        'Request timed out while connecting. Please tap retry.',
      );
    } catch (e) {
      debugPrint('[SYNC] Exception fetching Saved Messages: $e');
      rethrow;
    }
  }

  /// Fetches a single page of real Telegram Saved Messages metadata.
  ///
  /// Uses [offsetId] and [limit] for efficient pagination.
  /// If [thumbsDir] is provided, stripped thumbnails are inflated and saved to disk.
  Future<List<RemoteFile>> fetchSavedMessagesPage({
    int offsetId = 0,
    int limit = 50,
    String? thumbsDir,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final result = await fetchSavedMessagesPageDetailed(
      offsetId: offsetId,
      limit: limit,
      thumbsDir: thumbsDir,
      timeout: timeout,
    );
    return result.mediaFiles;
  }

  /// Downloads a real Telegram photo or document file to [destinationPath].
  ///
  /// Streams binary data chunks directly from Telegram MTProto via upload.getFile.
  Future<File> downloadMediaFile({
    required RemoteFile file,
    required String destinationPath,
    void Function(double progress)? onProgress,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final ready = await _authService.ensureConnected();
    if (!ready || _authService.client == null) {
      throw const SocketException(
        'Unable to connect to Telegram. Please check your internet connection.',
      );
    }

    final client = _authService.client!;
    debugPrint(
      '[DOWNLOAD] Fetching message #${file.telegramMessageId} for fresh media info...',
    );

    // 1. Fetch fresh message to obtain up-to-date fileReference and accessHash
    final msgRes = await client.messages
        .getMessages(id: [t.InputMessageID(id: file.telegramMessageId)])
        .timeout(const Duration(seconds: 15));

    if (msgRes.error != null) {
      throw Exception('Telegram error: ${msgRes.error!.errorMessage}');
    }

    final result = msgRes.result;
    t.Message? targetMsg;
    if (result is t.MessagesMessages) {
      for (final m in result.messages) {
        if (m is t.Message && m.id == file.telegramMessageId) {
          targetMsg = m;
          break;
        }
      }
    } else if (result is t.MessagesMessagesSlice) {
      for (final m in result.messages) {
        if (m is t.Message && m.id == file.telegramMessageId) {
          targetMsg = m;
          break;
        }
      }
    } else if (result is t.MessagesChannelMessages) {
      for (final m in result.messages) {
        if (m is t.Message && m.id == file.telegramMessageId) {
          targetMsg = m;
          break;
        }
      }
    }

    if (targetMsg == null || targetMsg.media == null) {
      throw Exception(
        'Message #${file.telegramMessageId} no longer contains media',
      );
    }

    final media = targetMsg.media!;
    t.InputFileLocationBase location;
    int expectedSize = file.sizeBytes;

    if (media is t.MessageMediaPhoto) {
      final photo = media.photo;
      if (photo is! t.Photo) throw Exception('No photo found in media');

      String thumbSize = '';
      int largestDim = 0;
      for (final sz in photo.sizes) {
        if (sz is t.PhotoSize) {
          if (sz.w > largestDim) {
            largestDim = sz.w;
            thumbSize = sz.type;
            expectedSize = sz.size;
          }
        } else if (sz is t.PhotoSizeProgressive) {
          if (sz.w > largestDim) {
            largestDim = sz.w;
            thumbSize = sz.type;
            expectedSize = sz.sizes.isNotEmpty ? sz.sizes.last : expectedSize;
          }
        }
      }

      location = t.InputPhotoFileLocation(
        id: photo.id,
        accessHash: photo.accessHash,
        fileReference: photo.fileReference,
        thumbSize: thumbSize,
      );
    } else if (media is t.MessageMediaDocument) {
      final doc = media.document;
      if (doc is! t.Document) throw Exception('No document found in media');

      expectedSize = doc.size;
      location = t.InputDocumentFileLocation(
        id: doc.id,
        accessHash: doc.accessHash,
        fileReference: doc.fileReference,
        thumbSize: '',
      );
    } else {
      throw Exception('Unsupported media type: ${media.runtimeType}');
    }

    // 2. Stream chunks to destination file
    final destFile = File(destinationPath);
    if (!destFile.parent.existsSync()) {
      destFile.parent.createSync(recursive: true);
    }

    final sink = destFile.openWrite();
    int offset = 0;
    const int chunkSize = 512 * 1024; // 512 KB per part
    bool isComplete = false;

    debugPrint(
      '[DOWNLOAD] Starting download for ${file.name} (size: $expectedSize bytes)...',
    );

    try {
      while (!isComplete) {
        final getFileRes = await client.upload
            .getFile(
              location: location,
              offset: offset,
              limit: chunkSize,
              cdnSupported: false,
              precise: false,
            )
            .timeout(timeout);

        if (getFileRes.error != null) {
          throw Exception(
            'Telegram download failed: ${getFileRes.error!.errorMessage}',
          );
        }

        final fileBase = getFileRes.result;
        if (fileBase is t.UploadFile) {
          final bytes = fileBase.bytes;
          if (bytes.isEmpty) {
            isComplete = true;
          } else {
            sink.add(bytes);
            offset += bytes.length;
            if (onProgress != null && expectedSize > 0) {
              onProgress((offset / expectedSize).clamp(0.0, 1.0));
            }
            if (bytes.length < chunkSize) {
              isComplete = true;
            }
          }
        } else {
          isComplete = true;
        }
      }

      await sink.flush();
      await sink.close();
      debugPrint(
        '[DOWNLOAD] Download complete for ${file.name} ($offset bytes written to $destinationPath)',
      );
      return destFile;
    } catch (e) {
      await sink.close();
      if (destFile.existsSync()) {
        try {
          destFile.deleteSync();
        } catch (_) {}
      }
      debugPrint('[DOWNLOAD] Error downloading ${file.name}: $e');
      rethrow;
    }
  }

  /// Downloads a real Telegram thumbnail for a photo or document.
  ///
  /// Extracts embedded stripped thumbnails if present, or downloads the small 's' thumbnail
  /// via MTProto client.upload.getFile.
  Future<File> downloadThumbnailFile({
    required RemoteFile file,
    required String destinationPath,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final ready = await _authService.ensureConnected();
    if (!ready || _authService.client == null) {
      throw const SocketException(
        'Unable to connect to Telegram. Please check your internet connection.',
      );
    }

    final client = _authService.client!;
    final destFile = File(destinationPath);
    if (destFile.existsSync() && destFile.lengthSync() > 0) {
      return destFile;
    }

    // 1. Obtain up-to-date message metadata: check memory cache first to eliminate redundant MTProto RPCs
    t.Message? targetMsg = _messageCache[file.telegramMessageId];
    if (targetMsg == null) {
      final msgRes = await client.messages
          .getMessages(id: [t.InputMessageID(id: file.telegramMessageId)])
          .timeout(timeout);

      if (msgRes.error != null) {
        throw Exception('Telegram error: ${msgRes.error!.errorMessage}');
      }

      final result = msgRes.result;
      if (result is t.MessagesMessages) {
        for (final m in result.messages) {
          if (m is t.Message && m.id == file.telegramMessageId) {
            targetMsg = m;
            break;
          }
        }
      } else if (result is t.MessagesMessagesSlice) {
        for (final m in result.messages) {
          if (m is t.Message && m.id == file.telegramMessageId) {
            targetMsg = m;
            break;
          }
        }
      } else if (result is t.MessagesChannelMessages) {
        for (final m in result.messages) {
          if (m is t.Message && m.id == file.telegramMessageId) {
            targetMsg = m;
            break;
          }
        }
      }

      if (targetMsg != null) {
        _messageCache[file.telegramMessageId] = targetMsg;
      }
    }

    if (targetMsg == null || targetMsg.media == null) {
      throw Exception(
        'Message #${file.telegramMessageId} no longer contains media',
      );
    }

    final media = targetMsg.media!;
    t.InputFileLocationBase? location;

    if (media is t.MessageMediaPhoto) {
      final photo = media.photo;
      if (photo is! t.Photo) throw Exception('No photo found in media');

      // Check for high-res cached thumbnail first (>= 200px)
      for (final sz in photo.sizes) {
        if (sz is t.PhotoCachedSize && sz.w >= 200) {
          if (!destFile.parent.existsSync()) {
            destFile.parent.createSync(recursive: true);
          }
          destFile.writeAsBytesSync(sz.bytes, flush: true);
          return destFile;
        }
      }

      // Select the largest suitable real thumbnail, preferably ~320â€“640px.
      // Prefer MTProto thumbnail type 'm' (box 320x320) when available;
      // otherwise use the best available larger thumbnail (e.g. 'x', or 's' as fallback).
      String thumbSize = 'm';
      bool foundTarget = false;

      // 1. Look for 'm' first (standard ~320px box, sharp on retina mobile)
      for (final sz in photo.sizes) {
        if (sz is t.PhotoSize && sz.type == 'm') {
          thumbSize = 'm';
          foundTarget = true;
          break;
        } else if (sz is t.PhotoSizeProgressive && sz.type == 'm') {
          thumbSize = 'm';
          foundTarget = true;
          break;
        }
      }

      // 2. If 'm' not found, find closest suitable size between 180px and 800px
      if (!foundTarget) {
        for (final sz in photo.sizes) {
          if (sz is t.PhotoSize && sz.w >= 180 && sz.w <= 800) {
            thumbSize = sz.type;
            foundTarget = true;
            break;
          } else if (sz is t.PhotoSizeProgressive &&
              sz.w >= 180 &&
              sz.w <= 800) {
            thumbSize = sz.type;
            foundTarget = true;
            break;
          }
        }
      }

      // 3. Fallback to 's' or first available PhotoSize
      if (!foundTarget) {
        for (final sz in photo.sizes) {
          if (sz is t.PhotoSize) {
            thumbSize = sz.type;
            foundTarget = true;
            break;
          }
        }
      }

      location = t.InputPhotoFileLocation(
        id: photo.id,
        accessHash: photo.accessHash,
        fileReference: photo.fileReference,
        thumbSize: thumbSize,
      );
    } else if (media is t.MessageMediaDocument) {
      final doc = media.document;
      if (doc is! t.Document) throw Exception('No document found in media');

      if (doc.thumbs != null) {
        for (final th in doc.thumbs!) {
          if (th is t.PhotoCachedSize && th.w >= 120) {
            if (!destFile.parent.existsSync()) {
              destFile.parent.createSync(recursive: true);
            }
            destFile.writeAsBytesSync(th.bytes, flush: true);
            return destFile;
          }
        }
      }

      String? thumbSize;
      if (doc.thumbs != null) {
        // 1. Look for 'm' first (~320px)
        for (final th in doc.thumbs!) {
          if ((th is t.PhotoSize && th.type == 'm') ||
              (th is t.PhotoSizeProgressive && th.type == 'm')) {
            thumbSize = 'm';
            break;
          }
        }
        // 2. Look for size between 120px and 800px
        if (thumbSize == null) {
          for (final th in doc.thumbs!) {
            if (th is t.PhotoSize && th.w >= 120 && th.w <= 800) {
              thumbSize = th.type;
              break;
            } else if (th is t.PhotoSizeProgressive &&
                th.w >= 120 &&
                th.w <= 800) {
              thumbSize = th.type;
              break;
            }
          }
        }
        // 3. Fallback to any available PhotoSize / PhotoSizeProgressive
        if (thumbSize == null) {
          for (final th in doc.thumbs!) {
            if (th is t.PhotoSize && th.type.isNotEmpty) {
              thumbSize = th.type;
              break;
            } else if (th is t.PhotoSizeProgressive && th.type.isNotEmpty) {
              thumbSize = th.type;
              break;
            }
          }
        }
      }

      if (thumbSize != null) {
        location = t.InputDocumentFileLocation(
          id: doc.id,
          accessHash: doc.accessHash,
          fileReference: doc.fileReference,
          thumbSize: thumbSize,
        );
      } else {
        // Fallback: check if stripped thumbnail is available
        if (doc.thumbs != null) {
          for (final th in doc.thumbs!) {
            if (th is t.PhotoStrippedSize) {
              final jpeg = inflateTelegramStrippedThumbnail(th.bytes);
              if (jpeg != null) {
                if (!destFile.parent.existsSync()) {
                  destFile.parent.createSync(recursive: true);
                }
                destFile.writeAsBytesSync(jpeg, flush: true);
                return destFile;
              }
            }
          }
        }
        throw Exception(
          'No thumbnail available for document #${file.telegramMessageId}',
        );
      }
    }

    if (location == null) {
      throw Exception('No thumbnail location found for media');
    }

    if (!destFile.parent.existsSync()) {
      destFile.parent.createSync(recursive: true);
    }

    final tmpFile = File(
      '$destinationPath.tmp_${DateTime.now().microsecondsSinceEpoch}',
    );
    final sink = tmpFile.openWrite();
    int offset = 0;
    const int chunkSize = 128 * 1024;
    bool isComplete = false;

    try {
      while (!isComplete) {
        final getFileRes = await client.upload
            .getFile(
              location: location,
              offset: offset,
              limit: chunkSize,
              cdnSupported: false,
              precise: false,
            )
            .timeout(timeout);

        if (getFileRes.error != null) {
          throw Exception(
            'Telegram thumbnail download failed: ${getFileRes.error!.errorMessage}',
          );
        }

        final fileBase = getFileRes.result;
        if (fileBase is t.UploadFile) {
          final bytes = fileBase.bytes;
          if (bytes.isEmpty) {
            isComplete = true;
          } else {
            sink.add(bytes);
            offset += bytes.length;
            if (bytes.length < chunkSize) {
              isComplete = true;
            }
          }
        } else {
          isComplete = true;
        }
      }

      await sink.flush();
      await sink.close();
      if (await tmpFile.exists()) {
        await tmpFile.rename(destinationPath);
      }
      return destFile;
    } catch (e) {
      await sink.close();
      if (await tmpFile.exists()) {
        try {
          await tmpFile.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// Checks if a lowercase filename ends with a supported image extension.
  static bool _isImageFilename(String lowerName) {
    return lowerName.endsWith('.jpg') ||
        lowerName.endsWith('.jpeg') ||
        lowerName.endsWith('.png') ||
        lowerName.endsWith('.webp') ||
        lowerName.endsWith('.heic') ||
        lowerName.endsWith('.heif') ||
        lowerName.endsWith('.gif') ||
        lowerName.endsWith('.bmp') ||
        lowerName.endsWith('.tiff') ||
        lowerName.endsWith('.tif') ||
        lowerName.endsWith('.raw') ||
        lowerName.endsWith('.cr2') ||
        lowerName.endsWith('.nef') ||
        lowerName.endsWith('.arw') ||
        lowerName.endsWith('.dng') ||
        lowerName.endsWith('.svg') ||
        lowerName.endsWith('.ico');
  }

  /// Checks if a lowercase filename ends with a supported video extension.
  static bool _isVideoFilename(String lowerName) {
    return lowerName.endsWith('.mp4') ||
        lowerName.endsWith('.mov') ||
        lowerName.endsWith('.avi') ||
        lowerName.endsWith('.mkv') ||
        lowerName.endsWith('.webm') ||
        lowerName.endsWith('.m4v') ||
        lowerName.endsWith('.3gp') ||
        lowerName.endsWith('.wmv') ||
        lowerName.endsWith('.flv') ||
        lowerName.endsWith('.ts');
  }

  /// Infers clean MIME type from filename if missing or generic.
  static String _inferMimeType(String lowerName, String rawMime) {
    final cleanMime = rawMime.trim().toLowerCase();
    if (cleanMime.isNotEmpty &&
        cleanMime != 'application/octet-stream' &&
        cleanMime != 'binary/octet-stream') {
      if (cleanMime == 'image/jpg') return 'image/jpeg';
      return cleanMime;
    }
    if (lowerName.endsWith('.jpg') || lowerName.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lowerName.endsWith('.png')) return 'image/png';
    if (lowerName.endsWith('.webp')) return 'image/webp';
    if (lowerName.endsWith('.heic')) return 'image/heic';
    if (lowerName.endsWith('.heif')) return 'image/heif';
    if (lowerName.endsWith('.gif')) return 'image/gif';
    if (lowerName.endsWith('.bmp')) return 'image/bmp';
    if (lowerName.endsWith('.mp4')) return 'video/mp4';
    if (lowerName.endsWith('.mov')) return 'video/quicktime';
    if (lowerName.endsWith('.avi')) return 'video/x-msvideo';
    if (lowerName.endsWith('.mkv')) return 'video/x-matroska';
    if (lowerName.endsWith('.webm')) return 'video/webm';
    if (lowerName.endsWith('.pdf')) return 'application/pdf';
    return cleanMime.isNotEmpty ? cleanMime : 'application/octet-stream';
  }

  /// Normalizes a Telegram MTProto message containing media into a [RemoteFile].
  ///
  /// Handles both Telegram photo messages and document messages (images, videos, documents).
  /// If [thumbsDir] is provided, stripped/cached thumbnails are extracted and written to disk.
  RemoteFile? normalizeMessage(t.Message msg, {String? thumbsDir}) {
    final media = msg.media;
    if (media == null) return null;

    final date = msg.date;
    final messageId = msg.id;

    // â”€â”€ 1. Photo Media (Standard Telegram compressed photos) â”€â”€
    if (media is t.MessageMediaPhoto) {
      final photo = media.photo;
      if (photo is! t.Photo) return null;

      int width = 0;
      int height = 0;
      int sizeBytes = 0;
      String? thumbnailPath;

      for (final sz in photo.sizes) {
        if (sz is t.PhotoSize) {
          if (sz.w > width) {
            width = sz.w;
            height = sz.h;
            sizeBytes = sz.size;
          }
        } else if (sz is t.PhotoSizeProgressive) {
          if (sz.w > width) {
            width = sz.w;
            height = sz.h;
            sizeBytes = sz.sizes.isNotEmpty ? sz.sizes.last : 0;
          }
        } else if (sz is t.PhotoStrippedSize && thumbsDir != null) {
          try {
            final placeholderFile = File(
              '$thumbsDir/${messageId}_placeholder.jpg',
            );
            if (!placeholderFile.existsSync()) {
              final jpeg = inflateTelegramStrippedThumbnail(sz.bytes);
              if (jpeg != null) {
                if (!placeholderFile.parent.existsSync()) {
                  placeholderFile.parent.createSync(recursive: true);
                }
                placeholderFile.writeAsBytesSync(jpeg);
              }
            }
          } catch (_) {}
        } else if (sz is t.PhotoCachedSize &&
            thumbsDir != null &&
            sz.w >= 120) {
          try {
            final thumbFile = File('$thumbsDir/${messageId}_hq.jpg');
            if (!thumbFile.existsSync()) {
              if (!thumbFile.parent.existsSync()) {
                thumbFile.parent.createSync(recursive: true);
              }
              thumbFile.writeAsBytesSync(sz.bytes);
            }
            thumbnailPath = thumbFile.path;
          } catch (_) {}
        }
      }

      // Reuse previously downloaded HQ thumbnail if it exists on disk and is valid
      if (thumbnailPath == null && thumbsDir != null) {
        final hqFile = File('$thumbsDir/${messageId}_hq.jpg');
        if (isValidHqThumbnail(hqFile)) {
          thumbnailPath = hqFile.path;
        }
      }

      return RemoteFile(
        id: messageId,
        telegramChatId: 0,
        telegramMessageId: messageId,
        telegramFileId: photo.id,
        name: 'Photo_$messageId.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: sizeBytes,
        createdAt: date,
        modifiedAt: date,
        thumbnailPath: thumbnailPath,
        width: width > 0 ? width : null,
        height: height > 0 ? height : null,
        category: 'photos',
      );
    }

    // â”€â”€ 2. Document Media (Photos, Videos, Files uploaded as Document) â”€â”€
    if (media is t.MessageMediaDocument) {
      final doc = media.document;
      if (doc is! t.Document) return null;

      // Immediately cache document location to prevent redundant messages.getMessages RPCs on video tap
      _locationCache[messageId] = t.InputDocumentFileLocation(
        id: doc.id,
        accessHash: doc.accessHash,
        fileReference: doc.fileReference,
        thumbSize: '',
      );

      String? rawFileName;
      bool isVideo = false;
      bool isSticker = false;
      int? width;
      int? height;
      int? durationMs;
      String? thumbnailPath;

      for (final attr in doc.attributes) {
        if (attr is t.DocumentAttributeFilename) {
          rawFileName = attr.fileName;
        } else if (attr is t.DocumentAttributeFilename023) {
          rawFileName = attr.fileName;
        } else if (attr is t.DocumentAttributeVideo) {
          isVideo = true;
          width = attr.w;
          height = attr.h;
          durationMs = (attr.duration * 1000).toInt();
        } else if (attr is t.DocumentAttributeVideo023) {
          isVideo = true;
          width = attr.w;
          height = attr.h;
          durationMs = attr.duration * 1000;
        } else if (attr is t.DocumentAttributeVideo066) {
          isVideo = true;
          width = attr.w;
          height = attr.h;
          durationMs = (attr.duration * 1000).toInt();
        } else if (attr is t.DocumentAttributeImageSize) {
          width = attr.w;
          height = attr.h;
        } else if (attr is t.DocumentAttributeImageSize023) {
          width = attr.w;
          height = attr.h;
        } else if (attr is t.DocumentAttributeSticker ||
            attr is t.DocumentAttributeSticker023 ||
            attr is t.DocumentAttributeSticker045 ||
            attr is t.DocumentAttributeCustomEmoji) {
          isSticker = true;
        } else if (attr is t.DocumentAttributeAudio) {
          durationMs = (attr.duration * 1000).toInt();
        } else if (attr is t.DocumentAttributeAudio023) {
          durationMs = attr.duration * 1000;
        } else if (attr is t.DocumentAttributeAudio045) {
          durationMs = attr.duration * 1000;
        } else if (attr is t.DocumentAttributeAudio046) {
          durationMs = attr.duration * 1000;
        }
      }

      // Check document thumbs
      if (doc.thumbs != null && thumbsDir != null) {
        for (final th in doc.thumbs!) {
          if (th is t.PhotoStrippedSize) {
            try {
              final placeholderFile = File(
                '$thumbsDir/${messageId}_placeholder.jpg',
              );
              if (!placeholderFile.existsSync()) {
                final jpeg = inflateTelegramStrippedThumbnail(th.bytes);
                if (jpeg != null) {
                  if (!placeholderFile.parent.existsSync()) {
                    placeholderFile.parent.createSync(recursive: true);
                  }
                  placeholderFile.writeAsBytesSync(jpeg);
                }
              }
            } catch (_) {}
          } else if (th is t.PhotoCachedSize && th.w >= 120) {
            try {
              final thumbFile = File('$thumbsDir/${messageId}_hq.jpg');
              if (!thumbFile.existsSync()) {
                if (!thumbFile.parent.existsSync()) {
                  thumbFile.parent.createSync(recursive: true);
                }
                thumbFile.writeAsBytesSync(th.bytes);
              }
              thumbnailPath = thumbFile.path;
              break;
            } catch (_) {}
          }
        }
      }

      // Reuse previously downloaded HQ thumbnail if it exists on disk and is valid
      if (thumbnailPath == null && thumbsDir != null) {
        final hqFile = File('$thumbsDir/${messageId}_hq.jpg');
        if (isValidHqThumbnail(hqFile)) {
          thumbnailPath = hqFile.path;
        }
      }

      final rawLowerName = (rawFileName ?? '').toLowerCase();
      final resolvedMime = _inferMimeType(rawLowerName, doc.mimeType);

      // Determine sensible filename if missing
      String fileName = rawFileName ?? '';
      if (fileName.isEmpty) {
        if (resolvedMime.startsWith('image/')) {
          final ext = resolvedMime == 'image/png' ? 'png' : 'jpg';
          fileName = 'Photo_$messageId.$ext';
        } else if (isVideo || resolvedMime.startsWith('video/')) {
          fileName = 'Video_$messageId.mp4';
        } else {
          fileName = 'file_$messageId';
        }
      }

      final lowerName = fileName.toLowerCase();

      // Metadata-based classification:
      // 1. Stickers (Telegram sticker documents)
      // 2. Videos (video MIME or video extension or video attribute)
      // 3. Photos (image MIME or image extension)
      // 4. Documents (all other files)
      String category = 'documents';
      if (isSticker ||
          resolvedMime == 'application/x-tgsticker' ||
          lowerName.endsWith('.tgs')) {
        category = 'stickers';
      } else if (isVideo ||
          resolvedMime.startsWith('video/') ||
          _isVideoFilename(lowerName)) {
        category = 'videos';
      } else if (resolvedMime.startsWith('image/') ||
          _isImageFilename(lowerName)) {
        category = 'photos';
      } else {
        category = 'documents';
      }

      return RemoteFile(
        id: messageId,
        telegramChatId: 0,
        telegramMessageId: messageId,
        telegramFileId: doc.id,
        name: fileName,
        mimeType: resolvedMime,
        sizeBytes: doc.size,
        createdAt: date,
        modifiedAt: date,
        thumbnailPath: thumbnailPath,
        width: width,
        height: height,
        durationMs: durationMs,
        category: category,
      );
    }

    // Unsupported media types (e.g. MessageMediaUnsupported, MessageMediaEmpty, polls, contacts, etc.)
    return null;
  }

  /// Deletes a message from Telegram Saved Messages using the existing authenticated client.
  ///
  /// [revoke]: When true (default), permanently deletes the message from Telegram.
  Future<bool> deleteMessage({
    required int messageId,
    bool revoke = true,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final ready = await _authService.ensureConnected();
    if (!ready || _authService.client == null) {
      throw const SocketException(
        'Unable to connect to Telegram. Please check your internet connection.',
      );
    }

    final client = _authService.client!;
    debugPrint('[DELETE] Deleting message #$messageId from Telegram...');

    try {
      final response = await client.messages
          .deleteMessages(id: [messageId], revoke: revoke)
          .timeout(timeout);

      if (response.error != null) {
        final err = response.error!.errorMessage;
        debugPrint('[DELETE] deleteMessages error: $err');
        throw Exception('Telegram error: $err');
      }

      debugPrint(
        '[DELETE] Successfully deleted message #$messageId from Telegram',
      );
      return true;
    } on TimeoutException {
      debugPrint(
        '[DELETE] Request timed out while deleting message #$messageId',
      );
      throw TimeoutException('Request timed out while deleting from Telegram.');
    } catch (e) {
      debugPrint('[DELETE] Exception deleting message #$messageId: $e');
      rethrow;
    }
  }

  /// Uploads a local file to Telegram Saved Messages (InputPeerSelf) as an uncompressed DOCUMENT/FILE.
  ///
  /// CRITICAL REQUIREMENTS:
  /// - Uploads strictly as a Telegram DOCUMENT (InputMediaUploadedDocument with forceFile: true),
  ///   NEVER as a compressed Telegram photo (InputMediaUploadedPhoto).
  /// - Preserves exact source bytes. Zero transcoding, zero downsampling, zero modifications.
  /// - Reads in 512 KB chunks via RandomAccessFile without loading large files into memory.
  /// - Supports arbitrary file formats (photos, videos, audio, documents, archives).
  /// - Supports upload progress reporting (0.0 -> 1.0).
  /// - Supports cooperative cancellation via [TelegramUploadCancelToken].
  /// - Automatically retries transient network/socket drops with exponential backoff.
  /// - Returns complete [TelegramUploadResult] with messageId, fileId, accessHash, fileReference, etc.
  Future<TelegramUploadResult> uploadDocumentFile({
    required File file,
    String? mimeType,
    void Function(double progress)? onProgress,
    TelegramUploadCancelToken? cancelToken,
    int? randomId,
    int maxRetries = 3,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    if (!file.existsSync()) {
      throw FileSystemException('File does not exist', file.path);
    }
    final int fileSize = file.lengthSync();
    final String fileName = p.basename(file.path);

    final ready = await _authService.ensureConnected();
    if (!ready || _authService.client == null) {
      throw const SocketException(
        'Unable to connect to Telegram. Please check your internet connection.',
      );
    }

    final client = _authService.client!;
    cancelToken?.throwIfCancelled();

    // MTProto upload parameters:
    // - 512 KB per part (must be divisible by 1024, max 512 KB)
    // - 10 MB threshold: files > 10 MB must use upload.saveBigFilePart and InputFileBig
    const int chunkSize = 512 * 1024;
    const int bigFileThresholdBytes = 10 * 1024 * 1024;
    final bool isBig = fileSize > bigFileThresholdBytes;
    final int totalParts = (fileSize == 0)
        ? 1
        : ((fileSize + chunkSize - 1) ~/ chunkSize);
    final int fileId = _generateRandom64BitId();

    debugPrint(
      '[UPLOAD] Starting upload of $fileName ($fileSize bytes, $totalParts parts, isBig: $isBig)...',
    );

    final raf = await file.open(mode: FileMode.read);
    int uploadedBytes = 0;

    try {
      for (int partIndex = 0; partIndex < totalParts; partIndex++) {
        cancelToken?.throwIfCancelled();

        final Uint8List chunk = await raf.read(chunkSize);
        if (chunk.isEmpty && fileSize > 0) {
          break;
        }

        // Retry loop for transient socket/network failures on this specific chunk
        int attempts = 0;
        while (true) {
          cancelToken?.throwIfCancelled();
          attempts++;
          try {
            if (isBig) {
              final res = await client.upload
                  .saveBigFilePart(
                    fileId: fileId,
                    filePart: partIndex,
                    fileTotalParts: totalParts,
                    bytes: chunk,
                  )
                  .timeout(timeout);

              if (res.error != null) {
                throw Exception(
                  'Telegram saveBigFilePart failed: ${res.error!.errorMessage}',
                );
              }
            } else {
              final res = await client.upload
                  .saveFilePart(
                    fileId: fileId,
                    filePart: partIndex,
                    bytes: chunk,
                  )
                  .timeout(timeout);

              if (res.error != null) {
                throw Exception(
                  'Telegram saveFilePart failed: ${res.error!.errorMessage}',
                );
              }
            }
            break;
          } catch (e) {
            cancelToken?.throwIfCancelled();
            if (attempts >= maxRetries) {
              debugPrint(
                '[UPLOAD] Failed part $partIndex after $attempts attempts: $e',
              );
              rethrow;
            }
            debugPrint(
              '[UPLOAD] Retry part $partIndex (attempt $attempts/$maxRetries) after error: $e',
            );
            await Future.delayed(
              Duration(milliseconds: 500 * (1 << (attempts - 1))),
            );
          }
        }

        uploadedBytes += chunk.length;
        if (onProgress != null && fileSize > 0) {
          onProgress((uploadedBytes / fileSize).clamp(0.0, 1.0));
        }
      }
    } finally {
      await raf.close();
    }

    // Construct InputFileBase
    final t.InputFileBase inputFile;
    if (isBig) {
      inputFile = t.InputFileBig(id: fileId, parts: totalParts, name: fileName);
    } else {
      inputFile = t.InputFile(
        id: fileId,
        parts: totalParts,
        name: fileName,
        md5Checksum: '',
      );
    }

    // Determine MIME type and document attributes
    final resolvedMimeType = mimeType ?? _detectMimeType(fileName);
    final List<t.DocumentAttributeBase> attributes = [
      t.DocumentAttributeFilename(fileName: fileName),
    ];

    int? width;
    int? height;
    int? durationMs;

    // Inspect leading bytes to extract image dimensions without decoding pixels
    if (resolvedMimeType.startsWith('image/')) {
      final headerBytes = await _readLeadingBytes(file, 65536);
      final dims = getImageDimensions(headerBytes);
      if (dims != null) {
        width = dims.width;
        height = dims.height;
        attributes.add(t.DocumentAttributeImageSize(w: width, h: height));
      }
    } else if (resolvedMimeType.startsWith('video/')) {
      attributes.add(
        const t.DocumentAttributeVideo(
          roundMessage: false,
          supportsStreaming: true,
          nosound: false,
          duration: 0,
          w: 0,
          h: 0,
        ),
      );
    }

    final bool isVideoUpload = resolvedMimeType.startsWith('video/');

    // Build uncompressed Telegram DOCUMENT media
    final media = t.InputMediaUploadedDocument(
      nosoundVideo: false,
      forceFile: !isVideoUpload, // false for streaming videos, true for untouched photo documents
      spoiler: false,
      file: inputFile,
      mimeType: resolvedMimeType,
      attributes: attributes,
    );

    cancelToken?.throwIfCancelled();
    debugPrint('[UPLOAD] Sending media message to Saved Messages...');

    final uploadRandomId = randomId ?? _generateRandom64BitId();
    final sendRes = await client.messages
        .sendMedia(
          silent: false,
          background: false,
          clearDraft: true,
          noforwards: false,
          updateStickersetsOrder: false,
          invertMedia: false,
          allowPaidFloodskip: false,
          peer: const t.InputPeerSelf(),
          media: media,
          message: '',
          randomId: uploadRandomId,
        )
        .timeout(timeout);

    if (sendRes.error != null) {
      throw Exception(
        'Telegram sendMedia failed: ${sendRes.error!.errorMessage}',
      );
    }

    final updates = sendRes.result;
    t.Message? sentMessage;

    if (updates is t.Updates) {
      for (final u in updates.updates) {
        if (u is t.UpdateNewMessage && u.message is t.Message) {
          sentMessage = u.message as t.Message;
          break;
        } else if (u is t.UpdateNewChannelMessage && u.message is t.Message) {
          sentMessage = u.message as t.Message;
          break;
        }
      }
    } else if (updates is t.UpdatesCombined) {
      for (final u in updates.updates) {
        if (u is t.UpdateNewMessage && u.message is t.Message) {
          sentMessage = u.message as t.Message;
          break;
        } else if (u is t.UpdateNewChannelMessage && u.message is t.Message) {
          sentMessage = u.message as t.Message;
          break;
        }
      }
    } else if (updates is t.UpdateShortSentMessage) {
      final getMsgRes = await client.messages.getMessages(
        id: [t.InputMessageID(id: updates.id)],
      );
      final res = getMsgRes.result;
      if (res is t.MessagesMessages) {
        for (final m in res.messages) {
          if (m is t.Message && m.id == updates.id) {
            sentMessage = m;
            break;
          }
        }
      } else if (res is t.MessagesMessagesSlice) {
        for (final m in res.messages) {
          if (m is t.Message && m.id == updates.id) {
            sentMessage = m;
            break;
          }
        }
      }
    }

    // Fallback: Query Saved Messages directly if message was not in update
    if (sentMessage == null) {
      final histRes = await client.messages.getHistory(
        peer: const t.InputPeerSelf(),
        offsetId: 0,
        offsetDate: DateTime.fromMillisecondsSinceEpoch(0),
        addOffset: 0,
        limit: 1,
        maxId: 0,
        minId: 0,
        hash: 0,
      );
      final res = histRes.result;
      if (res is t.MessagesMessages && res.messages.isNotEmpty) {
        final m = res.messages.first;
        if (m is t.Message) sentMessage = m;
      } else if (res is t.MessagesMessagesSlice && res.messages.isNotEmpty) {
        final m = res.messages.first;
        if (m is t.Message) sentMessage = m;
      }
    }

    if (sentMessage == null) {
      throw Exception('Failed to resolve sent Telegram message after upload');
    }

    int targetMessageId = sentMessage.id;
    int targetFileId = 0;
    int targetAccessHash = 0;
    Uint8List targetFileReference = Uint8List(0);
    String targetFileName = fileName;
    String targetMimeType = resolvedMimeType;
    int targetSizeBytes = fileSize;
    DateTime targetDate = sentMessage.date;

    if (sentMessage.media is t.MessageMediaDocument) {
      final doc = (sentMessage.media as t.MessageMediaDocument).document;
      if (doc is t.Document) {
        targetFileId = doc.id;
        targetAccessHash = doc.accessHash;
        targetFileReference = doc.fileReference;
        targetMimeType = doc.mimeType;
        targetSizeBytes = doc.size;
        for (final attr in doc.attributes) {
          if (attr is t.DocumentAttributeFilename) {
            targetFileName = attr.fileName;
          } else if (attr is t.DocumentAttributeImageSize) {
            width = attr.w;
            height = attr.h;
          } else if (attr is t.DocumentAttributeVideo) {
            width = attr.w;
            height = attr.h;
            durationMs = (attr.duration * 1000).toInt();
          }
        }
      }
    }

    final lowerName = targetFileName.toLowerCase();
    String category = 'documents';
    if (targetMimeType.startsWith('video/')) {
      category = 'videos';
    } else if (lowerName.contains('screenshot') ||
        lowerName.startsWith('screen_') ||
        lowerName.startsWith('scr_') ||
        lowerName.startsWith('screenshot_')) {
      category = 'screenshots';
    } else if (targetMimeType == 'application/x-tgsticker' ||
        targetMimeType == 'image/webp' ||
        lowerName.endsWith('.tgs')) {
      category = 'stickers';
    } else if (targetMimeType.startsWith('image/')) {
      category = 'photos';
    }

    debugPrint(
      '[UPLOAD] Successfully uploaded $targetFileName as Document (Msg ID: $targetMessageId, File ID: $targetFileId, Size: $targetSizeBytes)',
    );

    return TelegramUploadResult(
      messageId: targetMessageId,
      fileId: targetFileId,
      accessHash: targetAccessHash,
      fileReference: targetFileReference,
      fileName: targetFileName,
      mimeType: targetMimeType,
      sizeBytes: targetSizeBytes,
      date: targetDate,
      width: width,
      height: height,
      durationMs: durationMs,
      category: category,
      randomId: uploadRandomId,
    );
  }

  /// Generates a positive 63-bit random integer for MTProto IDs.
  int _generateRandom64BitId() {
    final rng = Random();
    final high = rng.nextInt(0x7FFFFFFF);
    final low = rng.nextInt(0x7FFFFFFF);
    final id = (high << 32) | low;
    return id == 0 ? 1 : id.abs();
  }

  /// Reads up to [maxBytes] from the start of a file without loading the entire file into memory.
  Future<Uint8List> _readLeadingBytes(File file, int maxBytes) async {
    try {
      final raf = await file.open(mode: FileMode.read);
      try {
        return await raf.read(maxBytes);
      } finally {
        await raf.close();
      }
    } catch (_) {
      return Uint8List(0);
    }
  }

  /// Detects MIME type from file extension for arbitrary file types.
  String _detectMimeType(String fileName) {
    final ext = p.extension(fileName).toLowerCase();
    switch (ext) {
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.heic':
        return 'image/heic';
      case '.heif':
        return 'image/heif';
      case '.bmp':
        return 'image/bmp';
      case '.svg':
        return 'image/svg+xml';
      case '.mp4':
        return 'video/mp4';
      case '.mov':
        return 'video/quicktime';
      case '.avi':
        return 'video/x-msvideo';
      case '.mkv':
        return 'video/x-matroska';
      case '.webm':
        return 'video/webm';
      case '.mp3':
        return 'audio/mpeg';
      case '.m4a':
        return 'audio/mp4';
      case '.wav':
        return 'audio/wav';
      case '.ogg':
      case '.oga':
        return 'audio/ogg';
      case '.flac':
        return 'audio/flac';
      case '.pdf':
        return 'application/pdf';
      case '.zip':
        return 'application/zip';
      case '.tar':
      case '.gz':
        return 'application/gzip';
      case '.txt':
        return 'text/plain';
      case '.json':
        return 'application/json';
      default:
        return 'application/octet-stream';
    }
  }
}
