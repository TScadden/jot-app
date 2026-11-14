// VC 100133 Phase 6 — founder-real report fixtures (Sable).
//
// WHY THIS FILE EXISTS
// Report acceptance kept passing on synthetic fixtures while
// founder-real data failed in production:
//  - VC 100129: generation state lived in memory (process death);
//  - VC 100130: collection overran the 120 s deadline because every
//    fixture read was INSTANT, so the deadline never bit;
//  - VC 100131: connection loss mid-generation;
//  - VC 100132 (accuracy): the standard PDF printed
//    "Daily Score: Available (0 records)" over a store holding real
//    scores, the BP availability count contradicted the BP chart in
//    the same PDF, and a 42-day spike series was framed as a
//    180-day total.
// The pre-existing fixtures could not SEE those classes: 2-day
// series (r66), 2–3-day histories (availability truth), a 6-entry
// log set (clinician), and a founder-shaped harness
// (report_collect_bounds_harness.dart) whose coverage counts are
// seed-dependent (~154 RHR / ~144 sleep / ~150 calories / ~160
// spikes) and which carries no Daily Scores, no BP readings, no
// knowledge documents, and no clinician-path wiring.
//
// This library pins the VERIFIED founder shape (from the VC 100131
// production artifact + Bram's VC 100132 verification) with EXACT,
// rule-derived counts — no Random anywhere, so every count below is
// auditable arithmetic, not a seed artifact:
//
//  - 762 server log entries across 5 categories:
//    Symptoms 205, Medication 187, Sleep 39, Weight & Vitals 0
//    (a real zero-entry category), Notes 331 (the remainder).
//  - ~70K characters of knowledge documents (7 docs).
//  - 180-day biometric window ending [founderNow]:
//    HeartRate 180 days, Sleep 178, DeepSleep 177, HRV 177,
//    Calories 180 (the founder artifact's own counts).
//  - HR spikes PARTIAL in one shape: 42 fresh-window days against
//    the 180-day store (the VC 100132 shape); full 180 in another.
//  - Daily Scores: 24 of the last 30 days (the founder's clinician
//    figure), 99 of 180 overall.
//  - Manual BP: 4 readings in one shape, proven-clean-empty
//    (source present + parsed, zero readings) in another, and
//    unproven-empty in a third — the three Juno Ruling 2 states.
//  - One metric stored-only (and a whole-HC stored-only variant):
//    fresh reads fail, the store carries the days.
//  - Per-read latencies that are NOT instant: slow-read and
//    wedged-read (never-completing) variants, so deadline / budget
//    / cancel behavior is exercised at founder shape, in scaled
//    time (the collect-bounds harness's own convention).
//
// RUNTIME: the founder shape is data-volume-real but
// compute-cheap — 762 small entries, 180 store rows, plain fakes.
// A full collect + both PDF renders runs in well under a second on
// this VM; the sweep asserts a generous 10 s ceiling per collect so
// a future volume bump that breaks CI sanity fails loudly here
// first. Nothing in this file touches lib/.

import 'dart:async';

import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/medications.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';

import '../test_helpers.dart';

/// Fixed anchor "now": the founder failure date, Fri 2026-11-13
/// noon (America/Denver) — the same anchor the collect-bounds
/// harness and the VC 100132 accuracy suite use.
final DateTime founderNow = DateTime(2026, 11, 13, 12);

String founderDstr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// The calendar day [ago] days before [founderNow] (ago 0 = Nov 13).
DateTime founderDayAt(int ago) =>
    DateTime(founderNow.year, founderNow.month, founderNow.day)
        .subtract(Duration(days: ago));

String founderKey(int ago) => founderDstr(founderDayAt(ago));

// ── Categories / log entries ─────────────────────────────────────

const founderCategories = <QuickLogCategory>[
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

/// The founder's verified per-category counts. Weight & Vitals is
/// genuinely ZERO — the zero-entry category shape is part of the
/// full founder shape, not a separate toy fixture.
const founderCategoryCounts = <int, int>{1: 205, 2: 187, 3: 39, 4: 0, 5: 331};
const founderEntryTotal = 762;

/// 762 entries, timestamps spread deterministically across the
/// 180-day window (no Random: entry i lands `ago = (i * 37) % 180`
/// days back at 10:00, so both the all-time and the 30-day slices
/// are stable across runs).
List<QuickLogEntry> founderEntries() {
  final out = <QuickLogEntry>[];
  var id = 0;
  founderCategoryCounts.forEach((catId, count) {
    for (var i = 0; i < count; i++) {
      id++;
      final ago = (id * 37) % 180;
      out.add(QuickLogEntry(
        id: id,
        categoryId: catId,
        body: 'entry $id',
        chips: '',
        manualText: '',
        timestamp: founderDayAt(ago)
            .add(const Duration(hours: 10))
            .millisecondsSinceEpoch,
      ));
    }
  });
  return out;
}

// ── Biometric coverage rules (exact counts, see header) ──────────

bool founderHasHr(int ago) => true; // 180 of 180
bool founderHasSleep(int ago) => ago % 90 != 89; // misses 89, 179 → 178
bool founderHasDeep(int ago) =>
    founderHasSleep(ago) && ago != 100; // one more → 177
bool founderHasCalories(int ago) => true; // 180 of 180
bool founderHasHrv(int ago) =>
    ago != 50 && ago != 120 && ago != 179; // → 177

/// Daily Score presence: 24 of the last 30 days (missing when
/// ago % 5 == 4 inside the window), every other day before that
/// (75 of 150) → 99 of 180.
bool founderHasScore(int ago) =>
    ago < 30 ? ago % 5 != 4 : ago % 2 == 0;

const founderSleepDays = 178;
const founderDeepDays = 177;
const founderHrDays = 180;
const founderHrvDays = 177;
const founderCaloriesDays = 180;
const founderSpikeDaysFull = 180;
const founderSpikeDaysPartial = 42;
const founderScoreDays180 = 99;
const founderScoreDays30 = 24;

/// Deterministic per-day values ( mild variation, no Random).
int founderHrValue(int ago) => 58 + (ago * 7) % 13;
int founderSleepValue(int ago) => 380 + (ago * 13) % 121;
int founderDeepValue(int ago) => 60 + (ago * 7) % 51;
int founderCaloriesValue(int ago) => 1750 + (ago * 29) % 601;
double founderHrvValue(int ago) => 34.0 + (ago * 3) % 29;
int founderSpikeValue(int ago) => (ago * 5) % 7; // 0 counts are real days
int founderScoreValue(int ago) => 55 + (ago * 11) % 41;

/// Store rows for the 180-day window. Scores are NOT merged here —
/// they are written through persistScore by [seedFounderStore],
/// the only legitimate score write path (mirrors Bram's VC 100132
/// default-loader test).
List<DailyBiometrics> founderStoreRows({bool partialSpikes = false}) => [
      for (var ago = 179; ago >= 0; ago--)
        DailyBiometrics(
          date: founderKey(ago),
          restingHrBpm: founderHrValue(ago),
          sleepMinutes:
              founderHasSleep(ago) ? founderSleepValue(ago) : null,
          deepSleepMinutes:
              founderHasDeep(ago) ? founderDeepValue(ago) : null,
          caloriesKcal: founderCaloriesValue(ago),
          hrvRmssdMs: founderHasHrv(ago) ? founderHrvValue(ago) : null,
          spikeCount: (!partialSpikes || ago < founderSpikeDaysPartial)
              ? founderSpikeValue(ago)
              : null,
        ),
    ];

/// The stored-score map the clinician path reads (same source the
/// standard collector's default loader reads: store rows' scores).
Map<String, int> founderScoreMap() => {
      for (var ago = 179; ago >= 0; ago--)
        if (founderHasScore(ago)) founderKey(ago): founderScoreValue(ago),
    };

/// A REAL HealthHistoryStore on an in-memory disk, seeded with the
/// founder rows + write-once scores.
Future<HealthHistoryStore> seedFounderStore({
  bool partialSpikes = false,
}) async {
  final disk = <String, String>{};
  final store = HealthHistoryStore.testInstance();
  store.debugSetStore(
    read: (k) async => disk[k],
    write: (k, v) async => disk[k] = v,
    delete: (k) async => disk.remove(k),
  );
  store.debugReset();
  await store.mergeRefresh(founderStoreRows(partialSpikes: partialSpikes));
  for (final e in founderScoreMap().entries) {
    await store.persistScore(e.key, dailyScore: e.value);
  }
  return store;
}

// ── Knowledge documents (~70K chars) ─────────────────────────────

/// 7 documents totalling ~70,000 characters (the founder's
/// verified knowledge-base volume). Content is a repeated ruled
/// pattern: each document is a 7-char 'Doc N: ' prefix plus
/// 312 × the 32-char unit = 9,991 chars, so the exact total is
/// 7 × 9,991 = 69,937 chars (asserted via [founderKnowledgeChars],
/// never via the rounded ~70K figure).
List<String> founderKnowledgeDocs() {
  const unit = 'Founder knowledge pattern line. ';
  final doc = unit * (10000 ~/ unit.length);
  return [for (var i = 0; i < 7; i++) 'Doc ${i + 1}: $doc'];
}

int get founderKnowledgeChars =>
    founderKnowledgeDocs().fold<int>(0, (a, d) => a + d.length);

// ── Profile ──────────────────────────────────────────────────────

/// Founder-real profile: the VC 100132-verified medication set.
/// Ivabradine's stored frequency is BLANK (the founder truth Bram
/// pinned — the report path must never fabricate "Once daily");
/// Escitalopram is the archived/stopped entry; one deleted row
/// exercises the collector filter.
ReportProfileInput founderProfile() => ReportProfileInput(
      userContext: 'founder fixture profile',
      age: 22,
      heightCm: 175,
      weightKg: 68,
      gender: 'M',
      conditions: const ['POTS', 'MCAS', 'hEDS'],
      activeMedications: [
        MedicationEntry(
            name: 'Desvenlafaxine', dose: '50 mg',
            frequency: 'Once daily', startDate: 'Oct 17, 2026'),
        MedicationEntry(
            name: 'Ivabradine', dose: '7.5 mg',
            frequency: '', startDate: 'Oct 5, 2026'),
        MedicationEntry(
            name: 'BPC-157', dose: '0.05',
            frequency: 'Once daily', startDate: 'Oct 6, 2026'),
        MedicationEntry(
            name: 'SS-31', dose: '0.05',
            frequency: 'Once daily', startDate: 'Oct 6, 2026'),
        MedicationEntry(
            name: 'MOTS-c', dose: '0.10',
            frequency: 'Once daily', startDate: 'Nov 11, 2026'),
        MedicationEntry(
            name: 'Escitalopram', dose: '10 mg',
            frequency: 'Once daily', startDate: 'Sep 1, 2026',
            endDate: 'Oct 16, 2026', isPresent: false),
        MedicationEntry(name: 'Gone Med', dose: '5 mg', isDeleted: true),
      ],
      allMedications: [
        MedicationEntry(
            name: 'Desvenlafaxine', dose: '50 mg',
            frequency: 'Once daily', startDate: 'Oct 17, 2026'),
        MedicationEntry(
            name: 'Ivabradine', dose: '7.5 mg',
            frequency: '', startDate: 'Oct 5, 2026'),
        MedicationEntry(
            name: 'BPC-157', dose: '0.05',
            frequency: 'Once daily', startDate: 'Oct 6, 2026'),
        MedicationEntry(
            name: 'SS-31', dose: '0.05',
            frequency: 'Once daily', startDate: 'Oct 6, 2026'),
        MedicationEntry(
            name: 'MOTS-c', dose: '0.10',
            frequency: 'Once daily', startDate: 'Nov 11, 2026'),
        MedicationEntry(
            name: 'Escitalopram', dose: '10 mg',
            frequency: 'Once daily', startDate: 'Sep 1, 2026',
            endDate: 'Oct 16, 2026', isPresent: false),
        MedicationEntry(name: 'Gone Med', dose: '5 mg', isDeleted: true),
      ],
    );

const founderActiveMedCount = 5;

// ── Blood pressure shapes ────────────────────────────────────────

/// The founder's manual readings shape: 4 readings inside the
/// 180-day window (his VC 100131 chart proved readings exist while
/// availability denied them — count and chart must agree).
List<BpRecord> founderBpReadings() => [
      for (var i = 0; i < 4; i++)
        BpRecord(
          systolic: 112 + i * 6,
          diastolic: 74 + i * 3,
          timeEpochMs: founderDayAt(100 - i * 25)
              .add(const Duration(hours: 9))
              .millisecondsSinceEpoch,
        ),
    ];

// ── Backend fake ─────────────────────────────────────────────────

class FounderBackend extends TabsBackend {
  FounderBackend({
    List<QuickLogEntry>? entries,
    List<BpRecord>? bp,
    this.bpSourceParsed = true,
    this.pullFails = false,
    this.pullDelay = Duration.zero,
    this.hangPull = false,
  })  : entries = entries ?? founderEntries(),
        bp = bp ?? founderBpReadings(),
        super(sessionStore: FakeSessionStore());

  final List<QuickLogEntry> entries;
  final List<BpRecord> bp;

  /// Juno Ruling 2's clean-empty signal: true = the sync pull
  /// succeeded AND its manual-BP field was present and parsed.
  final bool bpSourceParsed;
  final bool pullFails;
  final Duration pullDelay;

  /// A sync pull that never completes (backend-stage wedge).
  final bool hangPull;

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async {
    if (hangPull) return Completer<Map<String, dynamic>?>().future;
    if (pullDelay > Duration.zero) await Future<void>.delayed(pullDelay);
    return pullFails ? null : <String, dynamic>{};
  }

  @override
  Future<List<QuickLogEntry>> fetchLogEntryDtos() async => entries;

  @override
  Future<List<BpRecord>> fetchManualBpLogs() async => bp;

  @override
  Future<bool> manualBpSourceParsed() async =>
      !pullFails && bpSourceParsed;
}

// ── Health Connect fake (founder fresh window + latency) ─────────

/// Fresh HC serves the most recent 42 days (the collector's own
/// fresh-scan cap; HC retention is weeks — the store carries the
/// rest of the 180-day window). Values match the store's for those
/// days, as a real union source would.
///
/// Latency/failure knobs (all per-metric, by union metric name:
/// 'restingHr', 'sleep', 'calories', 'spikes', 'hrv'):
///  - [perReadDelay]: every read takes this long (slow-read shape);
///  - [wedged]: the named reads NEVER complete (wedged-read shape);
///  - [failGeneric]: the named reads fail with a generic
///    (non-SecurityException) detail — with store data present the
///    honest derivation is storedOnly, never a denial.
class FounderHc extends HealthConnectService {
  FounderHc({
    this.perReadDelay = Duration.zero,
    this.wedged = const {},
    this.failGeneric = const {},
  });

  final Duration perReadDelay;
  final Set<String> wedged;
  final Set<String> failGeneric;

  /// Fetch depths requested, in read order (union order:
  /// restingHr, sleep, calories, spikes, hrv).
  final List<int> requestedDays = [];

  Future<HcReadOutcome<T>> _run<T>(
      String metric, T Function() value) async {
    if (wedged.contains(metric)) {
      return Completer<HcReadOutcome<T>>().future;
    }
    if (perReadDelay > Duration.zero) {
      await Future<void>.delayed(perReadDelay);
    }
    if (failGeneric.contains(metric)) {
      return HcReadOutcome(
        value: value(),
        errorCode: 'READ_FAILED',
        errorDetails: 'java.io.IOException',
      );
    }
    return HcReadOutcome(value: value());
  }

  /// Fresh-window slice: the last 42 days of a founder series.
  List<({String date, int v})> _fresh(bool Function(int ago) has,
          int Function(int ago) value) =>
      [
        for (var ago = 41; ago >= 0; ago--)
          if (has(ago)) (date: founderKey(ago), v: value(ago)),
      ];

  @override
  Future<HcReadOutcome<List<({String date, int bpm})>>>
      readRestingHrHistoryWithOutcome(int days) {
    requestedDays.add(days);
    return _run(
        'restingHr',
        () => [
              for (final r in _fresh(founderHasHr, founderHrValue))
                (date: r.date, bpm: r.v),
            ]);
  }

  @override
  Future<HcReadOutcome<List<({String date, int mins, int deep})>>>
      readSleepHistoryWithOutcome(int days) {
    requestedDays.add(days);
    return _run(
        'sleep',
        () => [
              for (var ago = 41; ago >= 0; ago--)
                if (founderHasSleep(ago))
                  (
                    date: founderKey(ago),
                    mins: founderSleepValue(ago),
                    deep: founderHasDeep(ago) ? founderDeepValue(ago) : 0,
                  ),
            ]);
  }

  @override
  Future<HcReadOutcome<List<({String date, int kcal})>>>
      readCaloriesHistoryWithOutcome(int days) {
    requestedDays.add(days);
    return _run(
        'calories',
        () => [
              for (final r in _fresh(founderHasCalories, founderCaloriesValue))
                (date: r.date, kcal: r.v),
            ]);
  }

  @override
  Future<HcReadOutcome<List<({String date, int count})>>>
      readSpikeCountsWithOutcome(int days) {
    requestedDays.add(days);
    return _run(
        'spikes',
        () => [
              for (var ago = 41; ago >= 0; ago--)
                (date: founderKey(ago), count: founderSpikeValue(ago)),
            ]);
  }

  @override
  Future<HcReadOutcome<List<({int t, double ms, int tier})>>>
      readHrvSamplesWithOutcome(int days) {
    requestedDays.add(days);
    return _run(
        'hrv',
        () => [
              for (var ago = 41; ago >= 0; ago--)
                if (founderHasHrv(ago))
                  (
                    t: founderDayAt(ago)
                        .add(const Duration(hours: 12))
                        .millisecondsSinceEpoch,
                    ms: founderHrvValue(ago),
                    tier: 100,
                  ),
            ]);
  }

  @override
  Future<HcAvailability> probeAvailability() async => const HcAvailability(
        serviceAvailable: true,
        grantedPermissions: {},
        bridgeErrorCode: null,
        stepsProbe: null,
        persistedConnected: true,
      );
}

// ── Collector wiring (production shape) ──────────────────────────

/// A ReportDataCollector wired exactly as production wires it:
/// NO injected scoreLoader (the default store read is the
/// production path — Bram's VC 100132 coverage rule), the caller's
/// store shared between the union queries and the score read, the
/// founder knowledge docs as the documents stage, and no
/// correlation insights (the founder store holds none in the
/// verified runs; the insights stage is covered by its own suites).
ReportDataCollector founderCollector({
  required FounderHc hc,
  required HealthHistoryStore store,
  FounderBackend? backend,
  Duration? collectTimeout,
  Future<List<String>> Function()? documentsLoader,
}) =>
    ReportDataCollector(
      backend: backend ?? FounderBackend(),
      hc: hc,
      historyQueries: HealthHistoryQueries(hc: hc, store: store),
      documentsLoader:
          documentsLoader ?? (() async => founderKnowledgeDocs()),
      insightsLoader: () async => const [],
      collectTimeout: collectTimeout,
    );

Future<ReportSnapshot> collectFounder(
  ReportDataCollector collector, {
  bool last30Days = false,
  List<QuickLogCategory> selected = founderCategories,
  bool Function()? isCancelled,
}) =>
    collector.collect(
      selectedCategories: selected,
      last30Days: last30Days,
      profile: founderProfile(),
      isCancelled: isCancelled,
      now: founderNow,
    );
