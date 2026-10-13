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
///
/// Vera R39 fix pass: archive ops target entries by identity
/// (never name/id first-match — Finding 1), and saves go through
/// [MedicationDocument], which retains unparseable raw rows
/// verbatim and splices entry serializations back over their raw
/// rows (Finding 2).
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
/// delete it server-side. Unparseable rows are skipped HERE —
/// screens that save must go through [MedicationDocument], which
/// retains unparseable rows verbatim. Never throws.
List<MedicationEntry> parseMedicationBlob(
    List<Map<String, dynamic>> decoded) {
  final out = <MedicationEntry>[];
  for (final row in decoded) {
    final entry = MedicationEntry.fromBlobRow(row);
    if (entry != null) out.add(entry);
  }
  return out;
}

/// Encodes entries back to blob rows via [MedicationEntry.toBlobRow].
/// Entry-only encoding: it cannot retain rows the model could not
/// parse, so the screens' save paths use [MedicationDocument.encode]
/// instead (raw-row retention with splice-back).
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

/// Locates [target] in [list] for an archive/unarchive op.
///
/// Vera R39 fix pass, Finding 1: the previous name/id first-match
/// could stamp the WRONG row when id-less duplicates share a name.
/// Matching is now by row identity first — the screens render
/// from the same list instance they pass in, and parsed entries
/// are unique objects even when field-identical, so
/// `identical(...)` targets the exact row the user tapped. The
/// only fallback is a UNIQUE non-empty id match (a caller holding
/// an equal-but-not-identical copy of one row). When the id
/// matches more than one row the op REFUSES (returns -1) rather
/// than guess — a wrong-row write is impossible.
int _indexOfMedTarget(List<MedicationEntry> list, MedicationEntry target) {
  for (var i = 0; i < list.length; i++) {
    if (identical(list[i], target)) return i;
  }
  if (target.id.isEmpty) return -1;
  var found = -1;
  for (var i = 0; i < list.length; i++) {
    if (list[i].id == target.id) {
      if (found >= 0) return -1; // ambiguous — refuse, never guess
      found = i;
    }
  }
  return found;
}

/// Native archive, as a pure op on the entry list: [target] (the
/// exact entry instance the user acted on — see
/// [_indexOfMedTarget]) gets `isPresent=false`, `endDate` stamped
/// with [now]'s date (`MMM d, yyyy`) — unconditionally
/// overwriting any existing end date, exactly like native — and
/// `updatedAt` bumped to [now]. Unresolvable/ambiguous target →
/// list unchanged.
List<MedicationEntry> archiveMedicationInList(
  List<MedicationEntry> list,
  MedicationEntry target, {
  required DateTime now,
}) {
  final idx = _indexOfMedTarget(list, target);
  if (idx < 0) return list;
  final out = List<MedicationEntry>.of(list);
  out[idx] = list[idx].copyWith(
    isPresent: false,
    endDate: formatMedArchiveDate(now),
    updatedAt: now.millisecondsSinceEpoch,
  );
  return out;
}

/// Native unarchive, as a pure op on the entry list: [target]
/// gets `isPresent=true` and `endDate="Present"` — native clears
/// the ended date unconditionally (it cannot distinguish a
/// manually-set date), mirrored here — and `updatedAt` bumped
/// to [now]. Unresolvable/ambiguous target → list unchanged.
List<MedicationEntry> unarchiveMedicationInList(
  List<MedicationEntry> list,
  MedicationEntry target, {
  required DateTime now,
}) {
  final idx = _indexOfMedTarget(list, target);
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

/// A whole medications blob with RAW-ROW RETENTION (Vera R39 fix
/// pass, Finding 2): the raw decoded rows plus the parsed entries
/// aligned by raw index (`null` where a row could not be parsed).
///
/// Both screens' load → op → save flows go through this document,
/// so a save can never silently delete or strip a row the model
/// cannot fully represent. Encoding rule per raw row:
/// - unparseable → the raw row is emitted VERBATIM;
/// - parseable → the raw row overlaid with the entry's
///   [MedicationEntry.toBlobRow] (the entry wins on the 9 DTO
///   keys; any extra non-DTO raw keys survive).
///
/// Ops target rows by identity/position, never by name/id
/// first-match (Finding 1): [archiveEntry] takes the exact entry
/// instance from THIS document, and [archiveAt]/[unarchiveAt]
/// take the raw index the screens render (and key their buttons
/// with). Unresolvable or ambiguous targets return `this`
/// unchanged — the op refuses rather than guess.
class MedicationDocument {
  /// The raw decoded blob rows, in blob order.
  final List<Map<String, dynamic>> rawRows;

  /// Parsed entries aligned with [rawRows] by index; null where
  /// the raw row could not be parsed.
  final List<MedicationEntry?> _entries;

  MedicationDocument._(this.rawRows, this._entries);

  factory MedicationDocument.fromRawRows(List<Map<String, dynamic>> rows) {
    final raw = List<Map<String, dynamic>>.of(rows);
    return MedicationDocument._(
        raw, [for (final r in raw) MedicationEntry.fromBlobRow(r)]);
  }

  static final MedicationDocument empty =
      MedicationDocument._(<Map<String, dynamic>>[], <MedicationEntry?>[]);

  /// Number of raw rows (parseable or not).
  int get length => rawRows.length;

  /// The parsed entry at raw index [rawIndex], or null when the
  /// row is unparseable / the index is out of range.
  MedicationEntry? entryAt(int rawIndex) =>
      (rawIndex >= 0 && rawIndex < _entries.length)
          ? _entries[rawIndex]
          : null;

  /// Every parseable entry, in blob order.
  List<MedicationEntry> get entries =>
      [for (final e in _entries) ?e];

  /// Raw indices of the rows the active list shows (parseable,
  /// not deleted, not archived).
  List<int> get activeIndices => [
        for (var i = 0; i < _entries.length; i++)
          if (_entries[i] != null &&
              !_entries[i]!.isDeleted &&
              !_entries[i]!.isArchived)
            i,
      ];

  /// Raw indices of the rows the archived list shows (parseable,
  /// not deleted, archived).
  List<int> get archivedIndices => [
        for (var i = 0; i < _entries.length; i++)
          if (_entries[i] != null &&
              !_entries[i]!.isDeleted &&
              _entries[i]!.isArchived)
            i,
      ];

  /// Splice-back encoding (the class doc's rule): one output row
  /// per raw row, in order — unparseable rows verbatim, parseable
  /// rows overlaid with their entry's DTO serialization.
  List<Map<String, dynamic>> encode() => [
        for (var i = 0; i < rawRows.length; i++)
          if (_entries[i] == null)
            Map<String, dynamic>.of(rawRows[i])
          else
            {...rawRows[i], ..._entries[i]!.toBlobRow()},
      ];

  MedicationDocument _withEntry(int rawIndex, MedicationEntry entry) =>
      MedicationDocument._(rawRows, [
        for (var i = 0; i < _entries.length; i++)
          i == rawIndex ? entry : _entries[i],
      ]);

  /// Archive the exact entry instance [target] from this document
  /// (identity match, with the unique-id fallback of
  /// [_indexOfMedTarget] applied over the aligned entries).
  /// Native archive semantics; unresolvable/ambiguous → `this`.
  MedicationDocument archiveEntry(MedicationEntry target,
      {required DateTime now}) {
    final parsed = entries;
    final idx = _indexOfMedTarget(parsed, target);
    if (idx < 0) return this;
    final rawIndex = _rawIndexOfParsedIndex(idx);
    return _withEntry(
        rawIndex,
        _entries[rawIndex]!.copyWith(
          isPresent: false,
          endDate: formatMedArchiveDate(now),
          updatedAt: now.millisecondsSinceEpoch,
        ));
  }

  /// Unarchive the exact entry instance [target] from this
  /// document. Native unarchive semantics; unresolvable/
  /// ambiguous → `this`.
  MedicationDocument unarchiveEntry(MedicationEntry target,
      {required DateTime now}) {
    final parsed = entries;
    final idx = _indexOfMedTarget(parsed, target);
    if (idx < 0) return this;
    final rawIndex = _rawIndexOfParsedIndex(idx);
    return _withEntry(
        rawIndex,
        _entries[rawIndex]!.copyWith(
          isPresent: true,
          endDate: 'Present',
          updatedAt: now.millisecondsSinceEpoch,
          archivedStamp: false,
        ));
  }

  /// Archive the row at raw index [rawIndex] (the index the
  /// screens render and key buttons with). Unparseable or
  /// out-of-range → `this` unchanged.
  MedicationDocument archiveAt(int rawIndex, {required DateTime now}) {
    final entry = entryAt(rawIndex);
    if (entry == null) return this;
    return archiveEntry(entry, now: now);
  }

  /// Unarchive the row at raw index [rawIndex]. Unparseable or
  /// out-of-range → `this` unchanged.
  MedicationDocument unarchiveAt(int rawIndex, {required DateTime now}) {
    final entry = entryAt(rawIndex);
    if (entry == null) return this;
    return unarchiveEntry(entry, now: now);
  }

  /// Maps an index into [entries] (parseable-only) back to its
  /// raw row index.
  int _rawIndexOfParsedIndex(int parsedIndex) {
    var seen = -1;
    for (var i = 0; i < _entries.length; i++) {
      if (_entries[i] != null) {
        seen++;
        if (seen == parsedIndex) return i;
      }
    }
    return -1;
  }
}

/// Native "Took Med" validity rule: a real dose (set, and not
/// the "As prescribed" placeholder) AND a started date.
bool isDoseValid(MedicationEntry med) {
  final dose = med.dose.trim();
  return dose.isNotEmpty &&
      dose.toLowerCase() != 'as prescribed' &&
      (med.startedDate?.isNotEmpty ?? false);
}
