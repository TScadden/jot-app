/// Phase 1, item 2b — the medication timeline's ENTIRE user-visible
/// claim/label copy, in ONE place so a copy-lint test can enumerate
/// it against the allowlist.
///
/// Every string here is from Juno's FINAL VERBATIM STRING SET for
/// item 2 (`~/workspace/team/compliance/
/// 2026-10-28-phase1-juno-rulings.md`, ITEM 2 section). The spec's
/// §4.2 drafts are superseded wherever the rulings differ — notably
/// Draft 8's second empty state, replaced by Juno with the
/// below-floor string ([belowFloorMessage]) that carries the real
/// scored-day counts and the D1 floor.
///
/// Anything else the feature renders is data-derived (medication
/// names, doses, recorded date strings, counts) or a bare number
/// (the 7/14/30 window selector). No other claim or label copy may
/// be added here without a new Juno ruling.
///
/// Juno R2 (absolute): no numeric difference, percent change,
/// arrow, or color/ordering contrast between the two window
/// averages may appear anywhere — there is deliberately NO delta
/// string in this file.
abstract final class MedicationTimelineStrings {
  /// Draft 1 — screen title (also the Medications tool entry).
  static const String title = 'Medication timeline';

  /// Draft 2 — intro line.
  static const String intro =
      'See when your medications started, stopped, or changed, next to your Daily Scores and logged days.';

  /// Draft 3 — non-causation disclaimer. Renders on the
  /// before/after panel AND on the screen at first open.
  static const String nonCausationDisclaimer =
      'Tabs shows your own records side by side. A change in your scores after a medication change does not mean the medication caused it. What your records mean is a question for you and your clinician.';

  /// Draft 5 — window rule note. Renders whenever the panel
  /// renders averages.
  static const String ruleNote =
      'The day of the change counts in the "after" window for starts and dose changes, and in the "before" window for stops.';

  /// Draft 7 — seeded (pre-capture) provenance. Renders on EVERY
  /// seeded marker and nowhere else; captured events carry no
  /// provenance label.
  static const String seededProvenance = 'Date from your medication list';

  /// Draft 8, first string — the changes-list empty state.
  static const String noChangesInRange = 'No medication changes in this range.';

  /// Draft 9 — series toggle labels (plain series names).
  static const String toggleDailyScore = 'Daily Score';
  static const String toggleFlareDays = 'Flare days';
  static const String toggleMigraineDays = 'Migraine days';
  static const String toggleSymptomLogs = 'Symptom logs';

  /// R5 — the not-a-medical-device line. Renders ONCE, inside
  /// the before/after panel.
  static const String screenDisclaimer =
      'Tabs is not a medical device. It does not diagnose, treat, cure, or prevent any condition.';

  /// Draft 4 — window label, before window. [days] is the span
  /// actually averaged: the selected window length, or the true
  /// (truncated) span when the window was cut by the stored
  /// series edge or a neighboring same-medication change (R4/§3 —
  /// the label's day count IS the truncation statement).
  static String windowLabelBefore(int days) =>
      'Average Daily Score, $days days before';

  /// Draft 4 — window label, after window. See [windowLabelBefore].
  static String windowLabelAfter(int days) =>
      'Average Daily Score, $days days after';

  /// Draft 4's value shape: `{average} · {n} scored days`, with
  /// the average rendered as a whole number (scores are whole
  /// 0–100 by app convention).
  static String windowValue(int average, int scoredDays) =>
      '$average · $scoredDays scored days';

  /// Draft 8 as REPLACED by Juno — the panel's below-floor state
  /// (D1 shared floor: each window ≥ 5 scored days AND ≥ 14 in
  /// total). [beforeScoredDays] / [afterScoredDays] are the REAL
  /// counts; no partial average ever renders in this state.
  static String belowFloorMessage(int beforeScoredDays, int afterScoredDays) =>
      'Not enough scored days for these windows yet. Before: $beforeScoredDays scored days. After: $afterScoredDays scored days. Averages show when each window has at least 5 scored days and the two windows have 14 scored days in total.';

  /// Draft 6 — marker labels. Names, doses, and schedules render
  /// exactly as recorded in the event snapshots.
  static String startedLabel(String name, String dose) =>
      'Started $name · $dose';

  static String stoppedLabel(String name) => 'Stopped $name';

  static String doseChangedLabel(String name, String oldDose, String newDose) =>
      '$name dose changed from $oldDose to $newDose';

  static String scheduleChangedLabel(
          String name, String oldFrequency, String newFrequency) =>
      '$name schedule changed from $oldFrequency to $newFrequency';

  static String restartedLabel(String name, String dose) =>
      'Restarted $name · $dose';
}
