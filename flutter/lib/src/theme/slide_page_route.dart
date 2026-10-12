import 'package:flutter/material.dart';
import 'package:tabs_lab/src/theme/animations.dart';

/// Round 22 — ONE app-wide push transition: slide in from the right.
///
/// Root cause of the founder-reported flash / ghosting: pushes were
/// split between two transition types. Tool tiles and the watch icon
/// already used this route's pure slide, but Quick Log → History,
/// Quick Log → Trends and Health Coach → chat used [MaterialPageRoute]
/// — and the app's [MaterialApp] had NO theme, so those routes fell
/// back to Material 3's platform-default page transition
/// (FadeForwards on Android): the incoming screen FADES in while the
/// outgoing screen FADES out, so mid-transition both screens render at
/// partial opacity and their content overlaps on screen (the founder's
/// recording shows the "Quick Log" and "Visual Trends" titles at the
/// same time). That overlap IS the ghosting; the mixed transition
/// types are why some pushes slid cleanly and others flashed.
///
/// The fix is central, in two layers:
/// 1. This route — now used by EVERY push call site. It is a pure
///    slide with an explicitly opaque route and no fade anywhere, so
///    the incoming screen physically covers the outgoing one while it
///    travels; two screens can never blend.
/// 2. [SlidePageTransitionsBuilder], wired into the app theme's
///    `pageTransitionsTheme` in main.dart, gives the identical slide
///    to any [MaterialPageRoute] (present or future), so the fade
///    default can never sneak back in.
///
/// Opacity guarantees: this route is `opaque: true` (PageRouteBuilder's
/// default, now explicit), every pushed screen's Scaffold paints
/// `NotelColors.background` (0xFF080E1A, fully opaque), and the app
/// theme sets `scaffoldBackgroundColor` to the same color as a backstop.
///
/// Reduced motion: when the OS asks for reduced motion, pushes are
/// instant (zero duration, no slide). Call sites pass [reducedMotion]
/// from the pushing context via `animationsDisabled(context)`; the
/// transitions builders ALSO live-check [MediaQuery] so a pop after
/// the setting changes stays instant. The watch-icon Hero into
/// Connections is untouched (an approved animation); its hosts
/// already omit the Hero widgets under reduced motion, and this
/// route's opaque slide keeps the flight ghost-free.
class SlidePageRoute<T> extends PageRouteBuilder<T> {
  SlidePageRoute({
    required Widget Function(BuildContext) builder,
    super.settings,
    bool reducedMotion = false,
  }) : super(
          opaque: true,
          transitionDuration: reducedMotion
              ? Duration.zero
              : const Duration(milliseconds: 300),
          reverseTransitionDuration: reducedMotion
              ? Duration.zero
              : const Duration(milliseconds: 300),
          pageBuilder: (context, _, _) => builder(context),
          transitionsBuilder:
              (context, animation, secondaryAnimation, child) {
            if (reducedMotion || animationsDisabled(context)) return child;
            return SlideTransition(
              position: slideFromRight(animation),
              child: child,
            );
          },
        );
}

/// The shared slide tween: from fully off-screen right to zero —
/// easeOut on the way in; a pop reverses the same animation (easeIn
/// back out to the right).
Animation<Offset> slideFromRight(Animation<double> animation) {
  return Tween<Offset>(
    begin: const Offset(1.0, 0.0),
    end: Offset.zero,
  ).animate(CurvedAnimation(
    parent: animation,
    curve: Curves.easeOut,
    reverseCurve: Curves.easeIn,
  ));
}

/// Round 22 — the theme-level twin of [SlidePageRoute]: gives every
/// [MaterialPageRoute] the same slide-in-from-right instead of
/// Material 3's fade, so transition behavior cannot diverge by route
/// type again. Honors reduced motion the same way (instant).
class SlidePageTransitionsBuilder extends PageTransitionsBuilder {
  const SlidePageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (animationsDisabled(context)) return child;
    return SlideTransition(
      position: slideFromRight(animation),
      child: child,
    );
  }
}

/// Round 22 — the app-wide transitions theme, wired into [MaterialApp]
/// in main.dart. Every platform maps to [SlidePageTransitionsBuilder]
/// so a [MaterialPageRoute] pushed anywhere (present or future) slides
/// in from the right instead of fading.
PageTransitionsTheme slidePageTransitionsTheme() {
  return const PageTransitionsTheme(
    builders: {
      TargetPlatform.android: SlidePageTransitionsBuilder(),
      TargetPlatform.iOS: SlidePageTransitionsBuilder(),
      TargetPlatform.fuchsia: SlidePageTransitionsBuilder(),
      TargetPlatform.linux: SlidePageTransitionsBuilder(),
      TargetPlatform.macOS: SlidePageTransitionsBuilder(),
      TargetPlatform.windows: SlidePageTransitionsBuilder(),
    },
  );
}
