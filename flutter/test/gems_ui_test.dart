import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/streak_purchase.dart';
import 'package:tabs_lab/src/features/home/gems_sheet.dart';
import 'package:tabs_lab/src/features/home/streak_celebration_screen.dart';
import 'package:tabs_lab/src/features/home/streak_screen.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart';
import 'package:tabs_lab/src/features/settings/streak_sim.dart';

/// Opens the Gems sheet the way Home does, with the test's fake
/// service/state and a no-op settled-record push.
Future<void> unawaitedShowGemsSheet(
  BuildContext context, {
  required GemService gems,
  required StreakState state,
}) => showGemsSheet(
  context: context,
  gemService: gems,
  streakState: state,
  streakPush: (current, best, json, {int? purchasedFreezes}) async => true,
);

/// Gems UI (Nov 19, 2026) — Home pill rendering/widening, the
/// streak screen's buy-with-gems surface, the celebration earn
/// lines, and the SIM/dev fence.
///
/// Added scope #6 (Nov 20, 2026): the Juno §4 explainer MOVED off
/// the streak screen into the Gems sheet (opened by tapping the
/// Home gem pill) — the streak-screen tests below now pin its
/// ABSENCE there while the buy-with-gems row stays, and the new
/// Gems sheet group pins the sheet's balance + explainer (lines
/// 1–4 verbatim, line 5 = the coordinator-approved Proposal A) +
/// buy action.
void main() {
  DateTime at(int y, int m, int d) => DateTime(y, m, d, 12);

  GemService fakeGems({
    required int? balance,
    GemSpendResult Function()? onSpend,
    List<String>? spendIds,
  }) {
    final disk = <String, String>{};
    final s = GemService(
      grant: (_) async => (statusCode: null, body: null),
      spend: (id) async {
        spendIds?.add(id);
        final r =
            onSpend?.call() ??
            const GemSpendResult(status: GemSpendStatus.failed);
        return (
          statusCode: switch (r.status) {
            GemSpendStatus.success => 200,
            GemSpendStatus.replay => 200,
            GemSpendStatus.insufficient => 409,
            GemSpendStatus.capReached => 409,
            GemSpendStatus.failed => null,
          },
          body: {
            if (r.balance != null) 'gemBalance': r.balance,
            if (r.purchasedFreezes != null)
              'purchasedFreezes': r.purchasedFreezes,
            if (r.status == GemSpendStatus.replay) 'alreadyGranted': true,
            if (r.status == GemSpendStatus.insufficient)
              'error': 'insufficient_gems',
            if (r.status == GemSpendStatus.capReached)
              'error': 'freeze_cap_reached',
          },
        );
      },
      pullBalance: () async => balance,
    );
    s.debugSetStore(
      read: (k) async => disk[k],
      write: (k, v) async => disk[k] = v,
      delete: (k) async => disk.remove(k),
    );
    return s;
  }

  // ── Home gem pill ────────────────────────────────────────────

  group('Home gem pill', () {
    Future<void> pumpStack(WidgetTester tester, int? gems) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: HomeStreakStack(
                currentStreak: 7,
                animateCountUps: false,
                gemBalance: gems,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('renders counts 0 / 10 / 500 / 1000 as plain digits', (
      tester,
    ) async {
      for (final count in [0, 10, 500, 1000]) {
        await pumpStack(tester, count);
        expect(find.byKey(const Key('homeGemPill')), findsOneWidget);
        expect(find.byKey(const Key('homeGemPillIcon')), findsOneWidget);
        final text = tester.widget<Text>(
          find.byKey(const Key('homeGemPillCount')),
        );
        expect(
          text.data,
          '$count',
          reason: 'plain digits, no thousands separator',
        );
        expect(
          text.style!.color,
          kGemCountColor,
          reason: 'lavender #B9AFFF per the approved mock',
        );
      }
    });

    testWidgets('the pill widens as the count grows', (tester) async {
      final widths = <double>[];
      for (final count in [0, 10, 500, 1000]) {
        await pumpStack(tester, count);
        widths.add(tester.getSize(find.byKey(const Key('homeGemPill'))).width);
      }
      for (var i = 1; i < widths.length; i++) {
        expect(
          widths[i],
          greaterThan(widths[i - 1]),
          reason: 'widths $widths must strictly widen',
        );
      }
    });

    testWidgets('accessibility label is Juno §1', (tester) async {
      await pumpStack(tester, 0);
      expect(find.bySemanticsLabel('0 gems'), findsOneWidget);
      await pumpStack(tester, 1);
      expect(find.bySemanticsLabel('1 gem'), findsOneWidget);
      await pumpStack(tester, 1000);
      expect(find.bySemanticsLabel('1000 gems'), findsOneWidget);
    });

    testWidgets('no server balance yet → no pill (never a guess)', (
      tester,
    ) async {
      await pumpStack(tester, null);
      expect(find.byKey(const Key('homeGemPill')), findsNothing);
      // The streak pills are untouched.
      expect(find.byKey(const Key('homeStreakPills')), findsOneWidget);
    });
  });

  // ── Streak screen: buy-with-gems (explainer moved, scope #6) ─

  group('Streak screen gem section', () {
    StreakState baseState({
      int earned = 0,
      int purchased = 0,
      bool monthlyUsed = false,
    }) {
      final today = at(2026, 11, 19);
      var s = streakSeedForAdoption(
        current: 5,
        best: 12,
        now: today,
        purchasedFreezes: purchased,
      );
      s = s.copyWith(
        earnedFreezes: earned,
        consumedSaveMonths: monthlyUsed ? {'2026-11'} : const {},
      );
      return s;
    }

    Future<void> pumpScreen(
      WidgetTester tester,
      StreakState s,
      GemService gems,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: StreakScreen(
            state: s,
            now: at(2026, 11, 19),
            gemService: gems,
            streakPush: (current, best, json, {int? purchasedFreezes}) async =>
                true,
            purchaseService: StreakFreezePurchaseService(
              store: _FakePurchaseStore(),
              verify: ({
                required productId,
                required purchaseToken,
                required orderId,
              }) async => null,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    Future<void> scrollToGemSection(WidgetTester tester) async {
      await tester.scrollUntilVisible(
        find.byKey(const Key('gemBuySection')),
        120,
      );
      await tester.pump();
    }

    testWidgets('scope #6: NO explainer on the streak screen, but '
        'the gem-buy row still renders', (tester) async {
      await pumpScreen(tester, baseState(), fakeGems(balance: 35));
      await scrollToGemSection(tester);
      // The About-gems explainer is gone from this screen — no
      // heading, no lines, no moved-copy text anywhere.
      expect(find.byKey(const Key('gemExplainerHeading')), findsNothing);
      for (var i = 0; i < 5; i++) {
        expect(find.byKey(Key('gemExplainerLine$i')), findsNothing);
      }
      expect(find.text('About gems'), findsNothing);
      expect(
        find.text(
          "Gems are earned in Tabs. You can't buy them, and "
          'they have no cash value.',
        ),
        findsNothing,
      );
      // The buy-with-gems row STAYS exactly where it was.
      expect(find.byKey(const Key('gemBuySection')), findsOneWidget);
      expect(find.textContaining('· Gems: 35'), findsOneWidget);
      expect(find.byKey(const Key('gemBuyButton')), findsOneWidget);
      expect(find.text('100 GEMS'), findsOneWidget);
    });

    testWidgets('insufficient balance: balance line, DISABLED '
        'button with the same label, §2d line', (tester) async {
      await pumpScreen(tester, baseState(), fakeGems(balance: 35));
      await scrollToGemSection(tester);
      expect(find.textContaining('· Gems: 35'), findsOneWidget);
      final button = tester.widget<ElevatedButton>(
        find.byKey(const Key('gemBuyButton')),
      );
      expect(button.onPressed, isNull, reason: 'disabled under 100');
      expect(find.text('100 GEMS'), findsOneWidget);
      expect(
        find.text(
          'you need 65 more gems for a freeze — you earn 5 gems '
          'each time you finish your daily summary.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('singular balance and needed forms', (tester) async {
      await pumpScreen(tester, baseState(), fakeGems(balance: 1));
      await scrollToGemSection(tester);
      expect(find.textContaining('· Gems: 1'), findsOneWidget);
      expect(
        find.text(
          'you need 99 more gems for a freeze — you earn 5 gems '
          'each time you finish your daily summary.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('spend success: §2c fires only on the verified '
        'spend, with the post-spend balance', (tester) async {
      final gems = fakeGems(
        balance: 150,
        onSpend: () => const GemSpendResult(
          status: GemSpendStatus.success,
          balance: 50,
          purchasedFreezes: 1,
        ),
      );
      await pumpScreen(tester, baseState(), gems);
      await scrollToGemSection(tester);
      expect(find.textContaining('· Gems: 150'), findsOneWidget);
      final button = tester.widget<ElevatedButton>(
        find.byKey(const Key('gemBuyButton')),
      );
      expect(button.onPressed, isNotNull);
      await tester.tap(find.byKey(const Key('gemBuyButton')));
      // The spend chain awaits the pre-spend profile push (a real
      // TabsBackend round-trip through the test binding's async
      // channels) before the fake spend resolves — pump it out.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('freeze added'), findsOneWidget);
      expect(
        find.text(
          "you've got a freeze now. it covers one missed day. "
          'you have 50 gems left.',
        ),
        findsOneWidget,
      );
      // Gem-buy rule change (Nov 21, 2026): holding the freeze no
      // longer hides the buy rows — at 2 of 3 with a 50-gem
      // balance the button stays, DISABLED, with the §2d line.
      final afterButton = tester.widget<ElevatedButton>(
        find.byKey(const Key('gemBuyButton')),
      );
      expect(
        afterButton.onPressed,
        isNull,
        reason: 'visible but disabled under 100 after the spend',
      );
      expect(
        find.text(
          'you need 50 more gems for a freeze — you earn 5 gems '
          'each time you finish your daily summary.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('spend answered insufficient (balance moved): no '
        'success copy, refreshed balance, §2d state', (tester) async {
      final gems = fakeGems(
        balance: 150,
        onSpend: () => const GemSpendResult(
          status: GemSpendStatus.insufficient,
          balance: 40,
          purchasedFreezes: 0,
        ),
      );
      await pumpScreen(tester, baseState(), gems);
      await scrollToGemSection(tester);
      await tester.tap(find.byKey(const Key('gemBuyButton')));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('freeze added'), findsNothing);
      expect(find.textContaining('· Gems: 40'), findsOneWidget);
      expect(
        find.text(
          'you need 60 more gems for a freeze — you earn 5 gems '
          'each time you finish your daily summary.',
        ),
        findsOneWidget,
      );
      // No raw error code anywhere on the surface.
      expect(find.textContaining('insufficient_gems'), findsNothing);
    });

    testWidgets('spend answered with a no-grant 409 carrying a '
        'held count (the legacy purchased_already_held shape, '
        'which GemService now maps to capReached): the adopted '
        'state lands silently — no success copy, no raw error, '
        'and the buy rows re-derive under the new rule (2 of 3, '
        'balance ≥ 100 → still offered)', (tester) async {
      final gems = fakeGems(
        balance: 500,
        onSpend: () => const GemSpendResult(
          status: GemSpendStatus.capReached,
          balance: 500,
          purchasedFreezes: 1,
        ),
      );
      await pumpScreen(tester, baseState(), gems);
      await scrollToGemSection(tester);
      expect(find.textContaining('· Gems: 500'), findsOneWidget);
      await tester.tap(find.byKey(const Key('gemBuyButton')));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      // No §2c success copy, and no raw error code anywhere.
      expect(find.text('freeze added'), findsNothing);
      expect(find.textContaining('purchased_already_held'), findsNothing);
      // The 409's adopted held state IS the surface: 1 monthly +
      // 1 purchased-class = 2 of 3, so under the Nov 21, 2026
      // rule the buy stays visible and enabled.
      final button = tester.widget<ElevatedButton>(
        find.byKey(const Key('gemBuyButton')),
      );
      expect(button.onPressed, isNotNull);
      expect(find.byKey(const Key('streakBuyCaption')), findsOneWidget);
      expect(find.byKey(const Key('gemExplainerHeading')), findsNothing);
    });

    testWidgets('spend answered capReached (409): no success '
        'copy, no raw error, refusal not cached — the surface '
        're-derives from the adopted balance', (tester) async {
      final gems = fakeGems(
        balance: 500,
        onSpend: () => const GemSpendResult(
          status: GemSpendStatus.capReached,
          balance: 500,
          purchasedFreezes: 0,
        ),
      );
      await pumpScreen(tester, baseState(), gems);
      await scrollToGemSection(tester);
      await tester.tap(find.byKey(const Key('gemBuyButton')));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('freeze added'), findsNothing);
      expect(find.textContaining('freeze_cap_reached'), findsNothing);
      // The refusal is cached nowhere: after the one re-sync the
      // buy surface is live again from the adopted balance, so
      // the user can retry.
      expect(find.textContaining('· Gems: 500'), findsOneWidget);
      final button = tester.widget<ElevatedButton>(
        find.byKey(const Key('gemBuyButton')),
      );
      expect(button.onPressed, isNotNull);
      expect(find.byKey(const Key('gemExplainerHeading')), findsNothing);
    });

    testWidgets('gem-buy rule change: a held purchased freeze '
        '(1 of 3) with balance ≥ 100 — the gem buy is VISIBLE and '
        'ENABLED, while the \$0.99 affordance stays hidden behind '
        'its §1c already-held line', (tester) async {
      await pumpScreen(
        tester,
        baseState(purchased: 1, monthlyUsed: true),
        fakeGems(balance: 500),
      );
      await scrollToGemSection(tester);
      // The founder's exact state: 1 of 3, the one held freeze
      // being the purchased-class one.
      expect(
        find.textContaining('You have 1 of 3 Streak Freezes ready'),
        findsOneWidget,
      );
      expect(find.textContaining('· Gems: 500'), findsOneWidget);
      final button = tester.widget<ElevatedButton>(
        find.byKey(const Key('gemBuyButton')),
      );
      expect(
        button.onPressed,
        isNotNull,
        reason: 'gem buy enabled while a purchased freeze is held',
      );
      expect(find.text('100 GEMS'), findsOneWidget);
      // The $0.99 money buy keeps its own rule (unchanged): hidden
      // while a purchased freeze is held, §1c line in its place.
      expect(find.byKey(const Key('streakBuyButton')), findsNothing);
      expect(
        find.byKey(const Key('streakPurchaseAlreadyHeld')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('gemExplainerHeading')), findsNothing);
    });

    testWidgets('gem-buy rule change: held purchased freeze with '
        'balance < 100 — button present but DISABLED with the '
        '§2d shortfall line', (tester) async {
      await pumpScreen(
        tester,
        baseState(purchased: 1, monthlyUsed: true),
        fakeGems(balance: 35),
      );
      await scrollToGemSection(tester);
      expect(find.textContaining('· Gems: 35'), findsOneWidget);
      final button = tester.widget<ElevatedButton>(
        find.byKey(const Key('gemBuyButton')),
      );
      expect(button.onPressed, isNull, reason: 'disabled under 100');
      expect(
        find.text(
          'you need 65 more gems for a freeze — you earn 5 gems '
          'each time you finish your daily summary.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('buy rows hidden at cap (monthly + earned = 2/2)', (
      tester,
    ) async {
      await pumpScreen(tester, baseState(earned: 1), fakeGems(balance: 500));
      await scrollToGemSection(tester);
      expect(find.byKey(const Key('gemBuyButton')), findsNothing);
      expect(find.byKey(const Key('gemExplainerHeading')), findsNothing);
    });

    testWidgets('gem-buy rule change: at cap 3 of 3 (three '
        'purchased-class freezes held, monthly used) the gem buy '
        'is hidden', (tester) async {
      await pumpScreen(
        tester,
        baseState(purchased: 3, monthlyUsed: true),
        fakeGems(balance: 500),
      );
      await scrollToGemSection(tester);
      expect(
        find.textContaining('You have 3 of 3 Streak Freezes ready'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('gemBuyButton')), findsNothing);
      expect(find.byKey(const Key('gemBuyButton')), findsNothing);
    });
  });

  // ── Gems sheet (added scope #6) ──────────────────────────────

  group('Gems sheet (scope #6)', () {
    StreakState sheetState({int earned = 0, int purchased = 0}) {
      final today = at(2026, 11, 19);
      var s = streakSeedForAdoption(
        current: 5,
        best: 12,
        now: today,
        purchasedFreezes: purchased,
      );
      s = s.copyWith(earnedFreezes: earned);
      return s;
    }

    /// Pump a Home stack whose gem pill opens the sheet with the
    /// fake service + state (the production wiring shape), then tap
    /// the pill.
    Future<void> pumpHostAndTapPill(
      WidgetTester tester, {
      required GemService gems,
      required StreakState state,
      int pillBalance = 150,
    }) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: HomeStreakStack(
                  currentStreak: 5,
                  animateCountUps: false,
                  gemBalance: pillBalance,
                  onGemTap: () =>
                      unawaitedShowGemsSheet(context, gems: gems, state: state),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('homeGemPill')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('tapping the gem pill opens the sheet: title once, '
        'balance, explainer lines 1–4 verbatim + approved line 5', (
      tester,
    ) async {
      await pumpHostAndTapPill(
        tester,
        gems: fakeGems(balance: 150),
        state: sheetState(),
      );
      expect(find.byKey(const Key('gemsSheet')), findsOneWidget);
      // Title = the moved heading, used ONCE in the whole sheet.
      expect(find.text('About gems'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('gemsSheetTitle'))).data,
        'About gems',
      );
      // Balance — the server value, in the §3.1 wording.
      expect(find.text('You have 150 gems.'), findsOneWidget);
      // Explainer: lines 1–4 verbatim.
      const lines = [
        "Gems are earned in Tabs. You can't buy them, and they have no cash value.",
        'Finish your Daily Summary: +5 gems.',
        'Streak bonuses pay when you reach them: +25 gems at 7 days, +50 at 30 days, +100 at 100 days, and +100 at each 100 days after that.',
        'Perfect week: +20 gems when you finish your Daily Summary all 7 days of a Monday–Sunday week.',
      ];
      for (var i = 0; i < lines.length; i++) {
        expect(
          tester.widget<Text>(find.byKey(Key('gemsSheetExplainerLine$i'))).data,
          lines[i],
        );
      }
      // Line 5 = coordinator-approved Proposal A, exactly; the old
      // streak-screen line 5 never appears.
      expect(
        tester
            .widget<Text>(find.byKey(const Key('gemsSheetExplainerLine4')))
            .data,
        '100 gems buys one streak freeze.',
      );
      expect(
        find.text(
          '100 gems buys one streak freeze — the freeze on '
          'this screen.',
        ),
        findsNothing,
      );
    });

    testWidgets('buy-with-gems from the sheet succeeds at ≥100: '
        '§2c copy, service balance moves, buy control then stays '
        '— disabled under 100 with the §2d line (rule change)', (tester) async {
      final spendIds = <String>[];
      final gems = fakeGems(
        balance: 150,
        spendIds: spendIds,
        onSpend: () => const GemSpendResult(
          status: GemSpendStatus.success,
          balance: 50,
          purchasedFreezes: 1,
        ),
      );
      await pumpHostAndTapPill(tester, gems: gems, state: sheetState());
      final button = tester.widget<ElevatedButton>(
        find.byKey(const Key('gemsSheetBuyButton')),
      );
      expect(button.onPressed, isNotNull);
      expect(find.text('GET ONE MORE FREEZE · 100 GEMS'), findsOneWidget);
      await tester.tap(find.byKey(const Key('gemsSheetBuyButton')));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(spendIds, isNotEmpty, reason: 'the spend path ran');
      expect(find.text('freeze added'), findsOneWidget);
      expect(
        find.text(
          "you've got a freeze now. it covers one missed day. "
          'you have 50 gems left.',
        ),
        findsOneWidget,
      );
      // The shared service balance moved (the pill reads the same
      // service). Gem-buy rule change (Nov 21, 2026): the held
      // freeze no longer hides the buy control — at 2 of 3 with a
      // 50-gem balance it stays, DISABLED, with the §2d line. No
      // invented held string either way.
      expect(gems.balance, 50);
      expect(find.text('You have 50 gems.'), findsOneWidget);
      final afterButton = tester.widget<ElevatedButton>(
        find.byKey(const Key('gemsSheetBuyButton')),
      );
      expect(
        afterButton.onPressed,
        isNull,
        reason: 'visible but disabled under 100 after the spend',
      );
      expect(
        find.text(
          'you need 50 more gems for a freeze — you earn 5 gems '
          'each time you finish your daily summary.',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          "you've already got a freeze — it covers one "
          'missed day.',
        ),
        findsNothing,
      );
    });

    testWidgets('below 100: button present but DISABLED with the '
        '§2d line under it', (tester) async {
      await pumpHostAndTapPill(
        tester,
        gems: fakeGems(balance: 35),
        state: sheetState(),
        pillBalance: 35,
      );
      expect(find.text('You have 35 gems.'), findsOneWidget);
      final button = tester.widget<ElevatedButton>(
        find.byKey(const Key('gemsSheetBuyButton')),
      );
      expect(button.onPressed, isNull, reason: 'disabled under 100');
      expect(find.text('GET ONE MORE FREEZE · 100 GEMS'), findsOneWidget);
      expect(
        find.text(
          'you need 65 more gems for a freeze — you earn 5 gems '
          'each time you finish your daily summary.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('at-cap state: buy control ABSENT (no string '
        'invented), balance + explainer still render', (tester) async {
      await pumpHostAndTapPill(
        tester,
        gems: fakeGems(balance: 500),
        state: sheetState(earned: 1),
        pillBalance: 500,
      );
      expect(find.byKey(const Key('gemsSheetBuyButton')), findsNothing);
      expect(find.byKey(const Key('gemsSheetInsufficientLine')), findsNothing);
      expect(find.text('You have 500 gems.'), findsOneWidget);
      expect(find.text('About gems'), findsOneWidget);
      expect(
        find.text(
          "you've already got a freeze — it covers one "
          'missed day.',
        ),
        findsNothing,
      );
    });

    testWidgets('gem-buy rule change: held purchased freeze '
        '(1 held, 2 of 3 cover) with balance ≥ 100 — buy control '
        'PRESENT and ENABLED', (tester) async {
      await pumpHostAndTapPill(
        tester,
        gems: fakeGems(balance: 500),
        state: sheetState(purchased: 1),
        pillBalance: 500,
      );
      final button = tester.widget<ElevatedButton>(
        find.byKey(const Key('gemsSheetBuyButton')),
      );
      expect(
        button.onPressed,
        isNotNull,
        reason: 'gem buy enabled while a purchased freeze is held',
      );
      expect(find.text('You have 500 gems.'), findsOneWidget);
    });

    testWidgets('gem-buy rule change: held purchased freeze with '
        'balance < 100 — buy control present but DISABLED with '
        'the §2d line', (tester) async {
      await pumpHostAndTapPill(
        tester,
        gems: fakeGems(balance: 35),
        state: sheetState(purchased: 1),
        pillBalance: 35,
      );
      final button = tester.widget<ElevatedButton>(
        find.byKey(const Key('gemsSheetBuyButton')),
      );
      expect(button.onPressed, isNull, reason: 'disabled under 100');
      expect(
        find.text(
          'you need 65 more gems for a freeze — you earn 5 gems '
          'each time you finish your daily summary.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('gem-buy rule change: at cap 3 of 3 (monthly + '
        'earned + purchased-class) the buy control is ABSENT', (tester) async {
      await pumpHostAndTapPill(
        tester,
        gems: fakeGems(balance: 500),
        state: sheetState(earned: 1, purchased: 1),
        pillBalance: 500,
      );
      expect(find.byKey(const Key('gemsSheetBuyButton')), findsNothing);
      expect(find.byKey(const Key('gemsSheetInsufficientLine')), findsNothing);
      expect(find.text('You have 500 gems.'), findsOneWidget);
    });

    testWidgets('the Row layout gem pill is tappable too', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeStreakRow(
              currentStreak: 5,
              animateCountUps: false,
              gemBalance: 42,
              onGemTap: () => taps++,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('homeGemPill')), findsOneWidget);
      await tester.tap(find.byKey(const Key('homeGemPill')));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('streak pill tap does NOT open the sheet (separate '
        'targets)', (tester) async {
      var streakTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: HomeStreakStack(
                  currentStreak: 5,
                  animateCountUps: false,
                  gemBalance: 150,
                  onStreakTap: () => streakTaps++,
                  onGemTap: () => unawaitedShowGemsSheet(
                    context,
                    gems: fakeGems(balance: 150),
                    state: sheetState(),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('homeStreakPills')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(streakTaps, 1);
      expect(find.byKey(const Key('gemsSheet')), findsNothing);
    });
  });

  // ── Celebration earn lines ───────────────────────────────────

  group('Celebration gem lines', () {
    StreakCelebrationData data({List<String> gemLines = const []}) {
      return StreakCelebrationData(
        count: 7,
        previousCount: 6,
        isMilestoneDay: true,
        gemLines: gemLines,
        week: [
          for (var i = 0; i < 7; i++)
            (
              label: ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'][i],
              counted: i <= 3,
              isToday: i == 3,
              restored: false,
            ),
        ],
      );
    }

    Future<void> pumpCelebration(
      WidgetTester tester,
      StreakCelebrationData d,
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
          home: StreakCelebrationScreen(data: d, nickname: 'Tyson'),
        ),
      );
      await tester.pump();
    }

    testWidgets('granted lines render in Juno §3 order', (tester) async {
      await pumpCelebration(
        tester,
        data(
          gemLines: const [
            '+5 gems',
            '+25 gems — 7-day streak bonus',
            '+20 gems — perfect week bonus',
          ],
        ),
      );
      expect(find.byKey(const Key('celebrationGemLines')), findsOneWidget);
      expect(find.text('+5 gems'), findsOneWidget);
      expect(find.text('+25 gems — 7-day streak bonus'), findsOneWidget);
      expect(find.text('+20 gems — perfect week bonus'), findsOneWidget);
    });

    testWidgets('no lines when the day was already granted', (tester) async {
      await pumpCelebration(tester, data());
      expect(find.byKey(const Key('celebrationGemLines')), findsNothing);
      expect(find.text('+5 gems'), findsNothing);
    });
  });

  // ── SIM / dev fence ──────────────────────────────────────────

  group('SIM/dev fence', () {
    test('SIM preview data carries no gem lines — simulated '
        'completions never earn', () {
      final preview = StreakSimEntry.buildPreviewData(
        currentCount: 6,
        now: at(2026, 11, 19),
      );
      expect(preview.count, 7);
      expect(preview.gemLines, isEmpty);
    });

    test('the SIM and Restore sources never reference the gem '
        'grant/spend surface', () {
      for (final path in [
        'lib/src/features/settings/streak_sim.dart',
        'lib/src/features/settings/streak_restore.dart',
      ]) {
        final src = File(path).readAsStringSync();
        expect(src.contains('GemService'), isFalse, reason: path);
        expect(src.contains('grantGems'), isFalse, reason: path);
        expect(src.contains('spendGems'), isFalse, reason: path);
        expect(src.contains('/api/gems'), isFalse, reason: path);
        expect(src.contains('processCompletion'), isFalse, reason: path);
      }
    });
  });
}

class _FakePurchaseStore implements StreakFreezeStore {
  @override
  Future<bool> isAvailable() async => false;
  @override
  Stream<List<StreakFreezePurchaseUpdate>> get purchaseUpdates =>
      const Stream.empty();
  @override
  Future<StreakFreezeProduct?> queryProduct(String productId) async => null;
  @override
  Future<bool> buyConsumable(StreakFreezeProduct product) async => false;
  @override
  Future<void> completePurchase(StreakFreezePurchaseUpdate update) async {}
  @override
  Future<void> restorePurchases() async {}
}
