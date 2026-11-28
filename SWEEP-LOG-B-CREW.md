# Sweep log — Scope B (crew, Bram, Nov 27, 2026)

Branch `crew/theme-sweep-b` on `feat/theme-mode` (phase 1 landed).
Method per `PATTERN.md`: every `Color(0x…)` literal and every
`Colors.white` / `Colors.black` in scope was read in context and
classified 1–5. Alpha mapping used for class 4 (same construction as
the phase-1 vitals precedent, white @ 8% → hairline): white @
0.03–0.07 → `legacyDarkHairlineFaint` (5%), white @ 0.08–0.10 →
`legacyDarkHairline` (10%), white @ 0.18 → `legacyDarkDivider`
(15%). Dark-mode deltas are ≤ 3 alpha points throughout.

Totals: 13 files changed, 7 commits. Every remaining literal in
scope is a documented leave below (129 grep hits post-sweep, all
accounted for in this log).

## features/tools

### blood_pressure_tool_screen.dart — no changes
- L1103 `foregroundColor: Colors.white` + L1564 spinner
  `color: Colors.white` — on `NotelColors.primary` fills. Class 5,
  left.
- L1375/1376 chip fills `0xFF1E3A8A` / `0xFF064E3B` + L1385/1386 chip
  text `0xFF93C5FD` / `0xFF6EE7B7` — self-contained native chip pairs
  (dark fill ships with its light text). Class 2, left as a pair.

### body_info_screen.dart — CHANGED (commit 983c56c0)
- Region/status hues `0xFFFF7043`, `0xFFFF5252`, `0xFFAB47BC`,
  `0xFFFFB300`, `0xFF26A69A`, `0xFFEF5350`, `0xFF4ECDC4` (impact
  constructors) and the same family in `bodyRegionColor()` incl.
  `0xFF42A5F5` — data colors (class 3), left. NOTE: `impact.color`
  is also used as small TEXT on palette surfaces (status line,
  time-remaining chip). Several hues (amber `0xFFFFB300`, teal
  `0xFF26A69A`) will not pass AA as text on the light surface.
  No per-hue palette tokens exist and adding a light data palette
  is outside Scope B — FLAGGED as a follow-up (same bucket as
  key_metrics tile hues and the community streak orange).
- `_impactColor = Color(0xFF7C6EFF)` — exactly the brand primary.
  Class 1: token-routed to `NotelColors.primary` (value identical,
  stays `static const`).
- `_mildColor 0xFF4FB3A9`, `_workoutColor 0xFFFFB020` — founder-mock
  figure palette, data colors (class 3), left.
- `_panelColor 0xFF0C1429` + the white dot on it (L1137) — the body
  figure ART panel: a self-contained dark canvas that ships with
  the figure artwork and its tints (class 2), left. Routing the
  panel to `surface` would put the dark-designed art on white in
  light mode.
- Card borders white @ 0.08 (visualizer, workout-log cards) →
  `legacyDarkHairline`; segmented track fill white @ 0.06 →
  `legacyDarkHairlineFaint`, its border @ 0.08 → `legacyDarkHairline`;
  text-field fill white @ 0.05 → `legacyDarkHairlineFaint`, its
  borders @ 0.08 → `legacyDarkHairline`; card borders white @ 0.05
  (×3) → `legacyDarkHairlineFaint`. Class 4.
- Workout result message text `0xFFEF5350` / `0xFF66BB6A` — semantic
  TEXT on a palette surface (class 3 exception): routed to
  `NotelColors.error` / `NotelColors.success`.
- Segmented selected text `Colors.white` (L992) — on a
  `NotelColors.primary` fill. Class 5, left.

### body_workout.dart — examined, no hits
No `Color(0x`, `Colors.white`, `Colors.black`, `NotelColors`, or
`LabBlackColors` references at all.

### coach_mascot.dart — examined, no hits
Same as above — no color references of any kind.

### community_screen.dart — no changes
- `_kStreakOrange 0xFFFF6A3D` — founder-ruled streak flame color
  (class 3 data), left. It is used as 13px bold TEXT + icon on
  surface cards (`_StreakStat`, `_FriendStatCard` accent); on the
  light surface it measures ≈2.9:1 and will not pass AA — same
  shape as `kGemCountColor`, which phase 1 fixed with a light
  variant. No streak-orange token exists; FLAGGED as a follow-up
  (needs a palette decision, out of Scope B).
- Avatar palette `0xFF4E8FD0`, `0xFF5FAE7E`, `0xFFD478A8`,
  `0xFFE79B4B` — avatar background fills (data colors, class 3),
  left; the initials text on them is `Colors.white` (L1246), a
  class 2 pair with those fills, left.
- L760, L908, L917 `Colors.white` — on `NotelColors.primary`
  buttons (foreground + spinner). Class 5, left.

### food_screen.dart — CHANGED (commit b58b299b)
- Chip border white @ 0.05 (L842) → `legacyDarkHairlineFaint`
  (class 4).
- L641/646/650 `Colors.white` — spinner/icon/label on the primary
  FilledButton. Class 5, left.

### habits_screen.dart — no changes
- Gradient stop `0xFFFF6B35` @ 0.15 beside `NotelColors.warning` —
  decorative streak gradient (class 3), left.
- Check icon `Colors.white` (L1101) — on a `NotelColors.primary`
  dot fill. Class 2/5, left.

### health_coach_screen.dart — no changes
- L1894, L4643, L4724, L4734 `Colors.white` — FAB / approve / send
  foregrounds and spinner, all on `NotelColors.primary` fills.
  Class 5, left.

### key_metrics_screen.dart — no changes
- Export button whites (L678, L682) — on the primary FilledButton.
  Class 5, left. Retry button white (L797) — on primary. Class 5.
- Metric tile hues `0xFF81C784`, `0xFFFF8A65`, `0xFFBA68C8`,
  `0xFF4DB6AC` — per-metric data colors (class 3), used as the
  tile icon on their own 15% tint discs, left. Light-mode AA of
  the lightest hue on its tint is weak for a 18dp glyph —
  FLAGGED with the body-region hues follow-up.

### lean_test_screen.dart — examined, no hits
Token-routed already (12 `NotelColors` reads, zero literals).

### lists_screen.dart — CHANGED (commit b58b299b)
- Card border white @ 0.05 (L732) → `legacyDarkHairlineFaint`
  (class 4).

### med_scan_confirm_sheet.dart — no changes
- L312 `TextStyle(color: Colors.white)` — label on the primary
  FilledButton. Class 5, left.

### med_scan_screen.dart — no changes
- L398, L486, L553, L594 `Colors.white` — labels on primary
  ElevatedButtons. Class 5, left.

### med_scan_strings.dart — examined, no hits (strings only).

### medication_timeline_screen.dart — examined, no hits
Token-routed already (83 `NotelColors` reads, zero literals).

### medication_timeline_strings.dart — examined, no hits.

### medications_screen.dart — CHANGED (commit b58b299b)
- Card borders white @ 0.08 (L683, L926) → `legacyDarkHairline`
  (class 4).
- L737/746, L1064 `Colors.white` — "Took All Meds" / "Took Med"
  labels in their ENABLED state sit on `NotelColors.primary`
  (disabled state already uses `textSecondary`). Class 5, left.
- L1227, L1514 `Colors.white` — labels on primary buttons.
  Class 5, left.

### notes_screen.dart — CHANGED (commit b58b299b)
- Compose-card border white @ 0.03 and note-card border white
  @ 0.05 → `legacyDarkHairlineFaint` (class 4).

### project_focus_screen.dart — CHANGED (commit e6493845)
The creation flow lives in one card whose fill was
`Color(0x590A0A0E)` — black @ 35% over the page background. In dark
that composites to near-black and the white contents read fine;
in light it composites to mid-grey and every white label inside
fails. The card is a class 1 token-role surface:
- Card fill `0x590A0A0E` → `NotelColors.surface`; card border
  white @ 0.08 → `legacyDarkHairline`. (Dark-mode note: the card
  becomes the standard opaque card `#101013` instead of a
  translucent ~`#070708` composite — same family as every other
  card in the app; flagged for Vera's visual check.)
- White text on palette surfaces → `textPrimary` (class 5):
  Back/Cancel button foregrounds (×4, paired with the fills
  below), duration-stepper OutlinedButton foregrounds (×2),
  `$_setupDuration Days` headline, "Test Locked In!" headline,
  flow-option card title, test-selector chip title, unselected
  start-option label. Const dropped on the three `TextStyle`s
  that now read the getter (const rule).
- Future-day number `Colors.white @ 0.15` → 
  `NotelColors.textPrimary.withValues(alpha: 0.15)` — keeps the
  deliberate fade, flips polarity in light.
- White-alpha neutral fills/borders → hairline tokens (class 4):
  input card fill @ 0.03 / border @ 0.08; flow-option fill/border;
  start-option + test-chip + check-in-option unselected fills
  @ 0.03 and borders @ 0.08; progress track @ 0.07 →
  `legacyDarkHairlineFaint`; day-cell fills @ 0.04 and borders
  @ 0.05 → `legacyDarkHairlineFaint`; neutral button fills
  @ 0.08 → `legacyDarkHairline`.
- Left: L797/808 and L1075/1084 `Colors.white` — foreground +
  spinner on the two primary-fill buttons. Class 5.

### reminders_screen.dart — CHANGED (commit b58b299b)
- Reminder card border white @ 0.04 → `legacyDarkHairlineFaint`
  (class 4).
- FAB icon + label `Colors.white` (L831, L834) — on the primary
  FloatingActionButton. Class 5, left.

### research_screen.dart — no changes
- L381 `foregroundColor: Colors.white` — on primary. Class 5, left.

### sleep_screen.dart — no changes
- L1315 selected label `Colors.white` — the selected compare
  button's fill is `NotelColors.primary` (verified in context).
  Class 5, left.

### tips_tricks_screen.dart — no changes
- L650, L777, L780 `Colors.white` — on primary buttons. Class 5,
  left.

### tool_placeholder_screen.dart — examined, no hits
Token-routed already.

### tools_screen.dart — CHANGED (commit 67f27941)
- Drag handle `Color(0x997C6EFF)` — exactly `primary` @ 60%.
  Class 1: routed to `NotelColors.primary.withValues(alpha: 0.6)`;
  const dropped on the `Positioned`/`Icon` (const rule).
- Done chip icon + label `Colors.white` (L316, L323) — on a
  `NotelColors.primary` chip. Class 5, left.
- Drag shadow `Colors.black @ 0.4` (L487) — a drop shadow;
  black-alpha shadows are theme-stable (they darken whatever is
  beneath in both themes). Left, noted.

### trends_screen.dart — no changes
- L315 `foregroundColor: Colors.white` — on primary. Class 5, left.
- L931 `Colors.black54` — the modal barrier behind the
  most-used-symptoms dialog (the dialog itself is
  `NotelColors.surface`). SKIPPED, ambiguous: class 4 names
  scrims, but `legacyDarkScrim`'s light counterpart is a white
  @ 65% wash whose in-app uses are on-glass overlays and card
  shadows (vitals strip, email verification) — as a modal barrier
  it would invert the barrier's dimming function in light mode.
  A black barrier dims content correctly in both themes. Left
  for Vera's call.

## features/onboarding

### conditions_screen.dart — examined, no hits
Token-routed already (28 `NotelColors` reads, zero literals).

### consent_screen.dart — no changes
- Card shadow `Color(0x33000000)` (black @ 20%) — a drop shadow,
  left (theme-stable; its value also differs from the
  `legacyDarkScrim` card-shadow precedent at black @ 30%, so
  routing would change the elevation read — noted for Vera).
- L282 `foregroundColor: Colors.white` — on the primary
  FilledButton. Class 5, left.

### consultation_intro_screen.dart — no changes
- Gradient stop `0xFFA566FF` — decorative radial glow with
  `primary` (class 3 decorative), left.
- Icon-bubble fills `0xFFEC4899` (= `NotelColors.chipPink` value),
  `0xFFA855F7` (= `chipPurple` value), `0xFF8B5CF6`, `0xFF22C55E`
  — colored discs that ship with the white icon on them
  (class 2 pairs), left. The two brand-chip duplicates were NOT
  token-routed: the file does not import the tokens for these
  const bubbles and the values ride as a set of four category
  hues; noted here for the record.
- Bubble border `Colors.white @ 0.6` + icon `Colors.white` — part
  of the same on-disc pair (class 2), left.

### gems_onboarding_screen.dart — no changes
- Card icon hues `0xFFFF7043` (streak), `0xFF4FC3F7` (freeze) —
  category icon colors on `surfaceHigh` discs (class 3), left.
  The light blue on the light disc is low-contrast for a 28dp
  glyph — FLAGGED with the data-hue follow-up.

### membership_onboarding_screen.dart — CHANGED (commit 0a7680a8)
- Fine print `Color(0xBF7A8FAF)` ×2 (billed-by lines, 11px text
  on the page background) — class 1 text role → 
  `NotelColors.textSecondary`; consts dropped (const rule).
- Included check `Color(0xFF4CAF50)` — semantic icon on a palette
  surface → `NotelColors.success`; const dropped.
- Premium glyph `Colors.white` — its fill is a radial gradient
  from `primary @ 0.6` INTO `NotelColors.surface`, i.e. the fill
  itself is theme-coupled, so the pair is not self-contained;
  in light the glyph centre lands on near-white. Routed to
  `NotelColors.textPrimary` (dark value `#F5F5F7` ≈ white, so
  dark rendering is unchanged); const dropped. Judgment call,
  flagged for Vera.
- L350/359 `Colors.white` — on the primary FilledButton.
  Class 5, left.

### notification_onboarding_screen.dart — examined, no hits
Token-routed already.

### onboarding_connections_screen.dart — no changes
- L279 `foregroundColor: Colors.white` — on primary. Class 5, left.
- Icon-disc fills `0xFFEC407A`, `0xFF5C6BC0` + white icon (L524) —
  class 2 pairs (disc ships with its icon), left.

### onboarding_flow.dart — examined, no hits
No color references (flow wiring only).

### onboarding_header.dart — no changes
- L212/230 `Colors.white` — FilledButton foreground + bold label
  on `NotelColors.primary`. Class 5, left.

### post_onboarding_notification_card.dart — no changes
- L95 `foregroundColor: Colors.white` — on primary. Class 5, left.

### profile_setup_screen.dart — CHANGED (commit 0a7680a8)
- Word-count feedback colors are semantic TEXT on a surface
  (the same switch already returns `textSecondary`, `primary`,
  and `success` tokens for its other states): `0xFFFF9800` →
  `NotelColors.warning`, `0xFF0288D1` → `NotelColors.info`,
  `0xFF689F38` → `NotelColors.success` (class 3 exception).
- Button whites (L435, L447, L455/456) — on the primary
  FilledButton, including its disabled state (white @ 0.6 on
  `primary @ 0.4`; disabled states are AA-exempt and the ink
  ships with the primary fill family). Class 5/2, left.

### setup_loading_screen.dart — no changes
- Radial gradient `0xFFE8D5FF`, `0xB37C6EFF` (= primary @ 70%),
  `NotelColors.primary` — decorative brand glow (class 3),
  left.

### welcome_screen.dart — no changes
- L146 `foregroundColor: Colors.white` — on primary. Class 5, left.
- Callout icon `Colors.white` (L319) — on gradient discs filled
  from token colors (`info`, `chipPurple`). Class 2 pair, left.

## features/quicklog

### history_screen.dart — CHANGED (commit 95510af6)
- `_chipInk = Color(0xFF0A0A0E)` — exactly `NotelColors.onPrimary`
  (the Settings exemplar token-routed its `_chipInk` the same
  way). Class 1: routed to `NotelColors.onPrimary`; it is a
  `static const` token, so no de-const was needed.
- Detail dialog (surface is `NotelColors.surface`): drag handle
  white @ 0.18 → `legacyDarkDivider`; divider white @ 0.07 →
  `legacyDarkHairlineFaint`; Close button fill white @ 0.05 →
  `legacyDarkHairlineFaint`, its border white @ 0.10 →
  `legacyDarkHairline`. Class 4.
- Left: selected category chip check + label `Colors.white`
  (L1715, L1723) on a `NotelColors.primary` fill — class 5;
  L962/1855/1865 whites on primary buttons — class 5.

### quick_log_screen.dart — CHANGED (commit 95510af6)
- `_chipInk` → `NotelColors.onPrimary` (same as history).
- Left: L1043 white on primary (class 5); L1611/1612 white +
  white @ 0.5 on the Log button whose fill is the category's
  data color (`activeCatColor`) — class 2 pair, left. Noted
  tension: the category chips in the same file use `_chipInk`
  (dark ink) on those fills per the R49 audit, while the Log
  button uses white; changing the button's ink is a design call
  beyond literal classification — flagged for Vera/Juno.

## features/shell — MIXED-GLASS CHECK (explicit, per brief)

No file in `features/shell` mixes `LabBlackColors` surfaces with
`NotelColors` text or raw literals in a shared component. Details:

### heart_sleep_mode.dart — examined, no hits (enum only).

### main_shell.dart — examined, no hits
One `NotelColors` read (the resolved `background` token for the
shell scaffold, per its own comment); zero literals. It mounts
the three nav styles; it does not mix their internals.

### nav_dock.dart — no changes (pure Lab glass)
Reads `LabBlackColors` only (10 reads, zero `NotelColors`). The
single literal, `Color(0x00FFFFFF)` (L363), is the transparent
endpoint of the `glassSheen` gradient — part of the Lab glass
recipe. Internally consistent dark glass in both themes.
Left alone per the shell caution.

### nav_dock_glass.dart — no changes (pure Lab glass family)
Dock-local liquid-glass material (`NavDockLiquidGlass`): tint
gradient `0x802E2E2E` / `0x6B262626` / `0x5A1C1C1C` and rim
`0x80FFFFFF` / `0x2EFFFFFF` / `0x1AFFFFFF` are the recipe's own
constants (dark tint + light rim ship together as one material,
documented in the file as a deliberate dock-local retune); it
reads `LabBlackColors` for the blur sigma and no `NotelColors`.
Left alone per the shell caution.

### nav_dock_glass_light.dart — examined, no hits
No literals; a named wrapper mounting `NavDock` on its legacy
Lab path. Its doc comments reference `LabBlackColors` tokens
only.

### nav_dock_solid.dart — no changes — FLAGGED for Vera
This file reads NEITHER `LabBlackColors` NOR `NotelColors`: it
is a third, self-contained dock material (the founder-approved
Withings-style Solid style) with its own constants — charcoal
gradient `0xFF2B2B30` → `0xFF232327`, capsule `0xFF3E3E44`,
top line white @ 10%, border white @ 9%, shadow black @ 45%,
selected ink `0xFFFFFFFF`, unselected ink `0xFFC6C6CE`. The
dock styles are a user preference independent of the app theme
(main_shell mounts by nav style, not brightness), and every
text color ships on this material's own dark fills (class 2
reasoning). Left untouched, but called out explicitly because
it falls outside the brief's "reads LabBlackColors only"
description — Vera to confirm the leave.

## features/splash

### splash_screen.dart — CHANGED (commit e7ef7659)
- Title `Color(0xFF7C6EFF)` — exactly the brand primary.
  Class 1: routed to `NotelColors.primary` (static const, so
  the `const Text` stands).
- Tagline `Color(0xFF7A8FAF)` — the file's own doc names it the
  native secondary-text value, rendered on
  `NotelColors.background`. Class 1 text role → 
  `NotelColors.textSecondary`; const dropped on that `Text`
  (const rule). Dark-mode note: secondary text shifts from the
  slate-blue native value to the palette's neutral `#9A9AA3` —
  that IS the app's secondary-text token; flagged for Vera's
  visual check.

## Verification

- Post-sweep grep: no `Color(0x` / `Colors.white` / `Colors.black`
  remains in scope except the leaves documented above (each file's
  remaining hits were re-read and matched to its log entry).
- `flutter analyze`: the full-package run was OOM-killed by this
  VM (analysis server exit -9, 6 GB cell, other agents' Flutter
  processes resident) before emitting diagnostics. The scoped
  re-run over all five Scope B directories (`flutter analyze
  --no-pub lib/src/features/tools lib/src/features/onboarding
  lib/src/features/quicklog lib/src/features/shell
  lib/src/features/splash`) completed: **No issues found.**
- Tests (`flutter test --no-pub -j 1`, TMPDIR set per the brief):
  - `theme_mode_test.dart` — **11/11 passed, EXIT=0** (palette
    byte-identity + AA pins, startup modes, live switch, SYSTEM).
  - Medications batch (`medications_r39`, `medications_edit_r46`,
    `meds_drawer`, `medication_change_capture`) — **66 passed,
    EXIT=0**.
  - Onboarding/tools batch (`onboarding_flow3`, `onboarding_r32`,
    `onboarding_no_seeds`, `tools_screen_test`,
    `food_persist_gate_5c`, `reminder_toggle_repro`) — **105
    passed, EXIT=0**.
  - Quicklog batch (`history_dialog_polish`, `history_edit_r42`,
    `history_search_clear`, `quick_log_archive_r63`,
    `quick_log_dictation`) — PARTIAL: three attempts were killed
    by this VM's memory ceiling while other crews' Flutter jobs
    saturated the box (harness/channel errors, never an assertion
    failure). Best run: `history_dialog_polish` completed with
    all tests passing (including the 360dp detail-dialog render
    test that exercises the routed drag handle / divider / Close
    button) and `history_edit_r42` was mid-file at +20 with zero
    failures when the run died. `history_search_clear`,
    `quick_log_archive_r63`, and `quick_log_dictation` never
    completed a run — no verdict either way.
  - The full suite was not run (same environment ceiling).

## What I did NOT verify

- No screenshots in Light or Dark for any converted screen
  (PATTERN's per-screen Juno §2b gate) — no capture harness run
  in this worktree; the merged-diff review still needs them,
  above all project_focus (card fill change), membership
  (premium glyph), and splash (tagline hue shift in dark).
- No on-device or emulator run of any screen in either theme.
- Contrast was not recomputed pair-by-pair for the routed
  hairline alphas; the routing follows the palette's own
  AA-verified token family and the phase-1 precedent, but the
  exact effective-surface pairs were not re-measured.
- The full test suite was not run (see Verification), and three
  quicklog test files never completed a run for environment
  reasons — their verdicts are open, not passing.
- The data-hue AA follow-ups (body-region hues as text,
  key_metrics tile hues, community streak orange as text,
  gems_onboarding freeze icon) were identified, not fixed:
  they need light-variant palette decisions that are outside
  Scope B's file areas.
- `nav_dock_solid.dart`'s leave and the `trends_screen.dart`
  black54 leave are judgment calls documented above, not
  rulings.
