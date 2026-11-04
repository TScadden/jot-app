import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/billing_service.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/lab_black_colors.dart';

/// Settings tray — SETTINGS-FIDELITY round (Lab). Phase 1's
/// divergence audit (SETTINGS_DIVERGENCE_AUDIT.md) measured the
/// delivered V6 tray against the reference video frame by frame;
/// this round rebuilds the shell to the measured values. The
/// founder's verdict on V6: "It doesn't really look like the
/// video. I want it to be exact" + "his is more black than the
/// gray we have right now."
///
/// Behavior contract (SETTINGS_SPEC §3/§4/§6, audit §2):
/// - The tray GROWS OUT OF THE BOTTOM-BAR ZONE and FLOATS inset
///   like the reference: width 0.89W (side insets ≈0.057W), bottom
///   edge at ≈0.957H (≈0.043H of screen below it), covering the
///   dock while open (the dock never coexists with the tray — the
///   tray is a modal route above the shell and its ~90%-opaque
///   blurred glass covers the dock zone; the dock shows only as
///   an illegible ghost through the blur).
/// - NO scrim (audit D5): the reference shows no discernible
///   dimming, so the barrier is fully transparent; tap-outside
///   dismissal still works through it.
/// - Motion (measured values govern over the motion-design
///   skill's generic modal table of 300–400ms — named conflict):
///   open 180ms (reference bracket 135–200ms), bottom-anchored
///   grow, edge DECELERATES (easeOutCubic; entrance = decelerate
///   per the skill), contents settle after the edge over the
///   remaining ≈50–80ms (secondary layer: content fade/slide lag
///   via an Interval on the same controller). Close 200ms
///   (bracket 170–250ms), collapse ACCELERATES (easeInCubic;
///   exit = accelerate). Glass is a brittle material in the
///   skill's table: 0% overshoot everywhere, no linear spatial
///   motion. Reduced motion renders the final state instantly.
/// - Dismissal: tap outside (IN VIDEO, both Theme closes), the
///   header ✕ (affordance in video; click a named interpretation,
///   SETTINGS_SPEC §8.2), system back (sub-pages step back to the
///   menu first via SettingsScreen's PopScope, then the tray
///   route pops). Selecting an entry does NOT dismiss.
/// - Keyboard (audit D18): when the keyboard rises, the tray
///   rides above it as one stack (≈9dp gap, SETTINGS_SPEC §2.3) —
///   the tray's bottom offset follows MediaQuery.viewInsets and
///   its height clamps to the space above the keyboard.
///
/// Geometry — height, the FORCED way (audit §4): the reference
/// root tray is 0.29H ≈ 250pt because it holds a header, a
/// segmented control and 2 rows. Tabs' root holds a header, the
/// segmented control, the Personal Context editor (≈197dp
/// restyled) and 8 menu rows — an exact 0.29H is arithmetically
/// impossible (audit floor for header + 8 rows alone: 443pt ≈
/// 0.55H at 800dp). Chosen height 0.70H, from this arithmetic at
/// the 800dp capture surface (560dp total):
///   header 56 + divider 1                          =  57
///   list top padding                               =  12
///   segmented control (pill form)                  =  48
///   gap                                            =  12
///   Personal Context label row (outside its card)  =  48
///   gap                                            =   6
///   Personal Context card (restyled)               ≈ 197
///   gap                                            =  16
///   menu card: first 3 rows at 50dp pitch          = 150
///   + 14dp of the 4th row peeking (scroll cue)     =  14
///   TOTAL                                          = 560 = 0.70 × 800
/// The full root content (≈1,124dp at reference pitch) scrolls
/// internally inside this exact shell. Height is CONSTANT across
/// sub-pages — FORCED vs the reference's per-state height morph
/// (audit D16): Tabs sub-pages are full forms with no reference
/// height counterpart; the container still morphs its CONTENT
/// (crossfade + vertical slide, header chrome crossfade, in
/// settings_screen.dart), only the height endpoints are forced.
const Duration kSettingsTrayOpenDuration = Duration(milliseconds: 180);
const Duration kSettingsTrayCloseDuration = Duration(milliseconds: 200);

/// Tray height as a fraction of screen height (see arithmetic
/// above). Constant across all tray states (forced, D16).
const double kSettingsTrayHeightFraction = 0.70;

/// Tray width as a fraction of screen width (SETTINGS_SPEC §3:
/// 0.89W, side insets ≈0.057W).
const double kSettingsTrayWidthFraction = 0.89;

/// Bottom gap as a fraction of screen height: the tray's bottom
/// edge sits at ≈0.957H (SETTINGS_SPEC §3), so ≈0.043H of screen
/// remains below it.
const double kSettingsTrayBottomGapFraction = 0.043;

/// Opens the settings tray over the current screen. The returned
/// future completes when the tray is dismissed (any path), so the
/// caller can refresh whatever Settings may have changed.
Future<void> showSettingsTray(
  BuildContext context, {
  String? email,
  VoidCallback? onLogout,
  TabsBackend? backend,
  SettingsStore? settingsStore,
  HealthConnectService? healthConnectService,
  BillingService? billingService,
}) {
  // A PageRouteBuilder (not showGeneralDialog) so the CLOSE gets
  // its own duration: open 180ms / reverse 200ms, per the
  // measured brackets. Barrier behavior (tap-outside dismiss,
  // modal) is the route's own, identical to a dialog route's.
  return Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      barrierDismissible: true,
      barrierLabel: 'Settings',
      // Audit D5: NO scrim — the reference shows no discernible
      // dimming (delivered V6 had black @ 25%, measured ratio
      // 0.710). The barrier stays as the tap-outside target only.
      barrierColor: Colors.transparent,
      transitionDuration: kSettingsTrayOpenDuration,
      reverseTransitionDuration: kSettingsTrayCloseDuration,
      pageBuilder: (routeContext, animation, _) => SettingsTray(
        animation: animation,
        email: email,
        onLogout: onLogout,
        backend: backend,
        settingsStore: settingsStore,
        healthConnectService: healthConnectService,
        billingService: billingService,
        onClose: () => Navigator.of(routeContext).pop(),
      ),
      // The tray animates its own height from [animation] (so the
      // reverse run — dismissal — collapses through the same
      // geometry); the route transition itself adds nothing.
      transitionsBuilder: (_, _, _, child) => child,
    ),
  );
}

/// The tray surface + its hosted [SettingsScreen]. Sizes itself
/// from the route's primary animation: height interpolates from
/// the bottom-bar zone height to the fixed final height, bottom
/// edge anchored at the floating gap, content relayouting inside
/// the growing frame with a settle lag behind the edge.
class SettingsTray extends StatefulWidget {
  final Animation<double> animation;
  final String? email;
  final VoidCallback? onLogout;
  final TabsBackend? backend;
  final SettingsStore? settingsStore;
  final HealthConnectService? healthConnectService;
  final BillingService? billingService;
  final VoidCallback onClose;

  const SettingsTray({
    super.key,
    required this.animation,
    required this.onClose,
    this.email,
    this.onLogout,
    this.backend,
    this.settingsStore,
    this.healthConnectService,
    this.billingService,
  });

  @override
  State<SettingsTray> createState() => _SettingsTrayState();
}

class _SettingsTrayState extends State<SettingsTray> {
  // Grow = decelerating top edge (easeOut, SETTINGS_SPEC §4.2);
  // collapse = accelerating (easeIn, §4.3). Both monotonic, 0%
  // overshoot (glass = brittle material, motion-design skill).
  late final Animation<double> _grow = CurvedAnimation(
    parent: widget.animation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  // Secondary motion layer (SETTINGS_SPEC §4.1): the contents
  // settle AFTER the edge lands — the last ≈40% of the grow
  // drives a short fade + 12dp upward settle of the hosted
  // content. On close the same interval runs in reverse, so the
  // content leads the collapse slightly, as a settling layer
  // should.
  late final Animation<double> _settle = CurvedAnimation(
    parent: widget.animation,
    curve: const Interval(0.6, 1.0, curve: Curves.easeOutCubic),
    reverseCurve: const Interval(0.0, 0.4, curve: Curves.easeInCubic),
  );

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final reduced = animationsDisabled(context);
    final size = mq.size;
    // Keyboard ride (D18): above the keyboard the bottom offset
    // is the keyboard height + the Status tray's ≈9dp gap; with
    // no keyboard it is the floating ≈0.043H gap.
    final keyboard = mq.viewInsets.bottom;
    final bottomGap = keyboard > 0
        ? keyboard + 9.0
        : size.height * kSettingsTrayBottomGapFraction;
    final maxHeight =
        math.max(0.0, size.height - bottomGap - mq.viewPadding.top);
    final finalHeight =
        math.min(size.height * kSettingsTrayHeightFraction, maxHeight);
    // The bar zone the tray grows out of: the dock's bottom float
    // (same float rule the dock itself resolves) + the 62dp bar.
    final barZoneHeight =
        navDockBottomPadding(mq.viewPadding.bottom) + kNavDockHeight;
    final startHeight = math.min(barZoneHeight, finalHeight);
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomGap),
        child: AnimatedBuilder(
          animation: _grow,
          builder: (context, _) {
            final t = reduced ? 1.0 : _grow.value;
            final height = startHeight + (finalHeight - startHeight) * t;
            final settleT = reduced ? 1.0 : _settle.value;
            return SizedBox(
              key: const ValueKey('settings_tray'),
              width: size.width * kSettingsTrayWidthFraction,
              height: height,
              child: ClipRRect(
                borderRadius: const BorderRadius.only(
                  topLeft:
                      Radius.circular(LabBlackColors.settingsTrayRadius),
                  topRight:
                      Radius.circular(LabBlackColors.settingsTrayRadius),
                  bottomLeft: Radius.circular(
                      LabBlackColors.settingsTrayBottomRadius),
                  bottomRight: Radius.circular(
                      LabBlackColors.settingsTrayBottomRadius),
                ),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(
                    sigmaX: LabBlackColors.glassBlurSigma,
                    sigmaY: LabBlackColors.glassBlurSigma,
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LabBlackColors.settingsTrayGradient,
                      // Continuous dimmer rim on sides/bottom
                      // (audit D8; GLASS_STUDY: white ~20%).
                      border: Border.all(
                        color: LabBlackColors.glassEdge,
                        width: 1,
                      ),
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(
                            LabBlackColors.settingsTrayRadius),
                        topRight: Radius.circular(
                            LabBlackColors.settingsTrayRadius),
                        bottomLeft: Radius.circular(
                            LabBlackColors.settingsTrayBottomRadius),
                        bottomRight: Radius.circular(
                            LabBlackColors.settingsTrayBottomRadius),
                      ),
                    ),
                    child: Stack(
                      children: [
                        // Juno Condition 1 (V6 fix round, carried
                        // over unchanged): a tray-local
                        // ScaffoldMessenger + a transparent
                        // Scaffold host the hosted screen, so an
                        // error snackbar fired while the tray is
                        // open renders INSIDE the tray, above its
                        // glass. resizeToAvoidBottomInset stays
                        // false — the TRAY rides the keyboard
                        // (D18), the hosted body does not resize.
                        ScaffoldMessenger(
                          child: Scaffold(
                            backgroundColor: Colors.transparent,
                            resizeToAvoidBottomInset: false,
                            body: Material(
                              type: MaterialType.transparency,
                              child: Opacity(
                                opacity: settleT,
                                child: Transform.translate(
                                  offset: Offset(0, (1 - settleT) * 12),
                                  child: SettingsScreen(
                                    email: widget.email,
                                    onLogout: widget.onLogout,
                                    backend: widget.backend,
                                    settingsStore: widget.settingsStore,
                                    healthConnectService:
                                        widget.healthConnectService,
                                    billingService: widget.billingService,
                                    embeddedInTray: true,
                                    onTrayClose: widget.onClose,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        // Specular top line (audit D7): a 1dp core
                        // (white @ 65%, tray token) with a ≤4dp
                        // falloff skirt under it; the skirt band
                        // carries the tray's top-corner radius so
                        // the light follows the edge around the
                        // corners, and the core is inset by the
                        // radius so it never crosses the curve.
                        const Positioned(
                          left: 0,
                          right: 0,
                          top: 0,
                          height: 4,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.vertical(
                                top: Radius.circular(
                                    LabBlackColors.settingsTrayRadius),
                              ),
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  LabBlackColors.settingsTraySpecularSkirt,
                                  Color(0x00FFFFFF),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const Positioned(
                          left: LabBlackColors.settingsTrayRadius,
                          right: LabBlackColors.settingsTrayRadius,
                          top: 0,
                          height: 1,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: LabBlackColors.settingsTraySpecular,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
