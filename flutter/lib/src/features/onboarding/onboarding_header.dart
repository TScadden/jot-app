import 'package:flutter/material.dart';

import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 32 — port of native `TopLogoHeader` (`TopLogoHeader.kt:28-75`),
/// the header every native onboarding screen carries:
/// - Optional back button at the start: 40dp circle, NotelSurfaceHigh
///   fill, arrow-back icon in NotelTextPrimary.
/// - Centered logo + wordmark: 28dp Tabs note image, 8dp gap, "Tabs"
///   26sp Black, NotelPrimary, 1sp letter spacing.
/// - Optional "Skip" text button at the end: NotelTextSecondary, 15sp,
///   Medium.
///
/// Native lays this out as a full-width Box with the logo centered;
/// the Flutter port uses a Row with fixed 40dp side slots so the logo
/// stays centered whether the back/skip affordances are present.
class OnboardingHeader extends StatelessWidget {
  final VoidCallback? onBack;
  final VoidCallback? onSkip;

  const OnboardingHeader({super.key, this.onBack, this.onSkip});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 40,
          height: 40,
          child: onBack == null
              ? null
              : Material(
                  color: NotelColors.surfaceHigh,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: onBack,
                    child: const Icon(
                      Icons.arrow_back,
                      color: NotelColors.textPrimary,
                      size: 20,
                    ),
                  ),
                ),
        ),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/ic_tabs_note.png',
                width: 28,
                height: 28,
              ),
              const SizedBox(width: 8),
              const Text(
                'Tabs',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  color: NotelColors.primary,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          width: 40,
          height: 40,
          child: onSkip == null
              ? null
              : TextButton(
                  onPressed: onSkip,
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'Skip',
                    style: TextStyle(
                      color: NotelColors.textSecondary,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

/// The onboarding steps' shared primary button: full width, 54dp,
/// 24dp radius, NotelPrimary fill, white 16sp Bold label — the shape
/// native uses for "Next" / "Continue" / "Start keeping Tabs"
/// throughout the onboarding routes.
class OnboardingPrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  const OnboardingPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: NotelColors.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor:
              NotelColors.primary.withValues(alpha: 0.4),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        child: Text(label),
      ),
    );
  }
}
