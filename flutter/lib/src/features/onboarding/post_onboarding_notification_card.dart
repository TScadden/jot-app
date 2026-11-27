import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/onboarding_store.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Whether the one-time post-onboarding notification card should
/// show on this Home landing: only for a user who completed the
/// NEW flow (flow3 flag) and has not been shown it yet. Users who
/// completed onboarding under older flows never carry the flag.
Future<bool> shouldShowPostOnboardingNotificationCard(
  OnboardingStore store,
) async {
  try {
    if (!await store.getFlow3Completed()) return false;
    return !await store.getFlow3NotifPromptShown();
  } catch (_) {
    return false;
  }
}

/// Flow3 (Nov 19, 2026) — the notifications permission ask is no
/// longer an onboarding STEP. When a user who just completed the
/// new flow lands on Home for the first time, this card is shown
/// over Home (dialog-style, dimmed Home behind, Bandit peeking
/// over the card top — mock `flow3_08_home_notifications_v3`).
///
/// Copy rulings: the subtitle is exactly "Your evening check-in
/// reminder and habit nudges." — the phrase "Nothing else." is
/// banned (founder amendment, Nov 19, 5:44 PM).
///
/// "Allow" fires the real OS permission request through the
/// existing notification service (wired by the caller); "Don't
/// Allow" simply dismisses. The caller gates display on the
/// flow3-completion flag + a shown-once flag, so existing users
/// who completed onboarding under older flows never see it.
class PostOnboardingNotificationCard extends StatelessWidget {
  final VoidCallback onAllow;
  final VoidCallback onDontAllow;

  const PostOnboardingNotificationCard({
    super.key,
    required this.onAllow,
    required this.onDontAllow,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          key: const ValueKey('post_onboarding_notification_card'),
          width: double.infinity,
          decoration: BoxDecoration(
            color: NotelColors.surface,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: NotelColors.cardBorder),
          ),
          padding: const EdgeInsets.fromLTRB(24, 56, 24, 24),
          // GAP-13: at 3.0x text scale the fixed content is
          // ~122px taller than the dialog's max height and the
          // non-scrollable Column overflowed, clipping the
          // actions. The content now scrolls inside the card;
          // at normal scales nothing changes (no scrollable
          // extent is created).
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.notifications,
                  color: NotelColors.primary,
                  size: 40,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Allow Tabs to send you notifications?',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: NotelColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Your evening check-in reminder and habit nudges.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: NotelColors.textSecondary,
                    height: 20 / 14,
                  ),
                ),
                const SizedBox(height: 24),
                // GAP-13: 52dp is a minimum, not a fixed height —
                // the button grows with the text scale so the
                // 'Allow' label is never clipped.
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 52),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: onAllow,
                      style: FilledButton.styleFrom(
                        backgroundColor: NotelColors.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                      child: const Text(
                        'Allow',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: onDontAllow,
                  child: const Text(
                    "Don't Allow",
                    style: TextStyle(
                      color: NotelColors.textSecondary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Bandit peeking over the card top (mock flow3_08).
        Positioned(
          top: -52,
          left: 0,
          right: 0,
          child: Center(
            child: ClipRect(
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: 0.45,
                child: Image.asset(
                  'assets/images/bandit_cheer_cut_v3.png',
                  width: 120,
                  height: 120,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Shows [PostOnboardingNotificationCard] as a dialog over the
/// current (Home) surface. Returns 'allow' or 'dontAllow'.
Future<String?> showPostOnboardingNotificationCard(
  BuildContext context, {
  required VoidCallback onAllow,
  required VoidCallback onDontAllow,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      child: Padding(
        padding: const EdgeInsets.only(top: 52),
        child: PostOnboardingNotificationCard(
          onAllow: () {
            Navigator.of(dialogContext).pop('allow');
            onAllow();
          },
          onDontAllow: () {
            Navigator.of(dialogContext).pop('dontAllow');
            onDontAllow();
          },
        ),
      ),
    ),
  );
}
