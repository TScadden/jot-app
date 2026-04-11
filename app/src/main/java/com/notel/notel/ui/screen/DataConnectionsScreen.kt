package com.notel.notel.ui.screen

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ChevronRight
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.FitbitViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DataConnectionsScreen(
    onBack: () -> Unit,
    fitbitViewModel: FitbitViewModel = hiltViewModel()
) {
    val state by fitbitViewModel.state.collectAsState()
    var showHowToSheet by remember { mutableStateOf(false) }
    val context = LocalContext.current

    val healthConnectLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        contract = fitbitViewModel.healthConnectManager.requestPermissionsActivityContract()
    ) { granted ->
        if (granted.containsAll(fitbitViewModel.healthConnectManager.permissions)) {
            fitbitViewModel.onPermissionsGranted()
        }
    }

    // Definition of supported apps and their current connection status
    val supportedApps = remember(state.isConnected, state.isFitbitConnected) {
        listOf(
            AppInfo(
                id = "health_connect",
                name = "Health Connect",
                logo = { HealthConnectLogo() },
                isConnected = state.isConnected,
                onConnect = { healthConnectLauncher.launch(fitbitViewModel.healthConnectManager.permissions) }
            ),
            AppInfo(
                id = "fitbit",
                name = "Fitbit",
                logo = { FitbitLogo() },
                isConnected = state.isFitbitConnected,
                onConnect = { fitbitViewModel.connectFitbit(context) }
            ),
            AppInfo(
                id = "google_fit",
                name = "Google Fit",
                logo = { GoogleFitLogo() },
                isConnected = false, // Integrated into HC mainly for Android
                onConnect = { /* Future or link to Fit */ }
            )
        )
    }

    val connectedApps = supportedApps.filter { it.isConnected }
    val availableApps = supportedApps.filter { !it.isConnected }

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = {
                    Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                        Text(
                            "Data connections",
                            fontWeight = FontWeight.Bold,
                            color = NotelTextPrimary,
                            fontSize = 20.sp
                        )
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Default.ArrowBack, "Back", tint = NotelPrimary)
                    }
                },
                actions = {
                    Spacer(Modifier.width(48.dp))
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = NotelBackground)
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp)
        ) {
            // Your Connections Section
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    "Your connections",
                    color = NotelTextSecondary,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(start = 4.dp, bottom = 4.dp)
                )
                
                if (connectedApps.isNotEmpty()) {
                    connectedApps.forEach { app ->
                        ConnectionItem(
                            name = app.name,
                            logo = app.logo,
                            status = "Connected",
                            onClick = { /* Could open manage UI */ }
                        )
                    }
                } else {
                    Text(
                        "No trackers connected yet.",
                        color = NotelTextSecondary.copy(alpha = 0.5f),
                        fontSize = 14.sp,
                        modifier = Modifier.padding(start = 4.dp)
                    )
                }
            }

            // Add Connections Section
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    "Add connections",
                    color = NotelTextSecondary,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(start = 4.dp, bottom = 4.dp)
                )
                
                if (availableApps.isNotEmpty()) {
                    availableApps.forEach { app ->
                        ConnectionItem(
                            name = app.name,
                            logo = app.logo,
                            status = "Available",
                            onClick = { app.onConnect() }
                        )
                    }
                } else {
                    Text(
                        "You've connected every supported tracker.",
                        color = NotelTextSecondary.copy(alpha = 0.5f),
                        fontSize = 14.sp,
                        textAlign = TextAlign.Center,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 16.dp)
                    )
                }
            }

            // Help Section
            ConnectionSection(
                title = "How to connect a tracker",
                icon = Icons.Default.HelpOutline,
                onClick = { showHowToSheet = true }
            )
        }
    }

    if (showHowToSheet) {
        ModalBottomSheet(
            onDismissRequest = { showHowToSheet = false },
            containerColor = NotelSurface,
            dragHandle = { BottomSheetDefaults.DragHandle(color = NotelTextSecondary.copy(alpha = 0.3f)) }
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 32.dp)
                    .padding(bottom = 64.dp)
            ) {
                Text(
                    "How to connect",
                    color = NotelTextPrimary,
                    fontSize = 24.sp,
                    fontWeight = FontWeight.Black
                )
                Spacer(Modifier.height(24.dp))
                
                HowToStep(
                    number = "1",
                    title = "External Hubs",
                    description = "Most trackers (Fitbit, Garmin, Samsung) don't talk to Jot directly. They sync their data to a central hub like Health Connect."
                )
                
                HowToStep(
                    number = "2",
                    title = "Grant Permissions",
                    description = "When you click 'Add connections', Jot will request permission to read Heart Rate, Sleep, and Calories from your hub."
                )
                
                HowToStep(
                    number = "3",
                    title = "Ensure Sync is Active",
                    description = "Check that your tracker app (e.g., the Fitbit app) is set up to share data with Health Connect. Jot will then automatically pick it up!"
                )
                
                Spacer(Modifier.height(32.dp))
                
                Button(
                    onClick = { showHowToSheet = false },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary),
                    shape = RoundedCornerShape(12.dp)
                ) {
                    Text("Got it", fontWeight = FontWeight.Bold)
                }
            }
        }
    }
}

@Composable
fun HowToStep(
    number: String,
    title: String,
    description: String
) {
    Row(modifier = Modifier.padding(vertical = 12.dp)) {
        Box(
            modifier = Modifier
                .size(28.dp)
                .background(NotelPrimary.copy(alpha = 0.15f), CircleShape),
            contentAlignment = Alignment.Center
        ) {
            Text(number, color = NotelPrimary, fontWeight = FontWeight.Black, fontSize = 12.sp)
        }
        Spacer(Modifier.width(16.dp))
        Column {
            Text(title, color = NotelTextPrimary, fontWeight = FontWeight.Bold, fontSize = 16.sp)
            Text(description, color = NotelTextSecondary, fontSize = 14.sp)
        }
    }
}

data class AppInfo(
    val id: String,
    val name: String,
    val logo: @Composable () -> Unit,
    val isConnected: Boolean,
    val onConnect: () -> Unit
)

@Composable
fun ConnectionItem(
    name: String,
    logo: @Composable () -> Unit,
    status: String,
    onClick: () -> Unit
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onClick() },
        shape = RoundedCornerShape(20.dp),
        color = NotelSurface,
        border = androidx.compose.foundation.BorderStroke(1.dp, NotelSurfaceHigh.copy(alpha = 0.3f))
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .background(Color.White.copy(alpha = 0.05f), CircleShape),
                contentAlignment = Alignment.Center
            ) {
                logo()
            }
            Spacer(Modifier.width(16.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = name,
                    color = NotelTextPrimary,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold
                )
                Text(
                    text = status,
                    color = if (status == "Connected") Color(0xFF66BB6A) else NotelTextSecondary,
                    fontSize = 12.sp
                )
            }
            Icon(
                imageVector = Icons.AutoMirrored.Filled.ChevronRight,
                contentDescription = null,
                tint = NotelTextSecondary.copy(alpha = 0.5f),
                modifier = Modifier.size(20.dp)
            )
        }
    }
}

@Composable
fun FitbitLogo() {
    Canvas(modifier = Modifier.size(24.dp)) {
        val dotRadius = 2.dp.toPx()
        val spacing = 5.dp.toPx()
        val color = Color(0xFF00B0B9)

        drawCircle(color, dotRadius, center = center)
        drawCircle(color, dotRadius, center = center.copy(x = center.x - spacing))
        drawCircle(color, dotRadius, center = center.copy(x = center.x + spacing))
        drawCircle(color, dotRadius, center = center.copy(x = center.x - spacing * 2))
        drawCircle(color, dotRadius, center = center.copy(x = center.x + spacing * 2))

        drawCircle(color, dotRadius, center = center.copy(y = center.y - spacing))
        drawCircle(color, dotRadius, center = center.copy(y = center.y + spacing))
        drawCircle(color, dotRadius, center = center.copy(x = center.x - spacing, y = center.y - spacing))
        drawCircle(color, dotRadius, center = center.copy(x = center.x + spacing, y = center.y - spacing))
        drawCircle(color, dotRadius, center = center.copy(x = center.x - spacing, y = center.y + spacing))
        drawCircle(color, dotRadius, center = center.copy(x = center.x + spacing, y = center.y + spacing))
        
        drawCircle(color, dotRadius, center = center.copy(y = center.y - spacing * 2))
        drawCircle(color, dotRadius, center = center.copy(y = center.y + spacing * 2))
    }
}

@Composable
fun HealthConnectLogo() {
    Canvas(modifier = Modifier.size(24.dp)) {
        val color = Color(0xFF4285F4)
        val strokeWidth = 3.dp.toPx()
        
        drawCircle(color.copy(alpha = 0.8f), size.width / 4, center = center.copy(x = center.x - 4.dp.toPx()), style = androidx.compose.ui.graphics.drawscope.Stroke(strokeWidth))
        drawCircle(NotelPrimary.copy(alpha = 0.8f), size.width / 4, center = center.copy(x = center.x + 4.dp.toPx()), style = androidx.compose.ui.graphics.drawscope.Stroke(strokeWidth))
    }
}

@Composable
fun GoogleFitLogo() {
    Canvas(modifier = Modifier.size(24.dp)) {
        val strokeWidth = 3.dp.toPx()
        val path = Path().apply {
            moveTo(size.width * 0.2f, size.height * 0.5f)
            lineTo(size.width * 0.5f, size.height * 0.8f)
            lineTo(size.width * 0.8f, size.height * 0.2f)
        }
        drawPath(path, color = Color(0xFFEA4335), style = androidx.compose.ui.graphics.drawscope.Stroke(strokeWidth, cap = androidx.compose.ui.graphics.StrokeCap.Round))
    }
}

@Composable
fun ConnectionSection(
    title: String,
    icon: ImageVector,
    onClick: () -> Unit
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onClick() },
        shape = RoundedCornerShape(20.dp),
        color = NotelSurface,
        border = androidx.compose.foundation.BorderStroke(1.dp, NotelSurfaceHigh.copy(alpha = 0.3f))
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(20.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = NotelPrimary,
                modifier = Modifier.size(24.dp)
            )
            Spacer(Modifier.width(16.dp))
            Text(
                text = title,
                color = NotelTextPrimary,
                fontSize = 16.sp,
                fontWeight = FontWeight.Medium,
                modifier = Modifier.weight(1f)
            )
            Icon(
                imageVector = Icons.AutoMirrored.Filled.ChevronRight,
                contentDescription = null,
                tint = NotelTextSecondary.copy(alpha = 0.5f),
                modifier = Modifier.size(16.dp)
            )
        }
    }
}
