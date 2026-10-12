import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/main.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/slide_page_route.dart';

/// Round 22 — navigation transition regression tests.
///
/// The founder's screen recording showed pushes FLASHING: the incoming
/// screen faded in over the outgoing one, so both screens' titles were
/// visible at once (ghosting). Root cause: Quick Log → History/Trends
/// and Health Coach → chat used MaterialPageRoute while the app had no
/// theme, so they got Material 3's fade-based default; other pushes
/// used SlidePageRoute's pure slide. These tests pin the fix:
/// - every push slides in from the right with NO fade anywhere,
/// - routes are opaque,
/// - MaterialPageRoute inherits the same slide from the app theme,
/// - reduced motion makes pushes instant.
void main() {
  group('SlidePageRoute (Round 22)', () {
    test('is opaque with a 300ms slide by default', () {
      final route = SlidePageRoute<void>(builder: (_) => const SizedBox());
      expect(route.opaque, isTrue);
      expect(route.transitionDuration, const Duration(milliseconds: 300));
      expect(
          route.reverseTransitionDuration, const Duration(milliseconds: 300));
    });

    test('reduced motion zeroes both durations', () {
      final route = SlidePageRoute<void>(
        reducedMotion: true,
        builder: (_) => const SizedBox(),
      );
      expect(route.opaque, isTrue);
      expect(route.transitionDuration, Duration.zero);
      expect(route.reverseTransitionDuration, Duration.zero);
    });

    testWidgets('slides in from the right with no fade wrapper',
        (tester) async {
      await tester.pumpWidget(_harness());
      await tester.tap(find.text('Push'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150)); // mid-transition

      // Incoming page is part-way in from the right…
      expect(tester.getTopLeft(find.text('Target')).dx, greaterThan(0));
      // …carried by a SlideTransition, with NO FadeTransition around it
      // (a fade is what let the previous screen ghost through).
      expect(
        find.ancestor(
            of: find.text('Target'), matching: find.byType(SlideTransition)),
        findsWidgets,
      );
      expect(
        find.ancestor(
            of: find.text('Target'), matching: find.byType(FadeTransition)),
        findsNothing,
      );

      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('Target')).dx, 0);
    });

    testWidgets('reducedMotion: true lands instantly, no slide offset',
        (tester) async {
      await tester.pumpWidget(_harness(reducedMotion: true));
      await tester.tap(find.text('Push'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('Target'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Target')).dx, 0);
      await tester.pumpAndSettle();
    });

    testWidgets('system reduced motion (MediaQuery) makes the slide instant',
        (tester) async {
      await tester.pumpWidget(_harness(disableAnimations: true));
      await tester.tap(find.text('Push'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('Target'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Target')).dx, 0);
      await tester.pumpAndSettle();
    });
  });

  group('App theme (Round 22)', () {
    testWidgets('MaterialPageRoute under the app theme slides, never fades',
        (tester) async {
      await tester.pumpWidget(_harness(useMaterialRoute: true));
      await tester.tap(find.text('Push'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150)); // mid-transition

      expect(tester.getTopLeft(find.text('Target')).dx, greaterThan(0));
      expect(
        find.ancestor(
            of: find.text('Target'), matching: find.byType(FadeTransition)),
        findsNothing,
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('Target')).dx, 0);
    });

    testWidgets('TabsLabApp carries the slide theme + opaque scaffold color',
        (tester) async {
      await tester.pumpWidget(const TabsLabApp());
      final context = tester.element(find.byType(AppFlow));
      final theme = Theme.of(context);
      expect(
        theme.pageTransitionsTheme.builders[TargetPlatform.android],
        isA<SlidePageTransitionsBuilder>(),
      );
      expect(theme.scaffoldBackgroundColor, NotelColors.background);
      // Drain the splash timers so the test ends clean.
      await tester.pump(const Duration(milliseconds: 1900));
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
    });
  });
}

Widget _harness({
  bool reducedMotion = false,
  bool disableAnimations = false,
  bool useMaterialRoute = false,
}) {
  return MaterialApp(
    theme: ThemeData(
      scaffoldBackgroundColor: NotelColors.background,
      pageTransitionsTheme: slidePageTransitionsTheme(),
    ),
    builder: disableAnimations
        ? (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(disableAnimations: true),
              child: child!,
            )
        : null,
    home: _PushHome(
      reducedMotion: reducedMotion,
      useMaterialRoute: useMaterialRoute,
    ),
  );
}

class _PushHome extends StatelessWidget {
  final bool reducedMotion;
  final bool useMaterialRoute;
  const _PushHome({this.reducedMotion = false, this.useMaterialRoute = false});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      body: Center(
        child: TextButton(
          onPressed: () {
            if (useMaterialRoute) {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                    builder: (_) => const _TargetScreen()),
              );
            } else {
              Navigator.of(context).push(
                SlidePageRoute<void>(
                  // Mirrors the production call sites exactly.
                  reducedMotion:
                      reducedMotion || animationsDisabled(context),
                  builder: (_) => const _TargetScreen(),
                ),
              );
            }
          },
          child: const Text('Push'),
        ),
      ),
    );
  }
}

class _TargetScreen extends StatelessWidget {
  const _TargetScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: NotelColors.background,
      body: Align(
        alignment: Alignment.topLeft,
        child: Text('Target'),
      ),
    );
  }
}
