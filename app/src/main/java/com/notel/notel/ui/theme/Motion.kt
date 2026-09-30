package com.notel.notel.ui.theme

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.AnimationSpec
import androidx.compose.animation.core.spring
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback

/**
 * Instrument motion (2026-09-30).
 *
 * Springs settle in ~200ms — fast enough to feel instant, springy enough to
 * feel physical. One shared spec so the whole app moves like one machine.
 */
fun <T> InstrumentSpring(): AnimationSpec<T> = spring(
    dampingRatio = Spring.DampingRatioMediumBouncy,
    stiffness = 700f, // ~200ms settle
)

/** Gentler spring for larger surfaces (cards appearing, sheets). */
fun <T> InstrumentSurfaceSpring(): AnimationSpec<T> = spring(
    dampingRatio = Spring.DampingRatioNoBouncy,
    stiffness = 500f,
)

/**
 * Press-scale micro-interaction for tappable instrument controls: the
 * control dips to 96% while pressed and springs back on release.
 * Pass the control's own [MutableInteractionSource] (the one driving its
 * clickable) so the scale tracks the real press state. Pair with a haptic
 * on the commit (see [commitHaptic]).
 */
fun Modifier.instrumentPress(
    interactionSource: MutableInteractionSource,
): Modifier = composed {
    val isPressed by interactionSource.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (isPressed) 0.96f else 1f,
        animationSpec = InstrumentSpring(),
        label = "instrumentPress",
    )
    this.graphicsLayer { scaleX = scale; scaleY = scale }
}

/**
 * Haptic confirmation for commit moments (check-in tap, habit logged, entry
 * saved). One-liner, no permission needed. Returns a stable lambda; call it
 * right after the local write commits.
 */
@Composable
fun commitHaptic(): () -> Unit {
    val haptics = LocalHapticFeedback.current
    return remember(haptics) {
        { haptics.performHapticFeedback(HapticFeedbackType.LongPress) }
    }
}
