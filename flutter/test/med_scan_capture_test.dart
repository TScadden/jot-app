import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/med_scan.dart';
import 'package:tabs_lab/src/data/med_scan_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/med_scan_confirm_sheet.dart';
import 'package:tabs_lab/src/features/tools/med_scan_screen.dart';
import 'package:tabs_lab/src/features/tools/medications_screen.dart';

import 'test_helpers.dart';

/// Med Scan — visual capture harness (the badges_capture_test
/// pattern). Frames @ DPR 3.0 at 360dp and 390dp wide, named
/// with a Width placeholder suffix per frame:
/// - medscan_medications: the Medications screen with the
///   founder-shaped list (Ivabradine 7.5 mg, Desvenlafaxine
///   Succinate ER 25 mg) and the "Scan medication" entry point.
/// - medscan_scan_barcode: the scanner, barcode mode (the
///   preview area is the harness's empty camera surface — no
///   camera exists in the test environment).
/// - medscan_scan_photo: the scanner, label-photo mode.
/// - medscan_confirm_add: the confirm sheet, ADD case —
///   proposal Desvenlafaxine Succinate ER 50 mg, start = today.
/// - medscan_confirm_update: the confirm sheet, UPDATE
///   case — the same proposal matched to the saved 25 mg entry.
///
/// Output dir: $MED_SCAN_CAPTURE_OUT, default
/// ~/workspace/build-med-scan/captures. Filenames carry the
/// capture date (founder unique-filename rule).
void main() {
  testWidgets('capture the med scan frames', (tester) async {
    final outDir = Directory(
      Platform.environment['MED_SCAN_CAPTURE_OUT'] ??
          '${Platform.environment['HOME']}/workspace/build-med-scan/captures',
    );
    await tester.runAsync(() => outDir.create(recursive: true));
    final rootKey = GlobalKey();
    const stamp = '2026-11-23';

    // Real glyphs, not test-font blocks (repo capture pattern).
    await tester.runAsync(() async {
      final loader = FontLoader('Roboto');
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
      await loader.load();
      for (final sdk in ['tools/flutter', 'flutter-sdk']) {
        final iconsFile = File(
          '${Platform.environment['HOME']}/workspace/$sdk/bin/cache/'
          'artifacts/material_fonts/MaterialIcons-Regular.otf',
        );
        if (await iconsFile.exists()) {
          final icons = await iconsFile.readAsBytes();
          final iconLoader = FontLoader('MaterialIcons');
          iconLoader.addFont(
            Future.value(ByteData.view(Uint8List.fromList(icons).buffer)),
          );
          await iconLoader.load();
          break;
        }
      }
    });

    Future<void> capture(String name) async {
      final boundary = rootKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final ui.Image image = await boundary.toImage(pixelRatio: 3.0);
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${outDir.path}/$name.png')
            .writeAsBytes(byteData!.buffer.asUint8List());
      });
    }

    void setWidth(int dp) {
      tester.view.physicalSize = Size(dp * 3.0, 2400);
      tester.view.devicePixelRatio = 3.0;
    }

    // The scanner plugin has no platform side in the test
    // environment: mock its channels with a benign "authorized,
    // started" camera so the barcode frame renders the screen's
    // real chrome (the preview itself stays the harness's blank
    // camera surface — no camera exists here).
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.steenbakker.mobile_scanner/scanner/method'),
      (call) async {
        switch (call.method) {
          case 'state':
            return 1; // MobileScannerAuthorizationState.authorized
          case 'start':
            return <String, Object?>{
              'textureId': 0,
              'cameraDirection': 0,
              'numberOfCameras': 1,
              'currentTorchState': -1,
              'handlesCropAndRotation': true,
              'naturalDeviceOrientation': 'PORTRAIT_UP',
              'sensorOrientation': 90,
              'size': {'width': 1080.0, 'height': 2400.0},
            };
          default:
            return null;
        }
      },
    );
    for (final channel in [
      'dev.steenbakker.mobile_scanner/scanner/event',
      'dev.steenbakker.mobile_scanner/scanner/deviceOrientation',
    ]) {
      messenger.setMockStreamHandler(
        EventChannel(channel),
        MockStreamHandler.inline(onListen: (_, _) {}, onCancel: (_) {}),
      );
    }

    addTearDown(tester.view.reset);

    final backend = _CaptureBackend();
    final desvenlafaxine25 = MedicationEntry(
      id: 'cap-med-2',
      name: 'Desvenlafaxine Succinate ER',
      dose: '25 mg',
      startDate: 'Oct 1, 2026',
      frequency: 'Once daily',
    );
    const proposal = MedScanProposal(
      name: 'Desvenlafaxine Succinate ER',
      dose: '50 mg',
      form: 'Tablet',
      source: MedScanSource.barcode,
    );

    for (final width in [360, 390]) {
      setWidth(width);

      // FRAME 1 — Medications screen with the Scan entry point.
      await tester.pumpWidget(RepaintBoundary(
        key: rootKey,
        child: MaterialApp(home: MedicationsScreen(backend: backend)),
      ));
      await tester.pumpAndSettle();
      await capture('medscan_medications_${width}_$stamp');

      // FRAME 2 — scanner, barcode mode (rationale already seen).
      final mem = <String, String>{MedScanStore.rationaleSeenKey: 'true'};
      final store = MedScanStore.withStorage(
        read: (k) async => mem[k],
        write: (k, v) async => mem[k] = v,
      );
      await tester.pumpWidget(RepaintBoundary(
        key: rootKey,
        child: MaterialApp(home: MedScanScreen(store: store)),
      ));
      await tester.pumpAndSettle();
      await capture('medscan_scan_barcode_${width}_$stamp');

      // FRAME 3 — scanner, label-photo mode.
      await tester.tap(find.text('Label photo'));
      await tester.pumpAndSettle();
      await capture('medscan_scan_photo_${width}_$stamp');

      // FRAME 4 — confirm sheet, ADD case, over the meds screen.
      await tester.pumpWidget(RepaintBoundary(
        key: rootKey,
        child: MaterialApp(home: MedicationsScreen(backend: backend)),
      ));
      await tester.pumpAndSettle();
      unawaited(showMedScanConfirmSheet(
        tester.element(find.byType(MedicationsScreen)),
        proposal: proposal,
        matchedEntry: null,
      ));
      await tester.pumpAndSettle();
      await capture('medscan_confirm_add_${width}_$stamp');
      await tester.tap(find.byKey(const ValueKey('med_scan_cancel')));
      await tester.pumpAndSettle();

      // FRAME 5 — confirm sheet, UPDATE case ("Add as new
      // instead" visible; title names the saved 25 mg entry).
      unawaited(showMedScanConfirmSheet(
        tester.element(find.byType(MedicationsScreen)),
        proposal: proposal,
        matchedEntry: desvenlafaxine25,
      ));
      await tester.pumpAndSettle();
      await capture('medscan_confirm_update_${width}_$stamp');
      await tester.tap(find.byKey(const ValueKey('med_scan_cancel')));
      await tester.pumpAndSettle();
    }
  });
}

/// The founder-shaped seeded list: Ivabradine 7.5 mg and
/// Desvenlafaxine Succinate ER 25 mg, both active.
class _CaptureBackend extends TabsBackend {
  _CaptureBackend()
      : super(sessionStore: FakeSessionStore()..token = 'tok');

  @override
  Future<Map<String, dynamic>?> fetchProfile() async => {
        'medications': jsonEncode([
          {
            'id': 'cap-med-1',
            'name': 'Ivabradine',
            'startDate': 'Sep 15, 2026',
            'endDate': 'Present',
            'isPresent': true,
            'dose': '7.5 mg',
            'frequency': 'Twice daily',
            'updatedAt': 1000,
            'isDeleted': false,
          },
          {
            'id': 'cap-med-2',
            'name': 'Desvenlafaxine Succinate ER',
            'startDate': 'Oct 1, 2026',
            'endDate': 'Present',
            'isPresent': true,
            'dose': '25 mg',
            'frequency': 'Once daily',
            'updatedAt': 1000,
            'isDeleted': false,
          },
        ]),
      };

  @override
  void invalidateSyncPull() {}
}
