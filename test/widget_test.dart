import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuvex/app/app.dart';
import 'package:nuvex/app/router.dart';
import 'package:nuvex/features/auth/authenticated_screen.dart';
import 'package:nuvex/features/auth/code_screen.dart';
import 'package:nuvex/features/auth/controllers/auth_controller.dart';
import 'package:nuvex/features/auth/password_screen.dart';
import 'package:nuvex/features/auth/phone_screen.dart';
import 'package:nuvex/features/home/controllers/media_controller.dart';
import 'package:nuvex/features/home/home_screen.dart';
import 'package:nuvex/core/database/remote_file.dart';
import 'package:nuvex/features/home/repositories/media_repository.dart';
import 'package:nuvex/telegram/telegram_auth_service.dart';
import 'package:nuvex/telegram/telegram_media_service.dart';
import 'package:nuvex/telegram/telegram_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Fake TelegramMediaService that returns empty list immediately for clean widget testing.
class FakeMediaService extends TelegramMediaService {
  final List<RemoteFile> files;
  FakeMediaService({this.files = const []})
    : super(authService: FakeTelegramAuthService());

  @override
  Future<List<RemoteFile>> fetchSavedMessagesPage({
    int offsetId = 0,
    int limit = 30,
    String? thumbsDir,
    Duration timeout = const Duration(seconds: 15),
  }) async => files;
}

/// Fake TelegramAuthService for deterministic unit and widget testing.
class FakeTelegramAuthService extends TelegramAuthService {
  final bool shouldSucceed;
  final bool require2FA;

  FakeTelegramAuthService({this.shouldSucceed = true, this.require2FA = false})
    : super.create();

  @override
  bool get isConnected => shouldSucceed;

  @override
  Future<bool> ensureConnected() async => shouldSucceed;

  @override
  Future<TelegramConnectionResult> connect({
    required int apiId,
    required String apiHash,
    String? savedSessionJson,
    TelegramDc dc = TelegramDc.dc2,
  }) async {
    if (shouldSucceed) {
      return const TelegramConnectionResult.success(
        dcId: 2,
        authKeyId: 1234567890,
      );
    } else {
      return const TelegramConnectionResult.failure('Connection test failure');
    }
  }

  @override
  Future<AuthSendCodeResult> sendCode(String phoneNumber) async {
    if (!shouldSucceed) {
      return const AuthSendCodeResult.failure('Failed to send code');
    }
    return const AuthSendCodeResult.success(
      phoneCodeHash: 'mock_code_hash_123',
      timeout: 60,
    );
  }

  @override
  Future<AuthSignInResult> signIn({
    required String phoneNumber,
    required String phoneCodeHash,
    required String phoneCode,
  }) async {
    if (!shouldSucceed) {
      return const AuthSignInResult.failure('Invalid code');
    }
    if (require2FA) {
      return const AuthSignInResult.passwordNeeded();
    }
    return const AuthSignInResult.authorized(
      NuvexTelegramUser(
        id: 99887766,
        firstName: 'Nuvex',
        lastName: 'Tester',
        username: 'nuvextest',
        phone: '+1234567890',
      ),
    );
  }

  @override
  Future<AuthSignInResult> checkPassword(String password) async {
    if (password == 'correct_password') {
      return const AuthSignInResult.authorized(
        NuvexTelegramUser(
          id: 99887766,
          firstName: 'Nuvex',
          lastName: 'Tester',
          username: 'nuvextest',
          phone: '+1234567890',
        ),
      );
    } else {
      return const AuthSignInResult.failure('Incorrect 2FA password');
    }
  }

  @override
  Future<NuvexTelegramUser?> verifyExistingSession() async {
    if (shouldSucceed) {
      return const NuvexTelegramUser(
        id: 99887766,
        firstName: 'Nuvex',
        lastName: 'Tester',
        username: 'nuvextest',
        phone: '+1234567890',
      );
    }
    return null;
  }

  @override
  String? exportSession() => '{"id":1234567890,"key":"AABBCC","salt":42}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  FlutterSecureStorage.setMockInitialValues({});

  testWidgets('NuvexApp smoke test launches cleanly', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const NuvexApp());
    await tester.pumpAndSettle();
    expect(find.text('Your files, your space.'), findsOneWidget);
    expect(find.text('Getting Started'), findsOneWidget);
  });

  testWidgets(
    'Tapping Getting Started navigates to Login screen with credential flow',
    (WidgetTester tester) async {
      await tester.pumpWidget(const NuvexApp());
      await tester.pumpAndSettle();

      final gettingStartedBtn = find.text('Getting Started');
      expect(gettingStartedBtn, findsOneWidget);
      await tester.tap(gettingStartedBtn);
      await tester.pumpAndSettle();

      expect(find.text('Welcome to\nNuvex login now!'), findsOneWidget);
      expect(find.text('App ID'), findsOneWidget);
      expect(find.text('App Hash'), findsOneWidget);
      expect(find.text('Login'), findsOneWidget);
      expect(find.text('How do I get my API credentials?'), findsOneWidget);

      await tester.tap(find.text('How do I get my API credentials?'));
      await tester.pumpAndSettle();
      expect(find.text('API Credentials Help'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(find.text('API Credentials Help'), findsNothing);

      await tester.tap(find.text('Login'));
      await tester.pumpAndSettle();
      expect(find.text('Please enter your App ID'), findsOneWidget);
      expect(find.text('Please enter your App Hash'), findsOneWidget);
    },
  );

  test('AuthController full authentication pipeline without 2FA', () async {
    final fakeService = FakeTelegramAuthService(
      shouldSucceed: true,
      require2FA: false,
    );
    final controller = AuthController(telegramService: fakeService);

    await controller.initialize();
    expect(controller.status, AuthStatus.ready);

    final connSuccess = await controller.connectWithCredentials(
      apiId: 1234567,
      apiHash: '0123456789abcdef0123456789abcdef',
    );
    expect(connSuccess, isTrue);

    final sendSuccess = await controller.sendCode('+1234567890');
    expect(sendSuccess, isTrue);
    expect(controller.status, AuthStatus.waitingCode);
    expect(controller.phoneCodeHash, 'mock_code_hash_123');

    final verifySuccess = await controller.verifyCode('12345');
    expect(verifySuccess, isTrue);
    expect(controller.status, AuthStatus.authenticated);
    expect(controller.isAuthenticated, isTrue);
    expect(controller.currentUser?.displayName, 'Nuvex Tester');
  });

  test('AuthController authentication pipeline with 2FA password', () async {
    final fakeService = FakeTelegramAuthService(
      shouldSucceed: true,
      require2FA: true,
    );
    final controller = AuthController(telegramService: fakeService);

    await controller.initialize();
    await controller.connectWithCredentials(
      apiId: 1234567,
      apiHash: '0123456789abcdef0123456789abcdef',
    );

    await controller.sendCode('+1234567890');
    expect(controller.status, AuthStatus.waitingCode);

    final verifyCodeResult = await controller.verifyCode('12345');
    expect(verifyCodeResult, isFalse);
    expect(controller.status, AuthStatus.waitingPassword);

    final wrongPass = await controller.verifyPassword('wrong');
    expect(wrongPass, isFalse);
    expect(controller.status, AuthStatus.waitingPassword);
    expect(controller.errorMessage, 'Incorrect 2FA password');

    final correctPass = await controller.verifyPassword('correct_password');
    expect(correctPass, isTrue);
    expect(controller.status, AuthStatus.authenticated);
    expect(controller.isAuthenticated, isTrue);
  });

  testWidgets('PhoneScreen renders and validates phone number', (
    WidgetTester tester,
  ) async {
    final fakeService = FakeTelegramAuthService();
    final controller = AuthController(telegramService: fakeService);
    await controller.connectWithCredentials(
      apiId: 12345,
      apiHash: '0123456789abcdef',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PhoneScreen(controller: controller),
        onGenerateRoute: NuvexRouter.onGenerateRoute,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Phone Number'), findsWidgets);
    expect(find.text('Send Code'), findsOneWidget);

    // Tap Send Code with empty input
    await tester.tap(find.text('Send Code'));
    await tester.pumpAndSettle();
    expect(find.text('Please enter your phone number'), findsOneWidget);

    // Enter valid phone
    await tester.enterText(find.byType(TextField), '+1234567890');
    await tester.tap(find.text('Send Code'));
    await tester.pumpAndSettle();

    expect(controller.status, AuthStatus.waitingCode);
  });

  testWidgets('CodeScreen renders and validates OTP code', (
    WidgetTester tester,
  ) async {
    final fakeService = FakeTelegramAuthService();
    final controller = AuthController(telegramService: fakeService);
    await controller.connectWithCredentials(
      apiId: 12345,
      apiHash: '0123456789abcdef',
    );
    await controller.sendCode('+1234567890');

    await tester.pumpWidget(
      MaterialApp(
        home: CodeScreen(controller: controller),
        onGenerateRoute: NuvexRouter.onGenerateRoute,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Verification Code'), findsOneWidget);
    expect(find.text('Verify Code'), findsOneWidget);

    // Tap verify with empty code
    await tester.tap(find.text('Verify Code'));
    await tester.pumpAndSettle();
    expect(find.text('Please enter the verification code'), findsOneWidget);

    // Enter code
    await tester.enterText(find.byType(TextField), '12345');
    await tester.tap(find.text('Verify Code'));
    await tester.pumpAndSettle();

    expect(controller.status, AuthStatus.authenticated);
  });

  testWidgets('Password2FAScreen renders and validates password input', (
    WidgetTester tester,
  ) async {
    final fakeService = FakeTelegramAuthService(require2FA: true);
    final controller = AuthController(telegramService: fakeService);
    await controller.connectWithCredentials(
      apiId: 12345,
      apiHash: '0123456789abcdef',
    );
    await controller.sendCode('+1234567890');
    await controller.verifyCode('12345');

    await tester.pumpWidget(
      MaterialApp(
        home: Password2FAScreen(controller: controller),
        onGenerateRoute: NuvexRouter.onGenerateRoute,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Two-Step Verification'), findsOneWidget);
    expect(find.text('Verify Password'), findsOneWidget);

    // Tap verify with empty password
    await tester.tap(find.text('Verify Password'));
    await tester.pumpAndSettle();
    expect(
      find.text('Please enter your 2-step verification password'),
      findsOneWidget,
    );

    // Enter correct password
    await tester.enterText(find.byType(TextField), 'correct_password');
    await tester.tap(find.text('Verify Password'));
    await tester.pumpAndSettle();

    expect(controller.status, AuthStatus.authenticated);
  });

  testWidgets('AuthenticatedScreen renders authorized user info cleanly', (
    WidgetTester tester,
  ) async {
    final fakeService = FakeTelegramAuthService();
    final controller = AuthController(telegramService: fakeService);
    await controller.connectWithCredentials(
      apiId: 12345,
      apiHash: '0123456789abcdef',
    );
    await controller.sendCode('+1234567890');
    await controller.verifyCode('12345');

    await tester.pumpWidget(
      MaterialApp(home: AuthenticatedScreen(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Telegram Authorized'), findsOneWidget);
    expect(find.text('Nuvex Tester'), findsOneWidget);
    expect(find.text('@nuvextest'), findsOneWidget);
    expect(find.text('+1234567890'), findsOneWidget);
    expect(find.text('99887766'), findsOneWidget);
  });

  testWidgets('HomeScreen renders Photos view with approved structure', (
    WidgetTester tester,
  ) async {
    final fakeService = FakeTelegramAuthService();
    final controller = AuthController(telegramService: fakeService);
    await controller.connectWithCredentials(
      apiId: 12345,
      apiHash: '0123456789abcdef',
    );
    await controller.sendCode('+1234567890');
    await controller.verifyCode('12345');

    final mediaController = MediaController(
      repository: MediaRepository(mediaService: FakeMediaService()),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          controller: controller,
          mediaController: mediaController,
        ),
        onGenerateRoute: NuvexRouter.onGenerateRoute,
      ),
    );
    await tester.pumpAndSettle();

    // Verify Header Branding & Subtitle
    expect(find.text('Your files, your space.'), findsOneWidget);
    expect(find.text('Albums'), findsOneWidget);
    expect(find.text('See all'), findsOneWidget);

    // Verify Albums
    expect(find.text('Together'), findsOneWidget);
    expect(find.text('Spotlight'), findsOneWidget);
    expect(find.text('Travel'), findsOneWidget);

    // Verify Recent & Polished Empty State
    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('No photos yet'), findsOneWidget);
    expect(
      find.text(
        'Photos and memories from your Telegram storage will appear here.',
      ),
      findsOneWidget,
    );

    // Verify Bottom Navigation has exactly two destinations
    expect(find.text('Photos'), findsOneWidget);
    expect(find.text('Collections'), findsOneWidget);

    // Verify forbidden elements are NOT present
    expect(find.text('Create'), findsNothing);
    expect(find.text('Search'), findsNothing);
    expect(find.text('Out of storage'), findsNothing);
  });

  testWidgets(
    'HomeScreen switches between Photos and Collections tabs seamlessly',
    (WidgetTester tester) async {
      final fakeService = FakeTelegramAuthService();
      final controller = AuthController(telegramService: fakeService);
      await controller.connectWithCredentials(
        apiId: 12345,
        apiHash: '0123456789abcdef',
      );
      await controller.sendCode('+1234567890');
      await controller.verifyCode('12345');

      final mediaController = MediaController(
        repository: MediaRepository(mediaService: FakeMediaService()),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            controller: controller,
            mediaController: mediaController,
          ),
          onGenerateRoute: NuvexRouter.onGenerateRoute,
        ),
      );
      await tester.pumpAndSettle();

      // Initially on Photos
      expect(find.text('Your files, your space.'), findsOneWidget);

      // Tap Collections in bottom nav
      await tester.tap(find.text('Collections'));
      await tester.pumpAndSettle();

      // Collections primary cards (2x2)
      expect(find.text('Documents'), findsOneWidget);
      expect(find.text('Places'), findsOneWidget);
      expect(find.text('Stickers'), findsOneWidget);
      expect(find.text('Moments'), findsOneWidget);

      // Collections secondary rows
      expect(find.text('Screenshots'), findsOneWidget);
      expect(find.text('Videos'), findsOneWidget);
      expect(find.text('Recently added'), findsOneWidget);
      expect(find.text('Creations'), findsOneWidget);
      expect(find.text('Archive'), findsOneWidget);
      expect(find.text('Locked Folder'), findsOneWidget);

      // Tap Photos in bottom nav to switch back
      await tester.tap(find.text('Photos'));
      await tester.pumpAndSettle();

      // Back on Photos
      expect(find.text('Your files, your space.'), findsOneWidget);
    },
  );
}
