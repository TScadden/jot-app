import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/main.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/onboarding_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/data/widget_sync.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/onboarding/welcome_screen.dart';
import 'package:tabs_lab/src/features/settings/account_actions.dart';

import 'test_helpers.dart';

/// Round 52 FIX — tests for the new hardening behavior (the R52
/// audit tests in `widget_sync_r52_test.dart` cover the pre-existing
/// trigger accounting + payload matrix):
/// - app-start re-publish fires exactly one push with the right
///   payload for (a) session+snapshot, (b) no session, (c) session
///   without a snapshot;
/// - the widget update is requested even when a mid-sequence save
///   throws (clear path; the push path is covered by the flipped
///   characterization test in the audit file);
/// - `warmFromDisk` owner-mismatch clears the widget;
/// - double-clear removal: the session-expiry path (AppFlow) and
///   the logout wipe (AccountActions) each yield exactly ONE
///   widget update end-to-end, through HomeDataCache.clear() only.
class _FakeBridge {
  final Map<String, Object?> saved = {};
  final List<String> saveAttempts = [];
  var updateAttempts = 0;
  String? failOnSaveKey;

  Future<void> save(String key, Object? value) async {
    saveAttempts.add(key);
    if (key == failOnSaveKey) throw StateError('bridge down at $key');
    saved[key] = value;
  }

  Future<void> update() async {
    updateAttempts++;
  }

  void install() => WidgetSync.debugSetBridge(save: save, update: update);

  void reset() {
    saved.clear();
    saveAttempts.clear();
    updateAttempts = 0;
    failOnSaveKey = null;
  }
}

const _signedOutMap = <String, Object?>{
  WidgetSync.keySignedIn: false,
  WidgetSync.keyHeartRate: '--',
  WidgetSync.keyStreak: '--',
  WidgetSync.keyLogs: '--',
  WidgetSync.keySleep: '--',
};

HomeCacheSnapshot _snap({
  TodayVitals? vitals,
  bool vitalsLoaded = true,
  int? currentStreak,
  bool streakLoaded = true,
}) {
  return HomeCacheSnapshot(
    vitals: vitals,
    vitalsLoaded: vitalsLoaded,
    currentStreak: currentStreak,
    bestStreak: null,
    streakLoaded: streakLoaded,
  );
}

void main() {
  final bridge = _FakeBridge();

  setUp(() {
    bridge.reset();
    bridge.install();
  });

  tearDown(WidgetSync.debugResetBridge);

  group('R52 app-start re-publish (WidgetSync.republishAppStart)', () {
    test('(a) session + snapshot → exactly one signed-in push with '
        'the snapshot values', () async {
      await WidgetSync.republishAppStart(
        hasSession: true,
        snapshot: _snap(
          vitals: const TodayVitals(
            heartRate: 72,
            sleepMinutes: 482,
            logCountToday: 3,
          ),
          currentStreak: 12,
        ),
      );
      expect(bridge.saved, const <String, Object?>{
        WidgetSync.keySignedIn: true,
        WidgetSync.keyHeartRate: '72',
        WidgetSync.keyStreak: '12',
        WidgetSync.keyLogs: '3',
        WidgetSync.keySleep: '8h2m',
      });
      expect(bridge.saveAttempts, hasLength(5));
      expect(bridge.updateAttempts, 1);
    });

    test('(b) no session → exactly one signed-out push, even with '
        'a full snapshot in the cache', () async {
      await WidgetSync.republishAppStart(
        hasSession: false,
        snapshot: _snap(
          vitals: const TodayVitals(heartRate: 72, logCountToday: 3),
          currentStreak: 12,
        ),
      );
      expect(bridge.saved, _signedOutMap);
      expect(bridge.saveAttempts, hasLength(5));
      expect(bridge.updateAttempts, 1);
    });

    test('(c) session but NO cached snapshot → signed-out push '
        '(never a signed-in face with invented/empty numbers)', () async {
      await WidgetSync.republishAppStart(
        hasSession: true,
        snapshot: _snap(
          vitals: null,
          vitalsLoaded: false,
          currentStreak: null,
          streakLoaded: false,
        ),
      );
      expect(bridge.saved, _signedOutMap);
      expect(bridge.updateAttempts, 1);
    });
  });

  group('R52 update-in-finally (clear path)', () {
    test('clear requests the update even when a mid-sequence save '
        'throws; the remaining saves still land', () async {
      bridge.failOnSaveKey = WidgetSync.keyLogs;
      await expectLater(WidgetSync.clear(), completes);
      expect(bridge.saveAttempts, hasLength(5));
      expect(bridge.saved.containsKey(WidgetSync.keyLogs), isFalse);
      expect(bridge.saved[WidgetSync.keySignedIn], isFalse);
      expect(bridge.saved[WidgetSync.keySleep], '--');
      expect(bridge.updateAttempts, 1);
    });
  });

  group('R52 HomeDataCache funnels', () {
    final disk = <String, String>{};

    setUp(() {
      disk.clear();
      HomeDataCache.instance.debugSetStore(
        read: (key) async => disk[key],
        write: (key, value) async => disk[key] = value,
        delete: (key) async => disk.remove(key),
      );
      HomeDataCache.instance.debugReset();
    });

    tearDown(() {
      HomeDataCache.instance.debugReset();
    });

    test('warmFromDisk owner-mismatch clears the widget (previous '
        'account numbers do not survive the drop)', () async {
      final cache = HomeDataCache.instance;
      // Seed a disk blob owned by the first account.
      cache.applyVitals(
        const TodayVitals(heartRate: 88, logCountToday: 5),
        ownerEmail: 'first@example.com',
      );
      await cache.persist();
      await pumpEventQueue();
      expect(disk.containsKey(HomeDataCache.storageKey), isTrue);
      // Cold start: memory empty, blob still on disk.
      cache.debugReset();
      bridge.reset();
      await cache.warmFromDisk(currentEmail: 'second@example.com');
      await pumpEventQueue();
      expect(disk.containsKey(HomeDataCache.storageKey), isFalse);
      expect(bridge.saved, _signedOutMap);
      expect(bridge.updateAttempts, 1);
    });

    test('logout wipe (AccountActions.clearDefaultCaches) yields '
        'exactly ONE widget update end-to-end', () async {
      final cache = HomeDataCache.instance;
      cache.applyVitals(const TodayVitals(heartRate: 70));
      bridge.reset();
      await AccountActions.clearDefaultCaches();
      await pumpEventQueue();
      expect(bridge.saved, _signedOutMap);
      expect(bridge.updateAttempts, 1);
    });
  });

  group('R52 native provider source assertions (no Android '
      'unit-test pattern exists in flutter/android — the artifact '
      'gate in tool/check_widget_apk.sh covers the compiled side)',
      () {
    final provider = File(
        'android/app/src/main/kotlin/com/notel/notel/playground/'
        'flutter/VitalsWidgetProvider.kt');

    test('provider reads prefs type-tolerantly via .all, never '
        'bare getBoolean/getString on widgetData', () {
      final src = provider.readAsStringSync();
      expect(src, contains('widgetData.all'));
      expect(src, isNot(contains('widgetData.getBoolean')));
      expect(src, isNot(contains('widgetData.getString')));
      // Only a real Boolean counts for the signed-in flag.
      expect(src, contains('as? Boolean'));
    });

    test('onUpdate is exception-proof: signed-out fallback, then '
        'minimal hardcoded fallback', () {
      final src = provider.readAsStringSync();
      expect(src, contains('catch (_: Exception)'));
      expect(src, contains('signedOutViews(context)'));
      expect(src, contains('fallbackViews(context)'));
      expect(src, contains('R.layout.vitals_widget_fallback'));
      expect(src, contains('"Open Tabs to sign in"'));
    });

    test('fallback layout is a single TextView on the widget '
        'background drawable', () {
      final layout =
          File('android/app/src/main/res/layout/vitals_widget_fallback.xml')
              .readAsStringSync();
      expect(layout, contains('@drawable/widget_background'));
      expect(layout, contains('android:text="Open Tabs to sign in"'));
      expect('<TextView'.allMatches(layout).length, 1);
    });

    test('R8 keep rules name the provider + home_widget classes', () {
      final rules =
          File('android/app/proguard-rules.pro').readAsStringSync();
      expect(rules,
          contains('-keep class com.notel.notel.playground.flutter.VitalsWidgetProvider'));
      expect(rules, contains('es.antonborri.home_widget.HomeWidgetProvider'));
      expect(rules, contains('es.antonborri.home_widget.HomeWidgetPlugin'));
    });
  });

  testWidgets('session expiry (AppFlow) yields exactly ONE widget '
      'update end-to-end and routes to welcome', (tester) async {
    final disk = <String, String>{};
    HomeDataCache.instance.debugSetStore(
      read: (key) async => disk[key],
      write: (key, value) async => disk[key] = value,
      delete: (key) async => disk.remove(key),
    );
    HomeDataCache.instance.debugReset();
    addTearDown(() {
      HomeDataCache.instance.debugReset();
      TabsBackend.onSessionExpired = null;
    });

    final onboardingMap = <String, String>{};
    final store = FakeSessionStore()
      ..token = 'fake-access'
      ..refreshToken = 'fake-refresh'
      ..email = 'a@x.com';
    await tester.pumpWidget(
      MaterialApp(
        home: AppFlow(
          authApi: AuthApiClient(
            client: MockClient((_) async => http.Response('{}', 200)),
          ),
          sessionStore: store,
          onboardingStore: OnboardingStore.withStorage(
            read: (k) async => onboardingMap[k],
            write: (k, v) async => onboardingMap[k] = v,
            delete: (k) async => onboardingMap.remove(k),
          ),
          weatherApi: WeatherApiClient(
            client: MockClient(
              (_) async => http.Response(
                '{"current":{"temperature_2m":61.0,'
                '"weather_code":2,"is_day":1}}',
                200,
              ),
            ),
          ),
        ),
      ),
    );
    // Past the splash (entry 650 + hold 1200 + exit 650).
    await tester.pump(const Duration(milliseconds: 1850));
    await tester.pump(const Duration(milliseconds: 650));
    await tester.pump();
    expect(find.byType(HomeScreen), findsOneWidget);

    // Count only the expiry path: Home's own pushes while landing
    // are settled and discarded.
    bridge.reset();
    // The backend wrapper clears the session store BEFORE firing
    // this callback in production; mirror that order here.
    await store.clear();
    TabsBackend.onSessionExpired?.call();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(WelcomeScreen), findsOneWidget);
    expect(bridge.saved, _signedOutMap);
    expect(bridge.updateAttempts, 1);
  });
}
