import 'dart:async';

import 'package:flutter/material.dart';

import 'package:tabs_lab/src/features/home/streak_celebration_screen.dart';
import 'package:tabs_lab/src/features/settings/report_generation_presenter.dart';

/// Celebration presentation fix (Nov 21, 2026) — the founder
/// completed his Daily Summary inside the Today Summary sheet:
/// the day counted (29 -> 30) and both gem grants landed, but the
/// streak celebration never appeared and Home's pill showed the
/// new count with the flame unlit.
///
/// Proven mechanism (celebration_present_repro_test.dart): the
/// celebration was a single fragile shot at the END of
/// Home._presentCompletion — presented from Home's own State
/// context, after two network awaits, behind an
/// `if (!mounted) return` that also guarded the pill update, with
/// the watcher's fired-day marker already written, so a dropped
/// presentation could never re-fire. Two kill paths were
/// reproduced: Home unmounting mid-completion (tab switch — the
/// shell disposes the outgoing tab) ate the presentation while
/// the claim and the counted day landed; and a self-popping
/// commit sheet (the check-in kind sheet behind the founder's
/// "2 · Rough · Crash") whose late unconditional pop removed the
/// celebration instead of itself.
///
/// The fix decouples presentation from Home's lifecycle: Home
/// hands the built celebration to [StreakCelebrationService],
/// which holds it as pending until it has actually been pushed —
/// exactly once per completion day — and the app-root
/// [StreakCelebrationPresenter] (the ReportGenerationPresenter
/// precedent) pushes it on the root navigator, over whatever
/// surface is current. A completion that lands while Home is
/// disposed presents over the current tab; one that lands while
/// the app is not resumed is held and presented on the next
/// foreground instead of being dropped.
class PendingStreakCelebration {
  final StreakCelebrationData data;
  final String? nickname;

  /// The Tabs day the completion counted (the watcher's day) —
  /// the exactly-once key: one celebration per completed day.
  final String dayKey;

  const PendingStreakCelebration({
    required this.data,
    required this.dayKey,
    this.nickname,
  });
}

/// Holds at most one not-yet-presented celebration. The claim
/// (GemService) and the counted day (StreakStore) never pass
/// through here — this service owns PRESENTATION only, so a
/// missed or delayed presentation can never eat a grant, and a
/// grant can never be re-issued by a re-presentation.
class StreakCelebrationService {
  StreakCelebrationService._();

  static final StreakCelebrationService instance =
      StreakCelebrationService._();

  PendingStreakCelebration? _pending;
  String? _showingDayKey;
  void Function()? _presenter;

  PendingStreakCelebration? get pending => _pending;

  /// True while a celebration route is on stage (CHESTS package:
  /// the chest drop prompt waits for this to clear so it lands
  /// after the celebration, never over it).
  bool get isShowing => _showingDayKey != null;

  @visibleForTesting
  String? get debugShowingDayKey => _showingDayKey;

  /// The app-root presenter registers its attempt callback;
  /// a celebration already held is attempted immediately.
  void registerPresenter(void Function() present) {
    _presenter = present;
    if (_pending != null) present();
  }

  void unregisterPresenter(void Function() present) {
    if (_presenter == present) _presenter = null;
  }

  /// Hand a completed day's celebration to the presenter. A
  /// second hold for a day already pending or currently showing
  /// is a no-op (exactly once per completion day).
  void hold(PendingStreakCelebration celebration) {
    if (_pending?.dayKey == celebration.dayKey) return;
    if (_showingDayKey == celebration.dayKey) return;
    _pending = celebration;
    _presenter?.call();
  }

  /// Foreground retry: a celebration held while the app was not
  /// resumed is attempted again.
  void handleResumed() {
    if (_pending != null) _presenter?.call();
  }

  /// Consume [celebration] and run [show] (the route push). The
  /// pending slot clears BEFORE the push so a re-entrant hold for
  /// the same day during the celebration is governed by the
  /// showing key, and the showing key clears when the route is
  /// dismissed — a celebration is presented exactly once, and
  /// dismissing it never re-presents it.
  Future<void> presentHeld(
    PendingStreakCelebration celebration,
    Future<void> Function() show,
  ) async {
    if (!identical(_pending, celebration)) return;
    _pending = null;
    _showingDayKey = celebration.dayKey;
    try {
      await show();
    } finally {
      if (_showingDayKey == celebration.dayKey) _showingDayKey = null;
    }
  }

  @visibleForTesting
  void debugReset() {
    _pending = null;
    _showingDayKey = null;
    _presenter = null;
  }
}

/// App-root presenter for streak celebrations: mounted once
/// above the app's Navigator by the app root (alongside
/// [ReportGenerationPresenter]). It presents a held celebration
/// through the root navigator key — above the Today Summary
/// sheet, a pushed screen, the drawer, or another tab — and
/// retries a held celebration when the app returns to the
/// foreground.
class StreakCelebrationPresenter extends StatefulWidget {
  final Widget child;

  /// The navigator the celebration is pushed on (defaults to the
  /// shared [reportPresentationNavigatorKey] the app root wires
  /// into MaterialApp; tests pass their own).
  final GlobalKey<NavigatorState>? navigatorKey;

  /// Test seam: defaults to the singleton service.
  final StreakCelebrationService? service;

  const StreakCelebrationPresenter({
    super.key,
    required this.child,
    this.navigatorKey,
    this.service,
  });

  @override
  State<StreakCelebrationPresenter> createState() =>
      _StreakCelebrationPresenterState();
}

class _StreakCelebrationPresenterState
    extends State<StreakCelebrationPresenter>
    with WidgetsBindingObserver {
  StreakCelebrationService get _service =>
      widget.service ?? StreakCelebrationService.instance;

  late final void Function() _presentCallback = _tryPresent;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _service.registerPresenter(_presentCallback);
    // Registration happens before the Navigator below exists,
    // so a celebration already held at mount time finds no
    // navigator context on the first attempt: retry once the
    // first frame has built it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryPresent());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _service.unregisterPresenter(_presentCallback);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _service.handleResumed();
    }
  }

  void _tryPresent() {
    if (!mounted) return;
    final pending = _service.pending;
    if (pending == null) return;
    // Backgrounded at the completing moment: hold the
    // celebration and present it on the next foreground (the
    // lifecycle observer above retries) instead of dropping it.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      return;
    }
    // A context UNDER the root navigator (this widget's own
    // context is above it — see reportPresentationNavigatorKey).
    final navContext =
        (widget.navigatorKey ?? reportPresentationNavigatorKey)
            .currentContext;
    if (navContext == null) return;
    unawaited(_service.presentHeld(
      pending,
      () => StreakCelebrationScreen.show(
        navContext,
        data: pending.data,
        nickname: pending.nickname,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
