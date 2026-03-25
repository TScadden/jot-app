package com.notel.notel.ui.screen

import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.*
import com.notel.notel.ui.theme.*

// ─── Data model for each tutorial step ────────────────────────────────────────

data class TutorialStep(
    val title: String,
    val description: String,
    val icon: ImageVector,
    val arrowDirection: ArrowDirection = ArrowDirection.DOWN
)

enum class ArrowDirection { UP, DOWN, LEFT, RIGHT }

// ─── Tutorial step definitions ─────────────────────────────────────────────────

val settingsTutorialSteps = listOf(
    TutorialStep(
        title = "Personal Context",
        description = "Tell the AI about yourself here — health conditions, goals, and lifestyle. The more detail you give, the smarter your insights get.",
        icon = Icons.Default.Person,
        arrowDirection = ArrowDirection.DOWN
    ),
    TutorialStep(
        title = "Wallet & Credits",
        description = "Your AI credit balance lives here. Each action costs \$0.01. Tap the wallet icon any time to top-up or check usage — tap 'Add \$5' to get started!",
        icon = Icons.Default.AccountBalanceWallet,
        arrowDirection = ArrowDirection.DOWN
    ),
    TutorialStep(
        title = "User Profile",
        description = "Set your age, height, weight & gender. The AI uses this to calibrate health advice and generate accurate reports.",
        icon = Icons.Default.AccountCircle,
        arrowDirection = ArrowDirection.UP
    ),
    TutorialStep(
        title = "Connected Apps",
        description = "Link Fitbit and Google Health Connect to automatically pull in heart rate, sleep, and activity data for deeper insights.",
        icon = Icons.Default.Favorite,
        arrowDirection = ArrowDirection.UP
    ),
    TutorialStep(
        title = "AI & Knowledge Base",
        description = "Upload PDFs, notes, or doctor reports. The AI extracts key facts and remembers them in every conversation. Manage auto-pings and browse past insights here too.",
        icon = Icons.Default.AutoAwesome,
        arrowDirection = ArrowDirection.UP
    ),
    TutorialStep(
        title = "Event Counters",
        description = "Track how many days until (or since) important events — next check-up, medication start date, race day, and more. The starred counter appears on the main screen.",
        icon = Icons.Default.Timer,
        arrowDirection = ArrowDirection.UP
    )
)

// ─── Main overlay composable ───────────────────────────────────────────────────

@Composable
fun SettingsTutorialOverlay(
    /** Coordinates of the element to highlight for the current step.
     *  Pass null if coordinates are not yet measured. */
    targetCoords: LayoutCoordinates?,
    currentStep: Int,
    totalSteps: Int,
    screenHeightDp: Int,
    onNext: () -> Unit,
    onSkip: () -> Unit
) {
    if (currentStep >= totalSteps) return

    val step = settingsTutorialSteps[currentStep]
    val density = LocalDensity.current

    // ── Pulsing glow animation ──
    val infiniteTransition = rememberInfiniteTransition(label = "glow")
    val glowAlpha by infiniteTransition.animateFloat(
        initialValue = 0.4f, targetValue = 1f, label = "glowAlpha",
        animationSpec = infiniteRepeatable(
            animation = tween(900, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Reverse
        )
    )
    val glowRadius by infiniteTransition.animateFloat(
        initialValue = 4f, targetValue = 14f, label = "glowRadius",
        animationSpec = infiniteRepeatable(
            animation = tween(900, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Reverse
        )
    )

    // ── Arrow bob animation ──
    val arrowOffset by infiniteTransition.animateFloat(
        initialValue = 0f, targetValue = 8f, label = "arrowBob",
        animationSpec = infiniteRepeatable(
            animation = tween(700, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Reverse
        )
    )

    // ── Dim whole screen ──
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.62f))
            .clickable(
                indication = null,
                interactionSource = remember { MutableInteractionSource() }
            ) { /* consume touches — tapping backdrop does nothing */ }
    ) {
        // ── Glowing highlight around target ──
        if (targetCoords != null) {
            val bounds = targetCoords.boundsInWindow()
            val paddingPx = with(density) { 6.dp.toPx() }

            Canvas(modifier = Modifier.fillMaxSize()) {
                val rect = androidx.compose.ui.geometry.Rect(
                    left = bounds.left - paddingPx,
                    top = bounds.top - paddingPx,
                    right = bounds.right + paddingPx,
                    bottom = bounds.bottom + paddingPx
                )
                val cornerRadius = with(density) { 16.dp.toPx() }

                drawIntoCanvas { canvas ->
                    val paint = Paint().asFrameworkPaint().apply {
                        isAntiAlias = true
                        color = android.graphics.Color.TRANSPARENT
                        setShadowLayer(
                            glowRadius * density.density,
                            0f, 0f,
                            android.graphics.Color.argb(
                                (glowAlpha * 255).toInt(),
                                0x7C, 0x4D, 0xFF  // NotelPrimary ~
                            )
                        )
                        style = android.graphics.Paint.Style.STROKE
                        strokeWidth = with(density) { 2.5.dp.toPx() }
                    }
                    canvas.nativeCanvas.drawRoundRect(
                        rect.left, rect.top, rect.right, rect.bottom,
                        cornerRadius, cornerRadius,
                        paint
                    )
                }

                // Solid stroke on top
                drawRoundRect(
                    color = NotelPrimary.copy(alpha = glowAlpha),
                    topLeft = Offset(rect.left, rect.top),
                    size = Size(rect.width, rect.height),
                    cornerRadius = CornerRadius(cornerRadius),
                    style = Stroke(width = with(density) { 2.dp.toPx() })
                )
            }

            // ── Arrow + tooltip card ──
            val boundsTopDp    = with(density) { bounds.top.toDp() }
            val boundsBottomDp = with(density) { bounds.bottom.toDp() }
            val screenH        = screenHeightDp.dp

            // Estimate tooltip card height (title row + dots + text + buttons + arrow + padding)
            val tooltipHeightEstimate = 250.dp
            val clearance = 16.dp  // gap between element and tooltip

            // Space below = from element bottom to screen bottom
            val spaceBelow = screenH - boundsBottomDp - clearance
            // Space above = from screen top to element top
            val spaceAbove = boundsTopDp - clearance

            // Prefer below if it fits; otherwise go above
            val tooltipBelow = spaceBelow >= tooltipHeightEstimate || spaceBelow >= spaceAbove

            // Y position of the tooltip top
            val tooltipY = if (tooltipBelow) {
                // Place just below the element; clamp so it doesn't run off-screen bottom
                val ideal = boundsBottomDp + clearance
                minOf(ideal, screenH - tooltipHeightEstimate - 8.dp)
            } else {
                // Place above the element; clamp so it doesn't run off-screen top
                val ideal = boundsTopDp - tooltipHeightEstimate - clearance
                maxOf(ideal, 8.dp)
            }

            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 20.dp)
                    .offset(y = tooltipY)
            ) {
                TutorialTooltipCard(
                    step = step,
                    currentStep = currentStep,
                    totalSteps = totalSteps,
                    arrowAtTop = !tooltipBelow,
                    arrowOffset = arrowOffset,
                    onNext = onNext,
                    onSkip = onSkip
                )
            }
        } else {
            // No coords yet — show centered
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                TutorialTooltipCard(
                    step = step,
                    currentStep = currentStep,
                    totalSteps = totalSteps,
                    arrowAtTop = false,
                    arrowOffset = arrowOffset,
                    onNext = onNext,
                    onSkip = onSkip,
                    modifier = Modifier.padding(32.dp)
                )
            }
        }
    }
}

// ─── Tooltip card ─────────────────────────────────────────────────────────────

@Composable
private fun TutorialTooltipCard(
    step: TutorialStep,
    currentStep: Int,
    totalSteps: Int,
    arrowAtTop: Boolean,
    arrowOffset: Float,
    onNext: () -> Unit,
    onSkip: () -> Unit,
    modifier: Modifier = Modifier
) {
    Column(modifier = modifier, horizontalAlignment = Alignment.CenterHorizontally) {

        // Bouncing arrow
        val arrowDp = with(LocalDensity.current) { arrowOffset.toDp() }
        if (arrowAtTop) {
            Box(modifier = Modifier.offset(y = -arrowDp)) {
                Icon(
                    Icons.Default.KeyboardArrowUp,
                    contentDescription = null,
                    tint = NotelPrimary,
                    modifier = Modifier.size(36.dp)
                )
            }
            Spacer(Modifier.height(2.dp))
        }

        // Card body
        Surface(
            shape = RoundedCornerShape(20.dp),
            color = NotelSurface,
            tonalElevation = 0.dp,
            modifier = Modifier
                .fillMaxWidth()
                .drawBehind {
                    // outer glow
                    drawIntoCanvas { canvas ->
                        val paint = Paint().asFrameworkPaint().apply {
                            isAntiAlias = true
                            color = android.graphics.Color.TRANSPARENT
                            setShadowLayer(
                                24f,
                                0f, 0f,
                                android.graphics.Color.argb(180, 0x7C, 0x4D, 0xFF)
                            )
                        }
                        canvas.nativeCanvas.drawRoundRect(
                            0f, 0f, size.width, size.height,
                            60f, 60f, paint
                        )
                    }
                }
        ) {
            Column(modifier = Modifier.padding(20.dp)) {
                // Step icon + title
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Box(
                        modifier = Modifier
                            .size(38.dp)
                            .clip(CircleShape)
                            .background(NotelPrimary.copy(alpha = 0.15f)),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            step.icon,
                            contentDescription = null,
                            tint = NotelPrimary,
                            modifier = Modifier.size(20.dp)
                        )
                    }
                    Spacer(Modifier.width(12.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            step.title,
                            color = NotelTextPrimary,
                            fontWeight = FontWeight.Bold,
                            fontSize = 16.sp
                        )
                        Text(
                            "Step ${currentStep + 1} of $totalSteps",
                            color = NotelPrimary,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.SemiBold
                        )
                    }
                }

                Spacer(Modifier.height(12.dp))

                // Step dots
                Row(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    repeat(totalSteps) { idx ->
                        Box(
                            modifier = Modifier
                                .height(4.dp)
                                .weight(1f)
                                .clip(RoundedCornerShape(2.dp))
                                .background(
                                    if (idx <= currentStep) NotelPrimary
                                    else NotelSurfaceHigh
                                )
                        )
                    }
                }

                Spacer(Modifier.height(14.dp))

                Text(
                    step.description,
                    color = NotelTextSecondary,
                    fontSize = 13.sp,
                    lineHeight = 19.sp
                )

                Spacer(Modifier.height(18.dp))

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    TextButton(onClick = onSkip) {
                        Text(
                            if (currentStep == totalSteps - 1) "Close" else "Skip",
                            color = NotelTextSecondary,
                            fontSize = 13.sp
                        )
                    }

                    Button(
                        onClick = onNext,
                        colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary),
                        shape = RoundedCornerShape(12.dp),
                        contentPadding = PaddingValues(horizontal = 24.dp, vertical = 10.dp)
                    ) {
                        Text(
                            if (currentStep == totalSteps - 1) "Got it!" else "Next →",
                            color = Color.White,
                            fontWeight = FontWeight.Bold,
                            fontSize = 14.sp
                        )
                    }
                }
            }
        }

        if (!arrowAtTop) {
            Spacer(Modifier.height(2.dp))
            Box(modifier = Modifier.offset(y = arrowDp)) {
                Icon(
                    Icons.Default.KeyboardArrowDown,
                    contentDescription = null,
                    tint = NotelPrimary,
                    modifier = Modifier.size(36.dp)
                )
            }
        }
    }
}
