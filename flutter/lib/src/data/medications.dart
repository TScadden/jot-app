import 'package:tabs_lab/src/data/today_summary.dart';

/// Round 39 — the ONE shared medication model: the single synced
/// source of truth for the Tools Medications tab and Settings →
/// User Profile (founder rule: archive state is interpreted
/// identically everywhere).
///
/// Blob spec (native ground truth, treated as spec):
/// - The server profile `medications` blob is a JSON string of a
///   list of the native Settings DTO (`SettingsViewModel.kt:1684`):
///   `{id (uuid string), name, startDate, endDate, isPresent,
///   dose (default "As prescribed"), frequency (default "Daily"),
///   updatedAt (epoch ms), isDeleted}`, pushed via
///   `POST /api/sync/profile` field `medications`.
/// - The blob has NO `isArchived` field. Archived ⟺
///   `isPresent == false` (native pull merge, SyncManager.kt:
///   `isArchived = !med.isPresent`, `endedDate = med.endDate` only
///   when not present). Active meds always serialize `endDate` as
///   the literal string `"Present"`.
/// - Native archive (`MedicationsViewModel.archiveMedication`):
///   stamps `endedDate` with TODAY in `MMM d, yyyy` format —
///   unconditionally overwriting any existing end date — sets
///   `isArchived=true`, bumps `updatedAt`, and syncs the blob
///   (`endDate`=stamp, `isPresent=false`).
/// - Native unarchive: `isArchived=false`, `endedDate=null`
///   unconditionally (native cannot distinguish a manually-set
///   date — it clears it; mirrored here), so the blob becomes
///   `endDate="Present"`, `isPresent=true`.
///
/// Display defaults vs. round-trip fidelity: the Tools screen's
/// pinned display defaults live at the view level — [dose] is the
/// raw blob value (`''` stays `''`; the card renders "Dose not
/// set"), and [frequency] is a view over the raw value (empty →
/// `'Once daily'`). [toBlobRow] always emits the RAW values, so
/// round-tripping a parsed entry loses nothing except the
/// documented archive-op changes.
class MedicationEntry {
  final String id;
  final String name;
  final String startDate;

  /// Raw end date as stored in the blob: the `"Present"` sentinel
  /// for active meds, the stamped/entered date for archived meds,
  /// or `''` when absent.
  final String endDate;
  final bool isPresent;

  /// Raw dose value (no display default applied — `''` stays `''`).
  final String dose;
  final int updatedAt;
  final bool isDeleted;

  /// The raw frequency exactly as stored in the blob. [frequency]
  /// is the display view over this value.
  final String _frequencyRaw;

  /// Defensive explicit-archive stamp: a blob row that (against
  /// the native DTO) carries `isArchived == true` counts as
  /// archived even when `isPresent` reads true (R35 precedent).
  /// Never serialized — the native DTO has no such key.
  final bool _hasArchivedStamp;

  MedicationEntry({
    this.id = '',
    required this.name,
    this.startDate = '',
    this.endDate = '',
    this.isPresent = true,
    this.dose = '',
    String frequency = '',
    this.updatedAt = 0,
    this.isDeleted = false,
    bool isArchived = false,
  })  : _frequencyRaw = frequency,
        _hasArchivedStamp = isArchived;

  /// Display frequency: the Tools screen's pinned default — an
  /// empty raw frequency renders as `'Once daily'`.
  String get frequency =>
      _frequencyRaw.isEmpty ? 'Once daily' : _frequencyRaw;

  /// The raw frequency exactly as stored (what [toBlobRow] emits).
  String get rawFrequency => _frequencyRaw;

  /// Archived ⟺ not present (native), or an explicit defensive
  /// `isArchived` stamp on the row. When the blob's `isPresent`
  /// was missing/unparseable, [fromBlobRow] already resolved
  /// [isPresent] from the end-date signal (a non-empty endDate
  /// that is not `"Present"` means archived), so this getter is
  /// the one interpretation every surface shares.
  bool get isArchived => _hasArchivedStamp || !isPresent;

  /// Tools-card view: the start date, or null when unset.
  String? get startedDate {
    final s = startDate.trim();
    return s.isEmpty ? null : s;
  }

  /// Tools-card view: the end date, or null when unset — an empty
  /// value or the `"Present"` sentinel both mean "no end date".
  String? get endedDate {
    final e = endDate.trim();
    if (e.isEmpty || e.toLowerCase() == 'present') return null;
    return e;
  }

  /// The exact filter the Today Summary plan needs (native keeps
  /// only `!isArchived && !isDeleted` meds). Exposed here so every
  /// surface agrees; `today_summary.dart` is not modified.
  bool get isPlanVisible => !isDeleted && !isArchived;

  MedicationEntry copyWith({
    String? id,
    String? name,
    String? startDate,
    String? endDate,
    bool? isPresent,
    String? dose,
    String? frequency,
    int? updatedAt,
    bool? isDeleted,
    bool? archivedStamp,
  }) {
    return MedicationEntry(
      id: id ?? this.id,
      name: name ?? this.name,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      isPresent: isPresent ?? this.isPresent,
      dose: dose ?? this.dose,
      frequency: frequency ?? _frequencyRaw,
      updatedAt: updatedAt ?? this.updatedAt,
      isDeleted: isDeleted ?? this.isDeleted,
      isArchived: archivedStamp ?? _hasArchivedStamp,
    );
  }

  /// Tolerant parse of one blob row: null on a nameless/blank
  /// name, never throws. Flag and timestamp parses are loose (the
  /// server serializes int8-style fields as strings) — the shared
  /// parsers from `today_summary.dart`, not a third bool parser.
  static MedicationEntry? fromBlobRow(Map<String, dynamic> row) {
    try {
      final name = '${row['name'] ?? ''}'.trim();
      if (name.isEmpty) return null;
      final startDate =
          '${row['startDate'] ?? row['startedDate'] ?? ''}'.trim();
      final endDate =
          '${row['endDate'] ?? row['endedDate'] ?? ''}'.trim();
      final present = parseLooseBoolOrNull(row['isPresent']);
      // Fallback when isPresent is missing/unparseable: the
      // end-date signal — a non-empty endDate that is not the
      // "Present" sentinel means the med has ended (archived).
      final resolvedPresent = present ??
          !(endDate.isNotEmpty && endDate.toLowerCase() != 'present');
      return MedicationEntry(
        id: '${row['id'] ?? ''}'.trim(),
        name: name,
        startDate: startDate,
        endDate: endDate,
        isPresent: resolvedPresent,
        dose: '${row['dose'] ?? ''}'.trim(),
        frequency: '${row['frequency'] ?? ''}'.trim(),
        updatedAt: parseLooseIntOrNull(row['updatedAt']) ?? 0,
        isDeleted: parseLooseBoolOrNull(row['isDeleted']) == true,
        isArchived: parseLooseBoolOrNull(row['isArchived']) == true,
      );
    } catch (_) {
      return null;
    }
  }

  /// Serializes to exactly the native DTO key set. An active
  /// (present) entry always serializes `endDate: "Present"`; an
  /// archived entry serializes its stamped end date (or `""` if
  /// somehow absent — a `"Present"` value is not a stamp).
  Map<String, dynamic> toBlobRow() {
    final archived = isArchived;
    final stamped = endDate.trim();
    return <String, dynamic>{
      'id': id,
      'name': name,
      'startDate': startDate,
      'endDate': archived
          ? (stamped.isEmpty || stamped.toLowerCase() == 'present'
              ? ''
              : stamped)
          : 'Present',
      'isPresent': !archived,
      'dose': dose,
      'frequency': _frequencyRaw,
      'updatedAt': updatedAt,
      'isDeleted': isDeleted,
    };
  }
}

/// Full-fidelity parse of a decoded medications blob: preserves
/// EVERY parseable row — NO name dedupe — because writes
/// round-trip the entire list; dropping a row on save would
/// delete it server-side. Unparseable rows are skipped. Never
/// throws.
List<MedicationEntry> parseMedicationBlob(
    List<Map<String, dynamic>> decoded) {
  final out = <MedicationEntry>[];
  for (final row in decoded) {
    final entry = MedicationEntry.fromBlobRow(row);
    if (entry != null) out.add(entry);
  }
  return out;
}

/// Encodes the full list back to blob rows via [MedicationEntry.toBlobRow].
List<Map<String, dynamic>> encodeMedicationBlob(
        List<MedicationEntry> entries) =>
    entries.map((e) => e.toBlobRow()).toList();

/// Active medications for display: not deleted, not archived.
List<MedicationEntry> activeMedicationEntries(
        List<MedicationEntry> entries) =>
    entries.where((e) => !e.isDeleted && !e.isArchived).toList();

/// Archived medications for display: not deleted, archived.
List<MedicationEntry> archivedMedicationEntries(
        List<MedicationEntry> entries) =>
    entries.where((e) => !e.isDeleted && e.isArchived).toList();

/// `SimpleDateFormat("MMM d, yyyy")` — e.g. "Oct 13, 2026" —
/// with a hand-rolled month table (house pattern, heart_data.dart).
String formatMedArchiveDate(DateTime d) {
  const months = [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  return '${months[d.month]} ${d.day}, ${d.year}';
}

/// Whether [key] identifies [entry]: match on id when the entry
/// has a non-empty id, else on name. Blob rows written outside
/// the native Settings DTO flow can lack ids; the name fallback
/// keeps archive/unarchive working for those rows everywhere.
bool _matchesMedKey(MedicationEntry entry, String key) =>
    entry.id.isNotEmpty ? entry.id == key : entry.name == key;

/// Native archive, as a pure op: the target gets
/// `isPresent=false`, `endDate` stamped with [now]'s date
/// (`MMM d, yyyy`) — unconditionally overwriting any existing
/// end date, exactly like native — and `updatedAt` bumped to
/// [now]. Unknown id → list unchanged.
List<MedicationEntry> archiveMedicationInList(
  List<MedicationEntry> list,
  String id, {
  required DateTime now,
}) {
  final idx = list.indexWhere((e) => _matchesMedKey(e, id));
  if (idx < 0) return list;
  final out = List<MedicationEntry>.of(list);
  out[idx] = list[idx].copyWith(
    isPresent: false,
    endDate: formatMedArchiveDate(now),
    updatedAt: now.millisecondsSinceEpoch,
  );
  return out;
}

/// Native unarchive, as a pure op: the target gets
/// `isPresent=true` and `endDate="Present"` — native clears the
/// ended date unconditionally (it cannot distinguish a
/// manually-set date), mirrored here — and `updatedAt` bumped
/// to [now]. Unknown id → list unchanged.
List<MedicationEntry> unarchiveMedicationInList(
  List<MedicationEntry> list,
  String id, {
  required DateTime now,
}) {
  final idx = list.indexWhere((e) => _matchesMedKey(e, id));
  if (idx < 0) return list;
  final out = List<MedicationEntry>.of(list);
  out[idx] = list[idx].copyWith(
    isPresent: true,
    endDate: 'Present',
    updatedAt: now.millisecondsSinceEpoch,
    archivedStamp: false,
  );
  return out;
}

/// Native "Took Med" validity rule: a real dose (set, and not
/// the "As prescribed" placeholder) AND a started date.
bool isDoseValid(MedicationEntry med) {
  final dose = med.dose.trim();
  return dose.isNotEmpty &&
      dose.toLowerCase() != 'as prescribed' &&
      (med.startedDate?.isNotEmpty ?? false);
}
