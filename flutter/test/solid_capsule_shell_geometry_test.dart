import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/migraine_attack_store.dart';
import 'package:tabs_lab/src/data/migraine_controller.dart';
import 'package:tabs_lab/src/data/migraine_notification.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/shell/main_shell.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';
import 'package:tabs_lab/src/features/shell/nav_dock_solid.dart';

/// Nav Bar Style Fixes package, Item A — REAL-SHELL geometry
/// pins for the Solid dock's selection capsule.
///
/// Why this file exists: PR #172 pinned the capsule in a
/// dock-only harness (capsule 48dp, top = barTop + 5 at 800dp
/// wide), yet on the founder's device (VC 100187) the selected
/// capsule read as CUT OFF at the top. The reproduction that
/// opened this package mounted the real MainShell at 360/390 x
/// 844 @ DPR 3 with Pixel-class viewPadding (24/24) and measured
/// the capsule in the tree: margins were exactly 5.00dp top /
/// 5.00dp bottom for every tab at both widths and at text scale
/// 1.0 AND 1.3 — the shell does not constrain the bar, the slot
/// alignment is exact, and text scale does not move the capsule.
/// The defect was in the capsule's PAINT: its 1dp white-10% top
/// line sat flush at the capsule's top edge as an unclipped
/// child, painting outside the rounded fill in both corner
/// wedges (see kNavDockSolidCapsuleTopLineInset). The fix insets
/// the line 2dp and clips it to the capsule's shape.
///
/// These pins keep BOTH halves honest in the real shell: the
/// capsule's margins for all four tabs at 360 + 390 (two text
/// scales), and the top line's inset + clip. Services are faked
/// exactly as in heart_sleep_capture_test.dart so the shell's
/// background chains settle immediately.

class _UnavailableHc extends HealthConnectService {
  static const _snapshot = HcAvailability(
    serviceAvailable: false,
    grantedPermissions: {},
    bridgeErrorCode: null,
    stepsProbe: HcReadProbeOutcome.securityFailure,
    persistedConnected: false,
  );

  @override
  Future<HcAvailability> probeAvailability() async => _snapshot;

  @override
  Future<HcAvailability> probeGrantState() async => _snapshot;
}

class _FakeNotifier implements MigraineNotifier {
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> showAttack(int elapsedMin) async => true;
  @override
  Future<void> cancel() async {}
  @override
  Future<bool> areNotificationsEnabled() async => true;
  @override
  Future<bool> launchMigrainePayload() async => false;
}

class _FakeGateway implements MigraineTrendsGateway {
  @override
  Future<bool> postEntry(QuickLogEntry entry) async => true;
  @override
  Future<int> resolveMigraineCategoryId() async => 7;
  @override
  Future<int> generateEntryId() async => 100;
  @override
  Future<bool?> entryExists(int entryId) async => true;
}

MigraineController _testMigraineController() {
  final map = <String, String>{};
  return MigraineController(
    store: MigraineAttackStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    ),
    notifier: _FakeNotifier(),
    gateway: _FakeGateway(),
  );
}

WeatherApiClient _testWeather() => WeatherApiClient(
      client: MockClient((request) async {
        if (request.url.host == 'ipinfo.io') {
          return http.Response(
            '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
            200,
          );
        }
        return http.Response('not found', 404);
      }),
    );

void main() {
  setUp(() {
    final mem = <String, String>{};
    HealthHistoryStore.instance.debugSetStore(
      read: (k) async => mem[k],
      write: (k, v) async => mem[k] = v,
      delete: (k) async => mem.remove(k),
    );
    HealthHistoryStore.instance.debugReset();
  });

  // Real glyphs + real text metrics (the repo capture pattern):
  // under the Ahem test font the Heart screen's rows overflow at
  // 360dp and the framework fails the test on the exception —
  // and the text-scale legs below are only meaningful with the
  // real font loaded.
  Future<void> loadFonts(WidgetTester tester) async {
    await tester.runAsync(() async {
      final loader = FontLoader('Roboto');
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
      await loader.load();
      final iconsFile = File(
        '${Platform.environment['HOME']}/workspace/tools/flutter/bin/cache/'
        'artifacts/material_fonts/MaterialIcons-Regular.otf',
      );
      if (await iconsFile.exists()) {
        final icons = await iconsFile.readAsBytes();
        final iconLoader = FontLoader('MaterialIcons');
        iconLoader.addFont(
          Future.value(ByteData.view(Uint8List.fromList(icons).buffer)),
        );
        await iconLoader.load();
      }
    });
  }

  Finder gradientBar() => find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).gradient ==
                kNavDockSolidGradient,
      );

  Finder dockIcon(IconData icon) => find.descendant(
        of: find.byType(NavDockSolid),
        matching: find.byIcon(icon),
      );

  for (final width in [360.0, 390.0]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets(
          'capsule margins in the real shell at ${width.toInt()}dp, '
          'text scale $scale', (tester) async {
        await loadFonts(tester);
        tester.view.physicalSize = Size(width * 3, 844 * 3);
        tester.view.devicePixelRatio = 3.0;
        // Pixel-class viewPadding: 24dp top/bottom (72 physical).
        tester.view.viewPadding =
            const FakeViewPadding(top: 72, bottom: 72);
        tester.view.padding = const FakeViewPadding(top: 72, bottom: 72);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearAllTestValues);

        final map = <String, String>{
          SettingsStore.navBarStyleKey: 'solid',
        };
        final store = SettingsStore.withStorage(
          read: (k) async => map[k],
          write: (k, v) async => map[k] = v,
          delete: (k) async => map.remove(k),
        );

        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(fontFamily: 'Roboto'),
            home: MainShell(
              settingsStore: store,
              weatherApi: _testWeather(),
              healthConnectService: _UnavailableHc(),
              migraineController: _testMigraineController(),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byType(NavDockSolid), findsOneWidget);

        // Bar math: outer width = width - 2x16 margins; inner
        // width = outer - 2x5 padding; slot = inner / 4.
        final slotWidth = (width - 32 - 10) / 4;
        final pill =
            find.byKey(const ValueKey('solid_dock_selection_pill'));
        const tabs = <(DockTab, IconData)>[
          (DockTab.home, Icons.home),
          (DockTab.tools, Icons.assignment),
          (DockTab.quickLog, Icons.edit),
          (DockTab.heart, Icons.favorite),
        ];
        for (var i = 0; i < tabs.length; i++) {
          final (tab, glyph) = tabs[i];
          if (tab != DockTab.home) {
            await tester.tap(dockIcon(glyph));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 600));
          }
          final bar = tester.getRect(gradientBar());
          final cap = tester.getRect(pill);
          expect(bar.size, Size(width - 32, kNavDockSolidHeight),
              reason: 'bar size, tab $tab');
          expect(cap.size, Size(slotWidth, kNavDockSolidCapsuleHeight),
              reason: 'capsule size, tab $tab');
          expect(cap.top - bar.top, closeTo(5, 0.01),
              reason: 'capsule top margin, tab $tab');
          expect(bar.bottom - cap.bottom, closeTo(5, 0.01),
              reason: 'capsule bottom margin, tab $tab');
          expect(cap.left - bar.left,
              closeTo(kNavDockSolidInnerPadding + i * slotWidth, 0.01),
              reason: 'capsule left, tab $tab');
        }

        // Flush bounded-read timers so none outlive the tree.
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(seconds: 31));
        }
      });
    }
  }

  testWidgets('top line is a clipped 2dp inset inside the capsule, '
      'never an edge line', (tester) async {
    await loadFonts(tester);
    tester.view.physicalSize = const Size(360 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    tester.view.viewPadding = const FakeViewPadding(top: 72, bottom: 72);
    tester.view.padding = const FakeViewPadding(top: 72, bottom: 72);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);

    final map = <String, String>{
      SettingsStore.navBarStyleKey: 'solid',
    };
    final store = SettingsStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Roboto'),
        home: MainShell(
          settingsStore: store,
          weatherApi: _testWeather(),
          healthConnectService: _UnavailableHc(),
          migraineController: _testMigraineController(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(kNavDockSolidCapsuleTopLineInset, 2.0);
    final pill = find.byKey(const ValueKey('solid_dock_selection_pill'));
    final cap = tester.getRect(pill);

    // The line: the DecoratedBox carrying the top-line color,
    // inside the pill.
    final line = find.descendant(
      of: pill,
      matching: find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).color ==
                kNavDockSolidCapsuleTopLine,
      ),
    );
    expect(line, findsOneWidget);
    final lineRect = tester.getRect(line);
    // Inset: the line's top sits exactly the inset below the
    // capsule's top edge (pre-fix this was 0 — flush), its
    // height is 1dp, and the whole line lies strictly inside
    // the capsule's rect.
    expect(lineRect.top - cap.top,
        closeTo(kNavDockSolidCapsuleTopLineInset, 0.01));
    expect(lineRect.height, closeTo(1, 0.01));
    expect(cap.contains(lineRect.topLeft), isTrue);
    expect(cap.contains(lineRect.bottomRight), isTrue);

    // The clip: a ClipRRect at the capsule's radius wraps the
    // line inside the pill, so the capsule can never paint
    // outside its rounded shape (the corner-wedge spill).
    final clips = tester.widgetList<ClipRRect>(
      find.descendant(of: pill, matching: find.byType(ClipRRect)),
    );
    expect(
      clips.any((c) =>
          c.borderRadius ==
          BorderRadius.circular(kNavDockSolidCapsuleRadius)),
      isTrue,
      reason: 'capsule content clipped at the capsule radius',
    );

    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(seconds: 31));
    }
  });
}
