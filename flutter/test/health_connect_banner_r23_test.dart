import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/health_connect_banner.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';

import 'test_helpers.dart';

/// Round 23 — Health Connect status banner on Home.
///
/// Every HC failure mode used to collapse into the same silent "--":
/// not connected, partial grant, bridge error, and connected-but-empty
/// were indistinguishable. Now Home tracks the status enum and the
/// banner shows only for not-fully-connected + empty biometrics.

const _notConnectedTitle = "Health Connect isn't connected";
const _notConnectedBody = 'Tap to reconnect';
// Legacy joined form, still used to assert the old single-string
// rendering is GONE (Juno item 7 splits it at the em dash).
const _notConnectedCopy = "Health Connect isn't connected — tap to reconnect";
const _partialCopy = 'Health Connect needs permissions — tap to fix';
const _staleTitle = 'Health Connect got disconnected';
const _staleBody =
    "There's a problem with the connection. Tap to disconnect and connect again.";

class _MemoryStore implements SecureStore {
  final Map<String, String> _map = {};

  @override
  Future<String?> read(String key) async => _map[key];

  @override
  Future<void> write(String key, String value) async {
    _map[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _map.remove(key);
  }
}

const _channelName = HealthConnectService.channelName;

HealthConnectService _service({
  required List<String> granted,
  bool available = true,
  bool throwOnAvailable = false,
  bool withData = false,
  bool probeSecurityFailure = false,
}) {
  final channel = const MethodChannel(_channelName);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    switch (call.method) {
      case 'isAvailable':
        if (throwOnAvailable) {
          throw PlatformException(
              code: 'BRIDGE_DOWN', message: 'bridge exploded');
        }
        return available;
      case 'getGrantedPermissions':
        return granted;
      case 'probeReadAccess':
        if (probeSecurityFailure) {
          throw PlatformException(
            code: 'PROBE_READ_FAILED',
            message: 'Probe read failed.',
            details: 'SecurityException',
          );
        }
        return true;
      case 'readHeartRateSamples':
        if (!withData) return <dynamic>[];
        final now = DateTime.now();
        final noon = DateTime(now.year, now.month, now.day, 12);
        return [
          {'t': noon.millisecondsSinceEpoch, 'bpm': 72},
        ];
      case 'readActiveCalories':
        return withData ? 300 : null;
      case 'readSleepMinutes':
        return withData ? 420 : null;
      default:
        return null;
    }
  });
  return HealthConnectService(channel: channel, store: _MemoryStore());
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

Future<void> _pumpHome(WidgetTester tester, HealthConnectService service) async {
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
  // Let weather + status/vitals loads settle, then flush the
  // staggered-entrance timers (existing home-test pattern).
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 300));
  // Outlast any count-up tween so final values are what we assert on.
  await tester.pump(const Duration(seconds: 1));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => HomeDataCache.instance.debugReset());
  tearDown(() {
    HomeDataCache.instance.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName), null);
  });

  group('banner copy (Juno ruling, HC connection-honesty)', () {
    test('notConnected → ruled title/body (item 7: shipped string split '
        'at its em dash)', () {
      expect(healthConnectBannerTitle(HealthConnectStatus.notConnected),
          _notConnectedTitle);
      expect(healthConnectBannerBody(HealthConnectStatus.notConnected),
          _notConnectedBody);
    });

    test('unavailable → same ruled title/body (item 7 covers it)', () {
      expect(healthConnectBannerTitle(HealthConnectStatus.unavailable),
          _notConnectedTitle);
      expect(healthConnectBannerBody(HealthConnectStatus.unavailable),
          _notConnectedBody);
    });

    test('stale grant → ruled title/body (items 1–2), whatever the '
        'fallback status', () {
      expect(
          healthConnectBannerTitle(HealthConnectStatus.notConnected,
              staleGrant: true),
          _staleTitle);
      expect(
          healthConnectBannerBody(HealthConnectStatus.notConnected,
              staleGrant: true),
          _staleBody);
    });

    test('partiallyConnected → permissions copy unchanged, no body, '
        'never "isn\'t connected"', () {
      expect(
          healthConnectBannerTitle(HealthConnectStatus.partiallyConnected),
          _partialCopy);
      expect(healthConnectBannerBody(HealthConnectStatus.partiallyConnected),
          isNull);
    });

    test('connected → no banner', () {
      expect(healthConnectBannerTitle(HealthConnectStatus.connected), isNull);
      expect(healthConnectBannerText(HealthConnectStatus.connected), isNull);
    });

    test('status unknown yet → no banner (never on a guess)', () {
      expect(healthConnectBannerTitle(null), isNull);
      expect(healthConnectBannerText(null), isNull);
    });

    test('staleGrantMessage is Juno item 5, byte-exact', () {
      expect(
        HealthConnectService.staleGrantMessage,
        'Tabs is disconnected from Health Connect. Health Connect lists '
        'Tabs as having permission, but a test read was blocked. This '
        'sometimes happens after an app update or reinstall. To fix it, '
        'open Health Connect, tap App permissions, tap Tabs, then tap '
        'Remove access. Return here and connect again.',
      );
    });
  });

  group('banner gate (shouldShowHealthConnectBanner)', () {
    test('not connected + empty biometrics → show', () {
      expect(
        shouldShowHealthConnectBanner(
          status: HealthConnectStatus.notConnected,
          vitals: const TodayVitals(logCountToday: 0),
        ),
        isTrue,
      );
    });

    test('log count alone does NOT count as biometric data', () {
      // Logs come from the backend, not Health Connect — a logged day
      // with no HC data still needs the banner.
      expect(
        shouldShowHealthConnectBanner(
          status: HealthConnectStatus.notConnected,
          vitals: const TodayVitals(logCountToday: 5),
        ),
        isTrue,
      );
    });

    test('partial + empty → show', () {
      expect(
        shouldShowHealthConnectBanner(
          status: HealthConnectStatus.partiallyConnected,
          vitals: null,
        ),
        isTrue,
      );
    });

    test('connected + empty → NO banner (plain honest "--")', () {
      expect(
        shouldShowHealthConnectBanner(
          status: HealthConnectStatus.connected,
          vitals: const TodayVitals(logCountToday: 0),
        ),
        isFalse,
      );
    });

    test('not connected + cached biometric data → NO banner', () {
      expect(
        shouldShowHealthConnectBanner(
          status: HealthConnectStatus.notConnected,
          vitals: const TodayVitals(heartRate: 72, logCountToday: 0),
        ),
        isFalse,
      );
    });

    test('any single biometric suppresses the banner', () {
      for (final v in const [
        TodayVitals(activeCalories: 300),
        TodayVitals(sleepMinutes: 420),
      ]) {
        expect(
          shouldShowHealthConnectBanner(
            status: HealthConnectStatus.partiallyConnected,
            vitals: v,
          ),
          isFalse,
        );
      }
    });
  });

  // Juno condition 1: NO bracketed diagnostic code renders in ANY
  // banner state. Scans every Text widget in the tree, so re-adding
  // a '[$errorCode]' render fails here (and in the Home integration
  // tests below, where real coded throws drive the banner).
  void expectNoBracketedCode(WidgetTester tester) {
    for (final element in find.byType(Text).evaluate()) {
      final widget = element.widget as Text;
      final data = widget.data ?? '';
      expect(data, isNot(matches(RegExp(r'\[[A-Z][A-Z0-9_]*\]'))),
          reason: 'banner rendered a bracketed code: "$data"');
    }
    expect(find.text('[BRIDGE_DOWN]'), findsNothing);
    expect(find.text('[STALE_GRANT]'), findsNothing);
    expect(find.text('[UNKNOWN]'), findsNothing);
  }

  group('HealthConnectBanner widget', () {
    testWidgets('renders ruled title/body, tap fires, NO error code',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: HealthConnectBanner(
            status: HealthConnectStatus.notConnected,
            onTap: () => taps++,
          ),
        ),
      ));
      expect(find.text(_notConnectedTitle), findsOneWidget);
      expect(find.text(_notConnectedBody), findsOneWidget);
      expect(find.text(_notConnectedCopy), findsNothing);
      expectNoBracketedCode(tester);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.tap(find.text(_notConnectedTitle));
      expect(taps, 1);
    });

    testWidgets('stale grant renders items 1–2 and NO code', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: HealthConnectBanner(
            status: HealthConnectStatus.notConnected,
            staleGrant: true,
            onTap: () {},
          ),
        ),
      ));
      expect(find.text(_staleTitle), findsOneWidget);
      expect(find.text(_staleBody), findsOneWidget);
      expect(find.text(_notConnectedTitle), findsNothing);
      expectNoBracketedCode(tester);
    });

    testWidgets('partial renders the permissions copy, NO code',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: HealthConnectBanner(
            status: HealthConnectStatus.partiallyConnected,
            onTap: () {},
          ),
        ),
      ));
      expect(find.text(_partialCopy), findsOneWidget);
      expect(find.text(_notConnectedCopy), findsNothing);
      expectNoBracketedCode(tester);
    });

    testWidgets('unavailable renders the item-7 copy, NO code',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: HealthConnectBanner(
            status: HealthConnectStatus.unavailable,
            onTap: () {},
          ),
        ),
      ));
      expect(find.text(_notConnectedTitle), findsOneWidget);
      expect(find.text(_notConnectedBody), findsOneWidget);
      expectNoBracketedCode(tester);
    });
  });

  group('HomeScreen integration', () {
    testWidgets('not connected + empty → banner; tap opens Connections',
        (tester) async {
      await _pumpHome(tester, _service(granted: const []));
      expect(find.text(_notConnectedTitle), findsOneWidget);
      expect(find.text(_notConnectedBody), findsOneWidget);
      expect(find.text(_partialCopy), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.tap(find.text(_notConnectedTitle));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      // Same destination as the watch icon.
      expect(find.text('Data connections'), findsOneWidget);
    });

    testWidgets('partial grant + empty → permissions banner',
        (tester) async {
      final partial =
          HealthConnectService.requiredPermissions.take(3).toList();
      await _pumpHome(tester, _service(granted: partial));
      expect(find.text(_partialCopy), findsOneWidget);
      expect(find.text(_notConnectedCopy), findsNothing);
    });

    testWidgets('connected + no data yet → NO banner, plain "--"',
        (tester) async {
      final granted = HealthConnectService.requiredPermissions.toList();
      await _pumpHome(tester, _service(granted: granted));
      expect(find.text(_notConnectedCopy), findsNothing);
      expect(find.text(_partialCopy), findsNothing);
      expect(find.text('--'), findsWidgets);
    });

    testWidgets('connected + data → NO banner, real numbers render',
        (tester) async {
      final granted = HealthConnectService.requiredPermissions.toList();
      await _pumpHome(tester, _service(granted: granted, withData: true));
      expect(find.text(_notConnectedCopy), findsNothing);
      expect(find.text(_partialCopy), findsNothing);
      expect(find.text('72'), findsOneWidget);
    });

    testWidgets('unavailable device + empty → banner', (tester) async {
      await _pumpHome(tester, _service(granted: const [], available: false));
      expect(find.text(_notConnectedTitle), findsOneWidget);
      expect(find.text(_notConnectedBody), findsOneWidget);
    });

    testWidgets('bridge error (BRIDGE_DOWN throw) → banner with the '
        'item-7 copy and NO rendered code (Juno condition 1)',
        (tester) async {
      await _pumpHome(
          tester, _service(granted: const [], throwOnAvailable: true));
      expect(find.text(_notConnectedTitle), findsOneWidget);
      expect(find.text(_notConnectedBody), findsOneWidget);
      expect(find.text('[BRIDGE_DOWN]'), findsNothing);
      expectNoBracketedCode(tester);
    });

    testWidgets('stale grant (full grants, probe SecurityException) → '
        'banner items 1–2 and NO [STALE_GRANT] anywhere', (tester) async {
      final granted = HealthConnectService.requiredPermissions.toList();
      await _pumpHome(
          tester,
          _service(granted: granted, probeSecurityFailure: true));
      expect(find.text(_staleTitle), findsOneWidget);
      expect(find.text(_staleBody), findsOneWidget);
      expect(find.text(_notConnectedTitle), findsNothing);
      expect(find.text('[STALE_GRANT]'), findsNothing);
      expectNoBracketedCode(tester);
    });
  });
}
