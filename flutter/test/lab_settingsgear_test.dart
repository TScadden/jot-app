import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';
import 'package:tabs_lab/src/features/shell/main_shell.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Settings-gear round (Lab) — NAMED additions of that package:
/// the Home header gear (presence + numeric placement against
/// the watch button). The dock-side additions (no settings cell,
/// capsule = 1 of 4 cells) live in lab_navbar_test.dart (a)/(b).
///
/// SETTINGS-FULLSCREEN ROUND (V8, founder direction: "instead of
/// the settings pop up it just changes to the settings screen we
/// had before") — this file is REPLACED: every tray test is
/// removed with the tray itself (settings_tray.dart deleted;
/// showSettingsTray / SettingsTray / the settings_tray* keys no
/// longer exist anywhere), and the coverage now pins the NEW
/// behavior:
/// (2) the gear tap PUSHES a full-screen SettingsScreen route
///     (the screen fills the whole surface, carries its own
///     Scaffold + AppBar titled 'Settings', shows the real main
///     menu, and no tray key exists anywhere in the tree);
/// (3) full-screen back navigation — a sub-page shows the
///     AppBar back arrow + its own title, the arrow returns to
///     the menu, and system back steps sub-page -> menu first,
///     then pops the route back to Home;
/// (4) an in-Settings error snackbar (Sync failed, a real
///     _snack path) renders visibly on the pushed screen — the
///     Juno V6 Condition 1 coverage re-homed from the tray host
///     to the route's own Scaffold;
/// (5) the restored segmented control keeps the R49 SE3 /
///     Juno V7 Condition 2 hit floor: each segment's tappable
///     rect is >=48dp tall in its pre-tray structure.
/// Test (1), the gear placement pin, is carried over unchanged.
///
/// The shell harness mirrors settings_r30_navlabels_test.dart:
/// a real MainShell over an in-memory SettingsStore, with the
/// secure-storage channel mocked to the signed-out answers so
/// the real backend's loads complete deterministically.
void main() {
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
      return switch (call.method) {
        'read' => null,
        'readAll' => <String, String>{},
        _ => null,
      };
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  });

  SettingsStore storeOver(Map<String, String> map) =>
      SettingsStore.withStorage(
        read: (k) async => map[k],
        write: (k, v) async => map[k] = v,
        delete: (k) async => map.remove(k),
      );

  Future<void> pumpShell(WidgetTester tester) async {
    final map = <String, String>{};
    await tester.pumpWidget(
        MaterialApp(home: MainShell(settingsStore: storeOver(map))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Finder gear() => find.byKey(const ValueKey('home_settings_gear'));

  /// Lets Home's background chains finish before teardown. The
  /// Daily Score chain's Health Connect reads ride REAL async
  /// platform replies (unmocked channel), so fake pumps alone
  /// leave a bounded-read timeout timer pending at teardown;
  /// alternating real-async drains with pumps (the settings_r30
  /// seed-loop pattern) runs the chain to completion.
  Future<void> drainRealWork(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Taps the header gear and waits out the route push plus the
  /// pushed SettingsScreen's load.
  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(gear());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(SettingsScreen), findsOneWidget);
  }

  group('Lab settings gear + full-screen Settings (V8)', () {
    testWidgets('gear: present in Home header, immediately left of '
        'the watch button, 24dp in NotelColors.primary', (tester) async {
      // Standalone Home (not the shell): the header is the unit
      // under test, and the injected history store + snapshot
      // stub keep Home's Daily Score chain out of the Health
      // Connect capture path (whose 30s bounded reads would
      // otherwise pend at teardown — the shell harness's chain
      // restarts them indefinitely).
      final disk = <String, String>{};
      final scoreStore = HealthHistoryStore.testInstance();
      scoreStore.debugSetStore(
        read: (k) async => disk[k],
        write: (k, v) async => disk[k] = v,
        delete: (k) async => disk.remove(k),
      );
      scoreStore.debugReset();
      await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
          weatherApi: WeatherApiClient(
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
          ),
          healthHistoryStore: scoreStore,
          dailyScoreSnapshotCapture: ({bool force = false}) async => true,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(gear(), findsOneWidget);
      // Tabs' own gear glyph, same as the retired dock cell used.
      final glyph = tester.widget<Icon>(find.descendant(
          of: gear(), matching: find.byIcon(Icons.settings)));
      expect(glyph.size, 24);
      expect(glyph.color, NotelColors.primary);
      expect(find.byTooltip('Settings'), findsOneWidget);

      // Placement, numerically: the gear's 48dp box is CONTIGUOUS
      // with the watch button's box (gear right edge == watch left
      // edge) and they share a vertical center band. The watch
      // button itself did not move: it is still the rightmost
      // header action (its right edge is the surface edge). The
      // watch rect is read from its IconButton (the ancestor of
      // the 'Connections' tooltip — the Tooltip's own render box
      // is the button's centered 40dp visual box, not its 48dp
      // target box).
      final gearRect = tester.getRect(gear());
      final watchRect = tester.getRect(find.ancestor(
          of: find.byTooltip('Connections'),
          matching: find.byType(IconButton)));
      expect(gearRect.right, closeTo(watchRect.left, 0.5));
      expect(gearRect.center.dy, closeTo(watchRect.center.dy, 0.5));
      expect(gearRect.width, 48);
      expect(gearRect.height, 48);
      expect(watchRect.right, closeTo(800, 0.5));
      // Let the staggered-entrance delay timers fire (no pending
      // timers at teardown).
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets('gear tap pushes a FULL-SCREEN SettingsScreen route '
        '(own Scaffold + AppBar, real menu, no tray anywhere)',
        (tester) async {
      await pumpShell(tester);
      await openSettings(tester);

      // Full-screen: the pushed screen fills the whole 800x600
      // test surface (the tray floated at 0.89W x 0.70H; this
      // route does not float, inset, or anchor anywhere).
      final screenRect = tester.getRect(find.byType(SettingsScreen));
      expect(screenRect, const Rect.fromLTWH(0, 0, 800, 600));
      // Its own chrome is back: a Scaffold with an AppBar whose
      // title is the root 'Settings' string.
      expect(
          find.descendant(
              of: find.byType(SettingsScreen),
              matching: find.byType(Scaffold)),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(SettingsScreen),
              matching: find.byType(AppBar)),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(AppBar), matching: find.text('Settings')),
          findsOneWidget);
      // The root page's AppBar leading is null (pre-tray form),
      // so on a PUSHED route Flutter's automaticallyImplyLeading
      // supplies the standard BackButton — the same root chrome
      // the counter-slot and Research pushes have always shown.
      expect(
          find.descendant(
              of: find.byType(AppBar),
              matching: find.byIcon(Icons.arrow_back)),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(AppBar), matching: find.byType(BackButton)),
          findsOneWidget);
      // No tray remains reachable: none of the tray keys exist.
      expect(find.byKey(const ValueKey('settings_tray')), findsNothing);
      expect(find.byKey(const ValueKey('settings_tray_close')),
          findsNothing);
      expect(find.byKey(const ValueKey('settings_tray_back')),
          findsNothing);

      // Real Settings content: the actual main-menu rows
      // (strings untouched).
      await tester.ensureVisible(find.text('User Profile'));
      await tester.pump();
      expect(find.text('User Profile'), findsOneWidget);
      await tester.ensureVisible(find.text('Customize'));
      await tester.pump();
      expect(find.text('Customize'), findsOneWidget);
      await drainRealWork(tester);
    });

    testWidgets('full-screen back: sub-page AppBar arrow returns to '
        'the menu; system back steps sub-page -> menu, then pops '
        'the route to Home', (tester) async {
      await pumpShell(tester);
      await openSettings(tester);

      // Into a sub-page: the AppBar retitles and gains the
      // standard back arrow (pre-tray chrome).
      await tester.ensureVisible(find.text('Customize'));
      await tester.pump();
      await tester.tap(find.text('Customize'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('nav_labels_toggle')),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(AppBar), matching: find.text('Customize')),
          findsOneWidget);
      final appBarBack = find.descendant(
          of: find.byType(AppBar),
          matching: find.byIcon(Icons.arrow_back));
      expect(appBarBack, findsOneWidget);

      // System back steps back to the menu first (the screen's
      // own PopScope) — the route does NOT pop yet.
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(SettingsScreen), findsOneWidget,
          reason: 'first back should land on the Settings menu, '
              'not pop the route');
      expect(find.byKey(const ValueKey('nav_labels_toggle')),
          findsNothing);
      await tester.ensureVisible(find.text('User Profile'));
      await tester.pump();
      expect(find.text('User Profile'), findsOneWidget);

      // Back into the sub-page and out via the AppBar arrow.
      await tester.ensureVisible(find.text('Customize'));
      await tester.pump();
      await tester.tap(find.text('Customize'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('nav_labels_toggle')),
          findsOneWidget);
      await tester.tap(appBarBack);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SettingsScreen), findsOneWidget);
      await tester.ensureVisible(find.text('User Profile'));
      await tester.pump();
      expect(find.text('User Profile'), findsOneWidget);

      // Second system back (now at the menu root) pops the
      // route; Home remains underneath. (The SlidePageRoute
      // reverse slide is 300ms; pump past it and settle a frame
      // before reading the tree.)
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.byType(SettingsScreen), findsNothing);
      expect(find.text('Today'), findsOneWidget);
      await drainRealWork(tester);
    });

    testWidgets('full-screen: an in-Settings error snackbar (Sync '
        'failed, a real _snack path) renders visibly on the '
        'pushed screen', (tester) async {
      await pumpShell(tester);
      await openSettings(tester);

      // The pushed screen's body keeps its pre-tray ListView
      // padding (16 top, 110 bottom dock clearance).
      final bodyList = find.descendant(
          of: find.byType(SettingsScreen),
          matching: find.byType(ListView));
      expect(bodyList, findsOneWidget);
      expect(tester.widget<ListView>(bodyList).padding,
          const EdgeInsets.fromLTRB(16, 16, 16, 110));

      // Navigate to Sync Settings and tap Sync Now. In this
      // harness the shell is signed out (secure storage reads
      // return null), so the manual sync's pull fails and
      // _manualSync runs its real failure path:
      // _snack('Sync failed. Check your connection and try
      // again.') — a genuine _snack() call site, not a synthetic
      // ScaffoldMessenger call from the test.
      await tester.ensureVisible(find.text('Sync Settings'));
      await tester.pump();
      await tester.tap(find.text('Sync Settings'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SettingsScreen), findsOneWidget);
      for (var i = 0; i < 3; i++) {
        await tester.drag(bodyList, const Offset(0, 500));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(find.text('Share data with friends'), findsOneWidget);
      final syncButton = find.byKey(const ValueKey('sync_now_button'));
      for (var i = 0;
          i < 6 && syncButton.evaluate().isEmpty;
          i++) {
        await tester.drag(bodyList, const Offset(0, -300));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(syncButton, findsOneWidget);
      await tester.ensureVisible(syncButton);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('sync_now_button')));
      // The pull rides real-async replies; alternate real drains
      // with pumps (drainRealWork's pattern) until the snackbar
      // lands, stopping well inside its 4s display window.
      for (var i = 0; i < 10 && find.byType(SnackBar).evaluate().isEmpty;
          i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(milliseconds: 300));

      // PROOF: the snackbar is rendered with the real
      // sync-failure message, hosted by the pushed screen's own
      // Scaffold subtree (descendant of SettingsScreen).
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(SettingsScreen),
              matching: find.byType(SnackBar)),
          findsOneWidget);
      expect(
          find.text('Sync failed. Check your connection and try again.'),
          findsOneWidget);

      // Expire the snackbar so no timer pends at teardown.
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SnackBar), findsNothing);
      await drainRealWork(tester);
    });

    testWidgets('full-screen: segmented segments keep a >=48dp '
        'tappable height in the restored pre-tray structure',
        (tester) async {
      await pumpShell(tester);
      await openSettings(tester);

      // A segment's detector is the GestureDetector nearest above
      // its label, inside the pushed SettingsScreen.
      Finder segOf(String label) => find
          .ancestor(
              of: find.descendant(
                  of: find.byType(SettingsScreen),
                  matching: find.text(label)),
              matching: find.byType(GestureDetector))
          .first;
      for (final label in ['Settings', 'Membership']) {
        final hit = tester.getRect(segOf(label));
        expect(hit.height, greaterThanOrEqualTo(48),
            reason: '$label segment hit height regressed below 48dp');
      }
      // Switching segments still works by label tap: the
      // Membership page replaces the main menu.
      await tester.tap(find.descendant(
          of: find.byType(SettingsScreen),
          matching: find.text('Membership')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('User Profile'), findsNothing);
      await drainRealWork(tester);
    });
  });
}
