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
/// DEFERRED: add/edit/delete and "Took Med" / "Took All Meds" dose
/// logging. Adding medications happens in Settings → User Profile;
/// dose logging is not in the Lab yet.

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

  /// The FULL parsed blob — including deleted tombstones, which
  /// the display filters hide but an archive write must round-trip
  /// (dropping a row on save would delete it server-side).
  List<MedicationEntry> _meds = const [];
  bool _showArchived = true;

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
      final meds = parseMedicationBlob(decoded);
      if (!mounted) return;
      setState(() {
        _meds = meds;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      // Honest empty on any failure — nothing is invented.
      setState(() {
        _meds = const [];
        _loading = false;
      });
    }
  }

  /// The key archive/unarchive ops match on: the entry's id when
  /// it has one, else its name (blob rows can lack ids — the
  /// shared ops apply the same rule, see `data/medications.dart`).
  String _opKey(MedicationEntry med) =>
      med.id.isNotEmpty ? med.id : med.name;

  /// Archive/unarchive for real (Round 39): apply the shared op
  /// to the full list, update the UI immediately, then push the
  /// whole re-encoded blob through `POST /api/sync/profile`. On
  /// success the cached pull is invalidated; on failure a SnackBar
  /// says the change could not be saved and the screen reloads
  /// from the server — the UI never claims an unsaved state
  /// (Settings' `_pushProfile` honesty pattern).
  Future<void> _setArchived(MedicationEntry med, bool archive) async {
    final key = _opKey(med);
    final now = DateTime.now();
    final updated = archive
        ? archiveMedicationInList(_meds, key, now: now)
        : unarchiveMedicationInList(_meds, key, now: now);
    setState(() => _meds = updated);
    final ok = await _backend.postSyncProfile(
        {'medications': jsonEncode(encodeMedicationBlob(updated))});
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
  }

  @override
  Widget build(BuildContext context) {
    final active = activeMedicationEntries(_meds);
    final archived = archivedMedicationEntries(_meds);

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
                  ...active.map((m) => _medicationCard(m, false)),
                if (archived.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _archivedHeader(archived.length),
                  if (_showArchived) ...[
                    const SizedBox(height: 12),
                    ...archived.map((m) => _medicationCard(m, true)),
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
            'Archiving and restoring sync to your profile. Add medications in Settings → User Profile; dose logging is not in the Lab yet.',
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

  Widget _medicationCard(MedicationEntry med, bool isArchived) {
    final valid = isDoseValid(med);
    final accent =
        isArchived ? NotelColors.textSecondary : NotelColors.primary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
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
                  Text(
                    med.name,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: isArchived
                          ? NotelColors.textSecondary
                          : NotelColors.textPrimary,
                    ),
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
                key: ValueKey('archive_med_${_opKey(med)}'),
                icon: const Icon(Icons.archive,
                    size: 20, color: NotelColors.textSecondary),
                tooltip: 'Archive',
                onPressed: () => _setArchived(med, true),
              ),
            ],
            if (isArchived)
              IconButton(
                key: ValueKey('unarchive_med_${_opKey(med)}'),
                icon: const Icon(Icons.unarchive,
                    size: 20, color: NotelColors.textSecondary),
                tooltip: 'Restore',
                onPressed: () => _setArchived(med, false),
              ),
          ],
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
