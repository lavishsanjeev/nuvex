import 'dart:io';
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/storage/secure_storage.dart';
import '../../../telegram/telegram_auth_service.dart';
import '../../../telegram/telegram_models.dart';

/// Distinct states of the Nuvex authentication pipeline.
enum AuthStatus {
  /// Checking secure storage for existing credentials or session.
  uninitialized,

  /// Ready for App ID and App Hash input.
  ready,

  /// Actively establishing encrypted MTProto connection to Telegram DC.
  connecting,

  /// MTProto channel established and verified; ready for Phone Number.
  connectedWaitingPhone,

  /// Requesting Telegram to send verification code.
  sendingCode,

  /// Verification code sent; awaiting user input.
  waitingCode,

  /// Verifying OTP code with Telegram.
  verifyingCode,

  /// Telegram requires 2FA password; awaiting user input.
  waitingPassword,

  /// Verifying 2FA password with Telegram via SRP challenge.
  verifyingPassword,

  /// Genuine Telegram session authorized and verified!
  authenticated,

  /// An error occurred with human-readable explanation.
  error,
}

/// Central controller driving authentication state, credential persistence,
/// and Telegram MTProto lifecycle.
///
/// Implements singleton pattern so all screens share the same client and state.
class AuthController extends ChangeNotifier {
  static final AuthController _instance = AuthController._internal();

  factory AuthController({
    TelegramAuthService? telegramService,
    NuvexSecureStore? secureStore,
  }) {
    if (telegramService != null || secureStore != null) {
      return AuthController._internal(
        telegramService: telegramService,
        secureStore: secureStore,
      );
    }
    return _instance;
  }

  AuthController._internal({
    TelegramAuthService? telegramService,
    NuvexSecureStore? secureStore,
  }) : _telegramService = telegramService ?? TelegramAuthService(),
       _secureStore = secureStore ?? const NuvexSecureStore();

  final TelegramAuthService _telegramService;
  final NuvexSecureStore _secureStore;

  TelegramAuthService get telegramService => _telegramService;

  AuthStatus _status = AuthStatus.uninitialized;
  String? _errorMessage;
  int? _savedAppId;
  String? _savedAppHash;
  int? _connectedDcId;
  int? _authKeyId;

  String? _currentPhoneNumber;
  String? _phoneCodeHash;
  int? _codeTimeoutSeconds;
  NuvexTelegramUser? _currentUser;
  bool _isRestoringSession = false;
  bool _isBackendReachable = true;

  bool get isBackendReachable => _isBackendReachable;
  bool get isOffline => !_isBackendReachable;

  AuthStatus get status => _status;
  String? get errorMessage => _errorMessage;
  int? get savedAppId => _savedAppId;
  String? get savedAppHash => _savedAppHash;
  int? get connectedDcId => _connectedDcId;
  int? get authKeyId => _authKeyId;
  String? get currentPhoneNumber => _currentPhoneNumber;
  String? get phoneCodeHash => _phoneCodeHash;
  int? get codeTimeoutSeconds => _codeTimeoutSeconds;
  NuvexTelegramUser? get currentUser => _currentUser;
  bool get isRestoringSession => _isRestoringSession;

  bool get isConnecting => _status == AuthStatus.connecting;
  bool get isConnected =>
      _status == AuthStatus.connectedWaitingPhone ||
      _status == AuthStatus.sendingCode ||
      _status == AuthStatus.waitingCode ||
      _status == AuthStatus.verifyingCode ||
      _status == AuthStatus.waitingPassword ||
      _status == AuthStatus.verifyingPassword ||
      _status == AuthStatus.authenticated;
  bool get isSendingCode => _status == AuthStatus.sendingCode;
  bool get isVerifyingCode => _status == AuthStatus.verifyingCode;
  bool get isVerifyingPassword => _status == AuthStatus.verifyingPassword;
  bool get isAuthenticated => _status == AuthStatus.authenticated;
  bool get isInitialized => _status != AuthStatus.uninitialized;

  /// Initializes controller by checking local secure storage and attempting silent session restore.
  Future<void> initialize() async {
    if (_status == AuthStatus.authenticated) return;

    _status = AuthStatus.uninitialized;
    _errorMessage = null;
    notifyListeners();

    final creds = await _secureStore.getCredentials();
    if (creds != null) {
      _savedAppId = creds.apiId;
      _savedAppHash = creds.apiHash;
    }

    final savedPhone = await _secureStore.getUserPhone();
    if (savedPhone != null) {
      _currentPhoneNumber = savedPhone;
    }

    final savedSession = await _secureStore.getSession();
    final savedDcId = await _secureStore.getDcId();
    final savedUserData = await _secureStore.getUserData();

    // If there is an unauthenticated leftover session from incomplete login, clear it
    if (savedUserData == null && savedSession != null) {
      await _secureStore.clearSession();
    }

    // If credentials AND a previously authorized session exist, restore local session immediately
    if (creds != null &&
        savedSession != null &&
        savedSession.isNotEmpty &&
        savedUserData != null) {
      final localUser = NuvexTelegramUser.deserialize(savedUserData);
      if (localUser != null) {
        _currentUser = localUser;
        _status = AuthStatus.authenticated;
        _isRestoringSession = true;
        notifyListeners();

        try {
          final targetDc = savedDcId != null
              ? TelegramDc.forId(savedDcId)
              : TelegramDc.dc2;

          final conn = await _telegramService.connect(
            apiId: creds.apiId,
            apiHash: creds.apiHash,
            savedSessionJson: savedSession,
            dc: targetDc,
          );

          if (conn.isSuccess) {
            _connectedDcId = conn.dcId;
            _authKeyId = conn.authKeyId;
            _isBackendReachable = true;

            final verifiedUser = await _telegramService.verifyExistingSession();
            if (verifiedUser != null) {
              _currentUser = verifiedUser;
              await _persistSessionAndUser(verifiedUser);
            }
          } else {
            // Backend temporarily unreachable (offline or timeout); preserve authenticated state!
            _isBackendReachable = false;
            debugPrint(
              '[AUTH] Backend connection unreachable during startup: ${conn.errorMessage}',
            );
          }
        } on SocketException catch (e) {
          _isBackendReachable = false;
          debugPrint('[AUTH] Offline startup: SocketException ($e)');
        } on TimeoutException catch (e) {
          _isBackendReachable = false;
          debugPrint('[AUTH] Offline startup: TimeoutException ($e)');
        } catch (e) {
          final errStr = e.toString().toUpperCase();
          if (errStr.contains('AUTH_KEY_UNREGISTERED') ||
              errStr.contains('SESSION_REVOKED') ||
              errStr.contains('USER_DEACTIVATED') ||
              errStr.contains('401')) {
            // Actual authentication failure: clear invalid session
            debugPrint('[AUTH] Genuine authentication failure: $e');
            await _secureStore.clearSession();
            _currentUser = null;
            _status = AuthStatus.ready;
            _errorMessage = 'Session expired. Please sign in again.';
            _isRestoringSession = false;
            notifyListeners();
            return;
          } else {
            // Transient network or handshake failure; preserve authenticated state!
            _isBackendReachable = false;
            debugPrint('[AUTH] Startup connection transient error: $e');
          }
        } finally {
          _isRestoringSession = false;
          notifyListeners();
        }
        return;
      }
    }

    _status = AuthStatus.ready;
    notifyListeners();
  }

  /// Attempts to reconnect to the backend if previously unreachable, without affecting authenticated state.
  Future<bool> retryBackendConnection() async {
    if (_status != AuthStatus.authenticated ||
        _isRestoringSession ||
        _savedAppId == null ||
        _savedAppHash == null) {
      return false;
    }
    final savedSession = await _secureStore.getSession();
    if (savedSession == null || savedSession.isEmpty) return false;
    final savedDcId = await _secureStore.getDcId();
    final targetDc = savedDcId != null
        ? TelegramDc.forId(savedDcId)
        : TelegramDc.dc2;

    _isRestoringSession = true;
    notifyListeners();
    try {
      final conn = await _telegramService.connect(
        apiId: _savedAppId!,
        apiHash: _savedAppHash!,
        savedSessionJson: savedSession,
        dc: targetDc,
      );
      if (conn.isSuccess) {
        _connectedDcId = conn.dcId;
        _authKeyId = conn.authKeyId;
        _isBackendReachable = true;
        final verifiedUser = await _telegramService.verifyExistingSession();
        if (verifiedUser != null) {
          _currentUser = verifiedUser;
          await _persistSessionAndUser(verifiedUser);
        }
        return true;
      } else {
        _isBackendReachable = false;
        return false;
      }
    } catch (_) {
      _isBackendReachable = false;
      return false;
    } finally {
      _isRestoringSession = false;
      notifyListeners();
    }
  }

  /// Connects to Telegram MTProto gateway using the provided App ID & Hash.
  Future<bool> connectWithCredentials({
    required int apiId,
    required String apiHash,
  }) async {
    if (_status == AuthStatus.connecting) {
      debugPrint(
        '[AUTH] connection already in progress, skipping duplicate request',
      );
      return false;
    }

    _status = AuthStatus.connecting;
    _errorMessage = null;
    notifyListeners();

    try {
      // 1. Save credentials securely
      await _secureStore.saveCredentials(apiId: apiId, apiHash: apiHash);
      _savedAppId = apiId;
      _savedAppHash = apiHash;

      // 2. Check for existing authorized session (only restore if user was previously authenticated)
      final savedUserData = await _secureStore.getUserData();
      final savedSession = savedUserData != null
          ? await _secureStore.getSession()
          : null;
      final savedDcId = await _secureStore.getDcId();
      final targetDc = savedDcId != null
          ? TelegramDc.forId(savedDcId)
          : TelegramDc.dc2;

      // 3. Connect to Telegram DC
      final result = await _telegramService.connect(
        apiId: apiId,
        apiHash: apiHash,
        savedSessionJson: savedSession,
        dc: targetDc,
      );

      if (result.isSuccess) {
        _connectedDcId = result.dcId;
        _authKeyId = result.authKeyId;
        _errorMessage = null;

        // If a previously saved authorized session was restored, verify it
        if (savedSession != null && savedSession.isNotEmpty) {
          final user = await _telegramService.verifyExistingSession();
          if (user != null) {
            _currentUser = user;
            _status = AuthStatus.authenticated;
            await _persistSessionAndUser(user);
            notifyListeners();
            return true;
          }
        }

        // Ready for phone number
        _status = AuthStatus.connectedWaitingPhone;
        notifyListeners();
        return true;
      } else {
        _status = AuthStatus.error;
        _errorMessage = result.errorMessage;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _status = AuthStatus.error;
      _errorMessage =
          'Connection error: ${TelegramAuthService.cleanException(e)}';
      notifyListeners();
      return false;
    }
  }

  /// Requests Telegram to send an authorization code to [phoneNumber].
  Future<bool> sendCode(String phoneNumber) async {
    if (_status == AuthStatus.sendingCode) {
      debugPrint('[AUTH] sendCode already in progress, ignoring duplicate tap');
      return false;
    }

    final cleanPhone = phoneNumber.replaceAll(RegExp(r'[\s\-\(\)]'), '');
    if (cleanPhone.length < 7) {
      _errorMessage = 'Please enter a complete phone number with country code.';
      notifyListeners();
      return false;
    }

    _status = AuthStatus.sendingCode;
    _errorMessage = null;
    notifyListeners();

    try {
      final result = await _telegramService.sendCode(cleanPhone);

      if (result.isSuccess) {
        _currentPhoneNumber = cleanPhone;
        _phoneCodeHash = result.phoneCodeHash;
        _codeTimeoutSeconds = result.timeout;
        _status = AuthStatus.waitingCode;
        _errorMessage = null;
        await _secureStore.saveUserPhone(cleanPhone);
        return true;
      } else {
        _status = AuthStatus.connectedWaitingPhone;
        _errorMessage = result.errorMessage;
        return false;
      }
    } catch (e) {
      _status = AuthStatus.connectedWaitingPhone;
      _errorMessage =
          'Failed to send code: ${TelegramAuthService.cleanException(e)}';
      return false;
    } finally {
      // Guaranteed safety: if still sendingCode, reset to waitingPhone
      if (_status == AuthStatus.sendingCode) {
        _status = AuthStatus.connectedWaitingPhone;
      }
      notifyListeners();
    }
  }

  /// Verifies the verification code received from Telegram.
  Future<bool> verifyCode(String code) async {
    if (_status == AuthStatus.verifyingCode) {
      debugPrint(
        '[AUTH] verifyCode already in progress, ignoring duplicate tap',
      );
      return false;
    }

    final cleanCode = code.trim().replaceAll(RegExp(r'\D'), '');
    if (cleanCode.isEmpty) {
      _errorMessage = 'Please enter the verification code.';
      notifyListeners();
      return false;
    }

    if (_currentPhoneNumber == null || _phoneCodeHash == null) {
      _errorMessage = 'Session expired. Please request a new code.';
      _status = AuthStatus.connectedWaitingPhone;
      notifyListeners();
      return false;
    }

    _status = AuthStatus.verifyingCode;
    _errorMessage = null;
    notifyListeners();

    try {
      final result = await _telegramService.signIn(
        phoneNumber: _currentPhoneNumber!,
        phoneCodeHash: _phoneCodeHash!,
        phoneCode: cleanCode,
      );

      if (result.isAuthorized) {
        _currentUser = result.user;
        _status = AuthStatus.authenticated;
        _errorMessage = null;
        await _persistSessionAndUser(result.user);
        return true;
      } else if (result.isPasswordNeeded) {
        _status = AuthStatus.waitingPassword;
        _errorMessage = null;
        return false;
      } else {
        _status = AuthStatus.waitingCode;
        _errorMessage = result.errorMessage;
        return false;
      }
    } catch (e) {
      _status = AuthStatus.waitingCode;
      _errorMessage =
          'Verification error: ${TelegramAuthService.cleanException(e)}';
      return false;
    } finally {
      if (_status == AuthStatus.verifyingCode) {
        _status = AuthStatus.waitingCode;
      }
      notifyListeners();
    }
  }

  /// Verifies the 2FA password with Telegram.
  Future<bool> verifyPassword(String password) async {
    if (_status == AuthStatus.verifyingPassword) {
      debugPrint(
        '[AUTH] verifyPassword already in progress, ignoring duplicate tap',
      );
      return false;
    }

    if (password.isEmpty) {
      _errorMessage = 'Please enter your 2-step verification password.';
      notifyListeners();
      return false;
    }

    _status = AuthStatus.verifyingPassword;
    _errorMessage = null;
    notifyListeners();

    try {
      final result = await _telegramService.checkPassword(password);

      if (result.isAuthorized) {
        _currentUser = result.user;
        _status = AuthStatus.authenticated;
        _errorMessage = null;
        await _persistSessionAndUser(result.user);
        return true;
      } else {
        _status = AuthStatus.waitingPassword;
        _errorMessage = result.errorMessage;
        return false;
      }
    } catch (e) {
      _status = AuthStatus.waitingPassword;
      _errorMessage =
          'Password error: ${TelegramAuthService.cleanException(e)}';
      return false;
    } finally {
      if (_status == AuthStatus.verifyingPassword) {
        _status = AuthStatus.waitingPassword;
      }
      notifyListeners();
    }
  }

  /// Resends the verification code.
  Future<bool> resendCode() async {
    if (_currentPhoneNumber == null) return false;
    return sendCode(_currentPhoneNumber!);
  }

  /// Persists session key and user info in hardware-encrypted storage AFTER authorization.
  Future<void> _persistSessionAndUser(NuvexTelegramUser? user) async {
    final sessionJson = _telegramService.exportSession();
    if (sessionJson != null) {
      await _secureStore.saveSession(sessionJson);
    }
    await _secureStore.saveDcId(_telegramService.currentDc.id);
    if (user != null) {
      await _secureStore.saveUserData(user.serialize());
    }
    if (_currentPhoneNumber != null) {
      await _secureStore.saveUserPhone(_currentPhoneNumber!);
    }
  }

  /// Resets back to ready state.
  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  /// Refreshes the authorized user profile from Telegram MTProto.
  Future<bool> refreshCurrentUser() async {
    try {
      final user = await _telegramService.verifyExistingSession();
      if (user != null) {
        _currentUser = user;
        await _secureStore.saveUserData(user.serialize());
        notifyListeners();
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// Logs out and purges saved Telegram session.
  Future<void> logout() async {
    await _telegramService.disconnect();
    await _secureStore.clearSession();
    _currentUser = null;
    _currentPhoneNumber = null;
    _phoneCodeHash = null;
    _status = AuthStatus.ready;
    notifyListeners();
  }
}
