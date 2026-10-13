import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/medications.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

export 'package:tabs_lab/src/data/medications.dart';

/// Round 18 (Team B) — Medications tool, port of the native
/// `MedicationsScreen.kt` layout.
///
/// Round 39 — this screen and Settings → User Profile now share
/// ONE synced source of truth: the shared [MedicationEntry] model
/// in `data/medications.dart`. Archive/unarchive are wired for
/// real here: archiving stamps the med's end date with today
/// (native semantics) and pushes the full list back through
/// `POST /api/sync/profile`, so both surfaces agree.
///
/// Data source: `decodeProfileList((await fetchProfile())['medications'])`
/// — the server-synced medications blob (native Settings DTO
/// rows; see `data/medications.dart` for the blob spec).
///
/// Rendered (layout per native):
/// - Intro copy (verbatim native).
/// - "Quick Actions" hero card with the active count; the "Took All Meds"
///   and "Add Medication" buttons render disabled (deferred).
/// - "Active Prescriptions" list: icon badge, name, "dose • frequency"
///   line, "Started …" chip; the per-card "Took Med" button renders
///   disabled (dose logging deferred), and each active card carries
///   a working Archive button.
/// - Collapsible "Archived Medications (N)" section; each archived
///   card carries a working Restore (unarchive) button.
/// - Empty state (med icon, "No Active Medications") when the blob is
///   empty or the fetch fails — honest empty, never invented.
///
/// Round 46 — tap any medication card (native's invocation) to
/// edit it: the native Add/Edit dialog's field set — name, dose,
/// frequency, date started, and (archived meds only, exactly
/// like native) ended date. Dates go through the stock date
/// picker and are written as `MMM d, yyyy` strings, native's
/// format (its field examples and archive stamp). Saves follow
/// the Round 39 discipline: identity-targeted document op, full
/// splice-back push, honest failure with a server reload.
///
/// DEFERRED: add/delete and "Took Med" / "Took All Meds" dose
/// logging. Adding medications happens in Settings → User Profile;
/// dose logging is not in the Lab yet.
///
/// Round 48 — archive/edit writes are now serialized (one
/// whole-list push in flight at a time; controls disabled while
/// pending), matching the Vera B3 discipline Habits and Reminders
/// received in the Round 47 fix round.

class MedicationsScreen extends StatefulWidget {
  /// Injectable for tests.
  final TabsBackend? backend;

  const MedicationsScreen({super.key, this.backend});

  @override
  State<MedicationsScreen> createState() => _MedicationsScreenState();
}

class _MedicationsScreenState extends State<MedicationsScreen> {
  late final TabsBackend _backend;
  bool _loading = true;

  /// The FULL blob as a [MedicationDocument] — raw rows retained
  /// (including unparseable rows and deleted tombstones, which the
  /// display indices hide) so an archive write round-trips every
  /// row: dropping or stripping a row on save would delete or
  /// corrupt it server-side (Vera R39 Findings 1–2).
  MedicationDocument _doc = MedicationDocument.empty;
  bool _showArchived = true;

  /// Round 48 — a whole-list push is in flight. Archive/edit
  /// writes on this screen were never serialized (the Vera B3
  /// fix round covered Habits and Reminders only): two quick
  /// taps could run two whole-list pushes concurrently, and the
  /// slower push — built from the older document — could land
  /// last and silently undo the first change server-side. While
  /// a push is pending, every write control is disabled and
  /// every write entry point drops its tap.
  bool _writing = false;

  @override
  void initState() {
    super.initState();
    _backend = widget.backend ?? TabsBackend();
    _load();
  }

  Future<void> _load() async {
    try {
      final profile = await _backend.fetchProfile();
      final decoded =
          TabsBackend.decodeProfileList(profile?['medications']);
      final doc = MedicationDocument.fromRawRows(decoded);
      if (!mounted) return;
      setState(() {
        _doc = doc;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      // Honest empty on any failure — nothing is invented.
      setState(() {
        _doc = MedicationDocument.empty;
        _loading = false;
      });
    }
  }

  /// Archive/unarchive for real (Round 39): apply the shared op
  /// to the document — targeting the exact entry instance this
  /// screen rendered, by identity (Vera Finding 1) — update the
  /// UI immediately, then push the whole splice-back-encoded blob
  /// through `POST /api/sync/profile`. On success the cached pull
  /// is invalidated; on failure a SnackBar says the change could
  /// not be saved and the screen reloads from the server — the UI
  /// never claims an unsaved state (Settings' `_pushProfile`
  /// honesty pattern).
  Future<void> _setArchived(MedicationEntry med, bool archive) async {
    if (_writing) return;
    final now = DateTime.now();
    final updated = archive
        ? _doc.archiveEntry(med, now: now)
        : _doc.unarchiveEntry(med, now: now);
    await _pushDoc(updated);
  }

  /// Round 46 — native edit: tap a card, edit name/dose/
  /// frequency/start (and end, archived meds only) in the dialog,
  /// then save through the same document op + full push as
  /// archive. The op targets the exact entry instance this screen
  /// rendered (identity, Vera Finding 1) — never a name match.
  Future<void> _showEditDialog(MedicationEntry med) async {
    if (_writing) return;
    final result = await showDialog<_MedicationEditResult>(
      context: context,
      builder: (_) => _MedicationEditDialog(med: med),
    );
    if (result == null || !mounted) return;
    final updated = _doc.editEntry(
      med,
      name: result.name,
      dose: result.dose,
      frequency: result.frequency,
      startDate: result.startDate,
      endDate: result.endDate,
      now: DateTime.now(),
    );
    if (identical(updated, _doc)) {
      // The op refused (unresolvable/ambiguous target) — surface
      // it instead of claiming a save that never happened.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Could not save that change. Check your connection and try again.')));
      return;
    }
    await _pushDoc(updated);
  }

  /// Shared save path for archive/unarchive (R39) and edit (R46):
  /// swap the document in immediately, push the whole encoded
  /// blob through `POST /api/sync/profile`, invalidate
  /// the cached pull on success; on failure show the SnackBar and
  /// reload from the server — the UI never claims an unsaved
  /// state (Settings' `_pushProfile` honesty pattern).
  ///
  /// Round 48 — SERIALIZED (see [_writing]): at most one push
  /// runs at a time, and the flag is held across the failure-path
  /// reload so the reload can never race a push still in flight.
  Future<void> _pushDoc(MedicationDocument updated) async {
    if (_writing) return;
    _writing = true;
    setState(() => _doc = updated);
    try {
      final ok = await _backend.postSyncProfile(
          {'medications': jsonEncode(updated.encode())});
      if (ok) {
        _backend.invalidateSyncPull();
        return;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Could not save that change. Check your connection and try again.')));
      _backend.invalidateSyncPull();
      await _load();
    } finally {
      _writing = false;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = _doc.activeIndices;
    final archived = _doc.archivedIndices;

    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back,
            color: NotelColors.textPrimary,
            semanticLabel: 'Back',
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Medications & Side Effects',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(
              Icons.info,
              color: NotelColors.primary,
              semanticLabel: 'Medications Info',
            ),
            onPressed: _showInfoDialog,
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(
                color: NotelColors.primary,
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
              children: [
                const Text(
                  'Manage your active prescriptions and log doses to track body side-effects in real time.',
                  style: TextStyle(
                    fontSize: 14,
                    color: NotelColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 16),
                _quickActionsCard(active.length),
                const SizedBox(height: 16),
                const Text(
                  'Active Prescriptions',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: NotelColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                if (active.isEmpty)
                  _emptyState()
                else
                  ...active.map(
                      (i) => _medicationCard(i, _doc.entryAt(i)!, false)),
                if (archived.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _archivedHeader(archived.length),
                  if (_showArchived) ...[
                    const SizedBox(height: 12),
                    ...archived.map(
                        (i) => _medicationCard(i, _doc.entryAt(i)!, true)),
                  ],
                ],
              ],
            ),
    );
  }

  Widget _quickActionsCard(int activeCount) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: NotelColors.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Quick Actions',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: NotelColors.textPrimary,
                    ),
                  ),
                  Text(
                    '$activeCount Active Medication(s)',
                    style: const TextStyle(
                      fontSize: 13,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                ],
              ),
              // Deferred: dose logging is not in the Lab yet.
              ElevatedButton(
                onPressed: null,
                style: ElevatedButton.styleFrom(
                  disabledBackgroundColor:
                      NotelColors.surfaceHigh.withValues(alpha: 0.4),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.check,
                      size: 16,
                      color: NotelColors.textSecondary,
                    ),
                    SizedBox(width: 6),
                    Text(
                      'Took All Meds',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: NotelColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Deferred: adding happens in Settings → User Profile.
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: null,
              style: ElevatedButton.styleFrom(
                disabledBackgroundColor: NotelColors.surfaceHigh,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.add,
                    size: 16,
                    color: NotelColors.textPrimary,
                  ),
                  SizedBox(width: 6),
                  Text(
                    'Add Medication',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: NotelColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Archiving, restoring, and editing sync to your profile. Add medications in Settings → User Profile; dose logging is not in the Lab yet.',
            style: TextStyle(
              fontSize: 11,
              color: NotelColors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          Icon(
            Icons.medication,
            size: 44,
            color: NotelColors.primary.withValues(alpha: 0.6),
          ),
          const SizedBox(height: 8),
          const Text(
            'No Active Medications',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'No medications found in your profile.',
            style: TextStyle(
              fontSize: 13,
              color: NotelColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  /// [rawIndex] is the row's index in the FULL blob (the
  /// document's raw order) — button keys carry it so every
  /// rendered row's buttons are unique, even for id-less
  /// duplicate names (Vera R39 Finding 1).
  Widget _medicationCard(int rawIndex, MedicationEntry med, bool isArchived) {
    final valid = isDoseValid(med);
    final accent =
        isArchived ? NotelColors.textSecondary : NotelColors.primary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      // Native invocation (R46): the WHOLE card is tappable and
      // opens the edit dialog — the Archive/Restore buttons keep
      // their own taps. The key carries the raw index so tests
      // (and duplicate rows) can tell cards apart.
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('edit_med_at_$rawIndex'),
          borderRadius: BorderRadius.circular(20),
          // Disabled while a write push is in flight (Round 48).
          onTap: _writing ? null : () => _showEditDialog(med),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: NotelColors.surface
                  .withValues(alpha: isArchived ? 0.45 : 0.8),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.08),
              ),
            ),
            child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.15),
                shape: BoxShape.circle,
                border: Border.all(color: accent, width: 1.5),
              ),
              child: Icon(
                isArchived ? Icons.archive : Icons.medication,
                size: 22,
                color: accent,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Native name row: name + a small edit pencil
                  // (the card itself is the tap target, R46).
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          med.name,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            color: isArchived
                                ? NotelColors.textSecondary
                                : NotelColors.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        Icons.edit,
                        size: 14,
                        color:
                            NotelColors.textSecondary.withValues(alpha: 0.5),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  if (isArchived && med.endedDate != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: NotelColors.textSecondary
                            .withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'Ended ${med.endedDate}',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: NotelColors.textSecondary,
                        ),
                      ),
                    )
                  else
                    Text(
                      valid
                          ? '${med.dose}  •  ${med.frequency}'
                          : 'Dose not set  •  ${med.frequency}',
                      style: TextStyle(
                        fontSize: 13,
                        color: valid
                            ? NotelColors.textSecondary
                            : NotelColors.primary,
                      ),
                    ),
                  if (!isArchived && med.startedDate != null) ...[
                    const SizedBox(height: 3),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: NotelColors.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        'Started ${med.startedDate}',
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: NotelColors.primary,
                        ),
                      ),
                    ),
                  ],
                  if (!isArchived && med.startedDate == null) ...[
                    const SizedBox(height: 3),
                    const Text(
                      'Start date not set',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: NotelColors.primary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (!isArchived) ...[
              // Deferred: per-med dose logging is disabled.
              ElevatedButton(
                onPressed: null,
                style: ElevatedButton.styleFrom(
                  disabledBackgroundColor:
                      NotelColors.surfaceHigh.withValues(alpha: 0.4),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                ),
                child: const Text(
                  'Took Med',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: NotelColors.textSecondary,
                  ),
                ),
              ),
              IconButton(
                key: ValueKey('archive_med_at_$rawIndex'),
                icon: const Icon(Icons.archive,
                    size: 20, color: NotelColors.textSecondary),
                tooltip: 'Archive',
                onPressed:
                    _writing ? null : () => _setArchived(med, true),
              ),
            ],
            if (isArchived)
              IconButton(
                key: ValueKey('unarchive_med_at_$rawIndex'),
                icon: const Icon(Icons.unarchive,
                    size: 20, color: NotelColors.textSecondary),
                tooltip: 'Restore',
                onPressed:
                    _writing ? null : () => _setArchived(med, false),
              ),
            ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _archivedHeader(int count) {
    return GestureDetector(
      onTap: () => setState(() => _showArchived = !_showArchived),
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.archive,
                  size: 18,
                  color: NotelColors.textSecondary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Archived Medications ($count)',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: NotelColors.textSecondary,
                  ),
                ),
              ],
            ),
            Icon(
              _showArchived ? Icons.expand_less : Icons.expand_more,
              color: NotelColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  void _showInfoDialog() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: NotelColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
        title: const Row(
          children: [
            Icon(Icons.info, color: NotelColors.primary),
            SizedBox(width: 8),
            Text(
              'How Medications Work',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: NotelColors.textPrimary,
              ),
            ),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '• Synced: this screen shows the medications synced from your Tabs profile, the same list as Settings → User Profile. Archiving and restoring work here and sync to your profile; adding medications happens in Settings → User Profile.',
              style: TextStyle(
                fontSize: 13,
                color: NotelColors.textPrimary,
              ),
            ),
            SizedBox(height: 10),
            Text(
              '• Active & Archived: medications you no longer take are archived here to keep your list clean while preserving history. Archiving stamps the medication with today as its ended date; restoring makes it active again.',
              style: TextStyle(
                fontSize: 13,
                color: NotelColors.textPrimary,
              ),
            ),
            SizedBox(height: 10),
            Text(
              '• Tap to Edit: tap any medication card to edit its name, dose, frequency, and start or end dates.',
              style: TextStyle(
                fontSize: 13,
                color: NotelColors.textPrimary,
              ),
            ),
            SizedBox(height: 10),
            Text(
              '• "Took Med" Logging: dose logging is not in the Lab yet.',
              style: TextStyle(
                fontSize: 13,
                color: NotelColors.textPrimary,
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            style: ElevatedButton.styleFrom(
              backgroundColor: NotelColors.primary,
            ),
            child: const Text(
              'Got It',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

/// The values the edit dialog returns on Save — already
/// normalized the way native's save handler normalizes them
/// (name/dose trimmed, blank frequency defaulted, dates as
/// `MMM d, yyyy` strings or `''`).
class _MedicationEditResult {
  final String name;
  final String dose;
  final String frequency;
  final String startDate;
  final String endDate;

  const _MedicationEditResult({
    required this.name,
    required this.dose,
    required this.frequency,
    required this.startDate,
    required this.endDate,
  });
}

/// Round 46 — the native Add/Edit dialog, edit mode: title
/// "Edit Medication", fields Medication Name *, Dose *,
/// Frequency *, Date Started *, and Ended Date ONLY for an
/// archived med (native shows it under exactly that condition;
/// an active med's end date is not editable — it stays the
/// `"Present"` sentinel). Native's fields are free text; here
/// the dates use the stock date picker (themed by the R28 dark
/// theme) seeded from the stored string via
/// [parseMedicationDate], and a pick writes `MMM d, yyyy` —
/// native's write format. A stored `"As prescribed"` dose opens
/// emptied, exactly like native, so Save (enabled only with a
/// non-blank name AND dose — native's validation) always writes
/// a real dose.
class _MedicationEditDialog extends StatefulWidget {
  final MedicationEntry med;

  const _MedicationEditDialog({required this.med});

  @override
  State<_MedicationEditDialog> createState() =>
      _MedicationEditDialogState();
}

class _MedicationEditDialogState extends State<_MedicationEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _dose;
  late final TextEditingController _frequency;
  late final TextEditingController _start;
  late final TextEditingController _end;

  MedicationEntry get _med => widget.med;

  /// Native validation: Save is enabled only while both the
  /// name and the dose are non-blank.
  bool get _canSave =>
      _name.text.trim().isNotEmpty && _dose.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: _med.name);
    // Native: a stored "As prescribed" dose opens as an empty
    // field (exact match), forcing a real dose before Save.
    _dose = TextEditingController(
        text: _med.dose == 'As prescribed' ? '' : _med.dose);
    _frequency = TextEditingController(text: _med.frequency);
    _start = TextEditingController(text: _med.startDate);
    _end = TextEditingController(
        text: _med.isArchived ? (_med.endedDate ?? '') : '');
    // _canSave depends on the name/dose text — rebuild on change.
    _name.addListener(_onFieldChanged);
    _dose.addListener(_onFieldChanged);
    _start.addListener(_onFieldChanged);
  }

  void _onFieldChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _name.dispose();
    _dose.dispose();
    _frequency.dispose();
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  Future<void> _pickDate(TextEditingController controller) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final first = DateTime(1990);
    var initial = parseMedicationDate(controller.text) ?? today;
    if (initial.isAfter(today)) initial = today;
    if (initial.isBefore(first)) initial = first;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: today,
    );
    if (picked == null || !mounted) return;
    setState(() => controller.text = formatMedArchiveDate(picked));
  }

  void _save() {
    final frequency = _frequency.text.trim();
    Navigator.of(context).pop(_MedicationEditResult(
      name: _name.text.trim(),
      dose: _dose.text.trim(),
      // Native: a blank frequency saves as "Once daily".
      frequency: frequency.isEmpty ? 'Once daily' : frequency,
      startDate: _start.text.trim(),
      // Native: an active med's end date is passed through
      // untouched (and serializes as "Present" regardless); only
      // an archived med's end date comes from the field — a
      // cleared field writes '' and the med stays archived.
      endDate: _med.isArchived ? _end.text.trim() : _med.endDate,
    ));
  }

  Widget _dateField({
    required Key key,
    required TextEditingController controller,
    required String label,
  }) {
    return TextField(
      key: key,
      controller: controller,
      readOnly: true,
      onTap: () => _pickDate(controller),
      style: const TextStyle(color: NotelColors.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: NotelColors.textSecondary),
        suffixIcon: controller.text.isEmpty
            ? const Icon(Icons.calendar_month,
                color: NotelColors.textSecondary)
            : IconButton(
                icon: const Icon(Icons.clear,
                    color: NotelColors.textSecondary),
                tooltip: 'Clear date',
                onPressed: () =>
                    setState(() => controller.text = ''),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: NotelColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
      ),
      title: const Text(
        'Edit Medication',
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: NotelColors.textPrimary,
        ),
      ),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('med_edit_name'),
                controller: _name,
                style: const TextStyle(color: NotelColors.textPrimary),
                decoration: const InputDecoration(
                  labelText: 'Medication Name *',
                  labelStyle: TextStyle(color: NotelColors.textSecondary),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('med_edit_dose'),
                controller: _dose,
                style: const TextStyle(color: NotelColors.textPrimary),
                decoration: const InputDecoration(
                  labelText: 'Dose * (e.g. 50mg, 60mg, 0.5ml)',
                  labelStyle: TextStyle(color: NotelColors.textSecondary),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('med_edit_frequency'),
                controller: _frequency,
                style: const TextStyle(color: NotelColors.textPrimary),
                decoration: const InputDecoration(
                  labelText: 'Frequency * (e.g. Twice daily, Once weekly)',
                  labelStyle: TextStyle(color: NotelColors.textSecondary),
                ),
              ),
              const SizedBox(height: 12),
              _dateField(
                key: const ValueKey('med_edit_start'),
                controller: _start,
                label: 'Date Started * (e.g. Apr 14, 2026)',
              ),
              if (_start.text.trim().isEmpty) ...[
                const SizedBox(height: 4),
                const Text(
                  "⚠️ Date Started is required to use 'Took Med'",
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: NotelColors.primary,
                  ),
                ),
              ],
              if (_med.isArchived) ...[
                const SizedBox(height: 12),
                _dateField(
                  key: const ValueKey('med_edit_end'),
                  controller: _end,
                  label: 'Ended Date (e.g. Jul 24, 2026)',
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(
            'Cancel',
            style: TextStyle(color: NotelColors.textSecondary),
          ),
        ),
        ElevatedButton(
          onPressed: _canSave ? _save : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: NotelColors.primary,
          ),
          child: const Text(
            'Save Medication',
            style: TextStyle(color: Colors.white),
          ),
        ),
      ],
    );
  }
}
