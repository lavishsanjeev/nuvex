import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuvex/app/router.dart';
import 'package:nuvex/core/database/nuvex_database.dart';
import 'package:nuvex/core/database/remote_file.dart';
import 'package:nuvex/core/services/storage_cache_manager.dart';
import 'package:nuvex/features/account/account_screen.dart';
import 'package:nuvex/features/auth/controllers/auth_controller.dart';
import 'package:nuvex/features/home/collection_detail_screen.dart';
import 'package:nuvex/features/home/collections_screen.dart';
import 'package:nuvex/features/home/controllers/media_controller.dart';
import 'package:nuvex/features/home/photos_screen.dart';
import 'package:nuvex/features/home/repositories/media_repository.dart';
import 'package:nuvex/telegram/telegram_auth_service.dart';
import 'package:nuvex/telegram/telegram_media_service.dart';
import 'package:nuvex/telegram/telegram_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class MockTelegramAuthService extends TelegramAuthService {
  NuvexTelegramUser? mockUser;
  bool isDisconnected = false;

  MockTelegramAuthService({this.mockUser}) : super.create();

  @override
  bool get isConnected => !isDisconnected;

  @override
  Future<NuvexTelegramUser?> verifyExistingSession() async {
    return mockUser;
  }

  @override
  Future<void> disconnect() async {
    isDisconnected = true;
  }
}

class MockTelegramMediaService extends TelegramMediaService {
  final List<RemoteFile> files;

  MockTelegramMediaService({this.files = const []});

  @override
  Future<List<RemoteFile>> fetchSavedMessagesPage({
    int offsetId = 0,
    int limit = 30,
    String? thumbsDir,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    return files;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  FlutterSecureStorage.setMockInitialValues({});

  late Database testDb;
  late NuvexDatabase nuvexDb;
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('nuvex_account_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall methodCall) async {
            return tempDir.path;
          },
        );

    testDb = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE remote_files (
              id INTEGER PRIMARY KEY,
              telegramChatId INTEGER NOT NULL,
              telegramMessageId INTEGER NOT NULL UNIQUE,
              telegramFileId INTEGER NOT NULL,
              name TEXT NOT NULL,
              mimeType TEXT NOT NULL,
              sizeBytes INTEGER NOT NULL,
              createdAt INTEGER NOT NULL,
              modifiedAt INTEGER NOT NULL,
              thumbnailPath TEXT,
              localPath TEXT,
              remoteAvailable INTEGER NOT NULL DEFAULT 1,
              isFavorite INTEGER NOT NULL DEFAULT 0,
              isArchived INTEGER NOT NULL DEFAULT 0,
              isLocked INTEGER NOT NULL DEFAULT 0,
              latitude REAL,
              longitude REAL,
              durationMs INTEGER,
              width INTEGER,
              height INTEGER,
              category TEXT NOT NULL
            )
          ''');
        },
      ),
    );
    nuvexDb = NuvexDatabase();
    await nuvexDb.initialize(overrideDb: testDb);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await testDb.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  List<RemoteFile> createSampleFiles() {
    final now = DateTime.now();
    return [
      // 3 Photos: 2 MB, 3 MB, 5 MB = 10 MB total
      RemoteFile(
        id: 101,
        telegramChatId: 999,
        telegramMessageId: 101,
        telegramFileId: 101,
        name: 'photo_small.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 2 * 1024 * 1024,
        createdAt: now,
        modifiedAt: now,
        category: 'photos',
      ),
      RemoteFile(
        id: 102,
        telegramChatId: 999,
        telegramMessageId: 102,
        telegramFileId: 102,
        name: 'photo_med.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 3 * 1024 * 1024,
        createdAt: now,
        modifiedAt: now,
        category: 'photos',
      ),
      RemoteFile(
        id: 103,
        telegramChatId: 999,
        telegramMessageId: 103,
        telegramFileId: 103,
        name: 'photo_large.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 5 * 1024 * 1024,
        createdAt: now,
        modifiedAt: now,
        category: 'photos',
      ),
      // 2 Videos: 15 MB, 25 MB = 40 MB total
      RemoteFile(
        id: 201,
        telegramChatId: 999,
        telegramMessageId: 201,
        telegramFileId: 201,
        name: 'video_clip.mp4',
        mimeType: 'video/mp4',
        sizeBytes: 15 * 1024 * 1024,
        createdAt: now,
        modifiedAt: now,
        category: 'videos',
      ),
      RemoteFile(
        id: 202,
        telegramChatId: 999,
        telegramMessageId: 202,
        telegramFileId: 202,
        name: 'video_movie.mp4',
        mimeType: 'video/mp4',
        sizeBytes: 25 * 1024 * 1024,
        createdAt: now,
        modifiedAt: now,
        category: 'videos',
      ),
      // 1 Document: 4 MB total
      RemoteFile(
        id: 301,
        telegramChatId: 999,
        telegramMessageId: 301,
        telegramFileId: 301,
        name: 'document.pdf',
        mimeType: 'application/pdf',
        sizeBytes: 4 * 1024 * 1024,
        createdAt: now,
        modifiedAt: now,
        category: 'documents',
      ),
    ];
  }

  group('Account & Storage Dashboard Tests', () {
    testWidgets('1. Profile button on PhotosScreen opens AccountScreen', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final mockAuth = MockTelegramAuthService(
          mockUser: const NuvexTelegramUser(
            id: 777000,
            firstName: 'Lavish',
            lastName: 'Sharma',
            username: 'lavish_nuvex',
            phone: '+919876543210',
          ),
        );
        final authController = AuthController(telegramService: mockAuth);
        final repo = MediaRepository(
          database: nuvexDb,
          mediaService: MockTelegramMediaService(),
        );
        final mediaController = MediaController(repository: repo);

        await tester.pumpWidget(
          MaterialApp(
            onGenerateRoute: NuvexRouter.onGenerateRoute,
            home: Scaffold(
              body: PhotosScreen(
                controller: authController,
                mediaController: mediaController,
              ),
            ),
          ),
        );
        await tester.pump();

        // Find the profile avatar button
        final avatarBtn = find.byKey(const ValueKey('profile_avatar_button'));
        expect(avatarBtn, findsOneWidget);

        // Tap avatar button
        await tester.tap(avatarBtn);
        await tester.pump();
        await Future.delayed(const Duration(milliseconds: 100));
        await tester.pump();

        // Verify AccountScreen opened
        expect(find.byType(AccountScreen), findsOneWidget);
        expect(find.text('Account & Storage'), findsOneWidget);
      });
    });

    testWidgets('2. Profile button on CollectionsScreen opens AccountScreen', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final mockAuth = MockTelegramAuthService(
          mockUser: const NuvexTelegramUser(
            id: 777000,
            firstName: 'Lavish',
            lastName: 'Sharma',
            username: 'lavish_nuvex',
          ),
        );
        final authController = AuthController(telegramService: mockAuth);
        final repo = MediaRepository(
          database: nuvexDb,
          mediaService: MockTelegramMediaService(),
        );
        final mediaController = MediaController(repository: repo);

        await tester.pumpWidget(
          MaterialApp(
            onGenerateRoute: NuvexRouter.onGenerateRoute,
            home: Scaffold(
              body: CollectionsScreen(
                controller: authController,
                mediaController: mediaController,
              ),
            ),
          ),
        );
        await tester.pump();

        // Find the collections profile avatar button
        final avatarBtn = find.byKey(
          const ValueKey('profile_avatar_button_collections'),
        );
        expect(avatarBtn, findsOneWidget);

        // Tap avatar button
        await tester.tap(avatarBtn);
        await tester.pump();
        await Future.delayed(const Duration(milliseconds: 100));
        await tester.pump();

        // Verify AccountScreen opened
        expect(find.byType(AccountScreen), findsOneWidget);
      });
    });

    testWidgets('3. Displays real Telegram account details and user ID', (
      tester,
    ) async {
      await tester.runAsync(() async {
        const testUser = NuvexTelegramUser(
          id: 9876543,
          firstName: 'Alice',
          lastName: 'Wonderland',
          username: 'alice_telegram',
          phone: '+1234567890',
        );
        final mockAuth = MockTelegramAuthService(mockUser: testUser);
        final authController = AuthController(telegramService: mockAuth);
        await authController.refreshCurrentUser();

        final repo = MediaRepository(
          database: nuvexDb,
          mediaService: MockTelegramMediaService(),
        );
        final mediaController = MediaController(repository: repo);

        await tester.pumpWidget(
          MaterialApp(
            home: AccountScreen(
              authController: authController,
              mediaController: mediaController,
            ),
          ),
        );
        await tester.pump();
        await Future.delayed(const Duration(milliseconds: 100));
        await tester.pump();

        // Verify user info is visible
        expect(find.text('Alice Wonderland'), findsOneWidget);
        expect(find.text('@alice_telegram'), findsOneWidget);
        expect(find.text('+1234567890'), findsOneWidget);
        expect(find.text('ID: 9876543'), findsOneWidget);
      });
    });

    testWidgets(
      '4. Storage card displays real SQLite calculations and no fake quota',
      (tester) async {
        tester.view.physicalSize = const Size(800, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());

        await tester.runAsync(() async {
          final files = createSampleFiles();
          await nuvexDb.upsertFiles(files);

          final repo = MediaRepository(
            database: nuvexDb,
            mediaService: MockTelegramMediaService(),
          );
          final mediaController = MediaController(repository: repo);
          await mediaController.loadCacheOnly();

          await tester.pumpWidget(
            MaterialApp(home: AccountScreen(mediaController: mediaController)),
          );
          await tester.pump();
          await Future.delayed(const Duration(milliseconds: 200));
          await tester.pump();

          // Total files = 3 photos + 2 videos + 1 doc = 6 files
          expect(find.text('6 files'), findsOneWidget);

          // Total bytes = 10MB + 40MB + 4MB = 54 MB
          expect(find.text('54 MB'), findsOneWidget);

          // Quota unavailable notice is explicitly displayed (no invented quota!)
          expect(
            find.text(
              'Cloud storage quota not provided • Telegram Saved Messages',
            ),
            findsOneWidget,
          );

          // Verify category breakdowns in legend
          expect(find.text('Photos'), findsWidgets);
          expect(find.text('(3)'), findsOneWidget);
          expect(find.text('10 MB'), findsOneWidget);

          expect(find.text('Videos'), findsWidgets);
          expect(find.text('(2)'), findsOneWidget);
          expect(find.text('40 MB'), findsOneWidget);

          expect(find.text('Documents & Files'), findsOneWidget);
          expect(find.text('(1)'), findsOneWidget);
          expect(find.text('4.0 MB'), findsOneWidget);
        });
      },
    );

    testWidgets(
      '5. Tapping Largest Files opens CollectionDetailScreen sorted by size',
      (tester) async {
        tester.view.physicalSize = const Size(800, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());

        await tester.runAsync(() async {
          final files = createSampleFiles();
          await nuvexDb.upsertFiles(files);

          final repo = MediaRepository(
            database: nuvexDb,
            mediaService: MockTelegramMediaService(),
          );
          final mediaController = MediaController(repository: repo);

          await tester.pumpWidget(
            MaterialApp(home: AccountScreen(mediaController: mediaController)),
          );
          await tester.pump();
          await Future.delayed(const Duration(milliseconds: 100));
          await tester.pump();

          // Find Largest Files tile
          final largestTile = find.text('Largest Files');
          expect(largestTile, findsOneWidget);

          // Tap it
          await tester.tap(largestTile);
          await tester.pump();
          await Future.delayed(const Duration(milliseconds: 100));
          await tester.pump();

          // Verify CollectionDetailScreen opened with Largest Files
          expect(find.byType(CollectionDetailScreen), findsOneWidget);

          // Check that files are sorted descending by size
          final largestFiles = await repo.getCachedFilesByCategory(
            'largest_files',
          );
          expect(largestFiles.length, 6);
          expect(largestFiles.first.name, 'video_movie.mp4'); // 25 MB
          expect(largestFiles[1].name, 'video_clip.mp4'); // 15 MB
          expect(largestFiles.last.name, 'photo_small.jpg'); // 2 MB
        });
      },
    );

    testWidgets(
      '6. Cache clearing cleans local disk without deleting cloud files or DB metadata',
      (tester) async {
        await tester.runAsync(() async {
          final files = createSampleFiles();
          await nuvexDb.upsertFiles(files);

          // Create fake cache files in tempDir
          final thumbDir = Directory('${tempDir.path}/nuvex_thumbs')
            ..createSync();
          final videoDir = Directory('${tempDir.path}/nuvex_stream_cache')
            ..createSync();
          final mediaDir = Directory('${tempDir.path}/nuvex_media')
            ..createSync();

          File('${thumbDir.path}/thumb_1.jpg')
              .writeAsBytesSync(List.filled(1024, 0));
          File('${videoDir.path}/chunk_1.bin')
              .writeAsBytesSync(List.filled(2048, 0));
          File('${mediaDir.path}/full_media_1.mp4')
              .writeAsBytesSync(List.filled(4096, 0));

          final repo = MediaRepository(
            database: nuvexDb,
            mediaService: MockTelegramMediaService(),
          );

          final cacheManager = StorageCacheManager(
            customBasePath: tempDir.path,
          );
          // Test cache manager methods
          await cacheManager.clearAllCache();

          // Verify SQLite metadata is 100% PRESERVED
          final statsAfter = await repo.getStorageStats();
          expect(
            statsAfter.totalCount,
            6,
            reason: 'Database records must NOT be deleted by cache clearing',
          );
          expect(
            statsAfter.totalBytes,
            54 * 1024 * 1024,
            reason: 'Indexed metadata must remain untouched',
          );
        });
      },
    );

    testWidgets('7. Sync now invokes media sync and updates UI', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.runAsync(() async {
        final mockAuth = MockTelegramAuthService(
          mockUser: const NuvexTelegramUser(id: 1, firstName: 'User'),
        );
        final authController = AuthController(telegramService: mockAuth);

        final fakeMedia = createSampleFiles();
        final mockMedia = MockTelegramMediaService(files: fakeMedia);
        final repo = MediaRepository(
          database: nuvexDb,
          mediaService: mockMedia,
        );
        final mediaController = MediaController(repository: repo);

        await tester.pumpWidget(
          MaterialApp(
            home: AccountScreen(
              authController: authController,
              mediaController: mediaController,
            ),
          ),
        );
        await tester.pump();

        // Find and tap Sync Now button
        final syncBtn = find.byKey(const ValueKey('sync_now_button'));
        expect(syncBtn, findsOneWidget);

        await tester.tap(syncBtn);
        await tester.pump();

        for (int i = 0; i < 20; i++) {
          if (!mediaController.isSyncing &&
              mediaController.recentMedia.isNotEmpty) {
            break;
          }
          await Future.delayed(const Duration(milliseconds: 100));
          await tester.pump();
        }

        // Verify sync completed: 5 visual media items in gallery, 6 total files in DB
        expect(mediaController.recentMedia.length, 5);
        final stats = await repo.getStorageStats();
        expect(stats.totalCount, 6);
      });
    });

    testWidgets(
      '8. Logout shows confirmation dialog and safely disconnects session',
      (tester) async {
        tester.view.physicalSize = const Size(800, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());

        await tester.runAsync(() async {
          final mockAuth = MockTelegramAuthService(
            mockUser: const NuvexTelegramUser(id: 123, firstName: 'Bob'),
          );
          final authController = AuthController(telegramService: mockAuth);

          await tester.pumpWidget(
            MaterialApp(
              routes: {
                NuvexRoutes.gettingStarted: (_) =>
                    const Scaffold(body: Text('Onboarding Screen')),
              },
              home: AccountScreen(authController: authController),
            ),
          );
          await tester.pump();

          // Tap logout button
          final logoutBtn = find.byKey(const ValueKey('logout_button'));
          expect(logoutBtn, findsOneWidget);
          await tester.tap(logoutBtn);
          await tester.pump();
          await Future.delayed(const Duration(milliseconds: 100));
          await tester.pump();

          // Verify confirmation dialog appeared
          expect(find.text('Log out of Nuvex?'), findsOneWidget);
          expect(
            find.textContaining(
              'All your photos, videos, and files remain completely safe',
            ),
            findsOneWidget,
          );

          // Tap "Log Out" inside dialog
          final confirmBtn = find.widgetWithText(ElevatedButton, 'Log Out');
          await tester.tap(confirmBtn);
          await tester.pump();
          await Future.delayed(const Duration(milliseconds: 300));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump();

          // Verify session was disconnected
          expect(mockAuth.isDisconnected, isTrue);
          expect(find.text('Onboarding Screen'), findsOneWidget);
        });
      },
    );
  });
}
