import 'package:flutter/material.dart';

import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Lab (TikTok-UI exploration, v3) — the NEAR-BLACK palette for the
/// Lab-adapted surfaces only: the adapted Home screen and everything
/// on it, the floating pill dock, and the morphing quick-log tray.
///
/// Founder direction (Nov 3, 2026): "I like the black theme they
/// have on theirs. Can we do the black like his with some small
/// purple glass themes." The values are the reference's neutral
/// families, sampled from the reference frames (bg modes
/// #08080C–#0C0C10, card #18141C–#201C24, raised #282028–#302830):
/// true near-black with NO navy tint — [NotelColors.background]'s
/// #080E1A blue is deliberately killed on these surfaces.
///
/// This palette is SCOPED: it lives beside [NotelColors], never
/// inside it, so every non-adapted screen keeps the production
/// tokens untouched. Contrast (verified at sampling time): text
/// primary ≈17:1 on [background]; text secondary ≈6.2:1 on [card]
/// — both pass WCAG AA on the darkest surfaces.
///
/// Purple appears on these surfaces ONLY as glass (translucent
/// [NotelColors.primary] + blur + a hairline light edge) on exactly
/// four elements: the dock selection capsule, the hero top wash,
/// the tray surface / its 'Log' action, and the dock's center log
/// button. The pre-existing small solid accents (the plan rows'
/// Take circle, the header identity mark) are v2 usages and stay
/// exactly as they were.
abstract final class LabBlackColors {
  /// Page background — true near-black, neutral.
  static const background = Color(0xFF0A0A0B);

  /// Inset card — one shade up from black.
  static const card = Color(0xFF1A1A1E);

  /// Nested row inside a card — one shade DARKER than the card
  /// (the reference's nested-depth rule).
  static const nested = Color(0xFF121215);

  /// Raised surface base — the tray's base tone, small raised
  /// chips on Home (header watch button, snapshot tooltip/chips),
  /// and the hero arc's empty track.
  static const raised = Color(0xFF232329);

  /// Hairlines on the adapted surfaces: white at 8% alpha.
  static const hairline = Color(0x14FFFFFF);

  /// Text on the near-black surfaces.
  static const textPrimary = Color(0xFFF5F5F7);
  static const textSecondary = Color(0xFF9A9AA3);

  /// The glass edge: a 1px light line (white at 20% alpha) that
  /// sells the purple-glass surfaces as glass.
  static const glassEdge = Color(0x33FFFFFF);

  /// Dock selection capsule glass: Tabs purple at 30% alpha over a
  /// real BackdropFilter blur.
  static const glassCapsule = Color(0x4D7C6EFF);

  /// Center log button glass: the strongest glass of the set —
  /// Tabs purple at 45% alpha over a real BackdropFilter blur.
  static const glassCenterButton = Color(0x737C6EFF);

  /// 'Log' button glass (the tray's primary action): same strength
  /// as the center button.
  static const glassLogButton = Color(0x737C6EFF);

  /// The tray's glass surface: Tabs purple at 18% alpha blended
  /// over the [raised] base, itself at 92% alpha over a real
  /// BackdropFilter blur, so the Home content behind the tray
  /// frosts through the purple tint.
  static final trayGlass = Color.alphaBlend(
    NotelColors.primary.withValues(alpha: 0.18),
    raised,
  ).withValues(alpha: 0.92);
}
