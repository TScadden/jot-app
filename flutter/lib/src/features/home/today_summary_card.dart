import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
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
/// - Check-off "snap" dissolve (founder directive, R35 fix pass —
///   native has NO per-item check-off exit animation; its only
///   AnimatedVisibility wraps the whole expanded section,
///   TodayScreen.kt:550-554, and completed items stay visible at
///   0.5 alpha): checking an item off IN THIS CARD dusts it — the
///   row is snapshotted (RepaintBoundary), sampled into a bounded
///   particle grid in the row's own colors, and disintegrates with
///   an upward/rightward drift while its footprint is held; then
///   the gap closes smoothly and the item is gone from this card
///   instance's view. Presentation only: the check-off persists
///   through the exact same loader writes as before, BEFORE the
///   dissolve starts, so navigating away mid-dust never loses it.
///   Items already completed when the data loads keep the existing
///   display rule (dimmed, struck through, med Undo available) —
///   only in-session check-offs leave the view. Reduced motion
///   (animationsDisabled) removes the item instantly, no particles.
///   Section rule (founder): the card auto-collapses ONLY when a
///   check-off removes the LAST remaining plan item, and only after
///   the dissolve finishes; otherwise the section stays open.
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

  /// Dust dissolve state (see the class doc). At most one row dusts
  /// at a time; a second check-off finalizes the active dust
  /// instantly before its own dissolve begins.
  final Set<String> _goneItemIds = <String>{};
  final Map<String, GlobalKey> _rowKeys = <String, GlobalKey>{};
  String? _dustItemId;
  ui.Image? _dustImage;
  double _dustHeight = 0;
  final GlobalKey<_DustRowSlotState> _dustSlotKey =
      GlobalKey<_DustRowSlotState>();

  GlobalKey _rowKeyFor(String itemId) =>
      _rowKeys.putIfAbsent(itemId, () => GlobalKey());

  /// Snapshots the row for [itemId] as currently painted (the
  /// pre-check-off appearance). Best-effort: null when the row is
  /// not mounted/painted — the caller then removes the item
  /// instantly instead of dusting it.
  Future<({ui.Image image, double height})?> _captureRow(
      String itemId) async {
    try {
      final ro = _rowKeyFor(itemId).currentContext?.findRenderObject();
      if (ro is! RenderRepaintBoundary || !ro.attached) return null;
      // The tap lands mid-frame: the boundary is usually still
      // marked needs-paint, and toImage asserts against capturing
      // an unpainted layer. Wait out the current frame — the busy
      // state the handler sets next doesn't change the row's
      // appearance, so the snapshot still shows the row exactly
      // as the user saw it when they tapped.
      await SchedulerBinding.instance.endOfFrame;
      if (!ro.attached) return null;
      final height = ro.size.height;
      final image = await ro.toImage(pixelRatio: 1.0);
      return (image: image, height: height);
    } catch (_) {
      return null;
    }
  }

  /// Post-persist step of a check-off: dust the row, or remove it
  /// instantly when reduced motion is on or the snapshot failed.
  /// The write has ALREADY landed when this runs — presentation
  /// only from here, so an unmount anywhere below loses nothing.
  Future<void> _dissolveOrVanish(
    String itemId,
    Future<({ui.Image image, double height})?>? capture,
  ) async {
    if (!mounted || _goneItemIds.contains(itemId)) return;
    if (!animationsDisabled(context) && capture != null) {
      final shot = await capture.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () => null,
      );
      if (!mounted || _goneItemIds.contains(itemId)) {
        shot?.image.dispose();
        return;
      }
      if (shot != null) {
        // One dust at a time: finalize the active one instantly.
        _dustSlotKey.currentState?.finalizeNow();
        setState(() {
          _dustItemId = itemId;
          _dustImage = shot.image;
          _dustHeight = shot.height;
        });
        return;
      }
    }
    _vanishItem(itemId);
  }

  /// Instant removal (reduced motion / no snapshot): the item
  /// leaves the view now, and the last-item collapse rule applies
  /// immediately.
  void _vanishItem(String itemId) {
    _dustSlotKey.currentState?.finalizeNow();
    if (!mounted) return;
    setState(() {
      _goneItemIds.add(itemId);
      if (_dustItemId == itemId) {
        _dustItemId = null;
        _dustImage?.dispose();
        _dustImage = null;
      }
    });
    _collapseIfLastRemoved(itemId);
  }

  /// Slot callback: the dissolve + gap-close finished.
  void _onDustGone(String itemId) {
    if (!mounted) return;
    setState(() {
      _goneItemIds.add(itemId);
      if (_dustItemId == itemId) {
        _dustItemId = null;
        _dustImage?.dispose();
        _dustImage = null;
      }
    });
    _collapseIfLastRemoved(itemId);
  }

  /// Founder section rule: auto-collapse ONLY when a check-off has
  /// removed the last remaining plan item. Any items left — visible
  /// or still dusting — keep the section exactly as open as it was.
  void _collapseIfLastRemoved(String removedId) {
    if (!mounted || !_expanded) return;
    final items = _data?.plan.items ?? const <TodayPlanItem>[];
    if (items.isEmpty) return;
    final remaining = items
        .where((i) =>
            i.id != removedId &&
            !_goneItemIds.contains(i.id) &&
            i.id != _dustItemId)
        .length;
    if (remaining == 0) setState(() => _expanded = false);
  }

  @override
  void dispose() {
    _dustImage?.dispose();
    super.dispose();
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
    // Checking OFF (un-completing) keeps the row — only a check-off
    // dissolves. The snapshot is taken NOW, while the row is still
    // painted in its pre-check-off state; the persist below does
    // not wait for it.
    final checkingOff = !item.isCompleted;
    final capture = checkingOff && !animationsDisabled(context)
        ? _captureRow(item.id)
        : null;
    setState(() => _actingItemId = item.id);
    try {
      switch (item.kind) {
        case PlanItemKind.reminder:
          await _loader.setReminderCompleted(item, !item.isCompleted);
        case PlanItemKind.habit:
          await _loader.setHabitCompleted(item, !item.isCompleted);
        case PlanItemKind.medication:
          return; // Meds use the Take/Skip/Undo controls, not a toggle.
      }
      await _load(includeTrends: false);
    } finally {
      if (mounted) setState(() => _actingItemId = null);
    }
    // The write has landed and the one-action guard is released —
    // the dissolve is pure presentation from here and can never
    // block or double-fire an action.
    if (checkingOff) await _dissolveOrVanish(item.id, capture);
  }

  Future<void> _onMedAction(TodayPlanItem item, DoseStatus status) async {
    if (_actingItemId != null) return;
    // Take/Skip resolve the dose — a check-off, so the row dusts.
    // Undo (back to pending) keeps the row.
    final resolving =
        status == DoseStatus.taken || status == DoseStatus.skipped;
    final capture = resolving && !animationsDisabled(context)
        ? _captureRow(item.id)
        : null;
    setState(() => _actingItemId = item.id);
    try {
      await _loader.setMedicationAction(item, status);
      await _load(includeTrends: false);
    } finally {
      if (mounted) setState(() => _actingItemId = null);
    }
    if (resolving) await _dissolveOrVanish(item.id, capture);
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    // Before the first load lands (and with no cache to seed from)
    // the header matches native's initial state: empty subtitle,
    // plan/trends unresolved. It resolves within the first load.
    final subtitle = data?.plan.summaryText ?? '';
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
                            color: Color(0x14FFFFFF), // White @ 8%
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
                          if (data == null || data.plan.items.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 6.0),
                              child: Text(
                                'No plans recorded today',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: NotelColors.textSecondary,
                                ),
                              ),
                            )
                          else
                            for (final item in data.plan.items
                                .where((i) => !_goneItemIds.contains(i.id)))
                              if (item.id == _dustItemId &&
                                  _dustImage != null)
                                _DustRowSlot(
                                  key: _dustSlotKey,
                                  image: _dustImage!,
                                  height: _dustHeight,
                                  onGone: () => _onDustGone(item.id),
                                )
                              else
                                RepaintBoundary(
                                  key: _rowKeyFor(item.id),
                                  child: _PlanItemRow(
                                    item: item,
                                    busy: _actingItemId == item.id,
                                    onToggle: () => _onToggleItem(item),
                                    onMedAction: (s) =>
                                        _onMedAction(item, s),
                                  ),
                                ),
                          const SizedBox(height: 14),
                          const Divider(
                            color: Color(0x14FFFFFF), // White @ 8%
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
                              SizedBox(
                                width: 24,
                                height: 24,
                                child: IconButton(
                                  onPressed: _trendsRefreshing
                                      ? null
                                      : () => unawaited(_refreshTrends()),
                                  padding: EdgeInsets.zero,
                                  tooltip: 'Refresh Trends',
                                  icon: const Icon(
                                    Icons.refresh,
                                    size: 14,
                                    color: NotelColors.textSecondary,
                                  ),
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

/// One plan row — native's per-type layout:
/// - reminder/habit: a 32dp toggle button (check-circle when done);
/// - medication: a status icon, "{dose} · {slot}" line, and the
///   Take/Skip buttons while pending (status text + Undo once acted).
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
    final alpha = item.isCompleted ? 0.5 : 1.0;
    final isMed = item.kind == PlanItemKind.medication;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3.0),
      decoration: BoxDecoration(
        color: NotelColors.surfaceHigh.withValues(alpha: alpha),
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
                switch (item.status) {
                  DoseStatus.taken => Icons.check_circle,
                  DoseStatus.skipped => Icons.block,
                  DoseStatus.snoozed => Icons.access_time,
                  DoseStatus.pending => Icons.radio_button_unchecked,
                },
                size: 18,
                color: switch (item.status) {
                  DoseStatus.taken => NotelColors.primary,
                  DoseStatus.skipped => NotelColors.textSecondary,
                  DoseStatus.snoozed => const Color(0xFFFFA500),
                  DoseStatus.pending =>
                    overdue ? NotelColors.error : NotelColors.textSecondary,
                },
              ),
              const SizedBox(width: 10),
            ] else ...[
              SizedBox(
                width: 32,
                height: 32,
                child: IconButton(
                  onPressed: busy ? null : onToggle,
                  padding: EdgeInsets.zero,
                  tooltip: item.isCompleted ? 'Completed' : 'Mark complete',
                  icon: Icon(
                    item.isCompleted
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 18,
                    color: item.isCompleted
                        ? NotelColors.primary
                        : NotelColors.textSecondary,
                  ),
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
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: item.isCompleted
                                ? FontWeight.normal
                                : FontWeight.w500,
                            color: NotelColors.textPrimary
                                .withValues(alpha: alpha),
                            decoration: item.isCompleted
                                ? TextDecoration.lineThrough
                                : TextDecoration.none,
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
                    style: TextStyle(
                      fontSize: 11,
                      color:
                          NotelColors.textSecondary.withValues(alpha: alpha),
                    ),
                  ),
                ],
              ),
            ),
            if (isMed) ...[
              const SizedBox(width: 8),
              if (item.status == DoseStatus.pending ||
                  item.status == DoseStatus.snoozed)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: IconButton(
                        onPressed:
                            busy ? null : () => onMedAction(DoseStatus.taken),
                        padding: EdgeInsets.zero,
                        tooltip: 'Take Medication',
                        style: IconButton.styleFrom(
                          backgroundColor:
                              NotelColors.primary.withValues(alpha: 0.15),
                          foregroundColor: NotelColors.primary,
                        ),
                        icon: const Icon(Icons.check, size: 16),
                      ),
                    ),
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: IconButton(
                        onPressed: busy
                            ? null
                            : () => onMedAction(DoseStatus.skipped),
                        padding: EdgeInsets.zero,
                        tooltip: 'Skip Medication',
                        icon: const Icon(
                          Icons.block,
                          size: 16,
                          color: NotelColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                )
              else
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.status == DoseStatus.taken ? 'Taken' : 'Skipped',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: item.status == DoseStatus.taken
                            ? NotelColors.primary
                            : NotelColors.textSecondary,
                      ),
                    ),
                    SizedBox(
                      width: 28,
                      height: 28,
                      child: IconButton(
                        onPressed: busy
                            ? null
                            : () => onMedAction(DoseStatus.pending),
                        padding: EdgeInsets.zero,
                        tooltip: 'Undo action',
                        icon: const Icon(
                          Icons.undo,
                          size: 14,
                          color: NotelColors.textSecondary,
                        ),
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

/// One dust particle sampled from the row snapshot: a cell of the
/// row, in the row's own color, with a randomized gentle
/// upward/rightward drift.
class _DustParticle {
  final Offset origin;
  final Color color;
  final Offset drift; // total displacement over its active phase
  final double size;
  final double delay; // 0..~0.38 — the disintegration sweeps L→R

  const _DustParticle({
    required this.origin,
    required this.color,
    required this.drift,
    required this.size,
    required this.delay,
  });
}

/// Samples [image]'s pixels into a bounded particle grid (cell
/// grows until the count fits the cap, so a wide row stays smooth
/// on device). Fully transparent cells (the row's rounded corners)
/// are skipped. Deterministic seed — the founder's rows should
/// dust the same way every time, and tests stay stable.
List<_DustParticle> _buildDustParticles(ui.Image image, ByteData rgba) {
  final w = image.width;
  final h = image.height;
  if (w <= 0 || h <= 0) return const [];
  final bytes =
      rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes);
  var cell = 6;
  while ((w / cell).ceil() * (h / cell).ceil() > 640 && cell < 24) {
    cell += 2;
  }
  final rand = math.Random(0x5eed);
  final out = <_DustParticle>[];
  for (var y = 0; y < h; y += cell) {
    for (var x = 0; x < w; x += cell) {
      final cx = math.min(x + cell ~/ 2, w - 1);
      final cy = math.min(y + cell ~/ 2, h - 1);
      final i = (cy * w + cx) * 4;
      if (i + 3 >= bytes.length) continue;
      final a = bytes[i + 3];
      if (a < 24) continue;
      out.add(_DustParticle(
        origin: Offset(cx.toDouble(), cy.toDouble()),
        color: Color.fromARGB(a, bytes[i], bytes[i + 1], bytes[i + 2]),
        drift: Offset(
          10 + rand.nextDouble() * 48,
          -(14 + rand.nextDouble() * 46),
        ),
        size: math.max(2.0, cell * (0.55 + rand.nextDouble() * 0.5)),
        delay: 0.30 * (cx / w) + rand.nextDouble() * 0.08,
      ));
    }
  }
  return out;
}

class _DustPainter extends CustomPainter {
  final List<_DustParticle> particles;
  final Animation<double> progress;

  _DustPainter(this.particles, this.progress) : super(repaint: progress);

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    final paint = Paint();
    for (final p in particles) {
      final local =
          ((t - p.delay) / (1 - p.delay)).clamp(0.0, 1.0);
      final pos = p.origin +
          p.drift * local +
          Offset(0, -18 * local * local); // gentle lift as it thins
      final fade = math.pow(1 - local, 1.35).toDouble();
      paint.color = p.color.withValues(alpha: p.color.a * fade);
      final s = p.size * (1 - 0.5 * local);
      canvas.drawRect(
        Rect.fromCenter(center: pos, width: s, height: s),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DustPainter old) =>
      old.particles != particles;
}

/// The dissolving row's slot: holds the row's exact footprint
/// while the snapshot's particles disintegrate (~1.1s), then
/// collapses the gap smoothly (200ms) and reports [onGone].
/// [finalizeNow] ends it instantly (a second check-off supersedes
/// it) — the check-off itself was persisted before the slot ever
/// appeared, so ending early loses nothing.
class _DustRowSlot extends StatefulWidget {
  final ui.Image image;
  final double height;
  final VoidCallback onGone;

  const _DustRowSlot({
    super.key,
    required this.image,
    required this.height,
    required this.onGone,
  });

  @override
  State<_DustRowSlot> createState() => _DustRowSlotState();
}

class _DustRowSlotState extends State<_DustRowSlot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  List<_DustParticle>? _particles;
  bool _collapsing = false;
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted && !_gone) {
        setState(() => _collapsing = true);
      }
    });
    unawaited(_sample());
  }

  Future<void> _sample() async {
    try {
      final bd =
          await widget.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (!mounted) return;
      if (bd == null) {
        finalizeNow();
        return;
      }
      setState(() => _particles = _buildDustParticles(widget.image, bd));
      _controller.forward();
    } catch (_) {
      if (mounted) finalizeNow();
    }
  }

  /// Ends the dissolve immediately (superseded by a newer
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
    final particles = _particles;
    return AnimatedContainer(
      key: const Key('dust-slot'),
      height: _collapsing ? 0 : widget.height,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      onEnd: finalizeNow,
      child: particles == null
          // Still sampling the snapshot: the row itself stays on
          // screen (as its captured image) so the footprint never
          // flashes empty before the dust starts.
          ? SizedBox.expand(
              child: RawImage(image: widget.image, fit: BoxFit.fill),
            )
          : SizedBox.expand(
              child: CustomPaint(
                key: const Key('dust-particles'),
                painter: _DustPainter(particles, _controller),
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
                color: NotelColors.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
