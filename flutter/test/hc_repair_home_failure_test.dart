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
import 'package:tabs_lab/src/features/home/hc_repair_card.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';

import 'test_helpers.dart';

/// HC repair Continue fix (Nov 21, 2026) — regression tests for the
/// founder report "Clicking this is doing nothing": on Home, a
/// FAILED repair outcome (any launch/request failure other than
/// the stale grant) was swallowed by `_onHcRepairTap` into a
/// debugPrint only, so the disclosure closed, the spinner stopped,
/// and nothing rendered. The Heart screen surfaces the same
/// outcome through its error line (`_error = result.errorMessage`);
/// Home must surface the failure's plain-language message visibly
/// under its repair card the same way. Diagnostic CODES still never
/// render (Juno condition 1, enforced for Home by
/// health_connect_banner_r23_test.dart) — the code stays in the
/// debugPrint log; the visible line is the message, exactly like
/// Heart's.
///
/// The fake's IN_FLIGHT throw carries the native plugin's exact
/// message for that code (HealthConnectBridgePlugin.kt).

const _inFlightMessage =
    'A Health Connect permission request is already in progress.';

/// Home-screen fake for the repair-failure tests: full grant, but
/// the steps probe is SecurityException-blocked while [wedged] —
/// the Nov 20, 2026 incident shape, so Home derives its wedged
/// state and shows the repair card. [requestPermissions] throws
/// [requestError] when set; otherwise it unwedges.
class _HomeRepairHc extends HealthConnectService {
  bool wedged = true;
  Object? requestError;
  int requestCalls = 0;

  @override
  Future<HcAvailability> probeAvailability() async => fakeHcSnapshot(
        granted: HealthConnectService.requiredPermissions.toSet(),
        stepsProbe: wedged
            ? HcReadProbeOutcome.securityFailure
            : HcReadProbeOutcome.ok,
        persistedConnected: true,
      );

  @override
  Future<bool> hasPersistedConnection() async => true;

  @override
  Future<List<HrSample>> readHeartRateSamples(String dateStr) async {
    final now = DateTime.now();
    final noon = DateTime(now.year, now.month, now.day, 12)
        .millisecondsSinceEpoch;
    return [
      HrSample(timeMs: noon, bpm: 70),
      HrSample(timeMs: noon + 3600000, bpm: 80),
    ];
  }

  @override
  Future<int?> readActiveCalories(String dateStr) async => 300;

  @override
  Future<int?> readSleepMinutes(String dateStr) async => 420;

  @override
  Future<Set<String>> requestPermissions() async {
    requestCalls++;
    final error = requestError;
    if (error != null) throw error;
    wedged = false;
    return HealthConnectService.requiredPermissions;
  }
}

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

Future<void> _pumpHome(WidgetTester tester, _HomeRepairHc hc) async {
  final backend = TabsBackend(
    client: MockClient((_) async => http.Response('not found', 404)),
    sessionStore: FakeSessionStore(),
  );
  final repo = HealthRepository(hc: hc, backend: backend);
  await tester.pumpWidget(MaterialApp(
    home: HomeScreen(
      weatherApi: WeatherApiClient(client: _mockWeatherClient()),
      healthConnectService: hc,
      healthRepository: repo,
    ),
  ));
  // Same settle pattern as health_connect_banner_r23_test.dart.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(seconds: 1));
  await tester.pump();
}

/// Bounded pumps for the dialog steps: while the MF-3 disclosure
/// is open, the card's button shows its progress spinner, so
/// pumpAndSettle can never settle (pattern from
/// hc_grant_hardening_test.dart).
Future<void> _pumpDialogSteps(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Bounded settle: Home never fully settles in the harness (its
/// ambient animations keep frames scheduled), so pumpAndSettle
/// times out — pump fixed steps instead, well past the dialog's
/// exit animation and the fake-backed flow/reload futures.
Future<void> _pumpBounded(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

Future<void> _tapRepairAndContinue(WidgetTester tester) async {
  await tester.ensureVisible(find.text(hcRepairCardButton));
  await tester.pump();
  await tester.tap(find.text(hcRepairCardButton));
  await _pumpDialogSteps(tester);
  // MF-3: the disclosure is up and NOTHING has launched yet.
  expect(find.text('Continue'), findsOneWidget);
  await tester.tap(find.text('Continue'));
  await _pumpBounded(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => HomeDataCache.instance.debugReset());
  tearDown(() => HomeDataCache.instance.debugReset());

  group('Home repair card — failed outcome visibility', () {
    testWidgets(
        'failed repair (IN_FLIGHT throw) renders the failure '
        'message visibly under the Home repair card',
        (tester) async {
      final hc = _HomeRepairHc()
        ..requestError =
            const HealthConnectException('IN_FLIGHT', _inFlightMessage);
      await _pumpHome(tester, hc);

      expect(find.byType(HcRepairCard), findsOneWidget);
      expect(find.text(_inFlightMessage), findsNothing);

      await _tapRepairAndContinue(tester);
      expect(hc.requestCalls, 1);

      // THE REGRESSION: pre-fix, Home swallowed this outcome into
      // a debugPrint — the card stood unchanged and no error text
      // existed anywhere in the tree.
      expect(find.text(_inFlightMessage), findsOneWidget);
      // The card itself is still up (the wedge survives a failed
      // request; only a cleared flow or a still-wedged verdict
      // changes it).
      expect(find.byType(HcRepairCard), findsOneWidget);
      // Juno condition 1: the diagnostic CODE never renders.
      expect(find.textContaining('[IN_FLIGHT]'), findsNothing);
    });

    testWidgets(
        'a retry that succeeds clears the visible error and the '
        'repair card with the wedge', (tester) async {
      final hc = _HomeRepairHc()
        ..requestError =
            const HealthConnectException('IN_FLIGHT', _inFlightMessage);
      await _pumpHome(tester, hc);

      await _tapRepairAndContinue(tester);
      expect(find.text(_inFlightMessage), findsOneWidget);
      expect(find.byType(HcRepairCard), findsOneWidget);

      // The wedge's cause is gone; the retry re-grants in place.
      hc.requestError = null;
      await _tapRepairAndContinue(tester);
      expect(hc.requestCalls, 2);

      // Successful re-grant: the reload derives the cleared state —
      // card gone, and the earlier failure line gone with it.
      expect(find.byType(HcRepairCard), findsNothing);
      expect(find.text(_inFlightMessage), findsNothing);
    });
  });
}
