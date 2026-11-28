import 'dart:math' as math;

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

  /// Effective content width for [context]: the window width as the
  /// shell presents it to descendants (window width, capped).
  /// Widgets that size from raw screen width (e.g. the Tools
  /// drag-feedback tile) use this so they follow the same rule the
  /// shell enforces.
  static double effectiveWidthOf(BuildContext context) =>
      math.min(MediaQuery.sizeOf(context).width, maxContentWidth);

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
