import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/google_sign_in_service.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';

import 'settings_r29_test.dart' as r29;
import 'test_helpers.dart';

/// Round 30 Step 2 — Connected Apps: Google Account link/disconnect
/// and Google Calendar connect/disconnect, mirroring native
/// (SettingsViewModel.kt:204-263; JotApi.kt:589-593).
class FakeGoogle extends GoogleSignInService {
  GoogleAccountIdentity? identity;
  GoogleSignInOutcome? failure;

  @override
  Future<GoogleAccountIdentity> signInForIdentity() async {
    final f = failure;
    if (f != null) throw f;
    return identity ??
        const GoogleAccountIdentity(
            idToken: 'token-abc', email: 'person@example.com');
  }
}

class LinkBackend extends r29.FakeSettingsBackend {
  Map<String, dynamic>? linkResult;
  Map<String, dynamic>? disconnectResult;
  String? lastIdToken;

  @override
  Future<Map<String, dynamic>?> linkGoogle(String idToken) async {
    lastIdToken = idToken;
    return linkResult;
  }

  @override
  Future<Map<String, dynamic>?> disconnectGoogle() async =>
      disconnectResult;
}

SettingsStore store(Map<String, String> map) => SettingsStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );

Future<void> pumpConnectedApps(
  WidgetTester tester, {
  required LinkBackend backend,
  required Map<String, String> map,
  FakeGoogle? google,
}) async {
  tester.view.physicalSize = const Size(1080, 3400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SettingsScreen(
        backend: backend,
        settingsStore: store(map),
        notificationService: FakeReminderNotificationService(),
        googleSignInService: google ?? FakeGoogle(),
        urlLauncher: (uri) async => true,
      ),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('menu_connected_apps')));
  await tester.pumpAndSettle();
}

void main() {
  group('Google Account linking', () {
    testWidgets('connect: server success flips local state + email',
        (tester) async {
      final backend = LinkBackend()
        ..pullBody = r29.pull()
        ..linkResult = {'success': true, 'message': 'Linked'};
      final map = <String, String>{};
      await pumpConnectedApps(tester, backend: backend, map: map);
      await tester
          .tap(find.byKey(const ValueKey('connect_google_button')));
      await tester.pumpAndSettle();
      expect(backend.lastIdToken, 'token-abc');
      expect(map[SettingsStore.googleAccountConnectedKey], 'true');
      expect(map[SettingsStore.googleAccountEmailKey],
          'person@example.com');
      expect(find.text('Google Account Connected'), findsOneWidget);
      expect(find.text('Connected as person@example.com'),
          findsOneWidget);
    });

    testWidgets('connect: server refusal fails closed (state stays off)',
        (tester) async {
      final backend = LinkBackend()
        ..pullBody = r29.pull()
        ..linkResult = {'success': false, 'error': 'already linked'};
      final map = <String, String>{};
      await pumpConnectedApps(tester, backend: backend, map: map);
      await tester
          .tap(find.byKey(const ValueKey('connect_google_button')));
      await tester.pumpAndSettle();
      expect(map[SettingsStore.googleAccountConnectedKey], isNull);
      expect(find.text('Google Account Connected'), findsNothing);
    });

    testWidgets('connect: chooser cancel is a quiet no-op',
        (tester) async {
      final backend = LinkBackend()..pullBody = r29.pull();
      final google = FakeGoogle()
        ..failure = const GoogleSignInOutcome.cancelled();
      final map = <String, String>{};
      await pumpConnectedApps(tester,
          backend: backend, map: map, google: google);
      await tester
          .tap(find.byKey(const ValueKey('connect_google_button')));
      await tester.pumpAndSettle();
      expect(backend.lastIdToken, isNull);
      expect(map[SettingsStore.googleAccountConnectedKey], isNull);
    });

    testWidgets('disconnect: server success clears local state',
        (tester) async {
      final backend = LinkBackend()
        ..pullBody = r29.pull()
        ..disconnectResult = {'success': true};
      final map = <String, String>{
        SettingsStore.googleAccountConnectedKey: 'true',
        SettingsStore.googleAccountEmailKey: 'person@example.com',
      };
      await pumpConnectedApps(tester, backend: backend, map: map);
      expect(find.text('Google Account Connected'), findsOneWidget);
      await tester
          .tap(find.byKey(const ValueKey('disconnect_google_button')));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(const ValueKey('confirm_disconnect_google')));
      await tester.pumpAndSettle();
      expect(map[SettingsStore.googleAccountConnectedKey], 'false');
      expect(map[SettingsStore.googleAccountEmailKey], '');
      expect(find.text('Google Account Connected'), findsNothing);
    });

    testWidgets(
        'disconnect: server error keeps state and shows in dialog',
        (tester) async {
      final backend = LinkBackend()
        ..pullBody = r29.pull()
        ..disconnectResult = {
          'success': false,
          'error': 'Cannot disconnect your only sign in method',
        };
      final map = <String, String>{
        SettingsStore.googleAccountConnectedKey: 'true',
        SettingsStore.googleAccountEmailKey: 'person@example.com',
      };
      await pumpConnectedApps(tester, backend: backend, map: map);
      await tester
          .tap(find.byKey(const ValueKey('disconnect_google_button')));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(const ValueKey('confirm_disconnect_google')));
      await tester.pumpAndSettle();
      expect(map[SettingsStore.googleAccountConnectedKey], 'true');
      expect(find.text('Cannot disconnect your only sign in method'),
          findsOneWidget);
    });
  });

  group('Google Calendar', () {
    testWidgets('connect stores email locally; disconnect clears it',
        (tester) async {
      final backend = LinkBackend()..pullBody = r29.pull();
      final map = <String, String>{};
      await pumpConnectedApps(tester, backend: backend, map: map);
      await tester
          .tap(find.byKey(const ValueKey('connect_calendar_button')));
      await tester.pumpAndSettle();
      expect(map[SettingsStore.googleCalendarConnectedKey], 'true');
      expect(map[SettingsStore.googleCalendarEmailKey],
          'person@example.com');
      expect(find.text('Google Calendar Active'), findsOneWidget);
      // Calendar connect makes NO link-google server call (native
      // stores the Calendar flag locally only).
      expect(backend.lastIdToken, isNull);
      await tester.tap(
          find.byKey(const ValueKey('disconnect_calendar_button')));
      await tester.pumpAndSettle();
      expect(map[SettingsStore.googleCalendarConnectedKey], 'false');
      expect(find.text('Google Calendar Active'), findsNothing);
    });
  });

  group('SettingsStore google keys', () {
    test('round-trip + clear wipes them', () async {
      final map = <String, String>{};
      final s = store(map);
      expect(await s.getGoogleCalendarConnected(), isFalse);
      expect(await s.getGoogleAccountConnected(), isFalse);
      await s.setGoogleCalendarConnected(true);
      await s.setGoogleCalendarEmail('a@b.c');
      await s.setGoogleAccountConnected(true);
      await s.setGoogleAccountEmail('a@b.c');
      expect(await s.getGoogleCalendarEmail(), 'a@b.c');
      expect(await s.getGoogleAccountEmail(), 'a@b.c');
      await s.clear();
      expect(map, isEmpty);
    });
  });
}
