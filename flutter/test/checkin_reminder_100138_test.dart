import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/correlation_engine.dart';
import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';

import 'test_helpers.dart';

/// VC 100138 — check-in reminder gate: the bounded 20:00 one-shot
/// projection that replaced the unconditional 04:00 daily
/// (id 770001).
///
/// The gate mirrors native's fire-time rule ("only if not checked
/// in yet") at sync time: a date arms iff its Tabs-day label is
/// NOT among the already-checked-in labels. Labels are the Daily
/// Ranking attribution — `deriveFeelingByDay` keys, i.e.
/// `energyDayLabel` of each check-in entry's timestamp (04:00
/// day boundary; the boundary itself is NOT moved by this
/// package and its pin lives in correlation_engine_test.dart
/// test 2b).
void main() {
  // Wednesday Nov 11, 2026, 10:00 local — before the 20:00 fire.
  final now = DateTime(2026, 11, 11, 10);
  const categories = [
    QuickLogCategory(
      id: 6,
      name: 'Mood & Energy',
      icon: 'circle',
      colorHex: '#CCCCCC',
      isDefault: true,
      sortOrder: 1,
    ),
  ];

  QuickLogEntry feelingAt(DateTime at) => QuickLogEntry(
    id: 1,
    categoryId: 6,
    body: 'Feeling: 3/5 Today',
    chips: '["Daily Ranking"]',
    manualText: '',
    timestamp: at.millisecondsSinceEpoch,
  );

  Set<String> labelsFor(DateTime at) =>
      deriveFeelingByDay([feelingAt(at)], categories).keys.toSet();

  group('check-in id scheme', () {
    test('ids land in 810000–819999 and are disjoint from every '
        'other owner', () {
      const reserved = {1003, 1004, 770001, 7301, 7303, 7304};
      for (var offset = -400; offset <= 400; offset++) {
        final id = checkInReminderIdForDate(
          DateTime(2026, 11, 11 + offset, 20),
        );
        expect(id, inInclusiveRange(810000, 819999));
        expect(reserved.contains(id), isFalse);
        // Event-counter range 700000–799998.
        expect(id >= 700000 && id <= 799998, isFalse);
        // User-reminder blocks 101500–699999.
        expect(id >= 101500 && id <= 699999, isFalse);
        // Project Focus projection 800000–809999.
        expect(id >= 800000 && id <= 809999, isFalse);
        // Habit scheduled-time ids 900000–1899999.
        expect(id >= 900000 && id <= 1899999, isFalse);
      }
    });

    test('id is stable per date and distinct across the cancel '
        'window', () {
      final a = DateTime(2026, 11, 11, 20);
      expect(checkInReminderIdForDate(a), checkInReminderIdForDate(a));
      final ids = {
        for (var offset = -35; offset <= 35; offset++)
          checkInReminderIdForDate(DateTime(2026, 11, 11 + offset)),
      };
      expect(ids.length, 71);
      expect(checkInReminderCancelIds(now).toSet(), ids);
    });
  });

  group('checkInReminderFireTimes', () {
    test('projects 20:00 local, today through today+35, when '
        'nothing is checked in', () {
      final fires = checkInReminderFireTimes(
        now: now,
        checkedInDayLabels: const {},
      );
      expect(fires.length, 36);
      expect(fires.first, DateTime(2026, 11, 11, 20));
      expect(fires.last, DateTime(2026, 12, 16, 20));
      for (final f in fires) {
        expect(f.hour, 20);
        expect(f.minute, 0);
      }
    });

    test('skips a Tabs day already checked in', () {
      final fires = checkInReminderFireTimes(
        now: now,
        checkedInDayLabels: const {'2026-11-11'},
      );
      expect(fires.contains(DateTime(2026, 11, 11, 20)), isFalse);
      expect(fires.first, DateTime(2026, 11, 12, 20));
      expect(fires.length, 35);
    });

    test('includes today when unchecked and 20:00 is ahead', () {
      final fires = checkInReminderFireTimes(
        now: DateTime(2026, 11, 11, 19, 59),
        checkedInDayLabels: const {},
      );
      expect(fires.first, DateTime(2026, 11, 11, 20));
    });

    test('excludes today when 20:00 has passed (and at 20:00 '
        'exactly — strictly after)', () {
      for (final t in [
        DateTime(2026, 11, 11, 20),
        DateTime(2026, 11, 11, 21),
      ]) {
        final fires = checkInReminderFireTimes(
          now: t,
          checkedInDayLabels: const {},
        );
        expect(fires.contains(DateTime(2026, 11, 11, 20)), isFalse);
        expect(fires.first, DateTime(2026, 11, 12, 20));
      }
    });
  });

  group('attribution edges (energyDayLabel via deriveFeelingByDay)', () {
    test('a check-in at 01:30 on calendar D+1 belongs to Tabs '
        'day D — it does NOT suppress the 20:00 fire on D+1', () {
      // D = 2026-11-11; the entry lands 2026-11-12 01:30.
      final labels = labelsFor(DateTime(2026, 11, 12, 1, 30));
      expect(labels, {'2026-11-11'});
      final fires = checkInReminderFireTimes(
        now: DateTime(2026, 11, 12, 10),
        checkedInDayLabels: labels,
      );
      expect(fires, contains(DateTime(2026, 11, 12, 20)));
    });

    test('a check-in at 03:00 on calendar D belongs to Tabs '
        'day D−1 — it does NOT suppress the 20:00 fire on D', () {
      final labels = labelsFor(DateTime(2026, 11, 11, 3));
      expect(labels, {'2026-11-10'});
      final fires = checkInReminderFireTimes(
        now: now,
        checkedInDayLabels: labels,
      );
      expect(fires, contains(DateTime(2026, 11, 11, 20)));
    });

    test('a check-in at 10:00 on calendar D belongs to Tabs '
        'day D — it DOES suppress the 20:00 fire on D', () {
      final labels = labelsFor(DateTime(2026, 11, 11, 10));
      expect(labels, {'2026-11-11'});
      final fires = checkInReminderFireTimes(
        now: now,
        checkedInDayLabels: labels,
      );
      expect(fires.contains(DateTime(2026, 11, 11, 20)), isFalse);
      expect(fires.first, DateTime(2026, 11, 12, 20));
    });
  });

  group('ReminderSync check-in projection', () {
    Future<void> sync(
      FakeReminderNotificationService fake, {
      bool checkInEnabled = true,
      Set<String> labels = const {},
      DateTime? at,
    }) => ReminderSync(fake).syncAll(
      habitEnabled: false,
      projectEnabled: false,
      checkInEnabled: checkInEnabled,
      eventEnabled: false,
      events: const [],
      checkedInDayLabels: labels,
      now: at ?? now,
    );

    test('legacy daily 770001 is cancelled and never armed as a '
        'daily; one-shots run at 20:00 in the new block', () async {
      final fake = FakeReminderNotificationService();
      await sync(fake);
      expect(fake.cancelled, contains(ReminderIds.checkIn));
      expect(fake.daily.containsKey(ReminderIds.checkIn), isFalse);
      expect(fake.once.length, 36);
      for (final e in fake.once.entries) {
        expect(e.key, inInclusiveRange(810000, 819999));
        expect(e.value.hour, 20);
      }
      expect(
        fake.once[checkInReminderIdForDate(DateTime(2026, 11, 11))],
        DateTime(2026, 11, 11, 20),
      );
    });

    test('today checked in: first one-shot is tomorrow', () async {
      final fake = FakeReminderNotificationService();
      await sync(fake, labels: const {'2026-11-11'});
      expect(
        fake.once.containsKey(checkInReminderIdForDate(DateTime(2026, 11, 11))),
        isFalse,
      );
      expect(
        fake.once.values.reduce((a, b) => a.isBefore(b) ? a : b),
        DateTime(2026, 11, 12, 20),
      );
    });

    test('toggle off: legacy id and every projected id cancelled, '
        'zero scheduled', () async {
      final fake = FakeReminderNotificationService();
      await sync(fake, checkInEnabled: false);
      expect(fake.once, isEmpty);
      expect(fake.daily, isEmpty);
      expect(fake.cancelled, contains(ReminderIds.checkIn));
      expect(fake.cancelled, containsAll(checkInReminderCancelIds(now)));
    });

    test('OS notifications disabled: legacy id and projected '
        'window cancelled, nothing scheduled', () async {
      final fake = FakeReminderNotificationService(enabled: false);
      await sync(fake);
      expect(fake.once, isEmpty);
      expect(fake.daily, isEmpty);
      expect(fake.cancelled, contains(ReminderIds.checkIn));
      expect(fake.cancelled, containsAll(checkInReminderCancelIds(now)));
    });

    test('syncCheckInOnly: a save for today drops today\'s '
        'one-shot and re-arms the rest', () async {
      final fake = FakeReminderNotificationService();
      await ReminderSync(fake).syncCheckInOnly(
        checkInEnabled: true,
        checkedInDayLabels: const {'2026-11-11'},
        now: now,
      );
      expect(fake.cancelled, contains(ReminderIds.checkIn));
      expect(fake.cancelled, containsAll(checkInReminderCancelIds(now)));
      expect(
        fake.once.containsKey(checkInReminderIdForDate(DateTime(2026, 11, 11))),
        isFalse,
      );
      expect(
        fake.once.values.reduce((a, b) => a.isBefore(b) ? a : b),
        DateTime(2026, 11, 12, 20),
      );
    });

    test('syncCheckInOnly toggle off / permission off: cancel '
        'only, nothing armed', () async {
      final off = FakeReminderNotificationService();
      await ReminderSync(off).syncCheckInOnly(
        checkInEnabled: false,
        checkedInDayLabels: const {},
        now: now,
      );
      expect(off.once, isEmpty);
      expect(off.cancelled, containsAll(checkInReminderCancelIds(now)));

      final denied = FakeReminderNotificationService(enabled: false);
      await ReminderSync(denied).syncCheckInOnly(
        checkInEnabled: true,
        checkedInDayLabels: const {},
        now: now,
      );
      expect(denied.once, isEmpty);
      expect(denied.cancelled, containsAll(checkInReminderCancelIds(now)));
    });
  });

  group('SettingsProfileData checked-in parse path', () {
    Map<String, dynamic> pullWithEntry(DateTime at) => {
      'profile': <String, dynamic>{},
      'entries': [
        {
          'id': 7,
          'categoryId': 6,
          'body': 'Feeling: 4/5 Today',
          'chips': '["Daily Ranking"]',
          'manualText': '',
          'timestamp': at.millisecondsSinceEpoch,
        },
      ],
      'categories': [
        {
          'id': 6,
          'name': 'Mood & Energy',
          'icon': 'circle',
          'colorHex': '#CCCCCC',
          'isDefault': true,
          'sortOrder': 1,
        },
      ],
    };

    test('fromPull derives the checked-in label from entries + '
        'categories, with 04:00 attribution', () {
      // 10:00 on Nov 11 → Tabs day Nov 11.
      expect(
        SettingsProfileData.fromPull(pullWithEntry(DateTime(2026, 11, 11, 10)))
            .checkedInDayLabels,
        {'2026-11-11'},
      );
      // 01:30 on Nov 12 → Tabs day Nov 11 (not Nov 12).
      expect(
        SettingsProfileData.fromPull(
          pullWithEntry(DateTime(2026, 11, 12, 1, 30)),
        ).checkedInDayLabels,
        {'2026-11-11'},
      );
    });

    test('fromPull with no entries / no check-in yields an empty '
        'set and never throws', () {
      expect(SettingsProfileData.fromPull(null).checkedInDayLabels, isEmpty);
      expect(
        SettingsProfileData.fromPull({'profile': {}}).checkedInDayLabels,
        isEmpty,
      );
      expect(
        SettingsProfileData.fromPull({
          'profile': {},
          'entries': [
            {'id': 'bad'},
            {
              'id': 8,
              'categoryId': 6,
              'body': 'a normal note',
              'chips': '[]',
              'manualText': '',
              'timestamp': DateTime(2026, 11, 11, 10).millisecondsSinceEpoch,
            },
          ],
          'categories': const [],
        }).checkedInDayLabels,
        isEmpty,
      );
    });

    test('copyWith preserves / replaces the label set', () {
      const data = SettingsProfileData(checkedInDayLabels: {'2026-11-11'});
      expect(data.copyWith().checkedInDayLabels, {'2026-11-11'});
      expect(
        data.copyWith(checkedInDayLabels: const {}).checkedInDayLabels,
        isEmpty,
      );
    });
  });
}
