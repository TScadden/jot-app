// CELEBRATION DELAY (Nov 23, 2026) — companion suite to
// celebration_delay_repro_test.dart: the NETWORK-GATE half of the
// fix, plus the local gem-line projection contract.
//
// Home level: BOTH network gates closed — the streak push parked
// on a completer (repository seam) and the gem grant transport
// parked on a completer (GemService.debugSetGrantOverride). The
// day is completed from the Today Summary sheet; the celebration
// must present, WITH its projected gem lines, while neither gate
// has opened and no grant has even been attempted. Opening the
// gates afterwards must land the claim exactly once per key, in
// the original order (push before grants), and adopt the server
// balance.
//
// Service level: projectedCompletionLines must equal
// processCompletion's lines whenever every grant confirms FRESH
// (the parity contract the shared _completionKeys computation
// exists to keep), project NO lines for a grace-completed day,
// and project no line for a key already in the local granted
// set. One test pins the documented §3a divergence verbatim: a
// wiped local history + a server alreadyGranted replay earns NO
// line from processCompletion but DOES project one — the single
// case flagged for Vera/Juno ruling in the stage log.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/streak_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/tabs_day.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/home/streak_celebration_presenter.dart';
import 'package:tabs_lab/src/features/home/streak_celebration_screen.dart';
import 'package:tabs_lab/src/features/home/today_summary_card.dart';

import 'test_helpers.dart';

class _FakeHc extends HealthConnectService {
  @override
  Future<HcAvailability> probeAvailability() async => const HcAvailability(
    serviceAvailable: true,
    grantedPermissions: HealthConnectService.requiredPermissions,
    bridgeErrorCode: null,
    stepsProbe: HcReadProbeOutcome.ok,
    persistedConnected: true,
  );

  @override
  Future<List<HrSample>> readHeartRateSamples(String dateStr) async {
    final now = DateTime.now();
    final noon = DateTime(now.year, now.month, now.day, 12);
    return [HrSample(timeMs: noon.millisecondsSinceEpoch, bpm: 74)];
  }

  @override
  Future<int?> readActiveCalories(String dateStr) async => 159;

  @override
  Future<int?> readSleepMinutes(String dateStr) async => 510;

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
    int days,
  ) async {
    return const [];
  }

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(int days) async =>
      const [];
}

/// Same fixture as celebration_delay_repro_test.dart: check-in
/// done, ONE habit ("Stretch") outstanding, profile 29/29.
class _DelayServer {
  final List<Map<String, dynamic>> serverEntries = [];

  _DelayServer() {
    final now = DateTime.now();
    final checkInTs = DateTime(
      now.year,
      now.month,
      now.day,
      0,
      30,
    ).millisecondsSinceEpoch;
    serverEntries.add({
      'id': 200,
      'categoryId': 6,
      'body': 'Feeling: 2/5 Today',
      'chips': '["Daily Ranking"]',
      'manualText': '',
      'timestamp': checkInTs,
    });
  }

  http.Client get client => MockClient(_handle);

  Map<String, dynamic> _pullBody() => {
    'entries': serverEntries
        .map(
          (e) => {
            'id': '${e['id']}',
            'categoryId': '${e['categoryId']}',
            'body': e['body'],
            'chips': e['chips'],
            'manualText': e['manualText'],
            'timestamp': '${e['timestamp']}',
            'updatedAt': '${e['timestamp']}',
          },
        )
        .toList(),
    'categories': [
      {'id': 1, 'name': 'Symptoms'},
      {'id': 4, 'name': 'Goals & Habits'},
      {'id': 6, 'name': 'Mood & Energy'},
      {'id': 8, 'name': 'Medication'},
    ],
    'profile': {
      'currentStreak': 29,
      'bestStreak': 29,
      'medications': <dynamic>[],
      'reminders': <dynamic>[],
    },
    'isUnlimited': true,
    'isAdmin': false,
  };

  Future<http.Response> _handle(http.Request request) async {
    if (request.url.path == '/api/sync/pull') {
      return http.Response(jsonEncode(_pullBody()), 200);
    }
    if (request.url.path == '/api/habits/log') {
      return http.Response('{"success":true}', 200);
    }
    if (request.url.path == '/api/habits') {
      return http.Response(
        jsonEncode({
          'habits': [
            {
              'id': 'h1',
              'title': 'Stretch',
              'target_time': 'Anytime',
              'logs': <String>[],
            },
          ],
        }),
        200,
      );
    }
    if (request.url.path == '/api/sync/entries') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      for (final e in (body['entries'] as List)) {
        final row = (e as Map).cast<String, dynamic>();
        serverEntries.removeWhere((s) => s['id'] == row['id']);
        serverEntries.add(row);
      }
      return http.Response('{"success":true}', 200);
    }
    return http.Response('not found', 404);
  }
}

class _GatedRepo extends HealthRepository {
  _GatedRepo({required super.hc, required super.backend});

  Completer<void>? _gate;
  int pushCalls = 0;

  void closeGate() => _gate = Completer<void>();

  void openGate() {
    final gate = _gate;
    _gate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  bool get gateClosed => _gate != null && !_gate!.isCompleted;

  @override
  Future<
    ({
      bool succeeded,
      int? current,
      int? best,
      String? stateJson,
      int? purchasedFreezes,
    })
  >
  loadStreakRecord() async {
    return (
      succeeded: true,
      current: 29,
      best: 29,
      stateJson: null,
      purchasedFreezes: null,
    );
  }

  @override
  Future<bool> pushStreakRecord(
    int current,
    int best,
    String stateJson, {
    int? purchasedFreezes,
  }) async {
    pushCalls++;
    final gate = _gate;
    if (gate != null) await gate.future;
    return true;
  }
}

/// The gated grant transport: every request parks on [gate]
/// until the test opens it, then confirms FRESH with the
/// server-derived amount and a running balance (start 160, the
/// founder's pre-completion balance in the incident shape).
class _GatedGrants {
  final Completer<void> gate = Completer<void>();
  final List<String> calls = [];
  int balance = 160;

  static int amountFor(String key) {
    if (key.startsWith('daily:')) return 5;
    if (key.startsWith('week:')) return 20;
    if (key.startsWith('milestone:')) {
      return gemMilestoneBonus(int.parse(key.split(':')[1])) ?? 0;
    }
    return 0;
  }

  Future<GemRequestResult> grant(String key) async {
    calls.add(key);
    await gate.future;
    balance += amountFor(key);
    return (
      statusCode: 200,
      body: {'gemBalance': balance, 'alreadyGranted': false},
    );
  }
}

Future<void> _pumpReal(WidgetTester tester, {int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  group('celebration delay — both network gates closed (Home level)', () {
    late _GatedRepo repo;
    late _DelayServer server;
    late _GatedGrants grants;
    late String todayStr;
    late GlobalKey<NavigatorState> navKey;

    setUp(() {
      navKey = GlobalKey<NavigatorState>();
      server = _DelayServer();
      grants = _GatedGrants();
      StreakCelebrationService.instance.debugReset();
      TabsDayBoundary.instance.debugCutoverAt = DateTime(2026, 11, 1);
      TabsBackend.debugResetSharedCaches();
      final secureStore = <String, String>{
        // Badges: mark the real today already evaluated so Home's
        // app-open badge sync takes its retry-only path —
        // otherwise the first-evaluation BadgeUnlockDialog opens
        // over the card mid-test and eats the sheet tap (the
        // 100162 harness never saw it: its control test consumed
        // the one-time dialog in an earlier test of that file).
        'badges_v1': jsonEncode({
          'lastEvaluatedDay': tabsDayStr(DateTime.now()),
          'evaluatedOnce': true,
        }),
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async {
              final args = call.arguments is Map
                  ? (call.arguments as Map).cast<String, dynamic>()
                  : const <String, dynamic>{};
              switch (call.method) {
                case 'read':
                  return secureStore[args['key']];
                case 'readAll':
                  return Map<String, String>.of(secureStore);
                case 'write':
                  secureStore[args['key'] as String] =
                      args['value'] as String;
                  return null;
                case 'delete':
                  secureStore.remove(args['key']);
                  return null;
                case 'deleteAll':
                  secureStore.clear();
                  return null;
                case 'containsKey':
                  return secureStore.containsKey(args['key']);
              }
              return null;
            },
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
      final streakDisk = <String, String>{};
      StreakStore.instance.debugReset();
      StreakStore.instance.debugSetStore(
        read: (k) async => streakDisk[k],
        write: (k, v) async {
          streakDisk[k] = v;
        },
        delete: (k) async {
          streakDisk.remove(k);
        },
      );
      final gemDisk = <String, String>{};
      GemService.instance.debugReset();
      GemService.instance.debugSetStore(
        read: (k) async => gemDisk[k],
        write: (k, v) async {
          gemDisk[k] = v;
        },
        delete: (k) async {
          gemDisk.remove(k);
        },
      );
      // The grant gate is installed AFTER debugReset (which
      // clears it by design).
      GemService.instance.debugSetGrantOverride(grants.grant);
      final now = DateTime.now();
      todayStr =
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    });

    tearDown(() {
      TabsDayBoundary.instance.debugCutoverAt = null;
      StreakStore.instance.debugReset();
      GemService.instance.debugReset();
      StreakCelebrationService.instance.debugReset();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            null,
          );
    });

    testWidgets('celebration presents WITH projected gem lines while the '
        'push AND grant gates stay closed; the claim then lands '
        'exactly once per key when the gates open', (tester) async {
      final backend = TabsBackend(
        client: server.client,
        sessionStore: FakeSessionStore()
          ..token = 'tok'
          ..email = 'tysonscadden@gmail.com',
      );
      repo = _GatedRepo(hc: _FakeHc(), backend: backend);
      repo.closeGate();
      final scoreStore = HealthHistoryStore.testInstance();
      final disk = <String, String>{};
      scoreStore.debugSetStore(
        read: (k) async => disk[k],
        write: (k, v) async {
          disk[k] = v;
        },
        delete: (k) async {
          disk.remove(k);
        },
      );
      scoreStore.debugReset();
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navKey,
          builder: (context, child) => StreakCelebrationPresenter(
            navigatorKey: navKey,
            child: child ?? const SizedBox.shrink(),
          ),
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: HomeScreen(
              weatherApi: WeatherApiClient(client: _mockWeather()),
              tabsBackend: backend,
              logEntryOutbox: LogEntryOutbox.instance,
              healthConnectService: _FakeHc(),
              healthRepository: repo,
              healthHistoryStore: scoreStore,
              dailyScoreSnapshotCapture: ({bool force = false}) async => true,
            ),
          ),
        ),
      );
      await _pumpReal(tester);
      expect(
        StreakStore.instance.state?.countedDays.contains(todayStr),
        isNot(isTrue),
        reason: 'precondition: today not counted before the toggle',
      );

      // Pump well past the staggered entrance before tapping
      // (see celebration_delay_repro_test.dart: a mid-entrance
      // tap at the card's layout center misses the painted card).
      await _pumpReal(tester, rounds: 24);
      await tester.ensureVisible(find.byType(TodaySummaryCard));
      await tester.pump();
      await tester.tap(find.byType(TodaySummaryCard));
      await _pumpReal(tester, rounds: 6);
      expect(find.text('Stretch'), findsOneWidget);

      final sw = Stopwatch()..start();
      await tester.tap(find.byTooltip('Mark complete'));
      var presentedMs = -1;
      for (var i = 0; i < 200; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump();
        if (find.byType(StreakCelebrationScreen).evaluate().isNotEmpty) {
          presentedMs = sw.elapsedMilliseconds;
          break;
        }
      }
      sw.stop();
      // ignore: avoid_print
      print(
        'DELAY-GATES[toggle->presented] presentedMs=$presentedMs '
        'pushGateClosed=${repo.gateClosed} grantCalls=${grants.calls}',
      );

      // BOTH gates still closed, no grant even attempted — yet
      // the celebration is up, carrying the projected lines.
      expect(repo.gateClosed, isTrue);
      expect(
        grants.calls,
        isEmpty,
        reason:
            'the claim chain is parked on the push gate; '
            'presentation never waited for it',
      );
      expect(
        find.byType(StreakCelebrationScreen),
        findsOneWidget,
        reason: 'celebration presented with both gates closed',
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('celebrationGemLine0'))).data,
        '+5 gems',
        reason: 'projected daily line on the celebration',
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('celebrationGemLine1'))).data,
        '+50 gems — 30-day streak bonus',
        reason: 'projected milestone line on the celebration',
      );

      // Open the push gate: the chain advances to the grants and
      // parks on the grant gate (sequential flush — first key
      // only). The celebration is unaffected.
      repo.openGate();
      await _pumpReal(tester);
      expect(
        grants.calls,
        ['daily:$todayStr'],
        reason:
            'push landed first, then the claim started and '
            'parked on the grant gate',
      );
      expect(find.byType(StreakCelebrationScreen), findsOneWidget);

      // Open the grant gate: the claim lands exactly once per
      // key, the queue drains, and the server balance is adopted.
      grants.gate.complete();
      await _pumpReal(tester);
      expect(grants.calls, [
        'daily:$todayStr',
        'milestone:30',
      ], reason: 'each key requested exactly once, in order');
      expect(GemService.instance.debugPending, isEmpty);
      expect(
        GemService.instance.debugGranted,
        containsAll(['daily:$todayStr', 'milestone:30']),
      );
      expect(
        GemService.instance.balance,
        215,
        reason: '160 + 5 daily + 50 milestone, server-adopted',
      );
    });
  });

  group('presenter hold while backgrounded', () {
    setUp(() {
      StreakCelebrationService.instance.debugReset();
    });

    tearDown(() {
      StreakCelebrationService.instance.debugReset();
    });

    testWidgets(
        'a celebration held while the app is paused is NOT '
        'presented until the next foreground (exactly once)',
        (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final navKey = GlobalKey<NavigatorState>();
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navKey,
          builder: (context, child) => StreakCelebrationPresenter(
            navigatorKey: navKey,
            child: child ?? const SizedBox.shrink(),
          ),
          home: const MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: Scaffold(body: Text('HOST')),
          ),
        ),
      );
      await tester.pump();
      StreakCelebrationService.instance.hold(
        const PendingStreakCelebration(
          data: StreakCelebrationData(
            count: 30,
            previousCount: 29,
            week: [],
            isMilestoneDay: true,
          ),
          dayKey: '2026-11-19',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(StreakCelebrationScreen), findsNothing,
          reason: 'held while the app is not resumed');
      expect(StreakCelebrationService.instance.pending, isNotNull,
          reason: 'the celebration is held, not dropped');
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(StreakCelebrationScreen), findsOneWidget,
          reason: 'presented on the next foreground');
      expect(StreakCelebrationService.instance.pending, isNull);
    });
  });

  group('GemService.projectedCompletionLines', () {
    late Map<String, String> disk;
    late List<String> grantCalls;
    late int serverBalance;

    GemService buildService({bool alreadyGranted = false}) {
      final s = GemService(
        grant: (key) async {
          grantCalls.add(key);
          serverBalance += _GatedGrants.amountFor(key);
          return (
            statusCode: 200,
            body: {
              'gemBalance': serverBalance,
              'alreadyGranted': alreadyGranted,
            },
          );
        },
        spend: (id) async => (statusCode: null, body: null),
        pullBalance: () async => serverBalance,
      );
      s.debugSetStore(
        read: (k) async => disk[k],
        write: (k, v) async => disk[k] = v,
        delete: (k) async => disk.remove(k),
      );
      return s;
    }

    StreakState stateWith({
      Set<String> counted = const {},
      Set<String> completed = const {},
      Set<String> grace = const {},
    }) => StreakState(
      seeded: true,
      countedDays: counted,
      summaryCompletedDays: completed,
      graceCompletedDays: grace,
    );

    setUp(() {
      disk = {};
      grantCalls = [];
      serverBalance = 160;
    });

    test('parity: projection == confirmed lines when every grant '
        'confirms fresh (29 -> 30 milestone crossing)', () async {
      final state = stateWith(
        counted: {'2026-11-19'},
        completed: {'2026-11-19'},
      );
      final projector = buildService();
      final projected = await projector.projectedCompletionLines(
        summaryTabsDay: '2026-11-19',
        previousStreak: 29,
        newStreak: 30,
        settledState: state,
      );
      expect(projected, ['+5 gems', '+50 gems — 30-day streak bonus']);
      expect(
        grantCalls,
        isEmpty,
        reason: 'projection performs no grant requests',
      );

      // The production sequence on the SAME service: project,
      // then claim — identical lines, each key requested once.
      final claimed = await projector.processCompletion(
        summaryTabsDay: '2026-11-19',
        previousStreak: 29,
        newStreak: 30,
        settledState: state,
        now: DateTime(2026, 11, 19, 12),
      );
      expect(claimed.lines, projected);
      expect(grantCalls, ['daily:2026-11-19', 'milestone:30']);
    });

    test('grace-completed day projects NO lines (and claims none)', () async {
      final state = stateWith(
        counted: {'2026-11-19'},
        completed: {'2026-11-19'},
        grace: {'2026-11-19'},
      );
      final s = buildService();
      final projected = await s.projectedCompletionLines(
        summaryTabsDay: '2026-11-19',
        previousStreak: 29,
        newStreak: 30,
        settledState: state,
      );
      expect(
        projected,
        isEmpty,
        reason:
            'grace days project no lines, keyed on '
            'graceCompletedDays exactly as processCompletion',
      );
      final claimed = await s.processCompletion(
        summaryTabsDay: '2026-11-19',
        previousStreak: 29,
        newStreak: 30,
        settledState: state,
        now: DateTime(2026, 11, 19, 12),
      );
      expect(claimed.lines, isEmpty);
      expect(grantCalls, isEmpty);
    });

    test('a key already in the local granted set projects no line', () async {
      final state = stateWith(
        counted: {'2026-11-19'},
        completed: {'2026-11-19'},
      );
      final s = buildService();
      final first = await s.processCompletion(
        summaryTabsDay: '2026-11-19',
        previousStreak: 29,
        newStreak: 30,
        settledState: state,
        now: DateTime(2026, 11, 19, 12),
      );
      expect(first.lines, isNotEmpty);
      final projected = await s.projectedCompletionLines(
        summaryTabsDay: '2026-11-19',
        previousStreak: 29,
        newStreak: 30,
        settledState: state,
      );
      expect(
        projected,
        isEmpty,
        reason:
            'locally-granted keys can never earn a fresh '
            'line in the confirmed flow either',
      );
    });

    test('perfect week projects daily + milestone + week lines in '
        'Juno order', () async {
      const week = [
        '2026-11-02',
        '2026-11-03',
        '2026-11-04',
        '2026-11-05',
        '2026-11-06',
        '2026-11-07',
        '2026-11-08',
      ];
      final state = stateWith(counted: week.toSet(), completed: week.toSet());
      final s = buildService();
      final projected = await s.projectedCompletionLines(
        summaryTabsDay: '2026-11-08',
        previousStreak: 6,
        newStreak: 7,
        settledState: state,
      );
      expect(projected, [
        '+5 gems',
        '+25 gems — 7-day streak bonus',
        '+20 gems — perfect week bonus',
      ]);
      final claimed = await s.processCompletion(
        summaryTabsDay: '2026-11-08',
        previousStreak: 6,
        newStreak: 7,
        settledState: state,
        now: DateTime(2026, 11, 8, 12),
      );
      expect(claimed.lines, projected);
    });

    test('§3a DIVERGENCE (documented, flagged for Vera/Juno): '
        'wiped local history + server alreadyGranted replay — '
        'processCompletion earns NO line, the projection shows one', () async {
      final state = stateWith(
        counted: {'2026-11-19'},
        completed: {'2026-11-19'},
      );
      // The server granted this day in a prior flush (balance
      // already includes it), but this device's local history is
      // gone, so the completion re-requests and the server
      // answers alreadyGranted.
      serverBalance = 165;
      final s = buildService(alreadyGranted: true);
      final projected = await s.projectedCompletionLines(
        summaryTabsDay: '2026-11-19',
        previousStreak: 29,
        newStreak: 30,
        settledState: state,
      );
      final claimed = await s.processCompletion(
        summaryTabsDay: '2026-11-19',
        previousStreak: 29,
        newStreak: 30,
        settledState: state,
        now: DateTime(2026, 11, 19, 12),
      );
      expect(
        claimed.lines,
        isEmpty,
        reason: 'Juno §3a: an alreadyGranted replay earns no line',
      );
      expect(
        projected,
        ['+5 gems', '+50 gems — 30-day streak bonus'],
        reason:
            'THE DIVERGENCE: the projection cannot know the '
            'grants were already made — it shows the lines. This '
            'is the single case documented in gem_service.dart '
            'and the stage log for Vera/Juno ruling. The claim '
            'itself still retires the keys and never double-pays.',
      );
      expect(s.debugGranted, containsAll(['daily:2026-11-19', 'milestone:30']));
    });
  });
}

MockClient _mockWeather() => MockClient((request) async {
  if (request.url.host == 'ipinfo.io') {
    return http.Response(
      '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
      200,
    );
  }
  return http.Response(
    '{"current":{"temperature_2m":61.0,"weather_code":2,"is_day":1}}',
    200,
  );
});
