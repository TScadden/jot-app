import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/onboarding_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/onboarding/conditions_screen.dart';
import 'package:tabs_lab/src/features/onboarding/consent_screen.dart';
import 'package:tabs_lab/src/features/onboarding/gems_onboarding_screen.dart';
import 'package:tabs_lab/src/features/onboarding/membership_onboarding_screen.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_connections_screen.dart';
import 'package:tabs_lab/src/features/onboarding/post_onboarding_notification_card.dart';
import 'package:tabs_lab/src/features/onboarding/profile_setup_screen.dart';
import 'package:tabs_lab/src/features/onboarding/welcome_screen.dart';

/// Flow3 capture harness (modeled on gems_capture_test.dart).
/// Frames @ DPR 3.0, 360dp wide, into $ONBOARDING_CAPTURE_OUT
/// (default ~/workspace/build-onboarding/captures).
class _FakeBackend extends TabsBackend {
  @override
  Future<Map<String, dynamic>?> fetchProfile() async => null;
  @override
  Future<bool> fetchIsUnlimited() async => false;
  @override
  Future<bool> postSyncProfile(Map<String, dynamic> fields) async => true;
}

class _FakeHC extends HealthConnectService {
  @override
  Future<bool> hasPersistedConnection() async => false;
  @override
  Future<HealthConnectStatus> getStatus() async =>
      HealthConnectStatus.notConnected;
  @override
  Future<Set<String>> requestPermissions() async => const {};
  @override
  Future<void> openHealthConnectSettings() async {}
}

void main() {
  testWidgets('capture the flow3 frames', (tester) async {
    final outDir = Directory(
      Platform.environment['ONBOARDING_CAPTURE_OUT'] ??
          '${Platform.environment['HOME']}/workspace/build-onboarding/captures',
    );
    await tester.runAsync(() => outDir.create(recursive: true));
    final rootKey = GlobalKey();

    await tester.runAsync(() async {
      final loader = FontLoader('Roboto');
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
      await loader.load();
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

    Future<void> capture(String name, Widget screen) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      await tester.pumpWidget(
        RepaintBoundary(
          key: rootKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(fontFamily: 'Roboto'),
            home: TickerMode(enabled: false, child: screen),
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(() async {
        await precacheImage(
          const AssetImage('assets/images/bandit_cheer_cut_v3.png'),
          rootKey.currentContext!,
        );
        await precacheImage(
          const AssetImage('assets/images/tabs_gem_icon_v1_20261119.png'),
          rootKey.currentContext!,
        );
        await precacheImage(
          const AssetImage('assets/images/ic_tabs_note.png'),
          rootKey.currentContext!,
        );
      });
      await tester.pump();
      final boundary = rootKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final ui.Image image = await boundary.toImage(pixelRatio: 3.0);
        final byteData =
            await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${outDir.path}/$name.png')
            .writeAsBytes(byteData!.buffer.asUint8List());
      });
    }

    final store = OnboardingStore.withStorage(
      read: (k) async => null,
      write: (k, v) async {},
      delete: (k) async {},
    );

    await capture(
      'flow3_01_signup_360',
      WelcomeScreen(onRegister: () {}, onLogin: () {}),
    );
    await capture(
      'flow3_02_consent_360',
      OnboardingConsentScreen(
          onBack: () {}, onConsent: () {}, onDecline: () {}),
    );
    await capture(
      'flow3_03_profile_360',
      ProfileSetupScreen(
        onBack: () {},
        onNavigateNext: () {},
        onboardingStore: store,
        backend: _FakeBackend(),
      ),
    );
    await capture(
      'flow3_04_conditions_360',
      OnboardingConditionsScreen(
        onBack: () {},
        onNavigateNext: () {},
        onSkip: () {},
        onboardingStore: store,
        backend: _FakeBackend(),
      ),
    );
    await capture(
      'flow3_05_connections_360',
      OnboardingConnectionsScreen(
        onBack: () {},
        onNavigateNext: () {},
        healthConnectService: _FakeHC(),
      ),
    );
    // Skip-warning dialog state.
    await tester.tap(find.text('Skip for now'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final boundary = rootKey.currentContext!.findRenderObject()!
        as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 3.0);
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${outDir.path}/flow3_05_connections_skip_warning_360.png')
          .writeAsBytes(byteData!.buffer.asUint8List());
    });
    // Dismiss the dialog so its route cannot leak into later
    // frames (Navigator state survives pumpWidget otherwise).
    await tester.tap(find.text('Connect instead'));
    await tester.pumpAndSettle();
    await capture(
      'flow3_06_gems_360',
      GemsOnboardingScreen(onBack: () {}, onContinue: () {}),
    );
    await capture(
      'flow3_07_membership_360',
      MembershipOnboardingScreen(
        onBack: () {},
        onSkip: () {},
        backend: _FakeBackend(),
      ),
    );
    await capture(
      'flow3_08_home_notifications_360',
      Scaffold(
        backgroundColor: const Color(0xFF080E1A),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 64, 24, 24),
            child: PostOnboardingNotificationCard(
              onAllow: () {},
              onDontAllow: () {},
            ),
          ),
        ),
      ),
    );
  });
}
