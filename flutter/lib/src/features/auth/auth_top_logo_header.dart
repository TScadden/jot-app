import 'package:flutter/material.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Port of the native `TopLogoHeader`: circular back button on the
/// left, centered Tabs logo + wordmark.
///
/// Extracted from `login_screen.dart` for VC 100134 so the email
/// verification screen shares the ONE auth header instead of
/// inventing a second one. Geometry is unchanged from the
/// LoginScreen original: 40dp row, 28dp logo, "Tabs" 26sp w900
/// primary with 1sp tracking.
class AuthTopLogoHeader extends StatelessWidget {
  final VoidCallback? onBack;

  const AuthTopLogoHeader({super.key, this.onBack});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: Stack(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(
                color: NotelColors.surfaceHigh,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                onPressed: onBack,
                padding: EdgeInsets.zero,
                icon: const Icon(
                  Icons.arrow_back,
                  color: NotelColors.textPrimary,
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.center,
            child: Row(
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
        ],
      ),
    );
  }
}
