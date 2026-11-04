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

/// Settings-gear round (Lab) — the settings TRAY: Tabs' real
/// Settings, opened from the Home header gear, behaving like the
/// settings trays in the reference video (SETTINGS_SPEC.md).
///
/// Behavior contract (measured in SETTINGS_SPEC §3/§4/§6):
/// - The tray GROWS OUT OF THE BOTTOM-BAR ZONE: its bottom edge is
///   anchored at the screen bottom (the bar zone is inside its
///   footprint) and its top edge rises from the bar's occupied
///   height (bottom float + 62dp bar) to its final height. It does
///   not slide up as a detached sheet, and the nav dock never
///   coexists with it — the tray is a modal route above the shell
///   and its ~90%-opaque blurred glass covers the dock zone for
///   the whole open state (the dock shows only as an illegible
///   ghost through the blur, exactly the reference's translucency).
/// - Motion: open ≈220ms, close ≈200ms — inside the video's
///   measured 135–285ms tray band, at the spec's ≈200–250ms
///   container language. Monotonic, NO overshoot in either
///   direction: the grow edge decelerates (easeOutCubic), the
///   collapse accelerates (easeInCubic — SETTINGS_SPEC §4.3's
///   rising-velocity collapse). Under reduced motion the tray
///   renders at its final height instantly (the codebase's
///   [animationsDisabled] pattern).
/// - Dismissal: tap outside the tray (the barrier region above
///   it — IN VIDEO, both Theme closes), the header ✕ (affordance
///   in video; its click is a named interpretation, SETTINGS_SPEC
///   §8.2), and system back — which first steps Settings sub-pages
///   back to the main menu via SettingsScreen's own PopScope, and
///   only then dismisses the tray (the tray route pops before
///   Home, because it is the topmost route). Selecting a settings
///   entry does NOT dismiss: entries navigate inside the tray,
///   exactly as the video's rows keep the tray open.
///
/// Geometry (named interpretations where the video cannot carry
/// Tabs' content):
/// - Height: content height up to a max of ≈0.78 × screen height.
///   Tabs' main menu (~12 entries + cards) exceeds that cap at
///   every phone size, so the tray sits AT the cap and its content
///   scrolls internally (the hosted SettingsScreen body is the
///   scrollable). The height is then constant across sub-pages —
///   the container persists, per the video's single-container
///   grammar; per-state height morphs (Theme↔Accent) are not
///   replicated because Tabs' sub-pages swap in-body by design.
/// - Width: full screen width, anchored to the bottom edge, top
///   corners radius ≈30 (SETTINGS_SPEC §3), bottom corners square.
///   (The video's tray is inset ≈0.057W per side on its phone; the
///   anchored full-width read is this package's named choice for
///   "grows out of the bar zone" on Tabs' full-width bar.)
/// - Material: the GLASS_STUDY tray recipe — milky tint over a
///   real BackdropFilter blur σ14, ~90% opaque, specular top line.
/// - Barrier: a light scrim (black @ 25%). SETTINGS_SPEC §3 could
///   not discern a scrim in the capture (auto-exposure confound);
///   the tap target is what the video proves, so the scrim is
///   kept faint and is named here as an interpretation.
const Duration kSettingsTrayOpenDuration = Duration(milliseconds: 220);
const Duration kSettingsTrayCloseDuration = Duration(milliseconds: 200);

/// Tray height cap as a fraction of screen height (see above).
const double kSettingsTrayMaxHeightFraction = 0.78;

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
  // its own duration: open 220ms / reverse 200ms, per the measured
  // band. Barrier behavior (tap-outside dismiss, modal) is the
  // route's own, identical to a dialog route's.
  return Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      barrierDismissible: true,
      barrierLabel: 'Settings',
      barrierColor: const Color(0x40000000), // black @ 25% — see above
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
/// from the dialog's primary animation: height interpolates from
/// the bottom-bar zone height to the capped final height, bottom
/// edge anchored, content relayouting inside the growing frame
/// (header rides the rising top edge, the settings list viewport
/// expands beneath it — the video's grow, not a rigid slide).
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
  // collapse = accelerating (easeIn, §4.3). Both monotonic.
  late final Animation<double> _grow = CurvedAnimation(
    parent: widget.animation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final reduced = animationsDisabled(context);
    final finalHeight = mq.size.height * kSettingsTrayMaxHeightFraction;
    // The bar zone the tray grows out of: the dock's bottom float
    // (same float rule the dock itself resolves) + the 62dp bar.
    final barZoneHeight =
        navDockBottomPadding(mq.viewPadding.bottom) + kNavDockHeight;
    return Align(
      alignment: Alignment.bottomCenter,
      child: AnimatedBuilder(
        animation: _grow,
        builder: (context, _) {
          final t = reduced ? 1.0 : _grow.value;
          final height = barZoneHeight + (finalHeight - barZoneHeight) * t;
          return SizedBox(
            key: const ValueKey('settings_tray'),
            width: mq.size.width,
            height: height,
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(LabBlackColors.settingsTrayRadius),
              ),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(
                  sigmaX: LabBlackColors.glassBlurSigma,
                  sigmaY: LabBlackColors.glassBlurSigma,
                ),
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: LabBlackColors.settingsTrayGradient,
                  ),
                  child: Stack(
                    children: [
                      // Material ancestor for the hosted screen's
                      // InkWells/switches (the tray route has no
                      // Scaffold of its own — hosting fix 1 in
                      // settings_screen.dart).
                      Material(
                        type: MaterialType.transparency,
                        child: SettingsScreen(
                          email: widget.email,
                          onLogout: widget.onLogout,
                          backend: widget.backend,
                          settingsStore: widget.settingsStore,
                          healthConnectService: widget.healthConnectService,
                          billingService: widget.billingService,
                          embeddedInTray: true,
                          onTrayClose: widget.onClose,
                        ),
                      ),
                      // Specular top line: 1dp white @ 45%, inset
                      // to clear the top corners (dock pattern).
                      const Positioned(
                        left: 30,
                        right: 30,
                        top: 0,
                        height: 1,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: LabBlackColors.glassSpecular,
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
    );
  }
}
