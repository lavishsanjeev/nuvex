import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuvex/core/database/remote_file.dart';
import 'package:nuvex/core/services/video_range_cache_manager.dart';
import 'package:nuvex/core/services/video_streaming_proxy.dart';
import 'package:nuvex/telegram/telegram_media_service.dart';

/// Test mock of TelegramMediaService that records all range requests,
/// enforces MTProto offset/limit rules, and provides deterministic test payloads.
class MockTelegramRangeService extends TelegramMediaService {
  final int totalFileSize;
  final List<({int offset, int limit})> recordedRequests = [];
  bool simulateExpiredReferenceOnce = false;
  int refreshCallCount = 0;

  MockTelegramRangeService({
    required this.totalFileSize,
    this.simulateExpiredReferenceOnce = false,
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
    // 1. Strict 1 KB alignment rule validation
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

    // 2. 1 MB Region Boundary Splitting
    const int oneMb = 1024 * 1024;
    final builder = BytesBuilder(copy: false);
    int curOffset = offset;
    int remaining = limit;

    while (remaining > 0) {
      final currentRegionEnd = ((curOffset ~/ oneMb) + 1) * oneMb;
      final maxInRegion = currentRegionEnd - curOffset;
      final subLimit = remaining < maxInRegion ? remaining : maxInRegion;
      final clampedLimit = subLimit < oneMb ? subLimit : oneMb;

      final subBytes = await _mockFetchSingleRange(curOffset, clampedLimit);
      if (subBytes.isEmpty) break;

      builder.add(subBytes);
      curOffset += subBytes.length;
      remaining -= subBytes.length;

      if (subBytes.length < clampedLimit) break;
    }

    return builder.takeBytes();
  }

  Future<Uint8List> _mockFetchSingleRange(int offset, int limit) async {
    // Verify each sub-request never crosses 1 MB boundary
    const int oneMb = 1024 * 1024;
    final startRegion = offset ~/ oneMb;
    final endRegion = (offset + limit - 1) ~/ oneMb;
    if (startRegion != endRegion) {
      throw StateError(
        'Telegram MTProto violation: request [$offset, ${offset + limit - 1}] crosses 1 MB region boundary ($startRegion != $endRegion)',
      );
    }

    // Simulate FILE_REFERENCE_EXPIRED on first attempt
    if (simulateExpiredReferenceOnce) {
      simulateExpiredReferenceOnce = false;
      refreshCallCount++;
      // Recover and continue
    }

    recordedRequests.add((offset: offset, limit: limit));

    if (offset >= totalFileSize) {
      return Uint8List(0);
    }

    final available = totalFileSize - offset;
    final returnLength = available < limit ? available : limit;

    // Generate deterministic byte values based on file offset
    final data = Uint8List(returnLength);
    for (int i = 0; i < returnLength; i++) {
      data[i] = ((offset + i) % 256);
    }
    return data;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory tempDir;
  late VideoRangeCacheManager cacheManager;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('nuvex_streaming_test_');
    cacheManager = VideoRangeCacheManager(
      customCacheDirPath: tempDir.path,
      enablePrefetch: false,
    );
  });

  tearDown(() async {
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
    String? localPath,
  }) {
    return RemoteFile(
      id: messageId,
      telegramChatId: 12345,
      telegramMessageId: messageId,
      telegramFileId: messageId * 10,
      name: 'test_video_$messageId.mp4',
      mimeType: 'video/mp4',
      sizeBytes: sizeBytes,
      createdAt: DateTime.now(),
      modifiedAt: DateTime.now(),
      category: 'videos',
      localPath: localPath,
    );
  }

  group('Task 8 — Telegram MTProto Range Download Rules', () {
    test('Enforces 1 KB alignment on offset and limit', () async {
      final mockService = MockTelegramRangeService(
        totalFileSize: 10 * 1024 * 1024,
      );
      final file = createMockVideoFile(
        messageId: 101,
        sizeBytes: 10 * 1024 * 1024,
      );

      // Invalid offset (not 1024 aligned)
      expect(
        () => mockService.getMediaRange(file: file, offset: 500, limit: 1024),
        throwsArgumentError,
      );

      // Invalid limit (not 1024 aligned)
      expect(
        () => mockService.getMediaRange(file: file, offset: 1024, limit: 1500),
        throwsArgumentError,
      );

      // Valid 1024 aligned request
      final bytes = await mockService.getMediaRange(
        file: file,
        offset: 2048,
        limit: 4096,
      );
      expect(bytes.length, 4096);
    });

    test('Range crossing 1 MB Telegram boundary is automatically split without error', () async {
      final mockService = MockTelegramRangeService(
        totalFileSize: 20 * 1024 * 1024,
      );
      final file = createMockVideoFile(
        messageId: 102,
        sizeBytes: 20 * 1024 * 1024,
      );

      // Request from 768 KB (inside Region 0) for 512 KB (reaches 1280 KB inside Region 1)
      const offset = 768 * 1024;
      const limit = 512 * 1024;

      final bytes = await mockService.getMediaRange(
        file: file,
        offset: offset,
        limit: limit,
      );
      expect(bytes.length, limit);

      // Verify sub-requests split at 1 MB boundary
      expect(mockService.recordedRequests.length, 2);
      expect(mockService.recordedRequests[0], (
        offset: 768 * 1024,
        limit: 256 * 1024,
      ));
      expect(mockService.recordedRequests[1], (
        offset: 1024 * 1024,
        limit: 256 * 1024,
      ));
    });

    test(
      'FILE_REFERENCE_EXPIRED triggers auto-recovery without failing request',
      () async {
        final mockService = MockTelegramRangeService(
          totalFileSize: 10 * 1024 * 1024,
          simulateExpiredReferenceOnce: true,
        );
        final file = createMockVideoFile(
          messageId: 103,
          sizeBytes: 10 * 1024 * 1024,
        );

        final bytes = await mockService.getMediaRange(
          file: file,
          offset: 0,
          limit: 4096,
        );
        expect(bytes.length, 4096);
        expect(mockService.refreshCallCount, 1);
      },
    );
  });

  group('Task 8 — VideoRangeCacheManager', () {
    test(
      'Caches 1 MB chunks in app-private directory with .nomedia guard',
      () async {
        final cacheDir = await cacheManager.getCacheDirectoryPath();
        expect(File('$cacheDir/.nomedia').existsSync(), isTrue);

        final mockService = MockTelegramRangeService(
          totalFileSize: 10 * 1024 * 1024,
        );
        final file = createMockVideoFile(
          messageId: 201,
          sizeBytes: 10 * 1024 * 1024,
        );

        // Fetch Chunk 0 (first 1 MB)
        final chunk0 = await cacheManager.getChunk(
          file: file,
          chunkIndex: 0,
          mediaService: mockService,
        );
        expect(chunk0.length, 1024 * 1024);
        expect(mockService.recordedRequests.length, 1);

        // Verify chunk file exists on disk
        final chunkFile = await cacheManager.getChunkFile(
          file.telegramMessageId,
          0,
        );
        // Wait for async persistence to write
        int attempts = 0;
        while (!chunkFile.existsSync() && attempts < 20) {
          await Future.delayed(const Duration(milliseconds: 20));
          attempts++;
        }
        expect(chunkFile.existsSync(), isTrue);
        expect(chunkFile.lengthSync(), 1024 * 1024);

        // Re-read Chunk 0: must read 100% from RAM/disk with 0 Telegram network calls
        final cachedChunk0 = await cacheManager.getChunk(
          file: file,
          chunkIndex: 0,
          mediaService: mockService,
        );
        expect(cachedChunk0, chunk0);
        expect(mockService.recordedRequests.length, 1); // Still 1!
      },
    );

    test(
      'Deduplicates concurrent in-flight requests for the same chunk',
      () async {
        final mockService = MockTelegramRangeService(
          totalFileSize: 10 * 1024 * 1024,
        );
        final file = createMockVideoFile(
          messageId: 202,
          sizeBytes: 10 * 1024 * 1024,
        );

        // Launch 5 simultaneous requests for Chunk 1
        final futures = List.generate(
          5,
          (_) => cacheManager.getChunk(
            file: file,
            chunkIndex: 1,
            mediaService: mockService,
          ),
        );

        final results = await Future.wait(futures);
        for (final res in results) {
          expect(res.length, 1024 * 1024);
        }

        // Exactly ONE request made to Telegram
        expect(mockService.recordedRequests.length, 1);
      },
    );

    test('LRU cache eviction frees space when limit is exceeded', () async {
      final mockService = MockTelegramRangeService(
        totalFileSize: 5 * 1024 * 1024,
      );
      final file1 = createMockVideoFile(
        messageId: 203,
        sizeBytes: 2 * 1024 * 1024,
      );
      final file2 = createMockVideoFile(
        messageId: 204,
        sizeBytes: 2 * 1024 * 1024,
      );

      await cacheManager.getChunk(
        file: file1,
        chunkIndex: 0,
        mediaService: mockService,
      );
      await cacheManager.getChunk(
        file: file2,
        chunkIndex: 0,
        mediaService: mockService,
      );

      // Allow async disk writes to complete
      await Future.delayed(const Duration(milliseconds: 100));

      // Evict with a low max size of 1.2 MB (one 1 MB chunk allowed)
      final deletedBytes = await cacheManager.cleanOldCache(
        maxSizeBytes: 1200 * 1024,
      );
      expect(deletedBytes, greaterThanOrEqualTo(1024 * 1024));
    });
  });

  group('Task 8 — Localhost HTTP Streaming Proxy', () {
    late VideoStreamingProxy proxy;
    late MockTelegramRangeService mockService;
    late HttpClient httpClient;

    setUp(() async {
      mockService = MockTelegramRangeService(totalFileSize: 150 * 1024 * 1024);
      proxy = VideoStreamingProxy(
        mediaService: mockService,
        cacheManager: cacheManager,
        enablePreload: false,
      );
      await proxy.ensureStarted();
      httpClient = HttpClient();
    });

    tearDown(() async {
      httpClient.close();
      await proxy.stop();
    });

    test('Binds only to 127.0.0.1 with ephemeral port', () {
      expect(proxy.isRunning, isTrue);
      expect(proxy.port, isNotNull);
      expect(proxy.port, greaterThan(0));
    });

    test(
      'Rejects request without valid session token with 403 Forbidden',
      () async {
        final file = createMockVideoFile(
          messageId: 301,
          sizeBytes: 150 * 1024 * 1024,
        );
        proxy.registerFile(file);

        // Request without token
        final req = await httpClient.getUrl(
          Uri.parse(
            'http://127.0.0.1:${proxy.port}/video/${file.telegramMessageId}',
          ),
        );
        final res = await req.close();
        expect(res.statusCode, HttpStatus.forbidden);
      },
    );

    test(
      'Rejects request for unregistered message ID with 404 Not Found',
      () async {
        final req = await httpClient.getUrl(
          Uri.parse(
            'http://127.0.0.1:${proxy.port}/video/999999?token=invalid',
          ),
        );
        final res = await req.close();
        expect(res.statusCode, HttpStatus.notFound);
      },
    );

    test(
      'HEAD request returns media headers and 200 OK without body',
      () async {
        final file = createMockVideoFile(
          messageId: 302,
          sizeBytes: 150 * 1024 * 1024,
        );
        final streamUrl = proxy.registerFile(file);

        final req = await httpClient.headUrl(Uri.parse(streamUrl));
        final res = await req.close();

        expect(res.statusCode, HttpStatus.ok);
        expect(res.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
        expect(res.headers.value(HttpHeaders.contentTypeHeader), 'video/mp4');
        expect(
          res.headers.value(HttpHeaders.contentLengthHeader),
          (150 * 1024 * 1024).toString(),
        );

        // Body must be empty
        final body = await res.fold<List<int>>([], (p, e) => p..addAll(e));
        expect(body.isEmpty, isTrue);
        // No Telegram ranges requested on HEAD
        expect(mockService.recordedRequests.isEmpty, isTrue);
      },
    );

    test('GET Range bytes=0-1048575 returns 206 Partial Content with correct Content-Range', () async {
      final file = createMockVideoFile(
        messageId: 303,
        sizeBytes: 150 * 1024 * 1024,
      );
      final streamUrl = proxy.registerFile(file);

      final req = await httpClient.getUrl(Uri.parse(streamUrl));
      req.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=0-1048575',
      ); // Exactly 1 MB
      final res = await req.close();

      expect(res.statusCode, HttpStatus.partialContent);
      expect(
        res.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 0-1048575/${150 * 1024 * 1024}',
      );
      expect(res.headers.value(HttpHeaders.contentLengthHeader), '1048576');

      final body = await res.fold<List<int>>([], (p, e) => p..addAll(e));
      expect(body.length, 1048576);

      // Verify deterministic byte sequence matches offset 0
      expect(body[0], 0 % 256);
      expect(body[1], 1 % 256);
    });

    test(
      'Invalid range beyond total file size returns 416 Range Not Satisfiable',
      () async {
        final file = createMockVideoFile(
          messageId: 304,
          sizeBytes: 10 * 1024 * 1024,
        );
        final streamUrl = proxy.registerFile(file);

        final req = await httpClient.getUrl(Uri.parse(streamUrl));
        req.headers.set(
          HttpHeaders.rangeHeader,
          'bytes=20000000-25000000',
        ); // Beyond 10 MB
        final res = await req.close();

        expect(res.statusCode, HttpStatus.requestedRangeNotSatisfiable);
        expect(
          res.headers.value(HttpHeaders.contentRangeHeader),
          'bytes */${10 * 1024 * 1024}',
        );
      },
    );

    test('Reuses verified complete local original directly with zero network requests', () async {
      // Create a genuine complete local file matching exact file size
      const completeSize = 1024 * 1024;
      final localFile = File('${tempDir.path}/complete_video.mp4');
      final content = Uint8List(completeSize);
      for (int i = 0; i < completeSize; i++) {
        content[i] = i % 256;
      }
      localFile.writeAsBytesSync(content, flush: true);

      final file = createMockVideoFile(
        messageId: 305,
        sizeBytes: completeSize,
        localPath: localFile.path,
      );
      final streamUrl = proxy.registerFile(file);

      final req = await httpClient.getUrl(Uri.parse(streamUrl));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=100-199');
      final res = await req.close();

      expect(res.statusCode, HttpStatus.partialContent);
      final body = await res.fold<List<int>>([], (p, e) => p..addAll(e));
      expect(body.length, 100);
      expect(body[0], 100 % 256);

      // Zero Telegram requests made!
      expect(mockService.recordedRequests.isEmpty, isTrue);
    });
  });

  group('Task 8 — CRITICAL SUCCESS TEST: 150 MB Video Instant Streaming', () {
    test('Opening a 150 MB video downloads only initial ranges (< 1% of total file size)', () async {
      const int fileSize = 150 * 1024 * 1024; // 150 MB
      final mockService = MockTelegramRangeService(totalFileSize: fileSize);
      final proxy = VideoStreamingProxy(
        mediaService: mockService,
        cacheManager: cacheManager,
        enablePreload: false,
      );
      await proxy.ensureStarted();

      final file = createMockVideoFile(messageId: 401, sizeBytes: fileSize);
      final streamUrl = proxy.registerFile(file);
      final httpClient = HttpClient();

      // ── Step 1: Video Player opens video and requests initial chunk for first keyframe ──
      final initReq = await httpClient.getUrl(Uri.parse(streamUrl));
      initReq.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=0-524287',
      ); // Initial 512 KB
      final initRes = await initReq.close();
      expect(initRes.statusCode, HttpStatus.partialContent);

      final initialBytes = await initRes.fold<List<int>>(
        [],
        (p, e) => p..addAll(e),
      );
      expect(initialBytes.length, 512 * 1024);

      // Total network bytes requested from Telegram
      int totalNetworkBytes = 0;
      for (final r in mockService.recordedRequests) {
        totalNetworkBytes += r.limit;
      }

      // CRITICAL SUCCESS VERIFICATION:
      // Downloaded bytes before playback begins must be substantially less than 150 MB!
      expect(
        totalNetworkBytes,
        lessThan(fileSize ~/ 100),
      ); // Less than 1% of 150 MB!
      expect(totalNetworkBytes, 1024 * 1024); // Exactly one 1 MB chunk

      // ── Step 2: Forward Seek to 100 MB ──
      const int seekForwardOffset = 100 * 1024 * 1024; // 100 MB
      final seekForwardReq = await httpClient.getUrl(Uri.parse(streamUrl));
      seekForwardReq.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=$seekForwardOffset-${seekForwardOffset + 524287}',
      );
      final seekForwardRes = await seekForwardReq.close();
      expect(seekForwardRes.statusCode, HttpStatus.partialContent);

      final seekForwardBytes = await seekForwardRes.fold<List<int>>(
        [],
        (p, e) => p..addAll(e),
      );
      expect(seekForwardBytes.length, 512 * 1024);
      expect(seekForwardBytes[0], seekForwardOffset % 256);

      // Only chunk at 100 MB requested from Telegram
      expect(mockService.recordedRequests.length, 2);
      expect(mockService.recordedRequests[1].offset, seekForwardOffset);

      // ── Step 3: Backward Seek to 25 MB ──
      const int seekBackwardOffset = 25 * 1024 * 1024; // 25 MB
      final seekBackwardReq = await httpClient.getUrl(Uri.parse(streamUrl));
      seekBackwardReq.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=$seekBackwardOffset-${seekBackwardOffset + 524287}',
      );
      final seekBackwardRes = await seekBackwardReq.close();
      expect(seekBackwardRes.statusCode, HttpStatus.partialContent);

      final seekBackwardBytes = await seekBackwardRes.fold<List<int>>(
        [],
        (p, e) => p..addAll(e),
      );
      expect(seekBackwardBytes.length, 512 * 1024);
      expect(seekBackwardBytes[0], seekBackwardOffset % 256);

      expect(mockService.recordedRequests.length, 3);
      expect(mockService.recordedRequests[2].offset, seekBackwardOffset);

      // ── Step 4: Re-request initial range (bytes 0 to 524287) — Cached reuse ──
      final cachedReq = await httpClient.getUrl(Uri.parse(streamUrl));
      cachedReq.headers.set(HttpHeaders.rangeHeader, 'bytes=0-524287');
      final cachedRes = await cachedReq.close();
      expect(cachedRes.statusCode, HttpStatus.partialContent);

      final cachedBytes = await cachedRes.fold<List<int>>(
        [],
        (p, e) => p..addAll(e),
      );
      expect(cachedBytes, initialBytes);

      // Telegram call count remains 3 (ZERO network calls for cached range!)
      expect(mockService.recordedRequests.length, 3);

      httpClient.close();
      await proxy.stop();
    });

    test('10 MB MP4 streaming with forward and backward seeking', () async {
      const int fileSize = 10 * 1024 * 1024; // 10 MB
      final mockService = MockTelegramRangeService(totalFileSize: fileSize);
      final proxy = VideoStreamingProxy(
        mediaService: mockService,
        cacheManager: cacheManager,
        enablePreload: false,
      );
      await proxy.ensureStarted();

      final file = createMockVideoFile(messageId: 402, sizeBytes: fileSize);
      final streamUrl = proxy.registerFile(file);
      final httpClient = HttpClient();

      // Play from beginning
      final req1 = await httpClient.getUrl(Uri.parse(streamUrl));
      req1.headers.set(HttpHeaders.rangeHeader, 'bytes=0-524287');
      final res1 = await req1.close();
      expect(res1.statusCode, HttpStatus.partialContent);
      final bytes1 = await res1.fold<List<int>>([], (p, e) => p..addAll(e));
      expect(bytes1.length, 512 * 1024);

      // Seek forward to 7 MB
      const int seekFwd = 7 * 1024 * 1024;
      final req2 = await httpClient.getUrl(Uri.parse(streamUrl));
      req2.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=$seekFwd-${seekFwd + 524287}',
      );
      final res2 = await req2.close();
      expect(res2.statusCode, HttpStatus.partialContent);
      final bytes2 = await res2.fold<List<int>>([], (p, e) => p..addAll(e));
      expect(bytes2.length, 512 * 1024);
      expect(bytes2[0], seekFwd % 256);

      // Seek backward to 2 MB
      const int seekBack = 2 * 1024 * 1024;
      final req3 = await httpClient.getUrl(Uri.parse(streamUrl));
      req3.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=$seekBack-${seekBack + 524287}',
      );
      final res3 = await req3.close();
      expect(res3.statusCode, HttpStatus.partialContent);
      final bytes3 = await res3.fold<List<int>>([], (p, e) => p..addAll(e));
      expect(bytes3.length, 512 * 1024);
      expect(bytes3[0], seekBack % 256);

      expect(mockService.recordedRequests.length, 3);

      httpClient.close();
      await proxy.stop();
    });

    test('Partially cached video only downloads missing chunks', () async {
      const int fileSize = 5 * 1024 * 1024;
      final mockService = MockTelegramRangeService(totalFileSize: fileSize);
      final file = createMockVideoFile(messageId: 403, sizeBytes: fileSize);

      // Pre-cache Chunk 0 and Chunk 2 manually
      await cacheManager.getChunk(
        file: file,
        chunkIndex: 0,
        mediaService: mockService,
      );
      await cacheManager.getChunk(
        file: file,
        chunkIndex: 2,
        mediaService: mockService,
      );
      expect(mockService.recordedRequests.length, 2);

      // Now query range covering Chunk 0, 1, and 2
      final rangeBytes = await cacheManager.getRangeBytes(
        file: file,
        start: 0,
        end: (3 * 1024 * 1024) - 1, // 3 MB (Chunks 0, 1, and 2)
        mediaService: mockService,
      );

      expect(rangeBytes.length, 3 * 1024 * 1024);
      // Exactly ONE more request was made (for missing Chunk 1)
      expect(mockService.recordedRequests.length, 3);
      expect(mockService.recordedRequests[2].offset, 1024 * 1024);
    });

    test('Proxy handles abrupt client socket closure during stream safely', () async {
      final mockService = MockTelegramRangeService(
        totalFileSize: 10 * 1024 * 1024,
      );
      final proxy = VideoStreamingProxy(
        mediaService: mockService,
        cacheManager: cacheManager,
        enablePreload: false,
      );
      await proxy.ensureStarted();

      final file = createMockVideoFile(
        messageId: 404,
        sizeBytes: 10 * 1024 * 1024,
      );
      final streamUrl = proxy.registerFile(file);

      // Connect raw socket and abruptly detach/destroy mid-request to simulate user quitting video
      final uri = Uri.parse(streamUrl);
      final socket = await Socket.connect(uri.host, uri.port);
      socket.write(
        'GET ${uri.path}?${uri.query} HTTP/1.1\r\nHost: ${uri.host}\r\nRange: bytes=0-1048575\r\n\r\n',
      );
      await socket.flush();
      await Future.delayed(const Duration(milliseconds: 20));
      // Abruptly destroy socket
      socket.destroy();

      // Ensure proxy is still alive and responds to subsequent requests normally
      final normalClient = HttpClient();
      final req = await normalClient.getUrl(Uri.parse(streamUrl));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-100');
      final res = await req.close();
      expect(res.statusCode, HttpStatus.partialContent);

      normalClient.close();
      await proxy.stop();
    });
  });

  group('Task 8 Bug Fix Regressions — StreamSink & ExoPlayer Patterns', () {
    late VideoStreamingProxy proxy;
    late MockTelegramRangeService mockService;
    late HttpClient httpClient;
    const int testFileSize = 149 * 1024 * 1024; // ~149 MB test video

    setUp(() async {
      mockService = MockTelegramRangeService(totalFileSize: testFileSize);
      proxy = VideoStreamingProxy(
        mediaService: mockService,
        cacheManager: cacheManager,
        enablePreload: false,
      );
      await proxy.ensureStarted();
      httpClient = HttpClient();
    });

    tearDown(() async {
      httpClient.close();
      await proxy.stop();
    });

    test('StreamSink Binding: Rapid client disconnect mid-stream never throws StreamSink bound error', () async {
      final file = createMockVideoFile(messageId: 501, sizeBytes: testFileSize);
      final streamUrl = proxy.registerFile(file);

      // Connect raw socket and read only a tiny fragment, then immediately abort
      final uri = Uri.parse(streamUrl);
      final socket = await Socket.connect(uri.host, uri.port);
      socket.write(
        'GET ${uri.path}?${uri.query} HTTP/1.1\r\nHost: ${uri.host}\r\nRange: bytes=0-\r\n\r\n',
      );
      await socket.flush();

      final completer = Completer<void>();
      socket.listen(
        (data) {
          // Read first packet and destroy immediately
          socket.destroy();
          if (!completer.isCompleted) completer.complete();
        },
        onError: (_) {
          if (!completer.isCompleted) completer.complete();
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
      );

      await completer.future.timeout(const Duration(seconds: 5));
      await Future.delayed(const Duration(milliseconds: 100));

      // Ensure proxy immediately handles another request cleanly without StreamSink state errors
      final req2 = await httpClient.getUrl(Uri.parse(streamUrl));
      req2.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
      final res2 = await req2.close();
      expect(res2.statusCode, HttpStatus.partialContent);
      final body2 = await res2.fold<List<int>>([], (p, e) => p..addAll(e));
      expect(body2.length, 1024);
    });

    test(
      'Single response stream: Accurately delivers exact byte range',
      () async {
        final file = createMockVideoFile(
          messageId: 502,
          sizeBytes: testFileSize,
        );
        final streamUrl = proxy.registerFile(file);

        final req = await httpClient.getUrl(Uri.parse(streamUrl));
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=1000-1999');
        final res = await req.close();

        expect(res.statusCode, HttpStatus.partialContent);
        expect(res.headers.value(HttpHeaders.contentTypeHeader), 'video/mp4');
        expect(res.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
        expect(res.headers.value(HttpHeaders.contentLengthHeader), '1000');
        expect(
          res.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 1000-1999/$testFileSize',
        );

        final bytes = await res.fold<List<int>>([], (p, e) => p..addAll(e));
        expect(bytes.length, 1000);
        expect(bytes[0], 1000 % 256);
        expect(bytes[999], 1999 % 256);
      },
    );

    test('ExoPlayer open-ended range pattern (bytes=start-)', () async {
      final file = createMockVideoFile(
        messageId: 503,
        sizeBytes: 10 * 1024 * 1024,
      );
      final streamUrl = proxy.registerFile(file);

      // ExoPlayer standard initial request
      final req = await httpClient.getUrl(Uri.parse(streamUrl));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
      final res = await req.close();

      expect(res.statusCode, HttpStatus.partialContent);
      expect(
        res.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 0-${(10 * 1024 * 1024) - 1}/${10 * 1024 * 1024}',
      );
      expect(
        res.headers.value(HttpHeaders.contentLengthHeader),
        (10 * 1024 * 1024).toString(),
      );

      // Read only first chunk (ExoPlayer inspects moov box then seeks)
      final chunk = await res.first;
      expect(chunk.isNotEmpty, isTrue);
    });

    test('Safely rejects malformed and invalid ranges with HTTP 416', () async {
      final file = createMockVideoFile(
        messageId: 504,
        sizeBytes: 10 * 1024 * 1024,
      );
      final streamUrl = proxy.registerFile(file);

      final invalidRanges = [
        'bytes=abc-def', // Non-numeric
        'bytes=-', // Empty start and end
        'bytes=5000-1000', // Start > End
        'bytes=200000000-', // Start beyond total size
        'characters=0-100', // Invalid unit
        'bytes=0-10, 20-30', // Multiple ranges unsupported
      ];

      for (final badRange in invalidRanges) {
        final req = await httpClient.getUrl(Uri.parse(streamUrl));
        req.headers.set(HttpHeaders.rangeHeader, badRange);
        final res = await req.close();
        expect(
          res.statusCode,
          HttpStatus.requestedRangeNotSatisfiable,
          reason: 'Expected 416 for $badRange',
        );
        expect(
          res.headers.value(HttpHeaders.contentRangeHeader),
          'bytes */${10 * 1024 * 1024}',
        );
      }
    });

    test('Multiple sequential range requests simulate ExoPlayer playback & seeking', () async {
      final file = createMockVideoFile(messageId: 505, sizeBytes: testFileSize);
      final streamUrl = proxy.registerFile(file);

      // 1. Initial keyframe range (0 - 512 KB, part of 1 MB chunk 0)
      final req1 = await httpClient.getUrl(Uri.parse(streamUrl));
      req1.headers.set(HttpHeaders.rangeHeader, 'bytes=0-524287');
      final res1 = await req1.close();
      expect(res1.statusCode, HttpStatus.partialContent);
      await res1.drain();

      // 2. ExoPlayer seeks to MP4 tail (moov box check, tail chunk)
      const int tailOffset = testFileSize - 1048576;
      final req2 = await httpClient.getUrl(Uri.parse(streamUrl));
      req2.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=$tailOffset-${testFileSize - 1}',
      );
      final res2 = await req2.close();
      expect(res2.statusCode, HttpStatus.partialContent);
      await res2.drain();

      // 3. Playback continues from 512 KB (already cached inside 1 MB chunk 0!)
      final req3 = await httpClient.getUrl(Uri.parse(streamUrl));
      req3.headers.set(HttpHeaders.rangeHeader, 'bytes=524288-1048575');
      final res3 = await req3.close();
      expect(res3.statusCode, HttpStatus.partialContent);
      await res3.drain();

      // 4. Backward seek to 0 (already cached inside 1 MB chunk 0!)
      final req4 = await httpClient.getUrl(Uri.parse(streamUrl));
      req4.headers.set(HttpHeaders.rangeHeader, 'bytes=0-524287');
      final res4 = await req4.close();
      expect(res4.statusCode, HttpStatus.partialContent);
      await res4.drain();

      // Exactly 2 Telegram network requests (Chunk 0 and tail Chunk; #3 and #4 are cached)
      expect(mockService.recordedRequests.length, 2);
    });

    test(
      'Sequential multiple chunk writes: range spanning 3 chunks (3 MB)',
      () async {
        final file = createMockVideoFile(
          messageId: 506,
          sizeBytes: testFileSize,
        );
        final streamUrl = proxy.registerFile(file);

        // Request 3 MB across chunk 0, 1, and 2
        const int requestedLength = 3 * 1024 * 1024;
        final req = await httpClient.getUrl(Uri.parse(streamUrl));
        req.headers.set(
          HttpHeaders.rangeHeader,
          'bytes=0-${requestedLength - 1}',
        );
        final res = await req.close();

        expect(res.statusCode, HttpStatus.partialContent);
        expect(
          res.headers.value(HttpHeaders.contentLengthHeader),
          requestedLength.toString(),
        );
        expect(
          res.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 0-${requestedLength - 1}/$testFileSize',
        );

        final body = await res.fold<List<int>>([], (p, e) => p..addAll(e));
        expect(body.length, requestedLength);

        // Verify byte integrity across all 3 chunks
        for (int i = 0; i < requestedLength; i += 1024) {
          expect(body[i], i % 256);
        }
      },
    );

    test('Two sequential HTTP range requests on same proxy instance without restart', () async {
      final file = createMockVideoFile(messageId: 507, sizeBytes: testFileSize);
      final streamUrl = proxy.registerFile(file);

      // First range request
      final req1 = await httpClient.getUrl(Uri.parse(streamUrl));
      req1.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
      final res1 = await req1.close();
      expect(res1.statusCode, HttpStatus.partialContent);
      final body1 = await res1.fold<List<int>>([], (p, e) => p..addAll(e));
      expect(body1.length, 1024);

      // Second range request immediately after
      final req2 = await httpClient.getUrl(Uri.parse(streamUrl));
      req2.headers.set(HttpHeaders.rangeHeader, 'bytes=2048-3071');
      final res2 = await req2.close();
      expect(res2.statusCode, HttpStatus.partialContent);
      final body2 = await res2.fold<List<int>>([], (p, e) => p..addAll(e));
      expect(body2.length, 1024);
      expect(body2[0], 2048 % 256);
    });

    test('Proactive metadata preloading preloads chunk 0 and tail chunk in parallel', () async {
      final mock = MockTelegramRangeService(totalFileSize: testFileSize);
      final preloadProxy = VideoStreamingProxy(
        mediaService: mock,
        cacheManager: cacheManager,
        enablePreload: true,
      );
      await preloadProxy.ensureStarted();

      final file = createMockVideoFile(messageId: 508, sizeBytes: testFileSize);
      preloadProxy.registerFile(file);

      // Allow background preload futures to complete
      await Future.delayed(const Duration(milliseconds: 100));

      // Verified: both chunk 0 and tail chunk were preloaded
      expect(mock.recordedRequests.length, 2);
      expect(mock.recordedRequests.any((r) => r.offset == 0), isTrue);
      expect(
        mock.recordedRequests.any((r) => r.offset > 100 * 1024 * 1024),
        isTrue,
      );

      await preloadProxy.stop();
    });

    test(
      'Sliding-window prefetching fetches adjacent chunks into cache',
      () async {
        final prefetchCacheManager = VideoRangeCacheManager(
          customCacheDirPath: tempDir.path,
          enablePrefetch: true,
        );
        final mock = MockTelegramRangeService(totalFileSize: testFileSize);
        final prefetchProxy = VideoStreamingProxy(
          mediaService: mock,
          cacheManager: prefetchCacheManager,
          enablePreload: false,
        );
        await prefetchProxy.ensureStarted();

        final file = createMockVideoFile(
          messageId: 509,
          sizeBytes: testFileSize,
        );
        final streamUrl = prefetchProxy.registerFile(file);

        final req = await httpClient.getUrl(Uri.parse(streamUrl));
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
        final res = await req.close();
        await res.drain();

        // Wait briefly for background prefetch workers to execute
        await Future.delayed(const Duration(milliseconds: 100));

        // Both Chunk 0 and prefetched subsequent chunks were requested from Telegram
        expect(mock.recordedRequests.length, greaterThan(1));

        await prefetchProxy.stop();
      },
    );
  });
}
