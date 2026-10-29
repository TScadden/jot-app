import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:tabs_lab/src/data/billing_service.dart';
import 'package:tabs_lab/src/data/daily_score.dart';
import 'package:tabs_lab/src/data/daily_score_refresh.dart'
    show ScoreCapture;
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart'
    show historyDateStr;
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_history_sync.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/migraine_controller.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/launch_trace.dart';
import 'package:tabs_lab/src/data/location_service.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/data/widget_sync.dart';
import 'package:tabs_lab/src/features/connections/connections_screen.dart';
import 'package:tabs_lab/src/features/home/daily_score_circle.dart';
import 'package:tabs_lab/src/features/home/daily_score_screen.dart';
import 'package:tabs_lab/src/features/home/checkin_sheets.dart';
import 'package:tabs_lab/src/features/home/checkin_summary_card.dart';
import 'package:tabs_lab/src/features/home/feeling_checkin_card.dart';
import 'package:tabs_lab/src/features/home/flare_day_logging.dart';
import 'package:tabs_lab/src/features/home/good_day_logging.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';
import 'package:tabs_lab/src/features/home/health_connect_banner.dart';
import 'package:tabs_lab/src/features/home/migraine_block.dart';
import 'package:tabs_lab/src/features/home/today_summary_card.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart';
import 'package:tabs_lab/src/features/home/weather_sheet.dart';
import 'package:tabs_lab/src/features/home/weekly_snapshot_card.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/slide_page_route.dart';

/// Round 4 — home screen, background only (native `today` route).
///
/// Round 5: after a real login, shows a small centered
/// "Logged in as {email}" indicator. TEMPORARY — it exists only so the
/// founder can verify login worked; it goes away when real home content
/// lands.
///
/// Round 6 — Today header (native `TodayScreen.kt` topBar):
/// - AppBar, container `NotelBackground`, title "Today" (22sp Black,
///   `NotelTextPrimary`), no navigation icon.
/// - Weather action (64dp wide): `"{temp}°"` (14sp Bold, textPrimary 80%)
///   + cloud icon (20dp, primary 70%). The temp renders ONLY when real
///   data has loaded — never placeholder zeros; icon alone until then.
///   Tap is a no-op for now (the native weather sheet doesn't exist yet).
/// - Watch action: watch icon (24dp, `NotelPrimary`). Native calls
///   `onNavigateToConnections` here; that screen doesn't exist yet, so
///   the tap is a no-op for now.
/// Round 8 — Today Summary + Weekly Snapshot cards sit under the streak
/// row (native `TodayScreen.kt` items 3 and 3B). Data sources aren't wired
/// yet, so both cards show their native empty states; the snapshot metric
/// switcher is live across all 7 metrics. The "Logged in as" indicator
/// stays below them until real home content lands.
/// Round 10 — tapping the weather icon asks for the device location
/// (system permission dialog) and upgrades the IP-based temp to a
/// GPS-based one. Denial or disabled services fall back silently to
/// the IP fetch — never an error, never a fake zero.
/// Round 12 — the watch icon opens the data-connections screen
/// (Health Connect permission flow + retired-Fitbit notice).
/// Round 21 — the "How are you feeling?" check-in card is the FIRST
/// item on Home (native `TodayScreen.kt` item 0, above the vitals
/// strip). Its visibility and writes run through the sync pull +
/// `POST /api/sync/entries`, mirroring native `EnergyCheckInViewModel`:
/// shown only while no check-in entry exists for the current energy
/// day (04:00 local boundary); one tap logs the uneditable
/// 'Daily Ranking' entry and the card slides away. See
/// `feeling_checkin_card.dart` for the full native trace.
/// Round 23 — Home tracks the Health Connect STATUS ENUM (not just a
/// bool): when the status is not fully connected AND the biometrics
/// are empty, a slim banner under the vitals strip explains the "--"
/// cells and deep-links to Connections (partial grants get their own
/// wording). Connected-but-empty keeps the plain "--", no banner.
/// See `health_connect_banner.dart`.
/// Round 34 — the streak row's right slot is the native rotating
/// event-counter pager (native `TodayScreen.kt` section 2 — native
/// DOES surface its Settings event counters on Today; the
/// `📅 ${firstEvent.title}` line at TodayScreen.kt:461 is only the
/// zero-counter FALLBACK and its `firstEvent` is an
/// `UpcomingEventItem` built from today's reminders in
/// `TodayViewModel`, not a counter). Counters come from the SAME
/// profile-synced source Settings round 29 uses (the sync pull's
/// `profile.eventCounters`, decoded via [SettingsProfileData]), so
/// archiving in Settings removes a counter from Home and vice versa.
/// Cached counters render instantly (account-bound [HomeDataCache],
/// stale-while-revalidate); zero active counters render no slot.
/// Round 38 — the temporary "Logged in as {email}" label (Rounds 5/8,
/// founder verification only) is REMOVED from Home at the founder's
/// request: the signed-in email is no longer rendered anywhere on
/// this screen. The [HomeScreen.email] value itself stays — it is
/// internal plumbing (account-binding for the counters cache and
/// the email forwarded to the Settings screen pushed from Home),
/// never visible text here. The email still belongs on Settings.
class HomeScreen extends StatefulWidget {
  /// The signed-in account email. INTERNAL ONLY (Round 38): used to
  /// account-bind the Home counters cache and forwarded to the
  /// Settings screen pushed from Home. Never rendered on Home.
  final String? email;
  final WeatherApiClient? weatherApi;

  /// Injectable for tests; defaults to the real geolocator wrapper.
  final LocationService? locationService;

  /// Injectable for tests; defaults to a real HealthConnectService.
  /// Shared with the connections screen (and future onboarding) — state
  /// is persisted, so any instance sees the same connection.
  final HealthConnectService? healthConnectService;

  /// Injectable for tests; defaults to a real repository built from
  /// [healthConnectService]. Lets tests control (or stall) the
  /// background health-data load.
  final HealthRepository? healthRepository;

  /// Injectable for tests (round 21 check-in); defaults to the
  /// [HealthRepository]'s backend so Home shares one sync-pull cache.
  final TabsBackend? tabsBackend;

  /// Injectable for tests (counter-mutation durability, Oct 2026);
  /// defaults to the real on-device store. Home's counter load reads
  /// the locally persisted deleted-counter tombstones from here (the
  /// same store Settings writes at delete time) so a pulled list
  /// that still carries a deleted id cannot resurrect it on Home
  /// either. Forwarded to the Settings screen pushed from the
  /// counter slot so both surfaces share one store in tests.
  final SettingsStore? settingsStore;

  /// Round 34 — forwarded to the Settings screen pushed from the
  /// counter slot, so a logout started there still exits to the
  /// welcome flow (the shell owns that callback).
  final VoidCallback? onLogout;

  /// R70 Daily Score — injectable for tests; defaults to the
  /// shared history store singleton.
  final HealthHistoryStore? healthHistoryStore;

  /// Daily Score snapshot capture (founder amendment, Oct 20,
  /// 2026) — injectable for tests; defaults to a non-forced capture
  /// through a [HealthHistorySync] bound to the score store, run
  /// before the score load computes anything.
  final ScoreCapture? dailyScoreSnapshotCapture;

  /// The app-owned billing service (single instance), forwarded
  /// to the Settings screen pushed from the counter slot.
  final BillingService? billingService;

  /// The shared app-level migraine controller (app wiring in
  /// main.dart). Home consumes its one-shot pending-details signal
  /// (notification tap → attack ended → details form, Juno §C) and
  /// forwards the controller to the Today Summary card.
  final MigraineController? migraineController;

  /// Phase 1 item 1 — the entry outbox the flare-day commit stages
  /// through (the shipped VC 100107 optimistic mechanism). Injectable
  /// for tests; defaults to the shared singleton every other entry
  /// writer uses.
  final LogEntryOutbox? logEntryOutbox;

  const HomeScreen(
      {super.key,
      this.email,
      this.weatherApi,
      this.locationService,
      this.healthConnectService,
      this.healthRepository,
      this.tabsBackend,
      this.settingsStore,
      this.onLogout,
      this.healthHistoryStore,
      this.dailyScoreSnapshotCapture,
      this.billingService,
      this.migraineController,
      this.logEntryOutbox});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int? _temp;
  bool _weatherLoaded = false;

  /// Round 14 — condition fields for the living header icon.
  int? _weatherCode;
  bool _isDay = true;

  /// Country code from the IP fetch — reused for units when the user
  /// upgrades to GPS weather via the weather-icon tap.
  String _countryCode = 'US';

  // ── Round 13: real health data ──────────────────────────────────────────
  late final HealthRepository _healthRepo;
  TodayVitals? _vitals;
  int? _currentStreak;
  int? _bestStreak;

  // ── Round 23: Health Connect status (enum, not just a bool) ────────────
  /// Null until the first live status check lands — the banner never
  /// shows on a guess, and cached vitals render first regardless.
  HealthConnectStatus? _hcStatus;

  /// Visible-handling for a bridge failure (LESSONS.md): when
  /// `getStatus()` itself throws, [_hcStatus] falls back to
  /// notConnected (the honest user-facing state) and the exception
  /// code is kept here so the banner can render it as `[CODE]`.
  String? _hcStatusErrorCode;

  /// Round 15c — once-per-day count-up gate. False until the gate
  /// resolves; true only on the first home view of the day. On later
  /// views the numbers render instantly (watching them count up again
  /// reads as "no data yet").
  bool _countUpsAnimate = false;

  // ── Round 21: feeling check-in ───────────────────────────────────
  /// False until the sync pull proves no check-in exists for the
  /// current energy day (native's view model also starts hidden and
  /// only shows the card once the entry flow says so). A failed pull
  /// keeps the card hidden — the honest state, never a guess.
  bool _feelingVisible = false;

  /// Double-tap guard (native `tapInFlight`): one tap, one entry.
  bool _feelingTapInFlight = false;
  int? _feelingCategoryId;

  // ── Merged check-in flow (Juno ruling Oct 28, 2026) ─────────────
  /// Null until the sync pull resolves the Symptoms category (spec
  /// §4.2 honesty pattern: hide rather than misfile). The good-day
  /// record files under the Mood & Energy category — the check-in's
  /// own category, [_feelingCategoryId].
  int? _flareCategoryId;

  /// Today's three records, each DERIVED from the entry set (pulled
  /// entries overlaid with the outbox's pending local entries) —
  /// never persisted as separate state. Per-record gate (Juno
  /// Item 11): a record appears here only after ITS local stage
  /// succeeded, so a failed flare/good stage leaves the summary
  /// showing the ranking alone.
  QuickLogEntry? _checkInToday;
  QuickLogEntry? _flareToday;
  QuickLogEntry? _goodToday;

  /// The latest Item 11 live-region announcement label (a flare or
  /// good-day commit label), carried by the summary card. Null
  /// until a flare/good record commits this session.
  String? _checkInAnnouncement;

  /// The last known entry set AS MERGED with the outbox overlay —
  /// the Quick Log pattern (an entry whose push has landed stays in
  /// the local view even after its queue record leaves the outbox,
  /// until the next pull confirms it). Re-deriving against a stale
  /// raw pull instead would un-log a just-committed record.
  List<QuickLogEntry> _mergedEntries = const [];

  /// Commit guards: a double-tap or retry amends, never duplicates.
  bool _flareCommitInFlight = false;
  bool _goodCommitInFlight = false;

  LogEntryOutbox get _outbox => widget.logEntryOutbox ?? LogEntryOutbox.instance;

  // ── Round 34: event counters ─────────────────────────────────────
  /// Active counters in Settings list order. Empty until the cache or
  /// the first pull proves otherwise — the slot renders nothing while
  /// empty (honest state, no placeholder).
  List<EventCounterItem> _counters = const [];

  TabsBackend get _backend => widget.tabsBackend ?? _healthRepo.backend;

  // ── R70 Daily Score ─────────────────────────────────────────────
  /// Today's persisted Daily Score; null while no score exists
  /// for today (the header circle renders its building or pending
  /// state — never a number from nothing). Paint-first (Oct 22,
  /// 2026): today's row is read from the store and painted as
  /// soon as it lands; the snapshot capture + compute trigger
  /// then refresh it in the background (see [_loadDailyScore]).
  int? _todayScore;

  /// True when today is unscored but the score system is active
  /// (a scored day exists, or a component already counts for
  /// today): the completeness gate's pending state — today's
  /// score is waiting for today's health data to arrive. False
  /// while the baseline itself is still building.
  bool _todayScorePending = false;

  Future<void> _loadDailyScore() async {
    final store = widget.healthHistoryStore ?? HealthHistoryStore.instance;
    final today = historyDateStr(DateTime.now());

    // Derives today's score + pending flag from a store read —
    // the exact expressions this load has always used — and
    // paints only when they actually changed (no flicker on
    // repeated calls). Display derivation only: writes nothing.
    void paintFrom(Map<String, DailyBiometrics> all) {
      final row = all[today];
      final score = row?.dailyScore;
      final pending = score == null &&
          (all.values.any((r) => r.dailyScore != null) ||
              computeDailyScore(all, today) != null);
      if (score != _todayScore || pending != _todayScorePending) {
        setState(() {
          _todayScore = score;
          _todayScorePending = pending;
        });
      }
    }

    // BACKGROUND REFRESH: the existing snapshot → compute →
    // re-read chain, unchanged and in the same order, runs
    // behind the painted score and repaints on a change. Its
    // start is single-shot per load, kicked by whichever lands
    // first: the first paint completing (the normal case — the
    // chain then starts right after the paint), or the end of
    // the first frame. The frame kick exists so a first store
    // read that never lands cannot strand the chain behind it:
    // at base this load's first await WAS the snapshot, so the
    // capture (and its app-wide single-flight) always started
    // from this call even when the store read behind it wedged.
    Future<void>? chain;
    Future<void> startChain() => chain ??= _refreshDailyScoreChain(
        store: store, today: today, paintFrom: paintFrom);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(startChain());
    });

    // PAINT-FIRST (Oct 22, 2026): read the store and paint
    // today's stored score immediately, before the snapshot.
    // A due capture used to hold the header circle in its
    // no-number building state for the reads' full duration
    // even when today's score was already sitting in the store.
    // This paint performs NO computeMissingScores run and
    // persists nothing.
    try {
      final all = await store.readAll();
      if (!mounted) return;
      paintFrom(all);
    } catch (_) {
      // The circle keeps its building state — never a fake number.
    }
    await startChain();
  }

  /// The background half of [_loadDailyScore]: the snapshot →
  /// compute → re-read chain exactly as this load always ran it,
  /// repainting through [paintFrom] when it lands.
  Future<void> _refreshDailyScoreChain({
    required HealthHistoryStore store,
    required String today,
    required void Function(Map<String, DailyBiometrics>) paintFrom,
  }) async {
    try {
      // SNAPSHOT-FIRST (founder amendment, Oct 20, 2026; TODAY
      // RULE in daily_score.dart): before computing anything,
      // await a Health Connect capture — the snapshot — so a new
      // score is never computed from stale store state when
      // fresher data is obtainable. The capture stays under its
      // normal rules (NON-forced, 6h throttle; only the score
      // refresh button forces one): when it is throttled or
      // skipped, this load scores from the store exactly as the
      // last completed capture left it. The capture's own
      // post-capture engine run is the only automatic run that
      // may score today, and only when today is complete.
      final snapshot = widget.dailyScoreSnapshotCapture ??
          HealthHistorySync.withDeps(store: store).capture;
      await snapshot(force: false);
      // Home's OWN compute run is still cut off BEFORE today — it
      // backfills past days (day-boundary fallback) but never
      // scores today itself.
      await DailyScoreEngine(store: store)
          .computeMissingScores(beforeDate: today);
      final all = await store.readAll();
      if (!mounted) return;
      paintFrom(all);
    } catch (_) {
      // The circle keeps whatever is painted (the stored score,
      // or its building state) — never a fake number.
    }
  }

  Future<void> _openDailyScore() async {
    await Navigator.of(context).push(
      SlidePageRoute(
        reducedMotion: animationsDisabled(context),
        builder: (_) => DailyScoreScreen(
          store: widget.healthHistoryStore,
          // Thread Home's snapshot capture through: in production
          // both default to the same real sync; in tests the
          // injected capture governs the pushed screen too, so a
          // screen pump never falls back to a real-channel capture
          // (whose reads legitimately pend — and, since the V-2
          // read bound, would leave the bound's timer pending at
          // teardown).
          snapshotCapture: widget.dailyScoreSnapshotCapture,
        ),
      ),
    );
    if (!mounted) return;
    unawaited(_loadDailyScore());
  }

  @override
  void initState() {
    super.initState();
    _healthRepo = widget.healthRepository ??
        HealthRepository(
          hc: widget.healthConnectService ?? HealthConnectService(),
        );
    // Round 16 — stale-while-revalidate: seed the numbers from the
    // cache so they render on the first frame (no "--" flash on tab
    // switches or cold start). The refresh below runs in the background
    // and swaps in silently when it differs.
    final cached = HomeDataCache.instance.snapshot;
    if (cached.vitalsLoaded) _vitals = cached.vitals;
    if (cached.streakLoaded) {
      _currentStreak = cached.currentStreak;
      _bestStreak = cached.bestStreak;
    }
    // Round 34 — cached counters seed the first frame the same way;
    // day counts recompute from the target dates at render time, so
    // a cached counter never shows a stale count.
    if (cached.countersLoaded) _counters = cached.counters;
    // Round 60 — launch milestone: Home's first frame is seeded
    // from the on-device snapshot (the paint-before-network proof
    // lives in launch_perf_r60_test.dart: this seed is synchronous
    // and the refresh below is entirely behind it).
    if (cached.vitalsLoaded || cached.streakLoaded || cached.countersLoaded) {
      LaunchTrace.instance.mark(LaunchTrace.homeSeededFromCache);
    }
    _resolveCountUpGate();
    _loadHealthData();
    _loadCheckInState();
    _outbox.addListener(_onCheckInOutboxChanged);
    _loadCounters();
    _loadDailyScore();
    // Round 60 — non-essentials defer until AFTER the first frame:
    // the widget publish and the weather fetch never compete with
    // first paint. Both were already fire-and-forget; they now also
    // START after the frame. (Round 59 discipline holds: the widget
    // push still goes through WidgetSync's serialized latest-wins
    // drain, and the refresh re-pushes through
    // HomeDataCache.persist() when it lands.)
    // Migraine details form (Juno §C): consume the controller's
    // one-shot pending-details signal — raised when a notification
    // tap ended the attack — exactly once, here on Home. Checked on
    // mount (cold-start launch tap) and on every controller change
    // (foreground/background tap while Home is alive).
    widget.migraineController?.addListener(_onMigraineChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _maybeShowMigraineDetails();
      // Round 50 — push the cached snapshot to the home-screen
      // widget, so the widget matches what the strip shows even
      // before the background refresh completes. Signed-in when
      // this Home is account-bound (session email or a cache owner)
      // or the cache actually holds a completed load; a completely
      // empty, unbound cache pushes the signed-out payload instead,
      // so a previous account's numbers never linger.
      unawaited(WidgetSync.pushSnapshot(
        cached,
        signedIn: widget.email != null ||
            cached.ownerEmail != null ||
            cached.vitalsLoaded ||
            cached.streakLoaded,
      ));
      _loadWeather();
    });
  }

  // ── Migraine details form (Juno §C) ─────────────────────────────
  bool _migraineFormShowing = false;

  void _onMigraineChanged() {
    if (!mounted) return;
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _maybeShowMigraineDetails());
  }

  /// Presents the details form for a tap-ended attack, consuming
  /// the one-shot signal so it can never be presented twice. The
  /// signal is in-memory only: process death discards it, and the
  /// form is never re-presented on later opens (Juno §F).
  void _maybeShowMigraineDetails() {
    final controller = widget.migraineController;
    if (controller == null || !mounted || _migraineFormShowing) return;
    if (!controller.hasPendingDetails) return;
    final attack = controller.consumePendingDetails();
    if (attack == null) return;
    _migraineFormShowing = true;
    showMigraineDetailsForm(context, controller: controller, attack: attack)
        .whenComplete(() => _migraineFormShowing = false);
  }

  @override
  void dispose() {
    widget.migraineController?.removeListener(_onMigraineChanged);
    _outbox.removeListener(_onCheckInOutboxChanged);
    super.dispose();
  }

  /// Round 34 — loads the ACTIVE event counters from the sync pull's
  /// profile — the exact source Settings round 29 reads and writes
  /// (`SettingsProfileData.eventCounters` →
  /// `TabsBackend.decodeProfileList`), never a second store. A failed
  /// pull keeps the cached counters (stale-while-revalidate); the
  /// completed load lands in the account-bound [HomeDataCache].
  Future<void> _loadCounters() async {
    try {
      final body = await _backend.fetchSyncPull();
      if (body == null) return;
      final data = SettingsProfileData.fromPull(body);
      final counters =
          data.eventCounters.map(EventCounterItem.fromMap).toList();
      final active = activeEventCounters(counters);
      final cache = HomeDataCache.instance;
      final changed = cache.applyCounters(active, ownerEmail: widget.email);
      unawaited(cache.persist());
      if (!mounted) return;
      if (changed) setState(() => _counters = active);
      // Counter-mutation durability (Oct 2026) — the delete
      // tombstones Settings records are applied on an isolated
      // post-pass (the same shared helpers, settings_profile.dart),
      // never awaited on this load path: the tombstone store is
      // secure storage, and a storage read must never block or
      // stall the counters render (the Round 51 lesson). The pass
      // filters a locally deleted id out of the just-loaded list,
      // prunes tombstones the server no longer carries, and
      // re-lands the filtered list in the cache + UI.
      unawaited(_filterCountersTombstones(
          allCounters: counters, activeCounters: active));
    } catch (_) {
      // Keep whatever the cache seeded — never invent counters.
    }
  }

  /// The [_loadCounters] tombstone post-pass. [allCounters] is the
  /// full pulled list (pruning judges against it — an archived
  /// tombstoned counter is not in the active list but still counts
  /// as carried by the server); [activeCounters] is what the load
  /// rendered. If a newer load has replaced the counters while this
  /// pass ran, the newer state wins and this pass does nothing.
  /// Best-effort throughout: any failure leaves the loaded list as
  /// it is.
  Future<void> _filterCountersTombstones({
    required List<EventCounterItem> allCounters,
    required List<EventCounterItem> activeCounters,
  }) async {
    try {
      final store = widget.settingsStore ?? SettingsStore();
      final tombstones =
          await store.getDeletedCounterIds(ownerEmail: widget.email);
      if (tombstones.isEmpty) return;
      final stillNeeded = pruneCounterTombstones(
          tombstones, allCounters.map((c) => c.id));
      if (stillNeeded.length != tombstones.length) {
        await store.setDeletedCounterIds(stillNeeded,
            ownerEmail: widget.email);
      }
      if (stillNeeded.isEmpty || !mounted) return;
      String idsOf(List<EventCounterItem> l) =>
          l.map((c) => c.id).join('|');
      if (idsOf(_counters) != idsOf(activeCounters)) return;
      final filtered =
          activeEventCounters(filterDeletedCounters(allCounters, stillNeeded));
      if (idsOf(filtered) == idsOf(activeCounters)) return;
      final cache = HomeDataCache.instance;
      cache.applyCounters(filtered, ownerEmail: widget.email);
      unawaited(cache.persist());
      if (!mounted) return;
      setState(() => _counters = filtered);
    } catch (_) {}
  }

  /// Round 34 — the counter slot's tap: pushes Settings opened
  /// directly on its Event Counters page, via the round-22 app-wide
  /// slide transition. On return the pull cache is invalidated and
  /// the counters re-read, so an archive / end-and-save / edit made
  /// there reflects on Home immediately.
  Future<void> _openEventCounters() async {
    await Navigator.of(context).push(
      SlidePageRoute(
        reducedMotion: animationsDisabled(context),
        builder: (_) => SettingsScreen(
          email: widget.email,
          onLogout: widget.onLogout,
          backend: _backend,
          settingsStore: widget.settingsStore,
          healthConnectService: widget.healthConnectService,
          billingService: widget.billingService,
          openEventCounters: true,
        ),
      ),
    );
    if (!mounted) return;
    _backend.invalidateSyncPull();
    unawaited(_loadCounters());
  }

  /// Merged check-in — resolves ALL of today's check-in state
  /// (ranking visibility, flare record, good record) from the REAL
  /// pulled entries overlaid with the outbox. Any failure leaves
  /// the number card hidden and no summary shown — the honest
  /// state, never a guess.
  Future<void> _loadCheckInState() async {
    try {
      // Kick the outbox disk load against the session account, so a
      // record staged by a killed session is part of the derivation
      // (and of the retry flush the derivation kicks).
      String? email;
      try {
        email = await _backend.readEmail();
      } catch (_) {
        email = null;
      }
      await _outbox.load(ownerEmail: email);
      final pull = await _backend.fetchSyncPull();
      if (pull == null) return;
      final entries = await _backend.fetchLogEntryDtos();
      final categories = await _backend.fetchLogCategories();
      if (!mounted) return;
      _feelingCategoryId = resolveFeelingCategoryId(categories);
      _flareCategoryId = resolveFlareCategoryId(categories);
      _deriveCheckInState(entries);
      // A plain setState so the number card / flare slot appear
      // even when the derivation itself changed no record (the
      // category resolving is itself a render change).
      if (mounted) setState(() {});
    } catch (_) {
      // Honest hidden state — nothing renders on a guess.
    }
  }

  /// Derives today's three records from [base] overlaid with the
  /// outbox's pending local entries (a pending record counts).
  void _deriveCheckInState(List<QuickLogEntry> base) {
    _mergedEntries = _outbox.merge(base);
    _deriveFromMerged();
  }

  /// Re-derives from the stored merged view and paints on change.
  /// When a derived record is still pending in the outbox — e.g.
  /// staged in a session the OS killed before its push — this also
  /// kicks the retry flush (the _deriveFlareState pattern, now for
  /// all three records): Home may be the first surface to see that
  /// record, and derivation is the one place every path passes
  /// through.
  void _deriveFromMerged() {
    final feelingId = _feelingCategoryId;
    final flareId = _flareCategoryId;
    final checkIn = feelingId == null
        ? null
        : findFeelingCheckInEntry(_mergedEntries, moodCategoryId: feelingId);
    final flare = flareId == null
        ? null
        : findFlareRecord(_mergedEntries, symptomsCategoryId: flareId);
    final good = feelingId == null
        ? null
        : findGoodRecord(_mergedEntries, moodCategoryId: feelingId);
    for (final record in [checkIn, flare, good]) {
      if (record != null && _outbox.isPending(record.id)) {
        unawaited(_outbox.flush(_backend));
        break;
      }
    }
    if (!mounted) return;
    final visible = feelingId != null && checkIn == null;
    bool changed(QuickLogEntry? a, QuickLogEntry? b) =>
        a?.id != b?.id || a?.chips != b?.chips || a?.body != b?.body;
    if (changed(checkIn, _checkInToday) ||
        changed(flare, _flareToday) ||
        changed(good, _goodToday) ||
        visible != _feelingVisible) {
      setState(() {
        _checkInToday = checkIn;
        _flareToday = flare;
        _goodToday = good;
        _feelingVisible = visible;
      });
    } else {
      // Keep the fields current even when no paint is needed (the
      // category ids may have resolved on this pass).
      _checkInToday = checkIn;
      _flareToday = flare;
      _goodToday = good;
      _feelingVisible = visible;
    }
  }

  /// The outbox changed: re-derive from the local merged view.
  void _onCheckInOutboxChanged() {
    if (!mounted) return;
    _deriveCheckInState(_mergedEntries);
  }

  /// Fresh-pull context for a commit: invalidates the pull,
  /// re-reads entries + categories when the pull succeeds, and
  /// returns the merged view commits must re-check against (the
  /// check-in's re-check precedent, mirrored from _commitFlare).
  /// A failed pull falls back to the local merged view — the
  /// outbox allocation + stage still guard the write, exactly as
  /// the shipped flare commit behaved on a null pull.
  Future<({List<QuickLogEntry> fresh, List<QuickLogEntry> merged, bool pullOk})>
      _freshCommitContext() async {
    _backend.invalidateSyncPull();
    final pull = await _backend.fetchSyncPull();
    if (pull == null) {
      return (fresh: _mergedEntries, merged: _mergedEntries, pullOk: false);
    }
    final entries = await _backend.fetchLogEntryDtos();
    final categories = await _backend.fetchLogCategories();
    final feelingId = resolveFeelingCategoryId(categories);
    if (feelingId != null) _feelingCategoryId = feelingId;
    final flareId = resolveFlareCategoryId(categories);
    if (flareId != null) _flareCategoryId = flareId;
    return (fresh: entries, merged: _outbox.merge(entries), pullOk: true);
  }

  /// Whether [entry]'s id is server-known for staging: the outbox
  /// already classifies it so, or a FRESH pull carried it (a merged
  /// local view alone proves nothing).
  bool _serverKnownFor(
    QuickLogEntry entry,
    ({List<QuickLogEntry> fresh, List<QuickLogEntry> merged, bool pullOk}) ctx,
  ) =>
      _outbox.isServerKnown(entry.id) ||
      (ctx.pullOk && ctx.fresh.any((e) => e.id == entry.id));

  /// Stages [entry] through the outbox and, only on a successful
  /// LOCAL stage, applies it instantly on screen and kicks the
  /// background flush (Juno Item 11 per-record gate). Returns the
  /// stage result.
  Future<bool> _stageAndApply(
    QuickLogEntry entry, {
    required bool serverKnown,
    required List<QuickLogEntry> fresh,
  }) async {
    final staged = await _outbox.stageForBackend(
      entry,
      backend: _backend,
      serverKnown: serverKnown,
    );
    if (!staged) return false;
    if (!mounted) return true;
    _mergedEntries = _outbox.merge([...fresh, entry]);
    _deriveFromMerged();
    unawaited(_outbox.flush(_backend));
    unawaited(_loadHealthData());
    return true;
  }

  Future<int> _allocateId(List<QuickLogEntry> merged) async {
    var serverMaxId = 0;
    for (final e in merged) {
      if (e.id > serverMaxId) serverMaxId = e.id;
    }
    return _outbox.allocateEntryIdForBackend(
      backend: _backend,
      serverMaxId: serverMaxId,
    );
  }

  // ── Ranking commit (the check-in write, on the outbox) ────────

  /// One tap logs the ranking through the shipped outbox —
  /// mirroring _commitFlare exactly: invalidate, fresh-pull
  /// re-check (hasFeelingCheckIn on merged entries), allocate,
  /// stage, instant apply, unawaited flush. The old await-first
  /// postLogEntries path is gone. Returns today's check-in entry
  /// (newly staged or pre-existing), or null when the local stage
  /// failed — in which case nothing about the logged state changes
  /// and no follow-up sheet opens.
  Future<({QuickLogEntry entry, bool created})?> _commitRanking(
      int level) async {
    final categoryId = _feelingCategoryId;
    if (categoryId == null) return null;
    final ctx = await _freshCommitContext();
    final resolvedId = _feelingCategoryId ?? categoryId;
    if (hasFeelingCheckIn(ctx.merged, moodCategoryId: resolvedId)) {
      _deriveCheckInState(ctx.fresh);
      final existing = findFeelingCheckInEntry(ctx.merged,
          moodCategoryId: resolvedId);
      return existing == null ? null : (entry: existing, created: false);
    }
    final id = await _allocateId(ctx.merged);
    final entry = buildFeelingEntry(
      level: level,
      categoryId: resolvedId,
      existing: ctx.merged,
      id: id,
    );
    final ok = await _stageAndApply(entry,
        serverKnown: false, fresh: ctx.fresh);
    return ok ? (entry: entry, created: true) : null;
  }

  /// The number tap: the single entry point of the merged flow.
  /// The ranking stages first; only after ITS local stage succeeds
  /// do the number's follow-ups run (1–2 flare, 4–5 good sheet, 3
  /// nothing further).
  Future<void> _onFeelingSelect(int level) async {
    if (level < 1 || level > 5 || _feelingTapInFlight) return;
    _feelingTapInFlight = true;
    try {
      final result = await _commitRanking(level);
      if (result == null || !mounted) return;
      // A pre-existing check-in (double-tap / logged elsewhere)
      // opens no follow-ups — its own flow already ran.
      if (!result.created) return;
      if (level <= 2) {
        await _runLowFollowUp(level);
      } else if (level >= 4) {
        await showCheckInGoodSheet(
          context: context,
          onCommit: _commitGood,
        );
        if (mounted) _deriveCheckInState(_mergedEntries);
      }
    } catch (_) {
      // The card/summary keep their derived state; a failed stage
      // changed no logged state.
    } finally {
      _feelingTapInFlight = false;
    }
  }

  /// The 1–2 follow-up: stage the severity-only flare record
  /// IMMEDIATELY (only when no flare record exists for the day — an
  /// existing one is left untouched), then open the kind sheet.
  /// A kind tap upserts the flare; `Just log this` and dismissal
  /// leave the severity-only record (dismissal = commit path,
  /// Juno Item 4). When the immediate stage failed, the summary
  /// keeps showing the ranking alone and a kind pick retries the
  /// creation as an upsert.
  Future<void> _runLowFollowUp(int level) async {
    final severity = severityForRanking(level);
    if (severity == null) return;
    final preExisting = _flareToday;
    var stagedOk = preExisting != null;
    if (preExisting == null) {
      stagedOk = await _commitFlare(severity: severity, type: null);
    }
    if (!mounted) return;
    final effectiveSeverity =
        preExisting != null ? (flareSeverityOf(preExisting) ?? severity) : severity;
    await showCheckInKindSheet(
      context: context,
      onKind: (kind) => _commitFlare(
        severity: effectiveSeverity,
        type: kind,
      ),
      onJustLog: () async {
        // The severity-only record is the commit: already staged
        // (nothing to do), a pre-existing record stays untouched,
        // and a failed immediate stage retries here as an upsert.
        if (preExisting != null || stagedOk) return true;
        return _commitFlare(severity: severity, type: null);
      },
    );
    if (mounted) _deriveCheckInState(_mergedEntries);
  }

  // ── Flare commit (outbox upsert) ────────────────────────────────

  /// One flare record per energy day, amended in place. Returns
  /// true only when the LOCAL stage succeeded (Juno Item 11).
  Future<bool> _commitFlare({required String severity, String? type}) async {
    if (_flareCommitInFlight) return false;
    final categoryId = _flareCategoryId;
    if (categoryId == null) return false;
    _flareCommitInFlight = true;
    try {
      final ctx = await _freshCommitContext();
      final resolvedId = _flareCategoryId ?? categoryId;
      final existing =
          findFlareRecord(ctx.merged, symptomsCategoryId: resolvedId);
      final QuickLogEntry entry;
      final bool serverKnown;
      if (existing != null) {
        entry = amendFlareEntry(existing, severity: severity, type: type);
        serverKnown = _serverKnownFor(existing, ctx);
      } else {
        final id = await _allocateId(ctx.merged);
        entry = buildFlareEntry(
          id: id,
          categoryId: resolvedId,
          severity: severity,
          type: type,
        );
        serverKnown = false;
      }
      final ok = await _stageAndApply(entry,
          serverKnown: serverKnown, fresh: ctx.fresh);
      if (ok && mounted) {
        setState(() => _checkInAnnouncement =
            flareLoggedAnnouncement(severity, type: type));
      }
      return ok;
    } catch (_) {
      return false;
    } finally {
      _flareCommitInFlight = false;
    }
  }

  // ── Good-day commit (outbox upsert) ─────────────────────────────

  /// One good-day record per energy day, amended in place, in the
  /// check-in's Mood & Energy category. Returns true only when the
  /// LOCAL stage succeeded (Juno Item 11).
  Future<bool> _commitGood(List<String> options) async {
    if (_goodCommitInFlight) return false;
    if (options.isEmpty) return false;
    final categoryId = _feelingCategoryId;
    if (categoryId == null) return false;
    _goodCommitInFlight = true;
    try {
      final ctx = await _freshCommitContext();
      final resolvedId = _feelingCategoryId ?? categoryId;
      final existing =
          findGoodRecord(ctx.merged, moodCategoryId: resolvedId);
      final ordered = goodOptionsInSheetOrder(options);
      final QuickLogEntry entry;
      final bool serverKnown;
      if (existing != null) {
        entry = amendGoodEntry(existing, options: ordered);
        serverKnown = _serverKnownFor(existing, ctx);
      } else {
        final id = await _allocateId(ctx.merged);
        entry = buildGoodEntry(
          id: id,
          categoryId: resolvedId,
          options: ordered,
        );
        serverKnown = false;
      }
      final ok = await _stageAndApply(entry,
          serverKnown: serverKnown, fresh: ctx.fresh);
      if (ok && mounted) {
        setState(() => _checkInAnnouncement = goodBody(ordered));
      }
      return ok;
    } catch (_) {
      return false;
    } finally {
      _goodCommitInFlight = false;
    }
  }

  // ── Summary + amend ─────────────────────────────────────────────

  int? get _todayRanking =>
      _checkInToday == null ? null : feelingRankingOf(_checkInToday!);

  /// Item 7 origin rule: ranking 1–2 + flare ⇒ number-origin;
  /// ranking 3–5 + flare ⇒ late-added.
  SummaryFlareOrigin get _summaryFlareOrigin {
    final ranking = _todayRanking;
    if (_flareToday == null || ranking == null) {
      return SummaryFlareOrigin.none;
    }
    return ranking <= 2
        ? SummaryFlareOrigin.numberOrigin
        : SummaryFlareOrigin.lateAdded;
  }

  /// Tapping the summary card opens the amend sheet, with its
  /// sections derived from today's state (Item 9).
  Future<void> _onSummaryTap() async {
    final ranking = _todayRanking;
    if (ranking == null) return;
    final flare = _flareToday;
    final flareSeverity = flare == null ? null : flareSeverityOf(flare);
    final flareKind =
        flare == null ? null : flareTypesOf(flare).firstOrNull;
    final showKind = flare != null || ranking <= 2;
    final showFlareAdd = flare == null && ranking >= 3;
    final showGood = ranking >= 4 || _goodToday != null;
    await showCheckInAmendSheet(
      context: context,
      showKindSection: showKind,
      currentKind: flareKind,
      onKind: (kind) => _commitFlare(
        severity: flareSeverity ?? severityForRanking(ranking) ?? 'Rough',
        type: kind,
      ),
      showFlareAddSection: showFlareAdd,
      onFlareAdd: _commitFlare,
      showGoodSection: showGood,
      initialGood:
          _goodToday == null ? const [] : goodOptionsOf(_goodToday!),
      onGood: _commitGood,
    );
    if (!mounted) return;
    _deriveCheckInState(_mergedEntries);
  }

  /// Round 15c — resolves the once-per-day count-up gate from secure
  /// storage. The gate persists today's date BEFORE reporting true, so
  /// a rebuild mid-animation can never re-trigger it. Local read, so
  /// it resolves long before the health data arrives.
  Future<void> _resolveCountUpGate() async {
    const storage = FlutterSecureStorage();
    final animate = await CountUpGate.shouldAnimate(
      read: (key) => storage.read(key: key),
      write: (key, value) => storage.write(key: key, value: value),
    );
    if (!mounted) return;
    setState(() => _countUpsAnimate = animate);
  }

  /// Loads today's vitals + streaks once per mount. Everything is
  /// honest-empty on failure: the repository never throws, and any
  /// individual piece simply stays null/"--".
  ///
  /// Round 16 — stale-while-revalidate: the completed load is written
  /// into [HomeDataCache] (memory + disk) and the UI only rebuilds when
  /// the fresh data actually differs from what was seeded. A failed
  /// refresh keeps the old cache — the numbers never flash empty.
  /// Background updates never animate: the once-per-day count-up gate
  /// (round 15c) already fired for this view, so CountUp renders
  /// instantly.
  Future<void> _loadHealthData() async {
    // Round 60 — the streak load (a backend sync pull) is
    // INDEPENDENT of the Health Connect status/vitals chain, so its
    // future starts FIRST and runs concurrently with them. At base
    // it ran strictly after the vitals load completed — and because
    // this method set state only once at the end, the already-landed
    // vitals were held hostage behind the streak's second pull
    // (measured: fresh values at ~2× the pull latency; now ~1×).
    // The pull itself is single-flight app-wide (TabsBackend), so
    // this future, the counters load, the feeling load, and the
    // vitals log-count all share ONE network request.
    final streakFuture = _healthRepo.loadStreak();
    final hc = _healthRepo.hc;
    // Round 23 — track the full status enum, not just connected/not.
    // A bridge failure is handled visibly, never silently wedged
    // (LESSONS.md): the status falls back to notConnected so the
    // banner shows, and the exception code rides along for it.
    HealthConnectStatus status;
    String? statusErrorCode;
    try {
      status = await hc.getStatus();
    } on HealthConnectException catch (e) {
      status = HealthConnectStatus.notConnected;
      statusErrorCode = e.code;
    } catch (_) {
      status = HealthConnectStatus.notConnected;
      statusErrorCode = 'UNKNOWN';
    }
    final connected = status == HealthConnectStatus.connected;
    final vitals = await _healthRepo.loadTodayVitals(connected: connected);
    final streak = await streakFuture;
    final cache = HomeDataCache.instance;
    final changed = cache.applyVitals(vitals) |
        cache.applyStreak(streak.current, streak.best);
    // Persist in the background; never block the UI on storage.
    unawaited(cache.persist());
    // Round 60 — launch milestone: the background refresh has landed
    // (this fires on every Home load, but LaunchTrace keeps the
    // first mark only — the cold-start one).
    LaunchTrace.instance.mark(LaunchTrace.homeFreshData);
    if (!mounted) return;
    // Round 23 — a status-only change (e.g. the fresh load found the
    // same empty vitals the cache already held, but now we KNOW the
    // connection state) must also rebuild, or the banner never lands.
    final statusChanged =
        status != _hcStatus || statusErrorCode != _hcStatusErrorCode;
    if (changed || statusChanged) {
      setState(() {
        _vitals = vitals;
        _currentStreak = streak.current;
        _bestStreak = streak.best;
        _hcStatus = status;
        _hcStatusErrorCode = statusErrorCode;
      });
    }
    // R70 fix pass (Vera F2) — a completed health-data load re-runs
    // the Daily Score read: the load's fire-and-forget history
    // capture (HealthRepository._triggerHistoryCapture) lands
    // during/after this load, and its post-capture engine run is
    // what scores today — the circle must pick that score up
    // instead of staying frozen at whatever the initState race
    // read. Every refresh path that calls _loadHealthData (the
    // feeling check-in, the connections return) inherits this.
    unawaited(_loadDailyScore());
  }

  /// Opens the data-connections screen — the one destination/flow
  /// shared by the header watch icon and the round-23 Health Connect
  /// banner. On return, Home quietly re-checks the status + vitals in
  /// the background (stale-while-revalidate, no spinner), so a
  /// reconnect or permission fix made there clears the banner
  /// without a tab switch.
  Future<void> _openConnections() async {
    await Navigator.of(context).push(
      SlidePageRoute(
        reducedMotion: animationsDisabled(context),
        builder: (_) => ConnectionsScreen(
          healthConnectService: widget.healthConnectService,
        ),
      ),
    );
    if (!mounted) return;
    unawaited(_loadHealthData());
  }

  Future<void> _loadWeather() async {
    final reading =
        await (widget.weatherApi ?? WeatherApiClient())
            .getCurrentWeatherCondition();
    if (!mounted) return;
    setState(() {
      _temp = reading.temp;
      _countryCode = reading.countryCode;
      _weatherCode = reading.weatherCode;
      _isDay = reading.isDay;
      // Loaded only when we have a real reading — a null temp means
      // "unavailable", and the header shows the icon alone.
      _weatherLoaded = reading.temp != null;
    });
  }

  /// MF-1 (Juno compliance, Oct 2026): the weather tap NEVER requests
  /// location permission — it only *checks* the current status.
  /// - Already granted → fetch the GPS position silently (no system
  ///   dialog can appear) and share it with the sheet; the header temp
  ///   upgrades in the background.
  /// - Not granted → the sheet opens with the in-app rationale card, and
  ///   only the card's "Share location" button may trigger the system
  ///   dialog. A grant there upgrades the header temp via
  ///   [showWeatherSheet]'s onLocationGranted.
  /// Any denial, disabled services, timeout, or error falls back SILENTLY
  /// to the IP-based fetch — the user never sees an error and the header
  /// never shows a fake reading. (Play prominent-disclosure rule: the
  /// in-app rationale must precede the system dialog.)
  ///
  /// Privacy: the position is used ONLY to build the Open-Meteo
  /// request below. It is never logged, stored, or sent anywhere
  /// except api.open-meteo.com (HTTPS).
  Future<void> _onWeatherTap() async {
    final location = widget.locationService ?? LocationService();
    Future<Position?>? gpsFuture;
    try {
      final permission = await location.checkPermission();
      if (permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always) {
        gpsFuture = location.getPosition();
        // Upgrade the header temp in the background; any failure keeps
        // the IP-based reading silently.
        gpsFuture.then((position) {
          if (position != null && mounted) _upgradeHeaderCondition(position);
        });
      }
    } catch (_) {
      gpsFuture = null;
    }
    if (!mounted) return;
    await showWeatherSheet(
      context: context,
      weatherApi: widget.weatherApi ?? WeatherApiClient(),
      locationService: location,
      gpsPositionFuture: gpsFuture,
      onLocationGranted: (position) {
        if (mounted) _upgradeHeaderCondition(position);
      },
    );
  }

  /// Fetches the current conditions at [position] and upgrades the
  /// header (temp + living icon). Silent on any failure — the IP-based
  /// reading stays.
  Future<void> _upgradeHeaderCondition(Position position) async {
    try {
      final condition = await (widget.weatherApi ?? WeatherApiClient())
          .getConditionAt(
        latitude: position.latitude,
        longitude: position.longitude,
        countryCode: _countryCode,
      );
      if (!mounted) return;
      setState(() {
        _temp = condition.temp;
        _weatherCode = condition.weatherCode;
        _isDay = condition.isDay;
        _weatherLoaded = condition.temp != null;
      });
    } catch (_) {
      // Keep the IP-based reading.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: const Text(
          'Today',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w900,
            color: NotelColors.textPrimary,
          ),
        ),
        actions: [
          // R70 Daily Score — the score circle sits BESIDE the
          // weather icon (founder spec). Null score = the
          // baseline-building state, or the pending state while
          // today waits for its data to complete. Tap opens the
          // score history.
          DailyScoreCircle(
            score: _todayScore,
            pending: _todayScorePending,
            onTap: () => unawaited(_openDailyScore()),
          ),
          // Weather: tap asks for device location (system dialog) and
          // upgrades the IP-based temp to GPS-based weather. Denial
          // falls back silently to the IP fetch.
          SizedBox(
            width: 64,
            child: IconButton(
              onPressed: _onWeatherTap,
              // Audit 6d (Oct 27, 2026) — house label.
              tooltip: 'Weather',
              padding: EdgeInsets.zero,
              icon: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_weatherLoaded)
                      Text(
                        '${_temp!}°',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color:
                              NotelColors.textPrimary.withValues(alpha: 0.8),
                        ),
                      ),
                    if (_weatherLoaded) const SizedBox(width: 4),
                    // Round 14 — the condition icon is alive: rotating sun
                    // rays, falling rain, drifting clouds, twinkling stars.
                    // Before any condition loads it renders a static cloud
                    // (the old icon's "no data yet" role).
                    AnimatedWeatherIcon(
                      weatherCode: _weatherCode,
                      isDay: _isDay,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Watch: opens the data-connections screen (native
          // onNavigateToConnections). Round 12b: explicit slide-in-from-right —
          // Material 3's default Android transition is a zoom/fade that reads
          // as "just spawning in". Round 14: the icon is a shared element —
          // it flies to the connections screen's back arrow during the push
          // (skipped under reduced motion, where heroes are omitted).
          IconButton(
            onPressed: () => unawaited(_openConnections()),
            icon: animationsDisabled(context)
                ? const Icon(
                    Icons.watch,
                    size: 24,
                    color: NotelColors.primary,
                  )
                : const Hero(
                    tag: watchConnectionsHeroTag,
                    child: Icon(
                      Icons.watch,
                      size: 24,
                      color: NotelColors.primary,
                    ),
                  ),
            tooltip: 'Connections',
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Round 14 — staggered entrance: the cards cascade in with a
            // fade + slight rise, ~80ms apart. Purely visual; data loads
            // independently underneath.
            // Round 21 — the feeling check-in is native's item 0: the
            // first thing on Home, above the vitals strip. It renders
            // nothing until the pulled entries prove no check-in
            // exists for the current energy day. It is NOT wrapped in
            // StaggeredEntrance: native gives the card its own
            // slide-in-from-left entrance (400ms), and the existing
            // cards keep their original stagger indices 0–3.
            if (_feelingVisible)
              FeelingCheckInCard(
                onSelect: _onFeelingSelect,
              ),
            // Merged check-in flow — once a ranking is logged, ONE
            // summary card (Juno Item 7) replaces both the number
            // card and the removed standalone flare button, in the
            // same slot. Its composition derives from today's three
            // records; tapping it opens the amend sheet. It is NOT
            // premium-gated (logging is free-forever).
            if (_checkInToday != null && _todayRanking != null)
              CheckInSummaryCard(
                label: checkInSummaryLabel(
                  ranking: _todayRanking!,
                  flareSeverity: _flareToday == null
                      ? null
                      : flareSeverityOf(_flareToday!),
                  flareKind: _flareToday == null
                      ? null
                      : flareTypesOf(_flareToday!).firstOrNull,
                  flareOrigin: _summaryFlareOrigin,
                  goodOptions: _goodToday == null
                      ? const []
                      : goodOptionsOf(_goodToday!),
                ),
                semanticsLabel: checkInSummarySemantics(
                  ranking: _todayRanking!,
                  flareSeverity: _flareToday == null
                      ? null
                      : flareSeverityOf(_flareToday!),
                  flareKind: _flareToday == null
                      ? null
                      : flareTypesOf(_flareToday!).firstOrNull,
                  flareOrigin: _summaryFlareOrigin,
                  goodOptions: _goodToday == null
                      ? const []
                      : goodOptionsOf(_goodToday!),
                ),
                announcement: _checkInAnnouncement,
                onTap: () => unawaited(_onSummaryTap()),
              ),
            StaggeredEntrance(
              index: 0,
              child: VitalsStrip(
                vitals: _vitals,
                animateCountUps: _countUpsAnimate,
              ),
            ),
            // Round 23 — slim Health Connect banner, directly under
            // the vitals strip: only when the status is known to be
            // not fully connected AND the biometrics are empty. It is
            // deliberately NOT wrapped in StaggeredEntrance (no extra
            // motion, no spinner) — it appears/disappears quietly when
            // the background refresh lands, and cached values above it
            // keep rendering first either way.
            if (shouldShowHealthConnectBanner(
                status: _hcStatus, vitals: _vitals))
              HealthConnectBanner(
                status: _hcStatus!,
                errorCode: _hcStatusErrorCode,
                onTap: () => unawaited(_openConnections()),
              ),
            StaggeredEntrance(
              index: 1,
              child: HomeStreakRow(
                currentStreak: _currentStreak,
                bestStreak: _bestStreak,
                animateCountUps: _countUpsAnimate,
                counters: _counters,
                onCountersTap: () => unawaited(_openEventCounters()),
              ),
            ),
            StaggeredEntrance(
              index: 2,
              child: TodaySummaryCard(
                migraineController: widget.migraineController,
              ),
            ),
            StaggeredEntrance(
              index: 3,
              child: WeeklySnapshotCard(
                loadData: (metric) => _healthRepo.loadSnapshot(metric),
              ),
            ),
            // Clearance so the last content never hides behind the
            // floating nav dock (dock ≈ 56dp + 12dp + nav inset).
            const SizedBox(height: 110),
          ],
        ),
      ),
    );
  }
}
