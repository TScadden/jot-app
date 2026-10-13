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
/// - "Quick Actions" hero card with the active count, a working
///   "Took All Meds" button (enabled exactly when native enables
///   it: at least one active med and EVERY active med dose-valid)
///   and a working "Add Medication" button.
/// - "Active Prescriptions" list: icon badge, name, "dose • frequency"
///   line, "Started …" chip; each active card carries a working
///   "Took Med" button (enabled per-card exactly when native
///   enables it: that med's dose is valid) and a working Archive
///   button.
/// - Collapsible "Archived Medications (N)" section; each archived
///   card carries a working Restore (unarchive) button and a
///   working permanent-delete button (native's archived-card
///   delete affordance — immediate, no confirmation dialog in
///   native).
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
/// Round 48 — archive/edit writes are now serialized (one
/// whole-list push in flight at a time; controls disabled while
/// pending), matching the Vera B3 discipline Habits and Reminders
/// received in the Round 47 fix round.
///
/// Round 48 fix (Vera F1/F2/F3/F7) — every profile write now
/// follows the Lists/Notes/BP standard (see [_mutateDoc]):
/// invalidate the sync-pull cache, re-pull the FRESHEST profile,
/// re-resolve the target row in the fresh document
/// ([MedicationDocument.resolveFreshEntry]), splice into the
/// fresh raw rows, and push the whole blob — a med added
/// server-side after this screen opened is never reverted by an
/// archive/add/delete/edit push built from the load-time
/// snapshot. A target that cannot be re-resolved unambiguously
/// refuses: visible error, no push, never a claimed success.
/// The dose-log take path aborts the same way when its entries
/// pull actually failed (a success-distinguishing fetch), and
/// its entries carry the dual-reader shape Body Info's impact
/// engine gates on (see `data/medications.dart`).
///
/// Round 48D2 — the screen is COMPLETE (every action native
/// offers on this screen is wired):
/// - "Took Med" / "Took All Meds" dose logging: one log entry
///   per med through `POST /api/sync/entries`, built by
///   [buildMedTakeLogEntries] in the shared model — the Today
///   Summary take shape ("Took {name} {dose}", Medication
///   category, max+1 ids, per-day dedupe), so a dose logged here
///   reads as taken in Today Summary and vice versa (see the
///   dose-logging section of `data/medications.dart` for the
///   two-native-writers trace). Serialized under the same
///   `_writing` guard as the profile pushes.
/// - "Add Medication": the Round 46 dialog in add mode (native
///   title "Add New Medication", frequency prefilled "Once
///   daily"), saved via [MedicationDocument.addEntry] — exactly
///   one row appended, every existing row preserved.
/// - Archived permanent delete: [MedicationDocument.deleteEntry]
///   removes exactly that row and pushes the full remaining
///   list — native Settings' delete outcome, no confirmation,
///   exactly like native.

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

  /// Round 48 — a write is in flight. Archive/edit writes on
  /// this screen were never serialized (the Vera B3 fix round
  /// covered Habits and Reminders only): two quick taps could
  /// run two whole-list pushes concurrently, and the slower
  /// push — built from the older document — could land last
  /// and silently undo the first change server-side. While a
  /// write is pending, every write control is disabled and
  /// every write entry point drops its tap. Round 48D2: the
  /// dose-log writes (Took Med / Took All) hold the same guard
  /// — a dose post re-reads the entry list to dedupe, and two
  /// concurrent takes could both pass the dedupe check and
  /// double-post.
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

  /// Archive/unarchive for real (Round 39): the shared op runs
  /// inside [_mutateDoc] against the FRESHLY pulled document —
  /// the rendered entry is re-resolved there
  /// ([MedicationDocument.resolveFreshEntry]), never spliced
  /// into the load-time snapshot (Vera F1).
  Future<void> _setArchived(MedicationEntry med, bool archive) async {
    if (_writing) return;
    final hint = _rawIndexHint(med);
    final now = DateTime.now();
    await _mutateDoc((fresh) {
      final target = fresh.resolveFreshEntry(med, rawIndexHint: hint);
      if (target == null) return null;
      return archive
          ? fresh.archiveEntry(target, now: now)
          : fresh.unarchiveEntry(target, now: now);
    });
  }

  /// The raw index [med] occupies in the CURRENT document, or
  /// -1 when it is not there — the positional hint
  /// [MedicationDocument.resolveFreshEntry] uses to re-resolve
  /// the same rendered row in a fresh document.
  int _rawIndexHint(MedicationEntry med) {
    for (var i = 0; i < _doc.length; i++) {
      if (identical(_doc.entryAt(i), med)) return i;
    }
    return -1;
  }

  void _showSaveError() {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'Could not save that change. Check your connection and try again.')));
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
    final hint = _rawIndexHint(med);
    final now = DateTime.now();
    await _mutateDoc((fresh) {
      final target = fresh.resolveFreshEntry(med, rawIndexHint: hint);
      if (target == null) return null;
      return fresh.editEntry(
        target,
        name: result.name,
        dose: result.dose,
        frequency: result.frequency,
        startDate: result.startDate,
        endDate: result.endDate,
        now: now,
      );
    });
  }

  /// Round 48D2 — "Took Med" (single) and "Took All Meds"
  /// (every dose-valid active med, in list order). One log
  /// entry per med via [buildMedTakeLogEntries] — the Today
  /// Summary take shape, so the dose reads as taken there (and
  /// a dose already logged today, on either surface, is not
  /// double-posted: the builder returns an empty list, a
  /// successful no-op). Native's status copy is mirrored:
  /// "Logged 1 dose of {name} ({dose})" / "Logged 1 dose for
  /// all {N} medication(s)!". Failures (category unresolvable
  /// or the entries post rejected) show an error and claim
  /// nothing — no local state changes on this screen for a
  /// dose, so there is no phantom state to roll back (native's
  /// Medications writer likewise updates no med record; see
  /// the shared model's dose-logging trace).
  Future<void> _takeMeds(List<MedicationEntry> meds,
      {required bool all}) async {
    if (_writing || meds.isEmpty) return;
    _writing = true;
    if (mounted) setState(() {});
    try {
      // Fresh evidence for the dedupe check: drop the cached
      // pull so entries/categories reflect the server's latest
      // (a dose logged from Today Summary moments ago counts).
      _backend.invalidateSyncPull();
      // Vera F2 (med half): the entries fetch must DISTINGUISH
      // failure from a real empty log — the plain fetch flattens
      // both to [], and computing max+1 ids / dedupe from a
      // failed pull could post id 1 over an existing log or
      // double-post a dose that already stands. A null here
      // means the pull actually failed: abort with a visible
      // error and post NOTHING, before any id/dedupe math.
      final entries = await _backend.fetchLogEntryDtosOrNull();
      if (entries == null) {
        if (mounted) _showDoseError();
        return;
      }
      final categories = await _backend.fetchLogCategories();
      final toPost = buildMedTakeLogEntries(
        meds: meds,
        existingEntries: entries,
        categories: categories,
        now: DateTime.now(),
      );
      if (!mounted) return;
      if (toPost == null) {
        _showDoseError();
        return;
      }
      if (toPost.isNotEmpty) {
        final ok = await _backend.postLogEntries(toPost);
        _backend.invalidateSyncPull();
        if (!mounted) return;
        if (!ok) {
          _showDoseError();
          return;
        }
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      if (toPost.isEmpty) {
        messenger.showSnackBar(SnackBar(
            content: Text(all
                ? 'All active doses are already logged today'
                : 'Already logged today')));
      } else if (all) {
        messenger.showSnackBar(SnackBar(
            content: Text(
                'Logged 1 dose for all ${meds.length} medication(s)!')));
      } else {
        final med = meds.single;
        messenger.showSnackBar(SnackBar(
            content: Text('Logged 1 dose of ${med.name} (${med.dose})')));
      }
    } catch (_) {
      if (mounted) _showDoseError();
    } finally {
      _writing = false;
      if (mounted) setState(() {});
    }
  }

  void _showDoseError() {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'Could not log that dose. Check your connection and try again.')));
  }

  /// Round 48D2 — "Add Medication": the Round 46 dialog in add
  /// mode; the save appends exactly one row through
  /// [MedicationDocument.addEntry] and pushes through the same
  /// serialized splice-back path as archive/edit.
  Future<void> _showAddMedicationDialog() async {
    if (_writing) return;
    final result = await showDialog<_MedicationEditResult>(
      context: context,
      builder: (_) => const _MedicationEditDialog.add(),
    );
    if (result == null || !mounted) return;
    final id = generateMedicationUuid();
    final now = DateTime.now();
    await _mutateDoc((fresh) => fresh.addEntry(
          name: result.name,
          dose: result.dose,
          frequency: result.frequency,
          startDate: result.startDate,
          id: id,
          now: now,
        ));
  }

  /// Round 48D2 — archived-card permanent delete: native has
  /// NO confirmation (the delete icon deletes immediately), so
  /// neither does this. The document op removes exactly that
  /// row (identity-targeted); the push is the shared serialized
  /// splice-back path, with the same honest failure + reload.
  Future<void> _deleteMedication(MedicationEntry med) async {
    if (_writing) return;
    final hint = _rawIndexHint(med);
    await _mutateDoc((fresh) {
      final target = fresh.resolveFreshEntry(med, rawIndexHint: hint);
      if (target == null) return null;
      return fresh.deleteEntry(target);
    });
  }

  /// Shared save path for archive/unarchive (R39), edit (R46),
  /// and add/delete (R48D2) — Round 48 fix (Vera F1), the
  /// Lists/Notes/BP standard (`lists_screen.dart`'s `_mutate`):
  /// 1. invalidate the sync-pull cache and re-pull the FRESHEST
  ///    profile — a failed pull is a visible error + reload, and
  ///    nothing is pushed;
  /// 2. [splice] runs against the FRESH document (its target
  ///    re-resolved there by identity/unique match) and returns
  ///    the document to push, or null / the fresh document itself
  ///    when the target cannot be resolved unambiguously — the
  ///    op then REFUSES: visible error, the fresh data is
  ///    rendered, and nothing is pushed (Vera F7 — a refused op
  ///    never reports success);
  /// 3. swap the spliced document in, push the whole encoded
  ///    blob through `POST /api/sync/profile`, and invalidate
  ///    the cached pull on success; on push failure show the
  ///    SnackBar and reload from the server — the UI never
  ///    claims an unsaved state.
  ///
  /// SERIALIZED (see [_writing]): at most one mutation runs at
  /// a time, and the flag is held across the failure-path reload
  /// so the reload can never race a push still in flight.
  Future<void> _mutateDoc(
      MedicationDocument? Function(MedicationDocument fresh) splice) async {
    if (_writing) return;
    _writing = true;
    if (mounted) setState(() {});
    try {
      _backend.invalidateSyncPull();
      final profile = await _backend.fetchProfile();
      if (profile == null) {
        if (!mounted) return;
        _showSaveError();
        _backend.invalidateSyncPull();
        await _load();
        return;
      }
      final fresh = MedicationDocument.fromRawRows(
          TabsBackend.decodeProfileList(profile['medications']));
      final updated = splice(fresh);
      if (updated == null || identical(updated, fresh)) {
        // Refused (target gone or ambiguous in the fresh data):
        // error + render the fresh data; never push, never
        // claim success.
        if (!mounted) return;
        _showSaveError();
        setState(() => _doc = fresh);
        return;
      }
      if (mounted) {
        setState(() => _doc = updated);
      } else {
        _doc = updated;
      }
      final ok = await _backend.postSyncProfile(
          {'medications': jsonEncode(updated.encode())});
      if (ok) {
        _backend.invalidateSyncPull();
        return;
      }
      if (!mounted) return;
      _showSaveError();
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
                _quickActionsCard(
                    [for (final i in active) _doc.entryAt(i)!]),
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

  Widget _quickActionsCard(List<MedicationEntry> activeMeds) {
    final activeCount = activeMeds.length;
    // Native "Took All Meds" enable rule: there is at least one
    // active med and EVERY active med's dose is valid (a real
    // dose AND a started date — [isDoseValid]).
    final allValid =
        activeMeds.isNotEmpty && activeMeds.every(isDoseValid);
    final canTakeAll = allValid && !_writing;
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
              ElevatedButton(
                key: const ValueKey('took_all_meds'),
                onPressed: canTakeAll
                    ? () => _takeMeds(activeMeds, all: true)
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: NotelColors.primary,
                  disabledBackgroundColor:
                      NotelColors.surfaceHigh.withValues(alpha: 0.4),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.check,
                      size: 16,
                      color: canTakeAll
                          ? Colors.white
                          : NotelColors.textSecondary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Took All Meds',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: canTakeAll
                            ? Colors.white
                            : NotelColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (activeMeds.isNotEmpty && !allValid) ...[
            const SizedBox(height: 8),
            const Text(
              "⚠️ Fill out dose and date started below to unlock 'Took Med' logging.",
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: NotelColors.primary,
              ),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              key: const ValueKey('add_medication'),
              onPressed: _writing ? null : _showAddMedicationDialog,
              style: ElevatedButton.styleFrom(
                backgroundColor: NotelColors.surfaceHigh,
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
            'Dose logs sync to your history, and adding, archiving, restoring, and editing sync to your profile.',
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
              // Native enable rule: this med's dose must be valid
              // ([isDoseValid]); also disabled while a write is in
              // flight (Round 48 serialization).
              ElevatedButton(
                key: ValueKey('took_med_at_$rawIndex'),
                onPressed: (_writing || !valid)
                    ? null
                    : () => _takeMeds([med], all: false),
                style: ElevatedButton.styleFrom(
                  backgroundColor: NotelColors.primary,
                  disabledBackgroundColor:
                      NotelColors.surfaceHigh.withValues(alpha: 0.4),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                ),
                child: Text(
                  'Took Med',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: (valid && !_writing)
                        ? Colors.white
                        : NotelColors.textSecondary,
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
            if (isArchived) ...[
              IconButton(
                key: ValueKey('unarchive_med_at_$rawIndex'),
                icon: const Icon(Icons.unarchive,
                    size: 20, color: NotelColors.textSecondary),
                tooltip: 'Restore',
                onPressed:
                    _writing ? null : () => _setArchived(med, false),
              ),
              // Native archived-card delete: permanent, immediate
              // (no confirmation dialog in native).
              IconButton(
                key: ValueKey('delete_med_at_$rawIndex'),
                icon: const Icon(Icons.delete_outline,
                    size: 20, color: NotelColors.textSecondary),
                tooltip: 'Delete permanently',
                onPressed:
                    _writing ? null : () => _deleteMedication(med),
              ),
            ],
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
              '• Synced: this screen shows the medications synced from your Tabs profile, the same list as Settings → User Profile. Adding, archiving, and restoring work here and sync to your profile.',
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
              '• Required Dose Locking: "Took Med" and "Took All Meds" require a valid dose to be filled out.',
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
              '• "Took Med" Logging: Clicking "Took Med" creates a log entry for your history and triggers the Body Info map to show potential side effects.',
              style: TextStyle(
                fontSize: 13,
                color: NotelColors.textPrimary,
              ),
            ),
            SizedBox(height: 10),
            Text(
              '• "Took All Meds": Logs 1 dose for each active medication. If a medication is taken multiple times per day (e.g. 3x daily), taking it logs a single dose, not the full day\'s total.',
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
///
/// Round 48D2 — add mode (the `.add()` constructor, [med] null):
/// native's other title, "Add New Medication", with native's
/// add-mode field seeds — name/dose/start empty, frequency
/// prefilled "Once daily" (native keeps the frequency state at
/// its "Once daily" default when the Add button is tapped), and
/// no Ended Date field (native shows it only when editing an
/// archived med).
class _MedicationEditDialog extends StatefulWidget {
  final MedicationEntry? med;

  const _MedicationEditDialog({required this.med});

  const _MedicationEditDialog.add() : med = null;

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

  MedicationEntry? get _med => widget.med;

  bool get _isAdd => widget.med == null;

  /// Native validation: Save is enabled only while both the
  /// name and the dose are non-blank.
  bool get _canSave =>
      _name.text.trim().isNotEmpty && _dose.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: _med?.name ?? '');
    // Native: a stored "As prescribed" dose opens as an empty
    // field (exact match), forcing a real dose before Save.
    _dose = TextEditingController(
        text: _med == null
            ? ''
            : (_med!.dose == 'As prescribed' ? '' : _med!.dose));
    // Edit seeds from the stored frequency (display view: an
    // empty raw frequency shows as "Once daily"); add seeds
    // with native's "Once daily" default.
    _frequency =
        TextEditingController(text: _med?.frequency ?? 'Once daily');
    _start = TextEditingController(text: _med?.startDate ?? '');
    _end = TextEditingController(
        text: (_med?.isArchived ?? false) ? (_med!.endedDate ?? '') : '');
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
      // Add mode has no end date at all (the add op writes the
      // "Present" sentinel itself).
      endDate: _isAdd
          ? ''
          : ((_med!.isArchived) ? _end.text.trim() : _med!.endDate),
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
      title: Text(
        _isAdd ? 'Add New Medication' : 'Edit Medication',
        style: const TextStyle(
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
              if (_med?.isArchived ?? false) ...[
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
