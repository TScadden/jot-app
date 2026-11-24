import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/first_run_sync.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/features/tools/habits_screen.dart';

import 'test_helpers.dart';

/// Habits daily aggregate reminder — the bounded 19:00 one-shot
/// projection that replaced the unconditional daily repeating
/// alarm (ReminderIds.habit = 1003).
///
/// Founder report (Nov 23, 2026, 19:00 MST): the aggregate
/// reminder fired saying habits remained even though every habit
/// was finished. The shipped rule (Settings copy): "Daily ping
/// at 7:00 PM if you have unchecked habits remaining." The old
/// code armed scheduleDaily(1003) with no completion gate at all
/// (MECHANISM.md). The fix follows the Nov 11, 2026 lesson —
/// fire-time gates become sync-time projections — in the shape
/// of the Project Focus / check-in / streak-countdown precedents
/// in the same file: cancel the legacy daily id AND the whole
/// projected window on EVERY sync, then arm one 19:00 one-shot
/// per date on which at least one habit is unchecked.
///
/// Copy is byte-identical to the retired daily: title
/// 'Finish your habits! ✅', body 'You still have some daily
/// habits to check off. Keep your streak alive!', channel
/// 'habit_reminders', highImportance false.

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
    onceDetails[id] = (
      title: title,
      body: body,
      channelId: channelId,
      high: highImportance,
    );
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

void main() {
  setUp(TabsBackend.debugResetSharedCaches);

  // Monday Nov 23, 2026, 10:00 local — before the 19:00 fire.
  final now = DateTime(2026, 11, 23, 10);
  const todayKey = '2026-11-23';
  const tomorrowKey = '2026-11-24';

  HabitDto habit({
    String id = 'h1',
    String title = 'Physical therapy exercises',
    List<String> logs = const [],
  }) =>
      HabitDto(id: id, title: title, logs: logs);

  group('habit daily id scheme (830000–839999)', () {
    test('ids land in the block and are disjoint from every other '
        'owner', () {
      const reserved = {1003, 1004, 770001, 7301, 7303, 7304};
      for (var offset = -400; offset <= 400; offset++) {
        final id = habitDailyReminderIdForDate(
          DateTime(2026, 11, 23 + offset, 19),
        );
        expect(id, inInclusiveRange(830000, 839999));
        expect(reserved.contains(id), isFalse);
        // User-reminder blocks 101500–699999.
        expect(id >= 101500 && id <= 699999, isFalse);
        // Event-counter ids 700000–799998.
        expect(id >= 700000 && id <= 799998, isFalse);
        // Project Focus projection 800000–809999.
        expect(id >= 800000 && id <= 809999, isFalse);
        // Check-in projection 810000–819999.
        expect(id >= 810000 && id <= 819999, isFalse);
        // Streak countdown projection 820000–829999.
        expect(id >= 820000 && id <= 829999, isFalse);
        // Habit scheduled-time ids 900000–1899999.
        expect(id >= 900000 && id <= 1899999, isFalse);
      }
    });

    test('id is stable per date and distinct across the cancel '
        'window (71 ids)', () {
      final a = DateTime(2026, 11, 23, 19);
      expect(
        habitDailyReminderIdForDate(a),
        habitDailyReminderIdForDate(a),
      );
      final ids = {
        for (var offset = -35; offset <= 35; offset++)
          habitDailyReminderIdForDate(DateTime(2026, 11, 23 + offset)),
      };
      expect(ids.length, 71);
      expect(habitDailyReminderCancelIds(now).toSet(), ids);
    });
  });

  group('habitDailyFireTimes (the shared gate model)', () {
    test('(a) all habits logged for today → nothing tonight, '
        'future days still armed', () {
      final fires = habitDailyFireTimes(
        now: now,
        habits: [habit(logs: const [todayKey])],
      );
      expect(fires.contains(DateTime(2026, 11, 23, 19)), isFalse);
      expect(fires.first, DateTime(2026, 11, 24, 19));
      expect(fires.length, 35);
    });

    test('(b) one habit unchecked → tonight 19:00 armed, 36 fires',
        () {
      final fires = habitDailyFireTimes(
        now: now,
        habits: [
          habit(logs: const [todayKey]),
          habit(id: 'h2', title: 'Stretch'),
        ],
      );
      expect(fires.length, 36);
      expect(fires.first, DateTime(2026, 11, 23, 19));
      expect(fires.last, DateTime(2026, 12, 28, 19));
      for (final f in fires) {
        expect(f.hour, 19);
        expect(f.minute, 0);
      }
    });

    test('no habits at all → nothing armed', () {
      expect(habitDailyFireTimes(now: now, habits: const []), isEmpty);
    });

    test('after 19:00, tonight is not armed even when unchecked '
        '(strictly after)', () {
      for (final t in [DateTime(2026, 11, 23, 19), DateTime(2026, 11, 23, 21)]) {
        final fires = habitDailyFireTimes(now: t, habits: [habit()]);
        expect(fires.contains(DateTime(2026, 11, 23, 19)), isFalse);
        expect(fires.first, DateTime(2026, 11, 24, 19));
      }
    });

    test('a future date fully logged is skipped, others stay', () {
      final fires = habitDailyFireTimes(
        now: now,
        habits: [habit(logs: const [tomorrowKey])],
      );
      expect(fires.first, DateTime(2026, 11, 23, 19));
      expect(fires.contains(DateTime(2026, 11, 24, 19)), isFalse);
      expect(fires.length, 35);
    });
  });

  group('ReminderSync habit daily projection', () {
    Future<void> sync(
      FakeReminderNotificationService fake, {
      bool habitEnabled = true,
      List<HabitDto> habits = const [],
      DateTime? at,
    }) =>
        ReminderSync(fake).syncAll(
          habitEnabled: habitEnabled,
          projectEnabled: false,
          checkInEnabled: false,
          eventEnabled: false,
          events: const [],
          habits: habits,
          now: at ?? now,
        );

    test('(a)+(d) all done today: no 19:00 one-shot tonight, '
        'legacy daily 1003 cancelled and never armed as a daily',
        () async {
      final fake = RecordingFake();
      await sync(fake, habits: [habit(logs: const [todayKey])]);
      expect(fake.daily.containsKey(ReminderIds.habit), isFalse);
      expect(fake.cancelled, contains(ReminderIds.habit));
      expect(fake.cancelled, containsAll(habitDailyReminderCancelIds(now)));
      final tonightId = habitDailyReminderIdForDate(DateTime(2026, 11, 23));
      expect(fake.once.containsKey(tonightId), isFalse);
      // Future days (no logs yet) still project: 35 one-shots, all
      // inside the new block at 19:00.
      expect(fake.once.length, 35);
      for (final e in fake.once.entries) {
        expect(e.key, inInclusiveRange(830000, 839999));
        expect(e.value.hour, 19);
      }
    });

    test('(b) one unchecked: tonight armed with byte-identical '
        'copy on the habit channel', () async {
      final fake = RecordingFake();
      await sync(fake, habits: [habit()]);
      final tonightId = habitDailyReminderIdForDate(DateTime(2026, 11, 23));
      expect(fake.once[tonightId], DateTime(2026, 11, 23, 19));
      final details = fake.onceDetails[tonightId]!;
      expect(details.title, 'Finish your habits! ✅');
      expect(
        details.body,
        'You still have some daily habits to check off. '
        'Keep your streak alive!',
      );
      expect(details.channelId, 'habit_reminders');
      expect(details.high, isFalse);
      expect(fake.once.length, 36);
    });

    test('toggle off: legacy id and whole window cancelled, '
        'zero armed', () async {
      final fake = RecordingFake();
      await sync(fake, habitEnabled: false, habits: [habit()]);
      expect(fake.once, isEmpty);
      expect(fake.daily, isEmpty);
      expect(fake.cancelled, contains(ReminderIds.habit));
      expect(fake.cancelled, containsAll(habitDailyReminderCancelIds(now)));
    });

    test('OS notifications disabled: legacy id and whole window '
        'cancelled, nothing scheduled', () async {
      final fake = RecordingFake(enabled: false);
      await sync(fake, habits: [habit()]);
      expect(fake.once, isEmpty);
      expect(fake.daily, isEmpty);
      expect(fake.cancelled, contains(ReminderIds.habit));
      expect(fake.cancelled, containsAll(habitDailyReminderCancelIds(now)));
    });

    test('habit enabled but no habits: nothing armed, legacy '
        'still cancelled', () async {
      final fake = RecordingFake();
      await sync(fake);
      expect(fake.once, isEmpty);
      expect(fake.daily, isEmpty);
      expect(fake.cancelled, contains(ReminderIds.habit));
    });
  });

  group('syncHabitDailyOnly (completion-path re-sync)', () {
    test('(c) completing the last habit disarms tonight; '
        'un-completing re-arms it', () async {
      final fake = RecordingFake();
      final tonightId = habitDailyReminderIdForDate(DateTime(2026, 11, 23));

      await ReminderSync(fake).syncHabitDailyOnly(
        habitEnabled: true,
        habits: [habit()],
        now: now,
      );
      expect(fake.once[tonightId], DateTime(2026, 11, 23, 19));

      // The last habit is completed (its logs now carry today).
      await ReminderSync(fake).syncHabitDailyOnly(
        habitEnabled: true,
        habits: [habit(logs: const [todayKey])],
        now: now,
      );
      expect(fake.once.containsKey(tonightId), isFalse);
      expect(fake.cancelled, contains(tonightId));
      expect(fake.cancelled, contains(ReminderIds.habit));

      // Un-completing re-arms tonight (19:00 still ahead at `now`).
      await ReminderSync(fake).syncHabitDailyOnly(
        habitEnabled: true,
        habits: [habit()],
        now: now,
      );
      expect(fake.once[tonightId], DateTime(2026, 11, 23, 19));
    });

    test('toggle off / permission off: cancel only, nothing armed',
        () async {
      final off = RecordingFake();
      await ReminderSync(off).syncHabitDailyOnly(
        habitEnabled: false,
        habits: [habit()],
        now: now,
      );
      expect(off.once, isEmpty);
      expect(off.cancelled, contains(ReminderIds.habit));
      expect(off.cancelled, containsAll(habitDailyReminderCancelIds(now)));

      final denied = RecordingFake(enabled: false);
      await ReminderSync(denied).syncHabitDailyOnly(
        habitEnabled: true,
        habits: [habit()],
        now: now,
      );
      expect(denied.once, isEmpty);
      expect(denied.cancelled, contains(ReminderIds.habit));
      expect(denied.cancelled, containsAll(habitDailyReminderCancelIds(now)));
    });
  });

  group('first-run resync flag', () {
    test('doneKey is bumped to v6 so upgraded devices drop the '
        'stale daily alarm on first launch', () {
      expect(
        FirstRunReminderResync.doneKey,
        'first_run_reminder_resync_v6',
      );
    });
  });

  group('Today Summary completion path (today_summary.dart)', () {
    // In-memory habits server: one habit, mutable logs; the pull
    // carries habitReminderEnabled=true and the Goals & Habits
    // category the completion entry needs.
    late List<String> serverLogs;
    late MockClient client;

    TodaySummaryLoader loaderFor(FakeReminderNotificationService fake) {
      final session = FakeSessionStore()..token = 'tok';
      return TodaySummaryLoader(
        backend: TabsBackend(client: client, sessionStore: session),
        notificationService: fake,
        sessionStore: session,
      );
    }

    setUp(() {
      serverLogs = [];
      client = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'GET' && path == '/api/habits') {
          return http.Response(
            jsonEncode({
              'habits': [
                {
                  'id': 'h1',
                  'title': 'Stretch',
                  'target_time': 'Anytime',
                  'logs': serverLogs,
                },
              ],
            }),
            200,
          );
        }
        if (request.method == 'POST' && path == '/api/habits/log') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final date = body['completed_date'] as String;
          serverLogs = body['is_completed'] == true
              ? [...serverLogs, date]
              : serverLogs.where((l) => l != date).toList();
          return http.Response('{"success":true}', 200);
        }
        if (request.method == 'GET' && path == '/api/sync/pull') {
          return http.Response(
            jsonEncode({
              'profile': {'habitReminderEnabled': true},
              'entries': <dynamic>[],
              'categories': [
                {
                  'id': 4,
                  'name': 'Goals & Habits',
                  'icon': 'target',
                  'colorHex': '#CCCCCC',
                  'isDefault': true,
                  'sortOrder': 1,
                },
              ],
            }),
            200,
          );
        }
        if (request.method == 'POST' && path == '/api/sync/entries') {
          return http.Response('{"success":true}', 200);
        }
        return http.Response('{}', 404);
      });
    });

    const item = TodayPlanItem(
      kind: PlanItemKind.habit,
      id: 'habit_h1',
      title: 'Stretch',
      timeDisplay: 'Anytime',
      isCompleted: false,
      habitId: 'h1',
    );

    test('completing the last habit from Home disarms tonight; '
        'un-completing re-arms it', () async {
      final fake = RecordingFake();
      final at = DateTime.now();
      final today = DateTime(at.year, at.month, at.day);
      final tonightId = habitDailyReminderIdForDate(today);
      // Arm tonight first (10:00 projection, one habit unchecked).
      await ReminderSync(fake).syncHabitDailyOnly(
        habitEnabled: true,
        habits: [habit(id: 'h1', title: 'Stretch')],
        now: DateTime(today.year, today.month, today.day, 10),
      );
      expect(fake.once[tonightId], DateTime(today.year, today.month, today.day, 19));

      final loader = loaderFor(fake);
      expect(await loader.setHabitCompleted(item, true, now: at), isTrue);
      expect(serverLogs, isNotEmpty);
      expect(
        fake.once.containsKey(tonightId),
        isFalse,
        reason: 'the Home completion path must re-project the '
            'aggregate reminder — tonight drops out',
      );
      expect(fake.cancelled, contains(ReminderIds.habit));

      expect(await loader.setHabitCompleted(item, false, now: at), isTrue);
      expect(serverLogs, isEmpty);
      // Re-armed only when 19:00 is still ahead at run time.
      if (DateTime(today.year, today.month, today.day, 19).isAfter(at)) {
        expect(fake.once[tonightId],
            DateTime(today.year, today.month, today.day, 19));
      }
    });
  });

  group('Habits screen completion path (habits_screen.dart)', () {
    testWidgets('toggle re-projects the aggregate: completing the '
        'last habit disarms tonight, un-completing re-arms it',
        (tester) async {
      var logs = <String>[];
      final client = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'GET' && path == '/api/habits') {
          return http.Response(
            jsonEncode({
              'habits': [
                {
                  'id': 'h1',
                  'title': 'Drink water',
                  'target_time': 'Anytime',
                  'logs': logs,
                },
              ],
            }),
            200,
          );
        }
        if (request.method == 'POST' && path == '/api/habits/log') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final date = body['completed_date'] as String;
          logs = body['is_completed'] == true
              ? [...logs, date]
              : logs.where((l) => l != date).toList();
          return http.Response('{}', 200);
        }
        return http.Response('{}', 404);
      });
      final session = FakeSessionStore()..token = 'tok';
      final fake = RecordingFake();
      await tester.pumpWidget(
        MaterialApp(
          home: HabitsScreen(
            backend: TabsBackend(client: client, sessionStore: session),
            notificationService: fake,
            habitReminderEnabled: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final at = DateTime.now();
      final today = DateTime(at.year, at.month, at.day);
      final tonightId = habitDailyReminderIdForDate(today);
      final tonight = DateTime(today.year, today.month, today.day, 19);
      if (tonight.isAfter(at)) {
        expect(fake.once[tonightId], tonight);
      }

      await tester.tap(find.text('Drink water'));
      await tester.pumpAndSettle();
      expect(find.text('1/1 DONE'), findsOneWidget);
      expect(fake.once.containsKey(tonightId), isFalse);
      expect(fake.cancelled, contains(tonightId));
      expect(fake.cancelled, contains(ReminderIds.habit));

      await tester.tap(find.text('Drink water'));
      await tester.pumpAndSettle();
      expect(find.text('0/1 DONE'), findsOneWidget);
      if (tonight.isAfter(at)) {
        expect(fake.once[tonightId], tonight);
      }
    });
  });
}
