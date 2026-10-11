import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/main.dart';
import 'package:tabs_lab/src/features/auth/login_screen.dart';

void main() {
  testWidgets('login screen builds in register mode by default',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    expect(find.text('Create Your Account'), findsOneWidget);
    expect(find.text('Email Address'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('Sign Up'), findsOneWidget);
    expect(find.text('I confirm I am 13 or older.'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Already have an account? Log In'), findsOneWidget);
  });

  testWidgets('toggle switches to login mode', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    await tester.tap(find.text('Already have an account? Log In'));
    await tester.pump();
    expect(find.text('Welcome Back'), findsOneWidget);
    expect(find.text('Log In'), findsOneWidget);
    expect(find.text('Forgot Password?'), findsOneWidget);
    expect(find.text('Log in with Google'), findsOneWidget);
    // Age checkbox only exists on the sign-up form.
    expect(find.text('I confirm I am 13 or older.'), findsNothing);
  });

  testWidgets('forgot-password mode shows reset form', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    await tester.tap(find.text('Already have an account? Log In'));
    await tester.pump();
    await tester.tap(find.text('Forgot Password?'));
    await tester.pump();
    expect(find.text('Reset Password'), findsOneWidget);
    expect(find.text('Send Reset Link'), findsOneWidget);
    expect(find.text('Password'), findsNothing);
    expect(find.text('Back to Log In'), findsOneWidget);
  });

  testWidgets('app flow reveals login after splash exit', (tester) async {
    await tester.pumpWidget(const TabsLabApp());
    // Splash entry visible first.
    expect(find.text('Health & Symptom Intelligence'), findsOneWidget);
    // Advance past entry (650ms) + hold (1200ms) + exit (650ms).
    await tester.pump(const Duration(milliseconds: 1900));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(find.text('Create Your Account'), findsOneWidget);
    expect(find.text('Health & Symptom Intelligence'), findsNothing);
  });
}
