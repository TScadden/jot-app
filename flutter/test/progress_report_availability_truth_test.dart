import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/clinician_report.dart';
import 'package:tabs_lab/src/data/clinician_report_pdf.dart';
import 'package:tabs_lab/src/data/correlation_copy.dart';
import 'package:tabs_lab/src/data/correlation_engine.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/progress_report_pdf.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';

import 'test_helpers.dart';

/// Report Reliability Phase 1 — report availability truth.
///
/// The defect at base (ffd58a08): ReportDataCollector gated the
/// whole Health Connect block on hc.isConnected() (all 15 required
/// permissions granted AND a Steps-record probe). Any gate failure
/// flattened all six HC sections to permissionDenied / 0 records
/// with no read attempted and the history store never consulted,
/// and the PDF rendered the false line
/// 'Unavailable. Permission not granted.'
///
/// Each fixture below simulates one trigger the way the real
/// service reports it, and FAILS at base (blanket denial) while
/// PASSING with the fix (per-metric truth from real evidence).

const _sleepPerm = 'android.permission.health.READ_SLEEP';
const _stepsPerm = 'android.permission.health.READ_STEPS';

final _now = DateTime(2026, 10, 21, 12);

class _Backend extends TabsBackend {
  _Backend() : super(sessionStore: FakeSessionStore());

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async =>
      <String, dynamic>{};

  @override
  Future<List<QuickLogEntry>> fetchLogEntryDtos() async => const [];

  @override
  Future<List<BpRecord>> fetchManualBpLogs() async => const [];
}

/// How one metric's fresh read behaves in a fixture.
enum _ReadMode {
  healthy,
  failGeneric, // code + non-SecurityException detail, like the real service
  failSecurity, // code + 'SecurityException' detail — the stale signature
}

/// Fake HC in the real service's fail-closed shape: a failed read
/// returns [] and records lastReadErrorCode / lastReadErrorDetails
/// on the instance BEFORE returning. The legacy gate is simulated
/// faithfully too: [gateMode] drives isConnected() exactly as the
/// base collector consumed it (partial grant → false; stale Steps
/// probe → throws STALE_GRANT). The fixed collector never calls
/// isConnected(), so the gate simulation only bites at base.
class _FakeHc extends HealthConnectService {
  /// What isConnected() does at the (removed) gate.
  _GateMode gateMode = _GateMode.connected;

  /// The missing set getMissingPermissions() reports (the live
  /// granted set's complement, as the real API returns it).
  Set<String> missing = const {};

  _ReadMode sleepMode = _ReadMode.healthy;
  _ReadMode hrMode = _ReadMode.healthy;
  _ReadMode calMode = _ReadMode.healthy;
  _ReadMode spikeMode = _ReadMode.healthy;
  _ReadMode hrvMode = _ReadMode.healthy;

  List<({String date, int mins, int deep})> sleepHist = const [
    (date: '2026-10-19', mins: 420, deep: 80),
    (date: '2026-10-20', mins: 450, deep: 90),
  ];
  List<({String date, int bpm})> hrHist = const [
    (date: '2026-10-20', bpm: 62),
  ];
  List<({String date, int kcal})> calHist = const [
    (date: '2026-10-20', kcal: 2100),
  ];
  List<({String date, int count})> spikeHist = const [
    (date: '2026-10-20', count: 2),
  ];

  @override
  Future<bool> isConnected() async {
    switch (gateMode) {
      case _GateMode.connected:
        return true;
      case _GateMode.notConnected:
        return false;
      case _GateMode.staleProbe:
        throw const HealthConnectException(
            HealthConnectService.staleGrantCode,
            HealthConnectService.staleGrantMessage);
    }
  }

  @override
  Future<Set<String>> getMissingPermissions() async => missing;

  bool _fail(_ReadMode mode, String code) {
    switch (mode) {
      case _ReadMode.healthy:
        return false;
      case _ReadMode.failGeneric:
        lastReadErrorCode = code;
        lastReadErrorDetails = 'IOException';
        return true;
      case _ReadMode.failSecurity:
        lastReadErrorCode = code;
        lastReadErrorDetails = 'SecurityException';
        return true;
    }
  }

  // The union runs its reads CONCURRENTLY and each loader claims
  // the shared error fields in its own completion continuation —
  // the attribution protocol documented in health_history_queries.
  // The real service records the fields immediately before its
  // future completes (platform replies arrive one at a time), so
  // this fake does the same: the failure is recorded after an
  // async gap, never synchronously at call time (a synchronous
  // record would let the first loader claim every metric's
  // signal, which no real read can do).
  Future<bool> _failAsync(_ReadMode mode, String code) async {
    await Future<void>.delayed(Duration.zero);
    return _fail(mode, code);
  }

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
          int days) async =>
      await _failAsync(sleepMode, 'SLEEP_HISTORY_READ_FAILED')
          ? const []
          : sleepHist;

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
          int days) async =>
      await _failAsync(hrMode, 'RHR_HISTORY_READ_FAILED') ? const [] : hrHist;

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(
          int days) async =>
      await _failAsync(calMode, 'CALORIES_HISTORY_READ_FAILED')
          ? const []
          : calHist;

  @override
  Future<List<({String date, int count})>> readSpikeCounts(int days) async =>
      await _failAsync(spikeMode, 'SPIKE_COUNTS_READ_FAILED')
          ? const []
          : spikeHist;

  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(
      int days) async {
    if (await _failAsync(hrvMode, 'HRV_SAMPLES_READ_FAILED')) {
      return const [];
    }
    return [
      (
        t: DateTime(2026, 10, 20, 12).millisecondsSinceEpoch,
        ms: 55.0,
        tier: 100,
      ),
    ];
  }
}

enum _GateMode { connected, notConnected, staleProbe }

/// Vera Gate 2 regression fake (PR #72) — the record-then-yield
/// shape her concurrency probe used to falsify the old
/// concurrent-claims attribution protocol:
///
/// - sleep's read records its SecurityException signal
///   SYNCHRONOUSLY when the read starts, then yields 10 ms before
///   returning [] — fully conforming to the service contract
///   (the signal IS recorded before the read's future completes).
/// - restingHr's read records a GENERIC failure (IOException)
///   after 5 ms and returns [].
/// - calories is healthy and returns its rows immediately.
///
/// Under the old concurrent protocol, calories' loader was the
/// first continuation to run after sleep's signal was set, so
/// calories claimed sleep's stale signal, discarded its healthy
/// rows, and sleep's real block vanished. Attribution must land
/// each signal on the metric that recorded it.
class _RecordThenYieldHc extends HealthConnectService {
  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
      int days) async {
    lastReadErrorCode = 'SLEEP_HISTORY_READ_FAILED';
    lastReadErrorDetails = 'SecurityException';
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return const [];
  }

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
      int days) async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    lastReadErrorCode = 'RHR_HISTORY_READ_FAILED';
    lastReadErrorDetails = 'IOException';
    return const [];
  }

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(
          int days) async =>
      const [(date: '2026-10-20', kcal: 2100)];
}

QuickLogCategory _cat(int id, String name) => QuickLogCategory(
    id: id,
    name: name,
    icon: 'x',
    colorHex: '#FF0000',
    isDefault: true,
    sortOrder: id);

void main() {
  late Map<String, String> disk;
  late HealthHistoryStore store;
  late _FakeHc hc;

  setUp(() {
    disk = <String, String>{};
    store = HealthHistoryStore.testInstance();
    store.debugSetStore(
      read: (k) async => disk[k],
      write: (k, v) async => disk[k] = v,
      delete: (k) async => disk.remove(k),
    );
    store.debugReset();
    hc = _FakeHc();
  });

  Future<ReportSnapshot> collect({
    Future<List<InsightRecord>> Function()? insightsLoader,
  }) =>
      ReportDataCollector(
        backend: _Backend(),
        hc: hc,
        historyQueries: HealthHistoryQueries(hc: hc, store: store),
        insightsLoader: insightsLoader,
      ).collect(
        selectedCategories: [_cat(1, 'Symptoms')],
        last30Days: true,
        profile: const ReportProfileInput(),
        now: _now,
      );

  const hcKeys = ['sleep', 'deepSleep', 'heartRate', 'hrv', 'calories', 'hrSpikes'];

  group('Trigger 1 — partial grant (Steps missing, report metrics granted)',
      () {
    test('sections populate per-metric; no permissionDenied for granted '
        'metrics', () async {
      // Steps is in the 15-permission required set but no report
      // metric reads it. At base the gate collapses: isConnected()
      // is false → all six permissionDenied / 0.
      hc.gateMode = _GateMode.notConnected;
      hc.missing = {_stepsPerm};
      final snap = await collect();
      for (final key in hcKeys) {
        expect(snap.sectionMetadata[key]!.status,
            isNot(DataSourceStatus.permissionDenied),
            reason: '$key must not be condemned by a Steps gap');
      }
      expect(snap.sectionMetadata['sleep']!.status, DataSourceStatus.success);
      expect(snap.sectionMetadata['sleep']!.recordCount, 2);
      expect(
          snap.sectionMetadata['deepSleep']!.status, DataSourceStatus.success);
      expect(snap.sectionMetadata['deepSleep']!.recordCount, 2);
      expect(
          snap.sectionMetadata['heartRate']!.status, DataSourceStatus.success);
      expect(snap.sectionMetadata['hrv']!.status, DataSourceStatus.success);
      expect(
          snap.sectionMetadata['calories']!.status, DataSourceStatus.success);
      expect(
          snap.sectionMetadata['hrSpikes']!.status, DataSourceStatus.success);
      expect(snap.sleepSeries.length, 2);
      expect(snap.heartRateSeries.length, 1);
    });
  });

  group('Trigger 2 — stale Steps probe (all granted, probe blocked)', () {
    test('sections populate truthfully; the Steps probe is not evidence '
        'about the report reads', () async {
      // All 15 granted; getStatus()'s Steps probe throws
      // SecurityException → STALE_GRANT. At base the collector's
      // bare try/catch flattened that to the blanket denial.
      hc.gateMode = _GateMode.staleProbe;
      hc.missing = const {};
      final snap = await collect();
      for (final key in hcKeys) {
        expect(snap.sectionMetadata[key]!.status, DataSourceStatus.success,
            reason: '$key read healthy and must report success');
      }
      expect(snap.sectionMetadata['sleep']!.recordCount, 2);
      expect(snap.hrvSeries.length, 1);
    });
  });

  group('Stored-only — fresh reads failed, store holds the days', () {
    test('sections populated from store, status storedOnly, rendered line '
        'is Juno\'s stored-only string with the true count', () async {
      await store.mergeRefresh([
        for (final d in ['2026-10-18', '2026-10-19', '2026-10-20'])
          DailyBiometrics(
            date: d,
            sleepMinutes: 430,
            deepSleepMinutes: 85,
            restingHrBpm: 61,
            caloriesKcal: 2000,
            spikeCount: 1,
            hrvRmssdMs: 50.0,
          ),
      ]);
      hc.sleepMode = _ReadMode.failGeneric;
      hc.hrMode = _ReadMode.failGeneric;
      hc.calMode = _ReadMode.failGeneric;
      hc.spikeMode = _ReadMode.failGeneric;
      hc.hrvMode = _ReadMode.failGeneric;
      hc.missing = const {};
      final snap = await collect();
      for (final key in hcKeys) {
        // Status asserted by NAME (and by rendered line below) so
        // this fixture compiles — and fails on assertions — against
        // the pre-fix tree, where the storedOnly state does not
        // exist and the gate reports permissionDenied instead.
        expect(snap.sectionMetadata[key]!.status.name, 'storedOnly',
            reason: '$key was carried by the store alone');
        expect(snap.sectionMetadata[key]!.recordCount, 3,
            reason: '$key count is the union (store) day count');
      }
      expect(snap.sleepSeries.length, 3);
      expect(snap.deepSleepSeries.length, 3);
      expect(snap.hrvSeries.length, 3);
      expect(
        availabilityStatusText(snap.sectionMetadata['sleep']!),
        'Available from stored history (3 records)',
      );
    });
  });

  group('Stale render — own read blocked with SecurityException', () {
    test('sleep status is stale and renders Juno\'s stale string '
        'byte-exact, NOT the permission-denied string', () async {
      hc.sleepMode = _ReadMode.failSecurity;
      hc.missing = const {}; // the sleep grant IS present
      final snap = await collect();
      // Name-based assertion, as in the stored-only group: the
      // fixture must fail on assertions at base, not on symbols.
      expect(snap.sectionMetadata['sleep']!.status.name, 'stale');
      // deepSleep mirrors sleep's evidence (same read, same grant).
      expect(snap.sectionMetadata['deepSleep']!.status.name, 'stale');
      final line = availabilityStatusText(snap.sectionMetadata['sleep']!);
      expect(line, 'Unavailable. Permission shown as granted, but read blocked.');
      expect(line, isNot('Unavailable. Permission not granted.'));
      // Untouched metrics keep their own truth.
      expect(
          snap.sectionMetadata['heartRate']!.status, DataSourceStatus.success);
    });

    test('the same SecurityException failure WITH its grant missing is a '
        'true per-metric permissionDenied', () async {
      hc.sleepMode = _ReadMode.failSecurity;
      hc.missing = {_sleepPerm};
      final snap = await collect();
      expect(snap.sectionMetadata['sleep']!.status,
          DataSourceStatus.permissionDenied);
      expect(
          availabilityStatusText(snap.sectionMetadata['sleep']!),
          'Unavailable. Permission not granted.');
      // Per-metric: the Steps-style gap logic runs the other way —
      // sleep's gap does not condemn heartRate.
      expect(
          snap.sectionMetadata['heartRate']!.status, DataSourceStatus.success);
    });
  });

  group('Granted-normal regression', () {
    test('everything granted, reads succeed: statuses, counts and '
        'rendered lines exactly as before Phase 1', () async {
      hc.gateMode = _GateMode.connected;
      hc.missing = const {};
      final snap = await collect();
      expect(snap.sectionMetadata['sleep']!.status, DataSourceStatus.success);
      expect(
        availabilityStatusText(snap.sectionMetadata['sleep']!),
        'Available (2 records)',
      );
      expect(
          snap.sectionMetadata['heartRate']!.status, DataSourceStatus.success);
      expect(snap.sectionMetadata['hrv']!.status, DataSourceStatus.success);
      expect(
          snap.sectionMetadata['calories']!.status, DataSourceStatus.success);
      expect(
          snap.sectionMetadata['hrSpikes']!.status, DataSourceStatus.success);
    });

    test('a clean read with no data is noData (a read happened)', () async {
      hc.missing = const {};
      hc.sleepHist = const [];
      final empty = await collect();
      expect(
          empty.sectionMetadata['sleep']!.status, DataSourceStatus.noData);
      expect(availabilityStatusText(empty.sectionMetadata['sleep']!),
          'No data recorded');
    });
  });

  group('Clinician one-pager inherits the truth (shared collector)', () {
    Future<List<String>> z8Lines(ReportSnapshot snap) async {
      final data = await ClinicianReportCollector(
        scoreLoader: () async => const {},
        eventsLoader: () async => const [],
        categoriesLoader: () async => const [],
      ).extend(snap, allMedications: const []);
      return [
        for (final l in clinicianPageLines(data))
          if (l.zone == 'Z8') l.text,
      ];
    }

    test('Trigger 1 snapshot: Z8 prints no false denial', () async {
      hc.gateMode = _GateMode.notConnected;
      hc.missing = {_stepsPerm};
      final z8 = await z8Lines(await collect());
      expect(z8.join('\n'),
          isNot(contains('Unavailable. Permission not granted.')));
    });

    test('stored-only snapshot: Z8 states the stored provenance', () async {
      await store.mergeRefresh([
        DailyBiometrics(
            date: '2026-10-20', sleepMinutes: 430, deepSleepMinutes: 85),
      ]);
      hc.sleepMode = _ReadMode.failGeneric;
      hc.missing = const {};
      final z8 = await z8Lines(await collect());
      expect(
        z8.join('\n'),
        contains(
            'Sleep: Available from stored history (1 records); '
            'DeepSleep: Available from stored history (1 records)'),
      );
    });
  });

  group('Record-then-yield attribution (Vera Gate 2 regression)', () {
    test('a signal recorded before a yield lands ONLY on the metric '
        'that recorded it; the healthy metric keeps its rows; the '
        'generic failure stays generic', () async {
      final queries = HealthHistoryQueries(
          hc: _RecordThenYieldHc(), store: store);
      final union = await queries.loadRange(
        startDate: '2026-10-19',
        endDate: '2026-10-21',
        metrics: {
          HistoryMetric.sleep,
          HistoryMetric.restingHr,
          HistoryMetric.calories,
        },
      );
      // Sleep's own SecurityException block is sleep's — it must
      // not vanish (under the old protocol sleep reported clean
      // and would print 'No data recorded').
      expect(union.failed(HistoryMetric.sleep), isTrue,
          reason: 'sleep recorded the SecurityException signal');
      expect(union.failedWithSecurityException(HistoryMetric.sleep),
          isTrue);
      expect(union.failureDetails[HistoryMetric.sleep],
          contains('SecurityException'));
      // RestingHr's generic failure stays generic (error, not
      // stale) — it neither inherits sleep's SecurityException
      // nor loses its own failure.
      expect(union.failed(HistoryMetric.restingHr), isTrue);
      expect(union.failedWithSecurityException(HistoryMetric.restingHr),
          isFalse);
      expect(union.failureDetails[HistoryMetric.restingHr],
          contains('IOException'));
      // Calories is healthy: not failed, and its rows survive
      // (under the old protocol calories claimed sleep's signal,
      // was marked stale, and its rows were discarded).
      expect(union.failed(HistoryMetric.calories), isFalse);
      expect(union.failedWithSecurityException(HistoryMetric.calories),
          isFalse);
      expect(union.calories['2026-10-20'], 2100,
          reason: 'healthy rows must not be discarded');
      // Exactly the two real failures, nothing else.
      expect(union.failedMetrics,
          {HistoryMetric.sleep, HistoryMetric.restingHr});
    });
  });

  group('Phase 4 standard report truth', () {
    const record = InsightRecord(
      familyId: 'F1',
      splitId: 'F1a',
      windowKey: 'last90d',
      state: InsightState.numbers,
      groups: [
        InsightGroup(label: '8+ hrs sleep', n: 12, mean: 78.5),
        InsightGroup(label: '<7 hrs sleep', n: 10, mean: 55.0),
      ],
      computedAtMs: 1700000000000,
      throughDate: '2026-10-20',
      inputFingerprint: 'fp-test',
    );

    test('Daily Score metadata', () async {
      final snap = await collect();
      expect(snap.sectionMetadata.containsKey('dailyScore'), isTrue);
      expect(availabilityPdfLabel('dailyScore'), 'Daily Score');
    });

    test('Blood pressure empty + unproven source (Juno R4 '
        'Ruling 2, R2-2 default)', () async {
      // This fixture's BP fetch returns [] and its pull carries
      // no parsed manual-BP source field, so the empty cannot be
      // proven clean: Ruling 2 keeps it a retrieval statement.
      // (Present readings → success, and the proven-clean empty
      // → noData, are pinned in
      // report_accuracy_vc100132_test.dart.)
      final snap = await collect();
      final bpMeta = snap.sectionMetadata['bloodPressure'];
      expect(bpMeta, isNotNull);
      expect(bpMeta!.status, DataSourceStatus.error);
      expect(bpMeta.status, isNot(DataSourceStatus.success));
      expect(bpMeta.status, isNot(DataSourceStatus.noData));
      expect(
        availabilityStatusText(bpMeta),
        'Unavailable. Data could not be retrieved.',
      );
    });

    test('Correlation bridge', () async {
      final snap = await collect(
        insightsLoader: () async => [record],
      );
      expect(snap.correlationInsights, contains(record));
      expect(snap.correlationInsightsLoadFailed, isFalse);

      final failedSnap = await collect(
        insightsLoader: () async => throw Exception('storage error'),
      );
      expect(failedSnap.correlationInsightsLoadFailed, isTrue);
      expect(failedSnap.correlationInsights, isEmpty);
    });

    test('Request payload', () {
      final expectedSentence = correlationComparisonSentence(
        groupALabel: record.groups[0].label,
        groupAN: record.groups[0].n,
        groupAMean: record.groups[0].mean!,
        groupBLabel: record.groups[1].label,
        groupBN: record.groups[1].n,
        groupBMean: record.groups[1].mean!,
      );

      final snapWithRecord = ReportSnapshot(
        last30Days: true,
        generationTimestampMs: _now.millisecondsSinceEpoch,
        logEntries: const [],
        categoriesMap: const {},
        correlationInsights: [record],
        correlationInsightsLoadFailed: false,
      );
      final reqWithRecord = buildAiReportRequest(snapWithRecord);
      expect(reqWithRecord['correlation_insights'], isA<String>());
      expect(reqWithRecord['correlation_insights'], contains(expectedSentence));

      final snapFailed = ReportSnapshot(
        last30Days: true,
        generationTimestampMs: _now.millisecondsSinceEpoch,
        logEntries: const [],
        categoriesMap: const {},
        correlationInsights: [record],
        correlationInsightsLoadFailed: true,
      );
      final reqFailed = buildAiReportRequest(snapFailed);
      expect(reqFailed['correlation_insights'], isNull);

      final snapEmpty = ReportSnapshot(
        last30Days: true,
        generationTimestampMs: _now.millisecondsSinceEpoch,
        logEntries: const [],
        categoriesMap: const {},
        correlationInsights: const [],
        correlationInsightsLoadFailed: false,
      );
      final reqEmpty = buildAiReportRequest(snapEmpty);
      expect(reqEmpty['correlation_insights'], isNull);
    });
  });
}
