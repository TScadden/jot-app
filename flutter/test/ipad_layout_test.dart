import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/main.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/heart_data_cache.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/heart/heart_screen.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/home/streak_screen.dart';
import 'package:tabs_lab/src/features/onboarding/welcome_screen.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';
import 'package:tabs_lab/src/features/tools/body_info_screen.dart';
import 'package:tabs_lab/src/features/tools/sleep_screen.dart';

import 'test_helpers.dart';

/// iPad layout pass (Apple readiness Item 8) — every main surface
/// pumped at the two iPad logical sizes Apple reviews:
/// portrait 820x1180 and landscape 1180x820 (DPR 1.0).
///
/// A surface PASSES when it pumps with no RenderFlex overflow /
/// render exception (the framework reports overflows as test
/// exceptions; [expectNoException] pins that explicitly) and its
/// primary content is present and reachable (scrollable surfaces
/// are dragged and must not throw).
///
/// Rigs/fakes are the existing per-surface test rigs, replicated
/// minimally: Home's mock weather client (home_screen_test),
/// Heart's FakeHeartHc (heart_r25_test), Sleep's fake HC +
/// profile backend (tools_r18b_test), Body's pull backend
/// (body_workout_test), Streak's seeded state (streak_screen_test),
/// Settings' fake backend + in-memory store (settings_r29_test),
/// and the welcome/AppFlow onboarding rig (welcome_screen_test).

const Size ipadPortrait = Size(820, 1180);
const Size ipadLandscape = Size(1180, 820);

void setIpadSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void expectNoException(WidgetTester tester) {
  expect(tester.takeException(), isNull);
}

/// Scrolls the surface's primary vertical scrollable all the way
/// to its end in steps (building every sliver along the way, so
/// below-the-fold content is laid out at this size too) and
/// asserts no step threw — primary content stays reachable.
Future<void> expectScrollable(WidgetTester tester) async {
  for (final w in tester.widgetList<Scrollable>(find.byType(Scrollable))) {
    if (w.axisDirection != AxisDirection.down &&
        w.axisDirection != AxisDirection.up) {
      continue;
    }
    final finder = find.byWidget(w);
    var lastPixels = -1.0;
    for (var i = 0; i < 40; i++) {
      final state = tester.state<ScrollableState>(finder);
      final pixels = state.position.pixels;
      if (pixels == lastPixels) break;
      lastPixels = pixels;
      await tester.drag(finder, const Offset(0, -400));
      await tester.pump();
      expectNoException(tester);
    }
    return;
  }
}

// ── Home rig (home_screen_test) ─────────────────────────────────

MockClient _mockWeatherClient() {
  return MockClient((request) async {
    final host = request.url.host;
    if (host == 'ipinfo.io') {
      return http.Response(
          '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}', 200);
    }
    if (host == 'api.open-meteo.com') {
      return http.Response(
          '{"current":{"temperature_2m":72.0,"weather_code":2,"is_day":1}}',
          200);
    }
    return http.Response('not found', 404);
  });
}

// ── Heart rig (heart_r25_test) ──────────────────────────────────

class _FakeHeartHc extends HealthConnectService {
  _FakeHeartHc({this.byDate = const {}});

  final Map<String, List<HrSample>> byDate;

  @override
  Future<bool> isConnected() async => true;

  @override
  Future<HcAvailability> probeAvailability() async => HcAvailability(
        serviceAvailable: true,
        grantedPermissions: HealthConnectService.requiredPermissions,
        bridgeErrorCode: null,
        stepsProbe: null,
        persistedConnected: true,
      );

  @override
  Future<bool> hasPersistedConnection() async => true;

  @override
  Future<List<HrSample>> readHeartRateSamples(String dateStr) async =>
      byDate[dateStr] ?? const [];
}

String _todayStr() {
  final d = DateTime.now();
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

int _todayMs(int hour, [int minute = 0]) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day, hour, minute)
      .millisecondsSinceEpoch;
}

// ── Sleep rig (tools_r18b_test) ─────────────────────────────────

class _FakeSleepHc extends HealthConnectService {
  _FakeSleepHc({this.minutes = const {}});

  final Map<String, int?> minutes;

  @override
  Future<bool> isConnected() async => true;

  @override
  Future<int?> readSleepMinutes(String dateStr) async => minutes[dateStr];

  @override
  Future<SleepStages?> readSleepStages(String dateStr) async => null;
}

TabsBackend _backendWithProfile(Map<String, dynamic> profile) {
  final store = FakeSessionStore()..token = 'tok';
  return TabsBackend(
    client: MockClient(
      (_) async => http.Response(jsonEncode({'profile': profile}), 200),
    ),
    sessionStore: store,
  );
}

// ── Body rig (body_workout_test) ────────────────────────────────

TabsBackend _bodyBackend() {
  final now = DateTime.now().millisecondsSinceEpoch;
  final pull = <String, dynamic>{
    'profile': {'conditions': '[]', 'gender': 'female'},
    'entries': [
      {
        'id': 5,
        'categoryId': 1,
        'body': 'leg workout 3 sets',
        'chips': 'Workout',
        'manualText': '',
        'timestamp': now - 60 * 60 * 1000,
      },
    ],
    'categories': [
      {'id': 3, 'name': 'Exercise', 'isDefault': false},
      {'id': 1, 'name': 'Notes', 'isDefault': true},
    ],
  };
  final store = FakeSessionStore()..token = 'tok';
  return TabsBackend(
    client: MockClient((request) async {
      if (request.url.path == '/api/ai/body-impacts') {
        return http.Response('{"result":{"impacts":[]}}', 200);
      }
      return http.Response(jsonEncode(pull), 200);
    }),
    sessionStore: store,
  );
}

// ── Settings rig (settings_r29_test) ────────────────────────────

class _FakeSettingsBackend extends TabsBackend {
  _FakeSettingsBackend() : super(sessionStore: FakeSessionStore());

  Map<String, dynamic>? pullBody;

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async => pullBody;
}

SettingsStore _fakeSettingsStore(Map<String, String> map) =>
    SettingsStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );

// ── Tests ───────────────────────────────────────────────────────

void main() {
  group('iPad portrait 820x1180', () {
    testWidgets('Home pumps clean', (tester) async {
      setIpadSize(tester, ipadPortrait);
      await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
            weatherApi: WeatherApiClient(client: _mockWeatherClient())),
      ));
      await tester.pump();
      expectNoException(tester);
      expect(find.byKey(const ValueKey('vitalsStripCompact')), findsOneWidget);
      await expectScrollable(tester);
      // Let the staggered-entrance delay timers fire.
      await tester.pump(const Duration(milliseconds: 700));
      expectNoException(tester);
    });

    testWidgets('Heart pumps clean', (tester) async {
      setIpadSize(tester, ipadPortrait);
      HeartDataCache.instance.debugReset();
      final store = <String, String>{};
      HeartDataCache.instance.debugSetStore(
        read: (k) async => store[k],
        write: (k, v) async => store[k] = v,
        delete: (k) async => store.remove(k),
      );
      await tester.pumpWidget(MaterialApp(
        home: HeartScreen(
          email: 'a@b.c',
          healthConnectService: _FakeHeartHc(byDate: {
            _todayStr(): [
              HrSample(timeMs: _todayMs(8), bpm: 70),
              HrSample(timeMs: _todayMs(9), bpm: 80),
              HrSample(timeMs: _todayMs(11), bpm: 130),
            ],
          }),
          cache: HeartDataCache.instance,
        ),
      ));
      await tester.pumpAndSettle();
      expectNoException(tester);
      expect(find.text('Heart'), findsOneWidget);
      await expectScrollable(tester);
    });

    testWidgets('Sleep pumps clean', (tester) async {
      setIpadSize(tester, ipadPortrait);
      await tester.pumpWidget(MaterialApp(
        home: SleepScreen(
          backend: _backendWithProfile({'todaySleepMins': 522}),
          healthConnect: _FakeSleepHc(minutes: const {}),
        ),
      ));
      await tester.pumpAndSettle();
      expectNoException(tester);
      await expectScrollable(tester);
    });

    testWidgets('Body pumps clean', (tester) async {
      setIpadSize(tester, ipadPortrait);
      TabsBackend.debugResetSharedCaches();
      await tester.pumpWidget(
        MaterialApp(home: BodyInfoScreen(backend: _bodyBackend())),
      );
      await tester.pumpAndSettle();
      expectNoException(tester);
      expect(find.text('Body Impact Visualizer'), findsOneWidget);
      await expectScrollable(tester);
    });

    testWidgets('Streak pumps clean', (tester) async {
      setIpadSize(tester, ipadPortrait);
      final s = streakSeed(
          current: 5, best: 12, now: DateTime(2026, 11, 1, 12));
      await tester.pumpWidget(MaterialApp(
        home: StreakScreen(state: s, now: DateTime(2026, 11, 4, 12)),
      ));
      await tester.pump();
      expectNoException(tester);
      expect(find.text('Streak'), findsOneWidget);
      await expectScrollable(tester);
    });

    testWidgets('Settings pumps clean', (tester) async {
      setIpadSize(tester, ipadPortrait);
      final backend = _FakeSettingsBackend()
        ..pullBody = {
          'isUnlimited': false,
          'isAdmin': false,
          'nickname': 'Tyson',
          'tag': '1234',
          'profile': <String, dynamic>{},
          'insights': const [],
        };
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SettingsScreen(
            backend: backend,
            settingsStore: _fakeSettingsStore(<String, String>{}),
            notificationService: FakeReminderNotificationService(),
            urlLauncher: (uri) async => true,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expectNoException(tester);
      expect(find.text('Settings'), findsWidgets);
      await expectScrollable(tester);
    });

    testWidgets('Onboarding welcome + register step pump clean',
        (tester) async {
      setIpadSize(tester, ipadPortrait);
      await tester.pumpWidget(MaterialApp(
        home: WelcomeScreen(onRegister: () {}, onLogin: () {}),
      ));
      await tester.pump();
      expectNoException(tester);
      expect(find.text('Notes that build'), findsOneWidget);
      expect(find.text('Register'), findsOneWidget);
    });

    testWidgets('Onboarding flow: welcome -> create account pumps clean',
        (tester) async {
      setIpadSize(tester, ipadPortrait);
      await tester.pumpWidget(MaterialApp(
        home: AppFlow(
          authApi: AuthApiClient(
              client: MockClient((_) async => http.Response('{}', 200))),
          sessionStore: FakeSessionStore(),
          weatherApi: WeatherApiClient(client: _mockWeatherClient()),
        ),
      ));
      // Fast-forward past splash entry + hold + exit.
      await tester.pump(const Duration(milliseconds: 1850));
      await tester.pump(const Duration(milliseconds: 650));
      await tester.pump();
      expectNoException(tester);
      expect(find.text('Notes that build'), findsOneWidget);
      await tester.tap(find.text('Register'));
      await tester.pump();
      expectNoException(tester);
      expect(find.text('Create Your Account'), findsOneWidget);
    });
  });

  group('iPad landscape 1180x820', () {
    testWidgets('Home pumps clean', (tester) async {
      setIpadSize(tester, ipadLandscape);
      await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
            weatherApi: WeatherApiClient(client: _mockWeatherClient())),
      ));
      await tester.pump();
      expectNoException(tester);
      expect(find.byKey(const ValueKey('vitalsStripCompact')), findsOneWidget);
      await expectScrollable(tester);
      await tester.pump(const Duration(milliseconds: 700));
      expectNoException(tester);
    });

    testWidgets('Heart pumps clean', (tester) async {
      setIpadSize(tester, ipadLandscape);
      HeartDataCache.instance.debugReset();
      final store = <String, String>{};
      HeartDataCache.instance.debugSetStore(
        read: (k) async => store[k],
        write: (k, v) async => store[k] = v,
        delete: (k) async => store.remove(k),
      );
      await tester.pumpWidget(MaterialApp(
        home: HeartScreen(
          email: 'a@b.c',
          healthConnectService: _FakeHeartHc(byDate: {
            _todayStr(): [
              HrSample(timeMs: _todayMs(8), bpm: 70),
              HrSample(timeMs: _todayMs(9), bpm: 80),
              HrSample(timeMs: _todayMs(11), bpm: 130),
            ],
          }),
          cache: HeartDataCache.instance,
        ),
      ));
      await tester.pumpAndSettle();
      expectNoException(tester);
      expect(find.text('Heart'), findsOneWidget);
      await expectScrollable(tester);
    });

    testWidgets('Sleep pumps clean', (tester) async {
      setIpadSize(tester, ipadLandscape);
      await tester.pumpWidget(MaterialApp(
        home: SleepScreen(
          backend: _backendWithProfile({'todaySleepMins': 522}),
          healthConnect: _FakeSleepHc(minutes: const {}),
        ),
      ));
      await tester.pumpAndSettle();
      expectNoException(tester);
      await expectScrollable(tester);
    });

    testWidgets('Body pumps clean', (tester) async {
      setIpadSize(tester, ipadLandscape);
      TabsBackend.debugResetSharedCaches();
      await tester.pumpWidget(
        MaterialApp(home: BodyInfoScreen(backend: _bodyBackend())),
      );
      await tester.pumpAndSettle();
      expectNoException(tester);
      expect(find.text('Body Impact Visualizer'), findsOneWidget);
      await expectScrollable(tester);
    });

    testWidgets('Streak pumps clean', (tester) async {
      setIpadSize(tester, ipadLandscape);
      final s = streakSeed(
          current: 5, best: 12, now: DateTime(2026, 11, 1, 12));
      await tester.pumpWidget(MaterialApp(
        home: StreakScreen(state: s, now: DateTime(2026, 11, 4, 12)),
      ));
      await tester.pump();
      expectNoException(tester);
      expect(find.text('Streak'), findsOneWidget);
      await expectScrollable(tester);
    });

    testWidgets('Settings pumps clean', (tester) async {
      setIpadSize(tester, ipadLandscape);
      final backend = _FakeSettingsBackend()
        ..pullBody = {
          'isUnlimited': false,
          'isAdmin': false,
          'nickname': 'Tyson',
          'tag': '1234',
          'profile': <String, dynamic>{},
          'insights': const [],
        };
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SettingsScreen(
            backend: backend,
            settingsStore: _fakeSettingsStore(<String, String>{}),
            notificationService: FakeReminderNotificationService(),
            urlLauncher: (uri) async => true,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expectNoException(tester);
      expect(find.text('Settings'), findsWidgets);
      await expectScrollable(tester);
    });

    testWidgets('Onboarding welcome pumps clean', (tester) async {
      setIpadSize(tester, ipadLandscape);
      await tester.pumpWidget(MaterialApp(
        home: WelcomeScreen(onRegister: () {}, onLogin: () {}),
      ));
      await tester.pump();
      expectNoException(tester);
      expect(find.text('Notes that build'), findsOneWidget);
      expect(find.text('Register'), findsOneWidget);
    });

    testWidgets('Onboarding flow: welcome -> create account pumps clean',
        (tester) async {
      setIpadSize(tester, ipadLandscape);
      await tester.pumpWidget(MaterialApp(
        home: AppFlow(
          authApi: AuthApiClient(
              client: MockClient((_) async => http.Response('{}', 200))),
          sessionStore: FakeSessionStore(),
          weatherApi: WeatherApiClient(client: _mockWeatherClient()),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 1850));
      await tester.pump(const Duration(milliseconds: 650));
      await tester.pump();
      expectNoException(tester);
      expect(find.text('Notes that build'), findsOneWidget);
      await tester.tap(find.text('Register'));
      await tester.pump();
      expectNoException(tester);
      expect(find.text('Create Your Account'), findsOneWidget);
    });
  });
}
