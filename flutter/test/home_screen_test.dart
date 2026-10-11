import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/main.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

void main() {
  testWidgets('home screen renders the native background color',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    // Native today route: Scaffold containerColor = NotelBackground.
    expect(scaffold.backgroundColor, NotelColors.background);
    expect(NotelColors.background.toARGB32(), 0xFF080E1A);
    // Background only: no content whatsoever.
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('login "Log In" navigates to the home screen (placeholder)',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AppFlow()));
    // Fast-forward past splash entry (650ms) + hold (1200ms) + exit (650ms).
    await tester.pump(const Duration(milliseconds: 1850));
    await tester.pump(const Duration(milliseconds: 650));
    await tester.pump();

    // Welcome -> login in login mode.
    await tester.tap(find.text('Log In'));
    await tester.pump();
    expect(find.text('Welcome Back'), findsOneWidget);

    // PLACEHOLDER: the main "Log In" button navigates to home with no auth.
    final loginButton = find.widgetWithText(ElevatedButton, 'Log In');
    expect(loginButton, findsOneWidget);
    await tester.tap(loginButton);
    await tester.pump();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('Welcome Back'), findsNothing);
  });

  testWidgets('"Sign Up" stays a no-op (no navigation)', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AppFlow()));
    await tester.pump(const Duration(milliseconds: 1850));
    await tester.pump(const Duration(milliseconds: 650));
    await tester.pump();

    await tester.tap(find.text('Register'));
    await tester.pump();
    expect(find.text('Create Your Account'), findsOneWidget);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Sign Up'));
    await tester.pump();
    // Still on the login screen; nothing navigated.
    expect(find.text('Create Your Account'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });
}
