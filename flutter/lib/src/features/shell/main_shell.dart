import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/billing_service.dart';
import 'package:tabs_lab/src/data/daily_summary_open_signal.dart';
import 'package:tabs_lab/src/data/revenuecat_service.dart';
import 'package:tabs_lab/src/data/midnight_grace.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/migraine_controller.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/location_service.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/heart/heart_screen.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/quicklog/quick_log_screen.dart';
import 'package:tabs_lab/src/features/shell/heart_sleep_mode.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';
import 'package:tabs_lab/src/features/shell/nav_dock_glass_light.dart';
import 'package:tabs_lab/src/features/shell/nav_dock_solid.dart';
import 'package:tabs_lab/src/features/tools/sleep_screen.dart';
import 'package:tabs_lab/src/features/tools/tools_screen.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/app_background.dart';

/// Round 9 — the post-login shell: tab state, the bottom nav dock, and
/// placeholder screens.
///
/// - Home tab → the real home screen we've been building (Today header,
///   vitals strip, summary, weekly snapshot).
/// - Tools → the tools grid (round 17, UI only — cards open blank
///   placeholders for now).
/// - Quick-log → the real Quick Log screen (round 19): details field,
///   real categories, AI suggestions, history view.
/// - Heart → the real Heart screen (round 25): native FitbitScreen
///   port (summary, today's pattern chart, spikes, spike review).
/// - Settings is NOT a dock tab anymore (settings-gear round,
///   Lab): it opens from the Home header gear as a bottom tray
///   hosting the real Settings screen (round 29's port, unchanged),
///   and stays reachable as a push from Home's counter slot and
///   from Research. The shell no longer builds a Settings tab.
/// - The dock stays visible on every tab. The active icon highlights in
///   `NotelPrimary`, matching the native dock's selected state.
/// - The dock is NOT shown on splash / welcome / login — same as native
///   (those stages never reach this shell).
///
/// Round 40 — direction-aware dock tab transitions. Tab-state audit
/// first: this shell has NEVER preserved per-tab state — the body was
/// a plain `switch (_tab)` mounting only the selected screen, so
/// leaving a tab disposed its State and returning remounted it fresh
/// (round-35 tests pin exactly that: "Home remounts on tab switch").
/// There is no IndexedStack, no per-tab Navigator, no keep-alive.
/// This round preserves that behavior exactly: at rest only the
/// settled tab is mounted; during a switch the outgoing tab stays
/// mounted in its own slot only until the 300ms slide completes, then
/// it is removed and disposed precisely as the old instant swap did.
///
/// The slide is a paired two-slot arrangement:
/// - Two keyed slots ping-pong. A screen is born in a slot, slides in
///   in that slot, later slides out in the SAME slot, then is dropped.
///   Screens never change slots mid-life, so neither screen's State is
///   ever recreated by the transition machinery itself.
/// - Direction is pure index comparison (DockTab order IS the spec
///   order 0 Home, 1 Tools, 2 Quick Log, 3 Heart):
///   target index > current → incoming enters from the right and the
///   outgoing exits left; target < current → mirror image. Both use
///   the same eased progress, so the two screens tile exactly (their
///   offsets always sum to one full width) — one direction of travel,
///   no fade, no overlap, no ghosting (Round 22 opacity rules: both
///   screens stay fully opaque).
/// - 300ms + Curves.easeOut, matching Round 22's SlidePageRoute feel.
/// - Same-tab tap is a no-op (no transition), as before.
/// - Rapid taps never queue: a tap mid-slide disposes the stale
///   outgoing screen immediately, the currently-entering screen
///   becomes the new outgoing FROM ITS CAPTURED mid-slide offset (no
///   positional snap), and the new target enters the freed slot.
/// - Reduced motion (`animationsDisabled`): instant swap, as before —
///   no controller run, no second screen mounted.
/// - The dock is untouched: `_tab` (its `selected:` source) updates in
///   the same setState that starts the slide, so the Round 19c pill
///   spring and the quick-log ring stay in sync on multi-tab jumps.
class MainShell extends StatefulWidget {
  final String? email;
  final WeatherApiClient? weatherApi;

  /// Injectable for tests; defaults to the real geolocator wrapper.
  final LocationService? locationService;

  /// Injectable for tests; defaults to a real HealthConnectService.
  final HealthConnectService? healthConnectService;

  /// Round 29 — called by Settings after a completed logout or
  /// account deletion (session + caches already cleared) so the app
  /// returns to the welcome flow.
  final VoidCallback? onLogout;

  /// Injectable for tests (Round 30 nav-labels preference source).
  final SettingsStore? settingsStore;

  /// Injectable for tests (Heart/Sleep toggle, Nov 23, 2026): the
  /// persisted heart-slot mode source.
  final HeartSleepModeStore? heartSleepModeStore;

  /// The app-owned billing service (single instance), forwarded
  /// to Settings (pushed / tray routes via Home/Tools) — consumed
  /// there, never constructed or disposed by the shell or screens.
  final BillingService? billingService;

  /// The app-owned RevenueCat service (single instance, iOS),
  /// forwarded beside [billingService] along the same routes to
  /// Settings — consumed there, never constructed or disposed by
  /// the shell or screens.
  final RevenueCatService? revenueCatService;

  /// The shared app-level migraine controller (app wiring in
  /// main.dart), forwarded to Home.
  final MigraineController? migraineController;

  /// Midnight Grace (Nov 21, 2026) — injectable for tests; when
  /// null the shell creates, starts, and owns one. The controller
  /// lives at shell level (above Home) so the midnight crossing is
  /// detected wherever the user is in the app; Home consumes it.
  final MidnightGraceController? graceController;

  const MainShell(
      {super.key,
      this.email,
      this.weatherApi,
      this.locationService,
      this.healthConnectService,
      this.onLogout,
      this.settingsStore,
      this.heartSleepModeStore,
      this.billingService,
      this.revenueCatService,
      this.graceController,
      this.migraineController});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell>
    with SingleTickerProviderStateMixin {
  // Round 19c audit: this single field is the ONLY source of truth
  // for both the body switch below and the dock's `selected:` — they
  // cannot disagree. (The founder-reported wrong highlight lived one
  // level down, in NavDock's pill controller bounds; see nav_dock.dart.)
  DockTab _tab = DockTab.home;

  // Heart/Sleep toggle (founder, Nov 23, 2026) — the mode of the
  // DockTab.heart slot: heart (the Heart screen) or sleep (the Sleep
  // screen, moved out of Tools). This field is the single source of
  // truth: _screenFor renders the slot's screen from it and the dock
  // renders the heart cell's glyph from it, so they cannot disagree.
  // It starts at heart (the default) and the persisted value lands
  // a frame later, exactly like the nav-labels preference above.
  HeartSleepMode _heartSleepMode = HeartSleepMode.heart;
  late final HeartSleepModeStore _heartSleepModeStore;

  // Round 40 — the two slide slots. `_slots[i]` is the tab whose
  // screen currently lives in slot i (null = empty). At rest exactly
  // one slot is occupied, by `_tab`, in `_settledSlot`. During a slide
  // `_fromSlot` holds the outgoing tab and `_toSlot` the incoming one;
  // on completion the outgoing slot is emptied (its State disposed —
  // the pre-Round-40 destroy-on-switch semantics) and `_toSlot`
  // becomes `_settledSlot`.
  final List<DockTab?> _slots = [DockTab.home, null];
  int _settledSlot = 0;
  int _fromSlot = 0;
  int _toSlot = 0;
  bool _sliding = false;

  // Slide geometry for the in-flight transition. The incoming screen
  // always travels `_inBegin → Offset.zero`; the outgoing travels
  // `_outBegin → _outEnd`. For a fresh switch `_outBegin` is zero; for
  // a mid-slide retarget it is the entering screen's captured offset,
  // so its motion stays continuous.
  Offset _inBegin = const Offset(1, 0);
  Offset _outBegin = Offset.zero;
  Offset _outEnd = const Offset(-1, 0);

  late final AnimationController _slideController;
  late final Animation<double> _slideCurve;

  // Round 30 — the dock's label preference, read from the same
  // device store the Settings toggle writes. Native collects the
  // DataStore flow with initial = true (MainActivity.kt:137), so the
  // first frame assumes the native default and the stored value
  // lands a frame later.
  //
  // Customize-wiring fix (Oct 2026): the refresh is LIVE, not
  // tab-switch-timed. The shell listens to the shared SettingsStore
  // (see [_screenFor] — Home receives THIS instance and forwards it
  // into every Settings surface it opens, tray included, not a
  // fresh one), and setShowNavLabels notifies after its write
  // lands, so flipping the Customize toggle while sitting in
  // Settings updates the visible dock on that same screen, in both
  // directions. The dock-tap re-read below stays as a belt-and-
  // braces reseed for writes that bypass the setter (there are
  // none in production; a Round 30 test mutates storage directly).
  bool _showNavLabels = true;

  // Nav Bar Style (Nov 24, 2026): wired EXACTLY like
  // _showNavLabels above — seeded from the shared SettingsStore,
  // refreshed live when the store notifies (setNavBarStyle
  // notifies after its write, same as setShowNavLabels), and
  // re-read on dock taps as the same belt-and-braces reseed.
  // Default SOLID for everyone (the style supersedes the
  // PR #170 liquid-glass bool; see SettingsStore.getNavBarStyle).
  NavBarStyle _navBarStyle = NavBarStyle.solid;
  late final SettingsStore _settingsStore;

  // Drawer nav fade (founder, Nov 20, 2026) — true while the Home
  // drawer is open. The dock below is an overlay sibling ABOVE the
  // tab bodies, so it paints over the drawer's scrim and would sit
  // lit on top of the dimmed screen; while this is true the dock
  // fades out and stops taking touches. Reported by HomeScreen's
  // Scaffold.onDrawerChanged through the callback wired in
  // [_screenFor]. Only Home has a drawer and the drawer is modal,
  // so this can only be true while Home is mounted; [_selectTab]
  // also clears it defensively so no stale fade can leak onto
  // another tab.
  bool _homeDrawerOpen = false;

  /// Midnight Grace — the shell's grace controller (injected or
  /// owned) and whether this shell created it (owned → disposed
  /// here; injected → the caller owns its lifecycle).
  late final MidnightGraceController _graceController;
  late final bool _ownsGraceController;

  @override
  void initState() {
    super.initState();
    _graceController = widget.graceController ?? MidnightGraceController();
    _ownsGraceController = widget.graceController == null;
    _graceController.start();
    _settingsStore = widget.settingsStore ?? SettingsStore();
    _settingsStore.addListener(_onSettingsStoreChanged);
    _heartSleepModeStore =
        widget.heartSleepModeStore ?? HeartSleepModeStore();
    _loadHeartSleepMode();
    // Dev-only app background (Nov 19, 2026): when the background
    // controller notifies, repaint the shell so the ACTIVE tab
    // body re-reads the resolved NotelColors.background token on
    // this same frame — the change applies app-wide immediately,
    // no tab switch, no restart. Inert for non-dev users: the
    // controller only ever notifies on a dev-screen change or the
    // bootstrap load (which lands before the shell exists).
    AppBackgroundController.instance
        .addListener(_onAppBackgroundChanged);
    // Rich streak reminder: a Daily Summary open request (see
    // DailySummaryOpenSignal) shows the Home tab — the card
    // that hosts the sheet exists only there. The shell never
    // consumes the request; the card does, once it is mounted
    // with data.
    DailySummaryOpenSignal.instance
        .addListener(_onDailySummaryOpenSignal);
    // Round 40 — one controller for the paired slide; Round 22's
    // 300ms duration and easeOut curve.
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..addStatusListener(_onSlideStatus);
    _slideCurve =
        CurvedAnimation(parent: _slideController, curve: Curves.easeOut);
    _refreshNavLabels();
    _refreshNavBarStyle();
  }

  @override
  void dispose() {
    // The grace controller: an owned one is disposed (cancelling
    // its crossing/tick timers and its lifecycle observation); an
    // injected one belongs to the caller.
    if (_ownsGraceController) _graceController.dispose();
    // The store is NOT disposed here: when it was injected the
    // caller owns it, and when the shell created it nothing else
    // disposes stores anywhere in this codebase — only the
    // listener registration is the shell's to undo.
    _settingsStore.removeListener(_onSettingsStoreChanged);
    DailySummaryOpenSignal.instance
        .removeListener(_onDailySummaryOpenSignal);
    AppBackgroundController.instance
        .removeListener(_onAppBackgroundChanged);
    _slideController.dispose();
    super.dispose();
  }

  /// Store-change callback (Customize-wiring fix): the write has
  /// already landed in storage, so a plain re-read is the refresh.
  void _onSettingsStoreChanged() {
    _refreshNavLabels();
    _refreshNavBarStyle();
  }

  /// Background-change callback: the token already holds the new
  /// color; a bare setState re-runs the shell build (and with it
  /// the active tab's build) so the new base background paints
  /// immediately.
  void _onAppBackgroundChanged() {
    if (mounted) setState(() {});
  }

  /// Daily Summary open-signal callback (rich streak reminder):
  /// a pending request selects the Home tab through the ordinary
  /// tab-switch path. When Home is already showing this is a
  /// no-op — the mounted card hears the same notification and
  /// opens its sheet itself. A request raised before this shell
  /// exists (cold start) is not lost: the pending flag survives
  /// and the card polls it when its data lands.
  void _onDailySummaryOpenSignal() {
    if (!mounted) return;
    if (!DailySummaryOpenSignal.instance.hasPendingRequest) return;
    if (_tab != DockTab.home) _selectTab(DockTab.home);
  }

  void _onSlideStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !_sliding) return;
    // Slide finished: drop the outgoing screen (disposing its State,
    // exactly as the old instant swap did) and settle on the target.
    setState(() {
      _slots[_fromSlot] = null;
      _settledSlot = _toSlot;
      _sliding = false;
    });
  }

  Future<void> _refreshNavLabels() async {
    final v = await _settingsStore.getShowNavLabels();
    if (mounted && v != _showNavLabels) {
      setState(() => _showNavLabels = v);
    }
  }

  Future<void> _refreshNavBarStyle() async {
    final v = await _settingsStore.getNavBarStyle();
    if (mounted && v != _navBarStyle) {
      setState(() => _navBarStyle = v);
    }
  }

  /// Heart/Sleep toggle — cold-start restore: the founder's last
  /// mode is what the heart slot (and its dock glyph) shows when
  /// they swipe out and back in.
  Future<void> _loadHeartSleepMode() async {
    final mode = await _heartSleepModeStore.loadMode();
    if (mounted && mode != _heartSleepMode) {
      setState(() => _heartSleepMode = mode);
    }
  }

  /// Heart/Sleep toggle — a tap on either screen's switch button.
  /// The mode flips in this setState (screen + dock glyph together)
  /// and the write lands behind it; a failed write never breaks
  /// the switch (the store swallows it).
  void _setHeartSleepMode(HeartSleepMode mode) {
    if (mode == _heartSleepMode) return;
    setState(() => _heartSleepMode = mode);
    unawaited(_heartSleepModeStore.saveMode(mode));
  }

  /// Drawer nav fade: Home's drawer reported a state change. A
  /// plain rebuild flips the dock's fade target and its
  /// IgnorePointer gate together (see the dock mount in [build]).
  void _onHomeDrawerOpenChanged(bool open) {
    if (!mounted || open == _homeDrawerOpen) return;
    setState(() => _homeDrawerOpen = open);
  }

  /// Round 40 — a dock tap. Same-tab is a no-op; reduced motion swaps
  /// instantly; otherwise the paired directional slide starts (or
  /// retargets, if one is already in flight — nothing ever queues).
  void _selectTab(DockTab tab) {
    if (tab == _tab) return; // Tapping the active tab: no transition.
    // Drawer nav fade: leaving Home always restores the dock. The
    // modal drawer makes this unreachable in practice (its scrim
    // blocks dock taps), but a stale true here would strand the
    // dock invisible on the next tab. Both paths below setState,
    // so this plain mutation rides along.
    _homeDrawerOpen = false;
    if (animationsDisabled(context)) {
      // Instant swap, as before Round 40. Land the new tab in the
      // slot the current (or in-flight target) screen occupies so no
      // screen changes parent, and drop everything else.
      final slot = _sliding ? _toSlot : _settledSlot;
      _slideController.stop();
      setState(() {
        _slots[slot] = tab;
        _slots[1 - slot] = null;
        _settledSlot = slot;
        _sliding = false;
        _tab = tab;
      });
      return;
    }
    // Direction: purely by tab index (DockTab declaration order is
    // the spec order). Right jump → travel leftwards: incoming starts
    // at +1 width, outgoing ends at −1 width. Left jump mirrors.
    final dir = tab.index > _tab.index ? 1.0 : -1.0;
    // If a slide is in flight, the screen currently entering (in
    // `_toSlot`) becomes the new outgoing — from its CURRENT offset,
    // captured through the same eased curve, so it never snaps.
    final fromSlot = _sliding ? _toSlot : _settledSlot;
    final eased = _sliding ? _slideCurve.value : 0.0;
    final currentOffset =
        _sliding ? Offset.lerp(_inBegin, Offset.zero, eased)! : Offset.zero;
    // Bounce-back: the target IS the screen currently sliding out
    // (in `_fromSlot`). It re-enters from its captured mid-exit
    // offset — which is always on the correct entry side, since a
    // bounce-back reverses the travel direction — instead of
    // snapping to a full width out and starting over.
    final returning = _sliding && _slots[_fromSlot] == tab;
    final inBegin = returning
        ? Offset.lerp(_outBegin, _outEnd, eased)!
        : Offset(dir, 0);
    setState(() {
      _outBegin = currentOffset;
      _outEnd = Offset(-dir, 0);
      _inBegin = inBegin;
      _fromSlot = fromSlot;
      _toSlot = 1 - fromSlot;
      // The freed slot receives the new target; whatever stale
      // outgoing screen lived there is replaced and disposed now.
      _slots[_toSlot] = tab;
      _sliding = true;
      _tab = tab;
    });
    _slideController.forward(from: 0);
  }

  Widget _screenFor(DockTab tab) {
    return switch (tab) {
      DockTab.home => HomeScreen(
          key: const ValueKey('home_screen'),
          email: widget.email,
          weatherApi: widget.weatherApi,
          locationService: widget.locationService,
          healthConnectService: widget.healthConnectService,
          // Drawer nav fade (founder, Nov 20, 2026): Home reports
          // its drawer's open/close so the dock can fade.
          onDrawerOpenChanged: _onHomeDrawerOpenChanged,
          // The shell's shared instance: Home forwards it into
          // every Settings surface it opens (the Event Counters
          // push and the header-gear settings tray), so a
          // Customize change made there notifies this shell too.
          settingsStore: _settingsStore,
          billingService: widget.billingService,
          revenueCatService: widget.revenueCatService,
          graceController: _graceController,
          migraineController: widget.migraineController,
          // Round 34 — so a logout started in the Settings screen
          // pushed from Home's counter slot exits the shell too.
          onLogout: widget.onLogout,
        ),
      DockTab.tools => ToolsScreen(
          key: const ValueKey('tools_screen'),
          billingService: widget.billingService,
          revenueCatService: widget.revenueCatService),
      DockTab.quickLog => QuickLogScreen(
          key: const ValueKey('quicklog_screen'),
          weatherApi: widget.weatherApi,
        ),
      // Heart/Sleep toggle (founder, Nov 23, 2026): the heart slot
      // hosts Heart or Sleep by mode. Each screen gets the switch
      // callback for its own toggle button; Sleep is hosted (no
      // back button — there is nothing to pop to in the shell).
      DockTab.heart => _heartSleepMode == HeartSleepMode.sleep
          ? SleepScreen(
              key: const ValueKey('sleep_screen'),
              healthConnect: widget.healthConnectService,
              onShowHeart: () =>
                  _setHeartSleepMode(HeartSleepMode.heart),
            )
          : HeartScreen(
              key: const ValueKey('heart_screen'),
              email: widget.email,
              healthConnectService: widget.healthConnectService,
              onShowSleep: () =>
                  _setHeartSleepMode(HeartSleepMode.sleep),
            ),
    };
  }

  Animation<Offset> _positionFor(int slot) {
    if (!_sliding) return const AlwaysStoppedAnimation<Offset>(Offset.zero);
    if (slot == _toSlot) {
      return Tween<Offset>(begin: _inBegin, end: Offset.zero)
          .animate(_slideCurve);
    }
    return Tween<Offset>(begin: _outBegin, end: _outEnd).animate(_slideCurve);
  }

  Widget _slotWidget(int slot) {
    final tab = _slots[slot];
    return SlideTransition(
      // The slot wrapper's key never changes, so a screen keeps its
      // element (and State) while its slot's role flips between
      // incoming / outgoing / settled across rapid retargets.
      key: ValueKey('tab_slide_slot_$slot'),
      position: _positionFor(slot),
      child: tab == null ? const SizedBox.shrink() : _screenFor(tab),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ambient = Theme.of(context);
    return Stack(
      children: [
        // Snackbar clearance: the dock below is an overlay SIBLING
        // of the tab bodies, not any tab Scaffold's
        // bottomNavigationBar, so a Scaffold knows nothing about
        // it — and a fixed (M3 default) SnackBar anchors to its own
        // Scaffold's bottom edge, where the opaque dock pill paints
        // over its lower half. Scoping a FLOATING snackbar theme
        // around the body slot only (never the dock) parks the
        // visible card above the pill instead: a floating bar sits
        // at its base (the Scaffold's bottom, capped at the
        // viewPadding line the dock also resolves against) minus
        // the theme's insetPadding.bottom, which is derived from
        // the shared dock geometry in nav_dock.dart (Phase 2
        // replica: 62dp height in all states + the
        // max(27, viewPadding + 4) float rule), so the inset
        // tracks the dock exactly in every state.
        // Left/right stay 0, so the bar keeps its full-width look;
        // colors / shape / text style / duration come untouched
        // from the ambient theme. Screens outside the shell
        // (welcome / login, pushed routes) are not under this
        // Theme, so they get no phantom gap. Do not "simplify"
        // this wrapper away — the defect returns with it.
        Theme(
          data: ambient.copyWith(
            snackBarTheme: ambient.snackBarTheme.copyWith(
              behavior: SnackBarBehavior.floating,
              insetPadding: EdgeInsets.fromLTRB(
                0,
                5,
                0,
                // Per-style inset (Nav Bar Style package): the
                // glass dock's geometry when a Liquid Glass style
                // is active — dark OR light (Nav Bar Style Fixes
                // package: the light glass is the same NavDock
                // geometry family, 62dp + the glass float rule) —
                // the Solid dock's (58dp + its own float rule)
                // when Solid is.
                _navBarStyle == NavBarStyle.solid
                    ? navDockSolidSnackBarBottomInset(
                        viewPaddingBottom:
                            MediaQuery.viewPaddingOf(context).bottom,
                      )
                    : navDockSnackBarBottomInset(
                        showLabels: _showNavLabels,
                        viewPaddingBottom:
                            MediaQuery.viewPaddingOf(context).bottom,
                      ),
              ),
            ),
          ),
          // Tab body. This inner Stack is the slot wrappers' parent in
          // EVERY state (rest and sliding alike) — if the wrappers'
          // parent changed between states, their screens would remount
          // at each transition boundary. Outgoing renders below
          // incoming while sliding; at rest only the settled slot is in
          // the tree at all.
          child: Stack(
            children: _sliding
                ? [_slotWidget(_fromSlot), _slotWidget(_toSlot)]
                : [_slotWidget(_settledSlot)],
          ),
        ),
        // Dock floats above every tab.
        //
        // Drawer nav fade (founder, Nov 20, 2026): while the Home
        // drawer is open, the dock fades out over 200ms (the app's
        // easeOut family; the drawer's own slide is 250ms) and is
        // removed from the hit path — it paints ABOVE the drawer
        // scrim in this Stack, so left alone it would stay lit over
        // the dimmed screen and swallow the scrim taps that close
        // the drawer along the bottom edge. IgnorePointer flips
        // with the same state change that starts the fade, so the
        // dock is inert for the whole fade-out and live again the
        // moment the drawer starts closing. The Positioned slot is
        // unchanged, so nothing shifts layout in either state.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            key: const ValueKey('nav_dock_drawer_ignore_pointer'),
            ignoring: _homeDrawerOpen,
            child: AnimatedOpacity(
              key: const ValueKey('nav_dock_drawer_fade'),
              opacity: _homeDrawerOpen ? 0.0 : 1.0,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              // Nav Bar Style: Solid mounts the new NavDockSolid;
              // Dark Liquid Glass mounts the shipped PR #170
              // NavDock with liquidGlass: true (always true on
              // this path — nav_dock.dart itself is untouched);
              // Light Liquid Glass mounts NavDockLightGlass,
              // which builds the same NavDock on its legacy
              // (liquidGlass: false) path — the pre-#170 milky
              // glass by construction. The onSelect reseed is
              // shared by all three docks.
              child: switch (_navBarStyle) {
                NavBarStyle.liquidGlass => NavDock(
                    selected: _tab,
                    showLabels: _showNavLabels,
                    liquidGlass: true,
                    heartSleepMode: _heartSleepMode,
                    onSelect: (tab) {
                      _selectTab(tab);
                      _refreshNavLabels();
                      _refreshNavBarStyle();
                    },
                  ),
                NavBarStyle.liquidGlassLight => NavDockLightGlass(
                    selected: _tab,
                    showLabels: _showNavLabels,
                    heartSleepMode: _heartSleepMode,
                    onSelect: (tab) {
                      _selectTab(tab);
                      _refreshNavLabels();
                      _refreshNavBarStyle();
                    },
                  ),
                NavBarStyle.solid => NavDockSolid(
                    selected: _tab,
                    heartSleepMode: _heartSleepMode,
                    onSelect: (tab) {
                      _selectTab(tab);
                      _refreshNavLabels();
                      _refreshNavBarStyle();
                    },
                  ),
              },
            ),
          ),
        ),
      ],
    );
  }
}
