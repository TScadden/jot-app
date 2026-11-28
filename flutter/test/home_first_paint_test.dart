import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/location_service.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/streak_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/home/today_summary_card.dart';
import 'package:tabs_lab/src/features/home/weather_sheet.dart';

import 'test_helpers.dart';

/// Home First-Paint Latency package (Nov 24, 2026) — regression
/// suite converted from the Stage-1 probe suite
/// (home_first_paint_probe_test.dart, PROFILE.md §7). Each test is
/// FAIL-FIRST against base 2cf8f30f and pins one of the four fixes:
///  T1 (F1): a cold TodaySummaryCache warmed from disk (the
///     pre-frame warm, main.dart) seeds the summary card's first
///     frame while the sync pull is still gated.
///  T2 (F2): the weather sheet paints from the IP/cache path while
///     the GPS future is still pending, then upgrades to the GPS
///     location when the position lands.
///  T3 (F3): Home applies vitals in their own setState — the strip
///     repaints when loadTodayVitals lands, without waiting for
///     the streak pull.
///  T4 (F4): fetchLogEntryDtos parses the pull's entries once —
///     repeated calls return equal contents, a caller mutating
///     its returned list cannot corrupt the shared parse, and a
///     new pull body (epoch change) re-parses.

class _Mem {
  final Map<String, String> map = {};
  Future<String?> read(String k) async => map[k];
  Future<void> write(String k, String v) async => map[k] = v;
  Future<void> delete(String k) async => map.remove(k);
}

TodaySummaryCache _cacheWith(_Mem s) {
  final c = TodaySummaryCache.testInstance();
  c.debugSetStore(read: s.read, write: s.write, delete: s.delete);
  return c;
}

TodayPlanStore _planStoreWith(_Mem s) {
  final st = TodayPlanStore.testInstance();
  st.debugSetStore(read: s.read, write: s.write, delete: s.delete);
  return st;
}

const _seedPlan = TodayPlanData(
  items: [],
  plannedCount: 2,
  remainingCount: 1,
  overdueCount: 0,
  summaryText: 'SEEDED SUMMARY',
);

String _todayStr() => dateStrOf(DateTime.now());

TabsBackend _gatedBackend(Completer<void> gate, FakeSessionStore session) {
  final client = MockClient((request) async {
    if (request.url.path == '/api/sync/pull') {
      await gate.future;
      return http.Response(
        jsonEncode({
          'profile': {'medications': '[]', 'reminders': '[]'},
          'entries': [],
          'categories': [],
          'isUnlimited': true,
          'isAdmin': false,
        }),
        200,
      );
    }
    if (request.url.path == '/api/habits') {
      return http.Response(jsonEncode({'habits': []}), 200);
    }
    return http.Response('{}', 200);
  });
  return TabsBackend(client: client, sessionStore: session);
}

Widget _cardHost({
  required TabsBackend backend,
  required TodaySummaryCache cache,
  required FakeSessionStore session,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: TodaySummaryCard(
          backend: backend,
          planStore: _planStoreWith(_Mem()),
          summaryCache: cache,
          sessionStore: session,
        ),
      ),
    ),
  );
}

Position _pos(double lat, double lon) => Position(
      latitude: lat,
      longitude: lon,
      timestamp: DateTime(2026, 11, 24),
      accuracy: 10,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

/// Fake HC whose probe answers instantly (the celebration
/// suites' shape): the real bridge probe never replies under
/// fake-async pumps, which would stall _loadHealthData before
/// vitals regardless of the code under test.
class _FakeHc extends HealthConnectService {
  @override
  Future<HcAvailability> probeAvailability() async => const HcAvailability(
        serviceAvailable: true,
        grantedPermissions: HealthConnectService.requiredPermissions,
        bridgeErrorCode: null,
        stepsProbe: HcReadProbeOutcome.ok,
        persistedConnected: true,
      );
}

/// T3 repo: vitals land immediately; the streak pull is gated on
/// [streakGate] so the test can observe the strip BEFORE the pull
/// resolves. The settle's record pull answers instantly so opening
/// the gate at teardown cannot hang the suite.
class _GatedStreakRepo extends HealthRepository {
  _GatedStreakRepo() : super(hc: _FakeHc());

  final Completer<({bool succeeded, int? current, int? best})>
      streakGate = Completer();

  @override
  Future<TodayVitals> loadTodayVitals(
          {required HcAvailability snapshot}) async =>
      const TodayVitals(
        heartRate: 71,
        activeCalories: 321,
        sleepMinutes: 456,
        logCountToday: 3,
      );

  @override
  Future<({bool succeeded, int? current, int? best})> loadStreak() =>
      streakGate.future;

  @override
  Future<
      ({
        bool succeeded,
        int? current,
        int? best,
        String? stateJson,
        int? purchasedFreezes
      })> loadStreakRecord() async => (
        succeeded: true,
        current: 5,
        best: 9,
        stateJson: null,
        purchasedFreezes: null,
      );
}

void main() {
  group('T1 (F1) — cold summary cache seeds the card', () {
    testWidgets('disk blob + pre-frame warm seeds first frame '
        'while the pull is gated', (tester) async {
      final mem = _Mem();
      final writer = _cacheWith(mem);
      await writer.save(
          email: 'a@x.com',
          todayStr: _todayStr(),
          plan: _seedPlan,
          trends: const []);
      // Cold instance over the same disk — a cold process start.
      final coldCache = _cacheWith(mem);
      coldCache.debugReset();
      expect(
          coldCache.snapshot(email: 'a@x.com', todayStr: _todayStr()),
          isNull,
          reason: 'cold instance memory is empty despite disk blob');

      // The production pre-frame warm step (main.dart warm list).
      await coldCache.warmFromDisk(currentEmail: 'a@x.com');

      final session = FakeSessionStore()
        ..token = 'tok-t1'
        ..email = 'a@x.com';
      final gate = Completer<void>(); // pull never lands in-window
      await tester.pumpWidget(_cardHost(
          backend: _gatedBackend(gate, session),
          cache: coldCache,
          session: session));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('SEEDED SUMMARY'), findsOneWidget,
          reason: 'warmed seed paints the subtitle on first frames');
      expect(find.byKey(const ValueKey('todaySummaryProgressBar')),
          findsOneWidget,
          reason: 'warmed seed paints the progress bar');
      gate.complete();
      await tester.pumpAndSettle();
    });

    test('warmFromDisk refuses a foreign account blob', () async {
      final mem = _Mem();
      final writer = _cacheWith(mem);
      await writer.save(
          email: 'a@x.com',
          todayStr: _todayStr(),
          plan: _seedPlan,
          trends: const []);
      final coldCache = _cacheWith(mem);
      coldCache.debugReset();
      // Account switch: B's cold start must never seed A's plan.
      await coldCache.warmFromDisk(currentEmail: 'b@x.com');
      expect(
          coldCache.snapshot(email: 'b@x.com', todayStr: _todayStr()),
          isNull,
          reason: 'foreign blob is not warmed into memory');
      expect(mem.map.containsKey(TodaySummaryCache.storageKey), isFalse,
          reason: 'foreign blob is wiped so it cannot resurface');
    });

    test('warmFromDisk with unreadable session email warms nothing '
        'and wipes nothing', () async {
      final mem = _Mem();
      final writer = _cacheWith(mem);
      await writer.save(
          email: 'a@x.com',
          todayStr: _todayStr(),
          plan: _seedPlan,
          trends: const []);
      final coldCache = _cacheWith(mem);
      coldCache.debugReset();
      await coldCache.warmFromDisk(currentEmail: null);
      expect(
          coldCache.snapshot(email: 'a@x.com', todayStr: _todayStr()),
          isNull,
          reason: 'unbound warm serves nothing (snapshot parity)');
      expect(mem.map.containsKey(TodaySummaryCache.storageKey), isTrue,
          reason: 'an unreadable session must not destroy the blob '
              '— it may belong to this same account');
    });
  });

  group('T2 (F2) — weather sheet never gates content on GPS', () {
    testWidgets('paints from the IP path while GPS is pending, '
        'then upgrades when GPS lands', (tester) async {
      final api = WeatherApiClient(
        client: MockClient((request) async {
          if (request.url.host == 'ipinfo.io') {
            return http.Response(
                '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
                200);
          }
          return http.Response(
              '{"current":{"temperature_2m":61.4,"weather_code":2,'
              '"is_day":1,"surface_pressure":1012.3,"uv_index":4.2,'
              '"relative_humidity_2m":38,"wind_speed_10m":7.5}}',
              200);
        }),
      );
      final gps = Completer<Position?>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showWeatherSheet(
                  context: context,
                  weatherApi: api,
                  locationService: LocationService(),
                  gpsPositionFuture: gps.future,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // GPS still pending: content must already be painted from
      // the IP path — no skeleton, no "Fetching local weather...".
      expect(find.text('Fetching local weather...'), findsNothing,
          reason: 'sheet content is not gated on the GPS future');
      expect(find.text('Orem'), findsOneWidget,
          reason: 'IP-path weather painted before GPS resolves');
      // GPS lands: the sheet upgrades to the GPS location.
      gps.complete(_pos(40.0, -111.0));
      await tester.pumpAndSettle();
      expect(find.text('Current Location'), findsOneWidget,
          reason: 'GPS upgrade swaps in the GPS-based details');
    });
  });

  group('T3 (F3) — vitals repaint decoupled from the streak pull',
      () {
    setUp(() {
      TabsBackend.debugResetSharedCaches();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => call.method == 'readAll' ? <String, String>{} : null,
      );
      final disk = <String, String>{};
      LogEntryOutbox.instance.debugSetStore(
        read: (k) async => disk[k],
        write: (k, v) async {
          disk[k] = v;
        },
        delete: (k) async {
          disk.remove(k);
        },
      );
      LogEntryOutbox.instance.debugReset();
      StreakStore.instance.debugReset();
      final streakDisk = <String, String>{};
      StreakStore.instance.debugSetStore(
        read: (k) async => streakDisk[k],
        write: (k, v) async {
          streakDisk[k] = v;
        },
        delete: (k) async {
          streakDisk.remove(k);
        },
      );
      final cacheStore = _Mem();
      HomeDataCache.instance.debugSetStore(
          read: cacheStore.read,
          write: cacheStore.write,
          delete: cacheStore.delete);
      HomeDataCache.instance.debugReset();
    });

    tearDown(() {
      HomeDataCache.instance.debugReset();
      StreakStore.instance.debugReset();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        null,
      );
    });

    testWidgets('strip values repaint before the gated streak '
        'pull resolves', (tester) async {
      final repo = _GatedStreakRepo();
      // The celebration suites' shape: a test-instance score store
      // + a stub snapshot capture, so the Daily Score background
      // chain cannot leave real capture timers pending at
      // teardown.
      final scoreStore = HealthHistoryStore.testInstance();
      final scoreDisk = <String, String>{};
      scoreStore.debugSetStore(
        read: (k) async => scoreDisk[k],
        write: (k, v) async {
          scoreDisk[k] = v;
        },
        delete: (k) async {
          scoreDisk.remove(k);
        },
      );
      scoreStore.debugReset();
      await tester.pumpWidget(MaterialApp(
        // disableAnimations: CountUp renders final values instantly
        // (the celebration suites' harness shape), so the test
        // observes PAINT order, not the count-up tween.
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: HomeScreen(
          weatherApi: WeatherApiClient(
            client: MockClient((request) async {
              if (request.url.host == 'ipinfo.io') {
                return http.Response(
                    '{"city":"Orem","loc":"40.2969,-111.6946",'
                    '"country":"US"}',
                    200);
              }
              return http.Response(
                  '{"current":{"temperature_2m":60.0,'
                  '"weather_code":2,"is_day":1}}',
                  200);
            }),
          ),
          healthRepository: repo,
          healthHistoryStore: scoreStore,
          dailyScoreSnapshotCapture: ({bool force = false}) async => true,
          ),
        ),
      ));
      // Vitals land immediately; the streak pull is still gated.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('71'), findsOneWidget,
          reason: 'heart rate repaints without waiting for the '
              'streak pull');
      expect(find.text('321'), findsOneWidget,
          reason: 'calories repaint without waiting for the '
              'streak pull');
      expect(find.text('7h36m'), findsOneWidget,
          reason: 'sleep repaints without waiting for the streak '
              'pull');
      // Release the pull so the load (and its settle) can finish
      // before teardown.
      repo.streakGate
          .complete((succeeded: true, current: 5, best: 9));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // Flush the background history capture's 30s bounded-read
      // timeout (its bridge reads never reply in this harness):
      // fake time must pass the bound or the timer is still
      // pending at disposal.
      for (var i = 0; i < 50; i++) {
        await tester.pump(const Duration(seconds: 5));
      }
    });
  });

  group('T4 (F4) — entries parsed once per pull', () {
    setUp(TabsBackend.debugResetSharedCaches);
    tearDown(TabsBackend.debugResetSharedCaches);

    test('repeated calls return equal contents; mutating one '
        'returned list does not affect the next; a new pull body '
        're-parses', () async {
      var entriesPayload = <Map<String, dynamic>>[
        {
          'id': 1,
          'categoryId': 6,
          'body': 'one',
          'chips': '',
          'manualText': '',
          'timestamp': 1000,
        },
        {
          'id': 2,
          'categoryId': 6,
          'body': 'two',
          'chips': '',
          'manualText': '',
          'timestamp': 2000,
        },
      ];
      var pullCount = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          pullCount++;
          return http.Response(
            jsonEncode({
              'profile': <String, dynamic>{},
              'entries': entriesPayload,
              'categories': [],
              'isUnlimited': true,
              'isAdmin': false,
            }),
            200,
          );
        }
        if (request.url.path == '/api/sync/entries') {
          return http.Response('{}', 200);
        }
        return http.Response('{}', 200);
      });
      final backend = TabsBackend(
        client: client,
        sessionStore: FakeSessionStore()
          ..token = 'tok-t4'
          ..email = 'a@x.com',
      );

      final first = await backend.fetchLogEntryDtos();
      final second = await backend.fetchLogEntryDtos();
      expect(pullCount, 1, reason: 'one pull serves both calls');
      expect(first.map((e) => e.id).toList(), ['1', '2']);
      expect(second.map((e) => e.id).toList(),
          first.map((e) => e.id).toList());
      expect(second.map((e) => e.body).toList(), ['one', 'two']);

      // Mutating the first returned list must not corrupt the
      // shared parse the next caller receives.
      first.removeAt(0);
      first.add(first.first);
      final third = await backend.fetchLogEntryDtos();
      expect(third.map((e) => e.id).toList(), ['1', '2'],
          reason: 'consumer mutation cannot corrupt the memo');
      expect(pullCount, 1,
          reason: 'still the same pull — no refetch needed');

      // A write moves the epoch: the next read is a NEW pull body
      // and must be re-parsed, not served the stale memo.
      entriesPayload = <Map<String, dynamic>>[
        {
          'id': 7,
          'categoryId': 6,
          'body': 'seven',
          'chips': '',
          'manualText': '',
          'timestamp': 7000,
        },
      ];
      final ok = await backend.postLogEntries(const []);
      expect(ok, isTrue);
      final fourth = await backend.fetchLogEntryDtos();
      expect(pullCount, 2, reason: 'epoch change re-issues the pull');
      expect(fourth.map((e) => e.id).toList(), ['7'],
          reason: 'new pull body is re-parsed');
    });
  });
}
