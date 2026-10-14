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
/// Round 59 — strip parity (founder phone test of Round 58: the
/// widget's flame cell read 2 while the strip's flame cell read 62,
/// and the logs cell read 1 while the strip read 7). Cell mapping is
/// now the strip's mapping, field for field — [VitalsStrip] is the
/// spec (lib/src/features/home/vitals_strip.dart):
/// - heart rate → `snap.vitals.heartRate` (null or 0 → "--"; a
///   biometric 0 is a failed read, NEVER rendered) — the strip's
///   `v?.heartRate` cell.
/// - flame → `snap.vitals.activeCalories` (null or 0 → "--") — the
///   strip's `v?.activeCalories` cell. Round 50 deliberately put
///   `snap.currentStreak` (streak days) here; that substitution is
///   REMOVED: the streak belongs to the in-app streak row, never to
///   this strip, and the widget no longer reads it at all. (The
///   repository already nulls a 0 calorie read before it reaches a
///   snapshot, so the 0 guard here only keeps the biometric rule
///   for hand-built / disk-warmed snapshots — same as heart rate.)
/// - logs today → `snap.vitals.logCountToday` (real count, 0 is
///   honest), exactly the strip's `v?.logCountToday ?? 0`.
/// - sleep → `snap.vitals.sleepMinutes` (null or 0 → "--", else
///   [formatSleepMinutes], reused from the strip — never
///   reimplemented), so the string is the strip's string verbatim
///   ("8h36m", never reflowed or re-derived natively).
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
  ///
  /// Round 59: [keyCalories] keeps the Round 50 wire VALUE
  /// 'widget_streak' on purpose: it is an opaque storage identifier
  /// shared with the Kotlin provider, the `widget_streak` view id in
  /// the RemoteViews layout, already-placed widgets' stores, and the
  /// check_widget_apk.sh artifact gate. Renaming the wire value
  /// would orphan all of those to fix a name only Dart code reads;
  /// the VALUE stored under it is now the strip's calories number.
  static const String keySignedIn = 'widget_signed_in';
  static const String keyHeartRate = 'widget_heart_rate';
  static const String keyCalories = 'widget_streak';
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

  // Round 59 — push serialization (the entries-mismatch cause).
  //
  // Every production caller fires pushes unawaited (Home initState's
  // cached-snapshot push, HomeDataCache.persist()'s fresh-load push,
  // main()'s app-start re-publish, clear() on logout). Before this
  // drain, two pushes started in the same load overlapped: each one
  // awaits five platform saves in turn, so their saves INTERLEAVED
  // per key, and the earlier (stale) push could write a key AFTER
  // the later (fresh) push had already written it — with no further
  // push scheduled to correct it. On the founder's phone the stale
  // cached push (logs 1, from before later entries existed) landed
  // its logs save after the fresh load's (logs 7); heart rate and
  // sleep are identical in both snapshots so only the changed cell
  // showed the overwrite.
  //
  // The drain runs ONE payload at a time: a push that arrives while
  // another is in flight goes into the single pending slot
  // (latest wins — an in-between payload is superseded before it is
  // ever written, which is strictly better than writing it and
  // overwriting it), and the in-flight drain picks it up before
  // completing. The widget store therefore always ends on the LAST
  // payload initiated, whole — never a per-key mix of two payloads.
  // Callers awaiting a superseded push complete when the drain
  // empties; production callers are all fire-and-forget.
  //
  // A future-CHAIN design was tried first and rejected in testing:
  // a static chain future carried across async contexts can stall
  // the whole queue behind a completed-in-another-context tail,
  // and one hung platform save would wedge every later push behind
  // it forever. The drain carries no future between calls — the
  // loop is started by the first caller and lives entirely in that
  // caller's context; [_drainFuture] is non-null only while a drain
  // is actually running.
  static Future<void>? _drainFuture;
  static WidgetPayload? _pendingPayload;

  static Future<void> _enqueuePush(WidgetPayload payload) {
    _pendingPayload = payload;
    final running = _drainFuture;
    if (running != null) return running;
    final drain = _drain();
    _drainFuture = drain;
    return drain;
  }

  static Future<void> _drain() async {
    try {
      while (_pendingPayload != null) {
        final payload = _pendingPayload!;
        _pendingPayload = null;
        await _pushPayload(payload);
      }
    } finally {
      // No await between the loop exit and here, so a push cannot
      // slip into the gap: the next _enqueuePush either fed the
      // loop above or starts a fresh drain after this reset.
      _drainFuture = null;
    }
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
      await _save(keyCalories, payload.calories);
      await _save(keyLogs, payload.logs);
      await _save(keySleep, payload.sleep);
    } finally {
      await _requestUpdate();
    }
  }

  /// Maps a Home snapshot to the widget payload. Pure — the unit
  /// tests exercise this directly. Round 59: consumes ONLY the four
  /// fields [VitalsStrip] consumes, in the strip's own form — no
  /// substituted meanings, no parallel computation.
  static WidgetPayload buildPayload(
    HomeCacheSnapshot snap, {
    required bool signedIn,
  }) {
    if (!signedIn) return const WidgetPayload.signedOut();
    final vitals = snap.vitals;
    final heartRate = vitals?.heartRate;
    final activeCalories = vitals?.activeCalories;
    final sleepMinutes = vitals?.sleepMinutes;
    return WidgetPayload(
      signedIn: true,
      heartRate:
          (heartRate == null || heartRate == 0) ? '--' : '$heartRate',
      calories: (activeCalories == null || activeCalories == 0)
          ? '--'
          : '$activeCalories',
      // The log count is real even at 0 (same rule as the strip);
      // a snapshot with no vitals section yet reads as 0 logs,
      // exactly like the strip's `v?.logCountToday ?? 0`.
      logs: '${vitals?.logCountToday ?? 0}',
      sleep: (sleepMinutes == null || sleepMinutes == 0)
          ? '--'
          : formatSleepMinutes(sleepMinutes),
    );
  }

  /// Pushes [snap] to the widget. Serialized with every other
  /// push/clear through the drain (see the Round 59 note on
  /// [_enqueuePush]). Never throws.
  static Future<void> pushSnapshot(
    HomeCacheSnapshot snap, {
    required bool signedIn,
  }) async {
    try {
      await _enqueuePush(buildPayload(snap, signedIn: signedIn));
    } catch (_) {
      // Silent side-channel: Home / login must never see this fail.
    }
  }

  /// Wipes the saved values and drops the widget to its signed-out
  /// face. The real numbers are overwritten (never left sitting in
  /// the widget store), the flag goes false, and an update is
  /// requested. Serialized with pushes, so a clear initiated after
  /// a push can never be overwritten back by that push's tail.
  /// Never throws.
  static Future<void> clear() async {
    try {
      await _enqueuePush(const WidgetPayload.signedOut());
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

  /// The flame cell — the strip's active-calories string (Round 59;
  /// Round 50 carried streak days here under the name `streak`).
  final String calories;
  final String logs;
  final String sleep;

  const WidgetPayload({
    required this.signedIn,
    required this.heartRate,
    required this.calories,
    required this.logs,
    required this.sleep,
  });

  const WidgetPayload.signedOut()
      : signedIn = false,
        heartRate = '--',
        calories = '--',
        logs = '--',
        sleep = '--';

  Map<String, Object?> toMap() => {
        WidgetSync.keySignedIn: signedIn,
        WidgetSync.keyHeartRate: heartRate,
        WidgetSync.keyCalories: calories,
        WidgetSync.keyLogs: logs,
        WidgetSync.keySleep: sleep,
      };

  @override
  bool operator ==(Object other) =>
      other is WidgetPayload &&
      other.signedIn == signedIn &&
      other.heartRate == heartRate &&
      other.calories == calories &&
      other.logs == logs &&
      other.sleep == sleep;

  @override
  int get hashCode =>
      Object.hash(signedIn, heartRate, calories, logs, sleep);
}
