import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/heart_data.dart';
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
/// DEFERRED vs native: the top-bar PDF download action
/// (`PdfExporter.exportSpikesToPdf`) has no Flutter bridge in the Lab
/// and is omitted rather than faked — flagged in the round report.
///
/// Founder rule: samples arrive already valid-filtered by the caller,
/// and every derivation here re-filters (bpm ≤ 0 never renders).
class HeartSpikeReviewScreen extends StatefulWidget {
  final List<HrSample> samples;

  const HeartSpikeReviewScreen({super.key, required this.samples});

  @override
  State<HeartSpikeReviewScreen> createState() =>
      _HeartSpikeReviewScreenState();
}

class _HeartSpikeReviewScreenState extends State<HeartSpikeReviewScreen> {
  int? _expandedIndex;

  @override
  Widget build(BuildContext context) {
    final valid = validHrSamples(widget.samples);
    final spikes = detectSpikeEvents(valid);

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
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
                      ? 'Showing heart rate spikes ≥100 BPM for today'
                      : 'No spikes ≥100 BPM recorded for this time range',
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
                  const Divider(height: 1, color: NotelColors.surfaceHigh),
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
