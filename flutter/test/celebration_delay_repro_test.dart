// CELEBRATION DELAY (Nov 23, 2026) — fail-first harness for the
// streak-celebration latency fix. Founder report: after finishing
// the last habit in the Today Summary sheet the celebration was
// "really delayed". Coordinator trace (stage log) proved two
// gates upstream of the (instant) presenter:
//
//  (A) TRIGGER: the Today Summary surface's plan writes (habit /
//      reminder toggles, med actions) queue NO Home completion
//      evaluation — Home's triggers are only the outbox listener,
//      Home load settle, and app resume, and the card's writes
//      bypass the outbox. The last completing tap waits for an
//      incidental trigger.
//  (D) NETWORK GATE: Home._presentCompletion awaited the streak
//      push POST and then GemService.processCompletion (sequential
//      grant POSTs) before building the celebration data and
//      calling hold() — presentation waited on 1 + up-to-3+
//      sequential network round trips.
//
// These tests complete the day FROM the Today Summary sheet (one
// habit outstanding, today's check-in already logged) with the
// streak PUSH gated on a completer, and assert:
//  (a) the toggle itself fires the completion evaluation (the
//      store counts today without any other trigger), and
//  (b) the celebration is PRESENTED while the push gate is still
//      closed.
// On the base head both fail. The gem-grant gate + projected-line
// assertions live in the companion test added with the fix (they
// need the fix's GemService test seam).

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
      int days) async {
    return const [];
  }

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
      int days) async =>
      const [];
}

MockClient _mockWeather() => MockClient((request) async {
      if (request.url.host == 'ipinfo.io') {
        return http.Response(
            '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}', 200);
      }
      return http.Response(
          '{"current":{"temperature_2m":61.0,"weather_code":2,"is_day":1}}',
          200);
    });

/// Stateful fake server: today's check-in exists and exactly ONE
/// habit ("Stretch") is outstanding, so the day is incomplete
/// until that habit's Round 41 completion entry lands. Posted
/// entries are reflected in later pulls, exactly like the real
/// server. Profile counters 29/29 seed the run the completion
/// extends to 30 (a milestone, like the founder's).
class _DelayServer {
  final List<Map<String, dynamic>> serverEntries = [];
  int habitLogCalls = 0;

  _DelayServer() {
    final now = DateTime.now();
    final checkInTs =
        DateTime(now.year, now.month, now.day, 0, 30).millisecondsSinceEpoch;
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
            .map((e) => {
                  'id': '${e['id']}',
                  'categoryId': '${e['categoryId']}',
                  'body': e['body'],
                  'chips': e['chips'],
                  'manualText': e['manualText'],
                  'timestamp': '${e['timestamp']}',
                  'updatedAt': '${e['timestamp']}',
                })
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
      habitLogCalls++;
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

/// A HealthRepository whose streak-record PUSH parks while the
/// gate is closed — every push Home makes (the watcher's own and
/// _presentCompletion's explicit pre-grant push alike).
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
        int? purchasedFreezes
      })> loadStreakRecord() async {
    return (
      succeeded: true,
      current: 29,
      best: 29,
      stateJson: null,
      purchasedFreezes: null,
    );
  }

  @override
  Future<bool> pushStreakRecord(int current, int best, String stateJson,
      {int? purchasedFreezes}) async {
    pushCalls++;
    final gate = _gate;
    if (gate != null) await gate.future;
    return true;
  }
}

Future<void> _pumpReal(WidgetTester tester, {int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  group('celebration delay — Today Summary toggle path', () {
    late Map<String, String> streakDisk;
    late _GatedRepo repo;
    late _DelayServer server;
    late String todayStr;
    late GlobalKey<NavigatorState> navKey;

    setUp(() {
      navKey = GlobalKey<NavigatorState>();
      server = _DelayServer();
      StreakCelebrationService.instance.debugReset();
      TabsDayBoundary.instance.debugCutoverAt = DateTime(2026, 11, 1);
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
      streakDisk = <String, String>{};
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

    Future<void> pumpHome(WidgetTester tester) async {
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
    }

    testWidgets(
        'completing the last habit IN the Today Summary sheet fires '
        'the evaluation from the toggle itself and presents the '
        'celebration while the streak push is still gated',
        (tester) async {
      await pumpHome(tester);

      // Precondition: the day is NOT complete (one habit
      // outstanding) — no incidental trigger may have fired it.
      final before = StreakStore.instance.state;
      expect(before?.countedDays.contains(todayStr) ?? false, isFalse,
          reason: 'precondition: today not counted before the toggle');
      expect(find.byType(StreakCelebrationScreen), findsNothing);

      // Open the Today Summary sheet and find the habit row.
      await tester.tap(find.byType(TodaySummaryCard));
      await _pumpReal(tester, rounds: 4);
      expect(find.text("Today's Plan"), findsOneWidget,
          reason: 'the Today Summary sheet is open');
      expect(find.text('Stretch'), findsOneWidget,
          reason: 'the outstanding habit row renders in the sheet');

      // Tap the habit's toggle — the LAST completing action.
      final sw = Stopwatch()..start();
      await tester.tap(find.byTooltip('Mark complete'));
      // Poll for the celebration with fine steps so the latency
      // measurement means something.
      var presentedMs = -1;
      for (var i = 0; i < 200; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
        if (find.byType(StreakCelebrationScreen).evaluate().isNotEmpty) {
          presentedMs = sw.elapsedMilliseconds;
          break;
        }
      }
      sw.stop();
      // ignore: avoid_print
      print('DELAY[toggle->presented] pushGateClosed=${repo.gateClosed} '
          'presentedMs=$presentedMs '
          'storeCounted=${StreakStore.instance.state?.countedDays.contains(todayStr)} '
          'gemPending=${GemService.instance.debugPending}');

      // (a) The toggle itself fired the evaluation: the day
      // counted with NO other trigger (no resume, no outbox
      // commit, no reload) in between.
      expect(StreakStore.instance.state?.countedDays.contains(todayStr),
          isTrue,
          reason: '(a) the Today Summary toggle queued/fired a Home '
              'completion evaluation');
      // (b) The celebration is presented while the streak push
      // gate is STILL closed — presentation no longer waits on
      // the network chain.
      expect(repo.gateClosed, isTrue,
          reason: 'the push gate was never opened in this test');
      expect(find.byType(StreakCelebrationScreen), findsOneWidget,
          reason: '(b) celebration presented while the push gate '
              'remains closed');
      expect(presentedMs, greaterThanOrEqualTo(0),
          reason: 'tap->presented latency was measured');

      // Cleanup: open the gate so the background chain drains
      // before teardown.
      repo.openGate();
      await _pumpReal(tester);
    });
  });
}
