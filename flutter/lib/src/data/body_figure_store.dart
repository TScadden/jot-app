import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Which anatomical figure the Body screen shows.
enum BodyFigureVariant { male, female }

/// Resolves a free-text profile gender to a figure variant, or null
/// when it doesn't resolve. "female" is checked before "male"
/// because the word "female" contains "male".
BodyFigureVariant? figureVariantFromGender(String? gender) {
  final g = (gender ?? '').trim().toLowerCase();
  if (g.isEmpty) return null;
  if (g.contains('female') || g.contains('woman') || g == 'f') {
    return BodyFigureVariant.female;
  }
  if (g.contains('male') || g.contains('man') || g == 'm') {
    return BodyFigureVariant.male;
  }
  return null;
}

/// Figure resolution order (founder ruling, Nov 20, 2026):
/// 1. the manual switch on the Body screen (persisted override)
///    wins;
/// 2. the profile gender when it resolves;
/// 3. when the app does not know whether the user is a man or a
///    woman, the figure defaults to the MAN figure.
BodyFigureVariant resolveBodyFigure({
  BodyFigureVariant? override,
  String? profileGender,
}) {
  if (override != null) return override;
  return figureVariantFromGender(profileGender) ?? BodyFigureVariant.male;
}

/// Persists the manual figure switch. Injectable storage following
/// the badge-store pattern so tests never touch the platform.
class BodyFigureStore {
  static const storageKey = 'body_figure_variant_v1';

  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;

  BodyFigureStore({
    Future<String?> Function(String key)? read,
    Future<void> Function(String key, String value)? write,
  }) : _read = read ?? ((key) => const FlutterSecureStorage().read(key: key)),
       _write =
           write ??
           ((key, value) =>
               const FlutterSecureStorage().write(key: key, value: value));

  /// The persisted manual override, or null when never set (or when
  /// storage is unavailable — the caller then falls through to the
  /// profile/default resolution).
  Future<BodyFigureVariant?> loadOverride() async {
    try {
      final v = await _read(storageKey);
      if (v == 'female') return BodyFigureVariant.female;
      if (v == 'male') return BodyFigureVariant.male;
    } catch (_) {
      // Storage unavailable (e.g. widget tests) — no override.
    }
    return null;
  }

  Future<void> saveOverride(BodyFigureVariant variant) async {
    try {
      await _write(storageKey, variant.name);
    } catch (_) {
      // The switch still applies for this session; persistence is
      // best-effort and never blocks the screen.
    }
  }
}
