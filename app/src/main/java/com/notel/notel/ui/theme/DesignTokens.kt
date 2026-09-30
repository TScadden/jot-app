package com.notel.notel.ui.theme

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Design tokens — the professional bar for Tabs Lab.
 *
 * One spacing grid, one radius scale, one type scale, one accent.
 * Every screen must build from these (or the Material defaults they map to)
 * instead of ad-hoc dp values, radii, and font sizes.
 *
 * Steals the principles, not the execution, of Bearable / Visible / Finch /
 * Apple Health: restraint over decoration, an 8pt grid, a 3-style type
 * hierarchy, 48dp touch targets, and native components.
 */

// ── 8pt spacing grid ──────────────────────────────────────────────────────────
// Allowed values: 4, 8, 12, 16, 20, 24, 32 (and 48 for large gaps). Never use
// off-grid values like 6, 10, 14, 18, 22 in new UI code.
object Spacing {
    val s4: Dp = 4.dp
    val s8: Dp = 8.dp
    val s12: Dp = 12.dp
    val s16: Dp = 16.dp
    val s20: Dp = 20.dp
    val s24: Dp = 24.dp
    val s32: Dp = 32.dp
    val s48: Dp = 48.dp
}

// ── Corner radii ──────────────────────────────────────────────────────────────
// Three shapes, no more: chips 12, cards 16, dialogs/sheets 20.
// Fully-round pills keep using CircleShape.
object Radii {
    val chip: Dp = 12.dp
    val card: Dp = 16.dp
    val dialog: Dp = 20.dp
}

// ── Type scale ────────────────────────────────────────────────────────────────
// One display style, one body, one caption — mapped to the Material typography
// styles set in Type.kt:
//
//   Display → MaterialTheme.typography.titleLarge (22sp, bold at call sites)
//   Body    → MaterialTheme.typography.bodyLarge  (16sp)
//   Caption → MaterialTheme.typography.labelMedium (12sp)
//
// Small label overlays (eyebrow headers) use [SectionLabel]. Avoid raw
// fontSize values in new UI code.

/**
 * Eyebrow section header in sentence case (never ALL CAPS), per the Mira
 * voice spec. Default tint is secondary; pass [NotelPrimary] for accented
 * headers on stat/hero cards.
 */
@Composable
fun SectionLabel(
    text: String,
    modifier: Modifier = Modifier,
    color: androidx.compose.ui.graphics.Color = NotelTextSecondary,
) {
    Text(
        text = text,
        style = MaterialTheme.typography.labelMedium,
        fontWeight = FontWeight.SemiBold,
        color = color,
        modifier = modifier,
    )
}

/**
 * Meaningful empty state — never a blank screen. Title in the display style,
 * one honest supporting line, optional icon and one primary action.
 */
@Composable
fun EmptyState(
    title: String,
    body: String,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    Column(
        modifier = modifier.padding(horizontal = Spacing.s24, vertical = Spacing.s32),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        icon?.let {
            androidx.compose.material3.Icon(
                imageVector = it,
                contentDescription = null,
                tint = NotelTextSecondary,
                modifier = Modifier.padding(bottom = Spacing.s16),
            )
        }
        Text(
            text = title,
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.Bold,
            color = NotelTextPrimary,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(Spacing.s8))
        Text(
            text = body,
            style = MaterialTheme.typography.bodyMedium,
            color = NotelTextSecondary,
            textAlign = TextAlign.Center,
        )
        if (actionLabel != null && onAction != null) {
            Spacer(Modifier.height(Spacing.s16))
            GlassyButton(onClick = onAction) {
                Text(actionLabel, color = NotelOnAccent, fontWeight = FontWeight.Bold)
            }
        }
    }
}
