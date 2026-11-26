import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tabs_lab/src/data/chest_service.dart';
import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/features/home/chest_drop_presenter.dart';
import 'package:tabs_lab/src/features/home/chest_open_flow.dart';
import 'package:tabs_lab/src/features/settings/chest_sim.dart';

/// Drive the open flow from entry to the reward card, mirroring
/// the stepped-pump sequence in chests_test.dart (the repeating
/// idle clock means the tree never "settles" on its own).
Future<void> driveOpenFlowToReveal(WidgetTester tester) async {
  await tester.pump(); // the opener future resolves -> chances
  await tester.pump(const Duration(milliseconds: 300));
  expect(find.byKey(const Key('chestTierLabel')), findsOneWidget);
  // Tap 1.
  await tester.tap(find.byKey(const Key('chestOpenStage')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  // Tap 2.
  await tester.tap(find.byKey(const Key('chestOpenStage')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  // Tap 3: after the last orbit + fade + beat, "Tap to open!".
  await tester.tap(find.byKey(const Key('chestOpenStage')));
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 400));
  }
  expect(find.text('Tap to open!'), findsOneWidget);
  // Open tap -> squash/gold sequence -> reward card.
  await tester.tap(find.byKey(const Key('chestOpenStage')));
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  expect(find.byKey(const Key('chestContinue')), findsOneWidget);
}

Future<void> pumpPanel(WidgetTester tester, {int balance = 100}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ChestSimEntry(initialBalance: balance),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Counts backend reach attempts at the dart:io layer: any real
/// backend client construction or request in the process must
/// pass through here (the backend's HTTP client is built on
/// dart:io). The isolation test snapshots the counters after
/// setup and asserts the simulated runs move them by zero.
class _BackendTripwire {
  int clientCreations = 0;
  int requests = 0;
}

class _TripwireOverrides extends HttpOverrides {
  final _BackendTripwire tripwire;
  _TripwireOverrides(this.tripwire);

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    tripwire.clientCreations++;
    return _TripwireClient(tripwire);
  }
}

class _TripwireClient extends Fake implements HttpClient {
  final _BackendTripwire tripwire;
  _TripwireClient(this.tripwire);

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) {
    tripwire.requests++;
    throw StateError('backend call attempted during a simulated run');
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    tripwire.requests++;
    throw StateError('backend call attempted during a simulated run');
  }
}

void main() {
  group('ChestSimEntry.buildSimResult — the script builder', () {
    ChestOpenResult build(
      ChestTier tier,
      List<bool> taps, {
      int balance = 100,
    }) => ChestSimEntry.buildSimResult(
      startTier: tier,
      tapUpgrades: taps,
      simBalance: balance,
    );

    test('no upgrade: Daily stays Daily, pays 10', () {
      final r = build(ChestTier.daily, [false, false, false]);
      expect(r.tapOutcomes, [false, false, false]);
      expect(r.finalTier, ChestTier.daily);
      expect(r.gemsGranted, 10);
      expect(r.newBalance, 110);
    });

    test('upgrade on tap 1: Daily -> Streak, pays 25', () {
      final r = build(ChestTier.daily, [true, false, false]);
      expect(r.finalTier, ChestTier.streak);
      expect(r.gemsGranted, 25);
      expect(r.newBalance, 125);
    });

    test('upgrade on tap 2: Daily -> Streak, pays 25', () {
      final r = build(ChestTier.daily, [false, true, false]);
      expect(r.finalTier, ChestTier.streak);
      expect(r.gemsGranted, 25);
    });

    test('upgrade on tap 3: Daily -> Streak, pays 25', () {
      final r = build(ChestTier.daily, [false, false, true]);
      expect(r.finalTier, ChestTier.streak);
      expect(r.gemsGranted, 25);
    });

    test('Daily double upgrade reaches MEGA and pays 100', () {
      expect(
        build(ChestTier.daily, [true, true, false]).finalTier,
        ChestTier.mega,
      );
      expect(
        build(ChestTier.daily, [false, true, true]).finalTier,
        ChestTier.mega,
      );
      final r = build(ChestTier.daily, [true, true, true], balance: 445);
      expect(r.finalTier, ChestTier.mega);
      expect(r.gemsGranted, 100);
      expect(r.newBalance, 545);
    });

    test('Streak: no upgrade pays 25, one upgrade pays 100', () {
      expect(build(ChestTier.streak, [false, false, false]).gemsGranted, 25);
      final r = build(ChestTier.streak, [true, false, false]);
      expect(r.finalTier, ChestTier.mega);
      expect(r.gemsGranted, 100);
      // A second true cannot push past MEGA.
      expect(
        build(ChestTier.streak, [true, true, true]).finalTier,
        ChestTier.mega,
      );
    });

    test('MEGA is terminal: no toggle pattern changes it', () {
      for (final taps in [
        [false, false, false],
        [true, false, false],
        [true, true, true],
      ]) {
        final r = build(ChestTier.mega, taps, balance: 7);
        expect(r.finalTier, ChestTier.mega);
        expect(r.gemsGranted, 100);
        expect(r.newBalance, 107);
      }
    });

    test('a short toggle list pads with false', () {
      final r = build(ChestTier.daily, [true]);
      expect(r.tapOutcomes, [true, false, false]);
      expect(r.finalTier, ChestTier.streak);
    });
  });

  group('grep fence (A10)', () {
    test('chest_sim.dart references no backend, service, balance '
        'adoption, persistence, or reporting API', () {
      final source = File(
        'lib/src/features/settings/chest_sim.dart',
      ).readAsStringSync();
      expect(source, isNot(contains('TabsBackend')));
      expect(source, isNot(contains('ChestService')));
      expect(source, isNot(contains('GemService')));
      expect(source, isNot(contains('adoptServerBalance')));
      expect(source, isNot(contains('openChestRaw')));
      expect(source, isNot(contains('/api/chests')));
      expect(source, isNot(contains('FlutterSecureStorage')));
      expect(source, isNot(contains('ChestDropService')));
      expect(source, isNot(contains('ChestDropPresenter')));
      expect(source.toLowerCase(), isNot(contains('analytics')));
      expect(source.toLowerCase(), isNot(contains('metrics')));
      // The shipped-binary marker lives in this file.
      expect(source, contains('Chest popup test'));
    });
  });

  group('Chest popup test panel', () {
    testWidgets('renders Juno-ruled strings and defaults', (tester) async {
      await pumpPanel(tester, balance: 100);
      expect(find.text('Chest popup test'), findsOneWidget);
      expect(
        find.text('Simulated. Nothing here touches your real chests or gems.'),
        findsOneWidget,
      );
      expect(find.text('Tier'), findsOneWidget);
      expect(find.text('Daily'), findsOneWidget);
      expect(find.text('Streak'), findsOneWidget);
      expect(find.text('MEGA'), findsOneWidget);
      expect(find.text('Upgrade on tap 1'), findsOneWidget);
      expect(find.text('Upgrade on tap 2'), findsOneWidget);
      expect(find.text('Upgrade on tap 3'), findsOneWidget);
      expect(find.text('Simulated balance: 100 gems'), findsOneWidget);
      expect(find.text('Play chest popup'), findsOneWidget);
      expect(find.text('Preview drop prompt'), findsOneWidget);
      // The MEGA helper shows only for MEGA.
      expect(find.text("MEGA can't upgrade."), findsNothing);
      // No chance language anywhere in the panel (Juno ruling).
      expect(find.textContaining('chance'), findsNothing);
      expect(find.textContaining('random'), findsNothing);
    });

    testWidgets('MEGA disables the upgrade toggles and shows the '
        'helper; leaving MEGA re-enables them', (tester) async {
      await pumpPanel(tester);
      Switch tile(int i) =>
          tester.widget<Switch>(find.byKey(Key('chestSimUpgrade$i')));
      expect(tile(1).onChanged, isNotNull);
      await tester.tap(find.byKey(const Key('chestSimTier-mega')));
      await tester.pump();
      expect(find.text("MEGA can't upgrade."), findsOneWidget);
      expect(tile(1).onChanged, isNull);
      expect(tile(2).onChanged, isNull);
      expect(tile(3).onChanged, isNull);
      await tester.tap(find.byKey(const Key('chestSimTier-daily')));
      await tester.pump();
      expect(find.text("MEGA can't upgrade."), findsNothing);
      expect(tile(1).onChanged, isNotNull);
    });

    testWidgets('toggles flip their script setters', (tester) async {
      await pumpPanel(tester);
      await tester.tap(find.byKey(const Key('chestSimUpgrade2')));
      await tester.pump();
      final tile = tester.widget<Switch>(
        find.byKey(const Key('chestSimUpgrade2')),
      );
      expect(tile.value, isTrue);
    });

    testWidgets('Play runs the flow and the reward lands on the '
        'SIMULATED balance', (tester) async {
      await pumpPanel(tester, balance: 100);
      await tester.tap(find.byKey(const Key('chestSimPlayButton')));
      await driveOpenFlowToReveal(tester);
      // Daily, no upgrades scripted: +10, counter lands on 110.
      expect(find.text('+10 gems'), findsOneWidget);
      expect(
        (tester.widget<Text>(find.byKey(const Key('chestRewardBalance'))))
            .data,
        '110',
      );
      await tester.tap(find.byKey(const Key('chestContinue')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(ChestOpenScreen), findsNothing);
      expect(find.text('Simulated balance: 110 gems'), findsOneWidget);
    });

    testWidgets('Play with Upgrade on tap 1 upgrades the stage '
        'label and pays the Streak payout', (tester) async {
      await pumpPanel(tester, balance: 100);
      await tester.tap(find.byKey(const Key('chestSimUpgrade1')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('chestSimPlayButton')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        (tester.widget<Text>(find.byKey(const Key('chestTierLabel')))).data,
        'DAILY',
      );
      await tester.tap(find.byKey(const Key('chestOpenStage')));
      await tester.pump();
      expect(
        (tester.widget<Text>(find.byKey(const Key('chestTierLabel')))).data,
        'STREAK',
      );
      // Finish the run.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const Key('chestOpenStage')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const Key('chestOpenStage')));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 400));
      }
      await tester.tap(find.byKey(const Key('chestOpenStage')));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(find.text('+25 gems'), findsOneWidget);
      await tester.tap(find.byKey(const Key('chestContinue')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Simulated balance: 125 gems'), findsOneWidget);
    });
  });

  group('Drop prompt preview', () {
    testWidgets('prompt shows for the chosen tier; Later dismisses '
        'and no flow opens', (tester) async {
      await pumpPanel(tester);
      await tester.tap(find.byKey(const Key('chestSimTier-streak')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('chestSimDropPreviewButton')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ChestDropPrompt), findsOneWidget);
      expect(find.text('You got a chest!'), findsOneWidget);
      expect(
        find.text('A Streak chest dropped for finishing today.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('chestDropLater')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ChestDropPrompt), findsNothing);
      expect(find.byType(ChestOpenScreen), findsNothing);
    });

    testWidgets('Open now chains into the simulated open flow', (
      tester,
    ) async {
      await pumpPanel(tester);
      await tester.tap(find.byKey(const Key('chestSimDropPreviewButton')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ChestDropPrompt), findsOneWidget);
      await tester.tap(find.byKey(const Key('chestDropOpenNow')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ChestDropPrompt), findsNothing);
      expect(find.byType(ChestOpenScreen), findsOneWidget);
      expect(find.text('Tap! Tap!'), findsOneWidget);
      // Leave the flow cleanly.
      await tester.tap(find.byKey(const Key('chestOpenClose')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.byType(ChestOpenScreen), findsNothing);
    });
  });

  group('The seam (Option B)', () {
    testWidgets('an injected opener + sink run the flow while the '
        'REAL gem balance is never adopted into', (tester) async {
      // The trap this seam exists to avoid: the fabricated result
      // carries newBalance 9999 — if the screen's balance wiring
      // were the production default, the real balance would jump
      // to 9999. With the sink injected it must stay at 700.
      final gemDisk = <String, String>{};
      final gems = GemService.instance;
      gems.debugReset();
      gems.debugSetStore(
        read: (key) async => gemDisk[key],
        write: (key, value) async => gemDisk[key] = value,
        delete: (key) async => gemDisk.remove(key),
      );
      addTearDown(gems.debugReset);
      gems.adoptServerBalance(700);
      await tester.pump();
      await tester.pump();
      expect(gems.balance, 700);

      var openerCalls = 0;
      final openedIds = <String>[];
      final sink = <int>[];
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: ChestOpenScreen(
            chest: const ChestItem(id: 'seam-test-id', tier: ChestTier.daily),
            opener: (id) async {
              openerCalls++;
              openedIds.add(id);
              return const ChestOpenResult(
                tapOutcomes: [true, true, true],
                finalTier: ChestTier.mega,
                gemsGranted: 100,
                newBalance: 9999,
              );
            },
            onBalance: sink.add,
          ),
        ),
      );
      await driveOpenFlowToReveal(tester);
      expect(openerCalls, 1);
      expect(openedIds, ['seam-test-id']);
      expect(sink, [9999]);
      expect(find.text('+100 gems'), findsOneWidget);
      expect(
        (tester.widget<Text>(find.byKey(const Key('chestRewardBalance'))))
            .data,
        '9999',
      );
      expect(gems.balance, 700, reason: 'the real balance never moved');
      await tester.tap(find.byKey(const Key('chestContinue')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(gems.balance, 700);
    });
  });

  group('Isolation (A10-style)', () {
    testWidgets('a FULL simulated run — open flow to the reward '
        'card, plus a drop-preview run — changes NOTHING: zero '
        'backend calls, zero storage writes, real gem balance '
        'and real chest inventory untouched', (tester) async {
      // Instrument every surface a non-hermetic path could reach.
      final tripwire = _BackendTripwire();
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = _TripwireOverrides(tripwire);
      addTearDown(() => HttpOverrides.global = previousOverrides);

      const storageChannel = MethodChannel(
        'plugins.it_nom.flutter_secure_storage',
      );
      final storageCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storageChannel, (call) async {
            storageCalls.add(call);
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(storageChannel, null);
      });

      // The real gem balance, backed by an in-memory disk (the
      // GemService test seam) so its persistence is snapshot-able.
      final gemDisk = <String, String>{};
      final gems = GemService.instance;
      gems.debugReset();
      gems.debugSetStore(
        read: (key) async => gemDisk[key],
        write: (key, value) async => gemDisk[key] = value,
        delete: (key) async => gemDisk.remove(key),
      );
      addTearDown(gems.debugReset);
      gems.adoptServerBalance(500);
      await tester.pump();
      await tester.pump();
      expect(gems.balance, 500);

      // The real chest inventory singleton.
      final chests = ChestService.instance;
      chests.debugReset();
      addTearDown(chests.debugReset);

      // ── Snapshots (after setup, before any simulated run) ──
      final gemDiskBefore = Map<String, String>.of(gemDisk).toString();
      final gemBalanceBefore = gems.balance;
      final inventoryBefore = chests.inventory.length;
      final inventoryLoadedBefore = chests.loaded;
      final storageCallsBefore = storageCalls.length;
      final clientsBefore = tripwire.clientCreations;
      final requestsBefore = tripwire.requests;

      // ── Run 1: Play the open flow to the reward card ──
      await pumpPanel(tester, balance: 500);
      await tester.tap(find.byKey(const Key('chestSimPlayButton')));
      await driveOpenFlowToReveal(tester);
      expect(find.text('+10 gems'), findsOneWidget);
      expect(
        (tester.widget<Text>(find.byKey(const Key('chestRewardBalance'))))
            .data,
        '510',
        reason: 'the reward counter shows the SIMULATED balance',
      );
      await tester.tap(find.byKey(const Key('chestContinue')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Simulated balance: 510 gems'), findsOneWidget);

      // ── Run 2: drop preview -> Open now -> reward card ──
      await tester.tap(find.byKey(const Key('chestSimDropPreviewButton')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ChestDropPrompt), findsOneWidget);
      await tester.tap(find.byKey(const Key('chestDropOpenNow')));
      await driveOpenFlowToReveal(tester);
      await tester.tap(find.byKey(const Key('chestContinue')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Simulated balance: 520 gems'), findsOneWidget);

      // ── Every snapshot unchanged ──
      expect(
        Map<String, String>.of(gemDisk).toString(),
        gemDiskBefore,
        reason: 'secure storage / persisted profile records untouched',
      );
      expect(gems.balance, gemBalanceBefore);
      expect(gems.balance, 500);
      expect(chests.inventory.length, inventoryBefore);
      expect(chests.loaded, inventoryLoadedBefore);
      expect(
        storageCalls.length,
        storageCallsBefore,
        reason: 'zero secure-storage channel calls from the runs',
      );
      expect(
        tripwire.clientCreations,
        clientsBefore,
        reason: 'zero backend clients constructed by the runs',
      );
      expect(
        tripwire.requests,
        requestsBefore,
        reason: 'zero backend requests from the runs',
      );
    });
  });
}
