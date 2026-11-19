import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
///
/// Copy: EVERY user-facing gems string lives in [GemCopy] below,
/// verbatim from Juno's ruling (build-gems/JUNO-COPY.md §§1–4) —
/// the StreakPurchaseCopy swap-point pattern. No other file
/// hardcodes gems copy.
abstract final class GemCopy {
  /// The bundled gem icon asset (founder-approved v1 art).
  static const String iconAsset =
      'assets/images/tabs_gem_icon_v1_20261119.png';

  /// The fixed gem price of one streak freeze (Juno §2a literal).
  static const int freezePrice = 100;

  // ── §1 Home pill accessibility label ──────────────────────────
  static String pillLabel(int count) => count == 1 ? '1 gem' : '$count gems';

  // ── §2 Buy-with-gems surface ──────────────────────────────────
  static const String buyButtonLabel = 'GET ONE MORE FREEZE · 100 GEMS';

  static String balanceLine(int balance) =>
      balance == 1 ? 'You have 1 gem.' : 'You have $balance gems.';

  /// §2c success title (lowercase friend register, as ruled).
  static const String spendSuccessTitle = 'freeze added';

  /// §2c success body; [balance] is the post-spend SERVER balance.
  static String spendSuccessBody(int balance) => balance == 1
      ? "you've got a freeze now. it covers one missed day. you have 1 gem left."
      : "you've got a freeze now. it covers one missed day. you have $balance gems left.";

  /// §2d insufficient-balance line; [needed] is 100 − balance.
  static String insufficientLine(int needed) => needed == 1
      ? 'you need 1 more gem for a freeze — you earn 5 gems each time you finish your daily summary.'
      : 'you need $needed more gems for a freeze — you earn 5 gems each time you finish your daily summary.';

  // ── §3 Celebration earn lines ─────────────────────────────────
  static const String dailyEarnLine = '+5 gems';

  static String milestoneEarnLine(int bonus, int days) =>
      '+$bonus gems — $days-day streak bonus';

  static const String weekEarnLine = '+20 gems — perfect week bonus';

  // ── §4 Streak-screen explainer (verbatim block) ───────────────
  static const String explainerHeading = 'About gems';
  static const List<String> explainerLines = [
    "Gems are earned in Tabs. You can't buy them, and they have no cash value.",
    'Finish your Daily Summary: +5 gems.',
    'Streak bonuses pay when you reach them: +25 gems at 7 days, +50 at 30 days, +100 at 100 days, and +100 at each 100 days after that.',
    'Perfect week: +20 gems when you finish your Daily Summary all 7 days of a Monday–Sunday week.',
    '100 gems buys one streak freeze — the freeze on this screen.',
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
  alreadyHeld,
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

  @visibleForTesting
  void debugReset() {
    _loaded = false;
    _balance = null;
    _pending = [];
    _granted = {};
    _lastStreak = null;
    _activatedDay = null;
    _ownerEmail = null;
    _claimedOwner = null;
  }

  bool _loaded = false;
  int? _balance;
  List<String> _pending = [];
  Set<String> _granted = {};
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
        _balance = null;
        _pending = [];
        _granted = {};
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
    try {
      await _write(
        storageKey,
        jsonEncode({
          'ownerEmail': _ownerEmail,
          'balance': _balance,
          'pending': _pending,
          'granted': grantedList,
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
  Future<({List<String> retired, List<String> fresh})>
      _flushPending() async {
    final retired = <String>[];
    final fresh = <String>[];
    for (final key in List<String>.of(_pending)) {
      GemRequestResult r;
      try {
        r = await _grantFn(key);
      } catch (_) {
        continue;
      }
      if (isRetryableRefusal(r) || r.body == null) continue;
      final bal = r.body!['gemBalance'];
      _pending.remove(key);
      _granted.add(key);
      retired.add(key);
      if (r.statusCode == 200 && r.body!['alreadyGranted'] != true) {
        fresh.add(key);
      }
      if (bal is int) _setBalance(bal);
    }
    if (retired.isNotEmpty) await _persist();
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
      _activateIfNeeded(summaryTabsDay, baselineStreak: previousStreak);
      final effectivePrev = _lastStreak ?? previousStreak;

      final keys = <String>[];
      // Daily — exactly once per Tabs day (queue/granted dedupe;
      // server idempotency is the backstop).
      keys.add('daily:$summaryTabsDay');
      // Milestones — real crossings only: prev < n <= new.
      for (var n = effectivePrev + 1; n <= newStreak; n++) {
        if (gemMilestoneBonus(n) != null) keys.add('milestone:$n');
      }
      // Perfect week — the summary day's own Mon–Sun week, all 7
      // days summary-completed, and the week did not end before
      // the feature activated (no backfill).
      final monday = gemWeekMonday(summaryTabsDay);
      final days = gemWeekDays(monday);
      final sunday = days.last;
      if ((_activatedDay == null || sunday.compareTo(_activatedDay!) >= 0) &&
          days.every(settledState.summaryCompletedDays.contains)) {
        keys.add('week:$monday');
      }

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
      final today = tabsDayStr(now);
      final anchor = tabsDayAnchor(now);
      _activateIfNeeded(
        today,
        baselineStreak: streakCurrent(state, anchor),
      );
      // Perfect-week settle check for the current and previous
      // weeks (a week whose Sunday completion queued its grant
      // already is deduped by _queue).
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
        if (days.every(state.summaryCompletedDays.contains)) {
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

  /// Spend 100 gems on one streak freeze (POST /api/gems/spend/
  /// freeze). A unique spendId is generated per user intent; the
  /// server makes a replayed spendId a replay, never a double
  /// charge. Every server answer (success AND the three 409s)
  /// carries the authoritative balance, which is adopted here —
  /// the caller refreshes its surfaces from it and never shows a
  /// raw error code.
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
          return GemSpendResult(
            status: GemSpendStatus.alreadyHeld,
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
