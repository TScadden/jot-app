package com.notel.notel.ui.component

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CloudOff
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.notel.notel.ui.theme.NotelBorder
import com.notel.notel.ui.theme.NotelErrorTintOn
import com.notel.notel.ui.theme.NotelErrorTintStrong
import com.notel.notel.ui.theme.NotelOnAccent
import com.notel.notel.ui.theme.NotelPrimary
import com.notel.notel.ui.theme.NotelSurface
import com.notel.notel.ui.theme.NotelTextPrimary
import com.notel.notel.ui.theme.NotelTextSecondary

/**
 * Friendly error card (Mira spec 2026-09-29).
 *
 * Used when a whole content region fails: a screen-level load failure
 * (history list, coach list, PDF viewer page, chart area, tips list), or any
 * failure where the user has lost the context they were looking at. The card
 * replaces the failed content in the same layout box (same heights and
 * paddings as the skeleton that preceded it, so nothing jumps).
 *
 * Calm by choice: cloud glyph (never a warning triangle, exclamation mark, or
 * red octagon). All colors resolve through LocalNotelPalette, so Light / Dark /
 * System follow automatically. No entrance animation (reduced-motion rule).
 */
@Composable
fun ErrorStateCard(
    headline: String,
    explanation: String,
    actionLabel: String?,
    onAction: (() -> Unit)?,
    icon: ImageVector = Icons.Outlined.CloudOff,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(NotelSurface, RoundedCornerShape(16.dp))
            .border(1.dp, NotelBorder, RoundedCornerShape(16.dp))
            .padding(horizontal = 24.dp, vertical = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Box(
            modifier = Modifier
                .size(56.dp)
                .background(NotelErrorTintStrong, CircleShape),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = NotelErrorTintOn,
                modifier = Modifier.size(28.dp)
            )
        }

        Spacer(modifier = Modifier.height(16.dp))

        Text(
            text = headline,
            fontSize = 18.sp,
            fontWeight = FontWeight.SemiBold,
            color = NotelTextPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier.semantics { heading() }
        )

        Spacer(modifier = Modifier.height(8.dp))

        Text(
            text = explanation,
            fontSize = 14.sp,
            lineHeight = 21.sp,
            color = NotelTextSecondary,
            textAlign = TextAlign.Center
        )

        if (actionLabel != null && onAction != null) {
            Spacer(modifier = Modifier.height(24.dp))
            Button(
                onClick = onAction,
                modifier = Modifier.height(48.dp),
                shape = RoundedCornerShape(14.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = NotelPrimary,
                    contentColor = NotelOnAccent
                ),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 28.dp)
            ) {
                Text(
                    text = actionLabel,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold
                )
            }
        }
    }
}

/** Convenience: Template 2 (load failure) copy straight from Mira's spec. */
@Composable
fun LoadErrorCard(
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
    headline: String = "Could not load your data",
    explanation: String = "We could not pull your latest entries. Anything already saved is still here. Check your connection and try again."
) {
    ErrorStateCard(
        headline = headline,
        explanation = explanation,
        actionLabel = "Try again",
        onAction = onRetry,
        icon = Icons.Outlined.Refresh,
        modifier = modifier
    )
}
