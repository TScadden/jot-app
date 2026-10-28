import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/main.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weekly_snapshot.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/feeling_checkin_card.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/home/weekly_snapshot_card.dart';
import 'package:tabs_lab/src/features/quicklog/history_screen.dart';
import 'package:tabs_lab/src/features/splash/splash_screen.dart';
import 'package:tabs_lab/src/features/tools/health_coach_screen.dart';
import 'package:tabs_lab/src/features/tools/tools_screen.dart';

import 'test_helpers.dart';

/// Oct 27, 2026 industry-standards audit, surface 6 closures:
/// 6c reduced-motion gates (splash entry, splash exit, feeling
/// check-in), 6a 48dp touch targets (Tools Done pill, Weekly Snapshot
/// dropdown rows), 6d semantics labels (five icon buttons).

/// Wraps [child] in a MaterialApp whose MediaQuery carries the given
/// reduced-motion flag (copyWith preserves the real size etc.).
Widget _wrap(Widget child, {bool disableAnimations = false}) {
  return MaterialApp(
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(disableAnimations: disableAnimations),
        child: child,
      ),
    ),
  );
}

/// Asserts the house labelling pattern in semantics terms: exactly
/// one widget carries a tooltip with [label], and that tooltip is
/// exposed on its semantics node (SemanticsData.tooltip — what
/// TalkBack announces for the button).
void expectLabel(WidgetTester tester, String label) {
  final finder = find.byTooltip(label);
  expect(finder, findsOneWidget, reason: label);
  expect(tester.getSemantics(finder).getSemanticsData().tooltip, label,
      reason: label);
}

void main() {
  setUp(TabsBackend.debugResetSharedCaches);

  group('6c splash entry (SplashScreen)', () {
    testWidgets('reduced motion: final state instantly, no transforms',
        (tester) async {
      await tester.pumpWidget(
          _wrap(const SplashScreen(), disableAnimations: true));
      await tester.pump();
      expect(find.text('Tabs'), findsOneWidget);
      expect(find.text('Health & Symptom Intelligence'), findsOneWidget);
      // No fade/scale wrappers are applied at all.
      expect(
        find.ancestor(of: find.text('Tabs'), matching: find.byType(Opacity)),
        findsNothing,
      );
      expect(
        find.ancestor(of: find.text('Tabs'), matching: find.byType(Transform)),
        findsNothing,
      );
    });

    testWidgets('motion on: 650ms fade/scale entry unchanged',
        (tester) async {
      await tester.pumpWidget(_wrap(const SplashScreen()));
      await tester.pump();
      final opacity = tester.widget<Opacity>(find.ancestor(
          of: find.text('Tabs'), matching: find.byType(Opacity)));
      expect(opacity.opacity, lessThan(0.5));
      await tester.pump(const Duration(milliseconds: 700));
      final done = tester.widget<Opacity>(find.ancestor(
          of: find.text('Tabs'), matching: find.byType(Opacity)));
      expect(done.opacity, 1.0);
      final transform = tester.widget<Transform>(find.ancestor(
          of: find.text('Tabs'), matching: find.byType(Transform)));
      expect(transform.transform.storage[0], closeTo(1.05, 0.001));
    });
  });

  group('6c splash exit (AppFlow)', () {
    testWidgets('reduced motion: splash removed instantly after hold, '
        'no sweep', (tester) async {
      await tester.pumpWidget(_wrap(const AppFlow(), disableAnimations: true));
      await tester.pump();
      expect(find.text('Health & Symptom Intelligence'), findsOneWidget);
      // Entry (650) + hold (1200) elapse: splash is gone immediately,
      // without the extra 650ms sweep.
      await tester.pump(const Duration(milliseconds: 1850));
      await tester.pump();
      expect(find.text('Health & Symptom Intelligence'), findsNothing);
    });

    testWidgets('motion on: splash sweeps for 650ms before leaving',
        (tester) async {
      await tester.pumpWidget(_wrap(const AppFlow()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1850));
      await tester.pump();
      // Sweep has only just started: splash still on screen.
      expect(find.text('Health & Symptom Intelligence'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Health & Symptom Intelligence'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.text('Health & Symptom Intelligence'), findsNothing);
    });
  });

  group('6c feeling check-in card', () {
    testWidgets('reduced motion entry: no slide/fade transitions',
        (tester) async {
      await tester.pumpWidget(_wrap(
        Scaffold(body: FeelingCheckInCard(onSelect: (_) {})),
        disableAnimations: true,
      ));
      await tester.pump();
      expect(find.text('How are you feeling?'), findsOneWidget);
      final slides = tester.widgetList<SlideTransition>(find.ancestor(
          of: find.text('How are you feeling?'),
          matching: find.byType(SlideTransition)));
      for (final s in slides) {
        expect(s.position.value, Offset.zero);
      }
      final fades = tester.widgetList<FadeTransition>(find.ancestor(
          of: find.text('How are you feeling?'),
          matching: find.byType(FadeTransition)));
      for (final f in fades) {
        expect(f.opacity.value, 1.0);
      }
    });

    testWidgets('motion on entry: slides from -fullWidth to rest',
        (tester) async {
      await tester.pumpWidget(_wrap(
        Scaffold(body: FeelingCheckInCard(onSelect: (_) {})),
      ));
      await tester.pump();
      List<SlideTransition> slides() =>
          tester.widgetList<SlideTransition>(find.ancestor(
              of: find.text('How are you feeling?'),
              matching: find.byType(SlideTransition))).toList();
      // The card's own entrance starts at -fullWidth.
      expect(
        slides().any((s) => s.position.value.dx < -0.95),
        isTrue,
      );
      await tester.pump(const Duration(milliseconds: 450));
      for (final s in slides()) {
        expect(s.position.value, Offset.zero);
      }
    });

    testWidgets('reduced motion exit: completes instantly, no 350ms wait',
        (tester) async {
      await tester.pumpWidget(
          _wrap(const _FeelingHarness(), disableAnimations: true));
      await tester.pump();
      expect(find.text('How are you feeling?'), findsOneWidget);
      await tester.tap(find.text('leave'));
      await tester.pump();
      await tester.pump();
      expect(find.text('How are you feeling?'), findsNothing);
    });

    testWidgets('motion on exit: card slides away over 350ms',
        (tester) async {
      await tester.pumpWidget(_wrap(const _FeelingHarness()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450)); // entrance done
      await tester.tap(find.text('leave'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Mid-exit: still on screen.
      expect(find.text('How are you feeling?'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.text('How are you feeling?'), findsNothing);
    });
  });

  group('6a touch targets', () {
    testWidgets('Tools Done pill: hit height >= 48dp, pill visual < 48dp, '
        'tap in the expanded area exits edit mode', (tester) async {
      final store = ToolOrderStore();
      final backing = <String, String>{};
      store.debugSetIO(
        read: (key) async => backing[key],
        write: (key, value) async => backing[key] = value,
      );
      await tester.pumpWidget(MaterialApp(home: ToolsScreen(orderStore: store)));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.swap_vert));
      await tester.pumpAndSettle();
      expect(find.text('Done'), findsOneWidget);

      final detector = find.ancestor(
          of: find.text('Done'), matching: find.byType(GestureDetector));
      expect(tester.getSize(detector.first).height,
          greaterThanOrEqualTo(48));

      // The visible pill itself is unchanged (~28dp: 6+6 padding +
      // 13sp text + icon row).
      final pill = find.ancestor(
        of: find.text('Done'),
        matching: find.byWidgetPredicate((w) =>
            w is Container &&
            w.padding ==
                const EdgeInsets.symmetric(horizontal: 14, vertical: 6)),
      );
      expect(pill, findsOneWidget);
      expect(tester.getSize(pill).height, lessThan(48));

      // A tap near the bottom edge of the expanded hit area (outside
      // the visible pill) still triggers Done.
      final rect = tester.getRect(detector.first);
      await tester.tapAt(Offset(rect.center.dx, rect.bottom - 2));
      await tester.pumpAndSettle();
      expect(find.text('Done'), findsNothing);
    });

    testWidgets('Weekly Snapshot dropdown rows: hit height >= 48dp',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: WeeklySnapshotCard())),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_drop_down));
      await tester.pumpAndSettle();
      for (final m in SnapshotMetric.values) {
        final row = find.ancestor(
          of: find.text(m.displayName).last,
          matching: find.byType(InkWell),
        );
        expect(row, findsOneWidget, reason: m.displayName);
        expect(tester.getSize(row).height, greaterThanOrEqualTo(48),
            reason: m.displayName);
      }
    });
  });

  group('6d labels', () {
    testWidgets('History: Back / Clear search / Delete entry',
        (tester) async {
      final store = FakeSessionStore()..token = 'a11y-token';
      final backend = TabsBackend(
        client: MockClient((request) async {
          if (request.url.path == '/api/sync/pull') {
            return http.Response(
              jsonEncode({
                'entries': [
                  {
                    'id': 42,
                    'categoryId': 3,
                    'body': 'Brain fog all morning',
                    'chips': '["Symptoms"]',
                    'manualText': '',
                    'timestamp':
                        DateTime(2026, 10, 12, 9, 30).millisecondsSinceEpoch,
                  },
                ],
                'categories': [
                  {
                    'id': 3,
                    'name': 'Symptoms',
                    'icon': 'circle',
                    'colorHex': '#4ECDC4',
                    'isDefault': true,
                    'sortOrder': 1,
                  },
                ],
                'isUnlimited': true,
              }),
              200,
            );
          }
          return http.Response('{}', 404);
        }),
        sessionStore: store,
      );
      await tester.pumpWidget(MaterialApp(home: HistoryScreen(backend: backend)));
      await tester.pumpAndSettle();

      expectLabel(tester, 'Back');
      expectLabel(tester, 'Delete entry');

      // Clear-search appears only once the search field has text.
      expect(find.byTooltip('Clear search'), findsNothing);
      await tester.enterText(find.byType(TextField), 'fog');
      await tester.pumpAndSettle();
      expectLabel(tester, 'Clear search');
    });

    testWidgets('coach-history error banner dismiss is labelled Dismiss',
        (tester) async {
      final store = FakeSessionStore()..token = 'a11y-token';
      final backend = TabsBackend(
        client: MockClient((request) async {
          if (request.url.path == '/api/sync/pull') {
            return http.Response(
              jsonEncode({
                'isUnlimited': true,
                'coachSessions': [
                  {
                    'id': 's1',
                    'title': 'My Chat',
                    'createdAt': 1,
                    'updatedAt': 1760000000000,
                  },
                ],
                'coachMessages': [],
              }),
              200,
            );
          }
          return http.Response('nope', 500);
        }),
        sessionStore: store,
      );
      await tester
          .pumpWidget(MaterialApp(home: HealthCoachScreen(backend: backend)));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(
          find.text(
              'Could not delete that chat. Check your connection and try again.'),
          findsOneWidget);
      expectLabel(tester, 'Dismiss');
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not delete that chat.'), findsNothing);
    });

    testWidgets('Home weather button is labelled Weather', (tester) async {
      final weather = WeatherApiClient(
        client: MockClient((request) async {
          if (request.url.host == 'ipinfo.io') {
            return http.Response(
                '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
                200);
          }
          return http.Response(
              '{"current":{"temperature_2m":61.0,"weather_code":2,"is_day":1}}',
              200);
        }),
      );
      await tester.pumpWidget(
          MaterialApp(home: HomeScreen(weatherApi: weather)));
      await tester.pump();
      expectLabel(tester, 'Weather');
      // Let the staggered-entrance delay timers fire before teardown.
      await tester.pump(const Duration(milliseconds: 500));
    });
  });
}

/// Harness mirroring Home's usage: the card is removed when its exit
/// completes; a "leave" button flips [FeelingCheckInCard.leaving].
class _FeelingHarness extends StatefulWidget {
  const _FeelingHarness();

  @override
  State<_FeelingHarness> createState() => _FeelingHarnessState();
}

class _FeelingHarnessState extends State<_FeelingHarness> {
  bool _leaving = false;
  bool _gone = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          if (!_gone)
            FeelingCheckInCard(
              onSelect: (_) {},
              leaving: _leaving,
              onExitComplete: () => setState(() => _gone = true),
            ),
          TextButton(
            onPressed: () => setState(() => _leaving = true),
            child: const Text('leave'),
          ),
        ],
      ),
    );
  }
}
