import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

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
/// daily wall-clock recurrence for the three daily reminders, and a
/// plain one-shot `zonedSchedule` per event counter. The plugin's
/// boot receiver restores schedules after a reboot.
///
/// Known deviation (flagged in the round report): the plugin cannot
/// run Dart code at fire time, so the habit/project "only if still
/// unchecked" gate and the check-in "only if not checked in yet" gate
/// (both evaluated at fire time in native) cannot be re-evaluated when
/// the notification fires. The schedules fire daily while the toggle
/// is on; the subtitle copy on the Notifications page says exactly
/// what each reminder does.
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

/// One event-counter reminder to arm (or cancel).
class EventReminderRequest {
  final String counterId;
  final String name;
  final int targetDateMs;
  final bool isArchived;
  final bool isUp;

  const EventReminderRequest({
    required this.counterId,
    required this.name,
    required this.targetDateMs,
    required this.isArchived,
    required this.isUp,
  });
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
  Future<void> cancel(int id);
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

/// Keeps the device's schedules in step with the persisted reminder
/// preferences. Called after Settings loads, after any reminder
/// toggle flips, and after event counters change.
class ReminderSync {
  final ReminderNotificationService service;
  ReminderSync(this.service);

  Future<void> syncAll({
    required bool habitEnabled,
    required bool projectEnabled,
    required bool checkInEnabled,
    required bool eventEnabled,
    required List<EventReminderRequest> events,
    DateTime? now,
  }) async {
    final n = now ?? DateTime.now();
    await service.initialize();
    final enabled = await service.areNotificationsEnabled();
    if (!enabled) {
      // Nothing can fire without the system permission; make sure no
      // stale schedule survives from an earlier grant.
      await service.cancel(ReminderIds.habit);
      await service.cancel(ReminderIds.project);
      await service.cancel(ReminderIds.checkIn);
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
    if (projectEnabled) {
      await service.scheduleDaily(
        id: ReminderIds.project,
        title: 'Project Focus Nudge ⏳',
        body: "Don't forget to complete your project task for the day.",
        channelId: 'project_reminders',
        channelName: 'Project Reminders',
        hour: 20,
        minute: 0,
        highImportance: false,
      );
    } else {
      await service.cancel(ReminderIds.project);
    }
    if (checkInEnabled) {
      await service.scheduleDaily(
        id: ReminderIds.checkIn,
        title: 'How are you feeling?',
        body: "Tap to log today's check in.",
        channelId: 'check_in_reminder',
        channelName: 'Check in reminders',
        hour: 4,
        minute: 0,
        highImportance: true,
      );
    } else {
      await service.cancel(ReminderIds.checkIn);
    }
    for (final e in events) {
      final id = eventNotificationId(e.counterId);
      // Native's EventReceiver re-checks the master event toggle at
      // fire time; the plugin equivalent is cancelling here when the
      // toggle is off.
      final fire = (!eventEnabled || e.isArchived || e.isUp)
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
      final ok = await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      if (ok != true) {
        throw const NotificationServiceException('INIT_FAILED');
      }
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
