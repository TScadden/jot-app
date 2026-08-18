package com.notel.notel.ui.screen

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.notel.notel.ui.theme.*

@Composable
fun ConsultationIntroScreen(
    onContinue: () -> Unit
) {
    Scaffold(
        containerColor = NotelBackground
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(24.dp),
            contentAlignment = Alignment.Center
        ) {
            Column(
                modifier = Modifier.fillMaxSize(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.SpaceBetween
            ) {
                Spacer(Modifier.height(20.dp))

                // CENTER FLOATING ORB & HEALTH ICONS GRAPHIC
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(300.dp),
                    contentAlignment = Alignment.Center
                ) {
                    // Central Glowing Gradient Orb
                    Box(
                        modifier = Modifier
                            .size(160.dp)
                            .clip(CircleShape)
                            .background(
                                Brush.radialGradient(
                                    colors = listOf(
                                        NotelPrimary.copy(alpha = 0.8f),
                                        NotelAccent.copy(alpha = 0.5f),
                                        Color.Transparent
                                    )
                                )
                            )
                    )

                    // Surrounding Icon Bubble 1 (Top Left)
                    IconBubble(
                        icon = Icons.Default.MedicalServices,
                        bubbleColor = Color(0xFF38BDF8),
                        modifier = Modifier
                            .align(Alignment.TopStart)
                            .offset(x = 40.dp, y = 30.dp)
                    )

                    // Surrounding Icon Bubble 2 (Top Right)
                    IconBubble(
                        icon = Icons.Default.Favorite,
                        bubbleColor = Color(0xFFEC4899),
                        modifier = Modifier
                            .align(Alignment.TopEnd)
                            .offset(x = (-40).dp, y = 40.dp)
                    )

                    // Surrounding Icon Bubble 3 (Mid Left)
                    IconBubble(
                        icon = Icons.Default.Search,
                        bubbleColor = Color(0xFFA855F7),
                        modifier = Modifier
                            .align(Alignment.CenterStart)
                            .offset(x = 20.dp, y = (-10).dp)
                    )

                    // Surrounding Icon Bubble 4 (Mid Right)
                    IconBubble(
                        icon = Icons.Default.Psychology,
                        bubbleColor = Color(0xFF8B5CF6),
                        modifier = Modifier
                            .align(Alignment.CenterEnd)
                            .offset(x = (-20).dp, y = 20.dp)
                    )

                    // Surrounding Icon Bubble 5 (Bottom Left)
                    IconBubble(
                        icon = Icons.Default.LocalHospital,
                        bubbleColor = Color(0xFF22C55E),
                        modifier = Modifier
                            .align(Alignment.BottomStart)
                            .offset(x = 50.dp, y = (-20).dp)
                    )
                }

                // TEXT SECTION
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.padding(horizontal = 12.dp)
                ) {
                    Text(
                        text = "Let's get you set up!",
                        fontSize = 28.sp,
                        fontWeight = FontWeight.Bold,
                        color = NotelTextPrimary,
                        textAlign = TextAlign.Center
                    )

                    Spacer(Modifier.height(16.dp))

                    Text(
                        text = "Start by sharing your goals and why you are using this app so we can make sure the AI knows how to best help you.",
                        fontSize = 15.sp,
                        color = NotelTextSecondary,
                        textAlign = TextAlign.Center,
                        lineHeight = 22.sp
                    )
                }

                Spacer(Modifier.height(20.dp))

                // CONTINUE BUTTON
                Button(
                    onClick = onContinue,
                    colors = ButtonDefaults.buttonColors(
                        containerColor = NotelPrimary
                    ),
                    shape = RoundedCornerShape(24.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(54.dp)
                ) {
                    Text(
                        text = "Continue",
                        color = Color.White,
                        fontWeight = FontWeight.Bold,
                        fontSize = 16.sp
                    )
                }
            }
        }
    }
}

@Composable
private fun IconBubble(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    bubbleColor: Color,
    modifier: Modifier = Modifier
) {
    Box(
        modifier = modifier
            .size(46.dp)
            .clip(CircleShape)
            .background(
                Brush.linearGradient(
                    colors = listOf(bubbleColor, bubbleColor.copy(alpha = 0.7f))
                )
            )
            .border(1.5.dp, Color.White.copy(alpha = 0.6f), CircleShape),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier.size(22.dp)
        )
    }
}
