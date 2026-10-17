import 'package:tabs_lab/src/data/health_history_store.dart';

/// R70 WS3 — Tabs metrics CSV import into the [HealthHistoryStore].
///
/// Parses the metrics CSV exactly as the native exporter writes it:
///
///   Date,Average HR (BPM),Sleep Duration,Deep Sleep,Spikes (count)
///
/// - dates are `YYYY-MM-DD`
/// - durations use the spaced exporter format (`7h 6m`); the compact
///   `7h6m` and bare-minutes `45m` forms are also accepted
/// - `No data` / empty cells are ABSENT (never imported)
/// - the exporter pads columns generously with whitespace — trimmed
/// - malformed rows are skipped and counted, never fatal
/// - a file with the wrong header is rejected with a clear message
///   (message style follows the BP importer's constants pattern)
///
/// Imports merge through `mergeFillGaps`: existing stored values
/// always win, and the founder zero rule applies on the way in, so
/// a CSV "0" cell is a failed read and fills nothing.
///
/// `Average HR (BPM)` maps to [DailyBiometrics.restingHrBpm]: that
/// exporter column is sourced from resting-HR records (the same
/// per-day series `readRestingHrHistory` produces).

/// User-facing parser messages (BP importer style).
const String metricsCsvMsgWrongHeader =
    "Couldn't find the Tabs metrics columns in this file. Make sure the first row has headers like Date, Average HR (BPM), Sleep Duration, Deep Sleep, and Spikes (count).";
const String metricsCsvMsgNoValidRows =
    'No valid health history rows found in this file.';

/// One format implementation in the import registry: detection is
/// header-based, parsing yields history rows plus skip accounting.
abstract class MetricsImportFormat {
  const MetricsImportFormat();

  /// True when [headerCells] (raw, untrimmed) look like this format.
  bool canParse(List<String> headerCells);

  /// Parses the full CSV text. Only called when [canParse] matched.
  MetricsCsvParseResult parse(String csvText);
}

/// The registry of known metrics-import formats, in detection order.
///
/// ── FUTURE FORMAT PLUG-IN POINT ──────────────────────────────────
/// A future Fitbit archive parser (Takeout / Fitbit export CSVs)
/// plugs in HERE: implement [MetricsImportFormat] for the Fitbit
/// header shape and add it to this list. Detection, the Settings
/// flow, and the fill-gaps merge need no changes. (Deliberately NOT
/// built in R70.)
const List<MetricsImportFormat> metricsImportFormats = [
  TabsMetricsImportFormat(),
];

sealed class MetricsCsvParseResult {
  const MetricsCsvParseResult();
}

class MetricsCsvParseSuccess extends MetricsCsvParseResult {
  final List<DailyBiometrics> rows;

  /// Data rows read (excluding the header), valid + skipped.
  final int rowsRead;

  /// Rows skipped as malformed (bad date, unparseable cell, wrong
  /// column count). Rows whose cells are all "No data"/empty parse
  /// to an all-null row: they count as read, not skipped, and the
  /// merge ignores them.
  final int rowsSkipped;

  const MetricsCsvParseSuccess({
    required this.rows,
    required this.rowsRead,
    required this.rowsSkipped,
  });
}

class MetricsCsvParseFailure extends MetricsCsvParseResult {
  final String message;
  const MetricsCsvParseFailure(this.message);
}

/// The Tabs exporter format: header
/// `Date,Average HR (BPM),Sleep Duration,Deep Sleep,Spikes (count)`.
class TabsMetricsImportFormat extends MetricsImportFormat {
  const TabsMetricsImportFormat();

  static const List<String> expectedHeader = [
    'Date',
    'Average HR (BPM)',
    'Sleep Duration',
    'Deep Sleep',
    'Spikes (count)',
  ];

  @override
  bool canParse(List<String> headerCells) {
    if (headerCells.length != expectedHeader.length) return false;
    for (var i = 0; i < expectedHeader.length; i++) {
      if (headerCells[i].trim() != expectedHeader[i]) return false;
    }
    return true;
  }

  @override
  MetricsCsvParseResult parse(String csvText) => _parseTabsMetricsCsv(csvText);
}

/// Detects the format from the header row and parses. A file whose
/// header matches no known format is rejected with
/// [metricsCsvMsgWrongHeader].
MetricsCsvParseResult parseMetricsCsv(String csvText) {
  final text =
      csvText.startsWith('\uFEFF') ? csvText.substring(1) : csvText;
  final lines = text.split('\n');
  if (lines.isEmpty) {
    return const MetricsCsvParseFailure(metricsCsvMsgWrongHeader);
  }
  final headerCells = lines.first.split(',');
  for (final format in metricsImportFormats) {
    if (format.canParse(headerCells)) return format.parse(text);
  }
  return const MetricsCsvParseFailure(metricsCsvMsgWrongHeader);
}

MetricsCsvParseResult _parseTabsMetricsCsv(String csvText) {
  final lines = csvText
      .split('\n')
      .map((l) => l.endsWith('\r') ? l.substring(0, l.length - 1) : l)
      .where((l) => l.trim().isNotEmpty)
      .toList();
  if (lines.length <= 1) {
    return const MetricsCsvParseFailure(metricsCsvMsgNoValidRows);
  }
  final rows = <DailyBiometrics>[];
  var rowsRead = 0;
  var rowsSkipped = 0;
  for (final line in lines.skip(1)) {
    rowsRead++;
    final cells = line.split(',').map((c) => c.trim()).toList();
    if (cells.length != TabsMetricsImportFormat.expectedHeader.length) {
      rowsSkipped++;
      continue;
    }
    final date = cells[0];
    if (!_isValidDateStr(date)) {
      rowsSkipped++;
      continue;
    }
    // Each cell: absent ("No data"/empty) → null; malformed → the
    // whole row is skipped and counted.
    final hr = _parseIntCell(cells[1]);
    final sleep = _parseDurationCell(cells[2]);
    final deep = _parseDurationCell(cells[3]);
    final spikes = _parseIntCell(cells[4]);
    if (hr.malformed || sleep.malformed || deep.malformed || spikes.malformed) {
      rowsSkipped++;
      continue;
    }
    rows.add(DailyBiometrics(
      date: date,
      // The Average HR column is sourced from resting-HR records.
      restingHrBpm: hr.value,
      sleepMinutes: sleep.value,
      deepSleepMinutes: deep.value,
      spikeCount: spikes.value,
    ));
  }
  if (rows.isEmpty) {
    return const MetricsCsvParseFailure(metricsCsvMsgNoValidRows);
  }
  return MetricsCsvParseSuccess(
      rows: rows, rowsRead: rowsRead, rowsSkipped: rowsSkipped);
}

bool _isValidDateStr(String s) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(s);
  if (m == null) return false;
  final y = int.parse(m.group(1)!);
  final mo = int.parse(m.group(2)!);
  final d = int.parse(m.group(3)!);
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return false;
  final dt = DateTime(y, mo, d);
  return dt.year == y && dt.month == mo && dt.day == d;
}

typedef _Cell = ({int? value, bool malformed});

_Cell _parseIntCell(String raw) {
  final t = raw.trim();
  if (t.isEmpty || t == 'No data') return (value: null, malformed: false);
  final v = int.tryParse(t);
  if (v == null) return (value: null, malformed: true);
  return (value: v, malformed: false);
}

/// Duration cells: spaced exporter format `7h 6m`, compact `7h6m`,
/// `2h`, or bare minutes `45m`. `No data`/empty → absent.
_Cell _parseDurationCell(String raw) {
  final t = raw.trim();
  if (t.isEmpty || t == 'No data') return (value: null, malformed: false);
  final m = RegExp(r'^(?:(\d+)\s*h)?\s*(?:(\d+)\s*m)?$').firstMatch(t);
  if (m == null || (m.group(1) == null && m.group(2) == null)) {
    return (value: null, malformed: true);
  }
  final hours = m.group(1) != null ? int.parse(m.group(1)!) : 0;
  final mins = m.group(2) != null ? int.parse(m.group(2)!) : 0;
  return (value: hours * 60 + mins, malformed: false);
}

/// The import report surfaced in the Settings result dialog.
class MetricsImportReport {
  final int rowsRead;
  final int daysAdded;
  final int cellsFilled;
  final int rowsSkipped;

  const MetricsImportReport({
    required this.rowsRead,
    required this.daysAdded,
    required this.cellsFilled,
    required this.rowsSkipped,
  });

  /// BP-importer-style one-line summary.
  String get summary => '$rowsRead rows read, $daysAdded new days added, '
      '$cellsFilled values filled, $rowsSkipped rows skipped';
}

sealed class MetricsImportOutcome {
  const MetricsImportOutcome();
}

class MetricsImportOk extends MetricsImportOutcome {
  final MetricsImportReport report;
  const MetricsImportOk(this.report);
}

class MetricsImportError extends MetricsImportOutcome {
  final String message;
  const MetricsImportError(this.message);
}

/// Parses [csvText] and merges it into [store] via `mergeFillGaps`.
/// Never throws; failures carry a user-facing message.
Future<MetricsImportOutcome> importMetricsCsv({
  required String csvText,
  HealthHistoryStore? store,
}) async {
  final parsed = parseMetricsCsv(csvText);
  if (parsed is MetricsCsvParseFailure) {
    return MetricsImportError(parsed.message);
  }
  final success = parsed as MetricsCsvParseSuccess;
  final target = store ?? HealthHistoryStore.instance;
  final merged = await target.mergeFillGaps(success.rows);
  return MetricsImportOk(MetricsImportReport(
    rowsRead: success.rowsRead,
    daysAdded: merged.daysAdded,
    cellsFilled: merged.cellsFilled,
    rowsSkipped: success.rowsSkipped,
  ));
}
