import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/features/tools/reminders_screen.dart';

/// Round 47 — keeps the device's local notifications in step with
/// the user-reminder list, mirroring native's AlarmManager scheme
/// (`notifications/` + `RemindersScreen` ground truth):
///
/// - Notification id (native requestCode) = `id * 1000 + slotIndex`.
/// - FIXED without custom days → 1 slot (index 0), a daily schedule
///   at the fixed time (native arms a repeating daily alarm).
/// - FIXED with custom days → one weekly slot per ENABLED day,
///   slotIndex = the day's Calendar constant (SUNDAY=1 … SATURDAY=7).
/// - INTERVAL → one daily slot per computed time of day: start,
///   stepping the interval while ≤ end (empty when the interval
///   is 0); slotIndex = the slot's ordinal.
/// - Cancel brute-forces slots 0..47 for the reminder's id, exactly
///   like native's cancel path.
///
/// Channel: `user_reminders` ("Reminders", HIGH importance —
/// [ReminderNotificationService] maps `highImportance: true` to
/// Importance.high), title `Reminder 🔔`, body = the reminder title.
///
/// Every function here may throw [NotificationServiceException];
/// callers MUST wrap them so a notification failure never fails the
/// save that triggered the sync (the reminder row is the source of
/// truth; the alarm is a side effect).

/// Native channel id for user reminders.
const String userReminderChannelId = 'user_reminders';

/// Native channel name for user reminders.
const String userReminderChannelName = 'Reminders';

/// Native notification title for user reminders.
const String userReminderNotificationTitle = 'Reminder 🔔';

/// Highest slot index native's brute-force cancel touches.
const int reminderMaxSlot = 47;

/// Plugin notification id for [reminderId]'s slot [slotIndex].
int reminderSlotId(int reminderId, int slotIndex) =>
    reminderId * 1000 + slotIndex;

/// The daily times an INTERVAL reminder fires at, as minutes since
/// midnight: start, stepping the interval while ≤ end. Empty when
/// the interval totals 0 minutes (native computes no slots then).
List<int> intervalSlotMinutes(ReminderModel r) {
  final interval = r.intervalHours * 60 + r.intervalMinutes;
  if (interval <= 0) return const [];
  final start = r.startHour * 60 + r.startMinute;
  final end = r.endHour * 60 + r.endMinute;
  final out = <int>[];
  for (var t = start; t <= end; t += interval) {
    out.add(t);
  }
  return out;
}

/// Cancels every possible slot for [reminderId] (0..47), native's
/// brute-force cancel.
Future<void> cancelReminderAlarms(
    ReminderNotificationService service, int reminderId) async {
  await service.initialize();
  for (var slot = 0; slot <= reminderMaxSlot; slot++) {
    await service.cancel(reminderSlotId(reminderId, slot));
  }
}

/// Full resync for one reminder: cancel all its slots first, then —
/// only when it is enabled — schedule per the native slot rules.
/// A disabled reminder ends up cancel-only, as does a deleted one
/// (callers use [cancelReminderAlarms] directly for deletes).
Future<void> syncReminderAlarms(
    ReminderNotificationService service, ReminderModel r) async {
  await cancelReminderAlarms(service, r.id);
  if (!r.isEnabled) return;
  if (r.type == 'INTERVAL') {
    final times = intervalSlotMinutes(r);
    for (var i = 0; i < times.length; i++) {
      await service.scheduleDaily(
        id: reminderSlotId(r.id, i),
        title: userReminderNotificationTitle,
        body: r.title,
        channelId: userReminderChannelId,
        channelName: userReminderChannelName,
        hour: times[i] ~/ 60,
        minute: times[i] % 60,
        highImportance: true,
      );
    }
    return;
  }
  final enabledDays = r.dayConfigs.where((d) => d.isEnabled).toList();
  if (enabledDays.isNotEmpty) {
    for (final d in enabledDays) {
      await service.scheduleWeekly(
        id: reminderSlotId(r.id, d.dayOfWeek),
        title: userReminderNotificationTitle,
        body: r.title,
        channelId: userReminderChannelId,
        channelName: userReminderChannelName,
        weekday: d.dayOfWeek,
        hour: d.hour,
        minute: d.minute,
        highImportance: true,
      );
    }
  } else {
    await service.scheduleDaily(
      id: reminderSlotId(r.id, 0),
      title: userReminderNotificationTitle,
      body: r.title,
      channelId: userReminderChannelId,
      channelName: userReminderChannelName,
      hour: r.fixedHour,
      minute: r.fixedMinute,
      highImportance: true,
    );
  }
}
