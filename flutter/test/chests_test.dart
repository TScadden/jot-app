import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tabs_lab/src/data/chest_service.dart';
import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/features/home/chest_drop_presenter.dart';
import 'package:tabs_lab/src/features/home/chest_open_flow.dart';
import 'package:tabs_lab/src/features/home/chests_sheet.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart';

ChestItem chest(String id, ChestTier tier) =>
    ChestItem(id: id, tier: tier, createdAt: DateTime.utc(2026, 11, 26));

ChestOpenResult script(
  List<bool> outcomes,
  ChestTier finalTier, {
  int gems = 25,
  int balance = 445,
}) => ChestOpenResult(
  tapOutcomes: outcomes,
  finalTier: finalTier,
  gemsGranted: gems,
  newBalance: balance,
);

/// A ChestService wired to in-memory fakes.
class FakeChests {
  List<ChestItem>? inventoryResult;
  ChestOpenResult? openResult;
  int openCalls = 0;
  String? lastOpenedId;

  final Map<String, String> disk = {};

  late final ChestService service = ChestService(
    fetchInventory: () async => inventoryResult,
    openCall: (id) async {
      openCalls++;
      lastOpenedId = id;
      return openResult;
    },
    readValue: (key) async => disk[key],
    writeValue: (key, value) async => disk[key] = value,
  );
}

void main() {
  group('ChestTier — lowercase wire contract (Mason PR #75)', () {
    test('parses lowercase tiers, rejects anything else', () {
      expect(ChestTier.tryParse('daily'), ChestTier.daily);
      expect(ChestTier.tryParse('streak'), ChestTier.streak);
      expect(ChestTier.tryParse('mega'), ChestTier.mega);
      expect(ChestTier.tryParse('gold'), isNull);
      expect(ChestTier.tryParse(7), isNull);
      expect(ChestTier.tryParse(null), isNull);
    });

    test('payouts and labels', () {
      expect(ChestTier.daily.payout, 10);
      expect(ChestTier.streak.payout, 25);
      expect(ChestTier.mega.payout, 100);
      expect(ChestTier.daily.stageLabel, 'DAILY');
      expect(ChestTier.streak.stageLabel, 'STREAK');
      expect(ChestTier.mega.stageLabel, 'MEGA');
      expect(ChestTier.daily.rowName, 'Daily Chest');
      expect(ChestTier.streak.rowName, 'Streak Chest');
      expect(ChestTier.mega.rowName, 'MEGA Chest');
      expect(ChestTier.daily.upgraded, ChestTier.streak);
      expect(ChestTier.streak.upgraded, ChestTier.mega);
      expect(ChestTier.mega.upgraded, isNull);
    });
  });

  group('API response parsing', () {
    test('inventory body {chests:[...], counts:{...}} parses', () {
      final items = ChestService.parseInventory({
        'chests': [
          {'id': 'c1', 'tier': 'streak', 'createdAt': '2026-11-26T10:00:00Z'},
          {'id': 'c2', 'tier': 'mega', 'createdAt': '2026-11-26T09:00:00Z'},
          {'id': 'bad', 'tier': 'gold'},
        ],
        'counts': {'daily': 0, 'streak': 1, 'mega': 1, 'total': 2},
      });
      expect(items, hasLength(2));
      expect(items![0].id, 'c1');
      expect(items[0].tier, ChestTier.streak);
      expect(items[1].tier, ChestTier.mega);
    });

    test('inventory body malformed -> null, never invented', () {
      expect(ChestService.parseInventory(null), isNull);
      expect(ChestService.parseInventory({'nope': []}), isNull);
      expect(ChestService.parseInventory({'chests': 'x'}), isNull);
    });

    test('open result parses the exact server shape', () {
      final r = ChestOpenResult.fromJson({
        'tapOutcomes': [true, false, true],
        'finalTier': 'mega',
        'gemsGranted': 100,
        'newBalance': 520,
      });
      expect(r, isNotNull);
      expect(r!.tapOutcomes, [true, false, true]);
      expect(r.finalTier, ChestTier.mega);
      expect(r.gemsGranted, 100);
      expect(r.newBalance, 520);
    });

    test('open result rejects malformed scripts', () {
      expect(
        ChestOpenResult.fromJson({
          'tapOutcomes': [true, false],
          'finalTier': 'mega',
          'gemsGranted': 100,
          'newBalance': 520,
        }),
        isNull,
      );
      expect(
        ChestOpenResult.fromJson({
          'tapOutcomes': [true, 'yes', false],
          'finalTier': 'mega',
          'gemsGranted': 100,
          'newBalance': 520,
        }),
        isNull,
      );
      expect(
        ChestOpenResult.fromJson({
          'tapOutcomes': [true, false, false],
          'finalTier': 'gold',
          'gemsGranted': 100,
          'newBalance': 520,
        }),
        isNull,
      );
    });

    test('chestDropped settlement payload parses lowercase', () {
      final drop = ChestDrop.parseChestDropped({
        'chestDropped': {'id': 'c9', 'tier': 'daily'},
      });
      expect(drop, isNotNull);
      expect(drop!.id, 'c9');
      expect(drop.tier, ChestTier.daily);
      expect(ChestDrop.parseChestDropped({'chestDropped': null}), isNull);
      expect(ChestDrop.parseChestDropped(null), isNull);
      expect(
        ChestDrop.parseChestDropped({
          'chestDropped': {'id': 'c9', 'tier': 'gold'},
        }),
        isNull,
      );
    });

    test('drop prompt body uses {tier} with no Chest suffix (ruling #10)', () {
      expect(
        ChestCopy.dropBody(ChestTier.daily),
        'A Daily chest dropped for finishing today.',
      );
      expect(
        ChestCopy.dropBody(ChestTier.streak),
        'A Streak chest dropped for finishing today.',
      );
      expect(
        ChestCopy.dropBody(ChestTier.mega),
        'A MEGA chest dropped for finishing today.',
      );
    });
  });

  group('ChestService state', () {
    test('sync populates inventory, counts and badge total', () async {
      final fake = FakeChests()
        ..inventoryResult = [
          chest('a', ChestTier.streak),
          chest('b', ChestTier.streak),
          chest('c', ChestTier.mega),
        ];
      final got = await fake.service.syncInventory();
      expect(got, hasLength(3));
      expect(fake.service.totalCount, 3);
      expect(fake.service.countsByTier[ChestTier.streak], 2);
      expect(fake.service.countsByTier[ChestTier.mega], 1);
      expect(fake.service.groupedByTier[ChestTier.streak], hasLength(2));
    });

    test('failed sync keeps the previous inventory', () async {
      final fake = FakeChests()
        ..inventoryResult = [chest('a', ChestTier.daily)];
      await fake.service.syncInventory();
      fake.inventoryResult = null;
      expect(await fake.service.syncInventory(), isNull);
      expect(fake.service.totalCount, 1);
    });

    test('settlement sync prompts only for a never-seen chest, once', () async {
      final fake = FakeChests()
        ..inventoryResult = [chest('a', ChestTier.daily)];
      await fake.service.syncInventory(); // seeds known ids
      fake.inventoryResult = [
        chest('b', ChestTier.mega),
        chest('a', ChestTier.daily),
      ];
      final drop = await fake.service.syncAfterSettlement();
      expect(drop, isNotNull);
      expect(drop!.id, 'b');
      expect(drop.tier, ChestTier.mega);
      // Same inventory again: nothing new, no second prompt.
      expect(await fake.service.syncAfterSettlement(), isNull);
    });

    test('open removes the chest and returns the script', () async {
      final fake = FakeChests()
        ..inventoryResult = [chest('a', ChestTier.daily)]
        ..openResult = script(
          [false, false, false],
          ChestTier.daily,
          gems: 10,
          balance: 430,
        );
      await fake.service.syncInventory();
      final r = await fake.service.openChest('a');
      expect(r, isNotNull);
      expect(r!.gemsGranted, 10);
      expect(fake.service.totalCount, 0);
      expect(fake.lastOpenedId, 'a');
    });

    test('failed open keeps the chest in the inbox', () async {
      final fake = FakeChests()
        ..inventoryResult = [chest('a', ChestTier.daily)]
        ..openResult = null;
      await fake.service.syncInventory();
      expect(await fake.service.openChest('a'), isNull);
      expect(fake.service.totalCount, 1);
    });
  });

  group('ChestOpenController — scripted outcomes', () {
    Future<ChestOpenController> started(
      ChestTier start,
      ChestOpenResult result,
    ) async {
      final c = ChestOpenController(
        chest: chest('x', start),
        opener: (_) async => result,
      );
      await c.start();
      return c;
    }

    test('no upgrade: label never moves', () async {
      final c = await started(
        ChestTier.daily,
        script([false, false, false], ChestTier.daily),
      );
      expect(c.phase, ChestOpenPhase.chances);
      for (var i = 0; i < 3; i++) {
        expect(c.tapChance(), isTrue);
        expect(c.displayTier, ChestTier.daily);
      }
      expect(c.tapChance(), isFalse, reason: 'a 4th tap spends nothing');
    });

    test('one upgrade: Daily -> Streak on tap 1, then holds', () async {
      final c = await started(
        ChestTier.daily,
        script([true, false, false], ChestTier.streak),
      );
      c.tapChance();
      expect(c.displayTier, ChestTier.streak);
      c.tapChance();
      c.tapChance();
      expect(c.displayTier, ChestTier.streak);
      expect(c.displayTier, c.result!.finalTier);
    });

    test('two upgrades: Daily -> Streak -> MEGA', () async {
      final c = await started(
        ChestTier.daily,
        script([true, true, false], ChestTier.mega),
      );
      c.tapChance();
      expect(c.displayTier, ChestTier.streak);
      c.tapChance();
      expect(c.displayTier, ChestTier.mega);
      c.tapChance();
      expect(c.displayTier, ChestTier.mega);
      expect(c.displayTier, c.result!.finalTier);
    });

    test('MEGA start is terminal even when the script says upgrade', () async {
      final c = await started(
        ChestTier.mega,
        script([true, true, true], ChestTier.mega),
      );
      c.tapChance();
      c.tapChance();
      c.tapChance();
      expect(c.displayTier, ChestTier.mega);
    });

    test('phase gating: open only after chances complete', () async {
      final c = await started(
        ChestTier.streak,
        script([false, false, false], ChestTier.streak),
      );
      expect(c.beginOpen(), isFalse);
      c.tapChance();
      c.tapChance();
      c.tapChance();
      expect(
        c.beginOpen(),
        isFalse,
        reason: 'the fade/beat must complete first',
      );
      c.completeChances();
      expect(c.phase, ChestOpenPhase.readyToOpen);
      expect(c.beginOpen(), isTrue);
      expect(c.phase, ChestOpenPhase.opening);
      c.showReveal();
      expect(c.phase, ChestOpenPhase.reveal);
    });

    test('failed open -> loadFailed -> retry replays the call', () async {
      var attempts = 0;
      final c = ChestOpenController(
        chest: chest('x', ChestTier.daily),
        opener: (_) async {
          attempts++;
          return attempts == 1
              ? null
              : script([false, false, false], ChestTier.daily);
        },
      );
      await c.start();
      expect(c.phase, ChestOpenPhase.loadFailed);
      await c.retry();
      expect(attempts, 2);
      expect(c.phase, ChestOpenPhase.chances);
    });

    test('balance adoption: onBalance fires with newBalance', () async {
      int? adopted;
      final c = ChestOpenController(
        chest: chest('x', ChestTier.daily),
        opener: (_) async => script(
          [false, false, false],
          ChestTier.daily,
          gems: 10,
          balance: 99,
        ),
        onBalance: (b) => adopted = b,
      );
      await c.start();
      expect(adopted, 99);
      expect(c.balanceBefore, 89);
    });
  });

  group('Freeze price (founder raise, Nov 25, 2026)', () {
    test('client freeze price is 300 gems', () {
      expect(GemCopy.freezePrice, 300);
      expect(GemCopy.buyButtonLabel, 'GET ONE MORE FREEZE · 300 GEMS');
    });
  });

  group('Juno ruled copy (byte-exact spot checks)', () {
    test('ruling strings', () {
      expect(ChestCopy.sheetTitle, 'Chests');
      expect(
        ChestCopy.emptyState,
        'No chests yet. Finish your day for a chance at a chest.',
      );
      expect(ChestCopy.loadError, "Couldn't load your chests.");
      expect(ChestCopy.loadRetry, 'Try again');
      expect(ChestCopy.openError, "Couldn't open that chest.");
      expect(ChestCopy.openRetry, 'Try again');
      expect(ChestCopy.openLater, 'Later');
      expect(ChestCopy.dropTitle, 'You got a chest!');
      expect(ChestCopy.dropOpenNow, 'Open now');
      expect(ChestCopy.dropLater, 'Later');
      expect(ChestCopy.tapTap, 'Tap! Tap!');
      expect(ChestCopy.oneChanceLeft, '1 chance left!');
      expect(ChestCopy.tapToOpen, 'Tap to open!');
      expect(ChestCopy.plusGems(25), '+25 gems');
      expect(
        ChestCopy.rewardCaption,
        'You earned a reward for finishing your day!',
      );
      expect(ChestCopy.continueLabel, 'CONTINUE');
    });
  });

  group('Widgets', () {
    testWidgets('gem pill badge: hidden at 0, count + a11y at n>=1', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: HomeGemPill(gemBalance: 42))),
      );
      expect(find.byKey(const Key('homeGemPillChestBadge')), findsNothing);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: HomeGemPill(gemBalance: 42, chestCount: 3)),
        ),
      );
      expect(find.byKey(const Key('homeGemPillChestBadge')), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.bySemanticsLabel('3 unopened chests'), findsOneWidget);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: HomeGemPill(gemBalance: 42, chestCount: 1)),
        ),
      );
      expect(find.bySemanticsLabel('1 unopened chest'), findsOneWidget);
    });

    testWidgets('inbox sheet: empty state (ruling #2)', (tester) async {
      final fake = FakeChests()..inventoryResult = [];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ChestsSheet(chestService: fake.service)),
        ),
      );
      await tester.pump();
      expect(find.text('Chests'), findsOneWidget);
      expect(
        find.text('No chests yet. Finish your day for a chance at a chest.'),
        findsOneWidget,
      );
    });

    testWidgets('inbox sheet: stacked inventory groups rows by tier', (
      tester,
    ) async {
      final fake = FakeChests()
        ..inventoryResult = [
          chest('a', ChestTier.streak),
          chest('b', ChestTier.streak),
          chest('c', ChestTier.mega),
        ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ChestsSheet(chestService: fake.service)),
        ),
      );
      await tester.pump();
      expect(find.text('Streak Chest'), findsWidgets);
      expect(find.text('MEGA Chest'), findsWidgets);
      expect(find.byKey(const Key('chestOpen-a')), findsOneWidget);
      expect(find.byKey(const Key('chestOpen-b')), findsOneWidget);
      expect(find.byKey(const Key('chestOpen-c')), findsOneWidget);
    });

    testWidgets('inbox sheet: load failure shows ruling #7/#8, not empty', (
      tester,
    ) async {
      final fake = FakeChests()..inventoryResult = null;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ChestsSheet(chestService: fake.service)),
        ),
      );
      await tester.pump();
      expect(find.text("Couldn't load your chests."), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.byKey(const Key('chestsEmptyState')), findsNothing);
    });

    testWidgets('drop prompt renders ruling #9-#12', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ChestDropPrompt(
              drop: ChestDrop(id: 'c1', tier: ChestTier.streak),
            ),
          ),
        ),
      );
      expect(find.text('You got a chest!'), findsOneWidget);
      expect(
        find.text('A Streak chest dropped for finishing today.'),
        findsOneWidget,
      );
      expect(find.text('Open now'), findsOneWidget);
      expect(find.text('Later'), findsOneWidget);
    });

    testWidgets('open flow: scripted one-upgrade run reaches the reward card', (
      tester,
    ) async {
      final fake = FakeChests()
        ..inventoryResult = [chest('a', ChestTier.daily)]
        ..openResult = script(
          [true, false, false],
          ChestTier.streak,
          gems: 25,
          balance: 445,
        );
      await tester.pumpWidget(
        MaterialApp(
          home: ChestOpenScreen(
            chest: chest('a', ChestTier.daily),
            service: fake.service,
          ),
        ),
      );
      await tester.pump();
      // Entry fired the open call; chances phase is live.
      expect(fake.openCalls, 1);
      expect(find.byKey(const Key('chestTierLabel')), findsOneWidget);
      expect(
        (tester.widget<Text>(find.byKey(const Key('chestTierLabel')))).data,
        'DAILY',
      );
      expect(find.text('Tap! Tap!'), findsOneWidget);

      // Tap 1 upgrades (scripted): label becomes STREAK at orbit start.
      await tester.tap(find.byKey(const Key('chestOpenStage')));
      await tester.pump();
      expect(
        (tester.widget<Text>(find.byKey(const Key('chestTierLabel')))).data,
        'STREAK',
      );
      expect(
        find.text('Tap! Tap!'),
        findsOneWidget,
        reason: '2 chances remain',
      );

      // Tap 2: exactly one chance left (ruling wiring condition).
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const Key('chestOpenStage')));
      await tester.pump();
      expect(find.text('1 chance left!'), findsOneWidget);

      // Tap 3 spends the last chance; after orbit + fade + beat,
      // "Tap to open!" shows. (Stepped pumps: a ticker that starts
      // mid-pump only advances on subsequent frames.)
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const Key('chestOpenStage')));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(find.text('Tap to open!'), findsOneWidget);

      // Open tap -> sequence -> reward card.
      await tester.tap(find.byKey(const Key('chestOpenStage')));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(find.text('+25 gems'), findsOneWidget);
      expect(
        find.text('You earned a reward for finishing your day!'),
        findsOneWidget,
      );
      expect(find.text('CONTINUE'), findsOneWidget);
      expect(find.text('445'), findsOneWidget);
    });
  });
}
