/// Weekly Report v2 — the in-app mirror of the server report
/// (SPEC.md §5.6, package build-weekly-report-v2).
///
/// The app renders the page-1 snapshot sections (Verdict,
/// Scorecard, What changed, Notable days) plus Questions for Brad
/// and the Day by day grid from the SERVER's single
/// `computedMetrics` object (SPEC §1) carried in the
/// `/api/ai/report` response — it does NOT recompute any report
/// number on-device. Every printed number is the server builder's
/// `display` string, verbatim, so the app, the server PDF, and the
/// MCP report can never disagree (SPEC §1.2 / §1.4 invariant 2).
/// On-device aggregates in progress_report.dart no longer feed
/// report numbers for a v2 report; they remain for other features.
///
/// All reader-facing strings in this file are byte-exact per
/// JUNO-RULINGS-V2.md (16 rulings, FINAL, Nov 26, 2026) including
/// the P3 addendum (day-count normal cell form; BP single-reading
/// normal cell form) and the fix-round addendum (A.2 per-measure
/// verdict templates, A.4 tally agreement). The local fallback
/// builders for server-rendered strings are byte-aligned with
/// the server builder (reportV2.js) — Vera's Phase 2 app-review
/// fix round F-1–F-4: where a fallback cannot produce the ruled
/// form from the object's carried shape, the element is omitted
/// rather than manufactured. No improvised copy: where a ruled
/// template has slots, the slots are filled only from the
/// object's fields.
library;

// ── Ruled constants (Juno, byte-exact) ───────────────────────────

/// Ruling 16.1 section titles, in report order (page-1 mirror
/// renders the first four plus Questions and Day by day; Charts
/// and Appendix remain server-PDF surfaces in this package,
/// SPEC §5.6 — the PDF parity path renders their data lines).
const weeklyV2SectionTitles = <String>[
  'Verdict',
  'Scorecard',
  'What changed this week',
  'Notable days',
  'Questions for Brad',
  'Charts',
  'Day by day',
  'Appendix',
];

/// Ruling 1.4 disclaimer, verbatim, exactly once per report,
/// directly under the verdict block.
const weeklyV2Disclaimer =
    "This report is built from Tyson's self-tracked data in Tabs. "
    'It is not a diagnosis. A dash (—) means the value was not available.';

/// Ruling 15.2 default-window note, verbatim, directly under the
/// scorecard.
const weeklyV2NormalNote =
    'His normal is his trailing 30-day average before this week, '
    'unless a row says otherwise in its cell.';

/// Ruling 16.1 range-type label.
const weeklyV2RangeLabel = 'Weekly (7 Days)';

/// Ruling 2.1 scorecard column headers.
const weeklyV2ScorecardHeaders = <String>[
  'Metric',
  'This week',
  'Last week',
  'His normal',
  'Trend',
];

/// Ruling 13.2 + Ruling 10 grid legend, verbatim (two sentences in
/// one legend block).
const weeklyV2GridLegend =
    '— means nothing was logged for that day. '
    'n/a means the value is not in the source data for that day.\n'
    "Feeling is Tyson's Daily Summary check-in: a 1–5 rating of "
    'the day as a whole. It is not a rating of sleep.';

/// Ruling 6.3 no-changes cell, verbatim.
const weeklyV2NoChangesText = 'No medication changes this week.';

/// Ruling 8.1 questions framing line, verbatim.
const weeklyV2QuestionsForLine = 'For Brad Richards, PA-C.';

/// One scorecard row definition (Ruling 2.2): stable key, exact
/// label, exact better-when line, in ruled order.
class WeeklyScorecardRowDef {
  final String key;
  final String label;
  final String betterWhen;
  const WeeklyScorecardRowDef(this.key, this.label, this.betterWhen);
}

/// Ruling 2.2 rows 1–10, in order, none merged, none dropped.
const weeklyV2ScorecardRows = <WeeklyScorecardRowDef>[
  WeeklyScorecardRowDef('dailyScore', 'Daily Score (avg)', 'Better when: higher'),
  WeeklyScorecardRowDef('flareDays', 'Flare days', 'Better when: fewer'),
  WeeklyScorecardRowDef('headacheDays', 'Headache days', 'Better when: fewer'),
  WeeklyScorecardRowDef(
      'restingHr', 'Resting heart rate', 'Better when: lower'),
  WeeklyScorecardRowDef('hrv', 'HRV (RMSSD)', 'Better when: higher'),
  WeeklyScorecardRowDef(
      'sleepVsNeed', 'Sleep vs his need', 'Better when: higher (% of his need)'),
  WeeklyScorecardRowDef('minutesOver100', 'Minutes over 100 bpm (avg per day)',
      'Better when: lower'),
  WeeklyScorecardRowDef('minutesOver120', 'Minutes over 120 bpm (avg per day)',
      'Better when: lower'),
  WeeklyScorecardRowDef(
      'peakHr', 'Peak heart rate (weekly high)', 'Better when: lower'),
  WeeklyScorecardRowDef(
      'bloodPressure', 'Blood pressure', 'Better when: lower (both numbers)'),
];

/// Ruling 13.1 grid rows, in order: (object key, exact label).
const weeklyV2GridRows = <(String, String)>[
  ('score', 'Daily Score'),
  ('flare', 'Flare'),
  ('headache', 'Headache'),
  ('palpitations', 'Palpitations'),
  ('feeling', 'Feeling (daily check-in, 1–5)'),
  ('spikeCount', 'HR spikes (count)'),
  ('minutesOver100', 'Minutes over 100 bpm'),
  ('peakHr', 'Peak HR'),
  ('pt', 'PT'),
  ('coldExposure', 'Cold exposure'),
];

// ── P3 cell-form helpers (Juno P3 addendum, FINAL) ───────────────
//
// These format the two His-normal cell forms Ruling 15.3 did not
// enumerate. They are FORMAT helpers for the server builder's
// values; the renderer below always prefers the server's own
// `display` string when one is carried (SPEC §1.4 invariant 2).

/// P3(a), confirmed byte-exact: a day-count row's His-normal cell
/// is the per-week rate over the 30-day window, one decimal
/// always, `days` plural at every value (including 1.0). The
/// Trend computation uses the unrounded rate (server-side).
String formatDayCountNormalCell(double daysPerWeek) =>
    '${daysPerWeek.toStringAsFixed(1)} days (30-day avg, per week)';

/// P3(b), as CORRECTED by the addendum: a BP His-normal cell with
/// n ≥ 2 readings is the plain mean; with exactly n = 1 it must
/// carry the single-reading form — the plain form for n = 1 is
/// rejected (it would mislabel a single reading as an average).
/// This governs the His normal cell ONLY; this-week / last-week
/// BP cells print plainly. No readings → the dash (Ruling 2.4).
String formatBpNormalCell({
  required int? systolic,
  required int? diastolic,
  required int readingCount,
  String? singleReadingShortDate,
}) {
  if (systolic == null || diastolic == null || readingCount == 0) {
    return '—';
  }
  if (readingCount == 1 && singleReadingShortDate != null) {
    return '$systolic/$diastolic mmHg (single reading, $singleReadingShortDate)';
  }
  return '$systolic/$diastolic mmHg';
}

// ── The computedMetrics model (SPEC §1.3) ────────────────────────

Map<String, dynamic>? _asMap(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : null;

List<dynamic> _asList(Object? v) => v is List ? v : const [];

String _asString(Object? v) => v?.toString() ?? '';

/// One scorecard cell: the server's value + n + its `display`
/// string. Renderers print [display] verbatim and never re-round.
class ComputedCell {
  final Object? value;
  final int n;
  final String display;
  final String? statistic;
  final int? windowDays;

  /// The sleep row's percent-of-need, carried as a cell-level
  /// extra by the server builder (reportV2.js sleepCell); the
  /// verdict fallback's |Δ vs normal| for sleep is |pct − 100|
  /// (the server's verdictDelta rule).
  final double? pct;
  const ComputedCell(
      {this.value,
      this.n = 0,
      this.display = '—',
      this.statistic,
      this.windowDays,
      this.pct});

  factory ComputedCell.fromJson(Map<String, dynamic> j) => ComputedCell(
        value: j['value'],
        n: (j['n'] as num?)?.toInt() ?? 0,
        display: _asString(j['display']).isEmpty ? '—' : _asString(j['display']),
        statistic: j['statistic'] as String?,
        windowDays: (j['windowDays'] as num?)?.toInt(),
        pct: (j['pct'] as num?)?.toDouble(),
      );
}

/// One scorecard row (SPEC §1.3 row shape; reconciled against
/// Mason's landed server builder, reportV2.js: rows also carry a
/// server `label` and a `displayNormal` cell — the cell the His
/// normal column PRINTS, which for Daily Score is the 89-day
/// normalLong (decision D1) while `normal` keeps the 30-day value).
class ComputedScorecardRow {
  final String key;
  final String? serverLabel;
  final ComputedCell thisWeek;
  final ComputedCell lastWeek;
  final ComputedCell normal;
  final ComputedCell? displayNormalCell;
  final ComputedCell? normalLong;
  final String trend;
  const ComputedScorecardRow({
    required this.key,
    this.serverLabel,
    required this.thisWeek,
    required this.lastWeek,
    required this.normal,
    this.displayNormalCell,
    this.normalLong,
    required this.trend,
  });

  factory ComputedScorecardRow.fromJson(Map<String, dynamic> j) =>
      ComputedScorecardRow(
        key: _asString(j['key']),
        serverLabel: j['label'] as String?,
        thisWeek: ComputedCell.fromJson(_asMap(j['thisWeek']) ?? const {}),
        lastWeek: ComputedCell.fromJson(_asMap(j['lastWeek']) ?? const {}),
        normal: ComputedCell.fromJson(_asMap(j['normal']) ?? const {}),
        displayNormalCell: _asMap(j['displayNormal']) == null
            ? null
            : ComputedCell.fromJson(_asMap(j['displayNormal'])!),
        normalLong: _asMap(j['normalLong']) == null
            ? null
            : ComputedCell.fromJson(_asMap(j['normalLong'])!),
        trend: _asString(j['trend']),
      );

  WeeklyScorecardRowDef? get def {
    for (final d in weeklyV2ScorecardRows) {
      if (d.key == key) return d;
    }
    return null;
  }

  String get label => serverLabel ?? def?.label ?? key;
  String get betterWhen => def?.betterWhen ?? '';

  /// The His-normal cell as printed: the server's displayNormal
  /// when carried, else the normal cell.
  ComputedCell get displayNormal => displayNormalCell ?? normal;
}

/// One medication change (SPEC §1.3 medChanges entry shape).
class ComputedMedChange {
  final String drugKey;
  final String drugName;
  final String kind; // doseChange|frequencyChange|start|stop
  final String fromDose;
  final String toDose;
  final String fromFrequency;
  final String toFrequency;
  final String changeDate; // yyyy-MM-dd or month-precision string
  final String? display; // server-rendered phrase, when carried

  /// Mason's server builder names the pre-rendered phrase
  /// `phrasing` (reportV2.js changePhrasing) — preferred verbatim
  /// over the local template fill.
  final String? phrasing;

  /// Whether this change pairs a stop record with a start record
  /// for the same drug (reportV2.js buildMedChanges `paired`).
  /// MC-5 ranks PAIRED dose changes first (Vera F-3).
  final bool paired;

  /// The change event's recorded-at timestamp (server
  /// `recordedAt`); MC-5's tie-break is earliest recorded first.
  final int recordedAt;
  const ComputedMedChange({
    this.drugKey = '',
    this.drugName = '',
    this.kind = '',
    this.fromDose = '',
    this.toDose = '',
    this.fromFrequency = '',
    this.toFrequency = '',
    this.changeDate = '',
    this.display,
    this.phrasing,
    this.paired = false,
    this.recordedAt = 0,
  });

  factory ComputedMedChange.fromJson(Map<String, dynamic> j) =>
      ComputedMedChange(
        drugKey: _asString(j['drugKey']),
        drugName: _asString(j['drugName']),
        kind: _asString(j['kind']),
        fromDose: _asString(j['fromDose']),
        toDose: _asString(j['toDose']),
        fromFrequency: _asString(j['fromFrequency']),
        toFrequency: _asString(j['toFrequency']),
        changeDate: _asString(j['changeDate']),
        display: j['display'] as String?,
        phrasing: j['phrasing'] as String?,
        paired: j['paired'] == true,
        recordedAt: (j['recordedAt'] as num?)?.toInt() ?? 0,
      );
}

/// Ruling 6.2's table form for a dose: dose + space + unit
/// (`50mg` → `50 mg`), exactly the server's `doseWithSpace`
/// (reportV2.js). A dose with no unit letters is unchanged.
String doseWithSpace(String dose) {
  final t = dose.trim();
  return t.replaceFirstMapped(
    RegExp(r'^(\d+(?:\.\d+)?)\s*([a-zA-Z]+.*)$'),
    (m) => '${m[1]} ${m[2]}',
  );
}

/// Ruling 6.2 change phrasing for one change — byte-aligned with
/// the server's `changePhrasing` (reportV2.js), Vera F-3. A
/// server-carried [ComputedMedChange.display] /
/// [ComputedMedChange.phrasing] wins verbatim; the fallback fill
/// applies [doseWithSpace] to every dose slot and prints
/// `frequency not recorded` for an empty frequency side (Ruling
/// 3's recorded-frequency discipline).
String medChangePhrase(ComputedMedChange c) {
  if (c.display != null && c.display!.isNotEmpty) return c.display!;
  if (c.phrasing != null && c.phrasing!.isNotEmpty) return c.phrasing!;
  switch (c.kind) {
    case 'doseChange':
      final increased = _doseNumber(c.toDose) >= _doseNumber(c.fromDose);
      return '${c.drugName}: dose ${increased ? 'increased' : 'decreased'}, '
          '${doseWithSpace(c.fromDose)} → ${doseWithSpace(c.toDose)}';
    case 'frequencyChange':
      final from = c.fromFrequency.isEmpty
          ? 'frequency not recorded'
          : c.fromFrequency;
      final to =
          c.toFrequency.isEmpty ? 'frequency not recorded' : c.toFrequency;
      return '${c.drugName}: frequency changed, $from → $to';
    case 'stop':
      return '${'${c.drugName} ${doseWithSpace(c.fromDose.isNotEmpty ? c.fromDose : c.toDose)}'.trim()}: stopped';
    case 'start':
    default:
      // The server's fallthrough: any non-dose/frequency/stop
      // kind phrases as a start, from the to-dose only.
      return '${'${c.drugName} ${doseWithSpace(c.toDose)}'.trim()}: started';
  }
}

double _doseNumber(String dose) =>
    double.tryParse(RegExp(r'[0-9]+(?:\.[0-9]+)?').firstMatch(dose)?.group(0) ?? '') ??
    0;

/// MC-5 precedence for the single "Most recent change" line,
/// exactly the server's ranking (reportV2.js buildMedChanges,
/// Vera F-3): a PAIRED dose change ranks first, then any
/// dose/frequency change, then start, then stop; ties break by
/// earliest recordedAt, then list order (SPEC §3.2 MC-5).
ComputedMedChange? selectLatestPriorChange(List<ComputedMedChange> latestPrior) {
  if (latestPrior.isEmpty) return null;
  int rank(ComputedMedChange c) {
    if (c.kind == 'doseChange' && c.paired) return 0;
    if (c.kind == 'doseChange' || c.kind == 'frequencyChange') return 1;
    if (c.kind == 'start') return 2;
    return 3;
  }

  var best = latestPrior.first;
  for (final c in latestPrior.skip(1)) {
    final r = rank(c);
    final br = rank(best);
    if (r < br || (r == br && c.recordedAt < best.recordedAt)) best = c;
  }
  return best;
}

/// One current-medication appendix entry (SPEC §1.3): name/dose
/// exactly as recorded; frequency verbatim or ABSENT — never
/// inferred (Ruling 7.4: ivabradine prints dose with no frequency
/// segment when the record's frequency is blank).
class ComputedMedication {
  final String name;
  final String dose;
  final String frequency;
  const ComputedMedication(
      {required this.name, required this.dose, required this.frequency});

  factory ComputedMedication.fromJson(Map<String, dynamic> j) =>
      ComputedMedication(
        name: _asString(j['name']),
        dose: _asString(j['dose']),
        frequency: _asString(j['frequency']),
      );

  /// The appendix list line: `Name dose` plus ` (frequency)` only
  /// when the record carries a frequency string.
  String get listLine =>
      frequency.trim().isEmpty ? '$name $dose' : '$name $dose ($frequency)';
}

/// One notable day (SPEC §1.3): date, selecting slots, grid facts.
class ComputedNotableDay {
  final String date; // yyyy-MM-dd
  final List<String> slots;
  final Map<String, dynamic> facts;
  final String? display; // server-rendered line, when carried
  const ComputedNotableDay(
      {required this.date, this.slots = const [], this.facts = const {}, this.display});

  factory ComputedNotableDay.fromJson(Map<String, dynamic> j) =>
      ComputedNotableDay(
        date: _asString(j['date']),
        slots: [for (final s in _asList(j['slots'])) _asString(s)],
        facts: _asMap(j['facts']) ?? const {},
        display: j['display'] as String?,
      );

  /// Ruling 13.3 line: `[Short date] — [fact]; [fact]; … .` Facts
  /// in the ruled fixed order, only those the day carries. A
  /// server-carried [display] line wins verbatim.
  String get line {
    if (display != null && display!.isNotEmpty) return display!;
    final parts = <String>[];
    final f = facts;
    if (f['score'] != null) parts.add('score ${_numText(f['score'])}');
    if (f['minutesOver100'] != null) {
      parts.add('${_numText(f['minutesOver100'])} min over 100 bpm');
    }
    if (f['minutesOver120'] != null) {
      parts.add('${_numText(f['minutesOver120'])} min over 120 bpm');
    }
    if (f['peakHr'] != null) parts.add('peak HR ${_numText(f['peakHr'])} bpm');
    if (f['hrv'] != null) parts.add('HRV ${_numText(f['hrv'])} ms');
    if (f['rhr'] != null) {
      parts.add('resting HR ${_numText(f['rhr'])} bpm');
    }
    final palp = f['palpitationsText'];
    if (palp is String && palp.isNotEmpty) {
      // The server object carries the day's palpitations entry
      // text; the ruled symptom fact form (mirroring the server
      // renderer's notableDayLine) is `strong palpitations
      // logged` / `palpitations logged`.
      parts.add(RegExp(r'strong', caseSensitive: false).hasMatch(palp)
          ? 'strong palpitations logged'
          : 'palpitations logged');
    }
    return '${shortDateLabel(date)} — ${parts.join('; ')}.';
  }
}

String _numText(Object? v) {
  if (v is num && v == v.roundToDouble()) return v.toInt().toString();
  return v?.toString() ?? '';
}

const _monthShort = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];
const _monthFull = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July',
  'August', 'September', 'October', 'November', 'December',
];

/// `Nov 17` from `2026-11-17` (input returned unchanged when it is
/// not an ISO date — month-precision dates render as recorded).
String shortDateLabel(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null || !iso.contains('-')) return iso;
  return '${_monthShort[d.month - 1]} ${d.day}';
}

/// `November 11, 2026` from `2026-11-11` (Ruling 6.3 full form).
String fullDateLabel(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null || !iso.contains('-')) return iso;
  return '${_monthFull[d.month - 1]} ${d.day}, ${d.year}';
}

/// One day-by-day grid cell (SPEC §1.3): the two non-value states
/// are DISTINCT (Ruling 13.2).
class ComputedGridCell {
  final String state; // value|noneLogged|noSource
  final Object? value;
  const ComputedGridCell({this.state = 'noneLogged', this.value});

  factory ComputedGridCell.fromJson(Object? j) {
    if (j is Map) {
      final m = j.cast<String, dynamic>();
      return ComputedGridCell(
          state: _asString(m['state']).isEmpty
              ? 'noneLogged'
              : _asString(m['state']),
          value: m['value']);
    }
    if (j == null) return const ComputedGridCell();
    return ComputedGridCell(state: 'value', value: j);
  }
}

/// One grid day: date plus the row-keyed cells.
class ComputedGridDay {
  final String date;
  final Map<String, ComputedGridCell> cells;
  const ComputedGridDay({required this.date, required this.cells});

  factory ComputedGridDay.fromJson(Map<String, dynamic> j) {
    final cells = <String, ComputedGridCell>{};
    for (final (key, _) in weeklyV2GridRows) {
      if (j.containsKey(key)) cells[key] = ComputedGridCell.fromJson(j[key]);
    }
    return ComputedGridDay(date: _asString(j['date']), cells: cells);
  }
}

/// Grid cell text for one row (Ruling 13.1 vocabulary): symptom
/// rows print `Yes`, behavior rows `Done`, numeric rows the value;
/// `—` = nothing logged, `n/a` = not in the source data.
String gridCellText(String rowKey, ComputedGridCell cell) {
  if (cell.state == 'noSource') return 'n/a';
  if (cell.state != 'value' || cell.value == null) return '—';
  final v = cell.value;
  if (v is bool) {
    if (!v) return '—';
    return (rowKey == 'pt' || rowKey == 'coldExposure') ? 'Done' : 'Yes';
  }
  return _numText(v);
}

/// One question anchor (SPEC §1.3): kind + the exact values its
/// ruled question shape must cite.
class ComputedQuestionAnchor {
  final String kind;
  final String? scorecardKey;
  final String? date;
  final Map<String, dynamic> values;
  final String? text; // server-rendered question, when carried
  const ComputedQuestionAnchor({
    required this.kind,
    this.scorecardKey,
    this.date,
    this.values = const {},
    this.text,
  });

  factory ComputedQuestionAnchor.fromJson(Map<String, dynamic> j) =>
      ComputedQuestionAnchor(
        kind: _asString(j['kind']),
        scorecardKey: j['scorecardKey'] as String?,
        date: j['date'] as String?,
        values: _asMap(j['values']) ?? const {},
        text: j['text'] as String?,
      );

  /// The question rendered through its Ruling 8/9.3 shape. A
  /// server-carried [text] wins verbatim. Candidate frequencies
  /// appear ONLY inside the blank-frequency question, as a
  /// question (Ruling 8.3) — never as a stated fact anywhere.
  String get question {
    if (text != null && text!.isNotEmpty) return text!;
    final v = values;
    String s(String k) => _asString(v[k]);
    switch (kind) {
      case 'blankFrequency':
        final base = 'Can you confirm how often Tyson should take '
            '${s('drugName')} ${s('dose')}? His medication record '
            'lists the dose with no frequency.';
        final candidate = s('candidateFrequency');
        return candidate.isEmpty ? base : '$base Is it $candidate?';
      case 'motsCStatus':
        final dose = s('dose');
        return 'Tyson is taking ${s('itemName')}'
            '${dose.isEmpty ? '' : ' $dose'}. It appears in his '
            'current medications and supplements with no prescriber '
            'recorded. Do you approve of him taking it, and should '
            'it stay on his list?';
      case 'medChangeDelta':
        return '${s('drugName')} was ${s('direction')} from '
            '${s('fromDose')} to ${s('toDose')} on '
            '${fullDateLabel(s('changeDate'))}. In the week of '
            '${s('rangeLabel')}, his ${s('metricLabel')} averaged '
            '${s('value')}, against his normal of ${s('normal')}. '
            'Is any change needed, or should this dose continue?';
      case 'extremeDay':
        // Vera F-4: the server's extreme-day anchor carries NO
        // symptom slot — its values are {minutesOver100, peakHr}
        // only, and the symptom lives in the anchor's rendered
        // text and in the matching notable day's
        // facts.palpitationsText (the parser resolves that into
        // `palpitationsText` here, see ComputedMetrics.tryParse).
        // A legacy `symptom` slot is still honoured when present.
        // When no symptom can be sourced from either shape — or
        // the carried numbers are absent — the question is
        // OMITTED (empty string; the section renderer drops it)
        // rather than rendered with an empty symptom.
        var symptom = s('symptom');
        if (symptom.isEmpty) symptom = s('palpitationsText');
        final minutes = s('minutesOver100');
        final peak = s('peakHr');
        if (symptom.isEmpty || minutes.isEmpty || peak.isEmpty) return '';
        return 'On ${fullDateLabel(date ?? s('date'))}, Tyson logged '
            '$symptom and his heart rate was over 100 bpm for '
            '$minutes minutes, with a peak of '
            '$peak bpm. Should an ECG or any other check be '
            'done for an event like that?';
      case 'sleepVsNeed':
        return 'Tyson averaged ${s('duration')} of sleep this week, '
            '${s('pct')}% of his Sleep Need of ${s('need')} — '
            '${s('shortfall')} short per night on average. Is there '
            'anything you would change or check about his sleep?';
      default:
        return s('question');
    }
  }
}

/// The server computed-metrics object (SPEC §1.3), parsed
/// tolerantly: unknown/missing sub-objects degrade to empty, a
/// missing object parses to null (legacy reports keep their v1
/// rendering — the v2 mirror engages only when the server sends
/// the object).
class ComputedMetrics {
  final String rangeStart;
  final String rangeEnd;
  final List<ComputedScorecardRow> scorecard;
  final Map<String, int> tally;
  final List<String> noDataRowLabels;
  final int headlineKey;
  final List<ComputedNotableDay> notableDays;
  final List<ComputedMedChange> medChangesInWindow;
  final List<ComputedMedChange> medChangesLatestPrior;

  /// The server's MC-5 selection (medChanges.latestPriorNamed),
  /// when carried — preferred over the local precedence fill.
  final ComputedMedChange? medChangesLatestPriorNamed;
  final List<ComputedMedication> currentMedications;
  final List<ComputedGridDay> grid;
  final List<ComputedQuestionAnchor> questionAnchors;
  final Map<String, dynamic> charts;
  final Map<String, dynamic> correlations;
  final Map<String, dynamic> raw;

  const ComputedMetrics({
    required this.rangeStart,
    required this.rangeEnd,
    required this.scorecard,
    required this.tally,
    required this.noDataRowLabels,
    required this.headlineKey,
    required this.notableDays,
    required this.medChangesInWindow,
    required this.medChangesLatestPrior,
    this.medChangesLatestPriorNamed,
    required this.currentMedications,
    required this.grid,
    required this.questionAnchors,
    required this.charts,
    required this.correlations,
    required this.raw,
  });

  static ComputedMetrics? tryParse(Object? json) {
    final j = _asMap(json);
    if (j == null) return null;
    final range = _asMap(j['range']) ?? const {};
    final tallyRaw = _asMap(j['tally']) ?? const {};
    int t(String k) => (tallyRaw[k] as num?)?.toInt() ?? 0;
    final med = _asMap(j['medChanges']) ?? const {};
    // Vera F-4: resolve the extreme-day anchor's symptom from the
    // shape the server actually emits — the notable day on the
    // anchor's date carries facts.palpitationsText. Anchors whose
    // own values already carry a symptom are left untouched.
    final parsedNotableDays = <ComputedNotableDay>[
      for (final r in _asList(j['notableDays']))
        if (_asMap(r) != null) ComputedNotableDay.fromJson(_asMap(r)!),
    ];
    ComputedQuestionAnchor enrichAnchor(ComputedQuestionAnchor a) {
      if (a.kind != 'extremeDay') return a;
      if (_asString(a.values['symptom']).isNotEmpty ||
          _asString(a.values['palpitationsText']).isNotEmpty) {
        return a;
      }
      for (final d in parsedNotableDays) {
        if (d.date != (a.date ?? _asString(a.values['date']))) continue;
        final text = d.facts['palpitationsText'];
        if (text is String && text.isNotEmpty) {
          return ComputedQuestionAnchor(
            kind: a.kind,
            scorecardKey: a.scorecardKey,
            date: a.date,
            values: {...a.values, 'palpitationsText': text},
            text: a.text,
          );
        }
      }
      return a;
    }

    return ComputedMetrics(
      rangeStart: _asString(range['start']),
      rangeEnd: _asString(range['end']),
      scorecard: [
        for (final r in _asList(j['scorecard']))
          if (_asMap(r) != null) ComputedScorecardRow.fromJson(_asMap(r)!),
      ],
      tally: {
        'worse': t('worse'),
        'better': t('better'),
        'same': t('same'),
        'mixed': t('mixed'),
        'noData': t('noData'),
        'total': t('total') == 0 ? 10 : t('total'),
      },
      noDataRowLabels: [
        for (final s in _asList(tallyRaw['noDataRowLabels'])) _asString(s),
      ],
      headlineKey: (j['headlineKey'] as num?)?.toInt() ?? 0,
      notableDays: parsedNotableDays,
      medChangesInWindow: [
        for (final r in _asList(med['inWindow']))
          if (_asMap(r) != null) ComputedMedChange.fromJson(_asMap(r)!),
      ],
      medChangesLatestPrior: [
        for (final r in _asList(med['latestPrior']))
          if (_asMap(r) != null) ComputedMedChange.fromJson(_asMap(r)!),
      ],
      medChangesLatestPriorNamed: _asMap(med['latestPriorNamed']) == null
          ? null
          : ComputedMedChange.fromJson(_asMap(med['latestPriorNamed'])!),
      currentMedications: [
        for (final r in _asList(med['currentMedications']))
          if (_asMap(r) != null) ComputedMedication.fromJson(_asMap(r)!),
      ],
      grid: [
        for (final r in _asList(j['grid']))
          if (_asMap(r) != null) ComputedGridDay.fromJson(_asMap(r)!),
      ],
      questionAnchors: [
        for (final r in _asList(j['questionAnchors']))
          if (_asMap(r) != null)
            enrichAnchor(ComputedQuestionAnchor.fromJson(_asMap(r)!)),
      ],
      charts: _asMap(j['charts']) ?? const {},
      correlations: _asMap(j['correlations']) ?? const {},
      raw: j,
    );
  }

  ComputedScorecardRow? rowByKey(String key) {
    for (final r in scorecard) {
      if (r.key == key) return r;
    }
    return null;
  }

  /// Ruling 16.1 title: `Tyson · Weekly snapshot, Nov 16–22, 2026`.
  String get snapshotTitle {
    final s = DateTime.tryParse(rangeStart);
    final e = DateTime.tryParse(rangeEnd);
    if (s == null || e == null) {
      return 'Tyson · Weekly snapshot, $rangeStart–$rangeEnd';
    }
    final range = s.year == e.year && s.month == e.month
        ? '${_monthShort[s.month - 1]} ${s.day}–${e.day}, ${e.year}'
        : '${_monthShort[s.month - 1]} ${s.day} – '
            '${_monthShort[e.month - 1]} ${e.day}, ${e.year}';
    return 'Tyson · Weekly snapshot, $range';
  }

  /// The server's pre-rendered verdict block (reportV2.js
  /// buildVerdict), when carried: {headline, supporting,
  /// tallySentence, text}. Preferred verbatim everywhere below —
  /// the local deterministic builders are the fallback for
  /// spec-shaped objects without it.
  Map<String, dynamic>? get serverVerdict => _asMap(raw['verdict']);

  /// Ruling 1.1 headline cascade over the tally (deterministic;
  /// the headline string is rendered from the ruling's closed
  /// set, never stored free-text — SPEC §1.3 headlineKey is the
  /// audit key for which rule fired).
  String get headline {
    final server = serverVerdict?['headline'] ?? raw['headline'];
    if (server is String && server.isNotEmpty) return server;
    final w = tally['worse'] ?? 0;
    final b = tally['better'] ?? 0;
    final s = tally['same'] ?? 0;
    final m = tally['mixed'] ?? 0;
    final n = tally['noData'] ?? 0;
    if (n == (tally['total'] ?? 10)) {
      return 'Not enough data this week to compare with his usual.';
    }
    int largest(int a, int bb, int c, int d) =>
        [a, bb, c, d].reduce((x, y) => x > y ? x : y);
    final maxCount = largest(w, b, s, m);
    if (w == maxCount && w > b) return 'Harder week than his usual.';
    if (b == maxCount && b > w) return 'Easier week than his usual.';
    if (s == maxCount && s > w && s > b && s > m) {
      return 'About the same as his usual week.';
    }
    return 'A mixed week against his usual.';
  }

  /// Ruling 4.2 tally sentence, as amended by Juno's fix-round
  /// addendum A.4 — the LAST sentence of the verdict block and
  /// byte-aligned with the server's `buildTallySentence`
  /// (reportV2.js), Vera F-1: EVERY category agrees in number
  /// (singular at count 1: `1 is worse / is better / is the same /
  /// is mixed / has no data this week`; plural otherwise),
  /// categories in fixed order, zero counts omitted, the no-data
  /// clause names the no-data rows lowercased.
  String get tallySentence {
    final server = serverVerdict?['tallySentence'] ?? raw['tallySentence'];
    if (server is String && server.isNotEmpty) return server;
    String cat(int n, String singular, String plural) =>
        '$n ${n == 1 ? singular : plural}';
    final parts = <String>[];
    final w = tally['worse'] ?? 0;
    final b = tally['better'] ?? 0;
    final s = tally['same'] ?? 0;
    final m = tally['mixed'] ?? 0;
    final n = tally['noData'] ?? 0;
    if (w > 0) parts.add(cat(w, 'is worse', 'are worse'));
    if (b > 0) parts.add(cat(b, 'is better', 'are better'));
    if (s > 0) parts.add(cat(s, 'is the same', 'are the same'));
    if (m > 0) parts.add(cat(m, 'is mixed', 'are mixed'));
    var sentence = 'Of the 10 measures on the scorecard, ${parts.join(', ')}';
    if (n > 0) {
      final names = noDataRowLabels.isNotEmpty
          ? noDataRowLabels
          : [
              for (final r in scorecard)
                if (r.trend == 'No data') r.label.toLowerCase(),
            ];
      final joined = names.length <= 2
          ? names.join(' and ')
          : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
      final clause = '$n ${n == 1 ? 'has' : 'have'} no data this week ($joined)';
      sentence += parts.isNotEmpty ? ', and $clause' : clause;
    }
    return '$sentence.';
  }

  /// Ruling 1.2 supporting passage, as amended by Juno's fix-round
  /// addendum A — byte-aligned with the server's `buildVerdict`
  /// (reportV2.js), Vera F-2:
  /// * each cited measure's sentence comes from the A.2
  ///   per-measure template table, keyed by measure (see
  ///   [_verdictSentence]); the A.1-banned generic template
  ///   (`His [label] averaged …`) does not exist in any branch —
  ///   an unknown measure key is omitted, never templated;
  /// * A.1 rule 4 eligibility on every branch: a measure is cited
  ///   only when BOTH its displays exist (neither is `—`, neither
  ///   value null) and its Trend is not `No data` — a no-data
  ///   measure is never cited;
  /// * selection: harder headlines cite worse measures, easier
  ///   headlines cite better measures (scorecard order, at most
  ///   four); same/mixed headlines cite the eligible measures
  ///   with the largest |Δ vs normal| (Ruling 1.2, the server's
  ///   `verdictDelta`), presented in scorecard order;
  /// * the closing day sentence follows the server: hardest days
  ///   on harder/mixed headlines, best days on easier, none on a
  ///   same headline. No banned causal word appears in any
  ///   template here.
  String get supportingPassage {
    final server = serverVerdict?['supporting'];
    if (server is String && server.isNotEmpty) return server;
    final head = headline;
    final harder = head == 'Harder week than his usual.';
    final easier = head == 'Easier week than his usual.';
    final mixed = head == 'A mixed week against his usual.';
    final same = head == 'About the same as his usual week.';
    final cited = <ComputedScorecardRow>[];
    if (harder || easier) {
      final wanted = harder ? 'Worse' : 'Better';
      for (final row in scorecard) {
        if (cited.length >= 4) break;
        if (row.trend == wanted && _verdictEligible(row)) cited.add(row);
      }
    } else if (same || mixed) {
      final ranked = <(int, ComputedScorecardRow, double)>[];
      for (var i = 0; i < scorecard.length; i++) {
        final row = scorecard[i];
        if (!_verdictEligible(row)) continue;
        final d = _verdictDelta(row);
        if (d == null) continue;
        ranked.add((i, row, d));
      }
      ranked.sort((a, b) {
        final byDelta = b.$3.compareTo(a.$3);
        return byDelta != 0 ? byDelta : a.$1.compareTo(b.$1);
      });
      final picked = ranked.take(4).toList()
        ..sort((a, b) => a.$1.compareTo(b.$1));
      cited.addAll([for (final e in picked) e.$2]);
    }
    final sentences = <String>[];
    for (final row in cited) {
      final sentence = _verdictSentence(row);
      if (sentence != null) sentences.add(sentence);
    }
    if (notableDays.isNotEmpty && (harder || easier || mixed)) {
      final days = notableDays.take(2).toList();
      final label = easier ? 'best' : 'hardest';
      if (days.length == 1) {
        sentences.add('The $label day was ${shortDateLabel(days.first.date)}.');
      } else {
        sentences.add('The $label days were '
            '${shortDateLabel(days[0].date)} and ${shortDateLabel(days[1].date)}.');
      }
    }
    return sentences.join(' ');
  }

  /// Ruling 6.3 most-recent line, or null when no prior change
  /// exists at all.
  String? get mostRecentChangeLine {
    final change = medChangesLatestPriorNamed ??
        selectLatestPriorChange(medChangesLatestPrior);
    if (change == null) return null;
    return 'Most recent change before this week: '
        '${medChangePhrase(change)}, ${fullDateLabel(change.changeDate)}.';
  }

  /// Ruling 6.5 care-team facts line — rendered ONLY when the
  /// object carries a next-appointment record; never carried over
  /// from a prior report.
  String? get nextAppointmentLine {
    final appt = _asMap(raw['nextAppointment']);
    if (appt == null) return null;
    // Shape as carried by the server builder's input
    // ({name, credential, dateLabel} — dateLabel pre-rendered in
    // full form); the {clinicianName, date} ISO form is also
    // accepted.
    final name = _asString(appt['clinicianName']).isNotEmpty
        ? _asString(appt['clinicianName'])
        : _asString(appt['name']);
    final cred = _asString(appt['credential']);
    final dateText = _asString(appt['dateLabel']).isNotEmpty
        ? _asString(appt['dateLabel'])
        : fullDateLabel(_asString(appt['date']));
    if (name.isEmpty || dateText.isEmpty) return null;
    return 'Next appointment: $name${cred.isEmpty ? '' : ', $cred'}, '
        '$dateText.';
  }
}

/// Juno fix-round addendum A.1 rule 4 eligibility (the server's
/// `verdictEligible`): a measure may be cited in the supporting
/// passage only when both its displays exist (neither value null,
/// neither display the dash) and its Trend is not `No data`.
bool _verdictEligible(ComputedScorecardRow r) =>
    r.trend != 'No data' &&
    r.thisWeek.value != null &&
    r.displayNormal.value != null &&
    r.thisWeek.display != '—' &&
    r.displayNormal.display != '—';

/// |Δ vs His normal| in the row's own printed comparison terms
/// (the server's `verdictDelta`): sleep compares its
/// percent-of-need against 100% (its normal is the need itself);
/// blood pressure takes the larger component delta; every other
/// measure takes the numeric difference of the carried values.
double? _verdictDelta(ComputedScorecardRow r) {
  if (r.key == 'sleepVsNeed') {
    final pct = r.thisWeek.pct;
    return pct == null ? null : (pct - 100).abs();
  }
  if (r.key == 'bloodPressure') {
    final a = r.thisWeek.value;
    final b = r.displayNormal.value;
    if (a is Map && b is Map) {
      final aSys = a['systolic'];
      final aDia = a['diastolic'];
      final bSys = b['systolic'];
      final bDia = b['diastolic'];
      if (aSys is num && aDia is num && bSys is num && bDia is num) {
        final dSys = (aSys - bSys).abs().toDouble();
        final dDia = (aDia - bDia).abs().toDouble();
        return dSys > dDia ? dSys : dDia;
      }
    }
    return null;
  }
  final a = r.thisWeek.value;
  final b = r.displayNormal.value;
  if (a is num && b is num) return (a - b).abs().toDouble();
  return null;
}

/// Juno fix-round addendum A.2 per-measure verdict templates,
/// keyed by measure — byte-exact, direction-neutral. Slots are
/// the scorecard's own display strings exactly as printed; sleep's
/// need slot is its His-normal display with the trailing
/// ` (his Sleep Need)` removed. An unknown measure key returns
/// null and is omitted: the A.1-banned generic template
/// (`His [row label] averaged …`) exists in NO branch (Vera F-2).
String? _verdictSentence(ComputedScorecardRow r) {
  final tw = r.thisWeek.display;
  final n = r.displayNormal.display;
  switch (r.key) {
    case 'dailyScore':
      return 'His Daily Score averaged $tw, against his normal of $n.';
    case 'flareDays':
      return 'He logged flares on $tw, against his normal of $n.';
    case 'headacheDays':
      return 'He logged headaches on $tw, against his normal of $n.';
    case 'restingHr':
      return 'His resting heart rate averaged $tw, against his normal of $n.';
    case 'hrv':
      return 'His HRV averaged $tw, against his normal of $n.';
    case 'sleepVsNeed':
      final need = n.replaceFirst(RegExp(r' \(his Sleep Need\)$'), '');
      return 'His sleep averaged $tw; his Sleep Need is $need.';
    case 'minutesOver100':
      return 'His heart rate was over 100 bpm for an average of $tw a day, '
          'against his normal of $n.';
    case 'minutesOver120':
      return 'His heart rate was over 120 bpm for an average of $tw a day, '
          'against his normal of $n.';
    case 'peakHr':
      return 'His peak heart rate reached $tw, against his normal of $n.';
    case 'bloodPressure':
      return 'His blood pressure was $tw, against his normal of $n.';
    default:
      return null;
  }
}

// ── Section rendering (shared by the in-app mirror + PDF) ───────

/// One rendered v2 section: ruled title + its plain-text lines.
/// The in-app mirror and the PDF parity renderer both consume
/// this single rendering, so they cannot diverge.
class WeeklyV2Section {
  final String title;
  final List<String> lines;
  const WeeklyV2Section(this.title, this.lines);
}

/// Renders the mirror sections in ruled order: Verdict, Scorecard,
/// What changed this week, Notable days, Questions for Brad,
/// Day by day. (Charts and Appendix data lines are rendered by
/// [weeklyV2AppendixSections] for the PDF parity path; SPEC §5.6
/// keeps those as server-PDF surfaces for the in-app mirror.)
List<WeeklyV2Section> weeklyV2MirrorSections(ComputedMetrics m) {
  final verdict = WeeklyV2Section('Verdict', [
    m.headline,
    if (m.supportingPassage.isNotEmpty) m.supportingPassage,
    m.tallySentence,
    weeklyV2Disclaimer,
  ]);

  final scorecardLines = <String>[
    weeklyV2ScorecardHeaders.join(' | '),
    for (final def in weeklyV2ScorecardRows)
      if (m.rowByKey(def.key) case final row?)
        '${def.label} (${def.betterWhen}) | ${row.thisWeek.display} | '
            '${row.lastWeek.display} | ${row.displayNormal.display} | ${row.trend}',
    weeklyV2NormalNote,
  ];
  final scorecard = WeeklyV2Section('Scorecard', scorecardLines);

  final changedLines = <String>['Date | Change | Status'];
  if (m.medChangesInWindow.isEmpty) {
    changedLines.add('— | $weeklyV2NoChangesText | —');
    final recent = m.mostRecentChangeLine;
    if (recent != null) changedLines.add(recent);
  } else {
    for (final c in m.medChangesInWindow) {
      changedLines.add('${shortDateLabel(c.changeDate)} | '
          '${medChangePhrase(c)} | Current');
    }
  }
  final appt = m.nextAppointmentLine;
  if (appt != null) changedLines.add(appt);
  final changed = WeeklyV2Section('What changed this week', changedLines);

  final notable = WeeklyV2Section('Notable days', [
    for (final d in m.notableDays) d.line,
  ]);

  // A question whose fallback cannot be built from the anchor's
  // carried shape renders as '' and is OMITTED here (no
  // placeholder copy, remaining questions renumbered) — Vera F-4.
  final renderedQuestions = <String>[
    for (final a in m.questionAnchors)
      if (a.question.isNotEmpty) a.question,
  ];
  final questions = WeeklyV2Section('Questions for Brad', [
    weeklyV2QuestionsForLine,
    for (var i = 0; i < renderedQuestions.length; i++)
      '${i + 1}. ${renderedQuestions[i]}',
  ]);

  final gridLines = <String>[
    'Day | ${[for (final d in m.grid) shortDateLabel(d.date)].join(' | ')}',
    for (final (key, label) in weeklyV2GridRows)
      '$label | ${[for (final d in m.grid) gridCellText(key, d.cells[key] ?? const ComputedGridCell())].join(' | ')}',
    weeklyV2GridLegend,
  ];
  final grid = WeeklyV2Section('Day by day', gridLines);

  return [verdict, scorecard, changed, notable, questions, grid];
}

/// Charts + Appendix data lines for the PDF parity path: chart
/// series values with their `His usual` legend (Ruling 14.1),
/// medication-change markers (Ruling 14.2 labels as carried), the
/// appendix medication list (Ruling 7) and correlations text as
/// carried — all from the same object, nothing recomputed.
List<WeeklyV2Section> weeklyV2AppendixSections(ComputedMetrics m) {
  final chartLines = <String>[];
  final series = _asMap(m.charts['series']) ?? const {};
  final normalRef = _asMap(m.charts['normalRef']) ?? const {};
  for (final e in series.entries) {
    final vals = _asList(e.value);
    if (vals.isEmpty) continue;
    // Server series points are {date, value} objects (reportV2.js
    // charts.series); scalar points are also accepted.
    final points = [
      for (final v in vals)
        if (_asMap(v) != null) _numText(_asMap(v)!['value']) else _numText(v),
    ];
    chartLines.add('${e.key}: ${points.join(', ')}');
    // Server normalRef values are raw numbers (rowVal) or a cell
    // map with a display string.
    final refRaw = normalRef[e.key];
    final refMap = _asMap(refRaw);
    if (refMap != null && refMap['display'] != null) {
      chartLines.add('His usual: ${refMap['display']}');
    } else if (refRaw is num) {
      chartLines.add('His usual: ${_numText(refRaw)}');
    }
  }
  // Grouped same-date marker labels (Ruling 14.2) when carried;
  // otherwise the per-change marker labels.
  final grouped = _asList(m.charts['medMarkerLabels']);
  if (grouped.isNotEmpty) {
    for (final marker in grouped) {
      final mm = _asMap(marker);
      if (mm != null && mm['label'] != null) {
        chartLines.add(_asString(mm['label']));
      }
    }
  } else {
    for (final marker in _asList(m.charts['medMarkers'])) {
      final mm = _asMap(marker);
      if (mm != null && mm['label'] != null) {
        chartLines.add(_asString(mm['label']));
      }
    }
  }
  final appendixLines = <String>[
    'Current Medications and Supplements',
    for (final med in m.currentMedications) med.listLine,
  ];
  final corrText = m.correlations['text'];
  if (corrText is String && corrText.isNotEmpty) {
    appendixLines.add('Correlations');
    appendixLines.add(corrText);
  }
  return [
    if (chartLines.isNotEmpty) WeeklyV2Section('Charts', chartLines),
    WeeklyV2Section('Appendix', appendixLines),
  ];
}

/// The full v2 report as plain text (title, range label, mirror
/// sections, then charts/appendix sections) — the single text the
/// PDF parity renderer flows and the tests assert against.
String buildWeeklyReportV2Text(ComputedMetrics m) {
  final b = StringBuffer()
    ..writeln(m.snapshotTitle)
    ..writeln(weeklyV2RangeLabel);
  for (final s in [...weeklyV2MirrorSections(m), ...weeklyV2AppendixSections(m)]) {
    b
      ..writeln()
      ..writeln(s.title);
    for (final line in s.lines) {
      b.writeln(line);
    }
  }
  return b.toString();
}
