import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/migraine_attack_store.dart';
import 'package:tabs_lab/src/data/migraine_controller.dart';
import 'package:tabs_lab/src/data/migraine_notification.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/shell/main_shell.dart';

/// Drawer icon alignment — visual capture harness (modeled on
/// drawer_nav_fade_capture_test.dart). Renders the shell with the
/// drawer OPEN at the founder's 360dp phone class and at 390dp,
/// DPR 3.0, real Roboto + MaterialIcons fonts (no test-font blocks),
/// so the drawer's four leading icons can be pixel-checked: after
/// the fix the Badges badge (BadgeWidget at 22 in the drawer) must
/// share the other rows' icon center column and label start.
///
/// Output dir: $DRAWER_ICON_ALIGN_CAPTURE_OUT, default
/// ~/workspace/build-drawer-icon-align/captures.

class _UnavailableHc extends HealthConnectService {
  @override
  Future<HcAvailability> probeAvailability() async => const HcAvailability(
        serviceAvailable: false,
        grantedPermissions: {},
        bridgeErrorCode: null,
        stepsProbe: HcReadProbeOutcome.securityFailure,
        persistedConnected: false,
      );
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
  Future<String> resolveMigraineCategoryId() async => '7';
  @override
  Future<String> generateEntryId() async => '100';
  @override
  Future<bool?> entryExists(String entryId) async => true;
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
              200);
        }
        return http.Response('not found', 404);
      }),
    );

void main() {
  late Directory outDir;
  final rootKey = GlobalKey();

  setUpAll(() async {
    outDir = Directory(
      Platform.environment['DRAWER_ICON_ALIGN_CAPTURE_OUT'] ??
          '${Platform.environment['HOME']}'
              '/workspace/build-drawer-icon-align/captures',
    );
    await outDir.create(recursive: true);
  });

  Future<void> loadFonts(WidgetTester tester) async {
    // Real glyphs, not test-font blocks (repo capture pattern).
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

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary = rootKey.currentContext!.findRenderObject()!
        as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 3.0);
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${outDir.path}/$name.png')
          .writeAsBytes(byteData!.buffer.asUint8List());
    });
  }

  for (final width in [360.0, 390.0]) {
    final tag = width.toInt();
    testWidgets('capture the open drawer at $tag', (tester) async {
      await loadFonts(tester);
      tester.view.physicalSize = Size(width * 3, 800 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(RepaintBoundary(
        key: rootKey,
        child: MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          home: MainShell(
            weatherApi: _testWeather(),
            healthConnectService: _UnavailableHc(),
            migraineController: _testMigraineController(),
          ),
        ),
      ));
      await tester.pump();
      // Fire the staggered-entrance timers and let loads land.
      await tester.pump(const Duration(milliseconds: 600));

      await tester.tap(find.byKey(const ValueKey('home_drawer_button')));
      await tester.pump();
      // Drawer slide (250ms) complete before the capture.
      await tester.pump(const Duration(milliseconds: 500));
      await capture(tester, 'drawer_open_$tag');

      // Flush Home's Daily Score capture chain timers (see the
      // nav-fade harness: bounded HC reads park 30s timers against
      // the missing test platform channel).
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(seconds: 31));
      }
    });
  }
}
