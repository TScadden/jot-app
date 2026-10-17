import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/main.dart';
import 'package:tabs_lab/src/features/onboarding/welcome_screen.dart';

void main() {
  testWidgets('welcome screen shows slogan, avatars, and both buttons',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: WelcomeScreen(onRegister: () {}, onLogin: () {}),
    ));
    expect(find.text('Notes that build'), findsOneWidget);
    expect(find.text('with you'), findsOneWidget);
    expect(find.text('Track symptoms and treatments'), findsOneWidget);
    expect(find.text('Reach your goals'), findsOneWidget);
    expect(find.text('Learn patterns and get insights'), findsOneWidget);
    expect(find.text('Register'), findsOneWidget);
    expect(find.text('Log In'), findsOneWidget);
    expect(find.text('Tabs'), findsOneWidget);
  });

  testWidgets('Register button routes to login in register mode',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AppFlow()));
    // Fast-forward past splash entry (650ms) + hold (1200ms) + exit (650ms).
    await tester.pump(const Duration(milliseconds: 1850));
    await tester.pump(const Duration(milliseconds: 650));
    await tester.pump();
    expect(find.text('Notes that build'), findsOneWidget);

    await tester.tap(find.text('Register'));
    await tester.pump();
    expect(find.text('Create Your Account'), findsOneWidget);
    expect(find.text('Sign Up'), findsOneWidget);
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

    await tester.tap(find.text('Register'));
    await tester.pump();
    expect(find.text('Create Your Account'), findsOneWidget);

    // The circular back button in the login header.
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    expect(find.text('Notes that build'), findsOneWidget);
    expect(find.text('Create Your Account'), findsNothing);
  });
}
