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
// lives HERE, as a named constant / single composition function, so
// Juno's verbatim ruling can be swapped in at integration by
// editing ONLY this block. The values below are PLACEHOLDERS chosen
// by the build team, not ruled copy:
//
// - [kHomeCheckInPrompt] — the prompt over the 1–5 numbers in the
//   top strip, and the Today Summary sheet's display-only row.
// - [homeCheckInScoredLine] — the scored line shown on the Today
//   Summary CARD FACE and (through the same composition) the sheet's
//   summary row. It currently delegates to the merged flow's ruled
//   Item 7 label composition; if Juno rules a different scored-line
//   wording, this function is the only place that changes.
//
// The per-number word captions and button semantics are NOT new
// copy: they reuse the merged flow's existing ruled vocabulary
// ([feelingWordForRanking] / [feelingButtonSemantics], Juno Items
// 1–3) so the tap stays an informed declaration on this surface too.
// ════════════════════════════════════════════════════════════════════

/// PLACEHOLDER prompt (pending Juno's verbatim ruling — swap here).
const String kHomeCheckInPrompt = 'How are you feeling?';

/// The scored line for a logged check-in (Today Summary card face +
/// sheet summary row). PLACEHOLDER composition (pending Juno's
/// verbatim ruling — swap here): delegates to the Item 7 label.
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
        const Text(
          kHomeCheckInPrompt,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: NotelColors.textSecondary,
          ),
          textAlign: TextAlign.center,
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
