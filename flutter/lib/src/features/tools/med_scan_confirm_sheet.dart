import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/med_scan.dart';
import 'package:tabs_lab/src/data/medications.dart';
import 'package:tabs_lab/src/features/tools/med_scan_strings.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Med Scan confirm sheet (Nov 22, 2026) — the HARD SAFETY GATE
/// of the scan flow: a scan NEVER saves anything by itself. This
/// sheet shows the proposal (name, dose, form, start date) with
/// every persisted field editable, and only an explicit Save tap
/// produces a [MedScanSaveRequest]. Cancel/dismiss produces
/// nothing and nothing is written.
///
/// Copy is Juno's ruled §4 set (med_scan_strings.dart): the
/// UPDATE title names the EXISTING entry (its saved name and
/// dose) that a save would change, the nothing-saved line sits
/// directly above Save, and the footer repeats the §6 privacy
/// line for the proposal's source.
///
/// Modes:
/// - ADD (no confident match): fields seed from the proposal;
///   the start date defaults to TODAY (a package never carries
///   a start date) and is editable via the date picker.
/// - UPDATE (confident match against an existing entry): the
///   sheet leads with updating THAT entry. Fields seed
///   conservatively — the entry's own name and start date (a
///   scan must not silently rename the entry or rewrite its
///   history), the scanned dose (the point of the update).
///   "Add as new instead" (§4's ruled secondary action) flips
///   to ADD mode, reseeding from the proposal.
/// - Form is shown as lookup detail only: the medication model
///   has no form field, so there is nothing to save it into.
///
/// Save validation mirrors the manual add/edit dialog: name AND
/// dose must be non-blank.
class MedScanSaveRequest {
  /// True when the save should update [target]; false for an add.
  final bool updateExisting;

  /// The existing entry to update (the exact instance rendered
  /// from the caller's document — the caller re-resolves it in
  /// the fresh document before writing, exactly like the manual
  /// edit path). Null for an add.
  final MedicationEntry? target;

  final String name;
  final String dose;

  /// `MMM d, yyyy` (the model's date format).
  final String startDate;

  const MedScanSaveRequest({
    required this.updateExisting,
    required this.target,
    required this.name,
    required this.dose,
    required this.startDate,
  });
}

/// Shows the confirm sheet as a modal bottom sheet; resolves to
/// the user's confirmed [MedScanSaveRequest], or null when the
/// user cancelled/dismissed (nothing saved either way — saving
/// is the caller's job, through the manual add/edit paths).
Future<MedScanSaveRequest?> showMedScanConfirmSheet(
  BuildContext context, {
  required MedScanProposal proposal,
  required MedicationEntry? matchedEntry,
}) {
  return showModalBottomSheet<MedScanSaveRequest>(
    context: context,
    isScrollControlled: true,
    backgroundColor: NotelColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) =>
        MedScanConfirmSheet(proposal: proposal, matchedEntry: matchedEntry),
  );
}

class MedScanConfirmSheet extends StatefulWidget {
  final MedScanProposal proposal;
  final MedicationEntry? matchedEntry;

  /// Injectable "today" for tests; defaults to the real today.
  final DateTime? todayOverride;

  const MedScanConfirmSheet({
    super.key,
    required this.proposal,
    required this.matchedEntry,
    this.todayOverride,
  });

  @override
  State<MedScanConfirmSheet> createState() => _MedScanConfirmSheetState();
}

class _MedScanConfirmSheetState extends State<MedScanConfirmSheet> {
  late final TextEditingController _name;
  late final TextEditingController _dose;
  late final TextEditingController _startText;
  late DateTime _startDate;
  late bool _updateMode;

  MedicationEntry? get _match => widget.matchedEntry;

  DateTime get _today {
    final t = widget.todayOverride ?? DateTime.now();
    return DateTime(t.year, t.month, t.day);
  }

  bool get _canSave =>
      _name.text.trim().isNotEmpty && _dose.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _updateMode = _match != null;
    _name = TextEditingController();
    _dose = TextEditingController();
    _startText = TextEditingController();
    _seedFields();
    _name.addListener(_onFieldChanged);
    _dose.addListener(_onFieldChanged);
  }

  /// Seeds the fields for the current mode (see the class doc
  /// for the conservative update-mode seeding rule).
  void _seedFields() {
    if (_updateMode && _match != null) {
      _name.text = _match!.name;
      _dose.text = widget.proposal.dose.isNotEmpty
          ? widget.proposal.dose
          : _match!.dose;
      _startDate = parseMedicationDate(_match!.startDate) ?? _today;
    } else {
      _name.text = widget.proposal.name;
      _dose.text = widget.proposal.dose;
      _startDate = _today;
    }
    _startText.text = formatMedArchiveDate(_startDate);
  }

  void _onFieldChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _name.dispose();
    _dose.dispose();
    _startText.dispose();
    super.dispose();
  }

  Future<void> _pickStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate,
      firstDate: DateTime(1990),
      lastDate: _today,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _startDate = picked;
      _startText.text = formatMedArchiveDate(picked);
    });
  }

  void _save() {
    Navigator.of(context).pop(
      MedScanSaveRequest(
        updateExisting: _updateMode && _match != null,
        target: _updateMode ? _match : null,
        name: _name.text.trim(),
        dose: _dose.text.trim(),
        startDate: formatMedArchiveDate(_startDate),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final form = widget.proposal.form;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          20 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _updateMode && _match != null
                  ? MedScanStrings.confirmUpdateTitle(
                      _match!.name,
                      _match!.dose,
                    )
                  : MedScanStrings.confirmAddTitle,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: NotelColors.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _updateMode
                  ? MedScanStrings.confirmUpdateIntro
                  : MedScanStrings.confirmAddIntro,
              style: TextStyle(
                fontSize: 13,
                color: NotelColors.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('med_scan_name'),
              controller: _name,
              style: TextStyle(color: NotelColors.textPrimary),
              decoration: InputDecoration(
                labelText: MedScanStrings.nameLabel,
                labelStyle: TextStyle(color: NotelColors.textSecondary),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('med_scan_dose'),
              controller: _dose,
              style: TextStyle(color: NotelColors.textPrimary),
              decoration: InputDecoration(
                labelText: MedScanStrings.doseLabel,
                labelStyle: TextStyle(color: NotelColors.textSecondary),
              ),
            ),
            if (form != null && form.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    '${MedScanStrings.formLabel}: ',
                    style: TextStyle(
                      fontSize: 13,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                  Text(
                    form,
                    style: TextStyle(
                      fontSize: 13,
                      color: NotelColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('med_scan_start_date'),
              readOnly: true,
              onTap: _pickStartDate,
              controller: _startText,
              style: TextStyle(color: NotelColors.textPrimary),
              decoration: InputDecoration(
                labelText: MedScanStrings.startDateLabel,
                labelStyle: TextStyle(color: NotelColors.textSecondary),
                suffixIcon: Icon(
                  Icons.calendar_month,
                  color: NotelColors.textSecondary,
                ),
              ),
            ),
            const SizedBox(height: 20),
            // §4: the nothing-saved line sits directly above Save.
            Text(
              _updateMode
                  ? MedScanStrings.nothingSavedUpdate
                  : MedScanStrings.nothingSavedAdd,
              style: TextStyle(
                fontSize: 12,
                color: NotelColors.textSecondary,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('med_scan_cancel'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text(MedScanStrings.cancelButton),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    key: const ValueKey('med_scan_save'),
                    onPressed: _canSave ? _save : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: NotelColors.primary,
                    ),
                    child: Text(
                      _updateMode
                          ? MedScanStrings.saveUpdateButton
                          : MedScanStrings.saveAddButton,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
            if (_updateMode && _match != null) ...[
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  key: const ValueKey('med_scan_add_as_new'),
                  onPressed: () {
                    setState(() {
                      _updateMode = false;
                      _seedFields();
                    });
                  },
                  child: const Text(MedScanStrings.addAsNewInsteadButton),
                ),
              ),
            ],
            const SizedBox(height: 12),
            // §6: the privacy line for this proposal's source,
            // repeated as a small footer on the sheet.
            Text(
              widget.proposal.source == MedScanSource.labelPhoto
                  ? MedScanStrings.photoPrivacyNote
                  : MedScanStrings.barcodeLookupNote,
              style: TextStyle(
                fontSize: 11,
                color: NotelColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
