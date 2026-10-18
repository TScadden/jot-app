import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:tabs_lab/src/features/onboarding/onboarding_header.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 32 — port of native `ConsentScreen.kt` (route `consent`),
/// the first step of the post-registration onboarding chain
/// (`MainActivity.kt` login/consent routes).
///
/// Copy is native verbatim. The Terms / Privacy links are tappable
/// and open the same URLs native opens
/// (`https://api.jottracker.com/terms.html`,
/// `https://api.jottracker.com/privacy.html`) — Juno MF: legal links
/// must be tappable, never plain text.
///
/// Behavior (native `MainActivity.kt` consent route):
/// - "I consent" → the flow records `has_consented` and advances to
///   the consultation intro.
/// - "Decline" → native's "Data Consent Required" dialog: "I Consent"
///   proceeds exactly like consenting; "Log Out" declines, which
///   native answers by clearing the logged-in state and returning to
///   the welcome screen ([onDecline] — AppFlow clears the session,
///   the functional equivalent of native's `setLoggedIn(false)`).
class OnboardingConsentScreen extends StatelessWidget {
  final VoidCallback onBack;
  final VoidCallback onConsent;
  final VoidCallback onDecline;

  const OnboardingConsentScreen({
    super.key,
    required this.onBack,
    required this.onConsent,
    required this.onDecline,
  });

  Future<void> _openUrl(String url) async {
    try {
      await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      // A failed browser hand-off must never wedge onboarding; the
      // consent copy itself is fully readable on this screen.
    }
  }

  Future<void> _showDeclineDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: NotelColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: const Text(
          'Data Consent Required',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
        content: const Text(
          'Tabs relies on health notes and biometric data to generate '
          'personalized AI insights and recaps. Declining limits app '
          'capabilities. Would you like to go back to login or continue '
          'with limited functionality?',
          style: TextStyle(color: NotelColors.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              onDecline();
            },
            child: const Text(
              'Log Out',
              style: TextStyle(color: NotelColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              // Native: the dialog's confirm proceeds WITH consent
              // (ConsentScreen.kt decline dialog → onConsent()).
              onConsent();
            },
            child: const Text(
              'I Consent',
              style: TextStyle(
                color: NotelColors.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

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
              const SizedBox(height: 16),
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: NotelColors.surface,
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: NotelColors.cardBorder),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x33000000),
                        blurRadius: 12,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const SingleChildScrollView(
                    padding: EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Privacy & Data Consent',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: NotelColors.textPrimary,
                          ),
                        ),
                        SizedBox(height: 16),
                        Text(
                          'Tabs helps you build smart health logs and notes '
                          'that grow with you. To calculate health trends '
                          'and power your personalized AI recaps, we need '
                          'your consent to securely process your health '
                          'metrics.',
                          style: TextStyle(
                            fontSize: 14,
                            color: NotelColors.textSecondary,
                            height: 20 / 14,
                          ),
                        ),
                        SizedBox(height: 14),
                        Text(
                          'By consenting, you allow Tabs to sync and process '
                          'your symptoms, biometric metrics (such as heart '
                          'rate, sleep, and HRV), and logged notes to '
                          'deliver your personalized dashboards and weekly '
                          'health summaries.',
                          style: TextStyle(
                            fontSize: 14,
                            color: NotelColors.textSecondary,
                            height: 20 / 14,
                          ),
                        ),
                        SizedBox(height: 14),
                        Text(
                          'Your privacy is paramount. Anonymized and '
                          'aggregated metrics help us improve trend models '
                          'and build better features. Your personal data is '
                          'never sold to third parties.',
                          style: TextStyle(
                            fontSize: 14,
                            color: NotelColors.textSecondary,
                            height: 20 / 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    'Read our ',
                    style: TextStyle(
                      fontSize: 12,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                  GestureDetector(
                    onTap: () =>
                        _openUrl('https://api.jottracker.com/terms.html'),
                    child: const Text(
                      'Terms of Use',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: NotelColors.primary,
                      ),
                    ),
                  ),
                  const Text(
                    ' and ',
                    style: TextStyle(
                      fontSize: 12,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                  GestureDetector(
                    onTap: () =>
                        _openUrl('https://api.jottracker.com/privacy.html'),
                    child: const Text(
                      'Privacy Policy',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: NotelColors.primary,
                      ),
                    ),
                  ),
                  const Text(
                    ' for full details.',
                    style: TextStyle(
                      fontSize: 12,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 16, bottom: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 52,
                        child: FilledButton(
                          onPressed: () => _showDeclineDialog(context),
                          style: FilledButton.styleFrom(
                            backgroundColor: NotelColors.surfaceHigh,
                            foregroundColor: NotelColors.textPrimary,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(24),
                            ),
                            textStyle: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          child: const Text('Decline'),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: SizedBox(
                        height: 52,
                        child: FilledButton(
                          onPressed: onConsent,
                          style: FilledButton.styleFrom(
                            backgroundColor: NotelColors.primary,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(24),
                            ),
                            textStyle: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          child: const Text('I consent'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
