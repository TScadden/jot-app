import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/trends_screen.dart';

import 'test_helpers.dart';

/// Round 20b — Trends changes:
/// 1. Patterns (insights) section removed entirely.
/// 2. Log volume card toggles the hourly chart day ↔ all-time
///    (first tap clears an active filter instead of toggling).
/// 3. Most Used Symptoms dialog: height-capped, chip area scrolls,
///    header + Close pinned.

TabsBackend backendWith(MockClient client, {String? token}) {
  final store = FakeSessionStore()..token = token;
  return TabsBackend(client: client, sessionStore: store);
}

Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(MaterialApp(home: screen));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Map<String, dynamic> entry(
  int id,
  String body,
  DateTime when, {
  String chips = '[]',
}) => {
  'id': id,
  'body': body,
  'timestamp': when.millisecondsSinceEpoch,
  'categoryId': 1,
  'chips': chips,
};

/// 1 entry today 9am, 2 yesterday 9am, 1 yesterday 3pm.
Map<String, dynamic> togglePull() {
  final now = DateTime.now();
  final today9 = DateTime(now.year, now.month, now.day, 9);
  final yday9 = today9.subtract(const Duration(days: 1));
  final yday15 = DateTime(now.year, now.month, now.day - 1, 15);
  return {
    'entries': [
      entry(1, 'today nine', today9),
      entry(2, 'yday nine a', yday9),
      entry(3, 'yday nine b', yday9.add(const Duration(minutes: 5))),
      entry(4, 'yday three', yday15),
    ],
    'categories': [
      {'id': 1, 'name': 'Symptoms', 'colorHex': '#7C6EFF'},
    ],
    'insights': [
      {
        'id': 'i1',
        'text': 'You log most in the morning.',
        'type': 'pattern',
        'timestamp': 10,
      },
    ],
    'profile': <String, dynamic>{},
  };
}

Future<void> pumpTrends(WidgetTester tester, Map<String, dynamic> pull) async {
  final backend = backendWith(
    MockClient((_) async => http.Response(jsonEncode(pull), 200)),
    token: 't',
  );
  await pumpScreen(tester, TrendsScreen(backend: backend));
}

Finder mainScrollable() => find
    .descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    )
    .first;

void main() {
  // Oct 26, 2026 perf package: the sync-pull and habits caches are
  // STATIC and session-keyed, and cases in this file reuse one session
  // token across fresh fake servers — reset between cases so one
  // case's cached pull/habits body cannot be served to the next case.
  setUp(TabsBackend.debugResetSharedCaches);
  group('Round 20b Trends', () {
    testWidgets('patterns section is gone, HR section gone too (20c)',
        (tester) async {
      await pumpTrends(tester, togglePull());
      // Scroll to the very bottom — Category Focus is the last section
      // now that Patterns (20b) and Heart rate over time (20c) are gone.
      await tester.scrollUntilVisible(
        find.text('Category Focus'),
        300,
        scrollable: mainScrollable(),
      );
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await tester.pump();
      expect(find.text('PATTERNS'), findsNothing);
      expect(find.text('No patterns yet'), findsNothing);
      expect(find.text('You log most in the morning.'), findsNothing);
      expect(find.text('HEART RATE OVER TIME'), findsNothing);
      expect(find.text('No heart rate history yet'), findsNothing);
    });

    testWidgets('card tap toggles day → all-time → day bucketing', (
      tester,
    ) async {
      await pumpTrends(tester, togglePull());
      // Day mode (today): only today's 9am entry counts.
      expect(find.text('LOG ACTIVITY BY HOUR'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget); // day selector
      expect(find.text('Tap to view all time'), findsOneWidget);
      // 9am bar count, scoped to the chart: since Round 36 the
      // day-scoped Category Focus count legitimately renders its own
      // '1' for today's single Symptoms entry.
      expect(
        find.descendant(
          of: find.byType(ListView),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );
      expect(find.text('3'), findsNothing);

      await tester.tap(find.text('4 Total Entries'));
      await tester.pump();

      // All-time: 9am now buckets all 3 entries across both days.
      expect(find.text('LOG ACTIVITY BY HOUR · ALL TIME'), findsOneWidget);
      expect(
        find.text('Showing all time · tap to return to today'),
        findsOneWidget,
      );
      expect(find.text('Today'), findsNothing); // day selector hidden
      expect(find.text('3'), findsOneWidget);
      expect(find.text('1'), findsOneWidget); // yesterday 3pm bar

      await tester.tap(find.text('4 Total Entries'));
      await tester.pump();

      // Back to day mode.
      expect(find.text('LOG ACTIVITY BY HOUR'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Tap to view all time'), findsOneWidget);
      expect(find.text('3'), findsNothing);
    });

    testWidgets('returning from all-time lands on today', (tester) async {
      await pumpTrends(tester, togglePull());
      await tester.tap(find.byTooltip('Previous Day'));
      await tester.pump();
      expect(find.text('Yesterday'), findsOneWidget);
      await tester.tap(find.text('4 Total Entries')); // → all-time
      await tester.pump();
      expect(find.text('LOG ACTIVITY BY HOUR · ALL TIME'), findsOneWidget);
      await tester.tap(find.text('4 Total Entries')); // → back
      await tester.pump();
      // Hint promised "return to today" — and it does.
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Yesterday'), findsNothing);
    });

    testWidgets('hour tap in all-time lists that hour across all days', (
      tester,
    ) async {
      await pumpTrends(tester, togglePull());
      await tester.tap(find.text('4 Total Entries')); // → all-time
      await tester.pump();
      await tester.tap(find.text('9am'));
      await tester.pump();
      expect(find.text('LOGS AT 9 AM'), findsOneWidget);
      for (final body in ['today nine', 'yday nine a', 'yday nine b']) {
        await tester.scrollUntilVisible(
          find.text(body),
          200,
          scrollable: mainScrollable(),
        );
        expect(find.text(body), findsOneWidget);
      }
      expect(find.text('yday three'), findsNothing); // 3pm entry excluded
    });

    testWidgets('with a filter active, first card tap clears it only', (
      tester,
    ) async {
      await pumpTrends(tester, togglePull());
      await tester.tap(find.text('9am')); // day-mode hour filter
      await tester.pump();
      expect(find.text('LOGS AT 9 AM'), findsOneWidget);
      expect(find.text('Tap to reset filter'), findsOneWidget);

      await tester.tap(find.text('4 Total Entries'));
      await tester.pump();

      // Filter cleared, mode unchanged (still day, not all-time).
      expect(find.text('LOG ACTIVITY BY HOUR'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Tap to view all time'), findsOneWidget);
      expect(find.text('3'), findsNothing);

      // Next tap (no filter) toggles into all-time.
      await tester.tap(find.text('4 Total Entries'));
      await tester.pump();
      expect(find.text('LOG ACTIVITY BY HOUR · ALL TIME'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('symptoms dialog scrolls: last chip reachable, '
        'header and Close pinned', (tester) async {
      tester.view.physicalSize = const Size(420, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final now = DateTime.now();
      final base = DateTime(now.year, now.month, now.day, 8);
      final entries = <Map<String, dynamic>>[];
      var id = 0;
      // 24 symptoms × 2 entries (count 2) + ZebraLast × 1 (count 1)
      // → ZebraLast sorts last in the chip list.
      for (var s = 1; s <= 24; s++) {
        final name = 'Symptom${s.toString().padLeft(2, '0')}';
        for (var k = 0; k < 2; k++) {
          entries.add(
            entry(
              ++id,
              'log $id',
              base.add(Duration(minutes: id)),
              chips: '["$name"]',
            ),
          );
        }
      }
      entries.add(
        entry(
          ++id,
          'zebra log',
          base.add(const Duration(hours: 2)),
          chips: '["ZebraLast"]',
        ),
      );
      await pumpTrends(tester, {
        'entries': entries,
        'categories': [
          {'id': 1, 'name': 'Symptoms', 'colorHex': '#7C6EFF'},
        ],
        'profile': <String, dynamic>{},
      });

      await tester.tap(find.byIcon(Icons.list));
      await tester.pump();
      expect(find.text('MOST USED SYMPTOMS'), findsOneWidget);
      expect(find.text('Close'), findsOneWidget);

      final scrollView = find.byType(SingleChildScrollView);
      expect(scrollView, findsOneWidget);
      final scrollable = find.descendant(
        of: scrollView,
        matching: find.byType(Scrollable),
      );
      final viewRect = tester.getRect(scrollView);
      // Dialog is height-capped (~80% of the 640-high screen).
      expect(viewRect.bottom, lessThan(640));
      // The last chip starts below the fold of the chip scroll area…
      final chip = find.text('ZebraLast');
      expect(chip, findsOneWidget);
      expect(tester.getRect(chip).center.dy, greaterThan(viewRect.bottom));
      // …while Close is already visible without scrolling.
      final closeRect = tester.getRect(find.text('Close'));
      expect(closeRect.bottom, lessThanOrEqualTo(640));

      // Scroll the chip area until the last chip is reachable, then tap.
      await tester.scrollUntilVisible(chip, 120, scrollable: scrollable);
      // Header and Close stayed pinned during the scroll.
      expect(find.text('MOST USED SYMPTOMS'), findsOneWidget);
      expect(tester.getRect(find.text('Close')).bottom, lessThanOrEqualTo(640));
      await tester.tap(chip);
      await tester.pump();

      // Selection applied: dialog closed, symptom logs listed.
      expect(find.text('MOST USED SYMPTOMS'), findsNothing);
      await tester.scrollUntilVisible(
        find.text("LOGS FOR 'ZEBRALAST'"),
        200,
        scrollable: mainScrollable(),
      );
      expect(find.text("LOGS FOR 'ZEBRALAST'"), findsOneWidget);
    });
  });
}
