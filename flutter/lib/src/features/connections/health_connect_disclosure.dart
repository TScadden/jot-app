import 'package:flutter/material.dart';

import 'package:tabs_lab/src/theme/notel_colors.dart';

/// MF-3 (Juno compliance, Oct 2026): prominent in-app disclosure shown
/// BEFORE the Health Connect system permission UI (Google Health Connect
/// policy + Play prominent-disclosure rule).
///
/// Deliberately screen-agnostic: the future onboarding connections step
/// imports and calls this same function, so users see identical copy and
/// behavior whether they connect from onboarding or the connections
/// screen.
///
/// Returns true when the user taps "Continue" (the caller may then call
/// `HealthConnectService.requestPermissions()`), false for "Not now" or
/// any dismissal — in which case the caller must NOT request permissions.
Future<bool> showHealthConnectDisclosure(BuildContext context) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: NotelColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: NotelColors.primary.withValues(alpha: 0.15),
        ),
      ),
      title: const Text(
        'Connect Health Connect?',
        style: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.bold,
          color: NotelColors.textPrimary,
        ),
      ),
      content: const Text(
        'Tabs reads your heart rate, sleep, steps, calories, and blood '
        'pressure from Health Connect to show your vitals and weekly '
        'snapshot. Your health data stays on your device and is never sold.',
        style: TextStyle(
          fontSize: 14,
          color: NotelColors.textSecondary,
          height: 1.4,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text(
            'Not now',
            style: TextStyle(color: NotelColors.textSecondary),
          ),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: NotelColors.primary,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Continue'),
        ),
      ],
    ),
  ).then((value) => value ?? false);
}
