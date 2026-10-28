/// Phase 1, item 5 — correlation engine copy.
///
/// EVERY user-visible string in this file is Juno's FINAL ruled
/// string set (team/compliance/2026-10-28-phase1-juno-rulings.md,
/// Item 5 + D1 + Item 2 Drafts 4–6 as consumed by F5). They are
/// byte-verbatim: do not paraphrase, "improve", or re-punctuate
/// them. Any delta returns to Juno before it ships.
///
/// The engine itself (correlation_engine.dart) produces records,
/// not sentences; the Patterns surface renders records through
/// the formatters in this file so the ruled shapes exist in
/// exactly one place.
library;

// ── S1 — surface title + intro ─────────────────────────────────────

const String correlationTitle = 'Patterns in your records';

const String correlationIntro =
    'Tabs groups your logged days and averages your Daily Scores for each group. A pattern in your records, not a cause. Other things differed between these days too.';

// ── S2 — comparison sentence (the only score-outcome shape) ────────

/// Lag header for lagged families (F1, F2 score splits).
const String correlationLagHeader = 'Your score the next day';

/// Means render rounded to whole points (Juno's S2 shape).
String _whole(double v) => v.round().toString();

/// S2: `On {A} ({n} days), your Daily Score averaged {mean}. On
/// {B} ({m} days), it averaged {mean}.`
String correlationComparisonSentence({
  required String groupALabel,
  required int groupAN,
  required double groupAMean,
  required String groupBLabel,
  required int groupBN,
  required double groupBMean,
}) =>
    'On $groupALabel ($groupAN days), your Daily Score averaged ${_whole(groupAMean)}. On $groupBLabel ($groupBN days), it averaged ${_whole(groupBMean)}.';

/// Detail-expansion median line: `Middle score: {median}`.
String correlationMedianLine(double median) =>
    'Middle score: ${_whole(median)}';

// ── S3 — standing caption (every card, every render) ───────────────

const String correlationCaption =
    'A pattern in your records, not a cause. Other things differed between these days too.';

// ── S4 — incidence sentence (F2 flare / migraine outcomes) ─────────

/// Flare form, Juno's replacement shape verbatim.
String correlationFlareIncidenceSentence({
  required int x,
  required int n,
  required int y,
  required int m,
}) =>
    'A flare was logged on $x of the $n days after days your logged intake reached your target, and on $y of the $m days after days your logged intake was below your target.';

/// Migraine form — the same replaced shape with the first clause
/// substituted (Juno: "Migraine-day incidence rides this same
/// replaced shape").
String correlationMigraineIncidenceSentence({
  required int x,
  required int n,
  required int y,
  required int m,
}) =>
    'A migraine was logged on $x of the $n days after days your logged intake reached your target, and on $y of the $m days after days your logged intake was below your target.';

// ── S5 — co-occurrence note (computed co-occurrences only) ─────────

/// `On the {group A} days, {confounder label} also averaged
/// {value}, compared with {value} on the {group B} days.`
/// Values are sleep minutes for the v1 (F3) instance and render
/// rounded to whole minutes.
String correlationCoOccurrenceSentence({
  required String groupADays,
  required String confounderLabel,
  required double valueA,
  required String groupBDays,
  required double valueB,
}) =>
    'On the $groupADays days, $confounderLabel also averaged ${_whole(valueA)}, compared with ${_whole(valueB)} on the $groupBDays days.';

// ── S6 — progress state ────────────────────────────────────────────

/// `Not enough days yet. This pattern needs at least 5 days in
/// each group, and 14 days in total. So far: {x} {group A label},
/// {y} {group B label} — {t} days in total.` (em dash verbatim)
String correlationProgressSentence({
  required String groupALabel,
  required int groupAN,
  required String groupBLabel,
  required int groupBN,
}) =>
    'Not enough days yet. This pattern needs at least 5 days in each group, and 14 days in total. So far: $groupAN $groupALabel, $groupBN $groupBLabel — ${groupAN + groupBN} days in total.';

// ── S7 — unavailable families ──────────────────────────────────────

const String correlationUnavailableF2 =
    'This pattern needs salt and fluid logging, which is not in Tabs yet.';

const String correlationUnavailableF5 =
    'This pattern needs your medication change history. There are no recorded medication changes in Tabs yet.';

// ── S8 — window / through line ─────────────────────────────────────

/// `Last 90 days · through {date}`
String correlationWindowLine(String throughDate) =>
    'Last 90 days · through $throughDate';

// ── R5 — surface disclaimer (renders once on the surface) ──────────
//
// NOTE: this is Juno's item-5 line. It is NOT the longer
// disclaimer variant used on the Daily Score detail screen; do
// not substitute that variant here.

const String correlationSurfaceDisclaimer =
    'Tabs is not a medical device. It does not diagnose, treat, cure, or prevent any condition.';

// ── F2 split headers (spec §3.3's own nouns) ───────────────────────
// Juno's S4 sentence names "your target" without distinguishing
// fluid from sodium; the distinction is carried by these headers
// so her sentences stay byte-verbatim.

const String correlationFluidHeader = 'Fluid target';
const String correlationSodiumHeader = 'Sodium target';

// ── Group labels (pinned, factual bin definitions) ─────────────────

const String f1aGroupALabel = 'nights under 6 hours of sleep';
const String f1aGroupBLabel = 'nights with 6 or more hours of sleep';

const String f1bGroupALabel = 'nights under your sleep need';
const String f1bGroupBLabel = 'nights at or above your sleep need';

const String f2GroupALabel = 'days your logged intake reached your target';
const String f2GroupBLabel = 'days your logged intake was below your target';

const String f3GroupALabel = 'days you logged a flare';
const String f3GroupBLabel = 'days with no flare logged';

const String f4GroupALabel = 'days with a Daily Ranking of 1 or 2';
const String f4GroupBLabel = 'days with a Daily Ranking of 4 or 5';

/// F5 below-floor (S6-state) group labels (Juno, via D1: S6 with
/// before/after window counts as the groups).
const String f5GroupALabel = 'scored days before the change';
const String f5GroupBLabel = 'scored days after the change';

// ── Item 2 strings consumed by F5 (Juno, Item 2 Drafts 4–6) ────────

const String medWindowBeforeLabel = 'Average Daily Score, 14 days before';
const String medWindowAfterLabel = 'Average Daily Score, 14 days after';

/// Draft 4 rendering: `{average} · {n} scored days`.
String medWindowValue(double average, int n) =>
    '${_whole(average)} · $n scored days';

/// Draft 5 — window rule note (renders whenever the panel renders
/// averages).
const String medWindowRuleNote =
    'The day of the change counts in the "after" window for starts and dose changes, and in the "before" window for stops.';

/// Draft 6 — change labels.
String medChangeStartedLabel(String name, String dose) =>
    'Started $name · $dose';
String medChangeStoppedLabel(String name) => 'Stopped $name';
String medChangeDoseLabel(String name, String oldDose, String newDose) =>
    '$name dose changed from $oldDose to $newDose';
String medChangeScheduleLabel(
        String name, String oldFrequency, String newFrequency) =>
    '$name schedule changed from $oldFrequency to $newFrequency';
String medChangeRestartedLabel(String name, String dose) =>
    'Restarted $name · $dose';

// ── Copy-lint blocklist (U1, adopted by Juno R3) ───────────────────
//
// These strings are PROHIBITED user-visible copy. They live here
// as data for the UI worker's copy-lint test (spec §8, test A6):
// no rendered engine string, label, or group label may contain
// any of them (case-insensitive substring match).

const List<String> correlationCopyBlocklist = [
  'Short sleep lowers your score.',
  'Hitting your salt target improves your next day.',
  'Your score was higher because of',
  'Your strongest pattern is',
  'Expect a lower score after short nights.',
  'Try getting more sleep to raise your score.',
  // The medication verdict, as its two phrases (U1's
  // "This medication is working / is not working.").
  'This medication is working',
  'This medication is not working',
  'Days you failed to hit your target',
];

/// Lint-scope additions per Juno R3/R4: any '%' character in
/// rendered engine copy is banned (percentages are banned
/// outright on this surface in v1), and no delta presentation
/// exists — the record model carries no delta field by design.
const String correlationBannedCharacter = '%';

/// Every string constant this file ships, for lint sweeps. (The
/// formatters above are linted through their outputs in tests.)
const List<String> correlationStaticStrings = [
  correlationTitle,
  correlationIntro,
  correlationLagHeader,
  correlationCaption,
  correlationUnavailableF2,
  correlationUnavailableF5,
  correlationSurfaceDisclaimer,
  correlationFluidHeader,
  correlationSodiumHeader,
  f1aGroupALabel,
  f1aGroupBLabel,
  f1bGroupALabel,
  f1bGroupBLabel,
  f2GroupALabel,
  f2GroupBLabel,
  f3GroupALabel,
  f3GroupBLabel,
  f4GroupALabel,
  f4GroupBLabel,
  f5GroupALabel,
  f5GroupBLabel,
  medWindowBeforeLabel,
  medWindowAfterLabel,
  medWindowRuleNote,
];
