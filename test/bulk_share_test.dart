import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuvex/core/database/nuvex_database.dart';
import 'package:nuvex/core/database/remote_file.dart';
import 'package:nuvex/core/services/native_media_service.dart';
import 'package:nuvex/features/home/controllers/media_controller.dart';
import 'package:nuvex/features/home/photos_screen.dart';
import 'package:nuvex/features/home/repositories/media_repository.dart';
import 'package:nuvex/features/home/widgets/selection_action_bar.dart';
import 'package:nuvex/telegram/telegram_auth_service.dart';
import 'package:nuvex/telegram/telegram_media_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class MockTelegramAuthService extends TelegramAuthService {
  MockTelegramAuthService() : super.create();
  @override
  Future<bool> ensureConnected() async => true;
}

class MockTelegramMediaService extends TelegramMediaService {
  final Set<int> failMessageIds = {};
  int downloadCallCount = 0;
  Duration simulatedDownloadDelay = Duration.zero;

  MockTelegramMediaService() : super(authService: MockTelegramAuthService());

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
    downloadCallCount++;
    if (simulatedDownloadDelay > Duration.zero) {
      await Future.delayed(simulatedDownloadDelay);
    }
    if (failMessageIds.contains(file.telegramMessageId)) {
      throw Exception('Simulated download failure for ${file.name}');
    }
    final dest = File(destinationPath);
    if (!dest.parent.existsSync()) {
      dest.parent.createSync(recursive: true);
    }
    onProgress?.call(0.5);
    await dest.writeAsString('mock payload for ${file.name}');
    onProgress?.call(1.0);
    return dest;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late Database testDb;
  late NuvexDatabase database;
  late MockTelegramMediaService mockMediaService;
  late MediaRepository repository;
  late MediaController mediaController;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('nuvex_bulk_share_test_');
    final nuvexMedia = Directory('${Directory.systemTemp.path}/nuvex_media');
    if (nuvexMedia.existsSync()) {
      try {
        nuvexMedia.deleteSync(recursive: true);
      } catch (_) {}
    }

    database = NuvexDatabase();
    testDb = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await database.initialize(overrideDb: testDb);

    mockMediaService = MockTelegramMediaService();
    repository = MediaRepository(
      database: database,
      mediaService: mockMediaService,
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
    final nuvexMedia = Directory('${Directory.systemTemp.path}/nuvex_media');
    if (nuvexMedia.existsSync()) {
      try {
        nuvexMedia.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  Future<void> settle(WidgetTester tester, [int delayMs = 50]) async {
    await tester.pump();
    await Future.delayed(Duration(milliseconds: delayMs));
    await tester.pump();
  }

  group('NativeMediaService.shareFiles Unit Tests', () {
    test('shareFiles returns false on empty list', () async {
      final result = await NativeMediaService.shareFiles(
        filePaths: [],
        title: 'Empty',
      );
      expect(result, isFalse);
    });

    test(
      'shareFiles throws FileSystemException if any file does not exist',
      () async {
        expect(
          () => NativeMediaService.shareFiles(
            filePaths: ['${tempDir.path}/non_existent_123.jpg'],
            title: 'Missing File',
          ),
          throwsA(isA<FileSystemException>()),
        );
      },
    );

    test('shareFiles throws FileSystemException if file is 0 bytes', () async {
      final emptyFile = File('${tempDir.path}/empty.jpg');
      await emptyFile.create();
      expect(
        () => NativeMediaService.shareFiles(
          filePaths: [emptyFile.path],
          title: 'Empty File',
        ),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('shareFiles invokes shareFilesMock with exact parameters', () async {
      final file1 = File('${tempDir.path}/file1.jpg');
      await file1.writeAsString('photo 1');
      final file2 = File('${tempDir.path}/file2.mp4');
      await file2.writeAsString('video 2');

      List<String>? capturedPaths;
      List<String>? capturedMimes;
      String? capturedTitle;

      NativeMediaService.shareFilesMock =
          ({
            required List<String> filePaths,
            required List<String> mimeTypes,
            required String title,
          }) async {
            capturedPaths = filePaths;
            capturedMimes = mimeTypes;
            capturedTitle = title;
            return true;
          };

      final result = await NativeMediaService.shareFiles(
        filePaths: [file1.path, file2.path],
        mimeTypes: ['image/jpeg', 'video/mp4'],
        title: 'Share 2 items',
      );

      expect(result, isTrue);
      expect(capturedPaths, equals([file1.path, file2.path]));
      expect(capturedMimes, equals(['image/jpeg', 'video/mp4']));
      expect(capturedTitle, equals('Share 2 items'));
    });

    test('shareFiles falls back to shareFileMock when 1 file is passed and shareFilesMock is null', () async {
      final file1 = File('${tempDir.path}/single.jpg');
      await file1.writeAsString('photo single');

      String? capturedPath;
      String? capturedMime;
      String? capturedTitle;

      NativeMediaService.shareFileMock =
          ({
            required String filePath,
            required String mimeType,
            required String title,
          }) async {
            capturedPath = filePath;
            capturedMime = mimeType;
            capturedTitle = title;
            return true;
          };

      final result = await NativeMediaService.shareFiles(
        filePaths: [file1.path],
        mimeTypes: ['image/jpeg'],
        title: 'Single Share',
      );

      expect(result, isTrue);
      expect(capturedPath, equals(file1.path));
      expect(capturedMime, equals('image/jpeg'));
      expect(capturedTitle, equals('Single Share'));
    });
  });

  group('MediaController.shareSelected Bulk Flow', () {
    test('Downloads all required files first and calls shareFilesMock exactly ONCE', () async {
      final f1 = RemoteFile(
        id: 1,
        telegramChatId: 0,
        telegramMessageId: 101,
        telegramFileId: 1001,
        name: 'photo_1.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 100,
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
        category: 'photos',
      );
      final f2 = RemoteFile(
        id: 2,
        telegramChatId: 0,
        telegramMessageId: 102,
        telegramFileId: 1002,
        name: 'photo_2.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 200,
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
        category: 'photos',
      );
      await database.upsertFiles([f1, f2]);
      await mediaController.initializeAndSync();

      mediaController.enterSelectionMode(f1);
      mediaController.toggleSelection(f2);
      expect(mediaController.selectedCount, equals(2));

      int shareFilesInvocationCount = 0;
      List<String>? sharedPaths;

      NativeMediaService.shareFilesMock =
          ({
            required List<String> filePaths,
            required List<String> mimeTypes,
            required String title,
          }) async {
            shareFilesInvocationCount++;
            sharedPaths = filePaths;
            return true;
          };

      final success = await mediaController.shareSelected();

      expect(success, isTrue);
      // Verify downloads happened prior to share
      expect(mockMediaService.downloadCallCount, equals(2));
      // Exactly ONE native share invocation for bulk selection
      expect(shareFilesInvocationCount, equals(1));
      expect(sharedPaths?.length, equals(2));
      // Selection mode exited upon completion
      expect(mediaController.isSelectionMode, isFalse);
    });

    test('Reuses already cached files without redownloading them', () async {
      final cachedFile = File('${tempDir.path}/cached.jpg');
      await cachedFile.writeAsString('already cached');

      final f1 = RemoteFile(
        id: 1,
        telegramChatId: 0,
        telegramMessageId: 201,
        telegramFileId: 2001,
        name: 'cached.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 100,
        localPath: cachedFile.path,
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
        category: 'photos',
      );
      final f2 = RemoteFile(
        id: 2,
        telegramChatId: 0,
        telegramMessageId: 202,
        telegramFileId: 2002,
        name: 'uncached.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 200,
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
        category: 'photos',
      );
      await database.upsertFiles([f1, f2]);
      await mediaController.initializeAndSync();

      mediaController.enterSelectionMode(f1);
      mediaController.toggleSelection(f2);

      int shareCount = 0;
      NativeMediaService.shareFilesMock =
          ({
            required List<String> filePaths,
            required List<String> mimeTypes,
            required String title,
          }) async {
            shareCount++;
            return true;
          };

      await mediaController.shareSelected();

      // Only f2 needed downloading
      expect(mockMediaService.downloadCallCount, equals(1));
      expect(shareCount, equals(1));
    });

    test(
      'Cancellation halts remaining downloads and does NOT invoke native share',
      () async {
        final f1 = RemoteFile(
          id: 1,
          telegramChatId: 0,
          telegramMessageId: 301,
          telegramFileId: 3001,
          name: 'item1.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 100,
          createdAt: DateTime.now(),
          modifiedAt: DateTime.now(),
          category: 'photos',
        );
        final f2 = RemoteFile(
          id: 2,
          telegramChatId: 0,
          telegramMessageId: 302,
          telegramFileId: 3002,
          name: 'item2.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 100,
          createdAt: DateTime.now(),
          modifiedAt: DateTime.now(),
          category: 'photos',
        );
        await database.upsertFiles([f1, f2]);
        await mediaController.initializeAndSync();

        mediaController.enterSelectionMode(f1);
        mediaController.toggleSelection(f2);

        bool shareInvoked = false;
        NativeMediaService.shareFilesMock =
            ({
              required List<String> filePaths,
              required List<String> mimeTypes,
              required String title,
            }) async {
              shareInvoked = true;
              return true;
            };

        bool cancelFlag = false;
        final result = await mediaController.shareSelected(
          onProgress: (current, total, name) {
            if (current == 1) {
              cancelFlag = true;
            }
          },
          isCancelled: () => cancelFlag,
        );

        expect(result, isFalse);
        expect(shareInvoked, isFalse);
        // Second file was not downloaded
        expect(mockMediaService.downloadCallCount, equals(1));
      },
    );
  });

  group('BulkShareDialog & SelectionActionBar Widget Tests', () {
    testWidgets(
      'Single-file selection keeps direct share flow without showing BulkShareDialog',
      (tester) async {
        await tester.runAsync(() async {
          final sample = File('${tempDir.path}/single_action.jpg');
          await sample.writeAsString('test');

          final f1 = RemoteFile(
            id: 1,
            telegramChatId: 0,
            telegramMessageId: 401,
            telegramFileId: 4001,
            name: 'single_action.jpg',
            mimeType: 'image/jpeg',
            sizeBytes: 4,
            localPath: sample.path,
            createdAt: DateTime.now(),
            modifiedAt: DateTime.now(),
            category: 'photos',
          );
          await database.upsertFiles([f1]);
          await mediaController.initializeAndSync();

          bool shareCalled = false;
          NativeMediaService.shareFileMock =
              ({
                required String filePath,
                required String mimeType,
                required String title,
              }) async {
                shareCalled = true;
                return true;
              };

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: PhotosScreen(mediaController: mediaController),
              ),
            ),
          );
          await settle(tester);

          mediaController.enterSelectionMode(f1);
          await settle(tester);

          // Tap Share button in SelectionActionBar
          await tester.tap(
            find.byKey(const ValueKey('selection_action_share')),
          );
          await settle(tester, 200);

          expect(shareCalled, isTrue);
          expect(find.byKey(const ValueKey('bulk_share_dialog')), findsNothing);
          expect(mediaController.isSelectionMode, isFalse);
        });
      },
    );

    testWidgets(
      'Multiple-file selection opens BulkShareDialog and shares ONCE on success',
      (tester) async {
        await tester.runAsync(() async {
          final f1 = RemoteFile(
            id: 1,
            telegramChatId: 0,
            telegramMessageId: 501,
            telegramFileId: 5001,
            name: 'multi1.jpg',
            mimeType: 'image/jpeg',
            sizeBytes: 10,
            createdAt: DateTime.now(),
            modifiedAt: DateTime.now(),
            category: 'photos',
          );
          final f2 = RemoteFile(
            id: 2,
            telegramChatId: 0,
            telegramMessageId: 502,
            telegramFileId: 5002,
            name: 'multi2.jpg',
            mimeType: 'image/jpeg',
            sizeBytes: 20,
            createdAt: DateTime.now(),
            modifiedAt: DateTime.now(),
            category: 'photos',
          );
          await database.upsertFiles([f1, f2]);
          await mediaController.initializeAndSync();

          int shareInvocations = 0;
          List<String>? sharedPaths;

          NativeMediaService.shareFilesMock =
              ({
                required List<String> filePaths,
                required List<String> mimeTypes,
                required String title,
              }) async {
                shareInvocations++;
                sharedPaths = filePaths;
                return true;
              };

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SelectionActionBar(controller: mediaController),
              ),
            ),
          );

          mediaController.enterSelectionMode(f1);
          mediaController.toggleSelection(f2);
          await settle(tester);

          // Tap Share
          await tester.tap(
            find.byKey(const ValueKey('selection_action_share')),
          );
          await tester.pump();

          // Verify BulkShareDialog appeared
          expect(
            find.byKey(const ValueKey('bulk_share_dialog')),
            findsOneWidget,
          );
          expect(find.text('Preparing 2 photos...'), findsOneWidget);

          // Let the downloads finish
          for (int i = 0; i < 20 && mediaController.isSelectionMode; i++) {
            await settle(tester, 50);
          }

          expect(shareInvocations, equals(1));
          expect(sharedPaths?.length, equals(2));
          expect(mediaController.isSelectionMode, isFalse);
          expect(find.byKey(const ValueKey('bulk_share_dialog')), findsNothing);
        });
      },
    );

    testWidgets(
      'Cancelling BulkShareDialog halts downloads without invoking share sheet',
      (tester) async {
        await tester.runAsync(() async {
          mockMediaService.simulatedDownloadDelay = const Duration(
            milliseconds: 100,
          );

          final f1 = RemoteFile(
            id: 1,
            telegramChatId: 0,
            telegramMessageId: 601,
            telegramFileId: 6001,
            name: 'cancel1.jpg',
            mimeType: 'image/jpeg',
            sizeBytes: 10,
            createdAt: DateTime.now(),
            modifiedAt: DateTime.now(),
            category: 'photos',
          );
          final f2 = RemoteFile(
            id: 2,
            telegramChatId: 0,
            telegramMessageId: 602,
            telegramFileId: 6002,
            name: 'cancel2.jpg',
            mimeType: 'image/jpeg',
            sizeBytes: 20,
            createdAt: DateTime.now(),
            modifiedAt: DateTime.now(),
            category: 'photos',
          );
          await database.upsertFiles([f1, f2]);
          await mediaController.initializeAndSync();

          bool shareInvoked = false;
          NativeMediaService.shareFilesMock =
              ({
                required List<String> filePaths,
                required List<String> mimeTypes,
                required String title,
              }) async {
                shareInvoked = true;
                return true;
              };

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SelectionActionBar(controller: mediaController),
              ),
            ),
          );

          mediaController.enterSelectionMode(f1);
          mediaController.toggleSelection(f2);
          await settle(tester);

          await tester.tap(
            find.byKey(const ValueKey('selection_action_share')),
          );
          await tester.pump();

          expect(
            find.byKey(const ValueKey('bulk_share_dialog')),
            findsOneWidget,
          );

          // Tap Cancel on progress dialog
          await tester.tap(
            find.byKey(const ValueKey('bulk_share_cancel_button')),
          );
          await settle(tester, 150);

          expect(find.byKey(const ValueKey('bulk_share_dialog')), findsNothing);
          expect(shareInvoked, isFalse);
        });
      },
    );

    testWidgets(
      'Partial download failure displays "1 of 2 files ready to share" and allows sharing ready files',
      (tester) async {
        await tester.runAsync(() async {
          // Configure f2 to fail download
          mockMediaService.failMessageIds.add(702);

          final f1 = RemoteFile(
            id: 1,
            telegramChatId: 0,
            telegramMessageId: 701,
            telegramFileId: 7001,
            name: 'success.jpg',
            mimeType: 'image/jpeg',
            sizeBytes: 10,
            createdAt: DateTime.now(),
            modifiedAt: DateTime.now(),
            category: 'photos',
          );
          final f2 = RemoteFile(
            id: 2,
            telegramChatId: 0,
            telegramMessageId: 702,
            telegramFileId: 7002,
            name: 'fails.jpg',
            mimeType: 'image/jpeg',
            sizeBytes: 20,
            createdAt: DateTime.now(),
            modifiedAt: DateTime.now(),
            category: 'photos',
          );
          await database.upsertFiles([f1, f2]);
          await mediaController.initializeAndSync();

          List<String>? sharedPaths;
          NativeMediaService.shareFilesMock =
              ({
                required List<String> filePaths,
                required List<String> mimeTypes,
                required String title,
              }) async {
                sharedPaths = filePaths;
                return true;
              };

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SelectionActionBar(controller: mediaController),
              ),
            ),
          );

          mediaController.enterSelectionMode(f1);
          mediaController.toggleSelection(f2);
          await settle(tester);

          await tester.tap(
            find.byKey(const ValueKey('selection_action_share')),
          );
          // Let all download attempts complete
          for (int i = 0; i < 20; i++) {
            await settle(tester, 50);
            if (find
                .byKey(const ValueKey('bulk_share_result_title'))
                .evaluate()
                .isNotEmpty) {
              break;
            }
          }

          // Verify result text format matches requirement 4
          expect(find.text('1 of 2 files ready to share'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('bulk_share_share_ready')),
            findsOneWidget,
          );

          // Tap "Share Ready Files"
          await tester.tap(
            find.byKey(const ValueKey('bulk_share_share_ready')),
          );
          await settle(tester, 100);

          // Only the single successful file was shared
          expect(sharedPaths?.length, equals(1));
          expect(mediaController.isSelectionMode, isFalse);
        });
      },
    );
  });
}
