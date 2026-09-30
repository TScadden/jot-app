package com.notel.notel.ui.screen

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.FastOutLinearInEasing
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.notel.notel.ui.theme.NotelBorder
import com.notel.notel.ui.theme.NotelOnAccent
import com.notel.notel.ui.theme.NotelPrimary
import com.notel.notel.ui.theme.NotelSurfaceHigh
import com.notel.notel.ui.theme.NotelTextSecondary
import com.notel.notel.ui.theme.Radii

/**
 * Tabs Lab energy check-in card: the day's first interaction, pinned to the top
 * of the Home ("Today") screen. Five flat 1-5 selector buttons. On tap the
 * card slides off to the left with a slight accelerate (filed-away feel).
 *
 * Visibility is owned by EnergyCheckInViewModel: the card shows only while no
 * energy log entry exists for the current energy day (4am local boundary).
 */
@Composable
fun EnergyCheckInCard(
    visible: Boolean,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier
) {
    AnimatedVisibility(
        visible = visible,
        modifier = modifier,
        enter = slideInHorizontally(
            initialOffsetX = { fullWidth -> -fullWidth },
            animationSpec = tween(400, easing = LinearOutSlowInEasing)
        ) + fadeIn(animationSpec = tween(400)),
        exit = slideOutHorizontally(
            targetOffsetX = { fullWidth -> -fullWidth },
            animationSpec = tween(350, easing = FastOutLinearInEasing)
        ) + fadeOut(animationSpec = tween(350))
    ) {
        Surface(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            shape = RoundedCornerShape(16.dp),
            color = NotelPrimary.copy(alpha = 0.07f),
            border = BorderStroke(1.dp, NotelPrimary.copy(alpha = 0.22f))
        ) {
            Column(
                modifier = Modifier.padding(vertical = 14.dp, horizontal = 16.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Text(
                    text = "How are you feeling?",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                    color = NotelTextSecondary
                )
                Spacer(Modifier.height(10.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceEvenly,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    (1..5).forEach { level ->
                        EnergyNumberButton(
                            level = level,
                            onClick = { onSelect(level) }
                        )
                    }
                }
            }
        }
    }
}

/**
 * Flat 1-5 selector button: no bevel, no gradients, no drawn highlight/shadow
 * edges. A quiet [NotelSurfaceHigh] square with a 1dp [NotelBorder] hairline
 * and a muted number; while pressed it fills [NotelPrimary] with a white
 * number — the same selected-fill language the app uses elsewhere.
 *
 * The tap is dispatched through [onClick]; all logging, gating, and the
 * slide-left exit animation live outside this button and are unchanged.
 */
@Composable
private fun EnergyNumberButton(
    level: Int,
    onClick: () -> Unit
) {
    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()
    val shape = RoundedCornerShape(Radii.chip)
    Box(
        modifier = Modifier
            .size(48.dp)
            .clip(shape)
            .background(if (isPressed) NotelPrimary else NotelSurfaceHigh)
            .border(
                width = 1.dp,
                color = if (isPressed) NotelPrimary else NotelBorder,
                shape = shape
            )
            .semantics {
                contentDescription = "Energy $level of 5"
                role = Role.Button
            }
            .clickable(
                interactionSource = interactionSource,
                indication = null,
                onClick = onClick
            ),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = "$level",
            fontSize = 16.sp,
            fontWeight = FontWeight.SemiBold,
            color = if (isPressed) NotelOnAccent else NotelTextSecondary
        )
    }
}
