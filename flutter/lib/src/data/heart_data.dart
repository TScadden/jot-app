import 'package:tabs_lab/src/data/health_data.dart';

/// Round 25 — pure logic for the Heart screen, ported from the native
/// Heart screen's OWN code paths (not the weekly-snapshot summary):
///
/// - Summary card: `FitbitViewModel.syncFromHealthConnect` /
///   `fetchHeartRateForDate` (FitbitViewModel.kt) — awake/asleep split
///   computed inline there.
/// - Spikes card: the `todaySpikes` block inside `FitbitScreen.kt`.
/// - Spike review list: `HeartSpikeReviewScreen.kt`'s detection block.
///
/// ⚠️ DIVERGENCE FLAGGED (mirror-native per the round brief): the Heart
/// screen's ViewModel splits awake/asleep by device-local hour
/// **7..22 awake** / **23..6 asleep** (`h in 7..22`, `h >= 23 || h < 7`),
/// while the founder's standing rule and native
/// `computeDailyHeartRateSummary` (HealthConnectManager.kt) use
/// **7..21** (7 AM–10 PM) — see `daytimeHeartRateAvg` in
/// health_data.dart, which the Home/snapshot surfaces use. This file
/// mirrors the Heart screen's own native behavior exactly so the Heart
/// tab matches the native Heart tab; the 22:00–22:59 hour is the only
/// difference.
///
/// FOUNDER HARD RULES (non-negotiable):
/// - A 0 bpm sample is a failed read — filtered out BEFORE every
///   computation here, so it is never charted, averaged, counted, or
///   (via HeartDataCache) cached. Native's HC read does not filter
///   zeros; the founder rule wins.
/// - Missing data → null → the UI's "--" states. Never invented.

/// The valid (bpm > 0) samples, ascending by time. Every public
/// function in this file runs its input through this first.
List<HrSample> validHrSamples(List<HrSample> samples) {
  final valid = samples.where((s) => s.bpm > 0).toList()
    ..sort((a, b) => a.timeMs.compareTo(b.timeMs));
  return valid;
}

int _hourOf(int timeMs) => DateTime.fromMillisecondsSinceEpoch(timeMs).hour;

int? _avgOrNull(List<HrSample> samples) {
  if (samples.isEmpty) return null;
  final sum = samples.fold<int>(0, (a, s) => a + s.bpm);
  // Native: Double.average().toInt() — truncates toward zero.
  return (sum / samples.length).toInt();
}

/// "Awake average" — native FitbitViewModel: mean of samples whose
/// device-local hour is in 7..22, truncated to int. NO fallback when
/// the window is empty (native yields 0 → the UI shows "-- bpm").
int? heartAwakeAverage(List<HrSample> samples) {
  final valid = validHrSamples(samples);
  return _avgOrNull(valid.where((s) => _hourOf(s.timeMs) >= 7 && _hourOf(s.timeMs) <= 22).toList());
}

/// "Asleep" average — native FitbitViewModel: mean of samples whose
/// device-local hour is >= 23 or < 7. This is a time-of-day split of
/// the intraday samples, NOT an average over recorded sleep sessions.
/// Null when the window is empty (native yields 0 → "Asleep -- bpm").
int? heartAsleepAverage(List<HrSample> samples) {
  final valid = validHrSamples(samples);
  return _avgOrNull(valid.where((s) {
    final h = _hourOf(s.timeMs);
    return h >= 23 || h < 7;
  }).toList());
}

/// Peak bpm of the day (native: `maxOfOrNull { it.second }`), or null.
int? heartPeakBpm(List<HrSample> samples) {
  final valid = validHrSamples(samples);
  if (valid.isEmpty) return null;
  return valid.map((s) => s.bpm).reduce((a, b) => a > b ? a : b);
}

/// 10th-percentile baseline — native (both FitbitScreen.kt and
/// HeartSpikeReviewScreen.kt): sorted bpms, index
/// `(size * 0.10).toInt().coerceAtLeast(0)`. Null when empty.
int? heartBaselineP10(List<HrSample> samples) {
  final valid = validHrSamples(samples);
  if (valid.isEmpty) return null;
  final sorted = valid.map((s) => s.bpm).toList()..sort();
  var idx = (sorted.length * 0.10).toInt();
  if (idx < 0) idx = 0;
  if (idx > sorted.length - 1) idx = sorted.length - 1;
  return sorted[idx];
}

/// `SimpleDateFormat("h:mm a")` — e.g. "9:05 AM", "12:00 PM".
String formatHrTime(int timeMs) {
  final dt = DateTime.fromMillisecondsSinceEpoch(timeMs);
  final suffix = dt.hour < 12 ? 'AM' : 'PM';
  var h = dt.hour % 12;
  if (h == 0) h = 12;
  final m = dt.minute.toString().padLeft(2, '0');
  return '$h:$m $suffix';
}

/// Date-pill label — native FitbitScreen `displayDateLabel`: "Today"
/// for today, else `MMM d` (e.g. "Oct 3") for a "YYYY-MM-DD" string.
String heartDateLabel(String dateStr, String todayStr) {
  if (dateStr == 'today' || dateStr == todayStr) return 'Today';
  final parts = dateStr.split('-');
  if (parts.length == 3) {
    final month = int.tryParse(parts[1]) ?? 0;
    final day = int.tryParse(parts[2]) ?? 0;
    const months = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    if (month >= 1 && month <= 12 && day >= 1) return '${months[month]} $day';
  }
  return dateStr;
}

/// The Health Connect row subtitle. Native hardcodes the literal
/// "Synced 2 min ago" (FitbitScreen.kt) — it is NOT derived from any
/// timestamp. This port derives it honestly from the last successful
/// load instead (founder rule: no invented values): null → the honest
/// "Not synced yet".
String formatSyncedAgo(DateTime? lastSyncAt, DateTime now) {
  if (lastSyncAt == null) return 'Not synced yet';
  final diff = now.difference(lastSyncAt);
  if (diff.isNegative || diff.inMinutes < 1) return 'Synced just now';
  if (diff.inMinutes < 60) {
    return diff.inMinutes == 1
        ? 'Synced 1 min ago'
        : 'Synced ${diff.inMinutes} min ago';
  }
  if (diff.inHours < 24) {
    return diff.inHours == 1
        ? 'Synced 1 hr ago'
        : 'Synced ${diff.inHours} hr ago';
  }
  return diff.inDays == 1
      ? 'Synced 1 day ago'
      : 'Synced ${diff.inDays} days ago';
}

/// Load classification — native FitbitScreen.kt thresholds, verbatim:
/// High when max ≥ 130 or count ≥ 5; Moderate when max ≥ 110 or
/// count ≥ 2; otherwise Normal. Empty data (max 0, count 0) → Normal.
String heartLoadLevel({required int maxBpm, required int spikeCount}) {
  if (maxBpm >= 130 || spikeCount >= 5) return 'High load';
  if (maxBpm >= 110 || spikeCount >= 2) return 'Moderate load';
  return 'Normal load';
}

/// Spikes-card summary — verbatim port of the `todaySpikes` block in
/// FitbitScreen.kt:
///
/// - readings sorted; max = last; p10 = sorted[(size * 0.10).toInt()];
///   largest jump ("delta") = max − p10 (a GLOBAL max-vs-baseline
///   figure, not a per-event jump).
/// - spike count: walk samples in time order; a sample ≥ 100 starts a
///   new event when not already in one OR when its timestamp is after
///   `eventEndMs`; every ≥100 sample sets
///   `eventEndMs = t + 5 minutes`. So an event absorbs ≥100 samples
///   that arrive within 5 minutes of the previous ≥100 sample.
///
/// Empty input → all zeros (native's `listOf(0, 0, 0, 0)`), which the
/// UI renders as "--" / 0 / Normal load.
class HeartSpikesCardSummary {
  final int maxBpm;
  final int spikeCount;
  final int maxDelta; // max − p10
  final int baselineP10;

  const HeartSpikesCardSummary({
    required this.maxBpm,
    required this.spikeCount,
    required this.maxDelta,
    required this.baselineP10,
  });

  String get loadLevel =>
      heartLoadLevel(maxBpm: maxBpm, spikeCount: spikeCount);
}

HeartSpikesCardSummary computeHeartSpikesCard(List<HrSample> samples) {
  final valid = validHrSamples(samples);
  if (valid.isEmpty) {
    return const HeartSpikesCardSummary(
        maxBpm: 0, spikeCount: 0, maxDelta: 0, baselineP10: 0);
  }
  final sortedBpms = valid.map((s) => s.bpm).toList()..sort();
  final max = sortedBpms.last;
  var p10Idx = (sortedBpms.length * 0.10).toInt();
  if (p10Idx < 0) p10Idx = 0;
  final p10 = sortedBpms[p10Idx];

  var spikeCount = 0;
  var inEvent = false;
  var eventEndMs = 0;
  var currentPeak = 0; // tracked by native; not used in card stats
  for (final s in valid) {
    if (s.bpm >= 100) {
      if (!inEvent || s.timeMs > eventEndMs) {
        spikeCount++;
        inEvent = true;
        currentPeak = s.bpm;
      } else {
        if (s.bpm > currentPeak) currentPeak = s.bpm;
      }
      eventEndMs = s.timeMs + 5 * 60 * 1000;
    }
  }
  return HeartSpikesCardSummary(
    maxBpm: max,
    spikeCount: spikeCount,
    maxDelta: max - p10,
    baselineP10: p10,
  );
}

/// One spike event for the review list — port of native
/// `SpikeEventInfo` (HeartSpikeReviewScreen.kt). [source] is always
/// "Health Connect" in native.
class SpikeEvent {
  final int startTimeMs;
  final int endTimeMs; // timestamp of the LAST ≥100 sample in the event
  final int peakBpm;
  final int jumpDelta; // max(0, peak − p10 baseline)
  final String source;

  const SpikeEvent({
    required this.startTimeMs,
    required this.endTimeMs,
    required this.peakBpm,
    required this.jumpDelta,
    this.source = 'Health Connect',
  });

  /// Native: `maxOf(1, ((end − start) / 60000).toInt())`.
  int get durationMins {
    final mins = (endTimeMs - startTimeMs) ~/ 60000;
    return mins < 1 ? 1 : mins;
  }
}

/// Spike-review detection — verbatim port of HeartSpikeReviewScreen.kt:
///
/// - baseline = the same 10th-percentile rule as the card.
/// - a sample ≥ 100 starts a new event when not in one OR when its
///   timestamp is more than **3 minutes** after the previous event's
///   end (`tMs > currentSpikeEndMs + 3 * 60 * 1000`), where end is the
///   last ≥100 sample's timestamp. NOTE: this 3-minute gap rule
///   DIFFERS from the card's 5-minute window, so the review count can
///   differ from the card count on the same data — native behavior,
///   mirrored deliberately.
/// - jump = max(0, peak − baseline).
/// - the list is sorted by peak, descending.
List<SpikeEvent> detectSpikeEvents(List<HrSample> samples) {
  final valid = validHrSamples(samples);
  if (valid.isEmpty) return const [];
  final baseline = heartBaselineP10(valid) ?? 60;

  final detected = <SpikeEvent>[];
  var startMs = 0;
  var peakBpm = 0;
  var endMs = 0;
  var inEvent = false;

  void closeEvent() {
    final jump = peakBpm - baseline;
    detected.add(SpikeEvent(
      startTimeMs: startMs,
      endTimeMs: endMs,
      peakBpm: peakBpm,
      jumpDelta: jump < 0 ? 0 : jump,
    ));
  }

  for (final s in valid) {
    if (s.bpm >= 100) {
      if (!inEvent || s.timeMs > endMs + 3 * 60 * 1000) {
        if (inEvent) closeEvent();
        inEvent = true;
        startMs = s.timeMs;
        peakBpm = s.bpm;
      } else {
        if (s.bpm > peakBpm) peakBpm = s.bpm;
      }
      endMs = s.timeMs;
    }
  }
  if (inEvent) closeEvent();
  detected.sort((a, b) => b.peakBpm.compareTo(a.peakBpm));
  return detected;
}

/// Context readings around a spike (native review expansion):
/// samples within [start − 10 min, end + 10 min], time order.
List<HrSample> spikeContextReadings(List<HrSample> samples, SpikeEvent spike) {
  final valid = validHrSamples(samples);
  final lo = spike.startTimeMs - 10 * 60 * 1000;
  final hi = spike.endTimeMs + 10 * 60 * 1000;
  return valid.where((s) => s.timeMs >= lo && s.timeMs <= hi).toList();
}

/// Everything the Heart screen renders for one date, derived from the
/// raw samples in one pass.
class HeartDayData {
  /// Valid (bpm > 0) samples, ascending — the ONLY series the chart,
  /// cards, and review ever see.
  final List<HrSample> samples;
  final int? awakeAvg;
  final int? asleepAvg;
  final HrSample? latest;
  final int? peakBpm;
  final HeartSpikesCardSummary spikesCard;
  final List<SpikeEvent> spikeEvents;

  const HeartDayData({
    required this.samples,
    required this.awakeAvg,
    required this.asleepAvg,
    required this.latest,
    required this.peakBpm,
    required this.spikesCard,
    required this.spikeEvents,
  });

  factory HeartDayData.fromSamples(List<HrSample> raw) {
    final valid = validHrSamples(raw);
    return HeartDayData(
      samples: valid,
      awakeAvg: heartAwakeAverage(valid),
      asleepAvg: heartAsleepAverage(valid),
      latest: valid.isEmpty ? null : valid.last,
      peakBpm: heartPeakBpm(valid),
      spikesCard: computeHeartSpikesCard(valid),
      spikeEvents: detectSpikeEvents(valid),
    );
  }

  static const empty = HeartDayData(
    samples: [],
    awakeAvg: null,
    asleepAvg: null,
    latest: null,
    peakBpm: null,
    spikesCard:
        HeartSpikesCardSummary(maxBpm: 0, spikeCount: 0, maxDelta: 0, baselineP10: 0),
    spikeEvents: [],
  );
}
