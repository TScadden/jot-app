import 'correlation_engine.dart';
import 'correlation_insight_store.dart';
import 'health_history_store.dart';
import 'quick_log_models.dart';
import 'tabs_backend.dart';

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
/// PROVIDER GAPS (combine-time, documented per the build brief):
/// two of the engine's inputs have no read path in this tree yet.
/// - The intake target history (item 4 §4.6) has no store yet —
///   item 4's capture build lands it.
/// - Medication change events (item 2a contract) have a POST
///   capture path but no client GET read path in this tree yet.
/// The production providers below therefore return EMPTY, which
/// the engine handles honestly (F2 target splits stay
/// unclassifiable, F5 renders its S7 unavailable record). When
/// those read paths land at combine time, they plug into these
/// exact seams — the payload shapes are the contracts already
/// pinned in correlation_engine.dart and must not be reinvented.

/// Production target-history provider: empty until item 4's store
/// lands (see the file header).
class EmptyIntakeTargetHistoryProvider
    implements IntakeTargetHistoryProvider {
  const EmptyIntakeTargetHistoryProvider();

  @override
  Future<List<IntakeTargetHistoryEntry>> loadTargetHistory() async =>
      const [];
}

/// Production med-event provider: empty until a med-event GET
/// read path lands (see the file header).
class EmptyMedChangeEventProvider implements MedChangeEventProvider {
  const EmptyMedChangeEventProvider();

  @override
  Future<List<MedChangeEventInput>> loadMedChangeEvents() async => const [];
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
    required HealthHistoryStore historyStore,
    required CorrelationInsightStore insightStore,
    IntakeTargetHistoryProvider targetProvider =
        const EmptyIntakeTargetHistoryProvider(),
    MedChangeEventProvider medEventProvider =
        const EmptyMedChangeEventProvider(),
    Future<String?> Function()? readEmail,
    DateTime Function()? now,
  })  : _backend = backend,
        _historyStore = historyStore,
        _insightStore = insightStore,
        _targetProvider = targetProvider,
        _medEventProvider = medEventProvider,
        _readEmail = readEmail ?? backend.readEmail,
        _now = now ?? DateTime.now;

  factory CorrelationRefresher.production() {
    final backend = TabsBackend();
    return CorrelationRefresher(
      backend: backend,
      historyStore: HealthHistoryStore.instance,
      insightStore: CorrelationInsightStore.instance,
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
