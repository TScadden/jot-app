import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/settings/settings_tray.dart';
import 'package:tabs_lab/src/features/shell/main_shell.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';
import 'package:tabs_lab/src/theme/lab_black_colors.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Settings-gear round (Lab) — NAMED additions of this package:
/// the Home header gear (presence + numeric placement against the
/// watch button), and the settings tray it opens (SETTINGS_SPEC
/// behavior: grows from the bar zone, hosts the real Settings
/// menu, navigates inside itself, dismisses by ✕ / tap-outside /
/// system back). The dock-side additions (no settings cell,
/// capsule = 1 of 4 cells) live in lab_navbar_test.dart (a)/(b).
///
/// V6 FIX ROUND additions/changes (Juno SIGN WITH CONDITIONS on
/// 41e4ebb8): (8) NEW — an error snackbar fired through a real
/// _snack() path inside the open tray renders visibly INSIDE the
/// tray's region (Condition 1, gates delivery); the ✕ test (3)
/// is EXTENDED (count unchanged) with the Condition 3 pins: the
/// close hit area is 48dp, the visual circle stays 36dp, and
/// both share the same center.
///
/// SETTINGS-FIDELITY ROUND changes (audit-driven): the tray
/// geometry pins move to the measured reference values — width
/// 0.89W with ≈0.057W side insets, bottom edge at ≈0.957H
/// (0.043H gap), height 0.70H (the audit §4 arithmetic, NOT the
/// old 0.78 cap), NO scrim (transparent barrier), open 180ms —
/// and (9) NEW: the sub-state header form (back-chevron circle
/// top-left + CENTERED title + no ✕) vs the root form
/// (left-aligned title + ✕).
///
/// V7 FIX ROUND (Juno SIGN WITH CONDITIONS on 42300573, §5/§6):
/// test (9) is EXTENDED (count unchanged) with Condition 1's
/// pins — the back circle's keyed hit rect is 48x48, the 36dp
/// visual is concentric inside it, and a tap in the 36–48dp
/// RING navigates back — and (10) NEW (+1 test): the segmented
/// control's per-segment hit-rect height is >=48dp with the
/// 40dp capsule visual unchanged, including a tap in the band
/// above the capsule (Condition 2, restoring R49 SE3).
///
/// The shell harness mirrors settings_r30_navlabels_test.dart:
/// a real MainShell over an in-memory SettingsStore, with the
/// secure-storage channel mocked to the signed-out answers so the
/// real backend's loads complete deterministically.
void _noopClose() {}

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
  Finder tray() => find.byKey(const ValueKey('settings_tray'));

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

  /// Opens the tray from Home and waits out the 180ms grow plus
  /// the hosted Settings load.
  Future<void> openTray(WidgetTester tester) async {
    await tester.tap(gear());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tray(), findsOneWidget);
  }

  group('Lab settings gear + tray (settings-gear named additions)', () {
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

    testWidgets('tray: gear tap opens the tray anchored over the '
        'bar zone, hosting the real Settings menu', (tester) async {
      await pumpShell(tester);
      await openTray(tester);

      // Geometry (settings-fidelity round, audit D1/D2/D3):
      // the tray FLOATS inset like the reference — width 0.89W
      // (side insets (1-0.89)/2 = 0.055W), bottom edge at
      // ≈0.957H (0.043H of screen below it), height 0.70H (the
      // audit §4 arithmetic height) on the 800x600 test surface.
      final rect = tester.getRect(tray());
      expect(rect.left, closeTo(800 * 0.055, 0.5));
      expect(rect.right, closeTo(800 * 0.945, 0.5));
      expect(rect.width, closeTo(800 * 0.89, 0.5));
      expect(rect.bottom, closeTo(600 * 0.957, 0.5));
      expect(rect.height, closeTo(600 * 0.70, 0.5));
      // NO scrim (audit D5): the modal barrier paints nothing —
      // Flutter represents the route's fully-transparent
      // barrierColor as a null ModalBarrier color (no scrim
      // layer at all); it is a tap-outside target only.
      final barrier = tester.widget<ModalBarrier>(
          find.byType(ModalBarrier).first);
      expect(barrier.color, isNull);
      // The tray covers the dock zone completely: the dock's top
      // edge is BELOW the tray's top edge (dock hidden beneath).
      final dockTop = tester.getTopLeft(find.byType(NavDock)).dy;
      expect(rect.top, lessThan(dockTop));

      // Real Settings content inside: tray header ✕ + the actual
      // main-menu rows (strings untouched).
      expect(find.byKey(const ValueKey('settings_tray_close')),
          findsOneWidget);
      await tester.ensureVisible(find.text('User Profile'));
      await tester.pump();
      expect(find.text('User Profile'), findsOneWidget);
      await tester.ensureVisible(find.text('Customize'));
      await tester.pump();
      expect(find.text('Customize'), findsOneWidget);
      await drainRealWork(tester);
    });

    testWidgets('tray: ✕ closes it', (tester) async {
      await pumpShell(tester);
      await openTray(tester);
      // Juno Condition 3 (V6 fix round): the keyed hit area is
      // 48x48dp; the visual circle inside it is still exactly
      // 36x36dp; and the two are concentric (the visual circle
      // did not move — its center is the hit area's center).
      final closeKey = find.byKey(const ValueKey('settings_tray_close'));
      final hitRect = tester.getRect(closeKey);
      expect(hitRect.width, 48);
      expect(hitRect.height, 48);
      final visual = find.descendant(
          of: closeKey,
          matching: find.byWidgetPredicate((w) =>
              w is Material && w.shape is CircleBorder));
      expect(visual, findsOneWidget);
      expect(tester.getSize(visual), const Size(36, 36));
      expect(tester.getRect(visual).center, hitRect.center);
      await tester.tap(find.byKey(const ValueKey('settings_tray_close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tray(), findsNothing);
      // Home is still there underneath.
      expect(find.text('Today'), findsOneWidget);
      await drainRealWork(tester);
    });

    testWidgets('tray: an in-tray error snackbar (Sync failed, a '
        'real _snack path) renders visibly INSIDE the open tray '
        '(Juno Condition 1)', (tester) async {
      await pumpShell(tester);
      await openTray(tester);

      // The tray-local Scaffold host must not have changed the
      // hosted body's layout: the embedded ListView keeps its
      // designed padding, 24dp at the bottom included. (Top
      // padding 16 -> 12 is the settings-fidelity round's
      // intentional change — the tray height arithmetic in
      // settings_tray.dart — not a host side effect.)
      final bodyList = find.descendant(
          of: tray(), matching: find.byType(ListView));
      expect(bodyList, findsOneWidget);
      expect(tester.widget<ListView>(bodyList).padding,
          const EdgeInsets.fromLTRB(16, 12, 16, 24));

      // Navigate inside the tray to Sync Settings and tap Sync
      // Now. In this harness the shell is signed out (secure
      // storage reads return null), so the manual sync's pull
      // fails and _manualSync runs its real failure path:
      // _snack('Sync failed. Check your connection and try
      // again.') — a genuine _snack() call site, not a synthetic
      // ScaffoldMessenger call from the test.
      await tester.ensureVisible(find.text('Sync Settings'));
      await tester.pump();
      await tester.tap(find.text('Sync Settings'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tray(), findsOneWidget);
      // The in-body page swap keeps the ListView's scrolled
      // offset (the menu hunt scrolled it down), so scroll the
      // tray's list back to the top of the Sync page first —
      // its first row is then present — and the Sync Now button
      // still sits below the viewport's build extent, so scroll
      // down until it builds.
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

      // PROOF: the snackbar is rendered, its text is the real
      // sync-failure message, the tray is still open, and the
      // snackbar's rect lies WITHIN the tray's rect — visible
      // above the tray glass, not on the route below it.
      // The descendant assertion is the discriminating one:
      // rect containment alone does NOT discriminate, because
      // a snackbar presented on the route BELOW (the pre-fix
      // behavior) anchors at the screen bottom, geometrically
      // inside the tray's footprint while painting UNDER the
      // barrier and the tray glass. Only a snackbar hosted by
      // the tray's own Scaffold is an element DESCENDANT of
      // the tray subtree — and this test was verified to fail
      // on the pre-fix tray for exactly this assertion.
      expect(tray(), findsOneWidget);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(
          find.descendant(
              of: tray(), matching: find.byType(SnackBar)),
          findsOneWidget);
      expect(
          find.text('Sync failed. Check your connection and try again.'),
          findsOneWidget);
      final trayRect = tester.getRect(tray());
      final barRect = tester.getRect(find.byType(SnackBar));
      expect(barRect.top, greaterThanOrEqualTo(trayRect.top));
      expect(barRect.bottom, lessThanOrEqualTo(trayRect.bottom + 0.5));
      expect(barRect.left, greaterThanOrEqualTo(trayRect.left));
      expect(barRect.right, lessThanOrEqualTo(trayRect.right + 0.5));

      // Expire the snackbar so no timer pends at teardown.
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SnackBar), findsNothing);
      await drainRealWork(tester);
    });

    testWidgets('tray: tap outside (barrier above the tray) '
        'dismisses it', (tester) async {
      await pumpShell(tester);
      await openTray(tester);
      // The tray's top edge sits at 600 x 0.957 - 600 x 0.70 =
      // 154.2 on this surface; (400, 20) is squarely in the
      // (transparent) barrier region.
      await tester.tapAt(const Offset(400, 20));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tray(), findsNothing);
      expect(find.text('Today'), findsOneWidget);
      await drainRealWork(tester);
    });

    testWidgets('tray: selecting an entry navigates INSIDE the '
        'tray (no dismissal); in-tray back returns to the menu',
        (tester) async {
      await pumpShell(tester);
      await openTray(tester);

      await tester.ensureVisible(find.text('Customize'));
      await tester.pump();
      await tester.tap(find.text('Customize'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      // The tray is still open, now showing the Customize page —
      // proven by its nav-labels toggle (the Round 30 row).
      expect(tray(), findsOneWidget);
      expect(find.byKey(const ValueKey('nav_labels_toggle')),
          findsOneWidget);

      // In-tray back arrow (the SettingsScreen AppBar arrow's
      // replacement in the tray header) returns to the main menu;
      // the tray stays open.
      await tester.tap(find.descendant(
          of: tray(), matching: find.byIcon(Icons.arrow_back)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tray(), findsOneWidget);
      await tester.ensureVisible(find.text('User Profile'));
      await tester.pump();
      expect(find.text('User Profile'), findsOneWidget);
      await drainRealWork(tester);
    });

    testWidgets('tray: system back steps sub-page -> menu first, '
        'then dismisses the tray before Home', (tester) async {
      await pumpShell(tester);
      await openTray(tester);

      // Into a sub-page, then system back: the tray must stay
      // open on the main menu (SettingsScreen's own PopScope).
      await tester.ensureVisible(find.text('Customize'));
      await tester.pump();
      await tester.tap(find.text('Customize'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('nav_labels_toggle')),
          findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tray(), findsOneWidget,
          reason: 'first back should land on the Settings menu, '
              'not dismiss the tray');
      expect(find.byKey(const ValueKey('nav_labels_toggle')),
          findsNothing);

      // Second system back: the tray dismisses; Home remains.
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tray(), findsNothing);
      expect(find.text('Today'), findsOneWidget);
      await drainRealWork(tester);
    });

    testWidgets('tray: sub-page header is the reference sub-state '
        'form — back-chevron CIRCLE top-left, CENTERED title, '
        'no ✕ (audit D10)', (tester) async {
      await pumpShell(tester);
      await openTray(tester);

      // Root form first: 'Settings' title LEFT-aligned (its box
      // starts at the tray's left edge + 16dp header padding),
      // ✕ present.
      final trayRect = tester.getRect(tray());
      final rootTitle = tester.getRect(find.descendant(
          of: tray(), matching: find.text('Settings').first));
      expect(rootTitle.left, closeTo(trayRect.left + 16, 1.0));
      expect(find.byKey(const ValueKey('settings_tray_close')),
          findsOneWidget);

      // Into a sub-page (Customize) and let the 220ms header
      // morph settle.
      await tester.ensureVisible(find.text('Customize'));
      await tester.pump();
      await tester.tap(find.text('Customize'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // Sub form: NO ✕ anywhere in the tray; the back affordance
      // is a 36dp grey CIRCLE (Material with CircleBorder) at the
      // top-left; the 'Customize' title is CENTERED in the tray.
      expect(find.byKey(const ValueKey('settings_tray_close')),
          findsNothing);
      final backCircle = find.descendant(
          of: tray(),
          matching: find.byWidgetPredicate((w) =>
              w is Material && w.shape is CircleBorder));
      expect(backCircle, findsOneWidget);
      expect(tester.getSize(backCircle), const Size(36, 36));
      expect(tester.getRect(backCircle).left,
          closeTo(trayRect.left + 12, 1.0));
      final subTitle = tester.getRect(find.descendant(
          of: tray(), matching: find.text('Customize').first));
      expect(subTitle.center.dx, closeTo(trayRect.center.dx, 1.0));

      // V7 FIX ROUND (Juno Condition 1): the back circle's HIT
      // AREA is a true 48x48dp — the keyed opaque GestureDetector
      // box, mirroring the ✕'s construction — with the 36dp
      // visual circle CONCENTRIC inside it. The pre-fix build
      // wrapped a bare SizedBox around the 36dp InkWell, so the
      // effective hit area was 36dp; the visual-only pins above
      // could not see that, so this extension also TAPS THE RING.
      final backKey = find.byKey(const ValueKey('settings_tray_back'));
      expect(backKey, findsOneWidget);
      final backHit = tester.getRect(backKey);
      expect(backHit.width, 48);
      expect(backHit.height, 48);
      expect(tester.getRect(backCircle).center, backHit.center);
      // Ring point: 21dp above the center — OUTSIDE the 36dp
      // visual circle (radius 18), INSIDE the 48dp hit box.
      await tester.tapAt(backHit.center + const Offset(0, -21));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      // The ring tap navigated BACK: the tray is still open, the
      // root form is restored (✕ back, back key gone), and the
      // Customize page is gone.
      expect(tray(), findsOneWidget);
      expect(find.byKey(const ValueKey('settings_tray_back')),
          findsNothing);
      expect(find.byKey(const ValueKey('settings_tray_close')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('nav_labels_toggle')),
          findsNothing);
      await drainRealWork(tester);
    });

    testWidgets('tray: segmented segments keep a >=48dp HIT '
        'height while the capsule VISUAL stays 40dp (V7 fix '
        'round, Juno Condition 2)', (tester) async {
      await pumpShell(tester);
      await openTray(tester);

      // A segment's detector is the GestureDetector nearest above
      // its label; its capsule visual is the decorated Container
      // inside it; the track is the decorated Container above
      // both segments.
      Finder segOf(String label) => find
          .ancestor(
              of: find.descendant(
                  of: tray(), matching: find.text(label)),
              matching: find.byType(GestureDetector))
          .first;
      Finder capsuleOf(String label) => find.descendant(
          of: segOf(label),
          matching: find.byWidgetPredicate((w) =>
              w is Container && w.decoration is BoxDecoration));
      // The track's painted box is its DecoratedBox (the track
      // Container's own render object would also carry its 12dp
      // bottom margin, so the box is measured directly).
      final trackBox = find.ancestor(
          of: segOf('Settings'),
          matching: find.byWidgetPredicate((w) =>
              w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).color ==
                  LabBlackColors.segmentedTrack));

      // The track's TOTAL height is unchanged at 48dp, and each
      // segment's tappable rect now spans it fully (>=48dp hit
      // height — the R49 SE3 fix, restored) while the rendered
      // capsule inside stays exactly 40dp tall.
      expect(tester.getSize(trackBox).height, 48);
      for (final label in ['Settings', 'Membership']) {
        final hit = tester.getRect(segOf(label));
        expect(hit.height, greaterThanOrEqualTo(48),
            reason: '$label segment hit height regressed below 48dp');
        expect(tester.getSize(capsuleOf(label)).height, 40,
            reason: '$label capsule visual must stay 40dp');
        expect(tester.getRect(capsuleOf(label)).center.dy,
            hit.center.dy,
            reason: '$label capsule stays centered in its hit box');
      }
      // The selected capsule keeps its polarity token.
      expect(
          (tester.widget<Container>(capsuleOf('Settings')).decoration
                  as BoxDecoration)
              .color,
          LabBlackColors.segmentedSelected);

      // Band tap: switch to Membership by its label, then tap
      // the Settings segment 2dp below its hit rect's top —
      // INSIDE the detector but OUTSIDE the 40dp capsule (which
      // starts 4dp in). Pre-fix that point sat in the track's
      // padding, outside either segment's detector, and tapped
      // through to nothing.
      await tester.tap(find.descendant(
          of: tray(), matching: find.text('Membership')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('User Profile'), findsNothing);
      final settingsHit = tester.getRect(segOf('Settings'));
      await tester.tapAt(
          Offset(settingsHit.center.dx, settingsHit.top + 2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      // The band tap switched back to the Settings segment.
      await tester.ensureVisible(find.text('User Profile'));
      await tester.pump();
      expect(find.text('User Profile'), findsOneWidget);
      await drainRealWork(tester);
    });

    testWidgets('tray: keyboard up — the tray rides above the '
        'keyboard as one stack (audit D18)', (tester) async {
      // 300dp keyboard on the 800x600 logical surface (900
      // physical px at the test view's DPR 3): the tray's bottom
      // edge sits at keyboard top + the ≈9dp Status-tray gap,
      // and its height clamps to the space above the keyboard
      // (SETTINGS_SPEC §2.3/§4.4 — tray + keyboard move as one).
      tester.view.viewInsets = const FakeViewPadding(bottom: 900);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(const MaterialApp(
        home: SettingsTray(
          animation: AlwaysStoppedAnimation(1),
          onClose: _noopClose,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final rect = tester.getRect(tray());
      expect(rect.bottom, closeTo(600 - 309, 0.5));
      expect(rect.height, closeTo(600 - 309, 0.5));
      expect(rect.width, closeTo(800 * 0.89, 0.5));
    });

    testWidgets('tray geometry: height grows from the bar zone to '
        'the 0.70 fidelity height monotonically; reduced motion '
        'snaps to final', (tester) async {
      // Standalone tray pumps (the dialog animation replaced by a
      // stopped animation at fixed values). On the 800x600
      // surface with viewPadding 0: bar zone = 27 float + 62 bar
      // = 89; final = 0.70 x 600 = 420; bottom gap = 0.043 x 600
      // = 25.8, so the bottom edge sits at 574.2 and the width is
      // 0.89 x 800 = 712 with 44dp insets.
      Future<Rect> trayRectAt(double v, {bool reduced = false}) async {
        final trayWidget = SettingsTray(
          key: ValueKey('tray_probe_${v}_$reduced'),
          animation: AlwaysStoppedAnimation(v),
          onClose: () {},
        );
        await tester.pumpWidget(MaterialApp(
          home: reduced
              ? Builder(
                  builder: (context) => MediaQuery(
                    // copyWith from the AMBIENT data — a bare
                    // MediaQueryData would zero the size the tray
                    // measures its cap from.
                    data: MediaQuery.of(context)
                        .copyWith(disableAnimations: true),
                    child: trayWidget,
                  ),
                )
              : trayWidget,
        ));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        return tester.getRect(tray());
      }

      final at0 = await trayRectAt(0);
      expect(at0.height, closeTo(89, 0.5));
      expect(at0.left, closeTo(44, 0.5));
      expect(at0.width, closeTo(712, 0.5));
      expect(at0.bottom, closeTo(574.2, 0.5));
      // easeOutCubic(0.5) = 0.875 -> 89 + (420 - 89) x 0.875.
      expect((await trayRectAt(0.5)).height, closeTo(378.6, 1.0));
      expect((await trayRectAt(1)).height, closeTo(420, 0.5));
      // Reduced motion: final height instantly, even at value 0.
      expect((await trayRectAt(0, reduced: true)).height,
          closeTo(420, 0.5));
    });
  });
}
