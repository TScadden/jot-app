import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Heart/Sleep nav toggle (founder direction, Nov 23, 2026): the
/// heart nav slot shows either the Heart screen or the Sleep screen,
/// and the founder's last pick is what the slot (and its dock glyph)
/// shows when they come back. This enum is the slot's mode; MainShell
/// owns the live value, [HeartSleepModeStore] persists it.
enum HeartSleepMode { heart, sleep }

/// Persists the heart-slot mode. Mirrors ToolOrderStore's pattern
/// exactly (FlutterSecureStorage with injectable read/write seams,
/// try/catch everywhere): a failed read or write must never break
/// the UI — the mode just falls back to / stays at heart.
class HeartSleepModeStore {
  static const String storageKey = 'heart_sleep_mode_v1';

  Future<String?> Function(String key) _read = (key) =>
      const FlutterSecureStorage().read(key: key);
  Future<void> Function(String key, String value) _write = (key, value) =>
      const FlutterSecureStorage().write(key: key, value: value);

  /// Test seam.
  void debugSetIO({
    Future<String?> Function(String key)? read,
    Future<void> Function(String key, String value)? write,
  }) {
    if (read != null) _read = read;
    if (write != null) _write = write;
  }

  /// The persisted mode; heart on empty, corrupt, or failed reads.
  Future<HeartSleepMode> loadMode() async {
    try {
      final raw = await _read(storageKey);
      return raw == 'sleep' ? HeartSleepMode.sleep : HeartSleepMode.heart;
    } catch (_) {
      return HeartSleepMode.heart;
    }
  }

  Future<void> saveMode(HeartSleepMode mode) async {
    try {
      await _write(
        storageKey,
        mode == HeartSleepMode.sleep ? 'sleep' : 'heart',
      );
    } catch (_) {
      // Mode persistence is a nicety; never break the UI over it.
    }
  }
}
