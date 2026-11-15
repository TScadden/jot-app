import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/auth/email_verification_screen.dart';

import 'test_helpers.dart';

/// VC 100134 Package C — email verification screen + backend
/// outcome mapping tests. All strings asserted here are Juno's
/// verbatim copy (juno-copy-privacy.md §2 / §2.1).
///
/// Founder-directed box UI (Tyson, Nov 14, 2026): six individual
/// digit boxes (`verify_digit_0` … `verify_digit_5`), no text or
/// hint inside any box, `Verification code` as a plain label
/// above the row.

const _email = 'pending@tabs.app';
const _genericError =
    "That code didn't work. Check the code and try again, or resend a new code.";
const _networkError =
    'Network error. Please check your connection and try again.';

class FakeVerifyBackend extends TabsBackend {
  VerifyEmailOutcome verifyOutcome = const VerifyEmailSuccess();
  ResendVerificationOutcome resendOutcome =
      const ResendVerificationSent();
  Completer<VerifyEmailOutcome>? verifyGate;
  String? lastCode;
  int verifyCalls = 0;
  int resendCalls = 0;

  FakeVerifyBackend({required super.sessionStore});

  @override
  Future<VerifyEmailOutcome> verifyEmailCode(String code) async {
    verifyCalls++;
    lastCode = code;
    final gate = verifyGate;
    if (gate != null) return gate.future;
    return verifyOutcome;
  }

  @override
  Future<ResendVerificationOutcome> resendVerificationCode() async {
    resendCalls++;
    return resendOutcome;
  }
}

FakeSessionStore _store() => FakeSessionStore()..token = 'fake-access';

/// Mutable fake wall clock for the deadline-based countdown:
/// FakeAsync advances the screen's Timer but not DateTime.now(),
/// so countdown tests advance this clock by hand and then pump
/// one timer tick.
class FakeClock {
  DateTime _t = DateTime(2026, 1, 1, 12);
  DateTime now() => _t;
  void advance(Duration d) => _t = _t.add(d);
}

Future<FakeVerifyBackend> pumpScreen(
  WidgetTester tester, {
  VoidCallback? onVerified,
  VoidCallback? onEscape,
  FakeClock? clock,
}) async {
  final backend = FakeVerifyBackend(sessionStore: _store());
  await tester.pumpWidget(MaterialApp(
    home: EmailVerificationScreen(
      email: _email,
      backend: backend,
      now: clock?.now,
      onVerified: onVerified,
      onEscape: onEscape,
    ),
  ));
  await tester.pump();
  return backend;
}

/// Unmount the screen so its countdown timer is disposed before
/// the test ends (a live Timer.periodic fails widget tests).
Future<void> disposeScreen(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  await tester.pump();
}

ElevatedButton submitButton(WidgetTester tester) =>
    tester.widget(find.byKey(const ValueKey('verify_submit')));

Finder digitFinder(int index) => find.byKey(ValueKey('verify_digit_$index'));

TextField digitField(WidgetTester tester, int index) =>
    tester.widget(digitFinder(index));

String digitText(WidgetTester tester, int index) =>
    digitField(tester, index).controller!.text;

String enteredCode(WidgetTester tester) =>
    [for (var i = 0; i < 6; i++) digitText(tester, i)].join();

bool digitHasFocus(WidgetTester tester, int index) =>
    digitField(tester, index).focusNode!.hasFocus;

/// Type [digits] into box [index] the way a paste / autofill /
/// soft-keyboard commit delivers it to that box.
Future<void> enterIntoBox(WidgetTester tester, int index, String digits) async {
  await tester.enterText(digitFinder(index), digits);
  await tester.pump();
}

/// Fill all six boxes by pasting the full code into the first box.
Future<void> fillAllBoxes(WidgetTester tester, String code) =>
    enterIntoBox(tester, 0, code);

void main() {
  group('EmailVerificationScreen', () {
    testWidgets('renders Juno\'s strings with the account email '
        'interpolated; Verify disabled; Resend in cooldown', (tester) async {
      await pumpScreen(tester);
      expect(find.text('Verify your email'), findsOneWidget);
      expect(find.text('We sent a code to $_email'), findsOneWidget);
      expect(
        find.text(
          "Enter the 6-digit code to finish creating your account. If you don't see the email, check your spam folder.",
        ),
        findsOneWidget,
      );
      expect(find.text('Verification code'), findsOneWidget);
      expect(find.text('Verify'), findsOneWidget);
      expect(find.text('Resend code in 1:00'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
      expect(submitButton(tester).onPressed, isNull);
      final resend = tester.widget<TextButton>(
        find.byKey(const ValueKey('verify_resend')),
      );
      expect(resend.onPressed, isNull);
      await disposeScreen(tester);
    });

    testWidgets('six boxes: all empty, NO hint/label/placeholder '
        'inside any box, old single field and its hint are gone, '
        'label sits ABOVE the box row', (tester) async {
      await pumpScreen(tester);
      expect(find.byKey(const ValueKey('verify_code_field')), findsNothing);
      expect(find.text('6-digit code'), findsNothing);
      for (var i = 0; i < 6; i++) {
        final field = digitField(tester, i);
        expect(field.controller!.text, isEmpty, reason: 'box $i');
        expect(field.decoration?.hintText, isNull, reason: 'box $i');
        expect(field.decoration?.labelText, isNull, reason: 'box $i');
        expect(field.decoration?.hint, isNull, reason: 'box $i');
        expect(field.decoration?.label, isNull, reason: 'box $i');
        expect(field.keyboardType, TextInputType.number, reason: 'box $i');
        expect(field.textAlign, TextAlign.center, reason: 'box $i');
        expect(field.style?.fontSize, 24, reason: 'box $i');
      }
      // oneTimeCode autofill stays, on the first box only.
      expect(
        digitField(tester, 0).autofillHints,
        contains(AutofillHints.oneTimeCode),
      );
      for (var i = 1; i < 6; i++) {
        expect(
          digitField(tester, i).autofillHints,
          isNot(contains(AutofillHints.oneTimeCode)),
          reason: 'box $i',
        );
      }
      // The label is a plain Text above the boxes, not in a field.
      final labelTop = tester.getTopLeft(find.text('Verification code'));
      final rowTop = tester.getTopLeft(
        find.byKey(const ValueKey('verify_code_boxes')),
      );
      expect(labelTop.dy, lessThan(rowTop.dy));
      await disposeScreen(tester);
    });

    testWidgets('box geometry at 360 CSS px wide: six boxes fit '
        'inside the card padding, each at least 44px tall', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpScreen(tester);
      for (var i = 0; i < 6; i++) {
        final size = tester.getSize(digitFinder(i));
        expect(size.height, greaterThanOrEqualTo(44), reason: 'box $i height');
        expect(size.width, greaterThan(30), reason: 'box $i width');
      }
      // No overflow: the row's right edge stays inside the screen.
      final rowRect = tester.getRect(
        find.byKey(const ValueKey('verify_code_boxes')),
      );
      expect(rowRect.right, lessThanOrEqualTo(360));
      await disposeScreen(tester);
    });

    testWidgets('typing: each digit auto-advances focus; 5 digits '
        'keeps Verify disabled, the 6th enables it', (tester) async {
      await pumpScreen(tester);
      await tester.tap(digitFinder(0));
      await tester.pump();
      expect(digitHasFocus(tester, 0), isTrue);
      const digits = ['1', '2', '3', '4', '5'];
      for (var i = 0; i < digits.length; i++) {
        await enterIntoBox(tester, i, digits[i]);
        expect(digitText(tester, i), digits[i], reason: 'box $i');
        expect(
          digitHasFocus(tester, i + 1),
          isTrue,
          reason: 'focus should advance past box $i',
        );
        expect(submitButton(tester).onPressed, isNull);
      }
      await enterIntoBox(tester, 5, '6');
      expect(enteredCode(tester), '123456');
      expect(submitButton(tester).onPressed, isNotNull);
      await disposeScreen(tester);
    });

    testWidgets('typing: non-digits never land; a 7th digit is '
        'rejected (boxes hold one digit each)', (tester) async {
      await pumpScreen(tester);
      await enterIntoBox(tester, 0, '12a34567');
      expect(enteredCode(tester), '123456');
      for (var i = 0; i < 6; i++) {
        expect(digitText(tester, i).length, 1, reason: 'box $i');
      }
      expect(submitButton(tester).onPressed, isNotNull);
      await disposeScreen(tester);
    });

    testWidgets('paste: a full 6-digit code into the FIRST box '
        'fills all six boxes in order and enables Verify', (tester) async {
      await pumpScreen(tester);
      await enterIntoBox(tester, 0, '001234');
      expect(enteredCode(tester), '001234');
      expect(digitHasFocus(tester, 5), isTrue);
      expect(submitButton(tester).onPressed, isNotNull);
      await disposeScreen(tester);
    });

    testWidgets('paste: a full 6-digit code into ANY box fills '
        'all six boxes in order', (tester) async {
      await pumpScreen(tester);
      await enterIntoBox(tester, 3, '654321');
      expect(enteredCode(tester), '654321');
      expect(submitButton(tester).onPressed, isNotNull);
      await disposeScreen(tester);
    });

    testWidgets('paste: a multi-digit string landing in a box '
        'distributes across the following boxes', (tester) async {
      await pumpScreen(tester);
      await enterIntoBox(tester, 1, '789');
      expect(digitText(tester, 0), isEmpty);
      expect(digitText(tester, 1), '7');
      expect(digitText(tester, 2), '8');
      expect(digitText(tester, 3), '9');
      expect(digitText(tester, 4), isEmpty);
      expect(digitText(tester, 5), isEmpty);
      expect(digitHasFocus(tester, 4), isTrue);
      expect(submitButton(tester).onPressed, isNull);
      await disposeScreen(tester);
    });

    testWidgets('backspace on a FILLED box clears that box and '
        'focus stays on it', (tester) async {
      await pumpScreen(tester);
      await fillAllBoxes(tester, '123456');
      await tester.tap(digitFinder(3));
      await tester.pump();
      expect(digitHasFocus(tester, 3), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(digitText(tester, 3), isEmpty);
      // Joined code drops the cleared box's digit, order preserved.
      expect(enteredCode(tester), '12356');
      expect(digitHasFocus(tester, 3), isTrue);
      expect(submitButton(tester).onPressed, isNull);
      await disposeScreen(tester);
    });

    testWidgets('backspace on an EMPTY box deletes the previous '
        'box\'s digit and moves focus back to it', (tester) async {
      await pumpScreen(tester);
      await enterIntoBox(tester, 0, '123');
      expect(enteredCode(tester), '123');
      // Distribution leaves focus on the next (empty) box.
      expect(digitHasFocus(tester, 3), isTrue);
      expect(digitText(tester, 3), isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(digitText(tester, 2), isEmpty);
      expect(enteredCode(tester), '12');
      expect(digitHasFocus(tester, 2), isTrue);
      // Again from the now-empty box 2: clears box 1, focuses it.
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(digitText(tester, 1), isEmpty);
      expect(enteredCode(tester), '1');
      expect(digitHasFocus(tester, 1), isTrue);
      await disposeScreen(tester);
    });

    testWidgets('verify tap sends "001234" as the string "001234" '
        '(Vera R38) and success fires onVerified exactly once', (tester) async {
      var verifiedCalls = 0;
      final backend = await pumpScreen(
        tester,
        onVerified: () => verifiedCalls++,
      );
      await fillAllBoxes(tester, '001234');
      await tester.tap(find.byKey(const ValueKey('verify_submit')));
      await tester.pump();
      await tester.pump();
      expect(backend.verifyCalls, 1);
      expect(backend.lastCode, '001234');
      expect(backend.lastCode, isA<String>());
      expect(verifiedCalls, 1);
      await disposeScreen(tester);
    });

    testWidgets('while verifying: spinner, all actions disabled', (
      tester,
    ) async {
      var verifiedCalls = 0;
      final backend = await pumpScreen(
        tester,
        onVerified: () => verifiedCalls++,
      );
      backend.verifyGate = Completer<VerifyEmailOutcome>();
      await fillAllBoxes(tester, '123456');
      await tester.tap(find.byKey(const ValueKey('verify_submit')));
      await tester.pump();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('verify_submit')),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(submitButton(tester).onPressed, isNull);
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('verify_escape')))
            .onPressed,
        isNull,
      );
      backend.verifyGate!.complete(const VerifyEmailSuccess());
      await tester.pump();
      await tester.pump();
      expect(verifiedCalls, 1);
      await disposeScreen(tester);
    });

    testWidgets('rejection: the ONE generic Juno error, ALL six '
        'boxes cleared, focus back on the first box, Verify '
        'disabled again — no server string, no attempts remaining', (
      tester,
    ) async {
      final backend = await pumpScreen(tester);
      backend.verifyOutcome = const VerifyEmailRejected();
      await fillAllBoxes(tester, '999999');
      await tester.tap(find.byKey(const ValueKey('verify_submit')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('verify_error')), findsOneWidget);
      expect(find.text(_genericError), findsOneWidget);
      expect(find.textContaining('attempt'), findsNothing);
      expect(enteredCode(tester), isEmpty);
      for (var i = 0; i < 6; i++) {
        expect(digitText(tester, i), isEmpty, reason: 'box $i');
      }
      expect(digitHasFocus(tester, 0), isTrue);
      expect(submitButton(tester).onPressed, isNull);
      await disposeScreen(tester);
    });

    testWidgets('unreachable: network string, digits KEPT in all '
        'six boxes', (tester) async {
      final backend = await pumpScreen(tester);
      backend.verifyOutcome = const VerifyEmailUnreachable();
      await fillAllBoxes(tester, '123456');
      await tester.tap(find.byKey(const ValueKey('verify_submit')));
      await tester.pump();
      await tester.pump();
      expect(find.text(_networkError), findsOneWidget);
      expect(enteredCode(tester), '123456');
      await disposeScreen(tester);
    });

    testWidgets('resend: countdown ticks down deadline-based, '
        'enables at 0, tap sends, confirmation shows and the '
        'countdown restarts at 60', (tester) async {
      final clock = FakeClock();
      final backend = await pumpScreen(tester, clock: clock);
      expect(find.text('Resend code in 1:00'), findsOneWidget);
      clock.advance(const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Resend code in 0:30'), findsOneWidget);
      clock.advance(const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Resend code'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('verify_resend')));
      await tester.pump();
      await tester.pump();
      expect(backend.resendCalls, 1);
      expect(find.text('A new code was sent to $_email'), findsOneWidget);
      expect(find.text('Resend code in 1:00'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('resend 429: the server retryAfterSeconds is '
        'adopted as the new countdown, with Juno\'s wait string', (
      tester,
    ) async {
      final clock = FakeClock();
      final backend = await pumpScreen(tester, clock: clock);
      backend.resendOutcome = const ResendVerificationCooldown(120);
      clock.advance(const Duration(seconds: 60));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Resend code'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('verify_resend')));
      await tester.pump();
      await tester.pump();
      expect(
        find.text('Please wait 2:00 before requesting another code.'),
        findsOneWidget,
      );
      expect(find.text('Resend code in 2:00'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('escape tap fires onEscape', (tester) async {
      var escapes = 0;
      await pumpScreen(tester, onEscape: () => escapes++);
      await tester.tap(find.byKey(const ValueKey('verify_escape')));
      await tester.pump();
      expect(escapes, 1);
      await disposeScreen(tester);
    });

    testWidgets('timer hygiene: unmount mid-cooldown leaves no '
        'pending timer', (tester) async {
      await pumpScreen(tester);
      await tester.pump(const Duration(seconds: 10));
      await disposeScreen(tester);
      await tester.pump(const Duration(seconds: 120));
      // Reaching here without a pending-timer failure is the
      // assertion (the harness enforces it at test end).
    });
  });

  group('TabsBackend verify/resend outcome mapping', () {
    TabsBackend backendFor(
      Future<http.Response> Function(http.Request) handler,
    ) =>
        TabsBackend(client: MockClient(handler), sessionStore: _store());

    test('verify: code "001234" is POSTed as the JSON string '
        '"001234" in the body (never a number, never in the URL)',
        () async {
      late http.Request captured;
      final backend = backendFor((request) async {
        captured = request;
        return http.Response('{}', 200);
      });
      final outcome = await backend.verifyEmailCode('001234');
      expect(outcome, isA<VerifyEmailSuccess>());
      expect(captured.url.path, '/api/auth/verify-email');
      expect(captured.url.query, isEmpty);
      expect(captured.headers['Authorization'], 'Bearer fake-access');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['code'], '001234');
      expect(body['code'], isA<String>());
    });

    test('verify no-oracle: 400-wrong, 400-expired-shaped, 410 and '
        '429 bodies all collapse to the SAME Rejected outcome',
        () async {
      for (final (status, body) in [
        (400, '{"error":"That code didn\'t work."}'),
        (400, '{"error":"Code expired"}'),
        (410, '{"error":"gone"}'),
        (429, '{"error":"slow down"}'),
      ]) {
        final backend =
            backendFor((_) async => http.Response(body, status));
        final outcome = await backend.verifyEmailCode('123456');
        expect(outcome, isA<VerifyEmailRejected>(), reason: '$status');
      }
    });

    test('verify: transport failure and 5xx are Unreachable',
        () async {
      final throwing = backendFor(
          (_) async => throw const SocketException('off'));
      expect(await throwing.verifyEmailCode('123456'),
          isA<VerifyEmailUnreachable>());
      final fiveHundred =
          backendFor((_) async => http.Response('boom', 500));
      expect(await fiveHundred.verifyEmailCode('123456'),
          isA<VerifyEmailUnreachable>());
    });

    test('resend: 200 → Sent; 429 adopts retryAfterSeconds; 429 '
        'without the field defaults to 60; transport/5xx → '
        'Unreachable; other definitive → Failed', () async {
      final sent = backendFor((_) async => http.Response('{}', 200));
      expect(await sent.resendVerificationCode(),
          isA<ResendVerificationSent>());

      final cooldown = backendFor((_) async =>
          http.Response('{"retryAfterSeconds":42}', 429));
      final cooldownOutcome = await cooldown.resendVerificationCode();
      expect(cooldownOutcome, isA<ResendVerificationCooldown>());
      expect(
          (cooldownOutcome as ResendVerificationCooldown)
              .retryAfterSeconds,
          42);

      final bareCooldown =
          backendFor((_) async => http.Response('{}', 429));
      final bareOutcome = await bareCooldown.resendVerificationCode();
      expect(
          (bareOutcome as ResendVerificationCooldown)
              .retryAfterSeconds,
          60);

      final throwing = backendFor(
          (_) async => throw const SocketException('off'));
      expect(await throwing.resendVerificationCode(),
          isA<ResendVerificationUnreachable>());
      final fiveHundred =
          backendFor((_) async => http.Response('boom', 503));
      expect(await fiveHundred.resendVerificationCode(),
          isA<ResendVerificationUnreachable>());
      final forbidden =
          backendFor((_) async => http.Response('no', 403));
      expect(await forbidden.resendVerificationCode(),
          isA<ResendVerificationFailed>());
    });
  });
}
