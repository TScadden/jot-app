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
