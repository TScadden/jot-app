import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_history_sync.dart';

/// Capture read order + gap-aware routine windows.
///
/// Root cause (founder phone): one Daily Score refresh capture ran
/// five SEQUENTIAL reads, each with its own 30 s bound, in the
/// order RHR → calories → sleep → spikes → HRV. The two sibling
/// reads (calories, spikes) sat in front of the score-critical
/// sleep and HRV reads, and RHR / calories / sleep always re-read
/// their full windows (180 / 180 / 90 days) on routine captures —
/// sleep's serial chunks and the unchunked 180-day calories
/// aggregate timed out in consecutive refreshes.
///
/// The fix, pinned here:
/// - reads run critical-first: resting HR → sleep → HRV →
///   calories → spikes;
/// - RHR / calories / sleep use gap-aware routine windows:
///   full windows on the first capture or when the store has no
///   last-capture stamp, otherwise
///   clamp(ceil(gapDays) + 2, 31, fullCap) with fullCap 180 for
///   RHR / calories and 90 for sleep;
/// - spikes and HRV windows are UNCHANGED (180 / 90 first,
///   31 routine).

/// Recording fake: notes the invocation order and the requested
/// window of every read, returns empty windows. While
/// [hangSleep] is set the sleep read never completes (the wedged
/// bridge shape the bounded-read guard exists for).
class _RecordingHc extends HealthConnectService {
  final List<String> order = [];
  final Map<String, int> windows = {};
  bool hangSleep = false;

  void _record(String metric, int days) {
    order.add(metric);
    windows[metric] = days;
  }

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(int days) async {
    _record('restingHr', days);
    return const [];
  }

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(int days) {
    _record('sleep', days);
    if (hangSleep) {
      return Completer<List<({String date, int mins, int deep})>>().future;
    }
    return Future.value(const []);
  }

  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(int days) async {
    _record('hrv', days);
    return const [];
  }

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(int days) async {
    _record('calories', days);
    return const [];
  }

  @override
  Future<List<({String date, int count})>> readSpikeCounts(int days) async {
    _record('spikes', days);
    return const [];
  }
}

HealthHistoryStore _storeFor(Map<String, String> disk) {
  final store = HealthHistoryStore.testInstance();
  store.debugSetStore(
    read: (k) async => disk[k],
    write: (k, v) async => disk[k] = v,
    delete: (k) async => disk.remove(k),
  );
  return store;
}

final _now = DateTime.utc(2026, 10, 21, 12);
const _dayMs = 86400000;

/// Runs one forced capture against a fresh store and returns the
/// recording fake + store. When [seed] is set the store holds one
/// stored day (so the capture is NOT a first capture); when
/// [lastCaptureMs] is set it is stamped via `markCaptured`
/// exactly as a previous successful capture would leave it.
Future<({_RecordingHc hc, HealthHistoryStore store})> _runCapture({
  bool seed = false,
  int? lastCaptureMs,
  _RecordingHc? hc,
  Duration? readTimeoutOverride,
}) async {
  final disk = <String, String>{};
  final store = _storeFor(disk);
  if (seed) {
    await store.mergeRefresh(const [
      DailyBiometrics(
        date: '2026-10-10',
        restingHrBpm: 58,
        sleepMinutes: 432,
        deepSleepMinutes: 88,
        caloriesKcal: 2100,
      ),
    ]);
  }
  if (lastCaptureMs != null) {
    await store.markCaptured(lastCaptureMs);
  }
  final recording = hc ?? _RecordingHc();
  final sync = HealthHistorySync.withDeps(
    hc: recording,
    store: store,
    now: () => _now,
    readTimeoutOverride: readTimeoutOverride,
  );
  expect(await sync.captureFromHealthConnect(force: true), isTrue);
  return (hc: recording, store: store);
}

void main() {
  group('critical-first order', () {
    test('resting HR, sleep and HRV are invoked before calories '
        'and spikes', () async {
      final run = await _runCapture();
      // Exact order: score-critical reads first, siblings last.
      expect(run.hc.order, ['restingHr', 'sleep', 'hrv', 'calories', 'spikes']);
      // The spec form of the same claim, stated directly.
      for (final critical in ['restingHr', 'sleep', 'hrv']) {
        for (final sibling in ['calories', 'spikes']) {
          expect(
            run.hc.order.indexOf(critical),
            lessThan(run.hc.order.indexOf(sibling)),
            reason: '$critical must be invoked before $sibling',
          );
        }
      }
    });
  });

  group('gap-aware routine windows (RHR / calories / sleep)', () {
    test('first capture (empty store) requests full 180/180/90', () async {
      final run = await _runCapture();
      expect(run.hc.windows['restingHr'], 180);
      expect(run.hc.windows['calories'], 180);
      expect(run.hc.windows['sleep'], 90);
      // Unchanged legs: first-capture windows as before.
      expect(run.hc.windows['spikes'], 180);
      expect(run.hc.windows['hrv'], 90);
    });

    test('routine capture 1 day after the last requests the '
        '31-day floor for RHR/calories/sleep', () async {
      final run = await _runCapture(
        seed: true,
        lastCaptureMs: _now.millisecondsSinceEpoch - _dayMs,
      );
      // ceil(1) + 2 = 3, clamped up to the 31-day floor.
      expect(run.hc.windows['restingHr'], 31);
      expect(run.hc.windows['calories'], 31);
      expect(run.hc.windows['sleep'], 31);
      // Unchanged legs: routine windows as before.
      expect(run.hc.windows['spikes'], 31);
      expect(run.hc.windows['hrv'], 31);
    });

    test('routine capture 60 days after the last requests '
        '62/62/62 for RHR/calories/sleep', () async {
      final run = await _runCapture(
        seed: true,
        lastCaptureMs: _now.millisecondsSinceEpoch - 60 * _dayMs,
      );
      // ceil(60) + 2 = 62, inside both caps.
      expect(run.hc.windows['restingHr'], 62);
      expect(run.hc.windows['calories'], 62);
      expect(run.hc.windows['sleep'], 62);
      expect(run.hc.windows['spikes'], 31);
      expect(run.hc.windows['hrv'], 31);
    });

    test('routine capture 200 days after the last requests the '
        'caps 180/180/90 for RHR/calories/sleep', () async {
      final run = await _runCapture(
        seed: true,
        lastCaptureMs: _now.millisecondsSinceEpoch - 200 * _dayMs,
      );
      // ceil(200) + 2 = 202, clamped down to each full cap.
      expect(run.hc.windows['restingHr'], 180);
      expect(run.hc.windows['calories'], 180);
      expect(run.hc.windows['sleep'], 90);
      expect(run.hc.windows['spikes'], 31);
      expect(run.hc.windows['hrv'], 31);
    });

    test('routine capture 100.5 days after the last requests '
        '103/103/90 — fractional gap ceils and sleep hits its '
        'lower cap first', () async {
      // 100.5 days in ms: exactly half a day past 100 days.
      final gapMs = (100.5 * _dayMs).round();
      final run = await _runCapture(
        seed: true,
        lastCaptureMs: _now.millisecondsSinceEpoch - gapMs,
      );
      // ceil(100.5) = 101, + 2 = 103. RHR / calories caps are
      // 180, so both take 103; sleep's cap is 90, so it clamps
      // down to 90 — the divergent-cap case.
      expect(run.hc.windows['restingHr'], 103);
      expect(run.hc.windows['calories'], 103);
      expect(run.hc.windows['sleep'], 90);
      // Unchanged legs: routine windows as before.
      expect(run.hc.windows['spikes'], 31);
      expect(run.hc.windows['hrv'], 31);
    });

    test('routine capture with a future lastCaptureMs (clock '
        'skew) floors all gap-aware windows at 31', () async {
      final run = await _runCapture(
        seed: true,
        lastCaptureMs: _now.millisecondsSinceEpoch + 2 * _dayMs,
      );
      // _runCapture already asserted the capture returned true
      // (forced, so the throttle does not short-circuit on the
      // future stamp). gap = -2 days: ceil(-2) + 2 = 0, floored
      // at 31 for all three gap-aware windows.
      expect(run.hc.windows['restingHr'], 31);
      expect(run.hc.windows['calories'], 31);
      expect(run.hc.windows['sleep'], 31);
      // Unchanged legs: routine windows as before.
      expect(run.hc.windows['spikes'], 31);
      expect(run.hc.windows['hrv'], 31);
    });

    test('non-empty store with lastCaptureMs == null requests '
        'full windows', () async {
      // Seeded (non-empty) but never marked captured: the
      // pre-capture lastCaptureMs is null.
      final run = await _runCapture(seed: true);
      expect(run.hc.windows['restingHr'], 180);
      expect(run.hc.windows['calories'], 180);
      expect(run.hc.windows['sleep'], 90);
    });
  });

  group('regression guard — failed read survival', () {
    test('a timed-out sleep read lands in capture diagnostics '
        'under sleep, the capture returns true, and stored sleep '
        'values survive the merge', () async {
      final hc = _RecordingHc()..hangSleep = true;
      final run = await _runCapture(
        seed: true,
        lastCaptureMs: _now.millisecondsSinceEpoch - _dayMs,
        hc: hc,
        readTimeoutOverride: const Duration(milliseconds: 50),
      );
      // _runCapture already asserted the capture returned true.
      final diag = run.store.lastCaptureDiagnostics['sleep'];
      expect(diag, isNotNull);
      expect(diag!.errorCode, 'READ_TIMEOUT');
      final day = (await run.store.readAll())['2026-10-10']!;
      expect(day.sleepMinutes, 432);
      expect(day.deepSleepMinutes, 88);
      expect(day.restingHrBpm, 58);
      expect(day.caloriesKcal, 2100);
    });
  });
}
