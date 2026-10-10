// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuvex/core/database/remote_file.dart';
import 'package:nuvex/core/services/video_range_cache_manager.dart';
import 'package:nuvex/core/services/video_streaming_proxy.dart';
import 'package:nuvex/telegram/telegram_media_service.dart';

class LatencySimulatingTelegramService extends TelegramMediaService {
  final int totalFileSize;
  final int latencyMsPerMb;
  int _activeRequests = 0;
  final List<
    ({
      int offset,
      int limit,
      int activeAtStart,
      int elapsedMs,
      DateTime start,
      DateTime end,
    })
  >
  log = [];

  LatencySimulatingTelegramService({
    required this.totalFileSize,
    this.latencyMsPerMb = 80,
  });

  @override
  int get activeTelegramRequests => _activeRequests;

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
    _activeRequests++;
    final activeAtStart = _activeRequests;
    final start = DateTime.now();

    // Simulate network transfer time proportional to requested bytes
    final simulatedMs = ((limit / (1024 * 1024)) * latencyMsPerMb)
        .round()
        .clamp(10, 5000);
    await Future.delayed(Duration(milliseconds: simulatedMs));

    final end = DateTime.now();
    final elapsed = end.difference(start).inMilliseconds;
    _activeRequests--;

    log.add((
      offset: offset,
      limit: limit,
      activeAtStart: activeAtStart,
      elapsedMs: elapsed,
      start: start,
      end: end,
    ));

    onMetrics?.call(start, end, elapsed, activeAtStart);

    // Return dummy data of requested limit
    final available = totalFileSize > offset ? totalFileSize - offset : 0;
    final length = available < limit ? available : limit;
    final bytes = Uint8List(length);
    for (int i = 0; i < length; i += 4096) {
      bytes[i] = (offset + i) % 256;
    }
    return bytes;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory tempDir;
  late HttpClient httpClient;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('nuvex_trace_test_');
    httpClient = HttpClient();
  });

  tearDown(() async {
    httpClient.close();
    try {
      await VideoStreamingProxy.instance.stop();
    } catch (_) {}
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  RemoteFile createMockVideoFile({
    required int messageId,
    required int sizeBytes,
  }) {
    return RemoteFile(
      id: messageId,
      telegramChatId: 12345,
      telegramMessageId: messageId,
      telegramFileId: messageId * 10,
      name: 'trace_video_$messageId.mp4',
      mimeType: 'video/mp4',
      sizeBytes: sizeBytes,
      createdAt: DateTime.now(),
      modifiedAt: DateTime.now(),
      category: 'videos',
    );
  }

  test('Trace latency: Sequential playback through VideoStreamingProxy', () async {
    const fileSize = 20 * 1024 * 1024; // 20 MB = 20 chunks
    final cacheManager = VideoRangeCacheManager(
      customCacheDirPath: tempDir.path,
      enablePrefetch: true,
    );
    final mediaService = LatencySimulatingTelegramService(
      totalFileSize: fileSize,
      latencyMsPerMb: 100, // 100ms per 1MB
    );
    final proxy = VideoStreamingProxy(
      mediaService: mediaService,
      cacheManager: cacheManager,
      enablePreload:
          false, // disable startup preload to isolate playback requests
    );
    await proxy.ensureStarted();

    final file = createMockVideoFile(messageId: 999, sizeBytes: fileSize);
    final streamUrl = proxy.registerFile(file);

    print('\n=== SCENARIO 1: Requesting chunk 0 via HTTP Range ===');
    final sw0 = Stopwatch()..start();
    final req0 = await httpClient.getUrl(Uri.parse(streamUrl));
    req0.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1048575'); // Chunk 0
    final res0 = await req0.close();
    final bytes0 = await res0.fold<List<int>>([], (p, e) => p..addAll(e));
    sw0.stop();
    print(
      'Chunk 0 HTTP response completed: ${bytes0.length} bytes in ${sw0.elapsedMilliseconds}ms',
    );

    final trace0 = cacheManager.getTrace(999, 0);
    expect(trace0, isNotNull);
    trace0!.logSummary();

    // 1. VERIFY: Playback chunk is dispatched before background prefetch (offset 0 is first!)
    expect(mediaService.log.isNotEmpty, isTrue);
    expect(
      mediaService.log.first.offset,
      0,
      reason: 'Playback chunk 0 must be dispatched FIRST to Telegram',
    );
    expect(
      mediaService.log.first.activeAtStart,
      1,
      reason: 'Playback chunk 0 must not wait behind prefetch requests',
    );
    expect(trace0.activeTelegramRequestsAtStart, 1);
    expect(trace0.delayedBehindAnotherRequest, isFalse);

    // Wait 250ms to let initial prefetches complete
    await Future.delayed(const Duration(milliseconds: 250));

    print('\n=== SCENARIO 2: Requesting sequential chunk 1 via HTTP Range ===');
    final sw1 = Stopwatch()..start();
    final req1 = await httpClient.getUrl(Uri.parse(streamUrl));
    req1.headers.set(
      HttpHeaders.rangeHeader,
      'bytes=1048576-2097151',
    ); // Chunk 1
    final res1 = await req1.close();
    final bytes1 = await res1.fold<List<int>>([], (p, e) => p..addAll(e));
    sw1.stop();
    print(
      'Chunk 1 HTTP response completed: ${bytes1.length} bytes in ${sw1.elapsedMilliseconds}ms',
    );

    final trace1 = cacheManager.getTrace(999, 1);
    if (trace1 != null) {
      trace1.logSummary();
    }
    // 2. VERIFY: Sequential chunk hits RAM cache because it was prefetched
    expect(trace1?.cacheHitMiss, 'RAM_HIT');
    expect(
      trace1?.timeInPrefetchQueueMs,
      lessThanOrEqualTo(2),
      reason: 'Queue wait should be <= 2ms',
    );

    print('\n=== SCENARIO 3: Requesting sequential chunk 2 via HTTP Range ===');
    final sw2 = Stopwatch()..start();
    final req2 = await httpClient.getUrl(Uri.parse(streamUrl));
    req2.headers.set(
      HttpHeaders.rangeHeader,
      'bytes=2097152-3145727',
    ); // Chunk 2
    final res2 = await req2.close();
    final bytes2 = await res2.fold<List<int>>([], (p, e) => p..addAll(e));
    sw2.stop();
    print(
      'Chunk 2 HTTP response completed: ${bytes2.length} bytes in ${sw2.elapsedMilliseconds}ms',
    );

    final trace2 = cacheManager.getTrace(999, 2);
    if (trace2 != null) {
      trace2.logSummary();
    }
    expect(trace2?.cacheHitMiss, 'RAM_HIT');

    print(
      '\n=== SCENARIO 4: Requesting chunk 4 (beyond initial 3-chunk window) ===',
    );
    final sw4 = Stopwatch()..start();
    final req4 = await httpClient.getUrl(Uri.parse(streamUrl));
    req4.headers.set(
      HttpHeaders.rangeHeader,
      'bytes=4194304-5242879',
    ); // Chunk 4
    final res4 = await req4.close();
    final bytes4 = await res4.fold<List<int>>([], (p, e) => p..addAll(e));
    sw4.stop();
    print(
      'Chunk 4 HTTP response completed: ${bytes4.length} bytes in ${sw4.elapsedMilliseconds}ms',
    );

    final trace4 = cacheManager.getTrace(999, 4);
    if (trace4 != null) {
      trace4.logSummary();
    }
    expect(trace4?.cacheHitMiss, 'RAM_HIT');

    print('\n=== SCENARIO 5: Genuine large seek to Chunk 15 ===');
    const int seekOffset = 15 * 1024 * 1024;
    final reqSeek = await httpClient.getUrl(Uri.parse(streamUrl));
    reqSeek.headers.set(
      HttpHeaders.rangeHeader,
      'bytes=$seekOffset-${seekOffset + 1048575}',
    );
    final resSeek = await reqSeek.close();
    final bytesSeek = await resSeek.fold<List<int>>([], (p, e) => p..addAll(e));
    expect(bytesSeek.length, 1048576);

    final traceSeek = cacheManager.getTrace(999, 15);
    expect(traceSeek, isNotNull);
    expect(traceSeek?.isPlaybackRequest, isTrue);

    // Allow background prefetch to run for seek target
    await Future.delayed(const Duration(milliseconds: 150));

    // Verify prefetch refilled around chunk 15 (e.g. chunk 16 was prefetched)
    final trace16 = cacheManager.getTrace(999, 16);
    expect(trace16, isNotNull);

    print('\nAll Telegram requests made during test:');
    for (int i = 0; i < mediaService.log.length; i++) {
      final r = mediaService.log[i];
      print(
        '  [$i] offset=${r.offset} (chunk ${r.offset ~/ (1024 * 1024)}), activeAtStart=${r.activeAtStart}, duration=${r.elapsedMs}ms',
      );
    }

    await proxy.stop();
  });
}
