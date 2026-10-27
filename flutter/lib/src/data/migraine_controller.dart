import 'dart:async';

import 'package:flutter/foundation.dart';

import 'migraine_attack_store.dart';
import 'migraine_notification.dart';
import 'migraine_pressure.dart';
import 'migraine_trends.dart';
import 'quick_log_models.dart';
import 'tabs_backend.dart';
import 'today_summary.dart' show resolveSummaryCategoryId;

/// The Trends-write surface the controller needs. Abstract so tests
/// record entries without a backend; production is
/// [BackendMigraineTrendsGateway].
abstract class MigraineTrendsGateway {
  /// Posts (upserts) one entry via `POST /api/sync/entries`.
  Future<bool> postEntry(QuickLogEntry entry);

  /// Category id for the attack's entry (migraine log trio fix 3 —
  /// founder direction Oct 27, 2026; Juno receipt
  /// 2026-10-27-migraine-log-trio-juno.md §D): the founder's own
  /// "Migraine Symptoms & Triggers" category when it exists on his
  /// account, otherwise Symptoms resolved by name, final fallback
  /// id 1.
  Future<int> resolveMigraineCategoryId();

  /// A fresh entry id using the Quick Log convention (max existing
  /// id + 1). Called ONCE per attack, at first end; the id is then
  /// persisted on the attack record and reused for the form-save
  /// update, so the entry lands exactly once.
  Future<int> generateEntryId();
}

/// Production gateway over [TabsBackend].
class BackendMigraineTrendsGateway implements MigraineTrendsGateway {
  final TabsBackend backend;
  BackendMigraineTrendsGateway(this.backend);

  @override
  Future<bool> postEntry(QuickLogEntry entry) async {
    try {
      final ok = await backend.postLogEntries([entry]);
      if (ok) backend.invalidateSyncPull();
      return ok;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<int> resolveMigraineCategoryId() async {
    try {
      final categories = await backend.fetchLogCategories();
      // Fix 3 chain: founder category by name first, then Symptoms
      // by name, then id 1 (the 100102 §E default, preserved
      // exactly where the founder category is absent).
      return categoryIdByName(categories, 'Migraine Symptoms & Triggers') ??
          resolveSummaryCategoryId(categories,
              name: 'Symptoms', fallbackId: 1) ??
          1;
    } catch (_) {
      return 1;
    }
  }

  @override
  Future<int> generateEntryId() async {
    try {
      // Only trust max+1 when the pull actually succeeded — a failed
      // pull returns empty lists, and stamping id 1 for an offline
      // end could later upsert over an unrelated entry. Fall back to
      // a timestamp-derived id, which cannot collide with the small
      // sequential ids the convention produces.
      final pull = await backend.fetchSyncPull();
      if (pull == null) {
        return DateTime.now().millisecondsSinceEpoch;
      }
      final entries = await backend.fetchLogEntryDtos();
      var maxId = 0;
      for (final e in entries) {
        if (e.id > maxId) maxId = e.id;
      }
      return maxId + 1;
    } catch (_) {
      return DateTime.now().millisecondsSinceEpoch;
    }
  }
}

/// Name-only category lookup with [resolveSummaryCategoryId]'s
/// matching semantics (trimmed, case-insensitive) but NO id
/// fallback — fix 3's chain applies its own ordered fallbacks, and
/// the founder-category step must not silently land on an id when
/// the name is absent.
int? categoryIdByName(List<QuickLogCategory> categories, String name) {
  final target = name.trim().toLowerCase();
  for (final c in categories) {
    if (c.name.trim().toLowerCase() == target) return c.id;
  }
  return null;
}

/// The one shared app-level controller for the migraine attack
/// timer (founder spec, Oct 26, 2026). Created with the app wiring
/// in `main.dart` and passed to Home / Today Summary, so the card,
/// the collapsed header, and the notification tap handler all share
/// this one state.
///
/// Owns: start, mid-attack updates, both end paths, notification
/// sync, and the one-shot pending-details-form signal.
///
/// Degradation rules (Juno §F): notification denial/failure never
/// blocks start/timer/end and never prompts from here; every Trends
/// write failure sets the attack's pending flag and retries on app
/// start and on form save; the end itself is persisted FIRST, so no
/// failure downstream can un-end an attack.
class MigraineController extends ChangeNotifier {
  factory MigraineController({
    required MigraineAttackStore store,
    required MigraineNotifier notifier,
    required MigraineTrendsGateway gateway,
    Future<({double lat, double lon})?> Function()? storedCoordinates,
    Future<double> Function(double lat, double lon)? pressureFetcher,
    DateTime Function()? clock,
  }) =>
      MigraineController._(
        store,
        notifier,
        gateway,
        storedCoordinates,
        pressureFetcher ??
            ((lat, lon) => fetchPressureHpa(lat: lat, lon: lon)),
        clock ?? DateTime.now,
      );

  MigraineController._(
    this._store,
    this._notifier,
    this._gateway,
    this._storedCoordinates,
    this._pressureFetcher,
    this._clock,
  );

  /// Production wiring. The notifier's tap handler late-binds to
  /// this controller, mirroring how `main.dart` arms the Daily
  /// Score notifier.
  ///
  /// Pressure (Juno §G(3)): [storedCoordinates] defaults to null —
  /// production currently persists NO coordinates from the weather
  /// feature (its location cache is in-memory only), so pressure is
  /// simply not captured (0.0) and no location is ever requested at
  /// attack start. When a stored-coordinates source exists, pass it
  /// and the pressure attach runs best-effort through
  /// [fetchPressureHpa].
  factory MigraineController.production({
    TabsBackend? backend,
    MigraineAttackStore? store,
    Future<({double lat, double lon})?> Function()? storedCoordinates,
  }) {
    late MigraineController controller;
    final notifier = LocalMigraineNotifier(
      onTap: () => controller.handleNotificationTap(),
    );
    controller = MigraineController(
      store: store ?? MigraineAttackStore(),
      notifier: notifier,
      gateway: BackendMigraineTrendsGateway(backend ?? TabsBackend()),
      storedCoordinates: storedCoordinates,
    );
    return controller;
  }

  final MigraineAttackStore _store;
  final MigraineNotifier _notifier;
  final MigraineTrendsGateway _gateway;
  final Future<({double lat, double lon})?> Function()? _storedCoordinates;
  final Future<double> Function(double lat, double lon) _pressureFetcher;
  final DateTime Function() _clock;

  MigraineAttack? _active;
  bool _notificationPosted = false;
  String? _startError;
  MigraineAttack? _pendingDetails;
  bool _initialized = false;

  /// Single-flight guard for the end funnel: two racing end calls
  /// (e.g. a double notification tap) must end the attack at most
  /// once. Checked-and-set synchronously before the funnel's first
  /// await, which is atomic in Dart's single-threaded isolate.
  bool _ending = false;

  MigraineAttack? get activeAttack => _active;
  bool get isActive => _active != null;

  /// Whether a notification is actually posted for the active
  /// attack. Drives Juno §F's in-block note line (shown in that
  /// state only).
  bool get notificationPosted => _notificationPosted;

  /// Juno §F start-failure line, when the last start failed.
  String? get startError => _startError;

  /// The ended attack awaiting its one-shot details form, if any.
  /// Peek only — consume via [consumePendingDetails].
  MigraineAttack? get pendingDetails => _pendingDetails;
  bool get hasPendingDetails => _pendingDetails != null;

  int nowMs() => _clock().millisecondsSinceEpoch;

  /// Elapsed whole minutes of the active attack at [at] (default:
  /// now), always computed as now − startTimestamp.
  int elapsedMinutes({DateTime? at}) {
    final attack = _active;
    if (attack == null) return 0;
    return attack.elapsedMinutes((at ?? _clock()).millisecondsSinceEpoch);
  }

  /// App-start sync (also the card's first load): reload the store,
  /// reconcile the notification with reality (active attack →
  /// (re)post when permission allows; no active attack → no stale
  /// 7303 remains), and retry any pending Trends entry. Idempotent;
  /// never throws.
  Future<void> initialize() async {
    try {
      _active = await _store.loadActive();
    } catch (_) {
      _active = null;
    }
    _initialized = true;
    if (_active != null) {
      await _syncNotification();
    } else {
      _notificationPosted = false;
      await _notifier.cancel();
    }
    await retryPendingTrends();
    notifyListeners();
  }

  /// Lifecycle-resume sync: refresh the notification's elapsed text
  /// and retry pending Trends writes.
  Future<void> onAppResumed() async {
    if (!_initialized) {
      await initialize();
      return;
    }
    try {
      _active = await _store.loadActive();
    } catch (_) {}
    if (_active != null) {
      await _syncNotification();
    }
    await retryPendingTrends();
    notifyListeners();
  }

  /// Starts an attack. Pressure attach is best-effort and
  /// time-bounded — any failure yields 0.0 (not captured) and the
  /// attack starts anyway. NEVER fires a notification permission
  /// prompt and never fails because notification posting failed.
  /// Returns false and sets [startError] (Juno §F line) when the
  /// local save itself fails.
  Future<bool> startAttack() async {
    if (_active != null) return true;
    _startError = null;
    var pressure = 0.0;
    try {
      final coords = await _storedCoordinates?.call();
      if (coords != null && coords.lat != 0.0 && coords.lon != 0.0) {
        pressure = await _pressureFetcher(coords.lat, coords.lon)
            .timeout(const Duration(seconds: 3), onTimeout: () => 0.0);
        if (pressure < 0) pressure = 0.0;
      }
    } catch (_) {
      pressure = 0.0;
    }
    final now = nowMs();
    final attack = MigraineAttack(
      id: now,
      startTimestamp: now,
      pressureAtStartHpa: pressure,
      updatedAt: now,
    );
    try {
      await _store.save(attack);
      // Readback (wiring audit): the active attack must be the one
      // just saved before the UI may show it running.
      _active = await _store.loadActive() ?? attack;
    } catch (_) {
      _startError = 'Could not start the attack log. Please try again.';
      notifyListeners();
      return false;
    }
    notifyListeners();
    // Post the ongoing notification if permission allows. Awaited
    // only so [notificationPosted] is truthful for the note line;
    // the notifier never prompts and never throws.
    await _syncNotification();
    notifyListeners();
    return true;
  }

  /// Mid-attack edits persist immediately (Lab `updateActiveAttack`
  /// semantics). Best-effort: the timer keeps its local state on a
  /// storage failure.
  Future<void> updateActive({
    String? auraPhase,
    String? medsTaken,
    int? painPeak,
  }) async {
    final active = _active;
    if (active == null) return;
    final updated = active.copyWith(
      auraPhase: auraPhase,
      medsTaken: medsTaken,
      painPeak: painPeak,
      updatedAt: nowMs(),
    );
    _active = updated;
    try {
      await _store.save(updated);
    } catch (_) {}
    notifyListeners();
  }

  /// In-app end path (§A relief dialog Save): ends with the dialog's
  /// relief rating, writes the Trends entry, cancels the
  /// notification, returns the block to idle. NO details form on
  /// this path (one completion surface per path).
  Future<bool> endWithReliefDialog({
    required int reliefRating,
    int? finalPainPeak,
  }) async {
    final active = _active;
    if (active == null) return false;
    final ended = await _endAttack(
      active,
      endMs: nowMs(),
      reliefRating: reliefRating.clamp(0, 5),
      finalPainPeak: finalPainPeak,
    );
    return ended != null;
  }

  /// Notification-tap end path: END FIRST, FORM SECOND (Juno §B).
  /// Ends the active attack with endTimestamp = tap time
  /// (idempotent — ends at most once, only if active), cancels the
  /// notification, writes the Trends entry with the values known at
  /// end (relief unset), then raises the one-shot form signal.
  /// A stale tap with no active attack is a plain app open: no
  /// form, no error, returns null.
  Future<MigraineAttack?> endFromNotificationTap({int? tapMs}) async {
    final active = _active ?? await _store.loadActive();
    if (active == null) return null;
    _active = active;
    final ended = await _endAttack(active, endMs: tapMs ?? nowMs());
    if (ended == null) return null; // A racing end already won.
    _pendingDetails = ended;
    notifyListeners();
    return ended;
  }

  /// Plugin tap entry point (foreground/background dispatch). The
  /// cold-start launch payload goes through [consumeLaunchTap].
  void handleNotificationTap() {
    unawaited(endFromNotificationTap());
  }

  /// Cold start: if the app was launched by the migraine
  /// notification, run the same tap-end path. Returns whether a
  /// launch tap was consumed.
  Future<bool> consumeLaunchTap() async {
    bool launched;
    try {
      launched = await _notifier.launchMigrainePayload();
    } catch (_) {
      launched = false;
    }
    if (!launched) return false;
    if (!_initialized) await initialize();
    await endFromNotificationTap();
    return true;
  }

  /// Consumes the one-shot details-form signal exactly once. Later
  /// calls (and later app opens) return null — the form is never
  /// re-presented (Juno §F).
  MigraineAttack? consumePendingDetails() {
    final pending = _pendingDetails;
    _pendingDetails = null;
    return pending;
  }

  /// Details-form Save (§C): commits form edits to the attack record
  /// and updates the SAME Trends entry (same persisted id — never a
  /// second entry). Relief commits only when [reliefRating] is
  /// non-null (a selection was made); pain commits only when
  /// [commitPain] is true (prefilled mid-attack or slider touched).
  /// Returns false when the Trends update fails — the caller keeps
  /// the form open with Juno's §F line and a retry re-saves the
  /// details only (the attack stays ENDED regardless).
  Future<bool> saveDetails({
    required int attackId,
    int? reliefRating,
    int? painPeak,
    bool commitPain = false,
    String? auraPhase,
    String? medsTaken,
  }) async {
    MigraineAttack? attack;
    try {
      attack = await _store.loadById(attackId);
    } catch (_) {
      attack = null;
    }
    if (attack == null || attack.isActive) return false;
    var updated = attack.copyWith(
      reliefRating: reliefRating?.clamp(0, 5),
      painPeak: commitPain && painPeak != null
          ? painPeak.clamp(0, 10)
          : null,
      auraPhase: auraPhase,
      medsTaken: medsTaken,
      updatedAt: nowMs(),
    );
    try {
      await _store.save(updated);
    } catch (_) {
      return false;
    }
    final result = await _writeTrendsEntry(updated);
    try {
      // On failure the details stay on the record with the entry
      // marked pending, so the app-start retry converges the entry
      // (a form retry re-saves the same details — never the end).
      await _store.save(
          result.attack.copyWith(trendsEntryPending: !result.ok));
    } catch (_) {}
    return result.ok;
  }

  /// Retries every ended attack whose Trends entry has not landed.
  /// The entry id was persisted at end, so a retry upserts the same
  /// entry — it lands exactly once.
  Future<void> retryPendingTrends() async {
    try {
      final all = await _store.loadAll();
      for (final attack in all) {
        if (!attack.isActive && attack.trendsEntryPending) {
          final result = await _writeTrendsEntry(attack);
          if (result.ok) {
            try {
              await _store.save(
                  result.attack.copyWith(trendsEntryPending: false));
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }

  /// Re-posts the ongoing notification with the current elapsed
  /// text (in-app tick + lifecycle resume) and keeps
  /// [notificationPosted] truthful for the note line.
  Future<void> refreshNotification() async {
    if (_active == null) return;
    await _syncNotification();
    notifyListeners();
  }

  Future<void> _syncNotification() async {
    final active = _active;
    if (active == null) {
      _notificationPosted = false;
      return;
    }
    _notificationPosted =
        await _notifier.showAttack(active.elapsedMinutes(nowMs()));
  }

  /// The single end funnel for both end paths. The END is persisted
  /// first (it must survive the form being dismissed, the app being
  /// killed, or the form never rendering), then the notification is
  /// cancelled, then the Trends entry is written. Returns null when
  /// a racing end is already in flight (this call is the stale one).
  Future<MigraineAttack?> _endAttack(
    MigraineAttack active, {
    required int endMs,
    int? reliefRating,
    int? finalPainPeak,
  }) async {
    if (_ending) return null;
    _ending = true;
    try {
      var ended = active.copyWith(
        endTimestamp: endMs,
        reliefRating: reliefRating,
        painPeak: finalPainPeak,
        updatedAt: endMs,
      );
      try {
        await _store.save(ended);
      } catch (_) {
        // The end must not be lost to a storage blip in-session:
        // keep the ended record as the controller's truth and clear
        // the active pointer in memory; the Trends write below
        // still runs.
      }
      _active = null;
      _notificationPosted = false;
      notifyListeners();
      await _notifier.cancel();
      final result = await _writeTrendsEntry(ended);
      ended = result.attack.copyWith(trendsEntryPending: !result.ok);
      try {
        await _store.save(ended);
      } catch (_) {}
      notifyListeners();
      return ended;
    } finally {
      _ending = false;
    }
  }

  /// Writes (or updates) the attack's ONE Trends entry. Generates
  /// and persists the entry id on first write; later writes reuse
  /// it, so end + form-save + pending-retries all upsert the same
  /// entry. Returns the attack as augmented (with its entry id) so
  /// callers never overwrite the persisted id with a stale copy.
  Future<({bool ok, MigraineAttack attack})> _writeTrendsEntry(
      MigraineAttack attack) async {
    try {
      var entryId = attack.trendsEntryId;
      if (entryId == null) {
        entryId = await _gateway.generateEntryId();
        attack = attack.copyWith(
          trendsEntryId: entryId,
          trendsEntryPending: true,
        );
        try {
          await _store.save(attack);
        } catch (_) {}
      }
      final categoryId = await _gateway.resolveMigraineCategoryId();
      final entry = buildMigraineTrendsEntry(
        attack,
        entryId: entryId,
        categoryId: categoryId,
      );
      final ok = await _gateway.postEntry(entry);
      if (ok && attack.trendsEntryPending) {
        attack = attack.copyWith(trendsEntryPending: false);
        try {
          await _store.save(attack);
        } catch (_) {}
      }
      return (ok: ok, attack: attack);
    } catch (_) {
      return (ok: false, attack: attack);
    }
  }
}
