import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'package:tabs_lab/src/data/progress_report.dart';

/// Round 66 — the pure-Dart port of native `util/ReportGenerator.kt`
/// (the snapshot `generateReport` path only; the separate graph-PDF
/// generator is a different native feature and is not ported here).
///
/// Geometry, byte-for-byte from native: A4 595×842pt, margin 45,
/// content width 505, title 22pt bold rgb(33,33,33), section headers
/// 16pt bold rgb(0,102,204) with a 60pt underline, body 11pt
/// rgb(66,66,66) (bold/italic black), meta 9pt gray, line height 18
/// in the summary flow, page break when y > 780 with the next page
/// starting at y = 50 (continuation lines at 60 inside formatted
/// lines, as native's drawFormattedLine does).
///
/// Clean-wording rule (native): the Data Availability section maps
/// every status to CLEAN clinical wording only. Raw exception or
/// transport text NEVER reaches the PDF. The one founder-visible
/// reason line is the raw-fallback banner's "AI unavailable:"
/// line, whose reason comes from the fixed-string
/// [AiFailure.plainReason] mapping — never free text.

// ── Markup parsing (native summary renderer) ──────────────────────

sealed class SummaryBlock {
  const SummaryBlock();
}

class SectionBlock extends SummaryBlock {
  final String text;
  const SectionBlock(this.text);
}

class BulletBlock extends SummaryBlock {
  final String text;
  const BulletBlock(this.text);
}

class TextBlock extends SummaryBlock {
  final String text;
  const TextBlock(this.text);
}

/// Splits a summary into render blocks exactly as native's line
/// loop does: a line CONTAINING `[SECTION]` is a section header
/// (markers, `*` and `#` stripped); a line containing `[BULLET]`
/// becomes a "• " bullet (`*`/`#` stripped, leading `-` removed);
/// every other line is body text with `#` stripped. (Native keeps
/// `*` on plain lines — only `#` is stripped there.)
List<SummaryBlock> parseSummaryBlocks(String summary) {
  final out = <SummaryBlock>[];
  for (final line in summary.split('\n')) {
    if (line.contains('[SECTION]')) {
      out.add(SectionBlock(line
          .replaceAll('[SECTION]', '')
          .replaceAll('[BOLD]', '')
          .replaceAll('*', '')
          .replaceAll('#', '')
          .trim()));
    } else if (line.contains('[BULLET]')) {
      var t = line
          .replaceAll('[BULLET]', '')
          .replaceAll('*', '')
          .replaceAll('#', '')
          .trim();
      if (t.startsWith('-')) t = t.substring(1).trim();
      out.add(BulletBlock(t));
    } else {
      out.add(TextBlock(line.replaceAll('#', '')));
    }
  }
  return out;
}

/// One inline run after `[BOLD]` / `[ITALIC]` toggle parsing
/// (native drawFormattedLine: markers toggle state, never render).
class InlineRun {
  final String text;
  final bool bold;
  final bool italic;
  const InlineRun(this.text, {this.bold = false, this.italic = false});
}

List<InlineRun> parseInlineRuns(String text) {
  final runs = <InlineRun>[];
  var bold = false;
  var italic = false;
  var rest = text;
  void emit(String s) {
    if (s.isNotEmpty) runs.add(InlineRun(s, bold: bold, italic: italic));
  }

  while (rest.isNotEmpty) {
    final b = rest.indexOf('[BOLD]');
    final i = rest.indexOf('[ITALIC]');
    if (b == -1 && i == -1) {
      emit(rest);
      break;
    }
    final next = (b == -1) ? i : (i == -1 ? b : (b < i ? b : i));
    emit(rest.substring(0, next));
    if (next == b) {
      bold = !bold;
      rest = rest.substring(next + '[BOLD]'.length);
    } else {
      italic = !italic;
      rest = rest.substring(next + '[ITALIC]'.length);
    }
  }
  return runs;
}

/// The effective summary text native renders: the AI summary when
/// present, the raw fallback text when [isRawFallback], else
/// native's fixed unavailable line.
String effectiveSummaryText(
  ReportSnapshot s, {
  String? aiSummary,
  required bool isRawFallback,
}) {
  if (aiSummary != null && aiSummary.trim().isNotEmpty) return aiSummary;
  if (isRawFallback) return buildRawFallbackSummary(s);
  return 'Clinical summary unavailable. Analysis based on raw snapshot data.';
}

/// Clean clinical wording for one availability status (native map).
String availabilityStatusText(SectionMetadata meta) => switch (meta.status) {
      DataSourceStatus.success => 'Available (${meta.recordCount} records)',
      DataSourceStatus.noData => 'No data recorded',
      DataSourceStatus.permissionDenied =>
        'Unavailable. Permission not granted.',
      _ => 'Unavailable. Data could not be retrieved.',
    };

/// The PDF availability label: the section key with ONLY its first
/// character upper-cased (native `replaceFirstChar uppercase` —
/// `bloodPressure` → "BloodPressure", `hrv` → "Hrv").
String availabilityPdfLabel(String key) =>
    key.isEmpty ? key : key[0].toUpperCase() + key.substring(1);

// ── Chart series (native chart-data construction) ────────────────

class ChartSeries {
  final String title;
  final String colorHex;
  final String unit;

  /// (x label "MMM d", value) points, date-sorted, zeros excluded.
  final List<(String, double)> points;
  const ChartSeries({
    required this.title,
    required this.colorHex,
    required this.unit,
    required this.points,
  });
}

String _chartDateLabel(String yyyyMmDd) {
  final d = DateTime.tryParse(yyyyMmDd);
  if (d == null) return yyyyMmDd;
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[d.month - 1]} ${d.day}';
}

List<(String, double)> _sortedFilteredI(List<(String, int)> s) {
  final rows = s.where((e) => e.$2 > 0).toList()
    ..sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final e in rows) (_chartDateLabel(e.$1), e.$2.toDouble())];
}

/// Chart page 1 series, native order: Sleep (hours), Avg HR, HRV,
/// Systolic BP.
List<ChartSeries> chartPage1Series(ReportSnapshot s) {
  final sleepRows = s.sleepSeries.where((e) => e.$2 > 0).toList()
    ..sort((a, b) => a.$1.compareTo(b.$1));
  final bpRows = s.bloodPressureSeries.toList()
    ..sort((a, b) => a.timeEpochMs.compareTo(b.timeEpochMs));
  return [
    ChartSeries(
      title: 'Sleep Duration',
      colorHex: '#42A5F5',
      unit: 'h',
      points: [
        for (final e in sleepRows) (_chartDateLabel(e.$1), e.$2 / 60.0),
      ],
    ),
    ChartSeries(
      title: 'Avg Heart Rate',
      colorHex: '#FF5E62',
      unit: ' bpm',
      points: _sortedFilteredI(s.heartRateSeries),
    ),
    ChartSeries(
      title: 'HRV (RMSSD)',
      colorHex: '#B388FF',
      unit: ' ms',
      points: [
        for (final e in (s.hrvSeries.where((x) => x.$2 > 0).toList()
              ..sort((a, b) => a.$1.compareTo(b.$1))))
          (_chartDateLabel(e.$1), e.$2),
      ],
    ),
    ChartSeries(
      title: 'Systolic Blood Pressure',
      colorHex: '#E53935',
      unit: ' mmHg',
      points: [
        for (final r in bpRows)
          (
            _chartDateLabel(dateStrOf(
                DateTime.fromMillisecondsSinceEpoch(r.timeEpochMs))),
            r.systolic.toDouble(),
          ),
      ],
    ),
  ];
}

/// Chart page 2 series, native order: Calories, HR Spikes, Notes.
List<ChartSeries> chartPage2Series(ReportSnapshot s) {
  final byDate = <String, int>{};
  for (final e in s.logEntries) {
    final d = dateStrOf(DateTime.fromMillisecondsSinceEpoch(e.timestamp));
    byDate[d] = (byDate[d] ?? 0) + 1;
  }
  final noteKeys = byDate.keys.toList()..sort();
  return [
    ChartSeries(
      title: 'Calories Burned',
      colorHex: '#FFA726',
      unit: ' kcal',
      points: _sortedFilteredI(s.caloriesSeries),
    ),
    ChartSeries(
      title: 'HR Spikes (>=100 BPM)',
      colorHex: '#E040FB',
      unit: '',
      points: [
        for (final e in (s.heartRateSpikes.where((x) => x.$2 > 0).toList()
              ..sort((a, b) => a.$1.compareTo(b.$1))))
          (_chartDateLabel(e.$1), e.$2.toDouble()),
      ],
    ),
    ChartSeries(
      title: 'Recorded Patient Notes',
      colorHex: '#26A69A',
      unit: '',
      points: [
        for (final k in noteKeys) (_chartDateLabel(k), byDate[k]!.toDouble()),
      ],
    ),
  ];
}

/// Native y-axis padding: HR/HRV titles floor at min−5, BP at
/// min−10 (both floored at 0), everything else at 0; max = max+5.
({double minY, double maxY}) chartYRange(ChartSeries series) {
  final vals = series.points.map((p) => p.$2);
  final maxVal = vals.reduce((a, b) => a > b ? a : b);
  final minVal = vals.reduce((a, b) => a < b ? a : b);
  var minY = 0.0;
  if (series.title.contains('Heart Rate') || series.title.contains('HRV')) {
    minY = minVal - 5;
    if (minY < 0) minY = 0;
  } else if (series.title.contains('Blood Pressure')) {
    minY = minVal - 10;
    if (minY < 0) minY = 0;
  }
  var maxY = maxVal + 5;
  if (maxY < minY + 1) maxY = minY + 1;
  return (minY: minY, maxY: maxY);
}

/// X labels native draws: step = size/5 (min 1), a label only when
/// it does not collide with the previous drawn one (4pt gap), plus
/// the last point when the step misses it. Collision needs pixel
/// widths, so this returns the candidate indices; the painter
/// applies the same no-collision rule with real text widths.
List<int> chartXLabelCandidates(int count) {
  if (count == 0) return const [];
  var step = count ~/ 5;
  if (step < 1) step = 1;
  final out = <int>[];
  for (var i = 0; i < count; i += step) {
    out.add(i);
  }
  if ((count - 1) % step != 0) out.add(count - 1);
  return out;
}

// ── Document rendering ────────────────────────────────────────────

const _margin = 45.0;
const _contentWidth = 505.0;
const _pageHeight = 842.0;
const _bottomLimit = 780.0;

PdfColor _rgb(int r, int g, int b) => PdfColor(r / 255, g / 255, b / 255);

final _titleStyle = pw.TextStyle(
  font: pw.Font.helveticaBold(),
  fontSize: 22,
  color: _rgb(33, 33, 33),
);
final _sectionStyle = pw.TextStyle(
  font: pw.Font.helveticaBold(),
  fontSize: 16,
  color: _rgb(0, 102, 204),
);
final _bodyStyle = pw.TextStyle(
  font: pw.Font.helvetica(),
  fontSize: 11,
  color: _rgb(66, 66, 66),
);
final _boldStyle = pw.TextStyle(
  font: pw.Font.helveticaBold(),
  fontSize: 11,
  color: _rgb(0, 0, 0),
);
final _italicStyle = pw.TextStyle(
  font: pw.Font.helveticaOblique(),
  fontSize: 11,
  color: _rgb(0, 0, 0),
);
final _metaStyle = pw.TextStyle(
  font: pw.Font.helvetica(),
  fontSize: 9,
  color: _rgb(128, 128, 128),
);
final _alertStyle = pw.TextStyle(
  font: pw.Font.helveticaBold(),
  fontSize: 10,
  color: _rgb(200, 50, 50),
);
final _reasonStyle = pw.TextStyle(
  font: pw.Font.helvetica(),
  fontSize: 10,
  color: _rgb(110, 110, 110),
);

pw.TextSpan _spanFor(InlineRun run) => pw.TextSpan(
      // A mid-line "•" has no glyph in the core font; the Latin-1
      // middot renders instead (leading bullets are drawn dots).
      text: run.text.replaceAll('•', '·'),
      style: run.bold ? _boldStyle : (run.italic ? _italicStyle : _bodyStyle),
    );

/// A bullet line with a DRAWN dot (the core Helvetica has no "•"
/// glyph — it renders a notdef box). Native draws the "• " as text
/// in its system font; the layout (dot, gap, wrapped text) matches.
pw.Widget _dotRow(String text, {required double width}) {
  return pw.SizedBox(
    width: width,
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 5),
          child: pw.Container(
            width: 4,
            height: 4,
            decoration: pw.BoxDecoration(
                shape: pw.BoxShape.circle, color: _rgb(66, 66, 66)),
          ),
        ),
        pw.SizedBox(width: 6),
        pw.Expanded(
          child: pw.RichText(
              text: pw.TextSpan(children: [
            for (final r in parseInlineRuns(text)) _spanFor(r)
          ])),
        ),
      ],
    ),
  );
}

/// The meta line under the title rule (native
/// ReportGenerator.kt:296-305): "Report Range: 30-Day Audit" OR
/// "Full Audit (N Days)" — the day-count parenthetical belongs to
/// Full Audit only — then the generated stamp. Native's separator
/// is "•" (U+2022); the pdf package's core Helvetica has no glyph
/// for it (renders a notdef box), so the separator here is the
/// Latin-1 middot — visually identical at 9pt.
String reportMetaLine(ReportSnapshot snapshot) {
  final rangeLabel = snapshot.last30Days ? '30-Day Audit' : 'Full Audit';
  // Native ReportGenerator renders the day-count parenthetical
  // UNCONDITIONALLY: "30-Day Audit (30 Days)" included.
  return 'Report Range: $rangeLabel (${snapshot.durationDays} Days) '
      '· Generated: ${formatPdfGenerated(snapshot.generationTimestampMs)}';
}

/// Builds the report PDF bytes. Mirrors native's page flow: summary
/// pages (Canvas-style manual pagination, since native draws with
/// absolute y and breaks at y > 780), then the Data Availability
/// section closing the LAST summary page (or a fresh one when
/// y > 720), then the two fixed charts pages.
Future<List<int>> buildReportPdfBytes(
  ReportSnapshot snapshot, {
  String? aiSummary,
  required bool isRawFallback,
  String? aiFailureReason,
}) async {
  final doc = pw.Document();
  final blocks = parseSummaryBlocks(effectiveSummaryText(snapshot,
      aiSummary: aiSummary, isRawFallback: isRawFallback));

  // Manual flow layout over A4 pages. Native draws text by BASELINE
  // (title baseline at y=50, rule at 62, meta baseline at 82); the
  // positions here are widget TOPS chosen to land the same
  // baselines (title top 28, rule 62, meta top 73), and the flow
  // cursor y tracks tops from there.
  final pages = <List<pw.Widget>>[];
  var current = <pw.Widget>[];
  var y = 28.0;
  void newPage({double startY = 39}) {
    pages.add(current);
    current = <pw.Widget>[];
    y = startY;
  }

  void place(pw.Widget w, double height) {
    current.add(pw.Positioned(
      left: _margin,
      top: y,
      child: pw.SizedBox(width: _contentWidth, child: w),
    ));
    y += height;
  }

  // Header (page 1 only in native).
  place(pw.Text('Tabs Clinical Audit Report', style: _titleStyle), 34);
  current.add(pw.Positioned(
    left: _margin,
    top: y,
    child: pw.Container(
        width: _contentWidth,
        decoration: const pw.BoxDecoration(
            border: pw.Border(top: pw.BorderSide(color: PdfColors.grey300, width: 1)))),
  ));
  y += 11;
  place(
    pw.Text(
      reportMetaLine(snapshot),
      style: _metaStyle,
    ),
    25,
  );

  if (isRawFallback) {
    // Native's banner leads with ⚠️, which the core font cannot
    // render; a drawn warning triangle + "!" stands in for it.
    current.add(pw.Positioned(
      left: _margin,
      top: y,
      child: pw.SizedBox(
        width: _contentWidth,
        height: 14,
        child: pw.Stack(children: [
          pw.Positioned(
            left: 0,
            top: 1,
            child: pw.CustomPaint(
              size: const PdfPoint(13, 12),
              painter: (canvas, size) {
                canvas
                  ..setFillColor(PdfColor.fromHex('#FFC107'))
                  ..moveTo(6.5, 0)
                  ..lineTo(13, 12)
                  ..lineTo(0, 12)
                  ..closePath()
                  ..fillPath();
              },
            ),
          ),
          pw.Positioned(
            left: 4.6,
            top: 4,
            child: pw.Text('!',
                style: pw.TextStyle(
                    font: pw.Font.helveticaBold(),
                    fontSize: 8,
                    color: _rgb(33, 33, 33))),
          ),
          pw.Positioned(
            left: 17,
            top: 1,
            child: pw.Text(
                'RAW DATA REPORT: AI ANALYSIS UNAVAILABLE AT GENERATION TIME',
                style: _alertStyle),
          ),
        ]),
      ),
    ));
    y += 18;
    if (aiFailureReason != null && aiFailureReason.isNotEmpty) {
      place(pw.Text('AI unavailable: $aiFailureReason', style: _reasonStyle),
          16);
    }
  }

  // Summary blocks with native wrapping heights: pdf's text layout
  // wraps at the same content width; each rendered line is 18pt
  // tall in native (drawFormattedLine step) / 20 for section lines.
  for (final block in blocks) {
    if (block is SectionBlock) {
      y += 12;
      final lines = _measureLines(block.text, _sectionStyle, _contentWidth);
      if (y > _bottomLimit) newPage();
      place(
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(block.text, style: _sectionStyle),
            pw.SizedBox(height: 2),
            pw.Container(width: 60, height: 2, color: _rgb(0, 102, 204)),
          ],
        ),
        lines * 20 + 16,
      );
    } else if (block is BulletBlock) {
      // Native checks the page break per wrapped LINE; a block
      // that cannot fit whole moves/splits at line granularity.
      for (final chunk in _fitChunks(block.text, _contentWidth - 25,
          () => _bottomLimit - y, () => _bottomLimit - 39)) {
        if (y > _bottomLimit) newPage();
        final lines = _measureLines(chunk, _bodyStyle, _contentWidth - 25);
        current.add(pw.Positioned(
          left: _margin + 15,
          top: y,
          child: _dotRow(chunk, width: _contentWidth - 15),
        ));
        y += lines * 18 + 6;
        if (y > _bottomLimit) newPage();
      }
    } else if (block is TextBlock) {
      if (block.text.trim().isEmpty) {
        y += 6;
        continue;
      }
      // Native renders model lines that start with "•" as plain
      // text at the margin; here the leading bullet is a drawn dot
      // (core-font glyph limit) with the text beside it.
      final isBulletLine = block.text.trimLeft().startsWith('•');
      final bodyText = isBulletLine
          ? block.text.trimLeft().substring(1).trimLeft()
          : block.text;
      final textWidth = isBulletLine ? _contentWidth - 10 : _contentWidth;
      for (final chunk in _fitChunks(bodyText, textWidth,
          () => _bottomLimit - y, () => _bottomLimit - 39)) {
        if (y > _bottomLimit) newPage();
        final lines = _measureLines(chunk, _bodyStyle, textWidth);
        if (isBulletLine) {
          current.add(pw.Positioned(
            left: _margin,
            top: y,
            child: _dotRow(chunk, width: _contentWidth),
          ));
        } else {
          place(
            pw.RichText(
                text: pw.TextSpan(children: [
              for (final r in parseInlineRuns(chunk)) _spanFor(r)
            ])),
            lines * 18 + 6,
          );
        }
        if (isBulletLine) y += lines * 18 + 6;
        if (y > _bottomLimit) newPage();
      }
    }
  }

  // Data Availability & Source Freshness.
  y += 20;
  if (y > 720) newPage();
  final availTop = y;
  place(pw.Text('Data Availability & Source Freshness', style: _sectionStyle),
      24);
  current.add(pw.Positioned(
    left: _margin,
    top: availTop + 22,
    child: pw.Container(
        width: _contentWidth,
        decoration: const pw.BoxDecoration(
            border: pw.Border(top: pw.BorderSide(color: PdfColors.grey300, width: 1)))),
  ));
  y += 6;
  for (final e in snapshot.sectionMetadata.entries) {
    if (y > _bottomLimit) newPage();
    current.add(pw.Positioned(
      left: _margin + 10,
      top: y,
      child: _dotRow(
          '${availabilityPdfLabel(e.key)}: ${availabilityStatusText(e.value)}',
          width: _contentWidth - 10),
    ));
    y += 15;
  }
  pages.add(current);

  for (final pageWidgets in pages) {
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat(595, _pageHeight),
      margin: pw.EdgeInsets.zero,
      build: (_) => pw.Stack(children: pageWidgets),
    ));
  }

  // Charts pages (fixed layout, native positions).
  doc.addPage(_chartsPage(
    title: 'Longitudinal Health Metrics & Charts',
    series: chartPage1Series(snapshot),
    withDisclaimer: false,
  ));
  doc.addPage(_chartsPage(
    title: 'Longitudinal Health Metrics & Charts (Cont.)',
    series: chartPage2Series(snapshot),
    withDisclaimer: true,
  ));

  return doc.save();
}

/// Splits [text] into word-boundary chunks whose estimated height
/// fits the space the caller reports: the first chunk gets
/// [firstHeight] points, later chunks [laterHeight]. Inline toggle
/// state restarts per chunk (native resets per raw line too; a
/// chunk boundary can only occur inside a very long single line).
List<String> _fitChunks(
  String text,
  double width,
  double Function() firstHeight,
  double Function() laterHeight,
) {
  int capacity(double heightPx) {
    final c = (heightPx / 18).floor();
    return c < 1 ? 1 : c;
  }

  if (_measureLines(text, _bodyStyle, width) <= capacity(firstHeight())) {
    return [text];
  }
  final chunks = <String>[];
  var rest = text;
  var first = true;
  while (rest.isNotEmpty) {
    final cap = capacity(first ? firstHeight() : laterHeight());
    if (_measureLines(rest, _bodyStyle, width) <= cap) {
      chunks.add(rest);
      break;
    }
    final words = rest.split(' ');
    var take = 0;
    var candidate = '';
    for (var i = 0; i < words.length; i++) {
      final next = candidate.isEmpty ? words[i] : '$candidate ${words[i]}';
      if (_measureLines(next, _bodyStyle, width) > cap && candidate.isNotEmpty) {
        break;
      }
      candidate = next;
      take = i + 1;
    }
    if (candidate.isEmpty) candidate = words.first;
    chunks.add(candidate);
    rest = words.skip(take == 0 ? 1 : take).join(' ');
    first = false;
  }
  return chunks;
}

/// Approximate line count for [text] at [width] under [style], using
/// the same greedy word wrap native's wrapText performs (character
/// widths from the real PDF font metrics via pw's text painter is
/// not exposed synchronously; Helvetica average-width estimation is
/// used only to decide page breaks, never rendered geometry).
int _measureLines(String text, pw.TextStyle style, double width) {
  final fontSize = style.fontSize ?? 11;
  // Helvetica average glyph width ≈ 0.52 × font size for mixed case.
  final charWidth = fontSize * 0.52;
  final maxChars = (width / charWidth).floor().clamp(1, 10000);
  var lines = 0;
  var currentLen = 0;
  for (final word in text.split(' ')) {
    final wlen = word.length;
    if (currentLen == 0) {
      currentLen = wlen;
    } else if (currentLen + 1 + wlen <= maxChars) {
      currentLen += 1 + wlen;
    } else {
      lines++;
      currentLen = wlen;
    }
    while (currentLen > maxChars) {
      lines++;
      currentLen -= maxChars;
    }
  }
  if (currentLen > 0 || lines == 0) lines++;
  return lines;
}

pw.Page _chartsPage({
  required String title,
  required List<ChartSeries> series,
  required bool withDisclaimer,
}) {
  final chartTops = [85.0, 255.0, 425.0, 595.0];
  return pw.Page(
    pageFormat: PdfPageFormat(595, _pageHeight),
    margin: pw.EdgeInsets.zero,
    build: (_) => pw.Stack(children: [
      pw.Positioned(
        left: _margin,
        top: 28,
        child: pw.Text(title, style: _titleStyle),
      ),
      pw.Positioned(
        left: _margin,
        top: 62,
        child: pw.Container(
            width: _contentWidth,
            decoration: const pw.BoxDecoration(
                border:
                    pw.Border(top: pw.BorderSide(color: PdfColors.grey300, width: 1)))),
      ),
      for (var i = 0; i < series.length; i++)
        pw.Positioned(
          left: _margin,
          top: chartTops[i],
          child: _chartWidget(series[i]),
        ),
      if (withDisclaimer) ...[
        pw.Positioned(
          left: _margin,
          top: 650,
          child: pw.Container(
              width: _contentWidth,
              decoration: const pw.BoxDecoration(
                  border: pw.Border(
                      top: pw.BorderSide(color: PdfColors.grey300, width: 1)))),
        ),
        pw.Positioned(
          left: _margin,
          top: 666,
          child: pw.SizedBox(
            width: _contentWidth,
            child: pw.Text(
              'Disclaimer: This report is generated by AI based on personal logs and should be reviewed by a medical professional.',
              style: _metaStyle,
            ),
          ),
        ),
      ],
    ]),
  );
}

pw.Widget _chartWidget(ChartSeries series) {
  final chartTitleStyle = pw.TextStyle(
    font: pw.Font.helveticaBold(),
    fontSize: 11,
    color: _rgb(33, 33, 33),
  );
  if (series.points.length < 2) {
    return pw.SizedBox(
      width: _contentWidth,
      height: 140,
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(height: 6),
          pw.Text(series.title, style: chartTitleStyle),
          pw.SizedBox(height: 40),
          pw.Padding(
            padding: const pw.EdgeInsets.only(left: 55),
            child: pw.Text('Not enough data to display chart',
                style: pw.TextStyle(
                    font: pw.Font.helveticaOblique(),
                    fontSize: 9,
                    color: _rgb(128, 128, 128))),
          ),
        ],
      ),
    );
  }
  final range = chartYRange(series);
  final color = PdfColor.fromHex(series.colorHex);
  // Native geometry inside the 140pt slot: title at top, chart plot
  // from x=35 with width 460, plot height 100 (25..125 in slot
  // space), x labels under the plot.
  const plotLeft = 35.0;
  const plotTop = 25.0;
  const plotW = _contentWidth - 45;
  const plotH = 100.0;
  double px(int i) =>
      plotLeft +
      (series.points.length > 1 ? i / (series.points.length - 1) : 0) * plotW;
  final labelStyle = pw.TextStyle(
      font: pw.Font.helvetica(), fontSize: 8, color: _rgb(128, 128, 128));
  final xLabelStyle = pw.TextStyle(
      font: pw.Font.helvetica(), fontSize: 7, color: _rgb(128, 128, 128));

  // X labels: native's candidate step + no-collision rule (4pt
  // gap), widths estimated at 7pt Helvetica (≈4pt per glyph).
  final xLabels = <pw.Widget>[];
  var lastRight = -double.maxFinite;
  for (final idx in chartXLabelCandidates(series.points.length)) {
    final label = series.points[idx].$1;
    final w = label.length * 4.0;
    final cx = px(idx);
    if (cx - w / 2 > lastRight + 4) {
      xLabels.add(pw.Positioned(
        left: cx - w / 2,
        top: plotTop + plotH + 3,
        child: pw.Text(label, style: xLabelStyle),
      ));
      lastRight = cx + w / 2;
    }
  }

  return pw.SizedBox(
    width: _contentWidth,
    height: 140,
    child: pw.Stack(children: [
      pw.Positioned(
        left: 0,
        top: 6,
        child: pw.Text(series.title, style: chartTitleStyle),
      ),
      // Y labels (native formats "%.0f" + unit): native draws
      // them LEFT-aligned at the chart's x (the page margin),
      // extending right — long values ("2205 kcal", "119 mmHg")
      // reach into the plot's left edge, exactly as the gold
      // specimen shows. No width box, so they never wrap or clip.
      for (var i = 0; i <= 2; i++)
        pw.Positioned(
          left: 0,
          top: plotTop + plotH * (1 - i / 2) - 4,
          child: pw.Text(
            '${(range.minY + (i / 2) * (range.maxY - range.minY)).toStringAsFixed(0)}${series.unit}',
            style: labelStyle,
          ),
        ),
      pw.Positioned(
        left: 0,
        top: plotTop,
        child: pw.SizedBox(
          width: _contentWidth,
          height: plotH,
          child: pw.CustomPaint(
            size: const PdfPoint(_contentWidth, plotH),
            painter: (canvas, size) =>
                _paintChart(canvas, size, series, range, color),
          ),
        ),
      ),
      ...xLabels,
    ]),
  );
}

/// Paints grid, area fill, line and points. The pdf package calls
/// CustomPaint painters with the origin at the widget's BOTTOM-left
/// (standard PDF coordinates, y up); the plot occupies the full
/// height with x=35..35+460 in local space.
void _paintChart(
  PdfGraphics canvas,
  PdfPoint size,
  ChartSeries series,
  ({double minY, double maxY}) range,
  PdfColor color,
) {
  const chartX = 35.0;
  final chartW = size.x - 45;
  final chartH = size.y;
  final minY = range.minY;
  final yRange = range.maxY - range.minY;

  final gridColor = PdfColor(235 / 255, 235 / 255, 235 / 255);
  canvas.setStrokeColor(gridColor);
  canvas.setLineWidth(1);
  for (var i = 0; i <= 2; i++) {
    final gy = chartH * (i / 2);
    canvas.drawLine(chartX, gy, chartX + chartW, gy);
    canvas.strokePath();
  }

  double px(int i) =>
      chartX + (series.points.length > 1 ? i / (series.points.length - 1) : 0) * chartW;
  double py(double v) => chartH * ((v - minY) / yRange);

  // Area fill (native alpha 25).
  canvas.setFillColor(PdfColor(color.red, color.green, color.blue, 0.1));
  canvas.moveTo(px(0), 0);
  for (var i = 0; i < series.points.length; i++) {
    canvas.lineTo(px(i), py(series.points[i].$2));
  }
  canvas.lineTo(px(series.points.length - 1), 0);
  canvas.closePath();
  canvas.fillPath();

  // Line.
  canvas.setStrokeColor(color);
  canvas.setLineWidth(1.5);
  canvas.moveTo(px(0), py(series.points[0].$2));
  for (var i = 1; i < series.points.length; i++) {
    canvas.lineTo(px(i), py(series.points[i].$2));
  }
  canvas.strokePath();

  // Points (native: only when ≤ 42 points).
  if (series.points.length <= 42) {
    for (var i = 0; i < series.points.length; i++) {
      canvas.setFillColor(PdfColors.white);
      canvas.drawEllipse(px(i), py(series.points[i].$2), 2.5, 2.5);
      canvas.fillPath();
      canvas.setFillColor(color);
      canvas.drawEllipse(px(i), py(series.points[i].$2), 1.5, 1.5);
      canvas.fillPath();
    }
  }
}
