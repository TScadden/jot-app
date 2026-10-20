import 'dart:async';

import 'package:tabs_lab/src/data/daily_score.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';

/// R70 WS1b — Health Connect → [HealthHistoryStore] capture.
///
/// Every capture merges through `mergeRefresh`: Health Connect is
/// the source of truth inside its retention window, and everything
/// older than the window survives untouched (the store never
/// shrinks — the Sep 30, 2026 lesson).
///
/// Throttle: captures are skipped when the last successful capture
/// was < [throttle] ago, unless forced. The first-ever capture
/// (empty store) is a forced full backfill. Capture NEVER throws —
/// a failure must never break a screen.
///
/// Per-metric read failures are never swallowed either: each
/// read's `lastReadErrorCode` is snapshotted and persisted to the
/// store's capture diagnostics (see
/// [HealthHistoryStore.recordCaptureDiagnostics]) — a failed HRV
/// read leaves a visible trace instead of looking like no HRV.
/// The HRV leg also records its outcome numbers there (partial
/// code, raw sample count, attributed day count).
class HealthHistorySync {
  static const Duration throttle = Duration(hours: 6);

  static final HealthHistorySync instance = HealthHistorySync._internal();
  HealthHistorySync._internal()
      : _hc = HealthConnectService(),
        _store = HealthHistoryStore.instance,
        _now = DateTime.now;

  /// Injectable for tests / WS2 wiring.
  factory HealthHistorySync.withDeps({
    HealthConnectService? hc,
    HealthHistoryStore? store,
    DateTime Function()? now,
  }) =>
      HealthHistorySync._(hc ?? HealthConnectService(),
          store ?? HealthHistoryStore.instance, now ?? DateTime.now);

  HealthHistorySync._(this._hc, this._store, this._now);

  HealthConnectService _hc;
  HealthHistoryStore _store;
  DateTime Function() _now;

  /// Test hook: swap the dependencies of the shared instance.
  void debugSetDeps({
    HealthConnectService? hc,
    HealthHistoryStore? store,
    DateTime Function()? now,
  }) {
    if (hc != null) _hc = hc;
    if (store != null) _store = store;
    if (now != null) _now = now;
  }

  /// The WS2-facing entry point: fire-and-forget safe, never throws.
  /// Returns true when a capture actually ran.
  Future<bool> capture({bool force = false}) =>
      captureFromHealthConnect(force: force);

  /// Reads the Health Connect windows and merge-refreshes them into
  /// the history store:
  /// - resting HR: 180 days (`readRestingHrHistory`)
  /// - calories: 180 days (`readCaloriesHistory`)
  /// - sleep + deep: 90 days (`readSleepHistory`)
  /// - spikes: 180 days on the first-ever backfill only,
  ///   31 days on routine captures (`readSpikeCounts` is the
  ///   expensive raw-sample compute)
  /// - HRV: ONE range read (`readHrvSamples`) over 90 days on the
  ///   first-ever capture, 31 days on routine captures; raw samples
  ///   are attributed to local calendar days and reduced to the
  ///   daily top-tier average in Dart (`attributeDailyHrv`). The
  ///   range window retro-fills HRV for days the store already
  ///   holds from other metrics (merge-only: stored values are
  ///   never erased, only refreshed/filled).
  Future<bool> captureFromHealthConnect({bool force = false}) async {
    try {
      await _store.warmFromDisk();
      final now = _now();
      final isFirst = (await _store.dayCount()) == 0;
      final last = _store.lastCaptureMs;
      if (!force && !isFirst && last != null) {
        final age = now.millisecondsSinceEpoch - last;
        if (age >= 0 && age < throttle.inMilliseconds) return false;
      }

      final byDate = <String, DailyBiometrics>{};
      void put(String date,
          {int? hr, int? sleep, int? deep, int? spikes, int? kcal, double? hrv}) {
        final prev = byDate[date];
        byDate[date] = DailyBiometrics(
          date: date,
          restingHrBpm: hr ?? prev?.restingHrBpm,
          sleepMinutes: sleep ?? prev?.sleepMinutes,
          deepSleepMinutes: deep ?? prev?.deepSleepMinutes,
          spikeCount: spikes ?? prev?.spikeCount,
          caloriesKcal: kcal ?? prev?.caloriesKcal,
          hrvRmssdMs: hrv ?? prev?.hrvRmssdMs,
        );
      }

      // Capture diagnostics (HRV visibility fix): the HC service
      // fails closed — a failed read returns [] and records its
      // code in `lastReadErrorCode` — and the capture used to
      // never look, so e.g. an HRV read blocked by a missing grant
      // (HRV_SAMPLES_READ_FAILED) vanished without a trace while
      // markCaptured still stamped success. Mirror the queries
      // layer: reset the code around each read, snapshot it right
      // after, and persist the per-metric outcome to the store
      // (failures recorded, successes clear their metric's entry).
      final captureFailures = <String, String>{};
      final captureSucceeded = <String>{};
      void noteRead(String metric) {
        final code = _hc.lastReadErrorCode;
        if (code != null && code.isNotEmpty) {
          captureFailures[metric] = code;
        } else {
          captureSucceeded.add(metric);
        }
      }

      void resetReadCodes() {
        _hc.lastReadErrorCode = null;
        _hc.lastPartialErrorCode = null;
      }

      resetReadCodes();
      final hrHist = await _hc.readRestingHrHistory(180);
      noteRead('restingHr');
      for (final r in hrHist) {
        put(r.date, hr: r.bpm);
      }
      resetReadCodes();
      final calHist = await _hc.readCaloriesHistory(180);
      noteRead('calories');
      for (final r in calHist) {
        put(r.date, kcal: r.kcal);
      }
      resetReadCodes();
      final sleepHist = await _hc.readSleepHistory(90);
      noteRead('sleep');
      for (final r in sleepHist) {
        put(r.date, sleep: r.mins, deep: r.deep);
      }
      resetReadCodes();
      final spikeHist = await _hc.readSpikeCounts(isFirst ? 180 : 31);
      noteRead('spikes');
      for (final r in spikeHist) {
        put(r.date, spikes: r.count);
      }

      // HRV — ONE range read of raw samples; day attribution +
      // the daily top-tier rule run in Dart (attributeDailyHrv).
      // The window retro-fills HRV onto days already in the store
      // from other metrics: the first capture reaches back 90
      // days, routine captures 31.
      final hrvWindowDays = isFirst ? 90 : 31;
      final today = DateTime(now.year, now.month, now.day);
      final hrvDates = <String>{
        for (var i = 0; i < hrvWindowDays; i++)
          _historyDateStr(today.subtract(Duration(days: i))),
      };
      resetReadCodes();
      final hrvSamples = await _hc.readHrvSamples(hrvWindowDays);
      noteRead('hrv');
      // Defect 1b — HRV outcome numbers: the partial code (the
      // read returned data with chunks missing — Defect 0's new
      // contract), the raw sample count the bridge returned, and
      // the attributed day count are recorded alongside any error
      // code, so a recurrence is diagnosable from the diagnostics
      // record alone. Counts are operational metadata, not values.
      final hrvPartialCode = _hc.lastPartialErrorCode;
      final dailyHrv = attributeDailyHrv(hrvSamples, hrvDates);
      for (final entry in dailyHrv.entries) {
        put(entry.key, hrv: entry.value);
      }

      await _store.mergeRefresh(byDate.values);
      // A failed read leaves a visible trace even though the
      // capture itself still completes (merge + throttle stamp
      // unchanged): the diagnostics record is on the store.
      await _store.recordCaptureDiagnostics(
        failures: captureFailures,
        succeeded: captureSucceeded,
        atMs: now.millisecondsSinceEpoch,
        hrvPartialCode: hrvPartialCode,
        hrvSampleCount: hrvSamples.length,
        hrvDayCount: dailyHrv.length,
      );
      await _store.markCaptured(now.millisecondsSinceEpoch);
      // R70 Daily Score — after-capture compute trigger: any day
      // whose inputs now exist gets its (write-once) score. The
      // engine never throws and never rewrites a scored day.
      // TODAY RULE (see daily_score.dart header, amended Oct 20,
      // 2026): this post-capture run is the ONLY trigger allowed
      // to score the current day — it runs after the capture merge
      // (the snapshot), on the day's freshest data — so it
      // deliberately passes NO beforeDate cutoff; every other
      // trigger passes beforeDate: today. But it now names today
      // as the completeness-gated date: today is scored only when
      // ALL THREE components are available, otherwise it stays
      // pending for a later capture to retry. Past days in the
      // same run score under the day-boundary fallback.
      await DailyScoreEngine(store: _store).computeMissingScores(
        completeOnlyDate: _historyDateStr(now),
      );
      return true;
    } catch (_) {
      // Capture failure must never break a screen.
      return false;
    }
  }

}

String _historyDateStr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
