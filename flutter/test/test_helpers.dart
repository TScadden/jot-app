import 'package:tabs_lab/src/data/session_store.dart';

/// In-memory stand-in for [SessionStore] so widget tests never touch
/// platform channels (flutter_secure_storage) or real credentials.
class FakeSessionStore extends SessionStore {
  String? token;
  String? refreshToken;
  String? email;

  @override
  Future<void> saveSession({
    required String token,
    required String refreshToken,
    required String email,
  }) async {
    this.token = token;
    this.refreshToken = refreshToken;
    this.email = email;
  }

  @override
  Future<String?> readToken() async => token;

  @override
  Future<String?> readRefreshToken() async => refreshToken;

  @override
  Future<String?> readEmail() async => email;

  @override
  Future<void> clear() async {
    token = null;
    refreshToken = null;
    email = null;
  }
}
