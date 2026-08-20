package com.notel.notel.ui.screen

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.ui.draw.clip
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.FitbitViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConnectionsScreen(
    fitbitViewModel: FitbitViewModel = hiltViewModel(),
    onBack: () -> Unit = {},
    onNavigateNext: () -> Unit
) {
    val state by fitbitViewModel.state.collectAsState()
    val context = androidx.compose.ui.platform.LocalContext.current

    val healthConnectLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        contract = fitbitViewModel.healthConnectManager.requestPermissionsActivityContract()
    ) { granted ->
        if (granted.containsAll(fitbitViewModel.healthConnectManager.permissions)) {
            fitbitViewModel.onPermissionsGranted()
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
            Column(
                modifier = Modifier.fillMaxSize(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.SpaceBetween
            ) {
                TopLogoHeader(
                    onBack = onBack,
                    modifier = Modifier.padding(top = 8.dp)
                )

                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(
                        text = "Connect Health Data",
                        fontSize = 28.sp,
                        fontWeight = FontWeight.ExtraBold,
                        color = NotelTextPrimary,
                        textAlign = TextAlign.Center
                    )

                    Spacer(modifier = Modifier.height(12.dp))

                    Text(
                        text = "Sync your heart rate and sleep data so AI can personalize your insights.",
                        color = NotelTextSecondary,
                        fontSize = 15.sp,
                        textAlign = TextAlign.Center,
                        lineHeight = 22.sp
                    )

                    Spacer(modifier = Modifier.height(32.dp))

                    if (state.isConnected) {
                        GlassyCard(
                            modifier = Modifier.fillMaxWidth(),
                            color = Color(0xFF4CAF50).copy(alpha = 0.15f)
                        ) {
                            Text(
                                text = "Looks like you are already connected!",
                                color = Color(0xFF4CAF50),
                                fontWeight = FontWeight.Bold,
                                fontSize = 15.sp,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(16.dp),
                                textAlign = TextAlign.Center
                            )
                        }
                    } else {
                        Button(
                            onClick = { healthConnectLauncher.launch(fitbitViewModel.healthConnectManager.permissions) },
                            colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary),
                            shape = RoundedCornerShape(24.dp),
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(54.dp)
                        ) {
                            Text("Connect Health Data", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 16.sp)
                        }

                        Spacer(modifier = Modifier.height(8.dp))

                        TextButton(
                            onClick = {
                                try {
                                    val intent = android.content.Intent("android.health.connect.action.HEALTH_HOME_SETTINGS")
                                    context.startActivity(intent)
                                } catch (e: Exception) {}
                            },
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Text("Manage access in settings", color = NotelTextSecondary, fontSize = 12.sp)
                        }
                    }
                }

                // NEXT / CONTINUE SETUP BUTTON (STANDARD PRIMARY BUTTON)
                Button(
                    onClick = onNavigateNext,
                    colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary),
                    shape = RoundedCornerShape(24.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(54.dp)
                ) {
                    Text(
                        text = if (state.isConnected) "Next" else "Skip for now",
                        color = Color.White,
                        fontWeight = FontWeight.Bold,
                        fontSize = 16.sp
                    )
                }
            }
    }
}
}
