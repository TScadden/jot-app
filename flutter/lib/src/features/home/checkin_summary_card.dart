import 'package:flutter/material.dart';
import 'package:tabs_lab/src/features/home/feeling_checkin_card.dart'
    show feelingWordForRanking;
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Merged check-in flow — the logged-state summary card (Juno
/// ruling Oct 28, 2026, Item 7) and its pure composition helpers.
///
/// One summary card replaces BOTH the check-in card and the old
/// standalone flare button once a ranking is logged. Tapping it
/// opens the amend sheet (`Today's check-in`).

/// The origin of today's flare relative to the ranking, which
/// decides the summary composition (Item 7.1): a flare from a 1–2
/// tap attaches its kind to the check-in segment and gets NO
/// separate segment; a flare added later on a 3–5 day renders as
/// its own `Flare logged · {severity}` segment, last.
enum SummaryFlareOrigin { none, numberOrigin, lateAdded }

/// Visible label (Item 7.1), built exactly as ruled: segments
/// joined ` · `, lists inside an element joined `, `, no trailing
/// separator, no empty segment, no placeholder.
String checkInSummaryLabel({
  required int ranking,
  String? flareSeverity,
  String? flareKind,
  required SummaryFlareOrigin flareOrigin,
  List<String> goodOptions = const [],
}) {
  final buffer = StringBuffer(
    '$ranking · ${feelingWordForRanking(ranking)}',
  );
  if (flareOrigin == SummaryFlareOrigin.numberOrigin) {
    if (flareKind != null) buffer.write(' · $flareKind');
  } else if (goodOptions.isNotEmpty) {
    buffer.write(' · ${goodOptions.join(', ')}');
  }
  if (flareOrigin == SummaryFlareOrigin.lateAdded && flareSeverity != null) {
    buffer.write(' · Flare logged · $flareSeverity');
    if (flareKind != null) buffer.write(' · $flareKind');
  }
  return buffer.toString();
}

/// Accessibility semantics (Item 7.2): a sentence, not a copy of
/// the visible label — descriptive words lowercased, a late flare
/// as its own clause, ending with the ruled action sentence.
String checkInSummarySemantics({
  required int ranking,
  String? flareSeverity,
  String? flareKind,
  required SummaryFlareOrigin flareOrigin,
  List<String> goodOptions = const [],
}) {
  final buffer = StringBuffer(
    "Today's check-in: $ranking of 5, "
    '${feelingWordForRanking(ranking).toLowerCase()}',
  );
  if (flareOrigin == SummaryFlareOrigin.numberOrigin) {
    if (flareKind != null) buffer.write(', ${flareKind.toLowerCase()}');
  } else if (goodOptions.isNotEmpty) {
    buffer.write(
      ', ${goodOptions.map((o) => o.toLowerCase()).join(', ')}',
    );
  }
  buffer.write('. ');
  if (flareOrigin == SummaryFlareOrigin.lateAdded && flareSeverity != null) {
    buffer.write('Flare logged, ${flareSeverity.toLowerCase()}');
    if (flareKind != null) buffer.write(', ${flareKind.toLowerCase()}');
    buffer.write('. ');
  }
  buffer.write("Tap to update today's details.");
  return buffer.toString();
}

/// The summary card. The visible text is the Item 7.1 label; the
/// semantics are the Item 7.2 sentence. The card contains a live
/// region carrying the Item 11 commit announcement
/// ([announcement]: a flare or good-day label, verbatim) so a
/// commit announces that label to assistive technology — no toast
/// anywhere (Item 11 / ruling 3.3a).
class CheckInSummaryCard extends StatelessWidget {
  final String label;
  final String semanticsLabel;

  /// The latest Item 11 announcement label, or null before any
  /// flare/good commit this session. Live region only — never
  /// visible text.
  final String? announcement;
  final VoidCallback onTap;

  const CheckInSummaryCard({
    super.key,
    required this.label,
    required this.semanticsLabel,
    required this.onTap,
    this.announcement,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Semantics(
        button: true,
        label: semanticsLabel,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            constraints: const BoxConstraints(minHeight: 56),
            decoration: BoxDecoration(
              color: NotelColors.primary.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: NotelColors.primary.withValues(alpha: 0.22),
                width: 1,
              ),
            ),
            padding:
                const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.check_circle,
                  size: 20,
                  color: NotelColors.primary,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: NotelColors.textPrimary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                // Item 11 announcement: a zero-size live region
                // whose label is exactly the committed record's
                // label. Not visible, never a toast.
                if (announcement != null)
                  Semantics(
                    liveRegion: true,
                    label: announcement,
                    child: const SizedBox.shrink(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
