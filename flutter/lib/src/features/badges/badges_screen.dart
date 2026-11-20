import 'dart:async';

import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/badge_engine.dart';
import 'package:tabs_lab/src/data/badge_store.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/features/badges/badge_strings.dart';
import 'package:tabs_lab/src/features/badges/badge_widget.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/slide_page_route.dart';
import 'package:tabs_lab/src/theme/animations.dart';

/// The per-metric tile icons (brief §3; Juno §11 for the sleep
/// pair). total_logs uses edit_note and logs_in_day menu_book —
/// the same note family as the design renderer's notebook glyph,
/// differentiated so the two Logging tiles scan apart at small
/// size; edit_note reads better small for the headline metric.
IconData badgeIconOf(String metricId) => switch (metricId) {
      'total_logs' => Icons.edit_note,
      'logs_in_day' => Icons.menu_book,
      'morning_logger' => Icons.wb_sunny,
      'day_streak' => Icons.local_fire_department,
      'perfect_weeks' => Icons.calendar_month,
      'freeze_saver' => Icons.ac_unit,
      'calories_month' => Icons.whatshot,
      'steps_day' => Icons.directions_walk,
      'active_week' => Icons.bolt,
      'nights_tracked' => Icons.bedtime,
      'sleep_week' => Icons.hotel,
      'early_to_bed' => Icons.nightlight,
      _ => Icons.star,
    };

/// Opens Health Connect settings — the same route the Settings
/// surface's button of the same name uses (Juno §9 rule 7).
Future<void> openBadgeHealthConnectSettings() async {
  try {
    await HealthConnectService().openHealthConnectSettings();
  } catch (_) {
    // The badges screen stays put; the blocked tiles keep their
    // ruled state line.
  }
}

/// The Badges collection screen (badges_screen_v3 mock): header,
/// summary card, and the four sections of 3 tiles across. All
/// copy is Juno's, via [BadgeStrings]; all state comes from
/// [BadgeService]'s snapshot — this screen never computes a rung.
class BadgesScreen extends StatefulWidget {
  final BadgeService? service;

  /// Fired on open (production: a forced settlement evaluation so
  /// the screen shows fresh progress). Fail-soft by contract.
  final Future<void> Function()? onRefresh;

  final Future<void> Function() onOpenHcSettings;

  const BadgesScreen({
    super.key,
    this.service,
    this.onRefresh,
    this.onOpenHcSettings = openBadgeHealthConnectSettings,
  });

  BadgeService get _service => service ?? BadgeService.instance;

  @override
  State<BadgesScreen> createState() => _BadgesScreenState();
}

class _BadgesScreenState extends State<BadgesScreen> {
  bool _permissionDismissed = false;

  @override
  void initState() {
    super.initState();
    final refresh = widget.onRefresh;
    if (refresh != null) unawaited(refresh());
  }

  BadgeService get _svc => widget._service;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: _svc,
          builder: (context, _) {
            final snap = _svc.snapshot;
            final blockedSections = <String>[
              for (final section in BadgeSections.order)
                if (BadgeMetrics.inSection(section)
                    .any((m) => snap.blockedMetrics.contains(m.id)))
                  section,
            ];
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
              children: [
                _header(context),
                const SizedBox(height: 16),
                _summaryCard(snap),
                for (final section in BadgeSections.order) ...[
                  if (!_permissionDismissed &&
                      blockedSections.isNotEmpty &&
                      section == blockedSections.first) ...[
                    const SizedBox(height: 16),
                    _permissionBlock(context, blockedSections),
                  ],
                  const SizedBox(height: 24),
                  _sectionHeader(snap, section),
                  const SizedBox(height: 8),
                  _sectionGrid(context, snap, section),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 48,
            height: 48,
            child: InkWell(
              key: const ValueKey('badges_back_button'),
              customBorder: const CircleBorder(),
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: NotelColors.surface,
                ),
                child: const Icon(
                  Icons.chevron_left,
                  size: 24,
                  color: NotelColors.textPrimary,
                ),
              ),
            ),
          ),
        ),
        const Column(
          children: [
            Text(
              BadgeStrings.screenTitle,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                color: NotelColors.textPrimary,
              ),
            ),
            SizedBox(height: 2),
            Text(
              BadgeStrings.screenSubtitle,
              style: TextStyle(
                fontSize: 12,
                color: NotelColors.textSecondary,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _summaryCard(BadgeSnapshot snap) {
    final top = _svc.topBadge;
    return Container(
      key: const ValueKey('badges_summary_card'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: NotelColors.legacyDarkDivider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (top != null)
            BadgeWidget(
              rungIndex: top.rungIndex,
              icon: badgeIconOf(top.metric.id),
              size: 72,
            )
          else
            const BadgeWidget(
              rungIndex: 0,
              icon: Icons.star,
              size: 72,
              locked: true,
            ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  BadgeStrings.earnedCount(snap.earnedBadgeCount),
                  key: const ValueKey('badges_earned_count'),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: NotelColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                if (top != null) ...[
                  const Text(
                    BadgeStrings.topBadgeLabel,
                    style: TextStyle(
                      fontSize: 12,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    BadgeStrings.topBadgeValue(
                      top.rungIndex,
                      BadgeStrings.badgeName(top.metric.id),
                    ),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: NotelColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    BadgeStrings.thresholdLine(
                      top.metric.id,
                      top.metric.thresholds[top.rungIndex],
                    ),
                    style: const TextStyle(
                      fontSize: 12,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                ] else ...[
                  const Text(
                    BadgeStrings.emptyHeadline,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: NotelColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    BadgeStrings.emptyBody,
                    style: TextStyle(
                      fontSize: 13,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _permissionBlock(
    BuildContext context,
    List<String> blockedSections,
  ) {
    return Container(
      key: const ValueKey('badges_permission_block'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NotelColors.legacyDarkDivider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            BadgeStrings.permissionTitle,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            BadgeStrings.permissionBody,
            style: TextStyle(
              fontSize: 13,
              color: NotelColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            BadgeStrings.permissionBlockedLabel,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: NotelColors.textPrimary,
            ),
          ),
          for (final section in blockedSections)
            Text(
              BadgeStrings.sectionName(section),
              style: const TextStyle(
                fontSize: 13,
                color: NotelColors.textPrimary,
              ),
            ),
          const SizedBox(height: 8),
          const Text(
            BadgeStrings.permissionGuidance,
            style: TextStyle(
              fontSize: 12,
              color: NotelColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  key: const ValueKey('badges_permission_open_settings'),
                  onPressed: () => unawaited(widget.onOpenHcSettings()),
                  style: FilledButton.styleFrom(
                    backgroundColor: NotelColors.primary,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(48, 48),
                  ),
                  child: const Text(
                    BadgeStrings.permissionPrimaryAction,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                key: const ValueKey('badges_permission_not_now'),
                onPressed: () =>
                    setState(() => _permissionDismissed = true),
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                ),
                child: const Text(BadgeStrings.permissionSecondaryAction),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(BadgeSnapshot snap, String section) {
    final earned = BadgeMetrics.inSection(section)
        .where((m) => snap.topRungOf(m.id) >= 0)
        .length;
    return Row(
      children: [
        Text(
          BadgeStrings.sectionName(section),
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
        const Spacer(),
        Text(
          BadgeStrings.sectionCount(earned),
          style: const TextStyle(
            fontSize: 12,
            color: NotelColors.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _sectionGrid(
    BuildContext context,
    BadgeSnapshot snap,
    String section,
  ) {
    final metrics = BadgeMetrics.inSection(section);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 0.55,
      ),
      itemCount: metrics.length,
      itemBuilder: (context, i) => _tile(context, snap, metrics[i]),
    );
  }

  Widget _tile(BuildContext context, BadgeSnapshot snap, BadgeMetric metric) {
    final name = BadgeStrings.badgeName(metric.id);
    final topRung = snap.topRungOf(metric.id);
    final blocked = snap.blockedMetrics.contains(metric.id);
    final earned = topRung >= 0;
    final maxed = topRung == 14;
    final shownRung = earned ? topRung : 0;
    final value = snap.values[metric.id];

    final String semantics;
    if (blocked) {
      semantics = BadgeStrings.tileSemanticsBlocked(name);
    } else if (earned) {
      semantics = BadgeStrings.tileSemanticsEarned(name, topRung);
    } else {
      semantics = BadgeStrings.tileSemanticsNotEarned(name);
    }

    return Semantics(
      label: semantics,
      button: true,
      child: InkWell(
        key: ValueKey('badge_tile_${metric.id}'),
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openDetail(context, metric),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          decoration: BoxDecoration(
            color: NotelColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: NotelColors.cardBorder),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              BadgeWidget(
                rungIndex: shownRung,
                icon: badgeIconOf(metric.id),
                size: 52,
                locked: !earned,
              ),
              const SizedBox(height: 6),
              Text(
                name,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: earned
                      ? NotelColors.textPrimary
                      : NotelColors.textSecondary,
                ),
              ),
              const SizedBox(height: 2),
              ..._tileStateLines(metric, topRung, blocked, maxed, value),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _tileStateLines(
    BadgeMetric metric,
    int topRung,
    bool blocked,
    bool maxed,
    int? value,
  ) {
    // Juno §9 rule 3: a blocked tile shows the name and the ruled
    // status line — nothing numeric, no bar, no §5 line.
    if (blocked) {
      return const [
        Text(
          BadgeStrings.permissionTileLine,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: NotelColors.textSecondary),
        ),
      ];
    }
    if (maxed) {
      return [
        Text(
          badgeRungName(topRung),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: BadgeWidget.tierTextColor(topRung),
          ),
        ),
        const Text(
          BadgeStrings.maxed,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: NotelColors.textSecondary),
        ),
      ];
    }
    final nextRung = topRung + 1;
    final nextThreshold = metric.thresholds[nextRung];
    final lines = <Widget>[];
    if (topRung >= 0) {
      lines.add(Text(
        badgeRungName(topRung),
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: BadgeWidget.tierTextColor(topRung),
        ),
      ));
    } else {
      // Not yet earned: Form B at the next rung's threshold.
      lines.add(Text(
        BadgeStrings.thresholdLine(metric.id, nextThreshold),
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 11,
          color: NotelColors.textSecondary,
        ),
      ));
    }
    // Progress toward the next rung, only on a verified value
    // (Juno §7 rule 7): Tabs metrics always have one; HC metrics
    // have one only after a verified read (granted-but-empty is a
    // true 0). Unknown values show no progress element at all.
    if (value != null) {
      lines.add(const SizedBox(height: 4));
      lines.add(ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(
          value: (value / nextThreshold).clamp(0.0, 1.0),
          minHeight: 5,
          backgroundColor: NotelColors.surfaceHigh,
          color: NotelColors.primary,
        ),
      ));
      lines.add(const SizedBox(height: 2));
      lines.add(Text(
        BadgeStrings.progressLine(value, nextThreshold),
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 10,
          color: NotelColors.textSecondary,
        ),
      ));
    }
    return lines;
  }

  void _openDetail(BuildContext context, BadgeMetric metric) {
    Navigator.of(context).push(
      SlidePageRoute(
        reducedMotion: animationsDisabled(context),
        builder: (_) => BadgeDetailScreen(
          metric: metric,
          service: _svc,
          onOpenHcSettings: widget.onOpenHcSettings,
        ),
      ),
    );
  }
}

/// The badge detail view: large badge, current rung (Form B
/// receipt), the Next rung block (Form A + progress + amount
/// remaining), and the full 15-rung ladder, reached rungs lit.
class BadgeDetailScreen extends StatelessWidget {
  final BadgeMetric metric;
  final BadgeService? service;
  final Future<void> Function() onOpenHcSettings;

  const BadgeDetailScreen({
    super.key,
    required this.metric,
    this.service,
    this.onOpenHcSettings = openBadgeHealthConnectSettings,
  });

  BadgeService get _svc => service ?? BadgeService.instance;

  @override
  Widget build(BuildContext context) {
    final name = BadgeStrings.badgeName(metric.id);
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        title: Text(
          name,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
        leading: IconButton(
          key: const ValueKey('badge_detail_back_button'),
          icon: const Icon(Icons.chevron_left,
              color: NotelColors.textPrimary, size: 24),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: _svc,
          builder: (context, _) {
            final snap = _svc.snapshot;
            final topRung = snap.topRungOf(metric.id);
            final blocked = snap.blockedMetrics.contains(metric.id);
            final earned = topRung >= 0;
            final maxed = topRung == 14;
            final value = snap.values[metric.id];
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
              children: [
                Center(
                  child: BadgeWidget(
                    rungIndex: earned ? topRung : 0,
                    icon: badgeIconOf(metric.id),
                    size: 120,
                    locked: !earned,
                  ),
                ),
                const SizedBox(height: 16),
                // Current-rung block (a recorded fact — it stays
                // even under a later permission block, Juno §9
                // rule 4).
                if (earned) ...[
                  Center(
                    child: Text(
                      badgeRungName(topRung),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: BadgeWidget.tierTextColor(topRung),
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Center(
                    child: Text(
                      BadgeStrings.thresholdLine(
                        metric.id,
                        metric.thresholds[topRung],
                      ),
                      style: const TextStyle(
                        fontSize: 13,
                        color: NotelColors.textSecondary,
                      ),
                    ),
                  ),
                ] else
                  const Center(
                    child: Text(
                      BadgeStrings.noRungsYet,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: NotelColors.textPrimary,
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                if (blocked)
                  // Juno §9 rule 3: the blocked detail shows the
                  // permission state instead of any progress element
                  // — the ladder (whose rows carry threshold lines)
                  // is a progress element, so it is hidden here too.
                  _detailPermissionBlock(context)
                else ...[
                  if (maxed)
                    // §6: Maxed stands in place of the Next rung
                    // block — no requirement, progress, or to-go
                    // line. The ladder below still renders.
                    const Center(
                      child: Text(
                        BadgeStrings.maxed,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: NotelColors.textPrimary,
                        ),
                      ),
                    )
                  else ...[
                    const Text(
                      BadgeStrings.nextRungHeading,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: NotelColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    badgeRungName(topRung + 1),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: BadgeWidget.tierTextColor(topRung + 1),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    BadgeStrings.requirementLine(
                      metric.id,
                      metric.thresholds[topRung + 1],
                    ),
                    style: const TextStyle(
                      fontSize: 13,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                  if (value != null) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: (value / metric.thresholds[topRung + 1])
                            .clamp(0.0, 1.0),
                        minHeight: 6,
                        backgroundColor: NotelColors.surfaceHigh,
                        color: NotelColors.primary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      BadgeStrings.progressLine(
                        value,
                        metric.thresholds[topRung + 1],
                      ),
                      style: const TextStyle(
                        fontSize: 12,
                        color: NotelColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      BadgeStrings.toGo(
                        metric.thresholds[topRung + 1] - value,
                      ),
                      style: const TextStyle(
                        fontSize: 12,
                        color: NotelColors.textSecondary,
                      ),
                    ),
                  ],
                  ],
                  const SizedBox(height: 24),
                  // The full ladder: reached rungs lit, the rest
                  // dimmed with the locked badge rendering. Shown
                  // for every non-blocked state, maxed included.
                  for (var rung = 14; rung >= 0; rung--)
                    _ladderRow(rung, reached: rung <= topRung),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _ladderRow(int rung, {required bool reached}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          BadgeWidget(
            rungIndex: rung,
            icon: badgeIconOf(metric.id),
            size: 36,
            locked: !reached,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              badgeRungName(rung),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: reached
                    ? BadgeWidget.tierTextColor(rung)
                    : NotelColors.textSecondary,
              ),
            ),
          ),
          Text(
            BadgeStrings.thresholdLine(metric.id, metric.thresholds[rung]),
            style: TextStyle(
              fontSize: 12,
              color: reached
                  ? NotelColors.textPrimary
                  : NotelColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailPermissionBlock(BuildContext context) {
    return Container(
      key: const ValueKey('badge_detail_permission_block'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NotelColors.legacyDarkDivider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            BadgeStrings.permissionTitle,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            BadgeStrings.permissionBody,
            style: TextStyle(fontSize: 13, color: NotelColors.textSecondary),
          ),
          const SizedBox(height: 8),
          const Text(
            BadgeStrings.permissionBlockedLabel,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: NotelColors.textPrimary,
            ),
          ),
          Text(
            BadgeStrings.sectionName(metric.section),
            style: const TextStyle(
              fontSize: 13,
              color: NotelColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            BadgeStrings.permissionGuidance,
            style: TextStyle(fontSize: 12, color: NotelColors.textSecondary),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () => unawaited(onOpenHcSettings()),
                  style: FilledButton.styleFrom(
                    backgroundColor: NotelColors.primary,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(48, 48),
                  ),
                  child: const Text(
                    BadgeStrings.permissionPrimaryAction,
                    style:
                        TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                style:
                    TextButton.styleFrom(minimumSize: const Size(48, 48)),
                child: const Text(BadgeStrings.permissionSecondaryAction),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The unlock dialog (Juno §8 layouts + §13 gem honesty): one
/// dialog per evaluation batch. Badge art only — no other
/// imagery anywhere in this feature.
class BadgeUnlockDialog extends StatelessWidget {
  final BadgeUnlockBatch batch;

  const BadgeUnlockDialog({super.key, required this.batch});

  @override
  Widget build(BuildContext context) {
    final grants = batch.grants;
    final grouped = grants.length >= 6;
    return AlertDialog(
      key: const ValueKey('badge_unlock_dialog'),
      backgroundColor: NotelColors.surface,
      surfaceTintColor: Colors.transparent,
      title: Text(
        grants.length == 1
            ? BadgeStrings.unlockTitleSingle
            : BadgeStrings.unlockTitlePlural,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: NotelColors.textPrimary,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: grouped ? _groupedLines() : _perRungLines(),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('badge_unlock_done'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(BadgeStrings.dismiss),
        ),
      ],
    );
  }

  List<Widget> _perRungLines() {
    final lines = <Widget>[];
    for (final g in batch.grants) {
      lines.add(_lineRow(
        g,
        BadgeStrings.unlockLine(
          BadgeStrings.badgeName(g.metric.id),
          g.rungIndex,
        ),
      ));
      // Vera C2: only a FRESH grant shows the +5 line — an
      // alreadyGranted rung was paid in a previous install and
      // the dialog must not suggest it paid again.
      if (g.paidFresh) {
        lines.add(const Padding(
          padding: EdgeInsets.only(left: 52, top: 2),
          child: Text(
            BadgeStrings.unlockGemsLine,
            style: TextStyle(fontSize: 12, color: NotelColors.textSecondary),
          ),
        ));
      }
    }
    if (batch.grants.length >= 2 && batch.freshPaidCount >= 1) {
      lines.add(const SizedBox(height: 8));
      lines.add(Text(
        BadgeStrings.unlockTotalLine(
          batch.freshPaidCount * badgeRungGemAmount,
        ),
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: NotelColors.textPrimary,
        ),
      ));
    }
    if (batch.anyPending) {
      lines.add(const SizedBox(height: 8));
      lines.add(const Text(
        BadgeStrings.pendingGemsFooter,
        style: TextStyle(fontSize: 12, color: NotelColors.textSecondary),
      ));
    }
    return lines;
  }

  List<Widget> _groupedLines() {
    final lines = <Widget>[];
    if (batch.isBackfill) {
      lines.add(Text(
        batch.includesHcBadge
            ? BadgeStrings.backfillIntroHc
            : BadgeStrings.backfillIntroTabs,
        style: const TextStyle(
          fontSize: 13,
          color: NotelColors.textSecondary,
        ),
      ));
      lines.add(const SizedBox(height: 8));
    }
    lines.add(Text(
      BadgeStrings.unlockCountLine(batch.grants.length),
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.bold,
        color: NotelColors.textPrimary,
      ),
    ));
    lines.add(const SizedBox(height: 8));
    // One line per badge at its highest batch rung, screen order.
    for (final metric in BadgeMetrics.all) {
      final mine = [
        for (final g in batch.grants)
          if (g.metric.id == metric.id) g,
      ];
      if (mine.isEmpty) continue;
      final highest = mine
          .map((g) => g.rungIndex)
          .reduce((a, b) => b > a ? b : a);
      final representative =
          mine.firstWhere((g) => g.rungIndex == highest);
      lines.add(_lineRow(
        representative,
        mine.length >= 2
            ? BadgeStrings.unlockGroupedLine(
                BadgeStrings.badgeName(metric.id),
                highest,
                mine.length,
              )
            : BadgeStrings.unlockLine(
                BadgeStrings.badgeName(metric.id),
                highest,
              ),
      ));
    }
    if (batch.freshPaidCount >= 1) {
      lines.add(const SizedBox(height: 8));
      lines.add(Text(
        BadgeStrings.unlockTotalLine(
          batch.freshPaidCount * badgeRungGemAmount,
        ),
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: NotelColors.textPrimary,
        ),
      ));
    }
    if (batch.anyPending) {
      lines.add(const SizedBox(height: 8));
      lines.add(const Text(
        BadgeStrings.pendingGemsFooter,
        style: TextStyle(fontSize: 12, color: NotelColors.textSecondary),
      ));
    }
    return lines;
  }

  Widget _lineRow(BadgeGrant g, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          BadgeWidget(
            rungIndex: g.rungIndex,
            icon: badgeIconOf(g.metric.id),
            size: 40,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: NotelColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
