import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuvex/core/database/remote_file.dart';
import 'package:nuvex/core/services/video_prefetch_manager.dart';
import 'package:nuvex/core/services/video_range_cache_manager.dart';
import 'package:nuvex/core/services/video_streaming_proxy.dart';
import 'package:nuvex/telegram/telegram_media_service.dart';

class MockPrefetchTelegramService extends TelegramMediaService {
  final int totalFileSize;
  final int simulatedDelayMs;
  final List<({int offset, int limit, bool isPlayback})> requests = [];
  int activeRequests = 0;
  int maxConcurrentRequestsObserved = 0;

  MockPrefetchTelegramService({
    required this.totalFileSize,
    this.simulatedDelayMs = 20,
  });

  @override
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
    // Check 1 KB alignment
    if (offset % 1024 != 0 || limit % 1024 != 0) {
      throw ArgumentError('Offset and limit must be 1024 aligned');
    }
    // Check region boundary
    const oneMb = 1024 * 1024;
    if (offset ~/ oneMb != (offset + limit - 1) ~/ oneMb) {
      throw StateError('Cannot cross 1 MB boundary');
    }

    activeRequests++;
    if (activeRequests > maxConcurrentRequestsObserved) {
      maxConcurrentRequestsObserved = activeRequests;
    }
    final activeAtStart = activeRequests;
    final start = DateTime.now();

    requests.add((offset: offset, limit: limit, isPlayback: false));

    if (simulatedDelayMs > 0) {
      await Future.delayed(Duration(milliseconds: simulatedDelayMs));
    }

    final end = DateTime.now();
    activeRequests--;

    onMetrics?.call(
      start,
      end,
      end.difference(start).inMilliseconds,
      activeAtStart,
    );

    final available = totalFileSize > offset ? totalFileSize - offset : 0;
    final len = available < limit ? available : limit;
    final bytes = Uint8List(len);
    for (int i = 0; i < len; i += 4096) {
      bytes[i] = (offset + i) % 256;
    }
    return bytes;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory tempDir;
  late VideoRangeCacheManager cacheManager;
  late VideoPrefetchManager prefetchManager;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('nuvex_prefetch_test_');
    cacheManager = VideoRangeCacheManager(
      customCacheDirPath: tempDir.path,
      enablePrefetch: false, // We test VideoPrefetchManager explicitly
    );
    prefetchManager = VideoPrefetchManager(cacheManager: cacheManager);
  });

  tearDown(() async {
    prefetchManager.stop();
    prefetchManager.reset();
    try {
      await VideoStreamingProxy.instance.stop();
    } catch (_) {}
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  RemoteFile createMockFile({required int messageId, required int sizeBytes}) {
    return RemoteFile(
      id: messageId,
      telegramChatId: 1001,
      telegramMessageId: messageId,
      telegramFileId: messageId * 100,
      name: 'video_$messageId.mp4',
      mimeType: 'video/mp4',
      sizeBytes: sizeBytes,
      createdAt: DateTime.now(),
      modifiedAt: DateTime.now(),
      category: 'videos',
    );
  }

  group('Task 8C — VideoPrefetchManager Read-Ahead Engine', () {
    test('Proactively prefetches ~8 MB ahead of playback playhead', () async {
      const fileSize = 150 * 1024 * 1024; // 150 MB
      final file = createMockFile(messageId: 701, sizeBytes: fileSize);
      final mediaService = MockPrefetchTelegramService(
        totalFileSize: fileSize,
        simulatedDelayMs: 10,
      );

      prefetchManager.start(file: file, mediaService: mediaService);

      // Give worker pipeline time to fetch target buffer (~8 chunks)
      await Future.delayed(const Duration(milliseconds: 350));

      final bufferedAhead = cacheManager.getContiguousBufferedAhead(
        file.telegramMessageId,
        0,
        file.sizeBytes,
      );

      // Verify at least 4 MB (minimum) to 8 MB (normal) is buffered ahead
      expect(bufferedAhead, greaterThanOrEqualTo(4 * 1024 * 1024));
      expect(bufferedAhead, lessThanOrEqualTo(16 * 1024 * 1024));

      // Verify each individual request obeyed Telegram 1 MB rules
      for (final r in mediaService.requests) {
        expect(r.limit, lessThanOrEqualTo(1024 * 1024));
        expect(r.offset % 1024, 0);
        expect(r.limit % 1024, 0);
      }

      // CRITICAL: Total downloaded data is substantially less than 150 MB
      final totalDownloaded = mediaService.requests.fold<int>(
        0,
        (s, r) => s + r.limit,
      );
      expect(totalDownloaded, lessThan(20 * 1024 * 1024));
    });

    test(
      'Deduplicates in-flight requests between playback and prefetch',
      () async {
        const fileSize = 50 * 1024 * 1024;
        final file = createMockFile(messageId: 702, sizeBytes: fileSize);
        final mediaService = MockPrefetchTelegramService(
          totalFileSize: fileSize,
          simulatedDelayMs: 80, // Slower download to test in-flight sharing
        );

        prefetchManager.start(file: file, mediaService: mediaService);

        // Give prefetch a moment to initiate chunk 0/1
        await Future.delayed(const Duration(milliseconds: 10));

        // ExoPlayer now requests chunk 1 while prefetch is fetching chunk 1
        final chunk1Future = cacheManager.getChunk(
          file: file,
          chunkIndex: 1,
          mediaService: mediaService,
          isPlaybackRequest: true,
        );

        final chunk1Bytes = await chunk1Future;
        expect(chunk1Bytes.length, 1024 * 1024);

        // Count how many requests were made for chunk 1 offset (1048576)
        final chunk1Requests = mediaService.requests
            .where((r) => r.offset == 1024 * 1024)
            .toList();
        expect(
          chunk1Requests.length,
          1,
          reason: 'Must share in-flight future without duplicate request',
        );
      },
    );

    test(
      'Seeking cancels obsolete prefetch and rebuilds read-ahead window',
      () async {
        const fileSize = 150 * 1024 * 1024;
        final file = createMockFile(messageId: 703, sizeBytes: fileSize);
        final mediaService = MockPrefetchTelegramService(
          totalFileSize: fileSize,
          simulatedDelayMs: 50,
        );

        prefetchManager.start(file: file, mediaService: mediaService);
        await Future.delayed(const Duration(milliseconds: 70));

        // User seeks to 80 MB (offset 83886080, chunk 80)
        const seekOffset = 80 * 1024 * 1024;
        prefetchManager.onPlaybackRangeRequested(
          file: file,
          start: seekOffset,
          end: seekOffset + 524287,
        );

        expect(prefetchManager.authoritativeBytePosition, seekOffset);

        // Wait for prefetch workers to refocus around chunk 80
        await Future.delayed(const Duration(milliseconds: 300));

        // Verify new requests are centered around chunk 80
        final seekAreaRequests = mediaService.requests
            .where((r) => r.offset >= seekOffset)
            .toList();
        expect(seekAreaRequests.isNotEmpty, isTrue);
        expect(seekAreaRequests.first.offset, greaterThanOrEqualTo(seekOffset));
      },
    );

    test('Cache hit returns immediately without contacting Telegram', () async {
      const fileSize = 20 * 1024 * 1024;
      final file = createMockFile(messageId: 704, sizeBytes: fileSize);
      final mediaService = MockPrefetchTelegramService(
        totalFileSize: fileSize,
        simulatedDelayMs: 0,
      );

      // Pre-fill chunk 0
      await cacheManager.getChunk(
        file: file,
        chunkIndex: 0,
        mediaService: mediaService,
      );
      final initialCount = mediaService.requests.length;
      expect(initialCount, 1);

      // Now start prefetch session at 0
      prefetchManager.start(file: file, mediaService: mediaService);
      prefetchManager.onPlaybackRangeRequested(
        file: file,
        start: 0,
        end: 524287,
      );

      expect(cacheManager.isChunkCached(file.telegramMessageId, 0), isTrue);

      // Chunk 0 must not be re-requested
      final chunk0Requests = mediaService.requests
          .where((r) => r.offset == 0)
          .toList();
      expect(chunk0Requests.length, 1);
    });

    test(
      'Playback requests take priority over background prefetch workers',
      () async {
        const fileSize = 30 * 1024 * 1024;
        final file = createMockFile(messageId: 705, sizeBytes: fileSize);
        final mediaService = MockPrefetchTelegramService(
          totalFileSize: fileSize,
          simulatedDelayMs: 40,
        );

        prefetchManager.start(file: file, mediaService: mediaService);

        // Simulate playback request arriving
        final playbackFuture = cacheManager.getChunk(
          file: file,
          chunkIndex: 5,
          mediaService: mediaService,
          isPlaybackRequest: true,
        );

        expect(cacheManager.hasActivePlaybackRequests, isTrue);
        final bytes = await playbackFuture;
        expect(bytes.length, 1024 * 1024);
        expect(cacheManager.hasActivePlaybackRequests, isFalse);
      },
    );
  });
}
