import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:tabs_lab/src/data/med_scan.dart';
import 'package:tabs_lab/src/data/med_scan_store.dart';
import 'package:tabs_lab/src/features/tools/med_scan_strings.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// What the scan flow hands back to the Medications screen:
/// - [proposal] non-null → the medication was identified; the
///   caller shows the confirm sheet (nothing is saved here).
/// - [proposal] null (but the result itself non-null) → not
///   identified; the caller drops into the normal manual add
///   flow, prefilled with [prefillName] / [prefillDose] when
///   the label photo yielded them (Juno §5: any text that was
///   read is already filled in; no field gets a guessed value).
/// A null RESULT (route popped with no value) means the user
/// backed out — nothing happens.
class MedScanFlowResult {
  final MedScanProposal? proposal;
  final String? prefillName;
  final String? prefillDose;

  const MedScanFlowResult.identified(MedScanProposal this.proposal)
    : prefillName = null,
      prefillDose = null;

  const MedScanFlowResult.unidentified({this.prefillName, this.prefillDose})
    : proposal = null;
}

enum _ScanMode { barcode, photo }

enum _ScanPhase { rationale, scanning, busy, notIdentified, permissionDenied }

/// Med Scan screen (Nov 22, 2026): two modes —
/// (a) live barcode scan (mobile_scanner / ML Kit, on-device
///     detection; only the barcode DIGITS leave the phone, to
///     the public openFDA/RxNorm lookups in [DrugLookupService]);
/// (b) label photo: camera capture via image_picker, OCR via
///     google_mlkit_text_recognition — FULLY ON-DEVICE. The
///     image is processed from its local file path and is never
///     uploaded: this screen makes no network call on the photo
///     path, and the OCR result is parsed locally by
///     [parseMedicationLabelLines]. The image and the recognized
///     text are never written to analytics, crash reports, or
///     logs, and are not retained after this screen closes
///     (Juno §8.3) — they live only in this state's memory.
///
/// PERMISSION TIMING (Juno §3/§8.1): on first use the screen
/// opens on the in-app rationale; the camera does not start —
/// and the system permission prompt cannot fire — until the
/// user taps Continue. The rationale is shown once (persisted
/// by [MedScanStore]). Denial lands on the §3 message with a
/// direct manual-add route, never a dead end.
class MedScanScreen extends StatefulWidget {
  /// Injectable for tests / future wiring.
  final DrugLookupService? lookupService;
  final ImagePicker? imagePicker;
  final MedScanStore? store;

  const MedScanScreen({
    super.key,
    this.lookupService,
    this.imagePicker,
    this.store,
  });

  @override
  State<MedScanScreen> createState() => _MedScanScreenState();
}

class _MedScanScreenState extends State<MedScanScreen> {
  late final DrugLookupService _lookup;
  late final ImagePicker _picker;
  late final MedScanStore _store;
  final MobileScannerController _scannerController = MobileScannerController();

  _ScanMode _mode = _ScanMode.barcode;

  /// Starts at rationale — the SAFE default: the camera cannot
  /// start before the first-use check resolves, and a user who
  /// already saw the rationale flips to scanning a frame later.
  _ScanPhase _phase = _ScanPhase.rationale;

  /// The mode a "not identified" result came from.
  _ScanMode _failedMode = _ScanMode.barcode;

  /// Partial reads from a failed label parse, carried into the
  /// manual add flow as prefills.
  String? _prefillName;
  String? _prefillDose;

  /// A barcode was accepted and its lookup is in flight (or
  /// done) — further detections are ignored.
  bool _barcodeHandled = false;

  @override
  void initState() {
    super.initState();
    _lookup = widget.lookupService ?? DrugLookupService();
    _picker = widget.imagePicker ?? ImagePicker();
    _store = widget.store ?? MedScanStore();
    _resolveRationale();
  }

  Future<void> _resolveRationale() async {
    final seen = await _store.rationaleSeen();
    if (!mounted || !seen) return;
    setState(() => _phase = _ScanPhase.scanning);
  }

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  Future<void> _continueFromRationale() async {
    await _store.markRationaleSeen();
    if (!mounted) return;
    setState(() => _phase = _ScanPhase.scanning);
    if (_mode == _ScanMode.barcode) {
      await _scannerController.start();
    }
  }

  Future<void> _setMode(_ScanMode mode) async {
    if (mode == _mode && _phase == _ScanPhase.scanning) return;
    final keepRationale = _phase == _ScanPhase.rationale;
    setState(() {
      _mode = mode;
      if (!keepRationale) _phase = _ScanPhase.scanning;
      _prefillName = null;
      _prefillDose = null;
    });
    if (keepRationale) return;
    if (mode == _ScanMode.photo) {
      await _scannerController.stop();
    } else {
      _barcodeHandled = false;
      await _scannerController.start();
    }
  }

  // ── Barcode path ─────────────────────────────────────────────

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_barcodeHandled || _phase != _ScanPhase.scanning) return;
    String? raw;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim();
      if (value != null && value.isNotEmpty) {
        raw = value;
        break;
      }
    }
    if (raw == null) return;
    _barcodeHandled = true;
    setState(() => _phase = _ScanPhase.busy);
    await _scannerController.stop();
    final proposal = await _lookup.lookupBarcode(raw);
    if (!mounted) return;
    if (proposal != null) {
      Navigator.of(context).pop(MedScanFlowResult.identified(proposal));
      return;
    }
    setState(() {
      _failedMode = _ScanMode.barcode;
      _prefillName = null;
      _prefillDose = null;
      _phase = _ScanPhase.notIdentified;
    });
  }

  // ── Label photo path (on-device ONLY) ────────────────────────

  Future<void> _takeLabelPhoto() async {
    final XFile? photo;
    try {
      photo = await _picker.pickImage(source: ImageSource.camera);
    } on PlatformException catch (e) {
      if (!mounted) return;
      if (e.code == 'camera_access_denied' || e.code == 'photo_access_denied') {
        setState(() => _phase = _ScanPhase.permissionDenied);
      }
      return;
    } catch (_) {
      return;
    }
    if (photo == null || !mounted) return; // user backed out
    setState(() => _phase = _ScanPhase.busy);

    // On-device OCR: the image is read from its local path by
    // ML Kit's on-device recognizer. No upload exists on this
    // path — no network call is made with the image or its text.
    final recognizer = TextRecognizer();
    try {
      final recognized = await recognizer.processImage(
        InputImage.fromFilePath(photo.path),
      );
      if (!mounted) return;
      final lines = <String>[
        for (final block in recognized.blocks)
          for (final line in block.lines) line.text,
      ];
      final effectiveLines = lines.isNotEmpty
          ? lines
          : recognized.text.split('\n');
      final parts = parseMedicationLabelLines(effectiveLines);
      if (parts != null && parts.name != null && parts.name!.isNotEmpty) {
        Navigator.of(context).pop(
          MedScanFlowResult.identified(
            MedScanProposal(
              name: parts.name!,
              dose: parts.dose ?? '',
              form: parts.form,
              source: MedScanSource.labelPhoto,
            ),
          ),
        );
        return;
      }
      setState(() {
        _failedMode = _ScanMode.photo;
        _prefillName = parts?.name;
        _prefillDose = parts?.dose;
        _phase = _ScanPhase.notIdentified;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failedMode = _ScanMode.photo;
        _prefillName = null;
        _prefillDose = null;
        _phase = _ScanPhase.notIdentified;
      });
    } finally {
      await recognizer.close();
    }
  }

  // ── Shared exits ─────────────────────────────────────────────

  void _addManually() {
    Navigator.of(context).pop(
      MedScanFlowResult.unidentified(
        prefillName: _prefillName,
        prefillDose: _prefillDose,
      ),
    );
  }

  /// §5's Cancel: back to the scan screen (the mode toggle is
  /// the retry path — switch modes or scan again).
  Future<void> _backToScanning() async {
    setState(() {
      _phase = _ScanPhase.scanning;
      _barcodeHandled = false;
    });
    if (_mode == _ScanMode.barcode && _failedMode == _ScanMode.barcode) {
      await _scannerController.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back,
            color: NotelColors.textPrimary,
            semanticLabel: 'Back',
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          MedScanStrings.screenTitle,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SegmentedButton<_ScanMode>(
              segments: const [
                ButtonSegment(
                  value: _ScanMode.barcode,
                  icon: Icon(Icons.qr_code_scanner, size: 18),
                  label: Text(MedScanStrings.modeBarcode),
                ),
                ButtonSegment(
                  value: _ScanMode.photo,
                  icon: Icon(Icons.photo_camera, size: 18),
                  label: Text(MedScanStrings.modeLabelPhoto),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (selection) => _setMode(selection.first),
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    switch (_phase) {
      case _ScanPhase.rationale:
        return _rationalePanel();
      case _ScanPhase.busy:
        return _busyPanel();
      case _ScanPhase.notIdentified:
        return _notIdentifiedPanel();
      case _ScanPhase.permissionDenied:
        return _permissionDeniedPanel();
      case _ScanPhase.scanning:
        return _mode == _ScanMode.barcode ? _barcodePanel() : _photoPanel();
    }
  }

  /// §3 rationale — rendered BEFORE any camera widget exists,
  /// so no system prompt can precede it.
  Widget _rationalePanel() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.photo_camera, size: 48, color: NotelColors.primary),
          const SizedBox(height: 16),
          const Text(
            MedScanStrings.rationaleBody,
            style: TextStyle(fontSize: 14, color: NotelColors.textPrimary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            key: const ValueKey('med_scan_rationale_continue'),
            onPressed: _continueFromRationale,
            style: ElevatedButton.styleFrom(
              backgroundColor: NotelColors.primary,
            ),
            child: const Text(
              MedScanStrings.rationaleContinue,
              style: TextStyle(color: Colors.white),
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            key: const ValueKey('med_scan_rationale_not_now'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(MedScanStrings.rationaleNotNow),
          ),
        ],
      ),
    );
  }

  Widget _barcodePanel() {
    return Column(
      children: [
        Expanded(
          child: MobileScanner(
            controller: _scannerController,
            onDetect: _onDetect,
            errorBuilder: (context, error) {
              if (error.errorCode == MobileScannerErrorCode.permissionDenied) {
                return _permissionDeniedPanel();
              }
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    MedScanStrings.notIdentifiedMessage,
                    style: TextStyle(color: NotelColors.textSecondary),
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            },
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            MedScanStrings.barcodeHint,
            style: TextStyle(fontSize: 13, color: NotelColors.textSecondary),
            textAlign: TextAlign.center,
          ),
        ),
        // §6 barcode lookup disclosure, footer of barcode mode.
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 14),
          child: Text(
            MedScanStrings.barcodeLookupNote,
            style: TextStyle(fontSize: 11, color: NotelColors.textSecondary),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }

  Widget _photoPanel() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.photo_camera, size: 48, color: NotelColors.primary),
          const SizedBox(height: 16),
          const Text(
            MedScanStrings.photoHint,
            style: TextStyle(fontSize: 13, color: NotelColors.textSecondary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              key: const ValueKey('med_scan_take_photo'),
              onPressed: _takeLabelPhoto,
              style: ElevatedButton.styleFrom(
                backgroundColor: NotelColors.primary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                MedScanStrings.takePhotoButton,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          // §6 label-photo privacy line, footer of photo mode.
          const Text(
            MedScanStrings.photoPrivacyNote,
            style: TextStyle(fontSize: 11, color: NotelColors.textSecondary),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _busyPanel() {
    // No busy copy is in Juno's ruled set — a bare spinner,
    // never an unruled string.
    return const Center(
      child: CircularProgressIndicator(color: NotelColors.primary),
    );
  }

  Widget _notIdentifiedPanel() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.search_off, size: 48, color: NotelColors.primary),
          const SizedBox(height: 16),
          const Text(
            MedScanStrings.notIdentifiedMessage,
            style: TextStyle(fontSize: 14, color: NotelColors.textPrimary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            key: const ValueKey('med_scan_add_manually'),
            onPressed: _addManually,
            style: ElevatedButton.styleFrom(
              backgroundColor: NotelColors.primary,
            ),
            child: const Text(
              MedScanStrings.addManuallyButton,
              style: TextStyle(color: Colors.white),
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            key: const ValueKey('med_scan_not_identified_cancel'),
            onPressed: _backToScanning,
            child: const Text(MedScanStrings.cancelButton),
          ),
        ],
      ),
    );
  }

  Widget _permissionDeniedPanel() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(
            Icons.no_photography,
            size: 48,
            color: NotelColors.primary,
          ),
          const SizedBox(height: 16),
          const Text(
            MedScanStrings.permissionDeniedBody,
            style: TextStyle(fontSize: 14, color: NotelColors.textPrimary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            key: const ValueKey('med_scan_add_manually_denied'),
            onPressed: _addManually,
            style: ElevatedButton.styleFrom(
              backgroundColor: NotelColors.primary,
            ),
            child: const Text(
              MedScanStrings.addManuallyButton,
              style: TextStyle(color: Colors.white),
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            key: const ValueKey('med_scan_denied_cancel'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(MedScanStrings.cancelButton),
          ),
        ],
      ),
    );
  }
}
