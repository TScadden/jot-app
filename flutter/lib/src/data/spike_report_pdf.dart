import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/heart_data.dart';

/// Round 67 — Spike Review PDF export, the pure-Dart port of native
/// `util/PdfExporter.exportSpikesToPdf` (the last piece deferred in
/// Round 25: the Lab then had no PDF bridge; Round 66 landed the
/// pure-Dart `pdf`/`printing` stack for Progress Reports and this
/// round reuses it).
///
/// Native exporter semantics, traced from PdfExporter.kt — NOTE the
/// exporter runs its OWN detection, different from both the Heart
/// card (5-minute window) and the Spike Review screen (3-minute gap
/// rule, `detectSpikeEvents` in heart_data.dart):
/// - An event is a run of samples >= 100 bpm. A sample starts a new
///   event when it lands strictly AFTER the running event's end,
///   where the end is the last >= 100 sample's time + 5 minutes.
/// - Duration = max(1, (lastSpikeSampleMs - startMs) ~/ 60000).
/// - Summary statistics come from ALL of the day's readings: peak =
///   max bpm, baseline = the p10 value (sorted index
///   `(size * 0.10).toInt()`, clamped at 0 — the same rule
///   heart_data.dart's `heartBaselineP10` uses), delta = peak - p10.
/// - No events -> no PDF at all (native shows a Toast, "No spike
///   events to export"; the screen mirrors that with a SnackBar).
///
/// Founder rules win over native where they conflict:
/// - A 0 bpm sample is a failed read. Native's exporter does not
///   filter zeros (they can only drag the p10 down — they can never
///   start an event at >= 100). Every input here runs through
///   [validHrSamples] first, exactly like the rest of the Heart
///   surface, so a failed read never reaches the summary.
///
/// Divergences from native, all forced by the Flutter stack and
/// flagged in the round report:
/// - Saved copy: native writes to Downloads via MediaStore. The Lab
///   has no clean Downloads path (the R66 divergence), so the saved
///   copy lands in the app documents directory and the same bytes
///   are offered through the system share sheet.
/// - Glyphs: the pdf package's core Helvetica has no "•" or "➝"
///   glyph. Bullets use the R66 substitution ("·", Latin-1) and the
///   delta line's arrow renders as "->".
/// - Pagination: native draws ONE page and anything past y=842 is
///   silently clipped. This port paginates instead (29 rows on the
///   first page — native's own geometry — then 38 per continuation
///   page) so no clinician-facing event is ever dropped silently.

// ── Exporter event model ─────────────────────────────────────────

class SpikePdfEvent {
  final int startTimeMs;
  final int peakBpm;
  final int durationMins;

  const SpikePdfEvent({
    required this.startTimeMs,
    required this.peakBpm,
    required this.durationMins,
  });

  @override
  bool operator ==(Object other) =>
      other is SpikePdfEvent &&
      other.startTimeMs == startTimeMs &&
      other.peakBpm == peakBpm &&
      other.durationMins == durationMins;

  @override
  int get hashCode => Object.hash(startTimeMs, peakBpm, durationMins);
}

/// The exporter's event detection (see the file header). Input may
/// be raw samples; valid-filtering and sorting happen here.
List<SpikePdfEvent> detectSpikePdfEvents(List<HrSample> samples) {
  final valid = validHrSamples(samples);
  final events = <SpikePdfEvent>[];
  var inEvent = false;
  var startMs = 0;
  var peak = 0;
  var endMs = 0; // last >= 100 sample + 5 minutes, as native tracks it

  void closeEvent() {
    // Native: maxOf(1, ((endMs - 300000 - start) / 60000).toInt()) —
    // endMs - 300000 is the last spike sample's own timestamp.
    final raw = ((endMs - 300000 - startMs) / 60000).toInt();
    events.add(SpikePdfEvent(
      startTimeMs: startMs,
      peakBpm: peak,
      durationMins: raw > 1 ? raw : 1,
    ));
  }

  for (final s in valid) {
    if (s.bpm >= 100) {
      if (!inEvent || s.timeMs > endMs) {
        if (inEvent) closeEvent();
        inEvent = true;
        startMs = s.timeMs;
        peak = s.bpm;
      } else if (s.bpm > peak) {
        peak = s.bpm;
      }
      endMs = s.timeMs + 300000;
    }
  }
  if (inEvent) closeEvent();
  return events;
}

/// Summary block values (native PdfExporter section 2). Null when
/// there are no valid readings at all.
({int peakBpm, int baselineP10, int deltaBpm, int totalEvents})?
    spikePdfSummary(List<HrSample> samples, List<SpikePdfEvent> events) {
  final valid = validHrSamples(samples);
  if (valid.isEmpty) return null;
  final peak = heartPeakBpm(valid);
  final p10 = heartBaselineP10(valid);
  if (peak == null || p10 == null) return null;
  return (
    peakBpm: peak,
    baselineP10: p10,
    deltaBpm: peak - p10,
    totalEvents: events.length,
  );
}

// ── Pagination ───────────────────────────────────────────────────

/// Rows that fit native's first-page geometry: first row baseline
/// y=250, 20pt per row, page height 842 -> 29 rows.
const int spikePdfFirstPageRows = 29;

/// Continuation pages start at the top margin (table header at
/// y=60), so they fit more rows: header block ends at y=95, rows
/// at 20pt -> 38 rows before y=842.
const int spikePdfContinuationPageRows = 38;

/// Splits [events] into pages following the geometry above. The
/// first page also carries the title/summary block.
List<List<SpikePdfEvent>> paginateSpikePdfEvents(
    List<SpikePdfEvent> events) {
  if (events.isEmpty) return const [];
  final pages = <List<SpikePdfEvent>>[];
  var rest = events;
  pages.add(rest.take(spikePdfFirstPageRows).toList());
  rest = rest.skip(spikePdfFirstPageRows).toList();
  while (rest.isNotEmpty) {
    pages.add(rest.take(spikePdfContinuationPageRows).toList());
    rest = rest.skip(spikePdfContinuationPageRows).toList();
  }
  return pages;
}

// ── PDF rendering ────────────────────────────────────────────────

String _pad2(int v) => v.toString().padLeft(2, '0');

/// Native subtitle/exported stamp: `yyyy-MM-dd HH:mm`.
String spikePdfStamp(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-${_pad2(t.month)}-${_pad2(t.day)} '
    '${_pad2(t.hour)}:${_pad2(t.minute)}';

/// Native file display name: `Tabs <date> HR spikes` (the Flutter
/// saved copy adds the .pdf extension, as R66's saved copies do).
String spikePdfFileName(String dateStr) => 'Tabs $dateStr HR spikes.pdf';

Future<Uint8List> buildSpikeReportPdfBytes({
  required List<HrSample> samples,
  required String dateStr,
  required DateTime exportedAt,
}) async {
  final events = detectSpikePdfEvents(samples);
  final summary = spikePdfSummary(samples, events);
  final pages = paginateSpikePdfEvents(events);

  final ink = PdfColor.fromInt(0xFF212121); // native rgb(33,33,33)
  final gray = PdfColor.fromInt(0xFF757575); // native rgb(117,117,117)
  final lineColor = PdfColor.fromInt(0xFFE0E0E0); // native rgb(224)

  final titleStyle = pw.TextStyle(
    font: pw.Font.helveticaBold(),
    fontSize: 24,
    color: ink,
  );
  final subTitleStyle = pw.TextStyle(
    font: pw.Font.helveticaOblique(),
    fontSize: 12,
    color: gray,
  );
  final headerStyle = pw.TextStyle(
    font: pw.Font.helveticaBold(),
    fontSize: 14,
    color: ink,
  );
  final textStyle = pw.TextStyle(
    font: pw.Font.helvetica(),
    fontSize: 14,
    color: ink,
  );

  pw.Widget tableHeader() => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Row(children: [
            pw.SizedBox(
                width: 200, child: pw.Text('Time', style: headerStyle)),
            pw.SizedBox(
                width: 200, child: pw.Text('Duration', style: headerStyle)),
            pw.Text('Peak BPM', style: headerStyle),
          ]),
          pw.SizedBox(height: 10),
          pw.Container(height: 1, color: lineColor),
          pw.SizedBox(height: 25),
        ],
      );

  // Fixed 20pt pitch, native's baseline-to-baseline row advance.
  pw.Widget eventRow(SpikePdfEvent e) => pw.SizedBox(
        height: 20,
        child: pw.Row(children: [
          pw.SizedBox(
              width: 200,
              child: pw.Text(formatHrTime(e.startTimeMs), style: textStyle)),
          pw.SizedBox(
              width: 200,
              child: pw.Text(
                  e.durationMins > 1
                      ? '${e.durationMins} mins'
                      : '1 min',
                  style: textStyle)),
          pw.Text('${e.peakBpm} bpm', style: textStyle),
        ]),
      );

  final doc = pw.Document();
  for (var i = 0; i < pages.length; i++) {
    final first = i == 0;
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat(595, 842),
      margin: const pw.EdgeInsets.only(left: 50, right: 50),
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.SizedBox(height: 36),
          if (first) ...[
            pw.Text('Tabs HR Spikes Report', style: titleStyle),
            pw.SizedBox(height: 24),
            pw.Text(
              'Date: $dateStr | Exported: ${spikePdfStamp(exportedAt)}',
              style: subTitleStyle,
            ),
            pw.SizedBox(height: 35),
            if (summary != null) ...[
              pw.Text('SUMMARY', style: headerStyle),
              pw.SizedBox(height: 10),
              pw.Container(height: 1, color: lineColor),
              pw.SizedBox(height: 20),
              // Native bullet pitch is 18pt baseline-to-baseline.
              pw.SizedBox(
                  height: 18,
                  child: pw.Text('· Peak Heart Rate: ${summary.peakBpm} bpm',
                      style: textStyle)),
              pw.SizedBox(
                  height: 18,
                  child: pw.Text(
                      '· Total Spike Events: ${summary.totalEvents} events',
                      style: textStyle)),
              pw.Text(
                  '· Max Jump (Delta): +${summary.deltaBpm} bpm '
                  '(Baseline: ${summary.baselineP10} bpm -> '
                  'Peak: ${summary.peakBpm} bpm)',
                  style: textStyle),
              pw.SizedBox(height: 30),
            ],
          ] else ...[
            pw.Text('Tabs HR Spikes Report (continued)',
                style: headerStyle),
            pw.SizedBox(height: 24),
          ],
          tableHeader(),
          for (final e in pages[i]) eventRow(e),
        ],
      ),
    ));
  }
  return doc.save();
}
