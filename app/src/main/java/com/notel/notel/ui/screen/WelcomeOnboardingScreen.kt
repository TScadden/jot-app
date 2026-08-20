package com.notel.notel.ui.screen

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
    onLogin: () -> Unit,
    onSignUp: () -> Unit
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
                    .padding(horizontal = 20.dp, vertical = 16.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.SpaceBetween
            ) {
                // TOP LOGO HEADER
                TopLogoHeader(modifier = Modifier.padding(top = 8.dp))

                Spacer(Modifier.height(12.dp))

                // PEOPLE & CHIPS VERTICAL LIST (ONE AFTER THE OTHER WITH TIGHT SPACING)
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    // Item 1: Man Avatar + "Track symptoms and treatments"
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.Start
                    ) {
                        Box(
                            modifier = Modifier
                                .size(58.dp)
                                .clip(CircleShape)
                                .background(
                                    Brush.radialGradient(
                                        colors = listOf(
                                            NotelPrimary.copy(alpha = 0.4f),
                                            NotelSurface
                                        )
                                    )
                                )
                                .border(2.dp, NotelPrimary.copy(alpha = 0.35f), CircleShape)
                                .padding(3.dp)
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
                            text = "Track symptoms and treatments",
                            modifier = Modifier.weight(1f, fill = false)
                        )
                    }

                    // Item 2: Blonde Woman Avatar + "Reach your goals"
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.End
                    ) {
                        CalloutChip(
                            icon = Icons.Default.EmojiEvents,
                            iconBg = Color(0xFFA855F7),
                            text = "Reach your goals",
                            modifier = Modifier.weight(1f, fill = false)
                        )
                        Spacer(Modifier.width(10.dp))
                        Box(
                            modifier = Modifier
                                .size(58.dp)
                                .clip(CircleShape)
                                .background(
                                    Brush.radialGradient(
                                        colors = listOf(
                                            NotelAccent.copy(alpha = 0.4f),
                                            NotelSurface
                                        )
                                    )
                                )
                                .border(2.dp, NotelAccent.copy(alpha = 0.35f), CircleShape)
                                .padding(3.dp)
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

                    // Item 3: Asian Woman Avatar + "Learn patterns and get insights"
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.Start
                    ) {
                        Box(
                            modifier = Modifier
                                .size(58.dp)
                                .clip(CircleShape)
                                .background(
                                    Brush.radialGradient(
                                        colors = listOf(
                                            Color(0xFFEC4899).copy(alpha = 0.4f),
                                            NotelSurface
                                        )
                                    )
                                )
                                .border(2.dp, Color(0xFFEC4899).copy(alpha = 0.35f), CircleShape)
                                .padding(3.dp)
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
                            text = "Learn patterns and get insights",
                            modifier = Modifier.weight(1f, fill = false)
                        )
                    }
                }

                Spacer(Modifier.height(16.dp))

                // SLOGAN + BUTTONS AT THE BOTTOM
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    // SLOGAN TEXT: Notes that build with you (Above Buttons)
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.padding(bottom = 16.dp)
                    ) {
                        Text(
                            text = "Notes that build",
                            fontSize = 22.sp,
                            fontWeight = FontWeight.Light,
                            fontStyle = FontStyle.Italic,
                            fontFamily = FontFamily.Serif,
                            color = NotelPrimary,
                            textAlign = TextAlign.Center
                        )
                        Text(
                            text = "with you",
                            fontSize = 28.sp,
                            fontWeight = FontWeight.Bold,
                            fontStyle = FontStyle.Italic,
                            fontFamily = FontFamily.Serif,
                            color = NotelPrimary,
                            textAlign = TextAlign.Center
                        )
                    }

                    // DISCORD-STYLE REGISTRATION / LOGIN BUTTONS AT VERY BOTTOM
                    Column(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        // Sign Up / Register Button
                        Button(
                            onClick = onSignUp,
                            colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary),
                            shape = RoundedCornerShape(24.dp),
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(52.dp)
                        ) {
                            Text(
                                text = "Register",
                                fontSize = 17.sp,
                                fontWeight = FontWeight.Bold,
                                color = Color.White
                            )
                        }

                        // Log In Button
                        Button(
                            onClick = onLogin,
                            colors = ButtonDefaults.buttonColors(containerColor = NotelSurfaceHigh),
                            shape = RoundedCornerShape(24.dp),
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(52.dp)
                        ) {
                            Text(
                                text = "Log In",
                                fontSize = 17.sp,
                                fontWeight = FontWeight.Bold,
                                color = NotelPrimary
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun CalloutChip(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    iconBg: Color,
    text: String,
    modifier: Modifier = Modifier
) {
    Surface(
        shape = RoundedCornerShape(20.dp),
        color = NotelSurface,
        shadowElevation = 4.dp,
        border = BorderStroke(1.dp, NotelPrimary.copy(alpha = 0.15f)),
        modifier = modifier.padding(vertical = 2.dp)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(34.dp)
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
                    modifier = Modifier.size(18.dp)
                )
            }
            Spacer(Modifier.width(10.dp))
            Text(
                text = text,
                fontSize = 15.sp,
                fontWeight = FontWeight.Bold,
                color = NotelTextPrimary,
                maxLines = 2,
                softWrap = true
            )
        }
    }
}
