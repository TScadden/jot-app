// VC 100133 — Report Hardening Items A + B acceptance suite
// (Bram). Founder shape per the real-data acceptance skill: the
// round-2 harness's founder per-read latencies (spikes ≈18 s,
// HRV ≈22 s, sleep ≈7 s, resting HR ≈3 s, calories ≈2 s at
// production scale, sum ≈52 s) divided by 50 for test time
// (360/440/140/60/40 ms), driven through the REAL
// HealthHistoryQueries union and the REAL ReportDataCollector /
// ReportGenerationPipeline.
//
// Item A — the post-union availability probe is bounded: a
// wedged probe can no longer stall collection into the F4
// deadline; on expiry the affected metrics degrade to the
// grant-UNKNOWN derivation (error — never permissionDenied,
// never stale, never a fabricated success) and collection
// completes.
//
// Item B — the five union reads run concurrently ON TOP of the
// VC 100130 bounds: per-read bound, wedged-read isolation, the
// union soft budget (launch gate + completion cap), the 42-day
// fresh-fetch cap and the F4 conversion all preserved. The
// LatencyHc fake tracks how many reads are in flight at once,
// so the concurrency claim is measured, not assumed.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/progress_report.dart';

import 'report_collect_bounds_harness.dart';

/// Founder-shape per-read latencies at test scale (÷50):
/// resting HR 60 ms (≈3 s), sleep 140 ms (≈7 s), calories 40 ms
/// (≈2 s), spikes 360 ms (≈18 s), HRV 440 ms (≈22 s).
/// Sequential sum ≈ 1040 ms (≈52 s); slowest single read 440 ms.
/// (÷50, not ÷100: on this shared-CPU VM a timed leg carries
/// ~200 ms of scheduling overshoot regardless of its delays —
/// measured repeatedly — so at ÷100 the fixed overshoot, not
/// the read pattern, decided the ratio assertions. ÷50 keeps
/// the founder proportions while giving the wall-clock
/// assertions real margin.)
class LatencyHc extends HealthConnectService {
  LatencyHc({this.wedgeHrv = false, this.slowAll = false});

  final bool wedgeHrv;
  final bool slowAll;

  static const latencies = <String, Duration>{
    'restingHr': Duration(milliseconds: 60),
    'sleep': Duration(milliseconds: 140),
    'calories': Duration(milliseconds: 40),
    'spikes': Duration(milliseconds: 360),
    'hrv': Duration(milliseconds: 440),
  };

  int active = 0;
  int maxActive = 0;
  final List<int> requestedDays = [];

  Future<HcReadOutcome<T>> _run<T>(
      String name, int days, T Function() value) async {
    requestedDays.add(days);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      if (slowAll) {
        await Future.delayed(const Duration(seconds: 10));
      } else if (name == 'hrv' && wedgeHrv) {
        await Completer<void>().future; // never completes
      } else {
        await Future.delayed(latencies[name]!);
      }
      return HcReadOutcome(value: value());
    } finally {
      active--;
    }
  }

  String get _endDay => dstr(reproNow);

  @override
  Future<HcReadOutcome<List<({String date, int bpm})>>>
      readRestingHrHistoryWithOutcome(int days) =>
          _run('restingHr', days, () => [(date: _endDay, bpm: 61)]);

  @override
  Future<HcReadOutcome<List<({String date, int mins, int deep})>>>
      readSleepHistoryWithOutcome(int days) =>
          _run('sleep', days, () => [(date: _endDay, mins: 430, deep: 70)]);

  @override
  Future<HcReadOutcome<List<({String date, int kcal})>>>
      readCaloriesHistoryWithOutcome(int days) =>
          _run('calories', days, () => [(date: _endDay, kcal: 1750)]);

  @override
  Future<HcReadOutcome<List<({String date, int count})>>>
      readSpikeCountsWithOutcome(int days) =>
          _run('spikes', days, () => [(date: _endDay, count: 3)]);

  @override
  Future<HcReadOutcome<List<({int t, double ms, int tier})>>>
      readHrvSamplesWithOutcome(int days) => _run(
            'hrv',
            days,
            () => [
              (
                t: reproNow.millisecondsSinceEpoch,
                ms: 42.0,
                tier: 200,
              ),
            ],
          );
}

/// LatencyHc variant whose HRV read FAILS fast (the collector
/// wires the production 30 s read bound, so a never-completing
/// HRV read at collector level would cost 30 real seconds; the
/// wedged-at-the-bound property is pinned at union level above,
/// and the failed-read → storedOnly derivation is what the
/// collector leg needs).
class FailHrvHc extends LatencyHc {
  @override
  Future<HcReadOutcome<List<({int t, double ms, int tier})>>>
      readHrvSamplesWithOutcome(int days) async => HcReadOutcome(
            value: const [],
            errorCode: 'READ_FAILED',
            errorDetails: 'IOException',
          );
}

/// HC fake for Item A: every union read fails with a
/// SecurityException detail (the stale-grant signature — the
/// derivation may only call it stale when the probe CONFIRMS the
/// grant), and the availability probe itself is wedged (never
/// completes) or healthy, per [wedgeProbe].
class ProbeHc extends ModelHc {
  ProbeHc({required this.wedgeProbe}) : super(scaled(lightCost, 0.01));

  final bool wedgeProbe;
  // probeCalls is inherited from ModelHc and incremented below.

  @override
  Future<HcReadOutcome<List<({String date, int bpm})>>>
      readRestingHrHistoryWithOutcome(int days) async =>
          HcReadOutcome(
            value: const [],
            errorCode: 'READ_FAILED',
            errorDetails: 'java.lang.SecurityException',
          );

  @override
  Future<HcReadOutcome<List<({String date, int mins, int deep})>>>
      readSleepHistoryWithOutcome(int days) async => HcReadOutcome(
            value: const [],
            errorCode: 'READ_FAILED',
            errorDetails: 'java.lang.SecurityException',
          );

  @override
  Future<HcReadOutcome<List<({String date, int kcal})>>>
      readCaloriesHistoryWithOutcome(int days) async => HcReadOutcome(
            value: const [],
            errorCode: 'READ_FAILED',
            errorDetails: 'java.lang.SecurityException',
          );

  @override
  Future<HcReadOutcome<List<({String date, int count})>>>
      readSpikeCountsWithOutcome(int days) async => HcReadOutcome(
            value: const [],
            errorCode: 'READ_FAILED',
            errorDetails: 'java.lang.SecurityException',
          );

  @override
  Future<HcReadOutcome<List<({int t, double ms, int tier})>>>
      readHrvSamplesWithOutcome(int days) async => HcReadOutcome(
            value: const [],
            errorCode: 'READ_FAILED',
            errorDetails: 'java.lang.SecurityException',
          );

  @override
  Future<HcAvailability> probeAvailability() {
    probeCalls++;
    if (wedgeProbe) return Completer<HcAvailability>().future;
    return Future.value(HcAvailability(
      serviceAvailable: true,
      grantedPermissions: HealthConnectService.requiredPermissions,
      bridgeErrorCode: null,
      stepsProbe: HcReadProbeOutcome.ok,
      persistedConnected: true,
    ));
  }
}

Future<HealthHistoryStore> emptyStore() async {
  final disk = <String, String>{};
  final store = HealthHistoryStore.testInstance();
  store.debugSetStore(
    read: (k) async => disk[k],
    write: (k, v) async => disk[k] = v,
    delete: (k) async => disk.remove(k),
  );
  store.debugReset();
  return store;
}

ReportDataCollector makeCollector({
  required HealthConnectService hc,
  required HealthHistoryStore store,
  Duration? availabilityProbeTimeout,
}) {
  return ReportDataCollector(
    backend: ReproBackend(),
    hc: hc,
    historyQueries: HealthHistoryQueries(hc: hc, store: store),
    documentsLoader: () async => const ['doc one'],
    insightsLoader: () async => const [],
    availabilityProbeTimeout: availabilityProbeTimeout,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Item B — parallel union reads (founder shape)', () {
    test(
        'healthy: all five reads in flight at once; wall-clock '
        'tracks the slowest read, not the sequential sum; zero '
        'failed metrics; 42d cap preserved', () async {
      final store = await emptyStore();
      final hc = LatencyHc();
      final queries = HealthHistoryQueries(hc: hc, store: store);

      // Warmup: one throwaway union through the real machinery,
      // so first-run JIT/compile cost lands on neither timed leg
      // (the raw-read baseline below cannot warm loadRange's
      // internals; without this the parallel leg alone paid it).
      await queries.loadDays(
        180,
        end: reproNow,
        metrics: HistoryMetric.values.toSet(),
        readTimeout: const Duration(seconds: 5),
        unionBudget: const Duration(seconds: 10),
        maxFetchDays: 42,
      );
      hc.maxActive = 0;
      hc.requestedDays.clear();

      // Sequential baseline, measured the SAME way: the same
      // fake's five reads awaited one at a time.
      final baseSw = Stopwatch()..start();
      await hc.readRestingHrHistoryWithOutcome(42);
      await hc.readSleepHistoryWithOutcome(42);
      await hc.readCaloriesHistoryWithOutcome(42);
      await hc.readSpikeCountsWithOutcome(42);
      await hc.readHrvSamplesWithOutcome(42);
      baseSw.stop();
      hc.maxActive = 0;
      hc.requestedDays.clear();

      final sw = Stopwatch()..start();
      final union = await queries.loadDays(
        180,
        end: reproNow,
        metrics: HistoryMetric.values.toSet(),
        readTimeout: const Duration(seconds: 5),
        unionBudget: const Duration(seconds: 10),
        maxFetchDays: 42,
      );
      sw.stop();
      // ignore: avoid_print
      print('parallel healthy: baselineSeq=${baseSw.elapsedMilliseconds}ms '
          'parallel=${sw.elapsedMilliseconds}ms maxActive=${hc.maxActive} '
          'days=${hc.requestedDays}');
      // All five reads were genuinely in flight simultaneously.
      expect(hc.maxActive, 5);
      // Healthy case: zero failed metrics, fresh data everywhere.
      expect(union.failedMetrics, isEmpty);
      expect(union.failureDetails, isEmpty);
      expect(union.restingHr, isNotEmpty);
      expect(union.sleepMinutes, isNotEmpty);
      expect(union.deepSleepMinutes, isNotEmpty);
      expect(union.calories, isNotEmpty);
      expect(union.spikes, isNotEmpty);
      expect(union.hrv, isNotEmpty);
      // The 42-day fresh-fetch cap reached every read.
      expect(hc.requestedDays, [42, 42, 42, 42, 42]);
      // Wall-clock: at least the slowest read (440 ms nominal;
      // timers do not fire materially early), and decisively
      // under the sequential baseline — under two thirds of it,
      // where a sequential union would land at ~the full
      // baseline plus union overhead. (The hard concurrency
      // proof is maxActive == 5 above; this ratio is the
      // wall-clock corroboration, with the threshold set for
      // this VM's measured ~200 ms scheduling overshoot.)
      expect(sw.elapsed, greaterThan(const Duration(milliseconds: 400)));
      expect(
          sw.elapsed,
          lessThan(
              Duration(milliseconds: baseSw.elapsedMilliseconds * 2 ~/ 3)));
    });

    test(
        'wedged HRV: fails solo at its own read bound, the union '
        'completes on stored HRV, the other reads land fresh, and '
        'the collector pipeline still reaches ReportReady', () async {
      final store = await seededStore();
      final hc = LatencyHc(wedgeHrv: true);
      final queries = HealthHistoryQueries(hc: hc, store: store);
      final sw = Stopwatch()..start();
      final union = await queries.loadDays(
        180,
        end: reproNow,
        metrics: HistoryMetric.values.toSet(),
        // Read bound above every healthy latency at this scale
        // (max 440 ms), so ONLY the wedged HRV read meets it.
        readTimeout: const Duration(milliseconds: 500),
        unionBudget: const Duration(seconds: 5),
        maxFetchDays: 42,
      );
      sw.stop();
      // ignore: avoid_print
      print('parallel wedged-hrv: elapsed=${sw.elapsedMilliseconds}ms '
          'maxActive=${hc.maxActive}');
      expect(hc.maxActive, 5,
          reason: 'the wedged read did not block the others from '
              'starting');
      expect(union.failedMetrics, {HistoryMetric.hrv});
      expect(union.failureDetails[HistoryMetric.hrv], 'TimeoutException');
      expect(union.hrv, isNotEmpty,
          reason: 'stored HRV surfaces for the wedged metric');
      expect(union.sleepMinutes, isNotEmpty);
      expect(union.spikes, isNotEmpty);
      expect(sw.elapsed, greaterThan(const Duration(milliseconds: 480)));
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));

      // Collector level: the failed-HRV shape through the REAL
      // pipeline reaches ReportReady (stored HRV labeled
      // storedOnly), never a collection timeout.
      final collectorHc = FailHrvHc();
      final collectorStore = await seededStore();
      final backend = ReproBackend();
      final collector = ReportDataCollector(
        backend: backend,
        hc: collectorHc,
        historyQueries:
            HealthHistoryQueries(hc: collectorHc, store: collectorStore),
        documentsLoader: () async => const ['doc one'],
        insightsLoader: () async => const [],
      );
      final pipeline = ReportGenerationPipeline(
        collector: collector,
        backend: backend,
        aiCall: (body) async => (
          statusCode: 200,
          body: {'result': '[SECTION] SUMMARY\nok'},
          serverError: null,
          transportFailure: null,
        ),
        delay: (_) async {},
      );
      final outcome = await pipeline.generate(
        selectedCategories: reproCategories,
        last30Days: false,
        profile: founderProfile(),
        now: reproNow,
        renderPdf: (snap, summary,
                {required isRawFallback, rawBanner}) async =>
            [1, 2, 3],
        savePdf: (bytes, name) async => '/tmp/$name',
      );
      expect(outcome, isA<ReportReady>());
      final ready = outcome as ReportReady;
      expect(
          ready.snapshot.sectionMetadata['hrv']!.status,
          DataSourceStatus.storedOnly,
          reason: 'wedged fresh HRV read + surviving stored series '
              '= honest stored labeling');
      expect(ready.snapshot.hrvSeries, isNotEmpty);
    });

    test(
        'union budget as completion cap: reads slower than the '
        'budget are abandoned with UnionBudgetExhausted and the '
        'union returns on store data inside the budget', () async {
      final store = await seededStore();
      final hc = LatencyHc(slowAll: true);
      final queries = HealthHistoryQueries(hc: hc, store: store);
      final sw = Stopwatch()..start();
      final union = await queries.loadDays(
        180,
        end: reproNow,
        metrics: HistoryMetric.values.toSet(),
        // Read bound (10 s) deliberately LOOSER than the budget
        // (250 ms): the budget is the binding constraint here.
        readTimeout: const Duration(seconds: 10),
        unionBudget: const Duration(milliseconds: 250),
        maxFetchDays: 42,
      );
      sw.stop();
      // ignore: avoid_print
      print('parallel budget-cap: elapsed=${sw.elapsedMilliseconds}ms');
      expect(union.failedMetrics, HistoryMetric.values.toSet());
      expect(union.failureDetails.values.toSet(),
          {'UnionBudgetExhausted'});
      expect(union.sleepMinutes, isNotEmpty,
          reason: 'store data still surfaces for abandoned metrics');
      expect(sw.elapsed, greaterThan(const Duration(milliseconds: 240)));
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });

  group('Item A — bounded post-union availability probe', () {
    test(
        'wedged probe: collection completes inside the probe '
        'bound with grant-UNKNOWN (error) states — never stale, '
        'never permissionDenied — and the probe ran exactly once',
        () async {
      final store = await emptyStore();
      final hc = ProbeHc(wedgeProbe: true);
      final collector = makeCollector(
        hc: hc,
        store: store,
        availabilityProbeTimeout: const Duration(milliseconds: 200),
      );
      final sw = Stopwatch()..start();
      final snapshot = await collector.collect(
        selectedCategories: reproCategories,
        last30Days: false,
        profile: founderProfile(),
        now: reproNow,
      );
      sw.stop();
      // ignore: avoid_print
      print('wedged probe: elapsed=${sw.elapsedMilliseconds}ms '
          'probeCalls=${hc.probeCalls}');
      // The whole collect finished in seconds, not at the 120 s
      // F4 deadline: the probe cost its 200 ms bound, once.
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      expect(hc.probeCalls, 1,
          reason: 'one memoized probe per collect, however many '
              'metrics consult it');
      // Every HC section failed its read with no surviving data
      // and the grant layer is UNKNOWN: the honest derivation is
      // error for all six — the SecurityException detail must NOT
      // be promoted to stale, and no denial may be claimed.
      for (final key
          in ['sleep', 'deepSleep', 'heartRate', 'hrv', 'calories', 'hrSpikes']) {
        expect(snapshot.sectionMetadata[key]!.status,
            DataSourceStatus.error,
            reason: '$key: grant unknown → error');
      }
    });

    test(
        'healthy probe: behavior unchanged — the confirmed full '
        'grant + SecurityException reads derive stale, exactly '
        'as Phase 1/2 semantics pin', () async {
      final store = await emptyStore();
      final hc = ProbeHc(wedgeProbe: false);
      final collector = makeCollector(
        hc: hc,
        store: store,
        availabilityProbeTimeout: const Duration(seconds: 5),
      );
      final snapshot = await collector.collect(
        selectedCategories: reproCategories,
        last30Days: false,
        profile: founderProfile(),
        now: reproNow,
      );
      expect(hc.probeCalls, 1);
      for (final key
          in ['sleep', 'deepSleep', 'heartRate', 'hrv', 'calories', 'hrSpikes']) {
        expect(snapshot.sectionMetadata[key]!.status, DataSourceStatus.stale,
            reason: '$key: known full grant + own-read '
                'SecurityException → stale');
      }
    });
  });
}
