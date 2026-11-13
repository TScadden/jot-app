// VC 100130 regression harness (Mason) — the Round-2 reproduction
// harness, kept as the permanent regression's support file.
// Drives the REAL ReportDataCollector / HealthHistoryQueries /
// ReportGenerationPipeline / ReportGenerationService from VC 100129
// (merged head 8d02fe00) with founder-shaped data and bridge costs
// MODELED FROM THE NATIVE BRIDGE'S WORK, per Otto's trace:
//
// Native work for a 180-day union load (HealthConnectBridgePlugin.kt,
// sequential in health_history_queries.dart loadRange order
// restingHr → sleep → calories → spikes → hrv):
//  - readRestingHrHistory: ONE paginated readRecords range call
//    (RHR records ≈ 1/day) + ONE aggregateGroupByDuration fallback
//    (fires whenever any day lacks a record — effectively always).
//  - readSleepHistory: 6 chunks × 31 days, each a paginated
//    SleepSessionRecord read (≈1 page/chunk at 1–2 sessions/day).
//  - readCaloriesHistory: ONE aggregateGroupByDuration (2 metrics).
//  - readSpikeCounts: 6 chunks × 30 days of RAW HeartRateRecord
//    pages — every HR sample in the chunk crosses the bridge's
//    record layer and is processed sample-by-sample in Kotlin.
//    A watch sampling HR every ~5 min produces ~8,600 samples per
//    30-day chunk; at Health Connect's 1000-record pages and
//    batched records, that is multiple pages per chunk.
//  - readHrvSamples: 6 chunks × 31 days, paginated HRV records
//    (watch HRV every ~5 min ≈ 8,900 records/chunk at 1 record per
//    sample → up to ~9 pages/chunk), then the Dart side parses
//    every sample map and attributeDailyHrv aggregates them.
//
// The bridge Dart cores apply NO Dart-side timeout to these calls
// (health_connect_service.dart _read*Core: bare invokeMethod), so a
// read lasts exactly as long as the native work lasts. [BridgeCost]
// turns pages/chunks into durations under an explicit per-page cost
// assumption; the scenarios are printed by the tests so the
// calibration is auditable. The Dart-side record processing is
// MEASURED separately on this machine (report_repro_main_test).
import 'dart:math';

import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/medications.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';

/// Fixed anchor "now" for every repro run (the founder failure was
/// reported Fri 2026-11-13 morning, America/Denver).
final DateTime reproNow = DateTime(2026, 11, 13, 12, 0);

String dstr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

DateTime dayAt(int daysAgo) => DateTime(reproNow.year, reproNow.month,
    reproNow.day).subtract(Duration(days: daysAgo));

// ── Founder-shaped log data ──────────────────────────────────────
// 539 entries / 5 categories / ~404-day span (2025-10-06 →
// 2026-11-13). Founder counts: Symptoms 205, Medication 187,
// Sleep 39, Weight & Vitals 0. The fifth category (Notes, 108) is
// the harness-chosen remainder to reach 539 — disclosed in the
// report; the founder brief named only the four counts above.
const reproCategories = <QuickLogCategory>[
  QuickLogCategory(
      id: 1, name: 'Symptoms', icon: 'circle', colorHex: '#7C6EFF',
      isDefault: true, sortOrder: 0),
  QuickLogCategory(
      id: 2, name: 'Medication', icon: 'circle', colorHex: '#7C6EFF',
      isDefault: true, sortOrder: 1),
  QuickLogCategory(
      id: 3, name: 'Sleep', icon: 'circle', colorHex: '#7C6EFF',
      isDefault: true, sortOrder: 2),
  QuickLogCategory(
      id: 4, name: 'Weight & Vitals', icon: 'circle', colorHex: '#7C6EFF',
      isDefault: true, sortOrder: 3),
  QuickLogCategory(
      id: 5, name: 'Notes', icon: 'circle', colorHex: '#7C6EFF',
      isDefault: true, sortOrder: 4),
];

const Map<int, int> reproCategoryCounts = {1: 205, 2: 187, 3: 39, 4: 0, 5: 108};

List<QuickLogEntry> founderEntries() {
  final rnd = Random(42);
  final startMs = DateTime(2025, 10, 6).millisecondsSinceEpoch;
  const dayMs = 24 * 60 * 60 * 1000;
  final out = <QuickLogEntry>[];
  var id = 0;
  reproCategoryCounts.forEach((catId, count) {
    for (var i = 0; i < count; i++) {
      id++;
      out.add(QuickLogEntry(
        id: id,
        categoryId: catId,
        body: 'entry $id',
        chips: '',
        manualText: '',
        // 404-day span, composed under Random.nextInt's 2^32 cap.
        timestamp: startMs + rnd.nextInt(404) * dayMs + rnd.nextInt(dayMs),
      ));
    }
  });
  return out;
}

ReportProfileInput founderProfile() => ReportProfileInput(
      userContext: 'harness profile',
      age: 22,
      heightCm: 175,
      weightKg: 68,
      gender: 'M',
      conditions: const ['POTS', 'MCAS', 'hEDS'],
      activeMedications: [
        MedicationEntry(name: 'Med A', dose: '7.5 mg', startDate: '2026-01-01'),
        MedicationEntry(name: 'Med B', dose: '50 mg', startDate: '2026-02-01'),
        MedicationEntry(name: 'Med C', dose: '0.5', startDate: '2026-10-06'),
        MedicationEntry(name: 'Med D', dose: '0.05', startDate: '2026-10-06'),
        // Archived + deleted rows exercise the collector's filter.
        MedicationEntry(
            name: 'Old Med', dose: '10 mg', isPresent: false),
        MedicationEntry(name: 'Gone Med', dose: '5 mg', isDeleted: true),
      ],
    );

// ── Bridge cost model ────────────────────────────────────────────
class BridgeCost {
  final double perPageSec;
  final double chunkSetupSec;
  final double aggregateSec;
  final int spikesPagesPerChunk;
  final int hrvPagesPerChunk;
  final int sleepPagesPerChunk;
  final int rhrPages;
  final double scale; // 1.0 = full scale; 0.05 = 20× scaled run

  const BridgeCost({
    required this.perPageSec,
    required this.chunkSetupSec,
    required this.aggregateSec,
    required this.spikesPagesPerChunk,
    required this.hrvPagesPerChunk,
    this.sleepPagesPerChunk = 1,
    this.rhrPages = 1,
    this.scale = 1.0,
  });

  Duration _d(double sec) =>
      Duration(milliseconds: (sec * 1000 * scale).round());

  Duration get restingHr =>
      _d(chunkSetupSec + rhrPages * perPageSec + aggregateSec);
  Duration get sleep => _d(6 * (chunkSetupSec + sleepPagesPerChunk * perPageSec));
  Duration get calories => _d(aggregateSec);
  Duration get spikes =>
      _d(6 * (chunkSetupSec + spikesPagesPerChunk * perPageSec));
  Duration get hrv => _d(6 * (chunkSetupSec + hrvPagesPerChunk * perPageSec));
  double get totalSec => (restingHr + sleep + calories + spikes + hrv)
          .inMilliseconds /
      1000.0 /
      scale;

  String describe(String name) =>
      '$name: perPage=${perPageSec}s setup=${chunkSetupSec}s agg=${aggregateSec}s '
      'spikesPages/chunk=$spikesPagesPerChunk hrvPages/chunk=$hrvPagesPerChunk → '
      'rhr=${restingHr.inMilliseconds}ms sleep=${sleep.inMilliseconds}ms '
      'cal=${calories.inMilliseconds}ms spikes=${spikes.inMilliseconds}ms '
      'hrv=${hrv.inMilliseconds}ms TOTAL(modeled, unscaled)=${totalSec.toStringAsFixed(1)}s';
}

/// Light: sparse records, fast device. Modeled total ≈ 15 s.
const lightCost = BridgeCost(
    perPageSec: 0.3, chunkSetupSec: 0.1, aggregateSec: 0.8,
    spikesPagesPerChunk: 2, hrvPagesPerChunk: 3);

/// Mid: moderate density. Modeled total ≈ 49 s — under the bound.
const midCost = BridgeCost(
    perPageSec: 0.6, chunkSetupSec: 0.15, aggregateSec: 1.2,
    spikesPagesPerChunk: 5, hrvPagesPerChunk: 6);

/// Founder-heavy: dense watch data (HR + HRV every ~5 min),
/// ~1.1 s per Health Connect page call on a loaded phone.
/// Modeled total ≈ 133 s — over the 120 s F4 bound while every
/// individual read is finite (max single read ≈ 67 s HRV).
const heavyCost = BridgeCost(
    perPageSec: 1.1, chunkSetupSec: 0.2, aggregateSec: 1.6,
    spikesPagesPerChunk: 8, hrvPagesPerChunk: 10);

BridgeCost scaled(BridgeCost c, double s) => BridgeCost(
      perPageSec: c.perPageSec,
      chunkSetupSec: c.chunkSetupSec,
      aggregateSec: c.aggregateSec,
      spikesPagesPerChunk: c.spikesPagesPerChunk,
      hrvPagesPerChunk: c.hrvPagesPerChunk,
      sleepPagesPerChunk: c.sleepPagesPerChunk,
      rhrPages: c.rhrPages,
      scale: s,
    );

// ── Founder-shaped HC series (gappy, real-world values) ──────────
List<({String date, int bpm})> founderRhr() {
  final rnd = Random(7);
  return [
    for (var ago = 179; ago >= 0; ago--)
      if (ago % 7 != 3) // ~154 of 180 days present
        (date: dstr(dayAt(ago)), bpm: 52 + rnd.nextInt(17)),
  ];
}

List<({String date, int mins, int deep})> founderSleep() {
  final rnd = Random(11);
  return [
    for (var ago = 179; ago >= 0; ago--)
      if (ago % 5 != 2) // ~144 nights
        (
          date: dstr(dayAt(ago)),
          mins: 295 + rnd.nextInt(190),
          deep: 38 + rnd.nextInt(75),
        ),
  ];
}

List<({String date, int kcal})> founderCalories() {
  final rnd = Random(13);
  return [
    for (var ago = 179; ago >= 0; ago--)
      if (ago % 6 != 4) // ~150 days
        (date: dstr(dayAt(ago)), kcal: 1420 + rnd.nextInt(880)),
  ];
}

List<({String date, int count})> founderSpikes() {
  final rnd = Random(17);
  return [
    for (var ago = 179; ago >= 0; ago--)
      if (ago % 9 != 5) // ~160 days, 0 counts are real days
        (date: dstr(dayAt(ago)), count: rnd.nextInt(7)),
  ];
}

/// Raw HRV samples: watch-class density, every 5 min over ~16 h/day
/// for 170 of the last 180 days ≈ 32,640 samples, two tiers.
List<({int t, double ms, int tier})> founderHrvSamples() {
  final rnd = Random(19);
  final out = <({int t, double ms, int tier})>[];
  for (var ago = 179; ago >= 10; ago--) {
    final day = dayAt(ago);
    for (var s = 0; s < 192; s++) {
      final t = day.add(Duration(minutes: 240 + s * 5));
      out.add((
        t: t.millisecondsSinceEpoch,
        ms: 18 + rnd.nextDouble() * 47,
        tier: s % 11 == 0 ? 100 : 200,
      ));
    }
  }
  return out;
}

/// Seeds the REAL HealthHistoryStore (in-memory disk) with stored
/// daily rows: deep history the union serves alongside fresh HC,
/// with gaps that differ from the fresh series (union realism).
Future<HealthHistoryStore> seededStore() async {
  final disk = <String, String>{};
  final store = HealthHistoryStore.testInstance();
  store.debugSetStore(
    read: (k) async => disk[k],
    write: (k, v) async => disk[k] = v,
    delete: (k) async => disk.remove(k),
  );
  store.debugReset();
  final rnd = Random(23);
  final rows = <DailyBiometrics>[];
  for (var ago = 179; ago >= 0; ago--) {
    rows.add(DailyBiometrics(
      date: dstr(dayAt(ago)),
      restingHrBpm: ago % 4 == 1 ? null : 54 + rnd.nextInt(14),
      sleepMinutes: ago % 3 == 1 ? null : 310 + rnd.nextInt(170),
      deepSleepMinutes: ago % 3 == 1 ? null : 45 + rnd.nextInt(60),
      spikeCount: ago % 8 == 6 ? null : rnd.nextInt(6),
      caloriesKcal: ago % 5 == 2 ? null : 1500 + rnd.nextInt(700),
      hrvRmssdMs: ago % 4 == 3 ? null : 24 + rnd.nextDouble() * 34,
    ));
  }
  await store.mergeRefresh(rows);
  return store;
}

// ── Fake HC service: outcome variants overridden directly ────────
// (The union claims failure/partial signals from these outcome
// objects — health_history_queries.dart step 2b — so overriding
// the WithOutcome variants models the bridge exactly at the seam
// the production code consumes.)
class ModelHc extends HealthConnectService {
  ModelHc(this.cost, {this.failAll = false, this.partialSleepHrv = false});

  final BridgeCost cost;
  final bool failAll;
  final bool partialSleepHrv;
  final List<String> log = [];
  int probeCalls = 0;
  final Stopwatch _sw = Stopwatch();

  void _mark(String m, Duration d) =>
      log.add('$m start@${_sw.elapsedMilliseconds}ms dur=${d.inMilliseconds}ms');

  Future<HcReadOutcome<T>> _run<T>(
      String name, Duration delay, T Function() value) async {
    _sw.start();
    _mark(name, delay);
    await Future.delayed(delay);
    log.add('$name end@${_sw.elapsedMilliseconds}ms');
    if (failAll) {
      return HcReadOutcome(
          value: value(),
          errorCode: 'READ_FAILED',
          errorDetails: 'java.lang.SecurityException');
    }
    return HcReadOutcome(value: value());
  }

  @override
  Future<HcReadOutcome<List<({String date, int bpm})>>>
      readRestingHrHistoryWithOutcome(int days) =>
          _run('restingHr', cost.restingHr, founderRhr);

  @override
  Future<HcReadOutcome<List<({String date, int mins, int deep})>>>
      readSleepHistoryWithOutcome(int days) async {
    final o = await _run('sleep', cost.sleep, founderSleep);
    if (partialSleepHrv && !failAll) {
      return HcReadOutcome(
          value: o.value, partialCode: 'SLEEP_HISTORY_PARTIAL');
    }
    return o;
  }

  @override
  Future<HcReadOutcome<List<({String date, int kcal})>>>
      readCaloriesHistoryWithOutcome(int days) =>
          _run('calories', cost.calories, founderCalories);

  @override
  Future<HcReadOutcome<List<({String date, int count})>>>
      readSpikeCountsWithOutcome(int days) =>
          _run('spikes', cost.spikes, founderSpikes);

  @override
  Future<HcReadOutcome<List<({int t, double ms, int tier})>>>
      readHrvSamplesWithOutcome(int days) async {
    final o = await _run('hrv', cost.hrv, founderHrvSamples);
    if (partialSleepHrv && !failAll) {
      return HcReadOutcome(value: o.value, partialCode: 'HRV_SAMPLES_PARTIAL');
    }
    return o;
  }

  @override
  Future<HcAvailability> probeAvailability() async {
    probeCalls++;
    return HcAvailability(
      serviceAvailable: true,
      grantedPermissions: HealthConnectService.requiredPermissions,
      bridgeErrorCode: null,
      stepsProbe: HcReadProbeOutcome.ok,
      persistedConnected: true,
    );
  }
}

/// Backend seam fake (the r66 FakeBackend pattern): the collector's
/// three backend consumers return founder data instantly; the AI
/// leg is counted through the pipeline's injected aiCall instead.
class ReproBackend extends TabsBackend {
  ReproBackend({this.pullFails = false}) : super();
  final bool pullFails;
  int pullCalls = 0;
  int aiDetailedCalls = 0;

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async {
    pullCalls++;
    return pullFails ? null : <String, dynamic>{};
  }

  @override
  Future<List<QuickLogEntry>> fetchLogEntryDtos() async =>
      pullFails ? const [] : founderEntries();

  @override
  Future<List<BpRecord>> fetchManualBpLogs() async => const [];

  @override
  Future<
      ({
        int? statusCode,
        Map<String, dynamic>? body,
        String? serverError,
        AiTransportFailure? transportFailure,
      })> postAiDetailed(String path, Map<String, dynamic> body,
      {Duration? timeoutOverride}) async {
    aiDetailedCalls++;
    return (
      statusCode: 200,
      body: {'result': '[SECTION] SUMMARY\nok'},
      serverError: null,
      transportFailure: null,
    );
  }
}
