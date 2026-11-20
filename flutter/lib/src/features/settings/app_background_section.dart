import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:tabs_lab/src/theme/app_background.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Developer Terminal "App background" section (founder
/// direction Nov 19, 2026) — the dev-only background color
/// changer.
///
/// Placement fence — identical to the SIM's and Restore
/// Streak's: this section renders ONLY when the caller gates it
/// on the signed-in account's pulled `dev_access` flag (Tyson's
/// account only — not other admins, not any build flavor). The
/// widget itself is a dumb surface in the StreakRestoreEntry
/// shape: it holds the active color as a plain value and reports
/// taps through callbacks; the caller owns the
/// [AppBackgroundController] that resolves, persists (local
/// prefs only — never synced), and repaints the app.
///
/// Copy: Juno micro-pass (BG-COPY.md) — label, hint, reset
/// action, and hex placeholder ship byte-for-byte.
abstract final class AppBackgroundCopy {
  static const String sectionLabel = 'App background';
  static const String hint =
      'Sets the app background color on this device only. Applies immediately; reset restores the default.';
  static const String resetLabel = 'Reset to default';
  static const String hexPlaceholder = '#RRGGBB';

  /// Dev-facing validation feedback (not a Juno-ruled string):
  /// shown inline when a submitted hex is not 6 hex digits; the
  /// active color is left untouched.
  static const String invalidHex =
      'Invalid hex — enter 6 hex digits, like #1A2B3C.';
}

class AppBackgroundSection extends StatefulWidget {
  /// The currently resolved base background; the matching preset
  /// swatch (or the custom indicator) renders as active.
  final Color activeColor;

  /// A preset swatch was tapped.
  final ValueChanged<Color> onPresetSelected;

  /// A custom hex was submitted. Returns true when the hex was
  /// valid and applied; false rejects it inline (the section
  /// shows [AppBackgroundCopy.invalidHex] and nothing changes).
  final Future<bool> Function(String hex) onApplyHex;

  /// The Reset action was tapped.
  final VoidCallback onReset;

  const AppBackgroundSection({
    super.key,
    required this.activeColor,
    required this.onPresetSelected,
    required this.onApplyHex,
    required this.onReset,
  });

  @override
  State<AppBackgroundSection> createState() =>
      _AppBackgroundSectionState();
}

class _AppBackgroundSectionState extends State<AppBackgroundSection> {
  final TextEditingController _hexController = TextEditingController();
  bool _showInvalid = false;

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  Future<void> _submitHex() async {
    final ok = await widget.onApplyHex(_hexController.text);
    if (!mounted) return;
    setState(() => _showInvalid = !ok);
    if (ok) _hexController.clear();
  }

  Widget _swatch({
    required Key key,
    required Color color,
    required bool active,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      key: key,
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: active
                ? NotelColors.primary
                : NotelColors.fieldBorderIdle,
            width: active ? 2.5 : 1,
          ),
        ),
        child: active
            ? const Icon(
                Icons.check,
                key: Key('appBgActiveCheck'),
                size: 20,
                color: Colors.white,
                shadows: [
                  Shadow(color: Colors.black, blurRadius: 4),
                ],
              )
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.activeColor;
    final isCustom =
        !AppBackgroundPresets.all.any((p) => p.color == active);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          AppBackgroundCopy.sectionLabel,
          key: Key('appBgSectionLabel'),
          style: TextStyle(
            color: NotelColors.textPrimary,
            fontWeight: FontWeight.w600,
            fontSize: 15,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          AppBackgroundCopy.hint,
          key: Key('appBgHint'),
          style: TextStyle(
              color: NotelColors.textSecondary, fontSize: 12),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final preset in AppBackgroundPresets.all)
              _swatch(
                key: Key(
                    'appBgSwatch_${AppBackgroundController.formatHex(preset.color).substring(1)}'),
                color: preset.color,
                active: preset.color == active,
                onTap: () => widget.onPresetSelected(preset.color),
              ),
            if (isCustom)
              _swatch(
                key: const Key('appBgCustomSwatch'),
                color: active,
                active: true,
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          isCustom
              ? 'Active: custom ${AppBackgroundController.formatHex(active)}'
              : 'Active: ${AppBackgroundController.formatHex(active)}',
          key: const Key('appBgActiveLabel'),
          style: const TextStyle(
              color: NotelColors.textSecondary, fontSize: 12),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('appBgHexField'),
                controller: _hexController,
                decoration: const InputDecoration(
                  hintText: AppBackgroundCopy.hexPlaceholder,
                  isDense: true,
                ),
                style: const TextStyle(
                    color: NotelColors.textPrimary, fontSize: 14),
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(7),
                  FilteringTextInputFormatter.allow(
                      RegExp(r'[0-9a-fA-F#]')),
                ],
                onSubmitted: (_) => unawaited(_submitHex()),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              key: const Key('appBgApplyButton'),
              style: ElevatedButton.styleFrom(
                backgroundColor: NotelColors.primary,
                foregroundColor: Colors.white,
              ),
              onPressed: () => unawaited(_submitHex()),
              child: const Text('Apply'),
            ),
          ],
        ),
        if (_showInvalid) ...[
          const SizedBox(height: 6),
          const Text(
            AppBackgroundCopy.invalidHex,
            key: Key('appBgHexError'),
            style: TextStyle(color: NotelColors.error, fontSize: 12),
          ),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const Key('appBgResetButton'),
            onPressed: widget.onReset,
            child: const Text(AppBackgroundCopy.resetLabel),
          ),
        ),
      ],
    );
  }
}
