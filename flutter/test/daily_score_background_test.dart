import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/daily_score.dart';
import 'package:tabs_lab/src/data/daily_score_background.dart';
import 'package:workmanager/workmanager.dart'
    show ExistingPeriodicWorkPolicy;
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_history_sync.dart';

/// Daily Score background scoring (founder amendment #2, Oct 20,
/// 2026): a periodic background run snapshots Health Connect
/// (non-forced, throttle SHARED with the foreground), applies the
/// Amendment-#1 gate, falls back to past-day store-only scoring
/// when no snapshot ran, and posts exactly ONE notification per
/// run that created scores — for the most recent newly scored day,
/// and ONLY when the background grant is verified granted (MF-9):
/// an unverifiable grant scores silently, with no notification.
///
/// The HC channel reality (corrected Oct 22, 2026): the bridge
/// now lives in the health_connect_bridge plugin, registered on
/// every FlutterEngine (main + WorkManager background), so the
/// probe can answer true from a background isolate; when it does
/// not answer, the runner degrades to the store-only fallback.
/// These tests pin both shapes with fakes; on-device background
/// HC reads are NOT claimed (see daily_score_background.dart's
/// header).

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

class _FakeNotifier implements DailyScoreReadyNotifier {
  final List<({String date, int? score})> calls = [];

  @override
  Future<void> showScoreReady(String date, {int? score}) async {
    calls.add((date: date, score: score));
  }
}

/// Mutable-window HC fake (the gate tests' pattern) + read
/// counting + availability/grant overrides for the runner probes.
class _BgFakeHc extends HealthConnectService {
  List<({String date, int bpm})> hr = const [];
  List<({String date, int mins, int deep})> sleep = const [];
  List<({int t, double ms, int tier})> hrvSamples = const [];
  int readCalls = 0;
  bool available = true;
  Set<String> granted = const {};

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<Set<String>> getGrantedPermissions() async => granted;

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
      int days) async {
    readCalls++;
    return hr;
  }

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(
      int days) async {
    readCalls++;
    return const [];
  }

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
      int days) async {
    readCalls++;
    return sleep;
  }

  @override
  Future<List<({String date, int count})>> readSpikeCounts(
      int days) async {
    readCalls++;
    return const [];
  }

  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(
      int days) async {
    readCalls++;
    return hrvSamples;
  }
}

const _today = '2026-10-20';
final _now = DateTime(2026, 10, 20, 9);

/// Capture windows holding the 28 baseline days before today
/// (RHR 60, HRV 40, sleep 480) plus today's complete data when
/// [todayComplete] (sleep 480, RHR 54, HRV 40), or sleep-only
/// today otherwise.
void _fillWindows(_BgFakeHc hc,
    {required bool todayComplete, bool skipLastPrior = false}) {
  var priors = _priorDates(_today, 28);
  if (skipLastPrior) priors = priors.sublist(0, priors.length - 1);
  hc.hr = [
    for (final d in priors) (date: d, bpm: 60),
    if (todayComplete) (date: _today, bpm: 54),
  ];
  hc.sleep = [
    for (final d in priors) (date: d, mins: 480, deep: 90),
    (date: _today, mins: 480, deep: 90),
  ];
  hc.hrvSamples = [
    for (final d in priors)
      (
        t: DateTime.parse(d)
            .add(const Duration(hours: 12))
            .millisecondsSinceEpoch,
        ms: 40.0,
        tier: 1,
      ),
    if (todayComplete)
      (
        t: DateTime(2026, 10, 20, 3).millisecondsSinceEpoch,
        ms: 40.0,
        tier: 1,
      ),
  ];
}

DailyScoreBackgroundRunner _runner({
  required HealthHistoryStore store,
  required _BgFakeHc hc,
  required _FakeNotifier notifier,
  bool grant = true,
  bool channel = true,
  HealthHistorySync? sync,
}) {
  final effectiveSync =
      sync ?? HealthHistorySync.withDeps(hc: hc, store: store, now: () => _now);
  return DailyScoreBackgroundRunner(
    store: store,
    hasBackgroundAccess: () async => grant,
    probeChannel: () async => channel,
    runCapture: () => effectiveSync.capture(),
    scorePastDays: (before) =>
        DailyScoreEngine(store: store).computeMissingScores(beforeDate: before),
    notifier: notifier,
    now: () => _now,
  );
}

void main() {
  group('background runner', () {
    late _FakeStore fake;
    late HealthHistoryStore store;
    late _BgFakeHc hc;
    late _FakeNotifier notifier;

    setUp(() {
      fake = _FakeStore();
      store = _fakeStore(fake);
      hc = _BgFakeHc();
      notifier = _FakeNotifier();
    });

    test(
        'complete today data: today is scored in the background and '
        'exactly one notification names today', () async {
      _fillWindows(hc, todayComplete: true);
      final outcome =
          await _runner(store: store, hc: hc, notifier: notifier).run();
      expect(outcome.captureRan, isTrue);
      expect((await store.readAll())[_today]!.dailyScore, isNotNull);
      // The run also first-scored the baseline days (multi-score
      // run) — still ONE notification, for the most recent day.
      expect(outcome.newlyScoredDates.length, greaterThan(1));
      expect(notifier.calls, hasLength(1));
      expect(notifier.calls.single.date, _today);
      expect(outcome.notifiedDate, _today);
    });

    test('incomplete today stays pending and nothing is notified',
        () async {
      // Pre-score the baseline so the run has nothing else to do.
      await store.mergeRefresh([
        for (final d in _priorDates(_today, 28))
          DailyBiometrics(
              date: d, sleepMinutes: 480, restingHrBpm: 60, hrvRmssdMs: 40),
      ]);
      await DailyScoreEngine(store: store).computeMissingScores();
      _fillWindows(hc, todayComplete: false);
      final outcome =
          await _runner(store: store, hc: hc, notifier: notifier).run();
      expect(outcome.captureRan, isTrue);
      expect((await store.readAll())[_today]!.dailyScore, isNull);
      expect(outcome.newlyScoredDates, isEmpty);
      expect(notifier.calls, isEmpty);
    });

    test(
        'channel unreachable (background engine): no capture is '
        'attempted, past-day fallback scores from the store, and '
        'NO notification (MF-9: grant unverifiable)', () async {
      await store.mergeRefresh([
        for (final d in _priorDates('2026-10-19', 28))
          DailyBiometrics(
              date: d, sleepMinutes: 480, restingHrBpm: 60, hrvRmssdMs: 40),
        // Yesterday: sleep-only, permanently missing components.
        const DailyBiometrics(date: '2026-10-19', sleepMinutes: 420),
      ]);
      await DailyScoreEngine(store: store)
          .computeMissingScores(beforeDate: '2026-10-19');
      expect((await store.readAll())['2026-10-19']!.dailyScore, isNull);
      var grantChecked = false;
      final runner = DailyScoreBackgroundRunner(
        store: store,
        hasBackgroundAccess: () async {
          grantChecked = true;
          return true;
        },
        probeChannel: () async => false,
        runCapture: () async => throw StateError('must not capture'),
        scorePastDays: (before) => DailyScoreEngine(store: store)
            .computeMissingScores(beforeDate: before),
        notifier: notifier,
        now: () => _now,
      );
      final outcome = await runner.run();
      expect(outcome.captureAttempted, isFalse);
      expect(outcome.skippedReason, isNull);
      // No HC data is read in the store-only path, so the grant is
      // never even consulted.
      expect(grantChecked, isFalse);
      final row = (await store.readAll())['2026-10-19']!;
      expect(row.dailyScore, isNotNull);
      expect(row.scoreHrv, isNull); // honestly not counted
      // MF-9: the scores stand, but with the channel unavailable
      // the grant cannot be verified, so NO notification posts.
      expect(outcome.newlyScoredDates, ['2026-10-19']);
      expect(outcome.notifiedDate, isNull);
      expect(notifier.calls, isEmpty);
      // Today is NOT scored without a snapshot.
      expect((await store.readAll())[_today], isNull);
    });

    test('pre-existing scores are never re-notified', () async {
      await store.mergeRefresh([
        for (final d in _priorDates(_today, 28))
          DailyBiometrics(
              date: d, sleepMinutes: 480, restingHrBpm: 60, hrvRmssdMs: 40),
        const DailyBiometrics(
            date: _today,
            sleepMinutes: 480,
            restingHrBpm: 54,
            hrvRmssdMs: 40),
      ]);
      await DailyScoreEngine(store: store).computeMissingScores();
      _fillWindows(hc, todayComplete: true);
      final outcome =
          await _runner(store: store, hc: hc, notifier: notifier).run();
      expect(outcome.newlyScoredDates, isEmpty);
      expect(notifier.calls, isEmpty);
    });

    test(
        'grant absent: the pipeline is off — no capture, no '
        'scoring, no notification', () async {
      await store.mergeRefresh([
        for (final d in _priorDates(_today, 28))
          DailyBiometrics(
              date: d, sleepMinutes: 480, restingHrBpm: 60, hrvRmssdMs: 40),
        const DailyBiometrics(date: '2026-10-19', sleepMinutes: 420),
      ]);
      await DailyScoreEngine(store: store)
          .computeMissingScores(beforeDate: '2026-10-19');
      _fillWindows(hc, todayComplete: true);
      final outcome = await _runner(
              store: store, hc: hc, notifier: notifier, grant: false)
          .run();
      expect(outcome.skippedReason, 'grant-absent');
      expect(outcome.captureAttempted, isFalse);
      expect(hc.readCalls, 0);
      expect((await store.readAll())['2026-10-19']!.dailyScore, isNull);
      expect(notifier.calls, isEmpty);
    });

    test(
        'long-gap catch-up with a VERIFIED grant: several past '
        'days score, ONE notification for the most recent',
        () async {
      await store.mergeRefresh([
        for (final d in _priorDates(_today, 28))
          DailyBiometrics(
              date: d, sleepMinutes: 480, restingHrBpm: 60, hrvRmssdMs: 40),
      ]);
      await DailyScoreEngine(store: store)
          .computeMissingScores(beforeDate: '2026-10-18');
      final outcome =
          await _runner(store: store, hc: hc, notifier: notifier).run();
      expect(outcome.newlyScoredDates,
          ['2026-10-18', '2026-10-19']);
      expect(notifier.calls, hasLength(1));
      expect(notifier.calls.single.date, '2026-10-19');
    });

    test(
        'MF-9: grant read fails with the channel available — the '
        'run still scores from the capture, but posts NO '
        'notification (grant unverifiable)', () async {
      _fillWindows(hc, todayComplete: true);
      final sync =
          HealthHistorySync.withDeps(hc: hc, store: store, now: () => _now);
      final runner = DailyScoreBackgroundRunner(
        store: store,
        hasBackgroundAccess: () async =>
            throw StateError('grant read failed'),
        probeChannel: () async => true,
        runCapture: () => sync.capture(),
        scorePastDays: (before) => DailyScoreEngine(store: store)
            .computeMissingScores(beforeDate: before),
        notifier: notifier,
        now: () => _now,
      );
      final outcome = await runner.run();
      expect(outcome.channelAvailable, isTrue);
      expect(outcome.grantPresent, isNull); // unverifiable
      expect(outcome.captureRan, isTrue);
      expect((await store.readAll())[_today]!.dailyScore, isNotNull);
      expect(outcome.newlyScoredDates, isNotEmpty);
      expect(outcome.notifiedDate, isNull);
      expect(notifier.calls, isEmpty);
    });

    test(
        'shared throttle: a foreground capture inside the window '
        'means the background run reads nothing again, but still '
        'falls back for past days', () async {
      final sync =
          HealthHistorySync.withDeps(hc: hc, store: store, now: () => _now);
      // The windows omit yesterday, so the foreground capture
      // never sees it.
      _fillWindows(hc, todayComplete: true, skipLastPrior: true);
      // Foreground capture runs and stamps the shared throttle.
      expect(await sync.capture(), isTrue);
      final callsAfterForeground = hc.readCalls;
      expect(callsAfterForeground, greaterThan(0));
      expect((await store.readAll())['2026-10-19'], isNull);
      // Data lands in the store OUTSIDE a capture (CSV import
      // shape): yesterday appears, sleep-only, unscored.
      await store.mergeRefresh([
        const DailyBiometrics(date: '2026-10-19', sleepMinutes: 500),
      ]);
      final outcome = await _runner(
              store: store, hc: hc, notifier: notifier, sync: sync)
          .run();
      // The background capture was throttled out by the SHARED
      // stamp — no second read of Health Connect.
      expect(outcome.captureAttempted, isTrue);
      expect(outcome.captureRan, isFalse);
      expect(hc.readCalls, callsAfterForeground);
      // …and the past-day fallback still scored the imported day.
      expect((await store.readAll())['2026-10-19']!.dailyScore,
          isNotNull);
      expect(notifier.calls.single.date, '2026-10-19');
    });

    test(
        'Juno C2: an APP-OPEN capture stamps the shared throttle '
        'and the background run stays governed by it — the '
        'foreground bypass never leaks into the background path',
        () async {
      final sync =
          HealthHistorySync.withDeps(hc: hc, store: store, now: () => _now);
      _fillWindows(hc, todayComplete: true, skipLastPrior: true);
      // Foreground app-open capture runs (bypassing the throttle
      // for ITSELF) and stamps the shared store.
      expect(await sync.captureOnAppOpen(), isTrue);
      final callsAfterOpen = hc.readCalls;
      expect(callsAfterOpen, greaterThan(0));
      await store.mergeRefresh([
        const DailyBiometrics(date: '2026-10-19', sleepMinutes: 500),
      ]);
      final outcome = await _runner(
              store: store, hc: hc, notifier: notifier, sync: sync)
          .run();
      // The background capture was throttled out by the open
      // run's stamp: no fresh background reads (C1/C2), and the
      // wake did only its fallback work (C3) — yesterday scored
      // from stored data and the one notification still posted
      // under the verified grant (C4).
      expect(outcome.captureAttempted, isTrue);
      expect(outcome.captureRan, isFalse);
      expect(hc.readCalls, callsAfterOpen);
      expect((await store.readAll())['2026-10-19']!.dailyScore,
          isNotNull);
      expect(notifier.calls.single.date, '2026-10-19');
    });

    test('empty store: the run is a silent no-op (no scores, no '
        'notification)', () async {
      final outcome =
          await _runner(store: store, hc: hc, notifier: notifier).run();
      expect(outcome.newlyScoredDates, isEmpty);
      expect(outcome.notifiedDate, isNull);
      expect(notifier.calls, isEmpty);
    });
  });

  group('grant gate (HealthConnectService)', () {
    test('background permission is NOT in the runtime request set',
        () {
      expect(
          HealthConnectService.requiredPermissions
              .contains(HealthConnectService.backgroundPermission),
          isFalse);
    });

    test('hasBackgroundAccess reads the live granted set', () async {
      final hc = _BgFakeHc();
      hc.granted = {HealthConnectService.backgroundPermission};
      expect(await hc.hasBackgroundAccess(), isTrue);
      hc.granted = const {};
      expect(await hc.hasBackgroundAccess(), isFalse);
    });
  });

  group('score-ready notification', () {
    test('payload is exactly a date; friendly date formats', () {
      expect(LocalDailyScoreReadyNotifier.isScorePayload('2026-10-20'),
          isTrue);
      expect(LocalDailyScoreReadyNotifier.isScorePayload('reminders'),
          isFalse);
      expect(LocalDailyScoreReadyNotifier.isScorePayload(null), isFalse);
      expect(LocalDailyScoreReadyNotifier.friendlyDate('2026-10-20'),
          'Oct 20');
      // MF-8 (Juno Ruling 1): there is NO number-bearing body
      // variant to flip — the notifier is tap-to-view only. The
      // posted title/body/visibility are pinned against the real
      // plugin in notification_bootstrap_test.dart.
    });

    test('scheduler registration fails soft without a platform',
        () async {
      expect(await DailyScoreBackgroundScheduler.register(), isFalse);
    });
  });

  group('scheduler registration (sync cadence, Oct 22, 2026)', () {
    tearDown(() {
      DailyScoreBackgroundScheduler.debugResetWorkmanagerBridge();
    });

    test('requested period is 30 minutes', () {
      expect(DailyScoreBackgroundScheduler.period,
          const Duration(minutes: 30));
    });

    test(
        'register() issues the 30-minute frequency with the '
        'UPDATE policy, so the new period replaces the old 8h '
        'schedule on existing installs (C6)', () async {
      var initializeCalls = 0;
      String? seenUniqueName;
      String? seenTaskName;
      Duration? seenFrequency;
      ExistingPeriodicWorkPolicy? seenPolicy;
      DailyScoreBackgroundScheduler.debugSetWorkmanagerBridge(
        initialize: () async {
          initializeCalls++;
        },
        registerPeriodic: (uniqueName, taskName,
            {frequency, existingWorkPolicy}) async {
          seenUniqueName = uniqueName;
          seenTaskName = taskName;
          seenFrequency = frequency;
          seenPolicy = existingWorkPolicy;
        },
      );
      expect(await DailyScoreBackgroundScheduler.register(), isTrue);
      expect(initializeCalls, 1);
      expect(seenUniqueName, DailyScoreBackgroundScheduler.uniqueName);
      expect(seenTaskName, DailyScoreBackgroundScheduler.taskName);
      expect(seenFrequency, const Duration(minutes: 30));
      expect(seenPolicy, ExistingPeriodicWorkPolicy.update);
      expect(seenPolicy, isNot(ExistingPeriodicWorkPolicy.keep));
    });

    test('register() stays best-effort: a bridge failure is '
        'swallowed into false', () async {
      DailyScoreBackgroundScheduler.debugSetWorkmanagerBridge(
        initialize: () async {},
        registerPeriodic: (uniqueName, taskName,
                {frequency, existingWorkPolicy}) async =>
            throw StateError('no platform'),
      );
      expect(await DailyScoreBackgroundScheduler.register(), isFalse);
    });
  });
}
