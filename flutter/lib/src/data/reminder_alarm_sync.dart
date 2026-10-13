import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/features/tools/reminders_screen.dart';

/// Round 47 — keeps the device's local notifications in step with
/// the user-reminder list, mirroring native's AlarmManager semantics
/// (`notifications/` + `RemindersScreen` ground truth) for WHAT
/// fires when. Round 47 fix round (Vera B1/B2) — the plugin
/// notification ID scheme is NOT native's `id * 1000 + slot`: that
/// scheme collided with the Settings fixed ids (habit 1003, project
/// 1004 — reminder id 1 landed on 1000–1047), with the check-in id
/// 770001 (reminder id 770, slot 1), and with the event-counter
/// range 700000–799998 (any reminder id ≥ 700).
///
/// Fix-round scheme — a dedicated offset block per reminder:
/// `pluginId = 100000 + reminderId * 1500 + slotIndex`,
/// `slotIndex ∈ [0, 1500)`. Disjointness, by construction:
/// - Settings fixed ids 1003 / 1004 and check-in 770001: every
///   reminder block starts at ≥ 101500 (id 1) and the highest safe
///   block ends at 699999 (id 399), so neither fixed id is in any
///   block (1003/1004 are below the first block; 770001 is above
///   the last safe block).
/// - Event-counter range 700000–799998: the highest safe block
///   (id 399) is 698500–699999, strictly below 700000.
/// - Other reminders: blocks are 1500 wide and spaced 1500 apart,
///   so two distinct in-range reminder ids never share a plugin id.
/// A reminder id outside 1..399 is OUT OF RANGE: nothing is
/// scheduled or cancelled for it (never reach into a reserved
/// range), and an ENABLED out-of-range reminder surfaces the
/// non-blocking alarm note via [NotificationServiceException]
/// (`REMINDER_ID_OUT_OF_RANGE`) on the mutation path.
///
/// Slot semantics (unchanged from native):
/// - FIXED without custom days → 1 slot (index 0), daily at the
///   fixed time.
/// - FIXED with custom days → one weekly slot per ENABLED day,
///   slotIndex = the day's Calendar constant (SUNDAY=1 … SATURDAY=7).
/// - INTERVAL → one daily slot per computed time of day: start,
///   stepping the interval while ≤ end (empty when the interval
///   is 0); slotIndex = the slot's ordinal. Generation is capped
///   at [reminderSlotsPerReminder] slots (a 1-minute interval
///   across a full 24 h window is 1440, so real schedules fit).
/// - Cancel covers the reminder's WHOLE 1500-slot block.
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

/// Fix-round ID scheme: plugin ids live in a dedicated block of
/// this many slots per reminder, starting at
/// [reminderPluginIdOffset].
const int reminderPluginIdOffset = 100000;
const int reminderSlotsPerReminder = 1500;

/// Highest slot index inside one reminder's block.
const int reminderMaxSlot = reminderSlotsPerReminder - 1;

/// Highest reminder id whose block stays strictly below the
/// event-counter range (700000): id 399 → 698500–699999.
const int reminderMaxSchedulableId = 399;

/// Whether [reminderId]'s plugin-id block is provably disjoint
/// from every reserved range (see the file doc comment).
bool isReminderIdSchedulable(int reminderId) =>
    reminderId >= 1 && reminderId <= reminderMaxSchedulableId;

/// Plugin notification id for [reminderId]'s slot [slotIndex]:
/// `100000 + reminderId * 1500 + slotIndex`.
int reminderSlotId(int reminderId, int slotIndex) =>
    reminderPluginIdOffset + reminderId * reminderSlotsPerReminder + slotIndex;

/// The daily times an INTERVAL reminder fires at, as minutes since
/// midnight: start, stepping the interval while ≤ end. Empty when
/// the interval totals 0 minutes (native computes no slots then).
/// Capped at [reminderSlotsPerReminder] entries so a schedule can
/// never bleed past its own block (Vera B2).
List<int> intervalSlotMinutes(ReminderModel r) {
  final interval = r.intervalHours * 60 + r.intervalMinutes;
  if (interval <= 0) return const [];
  final start = r.startHour * 60 + r.startMinute;
  final end = r.endHour * 60 + r.endMinute;
  final out = <int>[];
  for (var t = start; t <= end && out.length < reminderSlotsPerReminder;
      t += interval) {
    out.add(t);
  }
  return out;
}

/// Cancels every slot of [reminderId]'s whole block (0..1499).
/// An out-of-range id is a no-op: its computed block could reach
/// into a reserved range, and nothing was ever scheduled for it.
Future<void> cancelReminderAlarms(
    ReminderNotificationService service, int reminderId) async {
  if (!isReminderIdSchedulable(reminderId)) return;
  await service.initialize();
  for (var slot = 0; slot <= reminderMaxSlot; slot++) {
    await service.cancel(reminderSlotId(reminderId, slot));
  }
}

/// Full resync for one reminder: cancel its whole block first,
/// then — only when it is enabled — schedule per the slot rules.
/// A disabled reminder ends up cancel-only, as does a deleted one
/// (callers use [cancelReminderAlarms] directly for deletes).
///
/// Throws [NotificationServiceException] with code
/// `REMINDER_ID_OUT_OF_RANGE` when an ENABLED reminder's id is out
/// of range (≥ 400, or ≤ 0 for an id-less row): nothing is
/// scheduled for it, and the mutation caller surfaces the
/// non-blocking alarm note. A DISABLED out-of-range reminder is
/// cancel-only by definition, so it returns silently.
Future<void> syncReminderAlarms(
    ReminderNotificationService service, ReminderModel r) async {
  if (!isReminderIdSchedulable(r.id)) {
    if (r.isEnabled) {
      throw const NotificationServiceException('REMINDER_ID_OUT_OF_RANGE');
    }
    return;
  }
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

/// Full alarm reconcile across ALL [reminders] (Vera B4): every
/// reminder is resynced in turn, so a surviving row that shared a
/// (duplicate or id-less) blob id with a just-deleted row gets its
/// alarms rescheduled after the delete's cancel wiped the shared
/// block. Per-reminder failures are isolated — one bad reminder
/// never stops the rest — and the return value reports whether
/// every reminder synced cleanly (false → the caller surfaces the
/// non-blocking alarm note on the mutation path; the load path
/// ignores it by design).
Future<bool> reconcileReminderAlarms(
    ReminderNotificationService service, Iterable<ReminderModel> reminders) async {
  var allOk = true;
  for (final r in reminders) {
    try {
      await syncReminderAlarms(service, r);
    } catch (_) {
      allOk = false;
    }
  }
  return allOk;
}
