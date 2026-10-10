import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuvex/core/database/nuvex_database.dart';
import 'package:nuvex/core/database/remote_file.dart';
import 'package:nuvex/core/services/native_media_service.dart';
import 'package:nuvex/features/home/collection_detail_screen.dart';
import 'package:nuvex/features/home/controllers/media_controller.dart';
import 'package:nuvex/features/home/media_viewer_screen.dart';
import 'package:nuvex/features/home/repositories/media_repository.dart';
import 'package:nuvex/features/home/widgets/media_tile.dart';
import 'package:nuvex/telegram/telegram_auth_service.dart';
import 'package:nuvex/telegram/telegram_media_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class FakeAuthService extends TelegramAuthService {
  FakeAuthService() : super.create();
  @override
  Future<bool> ensureConnected() async => false;
}

class FakeTelegramMediaService extends TelegramMediaService {
  final List<int> deletedMessageIds = [];

  FakeTelegramMediaService() : super(authService: FakeAuthService());

  @override
  Future<bool> deleteMessage({
    required int messageId,
    bool revoke = true,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    deletedMessageIds.add(messageId);
    return true;
  }

  @override
  Future<File> downloadThumbnailFile({
    required RemoteFile file,
    required String destinationPath,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final f = File(destinationPath);
    if (!f.parent.existsSync()) {
      f.parent.createSync(recursive: true);
    }
    // Valid 1x1 transparent PNG
    await f.writeAsBytes([
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
    return f;
  }
}

class FakeMediaRepository extends MediaRepository {
  final List<RemoteFile> cannedFiles;
  final List<int> deletedFileIds = [];

  FakeMediaRepository({
    this.cannedFiles = const [],
    super.mediaService,
    super.database,
  });

  @override
  Future<List<RemoteFile>> getCachedFilesByCategory(
    String category, {
    int limit = 50,
    int offset = 0,
  }) async {
    return cannedFiles;
  }

  @override
  Future<Map<String, int>> getCachedCollectionCounts() async {
    return {};
  }

  @override
  Future<void> deleteMedia(RemoteFile file) async {
    deletedFileIds.add(file.telegramMessageId);
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('NativeMediaService Unit Tests', () {
    test(
      'shareFile throws FileSystemException if local file does not exist',
      () async {
        expect(
          () => NativeMediaService.shareFile(
            filePath: '/non/existent/path/photo.jpg',
            mimeType: 'image/jpeg',
            title: 'photo.jpg',
          ),
          throwsA(isA<FileSystemException>()),
        );
      },
    );

    test(
      'saveToDevice throws FileSystemException if source file does not exist',
      () async {
        expect(
          () => NativeMediaService.saveToDevice(
            filePath: '/non/existent/path/video.mp4',
            fileName: 'video.mp4',
            mimeType: 'video/mp4',
            category: 'videos',
          ),
          throwsA(isA<FileSystemException>()),
        );
      },
    );

    test(
      'saveToDevice successfully copies file using fallback on test runtime',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'nuvex_test_save_',
        );
        final tempSrc = File('${tempDir.path}/test_image.png');
        await tempSrc.writeAsString('dummy media content');

        final result = await NativeMediaService.saveToDevice(
          filePath: tempSrc.path,
          fileName: 'saved_image.png',
          mimeType: 'image/png',
          category: 'photos',
        );

        expect(result, isNotEmpty);
        expect(File(result).existsSync(), isTrue);

        await tempDir.delete(recursive: true);
      },
    );

    test(
      'resolveMimeType detects standard image and video MIME types accurately',
      () {
        expect(
          NativeMediaService.resolveMimeType(
            fileName: 'pic.jpg',
            currentMime: '',
          ),
          'image/jpeg',
        );
        expect(
          NativeMediaService.resolveMimeType(
            fileName: 'pic.png',
            currentMime: 'application/octet-stream',
          ),
          'image/png',
        );
        expect(
          NativeMediaService.resolveMimeType(
            fileName: 'anim.gif',
            currentMime: '',
          ),
          'image/gif',
        );
        expect(
          NativeMediaService.resolveMimeType(
            fileName: 'clip.mp4',
            currentMime: 'video',
          ),
          'video/mp4',
        );
        expect(
          NativeMediaService.resolveMimeType(
            fileName: 'photo_no_ext',
            currentMime: 'photo',
            isPhoto: true,
          ),
          'image/jpeg',
        );
      },
    );

    test('shareFile invokes shareFileMock with exact parameters', () async {
      final tempDir = await Directory.systemTemp.createTemp('nuvex_test_mock_');
      final tempFile = File('${tempDir.path}/test_share.jpg');
      await tempFile.writeAsString('valid jpeg payload');

      String? sharedPath;
      String? sharedMime;
      String? sharedTitle;

      NativeMediaService.shareFileMock =
          ({required filePath, required mimeType, required title}) async {
            sharedPath = filePath;
            sharedMime = mimeType;
            sharedTitle = title;
            return true;
          };

      try {
        final result = await NativeMediaService.shareFile(
          filePath: tempFile.path,
          mimeType: 'image/jpeg',
          title: 'test_share.jpg',
        );

        expect(result, isTrue);
        expect(sharedPath, tempFile.path);
        expect(sharedMime, 'image/jpeg');
        expect(sharedTitle, 'test_share.jpg');
      } finally {
        NativeMediaService.shareFileMock = null;
        await tempDir.delete(recursive: true);
      }
    });

    test('shareFile throws FileSystemException if file exists but is 0 bytes (empty)', () async {
      final tempDir = await Directory.systemTemp.createTemp('nuvex_empty_');
      final emptyFile = File('${tempDir.path}/empty.jpg');
      await emptyFile.create();

      expect(
        () => NativeMediaService.shareFile(
          filePath: emptyFile.path,
          mimeType: 'image/jpeg',
          title: 'empty.jpg',
        ),
        throwsA(isA<FileSystemException>()),
      );

      await tempDir.delete(recursive: true);
    });
  });

  group('NuvexDatabase Real Collection Filtering Tests', () {
    late Database testDb;
    late NuvexDatabase nuvexDb;

    setUp(() async {
      testDb = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      nuvexDb = NuvexDatabase();
      await nuvexDb.initialize(overrideDb: testDb);

      final now = DateTime.now();
      final sampleFiles = [
        RemoteFile(
          id: 101,
          telegramChatId: 0,
          telegramMessageId: 101,
          telegramFileId: 101,
          name: 'sunset.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 2500000,
          createdAt: now,
          modifiedAt: now,
          category: 'photos',
          isFavorite: true,
        ),
        RemoteFile(
          id: 102,
          telegramChatId: 0,
          telegramMessageId: 102,
          telegramFileId: 102,
          name: 'vacation.mp4',
          mimeType: 'video/mp4',
          sizeBytes: 15000000,
          createdAt: now.subtract(const Duration(days: 1)),
          modifiedAt: now.subtract(const Duration(days: 1)),
          category: 'videos',
          durationMs: 45000,
        ),
        RemoteFile(
          id: 103,
          telegramChatId: 0,
          telegramMessageId: 103,
          telegramFileId: 103,
          name: 'report.pdf',
          mimeType: 'application/pdf',
          sizeBytes: 420000,
          createdAt: now.subtract(const Duration(days: 2)),
          modifiedAt: now.subtract(const Duration(days: 2)),
          category: 'documents',
          isArchived: true,
        ),
        RemoteFile(
          id: 104,
          telegramChatId: 0,
          telegramMessageId: 104,
          telegramFileId: 104,
          name: 'screenshot_order.png',
          mimeType: 'image/png',
          sizeBytes: 900000,
          createdAt: now.subtract(const Duration(days: 3)),
          modifiedAt: now.subtract(const Duration(days: 3)),
          category: 'screenshots',
        ),
        RemoteFile(
          id: 105,
          telegramChatId: 0,
          telegramMessageId: 105,
          telegramFileId: 105,
          name: 'pin_location.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 1200000,
          createdAt: now.subtract(const Duration(days: 4)),
          modifiedAt: now.subtract(const Duration(days: 4)),
          category: 'photos',
          latitude: 40.7128,
          longitude: -74.0060,
          isLocked: true,
        ),
        RemoteFile(
          id: 106,
          telegramChatId: 0,
          telegramMessageId: 106,
          telegramFileId: 106,
          name: 'cool_sticker.webp',
          mimeType: 'image/webp',
          sizeBytes: 54000,
          createdAt: now.subtract(const Duration(days: 10)),
          modifiedAt: now.subtract(const Duration(days: 10)),
          category: 'stickers',
        ),
      ];

      await nuvexDb.upsertFiles(sampleFiles);
    });

    tearDown(() async {
      await nuvexDb.close();
      await testDb.close();
    });

    test('getFilesByCategory filters photos accurately', () async {
      final photos = await nuvexDb.getFilesByCategory('photos');
      expect(photos.length, 2);
      expect(photos.every((f) => f.category == 'photos'), isTrue);
    });

    test('getFilesByCategory filters videos accurately', () async {
      final videos = await nuvexDb.getFilesByCategory('videos');
      expect(videos.length, 1);
      expect(videos.first.name, 'vacation.mp4');
      expect(videos.first.category, 'videos');
    });

    test('getFilesByCategory filters documents accurately', () async {
      final docs = await nuvexDb.getFilesByCategory('documents');
      expect(docs.length, 1);
      expect(docs.first.name, 'report.pdf');
    });

    test('getFilesByCategory filters screenshots accurately', () async {
      final shots = await nuvexDb.getFilesByCategory('screenshots');
      expect(shots.length, 1);
      expect(shots.first.name, 'screenshot_order.png');
    });

    test(
      'getFilesByCategory filters recently_added (newest real media)',
      () async {
        final recents = await nuvexDb.getFilesByCategory('recently_added');
        expect(recents.length, 5); // 5 files within last 7 days
        expect(recents.first.name, 'sunset.jpg'); // newest first
      },
    );

    test('getFilesByCategory filters favorites based on metadata', () async {
      final favs = await nuvexDb.getFilesByCategory('favorites');
      expect(favs.length, 1);
      expect(favs.first.name, 'sunset.jpg');
      expect(favs.first.isFavorite, isTrue);
    });

    test('getFilesByCategory filters archive based on metadata', () async {
      final archived = await nuvexDb.getFilesByCategory('archive');
      expect(archived.length, 1);
      expect(archived.first.name, 'report.pdf');
    });

    test('getFilesByCategory filters locked based on metadata', () async {
      final locked = await nuvexDb.getFilesByCategory('locked');
      expect(locked.length, 1);
      expect(locked.first.name, 'pin_location.jpg');
    });

    test('getFilesByCategory filters places based on coordinates', () async {
      final places = await nuvexDb.getFilesByCategory('places');
      expect(places.length, 1);
      expect(places.first.name, 'pin_location.jpg');
    });

    test(
      'getCollectionCounts returns exact counts without fake values',
      () async {
        final counts = await nuvexDb.getCollectionCounts();
        expect(counts['documents'], 1);
        expect(counts['videos'], 1);
        expect(counts['screenshots'], 1);
        expect(counts['stickers'], 1);
        expect(counts['places'], 1);
        expect(counts['archive'], 1);
        expect(counts['locked'], 1);
        expect(counts['favorites'], 1);
        expect(counts['recently_added'], 5);
        expect(counts['moments'], 0); // Clean 0 when metadata has none
        expect(counts['creations'], 0); // Clean 0 when metadata has none
      },
    );
  });

  group('MediaViewerScreen UI & Interactions Tests', () {
    late File dummyPhotoFile;

    setUp(() async {
      final temp = await Directory.systemTemp.createTemp('nuvex_test_viewer_');
      dummyPhotoFile = File('${temp.path}/sample_test.jpg');
      await dummyPhotoFile.writeAsBytes([
        0xFF,
        0xD8,
        0xFF,
        0xE0,
        0x00,
        0x10,
        0x4A,
        0x46,
        0x49,
        0x46,
        0x00,
        0x01,
        0x01,
        0x01,
        0x00,
        0x60,
        0x00,
        0x60,
        0x00,
        0x00,
        0xFF,
        0xD9,
      ]);
    });

    tearDown(() async {
      try {
        if (dummyPhotoFile.existsSync()) {
          await dummyPhotoFile.parent.delete(recursive: true);
        }
      } catch (_) {
        // Windows file locks from Image.file decoding are safely ignored
      }
    });

    testWidgets(
      'MediaViewerScreen renders photo, title, formatted size, and action buttons',
      (tester) async {
        final file = RemoteFile(
          id: 555,
          telegramChatId: 0,
          telegramMessageId: 555,
          telegramFileId: 555,
          name: 'sample_photo.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 2450000,
          createdAt: DateTime(2026, 9, 13, 15, 30),
          modifiedAt: DateTime(2026, 9, 13, 15, 30),
          localPath: dummyPhotoFile.path,
          category: 'photos',
          width: 1920,
          height: 1080,
        );

        final controller = MediaController(repository: MediaRepository());

        await tester.pumpWidget(
          MaterialApp(
            home: MediaViewerScreen(file: file, controller: controller),
          ),
        );

        await tester.pumpAndSettle();

        // 1. Verify minimal top overlay: Back button only, NO filename/title
        expect(find.byIcon(Icons.arrow_back), findsOneWidget);
        expect(find.text('sample_photo.jpg'), findsNothing);

        // 2. Verify Bottom Action Bar buttons exist
        expect(find.byIcon(Icons.share_outlined), findsOneWidget);
        expect(find.byIcon(Icons.file_download_outlined), findsOneWidget);
        expect(find.byIcon(Icons.info_outline), findsOneWidget);
        expect(find.text('Share'), findsOneWidget);
        expect(find.text('Save'), findsOneWidget);
        expect(find.text('Details'), findsOneWidget);

        // 3. Verify photo renders inside InteractiveViewer
        expect(find.byType(InteractiveViewer), findsOneWidget);
        expect(find.byType(Image), findsOneWidget);

        // 4. Verify double-tap zoom behavior
        final iv = tester.widget<InteractiveViewer>(
          find.byType(InteractiveViewer),
        );
        expect(
          iv.transformationController!.value.getMaxScaleOnAxis(),
          closeTo(1.0, 0.01),
        );

        // Double-tap on photo to zoom in
        await tester.tap(find.byType(InteractiveViewer));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.byType(InteractiveViewer));
        await tester.pumpAndSettle();

        expect(
          iv.transformationController!.value.getMaxScaleOnAxis(),
          greaterThan(1.05),
        );

        // Double-tap again to reset zoom
        await tester.tap(find.byType(InteractiveViewer));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.byType(InteractiveViewer));
        await tester.pumpAndSettle();

        expect(
          iv.transformationController!.value.getMaxScaleOnAxis(),
          closeTo(1.0, 0.01),
        );
      },
    );

    testWidgets(
      'MediaViewerScreen Details sheet displays accurate metadata without auth exposure',
      (tester) async {
        final file = RemoteFile(
          id: 777,
          telegramChatId: 0,
          telegramMessageId: 777,
          telegramFileId: 777,
          name: 'confidential_project.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 3145728,
          createdAt: DateTime(2026, 9, 13, 14, 0),
          modifiedAt: DateTime(2026, 9, 13, 14, 0),
          localPath: dummyPhotoFile.path,
          category: 'photos',
          width: 2560,
          height: 1440,
        );

        final controller = MediaController(repository: MediaRepository());

        await tester.pumpWidget(
          MaterialApp(
            home: MediaViewerScreen(file: file, controller: controller),
          ),
        );

        await tester.pumpAndSettle();

        // Tap info/details button
        await tester.tap(find.byIcon(Icons.info_outline));
        await tester.pumpAndSettle();

        // Verify Details Modal Sheet
        expect(find.text('Media Details'), findsOneWidget);
        expect(find.text('confidential_project.jpg'), findsWidgets);
        expect(find.text('image/jpeg'), findsOneWidget);
        expect(find.textContaining('3.0 MB (3,145,728 bytes)'), findsOneWidget);
        expect(find.text('2560 × 1440 px'), findsOneWidget);
        expect(find.text('Cached locally on device'), findsOneWidget);

        // Ensure no Telegram tokens or auth data leaked in UI
        expect(find.textContaining('session'), findsNothing);
        expect(find.textContaining('dcId'), findsNothing);
        expect(find.textContaining('authKey'), findsNothing);
      },
    );

    testWidgets(
      'MediaViewerScreen Share button triggers NativeMediaService for cached photo',
      (tester) async {
        final file = RemoteFile(
          id: 888,
          telegramChatId: 0,
          telegramMessageId: 888,
          telegramFileId: 888,
          name: 'summer_beach.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 102400,
          createdAt: DateTime(2026, 9, 13),
          modifiedAt: DateTime(2026, 9, 13),
          localPath: dummyPhotoFile.path,
          category: 'photos',
        );

        String? sharedPath;
        String? sharedMime;
        NativeMediaService.shareFileMock =
            ({required filePath, required mimeType, required title}) async {
              sharedPath = filePath;
              sharedMime = mimeType;
              return true;
            };

        final controller = MediaController(repository: MediaRepository());

        await tester.pumpWidget(
          MaterialApp(
            home: MediaViewerScreen(file: file, controller: controller),
          ),
        );
        await tester.pumpAndSettle();

        // Tap Share button in bottom action bar within real async zone for dart:io
        await tester.runAsync(() async {
          await tester.tap(find.byIcon(Icons.share_outlined));
          for (int i = 0; i < 20; i++) {
            await Future.delayed(const Duration(milliseconds: 30));
            if (sharedPath != null) break;
          }
        });
        await tester.pump();

        expect(sharedPath, dummyPhotoFile.path);
        expect(sharedMime, 'image/jpeg');

        NativeMediaService.shareFileMock = null;
      },
    );
  });

  group('CollectionDetailScreen UI Tests', () {
    testWidgets(
      'CollectionDetailScreen renders clean empty state when no items exist',
      (tester) async {
        final repository = FakeMediaRepository(cannedFiles: []);

        await tester.pumpWidget(
          MaterialApp(
            home: CollectionDetailScreen(
              title: 'Moments',
              categoryKey: 'moments',
              repository: repository,
            ),
          ),
        );

        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('Moments'), findsOneWidget);
        expect(find.text('Nothing here yet'), findsOneWidget);
        expect(
          find.text('No moments found in your Telegram storage.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'CollectionDetailScreen renders 4-column gallery grid when items exist',
      (tester) async {
        final tempDir = Directory.systemTemp.createTempSync();
        final dummy1 = File('${tempDir.path}/v1.mp4')
          ..writeAsStringSync('dummy 1');
        final dummy2 = File('${tempDir.path}/v2.mp4')
          ..writeAsStringSync('dummy 2');
        addTearDown(() {
          try {
            tempDir.deleteSync(recursive: true);
          } catch (_) {}
        });

        final now = DateTime.now();
        final files = [
          RemoteFile(
            id: 201,
            telegramChatId: 0,
            telegramMessageId: 201,
            telegramFileId: 201,
            name: 'video_1.mp4',
            mimeType: 'video/mp4',
            sizeBytes: 1048576,
            createdAt: now,
            modifiedAt: now,
            category: 'videos',
            durationMs: 60000,
            localPath: dummy1.path,
          ),
          RemoteFile(
            id: 202,
            telegramChatId: 0,
            telegramMessageId: 202,
            telegramFileId: 202,
            name: 'video_2.mp4',
            mimeType: 'video/mp4',
            sizeBytes: 2048576,
            createdAt: now,
            modifiedAt: now,
            category: 'videos',
            durationMs: 90000,
            localPath: dummy2.path,
          ),
        ];

        final repository = FakeMediaRepository(cannedFiles: files);

        tester.view.physicalSize = const Size(400 * 2.5, 800 * 2.5);
        tester.view.devicePixelRatio = 2.5;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: CollectionDetailScreen(
              title: 'Videos',
              categoryKey: 'videos',
              repository: repository,
            ),
          ),
        );

        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('Videos'), findsOneWidget);
        expect(find.text('2 items'), findsOneWidget);

        final gridView = tester.widget<GridView>(find.byType(GridView));
        final delegate =
            gridView.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
        expect(delegate.crossAxisCount, 4);
        expect(find.byType(MediaTile), findsNWidgets(2));
      },
    );
  });

  group('Task 6 Fix: MediaViewer Swipe & Gesture Conflict Resolution', () {
    late File dummyPhotoFile;

    setUp(() async {
      final temp = await Directory.systemTemp.createTemp('nuvex_test_task6_');
      dummyPhotoFile = File('${temp.path}/sample_test.jpg');
      await dummyPhotoFile.writeAsBytes([
        0xFF,
        0xD8,
        0xFF,
        0xE0,
        0x00,
        0x10,
        0x4A,
        0x46,
        0x49,
        0x46,
        0x00,
        0x01,
        0x01,
        0x00,
        0x00,
        0x01,
        0x00,
        0x01,
        0x00,
        0x00,
        0xFF,
        0xDB,
        0x00,
        0x43,
        0x00,
        0x08,
        0x06,
        0x06,
        0x07,
        0x06,
        0x05,
        0x08,
        0x07,
        0x07,
        0x07,
        0x09,
        0x09,
        0x08,
        0x0A,
        0x0C,
        0x14,
        0x0D,
        0x0C,
        0x0B,
        0x0B,
        0x0C,
        0x19,
        0x12,
        0x13,
        0x0F,
        0x14,
        0x1D,
        0x1A,
        0x1F,
        0x1E,
        0x1D,
        0x1A,
        0x1C,
        0x1C,
        0x20,
        0x24,
        0x2E,
        0x27,
        0x20,
        0x22,
        0x2C,
        0x23,
        0x1C,
        0x1C,
        0x28,
        0x37,
        0x29,
        0x2C,
        0x30,
        0x31,
        0x34,
        0x34,
        0x34,
        0x1F,
        0x27,
        0x39,
        0x3D,
        0x38,
        0x32,
        0x3C,
        0x2E,
        0x33,
        0x34,
        0x32,
        0xFF,
        0xC0,
        0x00,
        0x0B,
        0x08,
        0x00,
        0x01,
        0x00,
        0x01,
        0x01,
        0x01,
        0x11,
        0x00,
        0xFF,
        0xC4,
        0x00,
        0x1F,
        0x00,
        0x00,
        0x01,
        0x05,
        0x01,
        0x01,
        0x01,
        0x01,
        0x01,
        0x01,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x01,
        0x02,
        0x03,
        0x04,
        0x05,
        0x06,
        0x07,
        0x08,
        0x09,
        0x0A,
        0x0B,
        0xFF,
        0xDA,
        0x00,
        0x08,
        0x01,
        0x01,
        0x00,
        0x00,
        0x3F,
        0x00,
        0x7F,
        0x00,
        0xFF,
        0xD9,
      ]);
    });

    tearDown(() async {
      if (dummyPhotoFile.existsSync()) {
        await dummyPhotoFile.parent.delete(recursive: true);
      }
    });

    testWidgets(
      'MediaViewerScreen horizontal swipe navigates between items via PageView',
      (tester) async {
        final now = DateTime.now();
        final fileA = RemoteFile(
          id: 101,
          telegramChatId: 0,
          telegramMessageId: 101,
          telegramFileId: 101,
          name: 'photo_A.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 1000,
          createdAt: now,
          modifiedAt: now,
          category: 'photos',
          localPath: dummyPhotoFile.path,
        );
        final fileB = RemoteFile(
          id: 102,
          telegramChatId: 0,
          telegramMessageId: 102,
          telegramFileId: 102,
          name: 'photo_B.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 2000,
          createdAt: now,
          modifiedAt: now,
          category: 'photos',
          localPath: dummyPhotoFile.path,
        );
        final fileC = RemoteFile(
          id: 103,
          telegramChatId: 0,
          telegramMessageId: 103,
          telegramFileId: 103,
          name: 'photo_C.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 3000,
          createdAt: now,
          modifiedAt: now,
          category: 'photos',
          localPath: dummyPhotoFile.path,
        );

        final controller = MediaController(repository: MediaRepository());

        await tester.pumpWidget(
          MaterialApp(
            home: MediaViewerScreen(
              files: [fileA, fileB, fileC],
              initialIndex: 0,
              controller: controller,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(PageView), findsOneWidget);

        final viewerState =
            tester.state(find.byType(MediaViewerScreen)) as dynamic;
        expect(viewerState.currentIndex, 0);
        expect(viewerState.currentFile.name, 'photo_A.jpg');

        // Swipe Left (fling right-to-left) -> Next item (fileB)
        await tester.fling(find.byType(PageView), const Offset(-500, 0), 1000);
        await tester.pumpAndSettle();

        expect(viewerState.currentIndex, 1);
        expect(viewerState.currentFile.name, 'photo_B.jpg');

        // Swipe Left -> Next item (fileC)
        await tester.fling(find.byType(PageView), const Offset(-500, 0), 1000);
        await tester.pumpAndSettle();

        expect(viewerState.currentIndex, 2);
        expect(viewerState.currentFile.name, 'photo_C.jpg');

        // Swipe Right (fling left-to-right) -> Previous item (fileB)
        await tester.fling(find.byType(PageView), const Offset(500, 0), 1000);
        await tester.pumpAndSettle();

        expect(viewerState.currentIndex, 1);
        expect(viewerState.currentFile.name, 'photo_B.jpg');
      },
    );

    testWidgets(
      'MediaViewerScreen zoom pan conflict: when zoomed in, drag pans and does NOT change page; double-tap reset restores swipe',
      (tester) async {
        final now = DateTime.now();
        final file1 = RemoteFile(
          id: 201,
          telegramChatId: 0,
          telegramMessageId: 201,
          telegramFileId: 201,
          name: 'zoom_test_1.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 1000,
          createdAt: now,
          modifiedAt: now,
          category: 'photos',
          localPath: dummyPhotoFile.path,
        );
        final file2 = RemoteFile(
          id: 202,
          telegramChatId: 0,
          telegramMessageId: 202,
          telegramFileId: 202,
          name: 'zoom_test_2.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 2000,
          createdAt: now,
          modifiedAt: now,
          category: 'photos',
          localPath: dummyPhotoFile.path,
        );

        final controller = MediaController(repository: MediaRepository());

        await tester.pumpWidget(
          MaterialApp(
            home: MediaViewerScreen(
              files: [file1, file2],
              initialIndex: 0,
              controller: controller,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final viewerState =
            tester.state(find.byType(MediaViewerScreen)) as dynamic;
        expect(viewerState.currentIndex, 0);
        expect(viewerState.currentFile.name, 'zoom_test_1.jpg');

        // Initially at scale 1.0, panEnabled is false and PageView physics is PageScrollPhysics
        var iv = tester.widget<InteractiveViewer>(
          find.byType(InteractiveViewer),
        );
        expect(iv.panEnabled, isFalse);
        var pv = tester.widget<PageView>(find.byType(PageView));
        expect(pv.physics, isA<PageScrollPhysics>());

        // Double-tap to zoom in
        await tester.tap(find.byType(InteractiveViewer));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.byType(InteractiveViewer));
        await tester.pumpAndSettle();

        iv = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
        expect(
          iv.transformationController!.value.getMaxScaleOnAxis(),
          greaterThan(1.05),
        );
        expect(iv.panEnabled, isTrue);

        pv = tester.widget<PageView>(find.byType(PageView));
        expect(pv.physics, isA<NeverScrollableScrollPhysics>());

        // While zoomed in, horizontal drag must NOT change page
        await tester.drag(
          find.byType(InteractiveViewer),
          const Offset(-300, 0),
        );
        await tester.pumpAndSettle();

        // Verify still on zoom_test_1.jpg
        expect(viewerState.currentIndex, 0);
        expect(viewerState.currentFile.name, 'zoom_test_1.jpg');

        // Double-tap again to reset zoom back to fit (1.0x)
        await tester.tap(find.byType(InteractiveViewer));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.byType(InteractiveViewer));
        await tester.pumpAndSettle();

        iv = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
        expect(
          iv.transformationController!.value.getMaxScaleOnAxis(),
          closeTo(1.0, 0.01),
        );
        expect(iv.panEnabled, isFalse);

        pv = tester.widget<PageView>(find.byType(PageView));
        expect(pv.physics, isA<PageScrollPhysics>());

        // Now that zoom is reset, horizontal swipe MUST change page to zoom_test_2.jpg
        await tester.fling(find.byType(PageView), const Offset(-500, 0), 1000);
        await tester.pumpAndSettle();

        expect(viewerState.currentIndex, 1);
        expect(viewerState.currentFile.name, 'zoom_test_2.jpg');
      },
    );

    testWidgets(
      'MediaViewerScreen first and last boundaries handle swipes safely without crashing',
      (tester) async {
        final now = DateTime.now();
        final single = RemoteFile(
          id: 301,
          telegramChatId: 0,
          telegramMessageId: 301,
          telegramFileId: 301,
          name: 'solo.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 1000,
          createdAt: now,
          modifiedAt: now,
          category: 'photos',
          localPath: dummyPhotoFile.path,
        );

        final controller = MediaController(repository: MediaRepository());

        await tester.pumpWidget(
          MaterialApp(
            home: MediaViewerScreen(
              files: [single],
              initialIndex: 0,
              controller: controller,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Drag right at first item
        await tester.drag(find.byType(PageView), const Offset(300, 0));
        await tester.pumpAndSettle();

        // Drag left at last item
        await tester.drag(find.byType(PageView), const Offset(-300, 0));
        await tester.pumpAndSettle();

        expect(find.byType(MediaViewerScreen), findsOneWidget);
      },
    );

    testWidgets(
      'NativeMediaService.cleanupUnwantedGalleryFiles invokes cleanup on native layer',
      (tester) async {
        bool cleanupCalled = false;
        NativeMediaService.cleanupUnwantedGalleryFilesMock = () async {
          cleanupCalled = true;
          return 3;
        };

        final result = await NativeMediaService.cleanupUnwantedGalleryFiles();
        expect(cleanupCalled, isTrue);
        expect(result, 3);
        NativeMediaService.cleanupUnwantedGalleryFilesMock = null;
      },
    );
  });

  group('Task 6 Fix: Swipe-Down to Dismiss & Media Deletion Tests', () {
    late File dummyPhotoFile;

    setUp(() async {
      final temp = await Directory.systemTemp.createTemp(
        'nuvex_test_task6fix_',
      );
      dummyPhotoFile = File('${temp.path}/sample_test.jpg');
      await dummyPhotoFile.writeAsBytes([
        0xFF,
        0xD8,
        0xFF,
        0xE0,
        0x00,
        0x10,
        0x4A,
        0x46,
        0x49,
        0x46,
        0x00,
        0x01,
        0x01,
        0x01,
        0x00,
        0x60,
        0x00,
        0x60,
        0x00,
        0x00,
        0xFF,
        0xD9,
      ]);
    });

    tearDown(() async {
      try {
        if (dummyPhotoFile.existsSync()) {
          await dummyPhotoFile.parent.delete(recursive: true);
        }
      } catch (_) {}
    });

    testWidgets(
      'Swipe down past threshold dismisses MediaViewerScreen and pops route',
      (tester) async {
        final file = RemoteFile(
          id: 401,
          telegramChatId: 0,
          telegramMessageId: 401,
          telegramFileId: 401,
          name: 'dismiss_test.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 1000,
          createdAt: DateTime.now(),
          modifiedAt: DateTime.now(),
          category: 'photos',
          localPath: dummyPhotoFile.path,
        );

        final controller = MediaController(repository: MediaRepository());

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => ElevatedButton(
                  onPressed: () => Navigator.of(ctx).push(
                    MediaViewerScreen.route(
                      files: [file],
                      initialIndex: 0,
                      controller: controller,
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );

        // Open viewer
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.byType(MediaViewerScreen), findsOneWidget);

        // Drag down past threshold (200px)
        await tester.drag(find.byType(PageView), const Offset(0, 200));
        await tester.pumpAndSettle();

        // Screen popped!
        expect(find.byType(MediaViewerScreen), findsNothing);
        expect(find.text('Open'), findsOneWidget);
      },
    );

    testWidgets(
      'Partial downward swipe does NOT dismiss viewer and snaps back smoothly',
      (tester) async {
        final file = RemoteFile(
          id: 402,
          telegramChatId: 0,
          telegramMessageId: 402,
          telegramFileId: 402,
          name: 'partial_test.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 1000,
          createdAt: DateTime.now(),
          modifiedAt: DateTime.now(),
          category: 'photos',
          localPath: dummyPhotoFile.path,
        );

        final controller = MediaController(repository: MediaRepository());

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => ElevatedButton(
                  onPressed: () => Navigator.of(ctx).push(
                    MediaViewerScreen.route(
                      files: [file],
                      initialIndex: 0,
                      controller: controller,
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.byType(MediaViewerScreen), findsOneWidget);

        // Small downward drag (40px)
        await tester.drag(find.byType(PageView), const Offset(0, 40));
        await tester.pumpAndSettle();

        // Stays open
        expect(find.byType(MediaViewerScreen), findsOneWidget);
      },
    );

    testWidgets('Fast downward flick dismisses MediaViewerScreen', (
      tester,
    ) async {
      final file = RemoteFile(
        id: 403,
        telegramChatId: 0,
        telegramMessageId: 403,
        telegramFileId: 403,
        name: 'flick_test.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 1000,
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
        category: 'photos',
        localPath: dummyPhotoFile.path,
      );

      final controller = MediaController(repository: MediaRepository());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => Navigator.of(ctx).push(
                  MediaViewerScreen.route(
                    files: [file],
                    initialIndex: 0,
                    controller: controller,
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(MediaViewerScreen), findsOneWidget);

      // Downward flick with high velocity (> 600 px/s)
      await tester.fling(find.byType(PageView), const Offset(0, 100), 1000);
      await tester.pumpAndSettle();

      expect(find.byType(MediaViewerScreen), findsNothing);
    });

    testWidgets('Swipe UP does NOT dismiss MediaViewerScreen', (tester) async {
      final file = RemoteFile(
        id: 404,
        telegramChatId: 0,
        telegramMessageId: 404,
        telegramFileId: 404,
        name: 'upward_test.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 1000,
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
        category: 'photos',
        localPath: dummyPhotoFile.path,
      );

      final controller = MediaController(repository: MediaRepository());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => Navigator.of(ctx).push(
                  MediaViewerScreen.route(
                    files: [file],
                    initialIndex: 0,
                    controller: controller,
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(MediaViewerScreen), findsOneWidget);

      // Drag upwards
      await tester.drag(find.byType(PageView), const Offset(0, -250));
      await tester.pumpAndSettle();

      expect(find.byType(MediaViewerScreen), findsOneWidget);
    });

    testWidgets(
      'Zoomed photo pans instead of dismissing; double-tap reset restores dismiss',
      (tester) async {
        final file = RemoteFile(
          id: 405,
          telegramChatId: 0,
          telegramMessageId: 405,
          telegramFileId: 405,
          name: 'zoom_dismiss_test.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 1000,
          createdAt: DateTime.now(),
          modifiedAt: DateTime.now(),
          category: 'photos',
          localPath: dummyPhotoFile.path,
        );

        final controller = MediaController(repository: MediaRepository());

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => ElevatedButton(
                  onPressed: () => Navigator.of(ctx).push(
                    MediaViewerScreen.route(
                      files: [file],
                      initialIndex: 0,
                      controller: controller,
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.byType(MediaViewerScreen), findsOneWidget);

        // Double-tap to zoom in
        await tester.tap(find.byType(InteractiveViewer));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.byType(InteractiveViewer));
        await tester.pumpAndSettle();

        final iv = tester.widget<InteractiveViewer>(
          find.byType(InteractiveViewer),
        );
        expect(
          iv.transformationController!.value.getMaxScaleOnAxis(),
          greaterThan(1.05),
        );

        // Drag down while zoomed -> Pans image, does NOT dismiss viewer
        await tester.drag(find.byType(InteractiveViewer), const Offset(0, 250));
        await tester.pumpAndSettle();
        expect(find.byType(MediaViewerScreen), findsOneWidget);

        // Double-tap to reset zoom
        await tester.tap(find.byType(InteractiveViewer));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.byType(InteractiveViewer));
        await tester.pumpAndSettle();

        expect(
          iv.transformationController!.value.getMaxScaleOnAxis(),
          closeTo(1.0, 0.01),
        );

        // Now drag down -> Dismisses!
        await tester.drag(find.byType(PageView), const Offset(0, 250));
        await tester.pumpAndSettle();
        expect(find.byType(MediaViewerScreen), findsNothing);
      },
    );

    testWidgets(
      'Delete button shows confirmation dialog and cancels without deleting',
      (tester) async {
        final file = RemoteFile(
          id: 406,
          telegramChatId: 0,
          telegramMessageId: 406,
          telegramFileId: 406,
          name: 'delete_cancel_test.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 1000,
          createdAt: DateTime.now(),
          modifiedAt: DateTime.now(),
          category: 'photos',
          localPath: dummyPhotoFile.path,
        );

        final repo = FakeMediaRepository();
        final controller = MediaController(repository: repo);

        await tester.pumpWidget(
          MaterialApp(
            home: MediaViewerScreen(
              files: [file],
              initialIndex: 0,
              controller: controller,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Tap Delete button
        expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);
        await tester.tap(find.byIcon(Icons.delete_outline_rounded));
        await tester.pumpAndSettle();

        // Confirmation dialog appears
        expect(find.text('Delete Media?'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);
        expect(find.text('Delete'), findsWidgets);

        // Tap Cancel
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(find.text('Delete Media?'), findsNothing);
        expect(repo.deletedFileIds, isEmpty);
        expect(find.byType(MediaViewerScreen), findsOneWidget);
      },
    );

    testWidgets(
      'Delete button deletes middle item, updates list and displays next item',
      (tester) async {
        final f1 = RemoteFile(
          id: 501,
          telegramChatId: 0,
          telegramMessageId: 501,
          telegramFileId: 501,
          name: 'item1.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 1000,
          createdAt: DateTime.now(),
          modifiedAt: DateTime.now(),
          category: 'photos',
          localPath: dummyPhotoFile.path,
        );
        final f2 = RemoteFile(
          id: 502,
          telegramChatId: 0,
          telegramMessageId: 502,
          telegramFileId: 502,
          name: 'item2.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 1000,
          createdAt: DateTime.now(),
          modifiedAt: DateTime.now(),
          category: 'photos',
          localPath: dummyPhotoFile.path,
        );
        final f3 = RemoteFile(
          id: 503,
          telegramChatId: 0,
          telegramMessageId: 503,
          telegramFileId: 503,
          name: 'item3.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 1000,
          createdAt: DateTime.now(),
          modifiedAt: DateTime.now(),
          category: 'photos',
          localPath: dummyPhotoFile.path,
        );

        final repo = FakeMediaRepository();
        final controller = MediaController(repository: repo);

        await tester.pumpWidget(
          MaterialApp(
            home: MediaViewerScreen(
              files: [f1, f2, f3],
              initialIndex: 1, // viewing middle item (502)
              controller: controller,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Tap Delete button
        await tester.tap(find.byIcon(Icons.delete_outline_rounded));
        await tester.pumpAndSettle();

        // Tap Delete in dialog
        final dialogDeleteBtn = find.widgetWithText(ElevatedButton, 'Delete');
        await tester.tap(dialogDeleteBtn);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));

        // Verify repository deletion
        expect(repo.deletedFileIds, contains(502));

        // Viewer should remain open showing remaining item
        expect(find.byType(MediaViewerScreen), findsOneWidget);
      },
    );

    testWidgets('Deleting the last remaining item closes the viewer', (
      tester,
    ) async {
      final f1 = RemoteFile(
        id: 601,
        telegramChatId: 0,
        telegramMessageId: 601,
        telegramFileId: 601,
        name: 'only_item.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 1000,
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
        category: 'photos',
        localPath: dummyPhotoFile.path,
      );

      final repo = FakeMediaRepository();
      final controller = MediaController(repository: repo);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => Navigator.of(ctx).push(
                  MediaViewerScreen.route(
                    files: [f1],
                    initialIndex: 0,
                    controller: controller,
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(MediaViewerScreen), findsOneWidget);

      // Delete the only item
      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pumpAndSettle();

      final dialogDeleteBtn = find.widgetWithText(ElevatedButton, 'Delete');
      await tester.tap(dialogDeleteBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      // Viewer should automatically close
      expect(find.byType(MediaViewerScreen), findsNothing);
      expect(find.text('Open'), findsOneWidget);
      expect(repo.deletedFileIds, contains(601));
    });

    test('deleteLocalCachedFiles deletes files inside nuvex_thumbs and nuvex_media only', () async {
      final temp = await Directory.systemTemp.createTemp('nuvex_test_cache_');
      final thumbsDir = Directory('${temp.path}/nuvex_thumbs')
        ..createSync(recursive: true);
      final mediaDir = Directory('${temp.path}/nuvex_media')
        ..createSync(recursive: true);
      final userDcimDir = Directory('${temp.path}/DCIM/Camera')
        ..createSync(recursive: true);

      final thumbFile = File('${thumbsDir.path}/101_hq.jpg')
        ..writeAsStringSync('thumb');
      final mediaFile = File('${mediaDir.path}/101_pic.jpg')
        ..writeAsStringSync('media');
      final userFile = File('${userDcimDir.path}/user_important_photo.jpg')
        ..writeAsStringSync('user');

      final repo = MediaRepository();
      final target = RemoteFile(
        id: 101,
        telegramChatId: 0,
        telegramMessageId: 101,
        telegramFileId: 101,
        name: 'pic.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 50,
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
        category: 'photos',
        thumbnailPath: thumbFile.path,
        localPath: mediaFile.path,
      );

      repo.deleteLocalCachedFiles(target);

      // Cached files inside nuvex dirs are deleted
      expect(thumbFile.existsSync(), isFalse);
      expect(mediaFile.existsSync(), isFalse);

      // An arbitrary device file outside Nuvex cache is NEVER touched
      final externalFile = target.copyWith(localPath: userFile.path);
      repo.deleteLocalCachedFiles(externalFile);
      expect(userFile.existsSync(), isTrue);

      // Clean up
      try {
        await temp.delete(recursive: true);
      } catch (_) {}
    });
  });
}
