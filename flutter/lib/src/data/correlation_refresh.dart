import 'correlation_engine.dart';
import 'correlation_insight_store.dart';
import 'health_history_store.dart';
import 'medication_change_events.dart';
import 'quick_log_models.dart';
import 'settings_store.dart';
import 'tabs_backend.dart';
import '../features/home/intake_logging.dart';

/// Phase 1, item 5 — production input assembly + refresh (spec
/// §6: compute in the existing background cadence, never on open).
///
/// The refresher assembles the engine's inputs the way Today
/// Summary does (TabsBackend.fetchLogEntryDtos /
/// fetchLogCategories over the sync pull) plus the local
/// HealthHistoryStore, computes fresh fingerprints, and recomputes
/// ONLY the splits whose fingerprint changed. It never throws:
/// background work fails silently, and a stale record keeps
/// rendering with its honest through-date until a recompute lands.
///
/// PROVIDER GAPS — CLOSED at the VC 100109 combine: the two
/// inputs that had no read path in the item-5 branch's tree now
/// plug into the exact seams below. The production refresher
/// (see [CorrelationRefresher.production]) uses
/// [SettingsIntakeTargetHistoryProvider] (item 4's real store)
/// and [BackendMedChangeEventProvider] (the unified
/// `GET /api/sync/medication-events` read path item 2b added).
/// The Empty providers remain as the constructor defaults for
/// tests and fail-safe contexts; the engine handles empty
/// honestly (F2 target splits stay unclassifiable, F5 renders
/// its S7 unavailable record).

/// Production target-history provider: empty until item 4's store
/// lands (see the file header).
class EmptyIntakeTargetHistoryProvider implements IntakeTargetHistoryProvider {
  const EmptyIntakeTargetHistoryProvider();

  @override
  Future<List<IntakeTargetHistoryEntry>> loadTargetHistory() async => const [];
}

/// Production med-event provider: empty until a med-event GET
/// read path lands (see the file header).
class EmptyMedChangeEventProvider implements MedChangeEventProvider {
  const EmptyMedChangeEventProvider();

  @override
  Future<List<MedChangeEventInput>> loadMedChangeEvents() async => const [];
}

/// Production target-history provider (VC 100109 combine): reads
/// item 4's REAL versioned target store — `IntakeSettings` over
/// the shared [SettingsStore] (`intake_targets_v1`, device-local)
/// — and adapts each [IntakeTargetVersion] to the engine's
/// contract shape. A version's stored `effectiveFromDayMs` IS an
/// energy-day start (04:00 local, the feelingDayStart rule), so
/// its engine day key is `energyDayLabel` of that instant — the
/// same label the engine stamps on entry days. Fail-safe: the
/// store's loader already degrades to an empty history on any
/// read failure, never a throw, never an invented target.
class SettingsIntakeTargetHistoryProvider
    implements IntakeTargetHistoryProvider {
  final Future<List<IntakeTargetVersion>> Function() _loadVersions;

  SettingsIntakeTargetHistoryProvider({
    Future<List<IntakeTargetVersion>> Function()? loadVersions,
  }) : _loadVersions =
           loadVersions ??
           (() => IntakeSettings(SettingsStore()).loadTargets());

  @override
  Future<List<IntakeTargetHistoryEntry>> loadTargetHistory() async {
    final versions = await _loadVersions();
    return [
      for (final v in versions)
        IntakeTargetHistoryEntry(
          fluidTargetMl: v.fluidTargetMl,
          sodiumTargetMg: v.sodiumTargetMg,
          effectiveFromDay: energyDayLabel(v.effectiveFromDayMs),
        ),
    ];
  }
}

/// Adapts one captured event from the item 2a read contract
/// ([MedicationChangeEvent]) to the engine's input shape
/// ([MedChangeEventInput]) — a field-for-field projection; both
/// shapes carry the same contract, nothing is reinterpreted.
MedChangeEventInput medChangeEventInputFromEvent(MedicationChangeEvent e) {
  MedFieldSnapshot? snap(MedicationFieldSnapshot? s) => s == null
      ? null
      : MedFieldSnapshot(
          dose: s.dose,
          frequency: s.frequency,
          startDate: s.startDate,
          endDate: s.endDate,
          isPresent: s.isPresent,
        );
  return MedChangeEventInput(
    id: e.id,
    medId: e.medId,
    medName: e.medName,
    type: e.type,
    oldSnapshot: snap(e.oldSnapshot),
    newSnapshot: snap(e.newSnapshot),
    effectiveDate: e.effectiveDate,
    recordedAt: e.recordedAt,
    source: e.source,
  );
}

/// Production med-event provider (VC 100109 combine): reads the
/// unified medication-event read path —
/// [TabsBackend.fetchMedicationChangeEvents] (the GET item 2b
/// added, live since VC 100108). A failed fetch (null) degrades
/// to an empty event list: the refresher's posture is
/// never-throw, and F5 renders its honest no-changes state until
/// a successful refresh lands real events.
class BackendMedChangeEventProvider implements MedChangeEventProvider {
  final TabsBackend _backend;

  BackendMedChangeEventProvider({TabsBackend? backend})
    : _backend = backend ?? TabsBackend();

  @override
  Future<List<MedChangeEventInput>> loadMedChangeEvents() async {
    final events = await _backend.fetchMedicationChangeEvents();
    if (events == null) return const [];
    return [for (final e in events) medChangeEventInputFromEvent(e)];
  }
}

/// What one refresh did — returned for tests and diagnostics; the
/// refresher never throws, so a failed refresh is a value.
class CorrelationRefreshOutcome {
  /// Whether input assembly succeeded and the stale check ran.
  final bool ran;

  /// Store keys recomputed and written this run.
  final int recomputedCount;

  /// Store keys whose fingerprints already matched.
  final int unchangedCount;

  /// Why the run did not complete, when it didn't: 'error'.
  final String? skippedReason;

  const CorrelationRefreshOutcome({
    this.ran = false,
    this.recomputedCount = 0,
    this.unchangedCount = 0,
    this.skippedReason,
  });
}

String _dayKeyOf(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// One stale-checked correlation refresh. All dependencies are
/// injectable; [CorrelationRefresher.production] wires the real
/// singletons of whichever isolate it runs in.
class CorrelationRefresher {
  final TabsBackend _backend;
  final HealthHistoryStore _historyStore;
  final CorrelationInsightStore _insightStore;
  final IntakeTargetHistoryProvider _targetProvider;
  final MedChangeEventProvider _medEventProvider;
  final Future<String?> Function() _readEmail;
  final DateTime Function() _now;

  CorrelationRefresher({
    required TabsBackend backend,
    required this._historyStore,
    required this._insightStore,
    this._targetProvider = const EmptyIntakeTargetHistoryProvider(),
    this._medEventProvider = const EmptyMedChangeEventProvider(),
    Future<String?> Function()? readEmail,
    DateTime Function()? now,
  }) : _backend = backend,
       _readEmail = readEmail ?? backend.readEmail,
       _now = now ?? DateTime.now;

  factory CorrelationRefresher.production() {
    final backend = TabsBackend();
    return CorrelationRefresher(
      backend: backend,
      historyStore: HealthHistoryStore.instance,
      insightStore: CorrelationInsightStore.instance,
      // VC 100109 combine: the real read paths behind the seams
      // (item 4's target store; the item 2b med-event GET).
      targetProvider: SettingsIntakeTargetHistoryProvider(),
      medEventProvider: BackendMedChangeEventProvider(backend: backend),
    );
  }

  /// Assembles inputs, recomputes only the splits whose
  /// fingerprint changed, and writes those records. Never throws.
  Future<CorrelationRefreshOutcome> refreshIfStale() async {
    try {
      String? email;
      try {
        email = await _readEmail();
      } catch (_) {
        email = null;
      }
      await _insightStore.warmFromDisk(currentEmail: email);

      // The Today Summary pattern: entries + categories from the
      // sync pull, biometrics from the local history store.
      final results = await Future.wait<Object?>([
        _backend.fetchLogEntryDtos(),
        _backend.fetchLogCategories(),
        _historyStore.readAll(),
        _targetProvider.loadTargetHistory(),
        _medEventProvider.loadMedChangeEvents(),
      ]);
      final inputs = CorrelationInputs(
        entries: results[0] as List<QuickLogEntry>,
        categories: results[1] as List<QuickLogCategory>,
        biometrics: results[2] as Map<String, DailyBiometrics>,
        targetHistory: results[3] as List<IntakeTargetHistoryEntry>,
        medEvents: results[4] as List<MedChangeEventInput>,
        nowDayKey: _dayKeyOf(_now()),
      );

      final fresh = computeCorrelationFingerprints(inputs);
      final stored = await _insightStore.readAll();
      final staleKeys = <String>{
        for (final e in fresh.entries)
          if (stored[e.key]?.inputFingerprint != e.value) e.key,
      };
      if (staleKeys.isEmpty) {
        return CorrelationRefreshOutcome(
          ran: true,
          unchangedCount: fresh.length,
        );
      }
      final recomputed = computeCorrelationInsights(
        inputs,
        computedAtMs: _now().millisecondsSinceEpoch,
        onlySplitKeys: staleKeys,
      );
      await _insightStore.writeRecords(recomputed);
      return CorrelationRefreshOutcome(
        ran: true,
        recomputedCount: recomputed.length,
        unchangedCount: fresh.length - staleKeys.length,
      );
    } catch (_) {
      return const CorrelationRefreshOutcome(skippedReason: 'error');
    }
  }
}
