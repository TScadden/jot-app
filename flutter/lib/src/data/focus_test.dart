import 'dart:convert';

/// Pure Project Focus test model — the data-layer home of the
/// focus-test types that used to live in
/// `features/tools/project_focus_screen.dart`.
///
/// Moved here (with the screen re-exporting every symbol) so the
/// data layer — in particular `notification_service.dart`'s Project
/// Focus reminder projection, which mirrors native
/// `ProjectReminderWorker.kt` — can consume the model without
/// importing a feature screen. The screen's behavior is unchanged:
/// this file holds exactly the model code the screen defined.
///
/// Data shape: the server-synced `FocusStateDto` JSON blob
/// (`focusState` profile field) — see the Project Focus screen for
/// the read/write flow.

/// One read-only active test — mirrors native `ActiveProjectTest`.
class FocusTest {
  final String? id;
  final String title;
  final String? desc;
  final int durationDays;
  final int startTimestamp; // epoch ms
  final String? lockDayStr;
  final Map<String, bool> logs; // "YYYY-MM-DD" → did it
  final String? measureMetric;

  const FocusTest({
    this.id,
    required this.title,
    this.desc,
    required this.durationDays,
    required this.startTimestamp,
    this.lockDayStr,
    this.logs = const {},
    this.measureMetric,
  });

  /// Tolerant parse: null on a map that isn't test-shaped. Numbers
  /// may arrive as strings (server serialization) — both are
  /// accepted. Never throws.
  static FocusTest? fromJson(Map<String, dynamic> json) {    try {
      final title = json['title']?.toString().trim() ?? '';
      int? asInt(dynamic v) =>
          v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
      final durationRaw = asInt(json['durationDays']);
      final startRaw = asInt(json['startTimestamp']);
      if (title.isEmpty ||
          durationRaw == null ||
          startRaw == null ||
          durationRaw <= 0) {
        return null;
      }
      final logs = <String, bool>{};
      final logsRaw = json['logs'];
      if (logsRaw is Map) {
        logsRaw.forEach((k, v) {
          if (v is bool) logs[k.toString()] = v;
        });
      } else if (logsRaw is String && logsRaw.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(logsRaw);
          if (decoded is Map) {
            decoded.forEach((k, v) {
              if (v is bool) logs[k.toString()] = v;
            });
          }
        } catch (_) {}
      }
      return FocusTest(
        id: json['id']?.toString(),
        title: title,
        desc: json['desc']?.toString(),
        durationDays: durationRaw,
        startTimestamp: startRaw,
        lockDayStr: json['lockDayStr']?.toString(),
        logs: logs,
        measureMetric: json['measureMetric']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }

  FocusTest copyWith({Map<String, bool>? logs}) {
    return FocusTest(
      id: id,
      title: title,
      desc: desc,
      durationDays: durationDays,
      startTimestamp: startTimestamp,
      lockDayStr: lockDayStr,
      logs: logs ?? this.logs,
      measureMetric: measureMetric,
    );
  }

  /// Serializes back to the native `ActiveProjectTest` blob shape.
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'desc': desc,
        'durationDays': durationDays,
        'startTimestamp': startTimestamp,
        'lockDayStr': lockDayStr,
        'logs': logs,
        'measureMetric': measureMetric,
      };

  /// Mirrors native `ProjectFocusScreen.kt` (`leftMs <= 0` where
  /// `leftMs = max(durationMs - elapsedMs, 0)`).
  /// Pure and unit-testable via [nowMs].
  bool isCompletedAt(int nowMs) {
    const msPerDay = 24 * 60 * 60 * 1000;
    final durationMs = durationDays * msPerDay;
    final elapsedMs = nowMs - startTimestamp;
    final leftMs =
        elapsedMs < 0 ? durationMs : (durationMs - elapsedMs).clamp(0, durationMs);
    return leftMs <= 0;
  }

  /// True when the test's window has fully elapsed, device-local now.
  bool get isCompleted =>
      isCompletedAt(DateTime.now().millisecondsSinceEpoch);
}

/// Collects every active test from the decoded focusState maps.
/// Accepts the native `FocusStateDto` shape (`activeTests` / `activeTest`
/// arrays) and, tolerantly, a lone test-shaped map.
List<FocusTest> collectFocusTests(List<Map<String, dynamic>> decoded) {
  final out = <FocusTest>[];
  final seen = <String>{};
  void add(FocusTest t) {
    final key = t.id ?? '${t.title}|${t.startTimestamp}';
    if (seen.add(key)) out.add(t);
  }

  for (final map in decoded) {
    for (final key in const ['activeTests', 'tests']) {
      final raw = map[key];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map<String, dynamic>) {
            final t = FocusTest.fromJson(item);
            if (t != null) add(t);
          }
        }
      }
    }
    final active = map['activeTest'];
    if (active is Map<String, dynamic>) {
      final t = FocusTest.fromJson(active);
      if (t != null) add(t);
    }
    // Tolerate a blob that IS a single test.
    if (!map.containsKey('activeTests') && !map.containsKey('activeTest')) {
      final t = FocusTest.fromJson(map);
      if (t != null) add(t);
    }
  }
  return out;
}

/// Default test selection on open.
///
/// Founder-directed behavior (deliberate divergence from native, which
/// falls back to `tests.firstOrNull()` even when that test completed):
/// - If an in-progress test exists, select it — preferring the blob's
///   persisted `selectedTestId`, then the blob's `activeTest`, then the
///   first in-progress test.
/// - If NO in-progress test exists, return null so the screen opens in
///   the new-project/empty flow ("What are you trying to work towards?").
///   Completed tests stay reachable via the selector chips (manual tap).
/// A `selectedTestId`/`activeTest` naming a completed test is never
/// auto-selected. Pure and unit-tested.
String? defaultSelectedTestId(
    List<Map<String, dynamic>> decoded, List<FocusTest> tests) {
  String keyOf(FocusTest t) => t.id ?? t.title;
  final inProgress = tests.where((t) => !t.isCompleted).toList();
  if (inProgress.isEmpty) return null;
  final inProgressKeys = {for (final t in inProgress) keyOf(t)};
  for (final map in decoded) {
    final sid = map['selectedTestId']?.toString().trim();
    if (sid != null && sid.isNotEmpty && inProgressKeys.contains(sid)) {
      return sid;
    }
  }
  for (final map in decoded) {
    final active = map['activeTest'];
    if (active is Map<String, dynamic>) {
      final t = FocusTest.fromJson(active);
      final key = t == null ? null : keyOf(t);
      // inProgressKeys membership already guarantees not-completed.
      if (key != null && key.isNotEmpty && inProgressKeys.contains(key)) {
        return key;
      }
    }
  }
  final first = inProgress.first;
  return first.id ?? first.title;
}
