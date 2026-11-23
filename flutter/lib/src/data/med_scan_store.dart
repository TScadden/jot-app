import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Med Scan (Nov 22, 2026) — the one bit of on-device state the
/// scan flow needs: whether the camera rationale has been
/// shown. Juno's §3/§8.1 rule: the rationale appears BEFORE the
/// system camera-permission prompt, on FIRST use of Scan only —
/// so the flag is persisted (the [OnboardingStore] pattern:
/// flutter_secure_storage, injectable read/write for tests).
/// It records that the rationale was shown, nothing about any
/// scan; no scan data, label text, or barcode value is ever
/// stored here (Juno §8.3).
class MedScanStore {
  static const rationaleSeenKey = 'med_scan_camera_rationale_seen';

  Future<String?> Function(String key) _read = (key) =>
      const FlutterSecureStorage().read(key: key);
  Future<void> Function(String key, String value) _write = (key, value) =>
      const FlutterSecureStorage().write(key: key, value: value);

  MedScanStore();

  MedScanStore._(this._read, this._write);

  @visibleForTesting
  factory MedScanStore.withStorage({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
  }) => MedScanStore._(read, write);

  /// True once the camera rationale has been shown (and the
  /// user tapped Continue). A storage failure reads as "not
  /// seen" — showing the rationale again is the safe direction.
  Future<bool> rationaleSeen() async {
    try {
      return await _read(rationaleSeenKey) == 'true';
    } catch (_) {
      return false;
    }
  }

  /// Marks the rationale as shown. Best-effort: a failed write
  /// only means the rationale may show once more.
  Future<void> markRationaleSeen() async {
    try {
      await _write(rationaleSeenKey, 'true');
    } catch (_) {
      // Best-effort — see the doc above.
    }
  }
}
