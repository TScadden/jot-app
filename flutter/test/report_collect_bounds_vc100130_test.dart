// VC 100130 (Round 2) — collect-bounds + diagnostic-record
// regression suite (Mason).
//
// Root cause (proven in ~/workspace/mega-100127/round2-mason-repro.md
// against the OLD wiring): the five sequential, individually
// unbounded HC bridge reads inside ReportDataCollector.collect
// summed past the 120 s F4 deadline at founder scale →
// ReportCollectionTimeout → banner, zero AI attempts, and a
// journal record with no stage or cause. The Round-A repro case
// from that investigation is ported here as the first collector
// test: the same founder shape and heavy-band delays, scaled to
// the new 42-day fresh-fetch cap, now complete on the fixed code.
//
// The fix under test:
//  - per-read bound (readTimeout) in the union loaders — a wedged
//    read fails its metric solo with the class-only detail
//    'TimeoutException' (Juno J1);
//  - a union soft budget — loaders not yet started when the
//    budget is exhausted are skipped with the class-style token
//    'UnionBudgetExhausted' and surface over store data;
//  - the collector wires readTimeout = 30 s (the HC service's own
//    readTimeout), unionBudget = 90 s, maxFetchDays = 42 (the
//    report window stays 180 days of STORE data; HC retention is
//    weeks, the store carries the rest);
//  - the diagnostic record: ReportFailed.failureKind/failureStage
//    → journal failureKindName/failureStageName → ONE Juno-ruled
//    plain-language line (R6-1/R6-2) in the Details expansion,
//    after any AI attempt lines. Stage names are never rendered.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/clinician_report.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/report_generation_journal.dart';
import 'package:tabs_lab/src/data/report_generation_service.dart';

import 'report_collect_bounds_harness.dart';

/// The heavy-band founder model scaled to the 42-day fetch cap
/// and divided by 100 for test time (production seconds in
/// comments): spikes ≈18 s, HRV ≈22 s, sleep ≈7 s, resting HR
/// ≈3 s, calories ≈2 s — sum ≈52 s, every read < 30 s, sum <
/// 90 s union budget. At test scale: 180/220/70/30/20 ms against
/// a 300 ms read bound and a 900 ms union budget.
const heavyAt42 = BridgeCost(
  perPageSec: 0.010,
  chunkSetupSec: 0.001,
  aggregateSec: 0.020,
  spikesPagesPerChunk: 3,
  hrvPagesPerChunk: 4,
);

/// Records the fetch depth every read was asked for.
class RecordingHc extends ModelHc {
  RecordingHc(super.cost);
  final List<int> requestedDays = [];

  @override
  Future<HcReadOutcome<List<({String date, int bpm})>>>
      readRestingHrHistoryWithOutcome(int days) {
    requestedDays.add(days);
    return super.readRestingHrHistoryWithOutcome(days);
  }

  @override
  Future<HcReadOutcome<List<({String date, int mins, int deep})>>>
      readSleepHistoryWithOutcome(int days) {
    requestedDays.add(days);
    return super.readSleepHistoryWithOutcome(days);
  }

  @override
  Future<HcReadOutcome<List<({String date, int kcal})>>>
      readCaloriesHistoryWithOutcome(int days) {
    requestedDays.add(days);
    return super.readCaloriesHistoryWithOutcome(days);
  }

  @override
  Future<HcReadOutcome<List<({String date, int count})>>>
      readSpikeCountsWithOutcome(int days) {
    requestedDays.add(days);
    return super.readSpikeCountsWithOutcome(days);
  }

  @override
  Future<HcReadOutcome<List<({int t, double ms, int tier})>>>
      readHrvSamplesWithOutcome(int days) {
    requestedDays.add(days);
    return super.readHrvSamplesWithOutcome(days);
  }
}

/// HC fake whose named reads never complete (a wedged bridge).
class WedgeHc extends ModelHc {
  WedgeHc(this.wedged) : super(scaled(lightCost, 0.01));
  final Set<String> wedged;

  Future<HcReadOutcome<T>> _never<T>() =>
      Completer<HcReadOutcome<T>>().future;

  @override
  Future<HcReadOutcome<List<({String date, int bpm})>>>
      readRestingHrHistoryWithOutcome(int days) => wedged.contains('restingHr')
          ? _never()
          : super.readRestingHrHistoryWithOutcome(days);

  @override
  Future<HcReadOutcome<List<({String date, int mins, int deep})>>>
      readSleepHistoryWithOutcome(int days) => wedged.contains('sleep')
          ? _never()
          : super.readSleepHistoryWithOutcome(days);

  @override
  Future<HcReadOutcome<List<({String date, int kcal})>>>
      readCaloriesHistoryWithOutcome(int days) => wedged.contains('calories')
          ? _never()
          : super.readCaloriesHistoryWithOutcome(days);

  @override
  Future<HcReadOutcome<List<({String date, int count})>>>
      readSpikeCountsWithOutcome(int days) => wedged.contains('spikes')
          ? _never()
          : super.readSpikeCountsWithOutcome(days);

  @override
  Future<HcReadOutcome<List<({int t, double ms, int tier})>>>
      readHrvSamplesWithOutcome(int days) => wedged.contains('hrv')
          ? _never()
          : super.readHrvSamplesWithOutcome(days);
}

/// Backend whose sync pull never completes — a backend-stage hang
/// for the F4 umbrella regression (collection as a whole exceeds
/// its deadline outside the HC union entirely).
class HangBackend extends ReproBackend {
  @override
  Future<Map<String, dynamic>?> fetchSyncPull() =>
      Completer<Map<String, dynamic>?>().future;
}

ReportDataCollector makeCollector({
  required ModelHc hc,
  required HealthHistoryStore store,
  ReproBackend? backend,
  Duration? collectTimeout,
}) {
  return ReportDataCollector(
    backend: backend ?? ReproBackend(),
    hc: hc,
    historyQueries: HealthHistoryQueries(hc: hc, store: store),
    documentsLoader: () async => const ['doc one'],
    insightsLoader: () async => const [],
    collectTimeout: collectTimeout,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('union bounds (HealthHistoryQueries)', () {
    test(
        'heavy-band founder model at the 42d cap completes fresh, '
        'NO metric failed', () async {
      final store = await seededStore();
      final hc = RecordingHc(heavyAt42);
      final queries = HealthHistoryQueries(hc: hc, store: store);
      final sw = Stopwatch()..start();
      final union = await queries.loadDays(
        180,
        end: reproNow,
        metrics: HistoryMetric.values.toSet(),
        readTimeout: const Duration(milliseconds: 300),
        unionBudget: const Duration(milliseconds: 900),
        maxFetchDays: 42,
      );
      sw.stop();
      // ignore: avoid_print
      print('heavy@42: rhr=${heavyAt42.restingHr.inMilliseconds}ms '
          'sleep=${heavyAt42.sleep.inMilliseconds}ms '
          'cal=${heavyAt42.calories.inMilliseconds}ms '
          'spikes=${heavyAt42.spikes.inMilliseconds}ms '
          'hrv=${heavyAt42.hrv.inMilliseconds}ms '
          'elapsed=${sw.elapsedMilliseconds}ms days=${hc.requestedDays}');
      expect(union.failedMetrics, isEmpty);
      expect(union.failureDetails, isEmpty);
      // The fresh scan was capped at 42 days for every read.
      expect(hc.requestedDays, [42, 42, 42, 42, 42]);
      // Fresh data for every metric.
      expect(union.restingHr, isNotEmpty);
      expect(union.sleepMinutes, isNotEmpty);
      expect(union.calories, isNotEmpty);
      expect(union.spikes, isNotEmpty);
      expect(union.hrv, isNotEmpty);
      // The budget semantics are proven above (no loader was
      // skipped: failedMetrics is empty, and every loader started
      // before the 900 ms budget). Total elapsed additionally
      // carries Dart-side processing (32k HRV samples), so it is
      // asserted only as a loose sanity bound for slow CI.
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('default wiring is unchanged: no bounds, 180d cap',
        () async {
      final store = await seededStore();
      final hc = RecordingHc(scaled(lightCost, 0.01));
      final queries = HealthHistoryQueries(hc: hc, store: store);
      final union = await queries.loadDays(
        180,
        end: reproNow,
        metrics: HistoryMetric.values.toSet(),
      );
      expect(union.failedMetrics, isEmpty);
      expect(hc.requestedDays, [180, 180, 180, 180, 180]);
    });

    test(
        'single wedged read fails solo at the read bound, with the '
        'class-only TimeoutException detail; the union completes on '
        'store data', () async {
      final store = await seededStore();
      final hc = WedgeHc({'hrv'});
      final queries = HealthHistoryQueries(hc: hc, store: store);
      final sw = Stopwatch()..start();
      final union = await queries.loadDays(
        180,
        end: reproNow,
        metrics: HistoryMetric.values.toSet(),
        readTimeout: const Duration(milliseconds: 200),
        unionBudget: const Duration(seconds: 5),
        maxFetchDays: 42,
      );
      sw.stop();
      expect(union.failedMetrics, {HistoryMetric.hrv});
      // J1: the detail is EXACTLY the class-style token — never
      // the raw TimeoutException string with its message.
      expect(union.failureDetails[HistoryMetric.hrv],
          'TimeoutException');
      // The wedged metric still surfaces store data; the others
      // are fresh.
      expect(union.hrv, isNotEmpty);
      expect(union.sleepMinutes, isNotEmpty);
      expect(union.spikes, isNotEmpty);
      expect(sw.elapsed, greaterThan(const Duration(milliseconds: 190)));
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test(
        'multi-wedge: every read wedged returns from the union by '
        'ONE read bound, every metric failed on its OWN timeout, '
        'store data kept', () async {
      final store = await seededStore();
      final hc = WedgeHc(
          {'restingHr', 'sleep', 'calories', 'spikes', 'hrv'});
      final queries = HealthHistoryQueries(hc: hc, store: store);
      final sw = Stopwatch()..start();
      final union = await queries.loadDays(
        180,
        end: reproNow,
        metrics: HistoryMetric.values.toSet(),
        // Production shape at test scale: 30 s read bound, 90 s
        // budget ÷ 150 → 200 ms / 600 ms.
        readTimeout: const Duration(milliseconds: 200),
        unionBudget: const Duration(milliseconds: 600),
        maxFetchDays: 42,
      );
      sw.stop();
      expect(union.failedMetrics, HistoryMetric.values.toSet());
      // VC 100133 (Phase 5 parallel reads) SUPERSEDES the VC
      // 100130 sequential expectation below: the loaders used to
      // run one at a time, so three reads timed out in sequence
      // (200 + 200 + 200 ms) and the budget check then SKIPPED
      // the remaining loaders with 'UnionBudgetExhausted'
      // (expected return ≈600 ms, details mixed
      // TimeoutException + UnionBudgetExhausted). In parallel
      // every loader starts at once, so every wedged read meets
      // its OWN 30 s-class bound concurrently: the truthful
      // detail for all five is 'TimeoutException', the return is
      // ≈ one read bound, and the budget token now fires only
      // when the budget is the tighter bound (pinned in
      // report_hardening_vc100133_test.dart).
      expect(union.failureDetails.values.toSet(), {'TimeoutException'});
      // Store data still surfaces for the failed metrics.
      expect(union.sleepMinutes, isNotEmpty);
      expect(union.restingHr, isNotEmpty);
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 1000)),
          reason: 'the parallel union returns by ~one read bound, '
              'not 5× it and not the full budget');
      expect(sw.elapsed,
          greaterThan(const Duration(milliseconds: 190)));
    });
  });

  group('collector wiring + Round-A port', () {
    test(
        'ROUND-A PORT: founder-heavy collect at the 42d cap '
        'completes and the pipeline reaches the AI leg (the same '
        'shape/timing family timed out on the OLD wiring — see '
        'round2-mason-repro.md run A)', () async {
      final store = await seededStore();
      final hc = RecordingHc(heavyAt42);
      final backend = ReproBackend();
      final collector = makeCollector(hc: hc, store: store, backend: backend);
      var aiCalls = 0;
      final pipeline = ReportGenerationPipeline(
        collector: collector,
        backend: backend,
        aiCall: (body) async {
          aiCalls++;
          return (
            statusCode: 200,
            body: {'result': '[SECTION] SUMMARY\nok'},
            serverError: null,
            transportFailure: null,
          );
        },
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
      expect(aiCalls, 1);
      // The collector capped every fresh read at 42 days while
      // the snapshot still spans the full founder shape.
      expect(hc.requestedDays, [42, 42, 42, 42, 42]);
      final ready = outcome as ReportReady;
      expect(ready.snapshot.logEntries.length, 539);
      expect(ready.snapshot.sleepSeries, isNotEmpty);
      expect(ready.snapshot.hrvSeries, isNotEmpty);
    });

    test(
        'F4 REGRESSION: a backend-stage hang still fires the 120 s '
        'umbrella (here at test scale) — collect throws '
        'ReportCollectionTimeout and the pipeline maps it with '
        'kind=collectionTimeout, stage=collecting', () async {
      final store = await seededStore();
      final hc = ModelHc(scaled(lightCost, 0.01));
      final backend = HangBackend();
      final collector = makeCollector(
        hc: hc,
        store: store,
        backend: backend,
        collectTimeout: const Duration(milliseconds: 300),
      );
      await expectLater(
        collector.collect(
          selectedCategories: reproCategories,
          last30Days: false,
          profile: founderProfile(),
          now: reproNow,
        ),
        throwsA(isA<ReportCollectionTimeout>()),
      );
      final pipeline = ReportGenerationPipeline(
        collector: collector,
        backend: backend,
        aiCall: (body) async => (
          statusCode: 200,
          body: {'result': 'x'},
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
            [1],
        savePdf: (bytes, name) async => '/tmp/$name',
      );
      expect(outcome, isA<ReportFailed>());
      final failed = outcome as ReportFailed;
      expect(failed.message, reportExportFailureMessage);
      expect(failed.failureKind, ReportFailureKind.collectionTimeout);
      expect(failed.failureStage, ReportStage.collecting);
    });

    test(
        'clinician pipeline inherits the collector bounds and '
        'records collectionTimeout on a hang', () async {
      final store = await seededStore();
      final hc = ModelHc(scaled(lightCost, 0.01));
      final collector = makeCollector(
        hc: hc,
        store: store,
        backend: HangBackend(),
        collectTimeout: const Duration(milliseconds: 300),
      );
      final pipeline = ClinicianReportPipeline(
        collector: collector,
        clinicianCollector: ClinicianReportCollector(
          scoreLoader: () async => const {},
          eventsLoader: () async => const [],
          categoriesLoader: () async => reproCategories,
        ),
      );
      final outcome = await pipeline.generate(
        selectedCategories: reproCategories,
        last30Days: false,
        profile: founderProfile(),
        now: reproNow,
        renderPdf: (data) async => [1],
        savePdf: (bytes, name) async => '/tmp/$name',
      );
      expect(outcome, isA<ReportFailed>());
      final failed = outcome as ReportFailed;
      expect(failed.failureKind, ReportFailureKind.collectionTimeout);
      expect(failed.failureStage, ReportStage.collecting);
    });
  });

  group('diagnostic record — journal + surface', () {
    Future<ReportGenerationService> serviceOver(
        Map<String, String> mem) async {
      final s = ReportGenerationService(
          journal: ReportGenerationJournal.inMemory(mem));
      await s.restoreSettled;
      return s;
    }

    test(
        'collection timeout: kind+stage persisted with ZERO '
        'attempts; restored entry exposes them; the Juno line '
        'renders from the record', () async {
      final mem = <String, String>{};
      final service = await serviceOver(mem);
      final store = await seededStore();
      final hc = ModelHc(scaled(lightCost, 0.01));
      final backend = HangBackend();
      final collector = makeCollector(
        hc: hc,
        store: store,
        backend: backend,
        collectTimeout: const Duration(milliseconds: 300),
      );
      final pipeline = ReportGenerationPipeline(
        collector: collector,
        backend: backend,
        delay: (_) async {},
      );
      await service.start(
        ({required onStage, required isCancelled}) => pipeline.generate(
          selectedCategories: reproCategories,
          last30Days: false,
          profile: founderProfile(),
          now: reproNow,
          onStage: onStage,
          isCancelled: isCancelled,
          renderPdf: (snap, summary,
                  {required isRawFallback, rawBanner}) async =>
              [1],
          savePdf: (bytes, name) async => '/tmp/$name',
        ),
        request: const ReportRequestIdentity(
          kind: 'standard',
          focusKey: 'health',
          last30Days: false,
          categoryIds: [1, 2, 3, 4, 5],
        ),
      );
      final entry = service.journalEntry!;
      expect(entry.outcomeKind, JournalOutcomeKind.failed);
      expect(entry.attempts, isEmpty);
      expect(entry.failureKindName, 'collectionTimeout');
      expect(entry.failureStageName, 'collecting');
      expect(entry.stage, isNull,
          reason: 'the live stage clears at finish; the failure '
              'stage is the permanent record');
      final expectedLine =
          'Collecting your report data took too long, so the '
          'report stopped · ${journalTimeText(entry.finishedAt!)}';
      expect(service.displayFailureLines, [expectedLine]);
      expect(service.displayAttemptLines, isEmpty);

      // Restored after relaunch: same record, same one line.
      final restored = await serviceOver(mem);
      expect(restored.journalEntry?.failureKindName, 'collectionTimeout');
      expect(restored.journalEntry?.failureStageName, 'collecting');
      expect(restored.pendingFailure, isNotNull);
      expect(restored.displayFailureLines, [expectedLine]);
    });

    test(
        'render failure through the real pipeline: kind/stage '
        'recorded and the Juno render line shown', () async {
      final mem = <String, String>{};
      final service = await serviceOver(mem);
      final store = await seededStore();
      final hc = ModelHc(scaled(lightCost, 0.01));
      final backend = ReproBackend();
      final collector = makeCollector(hc: hc, store: store, backend: backend);
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
      await service.start(
        ({required onStage, required isCancelled}) => pipeline.generate(
          selectedCategories: reproCategories,
          last30Days: false,
          profile: founderProfile(),
          now: reproNow,
          forceRawFallback: true,
          onStage: onStage,
          isCancelled: isCancelled,
          renderPdf: (snap, summary,
                  {required isRawFallback, rawBanner}) async =>
              throw StateError('render boom'),
          savePdf: (bytes, name) async => '/tmp/$name',
        ),
        request: const ReportRequestIdentity(
          kind: 'standard',
          focusKey: 'health',
          last30Days: false,
          categoryIds: [1, 2, 3, 4, 5],
        ),
      );
      final entry = service.journalEntry!;
      expect(entry.failureKindName, 'renderFailure');
      expect(entry.failureStageName, 'renderingPdf');
      expect(service.displayFailureLines, [
        'Something went wrong while creating the PDF file · '
            '${journalTimeText(entry.finishedAt!)}',
      ]);
    });

    test(
        'save failure at the pipeline seam: kind=saveFailure, '
        'stage=savingFile', () async {
      final store = await seededStore();
      final hc = ModelHc(scaled(lightCost, 0.01));
      final backend = ReproBackend();
      final collector = makeCollector(hc: hc, store: store, backend: backend);
      final pipeline = ReportGenerationPipeline(
        collector: collector,
        backend: backend,
        delay: (_) async {},
      );
      final outcome = await pipeline.generate(
        selectedCategories: reproCategories,
        last30Days: false,
        profile: founderProfile(),
        now: reproNow,
        forceRawFallback: true,
        renderPdf: (snap, summary,
                {required isRawFallback, rawBanner}) async =>
            [1],
        savePdf: (bytes, name) async => throw StateError('disk full'),
      );
      expect(outcome, isA<ReportFailed>());
      final failed = outcome as ReportFailed;
      expect(failed.failureKind, ReportFailureKind.saveFailure);
      expect(failed.failureStage, ReportStage.savingFile);
    });

    test(
        'service catch-all maps the CURRENT stage (R6-2): a '
        'renderingPdf escape records renderFailure', () async {
      final mem = <String, String>{};
      final service = await serviceOver(mem);
      await service.start(({required onStage, required isCancelled}) async {
        onStage(ReportStage.renderingPdf);
        throw StateError('escape');
      });
      final entry = service.journalEntry!;
      expect(entry.failureKindName, 'renderFailure');
      expect(entry.failureStageName, 'renderingPdf');
      expect(service.displayFailureLines, [
        'Something went wrong while creating the PDF file · '
            '${journalTimeText(entry.finishedAt!)}',
      ]);
    });

    test(
        'service catch-all maps syncing → collectionFailure with '
        'the Juno collection line', () async {
      final mem = <String, String>{};
      final service = await serviceOver(mem);
      await service.start(({required onStage, required isCancelled}) async {
        onStage(ReportStage.syncing);
        throw StateError('escape');
      });
      final entry = service.journalEntry!;
      expect(entry.failureKindName, 'collectionFailure');
      expect(entry.failureStageName, 'syncing');
      expect(service.displayFailureLines, [
        'Something went wrong while collecting your report data · '
            '${journalTimeText(entry.finishedAt!)}',
      ]);
    });

    test(
        'service catch-all at buildingSummary records NO kind and '
        'shows NO non-AI line (the AI attempt records govern)',
        () async {
      final mem = <String, String>{};
      final service = await serviceOver(mem);
      await service.start(({required onStage, required isCancelled}) async {
        onStage(ReportStage.buildingSummary);
        throw StateError('escape');
      });
      final entry = service.journalEntry!;
      expect(entry.outcomeKind, JournalOutcomeKind.failed);
      expect(entry.failureKindName, isNull);
      expect(entry.failureStageName, isNull);
      expect(service.displayFailureLines, isEmpty);
      expect(service.pendingFailure?.failureKind, isNull);
    });

    test('Juno R6-1 line format: verbatim bases, time suffix, '
        'missing-time and unknown-kind rules', () {
      final at = DateTime(2026, 11, 13, 10, 52);
      expect(
        reportFailureDetailLine('collectionTimeout', finishedAt: at),
        'Collecting your report data took too long, so the '
        'report stopped · 10:52 AM',
      );
      expect(
        reportFailureDetailLine('collectionFailure', finishedAt: at),
        'Something went wrong while collecting your report data '
        '· 10:52 AM',
      );
      expect(
        reportFailureDetailLine('renderFailure', finishedAt: at),
        'Something went wrong while creating the PDF file · 10:52 AM',
      );
      expect(
        reportFailureDetailLine('saveFailure', finishedAt: at),
        'Something went wrong while saving the PDF file · 10:52 AM',
      );
      // No recorded finish time → the base line alone.
      expect(
        reportFailureDetailLine('saveFailure'),
        'Something went wrong while saving the PDF file',
      );
      // No kind / unknown kind → no line, ever.
      expect(reportFailureDetailLine(null, finishedAt: at), isNull);
      expect(reportFailureDetailLine('buildingSummary', finishedAt: at),
          isNull);
    });
  });
}
