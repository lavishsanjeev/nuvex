import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:t/t.dart' as t;
import 'package:tg/tg.dart';

import '../core/storage/secure_storage.dart';
import 'telegram_models.dart';

class TcpSocketAbstraction implements SocketAbstraction {
  final Socket _socket;
  bool _isHealthy = true;
  final StreamController<Uint8List> _controller = StreamController<Uint8List>();
  final VoidCallback? onDisconnected;

  TcpSocketAbstraction(this._socket, {this.onDisconnected}) {
    _socket.listen(
      (data) {
        if (!_controller.isClosed) {
          _controller.add(data);
        }
      },
      onError: (err) {
        debugPrint('[AUTH] socket error caught safely: $err');
        _isHealthy = false;
        if (!_controller.isClosed) {
          _controller.close();
        }
        onDisconnected?.call();
      },
      onDone: () {
        debugPrint('[AUTH] socket closed by peer/server');
        _isHealthy = false;
        if (!_controller.isClosed) {
          _controller.close();
        }
        onDisconnected?.call();
      },
      cancelOnError: false,
    );
  }

  bool get isHealthy => _isHealthy;

  @override
  Stream<Uint8List> get receiver => _controller.stream;

  Future<void>? _lastWrite;

  @override
  Future<void> send(List<int> data) async {
    if (!_isHealthy) {
      throw const SocketException('Socket is disconnected');
    }
    final prev = _lastWrite;
    final completer = Completer<void>();
    _lastWrite = completer.future;

    if (prev != null) {
      try {
        await prev;
      } catch (_) {}
    }

    try {
      if (!_isHealthy) {
        throw const SocketException('Socket is disconnected');
      }
      _socket.add(data);
      await _socket.flush();
    } catch (e) {
      _isHealthy = false;
      rethrow;
    } finally {
      completer.complete();
    }
  }

  Future<void> close() async {
    _isHealthy = false;
    try {
      if (!_controller.isClosed) {
        await _controller.close();
      }
      await _socket.close();
      _socket.destroy();
    } catch (_) {}
  }
}

/// Telegram Data Center configuration.
class TelegramDc {
  final int id;
  final String ip;
  final int port;

  const TelegramDc({required this.id, required this.ip, required this.port});

  static const TelegramDc dc1 = TelegramDc(
    id: 1,
    ip: '149.154.175.50',
    port: 443,
  );
  static const TelegramDc dc2 = TelegramDc(
    id: 2,
    ip: '149.154.167.50',
    port: 443,
  );
  static const TelegramDc dc3 = TelegramDc(
    id: 3,
    ip: '149.154.175.100',
    port: 443,
  );
  static const TelegramDc dc4 = TelegramDc(
    id: 4,
    ip: '149.154.167.91',
    port: 443,
  );
  static const TelegramDc dc5 = TelegramDc(
    id: 5,
    ip: '91.108.56.107',
    port: 443,
  );

  static TelegramDc forId(int id) {
    switch (id) {
      case 1:
        return dc1;
      case 2:
        return dc2;
      case 3:
        return dc3;
      case 4:
        return dc4;
      case 5:
        return dc5;
      default:
        return dc2;
    }
  }
}

/// Result of a Telegram connection attempt.
class TelegramConnectionResult {
  final bool isSuccess;
  final int? dcId;
  final int? authKeyId;
  final String? errorMessage;

  const TelegramConnectionResult.success({
    required this.dcId,
    required this.authKeyId,
  }) : isSuccess = true,
       errorMessage = null;

  const TelegramConnectionResult.failure(this.errorMessage)
    : isSuccess = false,
      dcId = null,
      authKeyId = null;
}

/// Low-level service managing real MTProto connection and authorization.
///
/// Features:
/// - Reuses established MTProto connection; prevents duplicate clients.
/// - Performs Diffie-Hellman on a dedicated socket, then opens a clean encrypted socket
///   to prevent stream cipher desynchronization and AES-IGE padding errors.
/// - Strict 15-second timeouts on all network operations.
/// - Zero logging of sensitive credentials, codes, or session keys.
class TelegramAuthService {
  static final TelegramAuthService _instance = TelegramAuthService.create();
  factory TelegramAuthService() => _instance;
  TelegramAuthService.create();

  TcpSocketAbstraction? _tcpSocket;
  Client? _client;
  AuthorizationKey? _authKey;
  TelegramDc _currentDc = TelegramDc.dc2;
  int? _apiId;
  String? _apiHash;
  bool _isConnected = false;
  bool _isConnecting = false;
  Timer? _heartbeatTimer;

  bool get isConnected =>
      _isConnected && _client != null && (_tcpSocket?.isHealthy ?? false);
  TelegramDc get currentDc => _currentDc;
  Client? get client => _client;
  int? get apiId => _apiId;
  String? get apiHash => _apiHash;
  AuthorizationKey? get authKey => _authKey ?? _client?.authorizationKey;

  /// Connects to Telegram DC and establishes an encrypted MTProto session.
  ///
  /// Reuses existing client if already connected to [dc] with matching [apiId].
  Future<TelegramConnectionResult> connect({
    required int apiId,
    required String apiHash,
    String? savedSessionJson,
    TelegramDc dc = TelegramDc.dc2,
  }) async {
    // 1. Reuse existing healthy connection if already connected to target DC
    if (_isConnected &&
        _client != null &&
        _tcpSocket != null &&
        _tcpSocket!.isHealthy &&
        _apiId == apiId &&
        _currentDc.id == dc.id) {
      debugPrint('[AUTH] client connected (reused existing connection)');
      return TelegramConnectionResult.success(
        dcId: _currentDc.id,
        authKeyId: _client!.authorizationKey.id,
      );
    }

    if (_isConnecting) {
      debugPrint('[AUTH] connection already in progress, waiting...');
      int attempts = 0;
      while (_isConnecting && attempts < 30) {
        await Future.delayed(const Duration(milliseconds: 200));
        attempts++;
      }
      if (_isConnected && _client != null) {
        return TelegramConnectionResult.success(
          dcId: _currentDc.id,
          authKeyId: _client!.authorizationKey.id,
        );
      }
    }

    _isConnecting = true;
    _apiId = apiId;
    _apiHash = apiHash;
    _currentDc = dc;

    debugPrint('[AUTH] client initialization started for DC ${dc.id}');

    try {
      AuthorizationKey? authKey;
      bool restoredSessionValid = false;

      // 2. Try restoring existing session if provided
      if (savedSessionJson != null && savedSessionJson.isNotEmpty) {
        try {
          final decoded = jsonDecode(savedSessionJson) as Map<String, dynamic>;
          authKey = AuthorizationKey.fromJson(decoded);
          debugPrint('[AUTH] restoring saved auth key...');

          // Test restored key with initConnection
          await _tcpSocket?.close();
          final socket = await Socket.connect(
            dc.ip,
            dc.port,
            timeout: const Duration(seconds: 8),
          );
          _tcpSocket = TcpSocketAbstraction(
            socket,
            onDisconnected: () {
              _isConnected = false;
            },
          );
          final obf = Obfuscation.random(false, dc.id);
          final idGen = MessageIdGenerator();
          await _tcpSocket!.send(obf.preamble);

          _client = Client(
            socket: _tcpSocket!,
            obfuscation: obf,
            authorizationKey: authKey,
            idGenerator: idGen,
          );

          await _client!
              .initConnection<t.ConfigBase>(
                apiId: apiId,
                deviceModel: 'Android Mobile',
                systemVersion: 'Android 14',
                appVersion: '1.0.0',
                systemLangCode: 'en',
                langPack: '',
                langCode: 'en',
                query: const t.HelpGetConfig(),
              )
              .timeout(const Duration(seconds: 8));

          restoredSessionValid = true;
          debugPrint('[AUTH] restored session verified successfully');
        } on SocketException {
          // Network is unreachable; preserve session key and report network failure
          rethrow;
        } on TimeoutException {
          // Network timed out; preserve session key
          rethrow;
        } catch (e) {
          debugPrint(
            '[AUTH] saved session key rejected/invalid ($e), generating fresh Diffie-Hellman key...',
          );
          authKey = null;
          restoredSessionValid = false;
          await _tcpSocket?.close();
          _tcpSocket = null;
          _client = null;
        }
      }

      // 3. If no valid session key (or restored session was rejected), perform fresh DH exchange
      if (!restoredSessionValid) {
        debugPrint(
          '[AUTH] generating new Diffie-Hellman key on DC ${dc.id}...',
        );
        final dhSocket = await Socket.connect(
          dc.ip,
          dc.port,
          timeout: const Duration(seconds: 8),
        );
        final dhTcp = TcpSocketAbstraction(dhSocket);
        final dhObf = Obfuscation.random(false, dc.id);
        final dhIdGen = MessageIdGenerator();
        await dhTcp.send(dhObf.preamble);

        authKey = await Client.authorize(
          dhTcp,
          dhObf,
          dhIdGen,
        ).timeout(const Duration(seconds: 12));

        // Close the DH exchange socket cleanly so no unconsumed bytes or
        // stream-cipher state leak into the encrypted session socket.
        await dhTcp.close();
        debugPrint('[AUTH] Diffie-Hellman key exchange completed');

        // 4. Open fresh dedicated TCP socket for encrypted MTProto communication
        await _tcpSocket?.close();
        final socket = await Socket.connect(
          dc.ip,
          dc.port,
          timeout: const Duration(seconds: 8),
        );
        _tcpSocket = TcpSocketAbstraction(
          socket,
          onDisconnected: () {
            _isConnected = false;
          },
        );

        final obfuscation = Obfuscation.random(false, dc.id);
        final idGenerator = MessageIdGenerator();
        await _tcpSocket!.send(obfuscation.preamble);

        // 5. Instantiate MTProto Client on clean socket
        _client = Client(
          socket: _tcpSocket!,
          obfuscation: obfuscation,
          authorizationKey: authKey,
          idGenerator: idGenerator,
        );

        // 6. Initialize connection layer and server config
        await _client!
            .initConnection<t.ConfigBase>(
              apiId: apiId,
              deviceModel: 'Android Mobile',
              systemVersion: 'Android 14',
              appVersion: '1.0.0',
              systemLangCode: 'en',
              langPack: '',
              langCode: 'en',
              query: const t.HelpGetConfig(),
            )
            .timeout(const Duration(seconds: 8));
        debugPrint('[AUTH] initConnection completed');
      }

      _authKey = authKey;
      _isConnected = true;
      debugPrint('[AUTH] client connected');

      return TelegramConnectionResult.success(
        dcId: dc.id,
        authKeyId: authKey!.id,
      );
    } on SocketException {
      _isConnected = false;
      debugPrint('[AUTH] connection failed: SocketException');
      return TelegramConnectionResult.failure(
        'Unable to reach network. Please check your internet connection.',
      );
    } on TimeoutException {
      _isConnected = false;
      debugPrint('[AUTH] timeout');
      return const TelegramConnectionResult.failure(
        'Connection to Telegram timed out. Please try again.',
      );
    } catch (e) {
      _isConnected = false;
      debugPrint('[AUTH] connection failed: ${e.runtimeType}');
      return TelegramConnectionResult.failure(
        'Telegram connection error: ${cleanException(e)}',
      );
    } finally {
      _isConnecting = false;
    }
  }

  /// Ensures MTProto connection is healthy; transparently re-establishes the TCP socket
  /// with the existing authorization key if the previous socket dropped while user was fetching OTP.
  Future<bool> ensureConnected() async {
    if (_isConnected &&
        _client != null &&
        _tcpSocket != null &&
        _tcpSocket!.isHealthy) {
      return true;
    }

    var key = _authKey ?? _client?.authorizationKey;
    if (key == null || _apiId == null || _apiHash == null) {
      try {
        const store = NuvexSecureStore();
        final creds = await store.getCredentials();
        final session = await store.getSession();
        final dcId = await store.getDcId();
        if (creds != null && session != null && session.isNotEmpty) {
          final targetDc = dcId != null ? TelegramDc.forId(dcId) : _currentDc;
          final res = await connect(
            apiId: creds.apiId,
            apiHash: creds.apiHash,
            savedSessionJson: session,
            dc: targetDc,
          );
          if (res.isSuccess) {
            return true;
          }
        }
      } catch (e) {
        debugPrint('[AUTH] ensureConnected auto-restore exception: $e');
      }
    }

    key = _authKey ?? _client?.authorizationKey;
    if (key == null || _apiId == null || _apiHash == null) {
      debugPrint(
        '[AUTH] ensureConnected: cannot reconnect without auth key or credentials',
      );
      return false;
    }

    debugPrint(
      '[AUTH] socket lost; reconnecting to DC ${_currentDc.id} with existing auth key...',
    );

    try {
      await _tcpSocket?.close();
      final socket = await Socket.connect(
        _currentDc.ip,
        _currentDc.port,
        timeout: const Duration(seconds: 8),
      );
      _tcpSocket = TcpSocketAbstraction(
        socket,
        onDisconnected: () {
          _isConnected = false;
        },
      );

      final obfuscation = Obfuscation.random(false, _currentDc.id);
      final idGenerator = MessageIdGenerator();
      await _tcpSocket!.send(obfuscation.preamble);

      _authKey = key;
      _client = Client(
        socket: _tcpSocket!,
        obfuscation: obfuscation,
        authorizationKey: key,
        idGenerator: idGenerator,
      );

      await _client!
          .initConnection<t.ConfigBase>(
            apiId: _apiId!,
            deviceModel: 'Android Mobile',
            systemVersion: 'Android 14',
            appVersion: '1.0.0',
            systemLangCode: 'en',
            langPack: '',
            langCode: 'en',
            query: const t.HelpGetConfig(),
          )
          .timeout(const Duration(seconds: 8));

      _isConnected = true;
      _startHeartbeat();
      debugPrint('[AUTH] transparent reconnection successful');
      return true;
    } catch (e) {
      debugPrint('[AUTH] transparent reconnection failed: $e');
      _isConnected = false;
      return false;
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 12), (
      timer,
    ) async {
      if (!_isConnected ||
          _client == null ||
          _tcpSocket == null ||
          !_tcpSocket!.isHealthy) {
        timer.cancel();
        return;
      }
      try {
        await _client!.help.getNearestDc().timeout(const Duration(seconds: 4));
      } catch (e) {
        debugPrint('[AUTH] keepalive ping missed: $e');
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// Requests Telegram to send an authorization code to the specified [phoneNumber].
  Future<AuthSendCodeResult> sendCode(String phoneNumber) async {
    if (!isConnected || _client == null || _apiId == null || _apiHash == null) {
      debugPrint(
        '[AUTH] sendCode called but client not connected; reconnecting...',
      );
      final conn = await connect(apiId: _apiId ?? 0, apiHash: _apiHash ?? '');
      if (!conn.isSuccess) {
        return const AuthSendCodeResult.failure(
          'Unable to connect to Telegram. Please check your connection and try again.',
        );
      }
    }

    final cleanPhone = phoneNumber.replaceAll(RegExp(r'[\s\-\(\)]'), '');
    if (cleanPhone.isEmpty) {
      return const AuthSendCodeResult.failure(
        'Please enter a valid phone number.',
      );
    }

    debugPrint('[AUTH] sendCode started');

    const settings = t.CodeSettings(
      allowFlashcall: false,
      currentNumber: false,
      allowAppHash: true,
      allowMissedCall: false,
      allowFirebase: false,
      unknownNumber: false,
    );

    try {
      var response = await _client!.auth
          .sendCode(
            phoneNumber: cleanPhone,
            apiId: _apiId!,
            apiHash: _apiHash!,
            settings: settings,
          )
          .timeout(const Duration(seconds: 15));

      // Handle DC migration if returned by Telegram
      if (response.error != null) {
        final errMsg = response.error!.errorMessage;
        debugPrint('[AUTH] sendCode returned error: $errMsg');

        if (errMsg.startsWith('PHONE_MIGRATE_') ||
            errMsg.startsWith('NETWORK_MIGRATE_')) {
          final dcIdStr = errMsg.replaceAll(RegExp(r'^\w+_MIGRATE_'), '');
          final targetDcId = int.tryParse(dcIdStr);
          if (targetDcId != null && targetDcId != _currentDc.id) {
            debugPrint('[AUTH] migrating to DC $targetDcId...');
            await disconnect();
            final migrated = await connect(
              apiId: _apiId!,
              apiHash: _apiHash!,
              dc: TelegramDc.forId(targetDcId),
            );

            if (migrated.isSuccess && _client != null) {
              debugPrint(
                '[AUTH] retrying sendCode on migrated DC $targetDcId...',
              );
              response = await _client!.auth
                  .sendCode(
                    phoneNumber: cleanPhone,
                    apiId: _apiId!,
                    apiHash: _apiHash!,
                    settings: settings,
                  )
                  .timeout(const Duration(seconds: 15));
            }
          }
        }
      }

      if (response.error != null) {
        debugPrint('[AUTH] sendCode failed: ${response.error!.errorMessage}');
        return AuthSendCodeResult.failure(
          _mapTelegramError(response.error!.errorMessage),
        );
      }

      final result = response.result;
      if (result is t.AuthSentCode) {
        debugPrint('[AUTH] sendCode completed');
        _startHeartbeat();
        return AuthSendCodeResult.success(
          phoneCodeHash: result.phoneCodeHash,
          timeout: result.timeout,
        );
      } else if (result is t.AuthSentCodeSuccess) {
        debugPrint('[AUTH] sendCode completed (auto-authorized)');
        return const AuthSendCodeResult.success(phoneCodeHash: '');
      }

      debugPrint('[AUTH] sendCode failed: unexpected response type');
      return const AuthSendCodeResult.failure(
        'Unexpected response from Telegram.',
      );
    } on TimeoutException {
      debugPrint('[AUTH] timeout in sendCode');
      return const AuthSendCodeResult.failure(
        'Request timed out while waiting for Telegram. Please try again.',
      );
    } catch (e) {
      debugPrint('[AUTH] sendCode failed: ${e.runtimeType}');
      return AuthSendCodeResult.failure(
        'Failed to send code: ${cleanException(e)}',
      );
    }
  }

  /// Verifies the entered verification code with Telegram.
  Future<AuthSignInResult> signIn({
    required String phoneNumber,
    required String phoneCodeHash,
    required String phoneCode,
  }) async {
    final cleanPhone = phoneNumber.replaceAll(RegExp(r'[\s\-\(\)]'), '');
    final cleanCode = phoneCode.trim().replaceAll(RegExp(r'\D'), '');

    if (cleanCode.isEmpty) {
      return const AuthSignInResult.failure(
        'Please enter the verification code.',
      );
    }

    // Transparently ensure active MTProto connection before dispatching verification
    final ready = await ensureConnected();
    if (!ready || _client == null) {
      return const AuthSignInResult.failure(
        'Connection to Telegram lost. Please check your internet connection and try again.',
      );
    }

    debugPrint('[AUTH] signIn started');

    try {
      final response = await _client!.auth
          .signIn(
            phoneNumber: cleanPhone,
            phoneCodeHash: phoneCodeHash,
            phoneCode: cleanCode,
          )
          .timeout(const Duration(seconds: 15));

      if (response.error != null) {
        final code = response.error!.errorCode;
        final msg = response.error!.errorMessage;
        debugPrint('[AUTH] signIn error: $code $msg');

        if (code == 401 || msg == 'SESSION_PASSWORD_NEEDED') {
          debugPrint('[AUTH] 2FA password needed');
          return const AuthSignInResult.passwordNeeded();
        }
        return AuthSignInResult.failure(_mapTelegramError(msg));
      }

      final result = response.result;
      if (result is t.AuthAuthorization) {
        debugPrint('[AUTH] signIn completed (authorized)');
        _stopHeartbeat();
        final user = _extractUser(result.user);
        return AuthSignInResult.authorized(user);
      } else if (result is t.AuthAuthorizationSignUpRequired) {
        debugPrint('[AUTH] signIn failed: sign-up required');
        return const AuthSignInResult.failure(
          'This phone number is not registered on Telegram. Please create an account in the Telegram app first.',
        );
      }

      return const AuthSignInResult.failure(
        'Failed to authorize with Telegram.',
      );
    } on TimeoutException {
      debugPrint('[AUTH] timeout in signIn');
      return const AuthSignInResult.failure(
        'Verification timed out. Please try again.',
      );
    } catch (e) {
      debugPrint('[AUTH] signIn failed: ${e.runtimeType}');
      _isConnected = false;
      return AuthSignInResult.failure('Sign-in error: ${cleanException(e)}');
    }
  }

  /// Verifies a 2-Step Verification password with Telegram using MTProto SRP.
  Future<AuthSignInResult> checkPassword(String password) async {
    final ready = await ensureConnected();
    if (!ready || _client == null) {
      return const AuthSignInResult.failure(
        'Connection to Telegram lost. Please check your internet connection and try again.',
      );
    }

    if (password.isEmpty) {
      return const AuthSignInResult.failure(
        'Please enter your 2-step verification password.',
      );
    }

    debugPrint('[AUTH] checkPassword started');

    try {
      final passRes = await _client!.account.getPassword().timeout(
        const Duration(seconds: 10),
      );
      if (passRes.error != null) {
        return AuthSignInResult.failure(
          _mapTelegramError(passRes.error!.errorMessage),
        );
      }

      final accountPassword = passRes.result;
      if (accountPassword is! t.AccountPassword) {
        return const AuthSignInResult.failure(
          'Unable to retrieve 2FA challenge from Telegram.',
        );
      }

      final srp = await check2FA(accountPassword, password);
      final checkRes = await _client!.auth
          .checkPassword(password: srp)
          .timeout(const Duration(seconds: 15));

      if (checkRes.error != null) {
        debugPrint(
          '[AUTH] checkPassword failed: ${checkRes.error!.errorMessage}',
        );
        return AuthSignInResult.failure(
          _mapTelegramError(checkRes.error!.errorMessage),
        );
      }

      final result = checkRes.result;
      if (result is t.AuthAuthorization) {
        debugPrint('[AUTH] checkPassword completed (authorized)');
        _stopHeartbeat();
        final user = _extractUser(result.user);
        return AuthSignInResult.authorized(user);
      }

      return const AuthSignInResult.failure('2FA verification failed.');
    } on TimeoutException {
      debugPrint('[AUTH] timeout in checkPassword');
      return const AuthSignInResult.failure(
        'Password verification timed out. Please try again.',
      );
    } catch (e) {
      debugPrint('[AUTH] checkPassword failed: ${e.runtimeType}');
      _isConnected = false;
      return AuthSignInResult.failure(
        'Password verification error: ${cleanException(e)}',
      );
    }
  }

  /// Verifies if the currently connected session is genuinely authenticated by Telegram.
  Future<NuvexTelegramUser?> verifyExistingSession() async {
    if (!isConnected || _client == null) return null;

    try {
      final res = await _client!.users
          .getFullUser(id: const t.InputUserSelf())
          .timeout(const Duration(seconds: 6));

      if (res.result != null && res.result is t.UsersUserFull) {
        final full = res.result as t.UsersUserFull;
        for (final u in full.users) {
          if (u is t.User && u.self) {
            return _extractUser(u);
          }
        }
        if (full.users.isNotEmpty && full.users.first is t.User) {
          return _extractUser(full.users.first);
        }
      }
    } catch (_) {
      // Not authenticated or network timeout
    }
    return null;
  }

  /// Serializes the current authorization key into encrypted-ready JSON.
  String? exportSession() {
    if (_client == null) return null;
    return jsonEncode(_client!.authorizationKey.toJson());
  }

  /// Disconnects and releases network resources.
  Future<void> disconnect() async {
    _stopHeartbeat();
    _isConnected = false;
    _client = null;
    await _tcpSocket?.close();
    _tcpSocket = null;
  }

  NuvexTelegramUser _extractUser(t.UserBase? userBase) {
    if (userBase is t.User) {
      return NuvexTelegramUser(
        id: userBase.id,
        firstName: userBase.firstName ?? 'Telegram User',
        lastName: userBase.lastName,
        username: userBase.username,
        phone: userBase.phone,
      );
    }
    return const NuvexTelegramUser(id: 0, firstName: 'Telegram User');
  }

  String _mapTelegramError(String rawError) {
    if (rawError.contains('PHONE_NUMBER_INVALID')) {
      return 'The phone number entered is invalid. Please verify your country code and digits.';
    }
    if (rawError.contains('PHONE_CODE_INVALID')) {
      return 'Invalid verification code. Please check and try again.';
    }
    if (rawError.contains('PHONE_CODE_EXPIRED')) {
      return 'The verification code has expired. Please request a new code.';
    }
    if (rawError.contains('PASSWORD_HASH_INVALID')) {
      return 'Incorrect 2-step verification password. Please try again.';
    }
    if (rawError.contains('FLOOD_WAIT_')) {
      final seconds = rawError.replaceAll(RegExp(r'\D'), '');
      return 'Too many attempts. Telegram rate limited this request. Please wait $seconds seconds before trying again.';
    }
    if (rawError.contains('PHONE_NUMBER_BANNED')) {
      return 'This phone number has been banned by Telegram.';
    }
    if (rawError.contains('API_ID_INVALID')) {
      return 'Invalid App ID or App Hash. Please verify your API credentials.';
    }
    return 'Telegram error: ${rawError.replaceAll(RegExp(r'Exception:\s*'), '')}';
  }

  static String cleanException(Object e) {
    return e.toString().replaceAll(RegExp(r'Exception:\s*'), '');
  }
}
