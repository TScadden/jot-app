import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/migraine_controller.dart';
import 'package:tabs_lab/src/data/migraine_time_format.dart';
import 'package:tabs_lab/src/data/session_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/features/home/migraine_block.dart';
import 'package:tabs_lab/src/features/quicklog/history_screen.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/slide_page_route.dart';

/// Today Summary card — port of the native "Expandable Today Summary
/// Section" (`TodayScreen.kt` item 3, `TodayViewModel`).
///
/// Round 35 — WIRED FOR REAL. The round-8 version of this card was a
/// visual shell: subtitle, plan list, and trends were hardcoded empty
/// states and the Trends refresh button was a no-op. The audit found
/// that defect and this rewrite computes everything from today's real
/// data via [TodaySummaryLoader] (see `today_summary.dart` for the
/// full native trace and the data-source mapping):
/// - subtitle: the native `summaryText` ("N items remaining ·
///   M overdue" / "Everything planned for today is complete" /
///   "No plans recorded today");
/// - Today's Plan: medications (Daily slot), enabled reminders, and
///   habits with native's sort, overdue badges, and working
///   complete / take / skip / undo actions;
/// - Trends: Sleep / Resting HR / Symptom comparisons with native's
///   exact strings; the refresh button re-runs the comparison load.
///
/// Behavior rules:
/// - Starts COLLAPSED on every mount — the founder's standing rule
///   for the Flutter rebuild (native persists an expanded pref that
///   defaults to expanded; round 13c divergence, kept deliberately).
///   The toggle itself is plain session state and flips reliably.
/// - Failure is honest and quiet: a failed sync pull renders the
///   last-known (account-bound, date-bound) summary from
///   [TodaySummaryCache], never an error and never a blank section;
///   Health Connect gaps simply omit their trend sections, matching
///   native's per-section fail-safe repository.
/// - Plan actions are optimistic (founder fix, Nov 2, 2026 —
///   supersedes the R35 no-optimism rule for plan rows): a
///   check-off slides the row away the same frame it is tapped,
///   and the loader write + reconciling reload run in the
///   background through a serialized chain (see [_actionChain]),
///   so a slow or stalled connection never leaves a tapped row
///   sitting motionless and rapid back-to-back taps on different
///   rows all register. A reminder/habit write that reports
///   failure restores its row on the reconciling reload — no
///   phantom completions. (Still no spinner and no count-up
///   replay — there are no animated numbers in this card.)
/// - Plan and trends load in two phases (native's flows are likewise
///   independent): the plan never waits on Health Connect. One
///   micro-divergence from native: the trends area shows its empty
///   text while the first comparison load is in flight instead of
///   native's Loading spinner — the load is one bridge round-trip,
///   the card starts collapsed, and live comparisons replace the
///   text the moment they land.
/// - Check-off slide-away (founder directive, Oct 20, 2026 —
///   supersedes the R35 check-off dissolve effect, which is
///   REMOVED; native has NO per-item check-off exit animation at
///   all — its only AnimatedVisibility wraps the whole expanded
///   section, TodayScreen.kt:550-554, and completed items stay
///   visible at 0.5 alpha): checking an item off IN THIS CARD
///   slides the row out to the right while its height collapses
///   (see [_SlideAwayRowSlot]: 300ms, the app's standard slide
///   duration; slide eased with easeIn — the app's exit curve —
///   and the height collapse with easeInOut), then the item is
///   gone from this card instance's view. The slide starts FIRST
///   (optimistic, the same frame as the tap); the check-off then
///   persists through the exact same loader writes as before,
///   in the background through the serialized [_actionChain],
///   and the reconciling reload that follows each write keeps
///   the view honest. Reduced motion
///   (animationsDisabled) removes the item instantly, no slide.
///   Section rule (founder): the card auto-collapses ONLY when a
///   check-off removes the LAST remaining plan item, and only after
///   the slide finishes; otherwise the section stays open.
/// - Round 41 (founder, supersedes the R35 completed-row display):
///   a completed/resolved item NEVER renders — not dimmed, not
///   struck through, no Undo affordance. `buildTodayPlan` already
///   excludes them from the plan, so a dose or habit completed
///   before this card mounted is simply absent, and the founder's
///   undo is deleting the check-off's log entry in History (the
///   next load restores the item). Because the reload after a
///   check-off already excludes the item, the slide-away slot is
///   inserted at the row's captured index rather than substituted
///   for a rendered row. When nothing remains but things were
///   planned, the expanded plan area shows the completed message
///   ("Everything planned for today is complete") — the same copy
///   as the subtitle — instead of an empty void; a day with
///   nothing planned shows "No plans recorded today".
class TodaySummaryCard extends StatefulWidget {
  /// Injectable for tests; production defaults are real instances.
  final TabsBackend? backend;
  final HealthConnectService? healthConnectService;
  final TodayPlanStore? planStore;
  final TodaySummaryCache? summaryCache;
  final SessionStore? sessionStore;

  /// The shared app-level migraine controller (created with the app
  /// wiring in main.dart). When null the card creates and owns one,
  /// so the migraine block works in every mount; the app passes its
  /// instance so the card, the collapsed header, and the
  /// notification tap handler share ONE state.
  final MigraineController? migraineController;

  /// Home redesign — optional builder for the check-in section hosted
  /// inside this card's summary SHEET. Home passes a builder returning
  /// its FeelingCheckInCard / CheckInSummaryCard; ALL check-in state
  /// and commits stay in Home — the card only hosts the widget. Null
  /// (standalone card mounts) renders no check-in section.
  final Widget Function(BuildContext context)? checkInBuilder;

  /// Seventh founder ruling (Nov 9, 2026) — a plain widget rendered
  /// at the right end of the card's header row, level with the
  /// 'Today Summary' title (Home passes its weather element). It is
  /// a SIBLING of the header's tappable region, never inside it, so
  /// its own tap target keeps its own behavior and never triggers
  /// the summary sheet.
  final Widget? headerTrailing;

  /// Home polish round 4 (Part C) — the scored check-in line shown
  /// on the card FACE once today's ranking is logged (Home composes
  /// it via `homeCheckInScoredLine`, the single copy swap point in
  /// home_checkin_strip.dart). Null (unscored, or a standalone card
  /// mount) renders no line.
  ///
  /// Round 5 (founder ruling, Nov 10, 2026): the line is
  /// DISPLAY-ONLY. Round 4 gave it a tap target opening the
  /// check-in amend flow; the founder ruled the "why it was good"
  /// explanation must not reopen after the ranking is logged, so
  /// the tap is removed entirely — no handler, no ripple, no
  /// button semantics. The score is just shown.
  final String? checkInScoredLine;

  /// The scored line's accessibility sentence (the merged flow's
  /// Item 7.2 semantics composition, supplied by Home alongside
  /// [checkInScoredLine]) and the latest Item 11 commit
  /// announcement, carried as a zero-size live region exactly as
  /// the sheet's CheckInSummaryCard carries it — a flare/good
  /// commit announces identically on both summary surfaces.
  final String? checkInScoredSemantics;
  final String? checkInAnnouncement;

  const TodaySummaryCard({
    super.key,
    this.backend,
    this.healthConnectService,
    this.planStore,
    this.summaryCache,
    this.sessionStore,
    this.migraineController,
    this.checkInBuilder,
    this.headerTrailing,
    this.checkInScoredLine,
    this.checkInScoredSemantics,
    this.checkInAnnouncement,
  });

  @override
  State<TodaySummaryCard> createState() => _TodaySummaryCardState();
}

class _TodaySummaryCardState extends State<TodaySummaryCard> {
  late final TodaySummaryLoader _loader;

  // Migraine timer (Juno §D): the shared controller drives the
  // block + the collapsed-header subtitle; a 30s tick (Lab cadence)
  // refreshes the elapsed text in both while an attack runs and
  // re-posts the ongoing notification with the same elapsed text.
  late final MigraineController _migraine;
  bool _ownsMigraine = false;
  Timer? _migraineTimer;

  TodaySummaryData? _data;
  bool _trendsRefreshing = false;

  /// Home redesign — the card no longer expands in place; its tap
  /// opens a modal sheet (hosted here so the sheet shares [_loader],
  /// [_actionChain], and the reconciling reload). While the sheet is
  /// open, card setStates bump [_sheetTick] (see the [setState]
  /// override) so the sheet re-reads the card's current data.
  bool _sheetOpen = false;
  final ValueNotifier<int> _sheetTick = ValueNotifier<int>(0);

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    if (_sheetOpen && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_sheetOpen && mounted) _sheetTick.value++;
      });
    }
  }

  /// Home redesign (coordinator ruling R1) — finish-line progress:
  /// resolved = taken + skipped + completed, i.e. everything that is
  /// no longer an OPEN item. `buildTodayPlan` already excludes
  /// resolved items (skipped doses included) from `items`, so
  /// progress = (plannedCount − items.length) / plannedCount.
  /// Null when there is no honest value (no data, or nothing planned).
  double? get _progress {
    final data = _data;
    if (data == null) return null;
    final planned = data.plan.plannedCount;
    if (planned == 0) return null;
    final resolved = planned - data.plan.items.length;
    return (resolved / planned).clamp(0.0, 1.0);
  }

  /// Background write chain for plan actions (Nov 2, 2026 fix).
  /// Taps NEVER wait on this chain — the slide-away is optimistic
  /// and starts the same frame — but the writes themselves must
  /// execute sequentially in tap order: the loader allocates each
  /// new log entry's id as server-max+1 from a fresh fetch, so two
  /// concurrent writes could collide on the same id and clobber
  /// each other's entry. Each link runs one write plus its
  /// reconciling reload, and swallows its own errors so a failed
  /// link never wedges the chain. There is deliberately NO global
  /// acting lock: the pre-fix `_actingItemId` guard silently ate
  /// taps on every other row for the whole in-flight window,
  /// which is what broke the founder's rapid back-to-back med
  /// routine. Idempotency is per item instead: an item already in
  /// [_goneItemIds] (sliding, slid, or vanished) ignores further
  /// taps, and once tapped its row is replaced by the inert slide
  /// slot, so a same-row double-tap cannot re-fire.
  Future<void> _actionChain = Future<void>.value();

  /// Slide-away exit state (see the class doc). At most one row
  /// slides out at a time; a second check-off finalizes the
  /// active slide instantly before its own slide begins.
  final Set<String> _goneItemIds = <String>{};
  String? _exitingItemId;

  /// The exiting row's data (Round 41's post-check-off reload
  /// already excludes it from the plan data) and its index in the
  /// rendered list, captured before the check-off write, so the
  /// slide slot is INSERTED at the row's position rather than
  /// substituted for a rendered row.
  TodayPlanItem? _exitingItem;
  int _exitingIndex = 0;

  /// Key of the ACTIVE exit slot. Replaced with a fresh key for
  /// every exit (see _slideOrVanish): a finalized slot's State is
  /// spent (its gone latch is set, its controller stopped), and a
  /// rapid second check-off can arrive before that slot has left
  /// the tree — reusing its key would inherit the spent State and
  /// freeze the new exit in place, unanimated, never completing.
  GlobalKey<_SlideAwayRowSlotState> _exitSlotKey =
      GlobalKey<_SlideAwayRowSlotState>();

  /// First step of a check-off (Nov 2, 2026 fix): slide the row
  /// out NOW, the same frame as the tap, or remove it instantly
  /// when reduced motion is on. The loader write has NOT landed
  /// yet — it runs in the background through [_actionChain] and
  /// the reconciling reload follows it; a failed reminder/habit
  /// write restores the row via [_restoreItem]. [index] is the
  /// row's position in the currently rendered list (plan items
  /// minus [_goneItemIds]), captured at tap time so back-to-back
  /// exits slot correctly; the item is marked gone immediately
  /// so a stale plan that still carries it never double-renders
  /// it alongside its slide slot.
  void _slideOrVanish(TodayPlanItem item, int index) {
    if (!mounted || _goneItemIds.contains(item.id)) return;
    if (animationsDisabled(context)) {
      _vanishItem(item.id);
      return;
    }
    // One exit at a time: finalize the active one instantly.
    _exitSlotKey.currentState?.finalizeNow();
    // Fresh slot State for THIS exit (see _exitSlotKey).
    _exitSlotKey = GlobalKey<_SlideAwayRowSlotState>();
    setState(() {
      _goneItemIds.add(item.id);
      _exitingItem = item;
      _exitingItemId = item.id;
      _exitingIndex = index;
    });
  }

  /// Instant removal (reduced motion): the item leaves the view
  /// now, and the last-item collapse rule applies immediately.
  void _vanishItem(String itemId) {
    _exitSlotKey.currentState?.finalizeNow();
    if (!mounted) return;
    setState(() {
      _goneItemIds.add(itemId);
      if (_exitingItemId == itemId) {
        _exitingItem = null;
        _exitingItemId = null;
      }
    });
  }

  /// Slot callback: the slide + gap-close finished.
  void _onExitGone(String itemId) {
    if (!mounted) return;
    setState(() {
      _goneItemIds.add(itemId);
      if (_exitingItemId == itemId) {
        _exitingItem = null;
        _exitingItemId = null;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _loader = TodaySummaryLoader(
      backend: widget.backend,
      hc: widget.healthConnectService,
      planStore: widget.planStore,
      cache: widget.summaryCache,
      sessionStore: widget.sessionStore,
    );
    _ownsMigraine = widget.migraineController == null;
    _migraine = widget.migraineController ??
        MigraineController.production(backend: widget.backend);
    _migraine.addListener(_onMigraineChanged);
    unawaited(_migraine.initialize());
    _syncMigraineTimer();
    // First frame: the in-memory last-known snapshot for this account
    // + day, when one exists — values render instantly, then the
    // fresh load below swaps in quietly if it differs.
    _seedFromCache();
    unawaited(_load());
  }

  @override
  void dispose() {
    _sheetTick.dispose();
    _migraineTimer?.cancel();
    _migraine.removeListener(_onMigraineChanged);
    if (_ownsMigraine) _migraine.dispose();
    super.dispose();
  }

  void _onMigraineChanged() {
    if (!mounted) return;
    setState(() {});
    _syncMigraineTimer();
  }

  /// The 30s elapsed tick runs only while an attack is active.
  void _syncMigraineTimer() {
    if (_migraine.isActive) {
      _migraineTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {
        if (!mounted) return;
        setState(() {});
        unawaited(_migraine.refreshNotification());
      });
    } else {
      _migraineTimer?.cancel();
      _migraineTimer = null;
    }
  }

  Future<void> _seedFromCache() async {
    try {
      final email = await (widget.sessionStore ?? SessionStore())
          .readEmail();
      if (!mounted) return;
      final snap = (widget.summaryCache ?? TodaySummaryCache.instance)
          .snapshot(email: email, todayStr: dateStrOf(DateTime.now()));
      if (snap != null && _data == null) {
        setState(() {
          _data = TodaySummaryData(
              plan: snap.plan, trends: snap.trends, fromCache: true);
        });
      }
    } catch (_) {
      // Cache seeding is best-effort; the live load follows anyway.
    }
  }

  /// Two-phase load, mirroring native's independent flows: the plan
  /// (subtitle + rows) lands as soon as the sync pull resolves, then
  /// the trends phase swaps in the live Health Connect comparisons
  /// whenever they land. Neither phase blocks the other, and a
  /// failed phase leaves the other phase's values untouched.
  Future<void> _load({bool includeTrends = true}) async {
    final data = await _loader.loadPlan();
    if (!mounted) return;
    setState(() {
      _data = TodaySummaryData(
        plan: data.plan,
        trends: _data?.trends ?? data.trends,
        fromCache: data.fromCache,
        pullSucceeded: data.pullSucceeded,
      );
    });
    if (includeTrends) {
      final trends = await _loader.loadLiveTrends();
      if (!mounted) return;
      setState(() {
        final current = _data;
        if (current != null) {
          _data = TodaySummaryData(
            plan: current.plan,
            trends: trends.isNotEmpty ? trends : current.trends,
            fromCache: current.fromCache,
            pullSucceeded: current.pullSucceeded,
          );
        }
      });
    }
  }

  Future<void> _refreshTrends() async {
    if (_trendsRefreshing) return;
    setState(() => _trendsRefreshing = true);
    final trends = await _loader.refreshTrends();
    if (!mounted) return;
    setState(() {
      _trendsRefreshing = false;
      final current = _data;
      if (current != null) {
        _data = TodaySummaryData(
          plan: current.plan,
          // Native keeps the previous items when a refresh produces
          // nothing (it marks them stale); never blank out on a blip.
          trends: trends.isNotEmpty ? trends : current.trends,
          fromCache: current.fromCache,
          pullSucceeded: current.pullSucceeded,
        );
      }
    });
  }

  /// Home redesign — the card tap opens the summary sheet, hosted
  /// BY this state so the sheet shares [_loader], the serialized
  /// [_actionChain], the optimistic exit machinery, and the
  /// reconciling reload (a second loader would risk the documented
  /// entry-id collision and would never refresh the card behind).
  Future<void> _openSheet() async {
    if (_sheetOpen) return;
    _sheetOpen = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: NotelColors.surface,
        isScrollControlled: true,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (sheetContext) {
          // Max height ~80% of the screen, read from the SHEET
          // route's own context (the overlay's MediaQuery always
          // carries the real size; the card's context may sit under
          // a partial MediaQuery override in tests).
          final maxHeight = MediaQuery.of(sheetContext).size.height * 0.8;
          return AnimatedBuilder(
            animation: _sheetTick,
            builder: (context, _) => ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: _sheetContent(context),
            ),
          );
        },
      );
    } finally {
      _sheetOpen = false;
    }
  }

  String get _subtitle => _migraine.isActive
      ? 'Migraine attack · '
          '${formatElapsedDuration(_migraine.elapsedMinutes())}'
      : (_data?.plan.summaryText ?? '');

  /// The sheet's content (rebuilt whenever [_sheetTick] bumps, which
  /// the [setState] override schedules after every card setState
  /// while the sheet is open — so plan actions and the check-in swap
  /// are reflected here and the card behind stays current too).
  Widget _sheetContent(BuildContext context) {
    final data = _data;
    final visibleItems = (data?.plan.items ?? const <TodayPlanItem>[])
        .where((i) => !_goneItemIds.contains(i.id))
        .toList();
    final exiting = _exitingItem;
    final planRows = <Widget>[];
    if (data != null) {
      Widget slideSlot() => _SlideAwayRowSlot(
            key: _exitSlotKey,
            onGone: () => _onExitGone(_exitingItemId!),
            child: _PlanItemRow(
              item: exiting!,
              busy: true,
              onToggle: () {},
              onMedAction: (_) {},
            ),
          );
      for (var idx = 0; idx < visibleItems.length; idx++) {
        if (exiting != null && idx == _exitingIndex) {
          planRows.add(slideSlot());
        }
        final item = visibleItems[idx];
        planRows.add(_PlanItemRow(
          item: item,
          busy: false,
          onToggle: () => _onToggleItem(item),
          onMedAction: (s) => _onMedAction(item, s),
        ));
      }
      if (exiting != null && _exitingIndex >= visibleItems.length) {
        planRows.add(slideSlot());
      }
    }
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Row(
                children: [
                  Icon(Icons.today, size: 20, color: NotelColors.primary),
                  SizedBox(width: 8),
                  Text(
                    'Today Summary',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: NotelColors.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                _subtitle,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: NotelColors.textSecondary,
                ),
              ),
              // Check-in section — hosted through Home's builder;
              // StatefulBuilder so the section re-reads the builder
              // when this sheet content rebuilds after a commit.
              if (widget.checkInBuilder != null) ...[
                const SizedBox(height: 12),
                StatefulBuilder(
                  builder: (context, setSheetState) =>
                      widget.checkInBuilder!(context),
                ),
              ],
              const SizedBox(height: 12),
              const Divider(color: NotelColors.divider, height: 1),
              const SizedBox(height: 12),
              MigraineBlock(
                controller: _migraine,
                onOpenLoggedEntry: _openLoggedEntry,
              ),
              const SizedBox(height: 14),
              const Divider(color: NotelColors.divider, height: 1),
              const SizedBox(height: 12),
              const Text(
                "Today's Plan",
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: NotelColors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              if (data == null || planRows.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Text(
                    data != null && data.plan.plannedCount > 0
                        ? 'Everything planned for today is complete'
                        : 'No plans recorded today',
                    style: const TextStyle(
                      fontSize: 12,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                )
              else
                ...planRows,
              const SizedBox(height: 14),
              const Divider(color: NotelColors.divider, height: 1),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Trends',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: NotelColors.textPrimary,
                    ),
                  ),
                  IconButton(
                    onPressed: _trendsRefreshing
                        ? null
                        : () => unawaited(_refreshTrends()),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    tooltip: 'Refresh Trends',
                    icon: const Icon(
                      Icons.refresh,
                      size: 16,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (data == null || data.trends.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4.0),
                  child: Text(
                    'Not enough data yet',
                    style: TextStyle(
                      fontSize: 12,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                )
              else
                for (final trend in data.trends) _TrendRow(trend: trend),
            ],
          ),
        ),
      ),
    );
  }

  /// Home redesign — the finish-line progress bar under the card's
  /// subtitle. Track = the card's divider tint family; fill =
  /// primary; the traveling marker is the Tabs logo
  /// (`assets/images/ic_tabs_note.png`, the splash/logo asset) in a
  /// 26dp circle at the fill's leading edge; the finish is the
  /// checkered flag in a 30dp circle at the right end. Changes
  /// animate over 220ms easeInOut (the allowed set); reduced
  /// motion renders the final state instantly. No data or
  /// plannedCount == 0 renders NO bar — never a fake 0.
  ///
  /// Flag legibility fix (Nov 10, 2026, founder report — the flag
  /// rendered see-through on the live build): the badge was
  /// primary at 18% alpha with the flag glyph in full primary, so
  /// the glyph's checker holes showed the 18% tint and the badge
  /// itself measured 1.25:1 against the card (sampled badge fill
  /// RGB 35,33,61 over the card). The badge is now SOLID primary
  /// and the glyph is [NotelColors.onPrimary] — the measured
  /// 5.21:1 ink-on-primary — so the checker reads dark squares on
  /// solid purple at full opacity in every progress state (the
  /// badge is state-independent; only the fill/marker move).
  /// Badge size (30dp) and position are unchanged.
  Widget _progressBar(BuildContext context) {
    final progress = _progress;
    if (progress == null) return const SizedBox.shrink();
    final disabled = animationsDisabled(context);
    return Padding(
      key: const ValueKey('todaySummaryProgressBar'),
      padding: const EdgeInsets.only(top: 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return SizedBox(
            height: 30,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: progress),
              duration:
                  disabled ? Duration.zero : const Duration(milliseconds: 220),
              curve: Curves.easeInOut,
              builder: (context, t, _) {
                final fillWidth = (width * t).clamp(0.0, width);
                final markerLeft = (fillWidth - 13).clamp(0.0, width - 26);
                return Stack(
                  alignment: Alignment.centerLeft,
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      child: Container(
                        key: const ValueKey('todaySummaryProgressTrack'),
                        height: 6,
                        decoration: BoxDecoration(
                          color: NotelColors.legacyDarkDivider,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      child: Container(
                        width: fillWidth,
                        height: 6,
                        decoration: BoxDecoration(
                          color: NotelColors.primary,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                    Positioned(
                      left: markerLeft,
                      child: Container(
                        key: const ValueKey('todaySummaryProgressMarker'),
                        width: 26,
                        height: 26,
                        decoration: const BoxDecoration(
                          color: NotelColors.surfaceHigh,
                          shape: BoxShape.circle,
                        ),
                        padding: const EdgeInsets.all(3),
                        child: Image.asset(
                          'assets/images/ic_tabs_note.png',
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                    Positioned(
                      right: 0,
                      child: Container(
                        key: const ValueKey('todaySummaryProgressFinish'),
                        width: 30,
                        height: 30,
                        decoration: const BoxDecoration(
                          color: NotelColors.primary,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.sports_score,
                          size: 18,
                          color: NotelColors.onPrimary,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }

  /// Migraine log trio fix 1 (Juno 2026-10-27 §A condition 3):
  /// the completion line's tap opens THAT attack's entry in
  /// History. HistoryScreen's initial load invalidates the
  /// sync-pull cache first (fix 2), so the entry is present on
  /// arrival, and [HistoryScreen.focusEntryId] opens it directly.
  /// Same SlidePageRoute pattern as Quick Log's history push.
  void _openLoggedEntry(int entryId) {
    Navigator.of(context).push(
      SlidePageRoute(
        reducedMotion: animationsDisabled(context),
        builder: (_) => HistoryScreen(
          backend: widget.backend,
          focusEntryId: entryId,
        ),
      ),
    );
  }

  /// The row's index in the CURRENTLY RENDERED list (plan items
  /// minus [_goneItemIds]) — the list the slide slot is inserted
  /// into at build time. Captured at tap time, so back-to-back
  /// exits slot correctly even while earlier rows are still
  /// sliding out.
  int _renderedIndexOf(TodayPlanItem item) {
    final visible = (_data?.plan.items ?? const <TodayPlanItem>[])
        .where((i) => !_goneItemIds.contains(i.id))
        .toList();
    final index = visible.indexOf(item);
    return index < 0 ? visible.length : index;
  }

  /// Queues one background write + its reconciling reload on the
  /// serialized [_actionChain]. The UI never waits on this: the
  /// caller has already started the slide. Errors are swallowed
  /// per link so one failure never wedges later writes.
  void _enqueueAction(Future<void> Function() write) {
    _actionChain = _actionChain.then((_) async {
      try {
        await write();
        await _load(includeTrends: false);
      } catch (_) {
        // A background write/reload failure must never wedge the
        // chain or surface as a crash; the next reconciling
        // reload (or the next mount's load) re-reads the truth.
      }
    });
  }

  /// Failure rollback for reminder/habit toggles: the optimistic
  /// exit is undone so the row honestly returns — no phantom
  /// completion. (Medication actions have no rollback: they
  /// return void and land device-locally first by design — the
  /// local dose record governs the plan.)
  void _restoreItem(TodayPlanItem item) {
    if (!mounted) return;
    setState(() {
      _goneItemIds.remove(item.id);
      if (_exitingItemId == item.id) {
        _exitingItem = null;
        _exitingItemId = null;
      }
    });
  }

  void _onToggleItem(TodayPlanItem item) {
    // Per-item idempotency (replaces the pre-fix global acting
    // lock): a tap on an item already exiting or gone is a no-op;
    // taps on OTHER rows always register, instantly.
    if (_goneItemIds.contains(item.id) || _exitingItemId == item.id) {
      return;
    }
    if (item.kind == PlanItemKind.medication) {
      return; // Meds use the Take/Skip controls, not a toggle.
    }
    // Round 41: rendered rows are never completed, so a toggle is
    // always a check-off. Optimistic order (Nov 2, 2026 fix):
    // slide FIRST, the same frame as the tap; the write runs in
    // the background through the serialized chain, then the
    // reconciling reload. A write that returns false restores
    // the row — no slide-and-stay, no phantom completion.
    _slideOrVanish(item, _renderedIndexOf(item));
    _enqueueAction(() async {
      final ok = switch (item.kind) {
        PlanItemKind.reminder =>
          await _loader.setReminderCompleted(item, true),
        PlanItemKind.habit =>
          await _loader.setHabitCompleted(item, true),
        PlanItemKind.medication => true, // unreachable (guard above)
      };
      if (!ok) _restoreItem(item);
    });
  }

  void _onMedAction(TodayPlanItem item, DoseStatus status) {
    // Per-item idempotency, as in _onToggleItem.
    if (_goneItemIds.contains(item.id) || _exitingItemId == item.id) {
      return;
    }
    // Only Take/Skip render on a plan row (Round 41 removed the
    // completed row and its Undo) — both resolve the dose, so the
    // row slides away. Optimistic order (Nov 2, 2026 fix): slide
    // FIRST, the same frame as the tap; the write + reconciling
    // reload run in the background through the serialized chain.
    // No rollback for meds: the loader records the action
    // device-locally first by design, and that local record is
    // what governs the plan.
    _slideOrVanish(item, _renderedIndexOf(item));
    _enqueueAction(() => _loader.setMedicationAction(item, status));
  }

  @override
  Widget build(BuildContext context) {
    // Home redesign — while the sheet is open, every rebuild of
    // this card (its own reloads AND Home's rebuilds above it —
    // Home settling after a check-in commit rebuilds this card
    // through the column) re-reads the sheet's hosted sections
    // one frame later. The setState-driven tick alone raced
    // Home's longer feeling-reload path (an edit-sheet delete
    // settles in Home AFTER this card's last reload), leaving
    // the sheet's check-in section stale; keying off build()
    // covers both orders because the section builder reads
    // Home's CURRENT state whenever it runs.
    if (_sheetOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_sheetOpen && mounted) _sheetTick.value++;
      });
    }
    // The card face is header + subtitle + the
    // finish-line progress bar ONLY. It never expands in place;
    // tapping it (or the chevron, a second tap target) opens the
    // summary sheet (see [_openSheet]).
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: NotelColors.legacyDarkDivider, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header row: the tappable title region (48dp min
            // height, opens the sheet) and — as a SIBLING outside
            // the InkWell, so its gesture wins inside its own
            // bounds — the trailing widget (Home's weather
            // element). The header chevron is dropped: the whole
            // card tap opens the sheet, so it was a duplicate.
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      onTap: () => unawaited(_openSheet()),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Row(
                              children: [
                                Icon(
                                  Icons.today,
                                  size: 20,
                                  color: NotelColors.primary,
                                ),
                                SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    'Today Summary',
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: NotelColors.textPrimary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _subtitle,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: NotelColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (widget.headerTrailing != null) widget.headerTrailing!,
              ],
            ),
            // Round 4 scored line (Part C): the day's recorded
            // check-in, flat on the card face under the header row.
            // Round 5: display-only — no tap target (see the field
            // doc); the line is a sibling of the header's
            // sheet-opening region and a tap here lands on nothing.
            if (widget.checkInScoredLine != null) ...[
              const SizedBox(height: 2),
              Semantics(
                label: widget.checkInScoredSemantics,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 40),
                  child: Row(
                    key: const ValueKey('todaySummaryCheckInLine'),
                    children: [
                      // Juno reconciliation Q2 (Nov 10, 2026):
                      // NO icon on the face line — a check glyph
                      // here would read as a completed plan item
                      // (Condition 3 presentation). Flat
                      // secondary text, the subtitle's own
                      // style; the Item 7.2 semantics sentence
                      // is descriptive only (round 5).
                      Flexible(
                        child: Text(
                          widget.checkInScoredLine!,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: NotelColors.textSecondary,
                          ),
                        ),
                      ),
                      // Item 11 announcement live region
                      // (zero-size, never visible), mirroring
                      // CheckInSummaryCard.
                      if (widget.checkInAnnouncement != null)
                        Semantics(
                          liveRegion: true,
                          label: widget.checkInAnnouncement,
                          child: const SizedBox.shrink(),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            _progressBar(context),
          ],
        ),
      ),
    );
  }
}
/// One plan row — native's per-type layout. Round 41: only OPEN
/// items ever render (completed/resolved items are excluded from
/// the plan data), so there is no dimmed/struck-through state and
/// no Undo affordance here:
/// - reminder/habit: a toggle button (unchecked circle; Round 49:
///   48dp hit area, glyph unchanged);
/// - medication: a status icon, "{dose} · {slot}" line, and the
///   Take/Skip buttons (a pending or snoozed dose).
class _PlanItemRow extends StatelessWidget {
  final TodayPlanItem item;
  final bool busy;
  final VoidCallback onToggle;
  final void Function(DoseStatus status) onMedAction;

  const _PlanItemRow({
    required this.item,
    required this.busy,
    required this.onToggle,
    required this.onMedAction,
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final overdue = item.isOverdue(now);
    final isMed = item.kind == PlanItemKind.medication;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4.0),
      decoration: BoxDecoration(
        color: NotelColors.surfaceHigh,
        borderRadius: BorderRadius.circular(10),
        border: overdue
            ? Border.all(
                color: NotelColors.error.withValues(alpha: 0.5), width: 1)
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.all(10.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (isMed) ...[
              Icon(
                item.status == DoseStatus.snoozed
                    ? Icons.access_time
                    : Icons.radio_button_unchecked,
                size: 18,
                color: item.status == DoseStatus.snoozed
                    ? const Color(0xFFFFA500)
                    : overdue
                        ? NotelColors.error
                        : NotelColors.textSecondary,
              ),
              const SizedBox(width: 10),
            ] else ...[
              IconButton(
                onPressed: busy ? null : onToggle,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 48,
                  minHeight: 48,
                ),
                tooltip: 'Mark complete',
                icon: const Icon(
                  Icons.radio_button_unchecked,
                  size: 18,
                  color: NotelColors.textSecondary,
                ),
              ),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.title,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: NotelColors.textPrimary,
                          ),
                        ),
                      ),
                      if (overdue)
                        const Padding(
                          padding: EdgeInsets.only(right: 8.0),
                          child: Text(
                            'Overdue',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: NotelColors.error,
                            ),
                          ),
                        ),
                    ],
                  ),
                  Text(
                    isMed
                        ? '${item.dose} · ${item.timeDisplay}'
                        : item.timeDisplay,
                    style: const TextStyle(
                      fontSize: 11,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (isMed) ...[
              const SizedBox(width: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Round 49 (audit H3): the hit area is 48dp, but the
                  // tinted disc stays the original 32dp visual — so the
                  // disc is painted behind a transparent IconButton
                  // instead of as the button's own background (which
                  // would have grown to 48dp with the button).
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color:
                                NotelColors.primary.withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                          ),
                        ),
                        IconButton(
                          onPressed: busy
                              ? null
                              : () => onMedAction(DoseStatus.taken),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 48,
                            minHeight: 48,
                          ),
                          tooltip: 'Take Medication',
                          style: IconButton.styleFrom(
                            foregroundColor: NotelColors.primary,
                          ),
                          icon: const Icon(Icons.check, size: 16),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    onPressed:
                        busy ? null : () => onMedAction(DoseStatus.skipped),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    tooltip: 'Skip Medication',
                    icon: const Icon(
                      Icons.block,
                      size: 16,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The checked-off row's exit slot: holds the row's position in
/// the list while the row slides out to the right and its height
/// collapses, so the rows below settle up smoothly. One transition
/// drives both: 300ms (the app's standard slide duration,
/// slide_page_route.dart) — the slide uses Curves.easeIn (the app's
/// exit curve for slides: "easeOut in / easeIn back") and the
/// height collapse uses Curves.easeInOut (the card's own
/// expand/collapse curve). No bounce, no spring. [finalizeNow] ends
/// it instantly (a second check-off supersedes it) — presentation
/// only: the superseded check-off's write is already queued on
/// the serialized background chain, so ending early loses nothing.
class _SlideAwayRowSlot extends StatefulWidget {
  final Widget child;
  final VoidCallback onGone;

  const _SlideAwayRowSlot({
    super.key,
    required this.child,
    required this.onGone,
  });

  @override
  State<_SlideAwayRowSlot> createState() => _SlideAwayRowSlotState();
}

class _SlideAwayRowSlotState extends State<_SlideAwayRowSlot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: Offset.zero,
    end: const Offset(1, 0),
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeIn));
  late final Animation<double> _size = Tween<double>(
    begin: 1,
    end: 0,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) finalizeNow();
    });
    _controller.forward();
  }

  /// Ends the slide-away immediately (superseded by a newer
  /// check-off). Idempotent.
  void finalizeNow() {
    if (_gone) return;
    _gone = true;
    _controller.stop();
    widget.onGone();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      key: const Key('slide-away-slot'),
      sizeFactor: _size,
      alignment: Alignment.topCenter,
      child: ClipRect(
        child: SlideTransition(
          key: const Key('slide-away-transition'),
          position: _slide,
          child: widget.child,
        ),
      ),
    );
  }
}

/// One trend row — native renders metric name + data source on the
/// first line and the difference text beneath (the current/comparison
/// period strings exist in the data but native's card doesn't show
/// them; parity keeps it that way).
class _TrendRow extends StatelessWidget {
  final TrendComparison trend;

  const _TrendRow({required this.trend});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4.0),
      decoration: BoxDecoration(
        color: NotelColors.surfaceHigh,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: NotelColors.legacyDarkDivider, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    trend.metricName,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: NotelColors.textPrimary,
                    ),
                  ),
                ),
                Text(
                  trend.dataSource,
                  style: const TextStyle(
                    fontSize: 10,
                    color: NotelColors.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              trend.differenceText,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: NotelColors.primaryText,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
