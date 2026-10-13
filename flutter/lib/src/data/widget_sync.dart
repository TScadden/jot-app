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

  // Round 52 — per-save isolation: each save swallows its own
  // failure (and logs it in debug builds) so one bad save can
  // neither abort the remaining saves nor skip the widget update
  // in [pushSnapshot]/[clear] — a partial payload must never be
  // left sitting un-refreshed in the widget store.
  //
  // The bridge's `bool?` results are NOT discarded: `false` means
  // the platform side refused the write/update and is treated as a
  // failure (debug-logged; the channel stays silent to the user).
  // A null result is the plugin's "no answer" and is not a failure.
  static Future<void> _save(String key, Object? value) async {
    try {
      final override = _saveOverride;
      if (override != null) {
        await override(key, value);
        return;
      }
      final bool? ok;
      if (value is bool) {
        ok = await HomeWidget.saveWidgetData<bool>(key, value);
      } else {
        ok = await HomeWidget.saveWidgetData<String>(key, value as String?);
      }
      if (ok == false) {
        debugPrint('WidgetSync: saveWidgetData($key) returned false');
      }
    } catch (e) {
      debugPrint('WidgetSync: saveWidgetData($key) failed: $e');
    }
  }

  static Future<void> _requestUpdate() async {
    try {
      final override = _updateOverride;
      if (override != null) {
        await override();
        return;
      }
      final ok = await HomeWidget.updateWidget(
        name: providerName,
        qualifiedAndroidName: qualifiedProviderName,
      );
      if (ok == false) {
        debugPrint('WidgetSync: updateWidget returned false');
      }
    } catch (e) {
      debugPrint('WidgetSync: updateWidget failed: $e');
    }
  }

  /// Saves every key of [payload], then requests exactly one widget
  /// update. The update is requested from a `finally` block: even
  /// if an individual save misbehaves beyond its own isolation, a
  /// partially-written payload is always refreshed.
  static Future<void> _pushPayload(WidgetPayload payload) async {
    try {
      await _save(keySignedIn, payload.signedIn);
      await _save(keyHeartRate, payload.heartRate);
      await _save(keyStreak, payload.streak);
      await _save(keyLogs, payload.logs);
      await _save(keySleep, payload.sleep);
    } finally {
      await _requestUpdate();
    }
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
      await _pushPayload(buildPayload(snap, signedIn: signedIn));
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
      await _pushPayload(const WidgetPayload.signedOut());
    } catch (_) {
      // Silent side-channel: logout must never see this fail.
    }
  }

  /// Round 52 — app-start re-publish. Fired once (unawaited) from
  /// `main()` after the session read + cache warm, so a widget
  /// orphaned by an app update — or by a cold start that routes to
  /// welcome/onboarding and never mounts Home — is re-bound to the
  /// CURRENT state instead of sitting on whatever a previous build
  /// left in the widget store:
  /// - session present AND the cache holds a snapshot → the
  ///   signed-in snapshot payload;
  /// - anything else (no session, or a session with no cached
  ///   snapshot yet) → the signed-out payload.
  /// Exactly one push (five saves + one update) per call. Never
  /// throws.
  static Future<void> republishAppStart({
    required bool hasSession,
    required HomeCacheSnapshot snapshot,
  }) async {
    final hasSnapshot = snapshot.vitalsLoaded ||
        snapshot.streakLoaded ||
        snapshot.countersLoaded;
    if (hasSession && hasSnapshot) {
      await pushSnapshot(snapshot, signedIn: true);
    } else {
      await clear();
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
