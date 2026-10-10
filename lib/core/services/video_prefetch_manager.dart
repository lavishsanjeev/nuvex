import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../../telegram/telegram_media_service.dart';
import '../database/remote_file.dart';
import 'video_range_cache_manager.dart';

/// Proactive read-ahead prefetch manager for instant video streaming in Nuvex.
///
/// Strictly conforms to Task 8C requirements:
/// - Authoritative byte position tracking from HTTP range requests and cache state.
/// - Aggressive read-ahead prefetch (4 MB min, 8 MB target, up to 16 MB max).
/// - Telegram MTProto chunk alignment (1 KB aligned, <= 1 MB chunk boundaries).
/// - Playback requests strictly prioritized over background prefetch.
/// - In-flight deduplication sharing identical futures.
/// - Seek cancellation and window re-centering without wasting bandwidth.
/// - Continuous logging adhering to specified format:
///   [PREFETCH] position=...
///   [PREFETCH] bufferedAhead=...
///   [PREFETCH] targetAhead=...
///   [PREFETCH] requesting range=start-end
///   [PREFETCH] cache hit start-end
///   [PREFETCH] download complete start-end
///   [PREFETCH] bufferedAhead now=...
///   [PREFETCH] cancelling obsolete range...
///   [PREFETCH] playback priority request...
///   [PLAYER] position=...
///   [PLAYER] buffered=...
class VideoPrefetchManager {
  static const int minBufferBytes = 4 * 1024 * 1024; // 4 MB minimum buffer
  static const int defaultTargetBufferBytes =
      8 * 1024 * 1024; // 8 MB normal target
  static const int maxBufferBytes = 16 * 1024 * 1024; // 16 MB maximum buffer
  static const int chunkSize =
      VideoRangeCacheManager.chunkSize; // 1 MB (1048576 bytes)
  static const int maxConcurrentPrefetch = 2; // Strict concurrency cap

  final VideoRangeCacheManager _cacheManager;
  TelegramMediaService? _mediaService;
  RemoteFile? _currentFile;

  int _authoritativeBytePosition = 0;
  int _authoritativeEndByte = 0;
  int _targetAheadBytes = defaultTargetBufferBytes;
  int _generation = 0;
  bool _isRunning = false;
  int _activePrefetchWorkers = 0;
  final Set<int> _activePrefetchChunks = {};
  final List<double> _recentDownloadSpeedsBytesPerSec = [];

  Duration _playerPosition = Duration.zero;
  Duration _playerDuration = Duration.zero;
  List<DurationRange> _playerBuffered = [];
  bool _isPlaying = false;
  bool _isBuffering = false;
  DateTime? _lastPlayerLogTime;
  bool _refillInProgress = false;

  VideoPrefetchManager({VideoRangeCacheManager? cacheManager})
    : _cacheManager = cacheManager ?? VideoRangeCacheManager.instance;

  static final VideoPrefetchManager instance = VideoPrefetchManager();

  // Getters for inspection and testing
  RemoteFile? get currentFile => _currentFile;
  int get authoritativeBytePosition => _authoritativeBytePosition;
  int get authoritativeEndByte => _authoritativeEndByte;
  int get targetAheadBytes => _targetAheadBytes;
  int get activePrefetchWorkers => _activePrefetchWorkers;
  Set<int> get activePrefetchChunks => Set.unmodifiable(_activePrefetchChunks);
  bool get isRunning => _isRunning;
  bool get isPlaying => _isPlaying;
  bool get isBuffering => _isBuffering;
  Duration get playerPosition => _playerPosition;
  Duration get playerDuration => _playerDuration;

  /// Starts a prefetch session for [file] using [mediaService].
  void start({
    required RemoteFile file,
    required TelegramMediaService mediaService,
  }) {
    if (_currentFile?.telegramMessageId == file.telegramMessageId &&
        _isRunning) {
      return;
    }

    _currentFile = file;
    _mediaService = mediaService;
    _authoritativeBytePosition = 0;
    _authoritativeEndByte = 0;
    _targetAheadBytes = defaultTargetBufferBytes;
    _generation++;
    _activePrefetchChunks.clear();
    _recentDownloadSpeedsBytesPerSec.clear();
    _isRunning = true;
    _lastPlayerLogTime = null;

    debugPrint(
      '[PREFETCH] Started prefetch session for #${file.telegramMessageId} (${file.name}, ${file.sizeBytes} bytes)',
    );

    // Warm up known cache chunks for this file
    _cacheManager.warmUpCacheState(file.telegramMessageId);

    // Initial prefetch ahead of starting chunk
    unawaited(refillPrefetchWindow());
  }

  /// Called by [VideoStreamingProxy] whenever ExoPlayer requests an HTTP range.
  /// This is the PRIMARY source of truth for the playback playhead byte offset.
  void onPlaybackRangeRequested({
    required RemoteFile file,
    required int start,
    required int end,
  }) {
    debugPrint('[PREFETCH] playback priority range=$start-$end');

    if (_currentFile?.telegramMessageId != file.telegramMessageId) {
      if (_mediaService != null) {
        this.start(file: file, mediaService: _mediaService!);
      } else {
        _currentFile = file;
        _isRunning = true;
      }
    }

    final prevStart = _authoritativeBytePosition;
    final prevEnd = _authoritativeEndByte;
    _authoritativeBytePosition = start;
    _authoritativeEndByte = end;

    if (prevEnd > 0) {
      final forwardGap = start - prevEnd;
      final isSequentialOrAdjacent =
          (forwardGap >= -chunkSize && forwardGap <= 2 * chunkSize) ||
          ((start - prevStart).abs() <= chunkSize);

      if (!isSequentialOrAdjacent) {
        // Genuine seek detected!
        cancelObsoletePrefetch(
          newBytePosition: start,
          reason: 'seek jump from byte $prevStart to $start',
        );
      }
    } else if (start > 2 * chunkSize) {
      cancelObsoletePrefetch(
        newBytePosition: start,
        reason: 'initial playback starting at non-zero offset $start',
      );
    }

    // Refill prefetch ahead of new playback position
    unawaited(refillPrefetchWindow());
  }

  /// Cancels pending prefetch tasks when a seek or discontinuity occurs.
  void cancelObsoletePrefetch({
    required int newBytePosition,
    String reason = 'seek',
  }) {
    debugPrint(
      '[PREFETCH] cancelling obsolete range... (reason: $reason, newPosition: $newBytePosition)',
    );
    _generation++;
    _activePrefetchChunks.clear();
    _authoritativeBytePosition = newBytePosition;
  }

  DateTime? _lastRefillCheckTime;
  Duration _lastCheckedPosition = Duration.zero;
  bool _lastRecordedBuffering = false;
  bool _lastRecordedPlaying = false;
  DateTime? _lastPrefetchLogTime;

  /// Updates player playback state and instruments [PLAYER] logs.
  void updatePlayerState({
    required Duration position,
    required Duration duration,
    List<DurationRange>? buffered,
    required bool isPlaying,
    required bool isBuffering,
  }) {
    _playerPosition = position;
    _playerDuration = duration;
    if (buffered != null) _playerBuffered = buffered;
    _isPlaying = isPlaying;
    _isBuffering = isBuffering;

    final now = DateTime.now();
    // Rate-limited [PLAYER] logging (at most once every 500ms unless buffering state changes)
    if (_lastPlayerLogTime == null ||
        now.difference(_lastPlayerLogTime!).inMilliseconds >= 500 ||
        isBuffering != _lastRecordedBuffering) {
      _lastPlayerLogTime = now;
      final bufferedStr = _playerBuffered
          .map((r) => '${r.start.inMilliseconds}-${r.end.inMilliseconds}ms')
          .join(', ');
      debugPrint('[PLAYER] position=${position.inMilliseconds}ms');
      debugPrint('[PLAYER] buffered=$bufferedStr');
    }

    // Rate-limit buffer checking to avoid running file stat / cache checks on every 16ms animation frame
    final bool bufferingChanged = isBuffering != _lastRecordedBuffering;
    final bool playingChanged = isPlaying != _lastRecordedPlaying;
    final bool positionMovedSignificantly =
        (position - _lastCheckedPosition).abs().inMilliseconds >= 1000;
    final bool intervalElapsed =
        _lastRefillCheckTime == null ||
        now.difference(_lastRefillCheckTime!).inMilliseconds >= 500;

    if ((_isPlaying || _isBuffering) &&
        (bufferingChanged ||
            playingChanged ||
            positionMovedSignificantly ||
            intervalElapsed)) {
      _lastRefillCheckTime = now;
      _lastCheckedPosition = position;
      _lastRecordedBuffering = isBuffering;
      _lastRecordedPlaying = isPlaying;

      final file = _currentFile;
      if (file != null && file.sizeBytes > 0) {
        final bufferedAhead = _cacheManager.getContiguousBufferedAhead(
          file.telegramMessageId,
          _authoritativeBytePosition,
          file.sizeBytes,
        );

        // If buffer drops below 2 MB or buffering, refill aggressively
        if (bufferedAhead < 2 * 1024 * 1024 ||
            _isBuffering ||
            bufferedAhead < _targetAheadBytes) {
          unawaited(refillPrefetchWindow());
        }
      }
    }
  }

  /// Refills the sliding prefetch window up to [targetAheadBytes] ahead of playhead.
  Future<void> refillPrefetchWindow() async {
    if (!_isRunning || _currentFile == null || _mediaService == null) return;
    if (_refillInProgress) return;
    _refillInProgress = true;

    try {
      final file = _currentFile!;
      final totalSize = file.sizeBytes;
      if (totalSize <= 0) return;

      final currentPos = _authoritativeBytePosition;
      final bufferedAhead = _cacheManager.getContiguousBufferedAhead(
        file.telegramMessageId,
        currentPos,
        totalSize,
      );

      final now = DateTime.now();
      if (_lastPrefetchLogTime == null ||
          now.difference(_lastPrefetchLogTime!).inMilliseconds >= 500) {
        _lastPrefetchLogTime = now;
        debugPrint('[PREFETCH] position=$currentPos');
        debugPrint('[PREFETCH] bufferedAhead=$bufferedAhead');
        debugPrint('[PREFETCH] targetAhead=$_targetAheadBytes');
      }

      final startChunk = currentPos ~/ chunkSize;
      final totalChunks = (totalSize + chunkSize - 1) ~/ chunkSize;
      final desiredEndByte = min(totalSize, currentPos + _targetAheadBytes);
      final targetEndChunk = (desiredEndByte - 1) ~/ chunkSize;

      for (int c = startChunk; c <= targetEndChunk && c < totalChunks; c++) {
        if (!_isRunning ||
            _currentFile?.telegramMessageId != file.telegramMessageId) {
          break;
        }

        final chunkStart = c * chunkSize;
        final chunkEnd = min(totalSize, (c + 1) * chunkSize) - 1;

        if (_cacheManager.isChunkCached(file.telegramMessageId, c)) {
          debugPrint('[PREFETCH] cache hit $chunkStart-$chunkEnd');
          continue;
        }

        if (_activePrefetchChunks.contains(c)) {
          continue;
        }

        // Rule 3: Playback requests MUST have higher priority than prefetch.
        // If a playback chunk is actively downloading, pause background prefetch workers.
        if (_cacheManager.hasActivePlaybackRequests) {
          break;
        }

        if (_activePrefetchWorkers >= maxConcurrentPrefetch) {
          break;
        }

        _scheduleChunkPrefetch(file, c, _generation);
      }
    } finally {
      _refillInProgress = false;
    }
  }

  void _scheduleChunkPrefetch(
    RemoteFile file,
    int chunkIndex,
    int generation,
  ) async {
    if (_activePrefetchWorkers >= maxConcurrentPrefetch) return;
    _activePrefetchWorkers++;
    _activePrefetchChunks.add(chunkIndex);

    final chunkStart = chunkIndex * chunkSize;
    final chunkEnd = min(file.sizeBytes, (chunkIndex + 1) * chunkSize) - 1;

    debugPrint('[PREFETCH] requesting range=$chunkStart-$chunkEnd');
    final sw = Stopwatch()..start();

    try {
      // Rule 3: Playback requests strictly prioritized over background prefetch.
      // Yield immediately if an active playback chunk is being retrieved.
      if (_cacheManager.hasActivePlaybackRequests) {
        debugPrint(
          '[PREFETCH] Yielding chunk $chunkIndex to active playback request',
        );
        return;
      }

      if (generation != _generation ||
          !_isRunning ||
          _currentFile?.telegramMessageId != file.telegramMessageId) {
        return;
      }

      final bytes = await _cacheManager.getChunk(
        file: file,
        chunkIndex: chunkIndex,
        mediaService: _mediaService!,
        isPlaybackRequest: false,
      );
      sw.stop();

      if (generation != _generation ||
          !_isRunning ||
          _currentFile?.telegramMessageId != file.telegramMessageId) {
        return;
      }

      if (bytes.isNotEmpty) {
        final elapsedMs = sw.elapsedMilliseconds;
        if (elapsedMs > 0) {
          final speed = (bytes.length * 1000.0) / elapsedMs;
          _adaptTargetBuffer(speed);
        }

        debugPrint('[PREFETCH] download complete range=$chunkStart-$chunkEnd');

        final newBufferedAhead = _cacheManager.getContiguousBufferedAhead(
          file.telegramMessageId,
          _authoritativeBytePosition,
          file.sizeBytes,
        );
        debugPrint('[PREFETCH] bufferedAhead=$newBufferedAhead');
        debugPrint('[PREFETCH] bufferedAhead now=$newBufferedAhead');
      }
    } catch (e, stack) {
      debugPrint('[PREFETCH] Error prefetching chunk $chunkIndex: $e\n$stack');
    } finally {
      _activePrefetchWorkers--;
      _activePrefetchChunks.remove(chunkIndex);

      // Continue refilling the prefetch pipeline for the active generation
      if (_isRunning &&
          _currentFile?.telegramMessageId == file.telegramMessageId) {
        unawaited(refillPrefetchWindow());
      }
    }
  }

  /// Dynamically tunes the read-ahead buffer based on measured network throughput.
  void _adaptTargetBuffer(double speedBytesPerSec) {
    _recentDownloadSpeedsBytesPerSec.add(speedBytesPerSec);
    if (_recentDownloadSpeedsBytesPerSec.length > 5) {
      _recentDownloadSpeedsBytesPerSec.removeAt(0);
    }
    final avgSpeed =
        _recentDownloadSpeedsBytesPerSec.reduce((a, b) => a + b) /
        _recentDownloadSpeedsBytesPerSec.length;

    if (avgSpeed > 2.5 * 1024 * 1024) {
      // Fast network (> 2.5 MB/s): expand buffer up to 16 MB
      _targetAheadBytes = maxBufferBytes;
    } else if (avgSpeed < 1.0 * 1024 * 1024) {
      // Slower network (< 1.0 MB/s): prioritize minimum playable buffer 4 MB
      _targetAheadBytes = minBufferBytes;
    } else {
      // Normal network (1.0 - 2.5 MB/s): 8 MB target
      _targetAheadBytes = defaultTargetBufferBytes;
    }
  }

  /// Stops the prefetch manager and cancels all active workers.
  void stop() {
    _isRunning = false;
    _generation++;
    _activePrefetchChunks.clear();
    _currentFile = null;
    _refillInProgress = false;
    debugPrint('[PREFETCH] Stopped prefetch manager');
  }

  /// Completely resets state.
  void reset() {
    stop();
    _mediaService = null;
    _authoritativeBytePosition = 0;
    _authoritativeEndByte = 0;
    _targetAheadBytes = defaultTargetBufferBytes;
    _activePrefetchWorkers = 0;
    _recentDownloadSpeedsBytesPerSec.clear();
    _playerPosition = Duration.zero;
    _playerDuration = Duration.zero;
    _playerBuffered = [];
    _isPlaying = false;
    _isBuffering = false;
    _lastPlayerLogTime = null;
  }
}
