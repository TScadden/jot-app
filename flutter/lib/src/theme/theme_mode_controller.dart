import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Theme-mode package (Nov 27, 2026) — the state seam behind the
/// re-enabled Appearance picker (Light / Dark / System).
///
/// The stored mode lives in [SettingsStore] (key
/// `settings_theme_mode`, values LIGHT / DARK / SYSTEM — the same
/// key and values that predate the Oct 2026 disabling, honored
/// untouched). This controller is the LIVE channel on top of that
/// store, following the [AppBackgroundController] precedent:
///
/// - the bootstrap [load]s the stored mode BEFORE the first frame
///   and selects the matching [NotelColors] palette, so a stored
///   LIGHT/SYSTEM takes effect on first launch with no flash;
/// - [setMode] writes the store, then applies the mode in memory;
/// - the Settings picker, whose screen owns a DIFFERENT
///   [SettingsStore] instance than this controller, writes through
///   its own store and then calls [applyMode] — storage stays the
///   source of truth, this channel only carries the live switch;
/// - with SYSTEM selected, the controller observes the platform
///   brightness and notifies when it changes, so the app
///   live-switches with the device setting, no restart.
///
/// The controller never touches the palette mid-frame on its own:
/// it exposes [resolvedBrightness] for the target, while the app
/// root (TabsLabApp) performs the actual palette flip inside its
/// snapshot cross-fade, so the whole UI switches in one frame,
/// under the fade.
class ThemeModeController extends ChangeNotifier
    with WidgetsBindingObserver {
  ThemeModeController({SettingsStore? store})
      : _store = store ?? SettingsStore();

  /// The app-wide instance: the bootstrap loads it before the
  /// first frame, `TabsLabApp` listens to it, and the Settings
  /// Appearance picker applies its writes through it.
  static final ThemeModeController instance = ThemeModeController();

  final SettingsStore _store;

  String _mode = 'DARK';
  bool _observingPlatform = false;

  /// The stored mode in effect: 'LIGHT' | 'DARK' | 'SYSTEM'.
  String get mode => _mode;

  ThemeMode get themeMode => switch (_mode) {
        'LIGHT' => ThemeMode.light,
        'SYSTEM' => ThemeMode.system,
        _ => ThemeMode.dark,
      };

  /// The platform's current brightness (read live, so a stale
  /// cached value can never disagree with the device). Read
  /// through the binding's dispatcher — the same source
  /// WidgetsApp resolves SYSTEM from — so the controller and
  /// MaterialApp can never disagree (and tests drive it through
  /// the test dispatcher's override).
  Brightness get platformBrightness {
    try {
      return WidgetsBinding.instance.platformDispatcher
          .platformBrightness;
    } catch (_) {
      return ui.PlatformDispatcher.instance.platformBrightness;
    }
  }

  /// The brightness the app should render at for the current mode.
  Brightness get resolvedBrightness => switch (_mode) {
        'LIGHT' => Brightness.light,
        'SYSTEM' => platformBrightness,
        _ => Brightness.dark,
      };

  /// Loads the persisted mode (if any) and selects its palette.
  /// Unset or unreadable → DARK, the shipped default — exactly
  /// [SettingsStore.getThemeMode]'s contract. Never throws.
  Future<void> load() async {
    _mode = await _store.getThemeMode();
    NotelColors.setBrightness(resolvedBrightness);
    _observePlatform();
    notifyListeners();
  }

  /// Writes [mode] to the store, then applies it live.
  Future<void> setMode(String mode) async {
    await _store.setThemeMode(mode);
    applyMode(mode);
  }

  /// Applies an already-persisted [mode] live (the Settings
  /// picker's path: its own store instance performed the write).
  /// Palette selection itself is left to the app root's fade
  /// coordinator — it reads [resolvedBrightness] when this
  /// notification lands and flips the palette under the fade.
  void applyMode(String mode) {
    if (mode != 'LIGHT' && mode != 'DARK' && mode != 'SYSTEM') return;
    if (_mode == mode) return;
    _mode = mode;
    _observePlatform();
    notifyListeners();
  }

  void _observePlatform() {
    if (_observingPlatform) return;
    try {
      WidgetsBinding.instance.addObserver(this);
      _observingPlatform = true;
    } catch (_) {
      // No binding yet (bare unit tests): SYSTEM still resolves
      // live through [platformBrightness] on every read; only the
      // push notification is unavailable.
    }
  }

  @override
  void didChangePlatformBrightness() {
    // Only a SYSTEM selection renders from the platform; for the
    // pinned modes a device change is not an app event.
    if (_mode == 'SYSTEM') notifyListeners();
  }

  @override
  void dispose() {
    if (_observingPlatform) {
      try {
        WidgetsBinding.instance.removeObserver(this);
      } catch (_) {}
      _observingPlatform = false;
    }
    super.dispose();
  }
}
