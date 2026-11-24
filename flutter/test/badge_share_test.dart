import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/badge_engine.dart';
import 'package:tabs_lab/src/data/badge_store.dart';
import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/features/badges/badge_share_card.dart';
import 'package:tabs_lab/src/features/badges/badge_strings.dart';
import 'package:tabs_lab/src/features/badges/badges_screen.dart';

/// Badge share pins (badge-share package; Juno JUNO-COPY.md
/// §§1–7): the card's ruled copy order with the rung standing
/// alone, the files-only share service (mirrors the streak share
/// tests), the unlock dialog's per-row Share buttons (per-rung
/// rows share their own rung; grouped rows share the highest
/// batch rung), and the detail view's labeled Share badge button
/// (earned + not blocked only, top rung only).
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

  BadgeGrant grant(String id, int rung, {bool paid = true}) => BadgeGrant(
        metric: BadgeMetrics.byId(id),
        rungIndex: rung,
        paid: paid,
        paidFresh: paid,
      );

  group('BadgeShareCard (Juno §§1–2)', () {
    Future<void> pumpCard(
      WidgetTester tester,
      BadgeMetric metric,
      int rungIndex,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: BadgeShareCardHost(
            boundaryKey: key,
            metric: metric,
            rungIndex: rungIndex,
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('Day streak Gold II: headline, name, rung ALONE, '
        'shared-rung achievement, wordmark', (tester) async {
      await pumpCard(tester, BadgeMetrics.dayStreak, 7);
      expect(find.text('I earned a badge!'), findsOneWidget);
      expect(find.text('Day streak'), findsOneWidget);
      // The rung stands alone on its own line (§2): an exact-match
      // Text whose data is the rung and nothing else — no combined
      // name-and-rung line anywhere on the card.
      expect(find.text('Gold II'), findsOneWidget);
      expect(find.textContaining('Day streak —'), findsNothing);
      expect(find.textContaining('Day streak, Gold'), findsNothing);
      expect(find.textContaining('Day streak · Gold'), findsNothing);
      // Achievement = thresholdLine of the SHARED rung (rung 7 →
      // 45), never the next rung (60) and never a measured value.
      expect(find.text('45-day streak'), findsOneWidget);
      expect(find.text('60-day streak'), findsNothing);
      expect(find.text('Tabs'), findsOneWidget);
      // The card itself is exactly 1080×1080.
      expect(
        tester.getSize(find.byType(BadgeShareCard)),
        const Size(1080, 1080),
      );
    });

    testWidgets('Monthly calories Silver I: comma-grouped threshold '
        'of the shared rung', (tester) async {
      await pumpCard(tester, BadgeMetrics.caloriesMonth, 5);
      expect(find.text('I earned a badge!'), findsOneWidget);
      expect(find.text('Monthly calories'), findsOneWidget);
      expect(find.text('Silver I'), findsOneWidget);
      expect(find.text('68,000 calories in one month'), findsOneWidget);
      // Next rung's threshold (75,000) must not appear.
      expect(find.text('75,000 calories in one month'), findsNothing);
    });
  });

  group('BadgeShareService (files only, Juno §3)', () {
    testWidgets('hands exactly the rendered 1080×1080 PNG file to '
        'the share fn', (tester) async {
      // The seam's type is the §3 pin: BadgeShareFn receives ONLY
      // a File — there is no text/subject parameter to pass.
      File? handedOff;
      var shareCalls = 0;
      BadgeShareService.debugSetShareFn(
        (file) async {
          shareCalls++;
          handedOff = file;
        },
        tempDir: () async => Directory.systemTemp,
      );
      addTearDown(() => BadgeShareService.debugSetShareFn(null));
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: BadgeShareCardHost(
            boundaryKey: key,
            metric: BadgeMetrics.dayStreak,
            rungIndex: 7,
          ),
        ),
      ));
      await tester.pump();
      // Capture bridge (the codebase's harness pattern): alternate
      // pumps with real-time runAsync delays so the boundary
      // settles before toImage; the render + file read run in
      // runAsync (toImage cannot complete in the fake-async zone).
      for (var i = 0; i < 5; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
      }
      await tester.pump();
      late final List<int> bytes;
      await tester.runAsync(() async {
        final ok = await BadgeShareService.shareFromBoundary(
          key,
          metric: BadgeMetrics.dayStreak,
          rungIndex: 7,
        );
        expect(ok, isTrue);
        expect(handedOff, isNotNull);
        bytes = await handedOff!.readAsBytes();
      });
      expect(shareCalls, 1);
      expect(
        handedOff!.path,
        contains('tabs_badge_share_day_streak_7.png'),
      );
      // PNG magic + IHDR dimensions: exactly 1080×1080.
      expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      final width =
          (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
      final height =
          (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
      expect(width, 1080);
      expect(height, 1080);
    });
  });

  group('unlock dialog share (Juno §4a + §7)', () {
    Future<void> pumpDialog(
        WidgetTester tester, BadgeUnlockBatch batch) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: BadgeUnlockDialog(batch: batch)),
      ));
      await tester.pump();
    }

    testWidgets('per-rung layout: one Share button per grant row, '
        'per-row semantics, tap targets that row\'s rung',
        (tester) async {
      final semanticsHandle = tester.ensureSemantics();
      File? handedOff;
      BadgeShareService.debugSetShareFn(
        (file) async => handedOff = file,
        tempDir: () async => Directory.systemTemp,
      );
      addTearDown(() => BadgeShareService.debugSetShareFn(null));
      await pumpDialog(
        tester,
        BadgeUnlockBatch(
          isBackfill: false,
          grants: [grant('total_logs', 0), grant('day_streak', 7)],
        ),
      );
      // Icon-only buttons, tooltip byte-exact (§4a).
      expect(find.byTooltip('Share badge'), findsNWidgets(2));
      expect(find.byIcon(Icons.share), findsNWidgets(2));
      // Per-row semantics labels name the exact badge + rung.
      expect(
        find.bySemanticsLabel('Share Total logs, Bronze III'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Share Day streak, Gold II'),
        findsOneWidget,
      );
      // No host renders until a share is tapped.
      expect(find.byType(BadgeShareCardHost), findsNothing);
      await tester
          .tap(find.byKey(const ValueKey('badge_share_day_streak_7')));
      await tester.pump();
      // Exactly ONE host, targeted at the tapped row's rung.
      final host = tester.widget<BadgeShareCardHost>(
        find.byType(BadgeShareCardHost),
      );
      expect(host.metric.id, 'day_streak');
      expect(host.rungIndex, 7);
      // The tap sets the target and the handler shares from this
      // host's boundary (the streak p0 pattern: pin the target at
      // the host, then render the PNG from its boundary through
      // the real service in runAsync — a tap-originated toImage
      // cannot complete in the fake-async zone).
      for (var i = 0; i < 5; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
      }
      await tester.pump();
      await tester.runAsync(() async {
        final ok = await BadgeShareService.shareFromBoundary(
          host.boundaryKey,
          metric: host.metric,
          rungIndex: host.rungIndex,
        );
        expect(ok, isTrue);
      });
      expect(handedOff, isNotNull);
      expect(
        handedOff!.path,
        contains('tabs_badge_share_day_streak_7.png'),
      );
      // The dialog stays up through the share (streak rule).
      expect(
        find.byKey(const ValueKey('badge_unlock_dialog')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('badge_unlock_done')), findsOneWidget);
      semanticsHandle.dispose();
    });

    testWidgets('grouped layout: share targets the row\'s highest '
        'batch rung (§7)', (tester) async {
      final semanticsHandle = tester.ensureSemantics();
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
      // One row (and one Share button) per badge, not per rung.
      expect(find.byTooltip('Share badge'), findsNWidgets(3));
      expect(
        find.bySemanticsLabel('Share Big step day, Bronze II'),
        findsOneWidget,
      );
      // The steps_day row's button is keyed/targeted at rung 1 —
      // the highest batch rung — never the batch's lowest (0).
      expect(
        find.byKey(const ValueKey('badge_share_steps_day_1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('badge_share_steps_day_0')),
        findsNothing,
      );
      await tester
          .tap(find.byKey(const ValueKey('badge_share_steps_day_1')));
      await tester.pump();
      final host = tester.widget<BadgeShareCardHost>(
        find.byType(BadgeShareCardHost),
      );
      expect(host.metric.id, 'steps_day');
      expect(host.rungIndex, 1);
      semanticsHandle.dispose();
    });
  });

  group('detail view share (Juno §4b)', () {
    Future<void> pumpDetail(
      WidgetTester tester,
      BadgeService svc,
      BadgeMetric metric,
    ) async {
      tester.view.physicalSize = const Size(1080, 2600 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: BadgeDetailScreen(
          metric: metric,
          service: svc,
          onOpenHcSettings: () async {},
        ),
      ));
      await tester.pump();
    }

    testWidgets('earned: labeled Share badge button under the '
        'current-rung block, shares the top rung', (tester) async {
      final semanticsHandle = tester.ensureSemantics();
      final svc = makeService();
      await svc.evaluate(
        inputs: logsOnly(6),
        blockedMetrics: const {},
        now: DateTime(2026, 11, 20, 12),
      );
      await pumpDetail(tester, svc, BadgeMetrics.totalLogs);
      expect(find.text('Share badge'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('badge_detail_share_button')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Share Total logs, Bronze III'),
        findsOneWidget,
      );
      // The host is already in the tree, targeted at the top rung.
      final host = tester.widget<BadgeShareCardHost>(
        find.byType(BadgeShareCardHost),
      );
      expect(host.metric.id, 'total_logs');
      expect(host.rungIndex, 0);
      semanticsHandle.dispose();
    });

    testWidgets('locked: no Share badge button, no host',
        (tester) async {
      final svc = makeService();
      await svc.ensureLoaded();
      await pumpDetail(tester, svc, BadgeMetrics.totalLogs);
      expect(find.text('No rungs yet'), findsOneWidget);
      expect(find.text('Share badge'), findsNothing);
      expect(
        find.byKey(const ValueKey('badge_detail_share_button')),
        findsNothing,
      );
      expect(find.byType(BadgeShareCardHost), findsNothing);
    });

    testWidgets('earned but permission-blocked: no Share badge '
        'button (§4b state rule)', (tester) async {
      final svc = makeService();
      // Earn steps_day rung 6 (20,000 steps) unblocked first…
      await svc.evaluate(
        inputs: const BadgeInputs(dailySteps: {'2026-11-10': 20000}),
        blockedMetrics: const {},
        now: DateTime(2026, 11, 20, 12),
      );
      expect(svc.snapshot.topRungOf('steps_day'), 6);
      // …then the same badge reads blocked: the recorded rung
      // stays (current-rung block renders) but Share must not.
      await svc.evaluate(
        inputs: const BadgeInputs(dailySteps: {'2026-11-10': 20000}),
        blockedMetrics: {'steps_day'},
        now: DateTime(2026, 11, 20, 13),
      );
      await pumpDetail(tester, svc, BadgeMetrics.stepsDay);
      expect(
        find.byKey(const ValueKey('badge_detail_permission_block')),
        findsOneWidget,
      );
      expect(find.text('Share badge'), findsNothing);
      expect(
        find.byKey(const ValueKey('badge_detail_share_button')),
        findsNothing,
      );
      expect(find.byType(BadgeShareCardHost), findsNothing);
    });
  });

  group('BadgeStrings §14 (byte pins)', () {
    test('ruled strings are byte-exact', () {
      expect(BadgeStrings.shareHeadline, 'I earned a badge!');
      expect(BadgeStrings.shareButtonLabel, 'Share badge');
      expect(
        BadgeStrings.shareSemantics('Day streak', 7),
        'Share Day streak, Gold II',
      );
      expect(
        BadgeStrings.shareReleaseNotes,
        'New: Share your badges. Tap Share when a badge unlocks, or '
        'open any earned badge and tap Share badge, to make a card '
        'with the badge, its rung, and what it took to earn it.',
      );
      // §6 character count, as ruled.
      expect(BadgeStrings.shareReleaseNotes.length, 171);
    });
  });
}
