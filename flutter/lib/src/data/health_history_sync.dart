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
  /// - HRV: per-day `readHrvRmssd` reads for the last 14 days —
  ///   this mirrors the report collector's mechanism exactly (it
  ///   issues one per-day read per date because no range HRV bridge
  ///   read exists; see progress_report.dart).
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

      final hrHist = await _hc.readRestingHrHistory(180);
      for (final r in hrHist) {
        put(r.date, hr: r.bpm);
      }
      final calHist = await _hc.readCaloriesHistory(180);
      for (final r in calHist) {
        put(r.date, kcal: r.kcal);
      }
      final sleepHist = await _hc.readSleepHistory(90);
      for (final r in sleepHist) {
        put(r.date, sleep: r.mins, deep: r.deep);
      }
      final spikeHist = await _hc.readSpikeCounts(isFirst ? 180 : 31);
      for (final r in spikeHist) {
        put(r.date, spikes: r.count);
      }

      // HRV — per-day reads in parallel, exactly the report
      // collector's mechanism, over the last 14 days.
      final today = DateTime(now.year, now.month, now.day);
      final hrvDates = List.generate(14, (i) {
        final d = today.subtract(Duration(days: 13 - i));
        return '${d.year.toString().padLeft(4, '0')}-'
            '${d.month.toString().padLeft(2, '0')}-'
            '${d.day.toString().padLeft(2, '0')}';
      });
      final hrvReads = await Future.wait([
        for (final d in hrvDates) _safeHrv(d),
      ]);
      for (var i = 0; i < hrvDates.length; i++) {
        final v = hrvReads[i];
        if (v != null) put(hrvDates[i], hrv: v);
      }

      await _store.mergeRefresh(byDate.values);
      await _store.markCaptured(now.millisecondsSinceEpoch);
      // R70 Daily Score — after-capture compute trigger: any day
      // whose inputs now exist gets its (write-once) score. The
      // engine never throws and never rewrites a scored day.
      // TODAY RULE (see daily_score.dart header): this post-capture
      // run is the ONLY trigger allowed to score the current day —
      // it runs after the capture merge, on the day's fullest data —
      // so it deliberately passes NO beforeDate cutoff. Every other
      // trigger passes beforeDate: today.
      await DailyScoreEngine(store: _store).computeMissingScores();
      return true;
    } catch (_) {
      // Capture failure must never break a screen.
      return false;
    }
  }

  Future<double?> _safeHrv(String date) async {
    try {
      return await _hc.readHrvRmssd(date);
    } catch (_) {
      return null;
    }
  }
}
