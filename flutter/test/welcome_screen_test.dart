import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/main.dart';
import 'package:tabs_lab/src/features/onboarding/welcome_screen.dart';

import 'onboarding_r32_test.dart' as r32;
import 'test_helpers.dart';

void main() {
  testWidgets('welcome screen shows slogan, avatars, and both buttons',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: WelcomeScreen(onRegister: () {}, onLogin: () {}),
    ));
    // Juno ruling 5 (onboarding reorder, Nov 27, 2026): byte-exact
    // callouts in order, the replaced slogan with its line break,
    // and the "Get started" entry label.
    expect(find.text('For the days that'), findsOneWidget);
    expect(find.text('blur together'), findsOneWidget);
    expect(
        find.text('Days blur together? Jot a symptom or treatment '
            'in a few words, right when it happens.'),
        findsOneWidget);
    expect(
        find.text("Can't remember what you tried last week? Keep "
            "it next to the day it happened."),
        findsOneWidget);
    expect(
        find.text("Hard to see what's been going on lately? Your "
            "own notes, in one place to look back on."),
        findsOneWidget);
    expect(find.text('Get started'), findsOneWidget);
    expect(find.text('Log In'), findsOneWidget);
    expect(find.text('Tabs'), findsOneWidget);
  });

  testWidgets(
      'Get started enters the pre-account onboarding flow at consent',
      (tester) async {
    // Fake stores: the pre-account entry reads the onboarding
    // store, whose real secure-storage futures stall in
    // fake-async (every other AppFlow test injects fakes too).
    final session = FakeSessionStore();
    await tester.pumpWidget(MaterialApp(
      home: AppFlow(
        sessionStore: session,
        onboardingStore: r32.fakeOnboardingStore({}),
        tabsBackend: r32.FakeOnboardingBackend(sessionStore: session),
        healthConnectService: r32.FakeOnboardingHC(),
        notificationService: FakeReminderNotificationService(),
      ),
    ));
    // Fast-forward past splash entry (650ms) + hold (1200ms) + exit (650ms).
    await tester.pump(const Duration(milliseconds: 1850));
    await tester.pump(const Duration(milliseconds: 650));
    await tester.pump();
    expect(find.text('For the days that'), findsOneWidget);

    await tester.tap(find.text('Get started'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    // The value flow opens at Consent — registration is the gate
    // between Gems and Membership now, not the entry.
    expect(find.text('Privacy & Data Consent'), findsOneWidget);
    expect(find.text('Create Your Account'), findsNothing);
  });

  testWidgets('Log In button routes to login in login mode', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AppFlow()));
    await tester.pump(const Duration(milliseconds: 1850));
    await tester.pump(const Duration(milliseconds: 650));
    await tester.pump();

    await tester.tap(find.text('Log In'));
    await tester.pump();
    expect(find.text('Welcome Back'), findsOneWidget);
    // Main button in login mode reads "Log In"; the mode-toggle link is gone.
    expect(find.text('Forgot Password?'), findsOneWidget);
  });

  testWidgets('login back button returns to welcome', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AppFlow()));
    await tester.pump(const Duration(milliseconds: 1850));
    await tester.pump(const Duration(milliseconds: 650));
    await tester.pump();

    await tester.tap(find.text('Log In'));
    await tester.pump();
    expect(find.text('Welcome Back'), findsOneWidget);

    // The circular back button in the login header.
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    expect(find.text('For the days that'), findsOneWidget);
    expect(find.text('Welcome Back'), findsNothing);
  });
}
