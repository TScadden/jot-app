import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';

import 'test_helpers.dart';

/// Sign in with Apple — TabsBackend link/disconnect decoding.
///
/// CONTRACT DIVERGENCE pin: Google's link/disconnect endpoints
/// report errors inside a 200 body (so linkGoogle/disconnectGoogle
/// decode only on 200), but the Apple endpoints return errors as
/// NON-200 (400/401/409) with `{success: false, error}` bodies.
/// linkApple/disconnectApple must therefore decode the body on
/// error statuses too — otherwise the 409 "only sign-in method"
/// refusal could never reach the disconnect dialog.
void main() {
  TabsBackend backendReturning(int status, Map<String, dynamic> body,
      {void Function(http.Request)? onRequest}) {
    final store = FakeSessionStore()..token = 'access-token';
    return TabsBackend(
      sessionStore: store,
      client: MockClient((request) async {
        onRequest?.call(request);
        return http.Response(jsonEncode(body), status);
      }),
    );
  }

  test('linkApple posts the idToken to link-apple and returns the '
      '200 body', () async {
    late http.Request captured;
    final backend = backendReturning(
      200,
      {
        'success': true,
        'message': 'Apple account connected successfully',
        'appleEmail': 'jane@privaterelay.appleid.com',
        'emailVerified': true,
      },
      onRequest: (r) => captured = r,
    );

    final res = await backend.linkApple('identity-token-abc');

    expect(captured.url.toString(),
        'https://api.jottracker.com/api/auth/link-apple');
    expect(captured.headers['Authorization'], 'Bearer access-token');
    expect(jsonDecode(captured.body), {'idToken': 'identity-token-abc'});
    expect(res?['success'], true);
    expect(res?['appleEmail'], 'jane@privaterelay.appleid.com');
  });

  test('linkApple decodes a NON-200 error body (409) instead of '
      'returning null — the divergence from linkGoogle', () async {
    final backend = backendReturning(409, {
      'success': false,
      'error':
          'That Apple account is already connected to another Tabs account',
    });

    final res = await backend.linkApple('identity-token-abc');

    expect(res, isNotNull);
    expect(res?['success'], false);
    expect(res?['error'],
        'That Apple account is already connected to another Tabs account');
  });

  test('disconnectApple returns the 200 success body', () async {
    late http.Request captured;
    final backend = backendReturning(
      200,
      {'success': true, 'message': 'Apple account disconnected successfully'},
      onRequest: (r) => captured = r,
    );

    final res = await backend.disconnectApple();

    expect(captured.url.toString(),
        'https://api.jottracker.com/api/auth/disconnect-apple');
    expect(res?['success'], true);
  });

  test('disconnectApple decodes the 409 only-sign-in-method body '
      'so the dialog can show it', () async {
    final backend = backendReturning(409, {
      'success': false,
      'error':
          'Set or reset a password before disconnecting your only sign-in method',
    });

    final res = await backend.disconnectApple();

    expect(res, isNotNull);
    expect(res?['success'], false);
    expect(res?['error'],
        'Set or reset a password before disconnecting your only sign-in method');
  });

  test('linkApple returns null on transport failure', () async {
    final store = FakeSessionStore()..token = 'access-token';
    final backend = TabsBackend(
      sessionStore: store,
      client: MockClient((_) async => throw Exception('boom')),
    );

    expect(await backend.linkApple('identity-token-abc'), isNull);
    expect(await backend.disconnectApple(), isNull);
  });
}
