import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/billing_service.dart';
import 'package:tabs_lab/src/features/auth/login_screen.dart';
import 'package:tabs_lab/src/features/billing/billing_plans_panel.dart';
import 'package:tabs_lab/src/features/onboarding/consent_screen.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_connections_screen.dart';
import 'package:tabs_lab/src/features/onboarding/post_onboarding_notification_card.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';
import 'package:tabs_lab/src/features/shell/tablet_content_shell.dart';
import 'package:tabs_lab/src/theme/notel_theme.dart';

import 'billing_takeover_test.dart' as bt;
import 'settings_r29_test.dart' as r29;
import 'test_helpers.dart';

/// Tablet width adaptation — Juno C5 compliance-surface captures
/// (merge gate, JUNO-CHECK.md). Before/after at 820x1180 and
/// 1180x820 for: onboarding consent, HC prominent disclosure dialog
/// (open, from the onboarding connections step), connections
/// skip-warning dialog, post-onboarding notification card
/// (non-dismissible, Allow / Don't Allow), login terms line,
/// Settings footer legal links (scrolled to footer), membership
/// paywall ROSCA block.
///
/// Same variant mechanism as tablet_adaptation_capture_test.dart:
/// TABLET_CAPTURE_VARIANT=before on the base head, =after on the
/// prototype branch. Output dir: $TABLET_CAPTURE_OUT.
void main() {
  testWidgets('capture Juno C5 compliance frames', (tester) async {
    final variant =
        Platform.environment['TABLET_CAPTURE_VARIANT'] ?? 'after';
    final outDir = Directory(
      Platform.environment['TABLET_CAPTURE_OUT'] ??
          '${Platform.environment['HOME']}/workspace/build-tablet-adaptation/renders',
    );
    await tester.runAsync(() => outDir.create(recursive: true));
    final rootKey = GlobalKey();

    await tester.runAsync(() async {
      final loader = FontLoader('Roboto');
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
      await loader.load();
      final nunito = FontLoader('Nunito');
      nunito.addFont(rootBundle.load('assets/fonts/Nunito-Variable.ttf'));
      await nunito.load();
      final iconsFile = File(
        '${Platform.environment['HOME']}/workspace/flutter-sdk/bin/cache/'
        'artifacts/material_fonts/MaterialIcons-Regular.otf',
      );
      if (await iconsFile.exists()) {
        final icons = await iconsFile.readAsBytes();
        final iconLoader = FontLoader('MaterialIcons');
        iconLoader.addFont(
          Future.value(ByteData.view(Uint8List.fromList(icons).buffer)),
        );
        await iconLoader.load();
      }
    });

    Future<void> capture(String name) async {
      final boundary = rootKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final ui.Image image = await boundary.toImage(pixelRatio: 1.0);
        final byteData =
            await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${outDir.path}/$name.png')
            .writeAsBytes(byteData!.buffer.asUint8List());
      });
    }

    Widget frame(Widget child) => RepaintBoundary(
          key: rootKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: notelDarkTheme(),
            home: TickerMode(
              enabled: false,
              child: MediaQuery(
                data: const MediaQueryData(disableAnimations: true),
                child: variant == 'after'
                    ? TabletContentShell(child: child)
                    : child,
              ),
            ),
          ),
        );

    Future<void> settle() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> shoot(String surface, Size size, Widget child) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(frame(child));
      await settle();
      final tag = '${size.width.toInt()}x${size.height.toInt()}';
      await capture('${surface}_${tag}_$variant');
      tester.takeException();
    }

    final settingsBackend = r29.FakeSettingsBackend()
      ..pullBody = r29.pull(profile: {'avatarId': 'avatar_03'});

    const sizes = [Size(820, 1180), Size(1180, 820)];
    var n = 0;
    for (final size in sizes) {
      n++;
      final tag = '${size.width.toInt()}x${size.height.toInt()}';

      // 1 — Onboarding consent screen.
      await shoot(
          'consent',
          size,
          OnboardingConsentScreen(
            onBack: () {},
            onConsent: () {},
            onDecline: () {},
          ));

      // 2 — HC prominent disclosure, open from the connections step.
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(frame(OnboardingConnectionsScreen(
        key: ValueKey('connections_hc_$n'),
        onBack: () {},
        onNavigateNext: () {},
      )));
      await settle();
      final connectFinder = find.text('Connect Health Data');
      if (connectFinder.evaluate().isNotEmpty) {
        await tester.tap(connectFinder.first);
        await settle();
      }
      await capture('hc_disclosure_${tag}_$variant');
      tester.takeException();
      // Dismiss via the explicit action (also C6 evidence the action
      // row is reachable).
      final notNow = find.text('Not now');
      if (notNow.evaluate().isNotEmpty) {
        await tester.tap(notNow.first);
        await settle();
      }

      // 3 — Connections skip-warning dialog.
      await tester.pumpWidget(frame(OnboardingConnectionsScreen(
        key: ValueKey('connections_skip_$n'),
        onBack: () {},
        onNavigateNext: () {},
      )));
      await settle();
      final skipFinder = find.text('Skip for now');
      if (skipFinder.evaluate().isNotEmpty) {
        await tester.tap(skipFinder.first);
        await settle();
      }
      await capture('skip_warning_${tag}_$variant');
      tester.takeException();

      // 3b — Post-onboarding notification card (non-dismissible,
      // Allow / Don't Allow) — Juno §3's second priming surface.
      await tester.pumpWidget(frame(Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showPostOnboardingNotificationCard(
                context,
                onAllow: () {},
                onDontAllow: () {},
              ),
              child: const Text('open-card'),
            ),
          ),
        ),
      )));
      await settle();
      await tester.tap(find.text('open-card'));
      await settle();
      await capture('notif_card_${tag}_$variant');
      tester.takeException();

      // 4 — Login screen (terms line under the card).
      await tester.pumpWidget(frame(const LoginScreen()));
      await settle();
      final termsFinder = find.textContaining('Terms');
      if (termsFinder.evaluate().isNotEmpty) {
        try {
          await tester.scrollUntilVisible(
            termsFinder.first,
            120,
            scrollable: find.byType(Scrollable).first,
          );
          await settle();
        } catch (_) {
          // Already fully visible — nothing to scroll.
        }
      }
      await capture('login_${tag}_$variant');
      tester.takeException();

      // 5 — Settings main page scrolled to the footer legal links.
      await tester.pumpWidget(frame(SettingsScreen(
        key: ValueKey('settings_footer_$n'),
        backend: settingsBackend,
        settingsStore: r29.fakeStore({}),
        notificationService: FakeReminderNotificationService(),
        urlLauncher: (uri) async => true,
      )));
      await settle();
      try {
        await tester.scrollUntilVisible(
          find.text('Terms of Use'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await settle();
      } catch (_) {
        // Footer already in frame at this size.
      }
      await capture('settings_footer_${tag}_$variant');
      tester.takeException();

      // 6 — Membership paywall ROSCA block (cancel-method line +
      // terms line immediately below the subscribe CTA).
      final log = <String>[];
      final store = bt.FakeBillingStore(log)
        ..catalog = [bt.liveCatalog()];
      final backend = bt.FakeBillingBackend(log);
      final service = BillingService(
          store: store, backend: backend, isProductionBuild: true);
      await tester.pumpWidget(frame(Scaffold(
        body: BillingPlansPanel(service: service),
      )));
      await settle();
      try {
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('paywall_cancel_method')),
          120,
          scrollable: find.byType(Scrollable).first,
        );
        await settle();
      } catch (_) {
        // Block already in frame at this size.
      }
      await capture('paywall_${tag}_$variant');
      tester.takeException();
      await service.dispose();
      await store.updates.close();
    }
  });
}
