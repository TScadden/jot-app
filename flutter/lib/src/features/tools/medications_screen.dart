import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 18 (Team B) — Medications tool, READ-ONLY port of the native
/// `MedicationsScreen.kt` layout.
///
/// Data source: `decodeProfileList((await fetchProfile())['medications'])`
/// — the server-synced medications blob. Entry shape mirrors what the
/// native `MedicationsViewModel` extracts from the profile:
/// `{name, dose, frequency, startDate, endDate, isPresent}` (dose may be
/// "As prescribed", frequency defaults to "Daily").
///
/// Rendered (layout per native):
/// - Intro copy (verbatim native).
/// - "Quick Actions" hero card with the active count; the "Took All Meds"
///   and "Add Medication" buttons render disabled (writes deferred).
/// - "Active Prescriptions" list: icon badge, name, "dose • frequency"
///   line, "Started …" chip; the per-card "Took Med" button renders
///   disabled (write deferred).
/// - Collapsible "Archived Medications (N)" section.
/// - Empty state (med icon, "No Active Medications") when the blob is
///   empty or the fetch fails — honest empty, never invented.
///
/// DEFERRED (display-only round): add/edit/archive/unarchive/delete,
/// "Took Med" / "Took All Meds" dose logging, and the status banner.
/// Dose logging in the main Tabs app is what feeds the Body Info map.

/// One read-only medication from the profile blob.
class ProfileMedication {
  final String name;
  final String dose;
  final String frequency;
  final String? startedDate;
  final String? endedDate;
  final bool isArchived;

  const ProfileMedication({
    required this.name,
    required this.dose,
    required this.frequency,
    this.startedDate,
    this.endedDate,
    required this.isArchived,
  });

  /// Tolerant parse: null when no usable name. Never throws.
  static ProfileMedication? fromJson(Map<String, dynamic> json) {
    try {
      final name = json['name']?.toString().trim() ?? '';
      if (name.isEmpty) return null;
      final dose = json['dose']?.toString().trim() ?? '';
      final frequency =
          json['frequency']?.toString().trim() ?? '';
      final startedDate =
          (json['startedDate'] ?? json['startDate'])?.toString().trim();
      final endedDate =
          (json['endedDate'] ?? json['endDate'])?.toString().trim();
      // Native extraction marks a profile med archived when it is no
      // longer present (ended), or when the flag is set explicitly.
      final presentRaw = json['isPresent'];
      final isPresent = presentRaw == null
          ? endedDate == null || endedDate.isEmpty
          : presentRaw == true;
      final archivedRaw = json['isArchived'];
      final isArchived =
          archivedRaw == true || !isPresent;
      return ProfileMedication(
        name: name,
        dose: dose,
        frequency: frequency.isEmpty ? 'Once daily' : frequency,
        startedDate:
            startedDate == null || startedDate.isEmpty ? null : startedDate,
        endedDate:
            endedDate == null || endedDate.isEmpty ? null : endedDate,
        isArchived: isArchived,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Collects medications from the decoded blob. Never throws.
List<ProfileMedication> collectMedications(
    List<Map<String, dynamic>> decoded) {
  final out = <ProfileMedication>[];
  final seen = <String>{};
  for (final map in decoded) {
    final med = ProfileMedication.fromJson(map);
    if (med != null && seen.add(med.name.toLowerCase())) out.add(med);
  }
  return out;
}

/// Native "Took Med" validity rule: a real dose AND a started date.
bool isDoseValid(ProfileMedication med) {
  final dose = med.dose.trim();
  return dose.isNotEmpty &&
      !dose.equalsAsPrescribed() &&
      (med.startedDate?.isNotEmpty ?? false);
}

extension on String {
  bool equalsAsPrescribed() =>
      toLowerCase() == 'as prescribed';
}

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
  List<ProfileMedication> _meds = const [];
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
      final meds = collectMedications(decoded);
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

  @override
  Widget build(BuildContext context) {
    final active = _meds.where((m) => !m.isArchived).toList();
    final archived = _meds.where((m) => m.isArchived).toList();

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
              // Write deferred: dose logging lives in the main Tabs app.
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
          // Write deferred: adding happens in the main Tabs app.
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
            'Read-only for now: adding medications and logging doses happen in the main Tabs app.',
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

  Widget _medicationCard(ProfileMedication med, bool isArchived) {
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
            if (!isArchived)
              // Write deferred: per-med dose logging is disabled.
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
              '• Read-only: this screen shows the medications synced from your Tabs profile. Adding, editing, archiving, and dose logging happen in the main Tabs app for now.',
              style: TextStyle(
                fontSize: 13,
                color: NotelColors.textPrimary,
              ),
            ),
            SizedBox(height: 10),
            Text(
              '• Active & Archived: medications you no longer take are archived here to keep your list clean while preserving history with their ended date.',
              style: TextStyle(
                fontSize: 13,
                color: NotelColors.textPrimary,
              ),
            ),
            SizedBox(height: 10),
            Text(
              '• "Took Med" Logging: logging a dose in the main Tabs app creates a history entry and feeds the Body Info map with potential side effects.',
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
