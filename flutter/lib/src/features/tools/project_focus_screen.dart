import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 18 (Team B) — Project Focus tool, READ-ONLY port of the native
/// `ProjectFocusScreen.kt` "details" view.
///
/// Data source: `decodeProfileList((await fetchProfile())['focusState'])`
/// — the server-synced `FocusStateDto` JSON blob. The first decoded map is
/// treated as the focus state; `activeTests` (or a lone test-shaped map)
/// become the read-only test list.
///
/// Rendered (layout per native):
/// - Active-test selector row (local selection only — no server write).
/// - Header card: status badge (Complete / In Progress), title, desc,
///   progress bar ("Day X of N", "N days left" / "Done!").
/// - Today's Check-In card, read-only (no Yes/No logging — deferred).
/// - Log History calendar grid + Completed/Missed/Upcoming legend.
/// - Empty state ("What are you trying to work towards?") when there are
///   no active tests.
///
/// DEFERRED (display-only round): the whole creation flow (struggle
/// input → AI suggestions → measure metric → setup → lock-in), daily
/// check-in logging, undo, cancel, and the jottracker.com results links.
/// Check-ins are logged from the main Tabs app.

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

  /// Tolerant parse: null on a map that isn't test-shaped. Never throws.
  static FocusTest? fromJson(Map<String, dynamic> json) {    try {
      final title = json['title']?.toString().trim() ?? '';
      final durationRaw = json['durationDays'];
      final startRaw = json['startTimestamp'];
      if (title.isEmpty ||
          durationRaw is! num ||
          startRaw is! num ||
          durationRaw.toInt() <= 0) {
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
        durationDays: durationRaw.toInt(),
        startTimestamp: startRaw.toInt(),
        lockDayStr: json['lockDayStr']?.toString(),
        logs: logs,
        measureMetric: json['measureMetric']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }

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

String _dateStr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _lockDayStr(DateTime d) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  return '${days[d.weekday - 1]} ${months[d.month - 1]} '
      '${d.day.toString().padLeft(2, '0')} ${d.year}';
}

class ProjectFocusScreen extends StatefulWidget {
  /// Injectable for tests.
  final TabsBackend? backend;

  const ProjectFocusScreen({super.key, this.backend});

  @override
  State<ProjectFocusScreen> createState() => _ProjectFocusScreenState();
}

class _ProjectFocusScreenState extends State<ProjectFocusScreen> {
  late final TabsBackend _backend;
  bool _loading = true;
  List<FocusTest> _tests = const [];
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _backend = widget.backend ?? TabsBackend();
    _load();
  }

  Future<void> _load() async {
    try {
      final profile = await _backend.fetchProfile();
      final decoded = TabsBackend.decodeProfileList(profile?['focusState']);
      final tests = collectFocusTests(decoded);
      if (!mounted) return;
      setState(() {
        _tests = tests;
        // Founder-directed: an in-progress test is selected; with none,
        // the screen opens in the new-project/empty flow (completed tests
        // stay reachable via the selector chips).
        _selectedId = defaultSelectedTestId(decoded, tests);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      // Honest empty on any failure — nothing is invented.
      setState(() {
        _tests = const [];
        _loading = false;
      });
    }
  }

  FocusTest? get _selected {
    final id = _selectedId;
    if (id == null) return null; // new-project/empty flow
    for (final t in _tests) {
      if ((t.id ?? t.title) == id) return t;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back,
            color: NotelColors.textPrimary,
            semanticLabel: 'Back',
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Project Focus',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
      ),
      body: _loading
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: NotelColors.primary),
                  SizedBox(height: 16),
                  Text(
                    'Syncing your projects…',
                    style: TextStyle(
                      fontSize: 14,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                ],
              ),
            )
          : _selected == null
              ? _emptyState()
              : _detailsView(_selected!),
    );
  }

  Widget _emptyState() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Completed tests stay reachable via the selector chips even
          // when nothing is in progress (founder direction).
          if (_tests.isNotEmpty) ...[
            _testSelector(),
            const SizedBox(height: 16),
          ],
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0x590A0A0E),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.08),
              ),
            ),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Project Focus',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    color: NotelColors.textPrimary,
                  ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 6),
                Text(
                  'What are you trying to work towards?',
                  style: TextStyle(
                    fontSize: 14,
                    color: NotelColors.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 16),
                Text(
                  'No active experiments right now. Creating new projects is coming soon — for now, set one up in the main Tabs app and it will appear here.',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: NotelColors.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailsView(FocusTest test) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 90),
      children: [
        if (_tests.length > 1) _testSelector(),
        if (_tests.length > 1) const SizedBox(height: 16),
        _headerCard(test),
        const SizedBox(height: 16),
        const Text(
          "Today's Check-In",
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w900,
            letterSpacing: 1,
            color: NotelColors.textSecondary,
          ),
        ),
        const SizedBox(height: 10),
        _checkInCard(test),
        const SizedBox(height: 16),
        const Text(
          'Log History',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w900,
            letterSpacing: 1,
            color: NotelColors.textSecondary,
          ),
        ),
        const SizedBox(height: 10),
        _logCalendar(test),
        const SizedBox(height: 12),
        _legend(),
      ],
    );
  }

  Widget _testSelector() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final t in _tests) ...[
            _testChip(t),
            const SizedBox(width: 10),
          ],
        ],
      ),
    );
  }

  Widget _testChip(FocusTest t) {
    final key = t.id ?? t.title;
    final selected = key == _selectedId;
    return GestureDetector(
      onTap: () => setState(() => _selectedId = key),
      child: Container(
        constraints: const BoxConstraints(minWidth: 120, maxWidth: 180),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? NotelColors.primary.withValues(alpha: 0.20)
              : Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? NotelColors.primary
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              t.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${t.durationDays} Days',
              style: const TextStyle(
                fontSize: 10,
                color: NotelColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _headerCard(FocusTest test) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final startMs = test.startTimestamp;
    final durationMs = test.durationDays * 24 * 60 * 60 * 1000;
    final elapsedMs = nowMs - startMs;
    final leftMs =
        elapsedMs < 0 ? durationMs : (durationMs - elapsedMs).clamp(0, durationMs);
    final isCompleted = leftMs <= 0;
    final daysLeft = elapsedMs < 0
        ? test.durationDays
        : (leftMs / (24 * 60 * 60 * 1000)).ceil();
    final daysElapsed = elapsedMs < 0
        ? 0
        : (elapsedMs ~/ (24 * 60 * 60 * 1000) + 1).clamp(0, test.durationDays);
    final progress = test.durationDays > 0
        ? (daysElapsed / test.durationDays).clamp(0.0, 1.0)
        : 1.0;

    final badgeColor = isCompleted ? NotelColors.success : NotelColors.primary;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            NotelColors.primary.withValues(alpha: 0.08),
            Colors.transparent,
          ],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: NotelColors.primary.withValues(alpha: 0.4),
          width: 2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  isCompleted
                      ? '✅ Complete. Results ready.'
                      : '⏳ In Progress',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5,
                    color: badgeColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            test.title,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              height: 1.27,
              color: NotelColors.textPrimary,
            ),
          ),
          if (test.desc != null && test.desc!.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              test.desc!,
              style: const TextStyle(
                fontSize: 13,
                height: 1.38,
                color: NotelColors.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Day $daysElapsed of ${test.durationDays}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: NotelColors.textSecondary,
                ),
              ),
              Text(
                isCompleted
                    ? 'Done!'
                    : '$daysLeft day${daysLeft == 1 ? '' : 's'} left',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: isCompleted
                      ? NotelColors.success
                      : NotelColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: Colors.white.withValues(alpha: 0.07),
              valueColor: AlwaysStoppedAnimation<Color>(
                isCompleted ? NotelColors.success : NotelColors.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _checkInCard(FocusTest test) {
    final now = DateTime.now();
    final todayStr = _dateStr(now);
    final startMs = test.startTimestamp;
    final elapsedMs = now.millisecondsSinceEpoch - startMs;
    final isFirstDay = test.lockDayStr == _lockDayStr(now);
    final checkedInToday =
        test.logs.containsKey(todayStr) || isFirstDay;

    if (elapsedMs < 0) {
      return _statusCard(
        emoji: '🔒',
        title: 'Day 0: Waiting to start',
        subtitle: 'Your experiment will begin tomorrow. Get ready!',
        accent: NotelColors.primary,
      );
    }
    if (checkedInToday) {
      return _statusCard(
        emoji: isFirstDay ? '🔒' : '✅',
        title: isFirstDay
            ? 'New test locked in!'
            : 'Response logged for today!',
        subtitle: isFirstDay
            ? 'Your check-in opens at midnight (12:00 AM) so you have time to perform the experiment first.'
            : 'Resets at midnight (12:00 AM)',
        accent: isFirstDay ? NotelColors.primary : NotelColors.success,
      );
    }
    // Read-only: no Yes/No buttons (check-in logging is deferred).
    return _statusCard(
      emoji: '⏳',
      title: 'Not checked in yet',
      subtitle:
          'Daily check-ins are logged from the main Tabs app.',
      accent: NotelColors.textSecondary,
    );
  }

  Widget _statusCard({
    required String emoji,
    required String title,
    required String subtitle,
    required Color accent,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: accent.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Text(emoji, style: const TextStyle(fontSize: 24)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: accent,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11,
                    color: accent.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _logCalendar(FocusTest test) {
    final startDate = DateTime.fromMillisecondsSinceEpoch(
      test.startTimestamp,
      isUtc: true,
    ).toLocal();
    final startDay =
        DateTime(startDate.year, startDate.month, startDate.day);
    final today = DateTime.now();
    final todayStr = _dateStr(today);
    final nowDay = DateTime(today.year, today.month, today.day);

    // Cap the grid so a corrupt duration can't build a huge list.
    final totalDays = test.durationDays.clamp(1, 91);
    final weeks = <List<int>>[];
    for (var i = 0; i < totalDays; i += 7) {
      weeks.add([
        for (var j = i; j < i + 7 && j < totalDays; j++) j,
      ]);
    }

    return Column(
      children: [
        for (final week in weeks)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                for (final dayOffset in week) ...[
                  Expanded(
                    child: _dayCell(
                      test: test,
                      date: startDay.add(Duration(days: dayOffset)),
                      dayNumber: dayOffset + 1,
                      todayStr: todayStr,
                      nowDay: nowDay,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                for (var k = week.length; k < 7; k++)
                  const Expanded(child: SizedBox()),
              ],
            ),
          ),
      ],
    );
  }

  Widget _dayCell({
    required FocusTest test,
    required DateTime date,
    required int dayNumber,
    required String todayStr,
    required DateTime nowDay,
  }) {
    final dateStr = _dateStr(date);
    final isToday = dateStr == todayStr;
    final isFuture = date.isAfter(nowDay);
    final logValue = test.logs[dateStr];
    final missed = logValue == false || (logValue == null && !isToday && !isFuture);

    late final Color bg;
    late final Color border;
    late final Widget inner;
    if (logValue == true) {
      bg = NotelColors.success.withValues(alpha: 0.25);
      border = NotelColors.success.withValues(alpha: 0.4);
      inner = const Text(
        '✓',
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w900,
          color: NotelColors.success,
        ),
      );
    } else if (missed) {
      bg = NotelColors.error.withValues(alpha: 0.15);
      border = NotelColors.error.withValues(alpha: 0.3);
      inner = const Text(
        '✗',
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w900,
          color: NotelColors.error,
        ),
      );
    } else if (isToday) {
      bg = NotelColors.primary.withValues(alpha: 0.1);
      border = NotelColors.primary.withValues(alpha: 0.4);
      inner = Text(
        '$dayNumber',
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: NotelColors.primary,
        ),
      );
    } else if (isFuture) {
      bg = Colors.white.withValues(alpha: 0.04);
      border = Colors.white.withValues(alpha: 0.05);
      inner = Text(
        '$dayNumber',
        style: TextStyle(
          fontSize: 10,
          color: Colors.white.withValues(alpha: 0.15),
        ),
      );
    } else {
      bg = Colors.white.withValues(alpha: 0.04);
      border = Colors.white.withValues(alpha: 0.05);
      inner = Text(
        '$dayNumber',
        style: const TextStyle(
          fontSize: 10,
          color: NotelColors.textSecondary,
        ),
      );
    }

    return AspectRatio(
      aspectRatio: 1,
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: border),
        ),
        alignment: Alignment.center,
        child: inner,
      ),
    );
  }

  Widget _legend() {
    return Row(
      children: [
        _legendItem(NotelColors.success, 'Completed'),
        const SizedBox(width: 16),
        _legendItem(NotelColors.error, 'Missed'),
        const SizedBox(width: 16),
        _legendItem(NotelColors.legacyDarkHairline, 'Upcoming'),
      ],
    );
  }

  Widget _legendItem(Color dot, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            color: NotelColors.textSecondary,
          ),
        ),
      ],
    );
  }
}
