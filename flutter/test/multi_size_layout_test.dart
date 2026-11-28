import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/auth/login_screen.dart';
import 'package:tabs_lab/src/features/home/daily_score_circle.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart';
import 'package:tabs_lab/src/features/onboarding/consultation_intro_screen.dart';
import 'package:tabs_lab/src/features/onboarding/welcome_screen.dart';
import 'package:tabs_lab/src/features/quicklog/history_screen.dart';
import 'package:tabs_lab/src/features/tools/tools_screen.dart';

import 'test_helpers.dart';

/// SCORECARD-5 step 1 (Video-lessons Wave A) — the permanent
/// multi-size widget-test suite whose absence the scorecard flagged
/// as the multiplier on every layout risk: ~140 test surfaces in the
/// tree were all portrait phones, so a regression that pushes a
/// button off screen at a short, wide, split-pane, or tablet size
/// shipped silently.
///
/// Key surfaces are pumped at:
/// - short heights: 800x360 / 915x412 landscape phones, 390x420
///   split pane (the heights that broke the consultation intro),
/// - small / standard phones: 320x568, 390x844,
/// - wide / tablet: 820x1180 (iPad portrait), 1180x820 (iPad
///   landscape).
///
/// Assertions are the scorecard's acceptance shape: no layout
/// exception at any size, and the surface's primary action is
/// reachable (scroll-until-visible + tappable), not merely present
/// in the tree.

class _FakeAuthApi extends AuthApiClient {
  @override
  Future<LoginResult> login({
    required String email,
    required String password,
  }) async =>
      const LoginFailure(LoginFailureKind.server, 'fake');

  @override
  Future<LoginResult> register({
    required String email,
    required String password,
    required bool ageConfirmed,
  }) async =>
      const LoginFailure(LoginFailureKind.server, 'fake');

  @override
  Future<ForgotPasswordResult> forgotPassword({
    required String email,
  }) async =>
      const ForgotPasswordSuccess();
}

void _setSize(WidgetTester tester, Size logical) {
  tester.view.physicalSize = logical;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

const _sizes = <String, Size>{
  'small phone 320x568': Size(320, 568),
  'phone 390x844': Size(390, 844),
  'landscape phone 800x360': Size(800, 360),
  'landscape phone 915x412': Size(915, 412),
  'split pane 390x420': Size(390, 420),
  'tablet portrait 820x1180': Size(820, 1180),
  'tablet landscape 1180x820': Size(1180, 820),
};

void main() {
  setUp(() => TabsBackend.debugResetSharedCaches());

  group('ConsultationIntroScreen (SCORECARD-5 risk 1)', () {
    for (final entry in _sizes.entries) {
      testWidgets('Continue reachable, no overflow — ${entry.key}',
          (tester) async {
        _setSize(tester, entry.value);
        var continued = 0;
        await tester.pumpWidget(MaterialApp(
          home: ConsultationIntroScreen(
            onBack: () {},
            onContinue: () => continued++,
          ),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(find.text('Continue'), 120);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Continue'));
        await tester.pump();
        expect(continued, 1);
      });
    }
  });

  group('LoginScreen', () {
    for (final entry in _sizes.entries) {
      testWidgets('form renders, main action reachable — ${entry.key}',
          (tester) async {
        _setSize(tester, entry.value);
        await tester.pumpWidget(MaterialApp(
          home: LoginScreen(
            initialRegisterMode: false,
            authApi: _FakeAuthApi(),
            sessionStore: FakeSessionStore(),
          ),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(TextField), findsNWidgets(2));
        // The page scrollable is named explicitly: each TextField
        // carries its own internal Scrollable, so the default
        // byType(Scrollable) finder is ambiguous here.
        await tester.scrollUntilVisible(
          find.text('Log In'),
          120,
          scrollable: find.byType(SingleChildScrollView),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('WelcomeScreen', () {
    for (final entry in _sizes.entries) {
      testWidgets('buttons reachable, no overflow — ${entry.key}',
          (tester) async {
        _setSize(tester, entry.value);
        await tester.pumpWidget(MaterialApp(
          home: WelcomeScreen(onRegister: () {}, onLogin: () {}),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(find.text('Log In'), 120);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('VitalsStrip + streak stack + Daily Score face', () {
    for (final width in [320.0, 390.0, 820.0, 1180.0]) {
      testWidgets('no overflow at ${width.toInt()}dp wide',
          (tester) async {
        _setSize(tester, Size(width, 700));
        await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  VitalsStrip(animateCountUps: false),
                  HomeStreakStack(
                    currentStreak: 12,
                    animateCountUps: false,
                    gemBalance: 345,
                  ),
                  DailyScoreFace(score: 78, size: 100),
                ],
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('345'), findsOneWidget);
      });
    }
  });

  group('ToolsScreen (grid at tablet width)', () {
    for (final entry in {
      'phone 390x844': const Size(390, 844),
      'tablet portrait 820x1180': const Size(820, 1180),
      'tablet landscape 1180x820': const Size(1180, 820),
    }.entries) {
      testWidgets('renders without overflow — ${entry.key}',
          (tester) async {
        _setSize(tester, entry.value);
        final store = ToolOrderStore();
        final backing = <String, String>{};
        store.debugSetIO(
          read: (key) async => backing[key],
          write: (key, value) async => backing[key] = value,
        );
        await tester.pumpWidget(MaterialApp(
          home: ToolsScreen(orderStore: store),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('HistoryScreen (wide / tablet sizes)', () {
    for (final entry in {
      'landscape phone 800x360': const Size(800, 360),
      'tablet portrait 820x1180': const Size(820, 1180),
      'tablet landscape 1180x820': const Size(1180, 820),
    }.entries) {
      testWidgets('entries render without overflow — ${entry.key}',
          (tester) async {
        _setSize(tester, entry.value);
        final store = FakeSessionStore()..token = 'size-token';
        final client = MockClient((request) async {
          if (request.url.path == '/api/sync/pull') {
            return http.Response(
              jsonEncode({
                'entries': [
                  {
                    'id': 42,
                    'categoryId': 7,
                    'body': 'a history entry',
                    'chips': '["General"]',
                    'manualText': '',
                    'timestamp': DateTime(2026, 11, 12, 12, 42)
                        .millisecondsSinceEpoch,
                  },
                ],
                'categories': [
                  {
                    'id': 7,
                    'name': 'General',
                    'icon': 'circle',
                    'colorHex': '#CCCCCC',
                    'isDefault': true,
                    'sortOrder': 0,
                  },
                ],
                'profile': <String, dynamic>{},
                'isUnlimited': true,
                'isAdmin': false,
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        });
        final disk = <String, String>{};
        final outbox = LogEntryOutbox.instance;
        outbox.debugReset();
        outbox.debugSetStore(
          read: (key) async => disk[key],
          write: (key, value) async => disk[key] = value,
          delete: (key) async => disk.remove(key),
        );
        await tester.pumpWidget(MaterialApp(
          home: HistoryScreen(
            backend: TabsBackend(client: client, sessionStore: store),
            outbox: outbox,
          ),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('a history entry'), findsOneWidget);
      });
    }
  });
}
