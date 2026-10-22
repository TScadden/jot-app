import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_history_sync.dart';

/// Sync cadence (founder directive, Oct 22, 2026: "we sync every
/// time the app is opened and every 30 minutes in the background").
///
/// - (a) An app-open capture ([HealthHistorySync.captureOnAppOpen])
///   runs even with a fresh (< 6h) throttle stamp. On the base
///   code there is no such entry point and every non-forced
///   capture is skipped inside the window, so this fails there.
/// - (b) One app open produces exactly ONE capture attempt: the
///   open trigger plus Home-shaped, history-shaped, and
///   repository-shaped attempts in the same open all join the one
///   in-flight run, and attempts after it completes are throttled
///   by the stamp it leaves.
/// - (e) Non-open, non-forced callers remain throttled exactly as
///   before; the relaxation is scoped to the open entry point
///   (Juno ruling, Oct 22, 2026, C2 — no global throttle change).
/// - The open intent is NOT force: it joins a forced run in
///   flight without chaining, and a forced refresh arriving
///   during an open run still chains its own run behind it (the
///   day-detail refresh semantics are unchanged).

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

HealthHistoryStore _fakeStore(_FakeStore fake) {
  final store = HealthHistoryStore.testInstance();
  store.debugSetStore(read: fake.read, write: fake.write, delete: fake.delete);
  return store;
}

final _now = DateTime(2026, 10, 22, 9);

/// Seeds a non-empty store whose last-capture stamp is FRESH
/// (age 0 against [_now]) — the state in which the old throttle
/// skipped every non-forced capture.
Future<HealthHistoryStore> _freshStampedStore() async {
  final store = _fakeStore(_FakeStore());
  await store.mergeRefresh([
    const DailyBiometrics(
      date: '2026-10-21',
      sleepMinutes: 480,
      restingHrBpm: 60,
    ),
  ]);
  await store.markCaptured(_now.millisecondsSinceEpoch);
  return store;
}

/// Instant HC fake; resting-HR reads are counted — one capture
/// run performs exactly one, so the count is the run count.
class _CountingHc extends HealthConnectService {
  int restingHrCalls = 0;

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(int days) async {
    restingHrCalls++;
    return const [];
  }

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(int days) async =>
      const [];

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
    int days,
  ) async => const [];

  @override
  Future<List<({String date, int count})>> readSpikeCounts(int days) async =>
      const [];

  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(int days) async =>
      const [];
}

/// Resting-HR reads gated on per-call completers the test
/// releases by hand; every call is counted.
class _GatedHc extends HealthConnectService {
  final List<Completer<List<({String date, int bpm})>>> gates = [];
  int restingHrCalls = 0;

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(int days) {
    restingHrCalls++;
    final gate = Completer<List<({String date, int bpm})>>();
    gates.add(gate);
    return gate.future;
  }

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(int days) async =>
      const [];

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
    int days,
  ) async => const [];

  @override
  Future<List<({String date, int count})>> readSpikeCounts(int days) async =>
      const [];

  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(int days) async =>
      const [];
}

Future<void> _flush() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUp(() {
    HealthHistorySync.debugResetFlight();
  });
  tearDown(() {
    HealthHistorySync.debugResetFlight();
  });

  test('(a)+(e) open capture runs with a fresh throttle stamp; '
      'the plain non-forced capture stays throttled before AND '
      'after it', () async {
    final store = await _freshStampedStore();
    final hc = _CountingHc();
    final sync = HealthHistorySync.withDeps(
      hc: hc,
      store: store,
      now: () => _now,
    );

    // (e) The plain caller is throttled by the fresh stamp.
    expect(await sync.capture(), isFalse);
    expect(hc.restingHrCalls, 0);

    // (a) The app-open caller runs anyway — exactly one run.
    expect(await sync.captureOnAppOpen(), isTrue);
    expect(hc.restingHrCalls, 1);

    // The open run stamped at its end like any capture, so a
    // later plain caller in the same window is still throttled:
    // the relaxation did not lower the shared throttle (C2).
    expect(await sync.capture(), isFalse);
    expect(hc.restingHrCalls, 1);
  });

  test('(b) one open = one capture: the open trigger and the '
      'Home / history / repository shaped attempts in the same '
      'open all join the single in-flight run', () async {
    final store = await _freshStampedStore();
    final hc = _GatedHc();
    // Distinct instances on the same store, as production builds
    // (AppFlow uses the singleton; Home/history build withDeps).
    final syncOpen = HealthHistorySync.withDeps(
      hc: hc,
      store: store,
      now: () => _now,
    );
    final syncScreens = HealthHistorySync.withDeps(
      hc: hc,
      store: store,
      now: () => _now,
    );

    final open = syncOpen.captureOnAppOpen();
    final homeAttempt = syncScreens.capture();
    final historyAttempt = syncScreens.capture();
    final repoAttempt = syncOpen.capture();
    final secondOpenAttempt = syncScreens.captureOnAppOpen();
    await _flush();
    expect(hc.restingHrCalls, 1); // one run, not five

    hc.gates.single.complete(const []);
    expect(await open, isTrue);
    expect(await homeAttempt, isTrue);
    expect(await historyAttempt, isTrue);
    expect(await repoAttempt, isTrue);
    expect(await secondOpenAttempt, isTrue);
    expect(hc.restingHrCalls, 1);

    // And after the open run completes, a screen load in the
    // same open is throttled by its stamp — no second attempt.
    expect(await syncScreens.capture(), isFalse);
    expect(hc.restingHrCalls, 1);
  });

  test('open intent is not force: an open call during a forced '
      'run joins it and chains nothing', () async {
    final store = await _freshStampedStore();
    final hc = _GatedHc();
    final sync = HealthHistorySync.withDeps(
      hc: hc,
      store: store,
      now: () => _now,
    );

    final forced = sync.capture(force: true);
    await _flush();
    expect(hc.restingHrCalls, 1);

    final open = sync.captureOnAppOpen();
    await _flush();
    expect(hc.restingHrCalls, 1);

    hc.gates.single.complete(const []);
    expect(await forced, isTrue);
    expect(await open, isTrue);
    await _flush();
    // No chained second run was started by the open call.
    expect(hc.restingHrCalls, 1);
  });

  test('forced refresh during an OPEN run still chains its own '
      'forced run behind it (refresh semantics unchanged)', () async {
    final store = await _freshStampedStore();
    final hc = _GatedHc();
    final sync = HealthHistorySync.withDeps(
      hc: hc,
      store: store,
      now: () => _now,
    );

    final open = sync.captureOnAppOpen();
    await _flush();
    expect(hc.restingHrCalls, 1);

    final forced = sync.capture(force: true);
    await _flush();
    expect(hc.restingHrCalls, 1); // chained, not parallel

    hc.gates[0].complete(const []);
    expect(await open, isTrue);
    await _flush();
    expect(hc.restingHrCalls, 2); // the chained forced run

    hc.gates[1].complete(const []);
    expect(await forced, isTrue);
    expect(hc.restingHrCalls, 2);
  });

  test('forced capture with a fresh stamp still runs (existing '
      'force semantics pinned)', () async {
    final store = await _freshStampedStore();
    final hc = _CountingHc();
    final sync = HealthHistorySync.withDeps(
      hc: hc,
      store: store,
      now: () => _now,
    );
    expect(await sync.capture(force: true), isTrue);
    expect(hc.restingHrCalls, 1);
  });
}
