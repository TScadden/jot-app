import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_history_sync.dart';

/// MCP HR-spike fix package (Nov 23, 2026) — the spike SUMMARY leg
/// is CHUNKED.
///
/// Regression context: the shipped leg (PR #153) made ONE
/// `readHrSamples` call over the whole spike window (up to 180
/// days of raw samples as a single MethodChannel list) bounded by
/// the shared 30 s read timeout, and applied summaries only when
/// that single read was fully clean. One bad/slow chunk → partial
/// → ZERO summaries filled, on every capture, forever — and the
/// leg recorded nothing in the capture diagnostics, so the
/// no-fill was invisible. On the founder's phone (VC 100167) the
/// summary fields were NULL on every stored row.
///
/// The fixed leg walks the window in 7-day chunks over the
/// range-capable bridge read (`readHrSamplesRange`); each chunk is
/// its own bounded read; summaries apply per CLEAN chunk; a chunk
/// that errors / partials / times out leaves those days' stored
/// summaries untouched. The leg records its outcome in the capture
/// diagnostics under its own `spikeSummary` entry.

final _now = DateTime(2026, 11, 20, 12); // local noon

int _ms(DateTime d) => d.millisecondsSinceEpoch;

/// Local midnight of the day [d] falls on.
DateTime _midnight(DateTime d) => DateTime(d.year, d.month, d.day);

/// A sample at [day] + [minutes] minutes, local time.
HrSample _s(DateTime day, int minutes, int bpm) => HrSample(
    timeMs: _ms(_midnight(day).add(Duration(minutes: minutes))), bpm: bpm);

String _dateStr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Future<HealthHistoryStore> _memStore(
    Map<String, String> values) async {
  final store = HealthHistoryStore.testInstance();
  store.debugSetStore(
    read: (k) async => values[k],
    write: (k, v) async => values[k] = v,
    delete: (k) async => values.remove(k),
  );
  // Routine-capture window (31 days) so chunk arithmetic is small
  // and explicit: [Oct 21, Nov 21) in 7-day chunks starting
  // Oct 21 / Oct 28 / Nov 4 / Nov 11 / Nov 18.
  await store.markSpikeBackfillComplete();
  return store;
}

HealthHistorySync _sync(_ChunkedHc hc, HealthHistoryStore store,
        {Duration? readTimeoutOverride}) =>
    HealthHistorySync.withDeps(
      hc: hc,
      store: store,
      now: () => _now,
      readTimeoutOverride: readTimeoutOverride,
    );

void main() {
  setUp(HealthHistorySync.debugResetFlight);
  tearDown(HealthHistorySync.debugResetFlight);

  test(
      'REGRESSION (pre-fix filled NOTHING): one failing chunk — '
      'clean chunks fill, the failed chunk\'s stored summaries '
      'stand untouched', () async {
    final values = <String, String>{};
    final store = await _memStore(values);
    // A stored summary inside the chunk that will fail — written
    // by an earlier clean capture. The failed chunk must NOT
    // overwrite it (and must not erase it).
    final nov12 = DateTime(2026, 11, 12);
    await store.mergeRefresh([
      DailyBiometrics(
        date: '2026-11-12',
        maxHrBpm: 135,
        maxHrAtMs: _ms(_midnight(nov12).add(const Duration(minutes: 30))),
        minutesOver100: 9,
        minutesOver120: 2,
        spikeEvents: [
          HrSpikeEvent(
              startMs:
                  _ms(_midnight(nov12).add(const Duration(minutes: 30))),
              peakBpm: 135,
              durationMinutes: 4),
        ],
      ),
    ]);

    final nov5 = DateTime(2026, 11, 5); // clean chunk [Nov 4, Nov 11)
    final nov13 = DateTime(2026, 11, 13); // failed chunk, no prior
    final nov19 = DateTime(2026, 11, 19); // clean chunk [Nov 18, Nov 21)
    final hc = _ChunkedHc(
      samples: [
        _s(nov5, 0, 110), _s(nov5, 1, 118), _s(nov5, 2, 70),
        // In the failed chunk: would compute max 150 if applied.
        _s(nov12, 0, 150), _s(nov12, 1, 150),
        _s(nov13, 0, 140), _s(nov13, 1, 70),
        _s(nov19, 0, 125), _s(nov19, 1, 90), _s(nov19, 2, 70),
      ],
      failChunkStarts: {_ms(DateTime(2026, 11, 11))},
    );
    expect(await _sync(hc, store).capture(force: true), isTrue);

    // The window was read in bounded chunks, none over 7 days.
    expect(hc.rangeCalls, hasLength(5));
    for (final c in hc.rangeCalls) {
      expect(c.endMs - c.startMs,
          lessThanOrEqualTo(const Duration(days: 7).inMilliseconds));
    }

    final all = await store.readAll();
    // Clean chunks filled.
    expect(all['2026-11-05']!.maxHrBpm, 118);
    expect(all['2026-11-19']!.maxHrBpm, 125);
    // Failed chunk: prior summary stands byte-for-byte; the
    // never-filled day in it stays null (no understatement).
    expect(all['2026-11-12']!.maxHrBpm, 135);
    expect(all['2026-11-12']!.minutesOver100, 9);
    expect(all['2026-11-13']?.maxHrBpm, isNull);
    // The counts path is untouched by the leg's failure.
    expect(all['2026-11-19']!.spikeCount, 1);

    // The leg left its OWN diagnostics trace: partial, with the
    // number of days it filled this capture.
    final diag = store.lastCaptureDiagnostics['spikeSummary'];
    expect(diag, isNotNull);
    expect(diag!.errorCode, isNull);
    expect(diag.partialCode, 'SPIKE_SUMMARY_PARTIAL');
    expect(diag.dayCount, 2);
    // …and it did NOT claim the counts leg's `spikes` entry.
    expect(store.lastCaptureDiagnostics['spikes'], isNull);
  });

  test('every chunk failing: capture still succeeds, counts still '
      'land, diagnostics carry the failure code', () async {
    final values = <String, String>{};
    final store = await _memStore(values);
    final hc = _ChunkedHc(
      samples: [_s(DateTime(2026, 11, 19), 0, 125)],
      failChunkStarts: {
        _ms(DateTime(2026, 10, 21)),
        _ms(DateTime(2026, 10, 28)),
        _ms(DateTime(2026, 11, 4)),
        _ms(DateTime(2026, 11, 11)),
        _ms(DateTime(2026, 11, 18)),
      },
    );
    expect(await _sync(hc, store).capture(force: true), isTrue);
    final all = await store.readAll();
    expect(all['2026-11-19']!.spikeCount, 1); // counts path intact
    expect(all['2026-11-19']!.maxHrBpm, isNull); // nothing filled
    final diag = store.lastCaptureDiagnostics['spikeSummary'];
    expect(diag, isNotNull);
    expect(diag!.errorCode, 'HR_SAMPLES_READ_FAILED');
    expect(diag.partialCode, isNull);
    expect(diag.dayCount, 0);
  });

  test('a chunk that TIMES OUT degrades like a failed chunk: its '
      'days are skipped, later chunks still fill', () async {
    final values = <String, String>{};
    final store = await _memStore(values);
    final nov19 = DateTime(2026, 11, 19);
    final hc = _ChunkedHc(
      samples: [
        _s(DateTime(2026, 11, 12), 0, 140), // in the hanging chunk
        _s(nov19, 0, 125), _s(nov19, 1, 70),
      ],
      hangChunkStarts: {_ms(DateTime(2026, 11, 11))},
    );
    final sync = _sync(hc, store,
        readTimeoutOverride: const Duration(milliseconds: 300));
    expect(await sync.capture(force: true), isTrue);
    final all = await store.readAll();
    expect(all['2026-11-12']?.maxHrBpm, isNull); // timed-out chunk
    expect(all['2026-11-19']!.maxHrBpm, 125); // later chunk filled
    final diag = store.lastCaptureDiagnostics['spikeSummary'];
    expect(diag, isNotNull);
    expect(diag!.partialCode, 'SPIKE_SUMMARY_PARTIAL');
    expect(diag.dayCount, 1);
  });

  test('large dataset: ≥100k samples across the window complete '
      'through the chunked path', () async {
    final values = <String, String>{};
    final store = await _memStore(values);
    // 31 days × 3600 samples (one every 2 s for 2 h) = 111,600.
    final samples = <HrSample>[];
    final start = DateTime(2026, 10, 21);
    for (var d = 0; d < 31; d++) {
      final day = start.add(Duration(days: d));
      for (var i = 0; i < 3600; i++) {
        samples.add(HrSample(
          timeMs: _ms(_midnight(day)) + i * 2000,
          bpm: 70 + (i % 50), // peaks at 119 every 50 samples
        ));
      }
    }
    expect(samples.length, greaterThanOrEqualTo(100000));
    final hc = _ChunkedHc(samples: samples);
    expect(await _sync(hc, store).capture(force: true), isTrue);
    expect(hc.rangeCalls, hasLength(5));
    final all = await store.readAll();
    for (var d = 0; d < 31; d++) {
      final date = _dateStr(start.add(Duration(days: d)));
      expect(all[date]!.maxHrBpm, 119, reason: date);
    }
    final diag = store.lastCaptureDiagnostics['spikeSummary'];
    expect(diag, isNotNull);
    expect(diag!.errorCode, isNull);
    expect(diag.partialCode, isNull);
    expect(diag.dayCount, 31);
    expect(diag.sampleCount, samples.length);
  });
}

/// Capture fake for the chunked summary leg: the bridge count
/// read and the range sample read describe the same world.
/// Range reads are keyed by their chunk startMs: a start in
/// [failChunkStarts] returns an HR_SAMPLES_READ_FAILED outcome; a
/// start in [hangChunkStarts] never returns (the wedged-read
/// shape the per-chunk bound exists for). The fake overrides the
/// outcome variant directly (the _ConcurrentHc pattern — the
/// range read's overridable surface, since its legacy method
/// delegates to the outcome variant, never the reverse).
class _ChunkedHc extends HealthConnectService {
  _ChunkedHc({
    required this.samples,
    this.failChunkStarts = const {},
    this.hangChunkStarts = const {},
  });

  final List<HrSample> samples;
  final Set<int> failChunkStarts;
  final Set<int> hangChunkStarts;
  final List<({int startMs, int endMs})> rangeCalls = [];

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
          int days) async =>
      const [];

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(
          int days) async =>
      const [];

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
          int days) async =>
      const [];

  @override
  Future<List<({String date, int count})>> readSpikeCounts(
          int days) async =>
      const [(date: '2026-11-19', count: 1)];

  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(
          int days) async =>
      const [];

  @override
  Future<HcReadOutcome<List<HrSample>>> readHrSamplesRangeWithOutcome(
      {required int startMs, required int endMs}) {
    rangeCalls.add((startMs: startMs, endMs: endMs));
    if (hangChunkStarts.contains(startMs)) {
      return Completer<HcReadOutcome<List<HrSample>>>().future;
    }
    if (failChunkStarts.contains(startMs)) {
      return Future.value(HcReadOutcome<List<HrSample>>(
        value: const [],
        errorCode: 'HR_SAMPLES_READ_FAILED',
        errorDetails: 'IOException',
      ));
    }
    return Future.value(HcReadOutcome<List<HrSample>>(
      value: samples
          .where((s) => s.timeMs >= startMs && s.timeMs < endMs)
          .toList(),
    ));
  }
}
