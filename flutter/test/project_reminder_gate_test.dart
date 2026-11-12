import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/focus_test.dart';
import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';

import 'test_helpers.dart';

/// Project Focus reminder gate — the bounded one-shot projection
/// that replaced the unconditional daily schedule (id 1004).
///
/// Native mirror: `ProjectReminderWorker.kt` posts at fire time
/// only when some active test is not completed (elapsed <
/// duration) AND not checked in for today, where checked-in = the
/// day's `yyyy-MM-dd` key is PRESENT in `logs` (any value) OR the
/// day's `EEE MMM dd yyyy` string equals `lockDayStr`. The
/// projection precomputes exactly those days at sync time.
class RecordingFake extends FakeReminderNotificationService {
  final Map<int, ({String title, String body, String channelId, bool high})>
      onceDetails = {};

  RecordingFake({super.enabled});

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
    onceDetails[id] =
        (title: title, body: body, channelId: channelId, high: highImportance);
    await super.scheduleOnce(
      id: id,
      title: title,
      body: body,
      channelId: channelId,
      channelName: channelName,
      when: when,
      highImportance: highImportance,
    );
  }
}

FocusTest makeTest({
  String id = 't1',
  required DateTime start,
  required int days,
  Map<String, bool> logs = const {},
  String? lockDayStr,
}) =>
    FocusTest(
      id: id,
      title: 'Test $id',
      durationDays: days,
      startTimestamp: start.millisecondsSinceEpoch,
      logs: logs,
      lockDayStr: lockDayStr,
    );

Future<void> sync(
  FakeReminderNotificationService fake, {
  required bool projectEnabled,
  required List<FocusTest> focusTests,
  required DateTime now,
  bool habitEnabled = false,
  bool checkInEnabled = false,
}) =>
    ReminderSync(fake).syncAll(
      habitEnabled: habitEnabled,
      projectEnabled: projectEnabled,
      checkInEnabled: checkInEnabled,
      eventEnabled: false,
      events: const [],
      focusTests: focusTests,
      now: now,
    );

void main() {
  // Wednesday Nov 11, 2026, 10:00 local — before the 20:00 fire.
  final now = DateTime(2026, 11, 11, 10);

  group('project id scheme', () {
    test('ids land in 800000–809999 and are disjoint from every '
        'other owner', () {
      const reserved = {1003, 1004, 770001, 7301, 7303, 7304};
      for (var offset = -400; offset <= 400; offset++) {
        final id = projectReminderIdForDate(
            DateTime(2026, 11, 11 + offset, 20));
        expect(id, inInclusiveRange(800000, 809999));
        expect(reserved.contains(id), isFalse);
        // Event-counter range 700000–799998.
        expect(id >= 700000 && id <= 799998, isFalse);
        // User-reminder blocks 101500–699999.
        expect(id >= 101500 && id <= 699999, isFalse);
      }
    });

    test('id is stable per date and distinct across the window', () {
      final a = DateTime(2026, 11, 11, 20);
      expect(projectReminderIdForDate(a), projectReminderIdForDate(a));
      final ids = {
        for (var offset = -35; offset <= 35; offset++)
          projectReminderIdForDate(DateTime(2026, 11, 11 + offset)),
      };
      expect(ids.length, 71);
      expect(projectReminderCancelIds(now).toSet(), ids);
    });
  });

  group('native-mirror helpers', () {
    test('date keys and lock-day strings match native formats', () {
      expect(focusLogDateKey(DateTime(2026, 11, 9)), '2026-11-09');
      expect(focusLogDateKey(DateTime(2026, 11, 11)), '2026-11-11');
      // Pattern 'EEE MMM dd yyyy', Locale.US.
      expect(focusLockDayString(DateTime(2026, 11, 11)), 'Wed Nov 11 2026');
      expect(focusLockDayString(DateTime(2026, 11, 9)), 'Mon Nov 09 2026');
    });

    test('checked-in is key PRESENCE — a false log still counts', () {
      final t = makeTest(
          start: DateTime(2026, 11, 9, 9),
          days: 5,
          logs: const {'2026-11-11': false});
      expect(focusTestCheckedInOn(t, DateTime(2026, 11, 11)), isTrue);
      expect(focusTestCheckedInOn(t, DateTime(2026, 11, 12)), isFalse);
    });

    test('lockDayStr equal to the day counts as checked in', () {
      final t = makeTest(
          start: DateTime(2026, 11, 11, 9),
          days: 5,
          lockDayStr: 'Wed Nov 11 2026');
      expect(focusTestCheckedInOn(t, DateTime(2026, 11, 11)), isTrue);
      expect(focusTestCheckedInOn(t, DateTime(2026, 11, 12)), isFalse);
    });

    test('a future test arms only from its start date; one starting '
        'past the horizon arms nothing', () {
      // Starts Nov 20 09:00: no fire before Nov 20 qualifies
      // (startTimestamp <= fire time is a per-date rule), the start
      // day itself does.
      final future = makeTest(start: DateTime(2026, 11, 20, 9), days: 5);
      final fires = projectReminderFireTimes(now: now, tests: [future]);
      expect(fires.first, DateTime(2026, 11, 20, 20));
      // Starts Dec 20 — beyond today + 35 days (Dec 16): nothing.
      final beyond = makeTest(start: DateTime(2026, 12, 20, 9), days: 5);
      expect(projectReminderFireTimes(now: now, tests: [beyond]),
          isEmpty);
    });
  });

  group('ReminderSync project projection', () {
    test('no focus tests: daily cancelled, zero one-shots', () async {
      final fake = RecordingFake();
      await sync(fake,
          projectEnabled: true, focusTests: const [], now: now);
      expect(fake.cancelled, contains(ReminderIds.project));
      expect(fake.daily.containsKey(ReminderIds.project), isFalse);
      expect(fake.once, isEmpty);
      // The whole projected window was swept too.
      expect(fake.cancelled,
          containsAll(projectReminderCancelIds(now)));
    });

    test("only completed tests (the founder's real shape): "
        'cancelled, zero one-shots', () async {
      final fake = RecordingFake();
      final tests = [
        makeTest(id: 'a', start: DateTime(2026, 6, 14, 9), days: 7),
        makeTest(id: 'b', start: DateTime(2026, 7, 31, 9), days: 7),
      ];
      await sync(fake, projectEnabled: true, focusTests: tests, now: now);
      expect(fake.cancelled, contains(ReminderIds.project));
      expect(fake.once, isEmpty);
    });

    test('in-progress, today unlogged, now before 20:00: one-shots '
        "run today through the test's last qualifying day", () async {
      final fake = RecordingFake();
      // Starts Nov 9 09:00, 5 days → completes Nov 14 09:00, so the
      // last 20:00 that still sees it active is Nov 13.
      final t = makeTest(start: DateTime(2026, 11, 9, 9), days: 5);
      await sync(fake, projectEnabled: true, focusTests: [t], now: now);
      final expected = [11, 12, 13].map((d) => DateTime(2026, 11, d, 20));
      expect(fake.once.values.toList()..sort(), expected.toList()..sort());
      for (final fire in expected) {
        expect(fake.once[projectReminderIdForDate(fire)], fire);
        final details = fake.onceDetails[projectReminderIdForDate(fire)];
        // Byte-identical to the retired daily schedule.
        expect(details?.title, 'Project Focus Nudge ⏳');
        expect(details?.body,
            "Don't forget to complete your project task for the day.");
        expect(details?.channelId, 'project_reminders');
        expect(details?.high, isFalse);
      }
      expect(fake.daily.containsKey(ReminderIds.project), isFalse);
      expect(fake.cancelled, contains(ReminderIds.project));
    });

    test('today already logged: first one-shot is tomorrow', () async {
      final fake = RecordingFake();
      final t = makeTest(
          start: DateTime(2026, 11, 9, 9),
          days: 5,
          logs: const {'2026-11-11': true});
      await sync(fake, projectEnabled: true, focusTests: [t], now: now);
      expect(fake.once.values.reduce((a, b) => a.isBefore(b) ? a : b),
          DateTime(2026, 11, 12, 20));
      expect(
          fake.once.containsKey(
              projectReminderIdForDate(DateTime(2026, 11, 11, 20))),
          isFalse);
    });

    test('today logged with a FALSE value still skips today '
        '(key presence, native rule)', () async {
      final fake = RecordingFake();
      final t = makeTest(
          start: DateTime(2026, 11, 9, 9),
          days: 5,
          logs: const {'2026-11-11': false});
      await sync(fake, projectEnabled: true, focusTests: [t], now: now);
      expect(
          fake.once.containsKey(
              projectReminderIdForDate(DateTime(2026, 11, 11, 20))),
          isFalse);
      expect(fake.once.values.reduce((a, b) => a.isBefore(b) ? a : b),
          DateTime(2026, 11, 12, 20));
    });

    test('lockDayStr == today skips today', () async {
      final fake = RecordingFake();
      final t = makeTest(
          start: DateTime(2026, 11, 11, 9),
          days: 5,
          lockDayStr: focusLockDayString(DateTime(2026, 11, 11)));
      await sync(fake, projectEnabled: true, focusTests: [t], now: now);
      expect(
          fake.once.containsKey(
              projectReminderIdForDate(DateTime(2026, 11, 11, 20))),
          isFalse);
      expect(fake.once.values.reduce((a, b) => a.isBefore(b) ? a : b),
          DateTime(2026, 11, 12, 20));
    });

    test("a test whose window ends tomorrow: one-shots stop at "
        'tomorrow', () async {
      final fake = RecordingFake();
      // Starts today 10:00, 2 days → completes Nov 13 10:00; the
      // Nov 13 20:00 fire already sees it completed.
      final t = makeTest(start: DateTime(2026, 11, 11, 10), days: 2);
      await sync(fake, projectEnabled: true, focusTests: [t], now: now);
      expect(fake.once.values.toList()..sort(),
          [DateTime(2026, 11, 11, 20), DateTime(2026, 11, 12, 20)]);
    });

    test('now after 20:00: today never arms even when unlogged',
        () async {
      final fake = RecordingFake();
      final t = makeTest(start: DateTime(2026, 11, 9, 9), days: 5);
      await sync(fake,
          projectEnabled: true,
          focusTests: [t],
          now: DateTime(2026, 11, 11, 21));
      expect(
          fake.once.containsKey(
              projectReminderIdForDate(DateTime(2026, 11, 11, 20))),
          isFalse);
      expect(fake.once.values.reduce((a, b) => a.isBefore(b) ? a : b),
          DateTime(2026, 11, 12, 20));
    });

    test('toggle off: daily and every projected id cancelled, '
        'zero scheduled', () async {
      final fake = RecordingFake();
      final t = makeTest(start: DateTime(2026, 11, 9, 9), days: 5);
      await sync(fake, projectEnabled: false, focusTests: [t], now: now);
      expect(fake.once, isEmpty);
      expect(fake.daily, isEmpty);
      expect(fake.cancelled, contains(ReminderIds.project));
      expect(fake.cancelled,
          containsAll(projectReminderCancelIds(now)));
    });

    test('OS notifications disabled: projected window is cancelled '
        'too, nothing scheduled', () async {
      final fake = RecordingFake(enabled: false);
      final t = makeTest(start: DateTime(2026, 11, 9, 9), days: 5);
      await sync(fake, projectEnabled: true, focusTests: [t], now: now);
      expect(fake.once, isEmpty);
      expect(fake.daily, isEmpty);
      expect(fake.cancelled,
          containsAll([ReminderIds.habit, ReminderIds.project, ReminderIds.checkIn]));
      expect(fake.cancelled,
          containsAll(projectReminderCancelIds(now)));
    });
  });

  group('SettingsProfileData focus parse path', () {
    test('fromPull carries focusState (JSON string) into focusTests',
        () {
      final startMs = DateTime(2026, 11, 9, 9).millisecondsSinceEpoch;
      final data = SettingsProfileData.fromPull({
        'profile': {
          'focusState':
              '{"activeTests":[{"id":"x","title":"T","durationDays":5,'
              '"startTimestamp":$startMs,"logs":{}}]}',
        },
      });
      expect(data.focusStateRaw, isNotEmpty);
      expect(data.focusTests.length, 1);
      expect(data.focusTests.single.id, 'x');
      expect(data.focusTests.single.durationDays, 5);
    });

    test('fromPull tolerates an already-decoded focusState map', () {
      final startMs = DateTime(2026, 11, 9, 9).millisecondsSinceEpoch;
      final data = SettingsProfileData.fromPull({
        'profile': {
          'focusState': {
            'activeTests': [
              {
                'id': 'y',
                'title': 'T2',
                'durationDays': 3,
                'startTimestamp': startMs,
              },
            ],
          },
        },
      });
      expect(data.focusTests.length, 1);
      expect(data.focusTests.single.id, 'y');
    });

    test('missing focusState parses to no tests', () {
      expect(SettingsProfileData.fromPull(null).focusTests, isEmpty);
      expect(
          SettingsProfileData.fromPull({'profile': {}}).focusTests,
          isEmpty);
    });
  });
}
