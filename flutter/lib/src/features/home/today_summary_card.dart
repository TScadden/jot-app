import 'package:flutter/material.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 8 — Today Summary card.
///
/// Pixel-port of the native "Expandable Today Summary Section"
/// (`TodayScreen.kt` item 3): calendar icon + "Today Summary" title,
/// subtitle, chevron; expanded content shows "Today's Plan" and "Trends".
///
/// DATA STATUS THIS ROUND: the plan/trend data sources (reminders,
/// habits, medications, health comparisons) are NOT wired in this fresh
/// app yet, so the honest native empty states render:
/// - subtitle: "No plans recorded today" (native `summaryText` when
///   remainingCount == 0 and the plan list is empty)
/// - plan list: "No plans recorded today"
/// - trends: "Not enough data yet" (native `TodayTrendsState.Empty`)
///
/// The chevron expand/collapse is live UI state (native default:
/// expanded).
class TodaySummaryCard extends StatefulWidget {
  const TodaySummaryCard({super.key});

  @override
  State<TodaySummaryCard> createState() => _TodaySummaryCardState();
}

class _TodaySummaryCardState extends State<TodaySummaryCard> {
  // Native default: expanded (todaySummaryExpanded pref defaults true).
  bool _expanded = true;

  void _toggle() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
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
                            Row(
                              children: [
                                const Icon(
                                  Icons.today,
                                  size: 20,
                                  color: NotelColors.primary,
                                ),
                                const SizedBox(width: 8),
                                const Text(
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
                            // Honest empty state: no plan sources wired yet.
                            // TODO: wire reminders/habits/medications and
                            // compute the native summaryText
                            // ("N items remaining · M overdue").
                            const Text(
                              'No plans recorded today',
                              style: TextStyle(
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
                          // TODO: wire plan items (reminders/habits/meds).
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 6.0),
                            child: Text(
                              'No plans recorded today',
                              style: TextStyle(
                                fontSize: 12,
                                color: NotelColors.textSecondary,
                              ),
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
                              // Refresh: no-op until trend sources are wired.
                              SizedBox(
                                width: 24,
                                height: 24,
                                child: IconButton(
                                  onPressed: () {},
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
                          // Native TodayTrendsState.Empty text.
                          // TODO: wire health comparisons.
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 4.0),
                            child: Text(
                              'Not enough data yet',
                              style: TextStyle(
                                fontSize: 12,
                                color: NotelColors.textSecondary,
                              ),
                            ),
                          ),
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
