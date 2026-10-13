import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart';

/// Round 50 — Dart side of the Android home-screen vitals widget.
///
/// Single source of truth: the widget renders EXACTLY the
/// [HomeCacheSnapshot] Home renders from — the same snapshot is mapped
/// here, preformatted, saved through the `home_widget` bridge, and read
/// back by the native `VitalsWidgetProvider` (Kotlin/RemoteViews).
///
/// Cell mapping (the founder's widget spec — note the ONE deliberate
/// difference from the in-app strip: the flame cell carries the
/// current streak days here, NOT active calories):
/// - heart rate → `snap.vitals.heartRate` (null or 0 → "--"; a
///   biometric 0 is a failed read, NEVER rendered)
/// - streak → `snap.currentStreak` (null → "--"; 0 is an honest count)
/// - logs today → `snap.vitals.logCountToday` (real count, 0 is honest)
/// - sleep → `snap.vitals.sleepMinutes` (null or 0 → "--", else
///   [formatSleepMinutes], reused from the strip — never reimplemented)
///
/// Signed-out payloads carry NO numbers at all: every value is "--"
/// and the signed-in flag is false, so the native side renders its
/// signed-out face and a previous account's numbers can never show.
///
/// Fire-and-forget safe: every entry point swallows its own failures.
/// A widget failure must NEVER break Home, login, or logout — this is
/// a silent side-channel and logs nothing user-visible.
class WidgetSync {
  WidgetSync._();

  /// SharedPreferences keys — must match `VitalsWidgetProvider.kt`.
  static const String keySignedIn = 'widget_signed_in';
  static const String keyHeartRate = 'widget_heart_rate';
  static const String keyStreak = 'widget_streak';
  static const String keyLogs = 'widget_logs';
  static const String keySleep = 'widget_sleep';

  /// Qualified Android provider name for `HomeWidget.updateWidget`.
  static const String qualifiedProviderName =
      'com.notel.notel.playground.flutter.VitalsWidgetProvider';
  static const String providerName = 'VitalsWidgetProvider';

  // Injectable bridge (unit tests): replaces the platform-channel
  // calls so the mapping + failure-swallowing can be verified without
  // a device. Null in production.
  static Future<void> Function(String key, Object? value)? _saveOverride;
  static Future<void> Function()? _updateOverride;

  @visibleForTesting
  static void debugSetBridge({
    required Future<void> Function(String key, Object? value) save,
    required Future<void> Function() update,
  }) {
    _saveOverride = save;
    _updateOverride = update;
  }

  @visibleForTesting
  static void debugResetBridge() {
    _saveOverride = null;
    _updateOverride = null;
  }

  static Future<void> _save(String key, Object? value) {
    final override = _saveOverride;
    if (override != null) return override(key, value);
    if (value is bool) return HomeWidget.saveWidgetData<bool>(key, value);
    return HomeWidget.saveWidgetData<String>(key, value as String?);
  }

  static Future<void> _requestUpdate() {
    final override = _updateOverride;
    if (override != null) return override();
    return HomeWidget.updateWidget(
      name: providerName,
      qualifiedAndroidName: qualifiedProviderName,
    );
  }

  /// Maps a Home snapshot to the widget payload. Pure — the unit
  /// tests exercise this directly.
  static WidgetPayload buildPayload(
    HomeCacheSnapshot snap, {
    required bool signedIn,
  }) {
    if (!signedIn) return const WidgetPayload.signedOut();
    final vitals = snap.vitals;
    final heartRate = vitals?.heartRate;
    final sleepMinutes = vitals?.sleepMinutes;
    return WidgetPayload(
      signedIn: true,
      heartRate:
          (heartRate == null || heartRate == 0) ? '--' : '$heartRate',
      streak:
          snap.currentStreak == null ? '--' : '${snap.currentStreak}',
      // The log count is real even at 0 (same rule as the strip);
      // a snapshot with no vitals section yet reads as 0 logs,
      // exactly like the strip's `v?.logCountToday ?? 0`.
      logs: '${vitals?.logCountToday ?? 0}',
      sleep: (sleepMinutes == null || sleepMinutes == 0)
          ? '--'
          : formatSleepMinutes(sleepMinutes),
    );
  }

  /// Pushes [snap] to the widget. Never throws.
  static Future<void> pushSnapshot(
    HomeCacheSnapshot snap, {
    required bool signedIn,
  }) async {
    try {
      final payload = buildPayload(snap, signedIn: signedIn);
      await _save(keySignedIn, payload.signedIn);
      await _save(keyHeartRate, payload.heartRate);
      await _save(keyStreak, payload.streak);
      await _save(keyLogs, payload.logs);
      await _save(keySleep, payload.sleep);
      await _requestUpdate();
    } catch (_) {
      // Silent side-channel: Home / login must never see this fail.
    }
  }

  /// Wipes the saved values and drops the widget to its signed-out
  /// face. The real numbers are overwritten (never left sitting in
  /// the widget store), the flag goes false, and an update is
  /// requested. Never throws.
  static Future<void> clear() async {
    try {
      const payload = WidgetPayload.signedOut();
      await _save(keySignedIn, payload.signedIn);
      await _save(keyHeartRate, payload.heartRate);
      await _save(keyStreak, payload.streak);
      await _save(keyLogs, payload.logs);
      await _save(keySleep, payload.sleep);
      await _requestUpdate();
    } catch (_) {
      // Silent side-channel: logout must never see this fail.
    }
  }
}

/// The preformatted widget payload: four display strings + the
/// signed-in flag. Signed-out payloads hold "--" in every cell.
class WidgetPayload {
  final bool signedIn;
  final String heartRate;
  final String streak;
  final String logs;
  final String sleep;

  const WidgetPayload({
    required this.signedIn,
    required this.heartRate,
    required this.streak,
    required this.logs,
    required this.sleep,
  });

  const WidgetPayload.signedOut()
      : signedIn = false,
        heartRate = '--',
        streak = '--',
        logs = '--',
        sleep = '--';

  Map<String, Object?> toMap() => {
        WidgetSync.keySignedIn: signedIn,
        WidgetSync.keyHeartRate: heartRate,
        WidgetSync.keyStreak: streak,
        WidgetSync.keyLogs: logs,
        WidgetSync.keySleep: sleep,
      };

  @override
  bool operator ==(Object other) =>
      other is WidgetPayload &&
      other.signedIn == signedIn &&
      other.heartRate == heartRate &&
      other.streak == streak &&
      other.logs == logs &&
      other.sleep == sleep;

  @override
  int get hashCode => Object.hash(signedIn, heartRate, streak, logs, sleep);
}
