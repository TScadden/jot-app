import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/apple_sign_in_service.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';

import 'settings_r29_test.dart' as r29;
import 'test_helpers.dart';

/// Sign in with Apple — Connected Apps: Apple Account link/disconnect,
/// mirroring the Round 30 Google tests (settings_r30_google_test.dart).
class FakeApple extends AppleSignInService {
  AppleAccountIdentity? identity;
  AppleSignInOutcome? failure;
  int signInCalls = 0;

  @override
  Future<AppleAccountIdentity> signInForIdentity() async {
    signInCalls++;
    final f = failure;
    if (f != null) throw f;
    return identity ??
        const AppleAccountIdentity(
            idToken: 'apple-token-abc',
            email: 'jane@privaterelay.appleid.com');
  }
}

class AppleLinkBackend extends r29.FakeSettingsBackend {
  Map<String, dynamic>? linkAppleResult;
  Map<String, dynamic>? disconnectAppleResult;
  String? lastAppleIdToken;

  @override
  Future<Map<String, dynamic>?> linkApple(String idToken) async {
    lastAppleIdToken = idToken;
    return linkAppleResult;
  }

  @override
  Future<Map<String, dynamic>?> disconnectApple() async =>
      disconnectAppleResult;
}

SettingsStore store(Map<String, String> map) => SettingsStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );

Future<void> pumpConnectedApps(
  WidgetTester tester, {
  required AppleLinkBackend backend,
  required Map<String, String> map,
  FakeApple? apple,
}) async {
  tester.view.physicalSize = const Size(1080, 4200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SettingsScreen(
        backend: backend,
        settingsStore: store(map),
        notificationService: FakeReminderNotificationService(),
        appleSignInService: apple ?? FakeApple(),
        urlLauncher: (uri) async => true,
      ),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('menu_connected_apps')));
  await tester.pumpAndSettle();
}

Future<void> tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  group('Apple Account linking', () {
    testWidgets('connect: server success flips local state + email',
        (tester) async {
      final backend = AppleLinkBackend()
        ..pullBody = r29.pull()
        ..linkAppleResult = {
          'success': true,
          'message': 'Apple account connected successfully',
          'appleEmail': 'jane@privaterelay.appleid.com',
        };
      final map = <String, String>{};
      await pumpConnectedApps(tester, backend: backend, map: map);
      await tapKey(tester, 'connect_apple_button');
      expect(backend.lastAppleIdToken, 'apple-token-abc');
      expect(map[SettingsStore.appleAccountConnectedKey], 'true');
      expect(map[SettingsStore.appleAccountEmailKey],
          'jane@privaterelay.appleid.com');
      expect(find.text('Apple Account Connected'), findsOneWidget);
      expect(find.text('Connected as jane@privaterelay.appleid.com'),
          findsOneWidget);
    });

    testWidgets(
        'connect: identity email null (later authorization) — the '
        'server appleEmail from the link body is stored instead',
        (tester) async {
      final backend = AppleLinkBackend()
        ..pullBody = r29.pull()
        ..linkAppleResult = {
          'success': true,
          'message': 'Apple account connected successfully',
          'appleEmail': 'stored@privaterelay.appleid.com',
        };
      final apple = FakeApple()
        ..identity =
            const AppleAccountIdentity(idToken: 'apple-token-abc');
      final map = <String, String>{};
      await pumpConnectedApps(tester,
          backend: backend, map: map, apple: apple);
      await tapKey(tester, 'connect_apple_button');
      expect(map[SettingsStore.appleAccountConnectedKey], 'true');
      expect(map[SettingsStore.appleAccountEmailKey],
          'stored@privaterelay.appleid.com');
      expect(find.text('Connected as stored@privaterelay.appleid.com'),
          findsOneWidget);
    });

    testWidgets('connect: server refusal fails closed (state stays off)',
        (tester) async {
      // The Apple endpoint's refusal is a NON-200 {success:false,
      // error} body; TabsBackend.linkApple decodes and returns it,
      // so the fake returns that same shape here.
      final backend = AppleLinkBackend()
        ..pullBody = r29.pull()
        ..linkAppleResult = {
          'success': false,
          'error':
              'That Apple account is already connected to another Tabs account',
        };
      final map = <String, String>{};
      await pumpConnectedApps(tester, backend: backend, map: map);
      await tapKey(tester, 'connect_apple_button');
      expect(map[SettingsStore.appleAccountConnectedKey], isNull);
      expect(find.text('Apple Account Connected'), findsNothing);
    });

    testWidgets('connect: authorization cancel is a quiet no-op',
        (tester) async {
      final backend = AppleLinkBackend()..pullBody = r29.pull();
      final apple = FakeApple()
        ..failure = const AppleSignInOutcome.cancelled();
      final map = <String, String>{};
      await pumpConnectedApps(tester,
          backend: backend, map: map, apple: apple);
      await tapKey(tester, 'connect_apple_button');
      expect(backend.lastAppleIdToken, isNull);
      expect(map[SettingsStore.appleAccountConnectedKey], isNull);
    });

    testWidgets('disconnect: server success clears local state',
        (tester) async {
      final backend = AppleLinkBackend()
        ..pullBody = r29.pull()
        ..disconnectAppleResult = {
          'success': true,
          'message': 'Apple account disconnected successfully',
        };
      final map = <String, String>{
        SettingsStore.appleAccountConnectedKey: 'true',
        SettingsStore.appleAccountEmailKey:
            'jane@privaterelay.appleid.com',
      };
      await pumpConnectedApps(tester, backend: backend, map: map);
      expect(find.text('Apple Account Connected'), findsOneWidget);
      await tapKey(tester, 'disconnect_apple_button');
      await tapKey(tester, 'confirm_disconnect_apple');
      expect(map[SettingsStore.appleAccountConnectedKey], 'false');
      expect(map[SettingsStore.appleAccountEmailKey], '');
      expect(find.text('Apple Account Connected'), findsNothing);
    });

    testWidgets(
        'disconnect: 409 only-sign-in-method refusal keeps state '
        'and shows the server message in the dialog', (tester) async {
      // 409 arrives as a NON-200 {success:false, error} body —
      // decoded by TabsBackend.disconnectApple (the contract
      // divergence), so the message reaches this dialog.
      final backend = AppleLinkBackend()
        ..pullBody = r29.pull()
        ..disconnectAppleResult = {
          'success': false,
          'error':
              'Set or reset a password before disconnecting your only sign-in method',
        };
      final map = <String, String>{
        SettingsStore.appleAccountConnectedKey: 'true',
        SettingsStore.appleAccountEmailKey:
            'jane@privaterelay.appleid.com',
      };
      await pumpConnectedApps(tester, backend: backend, map: map);
      await tapKey(tester, 'disconnect_apple_button');
      await tapKey(tester, 'confirm_disconnect_apple');
      expect(map[SettingsStore.appleAccountConnectedKey], 'true');
      expect(
          find.text(
              'Set or reset a password before disconnecting your only sign-in method'),
          findsOneWidget);
    });
  });

  group('SettingsStore apple keys', () {
    test('round-trip + clear wipes them', () async {
      final map = <String, String>{};
      final s = store(map);
      expect(await s.getAppleAccountConnected(), isFalse);
      await s.setAppleAccountConnected(true);
      await s.setAppleAccountEmail('a@b.c');
      expect(await s.getAppleAccountConnected(), isTrue);
      expect(await s.getAppleAccountEmail(), 'a@b.c');
      await s.clear();
      expect(map, isEmpty);
    });
  });
}
