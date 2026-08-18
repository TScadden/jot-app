package com.notel.notel.ui.screen

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.notel.notel.R
import com.notel.notel.ui.theme.*

@Composable
fun WelcomeOnboardingScreen(
    onGetStarted: () -> Unit
) {
    Scaffold(
        containerColor = NotelBackground
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.SpaceBetween
            ) {
                Spacer(Modifier.height(16.dp))

                // TOP FLOATING AVATARS & CALLOUT CARDS CONTAINER
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(380.dp)
                ) {
                    // Item 1: Man Avatar + "Track symptoms & treatments"
                    Row(
                        modifier = Modifier
                            .align(Alignment.TopStart)
                            .offset(y = 10.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Box(
                            modifier = Modifier
                                .size(90.dp)
                                .clip(CircleShape)
                                .background(
                                    Brush.radialGradient(
                                        colors = listOf(
                                            NotelPrimary.copy(alpha = 0.4f),
                                            NotelSurface
                                        )
                                    )
                                )
                                .border(2.dp, NotelPrimary.copy(alpha = 0.3f), CircleShape)
                                .padding(4.dp)
                        ) {
                            Image(
                                painter = painterResource(id = R.drawable.onboarding_avatar_man),
                                contentDescription = null,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier
                                    .fillMaxSize()
                                    .clip(CircleShape)
                            )
                        }
                        Spacer(Modifier.width(10.dp))
                        CalloutChip(
                            icon = Icons.Default.Biotech,
                            iconBg = Color(0xFF38BDF8),
                            title = "Track symptoms",
                            subtitle = "and treatments"
                        )
                    }

                    // Item 2: "Contribute to research" + Blonde Woman Avatar
                    Row(
                        modifier = Modifier
                            .align(Alignment.CenterEnd)
                            .offset(y = (-20).dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        CalloutChip(
                            icon = Icons.Default.EmojiEvents,
                            iconBg = Color(0xFFA855F7),
                            title = "Reach your",
                            subtitle = "goals"
                        )
                        Spacer(Modifier.width(10.dp))
                        Box(
                            modifier = Modifier
                                .size(95.dp)
                                .clip(CircleShape)
                                .background(
                                    Brush.radialGradient(
                                        colors = listOf(
                                            NotelAccent.copy(alpha = 0.4f),
                                            NotelSurface
                                        )
                                    )
                                )
                                .border(2.dp, NotelAccent.copy(alpha = 0.3f), CircleShape)
                                .padding(4.dp)
                        ) {
                            Image(
                                painter = painterResource(id = R.drawable.onboarding_avatar_woman1),
                                contentDescription = null,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier
                                    .fillMaxSize()
                                    .clip(CircleShape)
                            )
                        }
                    }

                    // Item 3: Asian Woman Avatar + "Learn patterns & get insights"
                    Row(
                        modifier = Modifier
                            .align(Alignment.BottomStart)
                            .offset(y = (-10).dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Box(
                            modifier = Modifier
                                .size(90.dp)
                                .clip(CircleShape)
                                .background(
                                    Brush.radialGradient(
                                        colors = listOf(
                                            Color(0xFFEC4899).copy(alpha = 0.4f),
                                            NotelSurface
                                        )
                                    )
                                )
                                .border(2.dp, Color(0xFFEC4899).copy(alpha = 0.3f), CircleShape)
                                .padding(4.dp)
                        ) {
                            Image(
                                painter = painterResource(id = R.drawable.onboarding_avatar_woman2),
                                contentDescription = null,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier
                                    .fillMaxSize()
                                    .clip(CircleShape)
                            )
                        }
                        Spacer(Modifier.width(10.dp))
                        CalloutChip(
                            icon = Icons.Default.Fingerprint,
                            iconBg = Color(0xFFA855F7),
                            title = "Learn patterns",
                            subtitle = "and get insights"
                        )
                    }
                }

                Spacer(Modifier.height(24.dp))

                // MIDDLE HEADLINE & BRANDING
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.Center
                    ) {
                        Image(
                            painter = painterResource(id = R.drawable.ic_tabs_note),
                            contentDescription = null,
                            modifier = Modifier.size(32.dp)
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(
                            text = "tabs",
                            fontSize = 32.sp,
                            fontWeight = FontWeight.Black,
                            color = NotelPrimary,
                            letterSpacing = 1.sp
                        )
                    }

                    Spacer(Modifier.height(16.dp))

                    Text(
                        text = "Notes that build",
                        fontSize = 34.sp,
                        fontWeight = FontWeight.Light,
                        fontStyle = FontStyle.Italic,
                        fontFamily = FontFamily.Serif,
                        color = NotelPrimary,
                        textAlign = TextAlign.Center
                    )
                    Text(
                        text = "with you",
                        fontSize = 42.sp,
                        fontWeight = FontWeight.Bold,
                        fontStyle = FontStyle.Italic,
                        fontFamily = FontFamily.Serif,
                        color = NotelPrimary,
                        textAlign = TextAlign.Center
                    )
                }

                Spacer(Modifier.height(36.dp))

                // BOTTOM GET STARTED BUTTON
                GlassyButton(
                    onClick = onGetStarted,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(56.dp)
                ) {
                    Text(
                        text = "Get started",
                        fontSize = 18.sp,
                        fontWeight = FontWeight.Bold,
                        color = Color.White
                    )
                }

                Spacer(Modifier.height(32.dp))
            }
        }
    }
}

@Composable
private fun CalloutChip(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    iconBg: Color,
    title: String,
    subtitle: String
) {
    Surface(
        shape = RoundedCornerShape(24.dp),
        color = NotelSurface,
        shadowElevation = 8.dp,
        border = BorderStroke(1.dp, NotelPrimary.copy(alpha = 0.15f)),
        modifier = Modifier.padding(vertical = 4.dp)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(36.dp)
                    .clip(CircleShape)
                    .background(
                        Brush.linearGradient(
                            colors = listOf(iconBg, iconBg.copy(alpha = 0.7f))
                        )
                    ),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = Color.White,
                    modifier = Modifier.size(20.dp)
                )
            }
            Spacer(Modifier.width(10.dp))
            Column {
                Text(
                    text = title,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = NotelTextPrimary,
                    lineHeight = 14.sp
                )
                Text(
                    text = subtitle,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Normal,
                    color = NotelTextSecondary,
                    lineHeight = 14.sp
                )
            }
        }
    }
}
