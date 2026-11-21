import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/badges/badge_widget.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';

/// Drawer icon alignment pins (founder, Nov 20, 2026): the Badges
/// row led with BadgeWidget(size: 28) while the AI Advocate, Event
/// Counters and Community rows lead with Icon(size: 22) — the badge's
/// box center sat 3dp right of the shared icon column, its label
/// started 6dp right of the other labels, and its row stood 6dp
/// taller. The drawer usage now renders the badge at 22, and this
/// test pins the shared geometry so the column cannot drift again:
/// every row's leading icon occupies a 22x22 box on the same center
/// column, every label starts at the same x, and every row is the
/// same height.
void main() {
  testWidgets('drawer: all four rows share the icon column geometry',
      (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    // Real Roboto (repo capture pattern): the default test font's
    // glyphs are full-width blocks, which wraps 'Event Counters'
    // onto two lines and inflates every row's height — neither is
    // true of the shipped render this test pins.
    await tester.runAsync(() async {
      final loader = FontLoader('Roboto');
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
      await loader.load();
    });

    final weather = WeatherApiClient(
      client: MockClient((request) async {
        if (request.url.host == 'ipinfo.io') {
          return http.Response(
              '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
              200);
        }
        return http.Response('not found', 404);
      }),
    );
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(fontFamily: 'Roboto'),
      home: HomeScreen(weatherApi: weather),
    ));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('home_drawer_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    const rowKeys = [
      ValueKey('home_drawer_ai_advocate'),
      ValueKey('home_drawer_event_counters'),
      ValueKey('home_drawer_community'),
      ValueKey('home_drawer_badges'),
    ];

    double? sharedCenterDx;
    double? sharedLabelDx;
    double? sharedRowHeight;
    for (final key in rowKeys) {
      final row = find.byKey(key);
      expect(row, findsOneWidget, reason: '$key row missing');

      // Leading visual: the plain Icon on rows 1-3, the BadgeWidget
      // on the Badges row.
      final Finder leading = key == const ValueKey('home_drawer_badges')
          ? find.descendant(of: row, matching: find.byType(BadgeWidget))
          : find.descendant(of: row, matching: find.byType(Icon)).first;
      expect(leading, findsOneWidget, reason: '$key leading icon');

      final iconSize = tester.getSize(leading);
      expect(iconSize, const Size(22, 22),
          reason: '$key leading icon must occupy the shared 22x22 box');

      final centerDx = tester.getCenter(leading).dx;
      sharedCenterDx ??= centerDx;
      expect(centerDx, sharedCenterDx,
          reason: '$key icon center must sit on the shared column');

      final label = find.descendant(of: row, matching: find.byType(Text));
      expect(label, findsOneWidget, reason: '$key label');
      final labelDx = tester.getTopLeft(label).dx;
      sharedLabelDx ??= labelDx;
      expect(labelDx, sharedLabelDx,
          reason: '$key label must start at the shared label x');

      final rowHeight = tester.getSize(row).height;
      sharedRowHeight ??= rowHeight;
      expect(rowHeight, sharedRowHeight,
          reason: '$key row must match the shared row height');
    }

    // Drain Home's Daily Score capture chain (bounded HC reads park
    // 30s timers against the missing test platform channel; the
    // repo capture pattern runs the clock past every bound).
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(seconds: 31));
    }
  });
}
