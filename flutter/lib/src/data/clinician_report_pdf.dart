import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:tabs_lab/src/data/clinician_report.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/progress_report_pdf.dart'
    show availabilityPdfLabel, availabilityStatusText;

/// Phase 1, item 3 — the one-page clinician renderer (spec
/// §4). Fixed layout, exactly ONE page by construction: zones
/// have capped heights (spec §4.4), reserved zones (Z6 salt &
/// fluids — item 4 has not shipped; Z7 lean test — item 6 is
/// blocked pending clinician review, Juno Item 3 · R1) are
/// ABSENT: no heading, no box, no placeholder.
///
/// The renderer reads ONLY its [ClinicianReportData] — no
/// store, no backend (spec §5.1). All printed text flows through
/// [clinicianPageLines], the page's line model, so the exact
/// strings on the page are testable without a PDF parser; the
/// renderer draws those lines and nothing else (besides the Z3
/// chart and its axis labels).

/// One line of the page, tagged with its zone (Z1–Z8).
typedef ClinicianLine = ({String zone, String text});

String _rangeLabel(ReportSnapshot s) =>
    s.last30Days ? 'Last 30 days' : 'Last 180 days';

String _chartDateLabel(String yyyyMmDd) {
  final d = DateTime.tryParse(yyyyMmDd);
  if (d == null) return yyyyMmDd;
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[d.month - 1]} ${d.day}';
}

/// The full ordered text content of the clinician page.
List<ClinicianLine> clinicianPageLines(ClinicianReportData data) {
  final s = data.snapshot;
  final lines = <ClinicianLine>[];

  // Z1 — header.
  lines.add((zone: 'Z1', text: clinicianReportTitle));
  lines.add((
    zone: 'Z1',
    text: clinicianMetaLine(
      rangeLabel: _rangeLabel(s),
      days: s.durationDays,
      generatedStamp: formatPdfGenerated(s.generationTimestampMs),
    ),
  ));
  final patient = <String>[
    if (s.userAge > 0) 'Age ${s.userAge}',
    if (s.userGender.isNotEmpty) s.userGender,
    if (s.userHeightIn > 0)
      'Height ${(s.userHeightIn ~/ 12)} ft ${(s.userHeightIn % 12).round()} in',
    if (s.userWeightLbs > 0)
      'Weight ${s.userWeightLbs == s.userWeightLbs.roundToDouble() ? s.userWeightLbs.round() : s.userWeightLbs.toStringAsFixed(1)} lbs',
    if (s.conditions.isNotEmpty) 'Conditions: ${s.conditions.join(', ')}',
  ];
  if (patient.isNotEmpty) {
    lines.add((zone: 'Z1', text: patient.join(' · ')));
  }

  // Z2 — medications (the verified active list, R5).
  lines.add((zone: 'Z2', text: clinicianHeadingMedications));
  if (s.medications.isEmpty) {
    lines.add((zone: 'Z2', text: clinicianNoMedications));
  } else {
    final shown = s.medications.take(clinicianMedicationCap).toList();
    for (final m in shown) {
      lines.add((zone: 'Z2', text: '${m.name} ${m.dose} (${m.frequency})'));
    }
    if (s.medications.length > shown.length) {
      lines.add((
        zone: 'Z2',
        text: clinicianOverflowLine(s.medications.length - shown.length),
      ));
    }
  }

  // Z3 — Daily Score (stored scores only; coverage always).
  lines.add((zone: 'Z3', text: clinicianHeadingDailyScore));
  if (data.scoredDays == 0) {
    lines.add((zone: 'Z3', text: 'Not enough data to display chart'));
  } else {
    final latest = data.dailyScoreSeries.last;
    if (data.scoredDays == 1) {
      lines.add((
        zone: 'Z3',
        text:
            'Latest score: ${latest.$2} on ${_chartDateLabel(latest.$1)}',
      ));
    } else {
      final avg = data.dailyScoreSeries.fold<int>(0, (a, e) => a + e.$2) /
          data.scoredDays;
      lines.add((
        zone: 'Z3',
        text:
            'Latest score: ${latest.$2} on ${_chartDateLabel(latest.$1)} · Average over scored days: ${clinicianAverageText(avg)}',
      ));
    }
  }
  lines.add((
    zone: 'Z3',
    text: clinicianScoreCoverage(data.scoredDays, data.rangeDays),
  ));

  // Z4 — flare / migraine / symptom summary.
  lines.add((zone: 'Z4', text: clinicianHeadingFlareMigraine));
  if (data.flareDays == 0) {
    lines.add((zone: 'Z4', text: clinicianNoFlareDays));
  } else {
    lines.add((zone: 'Z4', text: 'Flare days: ${data.flareDays}'));
    final mix = [
      for (final sev in clinicianFlareSeverities)
        if ((data.flareSeverityMix[sev] ?? 0) > 0)
          '$sev ${data.flareSeverityMix[sev]}',
    ];
    if (mix.isNotEmpty) {
      lines.add((zone: 'Z4', text: mix.join(' · ')));
    }
  }
  if (data.migraineCount == 0) {
    lines.add((zone: 'Z4', text: clinicianNoMigraineEntries));
  } else {
    lines.add((zone: 'Z4', text: 'Migraine entries: ${data.migraineCount}'));
  }
  if (data.topCategories.isNotEmpty) {
    lines.add((
      zone: 'Z4',
      text:
          'Most logged categories: ${data.topCategories.map((c) => '${c.name} (${c.count})').join(', ')}',
    ));
  }

  // Z5 — medication changes (absent entirely when there are no
  // change lines: no heading, no placeholder — spec §4.3).
  if (data.medChanges.isNotEmpty) {
    lines.add((zone: 'Z5', text: clinicianHeadingMedChanges));
    final shown = data.medChanges.take(clinicianChangeCap).toList();
    for (final change in shown) {
      lines.add((
        zone: 'Z5',
        text:
            '${change.dateLabel} — ${change.label} · ${change.captured ? clinicianProvenanceCaptured : clinicianProvenanceDeclared}',
      ));
      final before = change.beforeWindow;
      final after = change.afterWindow;
      if (before != null && after != null) {
        lines.add((
          zone: 'Z5',
          text:
              'Average Daily Score, 14 days before: ${clinicianAverageText(before.average)} · ${before.scoredDays} scored days. Average Daily Score, 14 days after: ${clinicianAverageText(after.average)} · ${after.scoredDays} scored days.',
        ));
      }
    }
    if (data.medChanges.length > shown.length) {
      lines.add((
        zone: 'Z5',
        text: clinicianOverflowLine(data.medChanges.length - shown.length),
      ));
    }
  }

  // Z6 — salt & fluids: ABSENT. Item 4 (timestamped intake) has
  // not shipped, so the source feature does not exist; per
  // §4.3 the zone is omitted entirely (no heading, no target
  // line, no zeros). S10 renders only when Z6 does.
  // Z7 — latest lean test: ABSENT. Item 6 is blocked pending
  // clinician review (Juno Item 6 · R1); no placeholder.

  // Z8 — footer.
  final unavailable = [
    for (final e in s.sectionMetadata.entries)
      if (e.value.status != DataSourceStatus.success)
        '${availabilityPdfLabel(e.key)}: ${availabilityStatusText(e.value)}',
  ];
  if (unavailable.isNotEmpty) {
    lines.add((zone: 'Z8', text: 'Data availability: ${unavailable.join('; ')}'));
  }
  lines.add((zone: 'Z8', text: clinicianDisclaimer));
  lines.add((zone: 'Z8', text: 'Generated by Tabs · ${_rangeLabel(s)}'));
  return lines;
}

// ── Rendering ────────────────────────────────────────────────────

PdfColor _rgb(int r, int g, int b) => PdfColor(r / 255, g / 255, b / 255);

// Fonts: Juno's verbatim strings include the em dash (S9, and
// the Z5 line separator), which the pdf package's built-in
// Helvetica cannot encode — it silently renders as a missing-
// glyph box. The clinician renderer therefore embeds Roboto
// (regular + bold, app assets, Apache-2.0) so every mandated
// character prints. The page loads the fonts on the production
// path (loadClinicianPdfFonts) and passes them in; Helvetica
// remains only as a load-failure fallback. The renderer itself
// never touches rootBundle, which keeps it hermetic in tests.
class ClinicianPdfFonts {
  final pw.Font regular;
  final pw.Font bold;
  const ClinicianPdfFonts(this.regular, this.bold);

  pw.TextStyle title() => pw.TextStyle(
        font: bold,
        fontSize: 22,
        color: _rgb(33, 33, 33),
      );
  pw.TextStyle heading() => pw.TextStyle(
        font: bold,
        fontSize: 13,
        color: _rgb(0, 102, 204),
      );
  pw.TextStyle body() => pw.TextStyle(
        font: regular,
        fontSize: 10.5,
        color: _rgb(66, 66, 66),
      );
  pw.TextStyle meta() => pw.TextStyle(
        font: regular,
        fontSize: 9,
        color: _rgb(128, 128, 128),
      );
  pw.TextStyle footer() => pw.TextStyle(
        font: regular,
        fontSize: 8.5,
        color: _rgb(128, 128, 128),
      );
}

/// Builds the embedded-font set from raw TTF bytes.
ClinicianPdfFonts clinicianPdfFontsFromBytes(
        Uint8List regularBytes, Uint8List boldBytes) =>
    ClinicianPdfFonts(
      pw.Font.ttf(ByteData.sublistView(regularBytes)),
      pw.Font.ttf(ByteData.sublistView(boldBytes)),
    );

ClinicianPdfFonts? _loadedClinicianFonts;
bool _clinicianFontsLoadAttempted = false;

/// Production font load: Roboto from the app assets, cached.
/// Returns null when the assets cannot be read, in which case
/// the renderer falls back to Helvetica.
Future<ClinicianPdfFonts?> loadClinicianPdfFonts() async {
  if (_clinicianFontsLoadAttempted) return _loadedClinicianFonts;
  _clinicianFontsLoadAttempted = true;
  try {
    final regularData =
        await rootBundle.load('assets/fonts/Roboto-Regular.ttf');
    final boldData = await rootBundle.load('assets/fonts/Roboto-Bold.ttf');
    _loadedClinicianFonts = ClinicianPdfFonts(
      pw.Font.ttf(regularData),
      pw.Font.ttf(boldData),
    );
  } catch (_) {
    _loadedClinicianFonts = null;
  }
  return _loadedClinicianFonts;
}

final _helveticaFonts =
    ClinicianPdfFonts(pw.Font.helvetica(), pw.Font.helveticaBold());

/// The Z3 score chart: a calendar-continuous line over the
/// range's days. Unscored days BREAK the line — no interpolation
/// across a gap (spec §4.2 Z3). Captured medication-change days
/// carry a marker tick (G3).
pw.Widget _scoreChart(ClinicianReportData data, pw.TextStyle metaStyle) {
  final range = data.range;
  final dayKeys = range.dayKeys;
  final scores = data.scoreMap;
  final markerDays = {
    for (final c in data.medChanges)
      if (c.captured) dateStrOf(c.day),
  };
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(
            width: 24,
            height: 110,
            child: pw.Column(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('100', style: metaStyle),
                pw.Text('50', style: metaStyle),
                pw.Text('0', style: metaStyle),
              ],
            ),
          ),
          pw.Expanded(
            child: pw.SizedBox(
              height: 110,
              child: pw.CustomPaint(
                size: const PdfPoint(481, 110),
                painter: (PdfGraphics canvas, PdfPoint size) {
            const left = 2.0;
            const right = 6.0;
            const top = 6.0;
            const bottom = 6.0;
            final plotW = size.x - left - right;
            final plotH = size.y - top - bottom;
            double xFor(int i) =>
                left + (dayKeys.length <= 1 ? 0 : plotW * i / (dayKeys.length - 1));
            double yFor(int v) => bottom + plotH * (v / 100);

            // Gridlines at 0 / 50 / 100 (labels in the widget
            // tree beside the plot).
            canvas
              ..setStrokeColor(_rgb(220, 220, 220))
              ..setLineWidth(0.5);
            for (final gv in [0, 50, 100]) {
              final y = yFor(gv);
              canvas
                ..moveTo(left, y)
                ..lineTo(size.x - right, y)
                ..strokePath();
            }
            // Change markers.
            canvas.setStrokeColor(_rgb(230, 126, 34));
            canvas.setLineWidth(0.8);
            for (var i = 0; i < dayKeys.length; i++) {
              if (!markerDays.contains(dayKeys[i])) continue;
              final x = xFor(i);
              canvas
                ..moveTo(x, bottom)
                ..lineTo(x, bottom + 8)
                ..strokePath();
            }
            // Gap-broken polyline + points.
            canvas.setStrokeColor(_rgb(0, 102, 204));
            canvas.setLineWidth(1.2);
            int? prevIndex;
            int? prevValue;
            for (var i = 0; i < dayKeys.length; i++) {
              final v = scores[dayKeys[i]];
              if (v == null || v <= 0) {
                prevIndex = null;
                prevValue = null;
                continue;
              }
              if (prevIndex != null && prevValue != null && i == prevIndex + 1) {
                canvas
                  ..moveTo(xFor(prevIndex), yFor(prevValue))
                  ..lineTo(xFor(i), yFor(v))
                  ..strokePath();
              }
              canvas
                ..setFillColor(_rgb(0, 102, 204))
                ..drawEllipse(xFor(i), yFor(v), 1.8, 1.8)
                ..fillPath()
                ..setStrokeColor(_rgb(0, 102, 204));
              prevIndex = i;
              prevValue = v;
            }
                },
              ),
            ),
          ),
        ],
      ),
      pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(_chartDateLabel(dayKeys.first), style: metaStyle),
          pw.Text(_chartDateLabel(dayKeys.last), style: metaStyle),
        ],
      ),
    ],
  );
}

/// Builds the one-page clinician PDF bytes from [data] alone.
Future<List<int>> buildClinicianPdfBytes(ClinicianReportData data,
    {ClinicianPdfFonts? fonts}) async {
  final fonts0 = fonts ?? _helveticaFonts;
  final doc = pw.Document();
  final lines = clinicianPageLines(data);
  List<String> zone(String z) =>
      [for (final l in lines) if (l.zone == z) l.text];

  pw.Widget zoneBlock(String z, {bool chart = false}) {
    final texts = zone(z);
    if (texts.isEmpty) return pw.SizedBox();
    return pw.Padding(
      padding: const pw.EdgeInsets.only(top: 10),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(texts.first, style: fonts0.heading()),
          pw.SizedBox(height: 3),
          if (chart) _scoreChart(data, fonts0.meta()),
          for (final t in texts.skip(1))
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 2),
              child: pw.Text(t, style: fonts0.body()),
            ),
        ],
      ),
    );
  }

  final z1 = zone('Z1');
  doc.addPage(
    pw.Page(
      pageFormat: const PdfPageFormat(595, 842, marginAll: 45),
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(z1[0], style: fonts0.title()),
          pw.SizedBox(height: 4),
          pw.Container(height: 1.2, color: _rgb(0, 102, 204)),
          pw.SizedBox(height: 4),
          pw.Text(z1[1], style: fonts0.meta()),
          if (z1.length > 2) ...[
            pw.SizedBox(height: 3),
            pw.Text(z1[2], style: fonts0.body()),
          ],
          zoneBlock('Z2'),
          zoneBlock('Z3', chart: data.scoredDays >= 2),
          zoneBlock('Z4'),
          zoneBlock('Z5'),
          pw.Spacer(),
          pw.Container(height: 0.7, color: _rgb(200, 200, 200)),
          pw.SizedBox(height: 4),
          for (final t in zone('Z8'))
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 2),
              child: pw.Text(t, style: fonts0.footer()),
            ),
        ],
      ),
    ),
  );
  return doc.save();
}
