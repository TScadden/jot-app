package com.notel.notel.ui.screen

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import com.notel.notel.ui.theme.*

@Composable
fun NotificationOnboardingScreen(
    onNavigateNext: () -> Unit,
    onSkip: () -> Unit
) {
    val context = LocalContext.current

    val launcher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission(),
        onResult = { isGranted ->
            onNavigateNext()
        }
    )

    fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val permissionCheck = ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS
            )
            if (permissionCheck == PackageManager.PERMISSION_GRANTED) {
                onNavigateNext()
            } else {
                launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
        } else {
            onNavigateNext()
        }
    }

    Scaffold(
        containerColor = NotelBackground
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 24.dp, vertical = 16.dp)
        ) {
            // TOP SKIP BUTTON
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .align(Alignment.TopStart),
                horizontalArrangement = Arrangement.Start
            ) {
                Button(
                    onClick = onSkip,
                    colors = ButtonDefaults.buttonColors(containerColor = NotelSurfaceHigh),
                    shape = CircleShape,
                    contentPadding = PaddingValues(horizontal = 18.dp, vertical = 6.dp)
                ) {
                    Text("Skip", color = NotelTextPrimary, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                }
            }

            // MAIN CONTENT COLUMN - CENTERED
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .align(Alignment.Center),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center
            ) {
                // NOTIFICATION PERMISSION CARD
                GlassyCard(
                    shape = RoundedCornerShape(32.dp),
                    color = NotelSurface,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 32.dp, horizontal = 24.dp),
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        Icon(
                            imageVector = Icons.Outlined.Notifications,
                            contentDescription = null,
                            tint = NotelPrimary,
                            modifier = Modifier.size(36.dp)
                        )

                        Spacer(Modifier.height(20.dp))

                        Text(
                            text = "Allow Tabs to send you\nnotifications?",
                            fontSize = 17.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = NotelTextPrimary,
                            textAlign = TextAlign.Center,
                            lineHeight = 23.sp
                        )

                        Spacer(Modifier.height(28.dp))

                        // ALLOW BUTTON
                        Button(
                            onClick = { requestNotificationPermission() },
                            colors = ButtonDefaults.buttonColors(containerColor = NotelSurfaceHigh),
                            shape = RoundedCornerShape(16.dp),
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(50.dp)
                        ) {
                            Text("Allow", color = NotelPrimary, fontWeight = FontWeight.Bold, fontSize = 16.sp)
                        }

                        Spacer(Modifier.height(10.dp))

                        // DON'T ALLOW BUTTON
                        Button(
                            onClick = onSkip,
                            colors = ButtonDefaults.buttonColors(containerColor = NotelSurfaceHigh.copy(alpha = 0.5f)),
                            shape = RoundedCornerShape(16.dp),
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(50.dp)
                        ) {
                            Text("Don't Allow", color = NotelPrimary.copy(alpha = 0.8f), fontWeight = FontWeight.Medium, fontSize = 16.sp)
                        }
                    }
                }

                Spacer(Modifier.height(36.dp))

                Text(
                    text = "Press \"Allow\"",
                    fontSize = 14.sp,
                    color = NotelPrimary,
                    fontWeight = FontWeight.Bold,
                    textAlign = TextAlign.Center
                )

                Spacer(Modifier.height(8.dp))

                Text(
                    text = "Never miss a\ncheck-in",
                    fontSize = 34.sp,
                    fontWeight = FontWeight.Black,
                    color = NotelPrimary,
                    textAlign = TextAlign.Center,
                    lineHeight = 40.sp
                )
            }
        }
    }
}
