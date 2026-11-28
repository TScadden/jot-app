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

  /// Flow3 (Nov 19, 2026) — a muted, NON-interactive label rendered
  /// in the trailing slot instead of a Skip button (the Profile
  /// step's "Can't skip"). Wider than the 40dp button slot, so the
  /// header is laid out as a Stack: the logo row is centered on the
  /// FULL header width and the side slots overlay it, which keeps
  /// the logo at the exact center whether the trailing slot holds
  /// the 48dp Skip hit box, this label, or nothing.
  final String? trailingLabel;

  const OnboardingHeader({
    super.key,
    this.onBack,
    this.onSkip,
    this.trailingLabel,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      // SCORECARD-3 #2: with a Skip button the header is 48dp tall
      // so the Skip hit box can be a full 48dp (design-audit §7);
      // the back-button and trailing-label forms keep the native
      // 40dp height. The Skip glyph itself is unchanged.
      height: onSkip != null ? 48 : 40,
      child: Stack(
        children: [
          const Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                _TabsLogoMark(),
              ],
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
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
                        child: Icon(
                          Icons.arrow_back,
                          color: NotelColors.textPrimary,
                          size: 20,
                        ),
                      ),
                    ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: trailingLabel != null
                ? Text(
                    trailingLabel!,
                    key: const ValueKey('onboarding_header_trailing_label'),
                    style: TextStyle(
                      color: NotelColors.textSecondary,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  )
                : SizedBox(
                    width: 48,
                    height: 48,
                    child: onSkip == null
                        ? null
                        : TextButton(
                            onPressed: onSkip,
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(48, 48),
                              tapTargetSize:
                                  MaterialTapTargetSize.padded,
                            ),
                            child: Text(
                              'Skip',
                              style: TextStyle(
                                color: NotelColors.textSecondary,
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// The centered 28dp logo + "Tabs" wordmark, factored out so the
/// Stack-based header centers the identical mark.
class _TabsLogoMark extends StatelessWidget {
  const _TabsLogoMark();

  @override
  Widget build(BuildContext context) {
    return Row(
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
    );
  }
}

/// Flow3 (Nov 19, 2026) — the pinned 6-segment progress bar shown
/// directly under [OnboardingHeader] on every SETUP step (never on
/// the sign-up/log-in screen). Segments, in order: Consent 1,
/// Profile 2, Conditions 3, Connections 4, Gems 5, Membership 6.
/// [currentSegment] is 1-based; segments up to and including it
/// render filled.
class OnboardingProgressBar extends StatelessWidget {
  static const int totalSegments = 6;

  final int currentSegment;

  const OnboardingProgressBar({super.key, required this.currentSegment});

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const ValueKey('onboarding_progress_bar'),
      children: [
        for (var i = 1; i <= totalSegments; i++) ...[
          if (i > 1) const SizedBox(width: 6),
          Expanded(
            child: Container(
              key: ValueKey('onboarding_progress_segment_$i'),
              height: 6,
              decoration: BoxDecoration(
                color: i <= currentSegment
                    ? NotelColors.primary
                    : NotelColors.surfaceHigh,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Flow3 pinned bottom inset: every setup screen's primary button
/// sits at this same bottom position (24dp page padding + 12dp
/// below the button area is the app standard used by the screens).
const double kOnboardingBottomPadding = 12;

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
        ),
        // The label carries its own style (the pattern the app's
        // other filled buttons use): a textStyle passed through
        // styleFrom resolves with inherit:false, which in the
        // capture harness drops the label to the test font —
        // child-carried style renders identically on device and
        // legibly in harness captures.
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
