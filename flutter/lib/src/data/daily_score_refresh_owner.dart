/// App-scoped owner for Daily Score refreshes (founder-directed
/// Oct 20, 2026, after device-testing VC 10095).
///
/// The refresh used to live inside `DailyScoreDayScreen`'s State:
/// a per-instance in-flight flag and an outcome delivered only to
/// the still-mounted screen. Three defects followed — unmounting
/// mid-refresh silently dropped the outcome (a capture failure
/// could vanish unseen), popping and re-opening a day could start
/// a SECOND forced capture while the first still ran, and
/// re-entering the refreshing day mid-flight showed an idle
/// control over the stale score.
///
/// This owner fixes the ownership, not the semantics:
/// [DailyScoreRefresher] still orchestrates every refresh exactly
/// as before (see daily_score_refresh.dart). The owner is the
/// single source of truth for in-flight state at APP scope —
/// the singleton pattern [HealthHistoryStore.instance] set for
/// this layer — and the refresh's future lives here, never in a
/// widget, so unmounting any screen cannot cancel, lose, or
/// duplicate it.
///
/// SINGLE-FLIGHT: at most one refresh runs at a time, app-wide.
/// [startRefresh] REFUSES while any refresh is in flight — no
/// queueing, no second forced capture — regardless of which day
/// is asked.
///
/// COMPLETION + DEFERRED SURFACING (Juno rulings, Oct 20, 2026):
/// a completed outcome is recorded against its date until it is
/// consumed ([consumeOutcome] — consume-once). A day screen that
/// is mounted for the completing date consumes it immediately and
/// reacts exactly as the screen always did (reload; SnackBar on a
/// capture failure). An outcome that completes while the user is
/// elsewhere is consumed by the next entry to that day and
/// surfaced INLINE ONLY — no SnackBar on entry — exactly once:
/// the record is removed when first rendered, so rotation, back-
/// and-return, and relaunch-after-render never re-show it.
/// Success while away needs no record's surfacing at all: the
/// refreshed score being present on return is the complete
/// outcome.
///
/// PRIVACY / HYGIENE (Juno ruling 5): the pending records hold a
/// date, a status, and bracketed error codes ONLY. The outcome a
/// refresh produces can carry a [DailyScoreComputation] — health
/// values (asleep minutes, HRV, resting HR, baselines) — so the
/// record stored here is a STRIPPED copy: status and
/// [DailyScoreRefreshOutcome.newFailureCodes] only, computation
/// dropped at record time (see [_run]). Nothing reads a recorded
/// computation back: day screens use only the status and failure
/// codes and re-derive everything they display from the store.
/// Records are IN
/// MEMORY ONLY: never persisted, never logged, never sent
/// off-device. They are cleared on logout and account switch via
/// [clear] (wired alongside the [HealthHistoryStore] clears in
/// main.dart's AppFlow and in AccountActions' cache wipe), and on
/// account-owner mismatch via [clearIfOwnerMismatch], mirroring
/// the store's hooks — the owner remembers the account email only
/// long enough to make that comparison, exactly as the store
/// does. [clear] also invalidates any in-flight refresh: when its
/// future settles, its outcome is discarded, never recorded.
///
/// PROCESS DEATH is out of scope by founder ruling: a refresh
/// survives in-app navigation and normal backgrounding while the
/// process lives. There is deliberately NO persisted in-flight
/// marker (that option is report-flag-only and would need a fresh
/// Juno ruling before being built).
library;

import 'package:flutter/foundation.dart';

import 'package:tabs_lab/src/data/daily_score_refresh.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';

/// Called whenever the owner's observable state changes: a refresh
/// started, a refresh completed (outcome recorded), or the owner
/// was cleared. Listeners re-read [DailyScoreRefreshOwner.isRefreshing],
/// [DailyScoreRefreshOwner.refreshingDate], and
/// [DailyScoreRefreshOwner.consumeOutcome].
typedef DailyScoreRefreshListener = void Function();

/// The app-scoped refresh owner. See the file header for the full
/// contract.
class DailyScoreRefreshOwner {
  final DailyScoreRefresher _refresher;

  DailyScoreRefreshOwner._(this._refresher);

  /// The shared app-scope owner, bound to the shared store's
  /// refresher — the [HealthHistoryStore.instance] pattern.
  static final DailyScoreRefreshOwner instance = DailyScoreRefreshOwner._(
    DailyScoreRefresher(store: HealthHistoryStore.instance),
  );

  /// Production-shaped construction over an explicit refresher
  /// (a screen's injected store seam flows through here).
  factory DailyScoreRefreshOwner({
    required DailyScoreRefresher refresher,
  }) =>
      DailyScoreRefreshOwner._(refresher);

  /// Test wiring: a fresh, non-singleton owner over a refresher
  /// built from [capture], mirroring
  /// [DailyScoreRefresher.withCapture] — a counting fake capture
  /// injected here proves the single-flight guarantee.
  factory DailyScoreRefreshOwner.withCapture({
    required HealthHistoryStore store,
    required ScoreCapture capture,
  }) =>
      DailyScoreRefreshOwner._(
        DailyScoreRefresher.withCapture(store: store, capture: capture),
      );

  final List<DailyScoreRefreshListener> _listeners = [];

  /// The one in-flight refresh's future, if any. Held here — at
  /// app scope — so no widget's lifecycle can cancel or lose it.
  Future<DailyScoreRefreshOutcome>? _inFlight;

  /// The date the in-flight refresh is scoring, if any.
  String? _refreshingDate;

  /// Completed outcomes awaiting consumption, keyed by date.
  /// Each record is a stripped copy holding the date (the key),
  /// a status, and bracketed error codes only — no computation,
  /// no health values (Juno ruling 5).
  final Map<String, DailyScoreRefreshOutcome> _pendingOutcomes = {};

  /// Bumped by [clear]: a refresh that started before a clear has
  /// a stale generation, and its outcome is discarded on settle
  /// instead of being recorded for a possibly different account.
  int _generation = 0;

  /// The account this owner's in-flight/pending state belongs to,
  /// stamped by the login/register hooks through
  /// [clearIfOwnerMismatch] — the store's owner pattern, kept so a
  /// login as a different account drops the previous account's
  /// pending outcomes before any screen can consume them. Null
  /// until first stamped (and after [clear]).
  String? _ownerEmail;

  /// Whether any refresh is currently in flight, app-wide.
  bool get isRefreshing => _inFlight != null;

  /// The date the in-flight refresh is scoring, or null when idle.
  String? get refreshingDate => _refreshingDate;

  /// Whether the in-flight refresh is scoring [date].
  bool isRefreshingDate(String date) =>
      _inFlight != null && _refreshingDate == date;

  /// Whether a completed outcome for [date] is waiting to be
  /// consumed. Peeking never consumes.
  bool hasPendingOutcome(String date) => _pendingOutcomes.containsKey(date);

  void addListener(DailyScoreRefreshListener listener) =>
      _listeners.add(listener);

  void removeListener(DailyScoreRefreshListener listener) =>
      _listeners.remove(listener);

  void _notify() {
    // Copy: a listener may add/remove listeners while reacting.
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  /// Starts a refresh of [date] through [DailyScoreRefresher],
  /// unless one is already in flight.
  ///
  /// Returns null when REFUSED (any refresh in flight, for any
  /// day — single-flight is app-wide). Otherwise returns the
  /// refresh's future, owned here: it completes with the outcome,
  /// which is ALSO recorded against [date] for consume-once
  /// surfacing (unless a [clear] invalidated this run meanwhile,
  /// in which case the outcome is discarded). Never throws — the
  /// refresher never throws, and a defensive guard keeps a wedged
  /// in-flight flag impossible even if that contract ever broke.
  Future<DailyScoreRefreshOutcome>? startRefresh(String date) {
    if (_inFlight != null) return null;
    final generation = _generation;
    _refreshingDate = date;
    final future = _run(date, generation);
    _inFlight = future;
    _notify();
    return future;
  }

  Future<DailyScoreRefreshOutcome> _run(String date, int generation) async {
    DailyScoreRefreshOutcome outcome;
    try {
      outcome = await _refresher.refresh(date);
    } catch (_) {
      outcome = const DailyScoreRefreshOutcome(
        status: DailyScoreRefreshStatus.captureFailed,
      );
    }
    // This run IS the in-flight refresh (single-flight: no other
    // run can have replaced it), so settling always frees the
    // flight slot — even when a clear invalidated the outcome.
    _inFlight = null;
    _refreshingDate = null;
    if (generation == _generation) {
      // Record the STRIPPED outcome only (Juno ruling 5): status
      // + newly recorded failure codes, computation dropped — the
      // pending record never holds health values. The outcome
      // returned to this run's direct caller keeps its computation
      // (that hand-off is transient, never stored here).
      _pendingOutcomes[date] = DailyScoreRefreshOutcome(
        status: outcome.status,
        newFailureCodes: outcome.newFailureCodes,
      );
    }
    _notify();
    return outcome;
  }

  /// Takes the pending outcome for [date], if one is recorded,
  /// removing it in the same step (consume-once: a surfaced
  /// outcome is never shown twice). Returns null when nothing is
  /// pending for the date.
  DailyScoreRefreshOutcome? consumeOutcome(String date) =>
      _pendingOutcomes.remove(date);

  /// Drops every pending outcome and invalidates any in-flight
  /// refresh (its outcome will be discarded when it settles; the
  /// in-flight flag itself clears on settle so the single-flight
  /// guarantee is never weakened mid-capture). Called on logout
  /// and session expiry, alongside the store's clear. Synchronous
  /// and total: after this call no trace of the previous account's
  /// refresh state can surface.
  void clear() {
    _generation++;
    _pendingOutcomes.clear();
    _ownerEmail = null;
    _notify();
  }

  /// The store's owner-mismatch pattern, mirrored: when the app
  /// learns the signed-in account ([email]) differs from the one
  /// this owner's state belongs to, drop the state. A null [email]
  /// teaches nothing and changes nothing (same as the store).
  /// Returns true when it cleared.
  bool clearIfOwnerMismatch(String? email) {
    if (email == null) return false;
    final owner = _ownerEmail;
    if (owner == null) {
      _ownerEmail = email;
      return false;
    }
    if (owner == email) return false;
    clear();
    _ownerEmail = email;
    return true;
  }

  /// Test hook: restore the pristine idle state (also settles the
  /// bookkeeping a mid-flight test may have left behind).
  @visibleForTesting
  void debugReset() {
    _generation++;
    _pendingOutcomes.clear();
    _ownerEmail = null;
    _inFlight = null;
    _refreshingDate = null;
  }
}
