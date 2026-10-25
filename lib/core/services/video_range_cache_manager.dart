import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../telegram/telegram_media_service.dart';
import '../database/remote_file.dart';

/// Diagnostic trace for an individual video chunk.
class ChunkTrace {
  final int requestId;
  final int chunkIndex;
  final int byteOffset;
  final int requestedSize;
  bool isPlaybackRequest;

  String cacheHitMiss = 'MISS'; // 'RAM_HIT', 'DISK_HIT', 'MISS'
  bool wasAlreadyPrefetching = false;
  int timeInPrefetchQueueMs = 0;
  DateTime? telegramRequestStartTime;
  DateTime? telegramResponseTime;
  int telegramTransferDurationMs = 0;
  int diskWriteDurationMs = 0;
  int timeFromChunkCompletionToProxyMs = 0;
  int totalEndToEndLatencyMs = 0;
  int activeTelegramRequestsAtStart = 0;
  bool delayedBehindAnotherRequest = false;
  final DateTime traceStartTime = DateTime.now();

  ChunkTrace({
    required this.requestId,
    required this.chunkIndex,
    required this.byteOffset,
    required this.requestedSize,
    required this.isPlaybackRequest,
  });

  void logSummary() {
    debugPrint(
      '[CHUNK_TRACE] '
      'REQ-$requestId | chunk: $chunkIndex | offset: $byteOffset | size: $requestedSize | '
      'type: ${isPlaybackRequest ? "PLAYBACK" : "PREFETCH"} | '
      'cache: $cacheHitMiss | alreadyPrefetching: $wasAlreadyPrefetching | '
      'prefetchQueueWait: ${timeInPrefetchQueueMs}ms | '
      'tgStart: ${telegramRequestStartTime?.toIso8601String() ?? "N/A"} | '
      'tgEnd: ${telegramResponseTime?.toIso8601String() ?? "N/A"} | '
      'tgTransfer: ${telegramTransferDurationMs}ms | '
      'diskWrite: ${diskWriteDurationMs}ms | '
      'completionToProxy: ${timeFromChunkCompletionToProxyMs}ms | '
      'totalE2E: ${totalEndToEndLatencyMs}ms | '
      'activeTgReqs: $activeTelegramRequestsAtStart | '
      'delayed: $delayedBehindAnotherRequest',
    );
  }
}

/// Manages app-private chunk caching for instant video streaming.
///
/// Strictly conforms to Task 8 requirements:
/// - Stores chunks in app-private directory protected by `.nomedia`
/// - Never exposes cache to Android Gallery or MediaStore
/// - Aligned chunks of 1 MB (Telegram MTProto upload.getFile limit)
/// - Deduplicates concurrent requests for the same chunk
/// - Reuses already-cached chunks with zero network calls
/// - Implements LRU cache eviction (default max 500 MB)
/// - Never confuses partial/range cache or thumbnails with complete originals
class VideoRangeCacheManager {
  static const int chunkSize =
      1024 * 1024; // 1 MB per chunk (aligned to Telegram 1 MB boundary)
  static const int defaultMaxCacheSizeBytes =
      500 * 1024 * 1024; // 500 MB on disk
  static const int maxMemoryChunks = 12; // Max 12 MB in RAM buffer

  final String? customCacheDirPath;
  final bool enablePrefetch;
  final Map<String, Future<Uint8List>> _inFlightChunks = {};
  final Map<String, Uint8List> _memoryChunkCache = {};
  final List<String> _memoryChunkLru = [];
  final Map<int, Set<int>> _knownCachedChunks = {};
  int _activePlaybackRequests = 0;
  String? _resolvedCacheDir;

  /// True when ExoPlayer playback request is actively fetching chunks with HIGH priority.
  bool get hasActivePlaybackRequests => _activePlaybackRequests > 0;

  // Prefetch worker state
  final Set<String> _activePrefetches = {};
  int _activePrefetchWorkers = 0;
  static const int maxConcurrentPrefetch = 2;
  static const int prefetchAheadCount =
      8; // Keep 8 MB ahead of playhead (Task 8C)
  int? _currentPrefetchMessageId;
  int? _currentPlayheadChunk;
  final List<Completer<void>> _slotWaiters = [];
  final List<Completer<void>> _playbackWaiters = [];

  void _notifyPlaybackFinished() {
    if (_activePlaybackRequests <= 0 && _playbackWaiters.isNotEmpty) {
      final waiters = List<Completer<void>>.from(_playbackWaiters);
      _playbackWaiters.clear();
      for (final w in waiters) {
        if (!w.isCompleted) w.complete();
      }
    }
  }

  Future<void> _waitForPlaybackSlot() {
    if (_activePlaybackRequests <= 0) return Future.value();
    final completer = Completer<void>();
    _playbackWaiters.add(completer);
    return completer.future;
  }

  void _drainPlaybackWaiters() {
    for (final w in _playbackWaiters) {
      if (!w.isCompleted) w.complete();
    }
    _playbackWaiters.clear();
  }

  // Diagnostics and chunk tracing
  static int _nextRequestId = 0;
  final Map<String, ChunkTrace> _traces = {};

  VideoRangeCacheManager({this.customCacheDirPath, this.enablePrefetch = true});

  static final VideoRangeCacheManager instance = VideoRangeCacheManager();

  ChunkTrace getOrCreateTrace({
    required int messageId,
    required int chunkIndex,
    required int byteOffset,
    required int requestedSize,
    required bool isPlaybackRequest,
  }) {
    final key = '${messageId}_$chunkIndex';
    if (_traces.containsKey(key)) {
      final existing = _traces[key]!;
      if (isPlaybackRequest && !existing.isPlaybackRequest) {
        existing.isPlaybackRequest = true;
        existing.wasAlreadyPrefetching = true;
      }
      return existing;
    }
    final trace = ChunkTrace(
      requestId: ++_nextRequestId,
      chunkIndex: chunkIndex,
      byteOffset: byteOffset,
      requestedSize: requestedSize,
      isPlaybackRequest: isPlaybackRequest,
    );
    _traces[key] = trace;
    return trace;
  }

  ChunkTrace? getTrace(int messageId, int chunkIndex) {
    return _traces['${messageId}_$chunkIndex'];
  }

  void _putInMemoryCache(String key, Uint8List bytes) {
    if (_memoryChunkCache.containsKey(key)) {
      _memoryChunkLru.remove(key);
      _memoryChunkLru.add(key);
      return;
    }
    while (_memoryChunkLru.length >= maxMemoryChunks) {
      final oldestKey = _memoryChunkLru.removeAt(0);
      _memoryChunkCache.remove(oldestKey);
    }
    _memoryChunkCache[key] = bytes;
    _memoryChunkLru.add(key);
  }

  /// Clears the in-memory RAM chunk cache.
  void clearMemoryCache() {
    _memoryChunkCache.clear();
    _memoryChunkLru.clear();
  }

  /// Resolves the app-private directory path for range caches.
  Future<String> getCacheDirectoryPath() async {
    if (_resolvedCacheDir != null) return _resolvedCacheDir!;

    if (customCacheDirPath != null) {
      _resolvedCacheDir = customCacheDirPath;
    } else {
      try {
        final docDir = await getApplicationDocumentsDirectory();
        _resolvedCacheDir = '${docDir.path}/nuvex_stream_cache';
      } catch (_) {
        _resolvedCacheDir = '${Directory.systemTemp.path}/nuvex_stream_cache';
      }
    }

    _ensureDirectoryAndNoMedia(_resolvedCacheDir!);
    return _resolvedCacheDir!;
  }

  /// Directory for a specific video message.
  Future<Directory> getVideoDirectory(int messageId) async {
    final base = await getCacheDirectoryPath();
    final dir = Directory('$base/$messageId');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// File handle for a specific chunk index.
  Future<File> getChunkFile(int messageId, int chunkIndex) async {
    final dir = await getVideoDirectory(messageId);
    return File('${dir.path}/chunk_$chunkIndex.part');
  }

  /// Retrieves a 1 MB chunk, reading from in-memory buffer or local disk cache if present,
  /// or fetching from Telegram MTProto with concurrent request deduplication.
  Future<Uint8List> getChunk({
    required RemoteFile file,
    required int chunkIndex,
    required TelegramMediaService mediaService,
    Duration timeout = const Duration(seconds: 30),
    bool isPlaybackRequest = false,
    ChunkTrace? trace,
  }) async {
    final dedupeKey = '${file.telegramMessageId}_$chunkIndex';
    final chunkTrace =
        trace ??
        getOrCreateTrace(
          messageId: file.telegramMessageId,
          chunkIndex: chunkIndex,
          byteOffset: chunkIndex * chunkSize,
          requestedSize: chunkSize,
          isPlaybackRequest: isPlaybackRequest,
        );

    if (isPlaybackRequest) {
      _activePlaybackRequests++;
    }

    try {
      // 1. Return from in-memory hot cache (0ms latency)
      if (_memoryChunkCache.containsKey(dedupeKey)) {
        chunkTrace.cacheHitMiss = 'RAM_HIT';
        debugPrint(
          '[PERF_CACHE] RAM HIT chunk $chunkIndex for #${file.telegramMessageId}',
        );
        _knownCachedChunks
            .putIfAbsent(file.telegramMessageId, () => {})
            .add(chunkIndex);
        _memoryChunkLru.remove(dedupeKey);
        _memoryChunkLru.add(dedupeKey);
        return _memoryChunkCache[dedupeKey]!;
      }

      // 2. Deduplicate in-flight concurrent requests for the exact same chunk
      if (_inFlightChunks.containsKey(dedupeKey)) {
        chunkTrace.wasAlreadyPrefetching = true;
        if (isPlaybackRequest) {
          chunkTrace.isPlaybackRequest = true;
        }
        debugPrint(
          '[PERF_CACHE] DEDUPE chunk $chunkIndex for #${file.telegramMessageId} (sharing in-flight future)',
        );
        return await _inFlightChunks[dedupeKey]!;
      }

      // Create and record in-flight future synchronously before any async gap
      final future = _loadOrFetchChunk(
        file: file,
        chunkIndex: chunkIndex,
        mediaService: mediaService,
        timeout: timeout,
        trace: chunkTrace,
      );
      _inFlightChunks[dedupeKey] = future;

      try {
        final result = await future;
        return result;
      } finally {
        _inFlightChunks.remove(dedupeKey);
      }
    } finally {
      if (isPlaybackRequest) {
        _activePlaybackRequests--;
        _notifyPlaybackFinished();
        if (_currentPrefetchMessageId == file.telegramMessageId) {
          _fillPrefetchPipeline(file, mediaService);
        }
      }
    }
  }

  Future<Uint8List> _loadOrFetchChunk({
    required RemoteFile file,
    required int chunkIndex,
    required TelegramMediaService mediaService,
    required Duration timeout,
    required ChunkTrace trace,
  }) async {
    final dedupeKey = '${file.telegramMessageId}_$chunkIndex';
    final chunkFile = await getChunkFile(file.telegramMessageId, chunkIndex);

    // Return from disk cache if non-empty (asynchronous read)
    if (await chunkFile.exists()) {
      final length = await chunkFile.length();
      if (length > 0) {
        trace.cacheHitMiss = 'DISK_HIT';
        debugPrint(
          '[PERF_CACHE] DISK HIT chunk $chunkIndex for #${file.telegramMessageId}',
        );
        _knownCachedChunks
            .putIfAbsent(file.telegramMessageId, () => {})
            .add(chunkIndex);
        unawaited(chunkFile.setLastModified(DateTime.now()).catchError((_) {}));
        final bytes = await chunkFile.readAsBytes();
        _putInMemoryCache(dedupeKey, bytes);
        return bytes;
      }
    }

    debugPrint(
      '[PERF_CACHE] MISS chunk $chunkIndex for #${file.telegramMessageId}',
    );
    trace.cacheHitMiss = 'MISS';

    final result = await _fetchAndSaveChunk(
      file: file,
      chunkIndex: chunkIndex,
      chunkFile: chunkFile,
      mediaService: mediaService,
      timeout: timeout,
      trace: trace,
    );

    if (result.isNotEmpty) {
      _knownCachedChunks
          .putIfAbsent(file.telegramMessageId, () => {})
          .add(chunkIndex);
    }
    return result;
  }

  Future<Uint8List> _fetchAndSaveChunk({
    required RemoteFile file,
    required int chunkIndex,
    required File chunkFile,
    required TelegramMediaService mediaService,
    required Duration timeout,
    ChunkTrace? trace,
  }) async {
    final offset = chunkIndex * chunkSize;
    final totalSize = file.sizeBytes;

    if (totalSize > 0 && offset >= totalSize) {
      return Uint8List(0);
    }

    // Determine request limit aligned to 1 KB (up to 1 MB)
    int limit = chunkSize;
    if (totalSize > 0 && (offset + limit) > totalSize) {
      final remaining = totalSize - offset;
      limit = ((remaining + 1023) ~/ 1024) * 1024;
      limit = min(limit, chunkSize);
    }

    // Download range from Telegram MTProto
    final downloadedBytes = await mediaService.getMediaRange(
      file: file,
      offset: offset,
      limit: limit,
      timeout: timeout,
      onMetrics: (start, end, elapsedMs, activeAtStart) {
        if (trace != null) {
          trace.telegramRequestStartTime = start;
          trace.telegramResponseTime = end;
          trace.telegramTransferDurationMs = elapsedMs;
          trace.activeTelegramRequestsAtStart = activeAtStart;
        }
      },
    );

    if (downloadedBytes.isEmpty) {
      return Uint8List(0);
    }

    // Clamp padding if Telegram returned beyond total file size
    Uint8List finalBytes = downloadedBytes;
    if (totalSize > 0 && (offset + downloadedBytes.length) > totalSize) {
      final actualLength = totalSize - offset;
      if (actualLength > 0 && actualLength < downloadedBytes.length) {
        finalBytes = downloadedBytes.sublist(0, actualLength);
      }
    }

    // Store in hot in-memory cache immediately
    final dedupeKey = '${file.telegramMessageId}_$chunkIndex';
    _putInMemoryCache(dedupeKey, finalBytes);

    // Persist to disk asynchronously without blocking the player response or stalling on fsync
    unawaited(_persistChunkToDisk(chunkFile, finalBytes, trace));

    return finalBytes;
  }

  Future<void> _persistChunkToDisk(
    File chunkFile,
    Uint8List bytes, [
    ChunkTrace? trace,
  ]) async {
    final sw = Stopwatch()..start();
    try {
      final parentDir = chunkFile.parent;
      if (!parentDir.existsSync()) {
        parentDir.createSync(recursive: true);
      }
      final tempFile = File('${chunkFile.path}.tmp');
      await tempFile.writeAsBytes(bytes, flush: false);
      if (!parentDir.existsSync()) return;
      if (chunkFile.existsSync()) {
        try {
          chunkFile.deleteSync();
        } catch (_) {}
      }
      if (tempFile.existsSync() && parentDir.existsSync()) {
        await tempFile.rename(chunkFile.path);
      }
    } catch (e) {
      debugPrint('[STREAM_CACHE] Warning: Failed to persist chunk to disk: $e');
    } finally {
      sw.stop();
      if (trace != null) {
        trace.diskWriteDurationMs = sw.elapsedMilliseconds;
      }
    }
  }

  /// Proactively preloads chunk 0 (container header) and the final chunk (where moov atom resides
  /// in phone camera recordings) in parallel as soon as a video session is registered.
  void preloadMetadataRanges({
    required RemoteFile file,
    required TelegramMediaService mediaService,
  }) {
    debugPrint(
      '[PERF_STARTUP] Preloading metadata ranges (head & tail) for #${file.telegramMessageId}',
    );

    // 1. Preload Chunk 0 (container header + ftyp)
    getChunk(
      file: file,
      chunkIndex: 0,
      mediaService: mediaService,
    ).catchError((_) => Uint8List(0));

    // 2. If file > 1 MB, preload the last chunk (where moov atom resides for camera recordings)
    if (file.sizeBytes > chunkSize) {
      final lastChunkIndex = (file.sizeBytes - 1) ~/ chunkSize;
      if (lastChunkIndex > 0) {
        getChunk(
          file: file,
          chunkIndex: lastChunkIndex,
          mediaService: mediaService,
        ).catchError((_) => Uint8List(0));
      }
    }
  }

  /// Advances the sliding prefetch window ahead of the current playback chunk.
  /// Keeps up to [prefetchAheadCount] chunks (3 MB) prefetched with a max concurrency of 2 workers.
  void prefetchAhead({
    required RemoteFile file,
    required int currentChunk,
    required TelegramMediaService mediaService,
  }) {
    if (!enablePrefetch) return;
    _currentPrefetchMessageId = file.telegramMessageId;
    _currentPlayheadChunk = currentChunk;

    _fillPrefetchPipeline(file, mediaService);
  }

  /// Refills the sliding prefetch window up to [prefetchAheadCount] chunks ahead of playhead,
  /// ensuring workers are continuously active and never idle while unbuffered chunks remain.
  void _fillPrefetchPipeline(
    RemoteFile file,
    TelegramMediaService mediaService,
  ) {
    if (!enablePrefetch) return;
    if (_currentPrefetchMessageId != file.telegramMessageId) return;

    final playhead = _currentPlayheadChunk ?? 0;
    final totalChunks = ((file.sizeBytes + chunkSize - 1) ~/ chunkSize);

    for (int i = 1; i <= prefetchAheadCount; i++) {
      if (_activePrefetchWorkers >= maxConcurrentPrefetch) {
        break; // Strict concurrency cap of 2 concurrent downloads
      }

      final targetChunk = playhead + i;
      if (targetChunk >= totalChunks) break;

      final key = '${file.telegramMessageId}_$targetChunk';
      if (_memoryChunkCache.containsKey(key)) continue;
      if (_activePrefetches.contains(key)) continue;
      if (_inFlightChunks.containsKey(key)) continue;

      _schedulePrefetch(file, targetChunk, mediaService);
    }
  }

  void _releaseWorkerSlot() {
    while (_slotWaiters.isNotEmpty) {
      final waiter = _slotWaiters.removeAt(0);
      if (!waiter.isCompleted) {
        waiter.complete();
        break;
      }
    }
  }

  void _drainSlotWaiters() {
    for (final waiter in _slotWaiters) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
    _slotWaiters.clear();
  }

  Future<void> _acquireWorkerSlot() {
    if (_activePrefetchWorkers < maxConcurrentPrefetch) {
      return Future.value();
    }
    final completer = Completer<void>();
    _slotWaiters.add(completer);
    return completer.future;
  }

  Future<void> _schedulePrefetch(
    RemoteFile file,
    int chunkIndex,
    TelegramMediaService mediaService,
  ) async {
    final key = '${file.telegramMessageId}_$chunkIndex';
    _activePrefetches.add(key);

    final queueStartTime = DateTime.now();
    bool delayed = false;
    if (_activePrefetchWorkers >= maxConcurrentPrefetch) {
      delayed = true;
    }

    // Reactive queue wait without polling (0-2ms latency)
    while (_activePrefetchWorkers >= maxConcurrentPrefetch) {
      await _acquireWorkerSlot();
      if (_currentPrefetchMessageId != file.telegramMessageId) {
        _activePrefetches.remove(key);
        return;
      }
    }

    if (_currentPrefetchMessageId != file.telegramMessageId) {
      _activePrefetches.remove(key);
      return;
    }

    final queueExitTime = DateTime.now();
    final trace = getOrCreateTrace(
      messageId: file.telegramMessageId,
      chunkIndex: chunkIndex,
      byteOffset: chunkIndex * chunkSize,
      requestedSize: chunkSize,
      isPlaybackRequest: false,
    );
    trace.timeInPrefetchQueueMs = queueExitTime
        .difference(queueStartTime)
        .inMilliseconds;
    trace.delayedBehindAnotherRequest = delayed;

    // Rule 3: Playback requests MUST have higher priority than prefetch.
    // Yield while an active playback request is in flight so playback receives 100% priority.
    while (hasActivePlaybackRequests) {
      debugPrint(
        '[PERF_PREFETCH] Pausing prefetch chunk $chunkIndex while playback is active',
      );
      await _waitForPlaybackSlot();
      if (_currentPrefetchMessageId != file.telegramMessageId) {
        _activePrefetches.remove(key);
        return;
      }
    }

    _activePrefetchWorkers++;
    debugPrint(
      '[PERF_PREFETCH] Active workers: $_activePrefetchWorkers | Prefetching chunk $chunkIndex for #${file.telegramMessageId}',
    );

    try {
      await getChunk(
        file: file,
        chunkIndex: chunkIndex,
        mediaService: mediaService,
        isPlaybackRequest: false,
        trace: trace,
      );
    } catch (e, stack) {
      debugPrint(
        '[PERF_PREFETCH] Error prefetching chunk $chunkIndex: $e\n$stack',
      );
    } finally {
      _activePrefetchWorkers--;
      _activePrefetches.remove(key);
      _releaseWorkerSlot();

      if (!trace.isPlaybackRequest) {
        trace.totalEndToEndLatencyMs = DateTime.now()
            .difference(trace.traceStartTime)
            .inMilliseconds;
        trace.logSummary();
      }

      // Continuous pipeline: immediately refill next uncached chunk in window
      if (_currentPrefetchMessageId == file.telegramMessageId &&
          !hasActivePlaybackRequests) {
        _fillPrefetchPipeline(file, mediaService);
      }
    }
  }

  /// Warmed up the in-memory index of locally cached chunks for [messageId].
  Future<void> warmUpCacheState(int messageId) async {
    try {
      final base = await getCacheDirectoryPath();
      final dir = Directory('$base/$messageId');
      if (await dir.exists()) {
        final set = _knownCachedChunks.putIfAbsent(messageId, () => {});
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is File) {
            final name = entity.uri.pathSegments.last;
            if (name.startsWith('chunk_') && name.endsWith('.part')) {
              final idxStr = name.substring(6, name.length - 5);
              final idx = int.tryParse(idxStr);
              if (idx != null) {
                final len = await entity.length();
                if (len > 0) {
                  set.add(idx);
                }
              }
            }
          }
        }
      }
    } catch (_) {}
  }

  /// Checks if [chunkIndex] for [messageId] is currently cached in memory or on disk.
  bool isChunkCached(int messageId, int chunkIndex) {
    final key = '${messageId}_$chunkIndex';
    if (_memoryChunkCache.containsKey(key)) return true;
    final cachedSet = _knownCachedChunks[messageId];
    if (cachedSet != null) {
      return cachedSet.contains(chunkIndex);
    }
    if (_resolvedCacheDir != null) {
      final f = File('$_resolvedCacheDir/$messageId/chunk_$chunkIndex.part');
      if (f.existsSync() && f.lengthSync() > 0) {
        _knownCachedChunks.putIfAbsent(messageId, () => {}).add(chunkIndex);
        return true;
      }
    }
    return false;
  }

  /// Calculates the contiguous bytes cached without any gaps starting from [currentByteOffset].
  int getContiguousBufferedAhead(
    int messageId,
    int currentByteOffset,
    int totalSize,
  ) {
    if (totalSize <= 0 || currentByteOffset >= totalSize) return 0;
    final currentChunk = currentByteOffset ~/ chunkSize;
    final totalChunks = (totalSize + chunkSize - 1) ~/ chunkSize;

    int contiguousEnd = currentByteOffset;
    for (int c = currentChunk; c < totalChunks; c++) {
      if (!isChunkCached(messageId, c)) {
        break;
      }
      final chunkEnd = min(totalSize, (c + 1) * chunkSize);
      contiguousEnd = chunkEnd;
    }
    return max(0, contiguousEnd - currentByteOffset);
  }

  /// Returns all contiguous cached byte intervals [start, end] for [messageId].
  List<({int start, int end})> getContiguousCachedRanges(
    int messageId,
    int totalSize,
  ) {
    if (totalSize <= 0) return [];
    final totalChunks = (totalSize + chunkSize - 1) ~/ chunkSize;
    final ranges = <({int start, int end})>[];
    int? rangeStart;
    int? rangeEnd;

    for (int c = 0; c < totalChunks; c++) {
      if (isChunkCached(messageId, c)) {
        final chunkStart = c * chunkSize;
        final chunkEnd = min(totalSize, (c + 1) * chunkSize) - 1;
        if (rangeStart == null) {
          rangeStart = chunkStart;
          rangeEnd = chunkEnd;
        } else {
          rangeEnd = chunkEnd;
        }
      } else {
        if (rangeStart != null && rangeEnd != null) {
          ranges.add((start: rangeStart, end: rangeEnd));
          rangeStart = null;
          rangeEnd = null;
        }
      }
    }
    if (rangeStart != null && rangeEnd != null) {
      ranges.add((start: rangeStart, end: rangeEnd));
    }
    return ranges;
  }

  /// Cancels pending prefetch requests when the user seeks to a different part of the file.
  void cancelPrefetch(int messageId) {
    debugPrint(
      '[PERF_SEEK] Canceling prefetch for #$messageId to reprioritize seek location',
    );
    _currentPrefetchMessageId = null;
    _currentPlayheadChunk = null;
    _activePrefetches.clear();
    _drainSlotWaiters();
    _drainPlaybackWaiters();
  }

  /// Retrieves an arbitrary byte range [start, end] across cached/downloaded 512 KB chunks.
  Future<Uint8List> getRangeBytes({
    required RemoteFile file,
    required int start,
    required int end,
    required TelegramMediaService mediaService,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (start < 0 || end < start) {
      return Uint8List(0);
    }

    final startChunk = start ~/ chunkSize;
    final endChunk = end ~/ chunkSize;
    final builder = BytesBuilder(copy: false);

    for (int c = startChunk; c <= endChunk; c++) {
      final chunk = await getChunk(
        file: file,
        chunkIndex: c,
        mediaService: mediaService,
        timeout: timeout,
      );

      if (chunk.isEmpty) break;

      final chunkStartByte = c * chunkSize;
      final chunkEndByte = chunkStartByte + chunk.length - 1;

      final sliceStart = max(0, start - chunkStartByte);
      final sliceEnd = min(chunk.length, end - chunkStartByte + 1);

      if (sliceStart < sliceEnd && sliceStart < chunk.length) {
        builder.add(chunk.sublist(sliceStart, sliceEnd));
      }

      if (chunkEndByte >= end) {
        break;
      }
    }

    return builder.takeBytes();
  }

  /// Checks if all chunks required to satisfy [start] to [end] exist on disk.
  Future<bool> isRangeLocallyCached({
    required int messageId,
    required int start,
    required int end,
  }) async {
    final startChunk = start ~/ chunkSize;
    final endChunk = end ~/ chunkSize;

    for (int c = startChunk; c <= endChunk; c++) {
      final chunkFile = await getChunkFile(messageId, c);
      if (!chunkFile.existsSync() || chunkFile.lengthSync() == 0) {
        return false;
      }
    }
    return true;
  }

  /// Cleans old video range caches using LRU eviction when total cache exceeds [maxSizeBytes].
  Future<int> cleanOldCache({
    int maxSizeBytes = defaultMaxCacheSizeBytes,
  }) async {
    try {
      final baseDir = Directory(await getCacheDirectoryPath());
      if (!baseDir.existsSync()) return 0;

      final videoDirs = <Directory>[];
      int totalBytes = 0;

      await for (final entity in baseDir.list(followLinks: false)) {
        if (entity is Directory) {
          videoDirs.add(entity);
          try {
            for (final f in entity.listSync(followLinks: false)) {
              if (f is File) {
                totalBytes += f.lengthSync();
              }
            }
          } catch (_) {}
        }
      }

      if (totalBytes <= maxSizeBytes) {
        return 0;
      }

      // Sort video directories by oldest modification time
      videoDirs.sort((a, b) {
        final aTime = _getLatestModified(a);
        final bTime = _getLatestModified(b);
        return aTime.compareTo(bTime);
      });

      int deletedBytes = 0;
      for (final dir in videoDirs) {
        if (totalBytes <= maxSizeBytes) break;
        try {
          int dirSize = 0;
          for (final f in dir.listSync(followLinks: false)) {
            if (f is File) dirSize += f.lengthSync();
          }
          dir.deleteSync(recursive: true);
          totalBytes -= dirSize;
          deletedBytes += dirSize;
          debugPrint(
            '[STREAM_CACHE] Evicted video cache directory: ${dir.path} ($dirSize bytes freed)',
          );
        } catch (_) {}
      }

      return deletedBytes;
    } catch (e) {
      debugPrint('[STREAM_CACHE] Error cleaning old cache: $e');
      return 0;
    }
  }

  DateTime _getLatestModified(Directory dir) {
    try {
      DateTime latest = dir.statSync().modified;
      for (final f in dir.listSync(followLinks: false)) {
        if (f is File) {
          final m = f.lastModifiedSync();
          if (m.isAfter(latest)) latest = m;
        }
      }
      return latest;
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  /// Clears cached range chunks for a specific video message.
  Future<void> clearCacheForFile(int messageId) async {
    try {
      final dir = await getVideoDirectory(messageId);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    } catch (_) {}
  }

  /// Ensures directory exists and contains a .nomedia guard file.
  void _ensureDirectoryAndNoMedia(String path) {
    try {
      final dir = Directory(path);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final noMedia = File('$path/.nomedia');
      if (!noMedia.existsSync()) {
        noMedia.createSync();
      }
    } catch (_) {}
  }
}
