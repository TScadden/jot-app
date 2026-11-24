import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/streak_purchase.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/home/streak_flame.dart';
import 'package:tabs_lab/src/features/home/streak_screen.dart';

/// Streak screen Duolingo-modeled rebuild (mock v3, Nov 22, 2026)
/// — the new presentation's widget tests: PERSONAL/FRIENDS tab
/// toggle, GET MORE scroll-to-buy, gem-buy disabled reasons,
/// calendar freeze/grace/today treatments, and Streak Goal
/// generalization across streak states. Copy per JUNO-COPY.md.
void main() {
  DateTime at(int y, int m, int d) => DateTime(y, m, d, 12);

  GemService fakeGems({required int? balance}) {
    final disk = <String, String>{};
    final s = GemService(
      grant: (_) async => (statusCode: null, body: null),
      spend: (id) async => (statusCode: null, body: null),
      pullBalance: () async => balance,
    );
    s.debugSetStore(
      read: (k) async => disk[k],
      write: (k, v) async => disk[k] = v,
      delete: (k) async => disk.remove(k),
    );
    return s;
  }

  StreakFreezePurchaseService fakePurchase() {
    return StreakFreezePurchaseService(
      store: _FakeStore(
        product: const StreakFreezeProduct(
          id: StreakFreezePurchaseService.productId,
          price: '\$0.99',
        ),
      ),
      verify: ({
        required productId,
        required purchaseToken,
        required orderId,
      }) async => null,
    );
  }

  Future<void> pumpScreen(
    WidgetTester tester,
    StreakState s, {
    DateTime? now,
    GemService? gems,
    List<FriendDto>? friends,
    Future<List<FriendDto>> Function()? friendsLoader,
    Size size = const Size(1080, 2400),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: StreakScreen(
          state: s,
          now: now ?? at(2026, 11, 19),
          gemService: gems ?? fakeGems(balance: 215),
          purchaseService: fakePurchase(),
          initialFriends: friends,
          friendsLoader: friendsLoader,
          streakPush: (c, b, j, {int? purchasedFreezes}) async => true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  group('PERSONAL / FRIENDS tabs', () {
    const friend = FriendDto(
      id: '7',
      nickname: 'Boston',
      tag: '67676',
      status: 'accepted',
      level: 4,
      gemBalance: 120,
      currentStreak: 12,
    );

    testWidgets('tab toggle switches PERSONAL → FRIENDS → PERSONAL', (
      tester,
    ) async {
      final s = streakSeed(current: 30, best: 68, now: at(2026, 11, 19));
      await pumpScreen(tester, s, friends: const [friend]);
      // PERSONAL is the default surface.
      expect(find.byKey(const Key('streakFreezeHeadline')), findsOneWidget);
      expect(find.text('Boston'), findsNothing);

      await tester.tap(find.byKey(const Key('streakTabFriends')));
      await tester.pump();
      await tester.pump();
      // Friend Streaks (DESIGN §7, Nov 23, 2026) replaced the old
      // auto-listed friends tab: friends NEVER auto-appear there.
      // With no pairs and no incoming invites, the tab renders the
      // Friend Streaks empty state — Boston's friend row (nickname,
      // #tag, streak, gems) is Community-surface data now and must
      // not render here.
      expect(find.text('Friend Streaks'), findsOneWidget);
      expect(find.text('Invite a friend'), findsNWidgets(2));
      expect(find.text('Boston'), findsNothing);
      expect(find.text('#67676'), findsNothing);
      expect(find.bySemanticsLabel('12 day streak'), findsNothing);
      expect(find.bySemanticsLabel('120 gems'), findsNothing);
      expect(find.textContaining('pts'), findsNothing);
      expect(find.byKey(const Key('streakFreezeHeadline')), findsNothing);

      await tester.tap(find.byKey(const Key('streakTabPersonal')));
      await tester.pump();
      expect(find.byKey(const Key('streakFreezeHeadline')), findsOneWidget);
      expect(find.text('Friend Streaks'), findsNothing);
    });

    testWidgets('empty friends list renders the Friend Streaks empty state', (
      tester,
    ) async {
      final s = streakSeed(current: 30, best: 68, now: at(2026, 11, 19));
      await pumpScreen(tester, s, friends: const []);
      await tester.tap(find.byKey(const Key('streakTabFriends')));
      await tester.pump();
      await tester.pump();
      // Friend Streaks empty state (DESIGN §7): heading + two
      // invite rows + Juno's amended footer. The old Community
      // empty line (Juno B-24) belongs to the Community screen and
      // no longer renders on this tab.
      expect(find.text('Friend Streaks'), findsOneWidget);
      expect(find.text('Invite a friend'), findsNWidgets(2));
      expect(
        find.text(
          'A friend streak goes up by one every day you both finish '
          'your day. If a day is missed, the streak ends. A day '
          'covered by a freeze pauses it instead.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('No friends added yet. Add friends using their Nickname#ID!'),
        findsNothing,
      );
    });

    testWidgets('load failure renders the Juno B-25 line', (tester) async {
      final s = streakSeed(current: 30, best: 68, now: at(2026, 11, 19));
      await pumpScreen(
        tester,
        s,
        friendsLoader: () async => throw StateError('boom'),
      );
      await tester.tap(find.byKey(const Key('streakTabFriends')));
      await tester.pump();
      await tester.pump();
      // fs_error_load (Juno, JUNO-COPY.md): the B-25 pattern with
      // the friend-streaks object — supersedes the old friends line
      // on this tab.
      expect(
        find.text(
          "Couldn't load your friend streaks right now. Try again later.",
        ),
        findsOneWidget,
      );
      expect(
        find.text("Couldn't load your friends right now. Try again later."),
        findsNothing,
      );
      expect(find.text('Friend Streaks'), findsNothing);
    });
  });

  group('GET MORE scroll action', () {
    testWidgets('GET MORE scrolls the buy card into the viewport', (
      tester,
    ) async {
      final s = streakSeed(current: 30, best: 68, now: at(2026, 11, 19));
      await pumpScreen(
        tester,
        s,
        size: const Size(1080, 1920), // 360x640 CSS — buy card below fold
      );
      final buyCard = find.byKey(const Key('streakBuyCard'));
      expect(buyCard, findsOneWidget);
      expect(tester.getTopLeft(buyCard).dy, greaterThan(640));

      await tester.tap(find.byKey(const Key('streakGetMoreButton')));
      // The ensureVisible animation runs 400 ms.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      final top = tester.getTopLeft(buyCard).dy;
      expect(top, lessThan(640));
      expect(top, greaterThan(-200));
    });
  });

  group('gem buy disabled reasons', () {
    testWidgets('balance < 100: button disabled + §2d line', (tester) async {
      final s = streakSeed(current: 5, best: 12, now: at(2026, 11, 19));
      await pumpScreen(tester, s, gems: fakeGems(balance: 35));
      await tester.scrollUntilVisible(
        find.byKey(const Key('gemBuyButton')),
        120,
      );
      await tester.pump();
      final button = tester.widget<ElevatedButton>(
        find.byKey(const Key('gemBuyButton')),
      );
      expect(button.onPressed, isNull);
      expect(
        find.text(
          'you need 65 more gems for a freeze — you earn 5 gems '
          'each time you finish your daily summary.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('at cap: gem buy hidden (Juno B-20, shipped rule)', (
      tester,
    ) async {
      var s = streakSeed(current: 5, best: 12, now: at(2026, 11, 19));
      s = s.copyWith(earnedFreezes: 1); // monthly 1 + earned 1 = 2 of 2
      await pumpScreen(tester, s, gems: fakeGems(balance: 500));
      await tester.scrollUntilVisible(
        find.byKey(const Key('streakBuyCard')),
        120,
      );
      await tester.pump();
      expect(find.byKey(const Key('gemBuyButton')), findsNothing);
      // The state line still reports the real numbers.
      expect(find.textContaining('You hold 2 · Gems: 500'), findsOneWidget);
    });

    testWidgets('no server balance yet: Gems segment omitted entirely', (
      tester,
    ) async {
      final s = streakSeed(current: 5, best: 12, now: at(2026, 11, 19));
      await pumpScreen(tester, s, gems: fakeGems(balance: null));
      await tester.scrollUntilVisible(
        find.byKey(const Key('streakBuyCard')),
        120,
      );
      await tester.pump();
      // Juno B-22: never render "Gems: 0" as a placeholder.
      expect(find.textContaining('Gems:'), findsNothing);
      expect(find.byKey(const Key('gemBuyButton')), findsNothing);
    });
  });

  group('calendar treatments', () {
    testWidgets('freeze + grace + today render distinctly', (tester) async {
      // November 2026, today = Sun Nov 22 (pending). Counted
      // Nov 1–21; Nov 10 covered by a freeze; Nov 12 completed via
      // Midnight Grace.
      final counted = <String>{
        for (var d = 1; d <= 21; d++) '2026-11-${d.toString().padLeft(2, '0')}',
      };
      final s = StreakState(
        seeded: true,
        seededCurrent: 30,
        seededBest: 68,
        countedDays: counted,
        restoredDays: const {'2026-11-10'},
        graceCompletedDays: const {'2026-11-12'},
        accrualMonth: '2026-11',
        lastEvaluatedDay: '2026-11-21',
        consumedSaveMonths: const {'2026-11'},
        purchasedFreezes: 1,
      );
      await pumpScreen(tester, s, now: at(2026, 11, 22));
      await tester.scrollUntilVisible(
        find.byKey(const Key('streakRestoredDay-2026-11-10')),
        120,
      );
      await tester.pump();

      // Freeze day: the shipped snowflake circle, keyed + labeled.
      final freezeCell = find.byKey(const Key('streakRestoredDay-2026-11-10'));
      expect(freezeCell, findsOneWidget);
      expect(tester.widget<StreakFreezeDayCircle>(freezeCell).size, 32);
      expect(
        find.bySemanticsLabel('November 10, covered by a freeze'),
        findsOneWidget,
      );
      // Grace day: NO distinct marker (Juno B-10) — it is not a
      // freeze cell and carries no special key; it joins the bar
      // as a plain completed day.
      expect(
        find.byKey(const Key('streakRestoredDay-2026-11-12')),
        findsNothing,
      );
      expect(find.text('Grace'), findsNothing);
      // Today: the day number renders (solid purple circle cell).
      expect(find.text('22'), findsOneWidget);
      // Legend describes exactly what is drawn.
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Freeze day'), findsOneWidget);
      expect(
        find.text('A day with a snowflake was covered by a freeze.'),
        findsOneWidget,
      );
      // Month nav: paging back shows October 2026.
      await tester.scrollUntilVisible(
        find.byKey(const Key('streakCalPrevMonth')),
        -120,
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('streakCalPrevMonth')));
      await tester.pump();
      expect(find.text('October 2026'), findsOneWidget);
      await tester.tap(find.byKey(const Key('streakCalNextMonth')));
      await tester.pump();
      expect(find.text('November 2026'), findsOneWidget);
    });
  });

  group('Streak Goal generalization', () {
    test('gem ladder helpers generalize', () {
      expect(gemGoalLastCrossed(5), isNull);
      expect(gemGoalUpcoming(5), [7, 30, 100]);
      expect(gemGoalLastCrossed(30), 30);
      expect(gemGoalUpcoming(30), [100, 200, 300]);
      expect(gemGoalLastCrossed(100), 100);
      expect(gemGoalUpcoming(100), [200, 300, 400]);
      expect(gemGoalLastCrossed(7), 7);
      expect(gemGoalUpcoming(7), [30, 100, 200]);
    });

    testWidgets('streak 5: no check, markers 7/30/100 with bonuses', (
      tester,
    ) async {
      final s = streakSeed(current: 5, best: 12, now: at(2026, 11, 19));
      await pumpScreen(tester, s);
      await tester.scrollUntilVisible(
        find.byKey(const Key('streakGoalCaption')),
        120,
      );
      await tester.pump();
      expect(find.byKey(const Key('streakGoalCheck')), findsNothing);
      expect(find.byKey(const Key('streakGoalStart')), findsOneWidget);
      expect(find.byKey(const Key('streakGoalMarker-7')), findsOneWidget);
      expect(find.byKey(const Key('streakGoalMarker-30')), findsOneWidget);
      expect(find.byKey(const Key('streakGoalMarker-100')), findsOneWidget);
      expect(find.text('+25 gems'), findsOneWidget);
      expect(find.text('+50 gems'), findsOneWidget);
      expect(find.text('+100 gems'), findsOneWidget);
      expect(find.text('5 / 7 DAYS'), findsOneWidget);
      expect(find.text('Next gem milestone: 7 days'), findsOneWidget);
    });

    testWidgets('streak 30: check at 30, markers 100/200/300', (tester) async {
      final s = streakSeed(current: 30, best: 68, now: at(2026, 11, 19));
      await pumpScreen(tester, s);
      await tester.scrollUntilVisible(
        find.byKey(const Key('streakGoalCaption')),
        120,
      );
      await tester.pump();
      expect(find.byKey(const Key('streakGoalCheck')), findsOneWidget);
      expect(find.byKey(const Key('streakGoalMarker-100')), findsOneWidget);
      expect(find.byKey(const Key('streakGoalMarker-200')), findsOneWidget);
      expect(find.byKey(const Key('streakGoalMarker-300')), findsOneWidget);
      expect(find.text('+100 gems'), findsNWidgets(3));
      expect(find.text('30 / 100 DAYS'), findsOneWidget);
      expect(find.text('Next gem milestone: 100 days'), findsOneWidget);
    });
  });

  group('Monthly Freeze REFILLS line', () {
    testWidgets('renders only in the monthly-used state, X computed', (
      tester,
    ) async {
      // Monthly used (Nov 2 restored by the grant): anchor Nov 19
      // → next refill Dec 1 = 12 days.
      var s = streakSeed(current: 5, best: 12, now: at(2026, 11, 1));
      s = streakEvaluate(s, at(2026, 11, 3));
      s = streakEvaluate(s, at(2026, 11, 4));
      await pumpScreen(tester, s, now: at(2026, 11, 19));
      await tester.scrollUntilVisible(
        find.byKey(const Key('streakRefillLine')),
        120,
      );
      await tester.pump();
      final refill = tester.widget<Text>(
        find.byKey(const Key('streakRefillLine')),
      );
      expect(refill.textSpan!.toPlainText(), 'REFILLS IN 12 DAYS');
    });
  });
}

class _FakeStore implements StreakFreezeStore {
  final StreakFreezeProduct? product;
  final StreamController<List<StreakFreezePurchaseUpdate>> _controller =
      StreamController<List<StreakFreezePurchaseUpdate>>.broadcast();

  _FakeStore({required this.product});

  @override
  Future<bool> isAvailable() async => true;

  @override
  Stream<List<StreakFreezePurchaseUpdate>> get purchaseUpdates =>
      _controller.stream;

  @override
  Future<StreakFreezeProduct?> queryProduct(String productId) async => product;

  @override
  Future<bool> buyConsumable(StreakFreezeProduct product) async => true;

  @override
  Future<void> completePurchase(StreakFreezePurchaseUpdate update) async {}

  @override
  Future<void> restorePurchases() async {}
}
