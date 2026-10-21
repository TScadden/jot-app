/// Refresh keep-alive — Dart side of the native foreground
/// service that protects a manual Daily Score refresh across a
/// Recents swipe (founder-directed Oct 20, 2026).
///
/// The mechanics live natively (RefreshKeepAliveService in the
/// health_connect_bridge plugin): an ongoing, LOW-importance
/// notification ("Refreshing your Daily Score…") on a health-type
/// foreground service declared stopWithTask="false", so swiping
/// Tabs from Recents leaves service + notification + process —
/// and the Dart refresh running in it — alive. This wrapper is
/// the ONLY Dart surface over those channel methods.
///
/// Contract:
/// - The channel is the Health Connect bridge channel (the plugin
///   registers on every engine), but the BACKGROUND isolate /
///   runner must never call this: a keep-alive protects a MANUAL
///   refresh only, and the refresh owner that calls it is
///   foreground-only. Nothing in daily_score_background.dart
///   references this file (pinned by a source-scan test).
/// - Arguments are the refresh DATE ONLY. No score and no health
///   value ever crosses this channel (pinned by the owner tests'
///   recorded channel arguments).
/// - NOTHING here ever throws into the refresh path: every method
///   catches every channel failure. [start] reports failure as
///   `false` so the owner can record it against the flight and
///   surface Juno's line (Ruling 3) with that refresh's outcome;
///   the refresh itself always proceeds in-process exactly as it
///   did before the keep-alive existed.
/// - A POST_NOTIFICATIONS denial is NOT a start failure: the
///   native start call still succeeds (the service runs; Android
///   simply does not show its notification), so it never reaches
///   this layer as an error and must never trigger Juno's line.
///   This layer never requests notification permission and never
///   gates a refresh on it.
library;

import 'package:flutter/services.dart';

import 'package:tabs_lab/src/data/health_connect_service.dart';

/// Juno Ruling 3's exact surfacing line, rendered by the day
/// screen as its own non-modal line AFTER a refresh's own
/// outcome/error rendering, once per failed-start refresh.
/// Every native start failure maps to the single bracketed code
/// in this string; the native exception class goes to logcat
/// only and never reaches the UI.
const String dailyScoreRefreshKeepAliveFailedLine =
    "Keep-alive couldn't start: this refresh wasn't protected if you "
    'swiped Tabs away. [FGS_START_FAILED]';

/// Thin, never-throwing wrapper over the plugin's keep-alive
/// channel methods. See the file header for the full contract.
class RefreshKeepAlive {
  final MethodChannel _channel;

  const RefreshKeepAlive({MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel(HealthConnectService.channelName);

  /// The shared app-scope wrapper over the bridge channel.
  static const RefreshKeepAlive instance = RefreshKeepAlive();

  /// Asks the native service to start protecting the refresh of
  /// [date]. Returns true when the start call succeeded; false on
  /// ANY failure (PlatformException of any code — including a
  /// SecurityException surfaced natively as FGS_START_FAILED —
  /// MissingPluginException, or anything unexpected).
  Future<bool> start(String date) async {
    try {
      final ok =
          await _channel.invokeMethod<bool>('startRefreshKeepAlive', {
        'date': date,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Asks the native service to stop (which dismisses its
  /// notification). Idempotent natively — a no-op when not
  /// running. Returns whether the stop call succeeded; callers
  /// treat either answer the same (a failed stop never breaks a
  /// settled refresh), it exists for tests and diagnostics.
  Future<bool> stop() async {
    try {
      final ok =
          await _channel.invokeMethod<bool>('stopRefreshKeepAlive');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Takes the date held from a keep-alive notification tap, if
  /// any (consume-once natively: a held date is returned exactly
  /// once; null when none). Never throws — a channel failure is
  /// indistinguishable from "no tap" for routing purposes.
  Future<String?> takePendingScoreTap() async {
    try {
      return await _channel.invokeMethod<String>('takePendingScoreTap');
    } catch (_) {
      return null;
    }
  }
}
