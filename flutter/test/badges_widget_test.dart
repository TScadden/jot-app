import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/badge_engine.dart';
import 'package:tabs_lab/src/data/badge_store.dart';
import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/badges/badge_widget.dart';
import 'package:tabs_lab/src/features/badges/badges_screen.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';

/// Badges widget pins (BADGES package): Juno's ruled strings on
/// the screen, tiles, detail ladder, and unlock dialog; the §9
/// permission state; and the drawer entry appended LAST.
void main() {
  GemRequestResult ok() => (
        statusCode: 200,
        body: {'gemBalance': 100, 'alreadyGranted': false},
      );

  BadgeService makeService() {
    final disk = <String, String>{};
    final svc = BadgeService(grant: (_) async => ok());
    svc.debugSetStore(
      read: (k) async => disk[k],
      write: (k, v) async => disk[k] = v,
      delete: (k) async => disk.remove(k),
    );
    return svc;
  }

  /// [count] logs, one per day at noon (isolates total_logs).
  BadgeInputs logsOnly(int count) => BadgeInputs(
        logTimestampsMs: [
          for (var i = 0; i < count; i++)
            DateTime(2025, 1, 1, 12)
                .add(Duration(days: i))
                .millisecondsSinceEpoch,
        ],
      );

  Future<void> pumpScreen(
    WidgetTester tester,
    BadgeService svc, {
    double width = 360,
  }) async {
    // Tall viewport: the screen is a ListView, which only builds
    // children inside the viewport + cache extent. At a phone-height
    // viewport the later sections (and the detail ladder's lower
    // rungs) are never built, so text finders miss them. 2600dp
    // builds the whole list; layout at phone WIDTH (the dimension
    // that governs tile overflow) is unchanged.
    tester.view.physicalSize = Size(width * 3, 2600 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: BadgesScreen(service: svc, onOpenHcSettings: () async {}),
    ));
    await tester.pump();
  }

  testWidgets('empty state: Juno §10 copy, §2 subtitle, zero counts',
      (tester) async {
    final svc = makeService();
    await svc.ensureLoaded();
    await pumpScreen(tester, svc);
    expect(find.text('Badges'), findsWidgets);
    expect(find.text('Earned and in progress'), findsOneWidget);
    expect(find.text('0 badges earned'), findsOneWidget);
    expect(find.text('No badges yet'), findsOneWidget);
    expect(
      find.text('Every badge below shows what it takes to earn its '
          'first rung. Your progress updates as you use Tabs.'),
      findsOneWidget,
    );
    // Sections in order with badge-count lines (never rung counts).
    expect(find.text('Logging'), findsOneWidget);
    expect(find.text('Streaks'), findsOneWidget);
    expect(find.text('Activity'), findsOneWidget);
    expect(find.text('Sleep'), findsOneWidget);
    expect(find.text('0 of 3'), findsNWidgets(4));
    // Juno §4 names (the shortened pair, not the mock's).
    expect(find.text('Monthly calories'), findsOneWidget);
    expect(find.text('Full sleep week'), findsOneWidget);
    expect(find.text('Calories in a month'), findsNothing);
    expect(find.text('Full week of sleep'), findsNothing);
    // A not-yet-earned Tabs tile: Form B at Bronze III + a true
    // zero progress line is NOT shown before any evaluation value
    // exists (no value recorded yet → no progress element).
    expect(find.text('5 logs all time'), findsOneWidget);
  });

  testWidgets('earned state: summary card, top badge, tile rung',
      (tester) async {
    final svc = makeService();
    await svc.evaluate(
      inputs: logsOnly(6),
      blockedMetrics: const {},
      now: DateTime(2026, 11, 20, 12),
    );
    await pumpScreen(tester, svc);
    expect(find.text('1 badge earned'), findsOneWidget);
    expect(find.text('Top badge'), findsOneWidget);
    expect(find.text('Bronze III · Total logs'), findsOneWidget);
    expect(find.text('1 of 3'), findsOneWidget); // Logging section
    // The in-progress tile shows its verified progress, unabbreviated.
    expect(find.text('6 of 15'), findsOneWidget);
  });

  testWidgets('maxed tile shows Maxed and no progress elements',
      (tester) async {
    final svc = makeService();
    await svc.evaluate(
      inputs: logsOnly(2000),
      blockedMetrics: const {},
      now: DateTime(2026, 11, 20, 12),
    );
    await pumpScreen(tester, svc);
    final tile = find.byKey(const ValueKey('badge_tile_total_logs'));
    expect(tile, findsOneWidget);
    expect(
      find.descendant(of: tile, matching: find.text('Maxed')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tile, matching: find.text('Diamond I')),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: tile, matching: find.byType(LinearProgressIndicator)),
      findsNothing,
    );
  });

  testWidgets('permission state: §9 block, blocked tiles carry no '
      'fake-zero progress', (tester) async {
    final svc = makeService();
    await svc.evaluate(
      inputs: const BadgeInputs(logTimestampsMs: []),
      blockedMetrics: {'steps_day', 'calories_month', 'active_week'},
      now: DateTime(2026, 11, 20, 12),
    );
    await pumpScreen(tester, svc);
    expect(find.text('Permission needed'), findsWidgets);
    expect(
      find.text("Tabs couldn't read the sections below because "
          "permission wasn't granted. Badges in those sections show "
          'no progress until access is granted.'),
      findsOneWidget,
    );
    expect(find.text('Needs permission:'), findsOneWidget);
    expect(find.text('Open Health Connect Settings'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
    final tile = find.byKey(const ValueKey('badge_tile_steps_day'));
    expect(
      find.descendant(of: tile, matching: find.text('Permission needed')),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: tile, matching: find.byType(LinearProgressIndicator)),
      findsNothing,
    );
    expect(
      find.descendant(of: tile, matching: find.textContaining('of 5,000')),
      findsNothing,
    );
    // Not now dismisses the block; the tile line stays.
    await tester.tap(find.text('Not now'));
    await tester.pump();
    expect(find.text('Needs permission:'), findsNothing);
    expect(
      find.descendant(of: tile, matching: find.text('Permission needed')),
      findsOneWidget,
    );
  });

  testWidgets('detail view: current rung, next rung, to-go, ladder',
      (tester) async {
    final svc = makeService();
    await svc.evaluate(
      inputs: logsOnly(6),
      blockedMetrics: const {},
      now: DateTime(2026, 11, 20, 12),
    );
    await pumpScreen(tester, svc);
    await tester.tap(find.byKey(const ValueKey('badge_tile_total_logs')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(BadgeDetailScreen), findsOneWidget);
    expect(find.text('Bronze III'), findsWidgets);
    expect(find.text('5 logs all time'), findsWidgets);
    expect(find.text('Next rung'), findsOneWidget);
    expect(find.text('Reach 15 logs all time'), findsOneWidget);
    expect(find.text('6 of 15'), findsOneWidget);
    expect(find.text('9 to go'), findsOneWidget);
    // The full ladder renders all 15 rungs (top and bottom ends).
    expect(find.text('Diamond I'), findsOneWidget);
    expect(find.text('2,000 logs all time'), findsOneWidget);
  });

  testWidgets('detail view: maxed shows Maxed, ladder still renders',
      (tester) async {
    final svc = makeService();
    await svc.evaluate(
      inputs: logsOnly(2000),
      blockedMetrics: const {},
      now: DateTime(2026, 11, 20, 12),
    );
    await pumpScreen(tester, svc);
    await tester.tap(find.byKey(const ValueKey('badge_tile_total_logs')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(BadgeDetailScreen), findsOneWidget);
    expect(find.text('Maxed'), findsOneWidget);
    expect(find.text('Next rung'), findsNothing);
    expect(find.textContaining('to go'), findsNothing);
    expect(find.text('Bronze III'), findsOneWidget); // ladder bottom
  });

  testWidgets('detail view: blocked badge shows the §9 state',
      (tester) async {
    final svc = makeService();
    await svc.evaluate(
      inputs: const BadgeInputs(logTimestampsMs: []),
      blockedMetrics: {'steps_day'},
      now: DateTime(2026, 11, 20, 12),
    );
    await pumpScreen(tester, svc);
    await tester.tap(find.byKey(const ValueKey('badge_tile_steps_day')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byKey(const ValueKey('badge_detail_permission_block')),
      findsOneWidget,
    );
    expect(find.text('Next rung'), findsNothing);
  });

  group('unlock dialog (Juno §8 + §13)', () {
    BadgeGrant grant(String id, int rung, {bool paid = true}) =>
        BadgeGrant(
          metric: BadgeMetrics.byId(id),
          rungIndex: rung,
          paid: paid,
          // These scenarios model fresh payouts (the store fake
          // answers alreadyGranted: false).
          paidFresh: paid,
        );

    Future<void> pumpDialog(
        WidgetTester tester, BadgeUnlockBatch batch) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: BadgeUnlockDialog(batch: batch)),
      ));
      await tester.pump();
    }

    testWidgets('single rung: singular title, +5 gems, no total',
        (tester) async {
      await pumpDialog(
        tester,
        BadgeUnlockBatch(
          isBackfill: false,
          grants: [grant('total_logs', 0)],
        ),
      );
      expect(find.text('Badge unlocked'), findsOneWidget);
      expect(find.text('Total logs — Bronze III'), findsOneWidget);
      expect(find.text('+5 gems'), findsOneWidget);
      expect(find.textContaining('Total:'), findsNothing);
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('three rungs: plural title and confirmed total',
        (tester) async {
      await pumpDialog(
        tester,
        BadgeUnlockBatch(
          isBackfill: false,
          grants: [
            grant('total_logs', 0),
            grant('total_logs', 1),
            grant('total_logs', 2),
          ],
        ),
      );
      expect(find.text('Badges unlocked'), findsOneWidget);
      expect(find.text('+5 gems'), findsNWidgets(3));
      expect(find.text('Total: +15 gems'), findsOneWidget);
      expect(
          find.text('Some gems will be added after sync.'), findsNothing);
    });

    testWidgets('alreadyGranted rungs: no gems element, no total '
        '(Vera C2 reinstall presentation)', (tester) async {
      await pumpDialog(
        tester,
        BadgeUnlockBatch(
          isBackfill: true,
          grants: [
            BadgeGrant(
              metric: BadgeMetrics.byId('total_logs'),
              rungIndex: 0,
              paid: true,
              paidFresh: false,
            ),
            BadgeGrant(
              metric: BadgeMetrics.byId('total_logs'),
              rungIndex: 1,
              paid: true,
              paidFresh: false,
            ),
          ],
        ),
      );
      expect(find.text('Badges unlocked'), findsOneWidget);
      expect(find.text('Total logs — Bronze III'), findsOneWidget);
      expect(find.text('+5 gems'), findsNothing);
      expect(find.textContaining('Total:'), findsNothing);
      expect(
          find.text('Some gems will be added after sync.'), findsNothing);
    });

    testWidgets('pending rung: no gems element, pending footer',
        (tester) async {
      await pumpDialog(
        tester,
        BadgeUnlockBatch(
          isBackfill: false,
          grants: [grant('total_logs', 0, paid: false)],
        ),
      );
      expect(find.text('+5 gems'), findsNothing);
      expect(find.textContaining('Total:'), findsNothing);
      expect(
        find.text('Some gems will be added after sync.'),
        findsOneWidget,
      );
    });

    testWidgets('grouped backfill: count line, per-badge groups, '
        'intro, confirmed-only total', (tester) async {
      await pumpDialog(
        tester,
        BadgeUnlockBatch(
          isBackfill: true,
          grants: [
            grant('total_logs', 0),
            grant('total_logs', 1),
            grant('total_logs', 2),
            grant('day_streak', 0),
            grant('day_streak', 1),
            grant('steps_day', 0),
            grant('steps_day', 1, paid: false),
          ],
        ),
      );
      expect(find.text('Badges unlocked'), findsOneWidget);
      expect(
        find.text('Earned from your history in Tabs and Health Connect.'),
        findsOneWidget,
      );
      expect(find.text('7 rungs unlocked'), findsOneWidget);
      expect(find.text('Total logs — Bronze I (3 rungs)'), findsOneWidget);
      expect(find.text('Day streak — Bronze II (2 rungs)'), findsOneWidget);
      expect(find.text('Big step day — Bronze II (2 rungs)'), findsOneWidget);
      // 6 confirmed of 7 → the total counts confirmed grants only.
      expect(find.text('Total: +30 gems'), findsOneWidget);
      expect(
        find.text('Some gems will be added after sync.'),
        findsOneWidget,
      );
      // Grouped layout has no per-rung +5 lines.
      expect(find.text('+5 gems'), findsNothing);
    });
  });

  testWidgets('BadgeWidget renders every rung without error',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Wrap(children: [
          for (var r = 0; r < 15; r++)
            BadgeWidget(rungIndex: r, icon: Icons.star, size: 48),
          const BadgeWidget(
              rungIndex: 0, icon: Icons.star, size: 48, locked: true),
        ]),
      ),
    ));
    await tester.pump();
    expect(find.byType(BadgeWidget), findsNWidgets(16));
    expect(tester.takeException(), isNull);
  });

  testWidgets('drawer: Badges entry appended last, opens the screen',
      (tester) async {
    final weather = WeatherApiClient(
      client: MockClient((request) async {
        if (request.url.host == 'ipinfo.io') {
          return http.Response(
              '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
              200);
        }
        return http.Response('not found', 404);
      }),
    );
    await tester.pumpWidget(MaterialApp(
      home: HomeScreen(weatherApi: weather),
    ));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('home_drawer_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final advocate =
        find.byKey(const ValueKey('home_drawer_ai_advocate'));
    final counters =
        find.byKey(const ValueKey('home_drawer_event_counters'));
    final badges = find.byKey(const ValueKey('home_drawer_badges'));
    expect(advocate, findsOneWidget);
    expect(counters, findsOneWidget);
    expect(badges, findsOneWidget);
    // Appended LAST at this base (final order after the Community
    // merge: AI Advocate, Event Counters, Community, Badges).
    expect(tester.getTopLeft(advocate).dy,
        lessThan(tester.getTopLeft(counters).dy));
    expect(tester.getTopLeft(counters).dy,
        lessThan(tester.getTopLeft(badges).dy));
    expect(
      find.descendant(of: badges, matching: find.text('Badges')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: badges, matching: find.byType(BadgeWidget)),
      findsOneWidget,
    );
    await tester.tap(badges);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(BadgesScreen), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 700));
  });
}
