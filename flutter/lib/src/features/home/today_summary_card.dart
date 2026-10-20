import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/session_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

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
/// - No optimistic flips: rows render from loaded data only, and an
///   action reloads quietly in the background (no spinner, no
///   count-up replay — there are no animated numbers in this card).
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
///   gone from this card instance's view. Presentation only: the
///   check-off persists through the exact same loader writes as
///   before, BEFORE the slide starts, so navigating away
///   mid-slide never loses it. Reduced motion
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
///   check-off already excludes the item, the dissolve slot is
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

  const TodaySummaryCard({
    super.key,
    this.backend,
    this.healthConnectService,
    this.planStore,
    this.summaryCache,
    this.sessionStore,
  });

  @override
  State<TodaySummaryCard> createState() => _TodaySummaryCardState();
}

class _TodaySummaryCardState extends State<TodaySummaryCard> {
  late final TodaySummaryLoader _loader;

  // Founder rule: collapsed at every mount (see class doc).
  bool _expanded = false;

  TodaySummaryData? _data;
  bool _trendsRefreshing = false;

  /// One action at a time per row (native's writes are serialized by
  /// its view-model scope; a double-tap must not double-post).
  String? _actingItemId;

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
  final GlobalKey<_SlideAwayRowSlotState> _exitSlotKey =
      GlobalKey<_SlideAwayRowSlotState>();

  /// Post-persist step of a check-off: slide the row out (after
  /// persist), or remove it instantly when reduced motion is on.
  /// The write has ALREADY landed when this runs — presentation
  /// only from here, so an unmount anywhere below loses nothing.
  /// [index] is the row's position in the rendered list, captured
  /// before the write; the item is marked gone immediately so a
  /// stale plan that still carries it never double-renders it
  /// alongside its slide slot.
  void _slideOrVanish(TodayPlanItem item, int index) {
    if (!mounted || _goneItemIds.contains(item.id)) return;
    if (animationsDisabled(context)) {
      _vanishItem(item.id);
      return;
    }
    // One exit at a time: finalize the active one instantly.
    _exitSlotKey.currentState?.finalizeNow();
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
    _collapseIfLastRemoved(itemId);
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
    _collapseIfLastRemoved(itemId);
  }

  /// Founder section rule: auto-collapse ONLY when a check-off has
  /// removed the last remaining plan item. Any items left — visible
  /// or still sliding out — keep the section exactly as open as it
  /// was.
  /// Round 41: the reloaded plan already EXCLUDES the removed item,
  /// so an empty list is exactly the collapse case (the R35
  /// early-return on empty assumed the completed item still sat in
  /// the data).
  void _collapseIfLastRemoved(String removedId) {
    if (!mounted || !_expanded || _data == null) return;
    final items = _data!.plan.items;
    final remaining = items
        .where((i) =>
            i.id != removedId &&
            !_goneItemIds.contains(i.id) &&
            i.id != _exitingItemId)
        .length;
    if (remaining == 0) setState(() => _expanded = false);
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
    // First frame: the in-memory last-known snapshot for this account
    // + day, when one exists — values render instantly, then the
    // fresh load below swaps in quietly if it differs.
    _seedFromCache();
    unawaited(_load());
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

  void _toggle() => setState(() => _expanded = !_expanded);

  Future<void> _onToggleItem(TodayPlanItem item) async {
    if (_actingItemId != null) return;
    // Round 41: rendered rows are never completed, so a toggle is
    // always a check-off and always slides away on success. The
    // list index is captured NOW, while the row is still rendered;
    // the slide itself starts only after the write + reload land
    // (see _slideOrVanish).
    final index =
        (_data?.plan.items ?? const <TodayPlanItem>[]).indexOf(item);
    setState(() => _actingItemId = item.id);
    var ok = false;
    try {
      switch (item.kind) {
        case PlanItemKind.reminder:
          ok = await _loader.setReminderCompleted(item, true);
        case PlanItemKind.habit:
          ok = await _loader.setHabitCompleted(item, true);
        case PlanItemKind.medication:
          return; // Meds use the Take/Skip controls, not a toggle.
      }
      await _load(includeTrends: false);
    } finally {
      if (mounted) setState(() => _actingItemId = null);
    }
    // The write has landed and the one-action guard is released —
    // the slide is pure presentation from here and can never block
    // or double-fire an action. A FAILED write leaves the row
    // exactly as it was: no slide, no phantom completion.
    if (ok) _slideOrVanish(item, index);
  }

  Future<void> _onMedAction(TodayPlanItem item, DoseStatus status) async {
    if (_actingItemId != null) return;
    // Only Take/Skip render on a plan row (Round 41 removed the
    // completed row and its Undo) — both resolve the dose, so the
    // row slides away. The index is captured before the write;
    // the slide starts after the write + reload land.
    final index =
        (_data?.plan.items ?? const <TodayPlanItem>[]).indexOf(item);
    setState(() => _actingItemId = item.id);
    try {
      await _loader.setMedicationAction(item, status);
      await _load(includeTrends: false);
    } finally {
      if (mounted) setState(() => _actingItemId = null);
    }
    _slideOrVanish(item, index);
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    // Before the first load lands (and with no cache to seed from)
    // the header matches native's initial state: empty subtitle,
    // plan/trends unresolved. It resolves within the first load.
    final subtitle = data?.plan.summaryText ?? '';

    // Rendered plan rows (Round 41): the plan data already excludes
    // completed items; _goneItemIds additionally hides an item whose
    // check-off landed but whose reload served a stale plan. The
    // slide slot is INSERTED at the checked-off row's captured index
    // — the item itself is no longer in the data to substitute for.
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
          busy: _actingItemId == item.id,
          onToggle: () => _onToggleItem(item),
          onMedAction: (s) => _onMedAction(item, s),
        ));
      }
      if (exiting != null && _exitingIndex >= visibleItems.length) {
        planRows.add(slideSlot());
      }
    }
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
            // Header row (tappable, 48dp+ target).
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                onTap: _toggle,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Row(
                    children: [
                      Expanded(
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
                              subtitle,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: NotelColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: _toggle,
                        tooltip: _expanded
                            ? 'Collapse Today Summary'
                            : 'Expand Today Summary',
                        icon: Icon(
                          _expanded
                              ? Icons.keyboard_arrow_up
                              : Icons.keyboard_arrow_down,
                          size: 26,
                          color: NotelColors.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Expanded content: Today's Plan & Trends.
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeInOut,
              child: _expanded
                  ? Padding(
                      padding: const EdgeInsets.only(top: 12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Divider(
                            color: NotelColors.divider,
                            height: 1,
                          ),
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
                            // Zero rendered rows, two honest states
                            // (founder, Round 41): nothing was ever
                            // planned → the no-plans text; things
                            // were planned and all are done → the
                            // completed message, never a blank void.
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 8.0),
                              child: Text(
                                data != null && data.plan.plannedCount > 0
                                    ? 'Everything planned for today is '
                                        'complete'
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
                          const Divider(
                            color: NotelColors.divider,
                            height: 1,
                          ),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceBetween,
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
                            for (final trend in data.trends)
                              _TrendRow(trend: trend),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
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
/// it instantly (a second check-off supersedes it) — the check-off
/// itself was persisted before the slot ever appeared, so ending
/// early loses nothing.
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
      axisAlignment: -1,
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
