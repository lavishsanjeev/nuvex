import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuvex/core/database/nuvex_database.dart';
import 'package:nuvex/core/database/remote_file.dart';
import 'package:nuvex/features/home/collections_screen.dart';
import 'package:nuvex/features/home/controllers/media_controller.dart';
import 'package:nuvex/features/home/models/collection_preview.dart';
import 'package:nuvex/features/home/repositories/media_repository.dart';
import 'package:nuvex/features/home/services/collection_thumbnail_resolver.dart';
import 'package:nuvex/features/home/widgets/collection_card.dart';
import 'package:nuvex/telegram/telegram_auth_service.dart';
import 'package:nuvex/telegram/telegram_media_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class MockAuthService extends TelegramAuthService {
  MockAuthService() : super.create();
  @override
  Future<bool> ensureConnected() async => false;
}

class MockTelegramMediaService extends TelegramMediaService {
  int downloadThumbnailCallCount = 0;

  MockTelegramMediaService() : super(authService: MockAuthService());

  @override
  Future<File> downloadThumbnailFile({
    required RemoteFile file,
    required String destinationPath,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    downloadThumbnailCallCount++;
    final f = File(destinationPath);
    if (!f.parent.existsSync()) {
      f.parent.createSync(recursive: true);
    }
    // Valid 1x1 transparent PNG
    await f.writeAsBytes(const [
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database testDb;
  late NuvexDatabase nuvexDb;
  late MediaRepository repository;
  late MockTelegramMediaService mockMediaService;
  late MediaController mediaController;
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('nuvex_test_thumbs_');
    final databaseFactory = databaseFactoryFfi;
    testDb = await databaseFactory.openDatabase(inMemoryDatabasePath);
    nuvexDb = NuvexDatabase();
    await nuvexDb.initialize(overrideDb: testDb);

    mockMediaService = MockTelegramMediaService();
    repository = MediaRepository(
      database: nuvexDb,
      mediaService: mockMediaService,
    );
    mediaController = MediaController(repository: repository);
  });

  tearDown(() async {
    await nuvexDb.close();
    await testDb.close();
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {
      // Ignore Windows file lock from image decoding
    }
  });

  group('Collection Classification & Database Queries', () {
    test(
      'getRepresentativeFile returns null when collections are empty',
      () async {
        expect(await nuvexDb.getRepresentativeFile('documents'), isNull);
        expect(await nuvexDb.getRepresentativeFile('places'), isNull);
        expect(await nuvexDb.getRepresentativeFile('stickers'), isNull);
        expect(await nuvexDb.getRepresentativeFile('moments'), isNull);
      },
    );

    test('documents: resolves most recent document, preferring items with thumbnail', () async {
      final doc1 = RemoteFile(
        id: 1,
        telegramChatId: 0,
        telegramMessageId: 1,
        telegramFileId: 1,
        name: 'invoice.pdf',
        mimeType: 'application/pdf',
        sizeBytes: 1024,
        createdAt: DateTime(2026, 1, 1),
        modifiedAt: DateTime(2026, 1, 1),
        thumbnailPath: '${tempDir.path}/doc1_thumb.jpg',
        category: 'documents',
      );

      final doc2 = RemoteFile(
        id: 2,
        telegramChatId: 0,
        telegramMessageId: 2,
        telegramFileId: 2,
        name: 'notes.txt',
        mimeType: 'text/plain',
        sizeBytes: 256,
        createdAt: DateTime(2026, 1, 2),
        modifiedAt: DateTime(2026, 1, 2),
        thumbnailPath: null,
        category: 'documents',
      );

      await nuvexDb.upsertFiles([doc1, doc2]);

      final rep = await nuvexDb.getRepresentativeFile('documents');
      expect(rep, isNotNull);
      // Prefers doc1 because it has an explicit thumbnail
      expect(rep!.id, 1);
      expect(rep.thumbnailPath, '${tempDir.path}/doc1_thumb.jpg');
    });

    test(
      'places: resolves newest item with valid geographic coordinates',
      () async {
        final photoNoGeo = RemoteFile(
          id: 10,
          telegramChatId: 0,
          telegramMessageId: 10,
          telegramFileId: 10,
          name: 'photo.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 5000,
          createdAt: DateTime(2026, 2, 2),
          modifiedAt: DateTime(2026, 2, 2),
          category: 'photos',
        );

        final photoWithGeo = RemoteFile(
          id: 11,
          telegramChatId: 0,
          telegramMessageId: 11,
          telegramFileId: 11,
          name: 'eiffel_tower.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 8000,
          createdAt: DateTime(2026, 2, 1),
          modifiedAt: DateTime(2026, 2, 1),
          latitude: 48.8584,
          longitude: 2.2945,
          thumbnailPath: '${tempDir.path}/eiffel_thumb.jpg',
          category: 'photos',
        );

        await nuvexDb.upsertFiles([photoNoGeo, photoWithGeo]);

        final rep = await nuvexDb.getRepresentativeFile('places');
        expect(rep, isNotNull);
        expect(rep!.id, 11);
        expect(rep.latitude, 48.8584);
        expect(rep.longitude, 2.2945);
      },
    );

    test('stickers: resolves newest Telegram sticker', () async {
      final sticker = RemoteFile(
        id: 20,
        telegramChatId: 0,
        telegramMessageId: 20,
        telegramFileId: 20,
        name: 'happy_cat.webp',
        mimeType: 'image/webp',
        sizeBytes: 15000,
        createdAt: DateTime(2026, 3, 1),
        modifiedAt: DateTime(2026, 3, 1),
        thumbnailPath: '${tempDir.path}/cat_thumb.jpg',
        category: 'stickers',
      );

      await nuvexDb.upsertFiles([sticker]);

      final rep = await nuvexDb.getRepresentativeFile('stickers');
      expect(rep, isNotNull);
      expect(rep!.id, 20);
      expect(rep.category, 'stickers');
    });

    test('moments: resolves newest moment when present', () async {
      final moment = RemoteFile(
        id: 30,
        telegramChatId: 0,
        telegramMessageId: 30,
        telegramFileId: 30,
        name: 'trip_moment.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 25000,
        createdAt: DateTime(2026, 4, 1),
        modifiedAt: DateTime(2026, 4, 1),
        thumbnailPath: '${tempDir.path}/moment_thumb.jpg',
        category: 'moments',
      );

      await nuvexDb.upsertFiles([moment]);

      final rep = await nuvexDb.getRepresentativeFile('moments');
      expect(rep, isNotNull);
      expect(rep!.id, 30);
      expect(rep.category, 'moments');
    });
  });

  group('CollectionThumbnailResolver & Cache Reuse', () {
    test(
      'resolves thumbnail path from disk cache without network requests',
      () async {
        final thumbFile = File('${tempDir.path}/cached_thumb.jpg');
        await thumbFile.writeAsBytes(List.filled(150, 0x11));

        final file = RemoteFile(
          id: 50,
          telegramChatId: 0,
          telegramMessageId: 50,
          telegramFileId: 50,
          name: 'doc.pdf',
          mimeType: 'application/pdf',
          sizeBytes: 2048,
          createdAt: DateTime.now(),
          modifiedAt: DateTime.now(),
          thumbnailPath: thumbFile.path,
          category: 'documents',
        );

        await nuvexDb.upsertFiles([file]);

        final resolver = CollectionThumbnailResolver(repository: repository);
        final resolved = await resolver.resolveAllThumbnails(autoFetch: false);

        expect(resolved['documents'], thumbFile.path);
        // Ensure zero network calls were made
        expect(mockMediaService.downloadThumbnailCallCount, 0);
      },
    );

    test('returns null cleanly when collection is empty', () async {
      final resolver = CollectionThumbnailResolver(repository: repository);
      final resolved = await resolver.resolveAllThumbnails(autoFetch: false);

      expect(resolved['documents'], isNull);
      expect(resolved['places'], isNull);
      expect(resolved['stickers'], isNull);
      expect(resolved['moments'], isNull);
    });
  });

  group('MediaController Real-Time Updates', () {
    test('loadCacheOnly updates collection counts and thumbnails', () async {
      final thumbFile = File('${tempDir.path}/doc_thumb.jpg');
      await thumbFile.writeAsBytes(List.filled(120, 0x22));

      final doc = RemoteFile(
        id: 100,
        telegramChatId: 0,
        telegramMessageId: 100,
        telegramFileId: 100,
        name: 'contract.pdf',
        mimeType: 'application/pdf',
        sizeBytes: 4096,
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
        thumbnailPath: thumbFile.path,
        category: 'documents',
      );

      await nuvexDb.upsertFiles([doc]);

      bool notified = false;
      mediaController.addListener(() => notified = true);

      await mediaController.loadCacheOnly();

      expect(notified, isTrue);
      expect(mediaController.collectionCounts['documents'], 1);
      expect(mediaController.collectionThumbnails['documents'], thumbFile.path);
      expect(mediaController.collectionCounts['places'], 0);
      expect(mediaController.collectionThumbnails['places'], isNull);
    });
  });

  group('CollectionCard UI & Fallback Behavior', () {
    testWidgets(
      'renders empty/default state with count and icon when no thumbnail',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: CollectionCard(
                title: 'Documents',
                icon: Icons.description_outlined,
                iconColor: Color(0xFF2563EB),
                badgeBackground: Color(0xFFEFF6FF),
                count: 13,
                thumbnailPath: null,
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('Documents'), findsOneWidget);
        expect(find.text('13'), findsOneWidget);
        expect(find.byIcon(Icons.description_outlined), findsOneWidget);
        expect(find.byType(Image), findsNothing);
      },
    );

    testWidgets('renders image layer and scrim when thumbnail is present', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CollectionCard(
              title: 'Places',
              icon: Icons.place_outlined,
              iconColor: Color(0xFF059669),
              badgeBackground: Color(0xFFECFDF5),
              count: 5,
              thumbnailWidget: SizedBox(key: Key('thumb_widget')),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Places'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
      expect(find.byKey(const Key('thumb_widget')), findsOneWidget);
    });

    testWidgets(
      'falls back safely when thumbnail file does not exist on disk',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CollectionCard(
                title: 'Stickers',
                icon: Icons.sentiment_satisfied_alt_outlined,
                iconColor: const Color(0xFF7C3AED),
                badgeBackground: const Color(0xFFF5F3FF),
                count: 2,
                thumbnailPath: '${tempDir.path}/non_existent.jpg',
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('Stickers'), findsOneWidget);
        expect(find.text('2'), findsOneWidget);
        expect(find.byType(Image), findsNothing);
      },
    );
  });

  group('CollectionsScreen Integration', () {
    testWidgets('CollectionsScreen renders 4 primary cards with real data', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final doc = RemoteFile(
          id: 201,
          telegramChatId: 0,
          telegramMessageId: 201,
          telegramFileId: 201,
          name: 'readme.pdf',
          mimeType: 'application/pdf',
          sizeBytes: 1024,
          createdAt: DateTime.now(),
          modifiedAt: DateTime.now(),
          thumbnailPath: null,
          category: 'documents',
        );

        await nuvexDb.upsertFiles([doc]);
        await mediaController.loadCacheOnly();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CollectionsScreen(mediaController: mediaController),
            ),
          ),
        );
        await tester.pump();
        await Future.delayed(const Duration(milliseconds: 50));
        await tester.pump();

        expect(find.text('Collections'), findsOneWidget);
        expect(find.text('Documents'), findsOneWidget);
        expect(find.text('Places'), findsOneWidget);
        expect(find.text('Stickers'), findsOneWidget);
        expect(find.text('Moments'), findsOneWidget);

        // Documents card has real count 1
        expect(
          find.descendant(
            of: find.widgetWithText(CollectionCard, 'Documents'),
            matching: find.text('1'),
          ),
          findsOneWidget,
        );
      });
    });
  });

  group('CollectionPreview Model Tests', () {
    test('instantiates with required properties and correct getters', () {
      final preview = CollectionPreview(
        category: 'documents',
        title: 'Documents',
        itemCount: 42,
        thumbnailPath: '/path/to/thumb.jpg',
        fallbackIcon: Icons.description_outlined,
        iconColor: const Color(0xFF2563EB),
        badgeBackground: const Color(0xFFEFF6FF),
      );

      expect(preview.category, 'documents');
      expect(preview.title, 'Documents');
      expect(preview.itemCount, 42);
      expect(preview.hasThumbnail, isTrue);
      expect(preview.isLoading, isFalse);

      final copy = preview.copyWith(itemCount: 43, isLoading: true);
      expect(copy.itemCount, 43);
      expect(copy.isLoading, isTrue);
      expect(copy.title, 'Documents');
    });

    test('hasThumbnail is false when thumbnailPath is null or empty', () {
      const p1 = CollectionPreview(
        category: 'places',
        title: 'Places',
        itemCount: 0,
        thumbnailPath: null,
        fallbackIcon: Icons.place_outlined,
        iconColor: Color(0xFF059669),
        badgeBackground: Color(0xFFECFDF5),
      );
      expect(p1.hasThumbnail, isFalse);

      final p2 = p1.copyWith(thumbnailPath: '   ');
      expect(p2.hasThumbnail, isFalse);
    });
  });

  group('Google-Photos-Style Visual Card Design Tests', () {
    testWidgets(
      'when thumbnail exists, icon is hidden and gradient overlay + white text rendered',
      (tester) async {
        const preview = CollectionPreview(
          category: 'documents',
          title: 'Documents',
          itemCount: 7,
          thumbnailPath: '/cached/doc_thumb.jpg',
          fallbackIcon: Icons.description_outlined,
          iconColor: Color(0xFF2563EB),
          badgeBackground: Color(0xFFEFF6FF),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CollectionCard.fromPreview(
                preview,
                thumbnailWidget: const SizedBox(key: Key('thumb_widget')),
              ),
            ),
          ),
        );
        await tester.pump();

        // Title & count are present
        expect(find.text('Documents'), findsOneWidget);
        expect(find.text('7'), findsOneWidget);

        // Category icon is HIDDEN because real thumbnail exists
        expect(find.byIcon(Icons.description_outlined), findsNothing);

        // Real thumbnail widget is present
        expect(find.byKey(const Key('thumb_widget')), findsOneWidget);

        // Text colors are white
        final titleWidget = tester.widget<Text>(find.text('Documents'));
        expect(titleWidget.style?.color, Colors.white);

        final countWidget = tester.widget<Text>(find.text('7'));
        expect(countWidget.style?.color, isNotNull);
        expect(countWidget.style!.color!.a, greaterThan(0.8));
      },
    );

    testWidgets(
      'when thumbnail is absent, clean fallback Nuvex card with icon is rendered',
      (tester) async {
        const preview = CollectionPreview(
          category: 'stickers',
          title: 'Stickers',
          itemCount: 0,
          thumbnailPath: null,
          fallbackIcon: Icons.sentiment_satisfied_alt_outlined,
          iconColor: Color(0xFF7C3AED),
          badgeBackground: Color(0xFFF5F3FF),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: CollectionCard.fromPreview(preview)),
          ),
        );
        await tester.pump();

        // Title is present
        expect(find.text('Stickers'), findsOneWidget);

        // Icon IS rendered
        expect(
          find.byIcon(Icons.sentiment_satisfied_alt_outlined),
          findsOneWidget,
        );

        // Image is NOT rendered
        expect(find.byType(Image), findsNothing);
      },
    );
  });

  group('Dynamic Moments Time Clustering Tests', () {
    test(
      'clusters recent photos into meaningful date moment and counts items',
      () async {
        final dateMoment1 = DateTime(2026, 3, 10, 14, 30);
        final dateMoment2 = DateTime(2026, 3, 10, 15, 45);
        final oldDate = DateTime(2026, 1, 1, 10, 0);

        final p1 = RemoteFile(
          id: 301,
          telegramChatId: 0,
          telegramMessageId: 301,
          telegramFileId: 301,
          name: 'beach1.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 1000,
          createdAt: dateMoment1,
          modifiedAt: dateMoment1,
          thumbnailPath: '${tempDir.path}/beach1_thumb.jpg',
          category: 'photos',
        );

        final p2 = RemoteFile(
          id: 302,
          telegramChatId: 0,
          telegramMessageId: 302,
          telegramFileId: 302,
          name: 'beach2.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 1200,
          createdAt: dateMoment2,
          modifiedAt: dateMoment2,
          thumbnailPath: null,
          category: 'photos',
        );

        final oldPhoto = RemoteFile(
          id: 300,
          telegramChatId: 0,
          telegramMessageId: 300,
          telegramFileId: 300,
          name: 'old_photo.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 800,
          createdAt: oldDate,
          modifiedAt: oldDate,
          thumbnailPath: null,
          category: 'photos',
        );

        await nuvexDb.upsertFiles([oldPhoto, p1, p2]);

        final counts = await nuvexDb.getCollectionCounts();
        // The current moment has the 2 photos from March 10, 2026
        expect(counts['moments'], 2);

        final rep = await nuvexDb.getRepresentativeFile('moments');
        expect(rep, isNotNull);
        // Prefers p1 because it has an explicit thumbnail
        expect(rep!.id, 301);

        final momentFiles = await nuvexDb.getFilesByCategory('moments');
        expect(momentFiles.length, 2);
        expect(momentFiles.map((f) => f.id), containsAll([301, 302]));
      },
    );

    test('returns null representative and 0 count when no media exists for moments', () async {
      final counts = await nuvexDb.getCollectionCounts();
      expect(counts['moments'], 0);

      final rep = await nuvexDb.getRepresentativeFile('moments');
      expect(rep, isNull);

      final files = await nuvexDb.getFilesByCategory('moments');
      expect(files, isEmpty);
    });
  });

  group('Strict Location Detection (Places) Tests', () {
    test('never infers location merely from filename', () async {
      final fakeNamedPhoto = RemoteFile(
        id: 401,
        telegramChatId: 0,
        telegramMessageId: 401,
        telegramFileId: 401,
        name: 'paris_france_eiffel_tower.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 5000,
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
        latitude: null, // No actual geographic coordinates
        longitude: null,
        category: 'photos',
      );

      await nuvexDb.upsertFiles([fakeNamedPhoto]);

      final counts = await nuvexDb.getCollectionCounts();
      expect(counts['places'], 0);

      final rep = await nuvexDb.getRepresentativeFile('places');
      expect(rep, isNull);

      final files = await nuvexDb.getFilesByCategory('places');
      expect(files, isEmpty);
    });

    test('detects real geographic coordinates for Places', () async {
      final realGeoPhoto = RemoteFile(
        id: 402,
        telegramChatId: 0,
        telegramMessageId: 402,
        telegramFileId: 402,
        name: 'IMG_2026.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 5000,
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
        latitude: 37.7749,
        longitude: -122.4194,
        thumbnailPath: '${tempDir.path}/sf_thumb.jpg',
        category: 'photos',
      );

      await nuvexDb.upsertFiles([realGeoPhoto]);

      final counts = await nuvexDb.getCollectionCounts();
      expect(counts['places'], 1);

      final rep = await nuvexDb.getRepresentativeFile('places');
      expect(rep, isNotNull);
      expect(rep!.id, 402);
      expect(rep.latitude, 37.7749);
    });
  });

  group('User-Specific Data Isolation Tests', () {
    test('different user datasets produce completely different collections and counts', () async {
      // User A dataset: 3 documents, 1 sticker, 0 places
      final userADoc1 = RemoteFile(
        id: 501,
        telegramChatId: 0,
        telegramMessageId: 501,
        telegramFileId: 501,
        name: 'docA1.pdf',
        mimeType: 'application/pdf',
        sizeBytes: 1024,
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
        category: 'documents',
      );
      final userADoc2 = RemoteFile(
        id: 502,
        telegramChatId: 0,
        telegramMessageId: 502,
        telegramFileId: 502,
        name: 'docA2.pdf',
        mimeType: 'application/pdf',
        sizeBytes: 2048,
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
        category: 'documents',
      );
      final userASticker = RemoteFile(
        id: 503,
        telegramChatId: 0,
        telegramMessageId: 503,
        telegramFileId: 503,
        name: 'stickerA.webp',
        mimeType: 'image/webp',
        sizeBytes: 500,
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
        category: 'stickers',
      );

      await nuvexDb.upsertFiles([userADoc1, userADoc2, userASticker]);

      var counts = await nuvexDb.getCollectionCounts();
      expect(counts['documents'], 2);
      expect(counts['stickers'], 1);
      expect(counts['places'], 0);

      // Now simulate a different user database state
      await testDb.delete('remote_files');

      // User B dataset: 0 documents, 0 stickers, 1 place
      final userBPlace = RemoteFile(
        id: 601,
        telegramChatId: 0,
        telegramMessageId: 601,
        telegramFileId: 601,
        name: 'placeB.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 4000,
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
        latitude: 40.7128,
        longitude: -74.0060,
        category: 'photos',
      );

      await nuvexDb.upsertFiles([userBPlace]);

      counts = await nuvexDb.getCollectionCounts();
      expect(counts['documents'], 0);
      expect(counts['stickers'], 0);
      expect(counts['places'], 1);

      // No mock counts or static thumbnails exist
      final repDocs = await nuvexDb.getRepresentativeFile('documents');
      expect(repDocs, isNull);
    });
  });
}
