import 'package:flutter/foundation.dart';

/// Round 60 — launch milestone recorder (launch-performance audit).
///
/// A tiny in-memory stopwatch log for the cold-start path:
///
///   processStart → cachesWarmed → runApp → firstFrame
///   → sessionRestored → homeSeededFromCache → homeFreshData
///
/// Design rules:
/// - **Harmless in release builds.** The recorder is just a map of
///   durations in memory — no I/O, no logging, no user data (the
///   milestone names are fixed strings chosen below; nothing about
///   the account, session, or health values is ever recorded).
///   Marks are only *printed* when the app is built with
///   `--dart-define=LAUNCH_TRACE=true`.
/// - **First mark wins.** A milestone is a point on ONE launch
///   timeline; a remount (tab switch back to Home) must not
///   overwrite the cold-start reading, so repeat marks are ignored.
/// - **Queryable in tests.** [elapsed] / [marks] / [order] let the
///   Round 60 timing tests assert the ORDER and PRESENCE of
///   milestones (paint-before-network proof) without depending on
///   wall-clock values, which are never fabricated or asserted as
///   absolutes anywhere in the audit.
class LaunchTrace {
  LaunchTrace._();

  static final LaunchTrace instance = LaunchTrace._();

  /// Compile-time opt-in for debug printing of the marks.
  static const bool _printMarks =
      bool.fromEnvironment('LAUNCH_TRACE');

  /// Milestone names (fixed strings — see the class doc).
  static const String processStart = 'processStart';
  static const String cachesWarmed = 'cachesWarmed';
  static const String runAppCalled = 'runApp';
  static const String firstFrame = 'firstFrame';
  static const String sessionRestored = 'sessionRestored';
  static const String homeSeededFromCache = 'homeSeededFromCache';
  static const String homeFreshData = 'homeFreshData';

  final Stopwatch _clock = Stopwatch()..start();
  final Map<String, Duration> _marks = <String, Duration>{};
  final List<String> _order = <String>[];

  /// Records [name] at the current elapsed time. Repeat marks of
  /// the same name are ignored (first wins — see class doc).
  void mark(String name) {
    if (_marks.containsKey(name)) return;
    final elapsed = _clock.elapsed;
    _marks[name] = elapsed;
    _order.add(name);
    if (_printMarks) {
      debugPrint('LaunchTrace: $name at ${elapsed.inMilliseconds}ms');
    }
  }

  /// Elapsed time of [name], or null when it never fired on this
  /// launch (e.g. [homeSeededFromCache] on a cold cache).
  Duration? elapsed(String name) => _marks[name];

  /// Whether [name] has fired.
  bool has(String name) => _marks.containsKey(name);

  /// All marks, in firing order (unmodifiable).
  List<String> get order => List<String>.unmodifiable(_order);

  /// All marks by name (unmodifiable).
  Map<String, Duration> get marks =>
      Map<String, Duration>.unmodifiable(_marks);

  /// Test-only reset: clears every mark and restarts the clock so
  /// one test's launch timeline never leaks into the next.
  @visibleForTesting
  void debugReset() {
    _marks.clear();
    _order.clear();
    _clock
      ..reset()
      ..start();
  }
}
