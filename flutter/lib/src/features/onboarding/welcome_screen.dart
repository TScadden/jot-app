import 'package:flutter/material.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 3 — welcome / onboarding screen.
///
/// Pixel-port of the native app's `WelcomeOnboardingScreen.kt`
/// (`welcome_onboarding` route, dark theme). Values taken straight from
/// the Kotlin source:
/// - Scaffold background: NotelBackground #080E1A
/// - Content: horizontal 20dp / vertical 16dp padding, SpaceBetween column
/// - TopLogoHeader (no back button here): 28dp logo + "Tabs" 26sp Black,
///   NotelPrimary, 1sp letter spacing; 8dp top padding
/// - Avatar rows: 58dp circles, radial gradient (tint @ 40% -> NotelSurface),
///   2dp border (tint @ 35%), 3dp padding, avatar image cropped to circle;
///   rows spaced 16dp; 10dp gap between avatar and chip
/// - Callout chips: 20dp radius, NotelSurface, 4dp elevation,
///   1dp NotelPrimary @ 15% border; icon circle 34dp with linear gradient
///   (iconBg -> iconBg @ 70%), 18dp white icon; 10dp gap; 15sp Bold
///   NotelTextPrimary label, max 2 lines
/// - Slogan: "Notes that build" 22sp Light Italic Serif + "with you"
///   28sp Bold Italic Serif, both NotelPrimary, centered; 16dp below
/// - Buttons: full width, 52dp, 24dp radius, 17sp Bold;
///   Register = NotelPrimary fill, white label;
///   Log In = NotelSurfaceHigh fill, NotelPrimary label; 10dp apart
///
/// UI + navigation only this round: Register/Log In invoke the callbacks
/// (wired to the login screen in register/login mode). The avatar rows are
/// decorative in the native app — no selection state, kept as-is.
class WelcomeScreen extends StatelessWidget {
  final VoidCallback onRegister;
  final VoidCallback onLogin;

  const WelcomeScreen({
    super.key,
    required this.onRegister,
    required this.onLogin,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 20.0, vertical: 16.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Column(
                      children: [
                        // TOP LOGO HEADER (no back / skip on welcome)
                        const Padding(
                          padding: EdgeInsets.only(top: 8.0),
                          child: _WelcomeHeader(),
                        ),
                        const SizedBox(height: 12),
                        // AVATAR + CALLOUT ROWS
                        Column(
                          children: [
                            _AvatarRow(
                              avatarAsset:
                                  'assets/images/onboarding_avatar_man.png',
                              ringTint: NotelColors.primary,
                              chip: const _CalloutChip(
                                icon: Icons.biotech,
                                iconBg: NotelColors.info,
                                text: 'Track symptoms and treatments',
                              ),
                              avatarFirst: true,
                            ),
                            const SizedBox(height: 16),
                            _AvatarRow(
                              avatarAsset:
                                  'assets/images/onboarding_avatar_woman1.png',
                              ringTint: NotelColors.primary,
                              chip: const _CalloutChip(
                                icon: Icons.emoji_events,
                                iconBg: NotelColors.chipPurple,
                                text: 'Reach your goals',
                              ),
                              avatarFirst: false,
                            ),
                            const SizedBox(height: 16),
                            _AvatarRow(
                              avatarAsset:
                                  'assets/images/onboarding_avatar_woman2.png',
                              ringTint: NotelColors.chipPink,
                              chip: const _CalloutChip(
                                icon: Icons.fingerprint,
                                iconBg: NotelColors.chipPurple,
                                text: 'Learn patterns and get insights',
                              ),
                              avatarFirst: true,
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    // SLOGAN + BUTTONS
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(bottom: 16.0),
                          child: Column(
                            children: [
                              Text(
                                'Notes that build',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w300,
                                  fontStyle: FontStyle.italic,
                                  fontFamily: 'serif',
                                  color: NotelColors.primary,
                                ),
                              ),
                              Text(
                                'with you',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w700,
                                  fontStyle: FontStyle.italic,
                                  fontFamily: 'serif',
                                  color: NotelColors.primary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(
                          height: 52,
                          child: FilledButton(
                            onPressed: onRegister,
                            style: FilledButton.styleFrom(
                              backgroundColor: NotelColors.primary,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(24),
                              ),
                              textStyle: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            child: const Text('Register'),
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 52,
                          child: FilledButton(
                            onPressed: onLogin,
                            style: FilledButton.styleFrom(
                              backgroundColor: NotelColors.surfaceHigh,
                              foregroundColor: NotelColors.primary,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(24),
                              ),
                              textStyle: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            child: const Text('Log In'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Centered Tabs logo + wordmark (native `TopLogoHeader` with no back/skip).
class _WelcomeHeader extends StatelessWidget {
  const _WelcomeHeader();

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

/// One avatar + callout-chip row. Native alternates sides: avatar left for
/// rows 1 and 3, avatar right for row 2.
class _AvatarRow extends StatelessWidget {
  final String avatarAsset;
  final Color ringTint;
  final _CalloutChip chip;
  final bool avatarFirst;

  const _AvatarRow({
    required this.avatarAsset,
    required this.ringTint,
    required this.chip,
    required this.avatarFirst,
  });

  @override
  Widget build(BuildContext context) {
    final avatar = Container(
      width: 58,
      height: 58,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            ringTint.withValues(alpha: 0.4),
            NotelColors.surface,
          ],
        ),
        border: Border.all(
          color: ringTint.withValues(alpha: 0.35),
          width: 2,
        ),
      ),
      child: ClipOval(
        child: Image.asset(
          avatarAsset,
          fit: BoxFit.cover,
        ),
      ),
    );
    // Native: chip has weight(1f, fill=false) — takes remaining space as its
    // max constraint but sizes to content, pinned to the row edge.
    final chipSlot = Expanded(
      child: Align(
        alignment:
            avatarFirst ? Alignment.centerLeft : Alignment.centerRight,
        child: chip,
      ),
    );
    return Row(
      children: avatarFirst
          ? [avatar, const SizedBox(width: 10), chipSlot]
          : [chipSlot, const SizedBox(width: 10), avatar],
    );
  }
}

/// Native `CalloutChip`: icon circle + bold label on a NotelSurface pill.
class _CalloutChip extends StatelessWidget {
  final IconData icon;
  final Color iconBg;
  final String text;

  const _CalloutChip({
    required this.icon,
    required this.iconBg,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: NotelColors.surface,
      elevation: 4,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: NotelColors.cardBorder, width: 1),
        ),
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 14.0, vertical: 10.0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [
                      iconBg,
                      iconBg.withValues(alpha: 0.7),
                    ],
                  ),
                ),
                child: Icon(icon, color: Colors.white, size: 18),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  text,
                  maxLines: 2,
                  softWrap: true,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: NotelColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
