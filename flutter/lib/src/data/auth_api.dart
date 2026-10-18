import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Round 5 — real authentication against the Tabs backend.
///
/// Mirrors the native app's `LoginViewModel.login()` (`LoginScreen.kt`):
/// - Endpoint: `POST https://api.jottracker.com/api/auth/login`
///   (see `TabsApi.login` in `data/remote/JotApi.kt`; base URL from
///   `di/AppModule.kt`). The login route is a public auth endpoint —
///   no bearer token, no special headers, just JSON.
/// - Request body: `{"email": ..., "password": ..., "ageConfirmed": false}`
///   (see `AuthRequest` in `JotApi.kt`).
/// - Success: HTTP 200 with a JSON body containing `token`
///   (plus `refreshToken`, `userId`, `email` — see `AuthResponse`).
/// - Failure: non-2xx. The server returns `{"error": "..."}`; the HTTP
///   status distinguishes the two cases the founder cares about:
///   404 = no account with that email (verified against the live API),
///   401 = wrong password.
///
/// Security rules (Vera):
/// - HTTPS only — the base URL is hard-coded with the https scheme and
///   there is no http fallback.
/// - The password and token are NEVER logged, printed, or included in
///   exceptions/toString. The password lives in memory only for the
///   duration of the request.
/// - The session token is persisted via [SessionStore]
///   (flutter_secure_storage), never plain preferences.
/// - Tests must mock [http.Client]; no real credentials in tests.
class AuthApiClient {
  static const String defaultBaseUrl = 'https://api.jottracker.com';

  final http.Client _client;
  final String _baseUrl;

  AuthApiClient({http.Client? client, this._baseUrl = defaultBaseUrl})
      : _client = client ?? http.Client();

  /// Attempts email+password login.
  ///
  /// Returns [LoginSuccess] with the session on HTTP 200 + non-blank
  /// token, otherwise a [LoginFailure] whose [LoginFailureKind]
  /// distinguishes wrong-password from nonexistent-account.
  Future<LoginResult> login({
    required String email,
    required String password,
  }) async {
    final uri = Uri.parse('$_baseUrl/api/auth/login');
    http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'email': email,
              'password': password,
              'ageConfirmed': false,
            }),
          )
          .timeout(const Duration(seconds: 20));
    } on TimeoutException {
      return const LoginFailure(
        LoginFailureKind.network,
        "Couldn't reach the server. Check your connection and try again.",
      );
    } on SocketException {
      return const LoginFailure(
        LoginFailureKind.network,
        "Couldn't reach the server. Check your connection and try again.",
      );
    } on HttpException {
      return const LoginFailure(
        LoginFailureKind.network,
        "Couldn't reach the server. Check your connection and try again.",
      );
    } catch (_) {
      // Deliberately generic: never leak transport details.
      return const LoginFailure(
        LoginFailureKind.network,
        "Couldn't reach the server. Check your connection and try again.",
      );
    }

    if (response.statusCode == 200) {
      final body = _decodeJson(response.body);
      final token = body['token']?.toString() ?? '';
      if (token.isNotBlank) {
        return LoginSuccess(
          token: token,
          refreshToken: body['refreshToken']?.toString() ?? '',
          userId: body['userId']?.toString(),
          email: body['email']?.toString() ?? email,
        );
      }
      // 200 without a token is a server bug — treat as a server error.
      return const LoginFailure(
        LoginFailureKind.server,
        'Something went wrong. Please try again.',
      );
    }

    if (response.statusCode == 404) {
      return const LoginFailure(
        LoginFailureKind.accountNotFound,
        "That account doesn't exist.",
      );
    }

    if (response.statusCode == 401) {
      return const LoginFailure(
        LoginFailureKind.wrongCredentials,
        'Wrong password or email.',
      );
    }

    // Other 4xx/5xx: surface the server's message when it has one,
    // otherwise a generic fallback. Never echo the request back.
    final serverMessage = _decodeJson(response.body)['error']?.toString();
    return LoginFailure(
      LoginFailureKind.server,
      (serverMessage?.isNotBlank ?? false)
          ? serverMessage!
          : 'Something went wrong. Please try again.',
    );
  }

  /// Round 32 — real registration, mirroring native
  /// `LoginViewModel.register()` (`LoginScreen.kt:252-296`):
  /// `POST https://api.jottracker.com/api/auth/register` with
  /// `{"email": ..., "password": ..., "ageConfirmed": ...}`
  /// (`AuthRequest`, JotApi.kt:119-123; endpoint JotApi.kt:559-560).
  ///
  /// Success: HTTP 200 + non-blank `token` → [LoginSuccess] (the same
  /// `AuthResponse` shape as login). Native's register does NOT mark
  /// onboarding complete — the new account enters onboarding
  /// (`onboardingCompleteByServer = false` in native) — so callers
  /// must route a register success into onboarding, not home.
  ///
  /// Failure: the server's `{"error": "..."}` message verbatim when
  /// present (native: `body?.error ?: "Registration failed"`),
  /// otherwise the native fallback. Transport failures use the same
  /// generic network message as [login]. The password is never
  /// logged, printed, or included in any error (Vera rule).
  Future<LoginResult> register({
    required String email,
    required String password,
    required bool ageConfirmed,
  }) async {
    final uri = Uri.parse('$_baseUrl/api/auth/register');
    http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'email': email,
              'password': password,
              'ageConfirmed': ageConfirmed,
            }),
          )
          .timeout(const Duration(seconds: 20));
    } on TimeoutException {
      return const LoginFailure(
        LoginFailureKind.network,
        "Couldn't reach the server. Check your connection and try again.",
      );
    } on SocketException {
      return const LoginFailure(
        LoginFailureKind.network,
        "Couldn't reach the server. Check your connection and try again.",
      );
    } on HttpException {
      return const LoginFailure(
        LoginFailureKind.network,
        "Couldn't reach the server. Check your connection and try again.",
      );
    } catch (_) {
      return const LoginFailure(
        LoginFailureKind.network,
        "Couldn't reach the server. Check your connection and try again.",
      );
    }

    if (response.statusCode == 200) {
      final body = _decodeJson(response.body);
      final token = body['token']?.toString() ?? '';
      if (token.isNotBlank) {
        return LoginSuccess(
          token: body['token']?.toString() ?? '',
          refreshToken: body['refreshToken']?.toString() ?? '',
          userId: body['userId']?.toString(),
          email: body['email']?.toString() ?? email,
        );
      }
      return const LoginFailure(
        LoginFailureKind.server,
        'Registration failed',
      );
    }

    final serverMessage = _decodeJson(response.body)['error']?.toString();
    return LoginFailure(
      LoginFailureKind.server,
      (serverMessage?.isNotBlank ?? false)
          ? serverMessage!
          : 'Registration failed',
    );
  }

  /// Round 24 — Google sign-in against the Tabs backend.
  ///
  /// Mirrors the native flow (`LoginScreen.kt` + `JotApi.kt`):
  /// `POST api/auth/google` with `{"idToken": ..., "isRegisterMode":
  /// ..., "ageConfirmed": ...}`, returning the same `AuthResponse`
  /// as password login. The server verifies the ID token with
  /// google-auth-library (audience = the web client ID in
  /// `google_sign_in_service.dart`).
  ///
  /// Unlike [login], non-200 responses are NOT mapped to fixed
  /// 404/401 strings: the server's own `{"error": "..."}` message is
  /// surfaced verbatim as a server failure (e.g. login mode with no
  /// account → "No account was found with that Google account.
  /// Please sign up first."), falling back to the generic server
  /// message when the body carries no usable error.
  ///
  /// The ID token is never logged, printed, or included in
  /// exceptions (Vera rule) — it lives in memory only for the
  /// duration of the request, same as the password in [login].
  Future<LoginResult> googleLogin({
    required String idToken,
    required bool isRegisterMode,
    required bool ageConfirmed,
  }) async {
    final uri = Uri.parse('$_baseUrl/api/auth/google');
    http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'idToken': idToken,
              'isRegisterMode': isRegisterMode,
              'ageConfirmed': ageConfirmed,
            }),
          )
          .timeout(const Duration(seconds: 20));
    } on TimeoutException {
      return const LoginFailure(
        LoginFailureKind.network,
        "Couldn't reach the server. Check your connection and try again.",
      );
    } on SocketException {
      return const LoginFailure(
        LoginFailureKind.network,
        "Couldn't reach the server. Check your connection and try again.",
      );
    } on HttpException {
      return const LoginFailure(
        LoginFailureKind.network,
        "Couldn't reach the server. Check your connection and try again.",
      );
    } catch (_) {
      // Deliberately generic: never leak transport details.
      return const LoginFailure(
        LoginFailureKind.network,
        "Couldn't reach the server. Check your connection and try again.",
      );
    }

    if (response.statusCode == 200) {
      final body = _decodeJson(response.body);
      final token = body['token']?.toString() ?? '';
      if (token.isNotBlank) {
        return LoginSuccess(
          token: token,
          refreshToken: body['refreshToken']?.toString() ?? '',
          userId: body['userId']?.toString(),
          // No typed email on this flow — the account email comes
          // back in the AuthResponse, same as password login.
          email: body['email']?.toString() ?? '',
        );
      }
      // 200 without a token is a server bug — treat as a server error.
      return const LoginFailure(
        LoginFailureKind.server,
        'Something went wrong. Please try again.',
      );
    }

    // Any non-200: surface the server's real message verbatim when
    // it has one, otherwise a generic fallback. Never echo the
    // request (and never the ID token) back.
    final serverMessage = _decodeJson(response.body)['error']?.toString();
    return LoginFailure(
      LoginFailureKind.server,
      (serverMessage?.isNotBlank ?? false)
          ? serverMessage!
          : 'Something went wrong. Please try again.',
    );
  }

  /// Round 31 — refresh-token exchange, mirroring the native
  /// `AuthInterceptor.performRefresh` taxonomy exactly.
  ///
  /// Endpoint: `POST /api/auth/refresh-token` with JSON body
  /// `{"refreshToken": ...}` → `{"token": ..., "refreshToken": ...,
  /// "error": ...}`. Both tokens rotate on success.
  ///
  /// Result taxonomy (native parity — do not widen or narrow).
  /// The checks run STATUS-FIRST, in exactly this order (native
  /// `AuthInterceptor.performRefresh` gates its error-string check
  /// to successful responses):
  /// 1. HTTP 401 or 403 → [RefreshDefinitiveFailure]. Status alone
  ///    decides; the body is never inspected.
  /// 2. Any other non-200 status → [RefreshTemporaryFailure]. This
  ///    covers 5xx AND every other non-2xx (400 included) — an
  ///    `error` string on a non-200 response is NEVER definitive,
  ///    even when it contains a keyword below.
  /// 3. Only on HTTP 200 is the body inspected: the `error` string
  ///    (lowercased) containing "expired", "revoked", "invalid",
  ///    or "disabled" → [RefreshDefinitiveFailure]; a non-blank
  ///    `token` AND non-blank `refreshToken` → [RefreshSuccess];
  ///    anything else (blank tokens, unparseable body) →
  ///    [RefreshTemporaryFailure].
  /// - Transport failures (network exception/timeout) are always
  ///   [RefreshTemporaryFailure]. The session MUST be preserved on
  ///   every temporary outcome.
  ///
  /// The refresh token is never logged, printed, or included in
  /// exceptions (Vera rule) — it lives in memory only for the
  /// duration of the request, same as the password in [login].
  Future<RefreshResult> refreshSession(String refreshToken) async {
    final uri = Uri.parse('$_baseUrl/api/auth/refresh-token');
    http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'refreshToken': refreshToken}),
          )
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      // Timeout / socket / TLS / anything transport — temporary.
      // Deliberately generic: never leak transport details.
      return const RefreshTemporaryFailure();
    }

    // Taxonomy step 1: 401/403 are definitive on status alone.
    if (response.statusCode == 401 || response.statusCode == 403) {
      return const RefreshDefinitiveFailure();
    }

    // Taxonomy step 2: every other non-200 is temporary — 5xx, 400,
    // anything. The error-string keyword check below must NEVER run
    // against a non-200 body: a 500 carrying {"error":"invalid
    // token"} is a server blip, not a dead session (native gates
    // the keyword check to successful responses).
    if (response.statusCode != 200) {
      return const RefreshTemporaryFailure();
    }

    // Taxonomy step 3 (HTTP 200 only): keyword check on the error
    // string, then the rotated-pair check.
    final body = _decodeJson(response.body);
    final error = body['error']?.toString().toLowerCase() ?? '';
    if (error.contains('expired') ||
        error.contains('revoked') ||
        error.contains('invalid') ||
        error.contains('disabled')) {
      return const RefreshDefinitiveFailure();
    }

    final token = body['token']?.toString() ?? '';
    final newRefreshToken = body['refreshToken']?.toString() ?? '';
    if (token.isNotBlank && newRefreshToken.isNotBlank) {
      return RefreshSuccess(token: token, refreshToken: newRefreshToken);
    }
    // 200 with blank tokens — server bug, NOT a dead session.
    return const RefreshTemporaryFailure();
  }

  Map<String, dynamic> _decodeJson(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // Not JSON — fall through to an empty map.
    }
    return const {};
  }

  void close() => _client.close();
}

/// Outcome of [AuthApiClient.login]. Never carries the password.
sealed class LoginResult {
  const LoginResult();
}

/// Successful login. [token] is the session access token.
class LoginSuccess extends LoginResult {
  final String token;
  final String refreshToken;
  final String? userId;
  final String email;

  const LoginSuccess({
    required this.token,
    required this.refreshToken,
    this.userId,
    required this.email,
  });
}

/// Failed login. [message] is the exact user-facing string to show.
class LoginFailure extends LoginResult {
  final LoginFailureKind kind;
  final String message;

  const LoginFailure(this.kind, this.message);
}

/// Outcome of [AuthApiClient.refreshSession]. Never carries error
/// text or tokens beyond the rotated pair on success.
sealed class RefreshResult {
  const RefreshResult();
}

/// Refresh succeeded — both tokens rotated; save BOTH.
class RefreshSuccess extends RefreshResult {
  final String token;
  final String refreshToken;

  const RefreshSuccess({required this.token, required this.refreshToken});
}

/// The refresh token is genuinely dead (rejected / expired /
/// revoked / invalid / disabled). The session must be cleared.
class RefreshDefinitiveFailure extends RefreshResult {
  const RefreshDefinitiveFailure();
}

/// Refresh could not complete for a transient reason. The stored
/// session MUST be preserved — never log the user out on this.
class RefreshTemporaryFailure extends RefreshResult {
  const RefreshTemporaryFailure();
}

enum LoginFailureKind {
  /// HTTP 404 — no account with that email.
  accountNotFound,

  /// HTTP 401 — account exists, password wrong.
  wrongCredentials,

  /// Transport failure (no connectivity, timeout, TLS).
  network,

  /// Anything else (5xx, malformed success, etc.).
  server,
}

extension on String {
  bool get isNotBlank => trim().isNotEmpty;
}
