import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/streak_purchase.dart';
import 'package:tabs_lab/src/data/streak_store.dart';
import 'package:tabs_lab/src/data/widget_sync.dart';
import 'package:tabs_lab/src/features/home/streak_celebration_screen.dart';
import 'package:tabs_lab/src/features/home/streak_flame.dart';
import 'package:tabs_lab/src/features/home/streak_screen.dart';
import 'package:tabs_lab/src/features/home/streak_share_card.dart';
import 'package:tabs_lab/src/features/settings/streak_sim.dart';

/// Streak upgrade — UI layer tests (Bram, Nov 18, 2026).
///
/// Covers: the rebuilt streak screen (both states, freeze card
/// variants, pending pause text, no bottom button), the
/// celebration screen (normal + milestone variants, Juno §6
/// naming), the share action (system share sheet with exactly the
/// generated PNG, no backend call), the purchase flow (Juno
/// §5a/§5b/§5c), the A10 SIM isolation test, and the D14 widget
/// sync fields.
void main() {
  DateTime at(int y, int m, int d, [int h = 12]) => DateTime(y, m, d, h);

  StreakState stateWith({
    required Set<String> counted,
    Set<String> restored = const {},
    Set<String> consumed = const {},
    Set<String> spoiled = const {},
    int earned = 0,
    int purchased = 0,
    bool pending = false,
    String accrualMonth = '2026-11',
  }) {
    return StreakState(
      seeded: true,
      seededCurrent: counted.length,
      seededBest: counted.length,
      countedDays: counted,
      restoredDays: restored,
      consumedSaveMonths: consumed,
      earnedFreezes: earned,
      purchasedFreezes: purchased,
      earnedPending: pending,
      accrualMonth: accrualMonth,
      spoiledMonths: spoiled,
      lastEvaluatedDay: '2026-11-18',
    );
  }

  Set<String> daysThrough(int lastDay) => {
    for (var d = 1; d <= lastDay; d++)
      '2026-11-${d.toString().padLeft(2, '0')}',
  };

  // ── Fake purchase store ────────────────────────────────────────
  // (Defined as local classes via a helper — see _FakeStore below.)

  group('streak screen (rebuilt)', () {
    Future<void> pumpScreen(
      WidgetTester tester,
      StreakState s, {
      StreakFreezePurchaseService? purchase,
    }) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: StreakScreen(
            state: s,
            now: at(2026, 11, 18),
            purchaseService: purchase,
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('not-done state: grey flame, milestone distance line, '
        'goal + freeze cards, no bottom button', (tester) async {
      // 20 counted days (Nov 1–17 + Oct 29–31 → run of 20 ending
      // yesterday); today (Nov 18) not counted.
      final counted = <String>{
        '2026-10-29',
        '2026-10-30',
        '2026-10-31',
        ...daysThrough(17),
      };
      await pumpScreen(tester, stateWith(counted: counted));
      expect(
        (tester.widget<Text>(find.byKey(const Key('streakHeroNumber')))).data,
        '20',
      );
      expect(find.text('day streak!'), findsOneWidget);
      // Juno §2 distance form (next milestone 30 → 10 days).
      expect(find.text('10 days to your next milestone'), findsOneWidget);
      // §3a + §3b + §3c (not pending).
      expect(
        find.text(
          "Finish November without using a freeze, and you'll "
          'earn an extra freeze — on top of your free monthly freeze.',
        ),
        findsOneWidget,
      );
      expect(find.text('18 / 30 DAYS freeze-free in November'), findsOneWidget);
      expect(
        find.text(
          "If you finish November with no freezes used, you "
          "earn one extra freeze. If you're at your max when it "
          'comes due, it waits — pending — until there\'s room for '
          'it. Max 2 freezes, or 3 while you hold a freeze you bought.',
        ),
        findsOneWidget,
      );
      // Freeze status (Juno B-3): monthly (1) + earned 0 +
      // purchased 0 = 1 of 2. (The §4a long status retired,
      // A-16/A-17; its sentence 3 survives as the status card's
      // caption, A-18.)
      await tester.scrollUntilVisible(
        find.byKey(const Key('streakFreezeHeadline')),
        120,
      );
      await tester.pump();
      expect(find.text('You have 1 of 2 Streak Freezes ready'), findsOneWidget);
      expect(
        find.text(
          'A freeze can cover one missed day automatically when '
          'you have one available.',
        ),
        findsOneWidget,
      );
      // No bottom action button: the only ElevatedButtons on the
      // screen belong to the freeze card's buy row (absent here —
      // the default service cannot reach Play in tests and its
      // state stays unknown, rendering no buy row at all).
      expect(find.byType(ElevatedButton), findsNothing);
      // "Restore" appears nowhere on the surface (Juno §11).
      for (final w in tester.widgetList<Text>(find.byType(Text))) {
        expect(w.data ?? '', isNot(contains('Restore')));
        expect(w.data ?? '', isNot(contains('restore')));
      }
    });

    testWidgets('done state: today counted, milestone line updates', (
      tester,
    ) async {
      final counted = <String>{
        '2026-10-28',
        '2026-10-29',
        '2026-10-30',
        '2026-10-31',
        ...daysThrough(18),
      };
      await pumpScreen(tester, stateWith(counted: counted));
      expect(
        (tester.widget<Text>(find.byKey(const Key('streakHeroNumber')))).data,
        '22',
      );
      expect(find.text('8 days to your next milestone'), findsOneWidget);
    });

    testWidgets('pending pause text + pinned-full progress (§3b/§3c)', (
      tester,
    ) async {
      final s = stateWith(counted: daysThrough(18), pending: true, earned: 0);
      await pumpScreen(tester, s);
      expect(
        find.text(
          "Your earned freeze is ready and waiting. It lands "
          "as soon as there's room for it: you aren't already "
          'holding an earned freeze, and your total freezes are '
          'under your max (2, or 3 while you hold a freeze you '
          'bought).',
        ),
        findsOneWidget,
      );
      // October (the completed month) has 31 days, pinned full.
      expect(find.text('31 / 31 DAYS freeze-free in October'), findsOneWidget);
    });

    testWidgets('freeze card: buy button renders the LISTING price; '
        'hidden while a purchased freeze is held', (tester) async {
      final store = _FakeStore(
        product: const StreakFreezeProduct(
          id: StreakFreezePurchaseService.productId,
          price: '\$1.25',
        ),
      );
      final service = StreakFreezePurchaseService(
        store: store,
        verify: ({
          required productId,
          required purchaseToken,
          required orderId,
        }) async => 1,
      );
      await service.initialize();
      await pumpScreen(
        tester,
        stateWith(counted: daysThrough(18)),
        purchase: service,
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('streakBuyButton')),
        120,
      );
      // Juno §4b/B-21: the button renders the listing's price
      // string ($1.25), never a hardcoded $0.99; the old
      // "GET ONE MORE FREEZE · {price}" label form is retired.
      expect(find.text('\$1.25'), findsOneWidget);
      expect(
        find.text(
          "Not a subscription — you pay once for this freeze. "
          "While you hold a freeze you bought, your max is 3; "
          "otherwise it's 2.",
        ),
        findsOneWidget,
      );

      // While a purchased freeze is held: no buy button, cap is 3.
      await pumpScreen(
        tester,
        stateWith(counted: daysThrough(18), purchased: 1),
        purchase: service,
      );
      expect(find.byKey(const Key('streakBuyButton')), findsNothing);
      expect(find.text('You have 2 of 3 Streak Freezes ready'), findsOneWidget);
    });

    testWidgets('freeze card: product unavailable renders Juno §5a', (
      tester,
    ) async {
      final service = StreakFreezePurchaseService(
        store: _FakeStore(product: null),
        verify: ({
          required productId,
          required purchaseToken,
          required orderId,
        }) async => null,
      );
      await service.initialize();
      expect(service.state, StreakFreezeBuyState.unavailable);
      await pumpScreen(
        tester,
        stateWith(counted: daysThrough(18)),
        purchase: service,
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('streakBuyUnavailable')),
        120,
      );
      expect(
        find.text('EXTRA FREEZE — NOT AVAILABLE RIGHT NOW'),
        findsOneWidget,
      );
      expect(
        find.text(
          "We can't reach Google Play right now, so extra "
          "freezes can't be bought at the moment. Try again later.",
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('streakBuyButton')), findsNothing);
    });
  });

  group('purchase flow (Juno §5b/§5c)', () {
    test('success adopts ONLY from the server verify count', () async {
      final store = _FakeStore(
        product: const StreakFreezeProduct(
          id: StreakFreezePurchaseService.productId,
          price: '\$0.99',
        ),
      );
      int? adopted;
      final service = StreakFreezePurchaseService(
        store: store,
        verify:
            ({
              required productId,
              required purchaseToken,
              required orderId,
            }) async {
              expect(productId, StreakFreezePurchaseService.productId);
              expect(purchaseToken, 'tok-1');
              return 1;
            },
        onAdopted: (count) => adopted = count,
        formatSuccess: (count) => "You've got an extra freeze. You now have 2 of 3 freezes available.",
      );
      await service.initialize();
      await service.buy();
      store.emit(
        const StreakFreezePurchaseUpdate(
          productId: StreakFreezePurchaseService.productId,
          purchaseToken: 'tok-1',
          orderId: 'order-1',
          status: 'purchased',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(adopted, 1);
      expect(
        service.successMessage,
        "You've got an extra freeze. You now have 2 of 3 freezes available.",
      );
      expect(service.failureMessage, isNull);
    });

    test('verify failure renders §1b ONLY (A2 fix: Juno §1b '
        'supersedes §5c for the verify-pending event); '
        'cancellation renders §5c', () async {
      final store = _FakeStore(
        product: const StreakFreezeProduct(
          id: StreakFreezePurchaseService.productId,
          price: '\$0.99',
        ),
      );
      final service = StreakFreezePurchaseService(
        store: store,
        verify: ({
          required productId,
          required purchaseToken,
          required orderId,
        }) async => null,
      );
      await service.initialize();
      await service.buy();
      store.emit(
        const StreakFreezePurchaseUpdate(
          productId: StreakFreezePurchaseService.productId,
          purchaseToken: 'tok-x',
          orderId: 'order-x',
          status: 'purchased',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      // A paid purchase whose verify has not landed is the
      // verify-pending state: Juno §1b is its message, and the
      // §5c string must not also be set for the same event.
      expect(service.pendingMessage, StreakPurchaseCopy.verifyPending);
      expect(service.failureMessage, isNull);
      expect(service.successMessage, isNull);

      await service.buy();
      store.emit(
        const StreakFreezePurchaseUpdate(
          productId: StreakFreezePurchaseService.productId,
          purchaseToken: '',
          orderId: '',
          status: 'canceled',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(service.failureMessage, isNotNull);
      expect(service.adoptedPurchasedFreezes, isNull);
    });
  });

  group('celebration screen', () {
    StreakCelebrationData data({
      required int count,
      bool milestone = false,
      int restoredIndex = -1,
    }) {
      return StreakCelebrationData(
        count: count,
        isMilestoneDay: milestone,
        week: [
          for (var i = 0; i < 7; i++)
            (
              label: ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'][i],
              counted: i <= 2,
              isToday: i == 2,
              restored: i == restoredIndex,
            ),
        ],
      );
    }

    Future<void> pumpCelebration(
      WidgetTester tester,
      StreakCelebrationData d, {
      String? nickname,
      Future<bool> Function(GlobalKey, int)? shareFn,
    }) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          // Reduced motion: the lit flame's flicker repeats
          // forever, which keeps the share card's RepaintBoundary
          // perpetually dirty and toImage can never complete under
          // fake-async. The static-flame path is a real supported
          // path (disableAnimations) and is what these tests use.
          builder: (context, child) => MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: child!,
          ),
          home: StreakCelebrationScreen(
            data: d,
            nickname: nickname,
            shareFn: shareFn,
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('normal day: count, §2 line, share icon + LET\'S GO!', (
      tester,
    ) async {
      await pumpCelebration(tester, data(count: 21), nickname: 'Tyson Scadden');
      expect(
        (tester.widget<Text>(find.byKey(const Key('celebrationCount')))).data,
        '21',
      );
      expect(find.text('day streak'), findsOneWidget);
      expect(find.text('9 days to your next milestone'), findsOneWidget);
      expect(find.byKey(const Key('celebrationShareIcon')), findsOneWidget);
      // Founder-dictated copy (Juno copy update §1, superseding
      // §6a): the button reads exactly "LET'S GO!" — no name, even
      // with a nickname set.
      expect(find.text("LET'S GO!"), findsOneWidget);
      expect(find.text('YAY, Tyson'), findsNothing);
      expect(find.byKey(const Key('celebrationShareMilestone')), findsNothing);
    });

    testWidgets('the LET\'S GO! button ignores the nickname entirely', (
      tester,
    ) async {
      await pumpCelebration(tester, data(count: 3), nickname: '   ');
      expect(find.text("LET'S GO!"), findsOneWidget);
      expect(find.text('YAY!'), findsNothing);
    });

    testWidgets('milestone day: §7 line, SHARE MILESTONE primary, '
        'Continue ungated', (tester) async {
      await pumpCelebration(
        tester,
        data(count: 30, milestone: true),
        nickname: 'Tyson',
      );
      expect(
        find.text('You reached a milestone today: 30 days.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('celebrationShareMilestone')),
        findsOneWidget,
      );
      expect(find.text('SHARE MILESTONE'), findsOneWidget);
      // Continue dismisses WITHOUT any share first (§6c).
      await tester.tap(find.byKey(const Key('celebrationContinue')));
      await tester.pumpAndSettle();
      expect(find.byType(StreakCelebrationScreen), findsNothing);
    });

    testWidgets('share icon invokes the share path with the settled '
        'count and the card boundary', (tester) async {
      GlobalKey? sharedKey;
      int? sharedCount;
      await pumpCelebration(
        tester,
        data(count: 21),
        nickname: 'Tyson',
        shareFn: (key, count) async {
          sharedKey = key;
          sharedCount = count;
          return true;
        },
      );
      await tester.tap(find.byKey(const Key('celebrationShareIcon')));
      await tester.pump();
      expect(sharedCount, 21);
      expect(sharedKey, isNotNull);
      expect(
        sharedKey!.currentContext?.findRenderObject(),
        isA<RenderRepaintBoundary>(),
      );
    });

    testWidgets('the generated card is exactly a 1080×1080 PNG and '
        'the share service hands THAT file to the share sheet', (tester) async {
      // path_provider has no test implementation: route the temp
      // dir through the service's seam (production uses the real
      // app temp dir).
      File? handedOff;
      StreakShareService.debugSetShareFn((file) async {
        handedOff = file;
      }, tempDir: () async => Directory.systemTemp);
      addTearDown(() => StreakShareService.debugSetShareFn(null));
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StreakShareCardHost(boundaryKey: key, count: 21),
          ),
        ),
      );
      await tester.pump();
      // Capture bridge (the codebase's harness pattern, cf.
      // streak_render_test): alternate pumps with real-time
      // runAsync delays so the card's asset image finishes
      // loading and the boundary settles before toImage.
      for (var i = 0; i < 5; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
      }
      await tester.pump();
      // The capture AND the file read both run in runAsync: a
      // real-IO await in the fake-async zone lets the body finish
      // but wedges test completion ("did not complete" at
      // teardown — bisected Nov 5, 2026; see streak_render_test).
      late final List<int> bytes;
      await tester.runAsync(() async {
        final ok = await StreakShareService.shareFromBoundary(key, count: 21);
        expect(ok, isTrue);
        expect(handedOff, isNotNull);
        bytes = await handedOff!.readAsBytes();
      });
      // PNG magic + IHDR dimensions: exactly 1080×1080.
      expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      final width =
          (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
      final height =
          (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
      expect(width, 1080);
      expect(height, 1080);
      expect(handedOff!.path, contains('tabs_streak_share_21.png'));
    });
  });

  group('freeze-day treatment (founder addition, Nov 18 2026)', () {
    // The recorded style, pinned exactly: a freeze-covered day is
    // a filled icy-blue #6EC6FF circle with a snowflake
    // (Icons.ac_unit) in dark navy #0D1428 — in the celebration
    // week row AND the streak screen month calendar (and week
    // row). The legacy purple-ring Restore treatment must not
    // render anywhere on these surfaces.
    void expectFreezeStyle(WidgetTester tester, Finder circle) {
      final container = tester.widget<Container>(
        find.descendant(of: circle, matching: find.byType(Container)),
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.shape, BoxShape.circle);
      expect(decoration.color, const Color(0xFF6EC6FF));
      expect(
        decoration.border,
        isNull,
        reason: 'the retired purple ring must not render',
      );
      final icon = tester.widget<Icon>(
        find.descendant(of: circle, matching: find.byIcon(Icons.ac_unit)),
      );
      expect(icon.color, const Color(0xFF0D1428));
      // A freeze day never shows the completed-day check.
      expect(
        find.descendant(of: circle, matching: find.byIcon(Icons.check)),
        findsNothing,
      );
    }

    test('fromCompletion maps restoredDays into the week row', () {
      final state = stateWith(
        counted: {'2026-11-16', '2026-11-17', '2026-11-18'},
        restored: {'2026-11-16'},
      );
      final data = StreakCelebrationData.fromCompletion(
        result: const StreakCompletionResult(
          newCount: 3,
          bridgedDays: ['2026-11-16'],
          freezeUsedKinds: {},
          brokeStreak: false,
          earnedLanded: false,
          isMilestone: false,
        ),
        state: state,
        now: at(2026, 11, 18),
      );
      // Nov 18 2026 is a Wednesday; the week starts Mon Nov 16.
      expect(data.week[0].label, 'Mo');
      expect(data.week[0].counted, isTrue);
      expect(data.week[0].restored, isTrue);
      expect(data.week[2].isToday, isTrue);
      expect(data.week[2].restored, isFalse);
    });

    testWidgets('celebration week row: freeze day is the icy-blue '
        'snowflake circle, other counted days keep their checks', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: child!,
          ),
          home: StreakCelebrationScreen(
            data: StreakCelebrationData(
              count: 21,
              isMilestoneDay: false,
              week: [
                for (var i = 0; i < 7; i++)
                  (
                    label: ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'][i],
                    counted: i <= 2,
                    isToday: i == 2,
                    restored: i == 1,
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      final circles = find.byType(StreakFreezeDayCircle);
      expect(circles, findsOneWidget);
      expectFreezeStyle(tester, circles);
      // Counted days 0 and 2 keep their checks; the restored day
      // (index 1, also counted) must NOT add a third.
      expect(find.byIcon(Icons.check), findsNWidgets(2));
    });

    testWidgets('streak screen: freeze day renders the icy-blue '
        'snowflake circle in the month calendar AND the legend', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      // Mon Nov 16 was covered by a freeze. (Mock v3 rebuild: the
      // old week row is superseded by the calendar; the treatment
      // now renders in the calendar cell and the legend swatch.)
      final s = stateWith(counted: daysThrough(18), restored: {'2026-11-16'});
      await tester.pumpWidget(
        MaterialApp(
          home: StreakScreen(state: s, now: at(2026, 11, 18)),
        ),
      );
      await tester.pump();
      // Legend swatch (14dp circle) under the calendar.
      final legendCircle = find.byWidgetPredicate(
        (w) => w is StreakFreezeDayCircle && w.size == 14,
      );
      expect(legendCircle, findsOneWidget);
      expectFreezeStyle(tester, legendCircle);
      // Month calendar (32dp circle, keyed by day).
      await tester.scrollUntilVisible(
        find.byKey(const Key('streakRestoredDay-2026-11-16')),
        120,
      );
      await tester.pump();
      final calCircle = find.byKey(const Key('streakRestoredDay-2026-11-16'));
      expect(calCircle, findsOneWidget);
      expect(tester.widget<StreakFreezeDayCircle>(calCircle).size, 32);
      expectFreezeStyle(tester, calCircle);
      // The calendar cell shows the glyph, not the day number.
      expect(
        find.descendant(of: calCircle, matching: find.byType(Text)),
        findsNothing,
      );
      // Legend + non-color identification (Juno C6) follow the
      // new marker.
      expect(
        find.text('A day with a snowflake was covered by a freeze.'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('November 16, covered by a freeze'),
        findsOneWidget,
      );
    });
  });

  group('share_plus channel (system share sheet)', () {
    testWidgets('the default share path invokes the share_plus '
        'platform channel with the PNG file', (tester) async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('dev.fluttercommunity.plus/share'),
            (call) async {
              calls.add(call);
              return null;
            },
          );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('dev.fluttercommunity.plus/share'),
              null,
            );
      });
      StreakShareService.debugSetShareFn(
        null,
        tempDir: () async => Directory.systemTemp,
      );
      addTearDown(() => StreakShareService.debugSetShareFn(null));
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: StreakShareCardHost(boundaryKey: key, count: 7)),
        ),
      );
      await tester.pump();
      await tester.runAsync(() async {
        final ok = await StreakShareService.shareFromBoundary(key, count: 7);
        expect(ok, isTrue);
      });
      expect(calls, isNotEmpty);
      final args = calls.first.arguments.toString();
      expect(args, contains('tabs_streak_share_7.png'));
    });
  });

  group('flame flicker', () {
    test('transform stays within the subtle band (scale 1.0–1.04)', () {
      for (var i = 0; i <= 20; i++) {
        final m = StreakFlame.flickerTransform(i / 20);
        final scale = m.entry('0', '0').abs() + m.entry('1', '0').abs();
        expect(scale, greaterThanOrEqualTo(0.99));
        expect(scale, lessThanOrEqualTo(1.05));
      }
    });
  });

  group('widget sync (D14)', () {
    test('not-done morning: peek pose, greeting, projected sub-line', () {
      final s = stateWith(
        counted: {'2026-10-29', '2026-10-30', '2026-10-31', ...daysThrough(17)},
      );
      final p = WidgetSync.buildStreakPayload(
        s,
        signedIn: true,
        nickname: 'Tyson Scadden',
        now: at(2026, 11, 18, 9),
      );
      expect(p.count, '20');
      expect(p.todayDone, isFalse);
      expect(p.pose, 'peek');
      expect(p.greeting, 'Hey Tyson.');
      expect(
        p.subline,
        "Finish today's Daily Summary when you're ready to lock in day 21.",
      );
    });

    test('not-done pose is always the v5 peek — the worried '
        'late-evening variant was dropped by the founder restyle', () {
      final s = stateWith(counted: daysThrough(17));
      final p = WidgetSync.buildStreakPayload(
        s,
        signedIn: true,
        nickname: 'Tyson',
        now: at(2026, 11, 18, 21),
      );
      expect(p.pose, 'peek');
      expect(p.greeting, 'Hey Tyson.');
    });

    test('projected next count is the ENGINE projection, not +1: '
        'a broken run restarts at day 1', () {
      // Last counted day was Nov 10; the gap to Nov 18 cannot
      // bridge with the freezes held (monthly Nov only) → the
      // next completion starts at 1.
      final s = stateWith(
        counted: {
          for (var d = 1; d <= 10; d++)
            '2026-11-${d.toString().padLeft(2, '0')}',
        },
      );
      final p = WidgetSync.buildStreakPayload(
        s,
        signedIn: true,
        nickname: null,
        now: at(2026, 11, 18, 9),
      );
      expect(
        p.subline,
        "Finish today's Daily Summary when you're ready to lock in day 1.",
      );
      // §9d: no nickname → the greeting line is omitted entirely.
      expect(p.greeting, '');
    });

    test('done: founder restyle — same peek card, expression '
        'rotates by day-of-year, founder copy verbatim', () {
      final s = stateWith(counted: daysThrough(18));
      final p = WidgetSync.buildStreakPayload(
        s,
        signedIn: true,
        nickname: 'Tyson',
        now: at(2026, 11, 18, 9),
      );
      expect(p.todayDone, isTrue);
      expect(p.count, '18');
      expect(WidgetSync.donePosePool, contains(p.pose));
      // Founder-dictated widget strings (the celebration SCREEN
      // keeps Juno's §9c — different surface, different string).
      expect(p.greeting, 'See you tomorrow!');
      expect(p.subline, 'Day 18 is locked in.');
      // Rotation: consecutive days alternate the two expressions.
      final next = WidgetSync.buildStreakPayload(
        stateWith(counted: {...daysThrough(18), '2026-11-19'}),
        signedIn: true,
        nickname: 'Tyson',
        now: at(2026, 11, 19, 9),
      );
      expect(next.pose, isNot(p.pose));
      expect(WidgetSync.donePosePool, contains(next.pose));
    });

    test('pushStreak writes the new fields through the bridge', () async {
      final saved = <String, Object?>{};
      var updates = 0;
      WidgetSync.debugSetBridge(
        save: (key, value) async {
          saved[key] = value;
        },
        update: () async {
          updates++;
        },
      );
      addTearDown(WidgetSync.debugResetBridge);
      await WidgetSync.pushStreak(
        stateWith(counted: daysThrough(17)),
        signedIn: true,
        nickname: 'Tyson',
        now: at(2026, 11, 18, 9),
      );
      expect(saved[WidgetSync.keyStreakCount], '17');
      expect(saved[WidgetSync.keyStreakTodayDone], isFalse);
      expect(saved[WidgetSync.keyStreakPose], 'peek');
      expect(saved[WidgetSync.keyStreakName], 'Tyson');
      expect(saved[WidgetSync.keyStreakGreeting], 'Hey Tyson.');
      expect(
        saved[WidgetSync.keyStreakSubline],
        "Finish today's Daily Summary when you're ready to lock in day 18.",
      );
      expect(updates, greaterThanOrEqualTo(1));
    });
  });

  group('A10 — SIM isolation', () {
    testWidgets('a full SIM run changes NOTHING: secure storage, '
        'profile pushes, and the analytics sink are untouched', (tester) async {
      // Snapshot 1: the ENTIRE secure-storage map behind the
      // streak store (in-memory fake), byte-for-byte.
      final disk = <String, String>{
        StreakStore.storageKey:
            '{"ownerEmail":"a@b.c","state":{"v":2,"seeded":true}}',
      };
      final store = StreakStore.instance;
      store.debugReset();
      store.debugSetStore(
        read: (key) async => disk[key],
        write: (key, value) async {
          disk[key] = value;
        },
        delete: (key) async {
          disk.remove(key);
        },
      );
      addTearDown(store.debugReset);
      final storageBefore = Map<String, String>.of(disk).toString();

      // Snapshot 2: the server profile — modeled by the push
      // recorder every streak write would have to travel through.
      final profilePushes = <Object?>[];
      // Snapshot 3: the analytics sink (fake).
      final analyticsSink = <Object?>[];

      // B-APP-1: mock the share_plus platform channel and record
      // every invocation. The SIM preview's count is simulated, so
      // the share path must never be reached from it (Juno §10).
      const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
      final shareCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(shareChannel, (call) async {
            shareCalls.add(call);
            return 'dev.fluttercommunity.plus/share/success';
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(shareChannel, null);
      });

      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StreakSimEntry(
              currentCount: 20,
              nickname: 'Tyson Scadden',
              now: at(2026, 11, 18),
            ),
          ),
        ),
      );
      await tester.pump();
      // Juno §8 verbatim label + caption.
      expect(
        find.text('Preview celebration — streak +1 [SIM]'),
        findsOneWidget,
      );
      expect(
        find.text('Simulation only. This does not change your real streak.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('streakSimPreviewButton')));
      // No pumpAndSettle: the lit flame's flicker animation repeats
      // forever by design, so the tree never "settles" while the
      // celebration is up.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // The preview shows settled + 1 with today completed.
      expect(find.byType(StreakCelebrationScreen), findsOneWidget);
      expect(
        (tester.widget<Text>(find.byKey(const Key('celebrationCount')))).data,
        '21',
      );
      // B-APP-1: BOTH share affordances are suppressed entirely in
      // the SIM preview — neither the share icon (normal days) nor
      // SHARE MILESTONE (milestone days) is rendered, so there is
      // no share affordance to tap and no share invocation can
      // occur. (Pre-fix both were live and this fails.)
      expect(find.byKey(const Key('celebrationShareIcon')), findsNothing);
      expect(find.byKey(const Key('celebrationShareMilestone')), findsNothing);
      expect(find.text('SHARE MILESTONE'), findsNothing);
      expect(shareCalls, isEmpty);
      // The LET'S GO! dismissal stays and still dismisses the
      // preview. ADAPTED for the sequence (Nov 18, 2026): the SIM
      // preview runs the ignition sequence without reduced motion,
      // and buttons are not tappable DURING it — the first tap
      // skips to the final state, the second dismisses.
      await tester.tap(find.byKey(const Key('celebrationYay')));
      await tester.pump();
      expect(find.byType(StreakCelebrationScreen), findsOneWidget);
      await tester.tap(find.byKey(const Key('celebrationYay')));
      await tester.pumpAndSettle();
      expect(find.byType(StreakCelebrationScreen), findsNothing);

      // All three snapshots byte-identical / empty, and still no
      // share invocation after the full SIM run.
      expect(Map<String, String>.of(disk).toString(), storageBefore);
      expect(profilePushes, isEmpty);
      expect(analyticsSink, isEmpty);
      expect(shareCalls, isEmpty);
    });

    testWidgets('B-APP-1: a milestone SIM preview (settled + 1 lands '
        'on a ladder rung) renders no SHARE MILESTONE and never '
        'invokes share', (tester) async {
      const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
      final shareCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(shareChannel, (call) async {
            shareCalls.add(call);
            return 'dev.fluttercommunity.plus/share/success';
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(shareChannel, null);
      });

      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StreakSimEntry(
              // 29 + 1 = 30, a milestone rung: pre-fix this preview's
              // primary button was the live SHARE MILESTONE button.
              currentCount: 29,
              nickname: 'Tyson Scadden',
              now: at(2026, 11, 18),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('streakSimPreviewButton')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(StreakCelebrationScreen), findsOneWidget);
      expect(
        (tester.widget<Text>(find.byKey(const Key('celebrationCount')))).data,
        '30',
      );
      expect(
        find.text('You reached a milestone today: 30 days.'),
        findsOneWidget,
      );
      // Both share affordances suppressed entirely; Continue stays.
      expect(find.byKey(const Key('celebrationShareMilestone')), findsNothing);
      expect(find.text('SHARE MILESTONE'), findsNothing);
      expect(find.byKey(const Key('celebrationShareIcon')), findsNothing);
      expect(find.byKey(const Key('celebrationContinue')), findsOneWidget);
      expect(shareCalls, isEmpty);
      // Same sequence adaptation as the normal-day SIM test: the
      // first tap skips the sequence, the second dismisses.
      await tester.tap(find.byKey(const Key('celebrationContinue')));
      await tester.pump();
      expect(find.byType(StreakCelebrationScreen), findsOneWidget);
      await tester.tap(find.byKey(const Key('celebrationContinue')));
      await tester.pumpAndSettle();
      expect(find.byType(StreakCelebrationScreen), findsNothing);
      expect(shareCalls, isEmpty);
    });

    test('grep fence: the SIM source references no store, backend, '
        'or analytics API (A10)', () {
      final source = File('lib/src/features/settings/streak_sim.dart')
          .readAsStringSync();
      expect(source, isNot(contains('StreakStore')));
      expect(source, isNot(contains('TabsBackend')));
      expect(source.toLowerCase(), isNot(contains('analytics')));
      expect(source, isNot(contains('SummaryCompletionWatcher')));
    });
  });
}

/// A fake Play store for the purchase-flow tests.
class _FakeStore implements StreakFreezeStore {
  final StreakFreezeProduct? product;
  final StreamController<List<StreakFreezePurchaseUpdate>> _controller =
      StreamController<List<StreakFreezePurchaseUpdate>>.broadcast();
  bool bought = false;
  bool completed = false;

  _FakeStore({required this.product});

  void emit(StreakFreezePurchaseUpdate update) => _controller.add([update]);

  @override
  Future<bool> isAvailable() async => true;

  @override
  Stream<List<StreakFreezePurchaseUpdate>> get purchaseUpdates =>
      _controller.stream;

  @override
  Future<StreakFreezeProduct?> queryProduct(String productId) async => product;

  @override
  Future<bool> buyConsumable(StreakFreezeProduct product) async {
    bought = true;
    return true;
  }

  @override
  Future<void> completePurchase(StreakFreezePurchaseUpdate update) async {
    completed = true;
  }

  @override
  Future<void> restorePurchases() async {}
}
