import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/auth_api.dart';

void main() {
  group('AuthApiClient.login', () {
    test('posts to the native login endpoint with the native payload',
        () async {
      late http.Request captured;
      final client = AuthApiClient(
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'token': 'tok123',
              'refreshToken': 'ref456',
              'userId': 'u1',
              'email': 'a@b.com',
            }),
            200,
          );
        }),
      );

      final result = await client.login(
        email: 'a@b.com',
        password: 's3cret',
      );

      expect(captured.url.toString(),
          'https://api.jottracker.com/api/auth/login');
      expect(captured.method, 'POST');
      expect(captured.headers['Content-Type'], 'application/json');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['email'], 'a@b.com');
      expect(body['password'], 's3cret');
      expect(body['ageConfirmed'], false);

      expect(result, isA<LoginSuccess>());
      final success = result as LoginSuccess;
      expect(success.token, 'tok123');
      expect(success.refreshToken, 'ref456');
      expect(success.userId, 'u1');
      expect(success.email, 'a@b.com');
    });

    test('404 maps to account-not-found with the founder wording', () async {
      final client = AuthApiClient(
        client: MockClient((_) async => http.Response(
              jsonEncode({
                'error':
                    'No account found with that email. Please sign up to create one.'
              }),
              404,
            )),
      );

      final result = await client.login(email: 'nope@b.com', password: 'x');

      expect(result, isA<LoginFailure>());
      final failure = result as LoginFailure;
      expect(failure.kind, LoginFailureKind.accountNotFound);
      expect(failure.message, "That account doesn't exist.");
    });

    test('401 maps to wrong-credentials with the founder wording', () async {
      final client = AuthApiClient(
        client: MockClient(
            (_) async => http.Response('{"error":"Invalid credentials"}', 401)),
      );

      final result = await client.login(email: 'a@b.com', password: 'wrong');

      expect(result, isA<LoginFailure>());
      final failure = result as LoginFailure;
      expect(failure.kind, LoginFailureKind.wrongCredentials);
      expect(failure.message, 'Wrong password or email.');
    });

    test('200 without a token is a server failure', () async {
      final client = AuthApiClient(
        client: MockClient((_) async => http.Response('{}', 200)),
      );

      final result = await client.login(email: 'a@b.com', password: 'x');

      expect(result, isA<LoginFailure>());
      expect((result as LoginFailure).kind, LoginFailureKind.server);
    });

    test('other errors surface the server message when present', () async {
      final client = AuthApiClient(
        client: MockClient(
            (_) async => http.Response('{"error":"Too many attempts"}', 429)),
      );

      final result = await client.login(email: 'a@b.com', password: 'x');

      expect(result, isA<LoginFailure>());
      final failure = result as LoginFailure;
      expect(failure.kind, LoginFailureKind.server);
      expect(failure.message, 'Too many attempts');
    });

    test('transport failure maps to the network message', () async {
      final client = AuthApiClient(
        client: MockClient((_) async => throw const SocketException('nope')),
      );

      final result = await client.login(email: 'a@b.com', password: 'x');

      expect(result, isA<LoginFailure>());
      final failure = result as LoginFailure;
      expect(failure.kind, LoginFailureKind.network);
      expect(failure.message, contains("Couldn't reach the server"));
    });

    test('failure messages never contain the password', () async {
      const password = 'super-secret-pw-123';
      final client = AuthApiClient(
        client: MockClient((_) async => throw const SocketException('nope')),
      );

      final result =
          await client.login(email: 'a@b.com', password: password);

      final failure = result as LoginFailure;
      expect(failure.message.contains(password), isFalse);
      expect(failure.toString().contains(password), isFalse);
    });
  });

  group('AuthApiClient.googleLogin', () {
    test('posts to the Google endpoint with the native payload and '
        'parses the AuthResponse like password login', () async {
      late http.Request captured;
      final client = AuthApiClient(
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'token': 'tok123',
              'refreshToken': 'ref456',
              'userId': 'u1',
              'email': 'google@example.com',
            }),
            200,
          );
        }),
      );

      final result = await client.googleLogin(
        idToken: 'fake-id-token',
        isRegisterMode: true,
        ageConfirmed: true,
      );

      expect(captured.url.toString(),
          'https://api.jottracker.com/api/auth/google');
      expect(captured.method, 'POST');
      expect(captured.headers['Content-Type'], 'application/json');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['idToken'], 'fake-id-token');
      expect(body['isRegisterMode'], true);
      expect(body['ageConfirmed'], true);
      expect(body.containsKey('password'), isFalse);

      expect(result, isA<LoginSuccess>());
      final success = result as LoginSuccess;
      expect(success.token, 'tok123');
      expect(success.refreshToken, 'ref456');
      expect(success.userId, 'u1');
      expect(success.email, 'google@example.com');
    });

    test('404 surfaces the server error verbatim as a server failure',
        () async {
      final client = AuthApiClient(
        client: MockClient((_) async => http.Response(
              jsonEncode({
                'error':
                    'No account was found with that Google account. Please sign up first.'
              }),
              404,
            )),
      );

      final result = await client.googleLogin(
        idToken: 'fake-id-token',
        isRegisterMode: false,
        ageConfirmed: false,
      );

      expect(result, isA<LoginFailure>());
      final failure = result as LoginFailure;
      // NOT the password flow's fixed 404 string/kind.
      expect(failure.kind, LoginFailureKind.server);
      expect(failure.message,
          'No account was found with that Google account. Please sign up first.');
    });

    test('401 also surfaces the server error verbatim (no fixed '
        'wrong-credentials mapping)', () async {
      final client = AuthApiClient(
        client: MockClient((_) async =>
            http.Response('{"error":"Google token expired"}', 401)),
      );

      final result = await client.googleLogin(
        idToken: 'fake-id-token',
        isRegisterMode: false,
        ageConfirmed: false,
      );

      final failure = result as LoginFailure;
      expect(failure.kind, LoginFailureKind.server);
      expect(failure.message, 'Google token expired');
    });

    test('non-200 without a server error uses the generic message',
        () async {
      final client = AuthApiClient(
        client: MockClient((_) async => http.Response('oops', 500)),
      );

      final result = await client.googleLogin(
        idToken: 'fake-id-token',
        isRegisterMode: false,
        ageConfirmed: false,
      );

      final failure = result as LoginFailure;
      expect(failure.kind, LoginFailureKind.server);
      expect(failure.message, 'Something went wrong. Please try again.');
    });

    test('200 without a token is a server failure', () async {
      final client = AuthApiClient(
        client: MockClient((_) async => http.Response('{}', 200)),
      );

      final result = await client.googleLogin(
        idToken: 'fake-id-token',
        isRegisterMode: false,
        ageConfirmed: false,
      );

      expect(result, isA<LoginFailure>());
      expect((result as LoginFailure).kind, LoginFailureKind.server);
    });

    test('transport failure maps to the network kind', () async {
      final client = AuthApiClient(
        client: MockClient((_) async => throw const SocketException('nope')),
      );

      final result = await client.googleLogin(
        idToken: 'fake-id-token',
        isRegisterMode: false,
        ageConfirmed: false,
      );

      expect(result, isA<LoginFailure>());
      final failure = result as LoginFailure;
      expect(failure.kind, LoginFailureKind.network);
      expect(failure.message, contains("Couldn't reach the server"));
    });
  });
}
