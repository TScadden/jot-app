import 'package:flutter/material.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// R70 Daily Score — ALL user-visible score vocabulary, centralized
/// in this one file for Juno's mandatory wording pass.
///
/// The starting vocabulary is FOUNDER-SEEN: Rusty showed the
/// founder the Daily Score concept mockup on Oct 17, 2026, and he
/// approved its direction. Concept words carried over verbatim:
/// the band chip "Good" (shown at a score of 78), the component
/// chips "Good" (Sleep), "Above" (HRV), "Normal" (Resting HR),
/// the "Daily Score" label, and the sleep line format
/// "7h29m of 8h27m need". Everything else here extends that
/// vocabulary as a proposal — status:
/// CONCEPT-APPROVED-PENDING-JUNO for every string in this file.
///
/// Rules that still bind (Juno): trend-vs-own-baseline framing
/// only, no diagnostic terms, no "stress"/"recovery" claims, no
/// vendor language, no accuracy claims. Bands and chips always
/// pair a TEXT label with color — never color alone.

/// One score band: range, plain state word, token color (the Home
/// arc + chip, chart and list accents).
class DailyScoreBand {
  final String label;
  final Color color;
  const DailyScoreBand(this.label, this.color);
}

/// Bands: 80+ / 60–79 / 40–59 / below 40. The 60–79 band is the
/// concept's green "Good" (the mockup's 78). The 80+ word extends
/// the concept vocabulary one step up; Juno rules on it.
DailyScoreBand bandForScore(int score) {
  if (score >= 80) return const DailyScoreBand('Great', NotelColors.success);
  if (score >= 60) return const DailyScoreBand('Good', NotelColors.success);
  if (score >= 40) return const DailyScoreBand('Low', NotelColors.warning);
  return const DailyScoreBand('Very low', NotelColors.error);
}

/// A component status chip: word + solid fill + ink, mirroring the
/// concept's solid chips (green "Good", blue "Above", purple
/// "Normal"). [foreground] is chosen per fill for measured
/// contrast: dark ink on the bright fills, and `onPrimary` ink on
/// `primary` — the token file's chip precedent (Round 49 audit S1:
/// onPrimary on primary = 5.21:1, passing for 11sp chip text;
/// white on primary = 3.80:1 is the §0.9 exception for primary
/// BUTTON labels/glyphs only and does not cover chips — Mira
/// design pass, Oct 17, 2026, measured from the token values).
class ScoreChip {
  final String label;
  final Color background;
  final Color foreground;
  const ScoreChip(this.label, this.background, this.foreground);
}

const ScoreChip _chipGood =
    ScoreChip('Good', NotelColors.success, NotelColors.background);
const ScoreChip _chipNormal =
    ScoreChip('Normal', NotelColors.primary, NotelColors.onPrimary);
// Juno C2 — the sleep 60–79 tier is "Fair" (info fill), NOT
// "Normal": after this change "Normal" means only "within ±2% of
// your own baseline" (the direction chips below).
const ScoreChip _chipFair =
    ScoreChip('Fair', NotelColors.info, NotelColors.background);
const ScoreChip _chipAbove =
    ScoreChip('Above', NotelColors.info, NotelColors.background);
const ScoreChip _chipBelow =
    ScoreChip('Below', NotelColors.warning, NotelColors.background);
// Juno C3 — resting-HR "Below" is direction-neutral (info fill,
// identical in color to "Above"): below-baseline resting HR
// RAISES that component's score, so the warning fill contradicted
// the scoring. HRV "Below" keeps _chipBelow's warning fill.
const ScoreChip _chipBelowInfo =
    ScoreChip('Below', NotelColors.info, NotelColors.background);
const ScoreChip _chipLow =
    ScoreChip('Low', NotelColors.warning, NotelColors.background);
const ScoreChip _chipVeryLow =
    ScoreChip('Very low', NotelColors.error, NotelColors.background);

/// Sleep chip, from the day's sleep component score (100 × the
/// share of personal need met, capped): the quality-word system.
ScoreChip sleepChipForScore(int componentScore) {
  if (componentScore >= 80) return _chipGood;
  if (componentScore >= 60) return _chipFair;
  if (componentScore >= 40) return _chipLow;
  return _chipVeryLow;
}

/// Deviation deadband (±%) inside which a day reads "Normal"
/// against its baseline — presentation rounding so a fraction of
/// a percent never flips the word.
const double chipNormalDeadbandPercent = 2;

/// HRV chip, from the percent deviation of today's value vs the
/// baseline median: the direction-word system (the concept's HRV
/// chip is "Above"). Direction words describe the value vs the
/// baseline; they are not good/bad judgments.
ScoreChip hrvChipForDeviation(double devPercent) {
  if (devPercent > chipNormalDeadbandPercent) return _chipAbove;
  if (devPercent < -chipNormalDeadbandPercent) return _chipBelow;
  return _chipNormal;
}

/// Resting-HR chip, same direction-word system as HRV (the
/// concept's Resting HR chip is "Normal"). "Below" for resting HR
/// means below the baseline — the word stays descriptive.
ScoreChip restingHrChipForDeviation(double devPercent) {
  if (devPercent > chipNormalDeadbandPercent) return _chipAbove;
  if (devPercent < -chipNormalDeadbandPercent) return _chipBelowInfo;
  return _chipNormal;
}
