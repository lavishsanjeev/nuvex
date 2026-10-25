import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure credential and session persistence utilizing Android KeyStore
/// and platform secure hardware.
///
/// Complies with Nuvex privacy standards:
/// - No credentials, hashes, or session tokens are ever logged.
/// - Data is encrypted at rest using platform security hardware.
class NuvexSecureStore {
  static const String _keyApiId = 'nuvex_api_id';
  static const String _keyApiHash = 'nuvex_api_hash';
  static const String _keySession = 'nuvex_session_data';
  static const String _keyUserPhone = 'nuvex_user_phone';

  static const String _keyDcId = 'nuvex_dc_id';
  static const String _keyUserData = 'nuvex_user_data';

  final FlutterSecureStorage _storage;

  const NuvexSecureStore([
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  ]) : _storage = storage;

  /// Saves App ID and App Hash securely.
  Future<void> saveCredentials({
    required int apiId,
    required String apiHash,
  }) async {
    await _storage.write(key: _keyApiId, value: apiId.toString());
    await _storage.write(key: _keyApiHash, value: apiHash);
  }

  /// Retrieves saved credentials if available.
  Future<({int apiId, String apiHash})?> getCredentials() async {
    final idStr = await _storage.read(key: _keyApiId);
    final hash = await _storage.read(key: _keyApiHash);

    if (idStr == null || hash == null) {
      return null;
    }

    final id = int.tryParse(idStr);
    if (id == null || id <= 0 || hash.isEmpty) {
      return null;
    }

    return (apiId: id, apiHash: hash);
  }

  /// Saves the authorized MTProto session string/JSON.
  Future<void> saveSession(String sessionData) async {
    await _storage.write(key: _keySession, value: sessionData);
  }

  /// Retrieves the saved session if available.
  Future<String?> getSession() async {
    return _storage.read(key: _keySession);
  }

  /// Saves the connected DC ID.
  Future<void> saveDcId(int dcId) async {
    await _storage.write(key: _keyDcId, value: dcId.toString());
  }

  /// Retrieves the saved DC ID if available.
  Future<int?> getDcId() async {
    final str = await _storage.read(key: _keyDcId);
    return str != null ? int.tryParse(str) : null;
  }

  /// Saves the authenticated user phone number.
  Future<void> saveUserPhone(String phone) async {
    await _storage.write(key: _keyUserPhone, value: phone);
  }

  /// Retrieves the authenticated user phone number.
  Future<String?> getUserPhone() async {
    return _storage.read(key: _keyUserPhone);
  }

  /// Saves serialized user data.
  Future<void> saveUserData(String userDataJson) async {
    await _storage.write(key: _keyUserData, value: userDataJson);
  }

  /// Retrieves serialized user data.
  Future<String?> getUserData() async {
    return _storage.read(key: _keyUserData);
  }

  /// Generic read for secure feature storage.
  Future<String?> read({required String key}) => _storage.read(key: key);

  /// Generic write for secure feature storage.
  Future<void> write({required String key, required String? value}) =>
      _storage.write(key: key, value: value);

  /// Generic delete for secure feature storage.
  Future<void> delete({required String key}) => _storage.delete(key: key);

  /// Clears only the session token and user info (e.g. on logout or session expiry).
  Future<void> clearSession() async {
    await _storage.delete(key: _keySession);
    await _storage.delete(key: _keyUserPhone);
    await _storage.delete(key: _keyDcId);
    await _storage.delete(key: _keyUserData);
  }

  /// Clears all stored data (credentials + session).
  Future<void> clearAll() async {
    await _storage.deleteAll();
  }
}
