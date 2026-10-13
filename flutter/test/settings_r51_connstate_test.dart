import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/features/auth/login_screen.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';

import 'google_sign_in_r24_test.dart' as r24;
import 'settings_r29_test.dart' as r29;
import 'settings_r30_google_test.dart' as r30g;
import 'test_helpers.dart';

/// Round 51 — Connected Apps state reading/presentation.
///
/// The founder's screenshot showed every row in its not-connected
/// state while the connections were live. Root causes pinned per
/// row (see the round report):
/// - Health Connect: the Settings card was STATIC — it never read
///   Health Connect state at all. It now binds
///   [HealthConnectService.getStatus], the same live bridge check
///   Home (Round 23) and the Data Connections screen use.
/// - Google Account: the row reads the SettingsStore flag, which
///   only the Settings link flow wrote — Google sign-in (the way
///   the founder actually connects, and the call that links the
///   identity server-side) never seeded it. Native seeds it in
///   `LoginScreen.kt` (:220-221); login_screen.dart now does too.
/// - Google Calendar / Account flags: they loaded once, inside an
///   all-or-nothing Future.wait with the sync pull, and were never
///   re-read when the Connected Apps page opened. They now load on
///   an isolated path and re-load on every page open.
///
/// The Round 30 write flows are exercised UNCHANGED here (the
/// disconnect fixture below runs the real R30 flow).

/// In-memory [SecureStore] for the fake Health Connect service.
class MemorySecureStore implements SecureStore {
  final Map<String, String> map = {};
  @override
  Future<String?> read(String key) async => map[key];
  @override
  Future<void> write(String key, String value) async => map[key] = value;
  @override
  Future<void> delete(String key) async => map.remove(key);
}

/// Fake bridge: [getStatus] returns a canned status or throws a
/// canned [HealthConnectException], and counts calls so tests can
/// prove the Settings screen actually checks (and re-checks).
class FakeHCService extends HealthConnectService {
  FakeHCService(this.status, {this.error}) : super(store: MemorySecureStore());

  HealthConnectStatus status;
  HealthConnectException? error;
  int statusCalls = 0;

  @override
  Future<HealthConnectStatus> getStatus() async {
    statusCalls++;
    final e = error;
    if (e != null) throw e;
    return status;
  }
}

SettingsStore store(Map<String, String> map) => SettingsStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );

Future<void> pumpSettings(
  WidgetTester tester, {
  required r30g.LinkBackend backend,
  required Map<String, String> map,
  required FakeHCService hc,
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
        googleSignInService: r30g.FakeGoogle(),
        healthConnectService: hc,
        urlLauncher: (uri) async => true,
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> openConnectedApps(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('menu_connected_apps')));
  await tester.pumpAndSettle();
}

Future<void> backToMenu(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.arrow_back));
  await tester.pumpAndSettle();
}

void main() {
  group('Health Connect row (Round 51)', () {
    testWidgets('connected: Active presentation, no connect CTA',
        (tester) async {
      final backend = r30g.LinkBackend()..pullBody = r29.pull();
      final hc = FakeHCService(HealthConnectStatus.connected);
      await pumpSettings(tester, backend: backend, map: {}, hc: hc);
      await openConnectedApps(tester);
      expect(find.text('Health Connect Active'), findsOneWidget);
      expect(find.text('Live synchronization active'), findsOneWidget);
      expect(find.text('• Connected to local device sensors'),
          findsOneWidget);
      expect(find.text('Connect Health Data'), findsNothing);
      // The state really was queried on this screen (not static).
      expect(hc.statusCalls, greaterThan(0));
      // Fitbit row untouched and still rendered as unavailable.
      expect(find.text('Fitbit Direct Sync'), findsOneWidget);
      expect(find.text('No longer available'), findsOneWidget);
    });

    testWidgets(
        'partially connected: needs-permissions presentation, '
        'no connect CTA', (tester) async {
      final backend = r30g.LinkBackend()..pullBody = r29.pull();
      final hc = FakeHCService(HealthConnectStatus.partiallyConnected);
      await pumpSettings(tester, backend: backend, map: {}, hc: hc);
      await openConnectedApps(tester);
      expect(find.text('Partially connected'), findsOneWidget);
      expect(find.text('Grant New Permissions'), findsOneWidget);
      expect(find.text('Connect Health Data'), findsNothing);
      expect(find.text('Health Connect Active'), findsNothing);
    });

    testWidgets('not connected: connect CTA shown', (tester) async {
      final backend = r30g.LinkBackend()..pullBody = r29.pull();
      final hc = FakeHCService(HealthConnectStatus.notConnected);
      await pumpSettings(tester, backend: backend, map: {}, hc: hc);
      await openConnectedApps(tester);
      expect(find.text('Connect Health Data'), findsOneWidget);
      expect(find.text('Health Connect Active'), findsNothing);
    });

    testWidgets(
        'unavailable: connect CTA shown (the Data Connections '
        'screen explains unavailability)', (tester) async {
      final backend = r30g.LinkBackend()..pullBody = r29.pull();
      final hc = FakeHCService(HealthConnectStatus.unavailable);
      await pumpSettings(tester, backend: backend, map: {}, hc: hc);
      await openConnectedApps(tester);
      expect(find.text('Connect Health Data'), findsOneWidget);
      expect(find.text('Health Connect Active'), findsNothing);
    });

    testWidgets(
        'bridge error: falls back to not-connected WITH the '
        'visible [CODE] (Home parity)', (tester) async {
      final backend = r30g.LinkBackend()..pullBody = r29.pull();
      final hc = FakeHCService(
        HealthConnectStatus.connected,
        error: const HealthConnectException(
            'NO_CHANNEL', 'Health Connect bridge is not available.'),
      );
      await pumpSettings(tester, backend: backend, map: {}, hc: hc);
      await openConnectedApps(tester);
      expect(find.text('Connect Health Data'), findsOneWidget);
      expect(find.text('Health Connect Active'), findsNothing);
      expect(
          find.text('Health Connect status check failed [NO_CHANNEL].'),
          findsOneWidget);
    });

    testWidgets(
        'status change is picked up when the page is re-opened '
        '(connected elsewhere, no restart)', (tester) async {
      final backend = r30g.LinkBackend()..pullBody = r29.pull();
      final hc = FakeHCService(HealthConnectStatus.notConnected);
      await pumpSettings(tester, backend: backend, map: {}, hc: hc);
      await openConnectedApps(tester);
      expect(find.text('Connect Health Data'), findsOneWidget);
      final callsBefore = hc.statusCalls;
      await backToMenu(tester);
      // The connection happens "elsewhere" (e.g. the Data
      // Connections screen / system permissions).
      hc.status = HealthConnectStatus.connected;
      await openConnectedApps(tester);
      expect(hc.statusCalls, greaterThan(callsBefore));
      expect(find.text('Health Connect Active'), findsOneWidget);
      expect(find.text('Connect Health Data'), findsNothing);
    });
  });

  group('Google Account row (Round 51)', () {
    testWidgets('linked: linked email + Disconnect shown',
        (tester) async {
      final backend = r30g.LinkBackend()..pullBody = r29.pull();
      final map = <String, String>{
        SettingsStore.googleAccountConnectedKey: 'true',
        SettingsStore.googleAccountEmailKey: 'person@example.com',
      };
      await pumpSettings(tester,
          backend: backend,
          map: map,
          hc: FakeHCService(HealthConnectStatus.notConnected));
      await openConnectedApps(tester);
      expect(find.text('Google Account Connected'), findsOneWidget);
      expect(find.text('Connected as person@example.com'),
          findsOneWidget);
      expect(find.byKey(const ValueKey('disconnect_google_button')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('connect_google_button')),
          findsNothing);
    });

    testWidgets('not linked: connect CTA shown', (tester) async {
      final backend = r30g.LinkBackend()..pullBody = r29.pull();
      await pumpSettings(tester,
          backend: backend,
          map: {},
          hc: FakeHCService(HealthConnectStatus.notConnected));
      await openConnectedApps(tester);
      expect(find.byKey(const ValueKey('connect_google_button')),
          findsOneWidget);
      expect(find.text('Google Account Connected'), findsNothing);
    });

    testWidgets(
        'state seeded elsewhere (Google sign-in) is reflected '
        'when the page is re-opened, without restart',
        (tester) async {
      final backend = r30g.LinkBackend()..pullBody = r29.pull();
      final map = <String, String>{};
      await pumpSettings(tester,
          backend: backend,
          map: map,
          hc: FakeHCService(HealthConnectStatus.notConnected));
      await openConnectedApps(tester);
      expect(find.text('Google Account Connected'), findsNothing);
      await backToMenu(tester);
      // Simulate the Round 51 login seed landing while Settings
      // stays alive in the shell.
      map[SettingsStore.googleAccountConnectedKey] = 'true';
      map[SettingsStore.googleAccountEmailKey] = 'person@example.com';
      map[SettingsStore.googleCalendarConnectedKey] = 'true';
      map[SettingsStore.googleCalendarEmailKey] = 'person@example.com';
      await openConnectedApps(tester);
      expect(find.text('Google Account Connected'), findsOneWidget);
      expect(find.text('Connected as person@example.com'),
          findsWidgets);
      expect(find.text('Google Calendar Active'), findsOneWidget);
    });

    testWidgets(
        'disconnect (unchanged Round 30 flow) flips the row '
        'without restart', (tester) async {
      final backend = r30g.LinkBackend()
        ..pullBody = r29.pull()
        ..disconnectResult = {'success': true};
      final map = <String, String>{
        SettingsStore.googleAccountConnectedKey: 'true',
        SettingsStore.googleAccountEmailKey: 'person@example.com',
      };
      await pumpSettings(tester,
          backend: backend,
          map: map,
          hc: FakeHCService(HealthConnectStatus.notConnected));
      await openConnectedApps(tester);
      expect(find.text('Google Account Connected'), findsOneWidget);
      await tester
          .tap(find.byKey(const ValueKey('disconnect_google_button')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const ValueKey('confirm_disconnect_google')));
      await tester.pumpAndSettle();
      expect(find.text('Google Account Connected'), findsNothing);
      expect(find.byKey(const ValueKey('connect_google_button')),
          findsOneWidget);
    });
  });

  group('Google Calendar row (Round 51)', () {
    testWidgets('flag on: Active + stored email shown',
        (tester) async {
      final backend = r30g.LinkBackend()..pullBody = r29.pull();
      final map = <String, String>{
        SettingsStore.googleCalendarConnectedKey: 'true',
        SettingsStore.googleCalendarEmailKey: 'person@example.com',
      };
      await pumpSettings(tester,
          backend: backend,
          map: map,
          hc: FakeHCService(HealthConnectStatus.notConnected));
      await openConnectedApps(tester);
      expect(find.text('Google Calendar Active'), findsOneWidget);
      expect(find.text('Connected as person@example.com'),
          findsOneWidget);
      expect(find.byKey(const ValueKey('disconnect_calendar_button')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('connect_calendar_button')),
          findsNothing);
    });

    testWidgets('flag off: connect CTA shown', (tester) async {
      final backend = r30g.LinkBackend()..pullBody = r29.pull();
      await pumpSettings(tester,
          backend: backend,
          map: {},
          hc: FakeHCService(HealthConnectStatus.notConnected));
      await openConnectedApps(tester);
      expect(find.byKey(const ValueKey('connect_calendar_button')),
          findsOneWidget);
      expect(find.text('Google Calendar Active'), findsNothing);
    });
  });

  group('Google sign-in seeds the account state (Round 51)', () {
    testWidgets(
        'Google login success writes connected=true + the account '
        'email to the settings store (native LoginScreen.kt:220-221)',
        (tester) async {
      final service = r24.FakeGoogleSignInService();
      final api = r24.FakeAuthApiClient()
        ..googleResult = const LoginSuccess(
          token: 'tok-google',
          refreshToken: 'ref-google',
          userId: 'u-google',
          email: 'google@example.com',
        );
      final map = <String, String>{};
      await tester.pumpWidget(MaterialApp(
        home: LoginScreen(
          initialRegisterMode: false,
          authApi: api,
          sessionStore: FakeSessionStore(),
          googleSignInService: service,
          settingsStore: store(map),
        ),
      ));
      await tester.ensureVisible(find.text('Log in with Google'));
      await tester.pump();
      await tester.tap(find.text('Log in with Google'));
      await tester.pump();
      await tester.pump();
      expect(map[SettingsStore.googleAccountConnectedKey], 'true');
      expect(map[SettingsStore.googleAccountEmailKey],
          'google@example.com');
    });

    testWidgets(
        'email/password login does NOT seed the Google flag '
        '(native parity)', (tester) async {
      final api = _PasswordAuthApi()
        ..loginResult = const LoginSuccess(
          token: 'tok-pw',
          refreshToken: 'ref-pw',
          userId: 'u-pw',
          email: 'person@example.com',
        );
      final map = <String, String>{};
      await tester.pumpWidget(MaterialApp(
        home: LoginScreen(
          initialRegisterMode: false,
          authApi: api,
          sessionStore: FakeSessionStore(),
          googleSignInService: r24.FakeGoogleSignInService(),
          settingsStore: store(map),
        ),
      ));
      await tester.enterText(
          find.byType(TextField).first, 'person@example.com');
      await tester.enterText(find.byType(TextField).last, 'secret-pw');
      await tester.tap(find.text('Log In'));
      await tester.pump();
      await tester.pump();
      expect(api.loginCalls, 1);
      expect(map[SettingsStore.googleAccountConnectedKey], isNull);
    });
  });
}

/// Fake auth API for the password-login fixture (googleLogin is
/// never reached on that path).
class _PasswordAuthApi extends AuthApiClient {
  LoginResult loginResult = const LoginFailure(
      LoginFailureKind.server, 'unconfigured fake');
  int loginCalls = 0;

  @override
  Future<LoginResult> login({
    required String email,
    required String password,
  }) async {
    loginCalls++;
    return loginResult;
  }
}
