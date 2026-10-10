// ignore_for_file: avoid_print
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuvex/core/database/nuvex_database.dart';
import 'package:nuvex/core/database/remote_file.dart';
import 'package:nuvex/features/home/controllers/media_controller.dart';
import 'package:nuvex/features/home/photos_screen.dart';
import 'package:nuvex/features/home/repositories/media_repository.dart';
import 'package:nuvex/telegram/telegram_media_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class PaginatedMockMediaService extends TelegramMediaService {
  final List<RemoteFile> allPhotos;
  final int pageSize;
  final List<({int offsetId, int limit, int returnedCount})> pageRequests = [];

  PaginatedMockMediaService({required this.allPhotos, this.pageSize = 30});

  @override
  Future<List<RemoteFile>> fetchSavedMessagesPage({
    int offsetId = 0,
    int limit = 30,
    String? thumbsDir,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    // Sort allPhotos descending by telegramMessageId (newest first)
    final sorted = List<RemoteFile>.from(allPhotos)
      ..sort((a, b) => b.telegramMessageId.compareTo(a.telegramMessageId));

    List<RemoteFile> page;
    if (offsetId == 0) {
      page = sorted.take(limit).toList();
    } else {
      page = sorted
          .where((f) => f.telegramMessageId < offsetId)
          .take(limit)
          .toList();
    }

    pageRequests.add((
      offsetId: offsetId,
      limit: limit,
      returnedCount: page.length,
    ));

    return page;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  FlutterSecureStorage.setMockInitialValues({});

  late Database testDb;
  late NuvexDatabase nuvexDb;

  setUp(() async {
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
    await testDb.close();
  });

  testWidgets(
    'Multi-page Telegram pagination syncs and renders exactly 100 photos',
    (WidgetTester tester) async {
      await tester.runAsync(() async {
        // 1. Generate exactly 100 photo files with descending message IDs (200 down to 101)
        final List<RemoteFile> hundredPhotos = List.generate(100, (i) {
          final msgId = 200 - i;
          final timestamp = DateTime(2026, 1, 1).add(Duration(minutes: msgId));
          return RemoteFile(
            id: msgId,
            telegramChatId: 1001,
            telegramMessageId: msgId,
            telegramFileId: msgId * 10,
            name: 'photo_$msgId.jpg',
            mimeType: 'image/jpeg',
            sizeBytes: 1024 * 500, // 500 KB
            createdAt: timestamp,
            modifiedAt: timestamp,
            category: 'photos',
          );
        });

        expect(hundredPhotos.length, 100);

        // 2. Setup mock Telegram service with page size = 30
        // To fetch 100 items with page size 30, it requires 4 pages (30 + 30 + 30 + 10 = 100)
        final mockService = PaginatedMockMediaService(
          allPhotos: hundredPhotos,
          pageSize: 30,
        );

        final repo = MediaRepository(
          database: nuvexDb,
          mediaService: mockService,
        );

        final controller = MediaController(repository: repo);

        // 3. Trigger full sync
        await controller.syncMedia();

        // 4. VERIFY: Pages fetched
        print('\n=== PAGINATION VERIFICATION REPORT ===');
        print('Telegram pages fetched: ${mockService.pageRequests.length}');
        for (int p = 0; p < mockService.pageRequests.length; p++) {
          final req = mockService.pageRequests[p];
          print(
            '  Page ${p + 1}: offsetId=${req.offsetId}, limit=${req.limit}, returned=${req.returnedCount}',
          );
        }
        expect(
          mockService.pageRequests.length,
          4,
          reason: '100 items / 30 per page must fetch 4 pages',
        );

        // 5. VERIFY: Media extracted
        print(
          'Media extracted from Telegram: ${controller.recentMedia.length}',
        );
        expect(
          controller.recentMedia.length,
          100,
          reason: 'All 100 photos must be extracted',
        );

        // 6. VERIFY: Local SQLite database count
        final dbCountRes = await testDb.rawQuery(
          'SELECT COUNT(*) as count FROM remote_files',
        );
        final dbCount = (dbCountRes.first['count'] as num).toInt();
        print('Database count: $dbCount');
        expect(
          dbCount,
          100,
          reason: 'SQLite database must contain exactly 100 rows',
        );

        // 7. VERIFY: Gallery query count
        final galleryFiles = await repo.getCachedRecentMedia();
        print('Gallery query count: ${galleryFiles.length}');
        expect(
          galleryFiles.length,
          100,
          reason:
              'Gallery query must return all 100 files without 30 or 50 limits',
        );

        // 8. VERIFY: Ordering is preserved newest-to-oldest (ID 200 down to 101)
        expect(controller.recentMedia.first.telegramMessageId, 200);
        expect(controller.recentMedia.last.telegramMessageId, 101);

        // 9. VERIFY: UI rendering in PhotosScreen
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

        // Verify GridView has 100 items
        final gridFinder = find.byType(GridView);
        expect(gridFinder, findsOneWidget);

        final grid = tester.widget<GridView>(gridFinder);
        final delegate = grid.childrenDelegate as SliverChildBuilderDelegate;
        print('UI rendered count in GridView: ${delegate.estimatedChildCount}');
        expect(
          delegate.estimatedChildCount,
          100,
          reason: 'PhotosScreen GridView must have itemCount == 100',
        );
        print('All 100 photos visible: YES\n');
      });
    },
  );
}
