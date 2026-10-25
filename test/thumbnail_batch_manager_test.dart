import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuvex/core/database/nuvex_database.dart';
import 'package:nuvex/core/database/remote_file.dart';
import 'package:nuvex/features/home/repositories/media_repository.dart';
import 'package:nuvex/features/home/services/thumbnail_batch_manager.dart';

class FakeNuvexDatabase implements NuvexDatabase {
  final List<List<RemoteFile>> upsertedBatches = [];

  @override
  bool get isInitialized => true;

  @override
  Future<void> upsertFiles(List<RemoteFile> files) async {
    upsertedBatches.add(List.from(files));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Uint8List createValidJpegBytes({
  int width = 200,
  int height = 200,
  int totalLength = 2000,
}) {
  final header = [
    0xFF, 0xD8, // SOI
    0xFF, 0xC0, // SOF0
    0x00, 0x11, // length
    0x08, // precision
    (height >> 8) & 0xFF, height & 0xFF, // height
    (width >> 8) & 0xFF, width & 0xFF, // width
    0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
  ];
  final bytes = Uint8List(totalLength);
  for (int i = 0; i < header.length; i++) {
    bytes[i] = header[i];
  }
  return bytes;
}

class FakeMediaRepository extends MediaRepository {
  final String thumbsDir;
  final FakeNuvexDatabase fakeDb;
  int activeThumbnailRequests = 0;
  int maxObservedConcurrentRequests = 0;
  int ensureThumbnailAvailableCallCount = 0;
  final Set<int> requestedMessageIds = {};
  Duration simulatedLatency;
  bool shouldSucceed;

  FakeMediaRepository({
    required this.thumbsDir,
    required this.fakeDb,
    this.simulatedLatency = const Duration(milliseconds: 30),
    this.shouldSucceed = true,
  }) : super(database: fakeDb);

  @override
  FakeNuvexDatabase get database => fakeDb;

  @override
  Future<String> getThumbsDirectory() async => thumbsDir;

  @override
  Future<RemoteFile> ensureThumbnailAvailable(
    RemoteFile file, {
    bool saveToDatabase = true,
  }) async {
    ensureThumbnailAvailableCallCount++;
    requestedMessageIds.add(file.telegramMessageId);
    activeThumbnailRequests++;
    if (activeThumbnailRequests > maxObservedConcurrentRequests) {
      maxObservedConcurrentRequests = activeThumbnailRequests;
    }

    if (simulatedLatency > Duration.zero) {
      await Future.delayed(simulatedLatency);
    }

    activeThumbnailRequests--;

    if (!shouldSucceed) {
      throw Exception('Simulated download failure');
    }

    final thumbPath = '$thumbsDir/${file.telegramMessageId}_hq.jpg';
    final f = File(thumbPath);
    if (!f.existsSync()) {
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync(createValidJpegBytes());
    }

    return file.copyWith(thumbnailPath: thumbPath);
  }
}

RemoteFile createTestFile(int id, {String? thumbnailPath}) {
  return RemoteFile(
    id: id,
    telegramChatId: 12345,
    telegramMessageId: id,
    telegramFileId: id * 10,
    name: 'photo_$id.jpg',
    mimeType: 'image/jpeg',
    sizeBytes: 50000,
    createdAt: DateTime.now(),
    modifiedAt: DateTime.now(),
    thumbnailPath: thumbnailPath,
    category: 'photos',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String thumbsDir;
  late FakeNuvexDatabase fakeDb;
  late FakeMediaRepository fakeRepo;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('nuvex_batch_test_');
    thumbsDir = '${tempDir.path}/thumbs';
    Directory(thumbsDir).createSync(recursive: true);
    fakeDb = FakeNuvexDatabase();
    fakeRepo = FakeMediaRepository(
      thumbsDir: thumbsDir,
      fakeDb: fakeDb,
      simulatedLatency: const Duration(milliseconds: 15),
    );
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('ThumbnailBatchManager', () {
    test('1. Batch creation & bounded batch size (~24 items)', () async {
      final manager = ThumbnailBatchManager(
        repository: fakeRepo,
        batchSize: 24,
        maxConcurrent: 6,
      );

      final files = List.generate(60, (i) => createTestFile(i + 1));
      await manager.onMediaListUpdated(files);

      // Batch 0 (0-23) and Batch 1 (24-47) are scheduled; Batch 2 (48-59) is not yet scheduled
      expect(
        manager.inFlightBatches.contains(0) ||
            manager.loadedBatches.contains(0),
        isTrue,
      );
      expect(
        manager.inFlightBatches.contains(1) ||
            manager.loadedBatches.contains(1),
        isTrue,
      );
      expect(manager.inFlightBatches.contains(2), isFalse);
      expect(manager.loadedBatches.contains(2), isFalse);

      manager.dispose();
    });

    test('2. Concurrency limit is strictly enforced (max 6)', () async {
      final manager = ThumbnailBatchManager(
        repository: fakeRepo,
        batchSize: 24,
        maxConcurrent: 6,
      );

      final files = List.generate(48, (i) => createTestFile(i + 100));

      manager.requestBatch(0, files);

      // Wait for batch 0 to complete
      int waitTicks = 0;
      while (!manager.loadedBatches.contains(0) && waitTicks < 100) {
        await Future.delayed(const Duration(milliseconds: 20));
        waitTicks++;
      }

      expect(manager.loadedBatches.contains(0), isTrue);
      // Concurrency must NEVER exceed maxConcurrent (6)
      expect(fakeRepo.maxObservedConcurrentRequests, lessThanOrEqualTo(6));
      expect(fakeRepo.maxObservedConcurrentRequests, greaterThan(0));

      manager.dispose();
    });

    test(
      '3. Cache-hit skipping (instant completion without network download)',
      () async {
        final cachedFilePath = '$thumbsDir/999_hq.jpg';
        final cachedFileOnDisk = File(cachedFilePath);
        cachedFileOnDisk.writeAsBytesSync(createValidJpegBytes());

        final manager = ThumbnailBatchManager(
          repository: fakeRepo,
          batchSize: 24,
          maxConcurrent: 6,
        );

        final cachedFile = createTestFile(999, thumbnailPath: cachedFilePath);
        final files = [cachedFile];

        final notifier = manager.getNotifier(999);
        expect(notifier.value, isNull);

        manager.requestBatch(0, files);

        // Cache hit should immediately update notifier without calling ensureThumbnailAvailable
        expect(notifier.value, equals(cachedFilePath));
        expect(fakeRepo.ensureThumbnailAvailableCallCount, equals(0));
        expect(manager.loadedBatches.contains(0), isTrue);

        manager.dispose();
      },
    );

    test(
      '4. Duplicate request deduplication (never downloads same item twice)',
      () async {
        final manager = ThumbnailBatchManager(
          repository: fakeRepo,
          batchSize: 24,
          maxConcurrent: 6,
        );

        final files = List.generate(10, (i) => createTestFile(i + 200));

        // Trigger batch 0 multiple times concurrently
        manager.requestBatch(0, files);
        manager.requestBatch(0, files);
        manager.requestBatchForIndex(0, files);

        int waitTicks = 0;
        while (!manager.loadedBatches.contains(0) && waitTicks < 100) {
          await Future.delayed(const Duration(milliseconds: 20));
          waitTicks++;
        }

        expect(manager.loadedBatches.contains(0), isTrue);
        // Each file must be downloaded exactly once
        expect(fakeRepo.ensureThumbnailAvailableCallCount, equals(10));
        expect(fakeRepo.requestedMessageIds.length, equals(10));

        manager.dispose();
      },
    );

    test(
      '5. Next-batch prefetch (approaching end of batch triggers next batch)',
      () async {
        final manager = ThumbnailBatchManager(
          repository: fakeRepo,
          batchSize: 24,
          maxConcurrent: 6,
        );

        final files = List.generate(72, (i) => createTestFile(i + 300));

        // Initial state: only batch 0 requested
        manager.requestBatch(0, files);
        expect(manager.inFlightBatches.contains(0), isTrue);
        expect(manager.inFlightBatches.contains(1), isFalse);

        // User scrolls to index 14 (past midpoint of batch 0 -> triggers prefetch of batch 1)
        manager.requestBatchForIndex(14, files);
        expect(
          manager.inFlightBatches.contains(1) ||
              manager.loadedBatches.contains(1),
          isTrue,
        );
        expect(manager.inFlightBatches.contains(2), isFalse);

        // User scrolls to index 38 (past midpoint of batch 1 -> triggers prefetch of batch 2)
        manager.requestBatchForIndex(38, files);
        expect(
          manager.inFlightBatches.contains(2) ||
              manager.loadedBatches.contains(2),
          isTrue,
        );

        manager.dispose();
      },
    );

    test('6. Queue reprioritization on fast scroll', () async {
      // Use longer latency so items remain in queue
      fakeRepo.simulatedLatency = const Duration(milliseconds: 200);

      final manager = ThumbnailBatchManager(
        repository: fakeRepo,
        batchSize: 24,
        maxConcurrent: 2, // low concurrency to observe queue
      );

      final files = List.generate(96, (i) => createTestFile(i + 400));

      // Request batch 0
      manager.requestBatch(0, files);
      expect(manager.queueLength, greaterThan(0));

      // Fast scroll to batch 3 (index 72)
      manager.requestBatch(3, files);
      manager.updateViewportIndex(72, files);

      expect(manager.currentVisibleBatch, equals(3));

      manager.dispose();
    });

    test(
      '7. Granular ValueNotifier UI updates and coalesced database buffer',
      () async {
        final manager = ThumbnailBatchManager(
          repository: fakeRepo,
          batchSize: 24,
          maxConcurrent: 6,
        );

        final files = List.generate(12, (i) => createTestFile(i + 500));
        final notifiers = files
            .map((f) => manager.getNotifier(f.telegramMessageId))
            .toList();

        for (final n in notifiers) {
          expect(n.value, isNull);
        }

        manager.requestBatch(0, files);

        int waitTicks = 0;
        while (!manager.loadedBatches.contains(0) && waitTicks < 100) {
          await Future.delayed(const Duration(milliseconds: 20));
          waitTicks++;
        }

        // Each individual notifier should be updated with the thumbnail path
        for (int i = 0; i < files.length; i++) {
          expect(notifiers[i].value, isNotNull);
          expect(
            notifiers[i].value,
            contains('${files[i].telegramMessageId}_hq.jpg'),
          );
        }

        // Buffer should flush to DB upon batch completion
        await Future.delayed(const Duration(milliseconds: 50));
        expect(fakeDb.upsertedBatches.isNotEmpty, isTrue);

        manager.dispose();
      },
    );

    test(
      '8. Fast-path in-memory pre-population via onMediaListUpdated',
      () async {
        final manager = ThumbnailBatchManager(
          repository: fakeRepo,
          batchSize: 24,
          maxConcurrent: 6,
        );

        final files = [
          createTestFile(601, thumbnailPath: '$thumbsDir/601_hq.jpg'),
          createTestFile(602, thumbnailPath: '$thumbsDir/602_hq.jpg'),
          createTestFile(603, thumbnailPath: null),
        ];

        await manager.onMediaListUpdated(files);

        // Known thumbnail paths should be immediately resolved in memory
        expect(manager.getNotifier(601).value, equals('$thumbsDir/601_hq.jpg'));
        expect(manager.getNotifier(602).value, equals('$thumbsDir/602_hq.jpg'));
        // File without thumbnail starts with null
        expect(manager.getNotifier(603).value, isNull);

        manager.dispose();
      },
    );

    test(
      '9. Direction-aware prefetching on upward and downward scroll',
      () async {
        final manager = ThumbnailBatchManager(
          repository: fakeRepo,
          batchSize: 24,
          maxConcurrent: 6,
        );

        final files = List.generate(96, (i) => createTestFile(i + 700));

        // Scrolling downwards at index 14 (past midpoint of batch 0)
        manager.requestBatchForIndex(14, files, scrollDirection: 1);
        expect(
          manager.inFlightBatches.contains(1) ||
              manager.loadedBatches.contains(1),
          isTrue,
        );

        // Fast forward to batch 2 (index 50)
        manager.requestBatch(2, files);
        manager.updateViewportIndex(50, files);

        // Scrolling upwards at index 50 (indexInBatch 2, scrollDirection -1)
        manager.requestBatchForIndex(50, files, scrollDirection: -1);
        expect(
          manager.inFlightBatches.contains(1) ||
              manager.loadedBatches.contains(1),
          isTrue,
        );

        manager.dispose();
      },
    );

    test(
      '10. Cache invalidation and recovery on corrupted or missing thumbnail',
      () async {
        final manager = ThumbnailBatchManager(
          repository: fakeRepo,
          batchSize: 24,
          maxConcurrent: 6,
        );

        final cachedPath = '$thumbsDir/801_hq.jpg';
        final file = createTestFile(801, thumbnailPath: cachedPath);

        manager.requestBatch(0, [file]);
        final notifier = manager.getNotifier(801);
        expect(notifier.value, equals(cachedPath));

        // Invalidate on error detection
        manager.invalidateThumbnail(801);
        expect(notifier.value, isNull);

        manager.dispose();
      },
    );

    test(
      '11. Safe disposal cancels timers and prevents stale callbacks',
      () async {
        fakeRepo.simulatedLatency = const Duration(milliseconds: 100);
        final manager = ThumbnailBatchManager(
          repository: fakeRepo,
          batchSize: 24,
          maxConcurrent: 2,
        );

        final files = List.generate(24, (i) => createTestFile(i + 900));
        manager.requestBatch(0, files);
        expect(manager.queueLength, greaterThan(0));

        // Dispose while requests are actively in-flight
        manager.dispose();

        // State is cleanly cleared
        expect(manager.queueLength, equals(0));
        // Waiting for asynchronous latency does not throw or corrupt state
        await Future.delayed(const Duration(milliseconds: 150));
      },
    );
  });
}
