import 'correlation_engine.dart';
import 'correlation_insight_store.dart';
import 'health_history_store.dart';
import 'medication_change_events.dart';
import 'medications.dart';
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
/// its S7 unavailable record). A third seam joined later (F5
/// seeded-bounds fix): [BackendMedicationListProvider] reads
/// the profile blob's medication rows so F5 bounds its windows
/// on the same seeded marker set as the panel and the
/// clinician PDF.

/// Production target-history provider: empty until item 4's store
/// lands (see the file header).
class EmptyIntakeTargetHistoryProvider implements IntakeTargetHistoryProvider {
  const EmptyIntakeTargetHistoryProvider();

  @override
  Future<List<IntakeTargetHistoryEntry>> loadTargetHistory() async => const [];
}

/// Production med-event provider: empty until a med-event GET
/// read path lands (see the file header). The empty result is a
/// SUCCESSFUL empty (non-null): this provider has no read path
/// that can fail, so it never reports the H1-01 failure null.
class EmptyMedChangeEventProvider implements MedChangeEventProvider {
  const EmptyMedChangeEventProvider();

  @override
  Future<List<MedChangeEventInput>?> loadMedChangeEvents() async => const [];
}

/// Production med-list provider: empty until the refresher
/// wires the profile read path (see
/// [BackendMedicationListProvider]).
class EmptyMedicationListProvider implements MedicationListProvider {
  const EmptyMedicationListProvider();

  @override
  Future<List<MedicationEntry>?> loadMedications() async => const [];
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
/// added, live since VC 100108).
///
/// H1-01: a failed fetch stays null (the backend's own contract)
/// instead of degrading to an empty event list. The refresher
/// reads null as "unknown" and SKIPS F5 entirely — recomputing
/// from an empty list overwrote the persisted F5 records with a
/// zero-data unavailable state on one offline wake. A successful
/// fetch of zero events still returns an empty list and F5
/// recomputes its honest no-changes state exactly as before.
class BackendMedChangeEventProvider implements MedChangeEventProvider {
  final TabsBackend _backend;

  BackendMedChangeEventProvider({TabsBackend? backend})
    : _backend = backend ?? TabsBackend();

  @override
  Future<List<MedChangeEventInput>?> loadMedChangeEvents() async {
    final events = await _backend.fetchMedicationChangeEvents();
    if (events == null) return null;
    return [for (final e in events) medChangeEventInputFromEvent(e)];
  }
}

/// Production med-list provider (F5 seeded-bounds fix): reads
/// the medication list from the same sync-pull profile blob the
/// item 2 panel and the clinician report read —
/// [TabsBackend.fetchProfile] → [TabsBackend.decodeProfileList]
/// → [parseMedicationBlob] — so the seeded markers F5 bounds on
/// derive from the identical rows the panel seeds from.
///
/// H1-01: a failed fetch stays null instead of degrading to an
/// empty list (see [BackendMedChangeEventProvider]) — bounding
/// F5 on captured markers only is a DIFFERENT computation from
/// the seeded one, so silently substituting it overwrote the
/// persisted F5 records; the refresher now skips F5 until a
/// successful refresh lands the real list.
class BackendMedicationListProvider implements MedicationListProvider {
  final TabsBackend _backend;

  BackendMedicationListProvider({TabsBackend? backend})
    : _backend = backend ?? TabsBackend();

  @override
  Future<List<MedicationEntry>?> loadMedications() async {
    final profile = await _backend.fetchProfile();
    if (profile == null) return null;
    return parseMedicationBlob(
      TabsBackend.decodeProfileList(profile['medications']),
    );
  }
}

/// What one refresh did — returned for tests and diagnostics; the
/// refresher never throws, so a failed refresh is a value.
class CorrelationRefreshOutcome {
  /// Whether input assembly succeeded and the stale check ran.
  final bool ran;

  /// Store keys recomputed and written this run.
  final int recomputedCount;

  /// Store keys left exactly as they were: their fingerprints
  /// already matched, or their family was skipped because an
  /// input it depends on failed to load (H1-01).
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
  final MedicationListProvider _medListProvider;
  final Future<String?> Function() _readEmail;
  final DateTime Function() _now;

  CorrelationRefresher({
    required TabsBackend backend,
    required this._historyStore,
    required this._insightStore,
    this._targetProvider = const EmptyIntakeTargetHistoryProvider(),
    this._medEventProvider = const EmptyMedChangeEventProvider(),
    this._medListProvider = const EmptyMedicationListProvider(),
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
      // (item 4's target store; the item 2b med-event GET). The
      // med-list seam joined them with the F5 seeded-bounds fix
      // (the profile blob's medication rows).
      targetProvider: SettingsIntakeTargetHistoryProvider(),
      medEventProvider: BackendMedChangeEventProvider(backend: backend),
      medListProvider: BackendMedicationListProvider(backend: backend),
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
      //
      // H1-01 — every sync-backed input is loaded through its
      // failure-distinguishing (OrNull / nullable) form. The
      // plain fetchers return an empty list on ANY pull failure,
      // indistinguishable from a genuinely empty account; feeding
      // that into the fingerprint + recompute below recomputed
      // the sync-dependent families from zero data and overwrote
      // the persisted records with zero-data/unavailable states —
      // one offline background wake silently destroyed unlocked
      // Patterns insights. A null here means "load failed", and
      // every family that depends on a failed input is SKIPPED
      // below: no recompute, no overwrite, its stored fingerprint
      // untouched, so the next successful refresh behaves
      // normally. Successful-but-empty loads are non-null and
      // recompute exactly as before.
      final results = await Future.wait<Object?>([
        _backend.fetchLogEntryDtosOrNull(),
        _backend.fetchLogCategoriesOrNull(),
        _historyStore.readAll(),
        _targetProvider.loadTargetHistory(),
        _medEventProvider.loadMedChangeEvents(),
        _medListProvider.loadMedications(),
      ]);
      final entries = results[0] as List<QuickLogEntry>?;
      final categories = results[1] as List<QuickLogCategory>?;
      final medEvents = results[4] as List<MedChangeEventInput>?;
      final medications = results[5] as List<MedicationEntry>?;
      // Family → sync-input dependency map (the engine's
      // derivations): F2/F3/F4 read the log entries (intake,
      // flare, migraine, feeling series) and the categories those
      // derivations resolve against; F5 reads the medication
      // change events and the medication list (its seeded
      // bounding markers). F1 reads ONLY the local biometrics —
      // it is never gated on a sync failure. Target history is
      // device-local (item 4's store) and is not gated either.
      final blockedFamilies = <String>{
        if (entries == null || categories == null) ...['F2', 'F3', 'F4'],
        if (medEvents == null || medications == null) 'F5',
      };
      final inputs = CorrelationInputs(
        entries: entries ?? const [],
        categories: categories ?? const [],
        biometrics: results[2] as Map<String, DailyBiometrics>,
        targetHistory: results[3] as List<IntakeTargetHistoryEntry>,
        medEvents: medEvents ?? const [],
        medications: medications ?? const [],
        nowDayKey: _dayKeyOf(_now()),
      );

      final fresh = computeCorrelationFingerprints(inputs);
      final stored = await _insightStore.readAll();
      final staleKeys = <String>{
        for (final e in fresh.entries)
          if (!blockedFamilies.contains(e.key.split('/').first) &&
              stored[e.key]?.inputFingerprint != e.value)
            e.key,
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
