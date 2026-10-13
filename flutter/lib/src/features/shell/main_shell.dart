import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/location_service.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/heart/heart_screen.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/quicklog/quick_log_screen.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';
import 'package:tabs_lab/src/features/tools/tools_screen.dart';
import 'package:tabs_lab/src/theme/animations.dart';

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
/// - Settings → the real Settings screen (round 29): native
///   SettingsScreen port with membership, profile-backed toggles,
///   and real logout / delete-account flows.
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
///   order 0 Home, 1 Tools, 2 Quick Log, 3 Heart, 4 Settings):
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

  const MainShell(
      {super.key,
      this.email,
      this.weatherApi,
      this.locationService,
      this.healthConnectService,
      this.onLogout,
      this.settingsStore});

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
  // lands a frame later. Re-read on every tab change so flipping the
  // Settings toggle takes effect as soon as the user leaves Settings.
  bool _showNavLabels = true;
  late final SettingsStore _settingsStore;

  @override
  void initState() {
    super.initState();
    _settingsStore = widget.settingsStore ?? SettingsStore();
    // Round 40 — one controller for the paired slide; Round 22's
    // 300ms duration and easeOut curve.
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..addStatusListener(_onSlideStatus);
    _slideCurve =
        CurvedAnimation(parent: _slideController, curve: Curves.easeOut);
    _refreshNavLabels();
  }

  @override
  void dispose() {
    _slideController.dispose();
    super.dispose();
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

  /// Round 40 — a dock tap. Same-tab is a no-op; reduced motion swaps
  /// instantly; otherwise the paired directional slide starts (or
  /// retargets, if one is already in flight — nothing ever queues).
  void _selectTab(DockTab tab) {
    if (tab == _tab) return; // Tapping the active tab: no transition.
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
          // Round 34 — so a logout started in the Settings screen
          // pushed from Home's counter slot exits the shell too.
          onLogout: widget.onLogout,
        ),
      DockTab.tools => const ToolsScreen(key: ValueKey('tools_screen')),
      DockTab.quickLog => QuickLogScreen(
          key: const ValueKey('quicklog_screen'),
          weatherApi: widget.weatherApi,
        ),
      DockTab.heart => HeartScreen(
          key: const ValueKey('heart_screen'),
          email: widget.email,
          healthConnectService: widget.healthConnectService,
        ),
      DockTab.settings => SettingsScreen(
          key: const ValueKey('settings_screen'),
          email: widget.email,
          onLogout: widget.onLogout,
          healthConnectService: widget.healthConnectService,
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
    return Stack(
      children: [
        // Tab body. This inner Stack is the slot wrappers' parent in
        // EVERY state (rest and sliding alike) — if the wrappers'
        // parent changed between states, their screens would remount
        // at each transition boundary. Outgoing renders below
        // incoming while sliding; at rest only the settled slot is in
        // the tree at all.
        Stack(
          children: _sliding
              ? [_slotWidget(_fromSlot), _slotWidget(_toSlot)]
              : [_slotWidget(_settledSlot)],
        ),
        // Dock floats above every tab.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: NavDock(
            selected: _tab,
            showLabels: _showNavLabels,
            onSelect: (tab) {
              _selectTab(tab);
              _refreshNavLabels();
            },
          ),
        ),
      ],
    );
  }
}
