// REPRO (celebration-present package, Nov 21, 2026) — founder
// report: completing the final Daily Summary item with the Today
// Summary sheet open counted the day (streak 29 -> 30, +5 daily
// and +50 milestone:30 grants landed server-side) but the streak
// celebration NEVER presented, and Home's streak pill showed the
// new count with the flame GRAY/unlit until a streak-screen visit
// refreshed it.
//
// These tests drive the REAL HomeScreen: a mock backend whose
// attested plan is empty and whose check-in for today exists, so
// Home's own load evaluation fires the completion watcher. The
// streak-record PUSH is gated on a completer, which parks
// Home._presentCompletion between the watcher fire (streak
// counted) and its presentation tail (explicit push -> gem claim
// -> pill setState -> celebration show) while the test arranges
// the surface state the founder was in. Releasing the gate then
// records, per surface: (a) celebration presented? (b) gem claim
// queued/granted? (GemService.debugPending / balance) (c) streak
// counted? (d) pill flame lit immediately?
//
// Desired behavior (founder direction, Nov 21, 2026): the
// celebration pops up RIGHT AWAY on completion, over whatever
// surface is up; the pill lights immediately; the claim is never
// eaten by a presentation drop.
//
// Celebration-delay adaptation (Nov 23, 2026): the latency fix
// moved the celebration hold BEFORE the streak push, so the
// gated push no longer parks the presentation — it parks only
// the claim chain behind an already-held celebration. This
// harness's original "celebration absent while parked" premise
// WAS the delay defect, so pumpHomeParked no longer asserts it;
// the surface tests below keep their outcome assertions
// (celebration present, claim queued, streak counted, pill lit)
// under the new timing, (e)/(g) are re-shaped to the guarantees
// that survive the timing change (exactly-once across
// backgrounding and remount; pill settles lit on remount), and
// the fire-while-the-sheet-is-open ordering is covered by
// celebration_delay_repro_test.dart, which completes the day
// from the sheet itself.

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
import 'package:tabs_lab/src/features/home/checkin_sheets.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/home/streak_celebration_presenter.dart';
import 'package:tabs_lab/src/features/home/streak_celebration_screen.dart';
import 'package:tabs_lab/src/features/home/today_summary_card.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart';

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

/// The completion fixture: attested EMPTY plan (medications /
/// reminders present and empty, habits endpoint answers []) plus
/// today's feeling check-in — the day is complete the moment an
/// evaluation resolves. Profile counters 29/29 seed the run the
/// completion extends to 30 (a milestone, like the founder's).
MockClient _mockCompleteBackend() {
  final now = DateTime.now();
  final checkInTs =
      DateTime(now.year, now.month, now.day, 0, 30).millisecondsSinceEpoch;
  final entries = <Map<String, dynamic>>[
    {
      'id': 200,
      'categoryId': 6,
      'body': 'Feeling: 2/5 Today',
      'chips': '["Daily Ranking"]',
      'manualText': '',
      'timestamp': checkInTs,
    },
  ];
  return MockClient((request) async {
    if (request.url.path == '/api/sync/pull') {
      return http.Response(
        jsonEncode({
          'entries': entries,
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
        }),
        200,
      );
    }
    if (request.url.path == '/api/habits') {
      return http.Response('{"habits":[]}', 200);
    }
    if (request.url.path == '/api/sync/entries') {
      return http.Response('{}', 200);
    }
    return http.Response('not found', 404);
  });
}

/// A HealthRepository whose streak-record PUSH parks while the
/// gate is closed — the park point inside
/// Home._presentCompletion (its explicit pre-grant push), which
/// is after the watcher has counted the day and before the gem
/// claim + presentation tail.
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
  group('celebration presentation repro (Home level)', () {
    late Map<String, String> streakDisk;
    late _GatedRepo repo;
    late String todayStr;
    late GlobalKey<NavigatorState> navKey;

    setUp(() {
      navKey = GlobalKey<NavigatorState>();
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

    /// Pump Home with the push gate closed; wait until the
    /// completion has fired (the store counts today). Since the
    /// celebration-delay fix the gate parks only the claim chain
    /// (the explicit push inside it) — the celebration itself is
    /// held and presented from local state before that push, so
    /// by the time the store counts, the celebration is normally
    /// already on screen.
    Future<void> pumpHomeParked(WidgetTester tester,
        {Key key = const ValueKey('repro-home')}) async {
      final backend = TabsBackend(
        client: _mockCompleteBackend(),
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
      // Phone-class surface (the default 800x600 test surface
      // overflows the celebration's fixed column — a harness
      // artifact, not the defect).
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          // The production app shape (main.dart): the root
          // celebration presenter wraps the Navigator, which is
          // keyed by the shared presentation key.
          navigatorKey: navKey,
          builder: (context, child) => StreakCelebrationPresenter(
            navigatorKey: navKey,
            child: child ?? const SizedBox.shrink(),
          ),
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: HomeScreen(
              key: key,
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
      // Let the load evaluation run until the watcher fires: the
      // store counting today is the observable fire point.
      for (var i = 0; i < 40; i++) {
        await _pumpReal(tester, rounds: 2);
        final s = StreakStore.instance.state;
        if (s != null && s.countedDays.contains(todayStr)) break;
      }
      final s = StreakStore.instance.state;
      expect(s, isNotNull, reason: 'store state installed');
      expect(s!.countedDays, contains(todayStr),
          reason: 'the completion fired and counted today while '
              'the claim chain was parked at the gated push');
    }

    Finder flamesFinder() =>
        find.byType(StreakPillFlame, skipOffstage: false);

    void recordOutcome(String surface) {
      final s = StreakStore.instance.state;
      final flames = flamesFinder();
      final lit = flames.evaluate().isEmpty
          ? null
          : (flames.evaluate().first.widget as StreakPillFlame).lit;
      // ignore: avoid_print
      print('REPRO[$surface] celebration='
          '${find.byType(StreakCelebrationScreen).evaluate().isNotEmpty} '
          'storeCounted=${s?.countedDays.contains(todayStr)} '
          'gemPending=${GemService.instance.debugPending} '
          'gemBalance=${GemService.instance.balance} pillLit=$lit');
    }

    void expectDesired(String surface) {
      expect(find.byType(StreakCelebrationScreen), findsOneWidget,
          reason: '[$surface] celebration presented right away');
      final s = StreakStore.instance.state!;
      expect(s.countedDays, contains(todayStr),
          reason: '[$surface] streak counted today');
      // The claim: either granted (balance adopted) or QUEUED —
      // never silently absent. The mock gem transport cannot
      // grant, so the daily key must be in the pending queue.
      final pending = GemService.instance.debugPending;
      expect(
        GemService.instance.balance != null ||
            pending.contains('daily:$todayStr'),
        isTrue,
        reason: '[$surface] +5 daily claim invoked (pending: $pending)',
      );
      final flames = flamesFinder();
      expect(flames, findsWidgets,
          reason: '[$surface] streak pill present');
      expect((flames.evaluate().first.widget as StreakPillFlame).lit,
          isTrue,
          reason: '[$surface] pill flame lit immediately');
    }

    testWidgets('(b) control: plain Home, nothing over it',
        (tester) async {
      await pumpHomeParked(tester);
      repo.openGate();
      await _pumpReal(tester);
      recordOutcome('plain-home');
      expectDesired('plain-home');
    });

    testWidgets('(a) Today Summary sheet open (founder incident)',
        (tester) async {
      await pumpHomeParked(tester);
      // Celebration-delay timing: the celebration is ALREADY
      // presented (it no longer waits for the gated push), so
      // Home sits offstage beneath it and the card cannot be
      // tapped yet. The founder-incident shape — the sheet open
      // when the fire lands — is covered by
      // celebration_delay_repro_test.dart, which completes the
      // day FROM the sheet. Here: verify the celebration landed,
      // dismiss it, then run the sheet-open outcome checks.
      expect(find.byType(StreakCelebrationScreen), findsOneWidget,
          reason: '[today-sheet] celebration presented before the '
              'sheet opens (presentation-first timing)');
      navKey.currentState!.pop();
      await _pumpReal(tester, rounds: 4);
      await tester.tap(find.byType(TodaySummaryCard));
      await _pumpReal(tester, rounds: 4);
      expect(find.text("Today's Plan"), findsOneWidget,
          reason: 'the Today Summary sheet is open');
      repo.openGate();
      await _pumpReal(tester);
      recordOutcome('today-sheet');
      // expectDesired asserts the celebration visible; it was
      // verified above and dismissed, so assert the rest of the
      // desired outcome here.
      expect(GemService.instance.debugPending, isNotEmpty,
          reason: '[today-sheet] the gem claim is queued, not eaten');
      expect(StreakStore.instance.state!.countedDays,
          contains(todayStr),
          reason: '[today-sheet] the streak counted today');
      final flame = tester.widgetList<StreakPillFlame>(flamesFinder());
      expect(flame, isNotEmpty,
          reason: '[today-sheet] streak pill flame present');
      expect(flame.first.lit, isTrue,
          reason: '[today-sheet] the pill is lit immediately');
    });

    testWidgets('(c) another route pushed on top of Home',
        (tester) async {
      await pumpHomeParked(tester);
      final nav = Navigator.of(
          tester.element(find.byType(HomeScreen, skipOffstage: false)));
      unawaited(nav.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('OTHER SCREEN')),
      )));
      await _pumpReal(tester, rounds: 4);
      expect(find.text('OTHER SCREEN'), findsOneWidget);
      // Celebration-delay timing: the celebration presented
      // BEFORE this push (it no longer waits for the gated
      // push), so it now sits in the stack UNDER the pushed
      // route — held, not dropped. (The original (c) shape —
      // fire lands while a route is already up, presenter pushes
      // over it — is the same code path as (d)/(f) and the delay
      // suites' sheet case.)
      expect(
          find.byType(StreakCelebrationScreen, skipOffstage: false),
          findsOneWidget,
          reason: '[pushed-route] the presented celebration is '
              'held in the stack under the pushed route');
      repo.openGate();
      await _pumpReal(tester);
      nav.pop();
      await _pumpReal(tester, rounds: 4);
      recordOutcome('pushed-route');
      expectDesired('pushed-route');
    });

    testWidgets('(d) Home drawer open', (tester) async {
      await pumpHomeParked(tester);
      final scaffold =
          tester.state<ScaffoldState>(find.byType(Scaffold).first);
      scaffold.openDrawer();
      await _pumpReal(tester, rounds: 4);
      repo.openGate();
      await _pumpReal(tester);
      recordOutcome('drawer');
      expectDesired('drawer');
    });

    testWidgets('(e) app backgrounded after the completing '
        'moment, then foregrounded — the celebration stays '
        'exactly once', (tester) async {
      await pumpHomeParked(tester);
      // Celebration-delay timing: the completion fired while the
      // app was resumed, so the celebration is already presented
      // (the held-while-paused path is pinned at the presenter
      // level in celebration_delay_grants_test.dart).
      expect(find.byType(StreakCelebrationScreen), findsOneWidget,
          reason: '[completing moment] celebration presented while '
              'resumed, before the gated push lands');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      repo.openGate();
      await _pumpReal(tester);
      recordOutcome('backgrounded');
      expect(find.byType(StreakCelebrationScreen), findsOneWidget,
          reason: '[backgrounded] the presented celebration is '
              'not dropped by backgrounding');
      expect(StreakCelebrationService.instance.pending, isNull,
          reason: '[backgrounded] nothing is left pending — the '
              'celebration was already consumed by presentation');
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _pumpReal(tester);
      recordOutcome('foregrounded');
      expectDesired('foregrounded');
    });

    testWidgets('(g) after an unmounted completion, a fresh Home '
        'mount settles the pill lit from the store', (tester) async {
      await pumpHomeParked(tester);
      // Celebration-delay timing: the celebration presented in
      // the first mount, before the unmount — presentation no
      // longer waits for the gated claim chain.
      expect(find.byType(StreakCelebrationScreen), findsOneWidget,
          reason: '[first mount] celebration presented before the '
              'unmount');
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('OTHER TAB'))),
      );
      await _pumpReal(tester, rounds: 3);
      repo.openGate();
      await _pumpReal(tester);
      // Return to Home (fresh mount): the pill settles lit from
      // the store state (this test's original intent), and the
      // celebration does NOT present a second time — the day
      // already counted and celebrated (exactly once per day).
      await pumpHomeParked(tester, key: const ValueKey('repro-home-2'));
      expect(find.byType(StreakCelebrationScreen), findsNothing,
          reason: '[remounted] no second celebration for an '
              'already-celebrated day');
      repo.openGate();
      await _pumpReal(tester);
      recordOutcome('remounted');
      final flames = flamesFinder();
      expect(flames.evaluate(), isNotEmpty);
      expect((flames.evaluate().first.widget as StreakPillFlame).lit,
          isTrue,
          reason: '[remounted] settle lights the pill from the '
              'settled store state');
    });

    testWidgets('(f) Home unmounted mid-completion (tab switch '
        'disposes Home, the MainShell rule)', (tester) async {
      await pumpHomeParked(tester);
      // The shell disposes the outgoing tab's screen on switch:
      // replace the tree while _presentCompletion is parked. The
      // replacement tree keeps the production app shape (root
      // presenter + keyed Navigator) with a different tab body.
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navKey,
          builder: (context, child) => StreakCelebrationPresenter(
            navigatorKey: navKey,
            child: child ?? const SizedBox.shrink(),
          ),
          home: const Scaffold(body: Text('OTHER TAB')),
        ),
      );
      await _pumpReal(tester, rounds: 3);
      repo.openGate();
      await _pumpReal(tester);
      recordOutcome('home-unmounted');
      // Desired: the celebration is not lost — it presents over
      // the current surface (or is held and presented on return).
      expect(find.byType(StreakCelebrationScreen), findsOneWidget,
          reason: '[home-unmounted] celebration not eaten by the '
              'mounted guard');
    });
  });

  // (h) The check-in pop race. The founder's completing check-in
  // was "2 · Rough · Crash": ranking 2 opens the REAL
  // CheckInKindSheet, whose tap-to-commit _run awaits the commit
  // and then calls Navigator.of(context).pop() UNCONDITIONALLY
  // (checkin_sheets.dart). That pop removes the TOP route of the
  // navigator — whatever it is when the commit future resolves.
  // The completion chain (evaluation -> watcher -> push -> gem
  // grants -> celebration push) races the kind commit's own
  // network chain; when the celebration wins the race to the top
  // of the stack, the sheet's late pop removes THE CELEBRATION,
  // in place, with no transition — the founder never sees it.
  group('check-in sheet pop race', () {
    testWidgets('(h) a kind-sheet commit resolving AFTER the '
        'celebration push pops the celebration, not the sheet',
        (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final commitGate = Completer<bool>();
      BuildContext? homeCtx;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (ctx) {
            homeCtx = ctx;
            return const Text('HOME');
          }),
        ),
      ));
      await tester.pump();
      // The kind sheet opens over Home (production entry point).
      unawaited(showCheckInKindSheet(
        context: homeCtx!,
        onKind: (_) => commitGate.future,
        onJustLog: () async => true,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(CheckInKindSheet), findsOneWidget);
      // Tap a kind: _run starts the commit and awaits the gate.
      await tester.tap(find.text('Crash'));
      await tester.pump();
      // The completion chain wins: the celebration is pushed over
      // the still-open kind sheet (the exact call Home makes).
      final data = StreakCelebrationData(
        count: 30,
        previousCount: 29,
        week: const [],
        isMilestoneDay: true,
      );
      unawaited(StreakCelebrationScreen.show(homeCtx!, data: data));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(StreakCelebrationScreen), findsOneWidget,
          reason: 'celebration is the top route');
      // NOW the kind commit resolves: the sheet pops.
      commitGate.complete(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // ignore: avoid_print
      print('REPRO[pop-race] celebration='
          '${find.byType(StreakCelebrationScreen).evaluate().isNotEmpty} '
          'kindSheet=${find.byType(CheckInKindSheet).evaluate().isNotEmpty}');
      expect(find.byType(StreakCelebrationScreen), findsOneWidget,
          reason: '[pop-race] the sheet\'s late pop must not remove '
              'the celebration');
      expect(find.byType(CheckInKindSheet), findsNothing,
          reason: '[pop-race] the sheet itself is gone');
    });
  });
}
