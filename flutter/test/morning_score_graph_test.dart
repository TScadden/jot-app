import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/correlation_engine.dart'
    show deriveFeelingByDay;
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart'
    show buildMorningScoreMetric, sevenDayWindow;
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weekly_snapshot.dart';
import 'package:tabs_lab/src/data/weekly_snapshot_cache.dart';
import 'package:tabs_lab/src/features/home/weekly_snapshot_card.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

import 'test_helpers.dart';

/// In-memory SecureStore fake — no platform channels.
class _MemStore implements SecureStore {
  final Map<String, String> _map = {};
  @override
  Future<String?> read(String key) async => _map[key];
  @override
  Future<void> write(String key, String value) async => _map[key] = value;
  @override
  Future<void> delete(String key) async => _map.remove(key);
}

/// Morning Score graph option (founder, Nov 4, 2026): the Weekly
/// Snapshot gains an eighth metric — the morning 1–5 Daily Ranking
/// over the trailing 7 days.
///
/// The read-back contract under test:
/// - Plotted points equal the stored Daily Rankings day by day,
///   derived by the app's own `deriveFeelingByDay` (energy day,
///   04:00 start; newest entry wins within a day).
/// - A day with no check-in is a null point (a gap) — never 0,
///   never interpolated. A stored 0 is dropped, never plotted.
/// - The line draws against the fixed 1–5 domain.
void main() {
  group('SnapshotMetric.morningScore definition', () {
    test('is the last option, with the signed labels and 1–5 domain', () {
      expect(SnapshotMetric.values.last, SnapshotMetric.morningScore);
      final m = SnapshotMetric.morningScore;
      expect(m.stableKey, 'morning_score');
      expect(m.displayName, 'Morning Score');
      expect(m.unit, '');
      expect(m.chartColor, NotelColors.primary);
      expect(m.isBarChart, isFalse);
      expect(m.chartMin, 1);
      expect(m.chartMax, 5);
      // Every other metric keeps the native data-range scaling.
      for (final other in SnapshotMetric.values) {
        if (other == m) continue;
        expect(other.chartMin, isNull, reason: other.displayName);
        expect(other.chartMax, isNull, reason: other.displayName);
      }
    });

    test('emptyMetricData is the honest empty week', () {
      final data = emptyMetricData(SnapshotMetric.morningScore);
      expect(data.points, hasLength(7));
      expect(data.points.every((p) => p.value == null), isTrue);
      expect(data.emptyMessage, 'No morning scores logged past 7 days');
      expect(data.averageOrTotalText, 'No morning scores logged past 7 days');
    });
  });

  group('buildMorningScoreMetric read-back', () {
    const dates = [
      '2026-10-29',
      '2026-10-30',
      '2026-10-31',
      '2026-11-01',
      '2026-11-02',
      '2026-11-03',
      '2026-11-04',
    ];
    const labels = ['Thu', 'Fri', 'Sat', 'Sun', 'Mon', 'Tue', 'Wed'];

    test('points equal the stored rankings day by day; gaps stay null', () {
      final data = buildMorningScoreMetric(dates, labels, const {
        '2026-10-29': 3,
        '2026-10-30': 4,
        '2026-11-01': 2,
        '2026-11-02': 5,
        '2026-11-04': 4,
      });
      expect(
        [for (final p in data.points) p.value],
        [3.0, 4.0, null, 2.0, 5.0, null, 4.0],
      );
      expect([for (final p in data.points) p.dateStr], dates);
      expect([for (final p in data.points) p.dayLabel], labels);
      expect(data.averageOrTotalText, '7-Day Avg: 3.6 / 5');
      expect(data.emptyMessage, isNull);
      expect(data.isEmpty, isFalse);
    });

    test('whole-number averages carry no trailing .0', () {
      final data = buildMorningScoreMetric(dates, labels, const {
        '2026-10-29': 4,
        '2026-11-02': 4,
      });
      expect(data.averageOrTotalText, '7-Day Avg: 4 / 5');
    });

    test('no rankings at all → the empty state, never zeros', () {
      final data = buildMorningScoreMetric(dates, labels, const {});
      expect(data.points.every((p) => p.value == null), isTrue);
      expect(data.emptyMessage, 'No morning scores logged past 7 days');
      expect(data.isEmpty, isTrue);
    });

    test('out-of-range stored values are dropped, never plotted', () {
      final data = buildMorningScoreMetric(dates, labels, const {
        '2026-10-29': 0, // a 0 is a failed/missing read, not a score
        '2026-10-30': 6,
        '2026-11-02': 3,
      });
      expect(
        [for (final p in data.points) p.value],
        [null, null, null, null, 3.0, null, null],
      );
    });
  });

  group('entries → derivation → graph (end to end)', () {
    QuickLogEntry entry({
      required int id,
      required DateTime at,
      required String body,
      int categoryId = 6,
      String chips = '["Daily Ranking"]',
    }) {
      return QuickLogEntry(
        id: id,
        categoryId: categoryId,
        body: body,
        chips: chips,
        manualText: '',
        timestamp: at.millisecondsSinceEpoch,
      );
    }

    const categories = [
      QuickLogCategory(
        id: 6,
        name: 'Mood & Energy',
        icon: 'circle',
        colorHex: '',
        isDefault: true,
        sortOrder: 6,
      ),
      QuickLogCategory(
        id: 1,
        name: 'Symptoms',
        icon: 'circle',
        colorHex: '',
        isDefault: true,
        sortOrder: 1,
      ),
    ];

    test('plotted week equals the stored check-ins, with app day rules',
        () {
      final entries = [
        // Thu Oct 29, morning check-in → 4.
        entry(id: 1, at: DateTime(2026, 10, 29, 8, 12), body: 'Feeling: 4/5 Today'),
        // Fri Oct 30 twice — the newest entry of the energy day wins.
        entry(id: 2, at: DateTime(2026, 10, 30, 7, 45), body: 'Feeling: 2/5 Today'),
        entry(id: 3, at: DateTime(2026, 10, 30, 21, 5), body: 'Feeling: 5/5 Today'),
        // Mon Nov 2 → 2.
        entry(id: 4, at: DateTime(2026, 11, 2, 9, 0), body: 'Feeling: 2/5 Today'),
        // Wed Nov 4 at 02:00 is BEFORE the 04:00 energy-day start,
        // so it belongs to Tue Nov 3's energy day → 1 on Nov 3.
        entry(id: 5, at: DateTime(2026, 11, 4, 2, 0), body: 'Feeling: 1/5 Today'),
        // Sun Nov 1: right body, but no Daily Ranking tag → ignored.
        entry(
          id: 6,
          at: DateTime(2026, 11, 1, 10, 0),
          body: 'Feeling: 2/5 Today',
          chips: '["Headache"]',
        ),
        // Sun Nov 1: right tag, wrong category → ignored.
        entry(
          id: 7,
          at: DateTime(2026, 11, 1, 11, 0),
          body: 'Feeling: 2/5 Today',
          categoryId: 1,
        ),
        // Wed Nov 4: tag + category, but no ranking in the body.
        entry(id: 8, at: DateTime(2026, 11, 4, 8, 0), body: 'Slept badly'),
      ];

      final byDay = deriveFeelingByDay(entries, categories);
      expect(byDay, {
        '2026-10-29': 4,
        '2026-10-30': 5,
        '2026-11-02': 2,
        '2026-11-03': 1,
      });

      final data = buildMorningScoreMetric(
        const [
          '2026-10-29',
          '2026-10-30',
          '2026-10-31',
          '2026-11-01',
          '2026-11-02',
          '2026-11-03',
          '2026-11-04',
        ],
        const ['Thu', 'Fri', 'Sat', 'Sun', 'Mon', 'Tue', 'Wed'],
        byDay,
      );
      // Sat, Sun and Wed have no check-in: gaps (null), not zeros.
      expect(
        [for (final p in data.points) p.value],
        [4.0, 5.0, null, null, 2.0, 1.0, null],
      );
      expect(data.averageOrTotalText, '7-Day Avg: 3 / 5');
    });
  });

  group('HealthRepository.loadSnapshot(morningScore)', () {
    // The sync-pull cache is static and session-keyed (health_data
    // suite's note) — reset between cases.
    setUp(TabsBackend.debugResetSharedCaches);

    HealthRepository repoWith({
      required http.Client httpClient,
      required FakeSessionStore sessionStore,
    }) {
      const channel = MethodChannel(HealthConnectService.channelName);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => null);
      return HealthRepository(
        hc: HealthConnectService(channel: channel, store: _MemStore()),
        backend: TabsBackend(client: httpClient, sessionStore: sessionStore),
      );
    }

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel(HealthConnectService.channelName), null);
    });

    test('logged in: the week reads back from the sync pull', () async {
      final now = DateTime.now();
      int at(int daysAgo) =>
          DateTime(now.year, now.month, now.day - daysAgo, 8)
              .millisecondsSinceEpoch;
      final pull = jsonEncode({
        'entries': [
          {
            'id': 1,
            'categoryId': 6,
            'body': 'Feeling: 5/5 Today',
            'chips': '["Daily Ranking"]',
            'manualText': '',
            'timestamp': at(0),
          },
          {
            'id': 2,
            'categoryId': 6,
            'body': 'Feeling: 3/5 Today',
            'chips': '["Daily Ranking"]',
            'manualText': '',
            'timestamp': at(3),
          },
          {
            'id': 3,
            'categoryId': 6,
            'body': 'Feeling: 1/5 Today',
            'chips': '["Headache"]',
            'manualText': '',
            'timestamp': at(1),
          },
        ],
        'categories': [
          {'id': 6, 'name': 'Mood & Energy'},
        ],
        'profile': <String, dynamic>{},
      });
      final repo = repoWith(
        httpClient: MockClient((request) async {
          if (request.url.path == '/api/sync/pull') {
            return http.Response(pull, 200);
          }
          return http.Response('not found', 404);
        }),
        sessionStore: FakeSessionStore()..token = 'tok',
      );

      final data = await repo.loadSnapshot(SnapshotMetric.morningScore);
      expect(data.metric, SnapshotMetric.morningScore);
      expect(data.points, hasLength(7));
      // Today (index 6) = 5, three days ago (index 3) = 3; the
      // untagged entry yesterday is ignored — a gap, not a 1.
      expect(
        [for (final p in data.points) p.value],
        [null, null, null, 3.0, null, null, 5.0],
      );
      expect(data.averageOrTotalText, '7-Day Avg: 4 / 5');
    });

    test('logged out: the honest empty week, never invented values',
        () async {
      final repo = repoWith(
        httpClient: MockClient(
            (_) async => http.Response('not found', 404)),
        sessionStore: FakeSessionStore(),
      );
      final data = await repo.loadSnapshot(SnapshotMetric.morningScore);
      expect(data.points.every((p) => p.value == null), isTrue);
      expect(data.emptyMessage, 'No morning scores logged past 7 days');
    });
  });

  group('WeeklySnapshotCard — Morning Score option', () {
    /// A loader that serves a seeded Morning Score week (built
    /// through the real builder over the real trailing-7-day window)
    /// and the honest empty state for every other metric.
    Future<WeeklySnapshotMetricData> Function(SnapshotMetric) loaderFor(
      Map<int, int> byWindowIndex,
    ) {
      return (metric) async {
        if (metric != SnapshotMetric.morningScore) {
          return emptyMetricData(metric);
        }
        final window = sevenDayWindow();
        final byDay = <String, int>{
          for (final e in byWindowIndex.entries)
            window[e.key].dateStr: e.value,
        };
        return buildMorningScoreMetric(
          [for (final w in window) w.dateStr],
          [for (final w in window) w.dayLabel],
          byDay,
        );
      };
    }

    Future<void> selectMorningScore(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.arrow_drop_down));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Morning Score').last);
      await tester.pumpAndSettle();
      // Let the 650ms chart draw-in finish.
      await tester.pump(const Duration(milliseconds: 700));
    }

    /// The snapshot chart's rect: the one CustomPaint in the card
    /// with the chart's fixed 160dp height (other paints in the
    /// subtree — progress indicators and the like — are not it).
    Rect chartRect(WidgetTester tester) {
      final paints = find.descendant(
        of: find.byType(WeeklySnapshotCard),
        matching: find.byType(CustomPaint),
      );
      Rect? found;
      for (var i = 0; i < paints.evaluate().length; i++) {
        final r = tester.getRect(paints.at(i));
        if (r.height == 160) found = r;
      }
      expect(found, isNotNull,
          reason: 'the 160dp snapshot chart should be rendered');
      return found!;
    }

    testWidgets('the option is listed and selecting it graphs the week',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WeeklySnapshotCard(
              loadData: loaderFor({0: 3, 1: 4, 3: 2, 4: 5, 6: 4}),
              cache: WeeklySnapshotCache.testInstance(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.arrow_drop_down));
      await tester.pumpAndSettle();
      expect(find.text('Morning Score'), findsWidgets);
      await tester.tap(find.text('Morning Score').last);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 700));

      // (3+4+2+5+4)/5 = 3.6 — the average of the plotted days only.
      expect(find.text('7-Day Avg: 3.6 / 5'), findsOneWidget);
    });

    testWidgets('tapping a plotted day reads back its exact score',
        (tester) async {
      final window = sevenDayWindow();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WeeklySnapshotCard(
              loadData: loaderFor({3: 2}),
              cache: WeeklySnapshotCache.testInstance(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await selectMorningScore(tester);
      // Selection + load landed (single plotted day: the average is
      // that day's score) before any tap is attempted.
      expect(find.text('7-Day Avg: 2 / 5'), findsOneWidget);

      final rect = chartRect(tester);
      await tester.tapAt(
        Offset(rect.left + rect.width * (3.5 / 7), rect.center.dy),
      );
      await tester.pumpAndSettle();
      final day = window[3];
      expect(
        find.text('${day.dateStr} (${day.dayLabel}): 2'),
        findsOneWidget,
      );
    });

    testWidgets('tapping a gap day says No data — never a score',
        (tester) async {
      final window = sevenDayWindow();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WeeklySnapshotCard(
              loadData: loaderFor({3: 2}),
              cache: WeeklySnapshotCache.testInstance(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await selectMorningScore(tester);
      expect(find.text('7-Day Avg: 2 / 5'), findsOneWidget);

      final rect = chartRect(tester);
      await tester.tapAt(
        Offset(rect.left + rect.width * (1.5 / 7), rect.center.dy),
      );
      await tester.pumpAndSettle();
      final day = window[1];
      expect(
        find.text('${day.dateStr} (${day.dayLabel}): No data'),
        findsOneWidget,
      );
    });

    testWidgets('a week with no check-ins shows the empty state',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WeeklySnapshotCard(
              loadData: loaderFor(const {}),
              cache: WeeklySnapshotCache.testInstance(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await selectMorningScore(tester);
      expect(find.text('No morning scores logged past 7 days'),
          findsWidgets);
    });
  });
}
