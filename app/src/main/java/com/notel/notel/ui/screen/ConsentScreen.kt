package com.notel.notel.ui.screen

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.notel.notel.ui.theme.*

@Composable
fun ConsentScreen(
    onConsent: () -> Unit,
    onDecline: () -> Unit
) {
    var showDeclineDialog by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }

    if (showDeclineDialog) {
        AlertDialog(
            onDismissRequest = { showDeclineDialog = false },
            title = {
                Text(
                    text = "Data Consent Required",
                    fontWeight = FontWeight.Bold,
                    color = NotelTextPrimary
                )
            },
            text = {
                Text(
                    text = "Tabs relies on health notes and biometric data to generate personalized AI insights and recaps. Declining limits app capabilities. Would you like to go back to login or continue with limited functionality?",
                    color = NotelTextSecondary,
                    fontSize = 14.sp
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        showDeclineDialog = false
                        onConsent() // Proceed with core features
                    }
                ) {
                    Text("I Consent", color = NotelPrimary, fontWeight = FontWeight.Bold)
                }
            },
            dismissButton = {
                TextButton(
                    onClick = {
                        showDeclineDialog = false
                        onDecline()
                    }
                ) {
                    Text("Log Out", color = NotelTextSecondary)
                }
            },
            containerColor = NotelSurface,
            shape = RoundedCornerShape(20.dp)
        )
    }

    Scaffold(
        containerColor = NotelBackground
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 24.dp, vertical = 16.dp),
            contentAlignment = Alignment.Center
        ) {
            Column(
                modifier = Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.SpaceBetween,
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                // TOP LOGO HEADER
                TopLogoHeader(modifier = Modifier.padding(top = 8.dp))

                Spacer(Modifier.height(16.dp))

                // CONSENT CARD (Heart Icon removed)
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
                        Text(
                            text = "Privacy & Data Consent",
                            fontSize = 22.sp,
                            fontWeight = FontWeight.Bold,
                            color = NotelTextPrimary
                        )

                        Spacer(Modifier.height(16.dp))

                        Text(
                            text = "Tabs helps you build smart health logs and notes that grow with you. To calculate health trends and power your personalized AI recaps, we need your consent to securely process your health metrics.",
                            fontSize = 14.sp,
                            color = NotelTextSecondary,
                            lineHeight = 20.sp
                        )

                        Spacer(Modifier.height(14.dp))

                        Text(
                            text = "By consenting, you allow Tabs to sync and process your symptoms, biometric metrics (such as heart rate, sleep, and HRV), and logged notes to deliver your personalized dashboards and weekly health summaries.",
                            fontSize = 14.sp,
                            color = NotelTextSecondary,
                            lineHeight = 20.sp
                        )

                        Spacer(Modifier.height(14.dp))

                        Text(
                            text = "Your privacy is paramount. Anonymized and aggregated metrics help us improve trend models and build better features. Your personal data is never sold to third parties.",
                            fontSize = 14.sp,
                            color = NotelTextSecondary,
                            lineHeight = 20.sp
                        )
                    }
                }

                Spacer(Modifier.height(12.dp))

                // PRIVACY & TERMS LINKS OUTSIDE MAIN BOX
                val context = androidx.compose.ui.platform.LocalContext.current
                FlowRow(
                    horizontalArrangement = Arrangement.Center,
                    verticalArrangement = Arrangement.Center,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(
                        text = "Read our ",
                        fontSize = 12.sp,
                        color = NotelTextSecondary
                    )
                    Text(
                        text = "Terms of Use",
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Bold,
                        color = NotelPrimary,
                        modifier = Modifier.clickable {
                            val intent = android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse("https://api.jottracker.com/terms.html"))
                            context.startActivity(intent)
                        }
                    )
                    Text(
                        text = " and ",
                        fontSize = 12.sp,
                        color = NotelTextSecondary
                    )
                    Text(
                        text = "Privacy Policy",
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Bold,
                        color = NotelPrimary,
                        modifier = Modifier.clickable {
                            val intent = android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse("https://api.jottracker.com/privacy.html"))
                            context.startActivity(intent)
                        }
                    )
                    Text(
                        text = " for full details.",
                        fontSize = 12.sp,
                        color = NotelTextSecondary
                    )
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
                        onClick = { showDeclineDialog = true },
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
                            fontSize = 15.sp
                        )
                    }

                    Button(
                        onClick = onConsent,
                        colors = ButtonDefaults.buttonColors(
                            containerColor = NotelPrimary
                        ),
                        shape = RoundedCornerShape(24.dp),
                        modifier = Modifier
                            .weight(1f)
                            .height(52.dp)
                    ) {
                        Text(
                            text = "I consent",
                            color = Color.White,
                            fontWeight = FontWeight.Bold,
                            fontSize = 15.sp
                        )
                    }
                }
            }
        }
    }
}
