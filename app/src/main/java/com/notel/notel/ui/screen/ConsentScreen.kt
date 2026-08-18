package com.notel.notel.ui.screen

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.notel.notel.ui.theme.*

@Composable
fun ConsentScreen(
    onConsent: () -> Unit,
    onDecline: () -> Unit
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
                verticalArrangement = Arrangement.SpaceBetween
            ) {
                Spacer(Modifier.height(12.dp))

                // CONSENT CARD
                Surface(
                    shape = RoundedCornerShape(28.dp),
                    color = NotelSurface,
                    shadowElevation = 6.dp,
                    border = BorderStroke(1.dp, NotelPrimary.copy(alpha = 0.15f)),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .verticalScroll(rememberScrollState())
                            .padding(24.dp)
                    ) {
                        // Heart Health Icon Badge
                        Box(
                            modifier = Modifier
                                .size(48.dp)
                                .clip(CircleShape)
                                .background(NotelPrimary.copy(alpha = 0.15f)),
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                imageVector = Icons.Default.FavoriteBorder,
                                contentDescription = null,
                                tint = NotelPrimary,
                                modifier = Modifier.size(24.dp)
                            )
                        }

                        Spacer(Modifier.height(20.dp))

                        Text(
                            text = "Before getting started",
                            fontSize = 24.sp,
                            fontWeight = FontWeight.Bold,
                            color = NotelTextPrimary
                        )

                        Spacer(Modifier.height(16.dp))

                        Text(
                            text = "This app processes health data to deliver its core features. Because health data is sensitive, we need your explicit consent before we can use it.",
                            fontSize = 14.sp,
                            color = NotelTextSecondary,
                            lineHeight = 20.sp
                        )

                        Spacer(Modifier.height(14.dp))

                        Text(
                            text = "If you consent, we will collect and use your health data (such as health conditions, symptoms, treatments and medical history) to track and visualize your health journey, and to provide technical support.",
                            fontSize = 14.sp,
                            color = NotelTextSecondary,
                            lineHeight = 20.sp
                        )

                        Spacer(Modifier.height(14.dp))

                        Text(
                            text = "We also combine your data with other users' data, removing details that could identify you individually. This helps us analyze user trends, produce statistics, improve existing features and decide what new features to build.",
                            fontSize = 14.sp,
                            color = NotelTextSecondary,
                            lineHeight = 20.sp
                        )

                        Spacer(Modifier.height(14.dp))

                        val context = androidx.compose.ui.platform.LocalContext.current
                        Row {
                            Text(
                                text = "See the ",
                                fontSize = 14.sp,
                                color = NotelTextSecondary
                            )
                            Text(
                                text = "Privacy Policy",
                                fontSize = 14.sp,
                                fontWeight = FontWeight.Bold,
                                color = NotelPrimary,
                                modifier = Modifier.clickable {
                                    val intent = android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse("https://jottracker.com/privacy.html"))
                                    context.startActivity(intent)
                                }
                            )
                            Text(
                                text = " for more detail.",
                                fontSize = 14.sp,
                                color = NotelTextSecondary
                            )
                        }
                    }
                }

                // BOTTOM BUTTON BAR (Decline & I consent)
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 16.dp, bottom = 12.dp),
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Button(
                        onClick = onDecline,
                        colors = ButtonDefaults.buttonColors(
                            containerColor = NotelSurfaceHigh
                        ),
                        shape = RoundedCornerShape(24.dp),
                        modifier = Modifier
                            .weight(1f)
                            .height(52.dp)
                    ) {
                        Text(
                            text = "Decline",
                            color = NotelTextPrimary,
                            fontWeight = FontWeight.Bold,
                            fontSize = 16.sp
                        )
                    }

                    GlassyButton(
                        onClick = onConsent,
                        modifier = Modifier
                            .weight(2f)
                            .height(52.dp)
                    ) {
                        Text(
                            text = "I consent",
                            color = Color.White,
                            fontWeight = FontWeight.Bold,
                            fontSize = 16.sp
                        )
                    }
                }
            }
        }
    }
}
