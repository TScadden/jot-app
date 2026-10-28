import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/features/home/feeling_checkin_card.dart'
    show feelingDayStart;
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Phase 1, item 1 — flare-day fast logging (spec
/// `phase1-item1-flare-logging-spec.md`, Oct 28, 2026).
///
/// The user DECLARES a flare day; Tabs never detects, predicts, or
/// infers one. Three taps from Home: open the sheet, pick a severity
/// word, pick a type word (or commit severity-only) — done. The
/// record is an ordinary [QuickLogEntry] in the existing Symptoms
/// category, identified by the reserved chip tag [flareTag], written
/// through the shipped VC 100107 optimistic outbox (durable local
/// stage first, background push, per-entry sync badge in History /
/// Quick Log). No new store, no new endpoint, no category writes.
///
/// All user-visible strings are Juno's reviewed verbatim set (spec
/// §3). Do not paraphrase them.

// ── Pinned vocabularies (spec §3 items 4/6, §4.2; founder Q1/Q3) ────

/// Reserved tag on every flare record (spec §4.2).
const String flareTag = 'Flare Day';

/// The existing category the record files under (founder Q4).
const String flareCategoryName = 'Symptoms';

/// Fallback id for [resolveFlareCategoryId]: used ONLY when a pulled
/// category actually carries id 1 (resolveSummaryCategoryId
/// semantics — NOT the migraine chain's unconditional `?? 1`).
const int flareCategoryFallbackId = 1;

/// Severity words, in sheet order (spec §3 item 4).
const List<String> flareSeverities = ['Rough', 'Bad', 'Really bad'];

/// Type words, in sheet order (spec §3 item 6).
const List<String> flareTypes = ['Dizzy', 'Pain', 'Fog', 'Crash'];

/// Icon per type word (spec §2 step 3: icon+label options).
const Map<String, IconData> flareTypeIcons = {
  'Dizzy': Icons.blur_circular,
  'Pain': Icons.healing,
  'Fog': Icons.cloud,
  'Crash': Icons.battery_alert,
};

/// Accessibility label for a severity option (spec §3 item 10):
/// `Rough, severity 1 of 3` / `Bad, severity 2 of 3` /
/// `Really bad, severity 3 of 3`.
String flareSeveritySemantics(String severity) {
  final index = flareSeverities.indexOf(severity);
  return '$severity, severity ${index + 1} of 3';
}

/// The logged-state label (spec §3 item 9):
/// `Flare logged · {severity}` — middle-dot separator, verbatim.
String flareLoggedLabel(String severity) => 'Flare logged · $severity';

// ── Category resolution (spec §4.2, founder Q4) ──────────────────────

/// Resolves the Symptoms category id from the pulled category set:
/// exact name first, then fallback id 1 ONLY when a pulled category
/// actually carries it. Null on a double miss — the caller does not
/// render the button (the check-in's hide-rather-than-misfile
/// honesty pattern).
int? resolveFlareCategoryId(List<QuickLogCategory> categories) =>
    resolveSummaryCategoryId(
      categories,
      name: flareCategoryName,
      fallbackId: flareCategoryFallbackId,
    );

// ── Chip parsing (spec §4.2; defensive, §1.3) ────────────────────────

/// Parses an entry's raw chips string into a chip list. The flare
/// writer uses the check-in's JSON-list form; other writers in the
/// tree use a `', '`-joined string, and pulls can carry a bare-list
/// rendering. All three shapes parse to the same list so identity
/// checks never misclassify: an ordinary Symptoms entry whose joined
/// chips are `Headache, Pain` yields `[Headache, Pain]` — no
/// reserved tag, never a flare record. Never throws.
List<String> parseFlareChips(String chips) {
  final raw = chips.trim();
  if (raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return [
        for (final c in decoded)
          if ('$c'.trim().isNotEmpty) '$c'.trim(),
      ];
    }
  } catch (_) {
    // Fall through to the joined / bare-list shapes.
  }
  var body = raw;
  if (body.startsWith('[') && body.endsWith(']')) {
    body = body.substring(1, body.length - 1);
  }
  return [
    for (final part in body.split(','))
      if (part.trim().replaceAll('"', '').trim().isNotEmpty)
        part.trim().replaceAll('"', '').trim(),
  ];
}

/// True when [chips] (raw string) parses to a list containing the
/// reserved [flareTag].
bool chipsContainFlareTag(String chips) =>
    parseFlareChips(chips).contains(flareTag);

/// The severity word carried by a flare record's chips, or null when
/// the parsed list holds no word from the pinned severity vocabulary.
String? flareSeverityOf(QuickLogEntry entry) {
  for (final chip in parseFlareChips(entry.chips)) {
    if (flareSeverities.contains(chip)) return chip;
  }
  return null;
}

/// The type words carried by a flare record's chips (pinned
/// vocabulary only), in chip order.
List<String> flareTypesOf(QuickLogEntry entry) => [
      for (final chip in parseFlareChips(entry.chips))
        if (flareTypes.contains(chip)) chip,
    ];

// ── Identity (spec §4.2; mirrors hasFeelingCheckIn) ──────────────────

/// The current energy day's flare record, or null: an entry is the
/// day's flare record iff its categoryId equals the resolved
/// Symptoms id, its parsed chip list contains [flareTag], and its
/// timestamp falls inside the current energy day (04:00 local start,
/// the feelingDayStart precedent). When several match (should not
/// happen — one record per day, founder Q2), the newest wins.
QuickLogEntry? findFlareRecord(
  List<QuickLogEntry> entries, {
  required int symptomsCategoryId,
  DateTime? now,
}) {
  final start = feelingDayStart(now ?? DateTime.now());
  final startMs = start.millisecondsSinceEpoch;
  final endMs = start.add(const Duration(days: 1)).millisecondsSinceEpoch;
  QuickLogEntry? found;
  for (final e in entries) {
    if (e.categoryId != symptomsCategoryId) continue;
    if (e.timestamp < startMs || e.timestamp >= endMs) continue;
    if (!chipsContainFlareTag(e.chips)) continue;
    if (found == null || e.timestamp > found.timestamp) found = e;
  }
  return found;
}

/// Whether a flare record exists for the current energy day.
bool hasFlareToday(
  List<QuickLogEntry> entries, {
  required int symptomsCategoryId,
  DateTime? now,
}) =>
    findFlareRecord(entries,
        symptomsCategoryId: symptomsCategoryId, now: now) !=
    null;

// ── Record building (spec §4.2, §3 item 11) ──────────────────────────

/// The entry body for a flare commit (spec §3 item 11): typed —
/// `Flare day · {severity} · {type}`; severity-only —
/// `Flare day · {severity}`. Middle-dot separators, verbatim.
String flareBody({required String severity, String? type}) =>
    type == null ? 'Flare day · $severity' : 'Flare day · $severity · $type';

/// The chips string for a flare commit: the check-in's JSON-list
/// form — `["Flare Day", severity]` or
/// `["Flare Day", severity, type]` (NOT the `', '`-joined form).
String flareChips({required String severity, String? type}) => jsonEncode(
      [flareTag, severity, ?type],
    );

/// Builds the exact entry a flare commit writes. [id] comes from the
/// outbox's post-load allocation (VC 100107 mechanism — never a
/// synchronous max+1 here). Timestamp is the commit time.
QuickLogEntry buildFlareEntry({
  required int id,
  required int categoryId,
  required String severity,
  String? type,
  DateTime? now,
}) {
  return QuickLogEntry(
    id: id,
    categoryId: categoryId,
    body: flareBody(severity: severity, type: type),
    chips: flareChips(severity: severity, type: type),
    manualText: '',
    timestamp: (now ?? DateTime.now()).millisecondsSinceEpoch,
  );
}

/// Amends an existing flare record in place (founder Q2): same id,
/// same timestamp, same category — new severity/type in body and
/// chips. `updatedAt` is stamped fresh by `toSyncJson()` at push
/// time, and the server upsert on `(user_id, local_id)` makes this a
/// single-record update, never a duplicate.
QuickLogEntry amendFlareEntry(
  QuickLogEntry existing, {
  required String severity,
  String? type,
}) {
  return existing.copyWith(
    body: flareBody(severity: severity, type: type),
    chips: flareChips(severity: severity, type: type),
    manualText: '',
  );
}

// ── Home button (spec §2 step 1, §3 items 1/9/10) ────────────────────

/// The persistent Home flare button. Un-logged it reads `Bad day`
/// (semantics `Log a flare day`, spec §3 item 10); once today's
/// record is written locally it reads `Flare logged · {severity}`
/// (item 9). The logged label sits in a live region, so the state
/// change itself announces the item 9 label to assistive technology
/// — Juno §3.3a: the logged state IS the confirmation, and there is
/// no toast anywhere in this flow.
class FlareDayButton extends StatelessWidget {
  /// Today's logged severity, or null when no flare is logged for
  /// the current energy day.
  final String? loggedSeverity;
  final VoidCallback onTap;

  const FlareDayButton({
    super.key,
    required this.loggedSeverity,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final logged = loggedSeverity != null;
    final label = logged ? flareLoggedLabel(loggedSeverity!) : 'Bad day';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Semantics(
        button: true,
        // Juno §3.3a: on commit the label becomes the item 9 logged
        // label inside a live region — assistive technology
        // announces it, the non-visual equivalent of the sighted
        // state change. Before commit the label is item 10's
        // `Log a flare day`.
        liveRegion: logged,
        label: logged ? label : 'Log a flare day',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
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
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  logged ? Icons.check_circle : Icons.cloud,
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Flare sheet (spec §2 steps 2–4, §3 items 2–7/10) ─────────────────

/// Commit callback for the sheet: Home stages the record through
/// the outbox and returns true only when the LOCAL write succeeded
/// (Juno §3.3b). The sheet closes on true; on false it stays open
/// with the app's existing generic save-error copy (below).
typedef FlareCommit = Future<bool> Function({
  required String severity,
  String? type,
});

/// The generic save-failure copy Quick Log already uses for a failed
/// local stage (quick_log_screen.dart) — reused verbatim, per Juno
/// §3.3b's "no flare-specific failure string" ruling.
const String flareStageFailureCopy =
    "Couldn't save that entry on this device. Try again.";

/// Opens the flare sheet. Dismissal (back / scrim / swipe) writes
/// nothing. There is no auto-dismiss timer and no entrance/exit
/// animation beyond the platform sheet itself, so reduced-motion
/// users get the same instant content swaps as the rest of Home.
Future<void> showFlareDaySheet({
  required BuildContext context,
  required FlareCommit onCommit,
  String? initialSeverity,
  String? initialType,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: NotelColors.surface,
    isScrollControlled: true,
    builder: (_) => FlareDaySheet(
      onCommit: onCommit,
      initialSeverity: initialSeverity,
      initialType: initialType,
    ),
  );
}

/// The two-step flare sheet: severity (step 1) advances to type
/// (step 2); a type tap — or `Just log this` — commits immediately.
/// No review screen, no save button.
class FlareDaySheet extends StatefulWidget {
  final FlareCommit onCommit;

  /// Prefill from today's record when the sheet is re-opened to
  /// amend (spec §2.6): the severity step opens with the logged
  /// severity selected, the type step with the logged type selected.
  final String? initialSeverity;
  final String? initialType;

  const FlareDaySheet({
    super.key,
    required this.onCommit,
    this.initialSeverity,
    this.initialType,
  });

  @override
  State<FlareDaySheet> createState() => _FlareDaySheetState();
}

class _FlareDaySheetState extends State<FlareDaySheet> {
  int _step = 0;
  String? _severity;
  String? _type;
  bool _committing = false;
  bool _commitFailed = false;

  @override
  void initState() {
    super.initState();
    _severity = widget.initialSeverity;
    _type = widget.initialType;
  }

  Future<void> _commit(String? type) async {
    final severity = _severity;
    if (severity == null || _committing) return;
    setState(() {
      _committing = true;
      _commitFailed = false;
    });
    bool ok;
    try {
      ok = await widget.onCommit(severity: severity, type: type);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      // Local write failed (Juno §3.3b): nothing was logged, the
      // sheet stays open so the user can retry, and the failure
      // surfaces through the existing generic copy — never a
      // flare-specific string, and the button stays un-logged.
      setState(() {
        _committing = false;
        _commitFailed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Flare day',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: NotelColors.textPrimary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              if (_step == 0) ..._severityStep() else ..._typeStep(),
              if (_commitFailed) ...[
                const SizedBox(height: 12),
                const Text(
                  flareStageFailureCopy,
                  style: TextStyle(
                    color: NotelColors.error,
                    fontSize: 13,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _severityStep() {
    return [
      const Text(
        'How bad is it today?',
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: NotelColors.textSecondary,
        ),
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 12),
      for (final severity in flareSeverities) ...[
        _FlareOption(
          label: severity,
          semanticsLabel: flareSeveritySemantics(severity),
          selected: _severity == severity,
          onTap: _committing
              ? null
              : () => setState(() {
                    _severity = severity;
                    _step = 1;
                  }),
        ),
        const SizedBox(height: 8),
      ],
    ];
  }

  List<Widget> _typeStep() {
    return [
      const Text(
        'What kind of bad?',
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: NotelColors.textSecondary,
        ),
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(child: _typeOption(flareTypes[0])),
          const SizedBox(width: 8),
          Expanded(child: _typeOption(flareTypes[1])),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(child: _typeOption(flareTypes[2])),
          const SizedBox(width: 8),
          Expanded(child: _typeOption(flareTypes[3])),
        ],
      ),
      const SizedBox(height: 8),
      _FlareOption(
        label: 'Just log this',
        semanticsLabel: 'Just log this',
        selected: false,
        onTap: _committing ? null : () => _commit(null),
      ),
    ];
  }

  Widget _typeOption(String type) {
    return _FlareOption(
      label: type,
      // Spec §3 item 10: type icon semantics are the type words.
      semanticsLabel: type,
      icon: flareTypeIcons[type],
      selected: _type == type,
      onTap: _committing ? null : () => _commit(type),
    );
  }
}

/// One large sheet option. Minimum height 56dp — every target in
/// the flow is ≥48dp (spec §2). Selected state (amend prefill) fills
/// Tabs purple like the check-in's pressed buttons.
class _FlareOption extends StatelessWidget {
  final String label;
  final String semanticsLabel;
  final IconData? icon;
  final bool selected;
  final VoidCallback? onTap;

  const _FlareOption({
    required this.label,
    required this.semanticsLabel,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticsLabel,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? NotelColors.primary : NotelColors.surfaceHigh,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? NotelColors.primary
                  : NotelColors.primary.withValues(alpha: 0.25),
              width: 1,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 22,
                  color: selected ? Colors.white : NotelColors.textSecondary,
                ),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color:
                        selected ? Colors.white : NotelColors.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
