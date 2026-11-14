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

  /// VC 100134 Package C — persisted email-verification flag
  /// ('true' / 'false' strings). Absent means verified
  /// (grandfathering + client-first rollout safety): only an
  /// explicit 'false' gates a restored session.
  static const _emailVerifiedKey = 'email_verified';

  final FlutterSecureStorage _storage;

  SessionStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  Future<void> saveSession({
    required String token,
    required String refreshToken,
    required String email,
    bool? emailVerified,
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
    // VC 100134 — the verified flag is written LAST, after the
    // email, and only when the caller carries one: it is a
    // routing-only value like the email (a lagging write can never
    // strand the session), and callers that know nothing about
    // verification (the refresh rotation path) must leave a stored
    // flag untouched rather than clobber it.
    if (emailVerified != null) {
      await _storage.write(
        key: _emailVerifiedKey,
        value: emailVerified ? 'true' : 'false',
      );
    }
  }

  /// VC 100134 — persist ONLY the verified flag (post-verify
  /// success). Touches nothing else in the session.
  Future<void> saveEmailVerified(bool verified) async {
    await _storage.write(
      key: _emailVerifiedKey,
      value: verified ? 'true' : 'false',
    );
  }

  /// VC 100134 — the stored verified flag, or null when absent or
  /// malformed. Callers treat null as VERIFIED (see the key doc).
  Future<bool?> readEmailVerified() async {
    final raw = await _storage.read(key: _emailVerifiedKey);
    if (raw == 'true') return true;
    if (raw == 'false') return false;
    return null;
  }

  /// H1-02 — persist ONLY a rotated token pair, leaving the
  /// stored email untouched.
  ///
  /// Used by the refresh path after the server has already
  /// rotated the refresh token: the rotated pair must be
  /// persisted even when the account email cannot be re-read
  /// (a transient keystore failure, or a null/empty read), and
  /// the previously stored `user_email` must never be
  /// overwritten with '' in that situation — email-scoped
  /// local stores normalize '' to null and would silently
  /// unbind. Same load-bearing write order as [saveSession]:
  /// refresh token first, then access token, so a crash
  /// between the two leaves the self-healing mixed pair.
  Future<void> saveRotatedTokens({
    required String token,
    required String refreshToken,
  }) async {
    await _storage.write(key: _refreshTokenKey, value: refreshToken);
    await _storage.write(key: _tokenKey, value: token);
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
    try {
      await _storage.delete(key: _emailVerifiedKey);
    } catch (_) {}
  }
}
