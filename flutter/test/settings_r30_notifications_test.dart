import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';

import 'settings_r29_test.dart' as r29;
import 'test_helpers.dart';

/// Round 30 Step 1 — notification scheduling: pure scheduling math,
/// the ReminderSync arm/cancel matrix, and the Settings permission
/// gate (disclosure dialog BEFORE the system request; the toggle
/// flips only on grant — native checkAndToggle /
/// handleCheckInReminderToggle semantics).
void main() {
  group('scheduling math', () {
    test('nextDailyInstance: later today stays today, past rolls over',
        () {
      final now = DateTime(2026, 10, 12, 18, 30);
      expect(nextDailyInstance(now, 19, 0), DateTime(2026, 10, 12, 19));
      expect(nextDailyInstance(now, 4, 0), DateTime(2026, 10, 13, 4));
      // Exactly at the fire time counts as passed (native uses <=).
      expect(nextDailyInstance(DateTime(2026, 10, 12, 19), 19, 0),
          DateTime(2026, 10, 13, 19));
    });

    test('eventFireTime: 9 AM on the target date, null when past', () {
      final target =
          DateTime(2026, 10, 20, 15, 45).millisecondsSinceEpoch;
      expect(eventFireTime(target, DateTime(2026, 10, 12)),
          DateTime(2026, 10, 20, 9));
      expect(eventFireTime(target, DateTime(2026, 10, 20, 9, 30)), isNull);
      expect(eventFireTime(target, DateTime(2026, 10, 21)), isNull);
    });

    test('eventNotificationId is stable and in its own range', () {
      expect(eventNotificationId('abc'), eventNotificationId('abc'));
      expect(eventNotificationId('abc'),
          greaterThanOrEqualTo(700000));
      expect(eventNotificationId('abc'), lessThan(800000));
      expect(eventNotificationId('abc'),
          isNot(eventNotificationId('abd')));
    });
  });

  group('ReminderSync', () {
    test('arms enabled dailies at native times, cancels disabled',
        () async {
      final fake = FakeReminderNotificationService();
      await ReminderSync(fake).syncAll(
        habitEnabled: true,
        projectEnabled: false,
        checkInEnabled: true,
        eventEnabled: true,
        events: const [],
        now: DateTime(2026, 10, 12, 12),
      );
      expect(fake.daily[ReminderIds.habit], '19:0');
      expect(fake.daily.containsKey(ReminderIds.project), isFalse);
      expect(fake.cancelled, contains(ReminderIds.project));
      expect(fake.daily[ReminderIds.checkIn], '4:0');
    });

    test('event counters: only future, active, count-down counters arm',
        () async {
      final fake = FakeReminderNotificationService();
      final future =
          DateTime(2026, 10, 20).millisecondsSinceEpoch;
      final past = DateTime(2026, 10, 1).millisecondsSinceEpoch;
      EventReminderRequest req(String id, int ms,
              {bool archived = false, bool up = false}) =>
          EventReminderRequest(
              counterId: id,
              name: id,
              targetDateMs: ms,
              isArchived: archived,
              isUp: up);
      await ReminderSync(fake).syncAll(
        habitEnabled: false,
        projectEnabled: false,
        checkInEnabled: false,
        eventEnabled: true,
        events: [
          req('future', future),
          req('past', past),
          req('archived', future, archived: true),
          req('up', future, up: true),
        ],
        now: DateTime(2026, 10, 12, 12),
      );
      expect(fake.once[eventNotificationId('future')],
          DateTime(2026, 10, 20, 9));
      expect(fake.once.containsKey(eventNotificationId('past')), isFalse);
      expect(
          fake.once.containsKey(eventNotificationId('archived')), isFalse);
      expect(fake.once.containsKey(eventNotificationId('up')), isFalse);
    });

    test('master event toggle off cancels counter alarms', () async {
      final fake = FakeReminderNotificationService();
      final future = DateTime(2026, 10, 20).millisecondsSinceEpoch;
      await ReminderSync(fake).syncAll(
        habitEnabled: false,
        projectEnabled: false,
        checkInEnabled: false,
        eventEnabled: false,
        events: [
          EventReminderRequest(
              counterId: 'future',
              name: 'future',
              targetDateMs: future,
              isArchived: false,
              isUp: false),
        ],
        now: DateTime(2026, 10, 12, 12),
      );
      expect(fake.once, isEmpty);
      expect(fake.cancelled, contains(eventNotificationId('future')));
    });

    test('permission off cancels everything', () async {
      final fake = FakeReminderNotificationService(enabled: false);
      await ReminderSync(fake).syncAll(
        habitEnabled: true,
        projectEnabled: true,
        checkInEnabled: true,
        eventEnabled: true,
        events: const [],
      );
      expect(fake.daily, isEmpty);
      expect(fake.cancelled, containsAll([1003, 1004, 770001]));
    });
  });

  group('Settings permission gate', () {
    SettingsStore store(Map<String, String> map) =>
        SettingsStore.withStorage(
          read: (k) async => map[k],
          write: (k, v) async => map[k] = v,
          delete: (k) async => map.remove(k),
        );

    Future<void> pumpToNotifications(
        WidgetTester tester,
        r29.FakeSettingsBackend backend,
        FakeReminderNotificationService notifs) async {
      tester.view.physicalSize = const Size(1080, 3400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SettingsScreen(
            backend: backend,
            settingsStore: store(<String, String>{}),
            notificationService: notifs,
            urlLauncher: (uri) async => true,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Notifications'));
      await tester.pumpAndSettle();
    }

    testWidgets(
        'enabling a reminder with permission denied keeps it off',
        (tester) async {
      final backend = r29.FakeSettingsBackend()..pullBody = r29.pull();
      final notifs = FakeReminderNotificationService(
          enabled: false, grantOnRequest: false);
      await pumpToNotifications(tester, backend, notifs);
      await tester.tap(find.descendant(
          of: find.byKey(const ValueKey('habit_reminder_toggle')),
          matching: find.byType(Switch)));
      await tester.pumpAndSettle();
      // The disclosure dialog appears BEFORE any system request.
      expect(find.text('Allow notifications?'), findsOneWidget);
      expect(notifs.requestCount, 0);
      await tester.tap(find.byKey(const ValueKey('notif_allow_button')));
      await tester.pumpAndSettle();
      expect(notifs.requestCount, 1);
      // Denied: no profile push, toggle still off, no schedule armed.
      expect(backend.profilePushes, isEmpty);
      expect(notifs.daily, isEmpty);
      final sw = tester.widget<Switch>(
          find.byKey(const ValueKey('habit_reminder_toggle')));
      expect(sw.value, isFalse);
    });

    testWidgets('grant after disclosure flips, pushes and schedules',
        (tester) async {
      final backend = r29.FakeSettingsBackend()..pullBody = r29.pull();
      final notifs = FakeReminderNotificationService(
          enabled: false, grantOnRequest: true);
      await pumpToNotifications(tester, backend, notifs);
      await tester.tap(find.descendant(
          of: find.byKey(const ValueKey('habit_reminder_toggle')),
          matching: find.byType(Switch)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('notif_allow_button')));
      await tester.pumpAndSettle();
      expect(backend.profilePushes,
          contains(equals({'habitReminderEnabled': true})));
      expect(notifs.daily[ReminderIds.habit], '19:0');
    });

    testWidgets('already-granted permission skips the dialog',
        (tester) async {
      final backend = r29.FakeSettingsBackend()..pullBody = r29.pull();
      final notifs = FakeReminderNotificationService(enabled: true);
      await pumpToNotifications(tester, backend, notifs);
      await tester.tap(find.descendant(
          of: find.byKey(const ValueKey('habit_reminder_toggle')),
          matching: find.byType(Switch)));
      await tester.pumpAndSettle();
      expect(find.text('Allow notifications?'), findsNothing);
      expect(notifs.requestCount, 0);
      expect(backend.profilePushes,
          contains(equals({'habitReminderEnabled': true})));
    });

    testWidgets('check-in denial shows the native denied explanation',
        (tester) async {
      final backend = r29.FakeSettingsBackend()..pullBody = r29.pull();
      // Check-in defaults ON in the store; seed it off so the tap is
      // an enable attempt.
      final map = <String, String>{
        SettingsStore.checkInReminderKey: 'false',
      };
      final notifs = FakeReminderNotificationService(
          enabled: false, grantOnRequest: false);
      tester.view.physicalSize = const Size(1080, 3400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SettingsScreen(
            backend: backend,
            settingsStore: store(map),
            notificationService: notifs,
            urlLauncher: (uri) async => true,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Notifications'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
          of: find.byKey(const ValueKey('checkin_reminder_toggle')),
          matching: find.byType(Switch)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('notif_allow_button')));
      await tester.pumpAndSettle();
      expect(
          find.text(
              'Notifications are turned off on this phone, so the reminder cannot fire. You can turn them on in system settings.'),
          findsOneWidget);
      expect(map[SettingsStore.checkInReminderKey], 'false');
    });
  });
}
