import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/habit_time.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/skeleton.dart';

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
/// - NO habit rename: a rename via delete+recreate would destroy
///   the habit's server-side log history, so renaming is
///   deliberately not built. VC 100137 adds the ONE supported edit:
///   the scheduled time (add-flow chip + per-card editor, PATCH
///   `/api/habits/{id}`), with its notification projection.
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
/// VC 100137 — optional scheduled time per habit (add chip, per-card
/// time editor) + the bounded one-shot notification projection.
///
/// [backend] is injectable so widget tests can drive the screen with a
/// mock client; production defaults to a real [TabsBackend].
/// [notificationService] is injectable the same way (the pattern of
/// RemindersScreen / SettingsScreen); production defaults to the
/// local plugin service.
class HabitsScreen extends StatefulWidget {
  final TabsBackend? backend;
  final ReminderNotificationService? notificationService;

  /// Test seam for the habit daily aggregate reminder's toggle:
  /// when non-null it is the value handed to
  /// [ReminderSync.syncHabitDailyOnly]; when null (production)
  /// the toggle is read from the sync pull's profile
  /// (`habitReminderEnabled`) at sync time.
  final bool? habitReminderEnabled;

  const HabitsScreen({
    super.key,
    this.backend,
    this.notificationService,
    this.habitReminderEnabled,
  });

  @override
  State<HabitsScreen> createState() => _HabitsScreenState();
}

class _HabitsScreenState extends State<HabitsScreen> {
  late final TabsBackend _backend;
  late final ReminderNotificationService _notifService;
  late final HabitTimeReminderSync _habitTimeSync;
  late final ReminderSync _habitDailySync;
  final TextEditingController _addController = TextEditingController();
  bool _loading = true;
  bool _failed = false;
  bool _adding = false;
  bool _writing = false; // any habit write in flight (fix round, Vera B3)
  List<HabitDto> _habits = const [];

  /// The add flow's picked time; null = Anytime (no set time).
  TimeOfDay? _addTime;

  @override
  void initState() {
    super.initState();
    _backend = widget.backend ?? TabsBackend();
    _notifService =
        widget.notificationService ?? LocalReminderNotificationService();
    _habitTimeSync = HabitTimeReminderSync(_notifService);
    _habitDailySync = ReminderSync(_notifService);
    _load();
  }

  /// Re-projects every habit's scheduled-time one-shots from the
  /// given list (VC 100137). Deliberately NOT awaited by callers:
  /// the sync is a device-state side effect of the list state, and
  /// its window sweep is dozens of plugin calls — holding a load,
  /// a save, or the [_writing] serializer open for it would delay
  /// the UI for bookkeeping the user never sees (and, with the
  /// real plugin service, channel replies land on the real event
  /// loop, which widget tests' fake-async pumps starve — the
  /// r47 habits tests caught exactly that wedge). Execution is
  /// serialized through [_notifSyncChain], so ordering follows
  /// list-state order exactly; the next load/write re-syncs again
  /// regardless.
  ///
  /// Failure handling, decided: a [NotificationServiceException]
  /// is logged (debugPrint, with its visible code) and swallowed —
  /// never a reason to fail a load, a save, or a toggle the server
  /// already accepted, and a snackbar on every load failure would
  /// train the user to ignore the screen's real error messages.
  /// A transient failure self-heals at the next sync.
  /// The notification-sync chain: syncs execute strictly in the
  /// order they were initiated (a slow load sync can never re-arm
  /// a one-shot a later toggle sync already cancelled), while no
  /// caller ever awaits them. Every link catches its own failures,
  /// so the chain itself never completes with an error.
  Future<void> _notifSyncChain = Future<void>.value();

  void _syncHabitNotifications(List<HabitDto> habits) {
    _notifSyncChain = _notifSyncChain.then((_) async {
      try {
        await _habitTimeSync.syncHabits(habits);
      } on NotificationServiceException catch (e) {
        debugPrint('HabitTimeReminderSync failed: $e');
      } catch (e) {
        // The local service converts plugin failures to
        // NotificationServiceException by contract; anything else
        // is a programming error — log it, still never break the
        // screen over notification bookkeeping.
        debugPrint('HabitTimeReminderSync unexpected failure: $e');
      }
      // The habit daily aggregate reminder re-projects from the
      // same list state, in the same chain link (so its ordering
      // relative to the timed projection follows list-state order
      // exactly): completing the last habit drops tonight's 19:00
      // one-shot, un-completing re-arms it. Its failures follow
      // the same decided rule — logged with the visible code,
      // swallowed, self-healing at the next sync.
      try {
        await _habitDailySync.syncHabitDailyOnly(
          habitEnabled: await _habitReminderEnabled(),
          habits: habits,
        );
      } on NotificationServiceException catch (e) {
        debugPrint('HabitDailyReminderSync failed: $e');
      } catch (e) {
        debugPrint('HabitDailyReminderSync unexpected failure: $e');
      }
    });
  }

  /// The Settings "Habit Reminders" toggle for the aggregate
  /// daily reminder: the widget override when one was injected
  /// (tests), else the sync pull's profile flag — the same
  /// `habitReminderEnabled` value Settings hands [ReminderSync].
  /// The pull is TTL-cached and [_toggleHabit] invalidates it
  /// after a write, so this reads live state without a new
  /// endpoint. An unreadable profile resolves to OFF: the
  /// projection then cancels only, never arms on a guess.
  Future<bool> _habitReminderEnabled() async {
    final override = widget.habitReminderEnabled;
    if (override != null) return override;
    try {
      final profile = await _backend.fetchProfile();
      final v = profile?['habitReminderEnabled'];
      return v == true || v == 'true';
    } catch (_) {
      return false;
    }
  }

  /// Cancels one deleted habit's scheduled-time window (VC 100137);
  /// same chained, fire-and-forget + failure rules as
  /// [_syncHabitNotifications].
  void _cancelHabitNotifications(String habitId) {
    _notifSyncChain = _notifSyncChain.then((_) async {
      try {
        await _habitTimeSync.cancelHabit(habitId);
      } on NotificationServiceException catch (e) {
        debugPrint('HabitTimeReminderSync cancel failed: $e');
      } catch (e) {
        debugPrint('HabitTimeReminderSync cancel unexpected failure: $e');
      }
    });
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
      // VC 100137: a fresh list is a new projection input.
      _syncHabitNotifications(habits);
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
  /// re-fetches the list the same way). Fix-round hardening: a
  /// refetch failure after a successful write now SURFACES an error
  /// instead of silently leaving a stale list on screen.
  ///
  /// Round 48 (Vera R47 ledger): the refresh goes through the
  /// nullable fetch ([TabsBackend.fetchHabitsOrNull]). The old
  /// path called `fetchHabits()`, which returns `[]` on ANY
  /// failure — so a failed refresh silently BLANKED the list to
  /// the empty state until the next load, and this error message
  /// was unreachable (the backend never throws). Now a failed
  /// refresh (null) surfaces the error and PRESERVES the list
  /// already on screen; only a successful fetch replaces it.
  Future<void> _refresh() async {
    try {
      final habits = await _backend.fetchHabitsOrNull();
      if (!mounted) return;
      if (habits == null) {
        _showError(
            'Saved, but the habit list could not be refreshed. Check your connection and try again.');
        return;
      }
      setState(() => _habits = habits);
      // VC 100137: every successful refresh re-projects the
      // scheduled-time one-shots (add and time-change flow through
      // here; toggle and delete sync on their own paths).
      _syncHabitNotifications(habits);
    } catch (_) {
      // Defensive: a throwing backend override is a failed refresh
      // too — same message, list preserved.
      _showError(
          'Saved, but the habit list could not be refreshed. Check your connection and try again.');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Native add: title (blank rejected, trimmed) → `POST /api/habits`
  /// → re-fetch. Serialized with every other habit write (Vera B3):
  /// taps are dropped while [_writing].
  ///
  /// VC 100137: the add flow's time chip contributes the picked
  /// time (stored `'HH:mm'`, or `'Anytime'` when none was picked).
  /// After a successful add the picker state resets to Anytime.
  Future<void> _addHabit() async {
    final title = _addController.text.trim();
    if (title.isEmpty || _writing) return;
    _writing = true;
    setState(() => _adding = true);
    try {
      final created = await _backend.createHabit(
        title,
        targetTime: _addTime == null
            ? kHabitAnytime
            : formatHabitTargetTimeForStorage(_addTime!),
      );
      if (!mounted) return;
      if (created == null) {
        _showError(
            'Could not add that habit. Check your connection and try again.');
        return;
      }
      _addController.clear();
      setState(() => _addTime = null);
      _backend.invalidateSyncPull();
      await _refresh();
    } finally {
      _writing = false;
      if (mounted) setState(() => _adding = false);
    }
  }

  /// Add-flow time chip tap: pick (or re-pick) the new habit's
  /// time. Cancelling the picker leaves the current choice alone.
  Future<void> _pickAddTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _addTime ?? TimeOfDay.now(),
    );
    if (picked == null || !mounted) return;
    setState(() => _addTime = picked);
  }

  /// VC 100137 — the per-habit time editor: a small dialog with
  /// 'Pick a time' (opens the time picker seeded with the current
  /// time, or now when Anytime), 'Anytime' (clears the set time),
  /// and 'Cancel' (no change). The labels are Juno-signed as a set
  /// (juno-copy-100137.md, item 3). Saving goes through
  /// [TabsBackend.updateHabitTargetTime], serialized through
  /// [_writing] like every other habit write; a failure shows the
  /// Juno-signed error and preserves the old value (no optimistic
  /// update is ever applied).
  Future<void> _editHabitTime(HabitDto habit) async {
    if (_writing) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: NotelColors.surface,
        title: Text(
          habit.title,
          style: TextStyle(
            color: NotelColors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop('pick'),
              child: const Text('Pick a time'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop('anytime'),
              child: const Text('Anytime'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    final String targetTime;
    if (choice == 'anytime') {
      targetTime = kHabitAnytime;
    } else {
      final picked = await showTimePicker(
        context: context,
        initialTime:
            habitTargetTimeOfDay(habit.targetTime) ?? TimeOfDay.now(),
      );
      if (picked == null || !mounted) return;
      targetTime = formatHabitTargetTimeForStorage(picked);
    }
    await _saveHabitTime(habit, targetTime);
  }

  /// The PATCH leg of [_editHabitTime], serialized via [_writing].
  /// On success the list refreshes (which also re-syncs the
  /// notification projection, [_refresh]).
  Future<void> _saveHabitTime(HabitDto habit, String targetTime) async {
    if (_writing) return;
    _writing = true;
    setState(() {});
    try {
      final ok = await _backend.updateHabitTargetTime(
        habitId: habit.id,
        targetTime: targetTime,
      );
      if (!mounted) return;
      if (!ok) {
        _showError(
            'Could not save that time. Check your connection and try again.');
        return;
      }
      _backend.invalidateSyncPull();
      await _refresh();
    } finally {
      _writing = false;
      if (mounted) setState(() {});
    }
  }

  /// Native delete: `DELETE /api/habits/{id}` → re-fetch on success.
  /// Serialized with every other habit write (Vera B3).
  Future<void> _deleteHabit(HabitDto habit) async {
    if (_writing) return;
    _writing = true;
    try {
      final ok = await _backend.deleteHabit(habit.id);
      if (!mounted) return;
      if (!ok) {
        _showError(
            'Could not delete that habit. Check your connection and try again.');
        return;
      }
      _backend.invalidateSyncPull();
      await _refresh();
      // VC 100137: the deleted habit is no longer in the refreshed
      // list, so its scheduled-time window is cancelled explicitly,
      // after the successful delete, by its id.
      _cancelHabitNotifications(habit.id);
    } finally {
      _writing = false;
      if (mounted) setState(() {});
    }
  }

  /// Card tap toggles TODAY's log: optimistic local update via the
  /// existing `logHabit` write; failure reverts + shows an error.
  /// Serialized with every other habit write (Vera B3): a second
  /// toggle attempted while this log write is pending is dropped,
  /// never queued into an out-of-order second write.
  Future<void> _toggleHabit(HabitDto habit) async {
    if (_writing) return;
    _writing = true;
    try {
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
      // VC 100137: completing today lands today in the habit's
      // completed dates, so the re-projection cancels today's
      // pending one-shot; un-completing re-arms today when its
      // time is still ahead. The list synced is the optimistic
      // (server-confirmed) one already on screen.
      // The same re-projection also re-arms/drops the habit
      // daily aggregate 19:00 one-shot (see
      // [_syncHabitNotifications]): completing the LAST habit
      // drops tonight's aggregate, un-completing re-arms it.
      _syncHabitNotifications(_habits);
    } finally {
      _writing = false;
      if (mounted) setState(() {});
    }
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
          icon: Icon(
            Icons.arrow_back,
            color: NotelColors.textPrimary,
            semanticLabel: 'Back',
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
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
      return const SkeletonGroup(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 110),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonBox(height: 64, radius: 20),
              SizedBox(height: 16),
              SkeletonBox(height: 110, radius: 20),
              SizedBox(height: 16),
              SkeletonBox(height: 110, radius: 20),
            ],
          ),
        ),
      );
    }
    if (_failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Couldn\'t load habits',
                style: TextStyle(
                  color: NotelColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
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
                child: const Text('Try again'),
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
          _addTimeChip(),
          const SizedBox(height: 16),
          if (overallStreak > 0) ...[
            _streakBanner(overallStreak),
            const SizedBox(height: 12),
          ],
          Text(
            subtitle,
            style: TextStyle(
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
  /// (spinner while loading) or IME Done submits.
  Widget _addField() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _addController,
            style: TextStyle(
              color: NotelColors.textPrimary,
              fontSize: 14,
            ),
            decoration: InputDecoration(
              hintText: 'Add new routine habit...',
              hintStyle: TextStyle(
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
                  horizontal: 16, vertical: 12),
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
            onPressed: _writing ? null : _addHabit,
          ),
      ],
    );
  }

  /// VC 100137 — the add flow's time chip, directly under the add
  /// field: a schedule icon + 'Anytime' by default (Juno-signed
  /// label) or the picked time in the user's locale format, with
  /// a clear (✕) action when a time is set. Tapping opens the
  /// time picker ([_pickAddTime]).
  Widget _addTimeChip() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InputChip(
        key: const ValueKey('habit_add_time_chip'),
        avatar: Icon(
          Icons.schedule,
          size: 16,
          color: NotelColors.textSecondary,
        ),
        label: Text(
          _addTime == null ? kHabitAnytime : _addTime!.format(context),
          style: TextStyle(
            color: NotelColors.textPrimary,
            fontSize: 12,
          ),
        ),
        backgroundColor: NotelColors.surfaceHigh.withValues(alpha: 0.1),
        onPressed: _writing ? null : _pickAddTime,
        onDeleted: _addTime == null
            ? null
            : () => setState(() => _addTime = null),
        deleteIconColor: NotelColors.textSecondary,
      ),
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
          Icon(Icons.whatshot,
              color: NotelColors.warning, size: 28),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$streak day streak!',
                  style: TextStyle(
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
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('🔥', style: TextStyle(fontSize: 48)),
          SizedBox(height: 16),
          Text(
            'No habits yet',
            style: TextStyle(
              color: NotelColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Add your first daily routine above!',
            style: TextStyle(
              color: NotelColors.textSecondary,
              fontSize: 13,
              height: 1.5,
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
      padding: const EdgeInsets.only(bottom: 110),
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
      // separate button and wins its own tap. While a write is in
      // flight the tap is disabled entirely (Vera B3).
      onTap: _writing ? null : () => _toggleHabit(habit),
      child: Container(
      constraints: const BoxConstraints(minHeight: 100),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: checked
            ? NotelColors.primary.withValues(alpha: 0.15)
            : NotelColors.surface,
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
                icon: Icon(
                  Icons.close,
                  color: NotelColors.textSecondary,
                  size: 14,
                  semanticLabel: 'Delete habit',
                ),
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: _writing ? null : () => _deleteHabit(habit),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            habit.title,
            style: TextStyle(
              color: NotelColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.bold,
              height: 16 / 13,
            ),
          ),
          // Native shows the habit's target time under the title
          // (`habit.target_time ?: "Anytime"` — the DTO already
          // defaults a missing value to "Anytime"). Round 48:
          // the Flutter card parsed this field but never rendered
          // it; restored for native parity.
          //
          // VC 100137: the stored value is rendered for DISPLAY
          // (locale format, e.g. `7:30 AM`; Anytime stays Anytime),
          // and the row is its own tap target that opens the time
          // editor — an InkWell here wins the gesture arena over
          // the card's toggle GestureDetector, exactly like the
          // delete ✕ above, so editing never toggles today's log.
          InkWell(
            key: ValueKey('habit_time_${habit.id}'),
            onTap: _writing ? null : () => _editHabitTime(habit),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.schedule,
                    size: 11,
                    color: NotelColors.textSecondary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    formatHabitTargetTimeForDisplay(
                        habit.targetTime, context),
                    style: TextStyle(
                      color: NotelColors.textSecondary,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
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
