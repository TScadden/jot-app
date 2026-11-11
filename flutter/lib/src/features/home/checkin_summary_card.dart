import 'package:flutter/material.dart';
import 'package:tabs_lab/src/features/home/feeling_checkin_card.dart'
    show feelingWordForRanking;
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Merged check-in flow — the logged-state summary card (Juno
/// ruling Oct 28, 2026, Item 7) and its pure composition helpers.
///
/// One summary card replaces BOTH the check-in card and the old
/// standalone flare button once a ranking is logged.
///
/// Home polish round 5 (founder ruling, Nov 10, 2026): the card is
/// DISPLAY-ONLY. It once opened the amend sheet (`Today's
/// check-in`); the founder ruled that the "why it was good"
/// explanation is a one-time, at-logging surface and must not
/// reopen after the ranking is logged — after logging, the score
/// is just shown. The card therefore carries no tap handler and
/// no button semantics, and its Item 7.2 sentence carries no
/// action wording (Juno ruling, Nov 10, 2026).

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
  }
  if (goodOptions.isNotEmpty) {
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
/// as its own clause. Round 5 (Juno ruling, Nov 10, 2026): the
/// sentence is descriptive ONLY — the former closing action
/// sentence ("Tap to update today's details.") is dropped with
/// no replacement, because the scored surfaces no longer carry
/// any tap action for it to describe; copy must be true at the
/// moment it is heard. One terminal period, no trailing space.
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
  }
  if (goodOptions.isNotEmpty) {
    buffer.write(
      ', ${goodOptions.map((o) => o.toLowerCase()).join(', ')}',
    );
  }
  if (flareOrigin == SummaryFlareOrigin.lateAdded && flareSeverity != null) {
    buffer.write('. Flare logged, ${flareSeverity.toLowerCase()}');
    if (flareKind != null) buffer.write(', ${flareKind.toLowerCase()}');
  }
  buffer.write('.');
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

  const CheckInSummaryCard({
    super.key,
    required this.label,
    required this.semanticsLabel,
    this.announcement,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Semantics(
        // Round 5: no button flag — the card is display-only
        // (see the file header). A button announcement on a
        // non-action would be a false affordance.
        label: semanticsLabel,
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
    );
  }
}
