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
                modifier = Modifier
                    .fillMaxSize(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.SpaceBetween
            ) {
                TopLogoHeader(
                    onBack = onBack,
                    modifier = Modifier.padding(top = 8.dp)
                )
            Icon(Icons.Default.Favorite, contentDescription = "Heart", tint = NotelPrimary, modifier = Modifier.size(64.dp))
            Spacer(modifier = Modifier.height(24.dp))
            
            Text("Connect Health Data", fontSize = 28.sp, fontWeight = FontWeight.ExtraBold, color = NotelTextPrimary)
            Spacer(modifier = Modifier.height(16.dp))
            
            Text(
                "Linking Health Connect allows Tabs to securely pull in your intraday heart rate and nightly sleep phases. This biometric data is invaluable for the AI to understand your physical state when building trends and insights.",
                color = NotelTextSecondary,
                fontSize = 16.sp,
                textAlign = TextAlign.Center
            )
            
            Spacer(modifier = Modifier.height(48.dp))
            
            if (state.isConnected) {
                GlassyCard(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp), color = Color.Green.copy(alpha = 0.2f)) {
                    Text("Health Connect is successfully connected!", color = Color.Green, fontWeight = FontWeight.Bold, modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center)
                }
                Spacer(modifier = Modifier.height(32.dp))
            } else {
                GlassyButton(
                    onClick = { healthConnectLauncher.launch(fitbitViewModel.healthConnectManager.permissions) },
                    modifier = Modifier.fillMaxWidth(),
                    containerColor = NotelPrimary
                ) {
                    Text("Connect Health Data", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                }
                Spacer(modifier = Modifier.height(4.dp))
                TextButton(
                    onClick = {
                        try {
                            val intent = android.content.Intent("android.health.connect.action.HEALTH_HOME_SETTINGS")
                            context.startActivity(intent)
                        } catch(e: Exception) {}
                    },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text("Manage access in settings", color = NotelTextSecondary, fontSize = 12.sp)
                }
                Spacer(modifier = Modifier.height(16.dp))
            }
            
            TextButton(
                onClick = onNavigateNext,
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(if (state.isConnected) "Continue Setup" else "Skip for now, I'll do it later in settings", color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}
}
