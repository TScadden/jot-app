import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 18 — Habits tool screen (display).
/// Round 47 — WRITE actions, porting native `HabitsScreen.kt`:
///
/// - Data: `TabsBackend.fetchHabits()` (GET /api/habits), i.e. real data —
///   nothing is invented. A failure or missing token yields the honest
///   empty state (the backend never throws; it returns `[]`).
/// - Renders: back + "Daily Habits" title bar, the "N/M DONE" pill, the
///   overall-streak banner (only when the streak is > 0), the subtitle +
///   progress bar, and the 2-per-row habit cards with the native streak
///   badge (✅ / 🔥 N) and the 7-day dot strip ending today.
/// - Add: the inline field pinned at the top ("Add new routine
///   habit...") — title only, blank rejected, trimmed — POSTs
///   `/api/habits` then re-fetches (native parity).
/// - Tap a card: toggles TODAY's log via `POST /api/habits/log`
///   (optimistic; failure reverts + shows an error).
/// - Delete: small ✕ at the card's top-right, no confirmation →
///   `DELETE /api/habits/{id}` → re-fetch on success.
/// - NO habit edit: native has none and no update endpoint exists;
///   a rename via delete+recreate would destroy the habit's
///   server-side log history, so editing is deliberately not built.
///
/// Pure helpers ([todayDateString], [isHabitCheckedToday], [habitStreak],
/// [overallHabitStreak], [habitDayMarks]) mirror the native
/// `HabitRepository`/`HabitViewModel` logic exactly and are unit-tested.

/// Today's date as a local `yyyy-MM-dd` string (native `todayDateString()`).
String todayDateString() {
  final now = DateTime.now();
  return _dayString(DateTime(now.year, now.month, now.day));
}

/// Whether the habit's `logs` contain today's date string.
bool isHabitCheckedToday(HabitDto habit) =>
    habit.logs.contains(todayDateString());

/// Port of `HabitRepository.calculateStreak`: consecutive-day count ending
/// today (or yesterday — the streak is still alive). 0 when the most
/// recent log is older than yesterday or the list is unparsable.
int habitStreak(List<String> logs) {
  if (logs.isEmpty) return 0;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final dates = <DateTime>{};
  for (final s in logs) {
    final d = _parseDay(s);
    if (d != null) dates.add(d);
  }
  if (dates.isEmpty) return 0;
  final mostRecent = dates.reduce((a, b) => a.isAfter(b) ? a : b);
  DateTime start;
  if (mostRecent == today) {
    start = today;
  } else if (mostRecent == yesterday) {
    start = yesterday;
  } else {
    return 0;
  }
  final sorted = dates.toList()..sort((a, b) => b.compareTo(a));
  var streak = 0;
  var expected = start;
  for (final d in sorted) {
    if (d == expected) {
      streak++;
      expected = expected.subtract(const Duration(days: 1));
    } else {
      break;
    }
  }
  return streak;
}

/// Port of `HabitRepository.calculateOverallStreak`: streak over the
/// dates ALL habits share (the intersection of their log sets).
int overallHabitStreak(List<HabitDto> habits) {
  if (habits.isEmpty) return 0;
  final sets = habits.map((h) => h.logs.toSet()).toList();
  final common = sets.reduce((a, b) => a.intersection(b)).toList();
  return habitStreak(common);
}

/// One day in the 7-day pacing strip, oldest first (native `HabitDayMark`).
class HabitDayMark {
  final String dayLabel; // single-letter weekday, e.g. "M"
  final bool completed;
  final bool isToday;

  const HabitDayMark({
    required this.dayLabel,
    required this.completed,
    required this.isToday,
  });
}

/// Port of `HabitViewModel.getLast7DayMarks`: last 7 days ending today,
/// oldest first, from the habit's already-synced log dates.
List<HabitDayMark> habitDayMarks(List<String> logs) {
  const labels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
  final set = logs.toSet();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return List.generate(7, (i) {
    final d = today.subtract(Duration(days: 6 - i));
    return HabitDayMark(
      dayLabel: labels[d.weekday - 1],
      completed: set.contains(_dayString(d)),
      isToday: i == 6,
    );
  });
}

String _dayString(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime? _parseDay(String s) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(s.trim());
  if (m == null) return null;
  try {
    return DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!),
        int.parse(m.group(3)!));
  } catch (_) {
    return null;
  }
}

/// Round 18 — Habits screen. Round 47 — add / delete / tap-to-log.
///
/// [backend] is injectable so widget tests can drive the screen with a
/// mock client; production defaults to a real [TabsBackend].
class HabitsScreen extends StatefulWidget {
  final TabsBackend? backend;

  const HabitsScreen({super.key, this.backend});

  @override
  State<HabitsScreen> createState() => _HabitsScreenState();
}

class _HabitsScreenState extends State<HabitsScreen> {
  late final TabsBackend _backend;
  final TextEditingController _addController = TextEditingController();
  bool _loading = true;
  bool _failed = false;
  bool _adding = false;
  List<HabitDto> _habits = const [];

  @override
  void initState() {
    super.initState();
    _backend = widget.backend ?? TabsBackend();
    _load();
  }

  @override
  void dispose() {
    _addController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final habits = await _backend.fetchHabits();
      if (!mounted) return;
      setState(() {
        _habits = habits;
        _loading = false;
      });
    } catch (_) {
      // TabsBackend is contractually non-throwing (null/empty on failure);
      // this is a defensive last resort — never a crash.
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  /// Re-fetch without the full-screen spinner (after a write, native
  /// re-fetches the list the same way).
  Future<void> _refresh() async {
    try {
      final habits = await _backend.fetchHabits();
      if (!mounted) return;
      setState(() => _habits = habits);
    } catch (_) {
      // Keep the current list; the write itself already reported.
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Native add: title only (blank rejected, trimmed) →
  /// `POST /api/habits` → re-fetch.
  Future<void> _addHabit() async {
    final title = _addController.text.trim();
    if (title.isEmpty || _adding) return;
    setState(() => _adding = true);
    final created = await _backend.createHabit(title);
    if (!mounted) return;
    setState(() => _adding = false);
    if (created == null) {
      _showError(
          'Could not add that habit. Check your connection and try again.');
      return;
    }
    _addController.clear();
    _backend.invalidateSyncPull();
    await _refresh();
  }

  /// Native delete: `DELETE /api/habits/{id}` → re-fetch on success.
  Future<void> _deleteHabit(HabitDto habit) async {
    final ok = await _backend.deleteHabit(habit.id);
    if (!mounted) return;
    if (!ok) {
      _showError(
          'Could not delete that habit. Check your connection and try again.');
      return;
    }
    _backend.invalidateSyncPull();
    await _refresh();
  }

  /// Card tap toggles TODAY's log: optimistic local update via the
  /// existing `logHabit` write; failure reverts + shows an error.
  Future<void> _toggleHabit(HabitDto habit) async {
    final today = todayDateString();
    final wasChecked = habit.logs.contains(today);
    final previous = _habits;
    setState(() {
      _habits = [
        for (final h in _habits)
          if (h.id == habit.id)
            HabitDto(
              id: h.id,
              title: h.title,
              logs: wasChecked
                  ? h.logs.where((l) => l != today).toList()
                  : [...h.logs, today],
              targetTime: h.targetTime,
            )
          else
            h,
      ];
    });
    final ok = await _backend.logHabit(
      habitId: habit.id,
      date: today,
      completed: !wasChecked,
    );
    if (!mounted) return;
    if (!ok) {
      setState(() => _habits = previous);
      _showError(
          'Could not update that habit. Check your connection and try again.');
      return;
    }
    _backend.invalidateSyncPull();
  }

  @override
  Widget build(BuildContext context) {
    final checkedCount = _habits.where(isHabitCheckedToday).length;
    final progressRatio =
        _habits.isEmpty ? 0.0 : checkedCount / _habits.length;

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
          'Daily Habits',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
        actions: [
          if (_habits.isNotEmpty && !_loading)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color:
                        NotelColors.primary.withValues(alpha: 0.1),
                    border: Border.all(
                      color:
                          NotelColors.primary.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Text(
                    '$checkedCount/${_habits.length} DONE',
                    style: const TextStyle(
                      color: NotelColors.primary,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: _buildBody(checkedCount, progressRatio),
    );
  }

  Widget _buildBody(int checkedCount, double progressRatio) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: NotelColors.primary),
      );
    }
    if (_failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Couldn\'t load habits',
                style: TextStyle(
                  color: NotelColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Check your connection and try again.',
                style: TextStyle(
                  color: NotelColors.textSecondary,
                  fontSize: 13,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _load,
                style: FilledButton.styleFrom(
                    backgroundColor: NotelColors.primary),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final overallStreak = overallHabitStreak(_habits);
    final subtitle = _habits.isEmpty
        ? 'No habits yet. Add your first habit above to get started.'
        : checkedCount == _habits.length
            ? 'All done today! Amazing work 🎉'
            : 'Keep it up. You\'re on a roll!';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _addField(),
          const SizedBox(height: 16),
          if (overallStreak > 0) ...[
            _streakBanner(overallStreak),
            const SizedBox(height: 12),
          ],
          Text(
            subtitle,
            style: const TextStyle(
              color: NotelColors.textSecondary,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 8),
          // Progress bar (native: 4dp, CircleShape clip).
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: SizedBox(
              height: 4,
              child: LinearProgressIndicator(
                value: progressRatio,
                backgroundColor:
                    NotelColors.surfaceHigh.withValues(alpha: 0.1),
                valueColor: AlwaysStoppedAnimation<Color>(
                  progressRatio == 1.0
                      ? NotelColors.success
                      : NotelColors.primary,
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Expanded(
            child: _habits.isEmpty ? _emptyState() : _habitGrid(),
          ),
        ],
      ),
    );
  }

  /// The inline add field pinned at the top of the screen (native):
  /// placeholder "Add new routine habit...", the add IconButton
  /// (spinner while loading) or IME Done submits. Title only.
  Widget _addField() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _addController,
            style: const TextStyle(
              color: NotelColors.textPrimary,
              fontSize: 14,
            ),
            decoration: InputDecoration(
              hintText: 'Add new routine habit...',
              hintStyle: const TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 14,
              ),
              filled: true,
              fillColor: NotelColors.surfaceHigh.withValues(alpha: 0.1),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 12),
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _addHabit(),
          ),
        ),
        const SizedBox(width: 8),
        if (_adding)
          const SizedBox(
            width: 40,
            height: 40,
            child: Padding(
              padding: EdgeInsets.all(8),
              child: CircularProgressIndicator(
                  color: NotelColors.primary, strokeWidth: 2),
            ),
          )
        else
          IconButton(
            icon: const Icon(
              Icons.add_circle,
              color: NotelColors.primary,
              size: 28,
              semanticLabel: 'Add habit',
            ),
            onPressed: _addHabit,
          ),
      ],
    );
  }

  Widget _streakBanner(int streak) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          colors: [
            NotelColors.warning.withValues(alpha: 0.20),
            const Color(0xFFFF6B35).withValues(alpha: 0.15),
          ],
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.whatshot,
              color: NotelColors.warning, size: 28),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$streak day streak!',
                  style: const TextStyle(
                    color: NotelColors.warning,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  'You completed every habit $streak day${streak == 1 ? '' : 's'} in a row',
                  style: TextStyle(
                    color:
                        NotelColors.warning.withValues(alpha: 0.7),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('🔥', style: TextStyle(fontSize: 40)),
          SizedBox(height: 12),
          Text(
            'No habits yet',
            style: TextStyle(
              color: NotelColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Add your first daily routine above!',
            style: TextStyle(
              color: NotelColors.textSecondary,
              fontSize: 13,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _habitGrid() {
    final rows = <List<HabitDto>>[];
    for (var i = 0; i < _habits.length; i += 2) {
      rows.add(_habits.sublist(
          i, i + 2 > _habits.length ? _habits.length : i + 2));
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 100),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final row = rows[index];
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _habitCard(row[0])),
            const SizedBox(width: 10),
            if (row.length == 2)
              Expanded(child: _habitCard(row[1]))
            else
              const Spacer(),
          ],
        );
      },
    );
  }

  Widget _habitCard(HabitDto habit) {
    final checked = isHabitCheckedToday(habit);
    final streak = habitStreak(habit.logs);
    final marks = habitDayMarks(habit.logs);
    return GestureDetector(
      // Card tap toggles today's log (native). The ✕ below is a
      // separate button and wins its own tap.
      onTap: () => _toggleHabit(habit),
      child: Container(
      constraints: const BoxConstraints(minHeight: 100),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: checked
            ? NotelColors.primary.withValues(alpha: 0.15)
            : NotelColors.surfaceHigh.withValues(alpha: 0.1),
        border: Border.all(
          color: checked
              ? NotelColors.primary.withValues(alpha: 0.3)
              : NotelColors.legacyDarkHairlineFaint,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _streakBadge(checked, streak),
              // Native per-card ✕ delete (top-right, no confirmation).
              IconButton(
                icon: const Icon(
                  Icons.close,
                  color: NotelColors.textSecondary,
                  size: 14,
                  semanticLabel: 'Delete habit',
                ),
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 20, minHeight: 20),
                onPressed: () => _deleteHabit(habit),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            habit.title,
            style: const TextStyle(
              color: NotelColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.bold,
              height: 16 / 13,
            ),
          ),
          const SizedBox(height: 8),
          _weekDots(marks),
        ],
      ),
      ),
    );
  }

  Widget _streakBadge(bool checked, int streak) {
    final String label;
    final Color bg;
    final Color fg;
    if (checked) {
      label = '✅';
      bg = NotelColors.success.withValues(alpha: 0.15);
      fg = NotelColors.success;
    } else if (streak > 0) {
      label = '🔥 $streak';
      bg = NotelColors.warning.withValues(alpha: 0.15);
      fg = NotelColors.warning;
    } else {
      label = '·';
      bg = Colors.transparent;
      fg = NotelColors.textSecondary;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: bg,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: fg,
        ),
      ),
    );
  }

  Widget _weekDots(List<HabitDayMark> marks) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: marks.map((mark) {
        final Color dotColor;
        BoxBorder? border;
        if (mark.completed) {
          dotColor = NotelColors.primary;
        } else if (mark.isToday) {
          dotColor = Colors.transparent;
          border = Border.all(color: NotelColors.primary);
        } else {
          dotColor =
              NotelColors.textSecondary.withValues(alpha: 0.18);
        }
        return Column(
          children: [
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: dotColor,
                border: border,
              ),
              child: mark.completed
                  ? const Icon(Icons.check,
                      color: Colors.white, size: 9)
                  : null,
            ),
            const SizedBox(height: 2),
            Text(
              mark.dayLabel,
              style: TextStyle(
                fontSize: 8,
                fontWeight: mark.isToday
                    ? FontWeight.bold
                    : FontWeight.normal,
                color: mark.isToday
                    ? NotelColors.textPrimary
                    : NotelColors.textSecondary,
              ),
            ),
          ],
        );
      }).toList(),
    );
  }
}
