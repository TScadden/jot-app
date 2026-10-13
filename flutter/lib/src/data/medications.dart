import 'dart:math';

import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
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
  /// Never serialized by [toBlobRow] — the native DTO has no such
  /// key. [MedicationDocument.encode] is the one exception: when a
  /// raw row already carried the key, it re-applies this stamp
  /// state over the raw value so an op's stamp change persists
  /// (R39 fix pass 2).
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

  /// The entry's post-op defensive-stamp state, exposed for
  /// [MedicationDocument.encode]: `true` while the explicit
  /// `isArchived` stamp is held, `false` once an unarchive op has
  /// cleared it (or when the row never carried one).
  bool get hasArchivedStamp => _hasArchivedStamp;

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

/// Tolerant parse of a stored medication date string — native's
/// edit dialog uses FREE-TEXT date fields, so real blob rows vary:
/// "Oct 13, 2026", "October 6,2026", "April 2026". Returns null
/// when the string carries no recognizable month name + year; a
/// month+year string resolves to the 1st of the month. Used to
/// seed the Round 46 edit dialog's date picker; a pick is always
/// written back via [formatMedArchiveDate] (`MMM d, yyyy` — the
/// native field examples and archive stamp format).
DateTime? parseMedicationDate(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  final m = RegExp(r'^([A-Za-z]+)\.?\s+(?:(\d{1,2})\s*,?\s*)?(\d{4})$')
      .firstMatch(s);
  if (m == null) return null;
  const months = <String, int>{
    'jan': 1, 'january': 1,
    'feb': 2, 'february': 2,
    'mar': 3, 'march': 3,
    'apr': 4, 'april': 4,
    'may': 5,
    'jun': 6, 'june': 6,
    'jul': 7, 'july': 7,
    'aug': 8, 'august': 8,
    'sep': 9, 'sept': 9, 'september': 9,
    'oct': 10, 'october': 10,
    'nov': 11, 'november': 11,
    'dec': 12, 'december': 12,
  };
  final month = months[m.group(1)!.toLowerCase()];
  if (month == null) return null;
  final year = int.tryParse(m.group(3)!);
  if (year == null) return null;
  final day = m.group(2) == null ? 1 : int.tryParse(m.group(2)!);
  if (day == null || day < 1 || day > 31) return null;
  return DateTime(year, month, day);
}

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

/// Native edit (`MedicationsViewModel.updateMedication`), as a
/// pure op on the entry list (Round 46): [target] gets the
/// dialog's name/dose/frequency/start/end values and an
/// `updatedAt` bump to [now]. Archive state is NOT touched —
/// native keeps `isArchived` as a separate flag: an active med
/// stays active (and serializes `endDate: "Present"` regardless),
/// an archived med stays archived with its (possibly edited or
/// cleared) end date. Values arrive pre-normalized by the dialog
/// exactly as native's save handler produces them: name/dose
/// trimmed, blank frequency already defaulted to `"Once daily"`,
/// dates as `MMM d, yyyy` strings (or `''`). Unresolvable/
/// ambiguous target → list unchanged.
List<MedicationEntry> editMedicationInList(
  List<MedicationEntry> list,
  MedicationEntry target, {
  required String name,
  required String dose,
  required String frequency,
  required String startDate,
  required String endDate,
  required DateTime now,
}) {
  final idx = _indexOfMedTarget(list, target);
  if (idx < 0) return list;
  final out = List<MedicationEntry>.of(list);
  out[idx] = list[idx].copyWith(
    name: name,
    dose: dose,
    frequency: frequency,
    startDate: startDate,
    endDate: endDate,
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
/// `isArchived` splice-back rule (Vera R39 fix pass 2): the
/// overlay above cannot carry the defensive stamp —
/// [MedicationEntry.toBlobRow] correctly never emits `isArchived`
/// (the native DTO has no such key), so a raw row carrying
/// `isArchived: true` would splice that `true` back into the
/// pushed blob even after an unarchive op cleared the stamp on
/// the entry, and the row would re-parse as archived forever.
/// So, for a parseable row, the stamp is controlled explicitly:
/// - raw row carried an `isArchived` key → the encoded row's
///   `isArchived` is the entry's post-op stamp state
///   ([MedicationEntry.hasArchivedStamp]: preserved `true` for an
///   untouched/archived entry, explicit `false` — not key
///   removal — for a cleared/unarchived one), so the encoded row
///   re-parses to the entry's archived classification;
/// - raw row did NOT carry an `isArchived` key → the encoded row
///   does not gain one (byte-stability for normal native rows;
///   the key is never invented).
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
  /// rows overlaid with their entry's DTO serialization, with the
  /// entry's stamp state controlling a pre-existing raw
  /// `isArchived` key.
  List<Map<String, dynamic>> encode() => [
        for (var i = 0; i < rawRows.length; i++)
          if (_entries[i] == null)
            Map<String, dynamic>.of(rawRows[i])
          else
            _encodeParsedRow(i),
      ];

  Map<String, dynamic> _encodeParsedRow(int rawIndex) {
    final raw = rawRows[rawIndex];
    final entry = _entries[rawIndex]!;
    final encoded = <String, dynamic>{...raw, ...entry.toBlobRow()};
    // Stamp control (class doc): only when the raw row already
    // carried the key — overwrite it with the entry's post-op
    // stamp state instead of letting the raw value splice back.
    if (raw.containsKey('isArchived')) {
      encoded['isArchived'] = entry.hasArchivedStamp;
    }
    return encoded;
  }

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

  /// Edit the exact entry instance [target] from this document
  /// (identity match, with the unique-id fallback of
  /// [_indexOfMedTarget] applied over the aligned entries).
  /// Native edit semantics (see [editMedicationInList]): the
  /// dialog's field values replace the row's, `updatedAt` bumps,
  /// archive state is preserved. Unresolvable/ambiguous → `this`.
  MedicationDocument editEntry(
    MedicationEntry target, {
    required String name,
    required String dose,
    required String frequency,
    required String startDate,
    required String endDate,
    required DateTime now,
  }) {
    final parsed = entries;
    final idx = _indexOfMedTarget(parsed, target);
    if (idx < 0) return this;
    final rawIndex = _rawIndexOfParsedIndex(idx);
    return _withEntry(
        rawIndex,
        _entries[rawIndex]!.copyWith(
          name: name,
          dose: dose,
          frequency: frequency,
          startDate: startDate,
          endDate: endDate,
          updatedAt: now.millisecondsSinceEpoch,
        ));
  }

  /// Append ONE new active medication (Round 48D2 — native
  /// `MedicationsViewModel.addMedication`): a fresh row at the
  /// END of the blob, every existing raw row retained verbatim
  /// and in order. Native's add semantics: name/dose trimmed by
  /// the caller, blank frequency already defaulted to
  /// `"Once daily"`, a blank start date stored as `''` (native's
  /// null), `endDate` the `"Present"` sentinel, `isPresent=true`,
  /// `isDeleted=false`, `updatedAt` = [now], and a fresh UUID
  /// [id] (native `UUID.randomUUID()`; the screen generates it
  /// via [generateMedicationUuid] — injected here so tests are
  /// deterministic).
  MedicationDocument addEntry({
    required String name,
    required String dose,
    required String frequency,
    required String startDate,
    required String id,
    required DateTime now,
  }) {
    final entry = MedicationEntry(
      id: id,
      name: name,
      startDate: startDate,
      endDate: 'Present',
      isPresent: true,
      dose: dose,
      frequency: frequency,
      updatedAt: now.millisecondsSinceEpoch,
      isDeleted: false,
    );
    return MedicationDocument._(
      [...rawRows, entry.toBlobRow()],
      [..._entries, entry],
    );
  }

  /// Permanently delete the exact entry instance [target] from
  /// this document (Round 48D2 — the archived card's delete
  /// affordance): the row is REMOVED from the document, so the
  /// splice-back encode pushes the full list WITHOUT it and
  /// every other row — parseable or not — is preserved verbatim
  /// and in order.
  ///
  /// Why removal, not an `isDeleted` tombstone row in the pushed
  /// blob: the tombstone is native's DEVICE-LOCAL DAO state
  /// (`MedicationsViewModel.deleteMedication` stamps
  /// `isDeleted=true` locally to stop sync resurrection), but
  /// native's own sync push filters deleted rows OUT of the
  /// blob it sends (`syncMedicationsToPreferencesAndCloud` maps
  /// only `!isDeleted` rows), and native Settings' delete
  /// (`SettingsViewModel.deleteMedication`) drops the row from
  /// the profile list and pushes the whole remaining list —
  /// exactly what the Flutter Settings screen's delete does.
  /// The server-visible outcome everywhere is "the row is
  /// absent"; Flutter has no local DAO merge to resurrect it,
  /// so removal IS the shared model's delete semantics here.
  /// Unresolvable/ambiguous target → `this` unchanged.
  MedicationDocument deleteEntry(MedicationEntry target) {
    final parsed = entries;
    final idx = _indexOfMedTarget(parsed, target);
    if (idx < 0) return this;
    final rawIndex = _rawIndexOfParsedIndex(idx);
    if (rawIndex < 0) return this;
    return MedicationDocument._(
      [
        for (var i = 0; i < rawRows.length; i++)
          if (i != rawIndex) rawRows[i],
      ],
      [
        for (var i = 0; i < _entries.length; i++)
          if (i != rawIndex) _entries[i],
      ],
    );
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

  /// Round 48 fix (Vera F1) — re-resolves [target], an entry
  /// rendered from an EARLIER document (typically this screen's
  /// load-time snapshot), against THIS (freshly pulled) document.
  /// A write must never splice into the stale snapshot: a med
  /// added server-side after the screen opened would be silently
  /// reverted by the next push built from it. Resolution order,
  /// mirroring the Lists `_resolveListRow` discipline:
  /// 1. identity — the exact instance (same-document callers);
  /// 2. the raw-index hint — trusted only when the fresh row at
  ///    that index still carries the target's name (and, when both
  ///    rows carry ids, the same id): this is what lets the
  ///    SECOND of two id-less duplicate names resolve exactly;
  /// 3. a UNIQUE non-empty id match;
  /// 4. for id-less targets, a unique name+start+dose composite,
  ///    then a unique name match.
  /// Anything else (gone, or ambiguous at every level) returns
  /// null — the caller refuses the write with a visible error
  /// rather than guess (Vera F7: a refused op never reports
  /// success and never pushes).
  MedicationEntry? resolveFreshEntry(MedicationEntry target,
      {int? rawIndexHint}) {
    for (final e in entries) {
      if (identical(e, target)) return e;
    }
    if (rawIndexHint != null) {
      final candidate = entryAt(rawIndexHint);
      if (candidate != null && candidate.name == target.name) {
        if (target.id.isEmpty ||
            candidate.id.isEmpty ||
            candidate.id == target.id) {
          return candidate;
        }
      }
    }
    if (target.id.isNotEmpty) {
      MedicationEntry? found;
      for (final e in entries) {
        if (e.id == target.id) {
          if (found != null) return null; // ambiguous — refuse
          found = e;
        }
      }
      return found;
    }
    final composite = entries
        .where((e) =>
            e.name == target.name &&
            e.startDate == target.startDate &&
            e.dose == target.dose)
        .toList();
    if (composite.length == 1) return composite.single;
    if (composite.length > 1) return null;
    final byName = entries.where((e) => e.name == target.name).toList();
    return byName.length == 1 ? byName.single : null;
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

/// A fresh UUID v4 for a newly added medication — native
/// `addMedication` assigns `UUID.randomUUID().toString()`.
/// Hand-rolled over [Random.secure] (the codebase carries no
/// uuid package dependency); the version (4) and variant bits
/// are set per RFC 4122.
String generateMedicationUuid() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx
  String hex(int i) => bytes[i].toRadixString(16).padLeft(2, '0');
  return '${hex(0)}${hex(1)}${hex(2)}${hex(3)}-'
      '${hex(4)}${hex(5)}-${hex(6)}${hex(7)}-'
      '${hex(8)}${hex(9)}-${hex(10)}${hex(11)}'
      '${hex(12)}${hex(13)}${hex(14)}${hex(15)}';
}

// ── Dose logging (Round 48D2) ────────────────────────────────────
//
// TWO native dose-log writers exist, and they disagree:
//
// - `MedicationsViewModel.logMedicationDose` (the Medications
//   tab's own writer): body `"Took Medication: {name} {dose}
//   (1 dose - {frequency})"`, chips `["Medication Tab"]`,
//   manualText `"Logged from Medications tab"`, category 8 —
//   with NO dedupe (every tap inserts another entry) and NO
//   update to any medication/occurrence record.
// - `ScheduledDoseRepository.recordDoseAction` (the Today
//   writer): body `"Took {name} {dose}"`, chips `"[]"`,
//   manualText `""`, category 8 — IDEMPOTENT by occurrence key
//   ("repeated taps do not duplicate log entries or
//   occurrences"), plus a device-local occurrence row.
//
// The Medications-tab body is NOT readable as TAKEN by Today's
// plan: the evidence reader (`medTakenFromEntries`, Round 41 —
// log entries are the source of truth for TAKEN, winning over
// the local record) matches `"Took {name}…"` in the Medication
// category, and `"Took Medication: …"` never matches it. A
// Medications-tab log in the native tab's own shape would
// therefore leave Today's dose PENDING — two native writers,
// one incoherent log. The Flutter port resolves that the only
// coherent way (the coordinator's Round 48D2 brief pins it):
// dose logs written HERE use the Today BODY shape — same body,
// same category resolution, same max+1 id discipline, same
// corrected-skip conventions — so a dose logged on either
// surface reads as taken on both.
//
// Round 48 fix (Vera F3) — the entry must ALSO satisfy Body
// Info's impact engine, the second reader. Round 48D2's shape
// (chips `'[]'`, manualText `''`) satisfied Today only: it
// carried NONE of the Medications-tab markers the engine gates
// its medication-dose card on (native `BodyImpactEngine.kt:145`:
// source "Medications Tab" / "logged from medications tab"
// text; the Flutter port at `body_info_screen.dart`:
// `isMedTabEntry` — chips containing "Medication Tab", or the
// entry text containing "logged from medications tab"), so a
// tab-logged dose produced NO Body Info card at all. FINAL
// SHAPE (all three fields deliberate, traced against both
// Flutter readers):
// - body `"Took {name} {dose}"` — UNCHANGED. Today's reader
//   checks body + category only, so this is the TAKEN evidence.
// - chips `'["Medication Tab"]'` — native's tab-writer chip;
//   `isMedTabEntry` matches it directly, opening the engine's
//   medication-dose (and peptide) gate.
// - manualText `"Logged from Medications tab. Took Medication:
//   {name} {dose} (1 dose - {frequency})"` — the field Today's
//   reader ignores entirely, carrying what Body Info's
//   extraction genuinely needs and the Today body cannot:
//   (a) the gate phrase "logged from medications tab" as a
//   second, chip-independent marker (native's own manualText
//   for tab logs); (b) the FREQUENCY: the engine derives the
//   active window from frequency text in the entry ("twice
//   daily"→12h, "3x daily"→8h, "once daily"→24h, else 12h) —
//   native's tab body carries it in its `(1 dose - {frequency})`
//   segment, the Today body has no frequency at all, so without
//   this segment every dose defaulted to a 12h window; and
//   (c) the NAME in extractable position: the engine's med-name
//   extraction takes the text after "Took Medication:" up to
//   "(" — embedding native's full tab marker here makes that
//   extraction yield exactly `"{name} {dose}"` (the same value
//   native's own body yields), so the card's "Systemic
//   ({name} {dose})" title and its per-med side-effect lookup
//   (substring match on the name) behave identically to a
//   native tab log. Body Info concatenates body + manualText
//   for both its gate text and its display text, which is why
//   this one field reaches every check; Today never reads
//   manualText, so nothing here can disturb TAKEN.
//
// Per-day dedupe (the `recordDoseAction` rule): one standing
// uncorrected `"Took {name}…"` entry for a med on a given day
// IS the dose's taken evidence; building a take for a med that
// already has one posts nothing for it. A `"[Corrected to
// Skipped] Took …"` entry does NOT block a take (native Today:
// the skip nulls the occurrence's log id, so a later take
// posts a fresh `"Took …"` entry, and the reader checks taken
// before skipped). No local med record is written — native's
// Medications-tab writer updates none, and a TAKEN record in
// Today's plan store would be inert anyway (Round 41: taken
// derives from entries only; the local record speaks only for
// SNOOZED). The AI side-effect cache native's tab writer fills
// is a device-local Gemini cache with no Flutter equivalent on
// this screen; it carries no user-visible state.

/// The body of the log entry a "Took Med" tap writes — the
/// Today/`recordDoseAction` shape (`"Took {name} {dose}"`, or
/// `"Took {name}"` when the dose is blank; callers gate on
/// [isDoseValid], so a blank dose is a defensive case only).
String medTakeEntryBody(MedicationEntry med) {
  final dose = med.dose.trim();
  return 'Took ${med.name}${dose.isNotEmpty ? ' $dose' : ''}';
}

/// The chips of a med-take entry — native's Medications-tab
/// chip (Vera F3; see the dose-logging trace above).
const String medTakeEntryChips = '["Medication Tab"]';

/// The manualText of a med-take entry (Vera F3; see the
/// dose-logging trace above): native's tab-log marker plus its
/// full `"Took Medication: {name} {dose} (1 dose - {frequency})"`
/// segment, so Body Info's gate, frequency-window, and med-name
/// extraction all resolve exactly as for a native tab log. The
/// frequency is the med's display frequency (a blank raw
/// frequency reads "Once daily", the card's own rendering).
String medTakeManualText(MedicationEntry med) {
  final dose = med.dose.trim();
  final nameDose = '${med.name}${dose.isNotEmpty ? ' $dose' : ''}';
  return 'Logged from Medications tab. '
      'Took Medication: $nameDose (1 dose - ${med.frequency})';
}

/// Round 48 fix (Vera F2, med half) — a success-distinguishing
/// variant of [TabsBackend.fetchLogEntryDtos], mirroring
/// [TabsBackend.fetchHabitsOrNull]: the plain fetch returns an
/// empty list on ANY failure, indistinguishable from a real
/// empty log, so a caller computing max+1 ids or a dedupe check
/// from it can post id 1 over an existing log or double-post.
/// Returns null when the sync pull itself failed (null body) or
/// carries no usable `entries` list; the parsed list — possibly
/// genuinely empty — only when the server actually answered.
/// The Medications take path aborts (zero posts, visible error)
/// on null, before any id or dedupe computation.
extension MedTakeEntryFetch on TabsBackend {
  Future<List<QuickLogEntry>?> fetchLogEntryDtosOrNull() async {
    final body = await fetchSyncPull();
    if (body == null) return null;
    final entries = body['entries'];
    if (entries is! List) return null;
    final out = <QuickLogEntry>[];
    for (final e in entries) {
      if (e is Map<String, dynamic>) {
        try {
          out.add(QuickLogEntry.fromJson(e));
        } catch (_) {
          // Skip malformed rows — never fail the whole list.
        }
      }
    }
    return out;
  }
}

/// Builds the entries ONE dose-log action posts: one entry per
/// med in [meds] that is not already logged as taken today,
/// in [meds] order, with fresh ids continuing from the maximum
/// id across ALL [existingEntries] (the round-19 max+1
/// discipline Today's take uses). Entries are in the Medication
/// category — resolved by name, falling back to the seeded id
/// 8 ([resolveSummaryCategoryId], the same resolver Today
/// uses) — with the dual-reader payload ([medTakeEntryChips] /
/// [medTakeManualText]; see the dose-logging trace above) and
/// timestamp [now]. Returns null when the Medication category cannot be
/// resolved at all (the caller fails honestly and posts
/// nothing — never a guessed category). An empty list means
/// every med was already logged today: a successful no-op,
/// NOT a failure.
List<QuickLogEntry>? buildMedTakeLogEntries({
  required List<MedicationEntry> meds,
  required List<QuickLogEntry> existingEntries,
  required List<QuickLogCategory> categories,
  required DateTime now,
}) {
  final medCategoryId = resolveSummaryCategoryId(categories,
      name: 'Medication', fallbackId: 8);
  if (medCategoryId == null) return null;
  final todayStr = dateStrOf(now);
  // The evidence pool grows as entries are planned, so a batch
  // (Took All) can never double-post: the reader is name-based
  // (one "Took {name}…" entry is taken evidence for that name
  // today), so a second same-name row in the batch is already
  // covered by the first row's planned entry.
  final evidence = existingEntries
      .where((e) =>
          dateStrOf(DateTime.fromMillisecondsSinceEpoch(e.timestamp)) ==
          todayStr)
      .toList();
  var maxId = 0;
  for (final e in existingEntries) {
    if (e.id > maxId) maxId = e.id;
  }
  final out = <QuickLogEntry>[];
  for (final med in meds) {
    if (medTakenFromEntries(
      medName: med.name,
      todayEntries: evidence,
      medicationCategoryId: medCategoryId,
    )) {
      continue;
    }
    maxId += 1;
    final entry = QuickLogEntry(
      id: maxId,
      categoryId: medCategoryId,
      body: medTakeEntryBody(med),
      chips: medTakeEntryChips,
      manualText: medTakeManualText(med),
      timestamp: now.millisecondsSinceEpoch,
    );
    out.add(entry);
    evidence.add(entry);
  }
  return out;
}
