import 'package:flutter/material.dart';

import 'package:tabs_lab/src/features/onboarding/onboarding_header.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Flow3 (Nov 19, 2026) — NEW step between Connections and
/// Membership: Streaks / Streak Freezes / Gems explainer.
/// Copy is verbatim from the approved mock
/// `flow3_06_gems_v5_20261119.png`. No progress dots — the pinned
/// 6-segment bar (segment 5) is the only progress indicator.
class GemsOnboardingScreen extends StatelessWidget {
  final VoidCallback onBack;
  final VoidCallback onContinue;

  const GemsOnboardingScreen({
    super.key,
    required this.onBack,
    required this.onContinue,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OnboardingHeader(onBack: onBack),
              ),
              const SizedBox(height: 12),
              const OnboardingProgressBar(currentSegment: 5),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      const SizedBox(height: 24),
                      const Text(
                        'STREAKS, FREEZES & GEMS',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                          color: NotelColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Three little things that help you stick with it.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15,
                          color: NotelColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              NotelColors.primary.withValues(alpha: 0.35),
                              Colors.transparent,
                            ],
                          ),
                        ),
                        child: Image.asset(
                          'assets/images/bandit_cheer_cut_v3.png',
                          width: 140,
                          height: 140,
                          fit: BoxFit.contain,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const _GemsCard(
                        icon: Icons.local_fire_department,
                        iconColor: Color(0xFFFF7043),
                        title: 'Streaks',
                        body: 'Finish your Daily Summary each day and '
                            'your streak grows. One day at a time.',
                      ),
                      const SizedBox(height: 12),
                      const _GemsCard(
                        icon: Icons.ac_unit,
                        iconColor: Color(0xFF4FC3F7),
                        title: 'Streak Freezes',
                        body: 'Miss a day? A freeze covers it, so your '
                            'streak stays alive. You get one free every '
                            'month, and you can buy more.',
                      ),
                      const SizedBox(height: 12),
                      _GemsCard(
                        customIcon: Image.asset(
                          'assets/images/tabs_gem_icon_v1_20261119.png',
                          width: 30,
                          height: 30,
                          fit: BoxFit.contain,
                        ),
                        title: 'Gems',
                        body: 'Finish your day to earn 5 gems. Streak '
                            'milestones and perfect weeks pay bonus '
                            'gems. Trade 100 gems for a streak freeze.',
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.only(bottom: kOnboardingBottomPadding),
                child: OnboardingPrimaryButton(
                  label: 'Got it',
                  onPressed: onContinue,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GemsCard extends StatelessWidget {
  final IconData? icon;
  final Color? iconColor;
  final Widget? customIcon;
  final String title;
  final String body;

  const _GemsCard({
    this.icon,
    this.iconColor,
    this.customIcon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NotelColors.cardBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: NotelColors.surfaceHigh,
            ),
            child: customIcon != null
                ? Center(child: customIcon)
                : Icon(icon, color: iconColor, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: NotelColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: const TextStyle(
                    fontSize: 14,
                    color: NotelColors.textSecondary,
                    height: 20 / 14,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
