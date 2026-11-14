// VC 100133 Phase 6 — PDF fixture sweep on founder-real shapes.
//
// Drives the shapes in fixtures/report_founder_fixtures.dart
// through BOTH report surfaces (the standard collector → snapshot →
// payload / health summary / charts / PDF, and the clinician
// collector → Z1–Z8 line zones → one-page PDF) plus the
// interruption set (slow reads, a wedged read, a wedged backend
// stage, cancel mid-collection). Every count asserted here is the
// verified founder count, derived from the fixture's stated rules
// — the defect classes of VC 100129–100132 (deadline overrun on
// instant fixtures, "Available (0 records)", BP count vs chart
// disagreement, partial coverage framed as full coverage,
// stored-only truth, zero-entry categories, clean-empty vs
// unproven-empty) each have a shape that can SEE them.
//
// If a case here fails on a REAL lib/ defect, the package rule is:
// record it as a finding — do not weaken the fixture to pass.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/clinician_report.dart';
import 'package:tabs_lab/src/data/clinician_report_pdf.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/progress_report_pdf.dart';

import 'fixtures/report_founder_fixtures.dart';

int _pageCount(List<int> bytes) =>
    RegExp(r'/Type\s*/Page(?![s\w])')
        .allMatches(latin1.decode(bytes))
        .length;

List<String> _zoneLines(ClinicianReportData data, String zone) => [
      for (final l in clinicianPageLines(data))
        if (l.zone == zone) l.text,
    ];

Future<ClinicianReportData> _clinicianExtend(ReportSnapshot snap) =>
    ClinicianReportCollector(
      scoreLoader: () async => founderScoreMap(),
      eventsLoader: () async => null, // declared-form Z5 (founder shape)
      categoriesLoader: () async => founderCategories,
    ).extend(snap, allMedications: founderProfile().allMedications);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('full founder shape — standard surface (180 days)', () {
    late ReportSnapshot snap;
    late FounderHc hc;
    late Duration collectElapsed;

    setUp(() async {
      hc = FounderHc();
      final store = await seedFounderStore();
      final sw = Stopwatch()..start();
      snap = await collectFounder(founderCollector(hc: hc, store: store));
      collectElapsed = sw.elapsed;
    });

    test('collect runs at CI speed despite founder volume', () {
      expect(collectElapsed, lessThan(const Duration(seconds: 10)),
          reason: 'founder shape must stay CI-sane; was $collectElapsed');
    });

    test('every section carries its verified founder count', () {
      final m = snap.sectionMetadata;
      void expectSection(String key, DataSourceStatus status, int count) {
        expect(m[key]!.status, status, reason: '$key status');
        expect(m[key]!.recordCount, count, reason: '$key count');
      }

      expectSection('logs', DataSourceStatus.success, founderEntryTotal);
      expectSection(
          'dailyScore', DataSourceStatus.success, founderScoreDays180);
      expectSection('conditions', DataSourceStatus.success, 3);
      expectSection(
          'medications', DataSourceStatus.success, founderActiveMedCount);
      expectSection('documents', DataSourceStatus.success, 7);
      expectSection('bloodPressure', DataSourceStatus.success, 4);
      expectSection('sleep', DataSourceStatus.success, founderSleepDays);
      expectSection('deepSleep', DataSourceStatus.success, founderDeepDays);
      expectSection('heartRate', DataSourceStatus.success, founderHrDays);
      expectSection('hrv', DataSourceStatus.success, founderHrvDays);
      expectSection(
          'calories', DataSourceStatus.success, founderCaloriesDays);
      expectSection('hrSpikes', DataSourceStatus.success, founderSpikeDaysFull);
      expect(m.length, 12, reason: 'the canonical 12 sections, no more');
    });

    test('availability counts EQUAL the series they describe '
        '(the VC 100132 count-vs-chart class)', () {
      final m = snap.sectionMetadata;
      expect(snap.logEntries.length, m['logs']!.recordCount);
      expect(snap.dailyScoreSeries.length, m['dailyScore']!.recordCount);
      expect(snap.bloodPressureSeries.length,
          m['bloodPressure']!.recordCount);
      expect(snap.sleepSeries.length, m['sleep']!.recordCount);
      expect(snap.deepSleepSeries.length, m['deepSleep']!.recordCount);
      expect(snap.heartRateSeries.length, m['heartRate']!.recordCount);
      expect(snap.hrvSeries.length, m['hrv']!.recordCount);
      expect(snap.caloriesSeries.length, m['calories']!.recordCount);
      expect(snap.heartRateSpikes.length, m['hrSpikes']!.recordCount);
      // And the charts consume the same series:
      final page1 = chartPage1Series(snap);
      expect(page1[0].points.length, founderSleepDays, reason: 'sleep chart');
      expect(page1[1].points.length, founderHrDays, reason: 'HR chart');
      expect(page1[2].points.length, founderHrvDays, reason: 'HRV chart');
      expect(page1[3].points.length, m['bloodPressure']!.recordCount,
          reason: 'systolic chart points == BP availability count');
      final page2 = chartPage2Series(snap);
      expect(page2[0].points.length, founderCaloriesDays);
      expect(
          page2[1].points.length,
          [for (var ago = 0; ago < 180; ago++) ago]
              .where((ago) => founderSpikeValue(ago) > 0)
              .length,
          reason: 'spike chart drops only the real zero-count days');
    });

    test('no "Available (0 records)" anywhere; payload is founder-scale',
        () {
      final availability = buildDataAvailability(snap);
      expect(availability, isNot(contains('Available (0 records)')));
      expect(availability,
          contains('DailyScore: Available ($founderScoreDays180 records)'));
      expect(availability, contains('BloodPressure: Available (4 records)'));
      expect(availability,
          contains('Logs: Available ($founderEntryTotal records)'));

      final payload = buildAiReportRequest(snap);
      expect((payload['entries'] as List).length, founderEntryTotal);
      expect((payload['knowledgeBase'] as String).length,
          founderKnowledgeChars + 12,
          reason: '7 docs joined by blank lines ≈ 70K chars');
      final meds = payload['medications'] as List;
      expect(meds.length, 6,
          reason: '5 active + 1 archived; the deleted row never ships');
      final ivabradine =
          meds.singleWhere((m) => (m as Map)['name'] == 'Ivabradine') as Map;
      expect(ivabradine['frequency'], '',
          reason: 'blank stored frequency stays blank (never fabricated)');
    });

    test('health summary frames every total by its true coverage', () {
      final summary = buildHealthSummary(snap);
      final spikeTotal = [
        for (var ago = 0; ago < 180; ago++) founderSpikeValue(ago),
      ].fold<int>(0, (a, c) => a + c);
      expect(
          summary,
          contains('Total HR Spikes: $spikeTotal recorded across 180 days '
              '(${founderKey(179)} to ${founderKey(0)}).'));
      expect(summary, contains('across 4 readings'));
      expect(summary,
          contains('Daily Score: average'), );
      expect(summary, contains('across $founderScoreDays180 days'));
    });

    test('fresh reads are capped at the 42-day scan (VC 100130 bound)',
        () {
      expect(hc.requestedDays, hasLength(5));
      expect(hc.requestedDays, everyElement(42));
    });

    test('standard PDF renders at founder volume', () async {
      final bytes = await buildReportPdfBytes(snap, isRawFallback: true);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(_pageCount(bytes), greaterThanOrEqualTo(3));
    });
  });

  group('full founder shape — clinician surface (Z1–Z8)', () {
    late ClinicianReportData data;

    setUp(() async {
      final store = await seedFounderStore();
      final snap =
          await collectFounder(founderCollector(hc: FounderHc(), store: store));
      data = await _clinicianExtend(snap);
    });

    test('Z2 prints the founder meds; blank frequency prints no '
        'fabricated frequency', () {
      final z2 = _zoneLines(data, 'Z2');
      expect(z2, contains('Ivabradine 7.5 mg'));
      expect(z2.join(' '), isNot(contains('Ivabradine 7.5 mg (')));
      expect(z2, contains('Desvenlafaxine 50 mg (Once daily)'));
      expect(z2, contains('MOTS-c 0.10 (Once daily)'));
      expect(z2.length, 1 + founderActiveMedCount);
    });

    test('Z3 states the real 180-day score coverage', () {
      expect(
          _zoneLines(data, 'Z3'),
          contains('Daily Score recorded on $founderScoreDays180 of 180 '
              'days in this range.'));
    });

    test('Z4 top categories are the founder counts; the zero-entry '
        'category never appears', () {
      final z4 = _zoneLines(data, 'Z4').join(' ');
      expect(z4, contains('Notes (331)'));
      expect(z4, contains('Symptoms (205)'));
      expect(z4, contains('Medication (187)'));
      expect(z4, isNot(contains('Weight & Vitals')));
    });

    test('Z5 carries the declared stop; Z8 tells no falsehood', () {
      expect(_zoneLines(data, 'Z5').join(' '), contains('Stopped Escitalopram'));
      final all = clinicianPageLines(data).map((l) => l.text).join('\n');
      expect(all, isNot(contains('Available (0 records)')));
      expect(all, isNot(contains('Permission not granted')));
      expect(_zoneLines(data, 'Z8').join(' '),
          isNot(contains('Unavailable')));
    });

    test('clinician PDF stays exactly one page at founder volume',
        () async {
      final bytes = await buildClinicianPdfBytes(data);
      expect(_pageCount(bytes), 1);
    });

    // RECOVERY ADDITION (Sable, VC 100133): the inherited draft
    // covered Z2/Z3/Z4/Z5/Z8 only. The zones below are the rest of
    // the clinician page — each carries a founder count that the
    // synthetic clinician fixtures (2–3-day series) could not
    // distinguish from a toy count.
    test('Z1 header carries the founder profile, not a placeholder',
        () {
      final z1 = _zoneLines(data, 'Z1').join('\n');
      expect(z1, contains('Tabs Clinician Report'));
      expect(z1, contains('Age 22'));
      expect(z1, contains('Conditions: POTS, MCAS, hEDS'));
      expect(z1, isNot(contains('not recorded')));
    });

    test('Z9/Z10/Z11 biometric zones state the founder day counts',
        () {
      final z9 = _zoneLines(data, 'Z9');
      expect(z9.length, 3, reason: 'heading + duration + deep lines');
      expect(z9[1], contains('across $founderSleepDays days'));
      expect(z9[2], contains('across $founderDeepDays days'));
      final z10 = _zoneLines(data, 'Z10');
      expect(z10.length, 2, reason: 'heading + HRV line');
      expect(z10[1], contains('across $founderHrvDays days'));
      final z11 = _zoneLines(data, 'Z11');
      expect(z11.length, 3, reason: 'heading + HR + spikes lines');
      expect(z11[1], contains('across $founderHrDays days'));
      final spikeTotal = [
        for (var ago = 0; ago < 180; ago++) founderSpikeValue(ago),
      ].fold<int>(0, (a, c) => a + c);
      expect(z11[2],
          contains('$spikeTotal recorded across $founderSpikeDaysFull days'));
    });

    test('Z12 states no patterns (the founder store holds none); '
        'reserved Z6/Z7 render nothing', () {
      expect(_zoneLines(data, 'Z12'),
          contains('No patterns detected for this period'));
      final zones = clinicianPageLines(data).map((l) => l.zone).toSet();
      expect(zones, isNot(contains('Z6')));
      expect(zones, isNot(contains('Z7')));
      expect(
          zones,
          containsAll([
            'Z1', 'Z2', 'Z3', 'Z4', 'Z5',
            'Z8', 'Z9', 'Z10', 'Z11', 'Z12',
          ]),
          reason: 'all 10 active clinician zones render at founder shape');
    });
  });

  group('founder 30-day slice — the 24-of-30 score truth', () {
    test('standard + clinician agree on 24 of 30', () async {
      final store = await seedFounderStore();
      final snap = await collectFounder(
          founderCollector(hc: FounderHc(), store: store),
          last30Days: true);
      expect(snap.sectionMetadata['dailyScore']!.status,
          DataSourceStatus.success);
      expect(snap.sectionMetadata['dailyScore']!.recordCount,
          founderScoreDays30);
      expect(snap.dailyScoreSeries.length, founderScoreDays30);
      // The collector fetches a 31-day HC window for a 30-day
      // report; the union series is that window's truth.
      final expectedSleep31 = [
        for (var ago = 0; ago <= 30; ago++) ago,
      ].where(founderHasSleep).length;
      expect(snap.sleepSeries.length, expectedSleep31);
      expect(snap.sectionMetadata['sleep']!.recordCount, expectedSleep31);

      final data = await _clinicianExtend(snap);
      expect(
          _zoneLines(data, 'Z3'),
          contains('Daily Score recorded on $founderScoreDays30 of 30 '
              'days in this range.'));
    });
  });

  group('partial-coverage shape — spikes 42 of 180 (VC 100132)', () {
    late ReportSnapshot snap;

    setUp(() async {
      final store = await seedFounderStore(partialSpikes: true);
      snap = await collectFounder(
          founderCollector(hc: FounderHc(), store: store));
    });

    test('spike section reports 42 while siblings report ~180', () {
      final m = snap.sectionMetadata;
      expect(m['hrSpikes']!.status, DataSourceStatus.success);
      expect(m['hrSpikes']!.recordCount, founderSpikeDaysPartial);
      expect(snap.heartRateSpikes.length, founderSpikeDaysPartial);
      expect(snap.heartRateSpikes.first.$1, founderKey(41));
      expect(snap.heartRateSpikes.last.$1, founderKey(0));
      expect(m['sleep']!.recordCount, founderSleepDays);
      expect(m['heartRate']!.recordCount, founderHrDays);
      expect(buildDataAvailability(snap),
          contains('HrSpikes: Available ($founderSpikeDaysPartial records)'));
    });

    test('the spike total is framed by the 42 covered days, never '
        'as a 180-day total', () {
      final summary = buildHealthSummary(snap);
      expect(
          summary,
          contains('recorded across $founderSpikeDaysPartial days '
              '(${founderKey(41)} to ${founderKey(0)}).'));
      expect(summary, isNot(contains('across 180 days (${founderKey(179)}')));
      final page2 = chartPage2Series(snap);
      expect(
          page2[1].points.length,
          [for (var ago = 0; ago < 42; ago++) ago]
              .where((ago) => founderSpikeValue(ago) > 0)
              .length);
    });

    test('both PDFs render on the partial shape', () async {
      final bytes = await buildReportPdfBytes(snap, isRawFallback: true);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      final clinician = await _clinicianExtend(snap);
      expect(_pageCount(await buildClinicianPdfBytes(clinician)), 1);
    });

    test('clinician Z11 frames the spike total by the 42 covered '
        'days too (the framing rule binds BOTH surfaces)', () async {
      final clinician = await _clinicianExtend(snap);
      final z11 = _zoneLines(clinician, 'Z11');
      final spikeTotal42 = [
        for (var ago = 0; ago < 42; ago++) founderSpikeValue(ago),
      ].fold<int>(0, (a, c) => a + c);
      expect(
          z11[2],
          contains(
              '$spikeTotal42 recorded across $founderSpikeDaysPartial days'));
      expect(z11[1], contains('across $founderHrDays days'),
          reason: 'the HR line beside it still carries its full 180');
    });
  });

  group('stored-only shapes — fresh reads failed, store carries it', () {
    test('whole-HC stored-only: statuses and counts stay truthful',
        () async {
      final store = await seedFounderStore();
      final snap = await collectFounder(founderCollector(
        hc: FounderHc(failGeneric: {
          'restingHr', 'sleep', 'calories', 'spikes', 'hrv',
        }),
        store: store,
      ));
      final m = snap.sectionMetadata;
      for (final (key, count) in [
        ('sleep', founderSleepDays),
        ('deepSleep', founderDeepDays),
        ('heartRate', founderHrDays),
        ('hrv', founderHrvDays),
        ('calories', founderCaloriesDays),
        ('hrSpikes', founderSpikeDaysFull),
      ]) {
        expect(m[key]!.status, DataSourceStatus.storedOnly, reason: key);
        expect(m[key]!.recordCount, count, reason: key);
      }
      expect(availabilityStatusText(m['sleep']!),
          'Available from stored history ($founderSleepDays records)');
      // The payload availability block carries the success form for
      // stored-only data (its provenance is the PDF list's job).
      expect(buildDataAvailability(snap),
          contains('Sleep: Available ($founderSleepDays records)'));
      final data = await _clinicianExtend(snap);
      expect(_zoneLines(data, 'Z8').join(' '),
          contains('Available from stored history'));
      // The biometric zones still print their real averages on
      // stored-only data (storedOnly is a printable status in the
      // zone resolver) — they must not collapse to Unavailable.
      expect(_zoneLines(data, 'Z9')[1],
          contains('across $founderSleepDays days'));
      expect(_zoneLines(data, 'Z10')[1],
          contains('across $founderHrvDays days'));
      expect(_zoneLines(data, 'Z11')[1],
          contains('across $founderHrDays days'));
    });

    test('one metric stored-only: sleep alone degrades, siblings '
        'stay fresh-success', () async {
      final store = await seedFounderStore();
      final snap = await collectFounder(founderCollector(
        hc: FounderHc(failGeneric: {'sleep'}),
        store: store,
      ));
      final m = snap.sectionMetadata;
      expect(m['sleep']!.status, DataSourceStatus.storedOnly);
      expect(m['sleep']!.recordCount, founderSleepDays);
      expect(m['deepSleep']!.status, DataSourceStatus.storedOnly);
      expect(m['heartRate']!.status, DataSourceStatus.success);
      expect(m['hrv']!.status, DataSourceStatus.success);
      expect(m['calories']!.status, DataSourceStatus.success);
      expect(m['hrSpikes']!.status, DataSourceStatus.success);
    });
  });

  group('zero-entry category shape', () {
    test('the full collect includes the empty category honestly',
        () async {
      final store = await seedFounderStore();
      final snap = await collectFounder(
          founderCollector(hc: FounderHc(), store: store));
      expect(snap.categoriesMap[4], 'Weight & Vitals');
      expect(snap.logEntries.where((e) => e.categoryId == 4), isEmpty);
      expect(snap.sectionMetadata['logs']!.recordCount, founderEntryTotal);
    });

    test('selecting ONLY the zero-entry category still collects '
        '(characterization: the collector range query has no '
        'category filter — native parity, pinned deliberately)',
        () async {
      final store = await seedFounderStore();
      final snap = await collectFounder(
        founderCollector(hc: FounderHc(), store: store),
        selected: [founderCategories[3]],
      );
      expect(snap.logEntries.length, founderEntryTotal);
      expect(snap.categoriesMap, {4: 'Weight & Vitals'});
    });
  });

  group('blood pressure shapes — Juno Ruling 2 states', () {
    test('clean-empty (source parsed, zero readings): noData, the '
        'ruled sentence, no chart points, no summary clause', () async {
      final store = await seedFounderStore();
      final snap = await collectFounder(founderCollector(
        hc: FounderHc(),
        store: store,
        backend: FounderBackend(bp: const [], bpSourceParsed: true),
      ));
      final meta = snap.sectionMetadata['bloodPressure']!;
      expect(meta.status, DataSourceStatus.noData);
      expect(meta.recordCount, 0);
      // The PDF list prints Juno R9-2's ruled clean-empty sentence
      // for BP (Wave 2.5), NOT the generic noData form.
      expect(availabilityStatusText(meta),
          'Unavailable. No manual Blood Pressure readings were recorded for this period.');
      expect(
          buildDataAvailability(snap),
          contains('BloodPressure: Unavailable. '
              'No manual Blood Pressure readings were recorded for this period.'));
      expect(chartPage1Series(snap)[3].points, isEmpty);
      expect(buildHealthSummary(snap), isNot(contains('Blood Pressure')));
      final bytes = await buildReportPdfBytes(snap, isRawFallback: true);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });

    test('unproven-empty (source unparsed): error — a retrieval '
        'statement, never dressed as a clean empty', () async {
      final store = await seedFounderStore();
      final snap = await collectFounder(founderCollector(
        hc: FounderHc(),
        store: store,
        backend: FounderBackend(bp: const [], bpSourceParsed: false),
      ));
      final meta = snap.sectionMetadata['bloodPressure']!;
      expect(meta.status, DataSourceStatus.error);
      expect(
          buildDataAvailability(snap),
          contains('BloodPressure: Unavailable. '
              'Data could not be retrieved.'));
    });
  });

  group('interruption set — latency, wedge, deadline, cancel', () {
    test('slow reads: 100 ms per read still completes inside the '
        'deadline, at full founder counts', () async {
      final store = await seedFounderStore();
      final sw = Stopwatch()..start();
      final snap = await collectFounder(founderCollector(
        hc: FounderHc(perReadDelay: const Duration(milliseconds: 100)),
        store: store,
      ));
      // ignore: avoid_print
      print('slow reads: elapsed=${sw.elapsedMilliseconds}ms');
      // Five union reads × 100 ms of modeled bridge latency, run
      // in PARALLEL since Bram's item B (VC 100133): every loader
      // starts before any is awaited, so the union costs one
      // read's latency, not the sum of five. This pin previously
      // asserted ≥400 ms on the sequential premise — five reads
      // in series cannot cost less than 5 × 100 ms (measured
      // 524 ms at this scale); B superseded that premise, not
      // the protection. The pin now asserts both directions:
      //  - floor ≥100 ms: at least one read's full latency
      //    really elapsed, so the slow path genuinely ran and
      //    was not bypassed — a completed parallel union cannot
      //    beat its own slowest read, and timers never fire
      //    materially early;
      //  - ceiling <300 ms: the reads genuinely overlapped —
      //    ~2.5× the measured parallel collect (116–122 ms),
      //    and decisively under the ≥500 ms sequential floor,
      //    which the old in-series union would fail.
      expect(sw.elapsed,
          greaterThanOrEqualTo(const Duration(milliseconds: 100)));
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 300)));
      expect(snap.sectionMetadata['sleep']!.recordCount, founderSleepDays);
      expect(snap.sectionMetadata['hrSpikes']!.recordCount,
          founderSpikeDaysFull);
    });

    test('wedged spike read: the union bound fails that metric solo '
        'and the store remainder survives', () async {
      final store = await seedFounderStore();
      final queries = HealthHistoryQueries(
          hc: FounderHc(wedged: {'spikes'}), store: store);
      final sw = Stopwatch()..start();
      final union = await queries.loadDays(
        180,
        end: founderNow,
        metrics: HistoryMetric.values.toSet(),
        readTimeout: const Duration(milliseconds: 300),
        unionBudget: const Duration(milliseconds: 900),
        maxFetchDays: 42,
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      expect(union.failed(HistoryMetric.spikes), isTrue);
      expect(union.failureDetails[HistoryMetric.spikes],
          contains('TimeoutException'));
      expect(union.sleepMinutes.length, founderSleepDays);
      expect(union.spikes.length, founderSpikeDaysFull,
          reason: 'store spikes survive the wedged fresh read');
    });

    test('wedged backend stage: the collection deadline fires as '
        'ReportCollectionTimeout, not a hang', () async {
      final store = await seedFounderStore();
      final collector = founderCollector(
        hc: FounderHc(),
        store: store,
        backend: FounderBackend(hangPull: true),
        collectTimeout: const Duration(milliseconds: 400),
      );
      final sw = Stopwatch()..start();
      await expectLater(collectFounder(collector),
          throwsA(isA<ReportCollectionTimeout>()));
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('slow-but-finite backend stage completes — no false '
        'timeout', () async {
      final store = await seedFounderStore();
      final snap = await collectFounder(founderCollector(
        hc: FounderHc(),
        store: store,
        backend:
            FounderBackend(pullDelay: const Duration(milliseconds: 200)),
        collectTimeout: const Duration(seconds: 5),
      ));
      expect(snap.sectionMetadata['logs']!.recordCount, founderEntryTotal);
    });

    test('cancel landing during the slow documents stage stops the '
        'collection before the HC union starts', () async {
      final store = await seedFounderStore();
      final hc = FounderHc();
      var cancelled = false;
      final collector = founderCollector(
        hc: hc,
        store: store,
        documentsLoader: () async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          cancelled = true;
          return founderKnowledgeDocs();
        },
      );
      await expectLater(
        collectFounder(collector, isCancelled: () => cancelled),
        throwsA(isA<ReportCollectionCancelled>()),
      );
      expect(hc.requestedDays, isEmpty,
          reason: 'the union never started after the cancel landed');
    });
  });
}
