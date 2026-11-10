import 'package:flutter/material.dart';
import 'package:tabs_lab/src/features/home/checkin_summary_card.dart'
    show SummaryFlareOrigin, checkInSummaryLabel;
import 'package:tabs_lab/src/features/home/feeling_checkin_card.dart'
    show feelingButtonSemantics, feelingWordForRanking;
import 'package:tabs_lab/src/theme/notel_colors.dart';

// ════════════════════════════════════════════════════════════════════
// HOME CHECK-IN COPY — THE SINGLE SWAP POINT (Home polish round 4)
//
// Every NEW user-visible string for the relocated Home check-in
// lives HERE, as a named constant / single composition function.
// Juno's verbatim ruling (Nov 10, 2026, Home polish round 4, Part
// C) was swapped in at integration:
//
// - [kHomeCheckInPrompt] — the prompt over the 1–5 numbers in the
//   top strip (Juno §1, lowercase as ruled).
// - [kSheetCheckInLabel] / [kSheetCheckInUnscoredText] — the Today
//   Summary sheet's unscored display-only row (Juno §5).
// - [homeCheckInScoredLine] — the scored line shown on the Today
//   Summary CARD FACE and (through the same composition) the sheet's
//   summary row. It delegates to the merged flow's ruled Item 7
//   label composition (Oct 28, 2026), whose plain form is Juno's
//   Nov 10 §3 template `{n} · {Word}`.
//
// The per-number word captions and button semantics are NOT new
// copy: they reuse the merged flow's existing ruled vocabulary
// ([feelingWordForRanking] / [feelingButtonSemantics], Juno Items
// 1–3) so the tap stays an informed declaration on this surface too.
// ════════════════════════════════════════════════════════════════════

/// The top-area prompt (Juno ruling Nov 10, 2026, §1 — verbatim,
/// lowercase deliberate). The fallback `feeling today?` ships ONLY
/// if this string cannot fit on one line at 360dp; it fits (the
/// strip is 230dp wide, the string ~125dp at its 13sp size), so
/// the primary ships. The screen-reader label is the full
/// question in its §6 form, [kHomeCheckInPromptSemantics].
const String kHomeCheckInPrompt = 'how are you feeling?';

/// Screen-reader form of the prompt (Juno §6 — always the full
/// question, this casing, even if the visual fallback ever ships).
const String kHomeCheckInPromptSemantics = 'How are you feeling?';

/// The Today Summary sheet's UNSCORED display row (Juno §5 —
/// verbatim): label + supporting text. The row is display-only —
/// no numerals, no tap — it says where the one input lives.
const String kSheetCheckInLabel = 'Morning Score';
const String kSheetCheckInUnscoredText =
    "one tap up top, whenever you're ready";

/// Semantics for the sheet's unscored row (Juno §6, verbatim).
const String kSheetCheckInUnscoredSemantics =
    "Morning Score. One tap up top, whenever you're ready.";

/// The Item 7.1 composition for a logged check-in (Oct 28, 2026):
/// the sheet summary card's label verbatim, and — with the
/// `Morning Score: ` prefix applied at the face only (Juno
/// reconciliation Q2, Nov 10, 2026) — the Today Summary card
/// face line. The prefix never enters this composition.
String homeCheckInScoredLine({
  required int ranking,
  String? flareSeverity,
  String? flareKind,
  required SummaryFlareOrigin flareOrigin,
  List<String> goodOptions = const [],
}) => checkInSummaryLabel(
  ranking: ranking,
  flareSeverity: flareSeverity,
  flareKind: flareKind,
  flareOrigin: flareOrigin,
  goodOptions: goodOptions,
);

/// Home polish round 4 (Part C) — the 1–5 check-in INPUT, relocated
/// from the Today Summary sheet to the open top-middle area of Home
/// (the corner band's center slot, between the streak stack and the
/// Daily Score face, above Bandit).
///
/// Presentation is FLAT by founder direction: no box, card, pill or
/// container background anywhere — the prompt and the numbers are
/// plain text directly on the app background, with the ruled word
/// caption under each number. Each number's tap target is an
/// invisible 44×44dp box (≥44dp per the round's floor).
///
/// The data path is UNCHANGED: [onSelect] is Home's existing
/// `_onFeelingSelect`, so a tap writes the same uneditable
/// 'Daily Ranking' entry through the same outbox path, with the
/// same 1–2 / 4–5 follow-up sheets. Home renders this strip only
/// while the day is unscored (the same `_feelingVisible` gate the
/// sheet-hosted card used); after scoring, the strip is gone and
/// the score shows on the Today Summary surface instead.
class HomeCheckInStrip extends StatelessWidget {
  final ValueChanged<int> onSelect;

  const HomeCheckInStrip({super.key, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('home_checkin_strip'),
      mainAxisSize: MainAxisSize.min,
      children: [
        // The prompt is the control's label, not a focusable
        // element (Juno §6): semantics carry the full question.
        Semantics(
          label: kHomeCheckInPromptSemantics,
          child: ExcludeSemantics(
            child: Text(
              kHomeCheckInPrompt,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: NotelColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var level = 1; level <= 5; level++)
              SizedBox(
                // 46dp column: five columns total 230dp, inside
                // the corner band's center slot at 360dp wide
                // (360 − 62 − 62 = 236dp) with room to spare; the
                // streak stack's axis (31dp) and the Daily Score
                // face's axis (width − 31dp) are untouched.
                width: 46,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _FlatCheckInNumber(
                      level: level,
                      onTap: () => onSelect(level),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      feelingWordForRanking(level),
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                        color: NotelColors.textSecondary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// One flat number: plain text on the app background inside an
/// invisible 44×44dp tap box. The only press feedback is the ink
/// turning Tabs primary while pressed — no fill, no border, no
/// container (the flat-presentation rule above).
class _FlatCheckInNumber extends StatefulWidget {
  final int level;
  final VoidCallback onTap;

  const _FlatCheckInNumber({required this.level, required this.onTap});

  @override
  State<_FlatCheckInNumber> createState() => _FlatCheckInNumberState();
}

class _FlatCheckInNumberState extends State<_FlatCheckInNumber> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: feelingButtonSemantics(widget.level),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) {
          setState(() => _pressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _pressed = false),
        child: SizedBox(
          key: ValueKey('home_checkin_number_${widget.level}'),
          width: 44,
          height: 44,
          child: Center(
            child: Text(
              '${widget.level}',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: _pressed ? NotelColors.primary : NotelColors.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
