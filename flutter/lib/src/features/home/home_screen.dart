import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/location_service.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/data/widget_sync.dart';
import 'package:tabs_lab/src/features/connections/connections_screen.dart';
import 'package:tabs_lab/src/features/home/feeling_checkin_card.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';
import 'package:tabs_lab/src/features/home/health_connect_banner.dart';
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

  /// Round 34 — forwarded to the Settings screen pushed from the
  /// counter slot, so a logout started there still exits to the
  /// welcome flow (the shell owns that callback).
  final VoidCallback? onLogout;

  const HomeScreen(
      {super.key,
      this.email,
      this.weatherApi,
      this.locationService,
      this.healthConnectService,
      this.healthRepository,
      this.tabsBackend,
      this.onLogout});

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
  bool _feelingLeaving = false;

  /// Double-tap guard (native `tapInFlight`): one tap, one entry.
  bool _feelingTapInFlight = false;
  int? _feelingCategoryId;

  // ── Round 34: event counters ─────────────────────────────────────
  /// Active counters in Settings list order. Empty until the cache or
  /// the first pull proves otherwise — the slot renders nothing while
  /// empty (honest state, no placeholder).
  List<EventCounterItem> _counters = const [];

  TabsBackend get _backend => widget.tabsBackend ?? _healthRepo.backend;

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
    // Round 50 — push the cached snapshot to the home-screen widget
    // on load, so the widget matches what the strip shows even
    // before the background refresh completes. Signed-in when this
    // Home is account-bound (session email or a cache owner) or the
    // cache actually holds a completed load; a completely empty,
    // unbound cache pushes the signed-out payload instead, so a
    // previous account's numbers never linger. The refresh below
    // re-pushes through HomeDataCache.persist() when it lands.
    unawaited(WidgetSync.pushSnapshot(
      cached,
      signedIn: widget.email != null ||
          cached.ownerEmail != null ||
          cached.vitalsLoaded ||
          cached.streakLoaded,
    ));
    _resolveCountUpGate();
    _loadWeather();
    _loadHealthData();
    _loadFeelingState();
    _loadCounters();
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
      final active = activeEventCounters(
          data.eventCounters.map(EventCounterItem.fromMap));
      final cache = HomeDataCache.instance;
      final changed = cache.applyCounters(active, ownerEmail: widget.email);
      unawaited(cache.persist());
      if (!mounted) return;
      if (changed) setState(() => _counters = active);
    } catch (_) {
      // Keep whatever the cache seeded — never invent counters.
    }
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
          healthConnectService: widget.healthConnectService,
          openEventCounters: true,
        ),
      ),
    );
    if (!mounted) return;
    _backend.invalidateSyncPull();
    unawaited(_loadCounters());
  }

  /// Round 21 — resolves check-in visibility from the REAL pulled
  /// entries (never invented): the card shows only when the pull
  /// succeeded, the Mood & Energy category resolved, and no
  /// 'Daily Ranking' entry exists in that category for the current
  /// energy day. Any failure leaves the card hidden.
  Future<void> _loadFeelingState() async {
    try {
      final pull = await _backend.fetchSyncPull();
      if (pull == null) return;
      final entries = await _backend.fetchLogEntryDtos();
      final categories = await _backend.fetchLogCategories();
      final categoryId = resolveFeelingCategoryId(categories);
      if (categoryId == null || !mounted) return;
      _feelingCategoryId = categoryId;
      final visible = !hasFeelingCheckIn(entries, moodCategoryId: categoryId);
      if (visible != _feelingVisible) {
        setState(() => _feelingVisible = visible);
      }
    } catch (_) {
      // Honest hidden state — native starts (and stays) hidden until
      // its entry flow proves the card should show.
    }
  }

  /// Round 21 — one tap logs the rating (native `selectLevel`).
  /// Re-pulls fresh before writing so the new id is
  /// max(existing ids) + 1 against current server state (the sync
  /// endpoint upserts on (user_id, local_id) — a colliding id would
  /// silently overwrite another entry) and so an entry logged
  /// elsewhere since this screen loaded is never duplicated.
  /// On success the card slides away and Home's counts refresh
  /// quietly in the background (no spinner, no count-up replay).
  /// On failure the card simply stays, exactly like native (its
  /// insert catch only resets the tap guard).
  Future<void> _onFeelingSelect(int level) async {
    if (level < 1 || level > 5 || _feelingTapInFlight) return;
    _feelingTapInFlight = true;
    try {
      _backend.invalidateSyncPull();
      // Vera round-21 gate: the write MUST NOT proceed on a failed
      // re-pull. fetchLogEntryDtos swallows failures into an empty
      // list, which would compute id = 1 and the upsert could
      // overwrite the real entry 1. A null pull aborts the tap —
      // the card stays and the user can tap again.
      final pull = await _backend.fetchSyncPull();
      if (pull == null) return;
      final entries = await _backend.fetchLogEntryDtos();
      final categories = await _backend.fetchLogCategories();
      final categoryId =
          resolveFeelingCategoryId(categories) ?? _feelingCategoryId;
      if (categoryId == null) return;
      _feelingCategoryId = categoryId;
      if (!mounted) return;
      if (hasFeelingCheckIn(entries, moodCategoryId: categoryId)) {
        // Already logged for this energy day — no second entry; the
        // card just goes away, as native's flow would hide it.
        setState(() => _feelingVisible = false);
        return;
      }
      final entry = buildFeelingEntry(
        level: level,
        categoryId: categoryId,
        existing: entries,
      );
      final ok = await _backend.postLogEntries([entry]);
      if (!ok || !mounted) return;
      _backend.invalidateSyncPull();
      setState(() => _feelingLeaving = true);
      // Quiet background refresh: today's log count / streak pick up
      // the new entry with no spinner and no count-up replay (the
      // once-per-day gate already fired for this view).
      unawaited(_loadHealthData());
    } catch (_) {
      // Card stays visible; the user can tap again.
    } finally {
      _feelingTapInFlight = false;
    }
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
    final streak = await _healthRepo.loadStreak();
    final cache = HomeDataCache.instance;
    final changed = cache.applyVitals(vitals) |
        cache.applyStreak(streak.current, streak.best);
    // Persist in the background; never block the UI on storage.
    unawaited(cache.persist());
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
          // Weather: tap asks for device location (system dialog) and
          // upgrades the IP-based temp to GPS-based weather. Denial
          // falls back silently to the IP fetch.
          SizedBox(
            width: 64,
            child: IconButton(
              onPressed: _onWeatherTap,
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
                leaving: _feelingLeaving,
                onExitComplete: () {
                  if (!mounted) return;
                  setState(() {
                    _feelingVisible = false;
                    _feelingLeaving = false;
                  });
                },
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
            const StaggeredEntrance(
              index: 2,
              child: TodaySummaryCard(),
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
