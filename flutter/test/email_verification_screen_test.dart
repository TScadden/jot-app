import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/auth/email_verification_screen.dart';

import 'test_helpers.dart';

/// VC 100134 Package C — email verification screen + backend
/// outcome mapping tests. All strings asserted here are Juno's
/// verbatim copy (juno-copy-privacy.md §2 / §2.1).

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

ElevatedButton submitButton(WidgetTester tester) => tester.widget(
    find.byKey(const ValueKey('verify_submit')));

TextField codeField(WidgetTester tester) => tester
    .widget(find.byKey(const ValueKey('verify_code_field')));

void main() {
  group('EmailVerificationScreen', () {
    testWidgets('renders Juno\'s strings with the account email '
        'interpolated; Verify disabled; Resend in cooldown',
        (tester) async {
      await pumpScreen(tester);
      expect(find.text('Verify your email'), findsOneWidget);
      expect(find.text('We sent a code to $_email'), findsOneWidget);
      expect(
        find.text(
            "Enter the 6-digit code to finish creating your account. If you don't see the email, check your spam folder."),
        findsOneWidget,
      );
      expect(find.text('Verification code'), findsOneWidget);
      expect(find.text('6-digit code'), findsOneWidget);
      expect(find.text('Verify'), findsOneWidget);
      expect(find.text('Resend code in 1:00'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
      expect(submitButton(tester).onPressed, isNull);
      final resend = tester.widget<TextButton>(
          find.byKey(const ValueKey('verify_resend')));
      expect(resend.onPressed, isNull);
      await disposeScreen(tester);
    });

    testWidgets('typing: 5 digits keeps Verify disabled, the 6th '
        'enables it; non-digits and a 7th digit are rejected',
        (tester) async {
      await pumpScreen(tester);
      final field = find.byKey(const ValueKey('verify_code_field'));
      await tester.enterText(field, '12345');
      await tester.pump();
      expect(submitButton(tester).onPressed, isNull);
      await tester.enterText(field, '123456');
      await tester.pump();
      expect(submitButton(tester).onPressed, isNotNull);
      // Formatters: letters never land, length caps at 6.
      await tester.enterText(field, '12a34567');
      await tester.pump();
      expect(codeField(tester).controller!.text, '123456');
      await disposeScreen(tester);
    });

    testWidgets('verify tap sends "001234" as the string "001234" '
        '(Vera R38) and success fires onVerified exactly once',
        (tester) async {
      var verifiedCalls = 0;
      final backend =
          await pumpScreen(tester, onVerified: () => verifiedCalls++);
      await tester.enterText(
          find.byKey(const ValueKey('verify_code_field')), '001234');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('verify_submit')));
      await tester.pump();
      await tester.pump();
      expect(backend.verifyCalls, 1);
      expect(backend.lastCode, '001234');
      expect(backend.lastCode, isA<String>());
      expect(verifiedCalls, 1);
      await disposeScreen(tester);
    });

    testWidgets('while verifying: spinner, all actions disabled',
        (tester) async {
      var verifiedCalls = 0;
      final backend =
          await pumpScreen(tester, onVerified: () => verifiedCalls++);
      backend.verifyGate = Completer<VerifyEmailOutcome>();
      await tester.enterText(
          find.byKey(const ValueKey('verify_code_field')), '123456');
      await tester.pump();
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
            .widget<TextButton>(
                find.byKey(const ValueKey('verify_escape')))
            .onPressed,
        isNull,
      );
      backend.verifyGate!.complete(const VerifyEmailSuccess());
      await tester.pump();
      await tester.pump();
      expect(verifiedCalls, 1);
      await disposeScreen(tester);
    });

    testWidgets('rejection: the ONE generic Juno error, field '
        'cleared, Verify disabled again — no server string, no '
        'attempts remaining', (tester) async {
      final backend = await pumpScreen(tester);
      backend.verifyOutcome = const VerifyEmailRejected();
      await tester.enterText(
          find.byKey(const ValueKey('verify_code_field')), '999999');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('verify_submit')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('verify_error')), findsOneWidget);
      expect(find.text(_genericError), findsOneWidget);
      expect(find.textContaining('attempt'), findsNothing);
      expect(codeField(tester).controller!.text, isEmpty);
      expect(submitButton(tester).onPressed, isNull);
      await disposeScreen(tester);
    });

    testWidgets('unreachable: network string, field content kept',
        (tester) async {
      final backend = await pumpScreen(tester);
      backend.verifyOutcome = const VerifyEmailUnreachable();
      await tester.enterText(
          find.byKey(const ValueKey('verify_code_field')), '123456');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('verify_submit')));
      await tester.pump();
      await tester.pump();
      expect(find.text(_networkError), findsOneWidget);
      expect(codeField(tester).controller!.text, '123456');
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
        'adopted as the new countdown, with Juno\'s wait string',
        (tester) async {
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
        find.text(
            'Please wait 2:00 before requesting another code.'),
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
