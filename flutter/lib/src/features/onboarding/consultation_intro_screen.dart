import 'package:flutter/material.dart';

import 'package:tabs_lab/src/features/onboarding/onboarding_header.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 32 — port of native `ConsultationIntroScreen.kt` (route
/// `consultation_intro`). Static intro step: glowing orb with the
/// five surrounding health-icon bubbles, "Let's get you set up!"
/// copy, and a Continue button. Continuing records
/// `intro_consultation_seen` (the flow owns the write) and advances
/// to profile setup — native `MainActivity.kt` consultation route.
class ConsultationIntroScreen extends StatelessWidget {
  final VoidCallback onBack;
  final VoidCallback onContinue;

  const ConsultationIntroScreen({
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
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Orb + bubbles (native: 300dp stage, 160dp orb).
                    SizedBox(
                      width: double.infinity,
                      height: 300,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            width: 160,
                            height: 160,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  NotelColors.primary.withValues(alpha: 0.8),
                                  const Color(0xFFA566FF)
                                      .withValues(alpha: 0.5),
                                  Colors.transparent,
                                ],
                              ),
                            ),
                          ),
                          const Positioned(
                            top: 30,
                            left: 40,
                            child: _IconBubble(
                              icon: Icons.medical_services,
                              color: NotelColors.info,
                            ),
                          ),
                          const Positioned(
                            top: 40,
                            right: 40,
                            child: _IconBubble(
                              icon: Icons.favorite,
                              color: Color(0xFFEC4899),
                            ),
                          ),
                          const Positioned(
                            left: 20,
                            child: _IconBubble(
                              icon: Icons.search,
                              color: Color(0xFFA855F7),
                            ),
                          ),
                          const Positioned(
                            right: 20,
                            child: _IconBubble(
                              icon: Icons.psychology,
                              color: Color(0xFF8B5CF6),
                            ),
                          ),
                          const Positioned(
                            bottom: 20,
                            left: 50,
                            child: _IconBubble(
                              icon: Icons.local_hospital,
                              color: Color(0xFF22C55E),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Column(
                        children: [
                          Text(
                            "Let's get you set up!",
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              color: NotelColors.textPrimary,
                            ),
                          ),
                          SizedBox(height: 16),
                          Text(
                            'Start by sharing your goals and why you are '
                            'using this app, so we can make sure the AI '
                            'knows how to best help you.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 15,
                              color: NotelColors.textSecondary,
                              height: 22 / 15,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
              OnboardingPrimaryButton(
                label: 'Continue',
                onPressed: onContinue,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Native `IconBubble`: 46dp circle, linear gradient (color → color
/// @ 70%), 1.5dp white @ 60% border, 22dp white icon.
class _IconBubble extends StatelessWidget {
  final IconData icon;
  final Color color;

  const _IconBubble({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [color, color.withValues(alpha: 0.7)],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.6),
          width: 1.5,
        ),
      ),
      child: Icon(icon, color: Colors.white, size: 22),
    );
  }
}
