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
import androidx.compose.foundation.clickable
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.notel.notel.ui.theme.NotelBorder
import com.notel.notel.ui.theme.NotelPrimary
import com.notel.notel.ui.theme.NotelSurface
import com.notel.notel.ui.theme.NotelTextPrimary
import com.notel.notel.ui.theme.NotelTextSecondary
import com.notel.notel.ui.theme.isLightTheme

/**
 * Tabs Lab energy check-in card: the day's first interaction, pinned to the top
 * of the Home ("Today") screen. Five square beveled 1-5 buttons. On tap the
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
                    text = "How is your energy today?",
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
                        BeveledNumberButton(
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
 * Classic raised bevel, no image assets: a diagonal face gradient (light at
 * top-left, dark at bottom-right) plus a 2dp light edge on the top/left and a
 * 2dp dark edge on the bottom/right, drawn inside the rounded square.
 */
@Composable
private fun BeveledNumberButton(
    level: Int,
    onClick: () -> Unit
) {
    val corner = 8.dp
    val highlight = Color.White.copy(alpha = if (isLightTheme) 0.90f else 0.22f)
    val shadow = Color.Black.copy(alpha = if (isLightTheme) 0.28f else 0.55f)
    val faceBrush = Brush.linearGradient(
        colors = listOf(
            highlight.copy(alpha = 0.35f),
            Color.Transparent,
            shadow.copy(alpha = 0.30f)
        ),
        start = Offset.Zero,
        end = Offset(Float.POSITIVE_INFINITY, Float.POSITIVE_INFINITY)
    )
    Box(
        modifier = Modifier
            .size(52.dp)
            .clip(RoundedCornerShape(corner))
            .background(NotelSurface)
            .background(faceBrush, RoundedCornerShape(corner))
            .drawBehind {
                val stroke = 2.dp.toPx()
                val r = corner.toPx()
                val w = size.width
                val h = size.height
                // Top + left: light edge
                drawLine(highlight, Offset(r, stroke / 2f), Offset(w - r, stroke / 2f), stroke)
                drawLine(highlight, Offset(stroke / 2f, r), Offset(stroke / 2f, h - r), stroke)
                // Bottom + right: dark edge
                drawLine(shadow, Offset(r, h - stroke / 2f), Offset(w - r, h - stroke / 2f), stroke)
                drawLine(shadow, Offset(w - stroke / 2f, r), Offset(w - stroke / 2f, h - r), stroke)
            }
            .semantics {
                contentDescription = "Energy $level of 5"
                role = Role.Button
            }
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = "$level",
            fontSize = 18.sp,
            fontWeight = FontWeight.SemiBold,
            color = NotelTextPrimary
        )
    }
}
