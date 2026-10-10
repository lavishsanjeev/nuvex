import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuvex/core/database/nuvex_database.dart';
import 'package:nuvex/core/database/remote_file.dart';
import 'package:nuvex/features/home/controllers/media_controller.dart';
import 'package:nuvex/features/home/repositories/media_repository.dart';
import 'package:nuvex/telegram/telegram_media_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class MockTrashTelegramMediaService extends TelegramMediaService {
  final Set<int> deletedTelegramMessageIds = {};
  bool shouldFailDeletion = false;

  MockTrashTelegramMediaService();

  @override
  Future<bool> deleteMessage({
    required int messageId,
    bool revoke = true,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (shouldFailDeletion) {
      throw Exception('MTProto RPC error: MESSAGE_ID_INVALID');
    }
    deletedTelegramMessageIds.add(messageId);
    return true;
  }

  @override
  Future<List<RemoteFile>> fetchSavedMessagesPage({
    int offsetId = 0,
    int limit = 30,
    String? thumbsDir,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    return [];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database testDb;
  late NuvexDatabase nuvexDb;
  late Directory tempDir;
  late MockTrashTelegramMediaService mockMediaService;
  late MediaRepository repository;
  late MediaController controller;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('nuvex_trash_test_');

    testDb = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          // Simulate legacy schema (version 1) without isTrashed or trashedAt
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

    mockMediaService = MockTrashTelegramMediaService();
    repository = MediaRepository(
      mediaService: mockMediaService,
      database: nuvexDb,
    );
    controller = MediaController(repository: repository);
  });

  tearDown(() async {
    controller.dispose();
    await nuvexDb.close();
    await testDb.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  RemoteFile createSampleFile({
    required int id,
    String name = 'photo.jpg',
    String category = 'photos',
    DateTime? createdAt,
    bool isTrashed = false,
    DateTime? trashedAt,
    String? localPath,
  }) {
    final now = DateTime.now();
    return RemoteFile(
      id: id,
      telegramChatId: 123456,
      telegramMessageId: id,
      telegramFileId: id,
      name: name,
      mimeType: 'image/jpeg',
      sizeBytes: 1024 * 1024,
      createdAt: createdAt ?? now,
      modifiedAt: createdAt ?? now,
      category: category,
      isTrashed: isTrashed,
      trashedAt: trashedAt,
      localPath: localPath,
    );
  }

  group('Nuvex Trash System Tests', () {
    test('existing media is unaffected by database migration (defaults isTrashed = 0)', () async {
      // Direct raw insert into legacy table with null isTrashed
      await testDb.rawInsert('''
        INSERT INTO remote_files (
          telegramChatId, telegramMessageId, telegramFileId, name, mimeType,
          sizeBytes, createdAt, modifiedAt, remoteAvailable, isFavorite,
          isArchived, isLocked, category
        ) VALUES (
          123456, 999, 999, 'legacy.jpg', 'image/jpeg',
          1024, 1600000000000, 1600000000000, 1, 0,
          0, 0, 'photos'
        )
      ''');

      // Query via NuvexDatabase API
      final recent = await nuvexDb.getRecentMedia();
      expect(recent.length, 1);
      expect(recent.first.telegramMessageId, 999);
      expect(recent.first.isTrashed, isFalse);
      expect(recent.first.trashedAt, isNull);
    });

    test(
      'delete -> item enters Trash with isTrashed = 1 and trashedAt timestamp',
      () async {
        final file = createSampleFile(id: 101, name: 'sunset.jpg');
        await nuvexDb.upsertFiles([file]);

        final beforeTrash = await nuvexDb.getRecentMedia();
        expect(beforeTrash.length, 1);

        final nowMs = DateTime.now().millisecondsSinceEpoch;
        await nuvexDb.moveToTrash(file.telegramMessageId, trashedAtMs: nowMs);

        final trashedList = await nuvexDb.getTrashedMedia();
        expect(trashedList.length, 1);
        expect(trashedList.first.telegramMessageId, 101);
        expect(trashedList.first.isTrashed, isTrue);
        expect(trashedList.first.trashedAt?.millisecondsSinceEpoch, nowMs);
      },
    );

    test('trashed item disappears from Photos and normal queries', () async {
      final f1 = createSampleFile(id: 101, name: 'active.jpg');
      final f2 = createSampleFile(id: 102, name: 'to_trash.jpg');
      await nuvexDb.upsertFiles([f1, f2]);

      // Move f2 to trash
      await nuvexDb.moveToTrash(102);

      // Normal Photos query excludes trashed
      final recent = await nuvexDb.getRecentMedia();
      expect(recent.length, 1);
      expect(recent.first.telegramMessageId, 101);

      // Category query excludes trashed
      final photos = await nuvexDb.getFilesByCategory('photos');
      expect(photos.length, 1);
      expect(photos.first.telegramMessageId, 101);
    });

    test('Trash queries include ONLY Trash items', () async {
      final f1 = createSampleFile(id: 201, name: 'active.jpg');
      final f2 = createSampleFile(id: 202, name: 'trashed.jpg');
      await nuvexDb.upsertFiles([f1, f2]);
      await nuvexDb.moveToTrash(202);

      final trashed = await nuvexDb.getTrashedMedia();
      expect(trashed.length, 1);
      expect(trashed.first.telegramMessageId, 202);

      final trashFromCategory = await nuvexDb.getFilesByCategory(
        'recently_deleted',
      );
      expect(trashFromCategory.length, 1);
      expect(trashFromCategory.first.telegramMessageId, 202);
    });

    test(
      'Trash count is accurate across database and collections count',
      () async {
        final f1 = createSampleFile(id: 301);
        final f2 = createSampleFile(id: 302);
        final f3 = createSampleFile(id: 303);
        await nuvexDb.upsertFiles([f1, f2, f3]);

        expect(await nuvexDb.getTrashedCount(), 0);

        await nuvexDb.moveToTrash(301);
        await nuvexDb.moveToTrash(302);

        expect(await nuvexDb.getTrashedCount(), 2);

        final counts = await nuvexDb.getCollectionCounts();
        expect(counts['recently_deleted'], 2);
        expect(counts['trash'], 2);
        final activePhotos = await nuvexDb.getFilesByCategory('photos');
        expect(activePhotos.length, 1); // Only 1 active photo left
      },
    );

    test(
      'restore -> item returns to Photos and Collections with isTrashed = 0',
      () async {
        final file = createSampleFile(id: 401, name: 'restore_me.jpg');
        await nuvexDb.upsertFiles([file]);
        await nuvexDb.moveToTrash(401);

        // Verify in trash
        expect(await nuvexDb.getTrashedCount(), 1);
        expect((await nuvexDb.getRecentMedia()).isEmpty, isTrue);

        // Restore
        await nuvexDb.restoreFromTrash(401);

        // Verify no longer in trash
        expect(await nuvexDb.getTrashedCount(), 0);

        // Verify back in Photos
        final recent = await nuvexDb.getRecentMedia();
        expect(recent.length, 1);
        expect(recent.first.telegramMessageId, 401);
        expect(recent.first.isTrashed, isFalse);
        expect(recent.first.trashedAt, isNull);
      },
    );

    test('permanent delete -> local record and cache removed ONLY after Telegram deletion succeeds', () async {
      final fakeCacheFile = File('${tempDir.path}/nuvex_media/501_photo.jpg')
        ..createSync(recursive: true);
      fakeCacheFile.writeAsStringSync('dummy-cached-bytes');

      final file = createSampleFile(
        id: 501,
        name: 'photo.jpg',
        localPath: fakeCacheFile.path,
      );
      await nuvexDb.upsertFiles([file]);
      await nuvexDb.moveToTrash(501);

      // Execute permanent delete
      await repository.permanentlyDeleteMedia(file);

      // Verify Telegram deletion succeeded
      expect(mockMediaService.deletedTelegramMessageIds, contains(501));

      // Verify local database record deleted
      final trashed = await nuvexDb.getTrashedMedia();
      expect(trashed.any((f) => f.telegramMessageId == 501), isFalse);

      // Verify cache deleted
      expect(fakeCacheFile.existsSync(), isFalse);
    });

    test('Telegram deletion failure keeps item in Trash and does NOT remove local record', () async {
      final fakeCacheFile = File('${tempDir.path}/nuvex_media/601_photo.jpg')
        ..createSync(recursive: true);
      fakeCacheFile.writeAsStringSync('dummy-cached-bytes');

      final file = createSampleFile(
        id: 601,
        name: 'photo.jpg',
        localPath: fakeCacheFile.path,
      );
      await nuvexDb.upsertFiles([file]);
      await nuvexDb.moveToTrash(601);

      // Simulate Telegram failure
      mockMediaService.shouldFailDeletion = true;

      // Attempt permanent delete; should throw
      expect(
        () => repository.permanentlyDeleteMedia(file),
        throwsA(isA<Exception>()),
      );

      // Item MUST remain in Trash
      final trashed = await nuvexDb.getTrashedMedia();
      expect(trashed.length, 1);
      expect(trashed.first.telegramMessageId, 601);
      expect(trashed.first.isTrashed, isTrue);

      // Cache file MUST still be intact
      expect(fakeCacheFile.existsSync(), isTrue);
    });

    test('30-day expiry calculation calculates remaining days correctly', () {
      final now = DateTime.now();

      // Trashed today (0 days elapsed) -> 30 days remaining
      final fToday = createSampleFile(id: 701, isTrashed: true, trashedAt: now);
      expect(fToday.daysRemainingInTrash, 30);
      expect(fToday.isExpiredInTrash, isFalse);

      // Trashed 10 days ago -> 20 days remaining
      final f10Days = createSampleFile(
        id: 702,
        isTrashed: true,
        trashedAt: now.subtract(const Duration(days: 10)),
      );
      expect(f10Days.daysRemainingInTrash, 20);
      expect(f10Days.isExpiredInTrash, isFalse);

      // Trashed 30 days ago -> 0 days remaining
      final f30Days = createSampleFile(
        id: 703,
        isTrashed: true,
        trashedAt: now.subtract(const Duration(days: 30)),
      );
      expect(f30Days.daysRemainingInTrash, 0);
      expect(f30Days.isExpiredInTrash, isTrue);

      // Trashed 35 days ago -> expired (0 days remaining)
      final f35Days = createSampleFile(
        id: 704,
        isTrashed: true,
        trashedAt: now.subtract(const Duration(days: 35)),
      );
      expect(f35Days.daysRemainingInTrash, 0);
      expect(f35Days.isExpiredInTrash, isTrue);
    });

    test('cleanupExpiredTrash automatically deletes only items exceeding 30-day retention', () async {
      final now = DateTime.now();

      // Fresh trashed item (10 days old)
      final fFresh = createSampleFile(
        id: 801,
        isTrashed: true,
        trashedAt: now.subtract(const Duration(days: 10)),
      );

      // Expired trashed item (31 days old)
      final fExpired = createSampleFile(
        id: 802,
        isTrashed: true,
        trashedAt: now.subtract(const Duration(days: 31)),
      );

      await nuvexDb.upsertFiles([fFresh, fExpired]);

      // Run cleanup
      final cleanedCount = await repository.cleanupExpiredTrash();
      expect(cleanedCount, 1);

      // Telegram deletion executed for expired item only
      expect(mockMediaService.deletedTelegramMessageIds, contains(802));
      expect(mockMediaService.deletedTelegramMessageIds.contains(801), isFalse);

      // Database should only have fFresh in trash
      final remainingTrash = await nuvexDb.getTrashedMedia();
      expect(remainingTrash.length, 1);
      expect(remainingTrash.first.telegramMessageId, 801);
    });

    test('MediaController moveToTrash and restoreFromTrash updates reactive gallery state', () async {
      final f1 = createSampleFile(id: 901);
      final f2 = createSampleFile(id: 902);
      await nuvexDb.upsertFiles([f1, f2]);

      await controller.loadCacheOnly();
      expect(controller.recentMedia.length, 2);

      // Move f2 to trash
      await controller.moveToTrash(f2);
      expect(controller.recentMedia.length, 1);
      expect(controller.recentMedia.first.telegramMessageId, 901);
      expect(controller.collectionCounts['recently_deleted'], 1);

      // Restore f2
      await controller.restoreFromTrash(f2);
      expect(controller.recentMedia.length, 2);
      expect(controller.collectionCounts['recently_deleted'], 0);
    });
  });
}
