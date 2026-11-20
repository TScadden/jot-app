import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'daily_score_background.dart' show LocalDailyScoreReadyNotifier;
import 'focus_test.dart';
import 'streak_engine.dart';
import 'habit_time.dart';
import 'health_data.dart' show HabitDto;
import 'migraine_notification.dart' show LocalMigraineNotifier;
import 'report_ready_notification.dart' show LocalReportReadyNotifier;

/// Round 30 — local notification scheduling for the Settings reminder
/// toggles, mirroring the native app.
///
/// Native evidence:
/// - Habit reminders: `HabitReminderWorker` (worker/HabitReminderWorker.kt)
///   — a one-shot WorkManager chain pinned to the next 19:00 local,
///   re-chained after every run; posts `NotificationHelper.showHabitReminder`
///   (util/NotificationHelper.kt:118-143) only when an unchecked habit
///   remains that day.
/// - Project reminders: `NotelApp.scheduleProjectReminder` (NotelApp.kt:
///   94-115) — PeriodicWorkRequest with initial delay to 20:00 local;
///   `ProjectReminderWorker` posts `showProjectReminder`
///   (NotificationHelper.kt:272-302) only when an active project test
///   still needs today's check-in.
/// - Check-in reminder: `EnergyCheckInReminderScheduler`
///   (notifications/EnergyCheckInReminderScheduler.kt) — exact alarm at
///   04:00 local; the receiver skips the post when today's feeling
///   check-in already exists and re-arms the next day.
/// - Event reminders: `EventScheduler.scheduleEventNotification`
///   (notifications/EventScheduler.kt) — one exact alarm per event
///   counter at 09:00 on the target date, armed when a counter is
///   saved (SettingsViewModel.kt:1270) and re-armed for non-archived,
///   non-count-up counters on boot (service/BootReceiver.kt:56-58);
///   the receiver re-checks the toggle before posting.
///
/// Flutter mapping: flutter_local_notifications `zonedSchedule` with
/// `matchDateTimeComponents: DateTimeComponents.time` gives the same
/// daily wall-clock recurrence for the habit daily reminder, and a
/// plain one-shot `zonedSchedule` per event counter and per
/// projected gate-fix date (Project Focus and, since VC 100138,
/// the check-in reminder). The plugin's boot receiver restores
/// schedules after a reboot.
///
/// Known deviation (flagged in the round report): the plugin cannot
/// run Dart code at fire time, so the habit "only if still
/// unchecked" gate (evaluated at fire time in native) cannot be
/// re-evaluated when the notification fires. That schedule fires
/// daily while the toggle is on; the subtitle copy on the
/// Notifications page says exactly what each reminder does. The
/// check-in "only if not checked in yet" gate is no longer part of
/// this deviation — see the check-in gate fix below.
///
/// Project Focus gate fix: the project reminder no longer fires
/// daily unconditionally. Native `ProjectReminderWorker` evaluates
/// its gate at fire time (an active, not-yet-completed test with no
/// check-in for today); the Flutter equivalent is a bounded one-shot
/// projection — [projectReminderFireTimes] precomputes, at sync
/// time, the 20:00 dates inside the next
/// [projectReminderHorizonDays] days on which the native gate WOULD
/// pass, and [ReminderSync] arms one one-shot per such date. A test
/// that completes, or a day that gets checked in, drops out at the
/// next sync; with no qualifying test nothing is armed at all.
///
/// Check-in gate fix (VC 100138): the check-in reminder no longer
/// fires daily unconditionally, and it no longer fires at 04:00.
/// Native evaluated its gate at fire time (skip when today's
/// feeling check-in already exists); the Flutter equivalent is the
/// same bounded one-shot projection shape —
/// [checkInReminderFireTimes] precomputes, at sync time, the
/// 20:00 dates inside the next [checkInReminderHorizonDays] days
/// whose Tabs day is NOT already checked in (checked-in Tabs-day
/// labels come from the sync pull via
/// `SettingsProfileData.checkedInDayLabels`, attributed by
/// `energyDayLabel`), and [ReminderSync] arms one one-shot per
/// such date. A check-in that gets saved drops today's one-shot at
/// the next sync — Home re-runs the projection on save (see
/// [ReminderSync.syncCheckInOnly]).
///
/// HR spike / delta alerts are NOT scheduled here: native runs them
/// from `HrSpikeMonitorService` (service/HrSpikeMonitorService.kt), a
/// persistent foreground service polling Health Connect every 30 s.
/// That is a separate flagged item (battery + foreground-service
/// compliance), not part of this service.
///
/// Failure rule (team lesson): no call in here fails silently — every
/// plugin failure is rethrown as a [NotificationServiceException]
/// carrying a visible code the UI surfaces.
class NotificationServiceException implements Exception {
  final String code;
  const NotificationServiceException(this.code);
  @override
  String toString() => 'NotificationServiceException($code)';
}

/// V-1 correction (Vera MAJOR) — the ONE app-level owner of
/// `FlutterLocalNotificationsPlugin.initialize` in the foreground
/// isolate.
///
/// flutter_local_notifications is a singleton: EVERY initialize()
/// call replaces the response callback wholesale. Before this
/// bootstrap existed, [LocalReminderNotificationService.initialize]
/// initialized with NO callback and is reached from ordinary
/// screens (Settings, Reminders, Progress Reports, Coach,
/// onboarding — each building fresh service instances), so any of
/// those screens erased the Daily Score notifier's tap callback
/// in-session: foreground/backgrounded score taps then did
/// nothing (only terminated-state taps survived, via the launch
/// details).
///
/// The rule now: `main()` runs [initialize] once, with ONE
/// dispatching callback. A payload matching
/// [LocalDailyScoreReadyNotifier.isScorePayload] routes to the
/// score tap handler the notifier registers via
/// [registerScoreTapHandler]; anything else keeps the reminder
/// service's previous behavior — no callback, i.e. a no-op.
/// Both services SKIP their own plugin.initialize once the
/// bootstrap has run (they call [initialize], which joins the
/// in-flight run or no-ops). The background isolate never runs
/// this bootstrap (WorkManager's entry point is separate), so
/// the score notifier's posting-only initialize there is
/// unaffected.
class NotificationBootstrap {
  NotificationBootstrap._();

  static bool _initialized = false;
  static Future<void>? _initializing;
  static void Function(String date)? _scoreTapHandler;
  static void Function()? _migraineTapHandler;
  static void Function()? _reportReadyTapHandler;

  /// Whether the foreground plugin.initialize has completed.
  static bool get isInitialized => _initialized;

  /// Whether a bootstrap initialize has been started (completed
  /// or still in flight) in this isolate.
  static bool get initializationStarted =>
      _initialized || _initializing != null;

  /// Registers the Daily Score notification tap handler (the
  /// notifier's `onTap`). Registration is independent of plugin
  /// initialization order: the dispatching callback reads this
  /// at tap time.
  static void registerScoreTapHandler(void Function(String date) handler) {
    _scoreTapHandler = handler;
  }

  /// Registers the migraine-timer notification tap handler (the
  /// migraine notifier's `onTap`). The payload is the constant
  /// [LocalMigraineNotifier.payload] — it carries no data; the
  /// handler ends the active attack (see the migraine controller).
  static void registerMigraineTapHandler(void Function() handler) {
    _migraineTapHandler = handler;
  }

  /// Registers the report-ready notification tap handler (the
  /// report notifier's `onTap`). The payload is the constant
  /// [LocalReportReadyNotifier.payload] — it carries no data; the
  /// handler returns the user to the held share confirmation on
  /// the Progress Reports page.
  static void registerReportReadyTapHandler(void Function() handler) {
    _reportReadyTapHandler = handler;
  }

  /// The dispatching response callback handed to the plugin —
  /// also directly callable in tests.
  static void dispatchNotificationResponse(NotificationResponse response) {
    final payload = response.payload;
    if (LocalMigraineNotifier.isMigrainePayload(payload)) {
      _migraineTapHandler?.call();
      return;
    }
    if (LocalReportReadyNotifier.isReportReadyPayload(payload)) {
      _reportReadyTapHandler?.call();
      return;
    }
    if (LocalDailyScoreReadyNotifier.isScorePayload(payload)) {
      _scoreTapHandler?.call(payload!);
    }
    // Anything else: the reminder service's previous no-op
    // behavior — reminder taps carry no routing.
  }

  /// Initializes the plugin ONCE for this isolate with the
  /// dispatching callback. Concurrent callers share the in-flight
  /// run; later callers no-op. A failure clears the in-flight
  /// state so a later call can retry, and is reported as
  /// [NotificationServiceException] `INIT_FAILED`, matching the
  /// reminder service's existing failure contract.
  static Future<void> initialize(FlutterLocalNotificationsPlugin plugin) {
    if (_initialized) return Future<void>.value();
    final inFlight = _initializing;
    if (inFlight != null) return inFlight;
    final run = _run(plugin);
    _initializing = run;
    return run;
  }

  static Future<void> _run(FlutterLocalNotificationsPlugin plugin) async {
    try {
      final ok = await plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
        onDidReceiveNotificationResponse: dispatchNotificationResponse,
      );
      if (ok != true) {
        throw const NotificationServiceException('INIT_FAILED');
      }
      _initialized = true;
    } catch (_) {
      _initializing = null;
      throw const NotificationServiceException('INIT_FAILED');
    }
  }

  @visibleForTesting
  static void debugReset() {
    _initialized = false;
    _initializing = null;
    _scoreTapHandler = null;
    _migraineTapHandler = null;
    _reportReadyTapHandler = null;
  }
}

/// One event-counter reminder to arm (or cancel).
class EventReminderRequest {
  final String counterId;
  final String name;
  final int targetDateMs;
  final bool isArchived;
  final bool isUp;

  /// Delete stamp (epoch ms) from the counter's Delete action, or
  /// null when not deleted. A deleted counter never arms an alarm —
  /// checked alongside [isArchived] so even a legacy row whose
  /// archive marker is missing cannot fire after a delete.
  final int? deletedAt;

  const EventReminderRequest({
    required this.counterId,
    required this.name,
    required this.targetDateMs,
    required this.isArchived,
    required this.isUp,
    this.deletedAt,
  });

  /// The unified non-active predicate (Oct 28, 2026 — the same
  /// rule as `EventCounterItem.isActive` in settings_profile.dart,
  /// mirrored here because this request type is the projection's
  /// input shape): a counter is non-active iff it is archived OR
  /// carries a delete stamp. A non-active counter never arms.
  bool get isNonActive => isArchived || deletedAt != null;
}

/// The scheduling surface the Settings screen depends on. The real
/// implementation is [LocalReminderNotificationService]; tests inject
/// a fake.
abstract class ReminderNotificationService {
  Future<void> initialize();
  Future<bool> areNotificationsEnabled();
  Future<bool> requestNotificationsPermission();
  Future<bool> canScheduleExact();
  Future<void> requestExactAlarmsPermission();
  Future<void> scheduleDaily({
    required int id,
    required String title,
    required String body,
    required String channelId,
    required String channelName,
    required int hour,
    required int minute,
    required bool highImportance,
  });
  Future<void> scheduleOnce({
    required int id,
    required String title,
    required String body,
    required String channelId,
    required String channelName,
    required DateTime when,
    required bool highImportance,
  });

  /// Round 47 — weekly schedule on one weekday (native user-reminder
  /// per-day slots). [weekday] uses java Calendar constants
  /// (SUNDAY=1 … SATURDAY=7) — the same numbering as the reminders
  /// blob's `dayOfWeek` and, verified against
  /// flutter_local_notifications 19.5.0 `lib/src/types.dart`, the
  /// plugin's `Day` enum values (`sunday(1)` … `saturday(7)`), so
  /// [dayForCalendarDayOfWeek] is an identity-value mapping.
  Future<void> scheduleWeekly({
    required int id,
    required String title,
    required String body,
    required String channelId,
    required String channelName,
    required int weekday,
    required int hour,
    required int minute,
    required bool highImportance,
  });

  /// Streak countdown one-shot (Community Added Scope #2): like
  /// [scheduleOnce], but the Android details carry a LIVE
  /// chronometer counting down to [countdownTo] (the next Tabs
  /// day boundary — see [nextTabsDayBoundary]) and a timeout at
  /// that same instant, so the system removes the notification
  /// at rollover even if the app never runs again. [when] is the
  /// 20:00 fire time; the chronometer target and the timeout are
  /// both derived from [countdownTo] by the implementation.
  Future<void> scheduleStreakCountdownOnce({
    required int id,
    required String title,
    required String body,
    required String channelId,
    required String channelName,
    required String channelDescription,
    required DateTime when,
    required DateTime countdownTo,
    required bool highImportance,
  });
  Future<void> cancel(int id);
}

/// Round 47 — java Calendar day-of-week constant for a local
/// [DateTime] (SUNDAY=1 … SATURDAY=7). Dart's `DateTime.weekday`
/// is Mon=1 … Sun=7, hence the rotate.
int calendarDayOfWeek(DateTime d) => d.weekday % 7 + 1;

/// Round 47 — the plugin `Day` for a Calendar day-of-week constant.
/// flutter_local_notifications 19.5.0 declares
/// `enum Day { sunday(1), monday(2), …, saturday(7) }`, so the enum
/// ordinal and value both line up 1:1 with the Calendar constants
/// the reminders blob stores. Out-of-range input clamps to Monday,
/// mirroring the DayTimeConfig dayName fallback.
Day dayForCalendarDayOfWeek(int calendarDay) {
  if (calendarDay < 1 || calendarDay > 7) return Day.monday;
  return Day.values[calendarDay - 1];
}

/// Round 47 — next local wall-clock instance of [hour]:[minute] on
/// the Calendar weekday [calendarDay], strictly after [now] (today
/// when that weekday is today and the time is still ahead, else the
/// matching day within the next 7 days).
DateTime nextWeeklyInstance(
    DateTime now, int calendarDay, int hour, int minute) {
  for (var offset = 0; offset <= 7; offset++) {
    // Calendar-day iteration (not 24h durations) so DST transitions
    // cannot skip or repeat a candidate date.
    final t = DateTime(now.year, now.month, now.day + offset, hour, minute);
    if (calendarDayOfWeek(t) == calendarDay && t.isAfter(now)) return t;
  }
  // Unreachable: within 8 consecutive days the weekday recurs with
  // a time strictly after `now`. Returned only to satisfy the type.
  return DateTime(now.year, now.month, now.day + 7, hour, minute);
}

/// Next local wall-clock instance of [hour]:[minute] strictly after
/// [now] (today if still ahead, else tomorrow) — the same rule as
/// native's `HabitReminderWorker.schedule` and
/// `EnergyCheckInReminderScheduler.nextFourAm`.
DateTime nextDailyInstance(DateTime now, int hour, int minute) {
  var t = DateTime(now.year, now.month, now.day, hour, minute);
  if (!t.isAfter(now)) t = t.add(const Duration(days: 1));
  return t;
}

/// 09:00 local on the counter's target date (native
/// `EventScheduler`), or null when that moment has already passed
/// (native does not schedule past dates).
DateTime? eventFireTime(int targetDateMs, DateTime now) {
  final d = DateTime.fromMillisecondsSinceEpoch(targetDateMs);
  final t = DateTime(d.year, d.month, d.day, 9);
  return t.isAfter(now) ? t : null;
}

/// Stable plugin notification id for an event counter (djb2 — Dart's
/// String.hashCode is not a stable cross-run contract, and these ids
/// must survive restarts so re-arms replace rather than duplicate).
int eventNotificationId(String counterId) {
  var hash = 5381;
  for (final unit in counterId.codeUnits) {
    hash = ((hash * 33) + unit) & 0x7fffffff;
  }
  return 700000 + (hash % 99999);
}

/// Notification ids — native's notify ids where native has them
/// (NotificationHelper.kt:18-21, EnergyCheckInReminderScheduler
/// REQUEST_CODE 770001).
abstract class ReminderIds {
  static const habit = 1003;
  static const project = 1004;
  static const checkIn = 770001;
}

/// Project Focus one-shot projection horizon: [ReminderSync] looks
/// this many local days ahead (today included) when projecting
/// project one-shots, and cancels this many days either side of
/// today when sweeping stale ones (see [projectReminderCancelIds]).
const int projectReminderHorizonDays = 35;

/// Base of the projected Project Focus one-shot id block:
/// `800000 + (epochDay % 10000)` → 800000–809999.
///
/// Disjointness (verified against every other id owner in the app):
/// - Fixed ids 1003 / 1004 / 770001 / 7301 / 7303 / 7304: all lie
///   outside 800000–809999 (770001 is the largest of them and is
///   still below the block).
/// - Event-counter ids ([eventNotificationId]): 700000–799998 —
///   the block starts at 800000, strictly above that range's top.
/// - User-reminder blocks (`reminder_alarm_sync.dart`):
///   101500–699999 — strictly below the block.
/// - Check-in projection ids: 810000–819999 — strictly above
///   the block.
/// - Habit scheduled-time ids: 900000–1899999 — strictly above
///   the block.
/// Inside the block, distinct dates can share an id only when their
/// epoch days differ by a multiple of 10000 (~27 years); the
/// projection horizon and the cancellable window are both 71 days
/// wide at most, so two dates that could ever be pending at once
/// never collide.
const int projectReminderIdBase = 800000;

/// Span of the projected Project Focus one-shot id block (see
/// [projectReminderIdBase]).
const int projectReminderIdSpan = 10000;

/// Plugin notification id for the Project Focus one-shot on the
/// local calendar date of [date] (see [projectReminderIdBase] for
/// the disjointness proof).
int projectReminderIdForDate(DateTime date) {
  final epochDay = DateTime.utc(date.year, date.month, date.day)
          .millisecondsSinceEpoch ~/
      Duration.millisecondsPerDay;
  return projectReminderIdBase + (epochDay % projectReminderIdSpan);
}

/// Every projected Project Focus id a previous sync could have left
/// pending around [now]: the ids for local dates from
/// `today - [projectReminderHorizonDays]` through
/// `today + [projectReminderHorizonDays]`. A sync never projects
/// beyond today + horizon, and a one-shot projected for a past date
/// has already fired (or was projected at most horizon days before
/// that date), so sweeping this window reaches every stale
/// projected id.
Iterable<int> projectReminderCancelIds(DateTime now) sync* {
  for (var offset = -projectReminderHorizonDays;
      offset <= projectReminderHorizonDays;
      offset++) {
    yield projectReminderIdForDate(
        DateTime(now.year, now.month, now.day + offset));
  }
}

/// The `yyyy-MM-dd` log key for [d] — the key shape of
/// [FocusTest.logs] and native's `LocalDate.now().toString()`
/// in `ProjectReminderWorker`.
String focusLogDateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// [d] formatted `EEE MMM dd yyyy` (US locale) — native
/// `ProjectReminderWorker`'s lock-day comparison format
/// (`DateTimeFormatter.ofPattern("EEE MMM dd yyyy", Locale.US)`),
/// the same string the Project Focus screen's lock-in writes as
/// [FocusTest.lockDayStr].
String focusLockDayString(DateTime d) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  return '${days[d.weekday - 1]} ${months[d.month - 1]} '
      '${d.day.toString().padLeft(2, '0')} ${d.year}';
}

/// Whether [test] counts as checked in for the local date of [d] —
/// native `ProjectReminderWorker`'s rule: the day's log key is
/// PRESENT in [FocusTest.logs] (any value, true or false) OR the
/// date's lock-day string equals [FocusTest.lockDayStr] (the lock-in
/// day itself counts as checked in).
bool focusTestCheckedInOn(FocusTest test, DateTime d) =>
    test.logs.containsKey(focusLogDateKey(d)) ||
    test.lockDayStr == focusLockDayString(d);

/// Whether native `ProjectReminderWorker` would post for [test] if
/// it ran at [fireTime]: the test has started by then
/// ([FocusTest.startTimestamp] ≤ fire time), is not completed at
/// fire time (the worker's `elapsedMs >= durationMs` rule, via
/// [FocusTest.isCompletedAt]), and is not checked in for the fire
/// date ([focusTestCheckedInOn]).
bool focusTestNeedsReminderAt(FocusTest test, DateTime fireTime) {
  final fireMs = fireTime.millisecondsSinceEpoch;
  return test.startTimestamp <= fireMs &&
      !test.isCompletedAt(fireMs) &&
      !focusTestCheckedInOn(test, fireTime);
}

/// The bounded Project Focus projection: the 20:00-local fire times
/// [ReminderSync] arms as one-shots, mirroring native
/// `ProjectReminderWorker`'s fire-time gate as evaluated at sync
/// time. For each local date D from today through
/// today + [projectReminderHorizonDays] days, D's 20:00 fire time
/// qualifies iff it is strictly after [now] AND at least one test in
/// [tests] satisfies [focusTestNeedsReminderAt] at that fire time.
/// Dates are built by calendar-day arithmetic (never 24-hour
/// durations), so DST transitions cannot skip or repeat a date.
List<DateTime> projectReminderFireTimes({
  required DateTime now,
  required List<FocusTest> tests,
}) {
  if (tests.isEmpty) return const [];
  final out = <DateTime>[];
  for (var offset = 0; offset <= projectReminderHorizonDays; offset++) {
    final fire = DateTime(now.year, now.month, now.day + offset, 20);
    if (!fire.isAfter(now)) continue;
    if (tests.any((t) => focusTestNeedsReminderAt(t, fire))) {
      out.add(fire);
    }
  }
  return out;
}

/// Check-in reminder one-shot projection horizon: [ReminderSync]
/// looks this many local days ahead (today included) when
/// projecting check-in one-shots, and cancels this many days
/// either side of today when sweeping stale ones (see
/// [checkInReminderCancelIds]). The same 35-day bound as the
/// Project Focus projection.
const int checkInReminderHorizonDays = 35;

/// Base of the projected check-in one-shot id block:
/// `810000 + (epochDay % 10000)` → 810000–819999.
///
/// Disjointness (verified against every other id owner in the
/// app, by grepping the whole lib/ tree):
/// - Fixed ids 1003 / 1004 / 770001 / 7301 / 7303 / 7304: all lie
///   outside 810000–819999 (770001 is the largest of them and is
///   still below the block). 7301 is the Daily Score notifier
///   (`daily_score_background.dart`), 7303 the migraine notifier
///   (`migraine_notification.dart`), 7304 the report-ready
///   notifier (`report_ready_notification.dart`).
/// - Event-counter ids ([eventNotificationId]): 700000–799998 —
///   the block starts at 810000, strictly above that range's top.
/// - User-reminder blocks (`reminder_alarm_sync.dart`):
///   101500–699999 — strictly below the block.
/// - Project Focus projection ids: 800000–809999 — strictly
///   below the block.
/// - Habit scheduled-time ids: 900000–1899999 — strictly above
///   the block.
/// Inside the block, distinct dates can share an id only when
/// their epoch days differ by a multiple of 10000 (~27 years);
/// the projection horizon and the cancellable window are both
/// 71 days wide at most, so two dates that could ever be pending
/// at once never collide.
const int checkInReminderIdBase = 810000;

/// Span of the projected check-in one-shot id block (see
/// [checkInReminderIdBase]).
const int checkInReminderIdSpan = 10000;

/// Plugin notification id for the check-in one-shot on the local
/// calendar date of [date] (see [checkInReminderIdBase] for the
/// disjointness proof).
int checkInReminderIdForDate(DateTime date) {
  final epochDay = DateTime.utc(date.year, date.month, date.day)
          .millisecondsSinceEpoch ~/
      Duration.millisecondsPerDay;
  return checkInReminderIdBase + (epochDay % checkInReminderIdSpan);
}

/// Every projected check-in id a previous sync could have left
/// pending around [now]: the ids for local dates from
/// `today - [checkInReminderHorizonDays]` through
/// `today + [checkInReminderHorizonDays]`. A sync never projects
/// beyond today + horizon, and a one-shot projected for a past
/// date has already fired (or was projected at most horizon days
/// before that date), so sweeping this window reaches every
/// stale projected id.
Iterable<int> checkInReminderCancelIds(DateTime now) sync* {
  for (var offset = -checkInReminderHorizonDays;
      offset <= checkInReminderHorizonDays;
      offset++) {
    yield checkInReminderIdForDate(
        DateTime(now.year, now.month, now.day + offset));
  }
}

/// The bounded check-in projection (VC 100138): the 20:00-local
/// fire times [ReminderSync] arms as one-shots, mirroring
/// native's fire-time "only if not checked in yet" gate as
/// evaluated at sync time. For each local date D from today
/// through today + [checkInReminderHorizonDays] days, D's 20:00
/// fire time qualifies iff it is strictly after [now] AND D's
/// Tabs-day label is NOT in [checkedInDayLabels].
///
/// Attribution: [checkedInDayLabels] holds Tabs-day labels in
/// `energyDayLabel`'s `yyyy-MM-dd` format (the Daily Ranking
/// attribution — a check-in at 03:59 on calendar date D belongs
/// to Tabs day D−1; at 04:00+ it belongs to D). At 20:00 on
/// calendar date D the current Tabs day's label is D itself
/// (20:00 is past the 04:00 reset), so D's label is compared
/// directly — [focusLogDateKey] formats the same `yyyy-MM-dd`
/// shape. Dates are built by calendar-day arithmetic (never
/// 24-hour durations), so DST transitions cannot skip or repeat
/// a date.
List<DateTime> checkInReminderFireTimes({
  required DateTime now,
  required Set<String> checkedInDayLabels,
}) {
  final out = <DateTime>[];
  for (var offset = 0; offset <= checkInReminderHorizonDays; offset++) {
    final date = DateTime(now.year, now.month, now.day + offset);
    if (checkedInDayLabels.contains(focusLogDateKey(date))) continue;
    final fire = DateTime(date.year, date.month, date.day, 20);
    if (!fire.isAfter(now)) continue;
    out.add(fire);
  }
  return out;
}

/// Streak countdown one-shot projection horizon: [ReminderSync]
/// looks this many local days ahead (today included) when
/// projecting streak-countdown one-shots, and cancels this many
/// days either side of today when sweeping stale ones (see
/// [streakCountdownCancelIds]). The same 35-day bound as the
/// check-in and Project Focus projections.
const int streakCountdownHorizonDays = 35;

/// Base of the projected streak-countdown one-shot id block:
/// `820000 + (epochDay % 10000)` → 820000–829999.
///
/// Disjointness (verified against every other id owner in the
/// app, by grepping the whole lib/ tree):
/// - Fixed ids 1003 / 1004 / 770001 / 7301 / 7303 / 7304: all lie
///   below the block (770001 is the largest of them).
/// - Event-counter ids ([eventNotificationId]): 700000–799998 —
///   strictly below the block.
/// - User-reminder blocks (`reminder_alarm_sync.dart`):
///   101500–699999 — strictly below the block.
/// - Project Focus projection ids: 800000–809999 — strictly
///   below the block.
/// - Check-in projection ids: 810000–819999 — strictly below
///   the block.
/// - Habit scheduled-time ids: 900000–1899999 — strictly above
///   the block.
/// Inside the block, distinct dates can share an id only when
/// their epoch days differ by a multiple of 10000 (~27 years);
/// the projection horizon and the cancellable window are both
/// 71 days wide at most, so two dates that could ever be pending
/// at once never collide.
const int streakCountdownIdBase = 820000;

/// Span of the projected streak-countdown one-shot id block (see
/// [streakCountdownIdBase]).
const int streakCountdownIdSpan = 10000;

/// Plugin notification id for the streak-countdown one-shot on
/// the local calendar date of [date] (see
/// [streakCountdownIdBase] for the disjointness proof).
int streakCountdownIdForDate(DateTime date) {
  final epochDay = DateTime.utc(date.year, date.month, date.day)
          .millisecondsSinceEpoch ~/
      Duration.millisecondsPerDay;
  return streakCountdownIdBase + (epochDay % streakCountdownIdSpan);
}

/// Every projected streak-countdown id a previous sync could
/// have left pending around [now]: the ids for local dates from
/// `today - [streakCountdownHorizonDays]` through
/// `today + [streakCountdownHorizonDays]`. Cancelling an id also
/// removes a POSTED notification carrying it (the plugin's
/// cancel covers both), so this sweep is what takes down a
/// live countdown when its day resolves.
Iterable<int> streakCountdownCancelIds(DateTime now) sync* {
  for (var offset = -streakCountdownHorizonDays;
      offset <= streakCountdownHorizonDays;
      offset++) {
    yield streakCountdownIdForDate(
        DateTime(now.year, now.month, now.day + offset));
  }
}

/// The streak countdown channel (Community Added Scope #2,
/// founder-named; description ruled by Juno, NOTIF-COPY.md §2 —
/// ship byte-for-byte).
const String streakCountdownChannelId = 'streak_reminders';
const String streakCountdownChannelName = 'Streak reminders';
const String streakCountdownChannelDescription =
    'Shows in the evening when you have a streak going and '
    'today\'s Daily Summary is not finished, with the time left '
    'to extend your streak.';

/// The streak countdown title (Juno, NOTIF-COPY.md §1.1 — ship
/// byte-for-byte; sentence case, no terminal punctuation).
const String streakCountdownTitle =
    'Finish today\'s Daily Summary when you\'re ready';

/// The streak countdown body (Juno, NOTIF-COPY.md §1.2 — ship
/// byte-for-byte): [streak] is the settled current streak at
/// projection time; the lowercase `t` and the absent terminal
/// punctuation are intentional (the body is a continuation
/// clause composed with the live chronometer), and `day` never
/// pluralizes (§1.4 — only the numeral changes).
String streakCountdownBody(int streak) =>
    'to extend your $streak day streak';

/// The next Tabs day boundary strictly after [now], derived
/// ONLY from the streak engine's shared day definition
/// ([tabsDayStr], which routes through [tabsDayAnchor]): the
/// first whole second at which the Tabs-day label changes.
/// No boundary hour is named anywhere in this derivation, so
/// when the shared definition moves (Added Scope #3), this
/// target moves with it untouched. The search window is 48
/// hours — wider than any Tabs day (a boundary-shifted calendar
/// day is 23–25 hours across DST) — and the resolution is one
/// second, the precision of the boundary itself.
DateTime nextTabsDayBoundary(DateTime now) {
  final today = tabsDayStr(now);
  var lo = DateTime(now.year, now.month, now.day, now.hour,
      now.minute, now.second);
  var hi = lo.add(const Duration(hours: 48));
  // Invariants: tabsDayStr(lo) == today, tabsDayStr(hi) != today.
  while (hi.difference(lo) > const Duration(seconds: 1)) {
    final mid = lo
        .add(Duration(seconds: hi.difference(lo).inSeconds ~/ 2));
    if (tabsDayStr(mid) == today) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return hi;
}

/// The settled current streak the countdown gate and body read:
/// [streakCurrent] over the settled [state], anchored on the
/// Tabs day of [now] via [tabsDayAnchor] (the Home display
/// convention — streakCurrent takes the anchor, not the wall
/// clock).
int settledStreakForCountdown(StreakState state, DateTime now) =>
    streakCurrent(state, tabsDayAnchor(now));

/// Whether the Tabs day [tabsDay] qualifies for the streak
/// countdown under the settled [state]: the day's Daily Summary
/// is NOT complete (not in [StreakState.summaryCompletedDays]),
/// the day is NOT freeze-covered (not in
/// [StreakState.restoredDays] — the engine's record of a day a
/// freeze bridged), and the settled current streak is at least
/// 1 ([settledStreak] — computed once per projection by
/// [settledStreakForCountdown]).
bool streakCountdownDayQualifies({
  required StreakState state,
  required String tabsDay,
  required int settledStreak,
}) =>
    settledStreak >= 1 &&
    !state.summaryCompletedDays.contains(tabsDay) &&
    !state.restoredDays.contains(tabsDay);

/// The bounded streak-countdown projection (Community Added
/// Scope #2; the Nov 11 fire-time-gates lesson, check-in
/// precedent): the 20:00-local fire times [ReminderSync] arms as
/// chronometer one-shots. For each local date D from today
/// through today + [streakCountdownHorizonDays] days, D's 20:00
/// fire time qualifies iff it is strictly after [now] AND D's
/// Tabs day (via [tabsDayStr] of the fire moment) qualifies
/// under [streakCountdownDayQualifies] with the settled streak
/// at [now]. A null [state] (no settled streak record available
/// at the call site) projects nothing — the countdown is never
/// armed on a guess. Future days carry no completion or freeze
/// marks yet, so they project on the current settled streak;
/// every re-sync (app open, settlement, freeze events, any
/// [ReminderSync] run) re-projects, and a day that completes
/// drops out at that sync. Dates are built by calendar-day
/// arithmetic, so DST cannot skip or repeat one.
List<DateTime> streakCountdownFireTimes({
  required DateTime now,
  required StreakState? state,
}) {
  if (state == null) return const [];
  final streak = settledStreakForCountdown(state, now);
  if (streak < 1) return const [];
  final out = <DateTime>[];
  for (var offset = 0; offset <= streakCountdownHorizonDays; offset++) {
    final date = DateTime(now.year, now.month, now.day + offset);
    final fire = DateTime(date.year, date.month, date.day, 20);
    if (!fire.isAfter(now)) continue;
    if (!streakCountdownDayQualifies(
      state: state,
      tabsDay: tabsDayStr(fire),
      settledStreak: streak,
    )) {
      continue;
    }
    out.add(fire);
  }
  return out;
}

/// VC 100137 — habit scheduled-time reminders: the Juno-ruled body
/// copy (juno-copy-100137.md, item 1: SIGN WITH CHANGES — the
/// proposed "It is time to check off this habit in Tabs." was
/// rejected on voice). Wired verbatim, lowercase and punctuation
/// included; the title is the habit's own title. Do not edit
/// without a new Juno ruling.
const String habitTimeReminderBody =
    "whenever you're ready. one tap is enough.";

/// Habit scheduled-time projection horizon: [HabitTimeReminderSync]
/// looks this many local days ahead (today included), the same
/// 35-day bound as the Project Focus projection.
const int habitTimeReminderHorizonDays = 35;

/// Base of the habit scheduled-time one-shot id block:
/// `900000 + (djb2 % 1000000)` → 900000–1899999.
///
/// Disjointness (verified against every other id owner in the app):
/// - Fixed ids 1003 / 1004 / 770001 / 7301 / 7303 / 7304: all lie
///   below the block.
/// - Event-counter ids ([eventNotificationId]): 700000–799998 —
///   strictly below the block.
/// - Project Focus projection ids: 800000–809999 — strictly below
///   the block.
/// - Check-in projection ids: 810000–819999 — strictly below
///   the block.
/// - User-reminder blocks (`reminder_alarm_sync.dart`):
///   101500–699999 — strictly below the block.
/// Inside the block, an id is a hash of (habit id, date): two
/// DIFFERENT habits could in principle hash-collide on the same
/// date, and the same habit on two dates could collide across the
/// 73-day cancellable window only if the hashes coincide mod
/// 1000000. That is the same collision class the event-counter
/// scheme already accepts (djb2 into a 99999-wide block); here the
/// block is ten times wider and the habit count per user is small,
/// and a collision would only replace one habit's one-shot with
/// another's on a single date — never a wrong-time or duplicate
/// fire. The window/distinctness tests pin the practical cases.
const int habitTimeIdBase = 900000;

/// Span of the habit scheduled-time one-shot id block (see
/// [habitTimeIdBase]).
const int habitTimeIdSpan = 1000000;

/// Stable plugin notification id for [habitId]'s scheduled-time
/// reminder on the local calendar date of [date] (djb2 over
/// `'$habitId|yyyy-MM-dd'` — Dart's String.hashCode is not a stable
/// cross-run contract; see [eventNotificationId]).
int habitTimeNotificationId(String habitId, DateTime date) {
  final key = '$habitId|${focusLogDateKey(date)}';
  var hash = 5381;
  for (final unit in key.codeUnits) {
    hash = ((hash * 33) + unit) & 0x7fffffff;
  }
  return habitTimeIdBase + (hash % habitTimeIdSpan);
}

/// Every habit scheduled-time id a previous sync could have left
/// pending for [habitId] around [now]: the ids for local dates from
/// `today - [habitTimeReminderHorizonDays] - 1` through
/// `today + [habitTimeReminderHorizonDays] + 1` (the task's
/// today−36..today+36 sweep). A sync never projects beyond
/// today + horizon, and a one-shot projected for a past date has
/// already fired (or was projected at most horizon days before
/// that date), so sweeping this window reaches every stale id.
Iterable<int> habitTimeCancelIds(String habitId, DateTime now) sync* {
  for (var offset = -(habitTimeReminderHorizonDays + 1);
      offset <= habitTimeReminderHorizonDays + 1;
      offset++) {
    yield habitTimeNotificationId(
        habitId, DateTime(now.year, now.month, now.day + offset));
  }
}

/// The bounded habit scheduled-time projection (the Nov 11
/// fire-time-gates lesson, Project Focus precedent): for each local
/// date offset 0..[horizonDays], the fire time is that date at the
/// habit's stored HH:mm; it is included iff it is strictly after
/// [now] AND the date's `yyyy-MM-dd` key is NOT in [completedDates]
/// (the habit's log dates — a completed day never fires, and the
/// gate is re-projected at every sync that can change the inputs).
/// A [targetTime] with no specific time (`'Anytime'` or garbage,
/// per [parseHabitTargetTime]) projects nothing. Dates are built
/// by calendar-day arithmetic, so DST cannot skip or repeat one.
List<DateTime> habitTimeFireTimes({
  required DateTime now,
  required String targetTime,
  required Set<String> completedDates,
  int horizonDays = habitTimeReminderHorizonDays,
}) {
  final parsed = parseHabitTargetTime(targetTime);
  if (parsed == null) return const [];
  final out = <DateTime>[];
  for (var offset = 0; offset <= horizonDays; offset++) {
    final date = DateTime(now.year, now.month, now.day + offset);
    if (completedDates.contains(focusLogDateKey(date))) continue;
    final fire = DateTime(
        date.year, date.month, date.day, parsed.hour, parsed.minute);
    if (!fire.isAfter(now)) continue;
    out.add(fire);
  }
  return out;
}

/// Keeps habit scheduled-time one-shots in step with the habits
/// list. Separate from [ReminderSync.syncAll] on purpose: habit
/// times are per-habit data (not a Settings toggle), and their
/// inputs (the list, its times, its logs) change on the Habits
/// screen's own writes, which is where this sync is wired. Follows
/// the Project Focus pattern inside [ReminderSync]: cancel the
/// whole window on EVERY sync before re-arming — including the
/// notifications-disabled path and Anytime habits (cancel only).
class HabitTimeReminderSync {
  final ReminderNotificationService service;
  HabitTimeReminderSync(this.service);

  /// Re-projects every habit in [habits]: each habit's window is
  /// cancelled first; then, when notifications are enabled and the
  /// habit carries a specific time, one one-shot per projected
  /// fire time is armed on the existing `habit_reminders` channel
  /// (the local service sends the channel id as the payload, so
  /// the payload is `'habit_reminders'` by construction).
  Future<void> syncHabits(List<HabitDto> habits, {DateTime? now}) async {
    final n = now ?? DateTime.now();
    await service.initialize();
    final enabled = await service.areNotificationsEnabled();
    for (final habit in habits) {
      for (final id in habitTimeCancelIds(habit.id, n)) {
        await service.cancel(id);
      }
      if (!enabled) continue;
      if (!hasHabitTargetTime(habit.targetTime)) continue;
      for (final fire in habitTimeFireTimes(
        now: n,
        targetTime: habit.targetTime,
        completedDates: habit.logs.toSet(),
      )) {
        await service.scheduleOnce(
          id: habitTimeNotificationId(habit.id, fire),
          title: habit.title,
          body: habitTimeReminderBody,
          channelId: 'habit_reminders',
          channelName: 'Habit Reminders',
          when: fire,
          highImportance: false,
        );
      }
    }
  }

  /// Cancels every scheduled-time one-shot [habitId] could have
  /// pending (the delete path: called after a successful delete,
  /// with the deleted habit's id).
  Future<void> cancelHabit(String habitId, {DateTime? now}) async {
    final n = now ?? DateTime.now();
    await service.initialize();
    for (final id in habitTimeCancelIds(habitId, n)) {
      await service.cancel(id);
    }
  }
}

/// Keeps the device's schedules in step with the persisted reminder
/// preferences. Called after Settings loads, after any reminder
/// toggle flips, and after event counters change.
class ReminderSync {
  final ReminderNotificationService service;
  ReminderSync(this.service);

  /// Cancels EVERY Project Focus schedule a previous sync could
  /// have left pending: the legacy daily id ([ReminderIds.project])
  /// and every projected one-shot id in the cancellable window
  /// ([projectReminderCancelIds]). Runs on every [syncAll] — before
  /// any re-arm, and on the paths that arm nothing (toggle off,
  /// OS permission off, empty projection) — so a stale daily or
  /// one-shot can never survive a sync.
  Future<void> _cancelProjectSchedules(DateTime n) async {
    await service.cancel(ReminderIds.project);
    for (final id in projectReminderCancelIds(n)) {
      await service.cancel(id);
    }
  }

  /// Cancels EVERY check-in schedule a previous sync could have
  /// left pending: the legacy daily id ([ReminderIds.checkIn],
  /// the retired unconditional 04:00 daily) and every projected
  /// one-shot id in the cancellable window
  /// ([checkInReminderCancelIds]). Runs on every [syncAll] —
  /// before any re-arm, and on the paths that arm nothing
  /// (toggle off, OS permission off) — and on every
  /// [syncCheckInOnly], so a stale daily or one-shot can never
  /// survive a sync.
  Future<void> _cancelCheckInSchedules(DateTime n) async {
    await service.cancel(ReminderIds.checkIn);
    for (final id in checkInReminderCancelIds(n)) {
      await service.cancel(id);
    }
  }

  /// Cancels EVERY streak-countdown schedule a previous sync
  /// could have left pending — and any POSTED countdown in the
  /// window (the plugin's cancel removes posted notifications
  /// by id too). Runs on every [syncAll] and every
  /// [syncCheckInOnly] — before any re-arm, and on the paths
  /// that arm nothing — so a countdown whose day has resolved
  /// (summary settled, freeze-covered) is taken down at the
  /// settlement sync and can never survive into a state where
  /// its message stopped being true.
  Future<void> _cancelStreakCountdownSchedules(DateTime n) async {
    for (final id in streakCountdownCancelIds(n)) {
      await service.cancel(id);
    }
  }

  /// Arms the unified evening projection: the streak countdown
  /// (see [streakCountdownFireTimes]) and the bounded check-in
  /// one-shot projection (see [checkInReminderFireTimes]),
  /// reconciled to ONE nudge per evening — on a date where the
  /// countdown is armed, that date's plain check-in one-shot is
  /// suppressed (not stacked). The check-in one-shots keep the
  /// SAME title/body/channel/importance as the retired daily
  /// schedule.
  Future<void> _armEveningProjection(DateTime n,
      Set<String> checkedInDayLabels, StreakState? streakState) async {
    final countdownFires =
        streakCountdownFireTimes(now: n, state: streakState);
    final countdownDates = <DateTime>{
      for (final f in countdownFires) DateTime(f.year, f.month, f.day),
    };
    if (streakState != null && countdownFires.isNotEmpty) {
      final streak = settledStreakForCountdown(streakState, n);
      for (final fire in countdownFires) {
        await service.scheduleStreakCountdownOnce(
          id: streakCountdownIdForDate(fire),
          title: streakCountdownTitle,
          body: streakCountdownBody(streak),
          channelId: streakCountdownChannelId,
          channelName: streakCountdownChannelName,
          channelDescription: streakCountdownChannelDescription,
          when: fire,
          countdownTo: nextTabsDayBoundary(fire),
          highImportance: true,
        );
      }
    }
    for (final fire in checkInReminderFireTimes(
        now: n, checkedInDayLabels: checkedInDayLabels)) {
      if (countdownDates.contains(
          DateTime(fire.year, fire.month, fire.day))) {
        continue;
      }
      await service.scheduleOnce(
        id: checkInReminderIdForDate(fire),
        title: 'how are you feeling?',
        body: 'one tap is enough. whenever you\'re ready.',
        channelId: 'check_in_reminder',
        channelName: 'Check in reminders',
        when: fire,
        highImportance: true,
      );
    }
  }

  /// Re-projects ONLY the evening nudges (VC 100138; streak
  /// countdown added by Community Added Scope #2) — the
  /// check-in save path's re-sync, mirroring the habits
  /// completion re-sync ([HabitTimeReminderSync.syncHabits]):
  /// after a feeling check-in is saved, today's pending 20:00
  /// one-shot must drop without waiting for the next full
  /// [syncAll]. The legacy daily id and both projected windows
  /// (check-in AND streak countdown — the countdown sweep also
  /// takes down a POSTED countdown, which is the settlement
  /// hook when this runs from a summary completion) are
  /// cancelled first, on EVERY path (toggle off and
  /// OS-permission off included); then, only when the toggle is
  /// on and notifications are enabled, the unified evening
  /// projection is re-armed from [checkedInDayLabels] — which
  /// the caller derives from its LOCAL merged entry view, so a
  /// just-saved check-in counts even before its server push
  /// lands — and from [streakState], the caller's settled
  /// streak state (null = no settled record; no countdown is
  /// armed on a guess).
  Future<void> syncCheckInOnly({
    required bool checkInEnabled,
    required Set<String> checkedInDayLabels,
    StreakState? streakState,
    DateTime? now,
  }) async {
    final n = now ?? DateTime.now();
    await service.initialize();
    final enabled = await service.areNotificationsEnabled();
    await _cancelCheckInSchedules(n);
    await _cancelStreakCountdownSchedules(n);
    if (!enabled || !checkInEnabled) return;
    await _armEveningProjection(n, checkedInDayLabels, streakState);
  }

  Future<void> syncAll({
    required bool habitEnabled,
    required bool projectEnabled,
    required bool checkInEnabled,
    required bool eventEnabled,
    required List<EventReminderRequest> events,
    List<FocusTest> focusTests = const [],
    Set<String> checkedInDayLabels = const {},
    StreakState? streakState,
    DateTime? now,
  }) async {
    final n = now ?? DateTime.now();
    await service.initialize();
    final enabled = await service.areNotificationsEnabled();
    if (!enabled) {
      // Nothing can fire without the system permission; make sure no
      // stale schedule survives from an earlier grant.
      await service.cancel(ReminderIds.habit);
      await _cancelProjectSchedules(n);
      await _cancelCheckInSchedules(n);
      await _cancelStreakCountdownSchedules(n);
      for (final e in events) {
        await service.cancel(eventNotificationId(e.counterId));
      }
      return;
    }
    if (habitEnabled) {
      await service.scheduleDaily(
        id: ReminderIds.habit,
        title: 'Finish your habits! ✅',
        body:
            'You still have some daily habits to check off. Keep your streak alive!',
        channelId: 'habit_reminders',
        channelName: 'Habit Reminders',
        hour: 19,
        minute: 0,
        highImportance: false,
      );
    } else {
      await service.cancel(ReminderIds.habit);
    }
    // Project Focus: the legacy daily schedule is ALWAYS cancelled
    // first (with the whole projected window), then — only when the
    // toggle is on — the bounded one-shot projection is armed: one
    // one-shot per date on which native's fire-time gate would pass
    // (see [projectReminderFireTimes]). No active test, or no
    // qualifying date, arms nothing. Copy and channel are
    // byte-identical to the retired daily schedule.
    await _cancelProjectSchedules(n);
    if (projectEnabled) {
      for (final fire
          in projectReminderFireTimes(now: n, tests: focusTests)) {
        await service.scheduleOnce(
          id: projectReminderIdForDate(fire),
          title: 'Project Focus Nudge ⏳',
          body: "Don't forget to complete your project task for the day.",
          channelId: 'project_reminders',
          channelName: 'Project Reminders',
          when: fire,
          highImportance: false,
        );
      }
    }
    // Check-in: the legacy daily schedule is ALWAYS cancelled
    // first (with the whole projected window), then — only when
    // the toggle is on — the bounded one-shot projection is
    // armed: one one-shot per 20:00 date whose Tabs day is not
    // already checked in (see [checkInReminderFireTimes]). Copy
    // and channel are byte-identical to the retired daily
    // schedule; only the fire time (20:00, not 04:00) and the
    // gate changed.
    await _cancelCheckInSchedules(n);
    await _cancelStreakCountdownSchedules(n);
    if (checkInEnabled) {
      await _armEveningProjection(n, checkedInDayLabels, streakState);
    }
    for (final e in events) {
      final id = eventNotificationId(e.counterId);
      // Native's EventReceiver re-checks the master event toggle at
      // fire time; the plugin equivalent is cancelling here when the
      // toggle is off.
      final fire =
          (!eventEnabled || e.isNonActive || e.isUp)
              ? null
              : eventFireTime(e.targetDateMs, n);
      if (fire == null) {
        await service.cancel(id);
      } else {
        await service.scheduleOnce(
          id: id,
          title: 'Event Today: ${e.name} 🗓️',
          body:
              "Today is the day! Don't forget: ${e.name}. Open the app for a quick refresher.",
          channelId: 'event_reminders',
          channelName: 'Event Reminders',
          when: fire,
          highImportance: true,
        );
      }
    }
  }
}

/// The real scheduler, backed by flutter_local_notifications.
class LocalReminderNotificationService implements ReminderNotificationService {
  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;
  bool _zoneReady = false;

  LocalReminderNotificationService({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    try {
      tzdata.initializeTimeZones();
      try {
        final name = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(name));
        _zoneReady = true;
      } catch (_) {
        _zoneReady = false;
      }
      // V-1: plugin.initialize belongs to the app-level bootstrap
      // (see [NotificationBootstrap]) — it installs the ONE
      // dispatching response callback. Calling initialize here
      // joins the bootstrap's run (or starts it, when a screen is
      // somehow the first caller) and NEVER replaces the
      // callback, so initializing the reminder service can no
      // longer wipe Daily Score tap routing in-session.
      await NotificationBootstrap.initialize(_plugin);
      _initialized = true;
    } on NotificationServiceException {
      rethrow;
    } catch (_) {
      throw const NotificationServiceException('INIT_FAILED');
    }
  }

  @override
  Future<bool> areNotificationsEnabled() async {
    try {
      await initialize();
      return await _android?.areNotificationsEnabled() ?? false;
    } on NotificationServiceException {
      rethrow;
    } catch (_) {
      throw const NotificationServiceException('PERMISSION_CHECK_FAILED');
    }
  }

  @override
  Future<bool> requestNotificationsPermission() async {
    try {
      await initialize();
      return await _android?.requestNotificationsPermission() ?? false;
    } on NotificationServiceException {
      rethrow;
    } catch (_) {
      throw const NotificationServiceException('PERMISSION_REQUEST_FAILED');
    }
  }

  @override
  Future<bool> canScheduleExact() async {
    try {
      await initialize();
      return await _android?.canScheduleExactNotifications() ?? false;
    } on NotificationServiceException {
      rethrow;
    } catch (_) {
      throw const NotificationServiceException('EXACT_CHECK_FAILED');
    }
  }

  @override
  Future<void> requestExactAlarmsPermission() async {
    try {
      await initialize();
      await _android?.requestExactAlarmsPermission();
    } on NotificationServiceException {
      rethrow;
    } catch (_) {
      throw const NotificationServiceException('EXACT_REQUEST_FAILED');
    }
  }

  tz.TZDateTime _zoned(DateTime local) {
    if (!_zoneReady) {
      // Scheduling against the UTC fallback would fire at the wrong
      // local time — fail visibly instead of silently mis-timing.
      throw const NotificationServiceException('TIMEZONE_UNAVAILABLE');
    }
    return tz.TZDateTime.from(local, tz.local);
  }

  NotificationDetails _details(
      String channelId, String channelName, bool highImportance) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        channelName,
        importance:
            highImportance ? Importance.high : Importance.defaultImportance,
        priority: highImportance ? Priority.high : Priority.defaultPriority,
        icon: '@mipmap/ic_launcher',
      ),
    );
  }

  @override
  Future<void> scheduleDaily({
    required int id,
    required String title,
    required String body,
    required String channelId,
    required String channelName,
    required int hour,
    required int minute,
    required bool highImportance,
  }) async {
    try {
      await initialize();
      final exact = await _android?.canScheduleExactNotifications() ?? false;
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        _zoned(nextDailyInstance(DateTime.now(), hour, minute)),
        _details(channelId, channelName, highImportance),
        androidScheduleMode: exact
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
        payload: channelId,
      );
    } on NotificationServiceException {
      rethrow;
    } catch (_) {
      throw const NotificationServiceException('SCHEDULE_FAILED');
    }
  }

  @override
  Future<void> scheduleOnce({
    required int id,
    required String title,
    required String body,
    required String channelId,
    required String channelName,
    required DateTime when,
    required bool highImportance,
  }) async {
    try {
      await initialize();
      final exact = await _android?.canScheduleExactNotifications() ?? false;
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        _zoned(when),
        _details(channelId, channelName, highImportance),
        androidScheduleMode: exact
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
        payload: channelId,
      );
    } on NotificationServiceException {
      rethrow;
    } catch (_) {
      throw const NotificationServiceException('SCHEDULE_FAILED');
    }
  }

  @override
  Future<void> scheduleWeekly({
    required int id,
    required String title,
    required String body,
    required String channelId,
    required String channelName,
    required int weekday,
    required int hour,
    required int minute,
    required bool highImportance,
  }) async {
    try {
      await initialize();
      final exact = await _android?.canScheduleExactNotifications() ?? false;
      final when = nextWeeklyInstance(DateTime.now(), weekday, hour, minute);
      // The plugin derives the recurring weekday from the scheduled
      // date itself when matching dayOfWeekAndTime; `when` is built
      // to BE the Calendar weekday [weekday] (see
      // [dayForCalendarDayOfWeek] for the verified 1:1 enum mapping).
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        _zoned(when),
        _details(channelId, channelName, highImportance),
        androidScheduleMode: exact
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
        payload: channelId,
      );
    } on NotificationServiceException {
      rethrow;
    } catch (_) {
      throw const NotificationServiceException('SCHEDULE_FAILED');
    }
  }

  @override
  Future<void> scheduleStreakCountdownOnce({
    required int id,
    required String title,
    required String body,
    required String channelId,
    required String channelName,
    required String channelDescription,
    required DateTime when,
    required DateTime countdownTo,
    required bool highImportance,
  }) async {
    try {
      await initialize();
      final exact = await _android?.canScheduleExactNotifications() ?? false;
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        _zoned(when),
        NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            channelName,
            channelDescription: channelDescription,
            importance: highImportance
                ? Importance.high
                : Importance.defaultImportance,
            priority:
                highImportance ? Priority.high : Priority.defaultPriority,
            icon: '@mipmap/ic_launcher',
            // Juno NOTIF-COPY.md §1.3 — chronometer configuration:
            // `when` is the boundary instant, shown as a LIVE
            // count-down; subText stays unset; no static time
            // text anywhere. timeoutAfter removes the posted
            // notification at the boundary even if the app
            // never runs again.
            showWhen: true,
            when: countdownTo.millisecondsSinceEpoch,
            usesChronometer: true,
            chronometerCountDown: true,
            timeoutAfter: countdownTo.difference(when).inMilliseconds,
          ),
        ),
        androidScheduleMode: exact
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
        payload: channelId,
      );
    } on NotificationServiceException {
      rethrow;
    } catch (_) {
      throw const NotificationServiceException('SCHEDULE_FAILED');
    }
  }

  @override
  Future<void> cancel(int id) async {
    try {
      await initialize();
      await _plugin.cancel(id);
    } on NotificationServiceException {
      rethrow;
    } catch (_) {
      throw const NotificationServiceException('CANCEL_FAILED');
    }
  }
}
