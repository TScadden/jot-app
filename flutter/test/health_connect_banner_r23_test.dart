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

const _notConnectedCopy = "Health Connect isn't connected — tap to reconnect";
const _partialCopy = 'Health Connect needs permissions — tap to fix';

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

  group('banner copy (healthConnectBannerText)', () {
    test('notConnected → reconnect copy', () {
      expect(healthConnectBannerText(HealthConnectStatus.notConnected),
          _notConnectedCopy);
    });

    test('unavailable → reconnect copy (tap leads to the honest '
        'Connections state)', () {
      expect(healthConnectBannerText(HealthConnectStatus.unavailable),
          _notConnectedCopy);
    });

    test('partiallyConnected → permissions copy, never "isn\'t connected"',
        () {
      expect(
          healthConnectBannerText(HealthConnectStatus.partiallyConnected),
          _partialCopy);
    });

    test('connected → no banner', () {
      expect(healthConnectBannerText(HealthConnectStatus.connected), isNull);
    });

    test('status unknown yet → no banner (never on a guess)', () {
      expect(healthConnectBannerText(null), isNull);
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

  group('HealthConnectBanner widget', () {
    testWidgets('renders copy, tap fires, error code is visible',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: HealthConnectBanner(
            status: HealthConnectStatus.notConnected,
            errorCode: 'BRIDGE_DOWN',
            onTap: () => taps++,
          ),
        ),
      ));
      expect(find.text(_notConnectedCopy), findsOneWidget);
      expect(find.text('[BRIDGE_DOWN]'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.tap(find.text(_notConnectedCopy));
      expect(taps, 1);
    });

    testWidgets('partial renders the permissions copy', (tester) async {
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
    });
  });

  group('HomeScreen integration', () {
    testWidgets('not connected + empty → banner; tap opens Connections',
        (tester) async {
      await _pumpHome(tester, _service(granted: const []));
      expect(find.text(_notConnectedCopy), findsOneWidget);
      expect(find.text(_partialCopy), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.tap(find.text(_notConnectedCopy));
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
      expect(find.text(_notConnectedCopy), findsOneWidget);
    });

    testWidgets('bridge error → banner with the visible error code',
        (tester) async {
      await _pumpHome(
          tester, _service(granted: const [], throwOnAvailable: true));
      expect(find.text(_notConnectedCopy), findsOneWidget);
      expect(find.text('[BRIDGE_DOWN]'), findsOneWidget);
    });
  });
}
