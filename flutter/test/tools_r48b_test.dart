import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/body_info_screen.dart';
import 'package:tabs_lab/src/features/tools/food_screen.dart';
import 'package:tabs_lab/src/features/tools/key_metrics_screen.dart';
import 'package:tabs_lab/src/features/tools/sleep_screen.dart';

import 'test_helpers.dart';

/// Round 48 (Team B) — Sleep, Body Info, Key Metrics, Food.
///
/// Covers the round's fixes: Sleep date picker / compare / debt math
/// + the guarded-read timeout fix, Body Info's native impact engine
/// port + AI mapping, Key Metrics' per-date reads + CSV export, and
/// Food's persisted encyclopedia + level normalization.

TabsBackend _backend(Map<String, dynamic> pullBody, {int status = 200}) {
  final store = FakeSessionStore()..token = 'tok';
  return TabsBackend(
    client: MockClient(
        (_) async => http.Response(jsonEncode(pullBody), status)),
    sessionStore: store,
  );
}

String _key(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

Future<void> _pump(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(MaterialApp(home: screen));
  await tester.pumpAndSettle();
}

/// Tall surface so lazy grids/lists build every row the tests assert
/// on (the default 800×600 test viewport leaves later tiles unbuilt).
void _bigSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

// ── Sleep fakes ─────────────────────────────────────────────────────

class _SleepHc extends HealthConnectService {
  _SleepHc({this.minutes = const {}, this.hangStages = false});

  final Map<String, int?> minutes;
  final bool hangStages;

  @override
  Future<bool> isConnected() async => true;

  @override
  Future<int?> readSleepMinutes(String dateStr) async => minutes[dateStr];

  @override
  Future<SleepStages?> readSleepStages(String dateStr) {
    if (hangStages) return Completer<SleepStages?>().future;
    return Future.value(null);
  }
}

Map<String, int?> _minutesAll(int mins) {
  final map = <String, int?>{};
  final now = DateTime.now();
  for (var i = 0; i < 14; i++) {
    map[_key(now.subtract(Duration(days: i)))] = mins;
  }
  return map;
}

void main() {
  // Oct 26, 2026 perf package: the sync-pull and habits caches are
  // STATIC and session-keyed, and cases in this file reuse one session
  // token across fresh fake servers — reset between cases so one
  // case's cached pull/habits body cannot be served to the next case.
  setUp(TabsBackend.debugResetSharedCaches);
  // R70 WS2 — the union helper reads/writes the shared history
  // store; reset it (in-memory backing) so cases stay isolated.
  setUp(() {
    final mem = <String, String>{};
    HealthHistoryStore.instance.debugSetStore(
      read: (k) async => mem[k],
      write: (k, v) async => mem[k] = v,
      delete: (k) async => mem.remove(k),
    );
    HealthHistoryStore.instance.debugReset();
  });

  // ── Sleep: pure math ──────────────────────────────────────────────

  group('computeSleepDebtMins (native calculateDebtAtDate port)', () {
    test('all 8h nights → no debt', () {
      final now = DateTime.now();
      final history = {
        for (var i = 0; i < 10; i++)
          _key(now.subtract(Duration(days: i))): 480,
      };
      expect(computeSleepDebtMins(history, _key(now)), 0);
    });

    test('ten 7h nights → 10h of debt', () {
      final now = DateTime.now();
      final history = {
        for (var i = 0; i < 10; i++)
          _key(now.subtract(Duration(days: i))): 420,
      };
      expect(computeSleepDebtMins(history, _key(now)), -600);
    });

    test('surplus over 8h is capped at 1.5h of credit', () {
      final d1 = _key(DateTime.now().subtract(const Duration(days: 1)));
      final d2 = _key(DateTime.now());
      // 1h debt, then a 10h night: credit capped at 1.5h → debt 0,
      // never negative.
      expect(computeSleepDebtMins({d1: 420, d2: 600}, d2), 0);
      expect(computeSleepDebtMins({d2: 600}, d2), 0);
    });

    test('only the last 10 nights count; future nights are ignored', () {
      final now = DateTime.now();
      final history = <String, int>{
        _key(now.subtract(const Duration(days: 10))): 60, // 11th night
        for (var i = 0; i < 10; i++)
          _key(now.subtract(Duration(days: i))): 480,
        _key(now.add(const Duration(days: 1))): 60, // future — ignored
      };
      expect(computeSleepDebtMins(history, _key(now)), 0);
    });

    test('empty history → 0 (screen renders "--" separately)', () {
      expect(computeSleepDebtMins({}, _key(DateTime.now())), 0);
    });
  });

  group('sleepWeekAverage + hero format', () {
    test('averages only nights with real data in the 7-day window', () {
      final now = DateTime.now();
      final history = {
        _key(now): 420,
        _key(now.subtract(const Duration(days: 2))): 480,
        _key(now.subtract(const Duration(days: 6))): 540,
        _key(now.subtract(const Duration(days: 7))): 60, // outside
      };
      expect(sleepWeekAverage(history, _key(now)), 480);
      expect(sleepWeekAverage({}, _key(now)), isNull);
    });

    test('hero format always shows hours and minutes (native)', () {
      expect(formatSleepHeroMins(480), '8h0m');
      expect(formatSleepHeroMins(450), '7h30m');
    });
  });

  group('SleepScreen (round 48)', () {
    testWidgets('wedged stages channel no longer hangs the load',
        (tester) async {
      _bigSurface(tester);
      // Regression test for the tools_team_b timeouts: readSleepStages
      // never completes (unmocked/wedged channel). The guarded read
      // must time out and the screen must finish loading with the
      // minutes that DID arrive.
      await _pump(
        tester,
        SleepScreen(
          backend: _backend({'profile': {}}),
          healthConnect:
              _SleepHc(minutes: _minutesAll(450), hangStages: true),
        ),
      );
      expect(find.text('Time Asleep Today'), findsOneWidget);
      expect(find.text('7h30m'), findsWidgets);
      expect(find.text('Recent Nights'), findsOneWidget);
      expect(find.text('Loading Sleep Data...'), findsNothing);
    });

    testWidgets('compare days: picker → comparison card with difference',
        (tester) async {
      _bigSurface(tester);
      await _pump(
        tester,
        SleepScreen(
          backend: _backend({'profile': {}}),
          healthConnect: _SleepHc(minutes: _minutesAll(450)),
        ),
      );
      expect(find.text('Compare Days'), findsOneWidget);
      expect(find.text('Compare Weeks'), findsOneWidget);
      await tester.tap(find.text('Compare Days'));
      await tester.pumpAndSettle();
      // Date picker is showing; confirm today (450m, same as selected).
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('Daily Comparison'), findsOneWidget);
      expect(find.text('Difference: +0m'), findsOneWidget);
      // Clear button removes the card.
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.text('Daily Comparison'), findsNothing);
    });

    testWidgets('tapping a recent night selects it (Daily label + Today)',
        (tester) async {
      _bigSurface(tester);
      await _pump(
        tester,
        SleepScreen(
          backend: _backend({'profile': {}}),
          healthConnect: _SleepHc(minutes: _minutesAll(450)),
        ),
      );
      expect(find.text('Time Asleep Today'), findsOneWidget);
      expect(find.byIcon(Icons.today), findsNothing);
      await tester.tap(find.byIcon(Icons.bedtime).first);
      await tester.pumpAndSettle();
      expect(find.text('Daily Time Asleep'), findsOneWidget);
      expect(find.byIcon(Icons.today), findsOneWidget);
      // Back to today via the Today action.
      await tester.tap(find.byIcon(Icons.today));
      await tester.pumpAndSettle();
      expect(find.text('Time Asleep Today'), findsOneWidget);
    });
  });

  // ── Body Info ─────────────────────────────────────────────────────

  QuickLogEntry entry({
    required int id,
    required String body,
    String chips = '',
    String manualText = '',
    required int timestamp,
  }) =>
      QuickLogEntry(
        id: id,
        categoryId: 1,
        body: body,
        chips: chips,
        manualText: manualText,
        timestamp: timestamp,
      );

  group('evaluateBodyImpacts (native BodyImpactEngine port)', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    const halfHour = 30 * 60 * 1000;

    test('headache: severe scales the window to 3h', () {
      final out = evaluateBodyImpacts(
        [entry(id: 1, body: 'Terrible headache', timestamp: now - halfHour)],
        now,
      );
      final head = out.where((i) => i.regionId == 'HEAD').toList();
      expect(head, hasLength(1));
      expect(head.single.durationMinutes, 180);
      expect(head.single.status, 'Symptom Active (0h ago)');
      expect(head.single.timeRemainingText(now), '2h 30m');
    });

    test('expired impacts are dropped', () {
      final out = evaluateBodyImpacts(
        [
          entry(
              id: 1,
              body: 'headache',
              timestamp: now - 5 * 60 * 60 * 1000), // 2h window, 5h ago
        ],
        now,
      );
      expect(out.where((i) => i.regionId == 'HEAD'), isEmpty);
    });

    test('medication impacts are gated to Medications Tab entries', () {
      final dose = entry(
        id: 2,
        body: 'Took Medication: Ivabradine (7.5mg) 2x daily',
        timestamp: now - halfHour,
      );
      expect(
        evaluateBodyImpacts([dose], now)
            .where((i) => i.regionId == 'SYSTEMIC'),
        isEmpty,
      );
      final fromTab = entry(
        id: 2,
        body: 'Took Medication: Ivabradine (7.5mg) 2x daily',
        chips: '["Medication Tab"]',
        timestamp: now - halfHour,
      );
      final systemic = evaluateBodyImpacts([fromTab], now)
          .where((i) => i.regionId == 'SYSTEMIC')
          .toList();
      expect(systemic, hasLength(1));
      expect(systemic.single.regionName, 'Systemic (Ivabradine)');
      expect(systemic.single.durationMinutes, 12 * 60); // 2x daily → 12h
      expect(systemic.single.details, contains('Ivabradine (7.5mg active)'));
    });

    test('peptide shot from the Medications Tab → PEPTIDE only', () {
      final shot = entry(
        id: 3,
        body: 'Peptide shot',
        chips: 'Medication Tab',
        timestamp: now - halfHour,
      );
      final out = evaluateBodyImpacts([shot], now);
      expect(out.map((i) => i.regionId), ['PEPTIDE']);
      expect(out.single.durationMinutes, 24 * 60);
    });

    test('results are sorted newest first', () {
      final older = entry(
          id: 4, body: 'Feeling dizzy', timestamp: now - 60 * 60 * 1000);
      final newer =
          entry(id: 5, body: 'Blood draw', timestamp: now - halfHour);
      final out = evaluateBodyImpacts([older, newer], now);
      expect(out.first.relatedLogId, 5);
      expect(out.first.regionId, 'LEFT_ARM'); // no side mentioned → left
    });
  });

  group('mapAiBodyImpacts', () {
    test('maps AI items, gates SYSTEMIC, unknown region → BACK', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final entries = [
        entry(id: 7, body: 'Feeling dizzy', timestamp: now),
        entry(id: 8, body: 'Random note', timestamp: now),
      ];
      final response = {
        'result': {
          'impacts': [
            {
              'region': 'HEAD',
              'regionName': 'Head & Neurological',
              'status': 'AI status',
              'details': 'AI details',
              'durationMinutes': 120,
              'logId': 7,
            },
            {
              // Not from the Medications Tab → dropped by the gate.
              'region': 'SYSTEMIC',
              'regionName': 'Systemic',
              'status': 'x',
              'details': 'y',
              'durationMinutes': 60,
              'logId': 8,
            },
            {
              'region': 'NOPE',
              'regionName': 'Mystery',
              'status': 'x',
              'details': 'y',
              'durationMinutes': '45', // string tolerated
              'logId': '7',
            },
          ],
        },
      };
      final out = mapAiBodyImpacts(response, entries);
      expect(out, hasLength(2));
      expect(out[0].regionId, 'HEAD');
      expect(out[0].details, 'AI details');
      expect(out[1].regionId, 'BACK');
      expect(out[1].durationMinutes, 45);
      expect(mapAiBodyImpacts(null, entries), isEmpty);
      expect(mapAiBodyImpacts({'result': {}}, entries), isEmpty);
    });
  });

  group('BodyInfoScreen (round 48)', () {
    TabsBackend bodyBackend({required bool aiResponds}) {
      final store = FakeSessionStore()..token = 'tok';
      final now = DateTime.now().millisecondsSinceEpoch;
      return TabsBackend(
        client: MockClient((request) async {
          if (request.url.path == '/api/ai/body-impacts') {
            return http.Response(
              jsonEncode({
                'result': {
                  'impacts': aiResponds
                      ? [
                          {
                            'region': 'HEAD',
                            'regionName': 'Head & Neurological',
                            'status': 'AI evaluated',
                            'details': 'AI details here.',
                            'durationMinutes': 120,
                            'logId': 7,
                          },
                        ]
                      : <dynamic>[],
                },
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'profile': <String, dynamic>{},
              'entries': [
                {
                  'id': 7,
                  'categoryId': 1,
                  'body': 'Feeling dizzy',
                  'chips': '',
                  'manualText': '',
                  'timestamp': now - 30 * 60 * 1000,
                },
              ],
            }),
            200,
          );
        }),
        sessionStore: store,
      );
    }

    testWidgets('local impact renders, expands to logged entry details',
        (tester) async {
      _bigSurface(tester);
      await _pump(
          tester, BodyInfoScreen(backend: bodyBackend(aiResponds: false)));
      expect(find.text('Active Body Impact Zones'), findsOneWidget);
      expect(find.text('Head & Neurological'), findsOneWidget);
      expect(find.text('1 Active'), findsOneWidget);
      expect(find.text('1 active body zones tracked'), findsOneWidget);
      await tester.tap(find.text('Head & Neurological'));
      await tester.pumpAndSettle();
      expect(find.text('LOGGED ENTRY DETAILS'), findsOneWidget);
      expect(find.text('"Feeling dizzy"'), findsOneWidget);
      expect(find.text('Active Window: 2h'), findsOneWidget);
      expect(find.textContaining('Logged: '), findsOneWidget);
    });

    testWidgets('non-empty AI result replaces the local impacts',
        (tester) async {
      _bigSurface(tester);
      await _pump(
          tester, BodyInfoScreen(backend: bodyBackend(aiResponds: true)));
      expect(find.text('AI details here.'), findsOneWidget);
      expect(find.text('AI evaluated'), findsOneWidget);
    });
  });

  // ── Key Metrics ───────────────────────────────────────────────────

  group('buildMetricsCsv (native exportMetricsCsv port)', () {
    test('header, center padding, No data rules, real spike zero', () {
      final csv = buildMetricsCsv(
        datesDesc: const ['2026-10-13', '2026-10-12', '2026-10-11'],
        avgHrByDate: const {'2026-10-13': 72, '2026-10-11': 0},
        sleepByDate: const {'2026-10-13': 450, '2026-10-11': 0},
        deepByDate: const {'2026-10-13': 120},
        spikesByDate: const {'2026-10-13': 0, '2026-10-12': 3},
      );
      // No trim(): the exact-string contract includes the last line's
      // trailing center-padding (native centerPad pads every field);
      // trimming would eat exactly the padding under test.
      final lines = csv.split('\n');
      expect(lines[0],
          'Date,Average HR (BPM),Sleep Duration,Deep Sleep,Spikes (count)');
      expect(lines[1],
          '2026-10-13,        72        ,    7h30m     ,   2h0m   ,      0       ');
      expect(lines[2],
          '2026-10-12,     No data      ,   No data    , No data  ,      3       ');
      // Zero biometrics are failed reads → "No data" everywhere.
      expect(lines[3],
          '2026-10-11,     No data      ,   No data    , No data  ,   No data    ');
    });

    test('nonZeroDouble tolerates strings, drops zero/negatives', () {
      expect(nonZeroDouble(14.5), 14.5);
      expect(nonZeroDouble('14.5'), 14.5);
      expect(nonZeroDouble(0), isNull);
      expect(nonZeroDouble('0'), isNull);
      expect(nonZeroDouble(-3), isNull);
      expect(nonZeroDouble('abc'), isNull);
      expect(nonZeroDouble(null), isNull);
    });
  });

  group('KeyMetricsScreen (round 48)', () {
    testWidgets(
        'per-date HC reads render all six native tiles; export dialog rules',
        (tester) async {
      final hc = _MetricsHc();
      _bigSurface(tester);
      final backend = _backend({
        'profile': {'todayAvgHr': '78', 'weightKg': '70'},
      });
      await _pump(
          tester, KeyMetricsScreen(backend: backend, healthConnect: hc));
      // Daytime average from samples (70 + 90) / 2 — not the profile.
      expect(find.text('80'), findsOneWidget);
      expect(find.text('157'), findsOneWidget); // 71kg HC weight → lbs
      expect(find.text('14.5'), findsOneWidget); // breathing rate
      expect(find.text('98.0'), findsOneWidget); // blood oxygen
      expect(find.text('58'), findsOneWidget); // resting HR
      expect(find.text('42'), findsOneWidget); // HRV 42.4 → "42"
      expect(find.text('Not synced on this build.'), findsNothing);
      expect(find.text('Active Calories'), findsNothing);

      // Export dialog: All Time forces spikes off + disables the switch.
      await tester.tap(find.byIcon(Icons.download));
      await tester.pumpAndSettle();
      expect(find.text('Export Biometrics CSV'), findsOneWidget);
      expect(find.text('Last 30 Days'), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNotNull);
      await tester.tap(find.text('All Time'));
      await tester.pumpAndSettle();
      final sw = tester.widget<Switch>(find.byType(Switch));
      expect(sw.value, isFalse);
      expect(sw.onChanged, isNull);
      expect(
        find.text('you can not toggle it on when you are on all time'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // Export (30 days, spikes on) hands a real CSV to the bridge.
      await tester.tap(find.byIcon(Icons.download));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export'));
      await tester.pumpAndSettle();
      expect(hc.exportedFileName, 'jot_metrics_30d.csv');
      expect(hc.exportedContent, contains('Date,Average HR (BPM)'));
      expect(hc.exportedContent, contains('7h30m'));
    });
  });

  // ── Food ──────────────────────────────────────────────────────────

  group('food level normalization + encyclopedia persistence', () {
    test('normalizeFoodLevel canonicalizes case and junk', () {
      expect(normalizeFoodLevel('high'), 'High');
      expect(normalizeFoodLevel('HIGH'), 'High');
      expect(normalizeFoodLevel(' Medium '), 'Medium');
      expect(normalizeFoodLevel('Low'), 'Low');
      expect(normalizeFoodLevel('banana'),
          'banana'); // unknown non-empty passes through (Juno F4 fix)
      expect(normalizeFoodLevel(null), 'Low');
    });

    test('parseFoodAiResponse normalizes lowercase AI levels', () {
      final out = parseFoodAiResponse(
          '{"spinach": {"Histamine": {"level": "high", "reasoning": "x"}}}');
      expect(out.single.levels[0].level, 'High');
      expect(out.single.levels[1].level, 'Low'); // missing → default
    });

    test('encyclopedia encode/decode round-trips the native shape', () {
      final result = FoodCheckResult(foodName: 'spinach', levels: [
        for (final t in foodCoreTopics)
          FoodTopicLevel(topicName: t, level: 'High', reasoning: 'r-$t'),
      ]);
      final json = encodeFoodEncyclopedia({'spinach': result});
      final decoded = decodeFoodEncyclopedia(json);
      expect(decoded.keys, ['spinach']);
      expect(decoded['spinach']!.levels, hasLength(5));
      expect(decoded['spinach']!.levels[0].reasoning, 'r-Histamine');
      expect(decodeFoodEncyclopedia('not json'), isEmpty);
      expect(decodeFoodEncyclopedia('{}'), isEmpty);
      expect(decodeFoodEncyclopedia(null), isEmpty);
    });
  });

  group('FoodToolScreen (round 48)', () {
    testWidgets('checked foods persist and serve the next session from cache',
        (tester) async {
      // VC 100110 combine fix: since the onboarding-no-seeds
      // branch, FoodToolScreen enforces history ownership against
      // SessionStore().readEmail() (a real secure-storage channel
      // read) BEFORE loading the encyclopedia. Unmocked, that
      // channel never answers in the test binding and the load
      // never runs. Mock an EMPTY secure store (no session email:
      // enforcement is the signed no-op for a null email, and the
      // load proceeds) — the onboarding_no_seeds_test idiom.
      const secureChannel =
          MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureChannel, (call) async => null);
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(secureChannel, null);
      });
      final store = _MemFoodStore();
      _bigSurface(tester);
      final result = {
        'spinach': {
          'Histamine': {'level': 'High', 'reasoning': 'Rich in histamine.'},
          'Sugar': {'level': 'Low', 'reasoning': 'Low sugar.'},
          'FODMAP': {'level': 'Low', 'reasoning': 'Low FODMAP.'},
          'Inflammation': {'level': 'Low', 'reasoning': 'Anti-inflammatory.'},
          'Oxalate': {'level': 'High', 'reasoning': 'High oxalate.'},
        },
      };
      final liveWithAi = TabsBackend(
        client: MockClient((request) async {
          if (request.url.path == '/api/ai/advice') {
            return http.Response(
                jsonEncode({'result': jsonEncode(result)}), 200);
          }
          return http.Response(jsonEncode({'profile': {}}), 200);
        }),
        sessionStore: FakeSessionStore()..token = 'tok',
      );
      await _pump(
          tester,
          FoodToolScreen(backend: liveWithAi, historyStore: store));
      await tester.enterText(find.byType(TextField), 'spinach');
      await tester.pump();
      await tester.tap(find.text('Check Sensitivity'));
      await tester.pumpAndSettle();
      expect(find.text('Spinach'), findsWidgets);
      expect(find.text('Rich in histamine.'), findsOneWidget);
      // The check was persisted in the native shape.
      expect(store.value, isNotNull);
      expect(store.value, contains('"spinach"'));
      expect(store.value, contains('"levels"'));

      // A brand-new screen (next session) with a DEAD backend shows
      // the persisted recent chip and answers the tap from cache.
      final deadBackend = TabsBackend(
        client: MockClient((_) async => http.Response('boom', 500)),
        sessionStore: FakeSessionStore()..token = 'tok',
      );
      // UniqueKey: pumpWidget with the same widget type would REUSE
      // the first session's State (its result card would survive, and
      // "Spinach" would match both the card and the recent chip). A
      // real next session starts from fresh State served by the cache.
      await _pump(
          tester,
          FoodToolScreen(
              key: UniqueKey(), backend: deadBackend, historyStore: store));
      expect(find.text('Recently Checked'), findsOneWidget);
      await tester.tap(find.text('Spinach'));
      await tester.pumpAndSettle();
      expect(find.text('Results'), findsOneWidget);
      expect(find.text('Rich in histamine.'), findsOneWidget);
    });
  });
}

class _MemFoodStore implements FoodHistoryStore {
  String? value;

  @override
  Future<String?> loadEncyclopediaJson() async => value;

  @override
  Future<void> saveEncyclopediaJson(String json) async {
    value = json;
  }

  // VC 100110 combine fix: the interface gained this method on
  // the onboarding-no-seeds branch (with a default in the abstract
  // class, which `implements` does not inherit). The fake takes
  // the documented default: no owner enforcement in memory.
  @override
  Future<bool> clearIfOwnerMismatch(String? email) async => false;
}

/// Connected fake Health Connect for Key Metrics: every read the
/// screen can make is overridden (unmocked channels hang in tests).
class _MetricsHc extends HealthConnectService {
  String? exportedFileName;
  String? exportedContent;

  String get _today => _key(DateTime.now());

  @override
  Future<bool> isConnected() async => true;

  @override
  Future<List<HrSample>> readHeartRateSamples(String dateStr) async {
    final now = DateTime.now();
    HrSample at(int hour, int bpm) => HrSample(
          timeMs: DateTime(now.year, now.month, now.day, hour)
              .millisecondsSinceEpoch,
          bpm: bpm,
        );
    return [at(8, 70), at(20, 90), at(2, 200)]; // night sample excluded
  }

  @override
  Future<int?> readRestingHeartRate(String dateStr) async => 58;

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
          int days) async =>
      [(date: _today, bpm: 58)];

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(
          int days) async =>
      [(date: _today, kcal: 500)];

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
          int days) async =>
      [(date: _today, mins: 450, deep: 120)];

  @override
  Future<List<({String date, int count})>> readSpikeCounts(int days) async =>
      [(date: _today, count: 2)];

  @override
  Future<double?> readLatestWeightKg() async => 71.0;

  @override
  Future<double?> readRespiratoryRate(String dateStr) async => 14.5;

  @override
  Future<double?> readOxygenSaturation(String dateStr) async => 98.0;

  @override
  Future<double?> readHrvRmssd(String dateStr) async => 42.4;

  @override
  Future<bool> exportCsvFile({
    required String fileName,
    required String content,
  }) async {
    exportedFileName = fileName;
    exportedContent = content;
    return true;
  }
}
