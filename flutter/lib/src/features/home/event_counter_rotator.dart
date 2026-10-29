import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 34 — the rotating event-counter slot on Home.
///
/// Native source: `TodayScreen.kt` section 2, "Compact Streak Boxes &
/// Rotating Event Counters Row" — the counters sit on the RIGHT of
/// the streak pills (they are not a separate card), fed by
/// `quickLogState.eventCounters.filter { !it.isArchived }` in stored
/// (Settings list) order. The Flutter caller filters with the
/// unified predicate (`EventCounterItem.isActive`, Oct 28, 2026 —
/// neither archived nor delete-stamped) via [activeEventCounters],
/// so a stamp-only row never reaches this widget.
///
/// Native behavior, ported:
/// - Display per counter: `"Since {name}"` / `"Until {name}"`
///   (9sp, FontWeight.Black, `NotelPrimary` — native's 80% alpha
///   measures 3.65:1, so Round 49 renders it at full opacity, 5.08:1;
///   letter spacing 0.5, right-aligned, single line, ellipsized) beside
///   `"{days}"` (14sp Black, textPrimary) + `"Days"` (8sp Bold,
///   textSecondary, letter spacing 0.5). The day count is the native
///   directed count clamped at 0 — see
///   [EventCounterItem.todayDisplay].
/// - Multiple counters: an (effectively) infinite pager auto-advances
///   every 10 seconds (`delay(10000)` after each settled page) and can
///   be swiped manually; page dots underneath (current: 4dp
///   `NotelPrimary`; others: 3dp `NotelSurfaceHigh` at 30% alpha,
///   3dp apart, 2dp below the count).
/// - One counter: static, no pager motion, no dots, no timer.
/// - Zero counters never reach this widget — the caller renders no
///   slot at all (native's fallback there is the upcoming-reminders
///   line, which is not counter data; the founder's Round 34 spec is
///   explicit: no empty placeholder).
///
/// Round 34 additions on top of native (founder spec):
/// - Tapping the slot opens the Settings Event Counters screen
///   (native's pager has no tap action; the founder asked for one).
/// - Rotation PAUSES while the user interacts with the slot
///   (pointer down / dragging) and resumes with a fresh interval
///   afterwards.
/// - Reduced motion (`animationsDisabled`): no auto-advance and no
///   animated page transitions — the pager stays manually swipeable
///   and otherwise static, per the app's animation rules.
class EventCounterRotator extends StatefulWidget {
  /// Active counters only (already filtered + ordered by the caller
  /// via [activeEventCounters]); must be non-empty.
  final List<EventCounterItem> counters;

  /// Tap destination (Home pushes the Settings Event Counters
  /// screen). Null disables the tap (previews/tests of pure display).
  final VoidCallback? onTap;

  /// Injectable clock for day-boundary tests; defaults to the
  /// device clock at build time.
  final DateTime? now;

  /// Native auto-advance interval (TodayScreen.kt: `delay(10000)`
  /// after each settled page).
  static const Duration rotationInterval = Duration(seconds: 10);

  /// Native pager's virtual page count (TodayScreen.kt:
  /// `infinitePageCount = 10000`, initial page 5000). The Flutter
  /// initial page is rounded DOWN to a multiple of the counter count
  /// so the first counter shown is always counters[0] in Settings
  /// order (native's raw 5000 can start mid-list when the count does
  /// not divide 5000).
  static const int virtualPageCount = 10000;

  const EventCounterRotator({
    super.key,
    required this.counters,
    this.onTap,
    this.now,
  }) : assert(counters.length > 0, 'zero counters must not render a slot');

  @override
  State<EventCounterRotator> createState() => _EventCounterRotatorState();
}

class _EventCounterRotatorState extends State<EventCounterRotator> {
  PageController? _controller;
  Timer? _timer;
  int _currentIndex = 0;
  bool _interacting = false;
  bool _reducedMotion = false;
  bool _timerInitialized = false;

  bool get _rotates => widget.counters.length > 1;

  int get _initialPage {
    const base = EventCounterRotator.virtualPageCount ~/ 2; // 5000
    final n = widget.counters.length;
    return base - (base % n);
  }

  @override
  void initState() {
    super.initState();
    if (_rotates) {
      _controller = PageController(initialPage: _initialPage);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduced motion can change at runtime; the timer policy follows
    // it live (auto-advance stops, manual swipe keeps working).
    final reduced = animationsDisabled(context);
    if (!_timerInitialized || reduced != _reducedMotion) {
      _timerInitialized = true;
      _reducedMotion = reduced;
      _restartTimer();
    }
  }

  @override
  void didUpdateWidget(EventCounterRotator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameIds(oldWidget.counters, widget.counters)) {
      // The set changed (e.g. a counter was archived in Settings and
      // Home refreshed): restart from the first counter in the new
      // order instead of landing on a stale virtual page.
      _currentIndex = 0;
      if (_rotates && _controller == null) {
        _controller = PageController(initialPage: _initialPage);
      } else if (!_rotates && _controller != null) {
        _controller!.dispose();
        _controller = null;
      } else if (_controller != null && _controller!.hasClients) {
        _controller!.jumpToPage(_initialPage);
      }
      _restartTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  static bool _sameIds(List<EventCounterItem> a, List<EventCounterItem> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = null;
    if (!_rotates || _reducedMotion || _interacting || !mounted) return;
    _timer = Timer.periodic(EventCounterRotator.rotationInterval, (_) {
      if (!mounted || _interacting || _reducedMotion) return;
      final controller = _controller;
      if (controller == null || !controller.hasClients) return;
      final page = controller.page?.round() ?? _initialPage;
      controller.animateToPage(
        page + 1,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    });
  }

  void _onPointerDown() {
    if (!_rotates) return;
    _interacting = true;
    _timer?.cancel();
    _timer = null;
  }

  void _onPointerUp() {
    if (!_rotates) return;
    _interacting = false;
    // Fresh full interval after the interaction ends — the user is
    // never yanked to the next counter mid-read.
    _restartTimer();
  }

  @override
  Widget build(BuildContext context) {
    final counters = widget.counters;
    final now = widget.now ?? DateTime.now();
    Widget content;
    if (!_rotates) {
      content = _counterPage(counters.first, now);
    } else {
      content = SizedBox(
        // Label/count row (~20) + 2dp gap + 4dp dots, native layout.
        height: 28,
        child: PageView.builder(
          controller: _controller,
          itemCount: EventCounterRotator.virtualPageCount,
          onPageChanged: (page) {
            final idx = page % counters.length;
            if (idx != _currentIndex) {
              setState(() => _currentIndex = idx);
            }
          },
          itemBuilder: (_, page) => _counterPage(
            counters[page % counters.length],
            now,
            showDots: true,
          ),
        ),
      );
    }
    return Listener(
      onPointerDown: (_) => _onPointerDown(),
      onPointerUp: (_) => _onPointerUp(),
      onPointerCancel: (_) => _onPointerUp(),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Semantics(
          button: widget.onTap != null,
          label: 'Event counters',
          // Round 49 (audit H4): the slot's tap height was 28dp (multi)
          // / ~20dp (single). A 48dp minimum height expands the HIT
          // AREA only — the label/count/dots render at their native
          // sizes, centered in the taller slot (H16's micro-labels are
          // flagged, untouched).
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: content,
          ),
        ),
      ),
    );
  }

  /// One counter's display, native values verbatim: the label is
  /// right-aligned inside the slot; the count column centers the
  /// "{days} Days" pair, with the page dots centered underneath it
  /// when [showDots] (native renders the dots inside each page,
  /// under the count column — never for a single counter).
  Widget _counterPage(EventCounterItem counter, DateTime now,
      {bool showDots = false}) {
    final display = counter.todayDisplay(now: now);
    final counters = widget.counters;
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          child: Text(
            display.up ? 'Since ${counter.name}' : 'Until ${counter.name}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.5,
              // Round 49 (audit H6): native's primary @ 80% measures
              // 3.65:1 on the page background; full-opacity primary is
              // 5.08:1. Size/weight are native-verbatim (H16, flagged).
              color: NotelColors.primary,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  '${display.days}',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    color: NotelColors.textPrimary,
                  ),
                ),
                const SizedBox(width: 2),
                Text(
                  'Days',
                  style: TextStyle(
                    fontSize: 8,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                    color: NotelColors.textSecondary,
                  ),
                ),
              ],
            ),
            if (showDots) ...[
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < counters.length; i++) ...[
                    if (i > 0) const SizedBox(width: 3),
                    Container(
                      width: i == _currentIndex ? 4 : 3,
                      height: i == _currentIndex ? 4 : 3,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == _currentIndex
                            ? NotelColors.primary
                            : NotelColors.surfaceHigh
                                .withValues(alpha: 0.3),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ],
    );
  }
}
