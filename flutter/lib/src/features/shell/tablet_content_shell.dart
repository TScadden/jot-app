import 'package:flutter/material.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Tablet width adaptation (Phase 1 prototype, Nov 27, 2026):
/// caps the app's content column at [maxContentWidth] and centers it
/// in a full-bleed [NotelColors.background] gutter on wider windows.
///
/// The shell wraps the Navigator's child INSIDE the root presenter
/// chain (see main.dart), so the presenters' overlays stay full-screen
/// while every route — screens, dialogs, sheets, and the nav dock,
/// which lives inside MainShell — lays out within the capped column.
///
/// Below the cap the shell is a pass-through in layout terms: the
/// ConstrainedBox never binds and the Centered child fills the window
/// exactly as before, so phone widths are behavior-identical.
class TabletContentShell extends StatelessWidget {
  const TabletContentShell({super.key, required this.child});

  final Widget child;

  /// The content-column cap. 680dp keeps two-up phone-proportioned
  /// reading columns and form rows at tablet sizes while leaving a
  /// deliberate gutter; see the package RENDERS.md for the read.
  static const double maxContentWidth = 680;

  /// The effective-width breakpoint at which width-driven layouts
  /// (the Tools and Badges grid column counts) switch to their wide
  /// form. This is the Material window-size-class compact→medium
  /// boundary, applied to the EFFECTIVE (post-cap, LayoutBuilder)
  /// width — never raw device/MediaQuery width — so a phone-width
  /// split pane keeps phone counts. Single-sourced here (Vera
  /// P2-5): Tools and Badges both read this constant; the threshold
  /// must never be re-inlined at a call site.
  static const double wideBreakpoint = 600;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: NotelColors.background,
      child: Center(
        child: ConstrainedBox(
          key: const ValueKey('tabletContentShell'),
          constraints: const BoxConstraints(maxWidth: maxContentWidth),
          child: child,
        ),
      ),
    );
  }
}
