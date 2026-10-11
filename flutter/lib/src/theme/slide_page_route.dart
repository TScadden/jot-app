import 'package:flutter/material.dart';

/// Round 12b — explicit slide-in-from-right page route.
///
/// The app runs Material 3, whose default Android page transition is a
/// zoom/fade (reads as "just spawning in"). The founder asked for the
/// classic push: the new screen slides in from the right, and the back
/// action slides it back out to the right. Used for the watch icon ->
/// data-connections navigation (and anywhere else a push is wanted).
class SlidePageRoute<T> extends PageRouteBuilder<T> {
  SlidePageRoute({
    required Widget Function(BuildContext) builder,
    super.settings,
  }) : super(
          pageBuilder: (context, _, _) => builder(context),
          transitionDuration: const Duration(milliseconds: 300),
          reverseTransitionDuration: const Duration(milliseconds: 300),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final slide = Tween<Offset>(
              begin: const Offset(1.0, 0.0),
              end: Offset.zero,
            ).animate(CurvedAnimation(
              parent: animation,
              curve: Curves.easeOut,
              reverseCurve: Curves.easeIn,
            ));
            return SlideTransition(position: slide, child: child);
          },
        );
}
