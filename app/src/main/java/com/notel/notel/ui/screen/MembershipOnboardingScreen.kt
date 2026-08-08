package com.notel.notel.ui.screen

import androidx.compose.animation.core.*
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.ui.theme.*

private data class PremiumFeature(
    val icon: ImageVector,
    val title: String,
    val description: String
)

private val premiumFeatures = listOf(
    PremiumFeature(Icons.Default.AutoAwesome, "AI Clinical Advocate", "Get a personalized AI coach that understands your health history, goals, and biometric data."),
    PremiumFeature(Icons.Default.Insights, "Smart Tiles & Trends", "Intelligent tiles that analyze your logs and surface patterns you didn't know existed."),
    PremiumFeature(Icons.Default.Science, "Deep Research Reports", "Generate clinical-quality weekly summaries of your body load, sleep, and heart data.")
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MembershipOnboardingScreen(
    settingsViewModel: com.notel.notel.ui.viewmodel.SettingsViewModel = hiltViewModel(),
    onSubscribe: () -> Unit,
    onSkip: () -> Unit
) {
    val context = LocalContext.current
    val activity = context as? android.app.Activity
    var selectedPlan by remember { mutableStateOf("monthly") }

    val isUnlimited by settingsViewModel.isUnlimited.collectAsState(initial = false)

    // Automatically navigate to loading screen to complete onboarding once user gets premium
    LaunchedEffect(isUnlimited) {
        if (isUnlimited) {
            onSkip()
        }
    }

    val infiniteTransition = rememberInfiniteTransition(label = "glow")
    val glowAlpha by infiniteTransition.animateFloat(
        initialValue = 0.4f,
        targetValue = 0.75f,
        animationSpec = infiniteRepeatable(
            animation = tween(2000, easing = EaseInOutSine),
            repeatMode = RepeatMode.Reverse
        ),
        label = "glowAlpha"
    )

    Scaffold(containerColor = NotelBackground) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Spacer(Modifier.height(32.dp))

            // Glow badge
            Box(
                modifier = Modifier
                    .size(88.dp)
                    .clip(RoundedCornerShape(24.dp))
                    .background(
                        Brush.radialGradient(
                            colors = listOf(
                                NotelPrimary.copy(alpha = glowAlpha),
                                NotelSurface
                            )
                        )
                    ),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    Icons.Default.WorkspacePremium,
                    contentDescription = "Premium",
                    tint = Color.White,
                    modifier = Modifier.size(48.dp)
                )
            }

            Spacer(Modifier.height(24.dp))

            Text(
                "Unlock Tabs Premium",
                fontSize = 28.sp,
                fontWeight = FontWeight.ExtraBold,
                color = NotelTextPrimary,
                textAlign = TextAlign.Center
            )
            Spacer(Modifier.height(8.dp))
            Text(
                "Everything you need to understand your body and reach your goals.",
                color = NotelTextSecondary,
                fontSize = 15.sp,
                textAlign = TextAlign.Center
            )

            Spacer(Modifier.height(32.dp))

            // Feature list
            premiumFeatures.forEach { feature ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 10.dp)
                        .clip(RoundedCornerShape(14.dp))
                        .background(NotelSurface)
                        .border(1.dp, NotelPrimary.copy(alpha = 0.15f), RoundedCornerShape(14.dp))
                        .padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Box(
                        modifier = Modifier
                            .size(40.dp)
                            .clip(RoundedCornerShape(10.dp))
                            .background(NotelPrimary.copy(alpha = 0.15f)),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(feature.icon, contentDescription = null, tint = NotelPrimary, modifier = Modifier.size(22.dp))
                    }
                    Spacer(Modifier.width(14.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(feature.title, color = NotelTextPrimary, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                        Text(feature.description, color = NotelTextSecondary, fontSize = 12.sp, lineHeight = 16.sp)
                    }
                }
            }

            Spacer(Modifier.height(32.dp))

            // Plan 1: Monthly
            val isMonthlySelected = selectedPlan == "monthly"
            Surface(
                onClick = { selectedPlan = "monthly" },
                shape = RoundedCornerShape(16.dp),
                color = if (isMonthlySelected) NotelPrimary.copy(alpha = 0.08f) else NotelSurfaceHigh,
                border = BorderStroke(
                    width = if (isMonthlySelected) 2.dp else 1.dp,
                    color = if (isMonthlySelected) NotelPrimary else NotelPrimary.copy(alpha = 0.15f)
                ),
                modifier = Modifier.fillMaxWidth()
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    RadioButton(
                        selected = isMonthlySelected,
                        onClick = { selectedPlan = "monthly" },
                        colors = RadioButtonDefaults.colors(
                            selectedColor = NotelPrimary,
                            unselectedColor = NotelTextSecondary
                        )
                    )
                    Spacer(Modifier.width(12.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "Monthly Plan",
                            color = NotelTextPrimary,
                            fontWeight = FontWeight.Bold,
                            fontSize = 16.sp
                        )
                        Spacer(Modifier.height(2.dp))
                        Text(
                            text = "7-day free trial, then $5.99/mo",
                            color = NotelTextSecondary,
                            fontSize = 13.sp
                        )
                    }
                    Surface(
                        shape = RoundedCornerShape(8.dp),
                        color = NotelPrimary.copy(alpha = 0.12f),
                        modifier = Modifier.padding(horizontal = 4.dp)
                    ) {
                        Text(
                            text = "FREE TRIAL",
                            color = NotelPrimary,
                            fontSize = 9.sp,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp)
                        )
                    }
                }
            }

            Spacer(Modifier.height(12.dp))

            // Plan 2: Yearly
            val isYearlySelected = selectedPlan == "yearly"
            Surface(
                onClick = { selectedPlan = "yearly" },
                shape = RoundedCornerShape(16.dp),
                color = if (isYearlySelected) NotelPrimary.copy(alpha = 0.08f) else NotelSurfaceHigh,
                border = BorderStroke(
                    width = if (isYearlySelected) 2.dp else 1.dp,
                    color = if (isYearlySelected) NotelPrimary else NotelPrimary.copy(alpha = 0.15f)
                ),
                modifier = Modifier.fillMaxWidth()
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    RadioButton(
                        selected = isYearlySelected,
                        onClick = { selectedPlan = "yearly" },
                        colors = RadioButtonDefaults.colors(
                            selectedColor = NotelPrimary,
                            unselectedColor = NotelTextSecondary
                        )
                    )
                    Spacer(Modifier.width(12.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "Yearly Plan",
                            color = NotelTextPrimary,
                            fontWeight = FontWeight.Bold,
                            fontSize = 16.sp
                        )
                        Spacer(Modifier.height(2.dp))
                        Text(
                            text = "7-day free trial, then $39.99/yr",
                            color = NotelTextSecondary,
                            fontSize = 13.sp
                        )
                    }
                    Surface(
                        shape = RoundedCornerShape(8.dp),
                        color = Color(0xFF4CAF50).copy(alpha = 0.12f),
                        modifier = Modifier.padding(horizontal = 4.dp)
                    ) {
                        Text(
                            text = "SAVE 45% • BEST VALUE",
                            color = Color(0xFF4CAF50),
                            fontSize = 9.sp,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp)
                        )
                    }
                }
            }

            Spacer(Modifier.height(24.dp))

            GlassyButton(
                onClick = {
                    activity?.let {
                        settingsViewModel.purchaseCredits(
                            it,
                            if (selectedPlan == "monthly") "jot_membership_monthly" else "jot_membership_yearly"
                        )
                    }
                },
                modifier = Modifier.fillMaxWidth()
            ) {
                Icon(Icons.Default.WorkspacePremium, contentDescription = null, tint = Color.White)
                Spacer(Modifier.width(8.dp))
                Text("Start 7-Day Free Trial", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 17.sp)
            }

            Spacer(Modifier.height(12.dp))

            TextButton(
                onClick = onSkip,
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(
                    "Use free account for now",
                    color = NotelTextSecondary,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Medium
                )
            }

            Spacer(Modifier.height(32.dp))
        }
    }
}
