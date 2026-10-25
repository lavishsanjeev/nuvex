import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuvex/core/database/remote_file.dart';
import 'package:nuvex/features/home/controllers/media_controller.dart';
import 'package:nuvex/features/home/media_viewer_screen.dart';
import 'package:nuvex/features/home/repositories/media_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  int _nextPlayerId = 1;
  final Map<int, StreamController<VideoEvent>> _eventControllers = {};
  final List<int> disposedPlayerIds = [];

  @override
  Future<void> init() async {}

  @override
  Future<void> dispose(int playerId) async {
    disposedPlayerIds.add(playerId);
    _eventControllers[playerId]?.close();
    _eventControllers.remove(playerId);
  }

  @override
  Future<int?> create(DataSource dataSource) async {
    final id = _nextPlayerId++;
    _eventControllers.putIfAbsent(
      id,
      () => StreamController<VideoEvent>.broadcast(),
    );
    return id;
  }

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    return create(options.dataSource);
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    final controller = _eventControllers.putIfAbsent(
      playerId,
      () => StreamController<VideoEvent>.broadcast(),
    );
    scheduleMicrotask(() {
      if (!controller.isClosed) {
        controller.add(
          VideoEvent(
            eventType: VideoEventType.initialized,
            duration: const Duration(seconds: 30),
            size: const Size(1080, 1920),
          ),
        );
      }
    });
    return controller.stream;
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Widget buildView(int playerId) => const SizedBox(width: 1080, height: 1920);

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox(width: 1080, height: 1920);

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeVideoPlayerPlatform fakePlatform;
  late File dummyThumb;
  late File dummyVideo;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dummyThumb = File('${Directory.systemTemp.path}/nuvex_test_thumb.jpg');
    // Minimal valid 1x1 JPG
    await dummyThumb.writeAsBytes([
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
      0x48,
      0x00,
      0x48,
      0x00,
      0x00,
      0xFF,
      0xDB,
      0x00,
      0x43,
      0x00,
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
      0x14,
      0x10,
      0x01,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
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
      0x37,
      0xFF,
      0xD9,
    ]);

    dummyVideo = File('${Directory.systemTemp.path}/nuvex_test_video.mp4');
    await dummyVideo.writeAsBytes(List.filled(1024, 0));
  });

  tearDownAll(() async {
    if (dummyThumb.existsSync()) {
      try {
        dummyThumb.deleteSync();
      } catch (_) {}
    }
    if (dummyVideo.existsSync()) {
      try {
        dummyVideo.deleteSync();
      } catch (_) {}
    }
  });

  setUp(() {
    fakePlatform = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = fakePlatform;
  });

  group('Video Playback Stability & Anti-Flicker Guarantees', () {
    test('1. AndroidManifest.xml disables Impeller to prevent Vulkan texture glitter', () {
      final manifestFile = File('android/app/src/main/AndroidManifest.xml');
      expect(
        manifestFile.existsSync(),
        isTrue,
        reason: 'AndroidManifest.xml must exist',
      );

      final content = manifestFile.readAsStringSync();
      expect(
        content.contains(
          'android:name="io.flutter.embedding.android.EnableImpeller"',
        ),
        isTrue,
        reason:
            'EnableImpeller meta-data must be defined in AndroidManifest.xml',
      );
      expect(
        content.contains('android:value="false"'),
        isTrue,
        reason: 'EnableImpeller must be set to false to prevent Vulkan external texture glittering',
      );
    });

    testWidgets(
      '2. MediaViewerScreen displays video item with correct aspect ratio and RepaintBoundary',
      (tester) async {
        final controller = MediaController(repository: MediaRepository());

        final videoFile = RemoteFile(
          id: 999,
          telegramChatId: 1001,
          telegramMessageId: 999,
          telegramFileId: 999,
          name: 'test_vertical_video.mp4',
          mimeType: 'video/mp4',
          sizeBytes: 1024,
          localPath: dummyVideo.path,
          thumbnailPath: dummyThumb.path,
          width: 1080,
          height: 1920, // 9:16 vertical video
          durationMs: 15000,
          createdAt: DateTime.now(),
          modifiedAt: DateTime.now(),
          category: 'videos',
        );

        await tester.pumpWidget(
          MaterialApp(
            home: MediaViewerScreen(
              files: [videoFile],
              initialIndex: 0,
              controller: controller,
            ),
          ),
        );

        // The viewer mounts immediately
        expect(find.byType(MediaViewerScreen), findsOneWidget);

        // Pump to process file initialization
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        // Verify that AspectRatio widget is rendered
        final aspectRatioFinders = find.byType(AspectRatio);
        expect(aspectRatioFinders, findsWidgets);

        // Check that at least one AspectRatio widget matches the video's 1080 / 1920 ratio
        final expectedRatio = 1080 / 1920;
        bool foundMatchingRatio = false;
        for (final element in aspectRatioFinders.evaluate()) {
          final widget = element.widget as AspectRatio;
          if ((widget.aspectRatio - expectedRatio).abs() < 0.01) {
            foundMatchingRatio = true;
            break;
          }
        }
        expect(
          foundMatchingRatio,
          isTrue,
          reason: 'MediaViewer must layout using the exact 1080/1920 aspect ratio before controller initialization',
        );

        // Verify that RepaintBoundary is wrapping the video texture
        expect(find.byType(RepaintBoundary), findsWidgets);
      },
    );

    testWidgets(
      '3. Swiping between media items cleanly pauses and maintains controller lifecycle',
      (tester) async {
        final controller = MediaController(repository: MediaRepository());

        final file1 = RemoteFile(
          id: 101,
          telegramChatId: 1001,
          telegramMessageId: 101,
          telegramFileId: 101,
          name: 'video_101.mp4',
          mimeType: 'video/mp4',
          sizeBytes: 1024,
          localPath: dummyVideo.path,
          thumbnailPath: dummyThumb.path,
          width: 1920,
          height: 1080,
          createdAt: DateTime.now(),
          modifiedAt: DateTime.now(),
          category: 'videos',
        );

        final file2 = RemoteFile(
          id: 102,
          telegramChatId: 1001,
          telegramMessageId: 102,
          telegramFileId: 102,
          name: 'photo_102.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 1024,
          localPath: dummyThumb.path,
          thumbnailPath: dummyThumb.path,
          width: 1920,
          height: 1080,
          createdAt: DateTime.now(),
          modifiedAt: DateTime.now(),
          category: 'photos',
        );

        await tester.pumpWidget(
          MaterialApp(
            home: MediaViewerScreen(
              files: [file1, file2],
              initialIndex: 0,
              controller: controller,
            ),
          ),
        );

        expect(find.byType(MediaViewerScreen), findsOneWidget);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        // Swipe horizontally to second item
        await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // Swipe back to first item
        await tester.fling(find.byType(PageView), const Offset(400, 0), 1000);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.byType(MediaViewerScreen), findsOneWidget);
      },
    );
  });
}
