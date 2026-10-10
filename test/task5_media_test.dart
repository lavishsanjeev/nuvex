import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuvex/app/app.dart';
import 'package:nuvex/core/database/nuvex_database.dart';
import 'package:nuvex/core/database/remote_file.dart';
import 'package:nuvex/core/storage/secure_storage.dart';
import 'package:nuvex/core/utils/image_dimensions.dart';
import 'package:nuvex/features/home/collection_detail_screen.dart';
import 'package:nuvex/features/home/collections_screen.dart';
import 'package:nuvex/features/home/controllers/media_controller.dart';
import 'package:nuvex/features/home/media_viewer_screen.dart';
import 'package:nuvex/features/home/photos_screen.dart';
import 'package:nuvex/features/home/repositories/media_repository.dart';
import 'package:nuvex/features/home/widgets/collection_card.dart';
import 'package:nuvex/features/home/widgets/media_tile.dart';
import 'package:nuvex/telegram/telegram_auth_service.dart';
import 'package:nuvex/telegram/telegram_media_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class FakeAuthService extends TelegramAuthService {
  FakeAuthService() : super.create();
  @override
  Future<bool> ensureConnected() async => false;
}

class FakeSecureStore extends NuvexSecureStore {
  const FakeSecureStore();
  @override
  Future<({int apiId, String apiHash})?> getCredentials() async => null;
  @override
  Future<String?> getUserPhone() async => null;
  @override
  Future<String?> getSession() async => null;
  @override
  Future<int?> getDcId() async => null;
  @override
  Future<String?> getUserData() async => null;
  @override
  Future<void> saveCredentials({
    required int apiId,
    required String apiHash,
  }) async {}
  @override
  Future<void> saveSession(String sessionData) async {}
  @override
  Future<void> saveDcId(int dcId) async {}
  @override
  Future<void> saveUserData(String userData) async {}
  @override
  Future<void> saveUserPhone(String phone) async {}
  @override
  Future<void> clearSession() async {}
  @override
  Future<void> clearAll() async {}
}

/// Fake MediaService that returns controlled results without network
class FakeTelegramMediaService extends TelegramMediaService {
  final List<RemoteFile> cannedFiles;
  final bool shouldFail;
  final String? failureMessage;

  FakeTelegramMediaService({
    this.cannedFiles = const [],
    this.shouldFail = false,
    this.failureMessage,
  }) : super(authService: FakeAuthService());

  @override
  Future<List<RemoteFile>> fetchSavedMessagesPage({
    int offsetId = 0,
    int limit = 30,
    String? thumbsDir,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (shouldFail) {
      throw Exception(failureMessage ?? 'Network sync failed');
    }
    return cannedFiles;
  }

  @override
  Future<File> downloadMediaFile({
    required RemoteFile file,
    required String destinationPath,
    void Function(double progress)? onProgress,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    if (shouldFail) {
      throw Exception(failureMessage ?? 'Download failed');
    }
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
  Future<File> downloadThumbnailFile({
    required RemoteFile file,
    required String destinationPath,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (shouldFail) {
      throw Exception(failureMessage ?? 'Thumb download failed');
    }
    final dest = File(destinationPath);
    if (!dest.parent.existsSync()) {
      dest.parent.createSync(recursive: true);
    }
    await dest.writeAsString('mock thumb for ${file.name}');
    return dest;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  FlutterSecureStorage.setMockInitialValues({});

  group('RemoteFile Model Tests', () {
    test('RemoteFile toMap and fromMap serialization roundtrip', () {
      final now = DateTime.now();
      final file = RemoteFile(
        id: 2002,
        telegramChatId: 1001,
        telegramMessageId: 2002,
        telegramFileId: 3003,
        name: 'IMG_2026.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 1048576, // 1 MB
        createdAt: now,
        modifiedAt: now,
        thumbnailPath: 'thumb_ref_3003',
        width: 1920,
        height: 1080,
        category: 'photos',
        isFavorite: true,
      );

      final map = file.toMap();
      expect(map['telegramMessageId'], 2002);
      expect(map['name'], 'IMG_2026.jpg');
      expect(map['category'], 'photos');
      expect(map['isFavorite'], 1);

      final restored = RemoteFile.fromMap(map);
      expect(restored.telegramMessageId, 2002);
      expect(restored.name, 'IMG_2026.jpg');
      expect(restored.mimeType, 'image/jpeg');
      expect(restored.sizeBytes, 1048576);
      expect(restored.category, 'photos');
      expect(restored.isFavorite, isTrue);
      expect(restored.width, 1920);
      expect(restored.height, 1080);
    });

    test('RemoteFile formattedSize produces human readable strings', () {
      final now = DateTime.now();
      final f1 = RemoteFile(
        id: 1,
        telegramChatId: 1,
        telegramMessageId: 1,
        telegramFileId: 1,
        name: 'small.txt',
        mimeType: 'text/plain',
        sizeBytes: 500,
        createdAt: now,
        modifiedAt: now,
        category: 'documents',
      );
      expect(f1.formattedSize, '500 B');

      final f2 = f1.copyWith(sizeBytes: 1024 * 512);
      expect(f2.formattedSize, '512.0 KB');

      final f3 = f1.copyWith(sizeBytes: 1024 * 1024 * 5);
      expect(f3.formattedSize, '5.0 MB');

      final f4 = f1.copyWith(sizeBytes: 1024 * 1024 * 1024 * 2);
      expect(f4.formattedSize, '2.00 GB');
    });

    test('RemoteFile formattedDuration formats video duration', () {
      final now = DateTime.now();
      final video = RemoteFile(
        id: 1,
        telegramChatId: 1,
        telegramMessageId: 1,
        telegramFileId: 1,
        name: 'video.mp4',
        mimeType: 'video/mp4',
        sizeBytes: 2000000,
        createdAt: now,
        modifiedAt: now,
        durationMs: 75000, // 1m 15s
        category: 'videos',
      );
      expect(video.formattedDuration, '1:15');
    });
  });

  group('NuvexDatabase SQLite Tests', () {
    late Database testDb;
    late NuvexDatabase nuvexDb;

    setUp(() async {
      nuvexDb = NuvexDatabase();
      testDb = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await nuvexDb.initialize(overrideDb: testDb);
    });

    tearDown(() async {
      await nuvexDb.close();
    });

    test(
      'upsertFiles and getRecentMedia retrieve saved photos & videos',
      () async {
        final now = DateTime.now();
        final files = [
          RemoteFile(
            id: 101,
            telegramChatId: 1,
            telegramMessageId: 101,
            telegramFileId: 501,
            name: 'photo1.jpg',
            mimeType: 'image/jpeg',
            sizeBytes: 204800,
            createdAt: now.subtract(const Duration(seconds: 10)),
            modifiedAt: now.subtract(const Duration(seconds: 10)),
            category: 'photos',
          ),
          RemoteFile(
            id: 102,
            telegramChatId: 1,
            telegramMessageId: 102,
            telegramFileId: 502,
            name: 'video1.mp4',
            mimeType: 'video/mp4',
            sizeBytes: 5242880,
            createdAt: now,
            modifiedAt: now,
            durationMs: 30000,
            category: 'videos',
          ),
          RemoteFile(
            id: 103,
            telegramChatId: 1,
            telegramMessageId: 103,
            telegramFileId: 503,
            name: 'report.pdf',
            mimeType: 'application/pdf',
            sizeBytes: 102400,
            createdAt: now.subtract(const Duration(seconds: 5)),
            modifiedAt: now.subtract(const Duration(seconds: 5)),
            category: 'documents',
          ),
        ];

        await nuvexDb.upsertFiles(files);

        final recent = await nuvexDb.getRecentMedia();
        expect(recent.length, 2);
        expect(recent[0].name, 'video1.mp4'); // More recent
        expect(recent[1].name, 'photo1.jpg');

        final docs = await nuvexDb.getFilesByCategory('documents');
        expect(docs.length, 1);
        expect(docs[0].name, 'report.pdf');
      },
    );

    test(
      'getCollectionCounts returns real database counts without fake values',
      () async {
        final now = DateTime.now();
        final files = [
          RemoteFile(
            id: 1,
            telegramChatId: 1,
            telegramMessageId: 1,
            telegramFileId: 1,
            name: 'doc1.pdf',
            mimeType: 'application/pdf',
            sizeBytes: 1000,
            createdAt: now,
            modifiedAt: now,
            category: 'documents',
          ),
          RemoteFile(
            id: 2,
            telegramChatId: 1,
            telegramMessageId: 2,
            telegramFileId: 2,
            name: 'doc2.pdf',
            mimeType: 'application/pdf',
            sizeBytes: 2000,
            createdAt: now,
            modifiedAt: now,
            category: 'documents',
          ),
          RemoteFile(
            id: 3,
            telegramChatId: 1,
            telegramMessageId: 3,
            telegramFileId: 3,
            name: 'clip.mp4',
            mimeType: 'video/mp4',
            sizeBytes: 3000,
            createdAt: now,
            modifiedAt: now,
            category: 'videos',
          ),
          RemoteFile(
            id: 4,
            telegramChatId: 1,
            telegramMessageId: 4,
            telegramFileId: 4,
            name: 'screen.png',
            mimeType: 'image/png',
            sizeBytes: 4000,
            createdAt: now,
            modifiedAt: now,
            category: 'screenshots',
          ),
          RemoteFile(
            id: 5,
            telegramChatId: 1,
            telegramMessageId: 5,
            telegramFileId: 5,
            name: 'sticker.webp',
            mimeType: 'image/webp',
            sizeBytes: 500,
            createdAt: now,
            modifiedAt: now,
            category: 'stickers',
          ),
        ];

        await nuvexDb.upsertFiles(files);

        final counts = await nuvexDb.getCollectionCounts();
        expect(counts['documents'], 2);
        expect(counts['videos'], 1);
        expect(counts['screenshots'], 1);
        expect(counts['stickers'], 1);
        expect(counts['places'], 0); // None had lat/lng
        expect(counts['archive'], 0);
        expect(counts['locked'], 0);
        expect(counts['recently_added'], 5); // All created today
      },
    );

    test(
      'getLatestMessageId returns maximum message id for incremental sync',
      () async {
        expect(await nuvexDb.getLatestMessageId(), isNull);

        final now = DateTime.now();
        final files = [
          RemoteFile(
            id: 42,
            telegramChatId: 1,
            telegramMessageId: 42,
            telegramFileId: 1,
            name: 'a.jpg',
            mimeType: 'image/jpeg',
            sizeBytes: 100,
            createdAt: now,
            modifiedAt: now,
            category: 'photos',
          ),
          RemoteFile(
            id: 99,
            telegramChatId: 1,
            telegramMessageId: 99,
            telegramFileId: 2,
            name: 'b.jpg',
            mimeType: 'image/jpeg',
            sizeBytes: 100,
            createdAt: now,
            modifiedAt: now,
            category: 'photos',
          ),
        ];

        await nuvexDb.upsertFiles(files);
        expect(await nuvexDb.getLatestMessageId(), 99);
      },
    );
  });

  group('MediaRepository & MediaController Tests', () {
    late Database testDb;
    late NuvexDatabase nuvexDb;

    setUp(() async {
      nuvexDb = NuvexDatabase();
      testDb = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await nuvexDb.initialize(overrideDb: testDb);
    });

    tearDown(() async {
      await nuvexDb.close();
    });

    test(
      'MediaController loads cached data immediately then syncs Telegram data',
      () async {
        final now = DateTime.now();
        // Pre-seed database with 1 photo
        await nuvexDb.upsertFiles([
          RemoteFile(
            id: 10,
            telegramChatId: 1,
            telegramMessageId: 10,
            telegramFileId: 100,
            name: 'cached_photo.jpg',
            mimeType: 'image/jpeg',
            sizeBytes: 1024,
            createdAt: now.subtract(const Duration(seconds: 5)),
            modifiedAt: now.subtract(const Duration(seconds: 5)),
            category: 'photos',
          ),
        ]);

        final fakeService = FakeTelegramMediaService(
          cannedFiles: [
            RemoteFile(
              id: 20,
              telegramChatId: 1,
              telegramMessageId: 20,
              telegramFileId: 200,
              name: 'synced_photo.jpg',
              mimeType: 'image/jpeg',
              sizeBytes: 2048,
              createdAt: now,
              modifiedAt: now,
              category: 'photos',
            ),
          ],
        );

        final repo = MediaRepository(
          database: nuvexDb,
          mediaService: fakeService,
        );

        final controller = MediaController(repository: repo);

        await controller.initializeAndSync();

        expect(controller.status, MediaLoadingStatus.loaded);
        expect(controller.recentMedia.length, 2);
        expect(controller.recentMedia[0].name, 'synced_photo.jpg');
        expect(controller.recentMedia[1].name, 'cached_photo.jpg');
      },
    );

    test('MediaController handles sync failure with clear error state and allows retry', () async {
      final fakeService = FakeTelegramMediaService(
        shouldFail: true,
        failureMessage: 'Telegram connection timeout',
      );

      final repo = MediaRepository(
        database: nuvexDb,
        mediaService: fakeService,
      );

      final controller = MediaController(repository: repo);
      await controller.initializeAndSync();

      // Because local DB was empty and sync failed, it enters error state
      expect(controller.status, MediaLoadingStatus.error);
      expect(controller.errorMessage, contains('Telegram connection timeout'));

      // Now fix the service and retry
      final workingService = FakeTelegramMediaService(
        cannedFiles: [
          RemoteFile(
            id: 30,
            telegramChatId: 1,
            telegramMessageId: 30,
            telegramFileId: 300,
            name: 'recovered.jpg',
            mimeType: 'image/jpeg',
            sizeBytes: 5000,
            createdAt: DateTime.now(),
            modifiedAt: DateTime.now(),
            category: 'photos',
          ),
        ],
      );

      final recoveringRepo = MediaRepository(
        database: nuvexDb,
        mediaService: workingService,
      );

      final recoveringController = MediaController(repository: recoveringRepo);
      await recoveringController.syncMedia(isRetry: true);

      expect(recoveringController.status, MediaLoadingStatus.loaded);
      expect(recoveringController.recentMedia.length, 1);
      expect(recoveringController.recentMedia[0].name, 'recovered.jpg');
    });
  });

  group('UI Widget Tests with Real Controller and Database', () {
    late Database testDb;
    late NuvexDatabase nuvexDb;

    setUp(() async {
      nuvexDb = NuvexDatabase();
      testDb = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await nuvexDb.initialize(overrideDb: testDb);
    });

    tearDown(() async {
      await nuvexDb.close();
    });

    testWidgets('MediaTile renders gallery square tile with fallback icon', (
      WidgetTester tester,
    ) async {
      final file = RemoteFile(
        id: 1,
        telegramChatId: 1,
        telegramMessageId: 1,
        telegramFileId: 1,
        name: 'vacation_sunset.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 3145728, // 3 MB
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
        category: 'photos',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 150,
              height: 150,
              child: MediaTile(file: file),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(MediaTile), findsOneWidget);
      expect(find.byType(AspectRatio), findsOneWidget);
      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    });

    testWidgets('PhotosScreen renders media items from controller', (
      WidgetTester tester,
    ) async {
      await tester.runAsync(() async {
        final now = DateTime.now();
        await nuvexDb.upsertFiles([
          RemoteFile(
            id: 1,
            telegramChatId: 1,
            telegramMessageId: 1,
            telegramFileId: 1,
            name: 'family.jpg',
            mimeType: 'image/jpeg',
            sizeBytes: 1500000,
            createdAt: now,
            modifiedAt: now,
            category: 'photos',
          ),
        ]);

        final fakeService = FakeTelegramMediaService();
        final repo = MediaRepository(
          database: nuvexDb,
          mediaService: fakeService,
        );
        final controller = MediaController(repository: repo);
        await controller.initializeAndSync();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: PhotosScreen(mediaController: controller)),
          ),
        );
        await tester.pump();
        await Future.delayed(const Duration(milliseconds: 100));
        await tester.pump();

        expect(find.text('Recent'), findsOneWidget);
        expect(find.byType(MediaTile), findsOneWidget);
        expect(find.text('No photos yet'), findsNothing);
      });
    });

    testWidgets(
      'CollectionsScreen displays real database counts and navigates to detail',
      (WidgetTester tester) async {
        await tester.runAsync(() async {
          final now = DateTime.now();
          await nuvexDb.upsertFiles([
            RemoteFile(
              id: 10,
              telegramChatId: 1,
              telegramMessageId: 10,
              telegramFileId: 1,
              name: 'tax_invoice.pdf',
              mimeType: 'application/pdf',
              sizeBytes: 250000,
              createdAt: now,
              modifiedAt: now,
              category: 'documents',
            ),
            RemoteFile(
              id: 11,
              telegramChatId: 1,
              telegramMessageId: 11,
              telegramFileId: 2,
              name: 'project_brief.pdf',
              mimeType: 'application/pdf',
              sizeBytes: 500000,
              createdAt: now,
              modifiedAt: now,
              category: 'documents',
            ),
          ]);

          final fakeService = FakeTelegramMediaService();
          final repo = MediaRepository(
            database: nuvexDb,
            mediaService: fakeService,
          );
          final controller = MediaController(repository: repo);
          await controller.initializeAndSync();

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: CollectionsScreen(mediaController: controller),
              ),
            ),
          );
          await tester.pump();
          await Future.delayed(const Duration(milliseconds: 100));
          await tester.pump();

          // Documents card should specifically show count 2
          expect(find.text('Documents'), findsOneWidget);
          expect(
            find.descendant(
              of: find.widgetWithText(CollectionCard, 'Documents'),
              matching: find.text('2'),
            ),
            findsOneWidget,
          );

          // Places should show title
          expect(find.text('Places'), findsOneWidget);

          // Tap Documents to navigate to detail
          await tester.tap(find.text('Documents'));
          await tester.pump();
          await Future.delayed(const Duration(milliseconds: 200));
          await tester.pump();

          expect(find.byType(MediaTile), findsNWidgets(2));
        });
      },
    );

    testWidgets(
      'CollectionDetailScreen shows clean empty state for empty category',
      (WidgetTester tester) async {
        await tester.runAsync(() async {
          final repo = MediaRepository(database: nuvexDb);

          await tester.pumpWidget(
            MaterialApp(
              home: CollectionDetailScreen(
                categoryKey: 'stickers',
                title: 'Stickers',
                repository: repo,
              ),
            ),
          );
          await tester.pump();
          await Future.delayed(const Duration(milliseconds: 200));
          await tester.pump();

          expect(find.text('Stickers'), findsOneWidget);
          expect(find.text('Nothing here yet'), findsOneWidget);
          expect(
            find.text('No stickers found in your Telegram storage.'),
            findsOneWidget,
          );
        });
      },
    );

    testWidgets(
      'CollectionCard renders with non-zero count without RenderFlex overflow',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 150,
                  height: 120,
                  child: CollectionCard(
                    title: 'Documents',
                    icon: Icons.description_outlined,
                    iconColor: Colors.blue,
                    badgeBackground: Colors.blue.shade50,
                    count: 142,
                    onTap: () {},
                  ),
                ),
              ),
            ),
          ),
        );

        expect(find.text('Documents'), findsOneWidget);
        expect(find.text('142'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    test(
      'MediaRepository ensureFileDownloaded caches file and updates SQLite',
      () async {
        final mediaService = FakeTelegramMediaService();
        final repo = MediaRepository(
          database: nuvexDb,
          mediaService: mediaService,
        );

        final file = RemoteFile(
          id: 777,
          telegramChatId: 0,
          telegramMessageId: 777,
          telegramFileId: 888,
          name: 'sample_photo.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 1024,
          createdAt: DateTime.now(),
          modifiedAt: DateTime.now(),
          category: 'photos',
        );

        final downloaded = await repo.ensureFileDownloaded(file);
        expect(downloaded.localPath, isNotNull);
        expect(File(downloaded.localPath!).existsSync(), isTrue);

        // Verify second call reuses existing file
        final cachedAgain = await repo.ensureFileDownloaded(downloaded);
        expect(cachedAgain.localPath, downloaded.localPath);
      },
    );

    testWidgets(
      'MediaViewerScreen renders InteractiveViewer for downloaded photo',
      (WidgetTester tester) async {
        await tester.runAsync(() async {
          final tempDir = Directory.systemTemp;
          final testPhoto = File('${tempDir.path}/test_photo_viewer.png');
          // Valid 1x1 transparent PNG bytes
          await testPhoto.writeAsBytes(const [
            0x89,
            0x50,
            0x4E,
            0x47,
            0x0D,
            0x0A,
            0x1A,
            0x0A,
            0x00,
            0x00,
            0x00,
            0x0D,
            0x49,
            0x48,
            0x44,
            0x52,
            0x00,
            0x00,
            0x00,
            0x01,
            0x00,
            0x00,
            0x00,
            0x01,
            0x08,
            0x06,
            0x00,
            0x00,
            0x00,
            0x1F,
            0x15,
            0xC4,
            0x89,
            0x00,
            0x00,
            0x00,
            0x0A,
            0x49,
            0x44,
            0x41,
            0x54,
            0x78,
            0x9C,
            0x63,
            0x00,
            0x01,
            0x00,
            0x00,
            0x05,
            0x00,
            0x01,
            0x0D,
            0x0A,
            0x2D,
            0xB4,
            0x00,
            0x00,
            0x00,
            0x00,
            0x49,
            0x45,
            0x4E,
            0x44,
            0xAE,
            0x42,
            0x60,
            0x82,
          ]);

          final file = RemoteFile(
            id: 999,
            telegramChatId: 0,
            telegramMessageId: 999,
            telegramFileId: 999,
            name: 'test_photo_viewer.png',
            mimeType: 'image/png',
            sizeBytes: 67,
            createdAt: DateTime.now(),
            modifiedAt: DateTime.now(),
            category: 'photos',
            localPath: testPhoto.path,
          );

          final controller = MediaController(
            repository: MediaRepository(database: nuvexDb),
          );

          await tester.pumpWidget(
            MaterialApp(
              home: MediaViewerScreen(file: file, controller: controller),
            ),
          );
          await tester.pump();

          expect(find.byIcon(Icons.arrow_back), findsOneWidget);
          expect(find.byType(InteractiveViewer), findsOneWidget);

          if (testPhoto.existsSync()) {
            testPhoto.deleteSync();
          }
        });
      },
    );

    testWidgets('StartupScreen checks session and routes to Getting Started', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const NuvexApp());
      await tester.pumpAndSettle();

      expect(find.text('Getting Started'), findsOneWidget);
    });

    test(
      'inflateTelegramStrippedThumbnail reconstructs valid JPEG byte array',
      () {
        // Byte 0 = 0x01 (version), Byte 1 = 40 (height), Byte 2 = 40 (width), rest = scan data
        final rawStripped = Uint8List.fromList([1, 40, 40, 0x11, 0x22, 0x33]);
        final inflated = inflateTelegramStrippedThumbnail(rawStripped);

        expect(inflated, isNotNull);
        // Valid JPEG starts with SOI 0xFF, 0xD8
        expect(inflated![0], 0xFF);
        expect(inflated[1], 0xD8);
        // Valid JPEG ends with EOI 0xFF, 0xD9
        expect(inflated[inflated.length - 2], 0xFF);
        expect(inflated[inflated.length - 1], 0xD9);
      },
    );

    test('getJpegDimensions extracts width and height from JPEG bytes', () {
      // Create a minimal synthetic JPEG with SOF0 marker (0xFF, 0xC0)
      // SOI: 0xFF, 0xD8
      // SOF0: 0xFF, 0xC0, 0x00, 0x11 (length 17), 0x08 (precision), 0x01, 0x40 (h=320), 0x01, 0x40 (w=320)
      final jpegBytes = Uint8List.fromList([
        0xFF,
        0xD8,
        0xFF,
        0xC0,
        0x00,
        0x11,
        0x08,
        0x01,
        0x40, // height = 320
        0x01,
        0x40, // width = 320
        0x03,
        0x01,
        0x11,
        0x00,
        0x02,
        0x11,
        0x01,
        0x03,
        0x11,
        0x01,
        0xFF,
        0xD9,
      ]);
      final dims = getJpegDimensions(jpegBytes);
      expect(dims, isNotNull);
      expect(dims!.width, equals(320));
      expect(dims.height, equals(320));

      // Test tiny stripped 40x40 JPEG
      final tinyBytes = Uint8List.fromList([
        0xFF,
        0xD8,
        0xFF,
        0xC0,
        0x00,
        0x11,
        0x08,
        0x00,
        0x28, // height = 40
        0x00,
        0x28, // width = 40
        0x03,
        0x01,
        0x11,
        0x00,
        0x02,
        0x11,
        0x01,
        0x03,
        0x11,
        0x01,
        0xFF,
        0xD9,
      ]);
      final tinyDims = getJpegDimensions(tinyBytes);
      expect(tinyDims, isNotNull);
      expect(tinyDims!.width, equals(40));
      expect(tinyDims.height, equals(40));
    });

    testWidgets('PhotosScreen renders 4-column gallery grid on phone width', (
      WidgetTester tester,
    ) async {
      await tester.runAsync(() async {
        final fakeMedia = [
          RemoteFile(
            id: 501,
            telegramChatId: 0,
            telegramMessageId: 501,
            telegramFileId: 501,
            name: 'Photo_501.jpg',
            mimeType: 'image/jpeg',
            sizeBytes: 2000,
            createdAt: DateTime.now(),
            modifiedAt: DateTime.now(),
            category: 'photos',
          ),
          RemoteFile(
            id: 502,
            telegramChatId: 0,
            telegramMessageId: 502,
            telegramFileId: 502,
            name: 'Video_502.mp4',
            mimeType: 'video/mp4',
            sizeBytes: 15000,
            durationMs: 45000,
            createdAt: DateTime.now(),
            modifiedAt: DateTime.now(),
            category: 'videos',
          ),
        ];

        final fakeService = FakeTelegramMediaService(cannedFiles: fakeMedia);
        final repo = MediaRepository(
          mediaService: fakeService,
          database: nuvexDb,
        );
        final controller = MediaController(repository: repo);
        await repo.syncSavedMessages();
        await controller.loadCacheOnly();

        // Set phone screen size (390 x 844)
        tester.view.physicalSize = const Size(390 * 3.0, 844 * 3.0);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(() => tester.view.resetPhysicalSize());

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: PhotosScreen(mediaController: controller)),
          ),
        );
        await tester.pump();
        await Future.delayed(const Duration(milliseconds: 100));
        await tester.pump();

        // Find the grid
        final gridFinder = find.byType(SliverGrid);
        expect(gridFinder, findsOneWidget);

        final grid = tester.widget<SliverGrid>(gridFinder);
        final delegate =
            grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
        expect(delegate.crossAxisCount, equals(4));

        // Verify video play icon is present
        expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

        // Tap the photo tile to verify it opens MediaViewerScreen
        final tileFinder = find.byType(MediaTile).first;
        await tester.tap(tileFinder);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.byType(MediaViewerScreen), findsOneWidget);
        expect(find.byIcon(Icons.arrow_back), findsOneWidget);

        // Test back navigation
        final backButton = find.byIcon(Icons.arrow_back);
        expect(backButton, findsOneWidget);
        await tester.tap(backButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));

        expect(find.byType(MediaViewerScreen), findsNothing);
        expect(find.byType(PhotosScreen), findsOneWidget);
      });
    });
  });
}
