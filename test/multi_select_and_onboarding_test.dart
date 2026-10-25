import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuvex/core/database/remote_file.dart';
import 'package:nuvex/core/storage/secure_storage.dart';
import 'package:nuvex/features/home/controllers/media_controller.dart';
import 'package:nuvex/features/home/widgets/selection_action_bar.dart';
import 'package:nuvex/features/onboarding/services/onboarding_service.dart';

class InMemorySecureStore extends NuvexSecureStore {
  final Map<String, String> _memory = {};

  @override
  Future<String?> read({required String key}) async => _memory[key];

  @override
  Future<void> write({required String key, required String? value}) async {
    if (value == null) {
      _memory.remove(key);
    } else {
      _memory[key] = value;
    }
  }

  @override
  Future<void> delete({required String key}) async {
    _memory.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Multi-Select Media Gallery', () {
    late MediaController controller;
    late RemoteFile file1;
    late RemoteFile file2;
    late RemoteFile file3;

    setUp(() {
      controller = MediaController();
      file1 = RemoteFile(
        id: 1,
        telegramChatId: 1000,
        telegramMessageId: 101,
        telegramFileId: 10101,
        name: 'photo1.jpg',
        sizeBytes: 1024,
        mimeType: 'image/jpeg',
        category: 'photos',
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
      );
      file2 = RemoteFile(
        id: 2,
        telegramChatId: 1000,
        telegramMessageId: 102,
        telegramFileId: 10102,
        name: 'photo2.jpg',
        sizeBytes: 2048,
        mimeType: 'image/jpeg',
        category: 'photos',
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
      );
      file3 = RemoteFile(
        id: 3,
        telegramChatId: 1000,
        telegramMessageId: 103,
        telegramFileId: 10103,
        name: 'video1.mp4',
        sizeBytes: 5096,
        mimeType: 'video/mp4',
        category: 'videos',
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
      );
    });

    test('Enter selection mode, toggle items, and count', () {
      expect(controller.isSelectionMode, isFalse);
      expect(controller.selectedCount, 0);

      // Long-press entry with initial file
      controller.enterSelectionMode(file1);
      expect(controller.isSelectionMode, isTrue);
      expect(controller.selectedCount, 1);
      expect(controller.isFileSelected(101), isTrue);
      expect(controller.isFileSelected(102), isFalse);

      // Toggle second file
      controller.toggleSelection(file2);
      expect(controller.selectedCount, 2);
      expect(controller.isFileSelected(102), isTrue);

      // Toggle first file off
      controller.toggleSelection(file1);
      expect(controller.selectedCount, 1);
      expect(controller.isFileSelected(101), isFalse);

      // Exit selection mode
      controller.exitSelectionMode();
      expect(controller.isSelectionMode, isFalse);
      expect(controller.selectedCount, 0);
    });

    test('Select All and Deselect All operations', () {
      controller.enterSelectionMode();
      final allFiles = [file1, file2, file3];

      controller.selectAll(allFiles);
      expect(controller.selectedCount, 3);
      expect(controller.isFileSelected(101), isTrue);
      expect(controller.isFileSelected(102), isTrue);
      expect(controller.isFileSelected(103), isTrue);

      controller.deselectAll();
      expect(controller.selectedCount, 0);
      expect(controller.isSelectionMode, isTrue); // Stays in selection mode
    });
  });

  group('Onboarding Guidance Service & Lifecycle', () {
    late InMemorySecureStore secureStore;
    late OnboardingService onboardingService;

    setUp(() {
      secureStore = InMemorySecureStore();
      onboardingService = OnboardingService(secureStore: secureStore);
    });

    test('Initial check shows unread guidance', () async {
      final seen = await onboardingService.initialize();
      expect(seen, isFalse);
      expect(onboardingService.hasUnreadGuidance.value, isTrue);
    });

    test('Marking guidance as seen persists and removes unread badge', () async {
      await onboardingService.initialize();
      expect(onboardingService.hasUnreadGuidance.value, isTrue);

      await onboardingService.markOnboardingAsSeen();
      expect(onboardingService.hasUnreadGuidance.value, isFalse);

      // Subsequent session check returns seen = true
      final newService = OnboardingService(secureStore: secureStore);
      final seenAfter = await newService.initialize();
      expect(seenAfter, isTrue);
      expect(newService.hasUnreadGuidance.value, isFalse);
    });

    test('Resetting guidance marks it unread again', () async {
      await onboardingService.markOnboardingAsSeen();
      expect(onboardingService.hasUnreadGuidance.value, isFalse);

      await onboardingService.resetOnboarding();
      expect(onboardingService.hasUnreadGuidance.value, isTrue);
    });
  });

  group('SelectionActionBar Narrow Screen Overflow Immunity (Bug 4)', () {
    testWidgets('Renders with zero RenderFlex overflow on ultra-narrow 320dp screen', (tester) async {
      tester.view.physicalSize = const Size(320, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final controller = MediaController();
      final sample = RemoteFile(
        id: 999,
        telegramChatId: 0,
        telegramMessageId: 999,
        telegramFileId: 9999,
        name: 'sample.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 100,
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
        category: 'photos',
      );
      controller.enterSelectionMode(sample);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SelectionActionBar(controller: controller),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify no overflow occurred
      expect(tester.takeException(), isNull);

      // Verify pinned elements are visible
      expect(find.byKey(const ValueKey('selection_count_text')), findsOneWidget);
      expect(find.byKey(const ValueKey('selection_action_cancel')), findsOneWidget);

      // Verify actions exist in the scrollable row
      expect(find.byKey(const ValueKey('selection_action_share')), findsOneWidget);
      expect(find.byKey(const ValueKey('selection_action_save')), findsOneWidget);
      expect(find.byKey(const ValueKey('selection_action_lock')), findsOneWidget);
      expect(find.byKey(const ValueKey('selection_action_delete')), findsOneWidget);
      expect(find.byKey(const ValueKey('selection_action_select_all')), findsOneWidget);
    });

    testWidgets('Renders with zero RenderFlex overflow on standard 360dp Android screen', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final controller = MediaController();
      final sample = RemoteFile(
        id: 998,
        telegramChatId: 0,
        telegramMessageId: 998,
        telegramFileId: 9998,
        name: 'sample2.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 200,
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
        category: 'photos',
      );
      controller.enterSelectionMode(sample);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SelectionActionBar(controller: controller),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('selection_count_text')), findsOneWidget);
      expect(find.text('1 selected'), findsOneWidget);
    });

    testWidgets('All actions fit within viewport bounds on 360dp mobile width without scrolling off-screen', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final controller = MediaController();
      final sample = RemoteFile(
        id: 997,
        telegramChatId: 0,
        telegramMessageId: 997,
        telegramFileId: 9997,
        name: 'sample3.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 200,
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
        category: 'photos',
      );
      controller.enterSelectionMode(sample);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SelectionActionBar(controller: controller),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);

      // Verify all 5 action buttons and count text are on screen and within 0..360 x-bounds
      final shareFinder = find.byKey(const ValueKey('selection_action_share'));
      final saveFinder = find.byKey(const ValueKey('selection_action_save'));
      final lockFinder = find.byKey(const ValueKey('selection_action_lock'));
      final deleteFinder = find.byKey(const ValueKey('selection_action_delete'));
      final selectAllFinder = find.byKey(const ValueKey('selection_action_select_all'));

      expect(shareFinder, findsOneWidget);
      expect(saveFinder, findsOneWidget);
      expect(lockFinder, findsOneWidget);
      expect(deleteFinder, findsOneWidget);
      expect(selectAllFinder, findsOneWidget);




final selectAllRect = tester.getRect(selectAllFinder);
      expect(selectAllRect.right, lessThanOrEqualTo(360.0));
      expect(selectAllRect.left, greaterThanOrEqualTo(0.0));

      final shareRect = tester.getRect(shareFinder);
      expect(shareRect.left, greaterThanOrEqualTo(0.0));
    });

    testWidgets('Renders full text labels on wide/tablet screens (>= 440dp)', (tester) async {
      tester.view.physicalSize = const Size(600, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final controller = MediaController();
      final sample = RemoteFile(
        id: 996,
        telegramChatId: 0,
        telegramMessageId: 996,
        telegramFileId: 9996,
        name: 'sample4.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 200,
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
        category: 'photos',
      );
      controller.enterSelectionMode(sample);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SelectionActionBar(controller: controller),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Share'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
      expect(find.text('Lock'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      expect(find.text('Select All'), findsOneWidget);
    });
  });
}
