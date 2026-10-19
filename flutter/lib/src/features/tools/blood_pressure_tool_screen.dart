import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/csv_file_picker.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/skeleton.dart';

/// Where a blood pressure reading came from.
enum BpSource { manual, healthConnect }

/// One merged reading tagged with its source.
class BpUiRecord {
  final BpRecord record;
  final BpSource source;

  /// Vera F8 (fix round): the id stored on the manual blob row this
  /// record was parsed from, when the row carries one. Stored ids
  /// are not always the deterministic form (older / imported /
  /// server-written rows), and delete targets rows BY id — losing
  /// this made such rows undeletable. Null when the stored row had
  /// no id (or the record did not come from a stored row).
  final String? storedId;

  const BpUiRecord({required this.record, required this.source, this.storedId});

  /// The id that identifies this record in the manual blob for
  /// delete: the stored id when there is one, else the deterministic
  /// manual-record id native uses
  /// (`"manual_<epochMs>_<systolic>_<diastolic>"`).
  String get manualId => (storedId != null && storedId!.isNotEmpty)
      ? storedId!
      : 'manual_${record.timeEpochMs}_${record.systolic}_${record.diastolic}';
}

/// Merge manual + Health Connect readings for the Blood Pressure tool.
///
/// Ports round 13's snapshot merge spirit, minus the 7-day bucketing:
/// - A 0 or negative systolic/diastolic is a failed read (founder rule) and
///   is dropped, never charted or listed.
/// - Duplicates by [BpRecord.timeEpochMs] are collapsed; the Health Connect
///   copy wins because device data is the source of truth.
/// - Newest first.
/// - Never throws; empty in → empty out.
List<BpUiRecord> mergeBpRecords({
  required List<BpRecord> manual,
  required List<BpRecord> healthConnect,
}) {
  return mergeBpUiRecords(
    manual: [
      for (final r in manual) BpUiRecord(record: r, source: BpSource.manual),
    ],
    healthConnect: healthConnect,
  );
}

/// Same merge as [mergeBpRecords], for manual records that already
/// carry their stored-row identity ([BpUiRecord.storedId] rides
/// through untouched, so delete can target the real stored id).
/// Display/dedupe semantics are identical: duplicates by
/// [BpRecord.timeEpochMs] collapse and the Health Connect copy wins.
List<BpUiRecord> mergeBpUiRecords({
  required List<BpUiRecord> manual,
  required List<BpRecord> healthConnect,
}) {
  final byTime = <int, BpUiRecord>{};
  for (final r in healthConnect) {
    if (r.systolic <= 0 || r.diastolic <= 0 || r.timeEpochMs <= 0) continue;
    byTime[r.timeEpochMs] = BpUiRecord(record: r, source: BpSource.healthConnect);
  }
  for (final u in manual) {
    final r = u.record;
    if (r.systolic <= 0 || r.diastolic <= 0 || r.timeEpochMs <= 0) continue;
    byTime.putIfAbsent(r.timeEpochMs, () => u);
  }
  final out = byTime.values.toList()
    ..sort((a, b) => b.record.timeEpochMs.compareTo(a.record.timeEpochMs));
  return out;
}

/// "Oct 11, 2026 · 6:16 PM" — small local formatter (no intl dep allowed).
String formatBpDateTime(int timeEpochMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(timeEpochMs);
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  final hour12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final minute = d.minute.toString().padLeft(2, '0');
  final ampm = d.hour < 12 ? 'AM' : 'PM';
  return '${months[d.month - 1]} ${d.day}, ${d.year} · $hour12:$minute $ampm';
}

/// Native history-row format: "EEE, MMM d, yyyy · h:mm a".
String formatBpHistoryDateTime(int timeEpochMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(timeEpochMs);
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return '${weekdays[d.weekday - 1]}, ${formatBpDateTime(timeEpochMs)}';
}

// ── Manual BP blob (profile.manualBloodPressureLogs) ─────────────────
//
// Native storage (BloodPressureRepository + SyncManager): manual
// readings are a JSON array in the profile field
// `manualBloodPressureLogs`, each row the serialized
// `BloodPressureUiRecord` `{systolic, diastolic, timeEpochMs, id,
// source}` with the deterministic id
// `manual_<epochMs>_<systolic>_<diastolic>` and source `MANUAL`.
// The whole blob rides `POST /api/sync/profile`.

/// Decodes the raw `manualBloodPressureLogs` profile value into its
/// raw JSON rows, preserving every row exactly as stored so a later
/// full-blob push never drops data. Tolerates a JSON string
/// (including double-encoded), an already-decoded list, and garbage
/// (→ empty). Never throws.
List<dynamic> decodeBpLogsRaw(dynamic raw) {
  dynamic decoded = raw;
  var guard = 0;
  while (decoded is String && decoded.trim().isNotEmpty && guard < 3) {
    guard++;
    try {
      decoded = jsonDecode(decoded);
    } catch (_) {
      return const [];
    }
  }
  if (decoded is List) return List<dynamic>.of(decoded);
  return const [];
}

int? _bpAsInt(dynamic v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? double.tryParse(v.trim())?.toInt();
  return null;
}

int? _bpTimeMs(dynamic v) {
  final asInt = _bpAsInt(v);
  if (asInt != null) return asInt;
  if (v is String) return DateTime.tryParse(v.trim())?.millisecondsSinceEpoch;
  return null;
}

/// Tolerant values of one raw manual-BP row. Null when the row does
/// not carry a complete reading.
({int systolic, int diastolic, int timeEpochMs})? bpRowValues(dynamic row) {
  if (row is! Map) return null;
  final sys = _bpAsInt(row['systolic']);
  final dia = _bpAsInt(row['diastolic']);
  final t = _bpTimeMs(row['timeEpochMs'] ?? row['t']);
  if (sys == null || dia == null || t == null) return null;
  return (systolic: sys, diastolic: dia, timeEpochMs: t);
}

/// Native's deterministic manual-record id.
String bpManualId(int timeEpochMs, int systolic, int diastolic) =>
    'manual_${timeEpochMs}_${systolic}_$diastolic';

/// The id of a raw row: its stored `id` when present, else the
/// deterministic id computed from its values (native computes the
/// same way). Null when the row has neither.
String? bpRowId(dynamic row) {
  if (row is Map) {
    final id = row['id'];
    if (id is String && id.isNotEmpty) return id;
  }
  final v = bpRowValues(row);
  if (v == null) return null;
  return bpManualId(v.timeEpochMs, v.systolic, v.diastolic);
}

/// Displayable manual records parsed from raw rows (fail-soft per
/// row, like native's decode).
List<BpRecord> bpRecordsFromRaw(List<dynamic> rows) =>
    [for (final u in bpUiRecordsFromRaw(rows)) u.record];

/// Vera F8 (fix round): like [bpRecordsFromRaw], but each record
/// keeps the id stored on its row ([BpUiRecord.storedId]) so delete
/// can target the row that actually exists. A row with no stored id
/// (or a blank one) yields a null storedId, and [BpUiRecord.manualId]
/// falls back to the deterministic id — the id [bpRowId] computes
/// for such a row as well.
List<BpUiRecord> bpUiRecordsFromRaw(List<dynamic> rows) {
  final out = <BpUiRecord>[];
  for (final row in rows) {
    final v = bpRowValues(row);
    if (v == null) continue;
    String? storedId;
    if (row is Map) {
      final id = row['id'];
      if (id is String && id.isNotEmpty) storedId = id;
    }
    out.add(BpUiRecord(
      record: BpRecord(
          systolic: v.systolic,
          diastolic: v.diastolic,
          timeEpochMs: v.timeEpochMs),
      source: BpSource.manual,
      storedId: storedId,
    ));
  }
  return out;
}

Map<String, dynamic> _bpRowMap(int systolic, int diastolic, int timeEpochMs) =>
    <String, dynamic>{
      'systolic': systolic,
      'diastolic': diastolic,
      'timeEpochMs': timeEpochMs,
      'id': bpManualId(timeEpochMs, systolic, diastolic),
      'source': 'MANUAL',
    };

/// Splice: prepend a manual reading (native `addManualRecord`
/// inserts at the front). Refused when the exact record already
/// exists — native dedupes by the deterministic id — returning the
/// rows unchanged in that case is WRONG for honesty, so this
/// returns null and the caller reports the duplicate.
List<dynamic>? bpLogsWithAdded(
    List<dynamic> rows, int systolic, int diastolic, int timeEpochMs) {
  if (systolic <= 0 || diastolic <= 0) return null;
  final id = bpManualId(timeEpochMs, systolic, diastolic);
  if (rows.any((r) => bpRowId(r) == id)) return null;
  return [_bpRowMap(systolic, diastolic, timeEpochMs), ...rows];
}

/// Splice: remove every row carrying [id] (native `deleteManualRecord`
/// removes by id). Null when no row matches.
List<dynamic>? bpLogsWithoutId(List<dynamic> rows, String id) {
  if (!rows.any((r) => bpRowId(r) == id)) return null;
  return rows.where((r) => bpRowId(r) != id).toList();
}

/// Splice: batch-add imported readings (native `addManualRecords`):
/// readings whose deterministic id already exists are skipped, the
/// merged blob is sorted newest first. Returns the merged rows and
/// how many readings were actually added.
({List<dynamic> rows, int added}) bpLogsWithImported(
    List<dynamic> rows, List<BpCsvReading> readings) {
  final existingIds = <String>{
    for (final r in rows)
      if (bpRowId(r) != null) bpRowId(r)!,
  };
  final additions = <Map<String, dynamic>>[];
  for (final r in readings) {
    final id = bpManualId(r.timeEpochMs, r.systolic, r.diastolic);
    if (existingIds.contains(id)) continue;
    existingIds.add(id);
    additions.add(_bpRowMap(r.systolic, r.diastolic, r.timeEpochMs));
  }
  final merged = <dynamic>[...rows, ...additions];
  // Newest first (native sorts the merged manual list descending);
  // rows without parseable values keep their relative place at the
  // end via a stable index tie-break.
  final indexed = <(int, dynamic)>[
    for (var i = 0; i < merged.length; i++) (i, merged[i]),
  ];
  indexed.sort((a, b) {
    final ta = bpRowValues(a.$2)?.timeEpochMs ?? -1;
    final tb = bpRowValues(b.$2)?.timeEpochMs ?? -1;
    final byTime = tb.compareTo(ta);
    return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
  });
  return (
    rows: [for (final e in indexed) e.$2],
    added: additions.length,
  );
}

// ── CSV import (port of native BloodPressureCsvParser) ───────────────

/// User-facing parser messages, verbatim from native.
const String bpCsvMsgNoHeaders =
    "Couldn't find blood pressure columns in this file. Make sure the first row has headers like Systolic, Diastolic, and Date.";
const String bpCsvMsgNoValidRows =
    'No valid blood pressure readings found in this file.';
const String bpCsvMsgNoDateFormat =
    "Couldn't understand the date format in this file. Dates should look like 2026-09-20, 9/20/2026, or 20.09.2026.";
const String bpCsvMsgTooManyRows =
    'This file has more than 10,000 readings. The limit is 10,000.';

const int bpCsvMaxDataRows = 10000;
const int bpCsvMaxSystolic = 400;
const int bpCsvMaxDiastolic = 300;

/// Header aliases keyed by logical column, compared against the
/// NORMALIZED header (native `HEADER_ALIASES`, verbatim).
const Map<String, Set<String>> bpCsvHeaderAliases = {
  'systolic': {
    'sys', 'systolic', 'systolic mmhg', 'sys mmhg', 'sys bp',
    'systolic bp', 'sbp', 'systolic pressure', 'upper', 'systole',
  },
  'diastolic': {
    'dia', 'diastolic', 'diastolic mmhg', 'dia mmhg', 'dia bp',
    'diastolic bp', 'dbp', 'diastolic pressure', 'lower', 'diastole',
  },
  'pulse': {
    'pulse', 'pulse bpm', 'pulse rate', 'heart rate',
    'heart rate bpm', 'hr', 'bpm',
  },
  'date': {
    'date', 'measurement date', 'date of measurement', 'reading date',
    'day', 'measurement day',
  },
  'time': {
    'time', 'measurement time', 'time of measurement', 'reading time',
  },
  'datetime': {
    'datetime', 'date time', 'date/time', 'measurement datetime',
    'timestamp', 'measured at', 'reading datetime', 'recorded at',
  },
};

/// One successfully parsed CSV reading (pulse is parsed nowhere and
/// stored nowhere, exactly like native).
class BpCsvReading {
  final int systolic;
  final int diastolic;
  final int timeEpochMs;

  const BpCsvReading({
    required this.systolic,
    required this.diastolic,
    required this.timeEpochMs,
  });
}

sealed class BpCsvParseResult {
  const BpCsvParseResult();
}

class BpCsvParseSuccess extends BpCsvParseResult {
  final List<BpCsvReading> readings;

  /// Rows skipped because values were impossible or unparseable.
  final int invalidRowCount;

  /// Duplicate (time, systolic, diastolic) rows within the file.
  final int duplicateRowCount;

  const BpCsvParseSuccess({
    required this.readings,
    required this.invalidRowCount,
    required this.duplicateRowCount,
  });
}

class BpCsvParseFailure extends BpCsvParseResult {
  final String message;
  const BpCsvParseFailure(this.message);
}

/// The import preview: parsed readings split against the existing
/// manual log (native `BloodPressureViewModel.previewCsvImport`).
class BpCsvPreview {
  final List<BpCsvReading> newReadings;
  final int duplicateCount;
  final int invalidCount;

  const BpCsvPreview({
    required this.newReadings,
    required this.duplicateCount,
    required this.invalidCount,
  });
}

/// Builds the preview: a parsed reading whose (time, systolic,
/// diastolic) already exists in the manual log counts as a
/// duplicate and is not imported again.
BpCsvPreview buildBpCsvPreview(
    BpCsvParseSuccess parsed, List<dynamic> existingRows) {
  final existingKeys = <(int, int, int)>{};
  for (final row in existingRows) {
    final v = bpRowValues(row);
    if (v != null) {
      existingKeys.add((v.timeEpochMs, v.systolic, v.diastolic));
    }
  }
  var duplicates = parsed.duplicateRowCount;
  final fresh = <BpCsvReading>[];
  for (final r in parsed.readings) {
    if (existingKeys.contains((r.timeEpochMs, r.systolic, r.diastolic))) {
      duplicates++;
    } else {
      fresh.add(r);
    }
  }
  return BpCsvPreview(
    newReadings: fresh,
    duplicateCount: duplicates,
    invalidCount: parsed.invalidRowCount,
  );
}

String _bpCsvPlural(int count, String singular) =>
    '$count $singular${count == 1 ? '' : 's'}';

/// Native's import-result message.
String bpCsvResultMessage(BpCsvPreview preview) {
  final imported = preview.newReadings.length;
  final skipped = preview.duplicateCount + preview.invalidCount;
  return '${_bpCsvPlural(imported, 'reading')} imported, '
      '${_bpCsvPlural(skipped, 'row')} skipped '
      '(${_bpCsvPlural(preview.duplicateCount, 'duplicate')}, '
      '${_bpCsvPlural(preview.invalidCount, 'invalid')})';
}

String _normalizeBpCsvHeader(String header) => header
    .toLowerCase()
    .replaceAll(RegExp(r'\(.*?\)'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Splits one CSV line on [delimiter], honoring double-quoted
/// fields (native `splitCsvLine` port).
List<String> splitBpCsvLine(String line, String delimiter) {
  final out = <String>[];
  final sb = StringBuffer();
  var inQuotes = false;
  var i = 0;
  while (i < line.length) {
    final c = line[i];
    if (c == '"') {
      if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
        sb.write('"');
        i++;
      } else {
        inQuotes = !inQuotes;
      }
    } else if (c == delimiter && !inQuotes) {
      out.add(sb.toString());
      sb.clear();
    } else {
      sb.write(c);
    }
    i++;
  }
  out.add(sb.toString());
  return out;
}

int? _parseBpCsvIntCell(String raw) {
  var t = raw.trim();
  if (t.length >= 2 && t.startsWith('"') && t.endsWith('"')) {
    t = t.substring(1, t.length - 1).trim();
  }
  if (t.isEmpty) return null;
  return int.tryParse(t) ?? double.tryParse(t)?.round();
}

bool _bpCsvValuesPlausible(int sys, int dia) =>
    sys > 0 &&
    dia > 0 &&
    dia <= sys &&
    sys <= bpCsvMaxSystolic &&
    dia <= bpCsvMaxDiastolic;

int _daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

/// Non-lenient date construction (native parses non-leniently):
/// null when any component is out of range.
int? _bpDateTimeMs(int year, int month, int day,
    [int hour = 0, int minute = 0, int second = 0]) {
  if (month < 1 || month > 12) return null;
  if (day < 1 || day > _daysInMonth(year, month)) return null;
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  if (second < 0 || second > 59) return null;
  return DateTime(year, month, day, hour, minute, second)
      .millisecondsSinceEpoch;
}

int? _bpMatchDate(RegExp re, String value,
    int? Function(List<int> groups) build) {
  final m = re.firstMatch(value);
  if (m == null) return null;
  final groups = [for (var i = 1; i <= m.groupCount; i++) int.parse(m.group(i)!)];
  return build(groups);
}

/// Tries native `DATE_FORMATS` pattern [pattern] against [value]
/// (whole-string match only, like native). Patterns, in native
/// order: ISO-with-offset, ISO-like local shapes, US M/d/yyyy,
/// EU d.M.yyyy, EU dd/MM/yyyy.
int? tryBpCsvDate(String value, int pattern) {
  final v = value.trim();
  if (v.isEmpty) return null;
  switch (pattern) {
    case 0: // yyyy-MM-dd'T'HH:mm:ssXXX
      if (!v.contains('T')) return null;
      if (!(v.endsWith('Z') ||
          RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(v))) {
        return null;
      }
      return DateTime.tryParse(v)?.millisecondsSinceEpoch;
    case 1: // yyyy-MM-dd'T'HH:mm:ss
      return _bpMatchDate(
          RegExp(r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})$'), v,
          (g) => _bpDateTimeMs(g[0], g[1], g[2], g[3], g[4], g[5]));
    case 2: // yyyy-MM-dd'T'HH:mm
      return _bpMatchDate(
          RegExp(r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$'), v,
          (g) => _bpDateTimeMs(g[0], g[1], g[2], g[3], g[4]));
    case 3: // yyyy-MM-dd HH:mm:ss
      return _bpMatchDate(
          RegExp(r'^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$'), v,
          (g) => _bpDateTimeMs(g[0], g[1], g[2], g[3], g[4], g[5]));
    case 4: // yyyy-MM-dd HH:mm
      return _bpMatchDate(
          RegExp(r'^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})$'), v,
          (g) => _bpDateTimeMs(g[0], g[1], g[2], g[3], g[4]));
    case 5: // yyyy-MM-dd
      return _bpMatchDate(RegExp(r'^(\d{4})-(\d{2})-(\d{2})$'), v,
          (g) => _bpDateTimeMs(g[0], g[1], g[2]));
    case 6: // M/d/yyyy h:mm a (US)
      final m = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4}) (\d{1,2}):(\d{2}) ([AaPp][Mm])$')
          .firstMatch(v);
      if (m == null) return null;
      var hour = int.parse(m.group(4)!);
      final isPm = m.group(6)!.toUpperCase() == 'PM';
      if (hour < 1 || hour > 12) return null;
      if (isPm && hour != 12) hour += 12;
      if (!isPm && hour == 12) hour = 0;
      return _bpDateTimeMs(int.parse(m.group(3)!), int.parse(m.group(1)!),
          int.parse(m.group(2)!), hour, int.parse(m.group(5)!));
    case 7: // M/d/yyyy (US)
      return _bpMatchDate(RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$'), v,
          (g) => _bpDateTimeMs(g[2], g[0], g[1]));
    case 8: // d.M.yyyy HH:mm (EU)
      return _bpMatchDate(
          RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4}) (\d{2}):(\d{2})$'), v,
          (g) => _bpDateTimeMs(g[2], g[1], g[0], g[3], g[4]));
    case 9: // d.M.yyyy (EU)
      return _bpMatchDate(RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})$'), v,
          (g) => _bpDateTimeMs(g[2], g[1], g[0]));
    case 10: // dd/MM/yyyy HH:mm (EU)
      return _bpMatchDate(
          RegExp(r'^(\d{2})/(\d{2})/(\d{4}) (\d{2}):(\d{2})$'), v,
          (g) => _bpDateTimeMs(g[2], g[1], g[0], g[3], g[4]));
    case 11: // dd/MM/yyyy (EU)
      return _bpMatchDate(RegExp(r'^(\d{2})/(\d{2})/(\d{4})$'), v,
          (g) => _bpDateTimeMs(g[2], g[1], g[0]));
  }
  return null;
}

const int _bpCsvDateFormatCount = 12;

/// Parses BP CSV text exactly like native `BloodPressureCsvParser`:
/// header-alias detection (comma, semicolon fallback), date-format
/// detection from the first dated row, per-row plausibility,
/// in-file duplicate counting, and the native row caps. Never
/// throws; failures carry the native user-facing message.
BpCsvParseResult parseBpCsv(String csvText) {
  try {
    return _parseBpCsvInternal(
        csvText.startsWith('\uFEFF') ? csvText.substring(1) : csvText);
  } catch (_) {
    return const BpCsvParseFailure(bpCsvMsgNoValidRows);
  }
}

BpCsvParseResult _parseBpCsvInternal(String csvText) {
  final lines = csvText
      .split('\n')
      .map((l) => l.endsWith('\r') ? l.substring(0, l.length - 1) : l)
      .where((l) => l.trim().isNotEmpty)
      .toList();
  if (lines.isEmpty) return const BpCsvParseFailure(bpCsvMsgNoValidRows);

  var delimiter = ',';
  var headerCells =
      splitBpCsvLine(lines[0], delimiter).map((c) => c.trim()).toList();
  if (headerCells.length <= 1) {
    final semi = splitBpCsvLine(lines[0], ';').map((c) => c.trim()).toList();
    if (semi.length > 1) {
      delimiter = ';';
      headerCells = semi;
    }
  }

  final colIndex = <String, int>{};
  for (var i = 0; i < headerCells.length; i++) {
    final normalized = _normalizeBpCsvHeader(headerCells[i]);
    for (final entry in bpCsvHeaderAliases.entries) {
      if (entry.value.contains(normalized) &&
          !colIndex.containsKey(entry.key)) {
        colIndex[entry.key] = i;
        break;
      }
    }
  }
  if (!colIndex.containsKey('systolic') ||
      !colIndex.containsKey('diastolic')) {
    return const BpCsvParseFailure(bpCsvMsgNoHeaders);
  }
  final sysIdx = colIndex['systolic']!;
  final diaIdx = colIndex['diastolic']!;
  final dateIdx = colIndex['date'];
  final timeIdx = colIndex['time'];
  final datetimeIdx = colIndex['datetime'];
  if (datetimeIdx == null && dateIdx == null) {
    return const BpCsvParseFailure(bpCsvMsgNoHeaders);
  }

  String dateValueOf(List<String> cells) {
    if (datetimeIdx != null) {
      return datetimeIdx < cells.length ? cells[datetimeIdx].trim() : '';
    }
    final d = dateIdx! < cells.length ? cells[dateIdx].trim() : '';
    final t = timeIdx != null && timeIdx < cells.length
        ? cells[timeIdx].trim()
        : '';
    return d.isNotEmpty && t.isNotEmpty ? '$d $t' : d;
  }

  String? firstDateValue;
  final probeRows = lines.skip(1).take(bpCsvMaxDataRows + 1);
  for (final line in probeRows) {
    final v = dateValueOf(splitBpCsvLine(line, delimiter));
    if (v.isNotEmpty) {
      firstDateValue = v;
      break;
    }
  }
  if (firstDateValue == null) {
    return const BpCsvParseFailure(bpCsvMsgNoValidRows);
  }

  int? datePattern;
  for (var p = 0; p < _bpCsvDateFormatCount; p++) {
    if (tryBpCsvDate(firstDateValue, p) != null) {
      datePattern = p;
      break;
    }
  }
  if (datePattern == null) {
    return const BpCsvParseFailure(bpCsvMsgNoDateFormat);
  }

  final readings = <BpCsvReading>[];
  final seenInFile = <(int, int, int)>{};
  var invalid = 0;
  var duplicates = 0;
  var dataRowCount = 0;

  for (final rawLine in lines.skip(1)) {
    dataRowCount++;
    if (dataRowCount > bpCsvMaxDataRows) {
      return const BpCsvParseFailure(bpCsvMsgTooManyRows);
    }
    final cells = splitBpCsvLine(rawLine, delimiter);
    final sys =
        _parseBpCsvIntCell(sysIdx < cells.length ? cells[sysIdx] : '');
    final dia =
        _parseBpCsvIntCell(diaIdx < cells.length ? cells[diaIdx] : '');
    final epochMs = tryBpCsvDate(dateValueOf(cells), datePattern);

    if (sys == null ||
        dia == null ||
        epochMs == null ||
        !_bpCsvValuesPlausible(sys, dia)) {
      invalid++;
      continue;
    }
    final key = (epochMs, sys, dia);
    if (!seenInFile.add(key)) {
      duplicates++;
      continue;
    }
    readings.add(
        BpCsvReading(systolic: sys, diastolic: dia, timeEpochMs: epochMs));
  }

  if (readings.isEmpty && duplicates == 0) {
    return const BpCsvParseFailure(bpCsvMsgNoValidRows);
  }
  return BpCsvParseSuccess(
    readings: readings,
    invalidRowCount: invalid,
    duplicateRowCount: duplicates,
  );
}

/// Round 48 — Blood Pressure tool screen, FULL port of native
/// `BloodPressureScreen.kt` + `BloodPressureViewModel.kt`:
///
/// - Latest reading spotlight + merged history (manual blob +
///   Health Connect last 30 days), as before.
/// - Manual add (FAB / "Log Reading") with systolic + diastolic +
///   date & time picker and native validation, written to the
///   `manualBloodPressureLogs` profile blob via
///   `POST /api/sync/profile`.
/// - Manual delete (tap a manual row or its delete icon → native
///   confirm dialog). Health Connect rows are not deletable, like
///   native.
/// - CSV import: SAF file pick (host channel) → the ported native
///   parser → preview with counts/date range/first readings →
///   explicit confirm → one blob push → result dialog. Nothing is
///   imported silently.
/// - Round 48 fix: a failed profile pull is now an honest error
///   state — round 18's `fetchManualBpLogs` returned [] on failure,
///   so an outage rendered as "No blood pressure records found."
///
/// Writes re-pull the freshest blob and push it whole; a failed
/// push shows an error and reloads from the server.
class BloodPressureToolScreen extends StatefulWidget {
  final VoidCallback? onBack;
  final TabsBackend? backend;
  final HealthConnectService? healthConnect;
  final CsvFilePicker? csvFilePicker;

  const BloodPressureToolScreen({
    super.key,
    this.onBack,
    this.backend,
    this.healthConnect,
    this.csvFilePicker,
  });

  @override
  State<BloodPressureToolScreen> createState() =>
      _BloodPressureToolScreenState();
}

class _BloodPressureToolScreenState extends State<BloodPressureToolScreen> {
  TabsBackend get _backend => widget.backend ?? TabsBackend();
  HealthConnectService get _hc =>
      widget.healthConnect ?? HealthConnectService();
  CsvFilePicker get _csvPicker => widget.csvFilePicker ?? CsvFilePicker();

  bool _loading = true;
  bool _refreshing = false;
  bool _writing = false;
  List<BpUiRecord> _records = const [];
  List<dynamic> _manualRows = const [];
  List<BpRecord> _hcRecords = const [];
  String? _hcNotice;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool isRefresh = false}) async {
    if (mounted) {
      setState(() {
        if (isRefresh) {
          _refreshing = true;
        } else {
          _loading = true;
        }
        _error = null;
      });
    }
    try {
      final profile = await _backend.fetchProfile();
      List<BpRecord> hcRecords = const [];
      String? notice;
      bool connected = false;
      try {
        // Bounded (Vera F3, same defect class as the Heart wedge):
        // a never-returning HC call used to leave this screen on
        // its skeleton forever. The bound uses the shared
        // readTimeout; expiry throws into the catch below and fails
        // to the existing "query issue" notice.
        connected =
            await _hc.isConnected().timeout(HealthConnectService.readTimeout);
        if (connected) {
          hcRecords = await _hc
              .readBloodPressure(30)
              .timeout(HealthConnectService.readTimeout);
        } else {
          notice = 'Health Connect is not connected. Showing manual readings only.';
        }
      } catch (e) {
        // Channel failures surface as a visible notice; manual data still shows.
        notice = 'Health Connect query issue. Showing manual readings.';
      }
      if (!mounted) return;
      setState(() {
        _hcRecords = hcRecords;
        _hcNotice = notice;
        if (profile == null) {
          // Honest failure — never render an outage as "no data".
          _manualRows = const [];
          _records = mergeBpRecords(manual: const [], healthConnect: hcRecords);
          _error = 'Could not load your data. We could not pull your latest '
              'readings. Check your connection and try again.';
        } else {
          _manualRows =
              decodeBpLogsRaw(profile['manualBloodPressureLogs']);
          _records = mergeBpUiRecords(
              manual: bpUiRecordsFromRaw(_manualRows),
              healthConnect: hcRecords);
        }
        _loading = false;
        _refreshing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load your data. We could not pull your latest '
            'readings. Check your connection and try again.';
        _loading = false;
        _refreshing = false;
      });
    }
  }

  void _showSaveError([String? message]) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(message ??
            'Could not save that change. Check your connection and try again.')));
  }

  /// Identity-safe manual-blob write: re-pull the freshest blob,
  /// splice, push the WHOLE blob. Returns true only when the push
  /// landed; on failure the error is shown and state reloads.
  Future<bool> _mutateManual(
      List<dynamic>? Function(List<dynamic> freshRows) splice) async {
    if (_writing) return false;
    setState(() => _writing = true);
    try {
      _backend.invalidateSyncPull();
      final profile = await _backend.fetchProfile();
      if (profile == null) {
        _showSaveError();
        await _load(isRefresh: true);
        return false;
      }
      final fresh = decodeBpLogsRaw(profile['manualBloodPressureLogs']);
      final next = splice(fresh);
      if (next == null) {
        _showSaveError();
        if (mounted) {
          setState(() {
            _manualRows = fresh;
            _records = mergeBpUiRecords(
                manual: bpUiRecordsFromRaw(fresh),
                healthConnect: _hcRecords);
          });
        }
        return false;
      }
      final ok = await _backend.postSyncProfile(
          {'manualBloodPressureLogs': jsonEncode(next)});
      if (!mounted) return false;
      if (ok) {
        _backend.invalidateSyncPull();
        setState(() {
          _manualRows = next;
          _records = mergeBpUiRecords(
              manual: bpUiRecordsFromRaw(next), healthConnect: _hcRecords);
        });
        return true;
      }
      _showSaveError();
      await _load(isRefresh: true);
      return false;
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  Future<void> _showAddDialog() async {
    if (_writing) return;
    await showDialog<bool>(
      context: context,
      builder: (_) => _AddBpDialog(
        onSave: (sys, dia, timeMs) async {
          final ok = await _mutateManual(
              (fresh) => bpLogsWithAdded(fresh, sys, dia, timeMs));
          if (ok) return null;
          // Distinguish the duplicate case for an honest message.
          return 'Could not save this reading. It may already exist, '
              'or the connection failed. Check your connection and try again.';
        },
      ),
    );
  }

  Future<void> _confirmDelete(BpUiRecord item) async {
    if (_writing) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: NotelColors.surface,
        title: const Text('Delete Manual Reading?',
            style: TextStyle(color: NotelColors.textPrimary)),
        content: Text(
          'Are you sure you want to delete this reading '
          '(${item.record.systolic}/${item.record.diastolic} mmHg)? '
          'This action cannot be undone.',
          style: const TextStyle(color: NotelColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel',
                style: TextStyle(color: NotelColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete',
                style: TextStyle(
                    color: NotelColors.error, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _mutateManual((fresh) => bpLogsWithoutId(fresh, item.manualId));
  }

  // ── CSV import flow ──────────────────────────────────────────────

  Future<void> _startCsvImport() async {
    if (_writing) return;
    String? text;
    try {
      text = await _csvPicker.pickCsvText();
    } on CsvPickException catch (e) {
      _showCsvError(e.message ??
          "Couldn't read this file. Please try a different CSV.");
      return;
    } catch (_) {
      _showCsvError("Couldn't read this file. Please try a different CSV.");
      return;
    }
    if (text == null || !mounted) return; // user cancelled the picker
    final parsed = parseBpCsv(text);
    if (parsed is BpCsvParseFailure) {
      _showCsvError(parsed.message);
      return;
    }
    final success = parsed as BpCsvParseSuccess;
    // Preview is computed against the FRESHEST manual blob.
    _backend.invalidateSyncPull();
    final profile = await _backend.fetchProfile();
    if (!mounted) return;
    if (profile == null) {
      _showCsvError(
          'Could not load your current readings. Check your connection and try again.');
      return;
    }
    final freshRows = decodeBpLogsRaw(profile['manualBloodPressureLogs']);
    final preview = buildBpCsvPreview(success, freshRows);
    await showDialog<void>(
      context: context,
      builder: (_) => _CsvPreviewDialog(
        preview: preview,
        onImport: () => _mutateManual((fresh) {
          // Recompute against the freshest rows at push time so a
          // reading added since the preview is never duplicated.
          final freshPreview = buildBpCsvPreview(success, fresh);
          return bpLogsWithImported(fresh, freshPreview.newReadings).rows;
        }),
      ),
    );
  }

  void _showCsvError(String message) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: NotelColors.surface,
        title: const Text("Couldn't Import CSV",
            style: TextStyle(
                color: NotelColors.textPrimary,
                fontWeight: FontWeight.bold)),
        content: Text(message,
            style: const TextStyle(
                color: NotelColors.textSecondary, fontSize: 14)),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            style: FilledButton.styleFrom(
                backgroundColor: NotelColors.primary),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final latest = _records.isEmpty ? null : _records.first;
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back,
              color: NotelColors.textSecondary, semanticLabel: 'Back'),
          onPressed: widget.onBack ?? () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Blood Pressure',
          style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh,
                color: NotelColors.textSecondary, semanticLabel: 'Refresh'),
            onPressed: _refreshing ? null : () => _load(isRefresh: true),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _writing ? null : _showAddDialog,
        backgroundColor: NotelColors.primary,
        foregroundColor: Colors.white,
        child: const Icon(Icons.add, semanticLabel: 'Log Blood Pressure'),
      ),
      body: _loading
          ? const SkeletonGroup(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 110),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonBox(height: 190, radius: 20),
                    SizedBox(height: 16),
                    SkeletonBox(height: 72, radius: 16),
                    SizedBox(height: 16),
                    SkeletonBox(height: 72, radius: 16),
                  ],
                ),
              ),
            )
          : RefreshIndicator(
              color: NotelColors.primary,
              onRefresh: () => _load(isRefresh: true),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
                children: [
                  if (_hcNotice != null) _noticeBanner(_hcNotice!),
                  _latestCard(latest),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'History',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: NotelColors.textPrimary),
                      ),
                      TextButton.icon(
                        onPressed: _writing ? null : _startCsvImport,
                        icon: const Icon(Icons.upload_file,
                            size: 16, color: NotelColors.primary),
                        label: const Text('Import CSV',
                            style: TextStyle(
                                color: NotelColors.primary,
                                fontSize: 13,
                                fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_error != null)
                    _errorBanner(_error!)
                  else if (_records.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: Text(
                        'No blood pressure records found.\nTap + below to add your first reading.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 14, color: NotelColors.textSecondary),
                      ),
                    )
                  else
                    ..._records.map(_historyRow),
                ],
              ),
            ),
    );
  }

  Widget _noticeBanner(String text) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: NotelColors.surfaceHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber,
              size: 18, color: NotelColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    fontSize: 12, color: NotelColors.textSecondary)),
          ),
        ],
      ),
    );
  }

  Widget _errorBanner(String text) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: NotelColors.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NotelColors.error.withValues(alpha: 0.4)),
      ),
      child: Text(text,
          style:
              const TextStyle(fontSize: 13, color: NotelColors.textPrimary)),
    );
  }

  Widget _latestCard(BpUiRecord? latest) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: NotelColors.cardBorder),
      ),
      child: Column(
        children: [
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.favorite, size: 20, color: NotelColors.primary),
              SizedBox(width: 8),
              Text('Latest Reading',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: NotelColors.textPrimary)),
            ],
          ),
          const SizedBox(height: 12),
          if (latest == null) ...[
            const Text('-- / --',
                style: TextStyle(
                    fontSize: 42,
                    fontWeight: FontWeight.w900,
                    color: NotelColors.textSecondary)),
            const SizedBox(height: 4),
            const Text('No readings logged yet',
                style: TextStyle(
                    fontSize: 13, color: NotelColors.textSecondary)),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _writing ? null : _showAddDialog,
              style: FilledButton.styleFrom(
                  backgroundColor: NotelColors.primary),
              child: const Text('Log Reading'),
            ),
          ] else ...[
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                    '${latest.record.systolic} / ${latest.record.diastolic}',
                    style: const TextStyle(
                        fontSize: 42,
                        fontWeight: FontWeight.w900,
                        color: NotelColors.textPrimary)),
                const SizedBox(width: 6),
                const Padding(
                  padding: EdgeInsets.only(bottom: 4),
                  child: Text('mmHg',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: NotelColors.textSecondary)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(formatBpDateTime(latest.record.timeEpochMs),
                    style: TextStyle(
                        fontSize: 12,
                        color:
                            NotelColors.textSecondary)),
                const SizedBox(width: 6),
                _sourceChip(latest.source),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _historyRow(BpUiRecord item) {
    final isManual = item.source == BpSource.manual;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NotelColors.cardBorder),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        // Native: tapping a manual row opens the delete confirm;
        // Health Connect rows are not tappable.
        onTap: isManual && !_writing ? () => _confirmDelete(item) : null,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      text:
                          '${item.record.systolic} / ${item.record.diastolic}',
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: NotelColors.textPrimary),
                      children: const [
                        TextSpan(
                            text: ' mmHg',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: NotelColors.textSecondary)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    formatBpHistoryDateTime(item.record.timeEpochMs),
                    style: const TextStyle(
                        fontSize: 12, color: NotelColors.textSecondary),
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _sourceChip(item.source),
                  if (isManual) ...[
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.delete,
                          size: 18,
                          color: NotelColors.textSecondary,
                          semanticLabel: 'Delete record'),
                      constraints: const BoxConstraints(
                          minWidth: 24, minHeight: 24),
                      padding: EdgeInsets.zero,
                      onPressed:
                          _writing ? null : () => _confirmDelete(item),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sourceChip(BpSource source) {
    final isHc = source == BpSource.healthConnect;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isHc
            ? const Color(0xFF1E3A8A)
            : const Color(0xFF064E3B), // native chip fills, verbatim
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        isHc ? 'Health Connect' : 'Manual',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: isHc
              ? const Color(0xFF93C5FD)
              : const Color(0xFF6EE7B7), // native chip text, verbatim
        ),
      ),
    );
  }
}

/// Native "Log Blood Pressure" dialog: systolic + diastolic +
/// tappable date & time row, native validation, save spinner.
class _AddBpDialog extends StatefulWidget {
  /// Returns null on success (dialog pops true), or an error
  /// message to show inside the dialog.
  final Future<String?> Function(int systolic, int diastolic, int timeMs)
      onSave;

  const _AddBpDialog({required this.onSave});

  @override
  State<_AddBpDialog> createState() => _AddBpDialogState();
}

class _AddBpDialogState extends State<_AddBpDialog> {
  final TextEditingController _sysController = TextEditingController();
  final TextEditingController _diaController = TextEditingController();
  int _timeMs = DateTime.now().millisecondsSinceEpoch;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _sysController.dispose();
    _diaController.dispose();
    super.dispose();
  }

  Future<void> _pickDateTime() async {
    final current = DateTime.fromMillisecondsSinceEpoch(_timeMs);
    final date = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (time == null || !mounted) return;
    setState(() {
      _timeMs = DateTime(date.year, date.month, date.day, time.hour,
              time.minute)
          .millisecondsSinceEpoch;
    });
  }

  Future<void> _save() async {
    final sys = int.tryParse(_sysController.text.trim());
    final dia = int.tryParse(_diaController.text.trim());
    if (sys == null || sys <= 0 || dia == null || dia <= 0) {
      setState(() =>
          _error = 'Please enter valid systolic and diastolic values');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await widget.onSave(sys, dia, _timeMs);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: NotelColors.surface,
      title: const Text('Log Blood Pressure',
          style: TextStyle(
              color: NotelColors.textPrimary, fontWeight: FontWeight.bold)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_error != null) ...[
            Text(_error!,
                style: const TextStyle(
                    color: NotelColors.error,
                    fontSize: 12,
                    fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
          ],
          TextField(
            controller: _sysController,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: NotelColors.textPrimary),
            decoration: const InputDecoration(
              labelText: 'Systolic (top / high)',
              hintText: '120',
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _diaController,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: NotelColors.textPrimary),
            decoration: const InputDecoration(
              labelText: 'Diastolic (bottom / low)',
              hintText: '80',
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          const SizedBox(height: 16),
          InkWell(
            onTap: _saving ? null : _pickDateTime,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: NotelColors.surfaceHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Date & Time',
                          style: TextStyle(
                              fontSize: 11,
                              color: NotelColors.textSecondary)),
                      Text(formatBpHistoryDateTime(_timeMs),
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: NotelColors.textPrimary)),
                    ],
                  ),
                  const Text('Change',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: NotelColors.primary)),
                ],
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel',
              style: TextStyle(color: NotelColors.textSecondary)),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          style:
              FilledButton.styleFrom(backgroundColor: NotelColors.primary),
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}

/// Native CSV import preview → importing → result dialog. The
/// import never starts without the user's explicit tap.
class _CsvPreviewDialog extends StatefulWidget {
  final BpCsvPreview preview;
  final Future<bool> Function() onImport;

  const _CsvPreviewDialog({required this.preview, required this.onImport});

  @override
  State<_CsvPreviewDialog> createState() => _CsvPreviewDialogState();
}

class _CsvPreviewDialogState extends State<_CsvPreviewDialog> {
  bool _importing = false;
  bool _done = false;

  String? get _rangeText {
    final times =
        widget.preview.newReadings.map((r) => r.timeEpochMs).toList();
    if (times.isEmpty) return null;
    times.sort();
    String fmt(int ms) {
      final d = DateTime.fromMillisecondsSinceEpoch(ms);
      const months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ];
      return '${months[d.month - 1]} ${d.day}, ${d.year}';
    }

    return '${fmt(times.first)} to ${fmt(times.last)}';
  }

  Future<void> _import() async {
    setState(() => _importing = true);
    final ok = await widget.onImport();
    if (!mounted) return;
    if (ok) {
      setState(() {
        _importing = false;
        _done = true;
      });
    } else {
      // The screen already surfaced the save error; close so the
      // user sees the reloaded list behind it.
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_importing) {
      return const AlertDialog(
        backgroundColor: NotelColors.surface,
        title: Text('Importing…',
            style: TextStyle(
                color: NotelColors.textPrimary,
                fontWeight: FontWeight.bold)),
        content: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                  color: NotelColors.primary, strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('Saving readings to your log…',
                style: TextStyle(
                    color: NotelColors.textSecondary, fontSize: 13)),
          ],
        ),
      );
    }
    if (_done) {
      return AlertDialog(
        backgroundColor: NotelColors.surface,
        title: const Text('Import Complete',
            style: TextStyle(
                color: NotelColors.textPrimary,
                fontWeight: FontWeight.bold)),
        content: Text(bpCsvResultMessage(widget.preview),
            style: const TextStyle(
                color: NotelColors.textSecondary, fontSize: 14)),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            style: FilledButton.styleFrom(
                backgroundColor: NotelColors.primary),
            child: const Text('Done'),
          ),
        ],
      );
    }
    final preview = widget.preview;
    final newCount = preview.newReadings.length;
    return AlertDialog(
      backgroundColor: NotelColors.surface,
      title: const Text('Import Blood Pressure CSV',
          style: TextStyle(
              color: NotelColors.textPrimary, fontWeight: FontWeight.bold)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              newCount == 1
                  ? '1 reading ready to import'
                  : '$newCount readings ready to import',
              style: const TextStyle(
                  color: NotelColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600),
            ),
            if (_rangeText != null) ...[
              const SizedBox(height: 8),
              Text('Date range: $_rangeText',
                  style: const TextStyle(
                      color: NotelColors.textSecondary, fontSize: 13)),
            ],
            if (preview.duplicateCount > 0) ...[
              const SizedBox(height: 8),
              Text(
                '${preview.duplicateCount} '
                '${preview.duplicateCount == 1 ? 'duplicate' : 'duplicates'} '
                'skipped (already in your log)',
                style: const TextStyle(
                    color: NotelColors.textSecondary, fontSize: 13),
              ),
            ],
            if (preview.invalidCount > 0) ...[
              const SizedBox(height: 8),
              Text(
                '${preview.invalidCount} invalid '
                '${preview.invalidCount == 1 ? 'row' : 'rows'} skipped',
                style: const TextStyle(
                    color: NotelColors.textSecondary, fontSize: 13),
              ),
            ],
            if (newCount > 0) ...[
              const SizedBox(height: 12),
              Text('First ${newCount < 5 ? newCount : 5} readings:',
                  style: const TextStyle(
                      color: NotelColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500)),
              const SizedBox(height: 4),
              for (final r in preview.newReadings.take(5))
                Text(
                  '${r.systolic}/${r.diastolic} mmHg, '
                  '${formatBpDateTime(r.timeEpochMs)}',
                  style: const TextStyle(
                      color: NotelColors.textPrimary, fontSize: 13),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel',
              style: TextStyle(color: NotelColors.textSecondary)),
        ),
        FilledButton(
          onPressed: _import,
          style:
              FilledButton.styleFrom(backgroundColor: NotelColors.primary),
          child: const Text('Import'),
        ),
      ],
    );
  }
}
