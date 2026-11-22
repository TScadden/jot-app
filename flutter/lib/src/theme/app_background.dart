import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Dev-only app background changer (founder direction Nov 19,
/// 2026) — the state seam behind the Developer Terminal section.
///
/// The override re-skins the app's BASE background only:
/// [NotelColors.background] resolves through here, the app theme
/// is rebuilt from the same value (`notelDarkTheme(background:)`),
/// and MainShell listens and repaints its active tab. Card /
/// surface tokens (`NotelColors.surface` / `surfaceHigh`) never
/// change.
///
/// Persistence is local device prefs ONLY, via [SettingsStore]
/// (key `settings_app_background_color`) — the same store the
/// other device-only settings use. The value is never synced,
/// never part of the user profile payload, and the section that
/// writes it renders only inside the `dev_access` gate, so
/// non-dev users never see it and always resolve the default
/// unless a dev set an override on that device.
///
/// Any valid 6-digit hex applies as-is: contrast is the
/// experimenter's problem — this is a dev tool.
class AppBackgroundController extends ChangeNotifier {
  AppBackgroundController({SettingsStore? store})
      : _store = store ?? SettingsStore();

  /// The app-wide instance: the bootstrap loads it before the
  /// first frame, `TabsLabApp` listens to it for the theme, and
  /// the dev section writes through it.
  static final AppBackgroundController instance =
      AppBackgroundController();

  final SettingsStore _store;

  /// The currently resolved base background.
  Color get color => NotelColors.background;

  /// True when the active color is not one of [presets] (a custom
  /// hex is in effect) — the dev section indicates this state.
  bool get isCustom =>
      !AppBackgroundPresets.all.any((p) => p.color == color);

  /// Loads the persisted override (if any) into the token.
  /// Unset or unreadable → the shipped default. Never throws.
  Future<void> load() async {
    final hex = await _store.getAppBackgroundColorHex();
    NotelColors.backgroundOverride =
        (hex == null ? null : parseHex(hex)) ??
            NotelColors.defaultBackground;
    notifyListeners();
  }

  /// Applies [next] immediately (token + listeners first, so the
  /// repaint never waits on storage), then persists it locally.
  Future<void> setColor(Color next) async {
    NotelColors.backgroundOverride = next;
    notifyListeners();
    await _store.setAppBackgroundColorHex(formatHex(next));
  }

  /// Applies a user-entered hex string. Returns false — and
  /// changes NOTHING (no token write, no persist, no notify) —
  /// when [input] is not a valid 6-digit hex.
  Future<bool> applyHex(String input) async {
    final parsed = parseHex(input);
    if (parsed == null) return false;
    await setColor(parsed);
    return true;
  }

  /// Clears the override: the token returns to the shipped
  /// default and the prefs key is deleted (unset state).
  Future<void> reset() async {
    NotelColors.backgroundOverride = NotelColors.defaultBackground;
    notifyListeners();
    await _store.setAppBackgroundColorHex(null);
  }

  /// Parses a 6-digit hex color: `RRGGBB` or `#RRGGBB`, any case.
  /// Anything else (wrong length, non-hex digits, 8-digit alpha
  /// forms) returns null.
  static Color? parseHex(String input) {
    var s = input.trim();
    if (s.startsWith('#')) s = s.substring(1);
    if (s.length != 6) return null;
    final value = int.tryParse(s, radix: 16);
    if (value == null) return null;
    // int.tryParse accepts a leading '-'; a negative parse is not
    // a color.
    if (value < 0 || value > 0xFFFFFF) return null;
    return Color(0xFF000000 | value);
  }

  /// Formats [c] as `#RRGGBB` (uppercase, alpha dropped — every
  /// background this tool sets is fully opaque).
  static String formatHex(Color c) {
    final v = c.toARGB32() & 0xFFFFFF;
    return '#${v.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }
}

/// One preset swatch in the dev section's grid.
class AppBackgroundPreset {
  final String name;
  final Color color;
  const AppBackgroundPreset(this.name, this.color);
}

/// The preset grid: the shipped default first, pure black, then
/// deep variants in the app's dark register (navy / purple /
/// teal / charcoal family). `#080E1A` — the deep navy the founder
/// named for this tool — is the third swatch.
abstract final class AppBackgroundPresets {
  static const List<AppBackgroundPreset> all = [
    AppBackgroundPreset('Default', NotelColors.defaultBackground),
    AppBackgroundPreset('Pure black', Color(0xFF000000)),
    AppBackgroundPreset('Deep navy', Color(0xFF080E1A)),
    AppBackgroundPreset('Midnight', Color(0xFF0C1830)),
    AppBackgroundPreset('Deep purple', Color(0xFF170D2B)),
    AppBackgroundPreset('Deep teal', Color(0xFF062A26)),
    AppBackgroundPreset('Charcoal', Color(0xFF1A1A1E)),
    AppBackgroundPreset('Slate', Color(0xFF141C28)),
  ];
}
