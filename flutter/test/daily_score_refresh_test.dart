import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/daily_score.dart';
import 'package:tabs_lab/src/data/daily_score_refresh.dart';
import 'package:tabs_lab/src/data/daily_score_refresh_owner.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_history_sync.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/daily_score_circle.dart';
import 'package:tabs_lab/src/features/home/daily_score_screen.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';

/// Daily Score refresh (founder direction, Oct 20, 2026) — the
/// user-initiated exception to write-once scoring:
///
/// - [HealthHistoryStore.replaceScore] is the ONLY overwrite path;
///   [HealthHistoryStore.persistScore] still refuses overwrites,
///   and the engine never rewrites a scored day.
/// - [DailyScoreRefresher] forces a capture (the button is the
///   only forcer; automatic captures keep the 6h throttle),
///   re-scores the viewed day ONLY, leaves the score untouched on
///   capture failure or a null recomputation, and carries any
///   newly recorded per-metric read failures in its outcome.
/// - The day detail shows the refresh control in every loaded
///   day-detail state (scored days, unscored days, and today's
///   pending state — the amended scope), disables it in flight,
///   and re-renders from the persisted record after a refresh;
///   the history list and the Home face pick the refreshed
///   number up on return through their existing reload paths.
/// - Refresh STATE is app-scoped (founder-directed Oct 20, 2026,
///   refresh-scope fix): [DailyScoreRefreshOwner] holds the one
///   in-flight refresh and its outcome. A second start is refused
///   on any day (counting fake capture: exactly one forced
///   capture); unmounting the originating screen loses nothing —
///   the store write lands, and an outcome that completes while
///   the user is elsewhere is surfaced INLINE ONLY, once, on the
///   next entry to that day (Juno's deferred-surfacing rulings:
///   no SnackBar on entry, no surfacing at all for success while
///   away, the no-score line only where the day still has no
///   score, and another day's busy control carries the reason
///   "A refresh is already running for another day." as tooltip
///   AND semantics label on a disabled control). Pending outcomes
///   are in-memory only and are dropped by the owner's clear /
///   owner-mismatch hooks (logout / account switch).

/// In-memory fake for the store's storage functions (same shape
/// as daily_score_r70_test.dart).
class _FakeStore {
  final Map<String, String> values = {};
  Future<String?> read(String key) async => values[key];
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  Future<void> delete(String key) async {
    values.remove(key);
  }
}

String _ds(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

List<String> _priorDates(String anchor, int count) {
  final a = DateTime.parse(anchor);
  return [
    for (var i = count; i >= 1; i--) _ds(a.subtract(Duration(days: i))),
  ];
}

HealthHistoryStore _fakeStore(_FakeStore fake) {
  final store = HealthHistoryStore.testInstance();
  store.debugSetStore(read: fake.read, write: fake.write, delete: fake.delete);
  return store;
}

const _target = '2026-10-16';

/// Baseline history (28 days: resting HR 60, HRV 40) + the target
/// day at resting HR 54 / HRV 32, scored by the engine:
/// resting HR −10% → 100, HRV −20% → 35, daily
/// (35·35 + 25·100) / 60 = 62. When a capture later lands HRV 50
/// for the target (+25% → 100), the refreshed daily score is 100.
Future<HealthHistoryStore> _seededStore(_FakeStore fake) async {
  final store = _fakeStore(fake);
  await store.mergeRefresh([
    for (final d in _priorDates(_target, 28))
      DailyBiometrics(date: d, restingHrBpm: 60, hrvRmssdMs: 40),
    const DailyBiometrics(date: _target, restingHrBpm: 54, hrvRmssdMs: 32),
  ]);
  await DailyScoreEngine(store: store).computeMissingScores();
  final row = (await store.readAll())[_target]!;
  assert(row.dailyScore == 62 &&
      row.scoreHrv == 35 &&
      row.scoreRestingHr == 100);
  return store;
}

/// A capture fake that lands [hrv] for the target day in the store
/// (what a real capture's merge would do with late-arriving data)
/// and returns true.
ScoreCapture _landingCapture(HealthHistoryStore store, {double hrv = 50}) {
  return ({bool force = false}) async {
    await store.mergeRefresh([
      DailyBiometrics(date: _target, hrvRmssdMs: hrv),
    ]);
    return true;
  };
}

void main() {
  group('store: replaceScore (the one overwrite path)', () {
    late _FakeStore fake;
    late HealthHistoryStore store;

    setUp(() {
      fake = _FakeStore();
      store = _fakeStore(fake);
    });

    test('replaces all four score fields, nulls included', () async {
      await store.mergeRefresh([
        const DailyBiometrics(date: '2026-10-01', restingHrBpm: 60),
      ]);
      await store.persistScore('2026-10-01',
          dailyScore: 50, scoreSleep: 60, scoreHrv: 40);
      final ok = await store.replaceScore('2026-10-01',
          dailyScore: 77, scoreRestingHr: 77);
      expect(ok, isTrue);
      final row = (await store.readAll())['2026-10-01']!;
      expect(row.dailyScore, 77);
      expect(row.scoreSleep, isNull); // replaced exactly, not merged
      expect(row.scoreHrv, isNull);
      expect(row.scoreRestingHr, 77);
      expect(row.restingHrBpm, 60); // biometrics untouched
      // And it persists: a cold store over the same disk sees it.
      final cold = _fakeStore(fake);
      expect((await cold.readAll())['2026-10-01']!.dailyScore, 77);
    });

    test('missing day: returns false and writes nothing', () async {
      expect(await store.replaceScore('2026-10-01', dailyScore: 50),
          isFalse);
      expect(await store.readAll(), isEmpty);
      expect(fake.values.containsKey(HealthHistoryStore.storageKey),
          isFalse);
    });

    test('write-once regression: persistScore still refuses overwrites',
        () async {
      await store.mergeRefresh([
        const DailyBiometrics(date: '2026-10-01', restingHrBpm: 60),
      ]);
      expect(await store.persistScore('2026-10-01', dailyScore: 50), isTrue);
      expect(await store.persistScore('2026-10-01', dailyScore: 99),
          isFalse);
      expect((await store.readAll())['2026-10-01']!.dailyScore, 50);
      // Even after a user-initiated replace, the automatic path
      // stays write-once.
      expect(await store.replaceScore('2026-10-01', dailyScore: 99),
          isTrue);
      expect(await store.persistScore('2026-10-01', dailyScore: 1),
          isFalse);
      expect((await store.readAll())['2026-10-01']!.dailyScore, 99);
    });
  });

  group('refresher: orchestration semantics', () {
    test(
        'new HRV data landing in the store changes the components '
        'and the number; the capture is forced', () async {
      final fake = _FakeStore();
      final store = await _seededStore(fake);
      final forces = <bool>[];
      final landing = _landingCapture(store);
      final refresher = DailyScoreRefresher.withCapture(
        store: store,
        capture: ({bool force = false}) {
          forces.add(force);
          return landing(force: force);
        },
      );
      final outcome = await refresher.refresh(_target);
      expect(outcome.status, DailyScoreRefreshStatus.refreshed);
      expect(outcome.computation!.dailyScore, 100);
      expect(outcome.newFailureCodes, isEmpty);
      expect(forces, [true]); // the button forces; nothing else may
      final row = (await store.readAll())[_target]!;
      expect(row.dailyScore, 100);
      expect(row.scoreHrv, 100); // was 35
      expect(row.scoreRestingHr, 100);
      expect(row.scoreSleep, isNull);
    });

    test('no new data: identical score, byte-identical persisted record',
        () async {
      final fake = _FakeStore();
      final store = await _seededStore(fake);
      final beforeRow = (await store.readAll())[_target]!;
      final beforeBlob = fake.values[HealthHistoryStore.storageKey];
      final refresher = DailyScoreRefresher.withCapture(
        store: store,
        capture: ({bool force = false}) async => true,
      );
      final outcome = await refresher.refresh(_target);
      expect(outcome.status, DailyScoreRefreshStatus.refreshed);
      expect(outcome.computation!.dailyScore, 62);
      expect((await store.readAll())[_target], beforeRow);
      expect(fake.values[HealthHistoryStore.storageKey], beforeBlob);
    });

    test('failed capture (returns false): prior score untouched',
        () async {
      final fake = _FakeStore();
      final store = await _seededStore(fake);
      final beforeRow = (await store.readAll())[_target]!;
      final beforeBlob = fake.values[HealthHistoryStore.storageKey];
      final refresher = DailyScoreRefresher.withCapture(
        store: store,
        capture: ({bool force = false}) async => false,
      );
      final outcome = await refresher.refresh(_target);
      expect(outcome.status, DailyScoreRefreshStatus.captureFailed);
      expect(outcome.computation, isNull);
      expect((await store.readAll())[_target], beforeRow);
      expect(fake.values[HealthHistoryStore.storageKey], beforeBlob);
    });

    test('throwing capture: reported as captureFailed, never thrown',
        () async {
      final fake = _FakeStore();
      final store = await _seededStore(fake);
      final refresher = DailyScoreRefresher.withCapture(
        store: store,
        capture: ({bool force = false}) async =>
            throw StateError('boom'),
      );
      final outcome = await refresher.refresh(_target);
      expect(outcome.status, DailyScoreRefreshStatus.captureFailed);
      expect((await store.readAll())[_target]!.dailyScore, 62);
    });

    test('refreshing a past day changes no other day\'s stored score',
        () async {
      final fake = _FakeStore();
      final store = await _seededStore(fake);
      final allBefore = await store.readAll();
      final otherBefore = allBefore['2026-10-15']!;
      expect(otherBefore.dailyScore, 70); // baseline day, scored 70
      final refresher = DailyScoreRefresher.withCapture(
        store: store,
        capture: _landingCapture(store),
      );
      await refresher.refresh(_target);
      final allAfter = await store.readAll();
      expect(allAfter[_target]!.dailyScore, 100);
      // Every other day's full record is untouched.
      for (final date in allBefore.keys) {
        if (date == _target) continue;
        expect(allAfter[date], allBefore[date], reason: date);
      }
      expect(allAfter['2026-10-15'], otherBefore);
    });

    test(
        'new diagnostics failures ride the outcome while the '
        'rescore still proceeds from store truth', () async {
      final fake = _FakeStore();
      final store = await _seededStore(fake);
      final landing = _landingCapture(store);
      final refresher = DailyScoreRefresher.withCapture(
        store: store,
        capture: ({bool force = false}) async {
          await store.recordCaptureDiagnostics(
            failures: const {'sleep': 'SLEEP_HISTORY_READ_FAILED'},
            succeeded: const {},
            atMs: 999,
          );
          return landing(force: force);
        },
      );
      final outcome = await refresher.refresh(_target);
      expect(outcome.status, DailyScoreRefreshStatus.refreshed);
      expect(outcome.computation!.dailyScore, 100); // HRV still landed
      expect(outcome.newFailureCodes,
          {'sleep': 'SLEEP_HISTORY_READ_FAILED'});
    });

    test('a pre-existing diagnostics failure is not re-reported',
        () async {
      final fake = _FakeStore();
      final store = await _seededStore(fake);
      await store.recordCaptureDiagnostics(
        failures: const {'hrv': 'HRV_SAMPLES_READ_FAILED'},
        succeeded: const {},
        atMs: 123,
        hrvSampleCount: 0,
        hrvDayCount: 0,
      );
      final refresher = DailyScoreRefresher.withCapture(
        store: store,
        capture: ({bool force = false}) async => true,
      );
      final outcome = await refresher.refresh(_target);
      expect(outcome.status, DailyScoreRefreshStatus.refreshed);
      expect(outcome.newFailureCodes, isEmpty);
    });

    test(
        'null recomputation (no baselines): no-change, existing '
        'score left untouched', () async {
      final fake = _FakeStore();
      final store = _fakeStore(fake);
      await store.mergeRefresh([
        const DailyBiometrics(date: '2026-10-16', restingHrBpm: 60),
      ]);
      await store.persistScore('2026-10-16', dailyScore: 42);
      final refresher = DailyScoreRefresher.withCapture(
        store: store,
        capture: ({bool force = false}) async => true,
      );
      final outcome = await refresher.refresh('2026-10-16');
      expect(outcome.status, DailyScoreRefreshStatus.noChange);
      expect((await store.readAll())['2026-10-16']!.dailyScore, 42);
      // A day not in the store at all: also a plain no-change.
      final missing = await refresher.refresh('2026-01-01');
      expect(missing.status, DailyScoreRefreshStatus.noChange);
      expect((await store.readAll()).containsKey('2026-01-01'), isFalse);
    });

    test(
        'automatic capture stays throttled; the refresher\'s forced '
        'capture runs (real sync wiring)', () async {
      final fake = _FakeStore();
      final store = await _seededStore(fake);
      final now = DateTime(2026, 10, 20, 12);
      await store.markCaptured(now.millisecondsSinceEpoch);
      final hc = _EmptyHc();
      final sync = HealthHistorySync.withDeps(
          hc: hc, store: store, now: () => now);
      // Automatic (unforced) capture within the 6h window: skipped,
      // no reads at all.
      expect(await sync.capture(), isFalse);
      expect(hc.calls, 0);
      // The refresher, wired to the same sync, forces its capture.
      final refresher = DailyScoreRefresher(store: store, sync: sync);
      final outcome = await refresher.refresh(_target);
      expect(outcome.status, DailyScoreRefreshStatus.refreshed);
      expect(hc.calls, greaterThan(0));
      expect((await store.readAll())[_target]!.dailyScore, 62);
    });
  });

  group('widgets: day detail refresh control', () {
    Future<void> pumpDetail(
      WidgetTester tester, {
      required HealthHistoryStore store,
      required String date,
      DailyScoreRefreshOwner? owner,
    }) async {
      await tester.pumpWidget(MaterialApp(
        home: DailyScoreDayScreen(
            store: store, date: date, refreshOwner: owner),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('scored day: control exists with a ≥48dp tap target',
        (tester) async {
      final store = await _seededStore(_FakeStore());
      await pumpDetail(tester, store: store, date: _target);
      final control = find.byKey(const ValueKey('daily-score-refresh'));
      expect(control, findsOneWidget);
      expect(find.byTooltip('Refresh score'), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsOneWidget);
      final size = tester.getSize(control);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(find.text('Daily Score: 62 · Good'), findsOneWidget);
    });

    testWidgets('tap refresh: the number and components re-render '
        'from the persisted record', (tester) async {
      final store = await _seededStore(_FakeStore());
      final owner = DailyScoreRefreshOwner.withCapture(
        store: store,
        capture: _landingCapture(store),
      );
      await pumpDetail(tester,
          store: store, date: _target, owner: owner);
      expect(find.text('Daily Score: 62 · Good'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('daily-score-refresh')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('Daily Score: 100 · Great'), findsOneWidget);
      expect(find.text('50.0 ms · your baseline 40 ms'), findsOneWidget);
      expect((await store.readAll())[_target]!.dailyScore, 100);
    });

    testWidgets('in flight: control disables, shows progress, and '
        'double-taps are ignored', (tester) async {
      final store = await _seededStore(_FakeStore());
      final completer = Completer<bool>();
      var captureCalls = 0;
      final owner = DailyScoreRefreshOwner.withCapture(
        store: store,
        capture: ({bool force = false}) {
          captureCalls++;
          return completer.future;
        },
      );
      await pumpDetail(tester,
          store: store, date: _target, owner: owner);
      final control = find.byKey(const ValueKey('daily-score-refresh'));
      await tester.tap(control);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      final button = tester.widget<IconButton>(control);
      expect(button.onPressed, isNull);
      // A second tap while in flight does nothing.
      await tester.tap(control, warnIfMissed: false);
      await tester.pump();
      expect(captureCalls, 1);
      completer.complete(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(captureCalls, 1);
      expect(find.text('Daily Score: 62 · Good'), findsOneWidget);
    });

    testWidgets(
        'no score stored: refresh control IS shown (amended scope) '
        'and a data-less tap ends in the honest no-score notice',
        (tester) async {
      final fake = _FakeStore();
      final store = _fakeStore(fake);
      await store.mergeRefresh([
        const DailyBiometrics(date: '2026-10-16', restingHrBpm: 60),
      ]);
      // A capture that lands nothing: the day has no baselines, so
      // no score can be computed even from the fresh snapshot.
      final owner = DailyScoreRefreshOwner.withCapture(
        store: store,
        capture: ({bool force = false}) async => true,
      );
      await pumpDetail(tester,
          store: store, date: '2026-10-16', owner: owner);
      expect(find.text('No score stored for this day.'), findsOneWidget);
      expect(find.byKey(const ValueKey('daily-score-refresh')),
          findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('daily-score-refresh')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('No score stored for this day.'), findsOneWidget);
      expect(
          find.text('Still no score for this day: not enough stored '
              'health data to score it yet.'),
          findsOneWidget);
      expect((await store.readAll())['2026-10-16']!.dailyScore, isNull);
    });

    testWidgets('capture failure: error shown with its code, '
        'displayed score untouched', (tester) async {
      final store = await _seededStore(_FakeStore());
      final owner = DailyScoreRefreshOwner.withCapture(
        store: store,
        capture: ({bool force = false}) async => false,
      );
      await pumpDetail(tester,
          store: store, date: _target, owner: owner);
      await tester.tap(find.byKey(const ValueKey('daily-score-refresh')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.textContaining('[CAPTURE_FAILED]'), findsWidgets);
      // MF-5 pins both surfaces: the SnackBar and this inline line.
      expect(
          find.text('Could not refresh. Please try again. '
              '[CAPTURE_FAILED]'),
          findsOneWidget);
      expect(
          find.text('Refresh failed. Nothing was changed. '
              '[CAPTURE_FAILED]'),
          findsOneWidget);
      expect(find.text('Daily Score: 62 · Good'), findsOneWidget);
      expect((await store.readAll())[_target]!.dailyScore, 62);
      // Flush the SnackBar's display timer before the test ends.
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
    });

    testWidgets('diagnostics failures from the capture are shown '
        'plainly alongside the updated score', (tester) async {
      final store = await _seededStore(_FakeStore());
      final landing = _landingCapture(store);
      final owner = DailyScoreRefreshOwner.withCapture(
        store: store,
        capture: ({bool force = false}) async {
          await store.recordCaptureDiagnostics(
            failures: const {'sleep': 'SLEEP_HISTORY_READ_FAILED'},
            succeeded: const {},
            atMs: 999,
          );
          return landing(force: force);
        },
      );
      await pumpDetail(tester,
          store: store, date: _target, owner: owner);
      await tester.tap(find.byKey(const ValueKey('daily-score-refresh')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('Daily Score: 100 · Great'), findsOneWidget);
      expect(
          find.text('Some data could not be read in this refresh: '
              'Sleep [SLEEP_HISTORY_READ_FAILED]. Any score shown '
              'uses only the data that is stored.'),
          findsOneWidget);
    });

    testWidgets(
        'MF-4: the diagnostic line also renders in the no-score '
        'state (it must read true in all three states)',
        (tester) async {
      final fake = _FakeStore();
      final store = _fakeStore(fake);
      await store.mergeRefresh([
        const DailyBiometrics(date: '2026-10-16', restingHrBpm: 60),
      ]);
      final owner = DailyScoreRefreshOwner.withCapture(
        store: store,
        capture: ({bool force = false}) async {
          await store.recordCaptureDiagnostics(
            failures: const {'hrv': 'HRV_SAMPLES_READ_FAILED'},
            succeeded: const {},
            atMs: 999,
          );
          return true;
        },
      );
      await pumpDetail(tester,
          store: store, date: '2026-10-16', owner: owner);
      await tester.tap(find.byKey(const ValueKey('daily-score-refresh')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('No score stored for this day.'), findsOneWidget);
      expect(
          find.text('Some data could not be read in this refresh: '
              'HRV [HRV_SAMPLES_READ_FAILED]. Any score shown uses '
              'only the data that is stored.'),
          findsOneWidget);
    });

    testWidgets('MF-1: the scored day detail footer is the final '
        'Juno string', (tester) async {
      final store = await _seededStore(_FakeStore());
      await pumpDetail(tester, store: store, date: _target);
      expect(
          find.text('This score uses the data stored for this day '
              'and your baseline from earlier days. It does not '
              'change on its own. It changes only when you refresh '
              'it.'),
          findsOneWidget);
    });
  });

  group('widgets: history + Home pick up a refreshed score', () {
    testWidgets('history list reloads on return from the day detail',
        (tester) async {
      final store = await _seededStore(_FakeStore());
      final owner = DailyScoreRefreshOwner.withCapture(
        store: store,
        capture: _landingCapture(store),
      );
      await tester.pumpWidget(MaterialApp(
        home: DailyScoreScreen(
          store: store,
          refreshOwner: owner,
          snapshotCapture: ({bool force = false}) async => true,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // MF-2 pin: the how-it-works card carries the final Juno
      // string verbatim.
      expect(
          find.text('Each day is compared with your own recent '
              'baseline: the most recent 28 days with data before '
              'it. Sleep counts 40%, HRV 35%, and resting heart rate '
              '25%, counting only the parts with at least 7 baseline '
              'days. HRV is measured as RMSSD, among the most-studied '
              'signals in physiology. A day is scored once and does '
              'not change on its own. You can refresh a day from its '
              'detail screen.'),
          findsOneWidget);
      // Target row first (newest scored), showing 62 before.
      expect(find.text('Fri, Oct 16'), findsOneWidget);
      expect(find.text('62'), findsWidgets);
      await tester.tap(find.text('Fri, Oct 16'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.text('Daily Score: 62 · Good'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('daily-score-refresh')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('Daily Score: 100 · Great'), findsOneWidget);
      // Back to the history: the refreshed number is already there.
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.text('100'), findsWidgets);
      expect(find.text('62'), findsNothing);
    });

    testWidgets('refreshing today: the Home face shows the new '
        'number after the score screen pops', (tester) async {
      final fake = _FakeStore();
      final store = _fakeStore(fake);
      final today = DateTime.now();
      final todayStr = _ds(DateTime(today.year, today.month, today.day));
      await store.mergeRefresh([
        for (final d in _priorDates(todayStr, 28))
          DailyBiometrics(date: d, restingHrBpm: 60, hrvRmssdMs: 40),
        DailyBiometrics(date: todayStr, restingHrBpm: 54, hrvRmssdMs: 32),
      ]);
      // Today is scored by the post-capture engine run (TODAY
      // RULE), simulated here with no cutoff.
      await DailyScoreEngine(store: store).computeMissingScores();
      expect((await store.readAll())[todayStr]!.dailyScore, 62);
      final mockWeather = MockClient((request) async {
        if (request.url.host == 'ipinfo.io') {
          return http.Response(
              '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
              200);
        }
        return http.Response(
            '{"current":{"temperature_2m":55.0,"weather_code":2,"is_day":1}}',
            200);
      });
      await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
          weatherApi: WeatherApiClient(client: mockWeather),
          healthHistoryStore: store,
          dailyScoreSnapshotCapture: ({bool force = false}) async =>
              true,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.byType(DailyScoreCircle), findsOneWidget);
      expect(find.text('62'), findsOneWidget);

      // A refresh of today persists a new score (the exact write
      // the refresher performs), then the user opens the score
      // screen and returns: Home's existing post-pop reload
      // (_openDailyScore → _loadDailyScore) must surface it.
      await store.replaceScore(todayStr,
          dailyScore: 100, scoreHrv: 100, scoreRestingHr: 100);
      await tester.tap(find.byType(DailyScoreCircle));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.byType(DailyScoreScreen), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.byType(DailyScoreCircle), findsOneWidget);
      expect(find.text('100'), findsOneWidget);
      expect(find.text('Great'), findsOneWidget);
    });
  });
  // ── Founder amendment (Oct 20, 2026): snapshot-first +
  // completeness gate for today + day-boundary fallback ─────────

  group('gate: engine completeness rule for today', () {
    // Dynamic "today" so the gated date is a real today.
    String todayStr() {
      final n = DateTime.now();
      return _ds(DateTime(n.year, n.month, n.day));
    }

    Future<HealthHistoryStore> seedAllMetrics(
      _FakeStore fake, {
      required String lastPrior,
      int priorCount = 28,
    }) async {
      final store = _fakeStore(fake);
      await store.mergeRefresh([
        for (final d in _priorDates(lastPrior, priorCount))
          DailyBiometrics(
              date: d,
              sleepMinutes: 480,
              restingHrBpm: 60,
              hrvRmssdMs: 40),
        DailyBiometrics(
            date: lastPrior,
            sleepMinutes: 480,
            restingHrBpm: 60,
            hrvRmssdMs: 40),
      ]);
      return store;
    }

    test(
        'morning: sleep-only today is NOT scored by the gated '
        'post-capture run (stays pending)', () async {
      final today = todayStr();
      final fake = _FakeStore();
      final store = await seedAllMetrics(fake,
          lastPrior: _ds(DateTime.now().subtract(const Duration(days: 1))));
      await store.mergeRefresh([
        DailyBiometrics(date: today, sleepMinutes: 420),
      ]);
      final written = await DailyScoreEngine(store: store)
          .computeMissingScores(completeOnlyDate: today);
      expect(written, greaterThan(0)); // past days still scored
      final row = (await store.readAll())[today]!;
      expect(row.sleepMinutes, 420);
      expect(row.dailyScore, isNull); // pending: no frozen partial
    });

    test('complete today scores in the gated run, once', () async {
      final today = todayStr();
      final fake = _FakeStore();
      final store = await seedAllMetrics(fake,
          lastPrior: _ds(DateTime.now().subtract(const Duration(days: 1))));
      await store.mergeRefresh([
        DailyBiometrics(
            date: today,
            sleepMinutes: 480,
            restingHrBpm: 60,
            hrvRmssdMs: 40),
      ]);
      await DailyScoreEngine(store: store)
          .computeMissingScores(completeOnlyDate: today);
      var row = (await store.readAll())[today]!;
      // Sleep 480/480 → 100; HRV at baseline → 70; RHR → 70.
      expect(row.dailyScore, 82);
      expect(row.scoreSleep, isNotNull);
      expect(row.scoreHrv, isNotNull);
      expect(row.scoreRestingHr, isNotNull);
      // Write-once under the gate: drift today's data and re-run —
      // the scored day never re-scores automatically.
      await store.mergeRefresh([
        DailyBiometrics(date: today, hrvRmssdMs: 90),
      ]);
      await DailyScoreEngine(store: store)
          .computeMissingScores(completeOnlyDate: today);
      row = (await store.readAll())[today]!;
      expect(row.dailyScore, 82);
    });

    test(
        'day-boundary fallback: yesterday incomplete scores with '
        'what the store holds at its first post-day run', () async {
      final today = todayStr();
      final yesterday =
          _ds(DateTime.now().subtract(const Duration(days: 1)));
      final fake = _FakeStore();
      final store = await seedAllMetrics(fake,
          lastPrior: _ds(DateTime.now().subtract(const Duration(days: 2))));
      // Yesterday: sleep only, forever (the Oct 10/12 shape).
      await store.mergeRefresh([
        DailyBiometrics(date: yesterday, sleepMinutes: 480),
      ]);
      await store.mergeRefresh([
        DailyBiometrics(date: today, sleepMinutes: 420),
      ]);
      await DailyScoreEngine(store: store)
          .computeMissingScores(completeOnlyDate: today);
      final all = await store.readAll();
      // Yesterday scored sleep-only (480 of 480 need → 100), its
      // missing components honestly absent ("Not counted").
      expect(all[yesterday]!.dailyScore, 100);
      expect(all[yesterday]!.scoreSleep, 100);
      expect(all[yesterday]!.scoreHrv, isNull);
      expect(all[yesterday]!.scoreRestingHr, isNull);
      // Gate does not leak: incomplete today stayed pending in
      // the same run.
      expect(all[today]!.dailyScore, isNull);
    });

    test(
        'past day with a permanently missing component scores at '
        'its first post-day snapshot (no HRV anywhere)', () async {
      final fake = _FakeStore();
      final store = _fakeStore(fake);
      await store.mergeRefresh([
        for (final d in _priorDates('2026-10-16', 28))
          DailyBiometrics(date: d, sleepMinutes: 480, restingHrBpm: 60),
        const DailyBiometrics(
            date: '2026-10-16', sleepMinutes: 480, restingHrBpm: 54),
      ]);
      await DailyScoreEngine(store: store)
          .computeMissingScores(completeOnlyDate: '2026-10-20');
      final row = (await store.readAll())['2026-10-16']!;
      expect(row.dailyScore, 100); // sleep 100 + RHR 100, renormalized
      expect(row.scoreHrv, isNull); // honestly not counted
    });
  });

  group('gate: sync morning → later the same day', () {
    test(
        'sleep-only morning capture leaves today pending; a later '
        'capture with HRV + resting HR scores it complete, once',
        () async {
      final fake = _FakeStore();
      final store = _fakeStore(fake);
      var now = DateTime(2026, 10, 20, 8);
      const today = '2026-10-20';
      await store.mergeRefresh([
        for (final d in _priorDates(today, 28))
          DailyBiometrics(
              date: d,
              sleepMinutes: 480,
              restingHrBpm: 60,
              hrvRmssdMs: 40),
      ]);
      final hc = _GateFakeHc();
      hc.sleep = const [(date: today, mins: 420, deep: 60)];
      final sync =
          HealthHistorySync.withDeps(hc: hc, store: store, now: () => now);

      // Morning open: the snapshot finds sleep only → no score.
      expect(await sync.capture(), isTrue);
      var row = (await store.readAll())[today]!;
      expect(row.sleepMinutes, 420);
      expect(row.dailyScore, isNull);

      // Later: HRV + resting HR land; the next capture (throttle
      // passed) finds the day complete and scores it.
      hc.hr = const [(date: today, bpm: 60)];
      hc.hrvSamples = [
        (t: DateTime(2026, 10, 20, 3).millisecondsSinceEpoch, ms: 40.0, tier: 100),
      ];
      now = now.add(const Duration(hours: 7));
      expect(await sync.capture(), isTrue);
      row = (await store.readAll())[today]!;
      // Sleep 420/480 = 0.875, squared → 76.5625; HRV 70; RHR 70
      // → (40·76.5625 + 35·70 + 25·70) / 100 = 72.625 → 73.
      expect(row.dailyScore, 73);
      expect(row.scoreSleep, isNotNull);
      expect(row.scoreHrv, isNotNull);
      expect(row.scoreRestingHr, isNotNull);

      // Scored once: later drift never re-scores it automatically.
      hc.hr = const [(date: today, bpm: 45)];
      now = now.add(const Duration(hours: 7));
      expect(await sync.capture(), isTrue);
      expect((await store.readAll())[today]!.dailyScore, 73);
    });
  });

  group('snapshot-first triggers', () {
    testWidgets(
        'history screen awaits its snapshot before computing: a '
        'day only the snapshot makes scoreable appears scored',
        (tester) async {
      final fake = _FakeStore();
      final store = _fakeStore(fake);
      // Six HRV baseline days only — the target cannot score
      // until a seventh baseline day exists.
      await store.mergeRefresh([
        for (final d in _priorDates(_target, 6))
          DailyBiometrics(date: d, hrvRmssdMs: 40),
        const DailyBiometrics(date: _target, hrvRmssdMs: 40),
      ]);
      expect(computeDailyScore(await store.readAll(), _target), isNull);
      var snapshotCalls = 0;
      final forces = <bool>[];
      Future<bool> snapshot({bool force = false}) async {
        snapshotCalls++;
        forces.add(force);
        // The snapshot lands the seventh baseline day.
        await store.mergeRefresh([
          DailyBiometrics(
              date: _priorDates(_target, 7).first, hrvRmssdMs: 40),
        ]);
        return true;
      }

      await tester.pumpWidget(MaterialApp(
        home: DailyScoreScreen(store: store, snapshotCapture: snapshot),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(snapshotCalls, greaterThanOrEqualTo(1));
      expect(forces, everyElement(isFalse)); // never forced here
      expect((await store.readAll())[_target]!.dailyScore, 70);
      expect(find.text('Fri, Oct 16'), findsOneWidget);
    });

    testWidgets(
        'Home awaits its snapshot before reading today: data the '
        'snapshot completes shows as the number', (tester) async {
      final fake = _FakeStore();
      final store = _fakeStore(fake);
      final now = DateTime.now();
      final todayStr = _ds(DateTime(now.year, now.month, now.day));
      await store.mergeRefresh([
        for (final d in _priorDates(todayStr, 28))
          DailyBiometrics(
              date: d,
              sleepMinutes: 480,
              restingHrBpm: 60,
              hrvRmssdMs: 40),
        DailyBiometrics(date: todayStr, sleepMinutes: 480),
      ]);
      final forces = <bool>[];
      // A snapshot with a real capture's shape: merge the fresh
      // data, then the post-capture gated engine run.
      Future<bool> snapshot({bool force = false}) async {
        forces.add(force);
        await store.mergeRefresh([
          DailyBiometrics(
              date: todayStr, restingHrBpm: 60, hrvRmssdMs: 40),
        ]);
        await DailyScoreEngine(store: store)
            .computeMissingScores(completeOnlyDate: todayStr);
        return true;
      }

      final mockWeather = MockClient((request) async {
        if (request.url.host == 'ipinfo.io') {
          return http.Response(
              '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
              200);
        }
        return http.Response(
            '{"current":{"temperature_2m":55.0,"weather_code":2,"is_day":1}}',
            200);
      });
      await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
          weatherApi: WeatherApiClient(client: mockWeather),
          healthHistoryStore: store,
          dailyScoreSnapshotCapture: snapshot,
        ),
      ));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // Sleep 100, HRV 70, RHR 70 → 82, scored by the snapshot's
      // post-capture run and read back by Home.
      expect(find.text('82'), findsOneWidget);
      expect(forces, isNotEmpty);
      expect(forces, everyElement(isFalse));
    });
  });

  group('pending state surfaces', () {
    Future<HealthHistoryStore> seedPendingToday(_FakeStore fake) async {
      final store = _fakeStore(fake);
      final now = DateTime.now();
      final todayStr = _ds(DateTime(now.year, now.month, now.day));
      await store.mergeRefresh([
        for (final d in _priorDates(todayStr, 28))
          DailyBiometrics(
              date: d,
              sleepMinutes: 480,
              restingHrBpm: 60,
              hrvRmssdMs: 40),
        DailyBiometrics(date: todayStr, sleepMinutes: 420),
      ]);
      // Past days score (plain run, past dates only matter here);
      // today stays unscored — the gate's pending state.
      await DailyScoreEngine(store: store)
          .computeMissingScores(completeOnlyDate: todayStr);
      assert((await store.readAll())[todayStr]!.dailyScore == null);
      return store;
    }

    testWidgets(
        'Home face: sleep-only today shows Waiting, no number, '
        'and today stays unscored', (tester) async {
      final fake = _FakeStore();
      final store = await seedPendingToday(fake);
      final now = DateTime.now();
      final todayStr = _ds(DateTime(now.year, now.month, now.day));
      final mockWeather = MockClient((request) async {
        if (request.url.host == 'ipinfo.io') {
          return http.Response(
              '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
              200);
        }
        return http.Response(
            '{"current":{"temperature_2m":55.0,"weather_code":2,"is_day":1}}',
            200);
      });
      await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
          weatherApi: WeatherApiClient(client: mockWeather),
          healthHistoryStore: store,
          // A completed snapshot that landed nothing new: Home's
          // own run must still not freeze a partial score for
          // today (the freeze protection itself is pinned at the
          // engine/sync level in the gate groups above).
          dailyScoreSnapshotCapture: ({bool force = false}) async =>
              true,
        ),
      ));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(DailyScoreCircle), findsOneWidget);
      expect(find.text('Waiting'), findsOneWidget);
      expect(find.text('Building'), findsNothing);
      expect((await store.readAll())[todayStr]!.dailyScore, isNull);
    });

    testWidgets(
        'day detail for a pending today shows the waiting copy '
        'and the refresh control', (tester) async {
      final fake = _FakeStore();
      final store = await seedPendingToday(fake);
      final now = DateTime.now();
      final todayStr = _ds(DateTime(now.year, now.month, now.day));
      await tester.pumpWidget(MaterialApp(
        home: DailyScoreDayScreen(store: store, date: todayStr),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
          find.text('Today\'s score is waiting for today\'s health '
              'data. Tabs can score today once sleep, HRV, and '
              'resting heart rate are all available and counted. You '
              'can also tap refresh to score it now from the data '
              'already stored.'),
          findsOneWidget);
      expect(find.text('No score stored for this day.'), findsNothing);
      expect(find.byKey(const ValueKey('daily-score-refresh')),
          findsOneWidget);
    });

    testWidgets(
        'refresh during pending today scores immediately from '
        'the snapshot data, complete or not', (tester) async {
      final fake = _FakeStore();
      final store = await seedPendingToday(fake);
      final now = DateTime.now();
      final todayStr = _ds(DateTime(now.year, now.month, now.day));
      // The forced capture lands nothing new: the refresh must
      // still score today sleep-only (420 of 480 need = 0.875,
      // squared → 76.5625 → 77).
      final owner = DailyScoreRefreshOwner.withCapture(
        store: store,
        capture: ({bool force = false}) async => true,
      );
      await tester.pumpWidget(MaterialApp(
        home: DailyScoreDayScreen(
            store: store, date: todayStr, refreshOwner: owner),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const ValueKey('daily-score-refresh')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      final row = (await store.readAll())[todayStr]!;
      expect(row.dailyScore, 77);
      expect(row.scoreSleep, 77);
      expect(row.scoreHrv, isNull);
      expect(row.scoreRestingHr, isNull);
      expect(find.text('Daily Score: 77 · Good'), findsOneWidget);
      expect(find.text('Not counted'), findsNWidgets(2));
      // Write-once resumes: a later gated automatic run with
      // drifted data never re-scores the manually scored day.
      await store.mergeRefresh([
        DailyBiometrics(date: todayStr, sleepMinutes: 100),
      ]);
      await DailyScoreEngine(store: store)
          .computeMissingScores(completeOnlyDate: todayStr);
      expect((await store.readAll())[todayStr]!.dailyScore, 77);
    });
  });

  // ── Refresh-scope fix (founder-directed Oct 20, 2026): the
  // app-scoped owner — single-flight, unmount-safe outcomes,
  // deferred inline-only surfacing (Juno rulings) ─────────────

  group('owner: single-flight + outcome records', () {
    test(
        'a second start is refused on the SAME day and on a '
        'DIFFERENT day; exactly one forced capture runs', () async {
      final store = await _seededStore(_FakeStore());
      final completer = Completer<bool>();
      var captureCalls = 0;
      final forces = <bool>[];
      final owner = DailyScoreRefreshOwner.withCapture(
        store: store,
        capture: ({bool force = false}) {
          captureCalls++;
          forces.add(force);
          return completer.future;
        },
      );
      final first = owner.startRefresh(_target);
      expect(first, isNotNull);
      expect(owner.isRefreshing, isTrue);
      expect(owner.refreshingDate, _target);
      expect(owner.isRefreshingDate(_target), isTrue);
      expect(owner.isRefreshingDate('2026-10-15'), isFalse);
      // Refused — no queueing, no second forced capture.
      expect(owner.startRefresh(_target), isNull);
      expect(owner.startRefresh('2026-10-15'), isNull);
      completer.complete(true);
      final outcome = await first!;
      expect(outcome.status, DailyScoreRefreshStatus.refreshed);
      expect(captureCalls, 1);
      expect(forces, [true]);
      expect(owner.isRefreshing, isFalse);
      expect(owner.refreshingDate, isNull);
      // The outcome is recorded for consume-once surfacing.
      expect(owner.hasPendingOutcome(_target), isTrue);
      expect(owner.consumeOutcome(_target), isNotNull);
      expect(owner.hasPendingOutcome(_target), isFalse);
      expect(owner.consumeOutcome(_target), isNull);
      // And the owner accepts a fresh refresh once idle.
      final second = owner.startRefresh(_target);
      expect(second, isNotNull);
      await second!;
      expect(captureCalls, 2);
    });

    test(
        'clear drops a recorded outcome (logout / session expiry '
        'leaves nothing to surface)', () async {
      final store = await _seededStore(_FakeStore());
      final owner = DailyScoreRefreshOwner.withCapture(
        store: store,
        capture: _landingCapture(store),
      );
      await owner.startRefresh(_target);
      expect(owner.hasPendingOutcome(_target), isTrue);
      owner.clear();
      expect(owner.hasPendingOutcome(_target), isFalse);
      expect(owner.consumeOutcome(_target), isNull);
    });

    test(
        'clear invalidates an in-flight refresh: its outcome is '
        'discarded when it settles, never recorded', () async {
      final store = await _seededStore(_FakeStore());
      final completer = Completer<bool>();
      final owner = DailyScoreRefreshOwner.withCapture(
        store: store,
        capture: ({bool force = false}) => completer.future,
      );
      final flight = owner.startRefresh(_target);
      expect(flight, isNotNull);
      owner.clear();
      completer.complete(true);
      await flight!;
      // The flight slot frees on settle (single-flight is never
      // weakened), but nothing was recorded for the next account.
      expect(owner.isRefreshing, isFalse);
      expect(owner.hasPendingOutcome(_target), isFalse);
      expect(owner.consumeOutcome(_target), isNull);
    });

    test(
        'clear during a flight does NOT free the flight slot: a '
        'start attempted during the still-running pre-clear '
        'flight is refused, and exactly one forced capture runs '
        'in total', () async {
      final store = await _seededStore(_FakeStore());
      final completer = Completer<bool>();
      var captureCalls = 0;
      final owner = DailyScoreRefreshOwner.withCapture(
        store: store,
        capture: ({bool force = false}) {
          captureCalls++;
          return completer.future;
        },
      );
      final flight = owner.startRefresh(_target);
      expect(flight, isNotNull);
      // Let the refresher reach its capture (it first snapshots
      // the store): the forced capture is now genuinely running,
      // suspended on the completer — the still-running pre-clear
      // flight this pin is about.
      await Future<void>.delayed(Duration.zero);
      expect(captureCalls, 1);
      expect(owner.isRefreshing, isTrue);
      owner.clear();
      // The pre-clear capture is still running: clear invalidated
      // its OUTCOME, never its flight — a new start here would be
      // a second concurrent forced capture, so it is refused.
      expect(owner.isRefreshing, isTrue);
      expect(owner.startRefresh(_target), isNull);
      expect(owner.startRefresh('2026-10-15'), isNull);
      expect(captureCalls, 1); // exactly one forced capture total
      completer.complete(true);
      await flight!;
      // After the pre-clear run settles: nothing was recorded,
      // and the flight slot is finally free.
      expect(owner.isRefreshing, isFalse);
      expect(owner.hasPendingOutcome(_target), isFalse);
      expect(owner.consumeOutcome(_target), isNull);
      final next = owner.startRefresh(_target);
      expect(next, isNotNull);
      await next!;
      expect(captureCalls, 2);
    });

    test(
        'a recorded pending outcome is STRIPPED to status + new '
        'failure codes only: no computation is held (Juno ruling '
        '5)', () async {
      final store = await _seededStore(_FakeStore());
      final landing = _landingCapture(store);
      final owner = DailyScoreRefreshOwner.withCapture(
        store: store,
        capture: ({bool force = false}) async {
          await store.recordCaptureDiagnostics(
            failures: const {'sleep': 'SLEEP_HISTORY_READ_FAILED'},
            succeeded: const {},
            atMs: 999,
          );
          return landing(force: force);
        },
      );
      final produced = await owner.startRefresh(_target);
      // The outcome the refresh PRODUCED carries its computation
      // (health values: asleep minutes, HRV, resting HR,
      // baselines) — which is exactly why the stored record must
      // not hold this object as-is.
      expect(produced, isNotNull);
      expect(produced!.status, DailyScoreRefreshStatus.refreshed);
      expect(produced.computation, isNotNull);
      expect(produced.newFailureCodes,
          {'sleep': 'SLEEP_HISTORY_READ_FAILED'});
      // The RECORDED pending outcome keeps the status and the
      // bracketed failure codes — and nothing else.
      final recorded = owner.consumeOutcome(_target);
      expect(recorded, isNotNull);
      expect(recorded!.status, DailyScoreRefreshStatus.refreshed);
      expect(recorded.newFailureCodes,
          {'sleep': 'SLEEP_HISTORY_READ_FAILED'});
      expect(recorded.computation, isNull);
    });

    test(
        'owner mismatch: the first stamp and the same account '
        'keep outcomes; a different account drops them', () async {
      final store = await _seededStore(_FakeStore());
      final owner = DailyScoreRefreshOwner.withCapture(
        store: store,
        capture: _landingCapture(store),
      );
      await owner.startRefresh(_target);
      expect(owner.hasPendingOutcome(_target), isTrue);
      expect(owner.clearIfOwnerMismatch(null), isFalse);
      expect(owner.clearIfOwnerMismatch('a@example.test'), isFalse);
      expect(owner.hasPendingOutcome(_target), isTrue);
      expect(owner.clearIfOwnerMismatch('a@example.test'), isFalse);
      expect(owner.hasPendingOutcome(_target), isTrue);
      expect(owner.clearIfOwnerMismatch('b@example.test'), isTrue);
      expect(owner.hasPendingOutcome(_target), isFalse);
    });
  });

  group('owner: screens across navigation', () {
    Future<void> pumpDetail(
      WidgetTester tester, {
      required HealthHistoryStore store,
      required String date,
      DailyScoreRefreshOwner? owner,
    }) async {
      await tester.pumpWidget(MaterialApp(
        home: DailyScoreDayScreen(
            store: store, date: date, refreshOwner: owner),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
    }

    Future<void> pumpElsewhere(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Text('elsewhere')),
      ));
      await tester.pump();
    }

    testWidgets(
        'refresh started → originating screen unmounts → refresh '
        'completes: the store holds the new score; re-entry shows '
        'it with NO extra surfacing (success while away)',
        (tester) async {
      final store = await _seededStore(_FakeStore());
      final completer = Completer<bool>();
      final landing = _landingCapture(store);
      final owner = DailyScoreRefreshOwner.withCapture(
        store: store,
        capture: ({bool force = false}) async {
          await completer.future;
          return landing(force: force);
        },
      );
      await pumpDetail(tester, store: store, date: _target, owner: owner);
      await tester.tap(find.byKey(const ValueKey('daily-score-refresh')));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // Leave the day entirely while the capture still runs.
      await pumpElsewhere(tester);
      completer.complete(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      // The owner's future lived outside the widget: the write
      // landed even though no screen was listening.
      expect((await store.readAll())[_target]!.dailyScore, 100);
      expect(owner.isRefreshing, isFalse);
      // Re-enter: the refreshed number is simply there — Juno:
      // no toast, banner, badge, or "refreshed" caption.
      await pumpDetail(tester, store: store, date: _target, owner: owner);
      expect(find.text('Daily Score: 100 · Great'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.textContaining('Refresh failed'), findsNothing);
      expect(find.textContaining('Some data could not be read'),
          findsNothing);
      expect(find.textContaining('Still no score'), findsNothing);
    });

    testWidgets(
        're-entering the refreshing day mid-flight shows the '
        'busy/disabled control, not an idle button', (tester) async {
      final store = await _seededStore(_FakeStore());
      final completer = Completer<bool>();
      var captureCalls = 0;
      final owner = DailyScoreRefreshOwner.withCapture(
        store: store,
        capture: ({bool force = false}) {
          captureCalls++;
          return completer.future;
        },
      );
      await pumpDetail(tester, store: store, date: _target, owner: owner);
      await tester.tap(find.byKey(const ValueKey('daily-score-refresh')));
      await tester.pump();
      // Pop and re-open the same day: a brand-new State, while
      // the owner's refresh still runs.
      await pumpDetail(tester, store: store, date: _target, owner: owner);
      final control = find.byKey(const ValueKey('daily-score-refresh'));
      expect(control, findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsNothing);
      final button = tester.widget<IconButton>(control);
      expect(button.onPressed, isNull);
      completer.complete(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(captureCalls, 1); // still exactly one forced capture
      expect(find.text('Daily Score: 62 · Good'), findsOneWidget);
    });

    testWidgets(
        'while one day refreshes, ANOTHER day\'s control is '
        'disabled WITH the reason (tooltip + semantics label)',
        (tester) async {
      final store = await _seededStore(_FakeStore());
      final completer = Completer<bool>();
      final owner = DailyScoreRefreshOwner.withCapture(
        store: store,
        capture: ({bool force = false}) => completer.future,
      );
      // The owner is app-scoped: a refresh can be in flight
      // before this day's screen is even opened.
      final flight = owner.startRefresh(_target);
      expect(flight, isNotNull);
      await pumpDetail(
          tester, store: store, date: '2026-10-15', owner: owner);
      final control = find.byKey(const ValueKey('daily-score-refresh'));
      // The control stays in the tree, disabled, showing progress.
      expect(control, findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsNothing);
      // Verbatim reason as the tooltip…
      expect(find.byTooltip(dailyScoreRefreshBusyOtherDayReason),
          findsOneWidget);
      // …and as the semantics label of a DISABLED button (Juno
      // ruling: the reason must be exposed, not just implied).
      final semantics = tester.widget<Semantics>(
        find.byWidgetPredicate((w) =>
            w is Semantics &&
            w.properties.label == dailyScoreRefreshBusyOtherDayReason),
      );
      expect(semantics.properties.button, isTrue);
      expect(semantics.properties.enabled, isFalse);
      // When the flight ends, this day's control is a normal
      // idle refresh button again.
      completer.complete(true);
      await flight!;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.byTooltip('Refresh score'), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsOneWidget);
    });

    testWidgets(
        'capture failure while away: old score untouched; on '
        'return the failure surfaces INLINE ONCE, with no '
        'SnackBar; a second entry does not re-show it',
        (tester) async {
      final store = await _seededStore(_FakeStore());
      final completer = Completer<bool>();
      final owner = DailyScoreRefreshOwner.withCapture(
        store: store,
        capture: ({bool force = false}) => completer.future,
      );
      await pumpDetail(tester, store: store, date: _target, owner: owner);
      await tester.tap(find.byKey(const ValueKey('daily-score-refresh')));
      await tester.pump();
      await pumpElsewhere(tester);
      completer.complete(false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect((await store.readAll())[_target]!.dailyScore, 62);
      expect(owner.hasPendingOutcome(_target), isTrue);
      // Return: the failure is there, inline, exactly the
      // standing string — and NO SnackBar on entry (Juno ruling).
      await pumpDetail(tester, store: store, date: _target, owner: owner);
      expect(
          find.text('Refresh failed. Nothing was changed. '
              '[CAPTURE_FAILED]'),
          findsOneWidget);
      expect(find.text('Daily Score: 62 · Good'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(
          find.text('Could not refresh. Please try again. '
              '[CAPTURE_FAILED]'),
          findsNothing);
      expect(owner.hasPendingOutcome(_target), isFalse); // consumed
      // Leave and re-enter: never shown again.
      await pumpElsewhere(tester);
      await pumpDetail(tester, store: store, date: _target, owner: owner);
      expect(find.textContaining('Refresh failed'), findsNothing);
      expect(find.text('Daily Score: 62 · Good'), findsOneWidget);
    });

    testWidgets(
        'per-metric failure while away: the qualification line '
        'surfaces inline on return EVEN THOUGH a score was '
        'produced — and only once', (tester) async {
      final store = await _seededStore(_FakeStore());
      final landing = _landingCapture(store);
      final owner = DailyScoreRefreshOwner.withCapture(
        store: store,
        capture: ({bool force = false}) async {
          await store.recordCaptureDiagnostics(
            failures: const {'sleep': 'SLEEP_HISTORY_READ_FAILED'},
            succeeded: const {},
            atMs: 999,
          );
          return landing(force: force);
        },
      );
      // The refresh runs with no day screen mounted at all.
      final flight = owner.startRefresh(_target);
      expect(flight, isNotNull);
      final outcome = await flight!;
      expect(outcome.status, DailyScoreRefreshStatus.refreshed);
      expect((await store.readAll())[_target]!.dailyScore, 100);
      await pumpDetail(tester, store: store, date: _target, owner: owner);
      expect(find.text('Daily Score: 100 · Great'), findsOneWidget);
      expect(
          find.text('Some data could not be read in this refresh: '
              'Sleep [SLEEP_HISTORY_READ_FAILED]. Any score shown '
              'uses only the data that is stored.'),
          findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      // Consumed on first render: a later entry does not re-show.
      await pumpElsewhere(tester);
      await pumpDetail(tester, store: store, date: _target, owner: owner);
      expect(find.textContaining('Some data could not be read'),
          findsNothing);
    });

    testWidgets('a deferred outcome is shown only on its own day',
        (tester) async {
      final store = await _seededStore(_FakeStore());
      final owner = DailyScoreRefreshOwner.withCapture(
        store: store,
        capture: ({bool force = false}) async => false,
      );
      final flight = owner.startRefresh(_target);
      expect(flight, isNotNull);
      await flight!;
      expect(owner.hasPendingOutcome(_target), isTrue);
      // Another day neither shows it nor consumes it.
      await pumpDetail(
          tester, store: store, date: '2026-10-15', owner: owner);
      expect(find.textContaining('Refresh failed'), findsNothing);
      expect(owner.hasPendingOutcome(_target), isTrue);
      // Its own day shows it.
      await pumpDetail(tester, store: store, date: _target, owner: owner);
      expect(
          find.text('Refresh failed. Nothing was changed. '
              '[CAPTURE_FAILED]'),
          findsOneWidget);
    });

    testWidgets(
        'no-change while away for a day that HAS a score: no '
        'deferred notice at all (Juno ruling)', (tester) async {
      // A store whose target row is scored but has no baselines,
      // so the recomputation is null → noChange.
      final fake = _FakeStore();
      final bare = _fakeStore(fake);
      await bare.mergeRefresh([
        const DailyBiometrics(date: '2026-10-16', restingHrBpm: 60),
      ]);
      await bare.persistScore('2026-10-16', dailyScore: 42);
      final owner = DailyScoreRefreshOwner.withCapture(
        store: bare,
        capture: ({bool force = false}) async => true,
      );
      final flight = owner.startRefresh('2026-10-16');
      expect(flight, isNotNull);
      final outcome = await flight!;
      expect(outcome.status, DailyScoreRefreshStatus.noChange);
      await pumpDetail(
          tester, store: bare, date: '2026-10-16', owner: owner);
      // The standing score renders; the "Still no score" line
      // must NOT — the day has a score.
      expect(find.textContaining('Still no score'), findsNothing);
      expect(find.textContaining('Refresh failed'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect((await bare.readAll())['2026-10-16']!.dailyScore, 42);
    });
  });
}

/// Fake HC source for the gate's sync-level test: mutable windows
/// so a test can land data between captures.
class _GateFakeHc extends HealthConnectService {
  List<({String date, int bpm})> hr = const [];
  List<({String date, int mins, int deep})> sleep = const [];
  List<({int t, double ms, int tier})> hrvSamples = const [];

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
          int days) async =>
      hr;

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(
          int days) async =>
      const [];

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
          int days) async =>
      sleep;

  @override
  Future<List<({String date, int count})>> readSpikeCounts(
          int days) async =>
      const [];

  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(
          int days) async =>
      hrvSamples;
}

/// Fake HC source whose every window is empty; counts its reads
/// so the throttle test can prove an unforced capture read
/// nothing (mirrors hrv_grant_visibility_test.dart's fake).
class _EmptyHc extends HealthConnectService {
  int calls = 0;

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
      int days) async {
    calls++;
    return const [];
  }

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(
      int days) async {
    calls++;
    return const [];
  }

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
      int days) async {
    calls++;
    return const [];
  }

  @override
  Future<List<({String date, int count})>> readSpikeCounts(
      int days) async {
    calls++;
    return const [];
  }

  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(
      int days) async {
    calls++;
    return const [];
  }
}
