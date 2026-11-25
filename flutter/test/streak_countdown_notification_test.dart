import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';

import 'test_helpers.dart';

/// Community Added Scope #2 — the streak countdown notification:
/// a 20:00 one-shot on incomplete Tabs days with a settled
/// streak ≥ 1 and no freeze cover, carrying a LIVE chronometer
/// down to the next Tabs day boundary (shared definition —
/// [tabsDayStr] / [tabsDayAnchor]; 04:00 under the current
/// definition), reconciled to ONE evening nudge with the
/// check-in reminder.
///
/// Gate inputs are a settled [StreakState]: the day is complete
/// iff it is in `summaryCompletedDays`, freeze-covered iff it
/// is in `restoredDays`, and the streak is [streakCurrent] over
/// that state.
void main() {
  // Thursday Nov 19, 2026, 10:00 local — before the 20:00 fire.
  final now = DateTime(2026, 11, 19, 10);

  /// A settled state whose counted run is the [streak] days
  /// ending yesterday (Nov 18) — today (Nov 19) still open.
  StreakState settled({
    int streak = 5,
    Set<String> completed = const {},
    Set<String> restored = const {},
    Set<String>? counted,
  }) {
    final days = counted ??
        {
          for (var i = 1; i <= streak; i++)
            streakDayStr(DateTime(2026, 11, 19 - i)),
        };
    return StreakState(
      seeded: true,
      seededCurrent: streak,
      seededBest: streak,
      countedDays: days,
      restoredDays: restored,
      summaryCompletedDays: completed,
    );
  }

  group('streak countdown id scheme', () {
    test('ids land in 820000–829999 and are disjoint from every '
        'other owner', () {
      const reserved = {1003, 1004, 770001, 7301, 7303, 7304};
      for (var offset = -400; offset <= 400; offset++) {
        final id = streakCountdownIdForDate(
          DateTime(2026, 11, 19 + offset, 20),
        );
        expect(id, inInclusiveRange(820000, 829999));
        expect(reserved.contains(id), isFalse);
        // Event-counter range 700000–799998.
        expect(id >= 700000 && id <= 799998, isFalse);
        // User-reminder blocks 101500–699999.
        expect(id >= 101500 && id <= 699999, isFalse);
        // Project Focus projection 800000–809999.
        expect(id >= 800000 && id <= 809999, isFalse);
        // Check-in projection 810000–819999.
        expect(id >= 810000 && id <= 819999, isFalse);
        // Habit scheduled-time ids 900000–1899999.
        expect(id >= 900000 && id <= 1899999, isFalse);
      }
    });

    test('id is stable per date and distinct across the cancel '
        'window', () {
      final a = DateTime(2026, 11, 19, 20);
      expect(streakCountdownIdForDate(a), streakCountdownIdForDate(a));
      final ids = {
        for (var offset = -35; offset <= 35; offset++)
          streakCountdownIdForDate(DateTime(2026, 11, 19 + offset)),
      };
      expect(ids.length, 71);
      expect(streakCountdownCancelIds(now).toSet(), ids);
    });
  });

  group('nextTabsDayBoundary (shared definition)', () {
    test('from the evening, the boundary is the next 04:00 '
        'under the current definition', () {
      expect(
        nextTabsDayBoundary(DateTime(2026, 11, 19, 20)),
        DateTime(2026, 11, 20, 4),
      );
      expect(
        nextTabsDayBoundary(DateTime(2026, 11, 19, 10)),
        DateTime(2026, 11, 20, 4),
      );
    });

    test('straddling midnight: at 01:00 the Tabs day is still '
        'yesterday and the boundary is 04:00 the same calendar '
        'morning', () {
      final at = DateTime(2026, 11, 19, 1);
      expect(tabsDayStr(at), '2026-11-18');
      expect(nextTabsDayBoundary(at), DateTime(2026, 11, 19, 4));
    });

    test('straddling the boundary: just before it the boundary '
        'is minutes away; at it, the next one is a day out', () {
      expect(
        nextTabsDayBoundary(DateTime(2026, 11, 19, 3, 59, 30)),
        DateTime(2026, 11, 19, 4),
      );
      expect(
        nextTabsDayBoundary(DateTime(2026, 11, 19, 4)),
        DateTime(2026, 11, 20, 4),
      );
    });

    test('the returned instant is exactly where tabsDayStr '
        'flips', () {
      for (final at in [
        DateTime(2026, 11, 19, 0, 30),
        DateTime(2026, 11, 19, 12),
        DateTime(2026, 11, 19, 23, 59),
        DateTime(2026, 3, 8, 12), // US DST spring-forward day
        DateTime(2026, 11, 1, 12), // US DST fall-back day
      ]) {
        final b = nextTabsDayBoundary(at);
        expect(b.isAfter(at), isTrue, reason: 'at $at');
        expect(tabsDayStr(b), isNot(tabsDayStr(at)), reason: 'at $at');
        expect(
          tabsDayStr(b.subtract(const Duration(seconds: 1))),
          tabsDayStr(at),
          reason: 'at $at',
        );
      }
    });
  });

  group('streakCountdownFireTimes gate matrix', () {
    test('fires at 20:00 today through today+35 when the day is '
        'incomplete, streak ≥ 1, and not freeze-covered', () {
      final fires = streakCountdownFireTimes(now: now, state: settled());
      expect(fires.length, 36);
      expect(fires.first, DateTime(2026, 11, 19, 20));
      expect(fires.last, DateTime(2026, 12, 24, 20));
      for (final f in fires) {
        expect(f.hour, 20);
        expect(f.minute, 0);
      }
    });

    test('no fire when today\'s Daily Summary is complete '
        '(settled)', () {
      final fires = streakCountdownFireTimes(
        now: now,
        state: settled(completed: {'2026-11-19'}),
      );
      expect(fires.contains(DateTime(2026, 11, 19, 20)), isFalse);
      expect(fires.first, DateTime(2026, 11, 20, 20));
    });

    test('no fire when the settled streak is 0', () {
      expect(
        streakCountdownFireTimes(now: now, state: settled(streak: 0)),
        isEmpty,
      );
      expect(
        streakCountdownFireTimes(
          now: now,
          state: settled(counted: const {}),
        ),
        isEmpty,
      );
    });

    test('no fire when the day is freeze-covered', () {
      final fires = streakCountdownFireTimes(
        now: now,
        state: settled(restored: {'2026-11-19'}),
      );
      expect(fires.contains(DateTime(2026, 11, 19, 20)), isFalse);
      expect(fires.first, DateTime(2026, 11, 20, 20));
    });

    test('no fire without a settled state (never armed on a '
        'guess)', () {
      expect(streakCountdownFireTimes(now: now, state: null), isEmpty);
    });

    test('streak of exactly 1 qualifies', () {
      final fires =
          streakCountdownFireTimes(now: now, state: settled(streak: 1));
      expect(fires.first, DateTime(2026, 11, 19, 20));
    });

    test('today drops out once 20:00 has passed (strictly '
        'after)', () {
      for (final t in [
        DateTime(2026, 11, 19, 20),
        DateTime(2026, 11, 19, 21, 30),
      ]) {
        final fires = streakCountdownFireTimes(now: t, state: settled());
        expect(fires.contains(DateTime(2026, 11, 19, 20)), isFalse);
        expect(fires.first, DateTime(2026, 11, 20, 20));
      }
    });

    test('a completed day that is also counted today still '
        'reads complete (completion wins)', () {
      final state = settled(
        completed: {'2026-11-19'},
        counted: {
          for (var i = 0; i <= 5; i++)
            streakDayStr(DateTime(2026, 11, 19 - i)),
        },
      );
      final fires = streakCountdownFireTimes(now: now, state: state);
      expect(fires.contains(DateTime(2026, 11, 19, 20)), isFalse);
    });
  });

  group('Juno copy (ruling 2026-11-24, byte-for-byte)', () {
    test('headline, body, big text, action and channel strings '
        'match the ruled strings exactly', () {
      // §1/§2 headline — plain and HTML forms, `day` never
      // pluralizes, the number appears only here.
      expect(streakCountdownHeadline(1), 'You\'re on a 1 day streak');
      expect(
          streakCountdownHeadline(27), 'You\'re on a 27 day streak');
      expect(streakCountdownHeadline(1000),
          'You\'re on a 1000 day streak');
      expect(
        streakCountdownHeadlineHtml(27),
        '<b><font color="#7C6EFF">You\'re on a 27 day streak</font></b>',
      );
      expect(
        streakCountdownHeadlineHtml(1),
        '<b><font color="#7C6EFF">You\'re on a 1 day streak</font></b>',
      );
      // §3 collapsed body (the retired title, verbatim) and the
      // expanded big text; neither carries the streak number.
      expect(streakCountdownBody,
          'Finish today\'s Daily Summary when you\'re ready');
      expect(
        streakCountdownBigText,
        'Finish today\'s Daily Summary when you\'re ready. '
        'There\'s still time tonight to add today to your streak.',
      );
      // §4 the one action's label, its id, and the tap payload.
      expect(streakCountdownActionLabel, 'Open Daily Summary');
      expect(dailySummaryOpenActionId, 'open_daily_summary');
      expect(dailySummaryNotificationPayload, 'daily_summary');
      // Channel strings are UNCHANGED by the ruling.
      expect(streakCountdownChannelId, 'streak_reminders');
      expect(streakCountdownChannelName, 'Streak reminders');
      expect(
        streakCountdownChannelDescription,
        'Shows in the evening when you have a streak going and '
        'today\'s Daily Summary is not finished, with the time '
        'left to extend your streak.',
      );
    });

    test('tap predicate: body payload OR action id, nothing else',
        () {
      expect(
        isDailySummaryNotificationTap(
            payload: dailySummaryNotificationPayload),
        isTrue,
      );
      expect(
        isDailySummaryNotificationTap(
            actionId: dailySummaryOpenActionId),
        isTrue,
      );
      expect(
        isDailySummaryNotificationTap(
            payload: dailySummaryNotificationPayload,
            actionId: dailySummaryOpenActionId),
        isTrue,
      );
      // The old channel-id payload no longer routes, and no
      // other notification's payload/action does either.
      expect(
        isDailySummaryNotificationTap(payload: 'streak_reminders'),
        isFalse,
      );
      expect(isDailySummaryNotificationTap(payload: '2026-11-19'),
          isFalse);
      expect(isDailySummaryNotificationTap(), isFalse);
      expect(
        isDailySummaryNotificationTap(actionId: 'some_other_action'),
        isFalse,
      );
    });
  });

  group('ReminderSync evening reconciliation', () {
    Future<void> sync(
      FakeReminderNotificationService fake, {
      bool checkInEnabled = true,
      Set<String> labels = const {},
      StreakState? state,
      DateTime? at,
    }) =>
        ReminderSync(fake).syncAll(
          habitEnabled: false,
          projectEnabled: false,
          checkInEnabled: checkInEnabled,
          eventEnabled: false,
          events: const [],
          checkedInDayLabels: labels,
          streakState: state,
          now: at ?? now,
        );

    test('countdown armed INSTEAD of the check-in one-shot on '
        'qualifying evenings (one nudge, never two)', () async {
      final fake = FakeReminderNotificationService();
      await sync(fake, state: settled());
      // Countdown: 36 evenings in its own block, Juno copy,
      // chronometer target = next boundary after the fire.
      expect(fake.countdown.length, 36);
      final todayId =
          streakCountdownIdForDate(DateTime(2026, 11, 19));
      final today = fake.countdown[todayId]!;
      expect(today.when, DateTime(2026, 11, 19, 20));
      expect(today.countdownTo, DateTime(2026, 11, 20, 4));
      expect(today.countdownTo, nextTabsDayBoundary(today.when));
      // Juno ruling 2026-11-24: the title argument is the HTML
      // headline for the settled streak (5), the body is the
      // collapsed body — the number lives in the headline only.
      expect(today.title, streakCountdownHeadlineHtml(5));
      expect(today.title,
          '<b><font color="#7C6EFF">You\'re on a 5 day streak</font></b>');
      expect(today.body, streakCountdownBody);
      expect(today.channelId, 'streak_reminders');
      expect(today.channelName, 'Streak reminders');
      expect(today.channelDescription,
          streakCountdownChannelDescription);
      expect(today.highImportance, isTrue);
      // Check-in: fully suppressed across the projection (the
      // countdown covers every projected evening).
      expect(fake.once, isEmpty);
      // Both windows were cancelled before arming.
      expect(fake.cancelled, containsAll(checkInReminderCancelIds(now)));
      expect(
          fake.cancelled, containsAll(streakCountdownCancelIds(now)));
    });

    test('streak 0: check-in one-shot present, countdown absent '
        '(existing behavior unchanged)', () async {
      final fake = FakeReminderNotificationService();
      await sync(fake, state: settled(streak: 0));
      expect(fake.countdown, isEmpty);
      expect(fake.once.length, 36);
      expect(
        fake.once[checkInReminderIdForDate(DateTime(2026, 11, 19))],
        DateTime(2026, 11, 19, 20),
      );
    });

    test('no settled state: check-in one-shot present, countdown '
        'absent', () async {
      final fake = FakeReminderNotificationService();
      await sync(fake);
      expect(fake.countdown, isEmpty);
      expect(fake.once.length, 36);
    });

    test('today complete: no countdown today, and today\'s '
        'check-in is governed by its own gate (checked-in label '
        'absent → check-in fires; the countdown alone is '
        'suppressed by completion)', () async {
      final fake = FakeReminderNotificationService();
      await sync(fake, state: settled(completed: {'2026-11-19'}));
      expect(
        fake.countdown
            .containsKey(streakCountdownIdForDate(DateTime(2026, 11, 19))),
        isFalse,
      );
      // Tomorrow's countdown is armed, so tomorrow's check-in
      // is suppressed; today's check-in remains (its own gate).
      expect(
        fake.once[checkInReminderIdForDate(DateTime(2026, 11, 19))],
        DateTime(2026, 11, 19, 20),
      );
      expect(
        fake.once
            .containsKey(checkInReminderIdForDate(DateTime(2026, 11, 20))),
        isFalse,
      );
    });

    test('today freeze-covered: no countdown today; check-in '
        'unchanged for today', () async {
      final fake = FakeReminderNotificationService();
      await sync(fake, state: settled(restored: {'2026-11-19'}));
      expect(
        fake.countdown
            .containsKey(streakCountdownIdForDate(DateTime(2026, 11, 19))),
        isFalse,
      );
      expect(
        fake.once[checkInReminderIdForDate(DateTime(2026, 11, 19))],
        DateTime(2026, 11, 19, 20),
      );
    });

    test('toggle off: both windows cancelled, nothing armed',
        () async {
      final fake = FakeReminderNotificationService();
      await sync(fake, checkInEnabled: false, state: settled());
      expect(fake.once, isEmpty);
      expect(fake.countdown, isEmpty);
      expect(fake.cancelled, containsAll(checkInReminderCancelIds(now)));
      expect(
          fake.cancelled, containsAll(streakCountdownCancelIds(now)));
    });

    test('OS notifications disabled: both windows cancelled, '
        'nothing armed', () async {
      final fake = FakeReminderNotificationService(enabled: false);
      await sync(fake, state: settled());
      expect(fake.once, isEmpty);
      expect(fake.countdown, isEmpty);
      expect(fake.cancelled, containsAll(checkInReminderCancelIds(now)));
      expect(
          fake.cancelled, containsAll(streakCountdownCancelIds(now)));
    });

    test('cancel-on-completion via the settlement hook: a '
        'posted countdown is cancelled when syncCheckInOnly '
        're-projects with the completed state', () async {
      final fake = FakeReminderNotificationService();
      // Evening: countdown armed for today.
      await ReminderSync(fake).syncCheckInOnly(
        checkInEnabled: true,
        checkedInDayLabels: const {},
        streakState: settled(),
        now: now,
      );
      final todayId =
          streakCountdownIdForDate(DateTime(2026, 11, 19));
      expect(fake.countdown.containsKey(todayId), isTrue);
      // Simulate the 20:00 post having happened: the fake's
      // record stands in for the posted notification (the
      // plugin cancels posted notifications by the same id).
      fake.cancelled.clear();
      // Settlement lands (summary completes) at 21:00.
      await ReminderSync(fake).syncCheckInOnly(
        checkInEnabled: true,
        checkedInDayLabels: const {'2026-11-19'},
        streakState: settled(completed: {'2026-11-19'}),
        now: DateTime(2026, 11, 19, 21),
      );
      expect(fake.cancelled, contains(todayId));
      expect(fake.countdown.containsKey(todayId), isFalse);
      // Tomorrow re-arms (incomplete, streak alive).
      expect(
        fake.countdown.containsKey(
            streakCountdownIdForDate(DateTime(2026, 11, 20))),
        isTrue,
      );
    });

    test('freeze event re-projection: a day that gains freeze '
        'cover loses its countdown at the next sync', () async {
      final fake = FakeReminderNotificationService();
      await ReminderSync(fake).syncCheckInOnly(
        checkInEnabled: true,
        checkedInDayLabels: const {},
        streakState: settled(),
        now: now,
      );
      final todayId =
          streakCountdownIdForDate(DateTime(2026, 11, 19));
      expect(fake.countdown.containsKey(todayId), isTrue);
      await ReminderSync(fake).syncCheckInOnly(
        checkInEnabled: true,
        checkedInDayLabels: const {},
        streakState: settled(restored: {'2026-11-19'}),
        now: DateTime(2026, 11, 19, 12),
      );
      expect(fake.countdown.containsKey(todayId), isFalse);
    });
  });

  group('SettingsProfileData streak parse path', () {
    test('fromPull parses the streakState blob into the gate '
        'inputs', () {
      final state = settled(completed: {'2026-11-18'});
      final data = SettingsProfileData.fromPull({
        'profile': {'streakState': jsonEncode(state.toJson())},
      });
      expect(data.streakState, isNotNull);
      expect(data.streakState!.summaryCompletedDays, {'2026-11-18'});
      expect(
        settledStreakForCountdown(data.streakState!, now),
        5,
      );
    });

    test('fromPull with no / malformed streakState yields null '
        'and never throws', () {
      expect(SettingsProfileData.fromPull(null).streakState, isNull);
      expect(
        SettingsProfileData.fromPull({'profile': {}}).streakState,
        isNull,
      );
      expect(
        SettingsProfileData.fromPull({
          'profile': {'streakState': 'not json'},
        }).streakState,
        isNull,
      );
    });

    test('copyWith preserves / replaces the streak state', () {
      final state = settled();
      final data = SettingsProfileData(streakState: state);
      expect(data.copyWith().streakState, state);
      expect(
        data.copyWith(streakState: settled(streak: 2)).streakState!
            .seededCurrent,
        2,
      );
    });
  });

  group('rich payload — LocalReminderNotificationService over the '
      'plugin channel', () {
    // The REAL service, driven over the mocked plugin method
    // channel (the notification_bootstrap_test pattern): this is
    // where the AndroidNotificationDetails the redesign changes
    // are asserted, field by field, alongside every field the
    // redesign must NOT change.
    const notificationsChannel =
        MethodChannel('dexterous.com/flutter/local_notifications');
    const timezoneChannel = MethodChannel('flutter_timezone');

    final zonedScheduleCalls = <MethodCall>[];
    final initializeCalls = <MethodCall>[];

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      FlutterLocalNotificationsPlatform.instance =
          AndroidFlutterLocalNotificationsPlugin();
      NotificationBootstrap.debugReset();
      zonedScheduleCalls.clear();
      initializeCalls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(notificationsChannel, (call) async {
        switch (call.method) {
          case 'initialize':
            initializeCalls.add(call);
            return true;
          case 'canScheduleExactNotifications':
            return true;
          case 'zonedSchedule':
            zonedScheduleCalls.add(call);
            return null;
          default:
            return null;
        }
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(timezoneChannel, (call) async {
        if (call.method == 'getLocalTimezone') return 'America/Denver';
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(notificationsChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(timezoneChannel, null);
      debugDefaultTargetPlatformOverride = null;
      NotificationBootstrap.debugReset();
    });

    test('scheduleStreakCountdownOnce posts the rich details with '
        'the gating fields unchanged', () async {
      final service = LocalReminderNotificationService(
          plugin: FlutterLocalNotificationsPlugin());
      // Future dates (the plugin validates the fire time is in
      // the future): tomorrow 20:00 fire, next-midnight boundary.
      final fire = DateTime.now().add(const Duration(days: 1));
      final when = DateTime(fire.year, fire.month, fire.day, 20);
      final countdownTo = DateTime(fire.year, fire.month, fire.day + 1);
      final id = streakCountdownIdForDate(when);
      await service.scheduleStreakCountdownOnce(
        id: id,
        title: streakCountdownHeadlineHtml(27),
        body: streakCountdownBody,
        channelId: streakCountdownChannelId,
        channelName: streakCountdownChannelName,
        channelDescription: streakCountdownChannelDescription,
        when: when,
        countdownTo: countdownTo,
        highImportance: true,
      );

      expect(zonedScheduleCalls, hasLength(1));
      final args =
          zonedScheduleCalls.single.arguments as Map<dynamic, dynamic>;
      // Title/content arguments: Juno's ruled HTML headline and
      // collapsed body; the distinct tap payload.
      expect(args['id'], id);
      expect(args['title'],
          '<b><font color="#7C6EFF">You\'re on a 27 day streak</font></b>');
      expect(args['body'],
          'Finish today\'s Daily Summary when you\'re ready');
      expect(args['payload'], 'daily_summary');

      final specifics =
          args['platformSpecifics'] as Map<dynamic, dynamic>;
      // Channel + importance/priority: unchanged.
      expect(specifics['channelId'], 'streak_reminders');
      expect(specifics['channelName'], 'Streak reminders');
      expect(specifics['channelDescription'],
          streakCountdownChannelDescription);
      expect(specifics['importance'], Importance.high.value);
      expect(specifics['priority'], Priority.high.value);
      // Small icon (RECON-ICON.md, founder scope addition
      // 2026-11-24): deliberately CHANGED from
      // '@mipmap/ic_launcher' — the fully opaque launcher icon
      // rendered as a solid white disc in the status bar. The
      // dedicated silhouette drawable replaces it here and at
      // every other notification site.
      expect(specifics['icon'], 'ic_stat_tabs');
      // The bootstrap's ONE foreground initialize persists the
      // same drawable as the plugin default icon (RECON-ICON
      // §3a: the persisted default is what icon-less posts use,
      // and every initialize rewrites it).
      expect(initializeCalls, hasLength(1));
      expect(
        (initializeCalls.single.arguments
            as Map<dynamic, dynamic>)['defaultIcon'],
        'ic_stat_tabs',
      );
      // Chronometer block: unchanged, byte-for-byte in behavior.
      expect(specifics['showWhen'], isTrue);
      expect(specifics['when'], countdownTo.millisecondsSinceEpoch);
      expect(specifics['usesChronometer'], isTrue);
      expect(specifics['chronometerCountDown'], isTrue);
      expect(specifics['timeoutAfter'],
          countdownTo.difference(when).inMilliseconds);
      // Exact schedule mode (the mock grants exact alarms; the
      // mapper serializes the mode by name).
      expect(specifics['scheduleMode'], 'exactAllowWhileIdle');
      // Large icon: the bandit_full drawable resource. (The
      // AndroidBitmapSource enum is hidden from the plugin's
      // public exports, so the expected serialized index is
      // taken from the exported bitmap class itself.)
      expect(specifics['largeIcon'], 'bandit_full');
      expect(
        specifics['largeIconBitmapSource'],
        const DrawableResourceAndroidBitmap('bandit_full').source.index,
      );
      // BigText style with Juno's exact strings and HTML flags.
      expect(specifics['style'], AndroidNotificationStyle.bigText.index);
      final style =
          specifics['styleInformation'] as Map<dynamic, dynamic>;
      expect(style['contentTitle'],
          '<b><font color="#7C6EFF">You\'re on a 27 day streak</font></b>');
      expect(style['htmlFormatContentTitle'], isTrue);
      expect(style['htmlFormatTitle'], isTrue);
      expect(style['htmlFormatContent'], isFalse);
      expect(
        style['bigText'],
        'Finish today\'s Daily Summary when you\'re ready. '
        'There\'s still time tonight to add today to your streak.',
      );
      expect(style['htmlFormatBigText'], isFalse);
      // Exactly ONE action: the ruled id/label, UI-showing,
      // notification-cancelling.
      final actions = specifics['actions'] as List<dynamic>;
      expect(actions, hasLength(1));
      final action = actions.single as Map<dynamic, dynamic>;
      expect(action['id'], 'open_daily_summary');
      expect(action['title'], 'Open Daily Summary');
      expect(action['showsUserInterface'], isTrue);
      expect(action['cancelNotification'], isTrue);
    });

    test('the shared reminder details builder (check-in, habit, '
        'project, event, user reminders) also carries the new '
        'small icon', () async {
      final service = LocalReminderNotificationService(
          plugin: FlutterLocalNotificationsPlugin());
      final when = DateTime.now().add(const Duration(days: 1));
      await service.scheduleOnce(
        id: 810001,
        title: 'how are you feeling?',
        body: 'one tap is enough. whenever you\'re ready.',
        channelId: 'check_in_reminder',
        channelName: 'Check in reminders',
        when: DateTime(when.year, when.month, when.day, 20),
        highImportance: true,
      );
      expect(zonedScheduleCalls, hasLength(1));
      final args =
          zonedScheduleCalls.single.arguments as Map<dynamic, dynamic>;
      final specifics =
          args['platformSpecifics'] as Map<dynamic, dynamic>;
      expect(specifics['icon'], 'ic_stat_tabs');
      // The other reminders keep the channel-id payload (no
      // routing) — only the streak countdown's payload changed.
      expect(args['payload'], 'check_in_reminder');
    });
  });
}
