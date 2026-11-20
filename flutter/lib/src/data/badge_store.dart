import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:tabs_lab/src/data/badge_engine.dart';
import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';

/// Badge state + evaluation + the gem-grant queue (BADGES
/// package, Nov 20, 2026).
///
/// Persistence follows the GemService/StreakStore house pattern:
/// one JSON blob in flutter_secure_storage, account-owner binding
/// via [clearIfOwnerMismatch], injectable storage for tests.
///
/// Invariants:
/// - The granted set is MONOTONIC: a rung once granted is never
///   removed by evaluation (badges never drop once earned).
/// - Every intended gem grant is persisted to the pending queue
///   BEFORE its first request (the GemService discipline), so a
///   restart between settlement and grant can neither lose nor
///   duplicate it. The server ledger's idempotency key
///   (`badge:{metric}:{metal}_{n}`) is the payout backstop: a
///   replayed key answers alreadyGranted and can never double-pay.
/// - A rung's payout state is tracked per grant key: pending vs
///   paid. A 200 counts as paid (ledger-confirmed) whether the
///   grant was fresh or alreadyGranted — but only a FRESH grant
///   may present a gems element in the unlock dialog (Juno §13
///   rule 4, Vera condition C2): an alreadyGranted answer means
///   the ledger paid in a previous install, the balance does not
///   move, and the dialog must not suggest it paid again.
/// - Evaluation is RETROACTIVE and IDEMPOTENT: the first run
///   computes from full history (the launch backfill, which pays
///   like any other unlock); re-evaluation with unchanged inputs
///   grants nothing and shows nothing.
class BadgeGrant {
  final BadgeMetric metric;
  final int rungIndex;

  /// True when the server ledger has confirmed this rung's grant
  /// (fresh or alreadyGranted) by the time the batch is reported.
  final bool paid;

  /// True only when the confirming 200 was a FRESH grant — the
  /// ledger paid in this install, in this batch's flush. An
  /// alreadyGranted confirmation (reinstall / second device) sets
  /// [paid] but never this, so the unlock dialog shows no +5 line
  /// and excludes the rung from its Total (Vera C2).
  final bool paidFresh;

  const BadgeGrant({
    required this.metric,
    required this.rungIndex,
    required this.paid,
    this.paidFresh = false,
  });
}

/// One evaluation's newly granted rungs, for the unlock dialog.
class BadgeUnlockBatch {
  /// In screen order (metric order, then rung ascending — the
  /// highest rung of a badge last, per Juno §8).
  final List<BadgeGrant> grants;

  /// True when this batch is the first-ever evaluation's backfill.
  final bool isBackfill;

  const BadgeUnlockBatch({required this.grants, required this.isBackfill});

  bool get anyPending => grants.any((g) => !g.paid);
  int get paidCount => grants.where((g) => g.paid).length;

  /// Grants the ledger paid FRESH in this batch — the only count
  /// the unlock dialog's Total may use (Vera C2).
  int get freshPaidCount => grants.where((g) => g.paidFresh).length;

  /// Whether any granted badge is Health Connect-backed (drives
  /// the backfill intro variant, Juno §8).
  bool get includesHcBadge => grants.any((g) =>
      g.metric.section == BadgeSections.activity ||
      g.metric.section == BadgeSections.sleep);
}

/// The UI's read model: granted rungs, last known values, and the
/// currently permission-blocked metrics (Juno §9).
class BadgeSnapshot {
  final bool loaded;
  final Map<String, Set<int>> granted;
  final Map<String, int> values;
  final Set<String> blockedMetrics;

  const BadgeSnapshot({
    required this.loaded,
    required this.granted,
    required this.values,
    required this.blockedMetrics,
  });

  static const empty = BadgeSnapshot(
    loaded: false,
    granted: {},
    values: {},
    blockedMetrics: {},
  );

  /// Badges with at least one rung earned (Juno §2 definition).
  int get earnedBadgeCount =>
      granted.values.where((rungs) => rungs.isNotEmpty).length;

  /// The highest rung earned for [metricId], or -1.
  int topRungOf(String metricId) {
    final rungs = granted[metricId];
    if (rungs == null || rungs.isEmpty) return -1;
    return rungs.reduce((a, b) => b > a ? b : a);
  }
}

typedef BadgeGrantFn = Future<GemRequestResult> Function(String key);
typedef BadgeBalanceFn = void Function(int balance);

class BadgeService extends ChangeNotifier {
  static const String storageKey = 'badges_v1';

  static final BadgeService instance = BadgeService._internal();
  BadgeService._internal() : this();

  final BadgeGrantFn _grantFn;
  final BadgeBalanceFn? _onBalance;

  Future<String?> Function(String key) _read =
      (key) => const FlutterSecureStorage().read(key: key);
  Future<void> Function(String key, String value) _write =
      (key, value) =>
          const FlutterSecureStorage().write(key: key, value: value);
  Future<void> Function(String key) _delete =
      (key) => const FlutterSecureStorage().delete(key: key);

  BadgeService({
    BadgeGrantFn? grant,
    TabsBackend? backend,
    BadgeBalanceFn? onBalance,
  })  : _grantFn = grant ?? _backendGrant(backend ?? TabsBackend()),
        // The production path mirrors a confirmed grant's balance
        // into GemService (the pill's one source); tests inject
        // their own grant fn and no balance sink.
        _onBalance = onBalance ??
            (grant == null
                ? (bal) => GemService.instance.adoptServerBalance(bal)
                : null);

  static BadgeGrantFn _backendGrant(TabsBackend backend) =>
      (key) => backend.grantGems(key);

  @visibleForTesting
  void debugSetStore({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
    Future<void> Function(String key)? delete,
  }) {
    _read = read;
    _write = write;
    if (delete != null) _delete = delete;
  }

  @visibleForTesting
  void debugReset() {
    _loaded = false;
    _granted = {};
    _paid = {};
    _freshPaid = {};
    _pending = [];
    _values = {};
    _grantedAtMs = {};
    _lastEvaluatedDay = null;
    _evaluatedOnce = false;
    _blockedMetrics = {};
    _ownerEmail = null;
    _claimedOwner = null;
  }

  bool _loaded = false;
  Map<String, Set<int>> _granted = {};
  Set<String> _paid = {};

  /// Keys whose confirming 200 in this process was a FRESH grant
  /// (not alreadyGranted). Session-only presentation state for the
  /// unlock dialog (Vera C2); never persisted — a batch is built
  /// by the same evaluation that flushed its grants.
  Set<String> _freshPaid = {};
  List<String> _pending = [];
  Map<String, int> _values = {};
  Map<String, int> _grantedAtMs = {};
  String? _lastEvaluatedDay;
  bool _evaluatedOnce = false;
  Set<String> _blockedMetrics = {};
  String? _ownerEmail;
  String? _claimedOwner;

  @visibleForTesting
  List<String> get debugPending => List.unmodifiable(_pending);
  @visibleForTesting
  Set<String> get debugPaid => Set.unmodifiable(_paid);

  BadgeSnapshot get snapshot => BadgeSnapshot(
        loaded: _loaded,
        granted: {
          for (final e in _granted.entries) e.key: Set.unmodifiable(e.value),
        },
        values: Map.unmodifiable(_values),
        blockedMetrics: Set.unmodifiable(_blockedMetrics),
      );

  /// The top badge for the summary card: the highest rung across
  /// metrics; ties break to the most recently granted rung, then
  /// to spec order (Juno §2 leaves the tie-break to the engine).
  ({BadgeMetric metric, int rungIndex})? get topBadge {
    ({BadgeMetric metric, int rungIndex})? best;
    var bestAt = -1;
    for (final metric in BadgeMetrics.all) {
      final rungs = _granted[metric.id];
      if (rungs == null || rungs.isEmpty) continue;
      final top = rungs.reduce((a, b) => b > a ? b : a);
      final at = _grantedAtMs[badgeGrantKey(metric.id, top)] ?? 0;
      if (best == null ||
          top > best.rungIndex ||
          (top == best.rungIndex && at > bestAt)) {
        best = (metric: metric, rungIndex: top);
        bestAt = at;
      }
    }
    return best;
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final String? raw;
    try {
      raw = await _read(storageKey);
    } catch (_) {
      return; // Retry on the next call; nothing is fabricated.
    }
    _loaded = true;
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final owner = decoded['ownerEmail'];
      _ownerEmail = owner is String ? owner : null;
      if (_claimedOwner != null && _ownerEmail != _claimedOwner) {
        _granted = {};
        _paid = {};
        _pending = [];
        _values = {};
        _grantedAtMs = {};
        _lastEvaluatedDay = null;
        _evaluatedOnce = false;
        _ownerEmail = _claimedOwner;
        unawaited(_deleteQuietly());
        return;
      }
      final granted = decoded['granted'];
      if (granted is Map<String, dynamic>) {
        _granted = {
          for (final e in granted.entries)
            e.key: e.value is List
                ? e.value.whereType<int>().toSet()
                : <int>{},
        };
      }
      final paid = decoded['paid'];
      if (paid is List) _paid = paid.whereType<String>().toSet();
      final pending = decoded['pending'];
      if (pending is List) _pending = pending.whereType<String>().toList();
      final values = decoded['values'];
      if (values is Map<String, dynamic>) {
        _values = {
          for (final e in values.entries)
            if (e.value is int) e.key: e.value as int,
        };
      }
      final grantedAt = decoded['grantedAt'];
      if (grantedAt is Map<String, dynamic>) {
        _grantedAtMs = {
          for (final e in grantedAt.entries)
            if (e.value is int) e.key: e.value as int,
        };
      }
      final last = decoded['lastEvaluatedDay'];
      _lastEvaluatedDay = last is String ? last : null;
      _evaluatedOnce = decoded['evaluatedOnce'] == true;
    } catch (_) {
      // A corrupt blob starts clean; server idempotency is the
      // backstop against any duplicate payout this could cause.
      _granted = {};
      _paid = {};
      _pending = [];
      _values = {};
      _grantedAtMs = {};
      _lastEvaluatedDay = null;
      _evaluatedOnce = false;
    }
  }

  Future<void> _deleteQuietly() async {
    try {
      await _delete(storageKey);
    } catch (_) {}
  }

  /// Account binding (GemService parity): a different account's
  /// badge record never surfaces under a new owner.
  Future<void> clearIfOwnerMismatch(String? email) async {
    if (email == null || email.isEmpty) return;
    _claimedOwner = email;
    if (_ownerEmail != null && _ownerEmail != email) {
      _granted = {};
      _paid = {};
      _pending = [];
      _values = {};
      _grantedAtMs = {};
      _lastEvaluatedDay = null;
      _evaluatedOnce = false;
      unawaited(_deleteQuietly());
    }
    _ownerEmail = email;
    await ensureLoaded();
  }

  Future<void> _persist() async {
    if (!_loaded) return;
    try {
      await _write(
        storageKey,
        jsonEncode({
          'ownerEmail': _ownerEmail,
          'granted': {
            for (final e in _granted.entries)
              e.key: e.value.toList()..sort(),
          },
          'paid': _paid.toList()..sort(),
          'pending': _pending,
          'values': _values,
          'grantedAt': _grantedAtMs,
          'lastEvaluatedDay': _lastEvaluatedDay,
          'evaluatedOnce': _evaluatedOnce,
        }),
      );
    } catch (_) {
      // In-memory state survives; the next mutation retries.
    }
  }

  /// Attempt every pending grant once, sequentially (the server
  /// has no batch endpoint — one POST /api/gems/grant per rung).
  /// A 200 (fresh OR alreadyGranted) retires the key as PAID and
  /// adopts the response balance; any other outcome leaves the
  /// key queued for the next settlement — keeping a key queued is
  /// always the safe side, and the ledger key makes a retry
  /// incapable of double-paying.
  Future<void> _flushPending() async {
    var changed = false;
    for (final key in List<String>.of(_pending)) {
      GemRequestResult r;
      try {
        r = await _grantFn(key);
      } catch (_) {
        continue;
      }
      if (r.statusCode != 200 || r.body == null) continue;
      _pending.remove(key);
      _paid.add(key);
      // Vera C2: an alreadyGranted 200 confirms the ledger paid in
      // a previous install — it must never present as a fresh
      // payout in this batch's unlock dialog.
      if (r.body!['alreadyGranted'] != true) _freshPaid.add(key);
      changed = true;
      final bal = r.body!['gemBalance'];
      if (bal is int) _onBalance?.call(bal);
    }
    if (changed) await _persist();
  }

  /// Whether a full evaluation is due at [now]: false only when
  /// an evaluation already landed for the current Tabs day. Home's
  /// settlement hook checks this BEFORE running the (expensive)
  /// inputs loaders, so the HC history scan is a once-a-day cost.
  Future<bool> needsEvaluation(DateTime now) async {
    await ensureLoaded();
    if (!_loaded) return false;
    return !_evaluatedOnce || _lastEvaluatedDay != tabsDayStr(now);
  }

  /// Retry queued grants without an evaluation (settlement retry
  /// point + tests). Never throws.
  Future<void> retryPending() async {
    await ensureLoaded();
    if (!_loaded) return;
    await _flushPending();
    notifyListeners();
  }

  /// One settlement evaluation. Runs at the same app-open
  /// settlement point as the streak engine (Home's settle path),
  /// never on a timer. [blockedMetrics] is the caller's verified
  /// Juno §9 determination for this run (permission-denied metric
  /// ids); it is display state, refreshed every evaluation.
  ///
  /// Day gate: after the first evaluation of a Tabs day, further
  /// same-day calls only retry pending grants — a full HC history
  /// scan is a once-a-day cost. Pass [force] (the Badges screen's
  /// refresh) to re-evaluate anyway.
  ///
  /// Returns the unlock batch when this evaluation granted new
  /// rungs, else null. Never throws.
  Future<BadgeUnlockBatch?> evaluate({
    required BadgeInputs inputs,
    required Set<String> blockedMetrics,
    required DateTime now,
    bool force = false,
  }) async {
    try {
      await ensureLoaded();
      if (!_loaded) return null;
      _blockedMetrics = blockedMetrics;
      // Queued grants retry at every settlement, gate or not. A
      // retry that lands is silent — it never re-enters a dialog
      // (Juno §13 rule 4).
      await _flushPending();

      final today = tabsDayStr(now);
      if (!force && _evaluatedOnce && _lastEvaluatedDay == today) {
        notifyListeners();
        return null;
      }

      final isBackfill = !_evaluatedOnce;
      final computed = computeBadgeValues(inputs);
      for (final e in computed.entries) {
        _values[e.key] = e.value;
      }

      final newGrants = <BadgeGrant>[];
      final nowMs = now.millisecondsSinceEpoch;
      for (final metric in BadgeMetrics.all) {
        final value = computed[metric.id];
        if (value == null) continue; // source unknown this run
        final reached = metric.rungForValue(value);
        final held = _granted[metric.id] ??= <int>{};
        for (var rung = 0; rung <= reached; rung++) {
          if (held.contains(rung)) continue;
          held.add(rung);
          final key = badgeGrantKey(metric.id, rung);
          _grantedAtMs[key] = nowMs;
          if (!_paid.contains(key) && !_pending.contains(key)) {
            _pending.add(key);
          }
          newGrants.add(BadgeGrant(
            metric: metric,
            rungIndex: rung,
            paid: _paid.contains(key),
          ));
        }
      }

      _evaluatedOnce = true;
      _lastEvaluatedDay = today;
      // The queue + granted set land BEFORE the first request.
      await _persist();

      if (newGrants.isNotEmpty) {
        await _flushPending();
        final batch = BadgeUnlockBatch(
          isBackfill: isBackfill,
          grants: [
            for (final g in newGrants)
              BadgeGrant(
                metric: g.metric,
                rungIndex: g.rungIndex,
                paid: _paid.contains(
                    badgeGrantKey(g.metric.id, g.rungIndex)),
                paidFresh: _freshPaid.contains(
                    badgeGrantKey(g.metric.id, g.rungIndex)),
              ),
          ],
        );
        notifyListeners();
        return batch;
      }
      notifyListeners();
      return null;
    } catch (_) {
      // A badge failure must never break the settlement flow.
      return null;
    }
  }
}

/// The production inputs loader: assembles one evaluation's
/// inputs from the app's existing sources.
///
/// - Logs: `TabsBackend.fetchLogEntries` — the same timestamp
///   list the app's existing log counters read.
/// - Streaks: the settled [StreakState] from Home's own settle
///   (passed in; never re-derived here).
/// - Health Connect: the availability probe decides the Juno §9
///   states. A section's metrics are BLOCKED only on a VERIFIED
///   denial — the probe ran, the service is available, and the
///   section's record permissions are not in the granted set.
///   An unavailable service is not a denial: HC metrics stay
///   unknown (their tiles show the requirement line, never an
///   error and never a fake zero). Granted sections read through
///   the HC service's history reads; a granted read that returns
///   nothing is a true zero (Juno §9 rule 5).
///
/// HC scan depth: 400 days for steps / total calories / exercise
/// (every ladder's best-ever window is comfortably inside it) and
/// 800 days for sleep (the 365-night top rung needs a year+).
Future<({BadgeInputs inputs, Set<String> blockedMetrics})> loadBadgeInputs({
  required TabsBackend backend,
  required HealthConnectService hc,
  required StreakState? streakState,
}) async {
  List<int>? logTimestamps;
  try {
    logTimestamps = await backend.fetchLogEntries();
  } catch (_) {
    logTimestamps = null;
  }

  final blocked = <String>{};
  Map<String, int>? dailySteps;
  Map<String, int>? dailyTotalCalories;
  List<BadgeExerciseSpan>? exercise;
  List<BadgeSleepSession>? sleep;

  try {
    final probe = await hc.probeAvailability();
    // Juno §9 rule 1: the permission state fires ONLY on a verified
    // denial — service available AND the grant layer known AND the
    // permission absent from it. An unknown grant layer (probe
    // errored) is not a denial: HC metrics stay unknown this run,
    // never blocked and never zero-filled.
    if (probe.serviceAvailable && probe.grantKnown) {
      final granted = probe.grantedPermissions!;
      bool has(String p) => granted.contains(p);
      final stepsBlocked = !has('android.permission.health.READ_STEPS');
      final caloriesBlocked =
          !has('android.permission.health.READ_TOTAL_CALORIES_BURNED');
      // Juno B-ruling (Nov 20, 2026), condition 4: READ_EXERCISE is
      // a badges-scoped OPTIONAL permission — declared in the
      // manifest, granted by the user in Health Connect settings,
      // never in requiredPermissions — so the probe snapshot
      // (derived from the required set) can never contain it. The
      // exercise check reads the LIVE granted set. A failed live
      // read leaves Active week UNKNOWN this run, never blocked
      // (§9 rule 1: only a verified denial blocks).
      bool? exerciseGranted;
      try {
        exerciseGranted = (await hc.getGrantedPermissions())
            .contains('android.permission.health.READ_EXERCISE');
      } catch (_) {
        exerciseGranted = null;
      }
      final exerciseBlocked = exerciseGranted == false;
      final sleepBlocked = !has('android.permission.health.READ_SLEEP');
      if (stepsBlocked) blocked.add(BadgeMetrics.stepsDay.id);
      if (caloriesBlocked) blocked.add(BadgeMetrics.caloriesMonth.id);
      if (exerciseBlocked) blocked.add(BadgeMetrics.activeWeek.id);
      if (sleepBlocked) {
        blocked.add(BadgeMetrics.nightsTracked.id);
        blocked.add(BadgeMetrics.sleepWeek.id);
        blocked.add(BadgeMetrics.earlyToBed.id);
      }
      if (!stepsBlocked) {
        final rows = await hc.readStepsHistory(400);
        dailySteps = {
          for (final r in rows)
            if (r.count > 0) r.date: r.count,
        };
      }
      if (!caloriesBlocked) {
        final rows = await hc.readTotalCaloriesHistory(400);
        dailyTotalCalories = {
          for (final r in rows)
            if (r.kcal > 0) r.date: r.kcal,
        };
      }
      if (exerciseGranted == true) {
        exercise = await hc.readExerciseSessions(400);
      }
      if (!sleepBlocked) {
        sleep = await hc.readSleepSessions(800);
      }
    }
  } catch (_) {
    // HC stays unknown this run; Tabs-sourced metrics still land.
  }

  return (
    inputs: BadgeInputs(
      logTimestampsMs: logTimestamps,
      streakState: streakState,
      dailyTotalCalories: dailyTotalCalories,
      dailySteps: dailySteps,
      exerciseSessions: exercise,
      sleepSessions: sleep,
    ),
    blockedMetrics: blocked,
  );
}
