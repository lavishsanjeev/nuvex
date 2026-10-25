import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/key_derivators/api.dart';
import 'package:pointycastle/key_derivators/pbkdf2.dart';
import 'package:pointycastle/macs/hmac.dart';

import '../../../core/storage/secure_storage.dart';

/// Service managing Locked Folder PIN, salted cryptographic verification,
/// Android hardware biometrics, and Keystore master encryption key.
///
/// Security architecture:
/// - PIN is NEVER stored in plaintext.
/// - Salted PBKDF2-HMAC-SHA256 with 100,000 iterations for key verification.
/// - 256-bit AES master encryption key generated cryptographically and stored
///   in Android Keystore-backed secure storage.
/// - Real Android BiometricPrompt via local_auth.
/// - PIN failure rate limiting (5 consecutive failures = 30 second cooldown).
/// - Documented recovery policy: biometrics cannot recover a forgotten PIN.
class LockedFolderAuthService {
  final NuvexSecureStore _secureStore;
  final LocalAuthentication _localAuth;

  // Secure storage keys
  static const _keyPinSalt = 'nuvex_locked_pin_salt';
  static const _keyPinHash = 'nuvex_locked_pin_hash';
  static const _keyMasterKey = 'nuvex_locked_master_key';
  static const _keyBiometricsEnabled = 'nuvex_locked_biometrics_enabled';
  static const _keyFailedAttempts = 'nuvex_locked_failed_attempts';
  static const _keyLockoutUntil = 'nuvex_locked_lockout_until';

  // Constants
  static const int _pbkdf2Iterations = 100000;
  static const int _saltBytesLength = 16;
  static const int _derivedKeyBytesLength = 32;
  static const int _maxFailedAttempts = 5;
  static const Duration _lockoutDuration = Duration(seconds: 30);

  LockedFolderAuthService({
    NuvexSecureStore? secureStore,
    LocalAuthentication? localAuth,
  })  : _secureStore = secureStore ?? NuvexSecureStore(),
        _localAuth = localAuth ?? LocalAuthentication();

  /// Whether the user has configured a PIN for the Locked Folder.
  Future<bool> isSetupComplete() async {
    final hash = await _secureStore.read(key: _keyPinHash);
    final masterKey = await _secureStore.read(key: _keyMasterKey);
    return hash != null && hash.isNotEmpty && masterKey != null && masterKey.isNotEmpty;
  }

  /// Sets up a new PIN for the first time, generating a 256-bit Master Key.
  Future<void> setupPin(String pin, {bool enableBiometrics = true}) async {
    if (pin.length < 4) {
      throw ArgumentError('PIN must be at least 4 digits');
    }

    // 1. Generate cryptographically random salt
    final salt = _generateRandomBytes(_saltBytesLength);
    final saltHex = _toHex(salt);

    // 2. Compute salted PBKDF2 hash
    final hash = _computePbkdf2Hash(pin, salt);
    final hashHex = _toHex(hash);

    // 3. Generate 256-bit (32 bytes) Master Encryption Key
    final masterKey = _generateRandomBytes(32);
    final masterKeyHex = _toHex(masterKey);

    // 4. Save credentials to Android Keystore-backed storage
    await _secureStore.write(key: _keyPinSalt, value: saltHex);
    await _secureStore.write(key: _keyPinHash, value: hashHex);
    await _secureStore.write(key: _keyMasterKey, value: masterKeyHex);
    await _secureStore.write(
      key: _keyBiometricsEnabled,
      value: enableBiometrics.toString(),
    );
    await _resetFailedAttempts();
  }

  /// Verifies the entered PIN against the stored PBKDF2 hash.
  /// Throws an [Exception] if the folder is currently rate-limited/locked out.
  Future<bool> verifyPin(String pin) async {
    final lockoutSeconds = await getRemainingLockoutSeconds();
    if (lockoutSeconds > 0) {
      throw Exception('Too many attempts. Please try again in $lockoutSeconds seconds.');
    }

    final storedSaltHex = await _secureStore.read(key: _keyPinSalt);
    final storedHashHex = await _secureStore.read(key: _keyPinHash);

    if (storedSaltHex == null || storedHashHex == null) {
      return false;
    }

    final salt = _fromHex(storedSaltHex);
    final computedHash = _computePbkdf2Hash(pin, salt);
    final computedHashHex = _toHex(computedHash);

    final bool isMatch = _constantTimeCompare(computedHashHex, storedHashHex);

    if (isMatch) {
      await _resetFailedAttempts();
      return true;
    } else {
      await _recordFailedAttempt();
      return false;
    }
  }

  /// Changes the user's PIN after verifying the current PIN.
  Future<void> changePin({
    required String oldPin,
    required String newPin,
  }) async {
    if (newPin.length < 4) {
      throw ArgumentError('New PIN must be at least 4 digits');
    }

    final isOldValid = await verifyPin(oldPin);
    if (!isOldValid) {
      throw Exception('Current PIN is incorrect');
    }

    // Preserve the master encryption key so existing files remain decryptable
    final salt = _generateRandomBytes(_saltBytesLength);
    final saltHex = _toHex(salt);
    final hash = _computePbkdf2Hash(newPin, salt);
    final hashHex = _toHex(hash);

    await _secureStore.write(key: _keyPinSalt, value: saltHex);
    await _secureStore.write(key: _keyPinHash, value: hashHex);
    await _resetFailedAttempts();
  }

  /// Authenticates using Android biometric authentication (fingerprint/face).
  Future<bool> authenticateWithBiometrics({
    String reason = 'Authenticate to access Locked Folder',
  }) async {
    final isEnabled = await isBiometricsEnabled();
    if (!isEnabled) return false;

    final canCheck = await _localAuth.canCheckBiometrics;
    final isDeviceSupported = await _localAuth.isDeviceSupported();

    if (!canCheck && !isDeviceSupported) {
      return false;
    }

    try {
      final success = await _localAuth.authenticate(
        localizedReason: reason,
        biometricOnly: true,
      );

      if (success) {
        await _resetFailedAttempts();
      }
      return success;
    } catch (e) {
      debugPrint('[LOCKED_AUTH] Biometric authentication error: $e');
      return false;
    }
  }

  /// Checks if the device hardware supports biometrics and has enrolled biometrics.
  Future<bool> isBiometricsAvailable() async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final isSupported = await _localAuth.isDeviceSupported();
      if (!canCheck && !isSupported) return false;
      final available = await _localAuth.getAvailableBiometrics();
      return available.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Whether biometric authentication is currently enabled by the user.
  Future<bool> isBiometricsEnabled() async {
    final value = await _secureStore.read(key: _keyBiometricsEnabled);
    return value == 'true';
  }

  /// Toggles biometric unlock on or off.
  Future<void> setBiometricsEnabled(bool enabled) async {
    await _secureStore.write(
      key: _keyBiometricsEnabled,
      value: enabled.toString(),
    );
  }

  /// Retrieves the 256-bit Master Encryption Key in bytes for media cipher operations.
  Future<Uint8List> getMasterKey() async {
    final masterKeyHex = await _secureStore.read(key: _keyMasterKey);
    if (masterKeyHex == null || masterKeyHex.isEmpty) {
      throw StateError('Locked Folder master encryption key is not initialized');
    }
    return _fromHex(masterKeyHex);
  }

  /// Resets the Locked Folder configuration.
  ///
  /// Recovery policy:
  /// Biometric authentication cannot recover a forgotten PIN. If the PIN is forgotten,
  /// the user can reset the Locked Folder to configure a new PIN. Existing encrypted
  /// local files are removed to ensure cryptographic privacy and prevent unauthorized access.
  Future<void> resetLockedFolder() async {
    await _secureStore.delete(key: _keyPinSalt);
    await _secureStore.delete(key: _keyPinHash);
    await _secureStore.delete(key: _keyMasterKey);
    await _secureStore.delete(key: _keyBiometricsEnabled);
    await _resetFailedAttempts();
  }

  /// Checks remaining seconds of attempt throttling lockout, or 0 if not locked out.
  Future<int> getRemainingLockoutSeconds() async {
    final lockoutUntilStr = await _secureStore.read(key: _keyLockoutUntil);
    if (lockoutUntilStr == null) return 0;

    final lockoutUntilMs = int.tryParse(lockoutUntilStr) ?? 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final diffMs = lockoutUntilMs - nowMs;

    if (diffMs <= 0) {
      await _secureStore.delete(key: _keyLockoutUntil);
      return 0;
    }
    return (diffMs / 1000).ceil();
  }

  Future<void> _recordFailedAttempt() async {
    final currentStr = await _secureStore.read(key: _keyFailedAttempts);
    final count = (int.tryParse(currentStr ?? '0') ?? 0) + 1;

    if (count >= _maxFailedAttempts) {
      final lockoutUntil = DateTime.now().add(_lockoutDuration).millisecondsSinceEpoch;
      await _secureStore.write(key: _keyLockoutUntil, value: lockoutUntil.toString());
      await _secureStore.write(key: _keyFailedAttempts, value: '0');
    } else {
      await _secureStore.write(key: _keyFailedAttempts, value: count.toString());
    }
  }

  Future<void> _resetFailedAttempts() async {
    await _secureStore.delete(key: _keyFailedAttempts);
    await _secureStore.delete(key: _keyLockoutUntil);
  }

  // ── Cryptographic Utilities ──

  Uint8List _computePbkdf2Hash(String pin, Uint8List salt) {
    final derivator = PBKDF2KeyDerivator(
      HMac(SHA256Digest(), 64),
    );
    derivator.init(
      Pbkdf2Parameters(salt, _pbkdf2Iterations, _derivedKeyBytesLength),
    );
    final pinBytes = utf8.encode(pin);
    return derivator.process(Uint8List.fromList(pinBytes));
  }

  Uint8List _generateRandomBytes(int length) {
    final rnd = Random.secure();
    final bytes = Uint8List(length);
    for (int i = 0; i < length; i++) {
      bytes[i] = rnd.nextInt(256);
    }
    return bytes;
  }

  String _toHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Uint8List _fromHex(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }

  bool _constantTimeCompare(String a, String b) {
    if (a.length != b.length) return false;
    int result = 0;
    for (int i = 0; i < a.length; i++) {
      result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return result == 0;
  }
}
