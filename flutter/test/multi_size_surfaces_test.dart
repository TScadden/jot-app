import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/features/auth/login_screen.dart';
import 'package:tabs_lab/src/features/onboarding/consultation_intro_screen.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_header.dart';
import 'package:tabs_lab/src/features/onboarding/welcome_screen.dart';

import 'test_helpers.dart';

/// SCORECARD-5 prescription, landed as apply-wave step 1: key
/// surfaces pumped at a size matrix — portrait phone, short heights
/// (<=600dp and <=420dp: landscape phones, split-screen panes),
/// wide (>=820dp) and tablet sizes. Before this file the suite's
/// ~140 test surfaces were ALL portrait phones, so a regression
/// that pushed a button off screen at iPad/landscape sizes shipped
/// silently.
///
/// What this suite asserts:
/// - No layout exception (overflow) at any size on the first-run
///   and auth surfaces — the screens SCORECARD-5 risk 1 names.
/// - The consultation intro's Continue is reachable and tappable at
///   short heights (the Wave A scrollability fix) and visible
///   without scrolling at tall heights.
/// - Wide-size behaviour is DOCUMENTED, not fixed: width adaptation
///   (max-content-width, grid column counts) is a founder-escalated
///   design decision (SCORECARD-5 item 3), so the wide cases here
///   characterize today's stretched layout.
/// - The Wave A SCORECARD-3 behaviours on the auth surface
///   (keyboard submit, blur validation, 48dp hit boxes).
///
/// Quick Log is not in the size matrix: its widget harness needs
/// the full backend fake that quick_log_test.dart owns, and
/// SCORECARD-5's size risks are the first-run/auth surfaces.

class _FakeAuthApi extends AuthApiClient {
  LoginResult loginResult = const LoginFailure(
    LoginFailureKind.server,
    'unconfigured fake',
  );

  @override
  Future<LoginResult> login({
    required String email,
    required String password,
  }) async =>
      loginResult;
}

const _sizes = <String, Size>{
  'phone portrait 360x800': Size(360, 800),
  'short landscape 800x360 (<=420 high)': Size(800, 360),
  'landscape phone 915x412 (<=420 high)': Size(915, 412),
  'split pane 390x590 (<=600 high)': Size(390, 590),
  'tablet portrait 820x1180 (>=820 wide)': Size(820, 1180),
  'tablet landscape 1180x820 (>=820 wide)': Size(1180, 820),
};

Future<void> _pumpAt(WidgetTester tester, Size size, Widget child) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: child));
  await tester.pump();
}

void main() {
  group('multi-size: consultation intro (SCORECARD-5 risk 1)', () {
    for (final entry in _sizes.entries) {
      testWidgets('no overflow, Continue tappable — ${entry.key}',
          (tester) async {
        var continued = false;
        await _pumpAt(
          tester,
          entry.value,
          ConsultationIntroScreen(
            onBack: () {},
            onContinue: () => continued = true,
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.text('Continue'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('Continue'),
          120,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pump();
        await tester.tap(find.text('Continue'));
        await tester.pump();
        expect(continued, isTrue);
      });
    }

    testWidgets('tall height: Continue visible without scrolling',
        (tester) async {
      await _pumpAt(
        tester,
        const Size(360, 800),
        ConsultationIntroScreen(onBack: () {}, onContinue: () {}),
      );
      final viewport = tester.view.physicalSize / tester.view.devicePixelRatio;
      final continueRect = tester.getRect(find.text('Continue'));
      expect(continueRect.bottom, lessThanOrEqualTo(viewport.height));
      expect(tester.takeException(), isNull);
    });
  });

  group('multi-size: welcome + login render clean', () {
    for (final entry in _sizes.entries) {
      testWidgets('welcome — ${entry.key}', (tester) async {
        await _pumpAt(
          tester,
          entry.value,
          WelcomeScreen(onRegister: () {}, onLogin: () {}),
        );
        expect(tester.takeException(), isNull);
        expect(find.byType(WelcomeScreen), findsOneWidget);
      });

      testWidgets('login — ${entry.key}', (tester) async {
        await _pumpAt(
          tester,
          entry.value,
          const LoginScreen(initialRegisterMode: false),
        );
        expect(tester.takeException(), isNull);
        // The submit action must be reachable at every size.
        await tester.scrollUntilVisible(
          find.text('Log In'),
          120,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pump();
        expect(find.text('Log In'), findsOneWidget);
      });
    }
  });

  group('wide-size characterization (SCORECARD-5 item 3, founder-escalated)',
      () {
    testWidgets('login form stretches full width at 1180dp today',
        (tester) async {
      await _pumpAt(
        tester,
        const Size(1180, 820),
        const LoginScreen(initialRegisterMode: false),
      );
      // Documents current behaviour: no max-content-width cap, so
      // the email field spans nearly the whole tablet width. When
      // the founder rules on width adaptation, this expectation is
      // the one that changes.
      final fieldWidth = tester.getSize(find.byType(TextField).first).width;
      expect(fieldWidth, greaterThan(600));
    });
  });

  group('Wave A auth behaviours (SCORECARD-3 #5/#7/#2)', () {
    testWidgets('email action is next, password action is done',
        (tester) async {
      await _pumpAt(
        tester,
        const Size(360, 800),
        const LoginScreen(initialRegisterMode: false),
      );
      final fields = find.byType(TextField);
      expect(tester.widget<TextField>(fields.at(0)).textInputAction,
          TextInputAction.next);
      expect(tester.widget<TextField>(fields.at(1)).textInputAction,
          TextInputAction.done);
    });

    testWidgets('password Enter submits login via the mode dispatch',
        (tester) async {
      final api = _FakeAuthApi()
        ..loginResult = const LoginSuccess(
          token: 'tok',
          refreshToken: 'ref',
          email: 'a@tabs.app',
          emailVerified: true,
        );
      AuthSuccess? fired;
      await _pumpAt(
        tester,
        const Size(360, 800),
        LoginScreen(
          initialRegisterMode: false,
          authApi: api,
          sessionStore: FakeSessionStore(),
          onLoginSuccess: (s) => fired = s,
        ),
      );
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'a@tabs.app');
      await tester.enterText(fields.at(1), 'secret');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(fired, isNotNull);
      expect(fired!.email, 'a@tabs.app');
    });

    testWidgets('blur on a malformed email flags it on the error line',
        (tester) async {
      await _pumpAt(
        tester,
        const Size(360, 800),
        const LoginScreen(initialRegisterMode: false),
      );
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'not-an-email');
      // Moving focus to the password field is the blur.
      await tester.tap(fields.at(1));
      await tester.pump();
      expect(find.text('Please enter a valid email address'),
          findsOneWidget);
    });

    testWidgets('blur on a well-formed email shows no format error',
        (tester) async {
      await _pumpAt(
        tester,
        const Size(360, 800),
        const LoginScreen(initialRegisterMode: false),
      );
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'a@tabs.app');
      await tester.tap(fields.at(1));
      await tester.pump();
      expect(find.text('Please enter a valid email address'),
          findsNothing);
    });

    testWidgets('Forgot Password? hit height >= 48dp, text unchanged',
        (tester) async {
      await _pumpAt(
        tester,
        const Size(360, 800),
        const LoginScreen(initialRegisterMode: false),
      );
      final button = find.widgetWithText(TextButton, 'Forgot Password?');
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
    });

    testWidgets('onboarding Skip hit box >= 48dp', (tester) async {
      var skipped = false;
      await _pumpAt(
        tester,
        const Size(360, 800),
        Scaffold(
          body: OnboardingHeader(onSkip: () => skipped = true),
        ),
      );
      final button = find.widgetWithText(TextButton, 'Skip');
      final size = tester.getSize(button);
      expect(size.height, greaterThanOrEqualTo(48));
      expect(size.width, greaterThanOrEqualTo(48));
      await tester.tap(button);
      expect(skipped, isTrue);
    });
  });
}
