import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/midnight_grace.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Midnight Grace — the Home band's grace element (founder spec +
/// approved mock grace_text_b2_capg_v1_20261121, Nov 21, 2026).
///
/// While a grace window is live, this REPLACES the band center
/// slot's event counters: the ticking timer ("1:30" → M:SS, bold
/// white, app font) over "Grace" in Tabs purple, flanked by a thin
/// hairline rule on each side. No ring, no circle. It fades in when
/// the window opens at midnight and fades out when the window ends
/// (completion, expiry, or backgrounding), staying mounted through
/// the fade-out so the band never snaps.
///
/// Band tenancy (founder brief): when the 1–5 check-in strip owns
/// the slot (the check-in is the closing day's missing piece), Home
/// stacks this element ABOVE the strip in the same center-slot
/// Column — the check-in stays tappable during grace, since hiding
/// it would defeat the window's purpose. When the counters own the
/// slot, this element replaces them exactly as the mock shows.
///
/// Geometry from the approved mock (390dp frame, pixel-measured
/// against the harness captures): timer cap height ≈ 18dp
/// (fontSize 25 bold), "Grace" at 12dp regular (its glyph core
/// measures ≈ 0.43× the timer's cap height), hairlines 20dp ×
/// ~1dp with ~9dp gaps to the word, glyph-to-glyph vertical gap
/// ≈ 17dp.
class MidnightGraceBand extends StatefulWidget {
  final MidnightGraceController controller;

  /// Called when the fade-out has fully dismissed with no live
  /// window — Home then unmounts this element and the band's
  /// normal tenant returns (the spec's "the new day's band
  /// content returns after fade-out").
  final VoidCallback? onFadeOutComplete;

  const MidnightGraceBand({
    super.key,
    required this.controller,
    this.onFadeOutComplete,
  });

  @override
  State<MidnightGraceBand> createState() => _MidnightGraceBandState();
}

class _MidnightGraceBandState extends State<MidnightGraceBand>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade;
  bool _mounted = false;

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..addStatusListener(_onFadeStatus);
    _mounted = widget.controller.isActive;
    if (_mounted) _fade.value = 1;
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _fade.dispose();
    super.dispose();
  }

  void _onFadeStatus(AnimationStatus status) {
    // Fade-out finished with no live window: leave the tree so the
    // band's normal tenant (counters / strip) stands alone again,
    // and tell Home so it can unmount this element.
    if (status == AnimationStatus.dismissed &&
        !widget.controller.isActive &&
        mounted) {
      setState(() => _mounted = false);
      widget.onFadeOutComplete?.call();
    }
  }

  void _onControllerChanged() {
    if (!mounted) return;
    if (widget.controller.isActive) {
      if (!_mounted) setState(() => _mounted = true);
      _fade.forward();
    } else if (_mounted) {
      // Reduced motion: there is no fade to dismiss, so leave
      // immediately (the build's forced-full opacity would
      // otherwise strand the element on screen forever).
      if (MediaQuery.of(context).disableAnimations) {
        setState(() => _mounted = false);
        widget.onFadeOutComplete?.call();
        return;
      }
      _fade.reverse();
    }
    // Tick notifications (250ms) also land here: the rebuild below
    // re-reads the controller's timer text.
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!_mounted) return const SizedBox.shrink();
    final reduceMotion =
        MediaQuery.of(context).disableAnimations;
    return FadeTransition(
      opacity: reduceMotion ? const AlwaysStoppedAnimation(1) : _fade,
      child: Column(
        key: const ValueKey('midnight_grace_band'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.controller.timerText,
            style: TextStyle(
              color: NotelColors.textPrimary,
              fontSize: 25,
              fontWeight: FontWeight.w700,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 20,
                height: 1.2,
                color: NotelColors.primary,
              ),
              const SizedBox(width: 9),
              const Text(
                'Grace',
                style: TextStyle(
                  color: NotelColors.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  height: 1.0,
                ),
              ),
              const SizedBox(width: 9),
              Container(
                width: 20,
                height: 1.2,
                color: NotelColors.primary,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
