/// Phase 1, item 6 — Guided Lean Test: the ONE centralized string
/// file for the feature.
///
/// Every user-visible sentence in this feature comes from the
/// founder-override Juno re-ruling's final verbatim string set
/// (`2026-10-28-phase1-item6-founder-override-juno-ruling.md` §8,
/// disclaimer version 2), plus its §9 addendum outcome form. Strings
/// are character-for-character; do not paraphrase, shorten, or
/// reorder them. The copy-lint test scans [allLeanTestStrings] (and
/// rendered widget text) for prohibited phrasing.
///
/// Data display (numbers with bpm / mmHg units, timestamps, timer
/// readouts) is NOT copy and lives with the rendering helpers in
/// `lean_test_session.dart`; no sentence-level string outside this
/// file may ship in the feature.
library;

/// Reserved chip on every lean-test log entry (spec §4).
const String leanTestChip = 'Lean Test';

/// Payload kind marker in the entry's `manualText` JSON (spec §4).
const String leanTestPayloadKind = 'lean_test';

/// Disclaimer version recorded on every session run under the
/// override ruling (§6 of that ruling). Version 1 never shipped.
const int leanTestDisclaimerVersion = 2;

// ── S1 — Tools tile ────────────────────────────────────────────────

const String leanS1Label = 'Guided lean test';
const String leanS1Subtitle =
    'Record lying and standing heart rate and blood pressure';

// ── Phase 0 safety screen, in the binding render order (§3.3) ─────

/// E1 — what the test is.
const String leanE1 =
    'The lean test is a clinical test used in evaluating POTS. It records heart rate and blood pressure while you lie down, then again while you stand still for about 10 minutes.';

/// E2 — this version is a mock version.
const String leanE2 =
    'The version in Tabs is only a mock version of that test, included to give you an idea of how the test works. It is not the real clinical test, and it is not a replacement for a test supervised by a clinician.';

/// D1 — clinician-approval precondition. Own block, immediately
/// before S2, no less prominent than S2, never shortened.
const String leanD1 =
    'Do not do this test unless your own clinician has approved it for you. If you have not talked with your clinician about this test, do not start it. Talk to your clinician first and do this test only if they approve it. Tabs cannot approve this test for you.';

/// S2 — disclaimer. Renders in full on the safety screen AND again
/// on the result screen. No shortened form is approved.
const String leanS2 =
    'Tabs is not a medical device. It does not diagnose, treat, cure, or prevent any condition. This test records heart rate and blood pressure values that you enter or confirm. It does not interpret them. Doing this test on your own is not the same as a test supervised by a clinician. Talk to your healthcare professional about your results.';

/// S3 — stop conditions, in full before start.
const String leanS3 =
    'Stop the test and sit or lie down right away if you feel faint, dizzy, nauseous, shaky, or unwell in any way, or if you feel you might fall. You can stop at any time, for any reason. Stopping early is always okay — the values you already recorded are still saved.';

/// S4(a) — preparation line.
const String leanS4a =
    'Have someone nearby who knows you are doing this test.';

/// S4 R4 confirmation — gates the start action.
const String leanS4Confirmation =
    'Someone who knows I am doing this test is nearby.';

/// S4(b) — preparation line.
const String leanS4b =
    'Do it somewhere you can sit or lie down right away — a chair or bed within reach.';

/// S4(c) — preparation line.
const String leanS4c =
    'You will stand still for up to 10 minutes, leaning against a wall.';

/// S5 — start action.
const String leanS5 = 'Start the test';

// ── Flow screens ───────────────────────────────────────────────────

/// S6 — rest prompt.
const String leanS6 =
    'Lie flat and rest quietly. Stay lying down until the timer ends.';

/// N1 — resting capture prompt (both resting captures).
const String leanN1 = 'Resting reading. Enter your heart rate.';

/// S7 — stand action, user-tapped only.
const String leanS7 = "I'm standing now";

/// S8 — standing position prompt.
const String leanS8 =
    'Stand with your heels about 6 inches from the wall and your shoulder blades against the wall. Keep your arms relaxed at your sides. Stay as still and quiet as you can.';

/// S9 — standing checkpoint prompt for minute [n].
String leanS9(int n) => 'Minute $n. Enter your heart rate.';

/// Blood-pressure field label at every capture.
const String leanBpLabel = 'Blood pressure (optional)';

/// S10 — symptom note prompt (standing checkpoints only; no
/// examples may be added, R6).
const String leanS10 = 'Anything you notice right now (optional)';

/// N2 — Health Connect assist action.
const String leanN2 = 'Use latest Health Connect reading';

/// U1 — assist offer, sample at this checkpoint's minute.
String leanU1At(String time) => 'Recorded at $time';

/// U1 — assist offer, sample older than this checkpoint's minute.
String leanU1Older(String time, int minutes) =>
    'Recorded at $time — $minutes minutes before this checkpoint';

/// S11 — stop action (every phase; on every standing screen without
/// scrolling).
const String leanS11Action = 'Stop the test';

/// S11 — standing-phase stop response. Standing only; never
/// interchanged with N5.
const String leanS11Response =
    'The test is stopped. Sit or lie down now, and stay there until you feel steady.';

/// N5 — rest/transition-phase stop response. Rest only.
const String leanN5 =
    'The test is stopped. Any values you already recorded are still saved.';

// ── Result, history, interrupted ───────────────────────────────────

/// S12 — result heading.
const String leanS12Heading = 'Your recorded values';

/// S12 outcome form — completed.
const String leanOutcomeCompleted = 'Completed all 10 minutes';

/// S12 outcome form — standing stop at minute [n] (standing only).
String leanOutcomeStoppedStanding(int n) => 'Stopped early at minute $n';

/// §9 outcome form — rest stop at elapsed rest minute [n]
/// (rest only).
String leanOutcomeStoppedRest(int n) =>
    'Stopped early during rest at minute $n';

/// S12 outcome form — interrupted.
const String leanOutcomeInterrupted = 'Interrupted';

/// S12 completion line. [startedTs] is the app's standard timestamp
/// rendering of the session start (data display).
String leanS12Line(String outcome, String startedTs) =>
    'Guided lean test recorded — $outcome. Started $startedTs.';

/// The migraine-pattern hint rendered with the completion line.
const String leanHistoryHint = 'Tap to view in History';

/// N6 — Juno ruling 2026-10-29 (§2.2, verbatim; VC 100110 combine
/// change discharging Vera's F5 condition): the pending-state line.
/// Renders on the RESULT screen only, in the PENDING close state
/// only, IN PLACE OF [leanHistoryHint] — the two never appear
/// together. In the staged state the hint renders exactly as
/// before and N6 never renders. N6 never renders in History,
/// past-results, clinician PDF/Z7, or coach output. It is an
/// addition, not an edit to any v2 string, so
/// `leanTestDisclaimerVersion` stays 2.
const String leanN6 =
    'Saved on this device. It will appear in your History once it has uploaded.';

/// R2 baseline label — mean of two resting readings. [value] is a
/// rendered measurement (data display, e.g. `72 bpm`).
String leanBaselineMeanLabel(String value) =>
    'Baseline (average of your two resting readings): $value';

/// R2 baseline label — single resting reading.
String leanBaselineSingleLabel(String value) =>
    'Baseline (your one resting reading): $value';

/// U2 — renders wherever a checkpoint has no recorded value.
const String leanU2 = 'Not recorded';

/// N3 — interrupted explanatory line.
const String leanN3Line =
    'This test was interrupted. Close it as interrupted to keep the values recorded before it stopped, or discard it and start over from the beginning.';

/// N3 — close-as-interrupted action.
const String leanN3Close = 'Close as interrupted';

/// N3 — discard action.
const String leanN3Discard = 'Discard and start over';

/// N4 — past-results list heading.
const String leanN4 = 'Past tests';

/// Every shipped string in the feature, with the templated forms
/// rendered at representative values, for the §8.13 copy-lint. The
/// lint scans THIS list (the real shipped constants), never
/// fixtures built to pass.
List<String> get allLeanTestStrings => [
      leanTestChip,
      leanS1Label,
      leanS1Subtitle,
      leanE1,
      leanE2,
      leanD1,
      leanS2,
      leanS3,
      leanS4a,
      leanS4Confirmation,
      leanS4b,
      leanS4c,
      leanS5,
      leanS6,
      leanN1,
      leanS7,
      leanS8,
      leanS9(3),
      leanBpLabel,
      leanS10,
      leanN2,
      leanU1At('9:41 AM'),
      leanU1Older('9:41 AM', 4),
      leanS11Action,
      leanS11Response,
      leanN5,
      leanS12Heading,
      leanOutcomeCompleted,
      leanOutcomeStoppedStanding(3),
      leanOutcomeStoppedRest(4),
      leanOutcomeInterrupted,
      leanS12Line(leanOutcomeCompleted, 'Oct 28, 9:41 AM'),
      leanHistoryHint,
      leanBaselineMeanLabel('72 bpm'),
      leanBaselineSingleLabel('72 bpm'),
      leanU2,
      leanN3Line,
      leanN3Close,
      leanN3Discard,
      leanN4,
    ];
