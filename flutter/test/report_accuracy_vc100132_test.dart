import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_history_sync.dart';
import 'package:tabs_lab/src/data/medications.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/progress_report_pdf.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';

import 'test_helpers.dart';

/// VC 100132 Round 4 — founder report accuracy, client half.
///
/// Pins the four fixes against the founder's VC 100131 artifact:
/// P1 the structured medications channel reaches the payload;
/// P2 Daily Score carries real stored scores (Juno Ruling 1's
/// three states); P3 blood pressure status derives from its own
/// series (Juno Ruling 2); P4 spike coverage is restored by a
/// persisted backfill flag and the spike total is framed by the
/// days it actually covers.

final _now = DateTime(2026, 11, 13, 15);

QuickLogCategory _cat(int id, String name) => QuickLogCategory(
    id: id, name: name, icon: 'x', colorHex: '#FF0000',
    isDefault: true, sortOrder: id);

class _Backend extends TabsBackend {
  _Backend() : super(sessionStore: FakeSessionStore());

  bool pullFails = false;
  List<BpRecord> bp = const [];
  bool bpSourceParsed = false;

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async =>
      pullFails ? null : <String, dynamic>{};

  @override
  Future<List<QuickLogEntry>> fetchLogEntryDtos() async => const [];

  @override
  Future<List<BpRecord>> fetchManualBpLogs() async => bp;

  @override
  Future<bool> manualBpSourceParsed() async => bpSourceParsed;
}

class _Hc extends HealthConnectService {
  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
          int days) async =>
      const [];
  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
          int days) async =>
      const [];
  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(
          int days) async =>
      const [];
  @override
  Future<List<({String date, int count})>> readSpikeCounts(int days) async =>
      const [];
  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(
          int days) async =>
      const [];
}

Future<ReportSnapshot> _collect(
  _Backend backend, {
  ReportProfileInput profile = const ReportProfileInput(),
  Future<Map<String, int>> Function()? scoreLoader,
  HealthHistoryStore? store,
}) {
  final hc = _Hc();
  final s = store ?? HealthHistoryStore.testInstance();
  return ReportDataCollector(
    backend: backend,
    hc: hc,
    historyQueries: HealthHistoryQueries(hc: hc, store: s),
    scoreLoader: scoreLoader ?? () async => const {},
  ).collect(
    selectedCategories: [_cat(1, 'Symptoms')],
    last30Days: false,
    profile: profile,
    now: _now,
  );
}

void main() {
  group('P1 — structured medications channel', () {
    final bpc = MedicationEntry(
        name: 'BPC-157 Peptide', dose: '0.5', frequency: 'Once daily',
        startDate: 'Oct 6, 2026', endDate: 'Present');
    final iva = MedicationEntry(
        name: 'Ivabradine', dose: '7.5mg', frequency: 'Twice daily',
        startDate: 'May 26, 2026', endDate: 'Present');
    final esc = MedicationEntry(
        name: 'Escitalopram', dose: '50mg', frequency: 'Daily',
        startDate: 'Sep 1, 2026', endDate: 'Oct 16, 2026',
        isPresent: false);

    test('payload carries current AND discontinued entries with '
        'dose/frequency truth intact', () async {
      final snap = await _collect(
        _Backend(),
        profile: ReportProfileInput(
          activeMedications: [bpc, iva],
          allMedications: [bpc, iva, esc],
        ),
      );
      final body = buildAiReportRequest(snap);
      final meds = body['medications'] as List<dynamic>;
      expect(meds.length, 3);
      final byName = {
        for (final m in meds) (m as Map)['name'] as String: m,
      };
      // The founder's two wrong values, pinned at their truth.
      expect(byName['BPC-157 Peptide']!['dose'], '0.5');
      expect(byName['Ivabradine']!['frequency'], 'Twice daily');
      expect(byName['Ivabradine']!['archived'], false);
      expect(byName['Escitalopram']!['archived'], true);
      expect(byName['Escitalopram']!['endDate'], 'Oct 16, 2026');
      // The snapshot's local active list is unchanged.
      expect(snap.medications.map((m) => m.name),
          ['BPC-157 Peptide', 'Ivabradine']);
    });

    test('a caller supplying only the active list degrades to '
        'exactly that list', () {
      final snap = ReportSnapshot(
        last30Days: false,
        generationTimestampMs: _now.millisecondsSinceEpoch,
        logEntries: const [],
        categoriesMap: const {},
        medications: [iva],
      );
      final meds = structuredProfileMedications(snap);
      expect(meds.length, 1);
      expect(meds.single['frequency'], 'Twice daily');
    });
  });

  group('P2 — Daily Score (Juno Ruling 1 states)', () {
    test('present: success with the real in-range count, series '
        'in the snapshot, template line in the summary, retrieval '
        'sentence impossible', () async {
      final snap = await _collect(
        _Backend(),
        scoreLoader: () async => {
          '2026-11-10': 70,
          '2026-11-11': 80,
          '2026-11-12': 90,
          '2026-01-01': 50, // out of the 180-day range
        },
      );
      final meta = snap.sectionMetadata['dailyScore']!;
      expect(meta.status, DataSourceStatus.success);
      expect(meta.recordCount, 3);
      expect(snap.dailyScoreSeries.length, 3);
      expect(availabilityStatusText(meta), 'Available (3 records)');
      expect(buildDataAvailability(snap),
          contains('DailyScore: Available (3 records)'));
      final summary = buildHealthSummary(snap);
      expect(
          summary,
          contains('Daily Score: average 80.0 across 3 days '
              '· latest 90 on 2026-11-12 · range 70 to 90. '));
    });

    test('no scores in range: noData, Juno\'s empty line, no '
        'score content anywhere', () async {
      final snap = await _collect(_Backend());
      final meta = snap.sectionMetadata['dailyScore']!;
      expect(meta.status, DataSourceStatus.noData);
      expect(meta.recordCount, 0);
      expect(availabilityStatusText(meta), 'No data recorded');
      expect(buildHealthSummary(snap), isNot(contains('Daily Score')));
      expect(buildDataAvailability(snap),
          isNot(contains('DailyScore: Available')));
    });

    test('score read failure: error, Juno\'s failure line, never '
        'softened to no-data', () async {
      final snap = await _collect(
        _Backend(),
        scoreLoader: () async => throw Exception('store read failed'),
      );
      final meta = snap.sectionMetadata['dailyScore']!;
      expect(meta.status, DataSourceStatus.error);
      expect(meta.recordCount, 0);
      expect(availabilityStatusText(meta),
          'Unavailable. Data could not be retrieved.');
    });

    test('count 1: range clause suppressed (Ruling 1 template)',
        () async {
      final snap = await _collect(
        _Backend(),
        scoreLoader: () async => {'2026-11-12': 75},
      );
      expect(
          buildHealthSummary(snap),
          contains('Daily Score: average 75.0 across 1 day '
              '· latest 75 on 2026-11-12. '));
    });
  });

  group('P3 — blood pressure (Juno Ruling 2 states)', () {
    test('readings in range: success with the readings count; '
        'availability matches the chart series', () async {
      final backend = _Backend()
        ..bp = [
          BpRecord(
              systolic: 120,
              diastolic: 80,
              timeEpochMs: DateTime(2026, 11, 1).millisecondsSinceEpoch),
          BpRecord(
              systolic: 130,
              diastolic: 85,
              timeEpochMs: DateTime(2026, 11, 10).millisecondsSinceEpoch),
        ];
      final snap = await _collect(backend);
      final meta = snap.sectionMetadata['bloodPressure']!;
      expect(meta.status, DataSourceStatus.success);
      expect(meta.recordCount, 2);
      expect(snap.bloodPressureSeries.length, 2);
      expect(availabilityStatusText(meta), 'Available (2 records)');
      expect(buildDataAvailability(snap),
          contains('BloodPressure: Available (2 records)'));
    });

    test('empty + proven-clean source (R2-2 exit): noData', () async {
      final backend = _Backend()..bpSourceParsed = true;
      final snap = await _collect(backend);
      final meta = snap.sectionMetadata['bloodPressure']!;
      expect(meta.status, DataSourceStatus.noData);
      expect(availabilityStatusText(meta), 'No data recorded');
    });

    test('empty + unproven source (R2-2 default): error', () async {
      final snap = await _collect(_Backend());
      final meta = snap.sectionMetadata['bloodPressure']!;
      expect(meta.status, DataSourceStatus.error);
      expect(availabilityStatusText(meta),
          'Unavailable. Data could not be retrieved.');
    });

    test('failed pull (R2-3): error even with a parsed signal',
        () async {
      final backend = _Backend()
        ..pullFails = true
        ..bpSourceParsed = true;
      final snap = await _collect(backend);
      expect(snap.sectionMetadata['bloodPressure']!.status,
          DataSourceStatus.error);
    });
  });

  group('P4 — spikes coverage + framing', () {
    test('health summary scopes the total to the covered days',
        () {
      final snap = ReportSnapshot(
        last30Days: false,
        generationTimestampMs: _now.millisecondsSinceEpoch,
        logEntries: const [],
        categoriesMap: const {},
        heartRateSpikes: const [('2026-10-03', 20), ('2026-11-12', 30)],
      );
      expect(
          buildHealthSummary(snap),
          contains('Total HR Spikes: 50 recorded across 2 days '
              '(2026-10-03 to 2026-11-12). '));
    });

    Future<({_SpikeHc hc, HealthHistoryStore store})> capture(
        _SpikeHc hc, HealthHistoryStore store) async {
      final sync = HealthHistorySync.withDeps(
          hc: hc, store: store, now: () => _now);
      await sync.captureFromHealthConnect(force: true);
      return (hc: hc, store: store);
    }

    HealthHistoryStore freshStore() {
      final disk = <String, String>{};
      final store = HealthHistoryStore.testInstance();
      store.debugSetStore(
        read: (k) async => disk[k],
        write: (k, v) async => disk[k] = v,
        delete: (k) async => disk.remove(k),
      );
      return store;
    }

    test('a non-empty store without a completed spike backfill '
        'still reads the full 180 days (the old isFirst collapse)',
        () async {
      final store = freshStore();
      // Sibling data lands first — under the old rule this alone
      // collapsed every later spike read to 31 days.
      await store.mergeRefresh(const [
        DailyBiometrics(date: '2026-11-01', sleepMinutes: 420),
      ]);
      final hc = _SpikeHc();
      await capture(hc, store);
      expect(hc.spikeWindows, [180]);
      expect(store.spikeBackfillComplete, isTrue,
          reason: 'the clean full-window read stamps the flag');
    });

    test('after a clean backfill the routine window is 31',
        () async {
      final store = freshStore();
      final hc = _SpikeHc();
      await capture(hc, store);
      await capture(hc, store);
      expect(hc.spikeWindows, [180, 31]);
    });

    test('a failed spike read leaves the flag unset and the '
        'next capture re-reads 180', () async {
      final store = freshStore();
      final hc = _SpikeHc()..spikeFails = true;
      await capture(hc, store);
      expect(store.spikeBackfillComplete, isFalse);
      hc.spikeFails = false;
      await capture(hc, store);
      expect(hc.spikeWindows, [180, 180]);
      expect(store.spikeBackfillComplete, isTrue);
    });
  });
}

/// Spike backfill capture behaviour (P4, capture layer).
class _SpikeHc extends HealthConnectService {
  final List<int> spikeWindows = [];
  bool spikeFails = false;

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
          int days) async =>
      const [];
  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
          int days) async =>
      const [];
  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(
          int days) async =>
      const [];
  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(
          int days) async =>
      const [];
  @override
  Future<List<({String date, int count})>> readSpikeCounts(int days) async {
    spikeWindows.add(days);
    if (spikeFails) {
      lastReadErrorCode = 'SPIKE_COUNTS_READ_FAILED';
      lastReadErrorDetails = 'IOException';
      return const [];
    }
    return const [];
  }
}
