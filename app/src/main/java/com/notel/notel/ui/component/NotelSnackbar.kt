package com.notel.notel.ui.component

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CloudOff
import androidx.compose.material3.Icon
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarData
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.notel.notel.ui.theme.NotelError
import com.notel.notel.ui.theme.NotelPrimary
import com.notel.notel.ui.theme.NotelSurfaceHigh
import com.notel.notel.ui.theme.NotelTextPrimary

/**
 * Shared snackbar host (Mira spec 2026-09-29).
 *
 * Extracts the top-center host pattern already used in HistoryScreen and
 * SettingsScreen so every screen shares one style: NotelSurfaceHigh at 95%,
 * 16dp radius, 16dp horizontal screen margin, top-center placement (avoids the
 * thumb-zone CTA bar). One error snackbar at a time: callers use
 * [showErrorSnackbar], which dismisses the current snackbar so a new error
 * replaces it instead of queuing behind it.
 *
 * @param leadingIcon optional leading glyph; [NotelErrorSnackbarHost] passes
 * the calm CloudOff glyph for error snackbars per the spec.
 */
@Composable
fun NotelSnackbarHost(
    hostState: SnackbarHostState,
    modifier: Modifier = Modifier,
    leadingIcon: (@Composable () -> Unit)? = null
) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .padding(top = 80.dp)
            .padding(horizontal = 16.dp),
        contentAlignment = Alignment.TopCenter
    ) {
        SnackbarHost(hostState) { data ->
            if (leadingIcon != null) {
                ErrorSnackbar(data = data, leadingIcon = leadingIcon)
            } else {
                Snackbar(
                    snackbarData = data,
                    containerColor = NotelSurfaceHigh.copy(alpha = 0.95f),
                    contentColor = NotelTextPrimary,
                    actionColor = NotelPrimary,
                    shape = RoundedCornerShape(16.dp)
                )
            }
        }
    }
}

/** Error-snackbar variant with the calm CloudOff leading glyph (Mira spec §3). */
@Composable
fun NotelErrorSnackbarHost(
    hostState: SnackbarHostState,
    modifier: Modifier = Modifier
) {
    NotelSnackbarHost(
        hostState = hostState,
        modifier = modifier,
        leadingIcon = {
            Icon(
                imageVector = Icons.Outlined.CloudOff,
                contentDescription = null,
                tint = NotelError,
                modifier = Modifier.size(20.dp)
            )
        }
    )
}

@Composable
private fun ErrorSnackbar(
    data: SnackbarData,
    leadingIcon: @Composable () -> Unit
) {
    Snackbar(
        containerColor = NotelSurfaceHigh.copy(alpha = 0.95f),
        contentColor = NotelTextPrimary,
        shape = RoundedCornerShape(16.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            leadingIcon()
            Spacer(modifier = Modifier.width(12.dp))
            Text(
                text = data.visuals.message,
                fontSize = 14.sp,
                color = NotelTextPrimary,
                maxLines = 2,
                modifier = Modifier.weight(1f)
            )
            data.visuals.actionLabel?.let { actionLabel ->
                TextButton(onClick = { data.performAction() }) {
                    Text(
                        text = actionLabel,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = NotelPrimary
                    )
                }
            }
        }
    }
}

/**
 * Show an error snackbar, replacing any current one. Long duration when an
 * action is present (user needs time to read and tap), Short otherwise.
 *
 * Replacement is explicit: [SnackbarHostState.showSnackbar] suspends and
 * queues behind a showing snackbar, so we dismiss the current one first. The
 * in-flight showSnackbar then returns Dismissed and the new error appears
 * immediately instead of waiting behind the old one.
 */
suspend fun SnackbarHostState.showErrorSnackbar(
    message: String,
    actionLabel: String? = null
): androidx.compose.material3.SnackbarResult {
    currentSnackbarData?.dismiss()
    return showSnackbar(
        message = message,
        actionLabel = actionLabel,
        duration = if (actionLabel != null) SnackbarDuration.Long else SnackbarDuration.Short
    )
}
