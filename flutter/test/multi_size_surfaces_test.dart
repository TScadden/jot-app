import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/badge_store.dart';
import 'package:tabs_lab/src/features/auth/login_screen.dart';
import 'package:tabs_lab/src/features/badges/badges_screen.dart';
import 'package:tabs_lab/src/features/onboarding/consultation_intro_screen.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_header.dart';
import 'package:tabs_lab/src/features/onboarding/welcome_screen.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';
import 'package:tabs_lab/src/features/shell/tablet_content_shell.dart';
import 'package:tabs_lab/src/features/tools/tools_screen.dart';

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
/// - Wide-size behaviour is ASSERTED, not characterized (tablet
///   width adaptation, adopted Nov 27, 2026 — DECISION.md): the
///   TabletContentShell caps the content column at 680dp, Tools goes
///   4-up and Badges 5-up at/above the single-sourced 600dp
///   effective-width breakpoint, and the nav dock is capped at the
///   column. The tablet-adaptation groups at the bottom of this file
///   (Vera P2-3 / P2-6) assert all of it directly, and assert the
///   phone gate (shell never binds, phone grid counts) at 360dp,
///   390dp, and a <600dp split-pane width.
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

/// Pumps [child] the way production composes it: the
/// [TabletContentShell] sits in `MaterialApp.builder`, wrapping the
/// navigator child inside the presenter chain (main.dart), so routes
/// — and everything inside them, dock included — lay out in the
/// capped column. The extra pumps run the Tools entrance animation
/// (300ms) to its final layout before any geometry is read.
Future<void> _pumpShellAt(
  WidgetTester tester,
  Size size,
  Widget child,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, navChild) => TabletContentShell(
        child: navChild ?? const SizedBox.shrink(),
      ),
      home: child,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump();
}

/// The render-object width of the shell, found via its shipped
/// marker key (`tabletContentShell`) — the same string the
/// shipped-binary grep gate looks for.
double _shellRenderWidth(WidgetTester tester) =>
    tester.getSize(find.byKey(const ValueKey('tabletContentShell'))).width;

/// The crossAxisCount of every GridView currently in the tree,
/// read straight off the delegates — a direct count assertion, not
/// a tile-size inference.
List<int> _gridCounts(WidgetTester tester) => [
      for (final grid in tester.widgetList<GridView>(find.byType(GridView)))
        (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
    ];

bool _realFontsLoaded = false;

/// Loads the app's bundled Roboto (the effective default family for
/// the Tools card text) so text metrics in the Tools tests are the
/// product's real metrics. The default widget-test font draws every
/// glyph a full em wide: titles wrap that never wrap on device and
/// the 4-up card's inner Column overflows by ~13dp — a test-font
/// artifact, not product geometry (with real metrics the card's
/// content tops out at ~92dp of the 117.5dp available at 4-up).
/// Same FontLoader pattern as the repo's capture harnesses. Row
/// assertions below read grid CELLS, never text, so counts and
/// rows do not depend on glyph metrics either way.
Future<void> _loadRealFonts(WidgetTester tester) async {
  if (_realFontsLoaded) return;
  await tester.runAsync(() async {
    final loader = FontLoader('Roboto');
    loader.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
    loader.addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
    await loader.load();
  });
  _realFontsLoaded = true;
}

/// The grid's cells in row-major order: each Tools cell's root is
/// the LayoutBuilder that sizes the drag feedback, so cell sizes
/// and positions are exact grid geometry, independent of fonts.
Finder _gridCells() => find.descendant(
      of: find.byType(GridView),
      matching: find.byType(LayoutBuilder),
    );

ToolOrderStore _fakeToolStore() {
  final map = <String, String>{};
  final store = ToolOrderStore();
  store.debugSetIO(
    read: (k) async => map[k],
    write: (k, v) async => map[k] = v,
  );
  return store;
}

Future<BadgeService> _fakeBadgeService() async {
  final disk = <String, String>{};
  final svc = BadgeService(
    grant: (_) async => (
      statusCode: 200,
      body: {'gemBalance': 500, 'alreadyGranted': false},
    ),
  );
  svc.debugSetStore(
    read: (k) async => disk[k],
    write: (k, v) async => disk[k] = v,
    delete: (k) async => disk.remove(k),
  );
  await svc.ensureLoaded();
  return svc;
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

  group('wide-size assertion (tablet adaptation adopted, P2-3)', () {
    testWidgets('login form is capped by the shell at 1180dp',
        (tester) async {
      await _pumpShellAt(
        tester,
        const Size(1180, 820),
        const LoginScreen(initialRegisterMode: false),
      );
      expect(tester.takeException(), isNull);
      // Flipped from the Phase 1 characterization (which asserted
      // the old stretched layout, fieldWidth > 600 with no shell):
      // inside the shell the column is exactly the 680 cap and the
      // form can never exceed it.
      expect(_shellRenderWidth(tester), 680);
      final fieldWidth = tester.getSize(find.byType(TextField).first).width;
      expect(fieldWidth, lessThanOrEqualTo(680));
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

  // ── Tablet width adaptation, Phase 2 (Vera P2-3 / P2-6) ─────
  //
  // Wide sizes assert the treatment DIRECTLY: shell render width
  // via the tabletContentShell marker key, grid counts off the
  // delegates plus filled-row geometry, dock width, and no
  // overflow exceptions. Phone sizes assert the hard gate: the
  // shell never binds (render width == window width) and the grid
  // counts stay at today's phone values.

  const wideSizes = <String, Size>{
    '820x1180': Size(820, 1180),
    '1180x820': Size(1180, 820),
    '915x412': Size(915, 412),
  };

  group('tablet adaptation assertions at wide sizes (P2-3)', () {
    for (final entry in wideSizes.entries) {
      testWidgets('shell caps at 680, Tools 4-up — ${entry.key}',
          (tester) async {
        await _loadRealFonts(tester);
        await _pumpShellAt(
          tester,
          entry.value,
          ToolsScreen(orderStore: _fakeToolStore()),
        );
        expect(tester.takeException(), isNull);
        expect(_shellRenderWidth(tester), 680);
        // Direct count: the delegate itself.
        expect(_gridCounts(tester), [4]);
        // Filled-row geometry: the first four CELLS share a row,
        // the fifth wraps below them (13 tiles on the screen, so
        // a filled 4-up row is genuinely observed).
        final cells = _gridCells();
        expect(cells, findsWidgets);
        final tops = [
          for (var i = 0; i < 5; i++) tester.getTopLeft(cells.at(i)).dy,
        ];
        for (final top in tops.sublist(1, 4)) {
          expect(top, closeTo(tops.first, 1.0));
        }
        expect(tops[4], greaterThan(tops.first));
        expect(tester.takeException(), isNull);
      });

      testWidgets('shell caps at 680, Badges 5-up — ${entry.key}',
          (tester) async {
        final svc = await _fakeBadgeService();
        await _pumpShellAt(
          tester,
          entry.value,
          BadgesScreen(service: svc, onOpenHcSettings: () async {}),
        );
        // Bring the first section's grid into the built tree at
        // short heights before reading its geometry.
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('badge_tile_total_logs')),
          120,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(_shellRenderWidth(tester), 680);
        // Direct count: every built section grid's delegate is 5.
        final counts = _gridCounts(tester);
        expect(counts, isNotEmpty);
        expect(counts, everyElement(5));
        // The Logging section's three tiles sit in ONE row at the
        // 5-up cell width: (680 − 32 list padding − 4×8 spacing)/5
        // = 123.2dp. Production sections hold exactly 3 metrics
        // each, so a filled production row of 5 cannot exist; the
        // filled-row observation for this delegate geometry is the
        // dedicated fixture test below.
        final tiles = [
          for (final id in ['total_logs', 'logs_in_day', 'morning_logger'])
            find.byKey(ValueKey('badge_tile_$id')),
        ];
        final tops = [for (final t in tiles) tester.getTopLeft(t).dy];
        for (final top in tops.skip(1)) {
          expect(top, closeTo(tops.first, 1.0));
        }
        expect(tester.getSize(tiles.first).width, closeTo(123.2, 2.0));
        expect(tester.takeException(), isNull);
      });

      testWidgets('dock width capped at the column — ${entry.key}',
          (tester) async {
        // The production NavDock, mounted the way MainShell mounts
        // it: a full-width Positioned overlay at the bottom of a
        // Stack, inside the shell.
        await _pumpShellAt(
          tester,
          entry.value,
          Scaffold(
            body: Stack(
              children: [
                const SizedBox.expand(),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: NavDock(
                    selected: DockTab.home,
                    onSelect: (_) {},
                  ),
                ),
              ],
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(_shellRenderWidth(tester), 680);
        expect(tester.getSize(find.byType(NavDock)).width, 680);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets(
        'badges filled-row fixture: a >=5-badge row fills 5-up at the cap',
        (tester) async {
      // Production badge sections hold exactly 3 metrics each
      // (BadgeMetrics), and Juno C3 forbids touching production
      // data to manufacture more — so the filled 5-up row is
      // observed on this fixture, which carries the production
      // delegate's exact values (count keyed off the same
      // single-sourced breakpoint at the capped width, spacing
      // 8/8, aspect 0.55, the Badges ListView's 16dp side padding).
      // The production screen's own count is asserted directly off
      // its delegate in the Badges tests above; this fixture proves
      // what that delegate does with >=5 items: five across, the
      // sixth wraps.
      await _pumpShellAt(
        tester,
        const Size(820, 1180),
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LayoutBuilder(
              builder: (context, constraints) => GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: constraints.maxWidth >=
                          TabletContentShell.wideBreakpoint
                      ? 5
                      : 3,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  childAspectRatio: 0.55,
                ),
                itemCount: 6,
                itemBuilder: (context, i) => SizedBox(
                  key: ValueKey('badges_fixture_tile_$i'),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(_shellRenderWidth(tester), 680);
      final tops = [
        for (var i = 0; i < 6; i++)
          tester
              .getTopLeft(find.byKey(ValueKey('badges_fixture_tile_$i')))
              .dy,
      ];
      for (final top in tops.sublist(1, 5)) {
        expect(top, closeTo(tops.first, 1.0));
      }
      expect(tops[5], greaterThan(tops.first));
      expect(tester.takeException(), isNull);
    });
  });

  const phoneSizes = <String, Size>{
    '360x800': Size(360, 800),
    '390x844': Size(390, 844),
    'split pane 500x800 (<600dp wide)': Size(500, 800),
  };

  group('phone gate assertions (P2-6)', () {
    for (final entry in phoneSizes.entries) {
      testWidgets('shell never binds, Tools stays 2-up — ${entry.key}',
          (tester) async {
        await _loadRealFonts(tester);
        await _pumpShellAt(
          tester,
          entry.value,
          ToolsScreen(orderStore: _fakeToolStore()),
        );
        expect(tester.takeException(), isNull);
        expect(_shellRenderWidth(tester), entry.value.width);
        expect(_gridCounts(tester), [2]);
        // Cell geometry: two across, the third wraps.
        final cells = _gridCells();
        final tops = [
          for (var i = 0; i < 3; i++) tester.getTopLeft(cells.at(i)).dy,
        ];
        expect(tops[1], closeTo(tops[0], 1.0));
        expect(tops[2], greaterThan(tops[0]));
        expect(tester.takeException(), isNull);
      });

      testWidgets('shell never binds, Badges stays 3-up — ${entry.key}',
          (tester) async {
        final svc = await _fakeBadgeService();
        await _pumpShellAt(
          tester,
          entry.value,
          BadgesScreen(service: svc, onOpenHcSettings: () async {}),
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('badge_tile_total_logs')),
          120,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        // Badges is a surface beyond the Home/Tools render pair:
        // the phone gate is asserted here in its own right.
        expect(_shellRenderWidth(tester), entry.value.width);
        final counts = _gridCounts(tester);
        expect(counts, isNotEmpty);
        expect(counts, everyElement(3));
        expect(tester.takeException(), isNull);
      });

      testWidgets('shell never binds on Login either — ${entry.key}',
          (tester) async {
        await _pumpShellAt(
          tester,
          entry.value,
          const LoginScreen(initialRegisterMode: false),
        );
        expect(tester.takeException(), isNull);
        expect(_shellRenderWidth(tester), entry.value.width);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
