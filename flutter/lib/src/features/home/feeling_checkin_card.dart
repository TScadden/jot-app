import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 21 — "How are you feeling?" energy check-in card.
///
/// Pixel/logic port of native `EnergyCheckInCard.kt` +
/// `EnergyCheckInViewModel.kt` (Tabs Lab, Sep 2026). The card is the
/// FIRST item on the Home ("Today") screen, above the vitals strip
/// (native `TodayScreen.kt` LazyColumn item 0).
///
/// Native spec (extracted from Kotlin source, never screenshots):
/// - Surface: fillMaxWidth, outer padding h16/v8, RoundedCornerShape
///   16dp, fill NotelPrimary @ 7%, border 1dp NotelPrimary @ 22%.
/// - Inner padding v14/h16, content centered. Title
///   "How are you feeling?" 13sp Medium, NotelTextSecondary.
/// - 10dp spacer, then a SpaceEvenly row of five 48dp buttons,
///   RoundedCornerShape(Radii.chip = 12dp), fill NotelSurfaceHigh,
///   border 1dp NotelBorder (dark palette: NotelPrimary @ 25%), number
///   16sp SemiBold NotelTextSecondary. While PRESSED the button fills
///   NotelPrimary, its border turns NotelPrimary, and the number turns
///   white (NotelOnAccent). No ripple (native indication = null).
///   Semantics: "Energy N of 5", Role.Button.
/// - Enter animation: slide in from -fullWidth + fade, 400ms,
///   LinearOutSlowIn. Exit: slide out to -fullWidth + fade, 350ms,
///   FastOutLinearIn (the "filed away" feel).
///
/// Behavior (native `EnergyCheckInViewModel`):
/// - Visible ONLY while no check-in entry exists for the current
///   "energy day" (the day starting 04:00 local). There is NO selected
///   state, NO locked card, NO edit affordance: one tap logs the entry
///   and the card slides away for the rest of the energy day. Deleting
///   the entry (History) makes the card reappear.
/// - One tap writes a real log entry: category = "Mood & Energy"
///   (native slug "mood", fallback id 6), body "Feeling: N/5 Today",
///   chips `["Daily Ranking"]` (the locked, uneditable tag),
///   manualText "". Native also stamps source "Energy check-in"
///   locally, but the sync DTO (`LogEntryDtoModel`) has NO source
///   field — it never reaches the server, and native's own
///   pull-restore recreates entries with source = null. The synced,
///   cross-install identity of a check-in entry is therefore exactly:
///   mood category + the reserved "Daily Ranking" chip. That is what
///   [hasFeelingCheckIn] checks against the pulled data.
/// - The entry is UNEDITABLE by design (native EntryDetail view model
///   early-returns every save path for check-in entries and the tag
///   can never be removed). This card mirrors that: after logging
///   there is nothing on Home to tap, change, or undo.

// ── Native constants (EnergyCheckInViewModel.kt) ─────────────────────

/// Reserved tag on every check-in entry (native `ENERGY_CHECKIN_TAG`).
const String feelingCheckInTag = 'Daily Ranking';

/// Seeded check-in category name (native `DefaultCategories`: id 6,
/// slug "mood"). The sync category DTO carries no slug, so the pulled
/// set is resolved by name first, then by the native fallback id.
const String feelingCategoryName = 'Mood & Energy';

/// Native `ENERGY_CATEGORY_FALLBACK_ID`.
const int feelingCategoryFallbackId = 6;

/// Native `ENERGY_DAY_START_HOUR` — the energy day starts 04:00 local.
const int feelingDayStartHour = 4;

/// Merged check-in flow (Juno ruling Oct 28, 2026, Item 1): the
/// founder-pinned number meanings, in number order. These words are
/// the visible captions under the buttons (Item 2 — every
/// presentation, no shortened forms), the severity vocabulary for
/// number-derived flares (1/2 only), and the summary words (Item 7).
const List<String> feelingWords = [
  'Really bad',
  'Rough',
  'Average',
  'Good',
  'Really good',
];

/// The Item 1 word for a ranking (1–5).
String feelingWordForRanking(int level) => feelingWords[level - 1];

/// Button semantics (Item 3): `Energy {n} of 5, {word}` with the
/// word lowercased — the lowercasing is confined to semantics.
String feelingButtonSemantics(int level) =>
    'Energy $level of 5, ${feelingWordForRanking(level).toLowerCase()}';

// ── Pure logic (ports of the native view model) ──────────────────────

/// Port of native `energyDayStart()`: 04:00 local today, or 04:00
/// yesterday when [now] is before 04:00.
DateTime feelingDayStart(DateTime now) {
  final date = now.hour < feelingDayStartHour
      ? DateTime(now.year, now.month, now.day - 1)
      : DateTime(now.year, now.month, now.day);
  return DateTime(date.year, date.month, date.day, feelingDayStartHour);
}

/// True when [chipsJson] (an entry's raw chips string) contains the
/// reserved "Daily Ranking" tag. Tolerant of the shapes the pull
/// actually sends (round 20): a JSON-array string, or a bare list
/// rendering. Never throws.
bool chipsContainFeelingTag(String chipsJson) {
  final raw = chipsJson.trim();
  if (raw.isEmpty) return false;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded.any((c) => '$c'.trim() == feelingCheckInTag);
    }
  } catch (_) {
    // Fall through to the substring check.
  }
  return raw.contains(feelingCheckInTag);
}

/// Port of the native visibility rule: a check-in exists for the
/// current energy day when an entry in the mood category carries the
/// "Daily Ranking" tag with a timestamp inside
/// [feelingDayStart, feelingDayStart + 1 day).
bool hasFeelingCheckIn(
  List<QuickLogEntry> entries, {
  required int moodCategoryId,
  DateTime? now,
}) =>
    findFeelingCheckInEntry(
      entries,
      moodCategoryId: moodCategoryId,
      now: now,
    ) !=
    null;

/// The current energy day's check-in entry, or null — the entry
/// [hasFeelingCheckIn] tests for, returned so the merged flow can
/// read today's ranking value off it. Newest wins when several
/// match (should not happen — one check-in per day).
QuickLogEntry? findFeelingCheckInEntry(
  List<QuickLogEntry> entries, {
  required int moodCategoryId,
  DateTime? now,
}) {
  final start = feelingDayStart(now ?? DateTime.now());
  final startMs = start.millisecondsSinceEpoch;
  final endMs = start.add(const Duration(days: 1)).millisecondsSinceEpoch;
  QuickLogEntry? found;
  for (final e in entries) {
    if (e.categoryId != moodCategoryId) continue;
    if (e.timestamp < startMs || e.timestamp >= endMs) continue;
    if (!chipsContainFeelingTag(e.chips)) continue;
    if (found == null || e.timestamp > found.timestamp) found = e;
  }
  return found;
}

/// Today's ranking (1–5) parsed from a check-in entry's body
/// `Feeling: N/5 Today` — the correlation engine's precedent
/// (`deriveFeelingByDay` matches `^Feeling: ([1-5])/5`). Null when
/// the body carries no ranking.
int? feelingRankingOf(QuickLogEntry entry) {
  final match = RegExp(r'^Feeling: ([1-5])/5\b').firstMatch(entry.body.trim());
  if (match == null) return null;
  return int.parse(match.group(1)!);
}

/// Resolves the Mood & Energy category id from the pulled category
/// set, mirroring native's slug lookup + fallback: by exact name
/// first, then the native fallback id when a category carries it.
/// Null when neither resolves — the caller hides the card rather than
/// writing into an unknown category.
int? resolveFeelingCategoryId(List<QuickLogCategory> categories) {
  for (final c in categories) {
    if (c.name.trim().toLowerCase() == feelingCategoryName.toLowerCase()) {
      return c.id;
    }
  }
  for (final c in categories) {
    if (c.id == feelingCategoryFallbackId) return c.id;
  }
  return null;
}

/// Builds the exact entry one tap writes (native `selectLevel`):
/// body "Feeling: N/5 Today", chips `["Daily Ranking"]`, manualText "".
/// [id] is REQUIRED and must come from the outbox's post-load
/// allocation (VC 100107 mechanism): the sync endpoint upserts on
/// (user_id, local_id), so a fresh id is mandatory (round 19 rule),
/// and a synchronous max+1 over a possibly-unloaded entry set is
/// exactly the allocation that mechanism abolished — there is no
/// fallback form of this builder.
QuickLogEntry buildFeelingEntry({
  required int level,
  required int categoryId,
  required int id,
  DateTime? now,
}) {
  return QuickLogEntry(
    id: id,
    categoryId: categoryId,
    body: 'Feeling: $level/5 Today',
    chips: jsonEncode(const [feelingCheckInTag]),
    manualText: '',
    timestamp: (now ?? DateTime.now()).millisecondsSinceEpoch,
  );
}

// ── Card widget ──────────────────────────────────────────────────────

/// The check-in card. The parent owns visibility state (driven by the
/// pulled entries); this widget owns the native enter/exit slide
/// animations. Set [leaving] after a successful log: the card slides
/// out left (350ms) and then calls [onExitComplete].
class FeelingCheckInCard extends StatefulWidget {
  final ValueChanged<int> onSelect;
  final bool leaving;
  final VoidCallback? onExitComplete;

  const FeelingCheckInCard({
    super.key,
    required this.onSelect,
    this.leaving = false,
    this.onExitComplete,
  });

  @override
  State<FeelingCheckInCard> createState() => _FeelingCheckInCardState();
}

class _FeelingCheckInCardState extends State<FeelingCheckInCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  // Reassigned once when the exit animation starts (different curve).
  late Animation<Offset> _slide;
  late Animation<double> _fade;
  bool _exitStarted = false;

  @override
  void initState() {
    super.initState();
    // Native enter: 400ms slideInHorizontally(-fullWidth) + fadeIn.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    final curved = CurvedAnimation(
      parent: _controller,
      // Compose LinearOutSlowInEasing = cubic-bezier(0.0, 0.0, 0.2, 1.0).
      curve: const Cubic(0.0, 0.0, 0.2, 1.0),
    );
    _slide = Tween<Offset>(
      begin: const Offset(-1, 0),
      end: Offset.zero,
    ).animate(curved);
    _fade = curved;
    _controller.forward();
  }

  @override
  void didUpdateWidget(covariant FeelingCheckInCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.leaving && !_exitStarted) {
      _exitStarted = true;
      // Audit 6c (Oct 27, 2026) — reduced motion: no exit slide/fade;
      // the card leaves instantly (final state rendered instantly,
      // the central-gate convention). Completion is posted to the
      // next frame so the parent's setState never lands mid-build.
      if (animationsDisabled(context)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onExitComplete?.call();
        });
        return;
      }
      // Native exit: 350ms slideOutHorizontally(-fullWidth) + fadeOut,
      // FastOutLinearInEasing.
      _controller.duration = const Duration(milliseconds: 350);
      final exit = CurvedAnimation(
        parent: _controller,
        // Compose FastOutLinearInEasing = cubic-bezier(0.4, 0.0, 1.0, 1.0).
        curve: const Cubic(0.4, 0.0, 1.0, 1.0),
      );
      setState(() {
        _slide = Tween<Offset>(
          begin: const Offset(-1, 0),
          end: Offset.zero,
        ).animate(exit);
        _fade = exit;
      });
      _controller.reverse().whenComplete(() {
        if (mounted) widget.onExitComplete?.call();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Audit 6c (Oct 27, 2026) — reduced motion: the enter slide+fade
    // (and the exit, handled in didUpdateWidget) are gated on the
    // central [animationsDisabled] check; the card renders its final
    // state instantly with no SlideTransition/FadeTransition applied,
    // matching StaggeredEntrance's gated build.
    if (animationsDisabled(context)) return _cardBody();
    return SlideTransition(
      position: _slide,
      child: FadeTransition(
        opacity: _fade,
        child: _cardBody(),
      ),
    );
  }

  Widget _cardBody() {
    return Padding(
          // Native Surface modifier: fillMaxWidth + padding h16/v8.
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Container(
            decoration: BoxDecoration(
              // NotelPrimary @ 7% fill, 1dp NotelPrimary @ 22% border.
              color: NotelColors.primary.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: NotelColors.primary.withValues(alpha: 0.22),
                width: 1,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Text(
                    'How are you feeling?',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var level = 1; level <= 5; level++)
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _FeelingNumberButton(
                                level: level,
                                onTap: widget.leaving
                                    ? null
                                    : () => widget.onSelect(level),
                              ),
                              const SizedBox(height: 4),
                              // Juno Item 2 — visible word captions
                              // under the buttons, on EVERY
                              // presentation, verbatim, no shortened
                              // forms. Load-bearing (binding
                              // condition 1): the tap is an informed
                              // declaration only because the meaning
                              // is printed before it.
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
              ),
            ),
          ),
    );
  }
}

/// Native `EnergyNumberButton`: flat 48dp square, radius Radii.chip
/// (12dp), NotelSurfaceHigh fill with a 1dp NotelBorder hairline
/// (dark palette border = NotelPrimary @ 25%); while pressed it fills
/// NotelPrimary with a white number. No ripple (indication = null).
class _FeelingNumberButton extends StatefulWidget {
  final int level;
  final VoidCallback? onTap;

  const _FeelingNumberButton({required this.level, required this.onTap});

  @override
  State<_FeelingNumberButton> createState() => _FeelingNumberButtonState();
}

class _FeelingNumberButtonState extends State<_FeelingNumberButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final pressed = _pressed;
    return Semantics(
      button: true,
      label: feelingButtonSemantics(widget.level),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.onTap == null
            ? null
            : (_) => setState(() => _pressed = true),
        onTapUp: widget.onTap == null
            ? null
            : (_) {
                setState(() => _pressed = false);
                widget.onTap!();
              },
        onTapCancel: widget.onTap == null
            ? null
            : () => setState(() => _pressed = false),
        child: Container(
          width: 48,
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: pressed ? NotelColors.primary : NotelColors.surfaceHigh,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: pressed
                  ? NotelColors.primary
                  // NotelBorder (dark palette) = NotelPrimary @ 25%.
                  : NotelColors.primary.withValues(alpha: 0.25),
              width: 1,
            ),
          ),
          child: Text(
            '${widget.level}',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: pressed ? Colors.white : NotelColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
