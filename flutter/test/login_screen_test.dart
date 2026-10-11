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

  testWidgets('app flow reveals welcome after splash exit', (tester) async {
    await tester.pumpWidget(const TabsLabApp());
    // Splash entry visible first.
    expect(find.text('Health & Symptom Intelligence'), findsOneWidget);
    // Advance past entry (650ms) + hold (1200ms) + exit (650ms).
    await tester.pump(const Duration(milliseconds: 1900));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(find.text('Notes that build'), findsOneWidget);
    expect(find.text('Health & Symptom Intelligence'), findsNothing);
  });

  testWidgets('login screen honors initialRegisterMode=false', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: LoginScreen(initialRegisterMode: false),
    ));
    expect(find.text('Welcome Back'), findsOneWidget);
    expect(find.text('Forgot Password?'), findsOneWidget);
    expect(find.text('I confirm I am 13 or older.'), findsNothing);
  });

  testWidgets(
      'card scroll region never overlaps the pinned header (keyboard open)',
      (tester) async {
    // Simulate a keyboard-open viewport: Pixel 9a ~800dp tall with a
    // ~350dp keyboard leaves ~450dp of body.
    tester.view.physicalSize = const Size(1236, 1350);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(
      home: LoginScreen(initialRegisterMode: false),
    ));
    await tester.pump();

    // The scrollable clips its content, so if the scroll region itself
    // starts below the header, nothing inside can ever paint under it.
    final headerRect = tester.getRect(find.text('Tabs'));
    final scrollRect = tester.getRect(find.byType(SingleChildScrollView));
    expect(scrollRect.top,
        greaterThanOrEqualTo(headerRect.bottom));
    // And the card title is fully below the header at rest.
    final titleRect = tester.getRect(find.text('Welcome Back'));
    expect(titleRect.top, greaterThanOrEqualTo(headerRect.bottom));
  });

  testWidgets('card stays vertically centered below the header (keyboard closed)',
      (tester) async {
    // Full-height viewport: Pixel 9a ~800dp tall, no keyboard.
    tester.view.physicalSize = const Size(1236, 2778);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(
      home: LoginScreen(initialRegisterMode: false),
    ));
    await tester.pump();

    final headerRect = tester.getRect(find.text('Tabs'));
    final cardRect =
        tester.getRect(find.byKey(const ValueKey('login_card')));
    final regionTop = headerRect.bottom + 16.0; // header gap
    final regionBottom = 926.0; // full Pixel 9a height in dp
    final topSpace = cardRect.top - regionTop;
    final bottomSpace = regionBottom - cardRect.bottom;
    // Roughly centered: the two spaces agree within a loose tolerance.
    expect(topSpace, greaterThan(0));
    expect(bottomSpace, greaterThan(0));
    expect((topSpace - bottomSpace).abs(), lessThan(48.0));
  });
}
