import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/hc_availability.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_history_sync.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weekly_snapshot.dart';

import 'test_helpers.dart';

/// Report Reliability Phase 2, PR-3 — the P2 identity fixtures
/// (design §5, the centerpiece evidence of this PR).
///
/// For EACH injected availability state, BOTH derivations run
/// over the SAME fake service + the SAME store:
///   (a) the report collector's per-metric derivation
///       (ReportDataCollector → sectionMetadata statuses), and
///   (b) the capture path's derivation
///       (HealthHistorySync.deriveCaptureMetricStatus over the
///       capture's OWN recorded outcome evidence —
///       HealthHistorySync.lastCaptureEvidence — plus the store's
///       post-capture data presence),
/// and the per-metric availability states are asserted IDENTICAL
/// under the mapping table below, and equal to the state's
/// expected status. Every cell of the matrix is asserted; no
/// cell is hand-waved.
///
/// ── MAPPING TABLE (report DataSourceStatus ↔ capture path) ──
///
/// Report section      Capture leg     Capture-side inputs
/// ──────────────────  ──────────────  ─────────────────────────
/// heartRate           restingHr       evidence['restingHr'],
///                                     store restingHrBpm presence
/// sleep               sleep           evidence['sleep'],
///                                     store sleepMinutes presence
/// deepSleep           sleep (mirror)  evidence['sleep'],
///                                     store deepSleepMinutes
///                                     presence — the report's
///                                     deepSleep section mirrors
///                                     sleep's evidence with its
///                                     own emptiness (Phase 1,
///                                     Juno §3); the capture has
///                                     ONE sleep leg producing
///                                     both fields, so its
///                                     deepSleep state derives
///                                     from that same leg.
/// hrv                 hrv             evidence['hrv'],
///                                     store hrvRmssdMs presence
/// calories            calories        evidence['calories'],
///                                     store caloriesKcal presence
/// hrSpikes            spikes          evidence['spikes'],
///                                     store spikeCount presence
///
/// Both sides feed THE shared derivation (deriveMetricStatus)
/// with the same-named inputs: grant from ONE probeAvailability()
/// snapshot's missing set via hcMetricGrantState (the collector
/// fetches its own snapshot per collect; the capture side here
/// reads the same fake's snapshot — the fake's grant layer is
/// fixed per state, so both snapshots are the same evidence),
/// partialRead / readFailed / readSecurityException from each
/// surface's OWN read outcomes, and data presence from the union
/// (report) / the post-capture store (capture — capture is
/// merge-only, so a failed leg's surviving store data is exactly
/// what the union surfaces from the store).
///
/// Run order per state: capture FIRST (its evidence + the
/// post-capture store are snapshotted into capture-side statuses
/// immediately), then the collector over the same store. Capture
/// is merge-only and the collector's union merges the same fresh
/// rows, so neither run can manufacture data presence the other
/// did not have.
///
/// Vera PR-2 Note A applies: these fixtures fake the PR-1/PR-3
/// seams (probeAvailability, the outcome variants,
/// lastCaptureEvidence) and therefore assert identity AT HEAD
/// only — no base parity is claimed for them.
///
/// Vera PR-2 Note B is pinned by the stale state below and by
/// the dedicated stale × repository test: a stale-wedged
/// snapshot's status is `connected`, so
/// HealthRepository._connected() is true and capture IS
/// attempted; all five capture reads return stale outcomes
/// (per-metric failure codes, SecurityException details);
/// the failures are recorded in the store's capture
/// diagnostics; the derived per-metric states are `stale` on
/// BOTH surfaces; and no score is computed or stored (the
/// store holds no days at all — every read failed and nothing
/// merged).

const _sleepPerm = 'android.permission.health.READ_SLEEP';

final _now = DateTime(2026, 10, 21, 12);
const _day = '2026-10-20';

/// How one metric's fresh read behaves in a fixture state.
enum _Mode {
  data, // clean read, rows returned
  empty, // clean read, no rows
  failGeneric, // failure code + IOException detail
  failSecurity, // failure code + SecurityException detail (stale)
  partial, // rows returned + partial code (HRV staging)
}

const _codes = <String, String>{
  'restingHr': 'RHR_HISTORY_READ_FAILED',
  'sleep': 'SLEEP_HISTORY_READ_FAILED',
  'hrv': 'HRV_SAMPLES_READ_FAILED',
  'calories': 'CALORIES_HISTORY_READ_FAILED',
  'spikes': 'SPIKE_COUNTS_READ_FAILED',
};

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

/// One fake staging ONE availability state for both surfaces.
/// The legacy reads are overridden in the real service's
/// fail-closed shape (slots set before return), so the outcome
/// variants reconstruct each read's outcome from its own signals
/// exactly as they do for every existing capture/union fake.
class _FakeHc extends HealthConnectService {
  Set<String> missing = const {};
  bool staleProbe = false;
  final Map<String, _Mode> modes = {
    'restingHr': _Mode.data,
    'sleep': _Mode.data,
    'hrv': _Mode.data,
    'calories': _Mode.data,
    'spikes': _Mode.data,
  };
  final Map<String, int> readCounts = {};

  void stageAll(_Mode mode) {
    for (final k in modes.keys) {
      modes[k] = mode;
    }
  }

  @override
  Future<HcAvailability> probeAvailability() async => HcAvailability(
        serviceAvailable: true,
        grantedPermissions:
            HealthConnectService.requiredPermissions.difference(missing),
        bridgeErrorCode: null,
        stepsProbe: staleProbe
            ? HcReadProbeOutcome.securityFailure
            : (missing.isEmpty ? HcReadProbeOutcome.ok : null),
        persistedConnected: false,
      );

  bool _fail(String metric) {
    readCounts[metric] = (readCounts[metric] ?? 0) + 1;
    switch (modes[metric]!) {
      case _Mode.failGeneric:
        lastReadErrorCode = _codes[metric];
        lastReadErrorDetails = 'IOException';
        return true;
      case _Mode.failSecurity:
        lastReadErrorCode = _codes[metric];
        lastReadErrorDetails = 'SecurityException';
        return true;
      case _Mode.data:
      case _Mode.empty:
      case _Mode.partial:
        return false;
    }
  }

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
          int days) async =>
      _fail('restingHr') || modes['restingHr'] == _Mode.empty
          ? const []
          : const [(date: _day, bpm: 62)];

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
          int days) async =>
      _fail('sleep') || modes['sleep'] == _Mode.empty
          ? const []
          : const [(date: _day, mins: 450, deep: 90)];

  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(
      int days) async {
    if (_fail('hrv') || modes['hrv'] == _Mode.empty) return const [];
    if (modes['hrv'] == _Mode.partial) {
      lastPartialErrorCode = 'HRV_SAMPLES_PARTIAL';
      lastReadErrorDetails = 'SecurityException';
    }
    return [
      (t: DateTime(2026, 10, 20, 12).millisecondsSinceEpoch, ms: 55.0, tier: 100),
    ];
  }

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(
          int days) async =>
      _fail('calories') || modes['calories'] == _Mode.empty
          ? const []
          : const [(date: _day, kcal: 2100)];

  @override
  Future<List<({String date, int count})>> readSpikeCounts(
          int days) async =>
      _fail('spikes') || modes['spikes'] == _Mode.empty
          ? const []
          : const [(date: _day, count: 2)];
}

void main() {
  late Map<String, String> disk;
  late HealthHistoryStore store;
  late _FakeHc hc;
  late HealthHistorySync sync;

  setUp(() {
    HealthHistorySync.debugResetFlight();
    disk = <String, String>{};
    store = HealthHistoryStore.testInstance();
    store.debugSetStore(
      read: (k) async => disk[k],
      write: (k, v) async => disk[k] = v,
      delete: (k) async => disk.remove(k),
    );
    store.debugReset();
    hc = _FakeHc();
    sync = HealthHistorySync.withDeps(hc: hc, store: store, now: () => _now);
  });

  tearDown(() {
    HealthHistorySync.debugResetFlight();
  });

  /// The capture path's per-metric states, derived from the
  /// capture's OWN recorded evidence + post-capture store
  /// presence, through the shared derivation.
  Future<Map<String, DataSourceStatus>> captureStatuses() async {
    final all = await store.readAll();
    bool has(String metric) => all.values.any((d) => switch (metric) {
          'restingHr' => d.restingHrBpm != null,
          'sleep' => d.sleepMinutes != null,
          'hrv' => d.hrvRmssdMs != null,
          'calories' => d.caloriesKcal != null,
          'spikes' => d.spikeCount != null,
          _ => false,
        });
    final snapshot = await hc.probeAvailability();
    final missingSet =
        snapshot.grantKnown ? snapshot.missingPermissions : null;
    return {
      for (final metric in _codes.keys)
        metric: HealthHistorySync.deriveCaptureMetricStatus(
          grant: hcMetricGrantState(
              HealthHistorySync.historyMetricForCaptureMetric(metric)!,
              missingSet),
          evidence: sync.lastCaptureEvidence[metric]!,
          storeHasData: has(metric),
        ),
    };
  }

  /// The report collector's per-metric states, keyed by the
  /// capture metric names under the mapping table.
  Future<Map<String, DataSourceStatus>> reportStatuses() async {
    final snap = await ReportDataCollector(
      backend: _Backend(),
      hc: hc,
      historyQueries: HealthHistoryQueries(hc: hc, store: store),
    ).collect(
      selectedCategories: const [],
      last30Days: true,
      profile: const ReportProfileInput(),
      now: _now,
    );
    DataSourceStatus st(String key) => snap.sectionMetadata[key]!.status;
    // deepSleep mirrors the sleep leg: assert the mirror itself
    // against the capture-side derivation for deep presence.
    final all = await store.readAll();
    final deepCapture = HealthHistorySync.deriveCaptureMetricStatus(
      grant: hcMetricGrantState(HistoryMetric.sleep,
          (await hc.probeAvailability()).missingPermissions),
      evidence: sync.lastCaptureEvidence['sleep']!,
      storeHasData: all.values.any((d) => d.deepSleepMinutes != null),
    );
    expect(st('deepSleep'), deepCapture,
        reason: 'deepSleep (report) must equal the capture sleep '
            'leg derived over deep-sleep presence');
    return {
      'restingHr': st('heartRate'),
      'sleep': st('sleep'),
      'hrv': st('hrv'),
      'calories': st('calories'),
      'spikes': st('hrSpikes'),
    };
  }

  /// Runs one matrix state end to end and asserts both surfaces
  /// equal [expected] cell for cell.
  Future<void> runState(
    String name,
    Map<String, DataSourceStatus> expected, {
    Future<void> Function()? extraCaptureAsserts,
  }) async {
    final ran = await sync.capture(force: true);
    expect(ran, isTrue, reason: '$name: capture must run');
    final captureSide = await captureStatuses();
    if (extraCaptureAsserts != null) await extraCaptureAsserts();
    final reportSide = await reportStatuses();
    for (final metric in _codes.keys) {
      expect(captureSide[metric], expected[metric],
          reason: '$name / $metric: capture-path state');
      expect(reportSide[metric], expected[metric],
          reason: '$name / $metric: report state');
      expect(captureSide[metric], reportSide[metric],
          reason: '$name / $metric: surfaces must be IDENTICAL');
    }
  }

  const allSuccess = <String, DataSourceStatus>{
    'restingHr': DataSourceStatus.success,
    'sleep': DataSourceStatus.success,
    'hrv': DataSourceStatus.success,
    'calories': DataSourceStatus.success,
    'spikes': DataSourceStatus.success,
  };

  test('healthy — full grant, all reads return data: success everywhere',
      () async {
    await runState('healthy', allSuccess);
  });

  test('per-metric grant missing (sleep) — sleep is permissionDenied, '
      'the rest stay success', () async {
    hc.modes['sleep'] = _Mode.failGeneric;
    hc.missing = {_sleepPerm};
    await runState('grant-missing-sleep', {
      ...allSuccess,
      'sleep': DataSourceStatus.permissionDenied,
    }, extraCaptureAsserts: () async {
      expect(store.lastCaptureDiagnostics['sleep']?.errorCode,
          'SLEEP_HISTORY_READ_FAILED');
      expect(sync.lastCaptureEvidence['sleep']!.readFailed, isTrue);
      expect(sync.lastCaptureEvidence['sleep']!.readSecurityException,
          isFalse);
    });
  });

  test('per-metric stale wedge — all reads blocked with '
      'SecurityException, grants complete: stale everywhere', () async {
    hc.stageAll(_Mode.failSecurity);
    hc.staleProbe = true;
    await runState('stale-wedge', {
      for (final m in _codes.keys) m: DataSourceStatus.stale,
    }, extraCaptureAsserts: () async {
      // The wedge in capture's own terms: every leg's evidence
      // carries its failure + the SecurityException signature,
      // and the persisted diagnostics record every leg's code.
      for (final metric in _codes.keys) {
        final ev = sync.lastCaptureEvidence[metric]!;
        expect(ev.readFailed, isTrue, reason: '$metric failed');
        expect(ev.readSecurityException, isTrue,
            reason: '$metric carries the stale signature');
        expect(store.lastCaptureDiagnostics[metric]?.errorCode,
            _codes[metric],
            reason: '$metric diagnostics record its read code');
      }
      // No data merged, no score computed or stored.
      expect(await store.dayCount(), 0);
    });
  });

  test('generic read failure — all reads fail without the stale '
      'signature and without a grant gap: error everywhere', () async {
    hc.stageAll(_Mode.failGeneric);
    await runState('generic-failure', {
      for (final m in _codes.keys) m: DataSourceStatus.error,
    });
  });

  test('stored-only — live reads fail, the store is populated: '
      'storedOnly everywhere', () async {
    await store.mergeRefresh([
      const DailyBiometrics(
        date: _day,
        restingHrBpm: 61,
        sleepMinutes: 430,
        deepSleepMinutes: 85,
        spikeCount: 1,
        caloriesKcal: 2000,
        hrvRmssdMs: 50.0,
      ),
    ]);
    hc.stageAll(_Mode.failGeneric);
    await runState('stored-only', {
      for (final m in _codes.keys) m: DataSourceStatus.storedOnly,
    });
  });

  test('absent — clean reads, nothing live, nothing stored: '
      'noData everywhere', () async {
    hc.stageAll(_Mode.empty);
    await runState('absent', {
      for (final m in _codes.keys) m: DataSourceStatus.noData,
    });
  });

  test('partial-read — HRV returns data with a partial signal: '
      'hrv is error on both surfaces, the rest stay success; the '
      'HRV partial is NOT a capture failure and scoring is '
      'suppressed', () async {
    hc.modes['hrv'] = _Mode.partial;
    await runState('partial-hrv', {
      ...allSuccess,
      'hrv': DataSourceStatus.error,
    }, extraCaptureAsserts: () async {
      final ev = sync.lastCaptureEvidence['hrv']!;
      expect(ev.partialRead, isTrue);
      expect(ev.readFailed, isFalse);
      // The HRV partial special-case, exactly: the diagnostics
      // entry carries the partial code and NO error code, with
      // the surviving samples counted.
      final diag = store.lastCaptureDiagnostics['hrv']!;
      expect(diag.errorCode, isNull);
      expect(diag.partialCode, 'HRV_SAMPLES_PARTIAL');
      expect(diag.sampleCount, 1);
      expect(diag.dayCount, 1);
      // The partial data merged, but the partial capture must
      // not score: the day it produced stays unscored, and the
      // HRV backfill stays incomplete.
      final day = (await store.readAll())[_day]!;
      expect(day.hrvRmssdMs, 55.0);
      expect(day.dailyScore, isNull,
          reason: 'a partial capture never runs the score compute');
      expect(store.hrvBackfillComplete, isFalse);
    });
  });

  test('stale × repository/capture trigger (Vera PR-2 Note B) — '
      'the probe snapshot status is connected, so _connected() is '
      'true and capture IS attempted; all five reads return stale '
      'outcomes; diagnostics record them; no score is stored',
      () async {
    hc.stageAll(_Mode.failSecurity);
    hc.staleProbe = true;

    // The snapshot semantics PR-2 signed: stale arrives as data;
    // status is connected (the wedge rides in staleWedged).
    final snapshot = await hc.probeAvailability();
    expect(snapshot.staleWedged, isTrue);
    expect(snapshot.status, HealthConnectStatus.connected,
        reason: 'HealthRepository._connected() derives '
            'status == connected, so the capture trigger fires');

    final repo = HealthRepository(
      hc: hc,
      backend: _Backend(),
      historySync: sync,
      historyQueries: HealthHistoryQueries(hc: hc, store: store),
    );
    await repo.loadSnapshot(SnapshotMetric.sleepHours);

    // The capture is fire-and-forget from the repository: poll
    // (bounded) until its diagnostics land on the store.
    var landed = false;
    for (var i = 0; i < 100 && !landed; i++) {
      landed = store.lastCaptureDiagnostics.length == 5;
      if (!landed) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    expect(landed, isTrue,
        reason: 'the triggered capture must run and record its '
            'diagnostics under the stale wedge');
    for (final metric in _codes.keys) {
      expect(hc.readCounts[metric], greaterThanOrEqualTo(1),
          reason: '$metric: capture attempted its read');
      expect(store.lastCaptureDiagnostics[metric]?.errorCode,
          _codes[metric],
          reason: '$metric: diagnostics record the stale read');
      final ev = sync.lastCaptureEvidence[metric]!;
      expect(ev.readFailed, isTrue, reason: '$metric failed');
      expect(ev.readSecurityException, isTrue,
          reason: '$metric carries the stale signature');
    }
    // Scoring is suppressed in outcome: the store holds no days
    // (every read failed, nothing merged), so no score could be
    // computed or stored for any day.
    expect(await store.dayCount(), 0);
    final all = await store.readAll();
    expect(all.values.any((d) => d.dailyScore != null), isFalse);
  });
}
