import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/connections/connections_screen.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';

import 'settings_r29_test.dart' as r29;
import 'settings_r30_google_test.dart' as r30g;
import 'settings_r51_connstate_test.dart' as r51;
import 'test_helpers.dart';

/// Report Reliability Phase 2, PR-2 — status-surfaces migration
/// fixtures (Vera's gate): every surface derives from ONE
/// probeAvailability() snapshot, and the PRESENTED strings are
/// matrixed per surface per state.
///
/// States: connected / partial / stale / notConnected /
/// unavailable / unknown (bridge error), plus loading (Settings
/// only). Parity rule: presented strings at head == base for
/// every state, EXCEPT the intended deltas Juno ruled for
/// Settings (stale / unavailable / unknown / loading
/// presentations; the raw bracketed-code line deleted). Home and
/// Connections deltas: none — identical strings via the new path.
///
/// The fake fakes the PROBE (a canned snapshot), never the old
/// getStatus() seam: stale arrives as DATA (staleWedged), unknown
/// as a null status with the bridge failure recorded for logs.

// ── Snapshot builders ─────────────────────────────────────────────

const _hrvPerm = 'android.permission.health.READ_HEART_RATE_VARIABILITY';

HcAvailability snapConnected({bool persisted = true}) => HcAvailability(
      serviceAvailable: true,
      grantedPermissions: HealthConnectService.requiredPermissions,
      bridgeErrorCode: null,
      stepsProbe: HcReadProbeOutcome.ok,
      persistedConnected: persisted,
    );

HcAvailability snapPartial() => HcAvailability(
      serviceAvailable: true,
      grantedPermissions: HealthConnectService.requiredPermissions
          .difference(const {_hrvPerm}),
      bridgeErrorCode: null,
      stepsProbe: null,
      persistedConnected: false,
    );

HcAvailability snapStale() => HcAvailability(
      serviceAvailable: true,
      grantedPermissions: HealthConnectService.requiredPermissions,
      bridgeErrorCode: null,
      stepsProbe: HcReadProbeOutcome.securityFailure,
      persistedConnected: true,
    );

HcAvailability snapNotConnected() => const HcAvailability(
      serviceAvailable: true,
      grantedPermissions: {},
      bridgeErrorCode: null,
      stepsProbe: null,
      persistedConnected: false,
    );

HcAvailability snapUnavailable() => const HcAvailability(
      serviceAvailable: false,
      grantedPermissions: null,
      bridgeErrorCode: null,
      stepsProbe: null,
      persistedConnected: false,
    );

HcAvailability snapUnknown({bool persisted = false}) => HcAvailability(
      serviceAvailable: false,
      grantedPermissions: null,
      bridgeErrorCode: 'BRIDGE_DOWN',
      grantError: const HealthConnectException(
          'BRIDGE_DOWN', 'bridge exploded'),
      stepsProbe: null,
      persistedConnected: persisted,
    );

const _partialMessage = 'Some health data is not shared: '
    'Heart rate variability. To fix it, open Health Connect, tap '
    'App permissions, tap Tabs, and turn on Heart rate variability.';

/// Probe fake: a canned snapshot (or a pending snapshot future),
/// with the vitals reads stubbed empty so Home's connected loads
/// complete honestly-empty.
class ProbeFakeHc extends HealthConnectService {
  ProbeFakeHc(this.snapshot, {this.snapshotFuture, this.requestError});

  HcAvailability snapshot;
  Future<HcAvailability>? snapshotFuture;
  HealthConnectException? requestError;
  int probeCalls = 0;

  @override
  Future<HcAvailability> probeAvailability() {
    probeCalls++;
    return snapshotFuture ?? Future.value(snapshot);
  }

  @override
  Future<bool> hasPersistedConnection() async => snapshot.persistedConnected;

  @override
  Future<Set<String>> requestPermissions() async {
    final e = requestError;
    if (e != null) throw e;
    return HealthConnectService.requiredPermissions;
  }

  @override
  Future<bool> hasBackgroundAccess() async => false;

  @override
  Future<void> openHealthConnectSettings() async {}

  @override
  Future<List<HrSample>> readHeartRateSamples(String dateStr) async =>
      const [];

  @override
  Future<int?> readActiveCalories(String dateStr) async => null;

  @override
  Future<int?> readSleepMinutes(String dateStr) async => null;
}

/// Settings fake: r51's pump plumbing types its HC parameter as
/// r51.FakeHCService, so the probe fake extends it and overrides
/// the probe outright.
class SettingsProbeHc extends r51.FakeHCService {
  SettingsProbeHc(this.snapshot, {this.snapshotFuture})
      : super(HealthConnectStatus.notConnected);

  HcAvailability snapshot;
  Future<HcAvailability>? snapshotFuture;

  @override
  Future<HcAvailability> probeAvailability() async {
    statusCalls++;
    return snapshotFuture ?? Future.value(snapshot);
  }

  @override
  Future<bool> hasBackgroundAccess() async => false;
}

void expectNoBracketedCode(WidgetTester tester) {
  for (final element in find.byType(Text).evaluate()) {
    final widget = element.widget as Text;
    final data = widget.data ?? '';
    expect(data, isNot(matches(RegExp(r'\[[A-Z][A-Z0-9_]*\]'))),
        reason: 'surface rendered a bracketed code: "$data"');
  }
}

// ── Home harness (health_connect_banner_r23_test pattern) ────────

MockClient _mockWeatherClient() {
  return MockClient((request) async {
    if (request.url.host == 'ipinfo.io') {
      return http.Response(
          '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}', 200);
    }
    if (request.url.host == 'api.open-meteo.com') {
      return http.Response(
          '{"current":{"temperature_2m":60.0,"weather_code":2,"is_day":1}}',
          200);
    }
    return http.Response('not found', 404);
  });
}

Future<void> _pumpHome(WidgetTester tester, ProbeFakeHc service) async {
  final backend = TabsBackend(
    client: MockClient((_) async => http.Response('not found', 404)),
    sessionStore: FakeSessionStore(),
  );
  final repo = HealthRepository(hc: service, backend: backend);
  await tester.pumpWidget(MaterialApp(
    home: HomeScreen(
      weatherApi: WeatherApiClient(client: _mockWeatherClient()),
      healthConnectService: service,
      healthRepository: repo,
    ),
  ));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(seconds: 1));
  await tester.pump();
}

Future<void> _pumpConnections(
    WidgetTester tester, ProbeFakeHc service) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(home: ConnectionsScreen(healthConnectService: service)),
  );
  await tester.pumpAndSettle();
}

const _ncTitle = "Health Connect isn't connected";
const _ncBody = 'Tap to reconnect';
const _partialBanner = 'Health Connect needs permissions — tap to fix';
const _staleTitle = 'Health Connect got disconnected';
const _staleBody =
    "There's a problem with the connection. Tap to disconnect and connect again.";
const _rowName = 'Android Health (Google Fit, Samsung)';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => HomeDataCache.instance.debugReset());
  tearDown(() => HomeDataCache.instance.debugReset());

  group('Home banner — presented strings per snapshot state', () {
    testWidgets('connected → NO banner', (tester) async {
      await _pumpHome(tester, ProbeFakeHc(snapConnected()));
      expect(find.text(_ncTitle), findsNothing);
      expect(find.text(_partialBanner), findsNothing);
      expect(find.text(_staleTitle), findsNothing);
    });

    testWidgets('partial → permissions banner (base string)', (tester) async {
      await _pumpHome(tester, ProbeFakeHc(snapPartial()));
      expect(find.text(_partialBanner), findsOneWidget);
      expect(find.text(_ncTitle), findsNothing);
    });

    testWidgets('stale (staleWedged data) → stale banner, no code',
        (tester) async {
      await _pumpHome(tester, ProbeFakeHc(snapStale()));
      expect(find.text(_staleTitle), findsOneWidget);
      expect(find.text(_staleBody), findsOneWidget);
      expect(find.text(_ncTitle), findsNothing);
      expectNoBracketedCode(tester);
    });

    testWidgets('notConnected → ruled title/body (base strings)',
        (tester) async {
      await _pumpHome(tester, ProbeFakeHc(snapNotConnected()));
      expect(find.text(_ncTitle), findsOneWidget);
      expect(find.text(_ncBody), findsOneWidget);
    });

    testWidgets('unavailable → same ruled title/body as base',
        (tester) async {
      await _pumpHome(tester, ProbeFakeHc(snapUnavailable()));
      expect(find.text(_ncTitle), findsOneWidget);
      expect(find.text(_ncBody), findsOneWidget);
    });

    testWidgets(
        'unknown (status null) → EXACTLY the old generic-catch '
        'presentation: notConnected banner, no stale, no code',
        (tester) async {
      await _pumpHome(tester, ProbeFakeHc(snapUnknown()));
      expect(find.text(_ncTitle), findsOneWidget);
      expect(find.text(_ncBody), findsOneWidget);
      expect(find.text(_staleTitle), findsNothing);
      expectNoBracketedCode(tester);
    });
  });

  group('Connections — presented strings per snapshot state', () {
    testWidgets('connected → Connected row + all-connected line',
        (tester) async {
      await _pumpConnections(tester, ProbeFakeHc(snapConnected()));
      expect(find.text('Connected'), findsOneWidget);
      expect(
          find.text("You've connected every supported tracker."),
          findsOneWidget);
      expectNoBracketedCode(tester);
    });

    testWidgets('partial → Partially connected row + naming message',
        (tester) async {
      await _pumpConnections(tester, ProbeFakeHc(snapPartial()));
      expect(find.text('Partially connected'), findsOneWidget);
      expect(find.text(_partialMessage), findsOneWidget);
    });

    testWidgets(
        'stale → Connection problem row + ruled recovery line; '
        'sheet isStale presentation', (tester) async {
      await _pumpConnections(tester, ProbeFakeHc(snapStale()));
      expect(find.text('Connection problem'), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
      expect(find.text(HealthConnectService.staleGrantMessage),
          findsOneWidget);
      expectNoBracketedCode(tester);

      await tester.tap(find.text(_rowName));
      await tester.pumpAndSettle();
      final sheet = find.byType(BottomSheet);
      expect(sheet, findsOneWidget);
      expect(
        find.descendant(
            of: sheet,
            matching: find.text(
                "Connection problem: Tabs can't read your health data right now.")),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: sheet,
            matching: find.text(HealthConnectService.staleGrantMessage)),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: sheet, matching: find.text('Manage system permissions')),
        findsOneWidget,
      );
    });

    testWidgets('notConnected → Available row, no error line',
        (tester) async {
      await _pumpConnections(tester, ProbeFakeHc(snapNotConnected()));
      expect(find.text('No trackers connected yet.'), findsOneWidget);
      expect(find.text('Available'), findsOneWidget);
      expect(find.text('bridge exploded'), findsNothing);
    });

    testWidgets('unavailable → disabled row, no chevron', (tester) async {
      await _pumpConnections(tester, ProbeFakeHc(snapUnavailable()));
      expect(find.text('Not available on this device'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });

    testWidgets(
        'unknown + persisted → persisted fallback row (Connected) '
        '+ the plain failure message (base fallback strings)',
        (tester) async {
      await _pumpConnections(
          tester, ProbeFakeHc(snapUnknown(persisted: true)));
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('bridge exploded'), findsOneWidget);
      expectNoBracketedCode(tester);
    });

    testWidgets(
        'unknown, no persisted → notConnected fallback + the '
        'plain failure message', (tester) async {
      await _pumpConnections(tester, ProbeFakeHc(snapUnknown()));
      expect(find.text('No trackers connected yet.'), findsOneWidget);
      expect(find.text('Available'), findsOneWidget);
      expect(find.text('bridge exploded'), findsOneWidget);
      expectNoBracketedCode(tester);
    });

    testWidgets(
        'requestPermissions throws STALE_GRANT → the state is '
        'taken from a FRESH PROBE (stale as data), never from the '
        'code', (tester) async {
      final service = ProbeFakeHc(
        snapNotConnected(),
        requestError: const HealthConnectException(
          HealthConnectService.staleGrantCode,
          HealthConnectService.staleGrantMessage,
        ),
      );
      await _pumpConnections(tester, service);
      expect(find.text('Available'), findsOneWidget);
      final probesBefore = service.probeCalls;

      // The post-request probe will report the wedged grant.
      service.snapshot = snapStale();
      await tester.tap(find.text(_rowName));
      await tester.pumpAndSettle();
      // Prominent disclosure first (MF-3) — Continue runs the flow.
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(service.probeCalls, greaterThan(probesBefore));
      expect(find.text('Connection problem'), findsOneWidget);
      expect(find.text(HealthConnectService.staleGrantMessage),
          findsOneWidget);
      expectNoBracketedCode(tester);
    });
  });

  group('Settings Connected Apps — Juno ruling per snapshot state',
      () {
    Future<void> pumpSettings(
        WidgetTester tester, SettingsProbeHc hc) async {
      final backend = r30g.LinkBackend()..pullBody = r29.pull();
      await r51.pumpSettings(tester, backend: backend, map: {}, hc: hc);
      await r51.openConnectedApps(tester);
    }

    testWidgets('loading (no snapshot yet) → checking line, EMPTY '
        'button slot', (tester) async {
      final completer = Completer<HcAvailability>();
      final backend = r30g.LinkBackend()..pullBody = r29.pull();
      final hc = SettingsProbeHc(snapNotConnected(),
          snapshotFuture: completer.future);
      // r51.pumpSettings settles — a pending probe schedules no
      // frames, so the settings shell still settles around it.
      await r51.pumpSettings(tester, backend: backend, map: {}, hc: hc);
      await r51.openConnectedApps(tester);
      expect(find.text('Google Health Connect'), findsWidgets);
      expect(find.text('Checking Health Connect status…'),
          findsOneWidget);
      expect(find.byKey(const ValueKey('open_connections')),
          findsNothing);
      expect(find.text('Connect Health Data'), findsNothing);
      expect(find.text('Manage Health Connect'), findsNothing);
      expect(find.text('Grant New Permissions'), findsNothing);
      completer.complete(snapNotConnected());
      await tester.pumpAndSettle();
    });

    testWidgets('connected → Active card, byte-untouched (Juno §5)',
        (tester) async {
      await pumpSettings(tester, SettingsProbeHc(snapConnected()));
      expect(find.text('Health Connect Active'), findsOneWidget);
      expect(find.text('Live synchronization active'), findsOneWidget);
      expect(find.text('• Connected to local device sensors'),
          findsOneWidget);
      expect(find.text('Manage Health Connect'), findsOneWidget);
      expect(find.text('Health Connect status check failed.'),
          findsNothing);
    });

    testWidgets('partial → naming message + Grant New Permissions '
        '(Juno §5)', (tester) async {
      await pumpSettings(tester, SettingsProbeHc(snapPartial()));
      expect(find.text('Partially connected'), findsOneWidget);
      expect(find.text(_partialMessage), findsOneWidget);
      expect(find.text('Grant New Permissions'), findsOneWidget);
      expect(find.text('Health Connect status check failed.'),
          findsNothing);
    });

    testWidgets(
        'stale → Juno §1 slots verbatim: Connection problem '
        '(error) + staleGrantMessage constant + Manage button; '
        'Active/Live-sync/connect strings banned', (tester) async {
      await pumpSettings(tester, SettingsProbeHc(snapStale()));
      expect(find.text('Google Health Connect'), findsWidgets);
      expect(find.text('Connection problem'), findsOneWidget);
      expect(find.text(HealthConnectService.staleGrantMessage),
          findsOneWidget);
      expect(find.text('Manage Health Connect'), findsOneWidget);
      expect(find.text('Health Connect Active'), findsNothing);
      expect(find.text('Live synchronization active'), findsNothing);
      expect(find.text('• Connected to local device sensors'),
          findsNothing);
      expect(find.text('Connect Health Data'), findsNothing);
      expect(find.text('Grant New Permissions'), findsNothing);
      // A KNOWN state: the Unknown supplementary line must NOT
      // appear here.
      expect(find.text('Health Connect status check failed.'),
          findsNothing);
      expectNoBracketedCode(tester);
    });

    testWidgets('notConnected (known empty grant) → connect card, '
        'byte-untouched, NO supplementary line (Juno §5)',
        (tester) async {
      await pumpSettings(tester, SettingsProbeHc(snapNotConnected()));
      expect(
          find.text(
              'Connect to grab data from Garmin, Oura, Fitbit and more.'),
          findsOneWidget);
      expect(find.text('Connect Health Data'), findsOneWidget);
      expect(find.text('Health Connect status check failed.'),
          findsNothing);
    });

    testWidgets(
        'unavailable → Juno §2: Not available status + ruled body, '
        'EMPTY button slot, connect body forbidden', (tester) async {
      await pumpSettings(tester, SettingsProbeHc(snapUnavailable()));
      expect(find.text('Not available on this device'), findsOneWidget);
      expect(
          find.text(
              "Tabs can't read health data through Health Connect on this device."),
          findsOneWidget);
      expect(find.byKey(const ValueKey('open_connections')),
          findsNothing);
      expect(find.text('Connect Health Data'), findsNothing);
      expect(find.text('Manage Health Connect'), findsNothing);
      expect(
          find.text(
              'Connect to grab data from Garmin, Oura, Fitbit and more.'),
          findsNothing);
      expect(find.text('Health Connect status check failed.'),
          findsNothing);
    });

    testWidgets(
        'unknown → Juno §3: not-connected fallback card PLUS the '
        'plain failure line; the Active card is NEVER manufactured '
        'from the persisted flag (snapshot carries persisted=true)',
        (tester) async {
      await pumpSettings(
          tester, SettingsProbeHc(snapUnknown(persisted: true)));
      expect(
          find.text(
              'Connect to grab data from Garmin, Oura, Fitbit and more.'),
          findsOneWidget);
      expect(find.text('Connect Health Data'), findsOneWidget);
      expect(find.text('Health Connect status check failed.'),
          findsOneWidget);
      expect(find.text('Health Connect Active'), findsNothing);
      expect(find.text('Manage Health Connect'), findsNothing);
      expect(
          find.text('Health Connect status check failed [BRIDGE_DOWN].'),
          findsNothing);
      expectNoBracketedCode(tester);
    });
  });
}
