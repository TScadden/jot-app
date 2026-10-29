import 'package:flutter/material.dart';
import 'package:tabs_lab/src/features/home/flare_day_logging.dart';
import 'package:tabs_lab/src/features/home/good_day_logging.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Merged check-in flow — the follow-up and amend sheets (Juno
/// ruling Oct 28, 2026, Items 4/5/8/9/11).
///
/// Every string here is in Juno's FINAL VERBATIM STRING SET (§4)
/// and no others: no added headings, no explanatory lines, no
/// severity prompt in the number-origin kind sheet, `Bad` offered
/// nowhere. Commit callbacks return true only when the record's
/// LOCAL stage succeeded (per-record gate, Item 11): on false the
/// sheet stays open with the existing generic failure copy
/// ([flareStageFailureCopy]) and no logged state changes. No sheet
/// has an auto-dismiss timer; all targets are ≥48dp.

typedef KindCommit = Future<bool> Function(String kind);
typedef GoodCommit = Future<bool> Function(List<String> options);
typedef FlareUpsertCommit = Future<bool> Function({
  required String severity,
  String? type,
});

// ── Shared sheet pieces ─────────────────────────────────────────────

/// One large sheet option (≥48dp; this flow uses 56dp minimum).
/// Selected state fills Tabs purple, like the check-in's pressed
/// buttons and the old flare sheet's amend prefill.
class CheckInSheetOption extends StatelessWidget {
  final String label;
  final String semanticsLabel;
  final IconData? icon;
  final bool selected;
  final VoidCallback? onTap;

  const CheckInSheetOption({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    String? semanticsLabel,
    this.icon,
  }) : semanticsLabel = semanticsLabel ?? label;

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

Widget _sheetShell({
  required String title,
  required List<Widget> children,
  required bool commitFailed,
}) {
  return SafeArea(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: NotelColors.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ...children,
            if (commitFailed) ...[
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

const _promptStyle = TextStyle(
  fontSize: 15,
  fontWeight: FontWeight.w500,
  color: NotelColors.textSecondary,
);

/// The kind options block (prompt + four kinds in a 2×2 grid),
/// shared by the kind sheet and the amend sheet. [onTap] commits
/// immediately, per the flow's tap-to-commit pattern.
List<Widget> _kindOptions({
  required String? selectedKind,
  required bool committing,
  required void Function(String kind) onTap,
}) {
  Widget option(String type) => CheckInSheetOption(
        label: type,
        semanticsLabel: type,
        icon: flareTypeIcons[type],
        selected: selectedKind == type,
        onTap: committing ? null : () => onTap(type),
      );
  return [
    const Text(
      'What kind of bad?',
      style: _promptStyle,
      textAlign: TextAlign.center,
    ),
    const SizedBox(height: 12),
    Row(
      children: [
        Expanded(child: option(flareTypes[0])),
        const SizedBox(width: 8),
        Expanded(child: option(flareTypes[1])),
      ],
    ),
    const SizedBox(height: 8),
    Row(
      children: [
        Expanded(child: option(flareTypes[2])),
        const SizedBox(width: 8),
        Expanded(child: option(flareTypes[3])),
      ],
    ),
  ];
}

// ── Kind sheet — from a 1–2 tap (Item 4) ────────────────────────────

Future<void> showCheckInKindSheet({
  required BuildContext context,
  required KindCommit onKind,
  required Future<bool> Function() onJustLog,
  bool initialCommitFailed = false,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: NotelColors.surface,
    isScrollControlled: true,
    builder: (_) => CheckInKindSheet(
      onKind: onKind,
      onJustLog: onJustLog,
      initialCommitFailed: initialCommitFailed,
    ),
  );
}

/// Title `Flare day`, prompt `What kind of bad?`, the four kinds,
/// and `Just log this`. NO severity prompt or options — the number
/// already supplied the severity. The severity-only flare record
/// was staged before this sheet opened, so dismissal is a commit
/// path (Item 4): it leaves that record exactly as `Just log this`
/// does. When that pre-sheet stage FAILED, [initialCommitFailed]
/// opens the sheet already showing the existing generic failure
/// copy (Vera F1) — the user must never sit in this sheet believing
/// a severity-only record exists when it does not — and the caller
/// retries the severity-only stage once when the sheet closes
/// without a successful commit.
class CheckInKindSheet extends StatefulWidget {
  final KindCommit onKind;

  /// Commits severity-only. When the pre-sheet stage already
  /// succeeded this is a no-op that returns true; when it failed,
  /// this retries the creation as an upsert.
  final Future<bool> Function() onJustLog;

  /// True when the severity-only stage that ran before this sheet
  /// opened failed: the sheet opens with the generic failure copy
  /// already showing.
  final bool initialCommitFailed;

  const CheckInKindSheet({
    super.key,
    required this.onKind,
    required this.onJustLog,
    this.initialCommitFailed = false,
  });

  @override
  State<CheckInKindSheet> createState() => _CheckInKindSheetState();
}

class _CheckInKindSheetState extends State<CheckInKindSheet> {
  bool _committing = false;
  late bool _commitFailed = widget.initialCommitFailed;

  Future<void> _run(Future<bool> Function() commit) async {
    if (_committing) return;
    setState(() {
      _committing = true;
      _commitFailed = false;
    });
    bool ok;
    try {
      ok = await commit();
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _committing = false;
        _commitFailed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _sheetShell(
      title: 'Flare day',
      commitFailed: _commitFailed,
      children: [
        ..._kindOptions(
          selectedKind: null,
          committing: _committing,
          onTap: (kind) => _run(() => widget.onKind(kind)),
        ),
        const SizedBox(height: 8),
        CheckInSheetOption(
          label: 'Just log this',
          selected: false,
          onTap: _committing ? null : () => _run(widget.onJustLog),
        ),
      ],
    );
  }
}

// ── Good sheet — from a 4–5 tap (Item 5) ────────────────────────────

Future<void> showCheckInGoodSheet({
  required BuildContext context,
  required GoodCommit onCommit,
  Set<String> initialSelected = const {},
  bool allowEmptyDone = true,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: NotelColors.surface,
    isScrollControlled: true,
    builder: (_) => CheckInGoodSheet(
      onCommit: onCommit,
      initialSelected: initialSelected,
      allowEmptyDone: allowEmptyDone,
    ),
  );
}

/// Title `Good day`, prompt `What is good about today?`, the six
/// multi-select options in sheet order, commit `Done`. Fresh
/// sheets start empty — no option is ever pre-selected from data
/// (binding condition 6); the amend sheet passes today's OWN good
/// record's options as [initialSelected] (the flare §2.6
/// amend-prefill precedent).
///
/// Empty `Done` behaviour: on a fresh sheet ([allowEmptyDone]) it
/// closes and writes nothing, exactly like dismissal (Item 5). In
/// amend mode ([allowEmptyDone] false) `Done` is DISABLED at zero
/// selections — see the build report: History's entry-delete is a
/// private History-screen UI flow, not a reusable delete path, so
/// zero-option amend does not delete the record.
class CheckInGoodSheet extends StatefulWidget {
  final GoodCommit onCommit;
  final Set<String> initialSelected;
  final bool allowEmptyDone;

  const CheckInGoodSheet({
    super.key,
    required this.onCommit,
    this.initialSelected = const {},
    this.allowEmptyDone = true,
  });

  @override
  State<CheckInGoodSheet> createState() => _CheckInGoodSheetState();
}

class _CheckInGoodSheetState extends State<CheckInGoodSheet> {
  late final Set<String> _selected = {...widget.initialSelected};
  bool _committing = false;
  bool _commitFailed = false;

  bool get _doneEnabled =>
      !_committing && (widget.allowEmptyDone || _selected.isNotEmpty);

  Future<void> _done() async {
    if (_selected.isEmpty) {
      // Item 5: empty Done creates no record and no announcement —
      // equivalent to dismissal.
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _committing = true;
      _commitFailed = false;
    });
    bool ok;
    try {
      ok = await widget.onCommit(goodOptionsInSheetOrder(_selected));
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _committing = false;
        _commitFailed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _sheetShell(
      title: 'Good day',
      commitFailed: _commitFailed,
      children: [
        const Text(
          'What is good about today?',
          style: _promptStyle,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        for (final option in goodOptions) ...[
          CheckInSheetOption(
            label: option,
            selected: _selected.contains(option),
            onTap: _committing
                ? null
                : () => setState(() {
                      if (!_selected.remove(option)) _selected.add(option);
                    }),
          ),
          const SizedBox(height: 8),
        ],
        CheckInSheetOption(
          label: 'Done',
          selected: false,
          onTap: _doneEnabled ? _done : null,
        ),
      ],
    );
  }
}

// ── Amend sheet — `Today's check-in` (Items 8/9) ────────────────────

Future<void> showCheckInAmendSheet({
  required BuildContext context,
  required bool showKindSection,
  String? currentKind,
  KindCommit? onKind,
  required bool showFlareAddSection,
  FlareUpsertCommit? onFlareAdd,
  required bool showGoodSection,
  List<String> initialGood = const [],
  GoodCommit? onGood,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: NotelColors.surface,
    isScrollControlled: true,
    builder: (_) => CheckInAmendSheet(
      showKindSection: showKindSection,
      currentKind: currentKind,
      onKind: onKind,
      showFlareAddSection: showFlareAddSection,
      onFlareAdd: onFlareAdd,
      showGoodSection: showGoodSection,
      initialGood: initialGood,
      onGood: onGood,
    ),
  );
}

/// The combined amend sheet. Sections, by state (no headings or
/// explanatory lines beyond the ruled prompts — Item 9):
/// - kind section (a flare exists, or the ranking is 1–2): the
///   kind prompt + options; a tap amends the kind in place. There
///   is NO kind-removal affordance and no `Just log this` here.
/// - flare-add section (no flare exists, ranking 3–5): the Item 8
///   severity step (`How bad is it today?`, `Rough` / `Really bad`
///   only) advancing in-sheet to the kind step, where `Just log
///   this` commits the chosen severity with no kind. Dismissal
///   before a kind-step commit writes nothing — no number declared
///   this flare, so nothing is pre-committed.
/// - good section (ranking 4–5, or a good record exists): the good
///   prompt + options + `Done`, pre-filled from today's own good
///   record; `Done` is disabled at zero selections (amend mode).
class CheckInAmendSheet extends StatefulWidget {
  final bool showKindSection;
  final String? currentKind;
  final KindCommit? onKind;
  final bool showFlareAddSection;
  final FlareUpsertCommit? onFlareAdd;
  final bool showGoodSection;
  final List<String> initialGood;
  final GoodCommit? onGood;

  const CheckInAmendSheet({
    super.key,
    required this.showKindSection,
    required this.showFlareAddSection,
    required this.showGoodSection,
    this.currentKind,
    this.onKind,
    this.onFlareAdd,
    this.initialGood = const [],
    this.onGood,
  });

  @override
  State<CheckInAmendSheet> createState() => _CheckInAmendSheetState();
}

class _CheckInAmendSheetState extends State<CheckInAmendSheet> {
  bool _committing = false;
  bool _commitFailed = false;

  /// Late-add two-step state: the severity chosen at step 1, or
  /// null while the sections view (with the severity step) shows.
  String? _lateSeverity;

  late final Set<String> _goodSelected = {...widget.initialGood};

  Future<void> _run(Future<bool> Function() commit) async {
    if (_committing) return;
    setState(() {
      _committing = true;
      _commitFailed = false;
    });
    bool ok;
    try {
      ok = await commit();
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _committing = false;
        _commitFailed = true;
      });
    }
  }

  Future<void> _goodDone() async {
    if (_goodSelected.isEmpty) return; // Done disabled at zero.
    await _run(
      () => widget.onGood!(goodOptionsInSheetOrder(_goodSelected)),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Late-add kind step replaces the sections view (the old flare
    // sheet's in-sheet two-step pattern).
    if (_lateSeverity != null) {
      final severity = _lateSeverity!;
      return _sheetShell(
        title: "Today's check-in",
        commitFailed: _commitFailed,
        children: [
          ..._kindOptions(
            selectedKind: null,
            committing: _committing,
            onTap: (kind) => _run(
              () => widget.onFlareAdd!(severity: severity, type: kind),
            ),
          ),
          const SizedBox(height: 8),
          CheckInSheetOption(
            label: 'Just log this',
            selected: false,
            onTap: _committing
                ? null
                : () => _run(
                      () => widget.onFlareAdd!(severity: severity),
                    ),
          ),
        ],
      );
    }

    final children = <Widget>[];
    if (widget.showKindSection && widget.onKind != null) {
      children.addAll(_kindOptions(
        selectedKind: widget.currentKind,
        committing: _committing,
        onTap: (kind) => _run(() => widget.onKind!(kind)),
      ));
    }
    if (widget.showFlareAddSection && widget.onFlareAdd != null) {
      if (children.isNotEmpty) children.add(const SizedBox(height: 16));
      children.addAll([
        const Text(
          'How bad is it today?',
          style: _promptStyle,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        for (final severity in flareLateSeverities) ...[
          CheckInSheetOption(
            label: severity,
            semanticsLabel: flareLateSeveritySemantics(severity),
            selected: false,
            onTap: _committing
                ? null
                : () => setState(() => _lateSeverity = severity),
          ),
          const SizedBox(height: 8),
        ],
      ]);
    }
    if (widget.showGoodSection && widget.onGood != null) {
      if (children.isNotEmpty) children.add(const SizedBox(height: 16));
      children.addAll([
        const Text(
          'What is good about today?',
          style: _promptStyle,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        for (final option in goodOptions) ...[
          CheckInSheetOption(
            label: option,
            selected: _goodSelected.contains(option),
            onTap: _committing
                ? null
                : () => setState(() {
                      if (!_goodSelected.remove(option)) {
                        _goodSelected.add(option);
                      }
                    }),
          ),
          const SizedBox(height: 8),
        ],
        CheckInSheetOption(
          label: 'Done',
          selected: false,
          // Amend mode: Done is disabled at zero selections.
          onTap: (_committing || _goodSelected.isEmpty) ? null : _goodDone,
        ),
      ]);
    }
    return _sheetShell(
      title: "Today's check-in",
      commitFailed: _commitFailed,
      children: children,
    );
  }
}
