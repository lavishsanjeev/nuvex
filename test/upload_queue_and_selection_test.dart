import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuvex/core/database/nuvex_database.dart';
import 'package:nuvex/core/database/remote_file.dart';
import 'package:nuvex/core/database/upload_queue_item.dart';
import 'package:nuvex/core/services/native_media_service.dart';
import 'package:nuvex/core/utils/file_hash.dart';
import 'package:nuvex/features/home/controllers/media_controller.dart';
import 'package:nuvex/features/home/controllers/upload_controller.dart';
import 'package:nuvex/features/home/photos_screen.dart';
import 'package:nuvex/features/home/repositories/media_repository.dart';
import 'package:nuvex/features/home/widgets/selection_action_bar.dart';
import 'package:nuvex/telegram/telegram_auth_service.dart';
import 'package:nuvex/telegram/telegram_media_service.dart';
import 'package:nuvex/telegram/telegram_models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late Database testDb;
  late NuvexDatabase database;
  late FakeUploadService fakeMediaService;
  late MediaRepository repository;
  late MediaController mediaController;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('nuvex_feature_test_');
    database = NuvexDatabase();
    testDb = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await database.initialize(overrideDb: testDb);

    fakeMediaService = FakeUploadService();
    repository = MediaRepository(
      database: database,
      mediaService: fakeMediaService,
    );
    mediaController = MediaController(repository: repository);
  });

  tearDown(() async {
    NativeMediaService.shareFileMock = null;
    NativeMediaService.shareFilesMock = null;
    mediaController.dispose();
    await database.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Feature 1: Multi-Select + Bulk Actions', () {
    Future<void> settleUi(WidgetTester tester, [int delayMs = 50]) async {
      await tester.pump();
      await Future.delayed(Duration(milliseconds: delayMs));
      await tester.pump();
    }

    testWidgets(
      'Long-press media tile enters selection mode and shows action bar',
      (tester) async {
        await tester.runAsync(() async {
          final file1 = RemoteFile(
            id: 101,
            telegramChatId: 0,
            telegramMessageId: 101,
            telegramFileId: 1001,
            name: 'photo_101.jpg',
            mimeType: 'image/jpeg',
            sizeBytes: 2048,
            createdAt: DateTime.now(),
            modifiedAt: DateTime.now(),
            category: 'photos',
          );
          final file2 = RemoteFile(
            id: 102,
            telegramChatId: 0,
            telegramMessageId: 102,
            telegramFileId: 1002,
            name: 'photo_102.jpg',
            mimeType: 'image/jpeg',
            sizeBytes: 4096,
            createdAt: DateTime.now(),
            modifiedAt: DateTime.now(),
            category: 'photos',
          );
          await database.upsertFiles([file1, file2]);
          await mediaController.initializeAndSync();

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: PhotosScreen(mediaController: mediaController),
              ),
            ),
          );
          await settleUi(tester);

          expect(mediaController.isSelectionMode, isFalse);
          expect(find.byType(SelectionActionBar), findsNothing);

          // Long-press tile 101 to enter selection mode
          final gesture = await tester.startGesture(
            tester.getCenter(find.byKey(const ValueKey(101))),
          );
          await Future.delayed(const Duration(milliseconds: 650));
          await gesture.up();
          await settleUi(tester);

          expect(mediaController.isSelectionMode, isTrue);
          expect(mediaController.selectedCount, equals(1));
          expect(mediaController.isFileSelected(101), isTrue);
          expect(find.byType(SelectionActionBar), findsOneWidget);
          expect(find.text('1 selected'), findsOneWidget);

          // Tap tile 102 to multi-select
          await tester.tap(find.byKey(const ValueKey(102)));
          await settleUi(tester);

          expect(mediaController.selectedCount, equals(2));
          expect(mediaController.isFileSelected(102), isTrue);
          expect(find.text('2 selected'), findsOneWidget);

          // Tap tile 101 to deselect
          await tester.tap(find.byKey(const ValueKey(101)));
          await settleUi(tester);

          expect(mediaController.selectedCount, equals(1));
          expect(mediaController.isFileSelected(101), isFalse);
          expect(find.text('1 selected'), findsOneWidget);

          // Select All action
          await tester.tap(
            find.byKey(const ValueKey('selection_action_select_all')),
          );
          await settleUi(tester);

          expect(mediaController.selectedCount, equals(2));
          expect(find.text('2 selected'), findsOneWidget);

          // Cancel action exits selection mode
          await tester.tap(
            find.byKey(const ValueKey('selection_action_cancel')),
          );
          await settleUi(tester);

          expect(mediaController.isSelectionMode, isFalse);
          expect(mediaController.selectedCount, equals(0));
          expect(find.byType(SelectionActionBar), findsNothing);
          await tester.pumpWidget(const SizedBox());
        });
      },
    );

    testWidgets(
      'Bulk Delete moves selected items to trash and exits selection mode',
      (tester) async {
        await tester.runAsync(() async {
          final file1 = RemoteFile(
            id: 201,
            telegramChatId: 0,
            telegramMessageId: 201,
            telegramFileId: 2001,
            name: 'delete_me_1.jpg',
            mimeType: 'image/jpeg',
            sizeBytes: 1024,
            createdAt: DateTime.now(),
            modifiedAt: DateTime.now(),
            category: 'photos',
          );
          final file2 = RemoteFile(
            id: 202,
            telegramChatId: 0,
            telegramMessageId: 202,
            telegramFileId: 2002,
            name: 'keep_me.jpg',
            mimeType: 'image/jpeg',
            sizeBytes: 1024,
            createdAt: DateTime.now(),
            modifiedAt: DateTime.now(),
            category: 'photos',
          );
          await database.upsertFiles([file1, file2]);
          await mediaController.initializeAndSync();

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: PhotosScreen(mediaController: mediaController),
              ),
            ),
          );
          await settleUi(tester);

          // Enter selection mode and select file 201
          mediaController.enterSelectionMode(file1);
          await settleUi(tester);

          expect(find.byType(SelectionActionBar), findsOneWidget);

          // Tap Delete action button
          await tester.tap(
            find.byKey(const ValueKey('selection_action_delete')),
          );
          await settleUi(tester);

          // Confirm dialog "Move to Trash"
          expect(find.text('Move to Trash?'), findsOneWidget);
          await tester.tap(find.text('Move to Trash'));
          for (int i = 0; i < 20 && mediaController.isSelectionMode; i++) {
            await settleUi(tester, 50);
          }

          // Automatically exits selection mode
          expect(mediaController.isSelectionMode, isFalse);
          expect(mediaController.selectedCount, equals(0));

          // Verify file 201 is now in Trash in database
          final trashed = await database.getTrashedMedia();
          expect(trashed.length, equals(1));
          expect(trashed.first.telegramMessageId, equals(201));

          // Active media only has file 202
          expect(mediaController.recentMedia.length, equals(1));
          expect(
            mediaController.recentMedia.first.telegramMessageId,
            equals(202),
          );
          await tester.pumpWidget(const SizedBox());
        });
      },
    );

    testWidgets(
      'Bulk Save and Share actions operate on selected files and exit selection mode',
      (tester) async {
        await tester.runAsync(() async {
          final sampleFile = File('${tempDir.path}/save_test.jpg');
          await sampleFile.writeAsBytes([1, 2, 3, 4, 5], flush: true);

          final file1 = RemoteFile(
            id: 301,
            telegramChatId: 0,
            telegramMessageId: 301,
            telegramFileId: 3001,
            name: 'save_test.jpg',
            mimeType: 'image/jpeg',
            sizeBytes: 5,
            localPath: sampleFile.path,
            createdAt: DateTime.now(),
            modifiedAt: DateTime.now(),
            category: 'photos',
          );
          await database.upsertFiles([file1]);
          await mediaController.initializeAndSync();

          bool shareWasCalled = false;
          NativeMediaService.shareFileMock =
              ({
                required String filePath,
                required String mimeType,
                required String title,
              }) async {
                shareWasCalled = true;
                expect(filePath, equals(sampleFile.path));
                return true;
              };

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: PhotosScreen(mediaController: mediaController),
              ),
            ),
          );
          await settleUi(tester);

          // Enter selection mode on file1
          mediaController.enterSelectionMode(file1);
          await settleUi(tester);

          // Tap Share
          await tester.tap(
            find.byKey(const ValueKey('selection_action_share')),
          );
          await settleUi(tester, 200);

          expect(shareWasCalled, isTrue);
          expect(mediaController.isSelectionMode, isFalse);

          // Re-enter selection mode to test Save
          mediaController.enterSelectionMode(file1);
          await settleUi(tester);

          await tester.tap(find.byKey(const ValueKey('selection_action_save')));
          for (int i = 0; i < 20 && mediaController.isSelectionMode; i++) {
            await settleUi(tester, 50);
          }

          expect(mediaController.isSelectionMode, isFalse);
          await tester.pumpWidget(const SizedBox());
        });
      },
    );
  });

  group('Feature 2: Upload Queue & Persistence', () {
    test('Queue items are persisted in SQLite upload_queue table', () async {
      final uploadRepo = repository.uploadRepository;

      final testFile = File('${tempDir.path}/queue_test.png');
      await testFile.writeAsBytes([10, 20, 30, 40], flush: true);

      final queued = await uploadRepo.enqueueFile(
        testFile,
        mimeType: 'image/png',
      );
      expect(queued.id, isNotNull);
      expect(queued.status, equals(UploadStatus.pending));
      expect(queued.fileName, equals('queue_test.png'));
      expect(queued.fileSize, equals(4));

      final items = await uploadRepo.getQueueItems();
      expect(items.length, equals(1));
      expect(items.first.fileName, equals('queue_test.png'));
      expect(items.first.status, equals(UploadStatus.pending));
    });

    test(
      'UploadController processes queue sequentially and updates remote_files',
      () async {
        final uploadRepo = repository.uploadRepository;
        RemoteFile? completedRemoteFile;

        final uploadController = UploadController(
          repository: uploadRepo,
          onUploadCompleted: (remote) {
            completedRemoteFile = remote;
          },
        );

        final fileA = File('${tempDir.path}/seq_a.jpg');
        final fileB = File('${tempDir.path}/seq_b.jpg');
        await fileA.writeAsBytes([1, 2, 3, 4], flush: true);
        await fileB.writeAsBytes([5, 6, 7, 8], flush: true);

        // Enqueue both files
        await uploadController.enqueueFiles([fileA, fileB]);

        // Wait for sequential queue processing
        while (uploadController.isProcessing) {
          await Future.delayed(const Duration(milliseconds: 50));
        }

        // Verify both items completed
        final items = await uploadRepo.getQueueItems();
        expect(items.length, equals(2));
        expect(items[0].status, equals(UploadStatus.completed));
        expect(items[1].status, equals(UploadStatus.completed));
        expect(items[0].progress, equals(1.0));
        expect(items[1].progress, equals(1.0));

        // Verify sequential execution in fake service
        expect(
          fakeMediaService.uploadedFileNames,
          equals(['seq_a.jpg', 'seq_b.jpg']),
        );
        expect(completedRemoteFile, isNotNull);

        // Verify remote_files contains the uploaded records
        final remoteRecords = await database.getRecentMedia();
        expect(remoteRecords.length, equals(2));
        expect(remoteRecords.any((f) => f.name == 'seq_a.jpg'), isTrue);
        expect(remoteRecords.any((f) => f.name == 'seq_b.jpg'), isTrue);
      },
    );

    test(
      'Queue survives app restart by resetting uploading items to pending',
      () async {
        final uploadRepo = repository.uploadRepository;

        final testFile = File('${tempDir.path}/interrupted.jpg');
        await testFile.writeAsBytes([9, 9, 9], flush: true);

        final item = await uploadRepo.enqueueFile(testFile);
        // Simulate app killed midway through upload
        final interrupted = item.copyWith(
          status: UploadStatus.uploading,
          progress: 0.5,
        );
        await database.updateUploadQueueItem(interrupted);

        // Verify status is currently uploading
        final preRestart = await uploadRepo.getQueueItems();
        expect(preRestart.first.status, equals(UploadStatus.uploading));

        // Simulate app restart: initialize recovers interrupted uploads
        final newController = UploadController(repository: uploadRepo);
        await newController.initialize();

        while (newController.isProcessing) {
          await Future.delayed(const Duration(milliseconds: 50));
        }

        // Verify upload recovered and completed successfully
        final postRestart = await uploadRepo.getQueueItems();
        expect(postRestart.first.status, equals(UploadStatus.completed));
      },
    );

    test(
      'Cooperative cancellation stops upload safely and retry restarts it',
      () async {
        final uploadRepo = repository.uploadRepository;
        fakeMediaService.delay = const Duration(milliseconds: 300);

        final uploadController = UploadController(repository: uploadRepo);

        final cancelFile = File('${tempDir.path}/cancel_me.mp4');
        await cancelFile.writeAsBytes(List.filled(1000, 1), flush: true);

        final item = await uploadController.enqueueFile(cancelFile);

        // Cancel upload while in flight
        await Future.delayed(const Duration(milliseconds: 50));
        await uploadController.cancelUpload(item.id!);

        while (uploadController.isProcessing) {
          await Future.delayed(const Duration(milliseconds: 50));
        }

        final itemsAfterCancel = await uploadRepo.getQueueItems();
        expect(itemsAfterCancel.first.status, equals(UploadStatus.cancelled));

        // Now retry the cancelled upload
        fakeMediaService.delay = Duration.zero;
        await uploadController.retryUpload(item.id!);

        while (uploadController.isProcessing) {
          await Future.delayed(const Duration(milliseconds: 50));
        }

        final itemsAfterRetry = await uploadRepo.getQueueItems();
        expect(itemsAfterRetry.first.status, equals(UploadStatus.completed));
      },
    );
  });

  group('Feature 3: Duplicate Detection', () {
    test('Calculates SHA-256 strictly from original file bytes', () async {
      final file = File('${tempDir.path}/raw_hash_test.bin');
      await file.writeAsBytes([0xDE, 0xAD, 0xBE, 0xEF], flush: true);

      final hash = await calculateFileSha256(file);
      expect(hash, isNotEmpty);
      expect(hash.length, equals(64)); // Standard SHA-256 hex string
    });

    test(
      'Duplicate upload is detected and skipped with message "Already exists"',
      () async {
        final uploadRepo = repository.uploadRepository;
        final uploadController = UploadController(repository: uploadRepo);

        final originalFile = File('${tempDir.path}/original.jpg');
        await originalFile.writeAsBytes([1, 2, 3, 4, 99, 100], flush: true);
        final originalHash = await calculateFileSha256(originalFile);

        // Pre-seed an existing file in remote_files with identical SHA-256
        final existingRecord = RemoteFile(
          id: 999,
          telegramChatId: 0,
          telegramMessageId: 999,
          telegramFileId: 9990,
          name: 'existing_in_cloud.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 6,
          sha256: originalHash,
          createdAt: DateTime.now(),
          modifiedAt: DateTime.now(),
          category: 'photos',
        );
        await database.upsertFiles([existingRecord]);

        // Verify database finds the duplicate
        final hasDup = await uploadRepo.hasDuplicateHash(originalHash);
        expect(hasDup, isTrue);

        // Now attempt to enqueue the duplicate file
        final initialCalls = fakeMediaService.uploadCallCount;
        await uploadController.enqueueFile(originalFile);

        while (uploadController.isProcessing) {
          await Future.delayed(const Duration(milliseconds: 50));
        }

        // Verify upload was SKIPPED: Telegram upload service was NOT called
        expect(fakeMediaService.uploadCallCount, equals(initialCalls));

        // Verify queue item is marked duplicate with "Already exists"
        final items = await uploadRepo.getQueueItems();
        expect(items.length, equals(1));
        expect(items.first.status, equals(UploadStatus.duplicate));
        expect(items.first.errorMessage, equals('Already exists'));
        expect(items.first.sha256, equals(originalHash));

        // Verify existing record is NOT deleted or modified
        final afterFiles = await database.getRecentMedia();
        expect(afterFiles.length, equals(1));
        expect(afterFiles.first.telegramMessageId, equals(999));
        expect(afterFiles.first.name, equals('existing_in_cloud.jpg'));
      },
    );
  });
}

/// Fake TelegramAuthService for deterministic testing
class FakeAuthService extends TelegramAuthService {
  FakeAuthService() : super.create();

  @override
  bool get isConnected => true;

  @override
  Future<bool> ensureConnected() async => true;
}

/// Fake TelegramMediaService for testing upload queue without network calls
class FakeUploadService extends TelegramMediaService {
  FakeUploadService() : super(authService: FakeAuthService());

  int uploadCallCount = 0;
  final List<String> uploadedFileNames = [];
  bool shouldFail = false;
  Duration delay = Duration.zero;

  @override
  Future<List<RemoteFile>> fetchSavedMessagesPage({
    int offsetId = 0,
    int limit = 30,
    String? thumbsDir,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    return [];
  }

  @override
  Future<File> downloadThumbnailFile({
    required RemoteFile file,
    required String destinationPath,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final dest = File(destinationPath);
    if (!dest.parent.existsSync()) {
      dest.parent.createSync(recursive: true);
    }
    await dest.writeAsBytes(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]));
    return dest;
  }

  @override
  Future<File> downloadMediaFile({
    required RemoteFile file,
    required String destinationPath,
    void Function(double progress)? onProgress,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final dest = File(destinationPath);
    if (!dest.parent.existsSync()) {
      dest.parent.createSync(recursive: true);
    }
    onProgress?.call(0.5);
    await dest.writeAsString('mock content for ${file.name}');
    onProgress?.call(1.0);
    return dest;
  }

  @override
  Future<TelegramUploadResult> uploadDocumentFile({
    required File file,
    String? mimeType,
    void Function(double progress)? onProgress,
    TelegramUploadCancelToken? cancelToken,
    int? randomId,
    int maxRetries = 3,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    uploadCallCount++;
    uploadedFileNames.add(p.basename(file.path));

    if (delay > Duration.zero) {
      for (int i = 1; i <= 5; i++) {
        cancelToken?.throwIfCancelled();
        await Future.delayed(delay ~/ 5);
        onProgress?.call(i * 0.2);
      }
    } else {
      cancelToken?.throwIfCancelled();
      onProgress?.call(0.5);
      onProgress?.call(1.0);
    }

    if (shouldFail) {
      throw Exception('Simulated upload failure');
    }

    final String name = p.basename(file.path);
    final String resolvedMime = mimeType ?? 'application/octet-stream';
    final String category = resolvedMime.startsWith('video/')
        ? 'videos'
        : (resolvedMime.startsWith('image/') ? 'photos' : 'documents');

    return TelegramUploadResult(
      messageId: 5000 + uploadCallCount,
      fileId: 6000 + uploadCallCount,
      accessHash: 7000 + uploadCallCount,
      fileReference: Uint8List.fromList([1, 2, 3]),
      fileName: name,
      mimeType: resolvedMime,
      sizeBytes: file.lengthSync(),
      date: DateTime.utc(2026, 9, 26, 12, 0, 0),
      category: category,
    );
  }
}
