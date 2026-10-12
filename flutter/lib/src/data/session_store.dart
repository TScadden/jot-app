import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Round 5 — secure session persistence.
///
/// The native app encrypts the access/refresh tokens with `NotelCrypto`
/// before writing them to DataStore (`NotelPreferences.saveSessionAtomically`).
/// The Flutter equivalent is flutter_secure_storage, which uses the
/// Android Keystore-backed EncryptedSharedPreferences on Android.
///
/// Only tokens and the account email live here. The password is NEVER
/// persisted — it exists in memory only for the duration of the login
/// request (see [AuthApiClient]).
class SessionStore {
  static const _tokenKey = 'auth_token';
  static const _refreshTokenKey = 'refresh_token';
  static const _emailKey = 'user_email';

  final FlutterSecureStorage _storage;

  SessionStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  Future<void> saveSession({
    required String token,
    required String refreshToken,
    required String email,
  }) async {
    await _storage.write(key: _tokenKey, value: token);
    await _storage.write(key: _refreshTokenKey, value: refreshToken);
    await _storage.write(key: _emailKey, value: email);
  }

  Future<String?> readToken() => _storage.read(key: _tokenKey);

  /// Round 29 — the stored refresh token, needed by the native-parity
  /// logout call (`POST /api/auth/logout` with `{refreshToken}`).
  Future<String?> readRefreshToken() => _storage.read(key: _refreshTokenKey);

  Future<String?> readEmail() => _storage.read(key: _emailKey);

  Future<void> clear() async {
    // Each delete isolated (R29b): one failing storage delete must
    // not leave the other session values behind, and must not throw
    // into the logout/delete wipe and skip the cache clears that
    // follow it.
    try {
      await _storage.delete(key: _tokenKey);
    } catch (_) {}
    try {
      await _storage.delete(key: _refreshTokenKey);
    } catch (_) {}
    try {
      await _storage.delete(key: _emailKey);
    } catch (_) {}
  }
}
