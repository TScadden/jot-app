import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:tabs_lab/src/data/crash_reporting.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';

/// Gems (founder-approved plan, Nov 19, 2026) — earn-only in-app
/// currency. Balance lives SERVER-side (profile `gem_balance`,
/// jot-server PR #41); this service is the client half:
///
/// - The displayed balance comes ONLY from server payloads (the
///   sync-pull profile, grant responses, spend responses) — never
///   from optimistic local math.
/// - Earn hooks run off the post-PR-#115 deterministic completion
///   path (Home's SummaryCompletionWatcher callback), NEVER the
///   dev SIM path and never the dev Restore Streak path: neither
///   constructs or calls this service (fence-tested).
/// - Grants are idempotent server-side; locally, every intended
///   grant key is persisted to the pending queue BEFORE its first
///   request, so an app restart between settlement and grant can
///   neither lose nor duplicate it — a failed request retries at
///   the next app-open sync, and a granted key is never
///   re-requested (no spam on re-settlement / relaunch / adoption
///   replays).
/// - Milestones pay only on a REAL crossing evaluated at a
///   completion transition: the persisted last-settled-streak
///   marker starts at the pre-completion settled streak, so a
///   streak already past a milestone when the feature first runs
///   is never backfilled.
/// - Midnight Grace completions earn NOTHING (founder, Nov 21,
///   2026): a day in [StreakState.graceCompletedDays] queues no
///   daily/milestone/week key, a week containing any grace day
///   never pays the perfect-week bonus, and stale pending keys
///   attributable to grace days are retired at flush time without
///   ever being requested (see the no-gems section below).
///
/// Copy: EVERY user-facing gems string lives in [GemCopy] below,
/// verbatim from Juno's ruling (build-gems/JUNO-COPY.md §§1–4) —
/// the StreakPurchaseCopy swap-point pattern. No other file
/// hardcodes gems copy.
abstract final class GemCopy {
  /// The bundled gem icon asset (founder-approved v1 art).
  static const String iconAsset =
      'assets/images/tabs_gem_icon_v1_20261119.png';

  /// The fixed gem price of one streak freeze (Juno §2a literal;
  /// amount raised 100 -> 300 by the founder, Nov 25, 2026 — the
  /// $0.99 cash price is unchanged).
  static const int freezePrice = 300;

  // ── §1 Home pill accessibility label ──────────────────────────
  static String pillLabel(int count) => count == 1 ? '1 gem' : '$count gems';

  // ── §2 Buy-with-gems surface ──────────────────────────────────
  static const String buyButtonLabel = 'GET ONE MORE FREEZE · 300 GEMS';

  static String balanceLine(int balance) =>
      balance == 1 ? 'You have 1 gem.' : 'You have $balance gems.';

  /// §2c success title (lowercase friend register, as ruled).
  static const String spendSuccessTitle = 'freeze added';

  /// §2c success body; [balance] is the post-spend SERVER balance.
  static String spendSuccessBody(int balance) => balance == 1
      ? "you've got a freeze now. it covers one missed day. you have 1 gem left."
      : "you've got a freeze now. it covers one missed day. you have $balance gems left.";

  /// §2d insufficient-balance line; [needed] is 300 − balance.
  static String insufficientLine(int needed) => needed == 1
      ? 'you need 1 more gem for a freeze — you earn 5 gems each time you finish your daily summary.'
      : 'you need $needed more gems for a freeze — you earn 5 gems each time you finish your daily summary.';

  // ── §3 Celebration earn lines ─────────────────────────────────
  static const String dailyEarnLine = '+5 gems';

  static String milestoneEarnLine(int bonus, int days) =>
      '+$bonus gems — $days-day streak bonus';

  static const String weekEarnLine = '+20 gems — perfect week bonus';

  // ── §4 Explainer (verbatim block) ─────────────────────────────
  // Added scope #6 (Nov 20, 2026): the explainer MOVED off the
  // streak screen into the Gems sheet (opened from the Home gem
  // pill). The heading serves as the sheet title (used once);
  // lines 1–4 move verbatim. Line 5 as written for the streak
  // screen ("— the freeze on this screen") cannot move verbatim —
  // its referent breaks in the sheet — so the sheet renders
  // [sheetExplainerLines]: lines 1–4 verbatim plus the
  // coordinator-approved replacement (GEMS-MOVE-COPY §1.3
  // Proposal A, ruled in the stage log). [explainerLines] keeps
  // the original streak-screen block as the copy record.
  static const String explainerHeading = 'About gems';
  static const List<String> explainerLines = [
    "Gems are earned in Tabs. You can't buy them, and they have no cash value.",
    'Finish your Daily Summary: +5 gems.',
    'Streak bonuses pay when you reach them: +25 gems at 7 days, +50 at 30 days, +100 at 100 days, and +100 at each 100 days after that.',
    'Perfect week: +20 gems when you finish your Daily Summary all 7 days of a Monday–Sunday week.',
    '300 gems buys one streak freeze — the freeze on this screen.',
  ];

  /// The sheet's line 5 (GEMS-MOVE-COPY §1.3 Proposal A, approved):
  /// the original line with only the broken streak-screen referent
  /// dropped — no amount, term, or claim changed.
  static const String sheetExplainerLine5 =
      '300 gems buys one streak freeze.';

  /// The explainer lines as rendered in the Gems sheet: lines 1–4
  /// verbatim from [explainerLines], then [sheetExplainerLine5].
  static List<String> get sheetExplainerLines => [
        ...explainerLines.take(4),
        sheetExplainerLine5,
      ];
}

/// The gem milestone ladder (server-derived amounts, Mason PR #41):
/// the bonus for CROSSING [n], or null when [n] earns no gems.
int? gemMilestoneBonus(int n) {
  if (n == 7) return 25;
  if (n == 30) return 50;
  if (n >= 100 && n % 100 == 0) return 100;
  return null;
}

/// The Monday (ISO day string) of the Mon–Sun week containing [day].
String gemWeekMonday(String day) {
  final d = DateTime.parse(day);
  final monday = DateTime.utc(d.year, d.month, d.day)
      .subtract(Duration(days: d.weekday - 1));
  return streakDayStr(monday);
}

/// The seven ISO day strings of the week starting [monday].
List<String> gemWeekDays(String monday) {
  final d = DateTime.parse(monday);
  final base = DateTime.utc(d.year, d.month, d.day);
  return [for (var i = 0; i < 7; i++) streakDayStr(base.add(Duration(days: i)))];
}

/// The settled streak as it stood BEFORE [summaryTabsDay] was
/// counted: the consecutive counted run ending the day before it
/// in [state] (the same derivation the celebration's roll uses).
int gemSettledStreakBefore(StreakState state, String summaryTabsDay) {
  var count = 0;
  var cursor = DateTime.parse(summaryTabsDay).subtract(const Duration(days: 1));
  while (state.countedDays.contains(streakDayStr(cursor))) {
    count++;
    cursor = cursor.subtract(const Duration(days: 1));
  }
  return count;
}

/// One grant/spend round-trip's raw outcome (status + decoded body;
/// both null on transport failure) — the TabsBackend seam shape.
typedef GemRequestResult = ({int? statusCode, Map<String, dynamic>? body});

typedef GemGrantFn = Future<GemRequestResult> Function(String key);
typedef GemSpendFn = Future<GemRequestResult> Function(String spendId);
typedef GemBalancePullFn = Future<int?> Function();

enum GemSpendStatus {
  success,
  replay,
  insufficient,
  capReached,
  failed,
}

class GemSpendResult {
  final GemSpendStatus status;

  /// The server balance after the attempt, when the server
  /// answered with one (success AND the three 409 shapes carry it).
  final int? balance;

  /// The server purchased-freeze count, on the same answers.
  final int? purchasedFreezes;

  const GemSpendResult({
    required this.status,
    this.balance,
    this.purchasedFreezes,
  });
}

/// What one completion granted, for the celebration screen: the
/// Juno §3 lines to render (empty when nothing landed — a replay
/// of an already-granted day shows NO line) and the latest
/// server balance.
class GemEarnResult {
  final List<String> lines;
  final int? balance;

  const GemEarnResult({required this.lines, required this.balance});

  static const empty = GemEarnResult(lines: [], balance: null);
}

class GemService extends ChangeNotifier {
  static const String storageKey = 'gems_v1';

  static final GemService instance = GemService._internal();
  GemService._internal() : this();

  final GemGrantFn _grantFn;
  final GemSpendFn _spendFn;
  final GemBalancePullFn _pullBalanceFn;
  final String Function() _spendIdGen;

  Future<String?> Function(String key) _read =
      (key) => const FlutterSecureStorage().read(key: key);
  Future<void> Function(String key, String value) _write =
      (key, value) =>
          const FlutterSecureStorage().write(key: key, value: value);
  Future<void> Function(String key) _delete =
      (key) => const FlutterSecureStorage().delete(key: key);

  GemService({
    GemGrantFn? grant,
    GemSpendFn? spend,
    GemBalancePullFn? pullBalance,
    TabsBackend? backend,
    String Function()? spendIdGen,
  })  : _grantFn = grant ?? _backendGrant(backend ?? TabsBackend()),
        _spendFn = spend ?? _backendSpend(backend ?? TabsBackend()),
        _pullBalanceFn =
            pullBalance ?? _backendPullBalance(backend ?? TabsBackend()),
        _spendIdGen = spendIdGen ?? _defaultSpendIdGen();

  static String Function() _defaultSpendIdGen() {
    var counter = 0;
    return () =>
        'gem-spend-${DateTime.now().microsecondsSinceEpoch}-${counter++}';
  }

  static GemGrantFn _backendGrant(TabsBackend backend) =>
      (key) => backend.grantGems(key);

  static GemSpendFn _backendSpend(TabsBackend backend) =>
      (spendId) => backend.spendGemsOnFreeze(spendId);

  static GemBalancePullFn _backendPullBalance(TabsBackend backend) =>
      () async {
        final rec = await backend.fetchStreakRecord();
        return rec.succeeded ? rec.gemBalance : null;
      };

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

  /// Test seam (celebration-delay package, Nov 23, 2026): when
  /// set, grant requests route through this function instead of
  /// the backend's — the Home-level latency harness gates the
  /// grant transport on a completer to prove the celebration no
  /// longer waits on it. Production never sets it.
  GemGrantFn? _debugGrantFn;

  @visibleForTesting
  void debugSetGrantOverride(GemGrantFn? fn) => _debugGrantFn = fn;

  @visibleForTesting
  void debugReset() {
    _debugGrantFn = null;
    _flushInFlight = null;
    _loaded = false;
    _balance = null;
    _pending = [];
    _granted = {};
    _graceDays = {};
    _lastStreak = null;
    _activatedDay = null;
    _ownerEmail = null;
    _claimedOwner = null;
    _loadFailures = 0;
    _recoveredLoad = false;
    _lastError = null;
  }

  bool _loaded = false;
  int _loadFailures = 0;
  bool _recoveredLoad = false;
  String? _lastError;
  int? _balance;
  List<String> _pending = [];
  Set<String> _granted = {};

  /// Days completed via the Midnight Grace window, adopted from
  /// every settled [StreakState] this service sees (no-gems fix,
  /// Nov 21, 2026). Persisted in this service's own blob because
  /// the flush entry points that receive NO state (retryPending)
  /// must still retire stale grace keys without requesting them.
  Set<String> _graceDays = {};
  int? _lastStreak;
  String? _activatedDay;
  String? _ownerEmail;
  String? _claimedOwner;

  /// The latest SERVER balance (pull / grant / spend payloads
  /// only). Null until a server payload lands.
  int? get balance => _balance;

  /// Test/debug view of the persisted queues.
  @visibleForTesting
  List<String> get debugPending => List.unmodifiable(_pending);
  @visibleForTesting
  Set<String> get debugGranted => Set.unmodifiable(_granted);
  @visibleForTesting
  int? get debugLastStreak => _lastStreak;

  // ── Diagnostics (Developer Terminal grants card) ──────────────
  // The grant path's health at a glance. Before the Nov 20, 2026
  // fix, every failure on this path was swallowed by a catch-all
  // and NOTHING recorded it anywhere — the production ledger sat
  // at 0 rows while the app looked fine. These getters are the
  // visible surface that silence used to hide behind.
  bool get diagLoaded => _loaded;
  int get diagPendingCount => _pending.length;
  int get diagGrantedCount => _granted.length;

  /// True when this session recovered from a wedged storage entry
  /// (see [ensureLoaded]): the service started clean because the
  /// persisted entry could not be read at all.
  bool get diagRecoveredLoad => _recoveredLoad;

  /// The most recent load / grant / sync failure on this path,
  /// rendered `source: error`. Null when nothing has failed.
  String? get diagLastError => _lastError;

  void _noteError(String source, Object error) {
    _lastError = '$source: $error';
  }

  /// Record an error that escaped an app-open sync wrapper (the
  /// Home settle hooks are fail-soft by design) into this
  /// service's diagnostics state, so the wrapper's catch can never
  /// swallow a failure invisibly.
  void recordSyncError(Object error) => _noteError('sync', error);

  /// One storage read with a single immediate retry: a transient
  /// hiccup (keystore momentarily unavailable) is absorbed inside
  /// the same call instead of costing an entry point.
  Future<String?> _readWithRetry() async {
    try {
      return await _read(storageKey);
    } catch (_) {
      return _read(storageKey);
    }
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final String? raw;
    try {
      raw = await _readWithRetry();
    } catch (e, st) {
      // A read failure is NOT an empty disk (the streak store's
      // C-04 doctrine): the blob may be valid but momentarily
      // unreadable, so a first failure only records the error and
      // leaves [_loaded] false for the next call's retry. A
      // SECOND consecutive failure means the entry is wedged —
      // an undecryptable secure-storage value fails every read
      // until it is cleared — so recover: clear it and start
      // clean. Nothing recoverable is destroyed (the entry was
      // already unreadable), and this service's state is
      // re-derivable: the balance is server-adopted, week keys
      // re-derive at app open, milestones re-baseline without
      // backfill, and the server ledger's idempotency keys make
      // any re-requested grant a replay, never a double-pay —
      // the same backstop the corrupt-blob path below relies on.
      _loadFailures++;
      _noteError('load', e);
      CrashReporting.captureError(
        e,
        stackTrace: st,
        staticMessage: 'gems storage load failed',
      );
      if (_loadFailures < 2) return;
      try {
        await _delete(storageKey);
      } catch (_) {
        // Even with the store fully broken, the clean in-memory
        // start below keeps grants flowing this session.
      }
      _recoveredLoad = true;
      if (_claimedOwner != null) _ownerEmail = _claimedOwner;
      _loaded = true;
      return;
    }
    _loadFailures = 0;
    _loaded = true;
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final owner = decoded['ownerEmail'];
      _ownerEmail = owner is String ? owner : null;
      if (_claimedOwner != null && _ownerEmail != _claimedOwner) {
        _balance = null;
        _pending = [];
        _granted = {};
        _graceDays = {};
        _lastStreak = null;
        _activatedDay = null;
        _ownerEmail = _claimedOwner;
        unawaited(_deleteQuietly());
        return;
      }
      final bal = decoded['balance'];
      _balance = bal is int ? bal : null;
      final pending = decoded['pending'];
      if (pending is List) {
        _pending = pending.whereType<String>().toList();
      }
      final granted = decoded['granted'];
      if (granted is List) _granted = granted.whereType<String>().toSet();
      final graceDays = decoded['graceDays'];
      if (graceDays is List) {
        _graceDays = graceDays.whereType<String>().toSet();
      }
      final last = decoded['lastStreak'];
      _lastStreak = last is int ? last : null;
      final act = decoded['activatedDay'];
      _activatedDay = act is String ? act : null;
    } catch (_) {
      // A corrupt blob starts clean; server idempotency is the
      // backstop against any duplicate this could cause.
      _balance = null;
      _pending = [];
      _granted = {};
      _graceDays = {};
      _lastStreak = null;
      _activatedDay = null;
    }
  }

  Future<void> _deleteQuietly() async {
    try {
      await _delete(storageKey);
    } catch (_) {}
  }

  /// Account binding (StreakStore parity): a different account's
  /// queued grants / markers never surface under a new owner.
  Future<void> clearIfOwnerMismatch(String? email) async {
    if (email == null || email.isEmpty) return;
    _claimedOwner = email;
    if (_ownerEmail != null && _ownerEmail != email) {
      _balance = null;
      _pending = [];
      _granted = {};
      _graceDays = {};
      _lastStreak = null;
      _activatedDay = null;
      unawaited(_deleteQuietly());
    }
    _ownerEmail = email;
    await ensureLoaded();
  }

  Future<void> _persist() async {
    if (!_loaded) return;
    // Bound the granted history: daily keys are the only unbounded
    // kind; keep the most recent 400 keys overall.
    var grantedList = _granted.toList()..sort();
    if (grantedList.length > 400) {
      grantedList = grantedList.sublist(grantedList.length - 400);
      _granted = grantedList.toSet();
    }
    // Same bound for the adopted grace days (ISO day strings sort
    // chronologically, so the tail is the most recent).
    var graceList = _graceDays.toList()..sort();
    if (graceList.length > 400) {
      graceList = graceList.sublist(graceList.length - 400);
      _graceDays = graceList.toSet();
    }
    try {
      await _write(
        storageKey,
        jsonEncode({
          'ownerEmail': _ownerEmail,
          'balance': _balance,
          'pending': _pending,
          'granted': grantedList,
          'graceDays': graceList,
          'lastStreak': _lastStreak,
          'activatedDay': _activatedDay,
        }),
      );
    } catch (_) {
      // In-memory state survives; the next mutation retries.
    }
  }

  void _setBalance(int? next) {
    if (next == null || next == _balance) return;
    _balance = next;
    notifyListeners();
  }

  /// Adopt a balance that arrived on a server payload the caller
  /// already holds (e.g. Home's streak-record pull) — the SAME
  /// source the buy surface reads.
  void adoptServerBalance(int? next) {
    if (next == null) return;
    _setBalance(next);
    unawaited(() async {
      await ensureLoaded();
      _setBalance(next);
      await _persist();
    }());
  }

  /// Refresh the balance from the profile pull (the buy surface's
  /// and the pill's one source). Returns the balance, or null when
  /// the pull failed (the last server value stands).
  Future<int?> refreshBalance() async {
    await ensureLoaded();
    try {
      final pulled = await _pullBalanceFn();
      if (pulled != null) {
        _setBalance(pulled);
        await _persist();
      }
      return _balance;
    } catch (_) {
      return _balance;
    }
  }

  void _activateIfNeeded(String todayTabsDay, {int? baselineStreak}) {
    if (_activatedDay != null) return;
    _activatedDay = todayTabsDay;
    // No-backfill baseline: the marker starts at the streak as it
    // already stands, so milestones at or below it never pay.
    if (_lastStreak == null && baselineStreak != null) {
      _lastStreak = baselineStreak;
    }
  }

  /// Queue [keys] for granting: persisted BEFORE any request, and
  /// never re-queued once granted or already queued.
  void _queue(List<String> keys) {
    for (final k in keys) {
      if (_granted.contains(k) || _pending.contains(k)) continue;
      _pending.add(k);
    }
  }

  // ── Midnight Grace no-gems (Nov 21, 2026) ─────────────────────
  // Founder verbatim: "you shouldn't get gems for doing the grace
  // period." A grace-completed day earns NO gems of any kind. The
  // server cannot distinguish a grace day (it validates against
  // summaryCompletedDays, which a grace day legitimately joins),
  // so suppression is client-side and absolute: never queue the
  // key, and retire without requesting any stale key the shipped
  // gem-paying build (VC 100157) may have left pending.

  /// Adopt [state]'s grace-completed days into this service's own
  /// record (persisted by the caller's next [_persist]). Adoption
  /// is what lets the state-less flush entry points (retryPending)
  /// apply the same suppression as the state-carrying ones.
  void _adoptGraceDays(StreakState state) {
    if (state.graceCompletedDays.isEmpty) return;
    _graceDays = {..._graceDays, ...state.graceCompletedDays};
  }

  /// The perfect-week STRICT predicate — the ONE localized check
  /// both evaluation sites (processCompletion and onAppOpen) use:
  /// a week pays +20 only when all 7 days summary-completed AND
  /// none of them was grace-completed. (Flagged for Vera + Juno
  /// concurrence at review: a single grace day anywhere in the
  /// week forfeits that week's +20.)
  bool _weekPays(StreakState state, List<String> days) =>
      days.every(state.summaryCompletedDays.contains) &&
      !days.any(state.graceCompletedDays.contains);

  /// Whether a queued grant [key] is attributable to grace days
  /// this service has adopted: a `daily:` key for a grace day, or
  /// a `week:` key whose week contains any grace day. Milestone
  /// keys are deliberately left alone here: they carry no day and
  /// cannot be attributed to a grace day, and retiring by number
  /// would be unsafe (the same `milestone:<n>` is the legitimate
  /// key for whichever completion crossed n). This build never
  /// queues a milestone key for a grace completion
  /// (processCompletion queues nothing), but the shipped
  /// VC 100157 build DID queue `milestone:<n>` for grace
  /// completions, so a milestone key left pending from that build
  /// (offline / retryable refusal at completion) can survive the
  /// upgrade and WILL be requested by this flush — an accepted,
  /// bounded residual (C2, PR #135): it requires a 100157 grace
  /// completion that exactly crossed a milestone with the grant
  /// still pending at upgrade, and Mason's production survey
  /// found 0 milestone rows and 0 grace payments ever.
  bool _isGraceKey(String key) {
    if (_graceDays.isEmpty) return false;
    if (key.startsWith('daily:')) {
      return _graceDays.contains(key.substring('daily:'.length));
    }
    if (key.startsWith('week:')) {
      try {
        return gemWeekDays(key.substring('week:'.length))
            .any(_graceDays.contains);
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  /// Whether a non-200 grant answer is a RETRY-LATER refusal:
  /// the key stays queued and is re-requested at the next
  /// app-open sync, exactly like a network failure, and is never
  /// surfaced to the user. The published shape (Mason PR #41 Fix
  /// Round 1, MASON-REPORT.md) is
  /// `409 {error: 'grant_not_ready', retryable: true, reason}` —
  /// bound-based refusals: milestone n above the profile's
  /// best_streak, a daily/week date not (yet) in the pushed
  /// blob's summaryCompletedDays, a future-dated key, or no
  /// parseable blob yet. Those retry. A 400 (invalid_key /
  /// invalid_request) is a PERMANENT refusal — the key itself is
  /// malformed — and is dropped rather than retried forever; it
  /// is unreachable from this client, whose keys are canonical
  /// by construction (milestone:7, never milestone:07; ladder
  /// enforced by [gemMilestoneBonus]; dates from real settled
  /// completions). Every other non-200 (5xx, transport-shaped)
  /// retries: keeping a key queued is always the safe side.
  static bool isRetryableRefusal(GemRequestResult r) {
    if (r.statusCode == 200) return false;
    if (r.statusCode == 400) return false;
    return true;
  }

  /// Attempt every pending grant once. A 200 (new grant OR
  /// alreadyGranted replay) retires the key and adopts the
  /// response balance; a network failure OR a retryable bound
  /// refusal (409 grant_not_ready) leaves it queued for the next
  /// app-open sync; a permanent 400 retires the key silently
  /// (unreachable by construction — see [isRetryableRefusal]).
  ///
  /// Returns the keys retired by THIS flush, split by freshness.
  /// A 200 whose body reports `alreadyGranted: true` is a
  /// REPLAY: the key still retires and the response balance is
  /// still adopted, but the gems did NOT land in this flush, so
  /// Juno §3a forbids an earn line for it — only keys in `fresh`
  /// (a 200 without `alreadyGranted`) may earn one. The split
  /// matters whenever the local granted-history is gone (owner-
  /// mismatch clear, reinstall, secure-storage loss): a replayed
  /// completion then re-requests its key and the server answers
  /// `alreadyGranted: true` (Vera B1, Fix Round 1).
  ///
  /// Single-flight (celebration-delay package, Nov 23, 2026):
  /// flushes never overlap. A key leaves [_pending] only AFTER
  /// its grant returns, so two flushes walking the queue at once
  /// (a completion claim racing the app-open sync) would each
  /// fire a grant request for the same key — the server's
  /// idempotency prevents a double PAY, but the claim discipline
  /// is exactly one request per key. A call that arrives while a
  /// flush is in flight chains a fresh pass behind it, so keys
  /// queued after the in-flight pass's snapshot still get their
  /// attempt in this call.
  Future<({List<String> retired, List<String> fresh})>?
      _flushInFlight;

  Future<({List<String> retired, List<String> fresh})>
      _flushPending() {
    final inFlight = _flushInFlight;
    if (inFlight != null) {
      return inFlight.then((_) => _flushPending());
    }
    final pass = _doFlushPending();
    _flushInFlight = pass;
    return pass.whenComplete(() {
      if (identical(_flushInFlight, pass)) _flushInFlight = null;
    });
  }

  Future<({List<String> retired, List<String> fresh})>
      _doFlushPending() async {
    final retired = <String>[];
    final fresh = <String>[];
    var droppedGraceKeys = false;
    for (final key in List<String>.of(_pending)) {
      // No-gems flush hardening: a pending key attributable to a
      // grace day (queued by the shipped gem-paying build before
      // this fix, e.g. while offline at the grace completion) is
      // retired WITHOUT a request — it must never reach the
      // server, where it would validate and pay. The key is NOT
      // marked granted (it never was); the grace-day record is
      // what keeps it from ever being re-queued.
      if (_isGraceKey(key)) {
        _pending.remove(key);
        droppedGraceKeys = true;
        continue;
      }
      GemRequestResult r;
      try {
        r = await (_debugGrantFn ?? _grantFn)(key);
      } catch (e, st) {
        // Never silent (Nov 20, 2026 fix): a transport failure on
        // a grant attempt is recorded for the diagnostics card and
        // reported; the key stays queued for the next sync.
        _noteError('grant', e);
        CrashReporting.captureError(
          e,
          stackTrace: st,
          staticMessage: 'gems grant request failed',
        );
        continue;
      }
      if (isRetryableRefusal(r) || r.body == null) {
        if (r.statusCode != null) {
          _noteError('grant', 'HTTP ${r.statusCode} for $key');
        }
        continue;
      }
      final bal = r.body!['gemBalance'];
      _pending.remove(key);
      _granted.add(key);
      retired.add(key);
      if (r.statusCode == 200 && r.body!['alreadyGranted'] != true) {
        fresh.add(key);
      }
      if (bal is int) _setBalance(bal);
    }
    if (retired.isNotEmpty || droppedGraceKeys) await _persist();
    return (retired: retired, fresh: fresh);
  }

  String? _lineForKey(String key) {
    if (key.startsWith('daily:')) return GemCopy.dailyEarnLine;
    if (key.startsWith('milestone:')) {
      final n = int.tryParse(key.substring('milestone:'.length));
      if (n == null) return null;
      final bonus = gemMilestoneBonus(n);
      if (bonus == null) return null;
      return GemCopy.milestoneEarnLine(bonus, n);
    }
    if (key.startsWith('week:')) return GemCopy.weekEarnLine;
    return null;
  }

  /// The completion earn hook — called ONLY from the real
  /// post-PR-#115 completion path (the watcher's callback), with
  /// the settled state AFTER the completion counted the day.
  ///
  /// Computes this completion's grant keys (daily, milestone
  /// crossings, perfect week), persists them to the pending queue
  /// BEFORE requesting, then flushes. Lines are returned ONLY for
  /// grants the server confirmed FRESH during this call — an
  /// alreadyGranted replay earns no line (Juno §3 truth rule); a
  /// failed grant queues silently and the completion flow
  /// is never broken by it. [previousStreak] is the settled streak
  /// before this completion counted the day (the caller derives it
  /// from the settled state); the persisted marker governs when it
  /// exists, so a restart between settlement and grant can neither
  /// lose nor duplicate a crossing.
  Future<GemEarnResult> processCompletion({
    required String summaryTabsDay,
    required int previousStreak,
    required int newStreak,
    required StreakState settledState,
    required DateTime now,
  }) async {
    try {
      await ensureLoaded();
      if (!_loaded) return GemEarnResult(lines: const [], balance: _balance);
      _adoptGraceDays(settledState);
      _activateIfNeeded(summaryTabsDay, baselineStreak: previousStreak);
      final effectivePrev = _lastStreak ?? previousStreak;

      // Midnight Grace no-gems: a completion whose day is marked
      // grace-completed queues NO keys — no daily, no milestone,
      // no week (see [_completionKeys]). The streak marker below
      // STILL advances to [newStreak], so a milestone crossing on
      // a grace day is consumed permanently, never re-evaluated
      // (and never paid) by a later completion. The celebration
      // still fires; only the gems are withheld. Suppression keys
      // off the per-day marker only, never the window (C3): the
      // new day's own genuine completion is unmarked and pays
      // normally.
      final keys = _completionKeys(
        summaryTabsDay: summaryTabsDay,
        effectivePrev: effectivePrev,
        newStreak: newStreak,
        settledState: settledState,
      );

      _queue(keys);
      if (newStreak > (_lastStreak ?? 0)) _lastStreak = newStreak;
      // The marker + queue land BEFORE the first request.
      await _persist();

      final flush = await _flushPending();
      // Lines only for THIS completion's keys whose grants the
      // server confirmed FRESH in this flush — an alreadyGranted
      // replay retires the key and adopts the balance but earns
      // NO line (Juno §3a) — in Juno §3 order: daily,
      // milestone(s), perfect week.
      final lines = <String>[];
      for (final k in keys) {
        if (!flush.fresh.contains(k)) continue;
        final line = _lineForKey(k);
        if (line != null) lines.add(line);
      }
      return GemEarnResult(lines: lines, balance: _balance);
    } catch (_) {
      // A gem failure must never break the completion flow.
      return GemEarnResult(lines: const [], balance: _balance);
    }
  }

  /// This completion's grant keys (daily, milestone crossings,
  /// perfect week) — the ONE computation [processCompletion] and
  /// [projectedCompletionLines] share, so the projected
  /// celebration lines can never drift from the keys the claim
  /// will actually request. [effectivePrev] is the settled streak
  /// before this completion as the persisted marker reports it
  /// (the caller resolves it identically for both entry points).
  /// A grace-completed day (in [StreakState.graceCompletedDays])
  /// yields NO keys — the grace no-gems rule.
  List<String> _completionKeys({
    required String summaryTabsDay,
    required int effectivePrev,
    required int newStreak,
    required StreakState settledState,
  }) {
    if (settledState.graceCompletedDays.contains(summaryTabsDay)) {
      return const [];
    }
    final keys = <String>[];
    // Daily — exactly once per Tabs day (queue/granted dedupe;
    // server idempotency is the backstop).
    keys.add('daily:$summaryTabsDay');
    // Milestones — real crossings only: prev < n <= new.
    for (var n = effectivePrev + 1; n <= newStreak; n++) {
      if (gemMilestoneBonus(n) != null) keys.add('milestone:$n');
    }
    // Perfect week — the summary day's own Mon–Sun week, all
    // 7 days summary-completed, none grace-completed (the
    // strict predicate), and the week did not end before the
    // feature activated (no backfill).
    final monday = gemWeekMonday(summaryTabsDay);
    final days = gemWeekDays(monday);
    final sunday = days.last;
    if ((_activatedDay == null || sunday.compareTo(_activatedDay!) >= 0) &&
        _weekPays(settledState, days)) {
      keys.add('week:$monday');
    }
    return keys;
  }

  /// LOCAL projection of this completion's Juno §3 earn lines —
  /// the celebration-delay fix (Nov 23, 2026). Home builds the
  /// celebration from this projection and presents it BEFORE any
  /// network await; the real claim ([processCompletion], same
  /// keys via [_completionKeys]) then runs behind the presented
  /// celebration and lands on its own discipline. Amounts are
  /// deterministic (daily +5, the milestone ladder, week +20 —
  /// [_lineForKey] is the same mapping the confirmed flow uses),
  /// grace-completed days project NO lines (the shared key
  /// computation suppresses them), and a key this device already
  /// knows is granted projects no line (the confirmed flow can
  /// never earn a fresh line for it either — [_queue] skips it).
  /// This method performs NO network I/O: [ensureLoaded] is a
  /// local secure-storage read, and the grace adoption +
  /// activation below are the same idempotent preamble
  /// [processCompletion] runs, so projecting first cannot change
  /// what the claim computes moments later.
  ///
  /// §3a DIVERGENCE (flagged for Vera/Juno ruling, Nov 23, 2026):
  /// Juno §3a defines earn lines as server-confirmed-FRESH — an
  /// `alreadyGranted` replay earns no line. A projection cannot
  /// know freshness: it assumes this completion's not-yet-locally-
  /// granted keys will confirm fresh. It therefore diverges from
  /// the §3a outcome in exactly one case: a key the server has
  /// ALREADY granted but this device's local granted-history does
  /// not record (the history was lost — reinstall, owner-mismatch
  /// clear, secure-storage loss — after a prior flush granted the
  /// key, e.g. a crash between that grant landing and any
  /// presentation of it). The projected celebration then shows a
  /// line for gems that in fact landed in the earlier flush; the
  /// background claim still retires the key as a replay, adopts
  /// the true balance, and never double-pays (server idempotency).
  /// No shape that keeps network out of the presentation path can
  /// rule this case out — freshness is server state — so it is
  /// documented here and in the package stage log for an explicit
  /// Vera/Juno ruling rather than silently accepted.
  Future<List<String>> projectedCompletionLines({
    required String summaryTabsDay,
    required int previousStreak,
    required int newStreak,
    required StreakState settledState,
  }) async {
    try {
      await ensureLoaded();
      if (!_loaded) return const [];
      _adoptGraceDays(settledState);
      _activateIfNeeded(summaryTabsDay, baselineStreak: previousStreak);
      final effectivePrev = _lastStreak ?? previousStreak;
      final keys = _completionKeys(
        summaryTabsDay: summaryTabsDay,
        effectivePrev: effectivePrev,
        newStreak: newStreak,
        settledState: settledState,
      );
      final lines = <String>[];
      for (final k in keys) {
        if (_granted.contains(k)) continue;
        final line = _lineForKey(k);
        if (line != null) lines.add(line);
      }
      return lines;
    } catch (_) {
      // A projection failure must never break the completion
      // flow: the celebration simply carries no gem lines and
      // the claim behind it proceeds unchanged.
      return const [];
    }
  }

  /// App-open sync: adopt the settled streak as the no-backfill
  /// baseline on first run, evaluate any just-closed perfect week
  /// the completion path has not already queued, and retry every
  /// pending grant. Never throws; returns the latest balance.
  Future<int?> onAppOpen({
    required StreakState state,
    required DateTime now,
  }) async {
    try {
      await ensureLoaded();
      if (!_loaded) return _balance;
      _adoptGraceDays(state);
      final today = tabsDayStr(now);
      final anchor = tabsDayAnchor(now);
      _activateIfNeeded(
        today,
        baselineStreak: streakCurrent(state, anchor),
      );
      // Perfect-week settle check for the current and previous
      // weeks (a week whose Sunday completion queued its grant
      // already is deduped by _queue). The SAME strict grace
      // predicate as the completion path applies here — this
      // reconcile site must never re-queue a week the completion
      // path suppressed.
      final keys = <String>[];
      for (final probe in [
        today,
        streakDayStr(anchor.subtract(const Duration(days: 7))),
      ]) {
        final monday = gemWeekMonday(probe);
        final days = gemWeekDays(monday);
        if (_activatedDay != null &&
            days.last.compareTo(_activatedDay!) < 0) {
          continue;
        }
        if (_weekPays(state, days)) {
          keys.add('week:$monday');
        }
      }
      _queue(keys);
      await _persist();
      await _flushPending();
      return _balance;
    } catch (_) {
      return _balance;
    }
  }

  /// Retry queued grants without any evaluation (spend/restore
  /// surfaces, tests). Returns the latest balance.
  Future<int?> retryPending() async {
    await ensureLoaded();
    if (!_loaded) return _balance;
    await _flushPending();
    return _balance;
  }

  /// Spend 300 gems on one streak freeze (POST /api/gems/spend/
  /// freeze). A unique spendId is generated per user intent; the
  /// server makes a replayed spendId a replay, never a double
  /// charge. Every server answer (success AND the 409s) carries
  /// the authoritative balance, which is adopted here — the
  /// caller refreshes its surfaces from it and never shows a raw
  /// error code. The gem path's only refusal outcomes are
  /// [GemSpendStatus.insufficient] and [GemSpendStatus.capReached]:
  /// since the Nov 21, 2026 rule change there is no already-held
  /// outcome for a gem spend (see the legacy-code mapping in the
  /// 409 switch below).
  Future<GemSpendResult> spendOnFreeze({String? spendId}) async {
    await ensureLoaded();
    GemRequestResult r;
    try {
      r = await _spendFn(spendId ?? _spendIdGen());
    } catch (_) {
      return const GemSpendResult(status: GemSpendStatus.failed);
    }
    final body = r.body;
    int? bal;
    int? freezes;
    if (body != null) {
      final b = body['gemBalance'];
      if (b is int) bal = b;
      final f = body['purchasedFreezes'];
      if (f is int) freezes = f;
    }
    if (bal != null) {
      _setBalance(bal);
      await _persist();
    }
    if (r.statusCode == 200 && body != null) {
      return GemSpendResult(
        status: body['alreadyGranted'] == true
            ? GemSpendStatus.replay
            : GemSpendStatus.success,
        balance: bal,
        purchasedFreezes: freezes,
      );
    }
    if (r.statusCode == 409 && body != null) {
      switch (body['error']) {
        case 'insufficient_gems':
          return GemSpendResult(
            status: GemSpendStatus.insufficient,
            balance: bal,
            purchasedFreezes: freezes,
          );
        case 'purchased_already_held':
          // Gem-buy rule change (Nov 21, 2026): the server no
          // longer returns this code for gem spends — holding a
          // purchased-class freeze no longer blocks a gem buy.
          // Only a pre-change server can still answer it. Map it
          // to the capReached re-sync outcome so the legacy code
          // can NEVER surface as a user-facing failure (or a
          // success) on the gem-spend path: the answer's balance
          // and freeze count are adopted above, both surfaces
          // re-derive from that state, and the user can retry
          // once the updated server is live.
          return GemSpendResult(
            status: GemSpendStatus.capReached,
            balance: bal,
            purchasedFreezes: freezes,
          );
        case 'freeze_cap_reached':
          return GemSpendResult(
            status: GemSpendStatus.capReached,
            balance: bal,
            purchasedFreezes: freezes,
          );
      }
    }
    return GemSpendResult(
      status: GemSpendStatus.failed,
      balance: bal,
      purchasedFreezes: freezes,
    );
  }
}
