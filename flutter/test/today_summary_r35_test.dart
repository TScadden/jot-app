import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/main.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/onboarding_store.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/home/today_summary_card.dart';
import 'package:tabs_lab/src/features/onboarding/welcome_screen.dart';
import 'package:tabs_lab/src/features/settings/account_actions.dart';

import 'test_helpers.dart';

/// Round 35 — Today Summary audit regression suite.
///
/// Fixtures mimic the server's REAL shapes: int8 columns arrive as
/// JSON strings (node-pg), profile blobs are JSON strings, habit rows
/// carry `target_time` + `logs` date strings, and medication blob rows
/// use native's view-model shape (no timesPerDay).

String day(DateTime d) => dateStrOf(d);

DateTime get _now => DateTime.now();

/// Fixture entry timestamps: safely inside "today" but a few minutes
/// in the past — a fixture stamped at handler time would land a few
/// milliseconds AFTER the loader's captured `now` and read as a
/// future entry (the symptom window excludes those, like native).
int get _pastMs =>
    DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch;
String get _today => day(_now);
String daysAgo(int n) => day(_now.subtract(Duration(days: n)));

/// In-memory secure-storage backing for the plan store / cache.
class MemoryStore {
  final Map<String, String> map = {};
  Future<String?> read(String k) async => map[k];
  Future<void> write(String k, String v) async => map[k] = v;
  Future<void> delete(String k) async => map.remove(k);
}

TodayPlanStore planStoreWith(MemoryStore s) {
  final store = TodayPlanStore.testInstance();
  store.debugSetStore(read: s.read, write: s.write, delete: s.delete);
  return store;
}

TodaySummaryCache cacheWith(MemoryStore s) {
  final cache = TodaySummaryCache.testInstance();
  cache.debugSetStore(read: s.read, write: s.write, delete: s.delete);
  return cache;
}

class FakeSummaryHc extends HealthConnectService {
  final Map<String, int> sleepByDate;
  final List<({String date, int bpm})> rhrHistory;
  FakeSummaryHc({this.sleepByDate = const {}, this.rhrHistory = const []});

  @override
  Future<int?> readSleepMinutes(String dateStr) async =>
      sleepByDate[dateStr];

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
          int days) async =>
      rhrHistory;
}

HabitDto habit(String id, String title,
        {String target = 'Anytime', List<String> logs = const []}) =>
    HabitDto(id: id, title: title, logs: logs, targetTime: target);

QuickLogEntry entry(int id, int categoryId, String body, DateTime at) =>
    QuickLogEntry(
      id: id,
      categoryId: categoryId,
      body: body,
      chips: '[]',
      manualText: '',
      timestamp: at.millisecondsSinceEpoch,
    );

void main() {
  group('buildTodayPlan — native summaryText (TodayViewModel port)', () {
    TodayPlanData build({
      List<SummaryMedication> meds = const [],
      List<SummaryReminder> reminders = const [],
      List<HabitDto> habits = const [],
      TodayPlanLocalState local = const TodayPlanLocalState(),
      List<QuickLogEntry> entries = const [],
      int? medCategoryId,
      DateTime? now,
    }) =>
        buildTodayPlan(
          medications: meds,
          reminders: reminders,
          habits: habits,
          localState: local,
          entries: entries,
          medicationCategoryId: medCategoryId,
          now: now ?? DateTime(2026, 10, 13, 9, 0),
        );

    test('empty plan → "No plans recorded today"', () {
      expect(build().summaryText, 'No plans recorded today');
      expect(build().remainingCount, 0);
    });

    test('remaining counts + pluralization', () {
      final data = build(reminders: [
        const SummaryReminder(
            id: 1, title: 'A', fixedHour: 23, fixedMinute: 0, isEnabled: true),
        const SummaryReminder(
            id: 2, title: 'B', fixedHour: 23, fixedMinute: 30, isEnabled: true),
      ]);
      expect(data.summaryText, '2 items remaining');
      final one = build(reminders: [
        const SummaryReminder(
            id: 1, title: 'A', fixedHour: 23, fixedMinute: 0, isEnabled: true),
      ]);
      expect(one.summaryText, '1 item remaining');
    });

    test('all complete → "Everything planned for today is complete"', () {
      final data = build(
        reminders: [
          const SummaryReminder(
              id: 1,
              title: 'A',
              fixedHour: 8,
              fixedMinute: 0,
              isEnabled: true),
        ],
        local: const TodayPlanLocalState(completedReminderIds: {1}),
      );
      expect(data.summaryText, 'Everything planned for today is complete');
    });

    test('overdue suffix joins with " · "', () {
      // 09:00 now; an 08:00 reminder is overdue by the summary rule
      // (fixedHour < currentHour), a 23:00 one is not.
      final data = build(reminders: [
        const SummaryReminder(
            id: 1, title: 'A', fixedHour: 8, fixedMinute: 0, isEnabled: true),
        const SummaryReminder(
            id: 2, title: 'B', fixedHour: 23, fixedMinute: 0, isEnabled: true),
      ]);
      expect(data.summaryText, '2 items remaining · 1 overdue');
      expect(data.overdueCount, 1);
    });

    test('disabled reminders are excluded (native: isEnabled only)', () {
      final data = build(reminders: [
        const SummaryReminder(
            id: 1, title: 'A', fixedHour: 8, fixedMinute: 0, isEnabled: false),
      ]);
      expect(data.items, isEmpty);
      expect(data.summaryText, 'No plans recorded today');
    });

    test('sort: incomplete first, then timeDisplay string order', () {
      final data = build(
        reminders: [
          const SummaryReminder(
              id: 1,
              title: 'late',
              fixedHour: 21,
              fixedMinute: 0,
              isEnabled: true),
          const SummaryReminder(
              id: 2,
              title: 'early',
              fixedHour: 7,
              fixedMinute: 30,
              isEnabled: true),
          const SummaryReminder(
              id: 3,
              title: 'done',
              fixedHour: 6,
              fixedMinute: 0,
              isEnabled: true),
        ],
        local: const TodayPlanLocalState(completedReminderIds: {3}),
      );
      expect(data.items.map((i) => i.title).toList(),
          ['early', 'late', 'done']);
      expect(data.items.first.timeDisplay, '07:30');
    });

    test('habit completion comes from logs containing today', () {
      final data = build(
        habits: [habit('h1', 'Stretch', logs: [_today])],
        now: _now,
      );
      expect(data.items.single.isCompleted, isTrue);
      expect(data.items.single.timeDisplay, 'Anytime');
    });
  });

  group('buildTodayPlan — medication status sources', () {
    const med = SummaryMedication(key: 'uuid-1', name: 'Ivabradine', dose: '7.5 mg');
    TodayPlanData build({
      TodayPlanLocalState local = const TodayPlanLocalState(),
      List<QuickLogEntry> entries = const [],
    }) =>
        buildTodayPlan(
          medications: const [med],
          reminders: const [],
          habits: const [],
          localState: local,
          entries: entries,
          medicationCategoryId: 8,
          now: _now,
        );

    test('default slot is Daily, status pending without any signal', () {
      final item = build().items.single;
      expect(item.slot, 'Daily');
      expect(item.timeDisplay, 'Daily');
      expect(item.status, DoseStatus.pending);
      expect(item.id, 'med_uuid-1_Daily');
    });

    test('a today "Took …" entry in the Medication category marks taken',
        () {
      final data = build(entries: [
        entry(10, 8, 'Took Ivabradine 7.5 mg', _now),
      ]);
      expect(data.items.single.status, DoseStatus.taken);
      expect(data.items.single.isCompleted, isTrue);
      expect(data.summaryText, 'Everything planned for today is complete');
    });

    test('a "[Corrected to Skipped]" entry never marks taken', () {
      final data = build(entries: [
        entry(10, 8, '[Corrected to Skipped] Took Ivabradine 7.5 mg', _now),
      ]);
      expect(data.items.single.status, DoseStatus.pending);
    });

    test('yesterday\'s "Took …" entry does not leak into today', () {
      final data = build(entries: [
        entry(10, 8, 'Took Ivabradine 7.5 mg',
            _now.subtract(const Duration(days: 1))),
      ]);
      expect(data.items.single.status, DoseStatus.pending);
    });

    test('local SKIPPED wins over a stale "Took …" entry', () {
      final data = build(
        local: const TodayPlanLocalState(medActions: {
          'uuid-1|Daily': DoseStatus.skipped,
        }),
        entries: [entry(10, 8, 'Took Ivabradine 7.5 mg', _now)],
      );
      expect(data.items.single.status, DoseStatus.skipped);
      expect(data.items.single.isCompleted, isFalse);
    });

    test('local PENDING (undo) wins over a "Took …" entry — native '
        'keeps the entry on undo too', () {
      final data = build(
        local: const TodayPlanLocalState(medActions: {
          'uuid-1|Daily': DoseStatus.pending,
        }),
        entries: [entry(10, 8, 'Took Ivabradine 7.5 mg', _now)],
      );
      expect(data.items.single.status, DoseStatus.pending);
    });

    test('blob rows: deleted + not-present meds are excluded', () {
      final deleted = SummaryMedication.fromBlobRow({
        'id': 'u1',
        'name': 'Gone',
        'dose': '5 mg',
        'isPresent': true,
        'isDeleted': true,
        'updatedAt': '1760000000000', // int8 as string — tolerated
      });
      final archived = SummaryMedication.fromBlobRow({
        'id': 'u2',
        'name': 'Old',
        'dose': '5 mg',
        'isPresent': false,
        'isDeleted': false,
      });
      final active = SummaryMedication.fromBlobRow({
        'id': 'u3',
        'name': 'Ivabradine',
        'dose': '7.5 mg',
        'isPresent': true,
        'isDeleted': false,
        'updatedAt': '1760000000000',
      });
      expect(deleted, isNull);
      expect(archived, isNull);
      expect(active?.name, 'Ivabradine');
      expect(active?.key, 'u3');
    });

    test('blob rows: string/num flag variants exclude archived + '
        'deleted meds (real payload shapes)', () {
      SummaryMedication? row(Map<String, dynamic> r) =>
          SummaryMedication.fromBlobRow({
            'id': 'u9',
            'name': 'Variant',
            'dose': '5 mg',
            ...r,
          });
      // Archived representations — every one must be excluded.
      expect(row({'isPresent': 'false'}), isNull);
      expect(row({'isPresent': 'False'}), isNull);
      expect(row({'isPresent': 0}), isNull);
      expect(row({'isPresent': '0'}), isNull);
      expect(row({'isArchived': true}), isNull);
      expect(row({'isArchived': 'true'}), isNull);
      expect(row({'isArchived': 1, 'isPresent': true}), isNull);
      // Deleted representations.
      expect(row({'isDeleted': 'true', 'isPresent': true}), isNull);
      expect(row({'isDeleted': 1, 'isPresent': true}), isNull);
      // Active representations — every one must survive.
      expect(row({'isPresent': 'true'})?.name, 'Variant');
      expect(row({'isPresent': 1})?.name, 'Variant');
      expect(row({'isPresent': '1'})?.name, 'Variant');
      expect(row({'isPresent': true, 'isArchived': 'false'})?.name,
          'Variant');
      expect(row({'isPresent': true, 'isDeleted': 'false'})?.name,
          'Variant');
    });

    test('blob rows: with no usable isPresent flag, a real end date '
        'marks the med ended; the "Present" sentinel stays active',
        () {
      SummaryMedication? row(Map<String, dynamic> r) =>
          SummaryMedication.fromBlobRow({
            'id': 'u10',
            'name': 'Ended',
            'dose': '5 mg',
            ...r,
          });
      expect(row({'endDate': '2026-08-01'}), isNull);
      expect(row({'endedDate': '2026-08-01'}), isNull);
      expect(row({'endDate': 'Present'})?.name, 'Ended');
      expect(row({'endDate': ''})?.name, 'Ended');
      expect(row({})?.name, 'Ended');
    });

    test('plan: archived meds in the real payload shape produce no '
        'rows and count nowhere; the active med remains', () {
      final rows = <Map<String, dynamic>>[
        {
          'id': 'a1',
          'name': 'Ivabradine',
          'dose': '7.5 mg',
          'isPresent': 'true', // string bool, real payload shape
          'isDeleted': 'false',
          'updatedAt': '1760000000000',
        },
        {
          'id': 'a2',
          'name': 'Sertraline', // stopped — archived via string flag
          'dose': '50 mg',
          'isPresent': 'false',
          'isDeleted': 'false',
        },
        {
          'id': 'a3',
          'name': 'Carvedilol', // stopped — archived via explicit stamp
          'dose': '3.125 mg',
          'isPresent': true,
          'isArchived': true,
        },
        {
          'id': 'a4',
          'name': 'Qulipta', // stopped — ended, no present flag
          'dose': '60 mg',
          'endDate': '2026-09-15',
        },
      ];
      // Mirrors TodaySummaryLoader._parseMeds exactly.
      final meds = rows
          .map(SummaryMedication.fromBlobRow)
          .whereType<SummaryMedication>()
          .toList();
      expect(meds.map((m) => m.name), ['Ivabradine']);
      final data = buildTodayPlan(
        medications: meds,
        reminders: const [],
        habits: const [],
        localState: const TodayPlanLocalState(),
        entries: const [],
        medicationCategoryId: 8,
        now: _now,
      );
      expect(data.items.single.title, 'Ivabradine');
      expect(data.items.single.kind, PlanItemKind.medication);
      expect(data.remainingCount, 1);
      expect(data.overdueCount, 0);
      expect(data.summaryText, '1 item remaining');
    });

    test('reminder blob rows tolerate string-encoded ints', () {
      final rem = SummaryReminder.fromBlobRow({
        'id': '42',
        'title': 'Salt pills',
        'fixedHour': '8',
        'fixedMinute': '30',
        'isEnabled': true,
      }, fallbackId: -1);
      expect(rem?.id, 42);
      expect(rem?.fixedHour, 8);
      expect(rem?.fixedMinute, 30);
    });
  });

  group('overdue rules — summary count vs per-row badge (native has both)',
      () {
    test('summary count: reminder uses hour only; badge uses minutes', () {
      final now = DateTime(2026, 10, 13, 9, 15);
      final data = buildTodayPlan(
        medications: const [],
        reminders: const [
          SummaryReminder(
              id: 1,
              title: 'A',
              fixedHour: 9,
              fixedMinute: 30,
              isEnabled: true),
        ],
        habits: const [],
        localState: const TodayPlanLocalState(),
        entries: const [],
        medicationCategoryId: null,
        now: now,
      );
      // 09:30 has not passed at 09:15, and fixedHour (9) is not <
      // currentHour (9): neither rule fires.
      expect(data.overdueCount, 0);
      expect(data.items.single.isOverdue(now), isFalse);
      // At 09:31 the badge fires (minute precision) while the
      // summary count still does not (hour rule) — native exactly.
      final later = DateTime(2026, 10, 13, 9, 31);
      expect(data.items.single.isOverdue(later), isTrue);
      final dataLater = buildTodayPlan(
        medications: const [],
        reminders: const [
          SummaryReminder(
              id: 1,
              title: 'A',
              fixedHour: 9,
              fixedMinute: 30,
              isEnabled: true),
        ],
        habits: const [],
        localState: const TodayPlanLocalState(),
        entries: const [],
        medicationCategoryId: null,
        now: later,
      );
      expect(dataLater.overdueCount, 0);
    });

    test('med Daily badge fires at 18:00; summary count never counts '
        'a Daily slot', () {
      TodayPlanData at(DateTime now) => buildTodayPlan(
            medications: const [
              SummaryMedication(key: 'k', name: 'M', dose: '1'),
            ],
            reminders: const [],
            habits: const [],
            localState: const TodayPlanLocalState(),
            entries: const [],
            medicationCategoryId: null,
            now: now,
          );
      final evening = DateTime(2026, 10, 13, 18, 0);
      expect(at(evening).items.single.isOverdue(evening), isTrue);
      expect(at(evening).overdueCount, 0);
      final before = DateTime(2026, 10, 13, 17, 59);
      expect(at(before).items.single.isOverdue(before), isFalse);
    });

    test('habit badge fires after target_time; "Anytime" never; '
        'summary count never counts habits', () {
      final now = DateTime(2026, 10, 13, 9, 0);
      final data = buildTodayPlan(
        medications: const [],
        reminders: const [],
        habits: [
          habit('h1', 'Timed', target: '08:30'),
          habit('h2', 'Any', target: 'Anytime'),
        ],
        localState: const TodayPlanLocalState(),
        entries: const [],
        medicationCategoryId: null,
        now: now,
      );
      final timed = data.items.firstWhere((i) => i.title == 'Timed');
      final any = data.items.firstWhere((i) => i.title == 'Any');
      expect(timed.isOverdue(now), isTrue);
      expect(any.isOverdue(now), isFalse);
      expect(data.overdueCount, 0);
    });

    test('skipped + completed items are never overdue', () {
      final now = DateTime(2026, 10, 13, 21, 0);
      final data = buildTodayPlan(
        medications: const [
          SummaryMedication(key: 'k', name: 'M', dose: '1'),
        ],
        reminders: const [],
        habits: const [],
        localState: const TodayPlanLocalState(medActions: {
          'k|Daily': DoseStatus.skipped,
        }),
        entries: const [],
        medicationCategoryId: null,
        now: now,
      );
      expect(data.items.single.isOverdue(now), isFalse);
      expect(data.overdueCount, 0);
    });
  });

  group('buildTrendComparisons — HealthComparisonRepository port', () {
    Map<String, int> sleepMap(Map<String, int> extra) => {
          _today: 420,
          daysAgo(1): 400,
          daysAgo(2): 410,
          daysAgo(3): 390,
          daysAgo(4): 405,
          ...extra,
        };

    test('sleep: longer than average produces native text + periods', () {
      final items = buildTrendComparisons(
        sleepMinutesByDate: sleepMap({}),
        restingHrByDate: const {},
        symptomLogCount: 0,
        todayStr: _today,
      );
      expect(items, hasLength(1));
      final sleep = items.single;
      expect(sleep.metricName, 'Sleep Duration');
      // avg prev = 401.25 → diff = 18 (truncated) → longer.
      expect(sleep.differenceText,
          'Sleep was 18 minutes longer than your seven-day average.');
      expect(sleep.currentPeriod, '7h 0m today');
      expect(sleep.comparisonPeriod, '7-day avg (6h 41m)');
      expect(sleep.dataSource, 'Health Connect');
    });

    test('sleep: diff boundaries −16 shorter / −15 close / +15 close', () {
      List<TrendComparison> withToday(int todayMins) =>
          buildTrendComparisons(
            sleepMinutesByDate: {
              _today: todayMins,
              daysAgo(1): 400,
              daysAgo(2): 400,
              daysAgo(3): 400,
            },
            restingHrByDate: const {},
            symptomLogCount: 0,
            todayStr: _today,
          );
      expect(withToday(384).single.differenceText,
          'Sleep was 16 minutes shorter than your seven-day average.');
      expect(withToday(385).single.differenceText,
          'Sleep was Close to your seven-day average.');
      expect(withToday(415).single.differenceText,
          'Sleep was Close to your seven-day average.');
      expect(withToday(416).single.differenceText,
          'Sleep was 16 minutes longer than your seven-day average.');
    });

    test('sleep: fewer than 3 previous days → no item; missing today '
        '→ no item; zero days never count as data', () {
      final twoPrev = buildTrendComparisons(
        sleepMinutesByDate: {_today: 400, daysAgo(1): 400, daysAgo(2): 400},
        restingHrByDate: const {},
        symptomLogCount: 0,
        todayStr: _today,
      );
      expect(twoPrev, isEmpty);
      final zeroToday = buildTrendComparisons(
        sleepMinutesByDate: {
          _today: 0, // failed read — excluded by the loader AND here
          daysAgo(1): 400,
          daysAgo(2): 400,
          daysAgo(3): 400,
        },
        restingHrByDate: const {},
        symptomLogCount: 0,
        todayStr: _today,
      );
      expect(zeroToday, isEmpty);
      final zeroPrev = buildTrendComparisons(
        sleepMinutesByDate: {
          _today: 400,
          daysAgo(1): 0,
          daysAgo(2): 0,
          daysAgo(3): 400,
          daysAgo(4): 400,
        },
        restingHrByDate: const {},
        symptomLogCount: 0,
        todayStr: _today,
      );
      expect(zeroPrev, isEmpty); // only 2 usable previous days
    });

    test('resting HR: higher / lower / close with truncated average', () {
      List<TrendComparison> withRhr(int todayBpm, List<int> prev) =>
          buildTrendComparisons(
            sleepMinutesByDate: const {},
            restingHrByDate: {
              _today: todayBpm,
              for (var i = 0; i < prev.length; i++) daysAgo(i + 1): prev[i],
            },
            symptomLogCount: 0,
            todayStr: _today,
          );
      // prev avg = 58.75 → truncated 58.
      expect(withRhr(64, [58, 59, 58, 60]).single.differenceText,
          'Resting heart rate is 6 bpm higher than your seven-day average.');
      expect(withRhr(52, [58, 59, 58, 60]).single.differenceText,
          'Resting heart rate is 6 bpm lower than your seven-day average.');
      expect(withRhr(63, [58, 59, 58, 60]).single.differenceText,
          'Resting heart rate is close to your recent average.');
      expect(withRhr(64, [58, 59, 58, 60]).single.currentPeriod,
          '64 bpm today');
      expect(withRhr(64, [58, 59, 58, 60]).single.comparisonPeriod,
          '7-day avg (58 bpm)');
    });

    test('symptom item: text + pluralization; zero → absent', () {
      final one = buildTrendComparisons(
        sleepMinutesByDate: const {},
        restingHrByDate: const {},
        symptomLogCount: 1,
        todayStr: _today,
      );
      expect(one.single.metricName, 'Symptom Logs');
      expect(one.single.differenceText,
          'Symptoms were logged 1 time this week.');
      expect(one.single.currentPeriod, '1 logged in past 7 days');
      expect(one.single.dataSource, 'Personal Log Entries');
      final three = buildTrendComparisons(
        sleepMinutesByDate: const {},
        restingHrByDate: const {},
        symptomLogCount: 3,
        todayStr: _today,
      );
      expect(three.single.differenceText,
          'Symptoms were logged 3 times this week.');
      expect(
          buildTrendComparisons(
            sleepMinutesByDate: const {},
            restingHrByDate: const {},
            symptomLogCount: 0,
            todayStr: _today,
          ),
          isEmpty);
    });

    test('order is Sleep, Resting HR, Symptoms (native order)', () {
      final items = buildTrendComparisons(
        sleepMinutesByDate: sleepMap({}),
        restingHrByDate: {
          _today: 62,
          daysAgo(1): 58,
          daysAgo(2): 59,
          daysAgo(3): 58,
          daysAgo(4): 60,
        },
        symptomLogCount: 2,
        todayStr: _today,
      );
      expect(items.map((i) => i.metricName).toList(),
          ['Sleep Duration', 'Resting Heart Rate', 'Symptom Logs']);
    });
  });

  group('countSymptomLogs — window + matching (native port)', () {
    test('category match, legacy fallback, and window edges', () {
      final now = DateTime(2026, 10, 13, 12, 0);
      final windowStart = DateTime(2026, 10, 6); // today − 7d midnight
      final entries = [
        entry(1, 1, 'Migraine', now), // category match
        entry(2, 0, 'bad Headache today', now), // legacy fallback
        entry(3, 0, 'Lunch', now), // categoryId 0, no keyword → no
        entry(4, 2, 'Headache', now), // keyword, wrong category → no
        entry(5, 1, 'At window start', windowStart), // inclusive → yes
        entry(6, 1, 'Before window',
            windowStart.subtract(const Duration(milliseconds: 1))),
        entry(7, 1, 'Future', now.add(const Duration(hours: 1))),
      ];
      expect(
        countSymptomLogs(
            entries: entries, symptomsCategoryId: 1, now: now),
        3,
      );
    });
  });

  group('TodayPlanStore — date + account binding', () {
    test('reminder completion + med action round-trip', () async {
      final mem = MemoryStore();
      final store = planStoreWith(mem);
      await store.setReminderCompleted(
          email: 'a@x.com', todayStr: _today, reminderId: 7, completed: true);
      await store.setMedAction(
          email: 'a@x.com',
          todayStr: _today,
          medKey: 'k',
          slot: 'Daily',
          status: DoseStatus.taken);
      final loaded = await store.load(email: 'a@x.com', todayStr: _today);
      expect(loaded.completedReminderIds, {7});
      expect(loaded.medActions['k|Daily'], DoseStatus.taken);
    });

    test('another day → empty (yesterday never bleeds into today)',
        () async {
      final mem = MemoryStore();
      final store = planStoreWith(mem);
      await store.setReminderCompleted(
          email: 'a@x.com',
          todayStr: daysAgo(1),
          reminderId: 7,
          completed: true);
      final loaded = await store.load(email: 'a@x.com', todayStr: _today);
      expect(loaded.completedReminderIds, isEmpty);
    });

    test('another account → empty and the blob is wiped', () async {
      final mem = MemoryStore();
      final store = planStoreWith(mem);
      await store.setReminderCompleted(
          email: 'a@x.com', todayStr: _today, reminderId: 7, completed: true);
      final loaded = await store.load(email: 'b@x.com', todayStr: _today);
      expect(loaded.completedReminderIds, isEmpty);
      expect(mem.map.containsKey(TodayPlanStore.storageKey), isFalse);
    });
  });

  group('TodaySummaryCache — account + date binding', () {
    TodayPlanData samplePlan() => buildTodayPlan(
          medications: const [
            SummaryMedication(key: 'k', name: 'M', dose: '1'),
          ],
          reminders: const [],
          habits: const [],
          localState: const TodayPlanLocalState(),
          entries: const [],
          medicationCategoryId: null,
          now: _now,
        );

    test('save → load round-trips plan + trends', () async {
      final mem = MemoryStore();
      final cache = cacheWith(mem);
      final trends = buildTrendComparisons(
        sleepMinutesByDate: const {},
        restingHrByDate: const {},
        symptomLogCount: 2,
        todayStr: _today,
      );
      await cache.save(
          email: 'a@x.com',
          todayStr: _today,
          plan: samplePlan(),
          trends: trends);
      final loaded = await cache.load(email: 'a@x.com', todayStr: _today);
      expect(loaded?.plan.summaryText, '1 item remaining');
      expect(loaded?.trends.single.metricName, 'Symptom Logs');
    });

    test('different account never sees the cached summary', () async {
      final mem = MemoryStore();
      final cache = cacheWith(mem);
      await cache.save(
          email: 'a@x.com',
          todayStr: _today,
          plan: samplePlan(),
          trends: const []);
      expect(await cache.load(email: 'b@x.com', todayStr: _today), isNull);
      expect(mem.map.containsKey(TodaySummaryCache.storageKey), isFalse);
    });

    test('different day → null (no stale yesterday)', () async {
      final mem = MemoryStore();
      final cache = cacheWith(mem);
      await cache.save(
          email: 'a@x.com',
          todayStr: daysAgo(1),
          plan: samplePlan(),
          trends: const []);
      expect(await cache.load(email: 'a@x.com', todayStr: _today), isNull);
    });
  });

  group('TodaySummaryLoader — real-shaped server payloads', () {
    /// A sync pull exactly as the server sends it: int8 fields as
    /// strings inside `entries`, blobs as JSON strings in `profile`.
    Map<String, dynamic> pullBody({List<dynamic>? entries}) {
      final meds = jsonEncode([
        {
          'id': 'med-uuid-1',
          'name': 'Ivabradine',
          'dose': '7.5 mg',
          'frequency': 'Daily',
          'startDate': '2026-01-01',
          'endDate': 'Present',
          'isPresent': true,
          'isDeleted': false,
          'updatedAt': '1760000000000',
        },
      ]);
      final reminders = jsonEncode([
        {
          'id': 5,
          'title': 'Salt pills',
          'type': 'FIXED',
          'fixedHour': 23,
          'fixedMinute': 45,
          'intervalHours': 2,
          'intervalMinutes': 0,
          'startHour': 8,
          'startMinute': 0,
          'endHour': 21,
          'endMinute': 0,
          'isEnabled': true,
          'daysOfWeekConfig': '',
        },
      ]);
      return {
        'entries': entries ??
            [
              {
                'id': '900',
                'categoryId': '1',
                'body': 'Migraine',
                'chips': '[]',
                'manualText': '',
                'timestamp': '$_pastMs',
                'updatedAt': '$_pastMs',
              },
            ],
        'categories': [
          {
            'id': 1,
            'name': 'Symptoms',
            'icon': 'Favorite',
            'colorHex': '#FF6B6B',
            'isDefault': true,
            'sortOrder': 0,
          },
          {
            'id': 8,
            'name': 'Medication',
            'icon': 'Medication',
            'colorHex': '#4ECDC4',
            'isDefault': true,
            'sortOrder': 3,
          },
        ],
        'profile': {'medications': meds, 'reminders': reminders},
        'isUnlimited': true,
        'isAdmin': false,
      };
    }

    TodaySummaryLoader loaderFor(
      http.Client client, {
      HealthConnectService? hc,
      MemoryStore? planMem,
      MemoryStore? cacheMem,
      String email = 'a@x.com',
    }) {
      final session = FakeSessionStore()
        ..token = 'tok'
        ..email = email;
      return TodaySummaryLoader(
        backend: TabsBackend(client: client, sessionStore: session),
        hc: hc ?? FakeSummaryHc(),
        planStore: planStoreWith(planMem ?? MemoryStore()),
        cache: cacheWith(cacheMem ?? MemoryStore()),
        sessionStore: session,
      );
    }

    MockClient healthyClient({List<String>? habitLogs}) {
      return MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(jsonEncode(pullBody()), 200);
        }
        if (request.url.path == '/api/habits') {
          return http.Response(
            jsonEncode({
              'habits': [
                {
                  'id': 'h1',
                  'title': 'Stretch',
                  'target_time': '07:15',
                  'created_at': '2026-01-01',
                  'logs': habitLogs ?? [_today],
                },
              ],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });
    }

    test('load: plan + subtitle + trends from one real-shaped pull',
        () async {
      final hc = FakeSummaryHc(sleepByDate: {
        _today: 420,
        daysAgo(1): 400,
        daysAgo(2): 410,
        daysAgo(3): 390,
        daysAgo(4): 405,
      });
      final loader = loaderFor(healthyClient(), hc: hc);
      final data = await loader.load(now: _now);
      expect(data.pullSucceeded, isTrue);
      // Med (pending) + reminder (pending) remain; habit is done.
      expect(data.plan.summaryText, '2 items remaining');
      expect(data.plan.items.map((i) => i.title).toList(),
          containsAll(['Ivabradine', 'Salt pills', 'Stretch']));
      final habitItem =
          data.plan.items.firstWhere((i) => i.title == 'Stretch');
      expect(habitItem.isCompleted, isTrue);
      expect(habitItem.timeDisplay, '07:15');
      // Trends: sleep comparison + 1 symptom log (string-ts entry).
      expect(data.trends.map((t) => t.metricName).toList(),
          ['Sleep Duration', 'Symptom Logs']);
    });

    test('load: pull failure falls back to the account cache', () async {
      final cacheMem = MemoryStore();
      final cache = cacheWith(cacheMem);
      final plan = buildTodayPlan(
        medications: const [
          SummaryMedication(key: 'k', name: 'CachedMed', dose: '1'),
        ],
        reminders: const [],
        habits: const [],
        localState: const TodayPlanLocalState(),
        entries: const [],
        medicationCategoryId: null,
        now: _now,
      );
      await cache.save(
          email: 'a@x.com', todayStr: _today, plan: plan, trends: const []);
      final failing = MockClient(
          (_) async => http.Response('{"error":"down"}', 500));
      final session = FakeSessionStore()
        ..token = 'tok'
        ..email = 'a@x.com';
      final loader = TodaySummaryLoader(
        backend: TabsBackend(client: failing, sessionStore: session),
        hc: FakeSummaryHc(),
        planStore: planStoreWith(MemoryStore()),
        cache: cache,
        sessionStore: session,
      );
      final data = await loader.load(now: _now);
      expect(data.fromCache, isTrue);
      expect(data.plan.summaryText, '1 item remaining');
      expect(data.plan.items.single.title, 'CachedMed');
    });

    test('load: pull failure with no cache → honest empty, no throw',
        () async {
      final failing = MockClient((_) async => throw http.ClientException('offline'));
      final loader = loaderFor(failing);
      final data = await loader.load(now: _now);
      expect(data.plan.summaryText, 'No plans recorded today');
      expect(data.trends, isEmpty);
    });

    test('habit toggle posts the native LogHabitRequest shape', () async {
      Map<String, dynamic>? posted;
      final client = MockClient((request) async {
        if (request.url.path == '/api/habits/log') {
          posted = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response('{"success":true}', 200);
        }
        return http.Response('{}', 404);
      });
      final loader = loaderFor(client);
      final item = TodayPlanItem(
        kind: PlanItemKind.habit,
        id: 'habit_h1',
        title: 'Stretch',
        timeDisplay: 'Anytime',
        isCompleted: false,
        habitId: 'h1',
      );
      final ok = await loader.setHabitCompleted(item, true, now: _now);
      expect(ok, isTrue);
      expect(posted, {
        'habit_id': 'h1',
        'completed_date': _today,
        'is_completed': true,
      });
    });

    test('med Take posts the native "Took …" entry and the next load '
        'shows Taken', () async {
      final postedEntries = <Map<String, dynamic>>[];
      var pullCount = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          pullCount++;
          // After the take, the server holds the new entry too.
          final extra = postedEntries
              .map((e) => {
                    'id': '${e['id']}',
                    'categoryId': '${e['categoryId']}',
                    'body': e['body'],
                    'chips': e['chips'],
                    'manualText': e['manualText'],
                    'timestamp': '${e['timestamp']}',
                    'updatedAt': '${e['timestamp']}',
                  })
              .toList();
          return http.Response(jsonEncode(pullBody(entries: extra)), 200);
        }
        if (request.url.path == '/api/sync/entries') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          for (final e in (body['entries'] as List)) {
            postedEntries.add(e as Map<String, dynamic>);
          }
          return http.Response('{"success":true}', 200);
        }
        if (request.url.path == '/api/habits') {
          return http.Response('{"habits":[]}', 200);
        }
        return http.Response('{}', 404);
      });
      final planMem = MemoryStore();
      final loader = loaderFor(client, planMem: planMem);
      final before = await loader.load(now: _now);
      final medItem =
          before.plan.items.firstWhere((i) => i.title == 'Ivabradine');
      expect(medItem.status, DoseStatus.pending);
      await loader.setMedicationAction(medItem, DoseStatus.taken,
          now: _now);
      expect(postedEntries, hasLength(1));
      expect(postedEntries.single['body'], 'Took Ivabradine 7.5 mg');
      expect(postedEntries.single['categoryId'], 8);
      expect(pullCount, greaterThan(0));
      final after = await loader.load(now: _now);
      final afterMed =
          after.plan.items.firstWhere((i) => i.title == 'Ivabradine');
      expect(afterMed.status, DoseStatus.taken);
    });

    test('med Skip after a Take posts the "[Corrected to Skipped]" '
        'rewrite of the same entry', () async {
      final posted = <Map<String, dynamic>>[];
      final client = MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
            jsonEncode(pullBody(entries: [
              {
                'id': '55',
                'categoryId': '8',
                'body': 'Took Ivabradine 7.5 mg',
                'chips': '[]',
                'manualText': '',
                'timestamp': '$_pastMs',
                'updatedAt': '$_pastMs',
              },
            ])),
            200,
          );
        }
        if (request.url.path == '/api/sync/entries') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          for (final e in (body['entries'] as List)) {
            posted.add(e as Map<String, dynamic>);
          }
          return http.Response('{"success":true}', 200);
        }
        if (request.url.path == '/api/habits') {
          return http.Response('{"habits":[]}', 200);
        }
        return http.Response('{}', 404);
      });
      final loader = loaderFor(client);
      final data = await loader.load(now: _now);
      final medItem =
          data.plan.items.firstWhere((i) => i.title == 'Ivabradine');
      expect(medItem.status, DoseStatus.taken); // from the entry
      await loader.setMedicationAction(medItem, DoseStatus.skipped,
          now: _now);
      expect(posted, hasLength(1));
      expect(posted.single['id'], 55);
      expect(posted.single['body'],
          '[Corrected to Skipped] Took Ivabradine 7.5 mg');
      final after = await loader.load(now: _now);
      expect(
          after.plan.items.firstWhere((i) => i.title == 'Ivabradine').status,
          DoseStatus.skipped);
    });
  });

  group('TodaySummaryCard (widget)', () {
    TabsBackend backendFor(http.Client client, FakeSessionStore session) =>
        TabsBackend(client: client, sessionStore: session);

    Future<void> pumpCard(
      WidgetTester tester, {
      required http.Client client,
      HealthConnectService? hc,
      MemoryStore? planMem,
      MemoryStore? cacheMem,
      String email = 'a@x.com',
    }) async {
      final session = FakeSessionStore()
        ..token = 'tok'
        ..email = email;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TodaySummaryCard(
                backend: backendFor(client, session),
                healthConnectService: hc ?? FakeSummaryHc(),
                planStore: planStoreWith(planMem ?? MemoryStore()),
                summaryCache: cacheWith(cacheMem ?? MemoryStore()),
                sessionStore: session,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    MockClient dataClient({bool habitDone = true}) {
      final meds = jsonEncode([
        {
          'id': 'med-uuid-1',
          'name': 'Ivabradine',
          'dose': '7.5 mg',
          'frequency': 'Daily',
          'startDate': '2026-01-01',
          'endDate': 'Present',
          'isPresent': true,
          'isDeleted': false,
          'updatedAt': '1760000000000',
        },
      ]);
      final reminders = jsonEncode([
        {
          'id': 5,
          'title': 'Salt pills',
          'type': 'FIXED',
          'fixedHour': 23,
          'fixedMinute': 45,
          'isEnabled': true,
          'daysOfWeekConfig': '',
        },
      ]);
      return MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
            jsonEncode({
              'entries': <dynamic>[],
              'categories': [
                {'id': 1, 'name': 'Symptoms'},
                {'id': 8, 'name': 'Medication'},
              ],
              'profile': {'medications': meds, 'reminders': reminders},
            }),
            200,
          );
        }
        if (request.url.path == '/api/habits') {
          return http.Response(
            jsonEncode({
              'habits': [
                {
                  'id': 'h1',
                  'title': 'Stretch',
                  'target_time': '07:15',
                  'logs': habitDone ? [_today] : <String>[],
                },
              ],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });
    }

    testWidgets('collapsed by default with real data; subtitle counts '
        'remaining; expand/collapse toggles repeatedly', (tester) async {
      await pumpCard(tester, client: dataClient());
      expect(find.text('Today Summary'), findsOneWidget);
      expect(find.text('2 items remaining'), findsOneWidget);
      expect(find.text("Today's Plan"), findsNothing);
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);

      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('Today Summary'));
        await tester.pumpAndSettle();
        expect(find.text("Today's Plan"), findsOneWidget);
        expect(find.text('Ivabradine'), findsOneWidget);
        expect(find.text('Salt pills'), findsOneWidget);
        expect(find.text('Stretch'), findsOneWidget);
        await tester.tap(find.text('Today Summary'));
        await tester.pumpAndSettle();
        expect(find.text("Today's Plan"), findsNothing);
      }
    });

    testWidgets('offline with a primed cache shows last-known values, '
        'not an error or a blank section', (tester) async {
      final cacheMem = MemoryStore();
      final cache = cacheWith(cacheMem);
      final plan = buildTodayPlan(
        medications: const [
          SummaryMedication(key: 'k', name: 'CachedMed', dose: '1'),
        ],
        reminders: const [],
        habits: const [],
        localState: const TodayPlanLocalState(),
        entries: const [],
        medicationCategoryId: null,
        now: _now,
      );
      await cache.save(
          email: 'a@x.com', todayStr: _today, plan: plan, trends: const []);
      final failing =
          MockClient((_) async => http.Response('{"error":"x"}', 500));
      final session = FakeSessionStore()
        ..token = 'tok'
        ..email = 'a@x.com';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TodaySummaryCard(
              backend: backendFor(failing, session),
              healthConnectService: FakeSummaryHc(),
              planStore: planStoreWith(MemoryStore()),
              summaryCache: cache,
              sessionStore: session,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 item remaining'), findsOneWidget);
      await tester.tap(find.text('Today Summary'));
      await tester.pumpAndSettle();
      expect(find.text('CachedMed'), findsOneWidget);
    });

    testWidgets('a different account never sees the previous '
        'account\'s cached summary', (tester) async {
      final cacheMem = MemoryStore();
      final cache = cacheWith(cacheMem);
      final plan = buildTodayPlan(
        medications: const [
          SummaryMedication(key: 'k', name: 'OtherAccountMed', dose: '1'),
        ],
        reminders: const [],
        habits: const [],
        localState: const TodayPlanLocalState(),
        entries: const [],
        medicationCategoryId: null,
        now: _now,
      );
      await cache.save(
          email: 'a@x.com', todayStr: _today, plan: plan, trends: const []);
      final failing =
          MockClient((_) async => http.Response('{"error":"x"}', 500));
      // pumpCard builds its own cache instance over the same store,
      // so the disk blob primed above is what the card can read —
      // owned by a@x.com, while the session is b@x.com.
      await pumpCard(tester,
          client: failing, cacheMem: cacheMem, email: 'b@x.com');
      expect(find.text('OtherAccountMed'), findsNothing);
      expect(find.text('1 item remaining'), findsNothing);
    });

    testWidgets('HC disconnected: symptom trend still renders, '
        'biometric trends honestly absent', (tester) async {
      final client = MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
            jsonEncode({
              'entries': [
                {
                  'id': '1',
                  'categoryId': '1',
                  'body': 'Migraine',
                  'chips': '[]',
                  'manualText': '',
                  'timestamp': '$_pastMs',
                  'updatedAt': '$_pastMs',
                },
              ],
              'categories': [
                {'id': 1, 'name': 'Symptoms'},
                {'id': 8, 'name': 'Medication'},
              ],
              'profile': {'medications': '[]', 'reminders': '[]'},
            }),
            200,
          );
        }
        if (request.url.path == '/api/habits') {
          return http.Response('{"habits":[]}', 200);
        }
        return http.Response('{}', 404);
      });
      await pumpCard(tester, client: client, hc: FakeSummaryHc());
      await tester.tap(find.text('Today Summary'));
      await tester.pumpAndSettle();
      expect(find.text('Symptom Logs'), findsOneWidget);
      expect(find.text('Symptoms were logged 1 time this week.'),
          findsOneWidget);
      expect(find.text('Sleep Duration'), findsNothing);
      expect(find.text('Not enough data yet'), findsNothing);
    });

    testWidgets('habit toggle tap posts the log and the row dusts '
        'away (founder check-off rule supersedes the R35 '
        'completed-row display)', (tester) async {
      var habitLogged = false;
      final client = MockClient((request) async {
        if (request.url.path == '/api/habits/log') {
          habitLogged = true;
          return http.Response('{"success":true}', 200);
        }
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
            jsonEncode({
              'entries': <dynamic>[],
              'categories': [
                {'id': 1, 'name': 'Symptoms'},
                {'id': 8, 'name': 'Medication'},
              ],
              'profile': {'medications': '[]', 'reminders': '[]'},
            }),
            200,
          );
        }
        if (request.url.path == '/api/habits') {
          return http.Response(
            jsonEncode({
              'habits': [
                {
                  'id': 'h1',
                  'title': 'Stretch',
                  'target_time': 'Anytime',
                  'logs': habitLogged ? [_today] : <String>[],
                },
              ],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });
      await pumpCard(tester, client: client);
      await tester.tap(find.text('Today Summary'));
      await tester.pumpAndSettle();
      expect(find.text('Stretch'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.radio_button_unchecked));
      await tester.pumpAndSettle();
      expect(habitLogged, isTrue);
      // Founder check-off rule: the checked item leaves the view
      // (dust dissolve), and since it was the LAST plan item the
      // section auto-collapses to its header after the dissolve.
      expect(find.text('Stretch'), findsNothing);
      expect(find.text("Today's Plan"), findsNothing);
      expect(find.text('Everything planned for today is complete'),
          findsOneWidget);
    });

    testWidgets('freshness: a remounted card reflects a dose logged '
        'elsewhere (Quick Log path)', (tester) async {
      var tookLogged = false;
      final client = MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
            jsonEncode({
              'entries': tookLogged
                  ? [
                      {
                        'id': '77',
                        'categoryId': '8',
                        'body': 'Took Ivabradine 7.5 mg',
                        'chips': '[]',
                        'manualText': '',
                        'timestamp': '$_pastMs',
                        'updatedAt': '$_pastMs',
                      },
                    ]
                  : <dynamic>[],
              'categories': [
                {'id': 1, 'name': 'Symptoms'},
                {'id': 8, 'name': 'Medication'},
              ],
              'profile': {
                'medications': jsonEncode([
                  {
                    'id': 'med-uuid-1',
                    'name': 'Ivabradine',
                    'dose': '7.5 mg',
                    'frequency': 'Daily',
                    'startDate': '2026-01-01',
                    'endDate': 'Present',
                    'isPresent': true,
                    'isDeleted': false,
                    'updatedAt': '1760000000000',
                  },
                ]),
                'reminders': '[]',
              },
            }),
            200,
          );
        }
        if (request.url.path == '/api/habits') {
          return http.Response('{"habits":[]}', 200);
        }
        return http.Response('{}', 404);
      });
      await pumpCard(tester, client: client);
      expect(find.text('1 item remaining'), findsOneWidget);
      // Simulate the user logging the dose on another screen, then
      // returning Home (Home remounts on tab switch in MainShell).
      // pumpWidget alone would REUSE the card's State (same widget
      // type in the same slot), so unmount fully first — the tab
      // switch in MainShell replaces the whole body the same way.
      tookLogged = true;
      await tester
          .pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
      await tester.pumpAndSettle();
      await pumpCard(tester, client: client);
      expect(find.text('Everything planned for today is complete'),
          findsOneWidget);
    });
  });

  group('Item 4 — check-off dust dissolve (founder)', () {
    Future<void> pumpMotionCard(
      WidgetTester tester, {
      required http.Client client,
      MemoryStore? planMem,
      bool disableAnimations = false,
    }) async {
      final session = FakeSessionStore()
        ..token = 'tok'
        ..email = 'a@x.com';
      final card = TodaySummaryCard(
        backend: TabsBackend(client: client, sessionStore: session),
        healthConnectService: FakeSummaryHc(),
        planStore: planStoreWith(planMem ?? MemoryStore()),
        summaryCache: cacheWith(MemoryStore()),
        sessionStore: session,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: disableAnimations
                  ? MediaQuery(
                      data: const MediaQueryData(disableAnimations: true),
                      child: card,
                    )
                  : card,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Today Summary'));
      await tester.pumpAndSettle();
    }

    // Reminder-only fixture: one reminder (id 5) whose completion
    // lives entirely in the plan store — no network writes — so the
    // persisted blob can be compared byte-for-byte across runs.
    MockClient reminderClient({bool second = false}) {
      final reminders = jsonEncode([
        {
          'id': 5,
          'title': 'Salt pills',
          'type': 'FIXED',
          'fixedHour': 23,
          'fixedMinute': 45,
          'isEnabled': true,
          'daysOfWeekConfig': '',
        },
        if (second)
          {
            'id': 6,
            'title': 'Water bottle',
            'type': 'FIXED',
            'fixedHour': 23,
            'fixedMinute': 50,
            'isEnabled': true,
            'daysOfWeekConfig': '',
          },
      ]);
      return MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
            jsonEncode({
              'entries': <dynamic>[],
              'categories': [
                {'id': 1, 'name': 'Symptoms'},
                {'id': 8, 'name': 'Medication'},
              ],
              'profile': {'medications': '[]', 'reminders': reminders},
            }),
            200,
          );
        }
        if (request.url.path == '/api/habits') {
          return http.Response(jsonEncode({'habits': []}), 200);
        }
        return http.Response('{}', 404);
      });
    }

    // Reaches the live dissolve. The snapshot chain
    // (RepaintBoundary.toImage + toByteData) completes on the real
    // event loop, which the fake-async test zone blocks — so bridge
    // through runAsync twice (capture, then sampling), pumping a
    // frame between, then step fake time until the particle
    // overlay is up. Stops at first sighting: still mid-flight.
    Future<void> pumpUntilDust(WidgetTester tester) async {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 700)));
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        if (find.byKey(const Key('dust-particles')).evaluate().isNotEmpty) {
          return;
        }
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('check-off dusts: particle overlay appears, the '
        'item leaves the view, remaining rows stay and the section '
        'stays expanded', (tester) async {
      await pumpMotionCard(tester,
          client: reminderClient(second: true));
      expect(find.text('Salt pills'), findsOneWidget);
      expect(find.text('Water bottle'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.radio_button_unchecked).first);
      await pumpUntilDust(tester);
      expect(find.byKey(const Key('dust-particles')), findsOneWidget);
      expect(find.text('Water bottle'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dust-particles')), findsNothing);
      expect(find.text('Salt pills'), findsNothing);
      expect(find.text('Water bottle'), findsOneWidget);
      // Not the last item — the section stays open (founder rule).
      expect(find.text("Today's Plan"), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('checking the LAST remaining item collapses the '
        'section after the dissolve finishes', (tester) async {
      await pumpMotionCard(tester, client: reminderClient());
      await tester.tap(find.byIcon(Icons.radio_button_unchecked));
      await pumpUntilDust(tester);
      // Mid-dissolve the section is still open — collapse waits for
      // the dust to finish.
      expect(find.byKey(const Key('dust-particles')), findsOneWidget);
      expect(find.text("Today's Plan"), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Salt pills'), findsNothing);
      expect(find.text("Today's Plan"), findsNothing);
      // Header (with its complete subtitle) remains.
      expect(find.text('Everything planned for today is complete'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('reduced motion: instant removal, no particles; '
        'the last-item collapse is immediate', (tester) async {
      await pumpMotionCard(tester,
          client: reminderClient(), disableAnimations: true);
      await tester.tap(find.byIcon(Icons.radio_button_unchecked));
      await tester.pump();
      expect(find.byKey(const Key('dust-particles')), findsNothing);
      expect(find.text('Salt pills'), findsNothing);
      expect(find.text("Today's Plan"), findsNothing);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('reduced motion: a non-final check-off stays '
        'expanded with the remaining rows present', (tester) async {
      await pumpMotionCard(tester,
          client: reminderClient(second: true),
          disableAnimations: true);
      await tester.tap(find.byIcon(Icons.radio_button_unchecked).first);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dust-particles')), findsNothing);
      expect(find.text('Salt pills'), findsNothing);
      expect(find.text('Water bottle'), findsOneWidget);
      expect(find.text("Today's Plan"), findsOneWidget);
    });

    testWidgets('persisted state after an ANIMATED check-off is '
        'identical to a non-animated one', (tester) async {
      final animatedMem = MemoryStore();
      await pumpMotionCard(tester,
          client: reminderClient(), planMem: animatedMem);
      await tester.tap(find.byIcon(Icons.radio_button_unchecked));
      await tester.pumpAndSettle();
      final animatedBlob = Map<String, String>.of(animatedMem.map);
      final animatedState = await planStoreWith(animatedMem).load(
        email: 'a@x.com',
        todayStr: _today,
      );
      expect(animatedState.completedReminderIds, contains(5));

      final reducedMem = MemoryStore();
      await pumpMotionCard(tester,
          client: reminderClient(),
          planMem: reducedMem,
          disableAnimations: true);
      await tester.tap(find.byIcon(Icons.radio_button_unchecked));
      await tester.pumpAndSettle();
      expect(reducedMem.map, animatedBlob);
    });

    testWidgets('a second check-off mid-dissolve finalizes the '
        'first instantly and loses neither write', (tester) async {
      final planMem = MemoryStore();
      await pumpMotionCard(tester,
          client: reminderClient(second: true), planMem: planMem);
      await tester.tap(find.byIcon(Icons.radio_button_unchecked).first);
      await pumpUntilDust(tester);
      expect(find.byKey(const Key('dust-particles')), findsOneWidget);
      // Second row's toggle is live while the first still dusts.
      await tester.tap(find.byIcon(Icons.radio_button_unchecked));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Salt pills'), findsNothing);
      expect(find.text('Water bottle'), findsNothing);
      final blob = planMem.map.values.join('\n');
      expect(blob, contains('5'));
      expect(blob, contains('6'));
      final state = await planStoreWith(planMem).load(
        email: 'a@x.com',
        todayStr: _today,
      );
      expect(state.completedReminderIds, containsAll(<int>[5, 6]));
    });

    testWidgets('med Take dusts the dose row after posting the '
        'entry; Skip on another med does the same', (tester) async {
      final posted = <String>[];
      final client = MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
            jsonEncode({
              'entries': <dynamic>[],
              'categories': [
                {'id': 1, 'name': 'Symptoms'},
                {'id': 8, 'name': 'Medication'},
              ],
              'profile': {
                'medications': jsonEncode([
                  {
                    'id': 'med-uuid-1',
                    'name': 'Ivabradine',
                    'dose': '7.5 mg',
                    'isPresent': true,
                    'isDeleted': false,
                  },
                  {
                    'id': 'med-uuid-2',
                    'name': 'Pyridostigmine',
                    'dose': '60 mg',
                    'isPresent': true,
                    'isDeleted': false,
                  },
                ]),
                'reminders': '[]',
              },
            }),
            200,
          );
        }
        if (request.url.path == '/api/habits') {
          return http.Response(jsonEncode({'habits': []}), 200);
        }
        if (request.url.path == '/api/sync/entries') {
          posted.add(request.body);
          return http.Response('{"success":true}', 200);
        }
        return http.Response('{}', 404);
      });
      await pumpMotionCard(tester, client: client);
      expect(find.text('Ivabradine'), findsOneWidget);
      await tester.tap(find.byTooltip('Take Medication').first);
      await tester.pumpAndSettle();
      expect(posted, isNotEmpty);
      expect(find.text('Ivabradine'), findsNothing);
      expect(find.text('Pyridostigmine'), findsOneWidget);
      // Skip resolves the second dose the same way — and it was
      // the last remaining item, so the section collapses.
      await tester.tap(find.byTooltip('Skip Medication'));
      await tester.pumpAndSettle();
      expect(find.text('Pyridostigmine'), findsNothing);
      expect(find.text("Today's Plan"), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('Vera R35 re-review — account binding fixes', () {
    TodayPlanData veraPlan(String medName) => buildTodayPlan(
          medications: [
            SummaryMedication(key: 'k', name: medName, dose: '1'),
          ],
          reminders: const [],
          habits: const [],
          localState: const TodayPlanLocalState(),
          entries: const [],
          medicationCategoryId: null,
          now: _now,
        );

    List<TrendComparison> veraTrends() => buildTrendComparisons(
          sleepMinutesByDate: const {},
          restingHrByDate: const {},
          symptomLogCount: 2,
          todayStr: _today,
        );

    /// Points the REAL store singletons back at genuine secure
    /// storage after a test that faked them (the logout-hook tests
    /// below exercise the production singletons on purpose).
    void restoreSingletonStorage() {
      const storage = FlutterSecureStorage();
      TodaySummaryCache.instance.debugSetStore(
        read: (k) => storage.read(key: k),
        write: (k, v) => storage.write(key: k, value: v),
        delete: (k) => storage.delete(key: k),
      );
      TodaySummaryCache.instance.debugReset();
      TodayPlanStore.instance.debugSetStore(
        read: (k) => storage.read(key: k),
        write: (k, v) => storage.write(key: k, value: v),
        delete: (k) => storage.delete(key: k),
      );
    }

    // ── BLOCKING 1: null-email loads/writes vs an owned blob ──────

    test('cache: null-email load never serves a known account\'s '
        'blob (memory + disk paths) and never wipes it', () async {
      final mem = MemoryStore();
      final cache = cacheWith(mem);
      await cache.save(
          email: 'a@x.com',
          todayStr: _today,
          plan: veraPlan('CachedMed'),
          trends: veraTrends());
      // Memory path: the warmed instance itself must refuse.
      expect(await cache.load(email: null, todayStr: _today), isNull);
      // Disk path: a cold instance over the same disk.
      final cold = cacheWith(mem);
      expect(await cold.load(email: null, todayStr: _today), isNull);
      // No wipe and no memory poisoning: the owner's own load still
      // returns everything.
      expect(mem.map.containsKey(TodaySummaryCache.storageKey), isTrue);
      final own = await cold.load(email: 'a@x.com', todayStr: _today);
      expect(own?.plan.items.single.title, 'CachedMed');
      expect(own?.trends.single.metricName, 'Symptom Logs');
    });

    test('cache: null-email save cannot re-stamp or overwrite a '
        'known account\'s blob', () async {
      final mem = MemoryStore();
      final seeder = cacheWith(mem);
      await seeder.save(
          email: 'a@x.com',
          todayStr: _today,
          plan: veraPlan('CachedMed'),
          trends: veraTrends());
      // Owner known from MEMORY (same instance, null email now).
      await seeder.save(
          email: null,
          todayStr: _today,
          plan: veraPlan('OtherMed'),
          trends: const []);
      // Owner known only from the DISK stamp (cold instance).
      final cold = cacheWith(mem);
      await cold.save(
          email: null,
          todayStr: _today,
          plan: veraPlan('OtherMed'),
          trends: const []);
      final blob = jsonDecode(mem.map[TodaySummaryCache.storageKey]!)
          as Map<String, dynamic>;
      expect(blob['ownerEmail'], 'a@x.com');
      final own =
          await cacheWith(mem).load(email: 'a@x.com', todayStr: _today);
      expect(own?.plan.items.single.title, 'CachedMed');
    });

    test('plan store: null-email load returns empty and never wipes',
        () async {
      final mem = MemoryStore();
      final store = planStoreWith(mem);
      await store.setReminderCompleted(
          email: 'a@x.com', todayStr: _today, reminderId: 7, completed: true);
      await store.setMedAction(
          email: 'a@x.com',
          todayStr: _today,
          medKey: 'k',
          slot: 'Daily',
          status: DoseStatus.taken);
      final anon = await store.load(email: null, todayStr: _today);
      expect(anon.completedReminderIds, isEmpty);
      expect(anon.medActions, isEmpty);
      expect(mem.map.containsKey(TodayPlanStore.storageKey), isTrue);
      final own = await store.load(email: 'a@x.com', todayStr: _today);
      expect(own.completedReminderIds, {7});
      expect(own.medActions['k|Daily'], DoseStatus.taken);
    });

    test('plan store: null-email write cannot re-stamp or overwrite '
        'a known account\'s blob', () async {
      final mem = MemoryStore();
      final store = planStoreWith(mem);
      await store.setReminderCompleted(
          email: 'a@x.com', todayStr: _today, reminderId: 7, completed: true);
      await store.setReminderCompleted(
          email: null, todayStr: _today, reminderId: 99, completed: true);
      final blob = jsonDecode(mem.map[TodayPlanStore.storageKey]!)
          as Map<String, dynamic>;
      expect(blob['ownerEmail'], 'a@x.com');
      expect(blob['completedReminderIds'], [7]);
      final own = await store.load(email: 'a@x.com', todayStr: _today);
      expect(own.completedReminderIds, {7});
    });

    test('loader: offline fallback with an unreadable (null) session '
        'email shows an empty summary — no cached meds or trends',
        () async {
      final cacheMem = MemoryStore();
      final cache = cacheWith(cacheMem);
      await cache.save(
          email: 'a@x.com',
          todayStr: _today,
          plan: veraPlan('CachedMed'),
          trends: veraTrends());
      final failing =
          MockClient((_) async => http.Response('{"error":"down"}', 500));
      // Token present but the email read yields null — the exact
      // transient state Vera's BLOCKING 1 is about.
      final session = FakeSessionStore()..token = 'tok';
      final loader = TodaySummaryLoader(
        backend: TabsBackend(client: failing, sessionStore: session),
        hc: FakeSummaryHc(),
        planStore: planStoreWith(MemoryStore()),
        cache: cache,
        sessionStore: session,
      );
      final data = await loader.load(now: _now);
      expect(data.fromCache, isFalse);
      expect(data.plan.summaryText, 'No plans recorded today');
      expect(data.plan.items, isEmpty);
      expect(data.trends, isEmpty);
    });

    // ── HIGH 2: owner-mismatch enforcement + logout hooks ─────────

    test('clearIfOwnerMismatch: foreign owner wiped, same owner '
        'kept (summary cache, memory + cold-disk paths)', () async {
      final mem = MemoryStore();
      final cache = cacheWith(mem);
      await cache.save(
          email: 'a@x.com',
          todayStr: _today,
          plan: veraPlan('CachedMed'),
          trends: veraTrends());
      // Unreadable email enforces nothing.
      expect(await cache.clearIfOwnerMismatch(null), isFalse);
      expect(mem.map.containsKey(TodaySummaryCache.storageKey), isTrue);
      // Same owner: everything kept (a re-login must not destroy
      // the last-known summary the offline fallback depends on).
      expect(await cache.clearIfOwnerMismatch('a@x.com'), isFalse);
      expect(
          await cache.load(email: 'a@x.com', todayStr: _today), isNotNull);
      // Foreign owner: wiped.
      expect(await cache.clearIfOwnerMismatch('b@x.com'), isTrue);
      expect(mem.map.containsKey(TodaySummaryCache.storageKey), isFalse);
      expect(await cache.load(email: 'a@x.com', todayStr: _today), isNull);
      // Cold-memory path: the blob's disk stamp decides.
      final mem2 = MemoryStore();
      await cacheWith(mem2).save(
          email: 'a@x.com',
          todayStr: _today,
          plan: veraPlan('CachedMed'),
          trends: const []);
      final coldCache = cacheWith(mem2);
      expect(await coldCache.clearIfOwnerMismatch('b@x.com'), isTrue);
      expect(mem2.map.containsKey(TodaySummaryCache.storageKey), isFalse);
    });

    test('clearIfOwnerMismatch: foreign owner wiped, same owner '
        'kept (plan store)', () async {
      final mem = MemoryStore();
      final store = planStoreWith(mem);
      await store.setReminderCompleted(
          email: 'a@x.com', todayStr: _today, reminderId: 7, completed: true);
      expect(await store.clearIfOwnerMismatch(null), isFalse);
      expect(await store.clearIfOwnerMismatch('a@x.com'), isFalse);
      expect(
          (await store.load(email: 'a@x.com', todayStr: _today))
              .completedReminderIds,
          {7});
      expect(await store.clearIfOwnerMismatch('b@x.com'), isTrue);
      expect(mem.map.containsKey(TodayPlanStore.storageKey), isFalse);
    });

    test('logout wipe (AccountActions.clearDefaultCaches) empties '
        'both Today Summary stores', () async {
      final cacheMem = MemoryStore();
      final planMem = MemoryStore();
      TodaySummaryCache.instance.debugSetStore(
          read: cacheMem.read, write: cacheMem.write, delete: cacheMem.delete);
      TodayPlanStore.instance.debugSetStore(
          read: planMem.read, write: planMem.write, delete: planMem.delete);
      addTearDown(restoreSingletonStorage);
      await TodaySummaryCache.instance.save(
          email: 'a@x.com',
          todayStr: _today,
          plan: veraPlan('CachedMed'),
          trends: veraTrends());
      await TodayPlanStore.instance.setReminderCompleted(
          email: 'a@x.com', todayStr: _today, reminderId: 7, completed: true);
      await AccountActions.clearDefaultCaches();
      expect(cacheMem.map.containsKey(TodaySummaryCache.storageKey),
          isFalse);
      expect(planMem.map.containsKey(TodayPlanStore.storageKey), isFalse);
      expect(
          await TodaySummaryCache.instance
              .load(email: 'a@x.com', todayStr: _today),
          isNull);
      expect(
          (await TodayPlanStore.instance
                  .load(email: 'a@x.com', todayStr: _today))
              .completedReminderIds,
          isEmpty);
    });

    test('logout wipe is fault-isolated: a throwing plan-store '
        'delete does not block the summary cache clear', () async {
      final cacheMem = MemoryStore();
      final planMem = MemoryStore();
      TodaySummaryCache.instance.debugSetStore(
          read: cacheMem.read, write: cacheMem.write, delete: cacheMem.delete);
      TodayPlanStore.instance.debugSetStore(
        read: planMem.read,
        write: planMem.write,
        delete: (_) async => throw StateError('storage gone'),
      );
      addTearDown(restoreSingletonStorage);
      await TodaySummaryCache.instance.save(
          email: 'a@x.com',
          todayStr: _today,
          plan: veraPlan('CachedMed'),
          trends: veraTrends());
      await TodayPlanStore.instance.setReminderCompleted(
          email: 'a@x.com', todayStr: _today, reminderId: 7, completed: true);
      // Must complete without throwing, and the healthy store's
      // clear must still land.
      await AccountActions.clearDefaultCaches();
      expect(cacheMem.map.containsKey(TodaySummaryCache.storageKey),
          isFalse);
    });

    testWidgets('session expiry (AppFlow) empties both Today Summary '
        'stores; the previous account\'s summary never renders',
        (tester) async {
      final cacheMem = MemoryStore();
      final planMem = MemoryStore();
      TodaySummaryCache.instance.debugSetStore(
          read: cacheMem.read, write: cacheMem.write, delete: cacheMem.delete);
      TodayPlanStore.instance.debugSetStore(
          read: planMem.read, write: planMem.write, delete: planMem.delete);
      addTearDown(restoreSingletonStorage);
      addTearDown(() => TabsBackend.onSessionExpired = null);
      // The previous account's summary + plan state sit on device.
      await TodaySummaryCache.instance.save(
          email: 'a@x.com',
          todayStr: _today,
          plan: veraPlan('CachedMed'),
          trends: veraTrends());
      await TodayPlanStore.instance.setReminderCompleted(
          email: 'a@x.com', todayStr: _today, reminderId: 7, completed: true);

      final onboardingMap = <String, String>{};
      final store = FakeSessionStore()
        ..token = 'fake-access'
        ..refreshToken = 'fake-refresh'
        ..email = 'a@x.com';
      await tester.pumpWidget(MaterialApp(
        home: AppFlow(
          authApi: AuthApiClient(
              client:
                  MockClient((_) async => http.Response('{}', 200))),
          sessionStore: store,
          onboardingStore: OnboardingStore.withStorage(
            read: (k) async => onboardingMap[k],
            write: (k, v) async => onboardingMap[k] = v,
            delete: (k) async => onboardingMap.remove(k),
          ),
          weatherApi: WeatherApiClient(
              client: MockClient((_) async => http.Response(
                  '{"current":{"temperature_2m":61.0,'
                  '"weather_code":2,"is_day":1}}',
                  200))),
        ),
      ));
      // Past the splash (entry 650 + hold 1200 + exit 650).
      await tester.pump(const Duration(milliseconds: 1850));
      await tester.pump(const Duration(milliseconds: 650));
      await tester.pump();
      expect(find.byType(HomeScreen), findsOneWidget);
      // The seeded subtitle belongs to the cached blob; the card's
      // own session-email read cannot produce it in this harness,
      // and the account-bound snapshot rule refuses it regardless.
      expect(find.text('1 item remaining'), findsNothing);

      // The backend wrapper clears the session store BEFORE firing
      // this callback in production; mirror that order here.
      await store.clear();
      TabsBackend.onSessionExpired?.call();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(WelcomeScreen), findsOneWidget);
      expect(cacheMem.map.containsKey(TodaySummaryCache.storageKey),
          isFalse);
      expect(planMem.map.containsKey(TodayPlanStore.storageKey), isFalse);
    });
  });
}
