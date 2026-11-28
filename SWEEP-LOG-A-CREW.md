# Sweep Log — Scope A (crew/theme-sweep-a, Bram)

Scope: `flutter/lib/src/features/{home,heart,badges,connections,billing,auth}`
+ `flutter/lib/src/data/quick_log_models.dart`. Pattern: PATTERN.md
classes 1–5. Base: `feat/theme-mode` @ fa8549e5. Fresh sweep — the
quarantined `agy/theme-sweep-a` branch was never checked out, diffed,
read, or copied from.

Legend: **FIXED** = token-routed per class 1/4/5-complement;
**LEFT** = class 2/3/5 or never-touch, with reason.

## Named defects

- `features/home/streak_flame.dart` — unlit flame glyph
  `Color(0xFF8E97B8)` (~2.9:1 on the light background) → **FIXED**:
  `NotelColors.textSecondary`. Chosen over `streakGold`: the unlit
  glyph's role is a muted/grey glyph, not a gold value; textSecondary
  is the muted-ink token and passes AA in both palettes (dark
  #9A9AA3: 6.70:1 on surface; light #525266: 7.62:1 on surface,
  6.94:1 on background). Caveat: the widget still applies the
  founder-mock 0.45 opacity + desaturation filter over the glyph, so
  the *rendered* ink is fainter than the raw token ratio — that
  treatment is the recorded mock behavior and was not altered
  (color-only remit). Same literal in the Home pill copy
  (`vitals_strip.dart` `StreakPillFlame.unlitColor`) fixed the same
  way (const → getter).
- `features/home/weekly_snapshot_card.dart` — chart halo
  `Color(0xFFFFFFFF)` dot (invisible on the light card) → **FIXED**:
  `NotelColors.surface`. The halo's role is a separation ring in the
  card's own surface color between the data dot and the line; the
  surface token resolves white in light / #101013 in dark, which is
  exactly that role in both themes.

## Files changed (12)

### features/home/streak_flame.dart
- L88 `0xFF8E97B8` unlit glyph — class 1 → `textSecondary` (above).
- L27 `0xFFFF6A3D` lit-flame default (`litColor` param default) —
  class 3, LEFT: the flame's brand/data color, a large glyph (not
  text); also a public parameter default that must stay const.
- L137 `0xFF6EC6FF` freeze fill + L140 `0xFF0D1428` freeze glyph —
  class 2, LEFT: recorded self-contained pair ("used exactly" per
  the in-file founder ruling), ships with its fill in both themes.

### features/home/weekly_snapshot_card.dart
- L1000 `0xFFFFFFFF` chart halo — class 1 → `surface` (above).
  All other colors in the file already read tokens.

### features/home/vitals_strip.dart (phase-1 exemplar; residual hits)
- `StreakPillFlame.unlitColor 0xFF8E97B8` — class 1 → getter
  returning `textSecondary` (same defect as streak_flame).
- `StreakPillFlame.litColor 0xFFFF6A3D` — class 3, LEFT (flame brand
  glyph color, mirrors StreakFlame's lit default).
- `kGemCountColor` `0xFF5340D6`/`0xFFB9AFFF` — LEFT: the pattern's
  sanctioned brightness branch from phase 1, untouched.
- Chest badge `0xFFE39A3B` fill + `0xFF121B20` count ink — class 2,
  LEFT: self-contained pair (dark ink on amber disc).

### features/home/migraine_block.dart
- ReliefOption value text `Colors.white` (unconditional) — class 1
  BUG FOUND: unselected fill is `NotelColors.surface`, so the digit
  was white-on-white in light mode → **FIXED**:
  `selected ? Colors.white : NotelColors.textPrimary` (selected
  state keeps white on the primary fill, class 5; const dropped on
  the TextStyle per the const rule).
- `0xFF1F7A5C` End-attack green + its `Colors.white` label —
  class 2, LEFT: in-file comment records it as the Lab-verbatim
  low-stimulation treatment color kept for this control only.
- `Colors.white` ×4 on `NotelColors.primary` FilledButtons (Start
  attack, Save ×2, dialog Save) — class 5 founder exception
  (bold labels on primary), LEFT.
- `_AuraChip` selected `Colors.white` on primary — class 5, LEFT.

### features/home/weather_info_sheets.dart
Sheet background is `NotelColors.background` and `darkCard` fill is
`NotelColors.surface` (both palette surfaces), but every text color
was raw white — white-on-white throughout in light mode. All class 1
except the hairlines (class 4):
- Sheet title `Colors.white` → `textPrimary` (const dropped).
- `whiteBold()` helper `Colors.white` → `textPrimary`.
- `whiteFaint()` helper `Colors.white` @0.7 → `textSecondary`.
- `emojiRangeRow` / `dotRangeRow` label white @0.8 → `textPrimary`;
  value white @0.6 → `textSecondary`.
- Two in-card bold headers `Colors.white` → `textPrimary`.
- Card fill `0xFF1A1C1E` (one card hand-rolled instead of darkCard)
  → `NotelColors.surface` (class 1, card-surface role).
- `darkCard` border `Colors.white` @0.05 → `legacyDarkHairlineFaint`
  (class 4; dark value is the identical white-alpha, light value is
  the black-alpha counterpart).
  Helper names (`whiteBold` etc.) unchanged — renaming is not a
  color change; the names are now historical, like the
  `legacyDark*` tokens.

### features/home/weather_info_sheets2.dart
Same sheet system as above:
- `_protectionLevelCard` (fill already `NotelColors.surface`):
  border white @0.05 → `legacyDarkHairlineFaint` (class 4); title
  `Colors.white` → `textPrimary` (const dropped); description
  white @0.6 → `textSecondary`.
- UV row helper label white @0.8 → `textPrimary`, value white @0.6
  → `textSecondary`.
- Two card-header titles `Colors.white` (inside `const Row`s) →
  `textPrimary` (const dropped on both Rows).

### features/heart/heart_screen.dart
- `_chipInk = Color(0xFF0A0A0E)` — class 1 → `NotelColors.onPrimary`
  (byte-identical value; the token exists for exactly this role;
  top-level const → final per the const rule).
- Peak-marker core `Colors.white` (r=2 dot inside the
  `NotelColors.error` r=5 disc) — class 2, LEFT: ink on a colored
  fill that ships with the fill.

### features/connections/connect_ai_screen.dart
- `Color(0x807A8FAF)` ×3 — class 1: 14px empty-state TEXT on palette
  surfaces → `NotelColors.textSecondary` (const dropped on the
  wrapping Paddings).
- `foregroundColor: Color(0xFF0A0A0E)` ×3 on primary buttons —
  class 1 → `NotelColors.onPrimary` (byte-identical).

### features/connections/connections_screen.dart
- `Color(0x807A8FAF)` ×4 — class 1: empty-state text →
  `textSecondary` (const dropped on the wrapping Paddings).
- `Color(0xFF00B0B9)` — class 3, LEFT: Fitbit brand logo painter
  (data/brand color).
- `Colors.white` ×3 on primary ElevatedButtons (bold labels) —
  class 5, LEFT.

### features/billing/billing_plans_panel.dart
- `Color(0xBF7A8FAF)` ×2 — class 1: 11px legal/terms TEXT on a
  palette surface → `textSecondary` (const dropped on one Text and
  one TextStyle).
- `Colors.white` ×3 — class 5, LEFT: CTA foreground/spinner/icon on
  the primary FilledButton.

### features/billing/revenuecat_plans_panel.dart
- `Color(0xBF7A8FAF)` ×2 — class 1 → `textSecondary` (same as above).
- `Colors.white` ×3 — class 5, LEFT (primary CTA).

### data/quick_log_models.dart
- Category color fallback `Color(0xFF7C6EFF)` — class 1 →
  `NotelColors.primary` (byte-identical; parsed user colorHex values
  above it are data colors, untouched).

## Files examined, literals left (with classification)

### Self-contained dark design systems (class 2 at system level)
These screens paint their OWN background and read zero NotelColors
tokens; every literal pairs inside the system. Piecemeal token
routing would break them (e.g. duo muted text sits on duo navy
cards, not on palette surfaces). A light conversion needs new
palette tokens + a design decision — flagged for Vera/founder, out
of this sweep's color-only remit.

- `features/home/streak_screen.dart` — the "duo" streak system:
  `_duoBg 0xFF0A0A0B`, `_duoPrimary 0xFF7C6EFF`, `_duoPrimaryLt
  0xFF9D8FFF`, `_duoFreeze 0xFF6EC6FF`, `_duoFreezeChip 0xFF12314F`,
  `_duoText 0xFFF0EEFF`, `_duoMuted 0xFF9A9AA3`, `_duoCaption
  0xFF7E8898`, `_duoBorder 0xFF39434E`, `_duoBarDark 0xFF251B42`,
  `_duoNavyBtn 0xFF152040`, `_duoOnBright 0xFF150F24`, plus ~40
  in-system literals (slate text #69727E ×5, #59637F ×5, #A4A4AD ×4,
  error #FF6B6B ×3, #AAB3D0 ×3, dividers #2A343C ×3, navy fills
  #1F2A4A/#1B2547-family, light pill #EDEFF5 with dark ink
  #1B1430 pair, freeze pair #12314F/#6EC6FF, `Colors.white` ×2 on
  in-system bright fills). Scaffold bg = `_duoBg`. ALL LEFT.
- `features/home/friend_streak_invite_screen.dart` — same duo
  system (own `_duo*` constants, Scaffold bg `_duoBg`): 13 literals
  + `Colors.white` ×1 on the primary button. ALL LEFT, same reason.
- `features/home/chest_open_flow.dart` — self-contained chest-open
  ceremony stage (own Scaffold bg `0xFF121B20`, zero NotelColors):
  rarity hues `0xFFC9A7EB`/`0xFFA78BFA`/`0xFFFFD74A` (class 3 data),
  primary copies `0xFF7C6EFF` ×4 (== `NotelColors.primary`, but
  inside const/system artwork), glow/sparkle painters
  (`0xC7FFCD50`, `0xFFFFD54A`, `0xFFD8B660`), dot-state browns
  (`0xFFE39A3B`/`0xFF4A3A24`/`0xFF342C22`/`0xFFA89E94`), stage text
  whites/white70 on the dark stage, black-alpha shadows/scrims
  inside the stage artwork. ALL LEFT (class 2/3 system).
- `features/home/streak_share_card.dart` and
  `features/badges/badge_share_card.dart` — share cards rendered to
  a 1080×1080 PNG via RepaintBoundary: a fixed dark gradient artwork
  (`0xFF0D1428`/`0xFF080E1A`/`0xFF1B1440`, primary glow, #C9CEEA /
  #F0EEFF / flame #FF6B4A text on that artwork, black-alpha scrim).
  Exported image design, not a theme surface. ALL LEFT (class 2/3).

### Never-touch (PATTERN list)
- `features/home/streak_celebration_screen.dart` — Scaffold bg is
  `LabBlackColors.background` (the streak celebration backdrop).
  Its literals live on that backdrop: flame orange `0xFFFF6B4A` ×5
  (celebration accent/data), week-circle navy pair
  `0xFF1B2547`/`0xFF131C33`, outline `0xFF2A3560`, #C9CEEA ×2 beside
  `LabBlackColors.textSecondary`; `Colors.white` ×3 are on
  `NotelColors.primary` buttons (class 5 anyway). ALL LEFT.
- `features/home/daily_score_circle.dart` — Daily Score disc glass
  (`LabBlackColors`); `Colors.white` ×2 are the score number/label
  ink over the purple liquid fill, with an in-file measured
  rationale (white 3.80:1 on primary beats textPrimary 3.32:1;
  18.30:1 on the dark disc). LEFT per never-touch + class 2.

### Class 5 founder exception (white on primary fills) — LEFT
- `features/home/checkin_sheets.dart` — selected chip: white icon +
  16px w600 label on `NotelColors.primary` fill (unselected state
  already token-routed).
- `features/home/feeling_checkin_card.dart` — pressed digit on
  primary fill.
- `features/home/gems_sheet.dart`, `features/home/hc_repair_card.dart`
  (button fg + spinner), `features/home/intake_logging.dart` ×2,
  `features/badges/badges_screen.dart` ×3,
  `features/connections/health_connect_disclosure.dart`,
  `features/billing/billing_panel.dart` — button foregrounds /
  spinners / icons on primary fills, bold labels.

### Class 3 data colors — LEFT
- `features/badges/badge_widget.dart` — medal tier palettes
  (bronze/silver/gold/diamond/platinum dark/base/light triples,
  15 literals) are data; painter artwork on its own dark disc
  `0xFF0D1428`: black-alpha shading, white gloss highlights,
  `0xFFBEE6FC` sheen; the center icon's `Colors.white` is a
  ShaderMask source color (srcIn — replaced by the tier gradient,
  never rendered as white).
- `features/home/today_summary_card.dart` — `0xFFFFA500` snoozed-dose
  status icon (semantic status hue; not the `warning` token value).

### Class 4 examined, deliberately LEFT
- `features/auth/login_screen.dart` — card `BoxShadow` color
  `Color(0x4D000000)`: a shadow must stay dark in BOTH themes;
  routing it to `legacyDarkScrim` would resolve to the light
  palette's white-alpha scrim (0xA6FFFFFF) and paint a white glow
  instead of a shadow in light mode. Left raw; flagged for Vera —
  if a shadow token is wanted it belongs in the palettes, not in
  this sweep.

## Files examined, no hits (already fully token-routed)
features/home: bandit_reading_slot, checkin_summary_card,
chest_drop_presenter, chests_sheet, daily_score_screen,
daily_score_vocabulary, event_counter_rotator, flare_day_logging,
good_day_logging, grace_band, health_connect_banner,
home_checkin_strip, home_screen (phase-1 exemplar),
patterns_screen, streak_celebration_presenter, weather_sheet.
features/heart: heart_spike_review_screen.
features/badges: badge_strings.
features/auth: auth_top_logo_header, email_verification_screen.
features/billing / features/connections: none hit-free beyond those
listed above (billing_panel and health_connect_disclosure appear
under class 5).

## Verification
- Residual grep after the sweep: every remaining `Color(0x` /
  `Colors.white` / `Colors.black` in scope is itemized above.
- `flutter analyze` (whole worktree, TMPDIR on workspace disk):
  **No issues found.** The first pass flagged 6 `invalid_constant`
  errors from my changes (heart `_chipInk` use sites ×4, weather
  header Rows ×2); all fixed by dropping `const` per the PATTERN
  const rule (commit 8ed81aac), second pass clean.
- `flutter test --no-pub -j 1` (TMPDIR on workspace disk), 14 files
  covering the theme system and every changed area — **201 tests,
  all passed, exit 0 in each batch**:
  theme_mode, dark_theme_r28, lab_blackglass_theme, vitals_strip,
  gem_pill_fit, migraine_timer (+62); heart_r25, weather_sheet,
  weekly_snapshot (+55 with the theme-adjacent files);
  quick_log, billing_takeover, data_connections_tap,
  streak_render, badges_widget (+84).
- Environment note: three earlier test attempts died in the test
  *compiler* at load time (Dart compiler exited unexpectedly /
  OOM-killed) while other agents' Flutter processes shared this
  VM's 6 GB cell; no test had run in those attempts. The same
  theme_mode_test passed in the sibling sweep-B worktree during
  the same window, confirming an environment failure, not a code
  failure; the successful batches above ran single-job
  (`-j 1 --no-pub`) once contention cleared.

## What I did NOT verify
- No screenshots were taken of any screen in Light or Dark (the
  PATTERN per-screen ship gate / Juno §2b) — no emulator/device pass
  was run; contrast claims rest on the palette's published ratios
  and the token roles, not on rendered pixels.
- The duo streak screens, chest ceremony, celebration backdrop, and
  share cards still render dark in light mode by design of their
  self-contained systems; whether that is the intended product
  behavior is a founder/Vera decision, not verified here.
- The login card shadow decision (above) is my judgment call
  against a literal class-4 routing; not verified with Vera.
- Tests were run only for the suites named in Verification; widget
  appearance in the full app (theme-mode switching at runtime) was
  not exercised end-to-end.
