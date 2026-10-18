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
    // WRITE ORDER IS LOAD-BEARING (Round 31 fix pass, Vera
    // SHOULD-FIX 1): the refresh token is written BEFORE the
    // access token. Secure storage offers no multi-key atomicity,
    // so a crash between the two token writes leaves a mixed pair:
    // - refresh-first (this order): OLD access + NEW refresh. The
    //   stale access token simply 401s at next use and the 401 →
    //   refresh path exchanges the new refresh token for a fresh
    //   pair — the session self-heals.
    // - access-first (the old order): NEW access + OLD refresh.
    //   The old refresh token was already rotated out (revoked)
    //   by the refresh that produced this pair, so the next
    //   refresh fails definitively — a guaranteed logout.
    // Residual risk: the pair is still not atomic. A crash in the
    // window leaves the mixed pair above (self-healing, per the
    // first bullet) until the next refresh completes, and the
    // email — written last, display-only — can lag one save
    // behind. Neither can strand the session.
    await _storage.write(key: _refreshTokenKey, value: refreshToken);
    await _storage.write(key: _tokenKey, value: token);
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
