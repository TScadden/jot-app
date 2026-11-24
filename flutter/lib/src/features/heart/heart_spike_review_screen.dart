import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/heart_data.dart';
import 'package:tabs_lab/src/data/spike_report_pdf.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 25 — Spike Review, port of native `HeartSpikeReviewScreen.kt`.
///
/// Same data as the Heart tab (the selected date's intraday series,
/// passed in — native shares the FitbitViewModel state the same way).
/// Detection is the REVIEW screen's own algorithm (3-minute gap rule,
/// see `detectSpikeEvents` in heart_data.dart) — its count can differ
/// from the Heart card's 5-minute-window count on identical data,
/// exactly as in native.
///
/// Round 67 — the top-bar PDF download action deferred in Round 25
/// is now built on the Round 66 pure-Dart PDF stack:
/// `spike_report_pdf.dart` ports native `PdfExporter.exportSpikesToPdf`
/// (including the exporter's OWN event detection, which differs from
/// this screen's). The saved copy lands in the app documents
/// directory (the R66 divergence — native writes to Downloads via
/// MediaStore) and the same bytes are offered via the share sheet
/// from the saved SnackBar's Share action.
///
/// Juno copy ruling (JUNO-COPY.md §4, BINDING, Nov 24, 2026) — the
/// detail-unavailable line for a day whose series is empty. Verbatim;
/// the only substitution anywhere in §4 is the stored integer in
/// [spikeReviewStoredCountLine].
const spikeReviewDetailUnavailableLine =
    "Reading-by-reading detail isn't available for this day, so there's no list to show here.";

/// Juno §4 line 1 — the stored spike count, plain integer, no other
/// substitution.
String spikeReviewStoredCountLine(int spikeCount) =>
    'Spike count saved for this day: $spikeCount';

/// Founder rule: samples arrive already valid-filtered by the caller,
/// and every derivation here re-filters (bpm ≤ 0 never renders).
class HeartSpikeReviewScreen extends StatefulWidget {
  final List<HrSample> samples;

  /// The rendered Heart day this review was opened from (Heart
  /// store-first fix): when the day's data is a stored summary with
  /// no intraday series, the summary's spike count rides here so
  /// the review can show the stored count instead of wording an
  /// empty list as an all-clear. Also passed when a series exists
  /// (the count then agrees with detection by construction and is
  /// unused). Null when the caller holds no stored summary for the
  /// date — the review then renders the no-count detail-unavailable
  /// variant for an empty series (Juno §4).
  final HeartDayData? heartData;

  /// The stored summary's spike count for [dateStr], when the
  /// caller holds one (see [heartData]). Kept as a separate scalar
  /// so tests and future callers can state the stored truth without
  /// building a full [HeartDayData].
  final int? storedSpikeCount;

  /// The selected date (`yyyy-MM-dd`) the samples belong to — native
  /// passes `state.selectedHeartRateDate` to the exporter the same
  /// way. Null in tests/previews: the export then derives the date
  /// from the first valid sample (or today when there are none).
  final String? dateStr;

  /// Test seams (Round 66 pattern): production saves into the app
  /// documents directory and shares via Printing.sharePdf.
  final Future<String> Function(List<int> bytes, String fileName)?
      savePdf;
  final Future<void> Function(List<int> bytes, String fileName)?
      sharePdf;

  /// Test seam for the PDF's "Exported:" stamp.
  final DateTime Function()? now;

  const HeartSpikeReviewScreen({
    super.key,
    required this.samples,
    this.dateStr,
    this.heartData,
    this.storedSpikeCount,
    this.savePdf,
    this.sharePdf,
    this.now,
  });

  /// The stored spike count that governs the empty-series state:
  /// the explicit scalar wins, then the handed-in day's stored
  /// summary (its stored count, or its series-derived card count
  /// when the day was built from a stored row).
  int? get effectiveStoredSpikeCount =>
      storedSpikeCount ?? heartData?.storedSpikeCount;

  @override
  State<HeartSpikeReviewScreen> createState() =>
      _HeartSpikeReviewScreenState();
}

class _HeartSpikeReviewScreenState extends State<HeartSpikeReviewScreen> {
  int? _expandedIndex;
  bool _exporting = false;

  String get _exportDateStr {
    if (widget.dateStr != null) return widget.dateStr!;
    final valid = validHrSamples(widget.samples);
    final anchor = valid.isNotEmpty
        ? DateTime.fromMillisecondsSinceEpoch(valid.first.timeMs)
        : (widget.now?.call() ?? DateTime.now());
    return '${anchor.year.toString().padLeft(4, '0')}-'
        '${anchor.month.toString().padLeft(2, '0')}-'
        '${anchor.day.toString().padLeft(2, '0')}';
  }

  Future<String> _defaultSave(List<int> bytes, String fileName) async {
    // R66 divergence: native saves this PDF to Downloads via
    // MediaStore; the Lab's saved copy lands in the app documents
    // directory and the share sheet shares the same bytes.
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<void> _exportPdf() async {
    if (_exporting) return;
    final valid = validHrSamples(widget.samples);
    final events = detectSpikePdfEvents(valid);
    if (events.isEmpty) {
      // Native Toast text, verbatim.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No spike events to export')),
      );
      return;
    }
    setState(() => _exporting = true);
    try {
      final dateStr = _exportDateStr;
      final bytes = await buildSpikeReportPdfBytes(
        samples: valid,
        dateStr: dateStr,
        exportedAt: widget.now?.call() ?? DateTime.now(),
      );
      final fileName = spikePdfFileName(dateStr);
      final saveFn = widget.savePdf ?? _defaultSave;
      await saveFn(bytes, fileName);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Spike report saved'),
          action: SnackBarAction(
            label: 'Share',
            onPressed: () {
              final shareFn = widget.sharePdf ??
                  (b, name) => Printing.sharePdf(
                      bytes: Uint8List.fromList(b), filename: name);
              shareFn(bytes, fileName);
            },
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Export failed unexpectedly. Try again.')),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final valid = validHrSamples(widget.samples);
    final spikes = detectSpikeEvents(valid);
    // Juno §4 BINDING all-clear gate: an empty valid series is an
    // UNEXAMINED day. The header's zero-spike claims and the
    // all-clear empty state may render ONLY when the series is
    // non-empty AND detection on it found 0 events. An unexamined
    // day renders the detail-unavailable state instead, with the
    // "0 Significant Spikes Detected" header suppressed entirely.
    final examined = valid.isNotEmpty;

    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back,
              color: NotelColors.textSecondary),
          tooltip: 'Back',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Spike Review',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
        // Native top-bar action (HeartSpikeReviewScreen.kt): the
        // Download icon in the primary tint runs the PDF export.
        actions: [
          IconButton(
            icon: const Icon(Icons.download, color: NotelColors.primary),
            tooltip: 'Download spike report',
            onPressed: _exporting ? null : _exportPdf,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!examined)
              _detailUnavailableState()
            else ...[
              _headerCard(spikes.length),
              const SizedBox(height: 16),
              if (spikes.isEmpty)
                _emptyState()
              else ...[
              const Text(
                'Detected Events',
                style: TextStyle(
                  color: NotelColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              for (var i = 0; i < spikes.length; i++) ...[
                _spikeCard(i, spikes[i], valid),
                if (i < spikes.length - 1) const SizedBox(height: 16),
              ],
              ],
            ],
          ],
        ),
      ),
    );
  }

  // Native summary header card: error-tinted when spikes exist.
  Widget _headerCard(int count) {
    final hasSpikes = count > 0;
    return Container(
      decoration: BoxDecoration(
        color: hasSpikes ? NotelColors.errorTint : NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: hasSpikes
              ? NotelColors.primary.withValues(alpha: 0.18)
              : NotelColors.cardBorder,
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(
              color: NotelColors.errorTintStrong,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.whatshot,
                color: NotelColors.error, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$count Significant Spikes Detected',
                  style: const TextStyle(
                    color: NotelColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hasSpikes
                      ? 'Showing heart rate spikes ≥100 bpm for today'
                      : 'No spikes ≥100 bpm recorded for this time range',
                  style: const TextStyle(
                    color: NotelColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Juno §4 — the detail-unavailable state for an UNEXAMINED day
  /// (empty series). With a stored count > 0 the count line renders
  /// above the detail line; with a stored count of 0 or no stored
  /// summary, the detail line renders alone. No header card, no
  /// zero-spike claim, no all-clear — see the gate in [build].
  Widget _detailUnavailableState() {
    final stored = widget.effectiveStoredSpikeCount;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          const Icon(Icons.info_outline,
              color: NotelColors.textSecondary, size: 48),
          const SizedBox(height: 12),
          if (stored != null && stored > 0) ...[
            Text(
              spikeReviewStoredCountLine(stored),
              style: const TextStyle(
                color: NotelColors.textPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
          ],
          const Text(
            spikeReviewDetailUnavailableLine,
            style: TextStyle(
              color: NotelColors.textSecondary,
              fontSize: 13,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  /// The all-clear. Juno §4 BINDING: renders ONLY from [build]'s
  /// examined-and-zero-events branch — a non-empty series was
  /// actually examined and detection found 0 events.
  Widget _emptyState() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Icon(Icons.check_circle, color: NotelColors.success, size: 48),
          SizedBox(height: 12),
          Text(
            'Normal Physiological Load',
            style: TextStyle(
              color: NotelColors.textPrimary,
              fontWeight: FontWeight.bold,
              fontSize: 18,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'All heart rate readings stayed within normal resting and active ranges.',
            style: TextStyle(
              color: NotelColors.textSecondary,
              fontSize: 13,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _spikeCard(int index, SpikeEvent spike, List<HrSample> valid) {
    final expanded = _expandedIndex == index;
    final startStr = formatHrTime(spike.startTimeMs);
    final endStr = formatHrTime(spike.endTimeMs);
    final timeLabel =
        spike.startTimeMs == spike.endTimeMs ? startStr : '$startStr - $endStr';
    final contextReadings = spikeContextReadings(valid, spike);

    return Container(
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NotelColors.cardBorder),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () =>
              setState(() => _expandedIndex = expanded ? null : index),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: NotelColors.errorTintStrong,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      child: Text(
                        '#${index + 1}',
                        style: const TextStyle(
                          color: NotelColors.error,
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            timeLabel,
                            style: const TextStyle(
                              color: NotelColors.textPrimary,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${spike.durationMins}m duration  •  ${spike.source}',
                            style: const TextStyle(
                              color: NotelColors.textSecondary,
                              fontSize: 11,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '${spike.peakBpm} bpm',
                          style: const TextStyle(
                            color: NotelColors.error,
                            fontWeight: FontWeight.w900,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '+${spike.jumpDelta} jump',
                          style: const TextStyle(
                            color: NotelColors.textSecondary,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                if (expanded) ...[
                  const SizedBox(height: 14),
                  const Divider(height: 1, color: NotelColors.divider),
                  const SizedBox(height: 12),
                  Text(
                    'Surrounding Context (${contextReadings.length} data points):',
                    style: const TextStyle(
                      color: NotelColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final r in contextReadings.take(8)) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          formatHrTime(r.timeMs),
                          style: const TextStyle(
                            color: NotelColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          '${r.bpm} bpm',
                          style: TextStyle(
                            color: r.bpm >= 100
                                ? NotelColors.error
                                : NotelColors.textPrimary,
                            fontSize: 12,
                            fontWeight: r.bpm >= 100
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
