import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tabs_lab/src/data/chest_service.dart';
import 'package:tabs_lab/src/data/cosmetics.dart';
import 'package:tabs_lab/src/data/cosmetics_service.dart';
import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/features/home/bandit_reading_slot.dart';
import 'package:tabs_lab/src/features/home/gem_store_screen.dart';
import 'package:tabs_lab/src/features/home/layered_bandit_view.dart';

/// Gem Store (Nov 27, 2026) — Bram's package tests: the baked
/// timeline, the fixed catalog, Juno's byte-exact copy
/// (build-gem-store/JUNO-COPY.md), the cosmetics service's
/// purchase/equip discipline, the layered view's layer stack,
/// the Home slot's equipped-look behavior, and the store
/// screen's states (load failure, footer, freeze total cover,
/// shades None card, detail buy flow).

// ── Fakes ─────────────────────────────────────────────────────

class FakeStoreBackend {
  int purchaseStatus = 200;
  Map<String, dynamic>? purchaseBody;
  int equipStatus = 200;
  Map<String, dynamic>? equipBody;
  Map<String, dynamic>? profileBody;
  final List<String> purchaseKeys = [];
  final List<String> purchaseItemIds = [];
  final List<({String slot, String? itemId})> equipCalls = [];
  int keyCounter = 0;

  CosmeticsService service() => CosmeticsService(
    purchase: (itemId, key) async {
      purchaseItemIds.add(itemId);
      purchaseKeys.add(key);
      return (statusCode: purchaseStatus, body: purchaseBody);
    },
    equip: (slot, itemId) async {
      equipCalls.add((slot: slot, itemId: itemId));
      return (statusCode: equipStatus, body: equipBody);
    },
    pullProfile: () async => profileBody,
    keyGen: () => 'key-${keyCounter++}',
  );
}

GemService fakeGems({required int? balance}) {
  final disk = <String, String>{};
  final s = GemService(
    grant: (_) async => (statusCode: null, body: null),
    spend: (_) async => (statusCode: null, body: null),
    pullBalance: () async => balance,
  );
  s.debugSetStore(
    read: (k) async => disk[k],
    write: (k, v) async => disk[k] = v,
    delete: (k) async => disk.remove(k),
  );
  return s;
}

ChestService fakeChests(List<ChestItem> items) {
  final disk = <String, String>{};
  return ChestService(
    fetchInventory: () async => items,
    openCall: (_) async => null,
    readValue: (k) async => disk[k],
    writeValue: (k, v) async => disk[k] = v,
  );
}

Map<String, dynamic> profileWith(Map<String, dynamic> cosmetics) => {
  'profile': {'cosmetics': cosmetics},
};

void main() {
  // ── Timeline ────────────────────────────────────────────────

  group('BanditTimeline (baked from the v9 loop timeline)', () {
    test('33 steps, durations sum to 13,999 ms', () {
      expect(BanditTimeline.steps, hasLength(33));
      expect(BanditTimeline.totalMs, 13999);
    });

    test('eye-state sequence is the blink cycle x4 + holds', () {
      final states = [for (final s in BanditTimeline.steps) s.eyeState];
      expect(states, [
        0, 1, 2, 3, 4, 3, 2, 1, //
        0, 1, 2, 3, 4, 3, 2, 1,
        0, 1, 2, 3, 4, 3, 2, 1,
        0, 1, 2, 3, 4, 3, 2, 1,
        0,
      ]);
    });
  });

  // ── Catalog ─────────────────────────────────────────────────

  group('CosmeticCatalog (Juno §5)', () {
    test('13 purchasables, exact prices, full set 4,550', () {
      expect(CosmeticCatalog.purchasables, hasLength(13));
      final prices = {
        for (final i in CosmeticCatalog.purchasables) i.id: i.price,
      };
      expect(prices, {
        'bandit_rose': 400,
        'bandit_sky': 400,
        'bandit_mint': 500,
        'bandit_sunset': 600,
        'chair_ocean': 350,
        'chair_crimson': 350,
        'chair_midnight': 500,
        'book_teal': 150,
        'book_scarlet': 200,
        'book_gold': 300,
        'shades_black': 200,
        'shades_rose': 250,
        'shades_gold': 350,
      });
      expect(prices.values.fold(0, (a, b) => a + b), 4550);
    });

    test('display names — chair default is Classic, NOT Classic Purple (§12)', () {
      expect(CosmeticCatalog.chairClassic.name, 'Classic');
      expect(CosmeticCatalog.bookPurple.name, 'Purple');
      expect(CosmeticCatalog.bookGold.name, 'Gold Leaf');
      expect(CosmeticCatalog.shadesRose.name, 'Rose Tint');
      expect(CosmeticCatalog.shadesGold.name, 'Gold Frame');
    });

    test('sunglasses purchasables are in ascending price order (§12)', () {
      final prices = [for (final i in CosmeticCatalog.shades) i.price];
      expect(prices, [200, 250, 350]);
    });
  });

  // ── Juno copy pins ──────────────────────────────────────────

  group('StoreCopy (Juno byte-exact)', () {
    test('structure + hero strings', () {
      expect(StoreCopy.storeTitle, 'Gem Store');
      expect(StoreCopy.heroTitle, 'Your Bandit');
      expect(
        StoreCopy.heroLine,
        'Tap any item and he tries it on, reading animation and all.',
      );
      expect(StoreCopy.banditSectionSub,
          'A new coat for Bandit, everywhere he shows up.');
      expect(StoreCopy.chairsSectionSub,
          "Bandit's reading chair on your home screen.");
      expect(StoreCopy.booksSectionSub, 'The book Bandit is reading.');
      expect(StoreCopy.shadesSectionSub,
          'Shades for Bandit. He wears them everywhere.');
    });

    test('chests row sublabels (#13/#14/#15)', () {
      expect(StoreCopy.chestsRowSubtitle(2), '2 unopened, tap to open');
      expect(StoreCopy.chestsRowSubtitle(1), '1 unopened, tap to open');
      expect(StoreCopy.chestsRowSubtitle(0), 'No chests yet');
    });

    test('insufficient lines for items (#36/#37)', () {
      expect(
        StoreCopy.insufficientForItem(1),
        'you need 1 more gem for this one — you earn 5 gems each time '
        'you finish your daily summary.',
      );
      expect(
        StoreCopy.insufficientForItem(45),
        'you need 45 more gems for this one — you earn 5 gems each time '
        'you finish your daily summary.',
      );
    });

    test('success body variants (#39/#40/#41)', () {
      expect(StoreCopy.purchaseSuccessTitle, "it's yours");
      expect(StoreCopy.purchaseSuccessBody('Rose', 45),
          'bandit is wearing Rose now. you have 45 gems left.');
      expect(StoreCopy.purchaseSuccessBody('Rose', 1),
          'bandit is wearing Rose now. you have 1 gem left.');
      expect(StoreCopy.purchaseSuccessBody('Rose', 0),
          'bandit is wearing Rose now. you have 0 gems left.');
    });

    test('failure strings assert no cause (§9)', () {
      expect(StoreCopy.purchaseFailedLine, "couldn't complete that purchase.");
      expect(StoreCopy.equipFailedLine, "couldn't save that change.");
      expect(StoreCopy.loadFailedLine, "Couldn't load the store.");
    });

    test('after-buying line (#26)', () {
      expect(StoreCopy.afterBuyingLine(45), 'After buying: 45 gems left');
      expect(StoreCopy.afterBuyingLine(1), 'After buying: 1 gem left');
    });

    test('hero a11y label (#49), with and without shades', () {
      expect(
        StoreCopy.heroLabel(BanditSelection.defaults),
        'Bandit reading in his chair. Wearing: Original Bandit, '
        'Classic chair, Purple book.',
      );
      final withShades = BanditSelection.defaults.withItem(
        CosmeticCatalog.shadesGold,
        CosmeticSlot.shades,
      );
      expect(
        StoreCopy.heroLabel(withShades),
        'Bandit reading in his chair. Wearing: Original Bandit, '
        'Classic chair, Purple book, Gold Frame sunglasses.',
      );
    });

    test('detail caption: the mock Bandit-color instance verbatim (#33)', () {
      expect(
        detailCaption(
          previewed: CosmeticSlot.bandit,
          equipped: BanditSelection.defaults,
        ),
        'Shown on the Classic chair with the Purple book. Your chair '
        'and book keep whatever colors you have equipped.',
      );
    });

    test('freeze a11y label (#55) has no at-cap variant', () {
      expect(StoreCopy.freezeLabel(2),
          'Streak Freeze, 300 gems. Covers one missed day. You have 2.');
    });
  });

  // ── CosmeticsState parsing ──────────────────────────────────

  group('CosmeticsState.fromPayload', () {
    test('map payload: owned + equipped adopted, defaults unioned', () {
      final s = CosmeticsState.fromPayload({
        'owned': ['bandit_rose'],
        'equipped': {
          'bandit': 'bandit_rose',
          'chair': 'chair_classic',
          'book': 'book_purple',
          'shades': 'shades_black',
        },
      });
      expect(s.owns('bandit_rose'), isTrue);
      expect(s.owns('bandit_original'), isTrue);
      expect(s.equipped.bandit.id, 'bandit_rose');
      expect(s.equipped.shades?.id, 'shades_black');
      expect(s.equipped.isDefault, isFalse);
    });

    test('string payload decodes; unknown ids ignored, never fabricated', () {
      final s = CosmeticsState.fromPayload(
        '{"owned":["bandit_nope","book_gold"],"equipped":{"book":"book_gold"}}',
      );
      expect(s.owns('book_gold'), isTrue);
      expect(s.owns('bandit_nope'), isFalse);
      expect(s.equipped.book.id, 'book_gold');
      expect(s.equipped.bandit.id, 'bandit_original');
    });

    test('null / malformed payloads fall back to defaults', () {
      expect(CosmeticsState.fromPayload(null), CosmeticsState.defaults);
      expect(CosmeticsState.fromPayload('not json'), CosmeticsState.defaults);
      expect(CosmeticsState.fromPayload(42), CosmeticsState.defaults);
    });
  });

  // ── Service discipline ──────────────────────────────────────

  group('CosmeticsService', () {
    test('refreshFromProfile adopts cosmetics and sets loaded', () async {
      final fake = FakeStoreBackend()
        ..profileBody = profileWith({
          'owned': ['chair_ocean'],
          'equipped': {'chair': 'chair_ocean'},
        });
      final service = fake.service();
      expect(service.loaded, isFalse);
      expect(await service.refreshFromProfile(), isTrue);
      expect(service.loaded, isTrue);
      expect(service.equipped.chair.id, 'chair_ocean');
    });

    test('failed refresh leaves loaded false (the §9 #47 gate)', () async {
      final fake = FakeStoreBackend()..profileBody = null;
      final service = fake.service();
      expect(await service.refreshFromProfile(), isFalse);
      expect(service.loaded, isFalse);
    });

    test('purchase success adopts cosmetics + equips via the response', () async {
      final fake = FakeStoreBackend()
        ..purchaseBody = {
          'balance': 45,
          'cosmetics': {
            'owned': ['bandit_rose'],
            'equipped': {'bandit': 'bandit_rose'},
          },
        };
      final service = fake.service();
      final result = await service.purchase(CosmeticCatalog.banditRose);
      expect(result.status, StorePurchaseStatus.success);
      expect(result.balance, 45);
      expect(service.owns(CosmeticCatalog.banditRose), isTrue);
      expect(service.isEquipped(CosmeticCatalog.banditRose), isTrue);
      // The response already equipped it — no follow-up equip call.
      expect(fake.equipCalls, isEmpty);
      expect(fake.purchaseKeys, hasLength(1));
    });

    test('purchase equips via a follow-up call when the response does not', () async {
      final fake = FakeStoreBackend()
        ..purchaseBody = {
          'balance': 45,
          'cosmetics': {
            'owned': ['bandit_rose'],
            'equipped': {'bandit': 'bandit_original'},
          },
        }
        ..equipBody = {
          'cosmetics': {
            'owned': ['bandit_rose'],
            'equipped': {'bandit': 'bandit_rose'},
          },
        };
      final service = fake.service();
      final result = await service.purchase(CosmeticCatalog.banditRose);
      expect(result.status, StorePurchaseStatus.success);
      expect(fake.equipCalls, hasLength(1));
      expect(fake.equipCalls.single.slot, 'bandit');
      expect(fake.equipCalls.single.itemId, 'bandit_rose');
      expect(service.isEquipped(CosmeticCatalog.banditRose), isTrue);
    });

    test('purchase is NOT optimistic: failure changes nothing', () async {
      final fake = FakeStoreBackend()
        ..purchaseStatus = 500
        ..purchaseBody = {'error': 'server_error'};
      final service = fake.service();
      final result = await service.purchase(CosmeticCatalog.banditRose);
      expect(result.status, StorePurchaseStatus.failed);
      expect(service.owns(CosmeticCatalog.banditRose), isFalse);
      expect(service.equipped.isDefault, isTrue);
    });

    test('a failed attempt keeps its key; Try again reuses it (§9)', () async {
      final fake = FakeStoreBackend()
        ..purchaseStatus = 500
        ..purchaseBody = null;
      final service = fake.service();
      await service.purchase(CosmeticCatalog.bookTeal);
      await service.purchase(CosmeticCatalog.bookTeal); // the retry
      expect(fake.purchaseKeys, hasLength(2));
      expect(fake.purchaseKeys[0], fake.purchaseKeys[1]);
      // "Later" abandons the attempt — the next buy mints fresh.
      service.abandonPurchaseAttempt('book_teal');
      await service.purchase(CosmeticCatalog.bookTeal);
      expect(fake.purchaseKeys[2], isNot(fake.purchaseKeys[0]));
    });

    test('insufficient (as-built 400) maps out and ends the attempt', () async {
      final fake = FakeStoreBackend()
        ..purchaseStatus = 400
        ..purchaseBody = {'error': 'insufficient_gems', 'balance': 100};
      final service = fake.service();
      final result = await service.purchase(CosmeticCatalog.banditRose);
      expect(result.status, StorePurchaseStatus.insufficient);
      expect(result.balance, 100);
      expect(service.debugAttemptKey('bandit_rose'), isNull);
    });

    test('already_owned (409) adopts state, equips, no success status', () async {
      final fake = FakeStoreBackend()
        ..purchaseStatus = 409
        ..purchaseBody = {
          'error': 'already_owned',
          'balance': 445,
          'cosmetics': {
            'owned': ['bandit_rose'],
            'equipped': {'bandit': 'bandit_original'},
          },
        }
        ..equipBody = {
          'cosmetics': {
            'owned': ['bandit_rose'],
            'equipped': {'bandit': 'bandit_rose'},
          },
        };
      final service = fake.service();
      final result = await service.purchase(CosmeticCatalog.banditRose);
      expect(result.status, StorePurchaseStatus.alreadyOwned);
      expect(service.owns(CosmeticCatalog.banditRose), isTrue);
      expect(service.isEquipped(CosmeticCatalog.banditRose), isTrue);
      expect(service.debugAttemptKey('bandit_rose'), isNull);
    });

    test('equip is optimistic and rolls back on failure', () async {
      final fake = FakeStoreBackend()..equipStatus = 500;
      final service = fake.service();
      final pending = service.equip(
        CosmeticSlot.chair,
        CosmeticCatalog.chairOcean,
      );
      // Optimistic: the flip is visible before the answer lands.
      expect(service.equipped.chair.id, 'chair_ocean');
      expect(await pending, isFalse);
      expect(service.equipped.chair.id, 'chair_classic');
    });

    test('equip success adopts the response cosmetics as truth', () async {
      final fake = FakeStoreBackend()
        ..equipBody = {
          'cosmetics': {
            'owned': ['shades_black'],
            'equipped': {'shades': 'shades_black'},
          },
        };
      final service = fake.service();
      expect(
        await service.equip(CosmeticSlot.shades, CosmeticCatalog.shadesBlack),
        isTrue,
      );
      expect(service.equipped.shades?.id, 'shades_black');
      // The shades None path sends a null itemId.
      await service.equip(CosmeticSlot.shades, null);
      expect(fake.equipCalls.last.itemId, isNull);
      expect(fake.equipCalls.last.slot, 'shades');
    });
  });

  // ── LayeredBanditView ───────────────────────────────────────

  group('LayeredBanditView', () {
    tearDown(() => debugLayeredBanditMotionOverride = null);

    String assetOf(Key key, WidgetTester tester) {
      final image = tester.widget<Image>(find.byKey(key));
      return (image.image as AssetImage).assetName;
    }

    testWidgets('still renders chair → bandit → book, no eyes, no shades', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LayeredBanditView(selection: BanditSelection.defaults),
          ),
        ),
      );
      expect(assetOf(const ValueKey('layered_chair'), tester),
          'assets/bandit_store/chair_classic.webp');
      expect(assetOf(const ValueKey('layered_bandit_base'), tester),
          'assets/bandit_store/bandit_original.webp');
      expect(assetOf(const ValueKey('layered_book'), tester),
          'assets/bandit_store/book_purple.webp');
      expect(find.byKey(const ValueKey('layered_shades')), findsNothing);
      expect(
        find.byKey(const ValueKey('layered_bandit_eyes_1')),
        findsNothing,
        reason: 'state 0 (eyes open) renders no eye patch',
      );
    });

    testWidgets('a fully mixed selection renders its own layers', (
      tester,
    ) async {
      const mixed = BanditSelection(
        bandit: CosmeticCatalog.banditRose,
        chair: CosmeticCatalog.chairMidnight,
        book: CosmeticCatalog.bookGold,
        shades: CosmeticCatalog.shadesGold,
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: LayeredBanditView(selection: mixed)),
        ),
      );
      expect(assetOf(const ValueKey('layered_chair'), tester),
          'assets/bandit_store/chair_midnight.webp');
      expect(assetOf(const ValueKey('layered_bandit_base'), tester),
          'assets/bandit_store/bandit_rose.webp');
      expect(assetOf(const ValueKey('layered_book'), tester),
          'assets/bandit_store/book_gold.webp');
      expect(assetOf(const ValueKey('layered_shades'), tester),
          'assets/bandit_store/shades_gold.webp');
    });

    testWidgets('the timeline steps blink states in order', (tester) async {
      debugLayeredBanditMotionOverride = true;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LayeredBanditView(selection: BanditSelection.defaults),
          ),
        ),
      );
      // Step 0 holds 2,291 ms with eyes open.
      await tester.pump(const Duration(milliseconds: 2291));
      expect(
        assetOf(const ValueKey('layered_bandit_eyes_1'), tester),
        'assets/bandit_store/bandit_eyes_original_1.webp',
      );
      await tester.pump(const Duration(milliseconds: 42));
      expect(find.byKey(const ValueKey('layered_bandit_eyes_2')),
          findsOneWidget);
      await tester.pump(const Duration(milliseconds: 42));
      expect(find.byKey(const ValueKey('layered_bandit_eyes_3')),
          findsOneWidget);
      await tester.pump(const Duration(milliseconds: 41));
      expect(find.byKey(const ValueKey('layered_bandit_eyes_4')),
          findsOneWidget);
      // The merged lid-1.0 hold (84 ms) returns through 3, 2, 1 to open.
      await tester.pump(const Duration(milliseconds: 84));
      expect(find.byKey(const ValueKey('layered_bandit_eyes_3')),
          findsOneWidget);
      await tester.pump(const Duration(milliseconds: 41 + 42 + 42));
      expect(find.byKey(const ValueKey('layered_bandit_eyes_1')),
          findsNothing);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('reduced motion forces the state-0 still', (tester) async {
      debugLayeredBanditMotionOverride = true;
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: LayeredBanditView(selection: BanditSelection.defaults),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 5));
      expect(find.byKey(const ValueKey('layered_bandit_eyes_1')),
          findsNothing);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });
  });

  // ── Home slot with cosmetics ────────────────────────────────

  group('BanditReadingSlot with an equipped look', () {
    tearDown(() => debugBanditSlotMotionOverride = null);

    CosmeticsService serviceWith(BanditSelection selection) {
      final fake = FakeStoreBackend();
      final service = fake.service();
      service.adoptCosmetics({
        'owned': [
          selection.bandit.id,
          selection.chair.id,
          selection.book.id,
          if (selection.shades != null) selection.shades!.id,
        ],
        'equipped': {
          'bandit': selection.bandit.id,
          'chair': selection.chair.id,
          'book': selection.book.id,
          'shades': selection.shades?.id,
        },
      });
      return service;
    }

    testWidgets('non-default look renders the layered view; taps do nothing', (
      tester,
    ) async {
      debugBanditSlotMotionOverride = true;
      final service = serviceWith(
        BanditSelection.defaults.withItem(
          CosmeticCatalog.banditRose,
          CosmeticSlot.bandit,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: BanditReadingSlot(cosmeticsService: service)),
        ),
      );
      expect(find.byType(LayeredBanditView), findsOneWidget);
      final layered = tester.widget<LayeredBanditView>(
        find.byType(LayeredBanditView),
      );
      expect(layered.selection.bandit.id, 'bandit_rose');
      expect(layered.animate, isTrue);
      await tester.tap(find.byKey(const ValueKey('bandit_reading_tap_target')));
      await tester.pump();
      // No tap reaction with cosmetics equipped (Otto decision):
      // the layered view is still what's on screen.
      expect(find.byType(LayeredBanditView), findsOneWidget);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('non-default look under reduced motion is the layered still', (
      tester,
    ) async {
      final service = serviceWith(
        BanditSelection.defaults.withItem(
          CosmeticCatalog.chairOcean,
          CosmeticSlot.chair,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: BanditReadingSlot(cosmeticsService: service)),
        ),
      );
      final layered = tester.widget<LayeredBanditView>(
        find.byType(LayeredBanditView),
      );
      expect(layered.animate, isFalse,
          reason: 'test environment = motion off: state-0 composite, '
              'not the poster path');
      expect(layered.selection.chair.id, 'chair_ocean');
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });
  });

  // ── Store screen ────────────────────────────────────────────

  group('GemStoreScreen', () {
    Future<void> pumpStore(
      WidgetTester tester, {
      required CosmeticsService cosmetics,
      required GemService gems,
      ChestService? chests,
      StreakState? streakState,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: GemStoreScreen(
            gemService: gems,
            cosmeticsService: cosmetics,
            chestService: chests ?? fakeChests(const []),
            streakState: streakState,
            streakPush: (c, b, j, {int? purchasedFreezes}) async => true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    /// The store body is a lazy ListView: drag a finder into
    /// the built range, then ensure it is FULLY visible (a
    /// partially visible card's center — the tap point — can
    /// sit below the viewport and eat the tap).
    Future<void> reveal(WidgetTester tester, Finder finder) async {
      await tester.dragUntilVisible(
        finder,
        find.byType(ListView),
        const Offset(0, -300),
      );
      await tester.ensureVisible(finder);
      await tester.pump();
    }

    testWidgets('load failure shows the ruled error only (§9 #47)', (
      tester,
    ) async {
      final fake = FakeStoreBackend()..profileBody = null;
      await pumpStore(
        tester,
        cosmetics: fake.service(),
        gems: fakeGems(balance: 445),
      );
      expect(find.byKey(const Key('gemStoreLoadError')), findsOneWidget);
      expect(find.text("Couldn't load the store."), findsOneWidget);
      expect(find.byKey(const Key('gemStoreLoadRetry')), findsOneWidget);
      expect(find.byKey(const Key('gemStoreSection-bandit')), findsNothing);
      expect(find.byKey(const Key('gemStoreFreezeCard')), findsNothing);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('sections, footer and shades None card render (§11, §5)', (
      tester,
    ) async {
      final fake = FakeStoreBackend()
        ..profileBody = profileWith({'owned': [], 'equipped': {}});
      await pumpStore(
        tester,
        cosmetics: fake.service(),
        gems: fakeGems(balance: 445),
        streakState: const StreakState(seeded: true),
      );
      // Reveals run in document order (the lazy ListView only
      // builds downward; earlier children dispose as it scrolls).
      await reveal(tester, find.byKey(const Key('gemStoreSection-bandit')));
      expect(find.byKey(const Key('gemStoreSection-bandit')), findsOneWidget);
      for (final item in CosmeticCatalog.bandits) {
        await reveal(tester, find.byKey(Key('storeCard-${item.id}')));
        expect(find.byKey(Key('storeCard-${item.id}')), findsOneWidget,
            reason: item.id);
      }
      await reveal(tester, find.byKey(const Key('gemStoreSection-chair')));
      expect(find.byKey(const Key('gemStoreSection-chair')), findsOneWidget);
      for (final item in CosmeticCatalog.chairs) {
        await reveal(tester, find.byKey(Key('storeCard-${item.id}')));
        expect(find.byKey(Key('storeCard-${item.id}')), findsOneWidget,
            reason: item.id);
      }
      // Chair default name is Classic (§12) — asserted while the
      // chair grid is the built range.
      expect(find.text('Classic'), findsOneWidget);
      expect(find.text('Classic Purple'), findsNothing);
      await reveal(tester, find.byKey(const Key('gemStoreSection-book')));
      expect(find.byKey(const Key('gemStoreSection-book')), findsOneWidget);
      for (final item in CosmeticCatalog.books) {
        await reveal(tester, find.byKey(Key('storeCard-${item.id}')));
        expect(find.byKey(Key('storeCard-${item.id}')), findsOneWidget,
            reason: item.id);
      }
      await reveal(tester, find.byKey(const Key('gemStoreSection-shades')));
      expect(find.byKey(const Key('gemStoreSection-shades')), findsOneWidget);
      await reveal(tester, find.byKey(const Key('storeCard-none')));
      expect(find.byKey(const Key('storeCard-none')), findsOneWidget);
      for (final item in CosmeticCatalog.shades) {
        await reveal(tester, find.byKey(Key('storeCard-${item.id}')));
        expect(find.byKey(Key('storeCard-${item.id}')), findsOneWidget,
            reason: item.id);
      }
      // Sunglasses price order (§12): None + Classic Black fill
      // the first row, so Rose Tint sits LEFT of Gold Frame in
      // the second row (mock had Gold before Rose — rejected).
      final rose = tester.getTopLeft(find.text('Rose Tint'));
      final gold = tester.getTopLeft(find.text('Gold Frame'));
      expect(rose.dy, gold.dy);
      expect(rose.dx, lessThan(gold.dx));
      // Footer: the explainer verbatim from GemCopy (§11).
      await reveal(
        tester,
        find.byKey(Key('gemStoreAboutLine${GemCopy.sheetExplainerLines.length - 1}')),
      );
      expect(find.byKey(const Key('gemStoreAboutHeading')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('gemStoreAboutHeading')))
            .data,
        GemCopy.explainerHeading,
      );
      for (var i = 0; i < GemCopy.sheetExplainerLines.length; i++) {
        expect(
          tester.widget<Text>(find.byKey(Key('gemStoreAboutLine$i'))).data,
          GemCopy.sheetExplainerLines[i],
        );
      }
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('chests row sublabels follow the count (§2)', (tester) async {
      ChestItem chest(String id) => ChestItem(
        id: id,
        tier: ChestTier.daily,
        createdAt: DateTime.utc(2026, 11, 27),
      );
      for (final (items, expected) in [
        (const <ChestItem>[], 'No chests yet'),
        ([chest('a')], '1 unopened, tap to open'),
        ([chest('a'), chest('b')], '2 unopened, tap to open'),
      ]) {
        final fake = FakeStoreBackend()
          ..profileBody = profileWith({'owned': [], 'equipped': {}});
        await pumpStore(
          tester,
          cosmetics: fake.service(),
          gems: fakeGems(balance: 0),
          chests: fakeChests(items),
        );
        expect(
          tester
              .widget<Text>(find.byKey(const Key('gemStoreChestsSubtitle')))
              .data,
          expected,
        );
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      }
    });

    testWidgets('freeze card counts TOTAL cover; at cap Buy is absent (§3)', (
      tester,
    ) async {
      final fake = FakeStoreBackend()
        ..profileBody = profileWith({'owned': [], 'equipped': {}});
      // Monthly grant unused (1) + 1 earned = 2 total = cap 2.
      await pumpStore(
        tester,
        cosmetics: fake.service(),
        gems: fakeGems(balance: 445),
        streakState: const StreakState(seeded: true, earnedFreezes: 1),
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('gemStoreFreezeOwned'))).data,
        'You have 2',
      );
      expect(find.byKey(const Key('gemStoreFreezeBuy')), findsNothing,
          reason: 'at cap the buy control does not render (absence rule)');
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));

      // Below cap the Buy renders; insufficient balance disables
      // it and shows GemCopy's insufficient line verbatim.
      final fake2 = FakeStoreBackend()
        ..profileBody = profileWith({'owned': [], 'equipped': {}});
      await pumpStore(
        tester,
        cosmetics: fake2.service(),
        gems: fakeGems(balance: 100),
        streakState: const StreakState(seeded: true),
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('gemStoreFreezeOwned'))).data,
        'You have 1',
      );
      final buy = tester.widget<FilledButton>(
        find.byKey(const Key('gemStoreFreezeBuy')),
      );
      expect(buy.onPressed, isNull);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('gemStoreFreezeInsufficient')))
            .data,
        GemCopy.insufficientLine(200),
      );
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('card states: equipped default, priced unowned (§4)', (
      tester,
    ) async {
      final fake = FakeStoreBackend()
        ..profileBody = profileWith({'owned': [], 'equipped': {}});
      await pumpStore(
        tester,
        cosmetics: fake.service(),
        gems: fakeGems(balance: 445),
        streakState: const StreakState(seeded: true),
      );
      await reveal(tester, find.byKey(const Key('storeCard-bandit_original')));
      final originalCard = find.byKey(const Key('storeCard-bandit_original'));
      expect(
        find.descendant(of: originalCard, matching: find.text('EQUIPPED')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: originalCard, matching: find.text('Owned')),
        findsOneWidget,
      );
      await reveal(tester, find.byKey(const Key('storeCard-bandit_rose')));
      final roseCard = find.byKey(const Key('storeCard-bandit_rose'));
      expect(
        find.descendant(of: roseCard, matching: find.text('400')),
        findsOneWidget,
      );
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('detail: Buy & Equip purchases, equips, shows §8 success', (
      tester,
    ) async {
      final fake = FakeStoreBackend()
        ..profileBody = profileWith({'owned': [], 'equipped': {}})
        ..purchaseBody = {
          'balance': 45,
          'cosmetics': {
            'owned': ['bandit_rose'],
            'equipped': {'bandit': 'bandit_rose'},
          },
        };
      final cosmetics = fake.service();
      await pumpStore(
        tester,
        cosmetics: cosmetics,
        gems: fakeGems(balance: 445),
        streakState: const StreakState(seeded: true),
      );
      await reveal(tester, find.byKey(const Key('storeCard-bandit_rose')));
      await tester.tap(find.byKey(const Key('storeCard-bandit_rose')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('gemStoreDetail')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('detailAfterBuying'))).data,
        'After buying: 45 gems left',
      );
      // The tap applied Rose to the preview already: the
      // detail's own preview view carries the preview selection
      // (the hero itself is disposed by the lazy ListView once
      // scrolled past, so it cannot be read back here).
      final detailPreview = tester.widget<LayeredBanditView>(
        find.descendant(
          of: find.byKey(const Key('gemStoreDetail')),
          matching: find.byType(LayeredBanditView),
        ),
      );
      expect(detailPreview.selection.bandit.id, 'bandit_rose');
      await tester.ensureVisible(find.byKey(const Key('detailBuyButton')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('detailBuyButton')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('detailSuccessTitle'))).data,
        "it's yours",
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('detailSuccessBody'))).data,
        'bandit is wearing Rose now. you have 45 gems left.',
      );
      expect(cosmetics.isEquipped(CosmeticCatalog.banditRose), isTrue);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('detail: insufficient disables Buy and shows §7 line', (
      tester,
    ) async {
      final fake = FakeStoreBackend()
        ..profileBody = profileWith({'owned': [], 'equipped': {}});
      await pumpStore(
        tester,
        cosmetics: fake.service(),
        gems: fakeGems(balance: 100),
        streakState: const StreakState(seeded: true),
      );
      await reveal(tester, find.byKey(const Key('storeCard-bandit_rose')));
      await tester.tap(find.byKey(const Key('storeCard-bandit_rose')));
      await tester.pumpAndSettle();
      final buy = tester.widget<FilledButton>(
        find.byKey(const Key('detailBuyButton')),
      );
      expect(buy.onPressed, isNull);
      expect(
        tester.widget<Text>(find.byKey(const Key('detailInsufficient'))).data,
        StoreCopy.insufficientForItem(300),
      );
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('detail: purchase failure reuses the attempt key on retry (§9)', (
      tester,
    ) async {
      final fake = FakeStoreBackend()
        ..profileBody = profileWith({'owned': [], 'equipped': {}})
        ..purchaseStatus = 500
        ..purchaseBody = null;
      await pumpStore(
        tester,
        cosmetics: fake.service(),
        gems: fakeGems(balance: 445),
        streakState: const StreakState(seeded: true),
      );
      await reveal(tester, find.byKey(const Key('storeCard-book_teal')));
      await tester.tap(find.byKey(const Key('storeCard-book_teal')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('detailBuyButton')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('detailBuyButton')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('detailPurchaseFailure')), findsOneWidget);
      expect(find.text("couldn't complete that purchase."), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('detailFailureRetry')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('detailFailureRetry')));
      await tester.pumpAndSettle();
      expect(fake.purchaseKeys, hasLength(2));
      expect(fake.purchaseKeys[0], fake.purchaseKeys[1],
          reason: 'Try again retries the SAME attempt (same key)');
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });
  });
}
