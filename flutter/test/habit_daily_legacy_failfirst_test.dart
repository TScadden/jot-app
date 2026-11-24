import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/notification_service.dart';

import 'test_helpers.dart';

/// FAIL-FIRST evidence for the habits-notification false fire
/// (Nov 23, 2026): the aggregate daily habit reminder
/// (ReminderIds.habit = 1003) was a daily repeating scheduleDaily
/// at 19:00 with NO completion gate — it fired even when every
/// habit was already checked off, while Settings promises
/// "Daily ping at 7:00 PM if you have unchecked habits remaining."
///
/// This file intentionally uses ONLY the pre-fix public API
/// (ReminderSync.syncAll's original signature), so it compiles on
/// the unmodified head and fails there BEHAVIORALLY: the old code
/// stands the unconditional daily up and never cancels it on the
/// enabled path. The full projection coverage (new API) lives in
/// habit_daily_reminder_projection_test.dart.
void main() {
  // Monday Nov 23, 2026, 10:00 local — before the 19:00 fire.
  final now = DateTime(2026, 11, 23, 10);

  test(
      'enabling the habit reminder does NOT stand up the '
      'unconditional daily id 1003', () async {
    final fake = FakeReminderNotificationService();
    await ReminderSync(fake).syncAll(
      habitEnabled: true,
      projectEnabled: false,
      checkInEnabled: false,
      eventEnabled: false,
      events: const [],
      now: now,
    );
    expect(
      fake.daily.containsKey(ReminderIds.habit),
      isFalse,
      reason: 'the aggregate habit reminder must be a gated '
          'one-shot projection, never a daily repeating alarm',
    );
  });

  test(
      'every sync cancels the legacy daily id 1003, including the '
      'habit-enabled path', () async {
    final fake = FakeReminderNotificationService();
    await ReminderSync(fake).syncAll(
      habitEnabled: true,
      projectEnabled: false,
      checkInEnabled: false,
      eventEnabled: false,
      events: const [],
      now: now,
    );
    expect(
      fake.cancelled,
      contains(ReminderIds.habit),
      reason: 'a stale unconditional daily alarm from an older '
          'build must be dropped by every sync, not only by the '
          'toggle-off path',
    );
  });
}
