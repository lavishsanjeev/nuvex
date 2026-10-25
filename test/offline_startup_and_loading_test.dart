import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuvex/app/router.dart';
import 'package:nuvex/core/database/remote_file.dart';
import 'package:nuvex/core/storage/secure_storage.dart';
import 'package:nuvex/features/auth/controllers/auth_controller.dart';
import 'package:nuvex/features/auth/startup_screen.dart';
import 'package:nuvex/features/home/controllers/media_controller.dart';
import 'package:nuvex/features/home/photos_screen.dart';
import 'package:nuvex/features/home/repositories/media_repository.dart';
import 'package:nuvex/features/home/widgets/nuvex_loading_view.dart';
import 'package:nuvex/telegram/telegram_auth_service.dart';
import 'package:nuvex/telegram/telegram_media_service.dart';
import 'package:nuvex/telegram/telegram_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class InMemorySecureStore extends NuvexSecureStore {
  ({int apiId, String apiHash})? creds;
  String? session;
  String? phone;
  int? dcId;
  String? userData;
  bool wasSessionCleared = false;

  InMemorySecureStore({
    this.creds,
    this.session,
    this.phone,
    this.dcId,
    this.userData,
  });

  @override
  Future<({int apiId, String apiHash})?> getCredentials() async => creds;

  @override
  Future<String?> getSession() async => session;

  @override
  Future<String?> getUserPhone() async => phone;

  @override
  Future<int?> getDcId() async => dcId;

  @override
  Future<String?> getUserData() async => userData;

  @override
  Future<void> saveCredentials({
    required int apiId,
    required String apiHash,
  }) async {
    creds = (apiId: apiId, apiHash: apiHash);
  }

  @override
  Future<void> saveSession(String sessionData) async {
    session = sessionData;
  }

  @override
  Future<void> saveDcId(int dc) async {
    dcId = dc;
  }

  @override
  Future<void> saveUserData(String data) async {
    userData = data;
  }

  @override
  Future<void> saveUserPhone(String p) async {
    phone = p;
  }

  @override
  Future<void> clearSession() async {
    wasSessionCleared = true;
    session = null;
    userData = null;
  }

  @override
  Future<void> clearAll() async {
    wasSessionCleared = true;
    creds = null;
    session = null;
    userData = null;
    phone = null;
  }
}

class FakeOfflineTelegramAuthService extends TelegramAuthService {
  final bool simulateOffline;
  final bool simulateRevokedKey;

  FakeOfflineTelegramAuthService({
    this.simulateOffline = false,
    this.simulateRevokedKey = false,
  }) : super.create();

  @override
  Future<TelegramConnectionResult> connect({
    required int apiId,
    required String apiHash,
    String? savedSessionJson,
    TelegramDc dc = TelegramDc.dc2,
  }) async {
    if (simulateOffline) {
      throw const SocketException('Network is unreachable (OS Error 101)');
    }
    if (simulateRevokedKey) {
      throw Exception(
        'AUTH_KEY_UNREGISTERED: Session was terminated on server',
      );
    }
    return const TelegramConnectionResult.success(dcId: 2, authKeyId: 77777);
  }

  @override
  Future<NuvexTelegramUser?> verifyExistingSession() async {
    if (simulateOffline) {
      throw const SocketException('Network is unreachable');
    }
    return const NuvexTelegramUser(
      id: 12345,
      firstName: 'Verified',
      lastName: 'User',
      username: 'verified_user',
    );
  }
}

class FakeEmptyMediaService extends TelegramMediaService {
  final bool throwNetworkError;

  FakeEmptyMediaService({this.throwNetworkError = false});

  @override
  Future<List<RemoteFile>> fetchSavedMessagesPage({
    int offsetId = 0,
    int limit = 30,
    String? thumbsDir,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (throwNetworkError) {
      throw const SocketException('Network unreachable');
    }
    return [];
  }

  @override
  int get lastTotalMessagesInPage => 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Offline Startup & State Machine Guarantees', () {
    test('1. Restarting app while offline with persisted session preserves authenticated state', () async {
      final savedUser = const NuvexTelegramUser(
        id: 99999,
        firstName: 'Offline',
        lastName: 'Tester',
        username: 'offlinetester',
        phone: '+1234567890',
      );

      final store = InMemorySecureStore(
        creds: (apiId: 12345, apiHash: 'abcdef1234567890'),
        session: '{"key": "test_auth_key"}',
        userData: savedUser.serialize(),
        phone: '+1234567890',
        dcId: 2,
      );

      final fakeAuth = FakeOfflineTelegramAuthService(simulateOffline: true);
      final controller = AuthController(
        telegramService: fakeAuth,
        secureStore: store,
      );

      await controller.initialize();

      // Guarantees:
      // 1. Must be authenticated (NOT dropped to Getting Started)
      expect(controller.isAuthenticated, isTrue);
      expect(controller.status, equals(AuthStatus.authenticated));

      // 2. User profile must be restored from saved data
      expect(controller.currentUser?.id, equals(99999));
      expect(controller.currentUser?.firstName, equals('Offline'));

      // 3. Backend is recognized as offline / unreachable
      expect(controller.isOffline, isTrue);
      expect(controller.isBackendReachable, isFalse);

      // 4. Session credentials MUST NOT be wiped on network error
      expect(store.wasSessionCleared, isFalse);
      expect(store.session, isNotNull);
    });

    test('2. Online startup successfully connects and updates verified user profile', () async {
      final savedUser = const NuvexTelegramUser(
        id: 99999,
        firstName: 'Cached',
        lastName: 'Name',
      );

      final store = InMemorySecureStore(
        creds: (apiId: 12345, apiHash: 'abcdef1234567890'),
        session: '{"key": "test_auth_key"}',
        userData: savedUser.serialize(),
      );

      final fakeAuth = FakeOfflineTelegramAuthService(simulateOffline: false);
      final controller = AuthController(
        telegramService: fakeAuth,
        secureStore: store,
      );

      await controller.initialize();

      expect(controller.isAuthenticated, isTrue);
      expect(controller.isOffline, isFalse);
      expect(controller.isBackendReachable, isTrue);
      expect(controller.currentUser?.firstName, equals('Verified'));
    });

    test('3. Genuine unauthenticated state (no saved credentials/session) routes to ready/onboarding', () async {
      final store = InMemorySecureStore(); // Empty secure store
      final fakeAuth = FakeOfflineTelegramAuthService();
      final controller = AuthController(
        telegramService: fakeAuth,
        secureStore: store,
      );

      await controller.initialize();

      expect(controller.isAuthenticated, isFalse);
      expect(controller.status, equals(AuthStatus.ready));
      expect(controller.currentUser, isNull);
    });

    test('4. Server session revocation (AUTH_KEY_UNREGISTERED) clears session and resets to ready', () async {
      final savedUser = const NuvexTelegramUser(
        id: 99999,
        firstName: 'Revoked',
        lastName: 'User',
      );

      final store = InMemorySecureStore(
        creds: (apiId: 12345, apiHash: 'abcdef1234567890'),
        session: '{"key": "test_revoked_key"}',
        userData: savedUser.serialize(),
      );

      final fakeAuth = FakeOfflineTelegramAuthService(simulateRevokedKey: true);
      final controller = AuthController(
        telegramService: fakeAuth,
        secureStore: store,
      );

      await controller.initialize();

      // Session must be cleared on genuine auth failure
      expect(store.wasSessionCleared, isTrue);
      expect(controller.isAuthenticated, isFalse);
      expect(controller.status, equals(AuthStatus.ready));
    });

    testWidgets(
      '5. StartupScreen routes directly to Home when offline with persisted session',
      (tester) async {
        final savedUser = const NuvexTelegramUser(
          id: 99999,
          firstName: 'Offline',
          lastName: 'User',
        );

        final store = InMemorySecureStore(
          creds: (apiId: 12345, apiHash: 'abcdef1234567890'),
          session: '{"key": "test_key"}',
          userData: savedUser.serialize(),
        );

        final fakeAuth = FakeOfflineTelegramAuthService(simulateOffline: true);
        final controller = AuthController(
          telegramService: fakeAuth,
          secureStore: store,
        );

        await controller.initialize();

        String? pushedRoute;
        await tester.pumpWidget(
          MaterialApp(
            onGenerateRoute: (settings) {
              pushedRoute = settings.name;
              return MaterialPageRoute(builder: (_) => const SizedBox());
            },
            home: StartupScreen(controller: controller),
          ),
        );

        await tester.pumpAndSettle();

        expect(pushedRoute, equals(NuvexRoutes.home));
        expect(pushedRoute, isNot(equals(NuvexRoutes.gettingStarted)));
      },
    );

    testWidgets(
      '6. StartupScreen routes to Getting Started when unauthenticated',
      (tester) async {
        final store = InMemorySecureStore();
        final controller = AuthController(
          telegramService: FakeOfflineTelegramAuthService(),
          secureStore: store,
        );

        await controller.initialize();

        String? pushedRoute;
        await tester.pumpWidget(
          MaterialApp(
            onGenerateRoute: (settings) {
              pushedRoute = settings.name;
              return MaterialPageRoute(builder: (_) => const SizedBox());
            },
            home: StartupScreen(controller: controller),
          ),
        );

        await tester.pumpAndSettle();

        expect(pushedRoute, equals(NuvexRoutes.gettingStarted));
      },
    );
  });

  group('NuvexLoadingView & Text-Free Presentation Guarantees', () {
    testWidgets(
      '1. NuvexLoadingView renders with zero connection text or Telegram wording',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: NuvexLoadingView(isDark: false)),
          ),
        );

        expect(find.byType(NuvexLoadingView), findsOneWidget);

        // Verify that NO Text widget is present anywhere in NuvexLoadingView
        final allTextWidgets = find.descendant(
          of: find.byType(NuvexLoadingView),
          matching: find.byType(Text),
        );
        expect(allTextWidgets, findsNothing);

        // Verify absence of backend strings
        expect(find.textContaining('Telegram'), findsNothing);
        expect(find.textContaining('Connecting'), findsNothing);
        expect(find.textContaining('Downloading'), findsNothing);
      },
    );

    testWidgets(
      '2. NuvexLoadingView renders cleanly in dark mode for media viewer',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              backgroundColor: Colors.black,
              body: NuvexLoadingView(isDark: true, size: 160),
            ),
          ),
        );

        expect(find.byType(NuvexLoadingView), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.textContaining('Telegram'), findsNothing);
      },
    );

    testWidgets(
      '3. PhotosScreen displays intentional offline card with zero Telegram wording when offline and empty',
      (tester) async {
        await tester.runAsync(() async {
          final savedUser = const NuvexTelegramUser(
            id: 99999,
            firstName: 'Offline',
            lastName: 'User',
          );

          final store = InMemorySecureStore(
            creds: (apiId: 12345, apiHash: 'abcdef1234567890'),
            session: '{"key": "test_key"}',
            userData: savedUser.serialize(),
          );

          final fakeAuth = FakeOfflineTelegramAuthService(
            simulateOffline: true,
          );
          final authController = AuthController(
            telegramService: fakeAuth,
            secureStore: store,
          );
          await authController.initialize();

          final mediaRepo = MediaRepository(
            mediaService: FakeEmptyMediaService(throwNetworkError: true),
          );
          final mediaController = MediaController(repository: mediaRepo);
          await mediaController.initializeAndSync();

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: PhotosScreen(
                  controller: authController,
                  mediaController: mediaController,
                ),
              ),
            ),
          );

          await tester.pump();
          await Future.delayed(const Duration(milliseconds: 100));
          await tester.pump();

          // The offline state card must be rendered
          expect(find.text("You're offline"), findsOneWidget);
          expect(find.text('Retry Connection'), findsOneWidget);

          // Must NOT contain Telegram wording
          expect(find.textContaining('Telegram'), findsNothing);
        });
      },
    );

    testWidgets(
      '4. NuvexLoadingView.galleryGrid renders 4-column skeleton grid with zero text',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: NuvexLoadingView.galleryGrid()),
          ),
        );

        expect(find.byType(NuvexLoadingView), findsOneWidget);
        expect(find.byType(GridView), findsOneWidget);

        // Verify zero text widgets in skeleton
        final textWidgets = find.descendant(
          of: find.byType(NuvexLoadingView),
          matching: find.byType(Text),
        );
        expect(textWidgets, findsNothing);
      },
    );

    testWidgets(
      '5. NuvexLoadingView media viewer skeleton matches aspect ratio with zero text',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              backgroundColor: Colors.black,
              body: NuvexLoadingView(
                isDark: true,
                aspectRatio: 16 / 9,
                isVideo: true,
              ),
            ),
          ),
        );

        expect(find.byType(NuvexLoadingView), findsOneWidget);
        expect(find.byType(AspectRatio), findsOneWidget);

        final aspectRatioFinder = tester.widget<AspectRatio>(
          find.byType(AspectRatio),
        );
        expect(aspectRatioFinder.aspectRatio, closeTo(16 / 9, 0.01));

        // Verify zero text widgets in skeleton
        final textWidgets = find.descendant(
          of: find.byType(NuvexLoadingView),
          matching: find.byType(Text),
        );
        expect(textWidgets, findsNothing);
      },
    );
  });
}
