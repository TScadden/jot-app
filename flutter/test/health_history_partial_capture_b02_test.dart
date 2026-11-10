import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_history_sync.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';

import 'test_helpers.dart';

/// B-02 (Pass 2, PARTIALLY HOLDS) — partial HRV / sleep chunk
/// captures must not be recorded as clean success:
///
/// (i) the HRV window is keyed off a persisted backfill-complete
///     flag set ONLY by a clean (no error, no partial) HRV read —
///     a partial first capture must not shrink the 90-day window
///     for later captures the way the old dayCount-derived
///     `isFirst` did (once any sibling metric merged, dayCount > 0
///     and the window collapsed to 31 forever);
/// (ii) a capture with any partial leg must NOT run the
///     post-capture Daily Score compute — past days are
///     write-once, so scoring from incomplete components locks a
///     day without its sleep/HRV forever;
/// (iii) a partial sleep read must not clear sleep's recorded
///     failure diagnostic (the old noteRead checked only
///     lastReadErrorCode, so partial sleep landed in
///     captureSucceeded and the succeeded-loop removed the entry);
/// (iv) ReportDataCollector must map the union's partial / failed
///     metrics to the report's error status instead of deriving
///     status from emptiness alone (partial-empty reported noData,
///     truncated non-empty reported success).
///
/// The flag itself is exercised BEHAVIOURALLY (through the HRV
/// window a later capture requests, including across a re-warm
/// over the same disk) so these tests fail on the pre-fix code
/// for the stated reasons, not on missing symbols.

HealthHistoryStore _storeFor(Map<String, String> disk) {
  final store = HealthHistoryStore.testInstance();
  store.debugSetStore(
    read: (k) async => disk[k],
    write: (k, v) async => disk[k] = v,
    delete: (k) async => disk.remove(k),
  );
  return store;
}

/// Configurable fake: every read returns empty except where a
/// test stages rows/samples; the sleep and HRV legs can be made
/// to fail or return partial exactly as the real service reports
/// it (the fake sets lastReadErrorCode / lastPartialErrorCode on
/// ITSELF during the read, and the sync snapshots those fields
/// off the instance after the read). Records every HRV window.
class _FakeHc extends HealthConnectService {
  final List<int> hrvWindows = [];

  String? sleepErrorCode;
  String? sleepPartialCode;
  String? hrvErrorCode;
  String? hrvPartialCode;

  List<({String date, int mins, int deep})> sleepRows = const [];
  List<({int t, double ms, int tier})> hrvSamples = const [];

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
      int days) async => const [];

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
      int days) async {
    if (sleepErrorCode != null) lastReadErrorCode = sleepErrorCode;
    if (sleepPartialCode != null) {
      lastPartialErrorCode = sleepPartialCode;
    }
    return sleepRows;
  }

  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(
      int days) async {
    hrvWindows.add(days);
    if (hrvErrorCode != null) lastReadErrorCode = hrvErrorCode;
    if (hrvPartialCode != null) lastPartialErrorCode = hrvPartialCode;
    return hrvSamples;
  }

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(
      int days) async => const [];

  @override
  Future<List<({String date, int count})>> readSpikeCounts(
      int days) async => const [];
}

final _now = DateTime.utc(2026, 10, 21, 12);

HealthHistorySync _sync(_FakeHc hc, HealthHistoryStore store) =>
    HealthHistorySync.withDeps(hc: hc, store: store, now: () => _now);

String _ds(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

void main() {
  setUp(() {
    HealthHistorySync.debugResetFlight();
  });
  tearDown(() {
    HealthHistorySync.debugResetFlight();
  });

  group('B-02 (i) — HRV backfill window keyed off a clean read', () {
    test(
        'partial HRV on the first capture: the window stays 90 on '
        'the next capture; a clean capture completes the backfill '
        'and only then does the window become 31', () async {
      final disk = <String, String>{};
      final store = _storeFor(disk);
      // A sibling metric lands data on the first capture (the
      // sleep row below), so dayCount() > 0 afterwards — the
      // exact condition under which the old isFirst logic shrank
      // the HRV window to 31 and never re-read days 31–90.
      final hc = _FakeHc()
        ..sleepRows = const [(date: '2026-10-20', mins: 450, deep: 90)]
        ..hrvPartialCode = 'HRV_SAMPLES_PARTIAL'
        ..hrvSamples = [
          (
            t: DateTime.utc(2026, 10, 20, 2).millisecondsSinceEpoch,
            ms: 55.0,
            tier: 100,
          ),
        ];
      final sync = _sync(hc, store);

      expect(await sync.captureFromHealthConnect(force: true), isTrue);
      expect(hc.hrvWindows, [90]);
      expect(await store.dayCount(), greaterThan(0));

      // Still partial: the backfill is NOT complete, so this
      // capture must still span the full 90 days.
      expect(await sync.captureFromHealthConnect(force: true), isTrue);
      expect(hc.hrvWindows, [90, 90]);

      // Clean capture: it still reads 90 (the flag was unset when
      // it started) and completes the backfill.
      hc.hrvPartialCode = null;
      expect(await sync.captureFromHealthConnect(force: true), isTrue);
      expect(hc.hrvWindows, [90, 90, 90]);

      // Only now does the routine window shrink to 31.
      expect(await sync.captureFromHealthConnect(force: true), isTrue);
      expect(hc.hrvWindows, [90, 90, 90, 31]);

      // The completion persisted: a fresh store over the same
      // disk (a restart) also reads the routine 31-day window.
      final rewarm = _storeFor(disk);
      final sync2 = _sync(hc, rewarm);
      expect(await sync2.captureFromHealthConnect(force: true), isTrue);
      expect(hc.hrvWindows, [90, 90, 90, 31, 31]);
    });

    test(
        'a FAILED HRV read does not complete the backfill either: '
        'the next capture still reads 90', () async {
      final disk = <String, String>{};
      final store = _storeFor(disk);
      final hc = _FakeHc()
        ..sleepRows = const [(date: '2026-10-20', mins: 450, deep: 90)]
        ..hrvErrorCode = 'HRV_SAMPLES_READ_FAILED';
      final sync = _sync(hc, store);

      expect(await sync.captureFromHealthConnect(force: true), isTrue);
      expect(hc.hrvWindows, [90]);
      expect(await sync.captureFromHealthConnect(force: true), isTrue);
      expect(hc.hrvWindows, [90, 90]);
    });

    test(
        'migration: a pre-B-02 blob (no backfill flag on disk) is '
        'treated as NOT complete — the capture reads 90 even '
        'though the store already holds days', () async {
      final disk = <String, String>{
        HealthHistoryStore.storageKey: jsonEncode({
          'ownerEmail': null,
          'lastCaptureMs': null,
          'sleepTotalsRuleVersion':
              HealthHistoryStore.currentSleepTotalsRuleVersion,
          'days': {
            '2026-10-10': {
              'date': '2026-10-10',
              'restingHrBpm': 58,
              'sleepMinutes': 432,
              'deepSleepMinutes': 88,
              'caloriesKcal': 2100,
            },
          },
        }),
      };
      final store = _storeFor(disk);
      await store.warmFromDisk();
      expect(await store.dayCount(), 1);

      final hc = _FakeHc();
      expect(await _sync(hc, store).captureFromHealthConnect(force: true),
          isTrue);
      expect(hc.hrvWindows, [90]);
    });
  });

  group('B-02 (ii) — a partial capture locks no write-once scores', () {
    test(
        'partial capture: the scorable past day stays UNSCORED; '
        'the following clean capture scores it', () async {
      final disk = <String, String>{};
      final store = _storeFor(disk);
      // 28 baseline days + the past target day, all complete —
      // the shape the engine scores 82 (sleep 100, HRV 70,
      // resting HR 70) on a clean run.
      final target = DateTime.utc(2026, 10, 19);
      await store.mergeRefresh([
        for (var i = 28; i >= 1; i--)
          DailyBiometrics(
            date: _ds(target.subtract(Duration(days: i))),
            sleepMinutes: 480,
            restingHrBpm: 60,
            hrvRmssdMs: 40,
          ),
        DailyBiometrics(
          date: _ds(target),
          sleepMinutes: 480,
          restingHrBpm: 60,
          hrvRmssdMs: 40,
        ),
      ]);
      expect((await store.readAll())[_ds(target)]!.dailyScore, isNull);

      final hc = _FakeHc()..hrvPartialCode = 'HRV_SAMPLES_PARTIAL';
      final sync = _sync(hc, store);
      expect(await sync.captureFromHealthConnect(force: true), isTrue);
      expect((await store.readAll())[_ds(target)]!.dailyScore, isNull,
          reason: 'a partial capture must not run the post-capture '
              'score compute — the day would be locked write-once '
              'without the components its failed chunks held');

      // The skip is capture-scoped, not permanent: the next clean
      // capture scores the day exactly as before.
      hc.hrvPartialCode = null;
      expect(await sync.captureFromHealthConnect(force: true), isTrue);
      expect((await store.readAll())[_ds(target)]!.dailyScore, 82);
    });

    test(
        'partial SLEEP leg also skips the score run', () async {
      final disk = <String, String>{};
      final store = _storeFor(disk);
      final target = DateTime.utc(2026, 10, 19);
      await store.mergeRefresh([
        for (var i = 28; i >= 1; i--)
          DailyBiometrics(
            date: _ds(target.subtract(Duration(days: i))),
            sleepMinutes: 480,
            restingHrBpm: 60,
            hrvRmssdMs: 40,
          ),
        DailyBiometrics(
          date: _ds(target),
          sleepMinutes: 480,
          restingHrBpm: 60,
          hrvRmssdMs: 40,
        ),
      ]);
      final hc = _FakeHc()..sleepPartialCode = 'SLEEP_HISTORY_PARTIAL';
      expect(await _sync(hc, store).captureFromHealthConnect(force: true),
          isTrue);
      expect((await store.readAll())[_ds(target)]!.dailyScore, isNull);
    });
  });

  group('B-02 (iii) — partial sleep keeps its failure diagnostic', () {
    test(
        'a sleep failure recorded by one capture is NOT cleared '
        'by a later partial sleep read', () async {
      final disk = <String, String>{};
      final store = _storeFor(disk);
      final hc = _FakeHc()..sleepErrorCode = 'SLEEP_HISTORY_READ_FAILED';
      final sync = _sync(hc, store);

      expect(await sync.captureFromHealthConnect(force: true), isTrue);
      expect(store.lastCaptureDiagnostics['sleep']!.errorCode,
          'SLEEP_HISTORY_READ_FAILED');

      hc.sleepErrorCode = null;
      hc.sleepPartialCode = 'SLEEP_HISTORY_PARTIAL';
      hc.sleepRows = const [(date: '2026-10-20', mins: 450, deep: 90)];
      expect(await sync.captureFromHealthConnect(force: true), isTrue);

      final diag = store.lastCaptureDiagnostics['sleep'];
      expect(diag, isNotNull,
          reason: 'a partial sleep read is not a success — it '
              'must not clear sleep\'s recorded failure');
      expect(diag!.errorCode ?? diag.partialCode, isNotNull,
          reason: 'the retained entry must carry a failure/partial '
              'code, not a clean outcome');
    });

    test(
        'guard: a partial HRV read still records its partial code '
        'as a partial (never an error) — the B-02 fix must not '
        'regress the HRV diagnostics contract', () async {
      final disk = <String, String>{};
      final store = _storeFor(disk);
      final hc = _FakeHc()
        ..hrvPartialCode = 'HRV_SAMPLES_PARTIAL'
        ..hrvSamples = [
          (
            t: DateTime.utc(2026, 10, 20, 2).millisecondsSinceEpoch,
            ms: 55.0,
            tier: 100,
          ),
        ];
      expect(await _sync(hc, store).captureFromHealthConnect(force: true),
          isTrue);
      final diag = store.lastCaptureDiagnostics['hrv']!;
      expect(diag.errorCode, isNull);
      expect(diag.partialCode, 'HRV_SAMPLES_PARTIAL');
      expect(diag.sampleCount, 1);
      expect(diag.dayCount, 1);
    });
  });

  group('B-02 (iv) — report collector honours union partial/failed', () {
    test(
        'partial sleep (non-empty) and partial HRV (empty) and '
        'failed calories (non-empty) report error, not '
        'success/noData; clean metrics keep emptiness semantics',
        () async {
      final queries = _UnionQueries(
        const HistoryUnion(
          startDate: '2026-09-21',
          endDate: '2026-10-21',
          sleepMinutes: {'2026-10-16': 430},
          deepSleepMinutes: {'2026-10-16': 90},
          restingHr: {'2026-10-16': 62},
          calories: {'2026-10-16': 2100},
          hrv: {},
          partialMetrics: {HistoryMetric.sleep, HistoryMetric.hrv},
          failedMetrics: {HistoryMetric.calories},
        ),
      );
      final collector = ReportDataCollector(
        backend: _ReportBackend(),
        hc: _ConnectedHc(),
        historyQueries: queries,
      );
      final snap = await collector.collect(
        selectedCategories: [_cat(1, 'Symptoms')],
        last30Days: true,
        profile: const ReportProfileInput(),
        now: _now,
      );
      // The partial series still lands in the snapshot…
      expect(snap.sleepSeries, [('2026-10-16', 430)]);
      expect(snap.caloriesSeries, [('2026-10-16', 2100)]);
      // …but its STATUS tells the truth (existing error status —
      // no new user-visible copy).
      expect(snap.sectionMetadata['sleep']!.status, DataSourceStatus.error);
      expect(
          snap.sectionMetadata['deepSleep']!.status, DataSourceStatus.error);
      expect(snap.sectionMetadata['hrv']!.status, DataSourceStatus.error);
      expect(
          snap.sectionMetadata['calories']!.status, DataSourceStatus.error);
      // Untouched metrics keep the old emptiness semantics.
      expect(snap.sectionMetadata['heartRate']!.status,
          DataSourceStatus.success);
      expect(
          snap.sectionMetadata['hrSpikes']!.status, DataSourceStatus.noData);
    });
  });
}

QuickLogCategory _cat(int id, String name) => QuickLogCategory(
    id: id,
    name: name,
    icon: 'x',
    colorHex: '#FF0000',
    isDefault: true,
    sortOrder: id);

class _ReportBackend extends TabsBackend {
  _ReportBackend() : super(sessionStore: FakeSessionStore());

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async =>
      <String, dynamic>{};

  @override
  Future<List<QuickLogEntry>> fetchLogEntryDtos() async => const [];

  @override
  Future<List<BpRecord>> fetchManualBpLogs() async => const [];
}

class _ConnectedHc extends HealthConnectService {
  @override
  Future<bool> isConnected() async => true;
}

/// Serves one staged union regardless of the requested window.
class _UnionQueries extends HealthHistoryQueries {
  _UnionQueries(this.union);
  final HistoryUnion union;

  @override
  Future<HistoryUnion> loadDays(
    int days, {
    DateTime? end,
    Set<HistoryMetric>? metrics,
    bool fetchFromHealthConnect = true,
  }) async =>
      union;
}
