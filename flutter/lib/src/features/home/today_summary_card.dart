import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/session_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
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
  }

  Future<void> _onMedAction(TodayPlanItem item, DoseStatus status) async {
    if (_actingItemId != null) return;
    setState(() => _actingItemId = item.id);
    try {
      await _loader.setMedicationAction(item, status);
      await _load(includeTrends: false);
    } finally {
      if (mounted) setState(() => _actingItemId = null);
    }
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
                            for (final item in data.plan.items)
                              _PlanItemRow(
                                item: item,
                                busy: _actingItemId == item.id,
                                onToggle: () => _onToggleItem(item),
                                onMedAction: (s) => _onMedAction(item, s),
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
