package com.notel.notel.ui.screen

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.*
import androidx.compose.ui.draw.clip
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.rounded.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.BodyLoadViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BodyLoadScreen(
    viewModel: BodyLoadViewModel = hiltViewModel(),
    onBack: () -> Unit,
    onNavigateToConnections: () -> Unit = {}
) {
    val state by viewModel.uiState.collectAsState()

    val sheetState = rememberModalBottomSheetState()
    var showTheorySheet by remember { mutableStateOf(false) }
    var showWeatherSheet by remember { mutableStateOf(false) }
    var showUvInfo by remember { mutableStateOf(false) }
    val todayStr = java.time.LocalDate.now().toString()
    val isToday = state.selectedDate == todayStr

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = "Jot",
                        fontWeight = FontWeight.Black,
                        color = NotelTextPrimary,
                        fontSize = 22.sp
                    )
                },
                navigationIcon = {},
                actions = {
                    IconButton(
                        onClick = { showWeatherSheet = true },
                        modifier = Modifier.width(64.dp)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            state.weather?.let { w ->
                                Text(
                                    text = "${w.temp}°",
                                    color = NotelTextPrimary.copy(alpha = 0.8f),
                                    fontSize = 14.sp,
                                    fontWeight = FontWeight.Bold
                                )
                            }
                            Icon(
                                imageVector = Icons.Default.Cloud,
                                contentDescription = "Weather",
                                tint = NotelPrimary.copy(alpha = 0.7f),
                                modifier = Modifier.size(20.dp)
                            )
                        }
                    }
                    IconButton(onClick = onNavigateToConnections) {
                        Icon(
                            imageVector = Icons.Default.Watch,
                            contentDescription = "Connections",
                            tint = NotelPrimary,
                            modifier = Modifier.size(24.dp)
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = NotelBackground
                )
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(bottom = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            BodyLoadCard(
                state = state,
                onDaySelected = { viewModel.selectDay(it) },
                onFactorSelected = { viewModel.selectFactor(it) },
                onResetSelection = { viewModel.selectFactor(null) },
                onShowTheory = { 
                    viewModel.markTheorySeen()
                    showTheorySheet = true 
                },
                onRefresh = { viewModel.refresh() },
                onBackToToday = { viewModel.selectDay(todayStr) },
                onLocationUpdate = { lat, lon, city ->
                    viewModel.updateLocation(lat, lon, city)
                }
            )

            if (state.error != null) {
                Spacer(Modifier.height(16.dp))
                Text(
                    state.error!!,
                    color = MaterialTheme.colorScheme.error,
                    fontSize = 12.sp,
                    modifier = Modifier.padding(horizontal = 32.dp)
                )
            }
        }
    }

    if (showTheorySheet) {
        ModalBottomSheet(
            onDismissRequest = { showTheorySheet = false },
            sheetState = sheetState,
            containerColor = NotelSurface
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(24.dp)
                    .padding(bottom = 40.dp)
            ) {
                Text(
                    text = "The Cup Theory",
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.Bold,
                    color = NotelPrimary
                )
                Spacer(Modifier.height(16.dp))
                Text(
                    text = "Think of your body's capacity as a cup. Every stressor—poor sleep, dehydration, high heart rate, or physical exertion—adds water to that cup.\n\n" +
                           "Your Body Load score is calculated using clinical biometric weighting:\n\n" +
                           "• 30% Autonomic Balance (HRV): Deviations from your 30-day RMSSD mean.\n" +
                           "• 25% Sleep Architecture: Accounting for your recent 'Sleep Debt'.\n" +
                           "• 20% Activity Stress: Your 7-day vs. 42-day workload ratio.\n" +
                           "• 15% Orthostatic Spikes: High HR events (>100bpm) that fill your cup.\n" +
                           "• 5% Heart Rate: Real-time RHR jumps from your baseline.\n" +
                           "• 5% Subjective Jots: AI context for pain, anxiety, and flares.\n\n" +
                           "When the cup is nearly empty, you feel resilient. When it's full, even a small drop can cause it to overflow, leading to symptom flares.",
                    color = NotelTextPrimary,
                    fontSize = 15.sp,
                    lineHeight = 22.sp
                )
                Spacer(Modifier.height(24.dp))
                Button(
                    onClick = { showTheorySheet = false },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary)
                ) {
                    Text("Got it")
                }
            }
        }
    }

    if (showWeatherSheet) {
        ModalBottomSheet(
            onDismissRequest = { showWeatherSheet = false },
            containerColor = NotelSurface
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 32.dp)
                    .padding(bottom = 64.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                val weather = state.weather
                if (weather != null) {
                    Text(weather.locationName, color = NotelTextPrimary, fontSize = 20.sp, fontWeight = FontWeight.Black)
                    Text(weather.condition, color = NotelTextSecondary, fontSize = 14.sp)
                    
                    Spacer(Modifier.height(32.dp))
                    
                    FlowRow(
                        modifier = Modifier.fillMaxWidth(),
                        maxItemsInEachRow = 2,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        // Temp Box
                        WeatherMetricBox(
                            icon = weather.icon,
                            value = "${weather.temp}°${weather.unit}",
                            label = "Temperature",
                            modifier = Modifier.weight(1f)
                        )
                        
                        // Humidity Box
                        WeatherMetricBox(
                            icon = "💧",
                            value = "${weather.humidity}%",
                            label = "Humidity",
                            modifier = Modifier.weight(1f)
                        )
                        
                        // Wind Box
                        WeatherMetricBox(
                            icon = "💨",
                            value = String.format("%.1f", weather.windSpeed),
                            subLabel = if (weather.unit == "F") "mph" else "km/h",
                            label = "Wind Velocity",
                            modifier = Modifier.weight(1f)
                        )
                        
                        // UV Box (Clickable)
                        Surface(
                            modifier = Modifier
                                .weight(1f)
                                .clip(RoundedCornerShape(20.dp))
                                .clickable { showUvInfo = true },
                            color = NotelSurfaceHigh.copy(alpha = 0.1f),
                            shape = RoundedCornerShape(20.dp),
                            border = BorderStroke(1.dp, Color.White.copy(alpha = 0.05f))
                        ) {
                            Column(
                                modifier = Modifier.padding(16.dp),
                                horizontalAlignment = Alignment.CenterHorizontally
                            ) {
                                Text("☀️", fontSize = 24.sp, color = if (weather.uvIndex > 5) NotelAccent else NotelTextPrimary)
                                Spacer(Modifier.height(4.dp))
                                Text(
                                    text = String.format("%.1f", weather.uvIndex),
                                    color = if (weather.uvIndex > 5) NotelAccent else NotelTextPrimary,
                                    fontSize = 18.sp,
                                    fontWeight = FontWeight.Bold
                                )
                                Text("UV Index", color = NotelTextSecondary, fontSize = 11.sp)
                                if (weather.uvIndex > 5) {
                                    Text("High Risk", color = NotelAccent, fontSize = 9.sp, fontWeight = FontWeight.Black)
                                }
                            }
                        }
                    }
                    
                    if (weather.uvIndex > 5) {
                        Spacer(Modifier.height(24.dp))
                        Surface(
                            color = NotelAccent.copy(alpha = 0.1f),
                            shape = RoundedCornerShape(12.dp),
                            border = BorderStroke(1.dp, NotelAccent.copy(alpha = 0.3f))
                        ) {
                            Row(
                                modifier = Modifier.padding(12.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Icon(Icons.Default.Warning, contentDescription = null, tint = NotelAccent, modifier = Modifier.size(16.dp))
                                Text("High UV levels detected. Consider sun protection.", color = NotelAccent, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                            }
                        }
                    }
                } else {
                    CircularProgressIndicator(color = NotelPrimary)
                    Spacer(Modifier.height(16.dp))
                    Text("Fetching local weather...", color = NotelTextSecondary, fontSize = 14.sp)
                }
            }
        }
    }

    if (showUvInfo) {
        ModalBottomSheet(
            onDismissRequest = { showUvInfo = false },
            containerColor = NotelBackground, // Dark background like screenshot
            dragHandle = { BottomSheetDefaults.DragHandle(color = Color.White.copy(alpha = 0.2f)) }
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 24.dp)
                    .padding(bottom = 64.dp)
            ) {
                Text(
                    text = "UV INDEX",
                    fontSize = 20.sp,
                    fontWeight = FontWeight.Black,
                    color = Color.White,
                    letterSpacing = 2.sp
                )
                
                Spacer(Modifier.height(24.dp))
                
                // UV Index Ranges Card
                Surface(
                    color = NotelSurface,
                    shape = RoundedCornerShape(16.dp),
                    border = BorderStroke(1.dp, Color.White.copy(alpha = 0.05f))
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Text("UV Index Ranges", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 16.sp)
                        Spacer(Modifier.height(16.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(12.dp).background(Color(0xFF66BB6A), CircleShape))
                            Spacer(Modifier.width(12.dp))
                            Text("Low", color = Color.White.copy(alpha = 0.8f), fontSize = 14.sp, modifier = Modifier.weight(1f))
                            Text("0-2", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
                        }
                        HorizontalDivider(Modifier.padding(vertical = 12.dp), color = Color.White.copy(alpha = 0.05f))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(12.dp).background(Color(0xFFFFD54F), CircleShape))
                            Spacer(Modifier.width(12.dp))
                            Text("Moderate", color = Color.White.copy(alpha = 0.8f), fontSize = 14.sp, modifier = Modifier.weight(1f))
                            Text("3-5", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
                        }
                        HorizontalDivider(Modifier.padding(vertical = 12.dp), color = Color.White.copy(alpha = 0.05f))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(12.dp).background(Color(0xFFFFB74D), CircleShape))
                            Spacer(Modifier.width(12.dp))
                            Text("High", color = Color.White.copy(alpha = 0.8f), fontSize = 14.sp, modifier = Modifier.weight(1f))
                            Text("6-7", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
                        }
                        HorizontalDivider(Modifier.padding(vertical = 12.dp), color = Color.White.copy(alpha = 0.05f))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(12.dp).background(Color(0xFFEF9A9A), CircleShape))
                            Spacer(Modifier.width(12.dp))
                            Text("Very High", color = Color.White.copy(alpha = 0.8f), fontSize = 14.sp, modifier = Modifier.weight(1f))
                            Text("8-10", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
                        }
                        HorizontalDivider(Modifier.padding(vertical = 12.dp), color = Color.White.copy(alpha = 0.05f))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(12.dp).background(Color(0xFFCE93D8), CircleShape))
                            Spacer(Modifier.width(12.dp))
                            Text("Extreme", color = Color.White.copy(alpha = 0.8f), fontSize = 14.sp, modifier = Modifier.weight(1f))
                            Text("11+", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
                        }
                    }
                }
                
                Spacer(Modifier.height(32.dp))
                
                Text("Why UV Index Matters", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                Spacer(Modifier.height(12.dp))
                Text(
                    text = "The UV Index measures the intensity of ultraviolet radiation from the sun. Excessive UV exposure causes sunburn, premature skin aging, eye damage, and significantly increases the risk of skin cancer including melanoma.\n\nUV radiation is highest between 10am and 4pm, at higher altitudes, near the equator, and during summer months. Reflection from water, sand, and snow can increase exposure.",
                    color = Color.White.copy(alpha = 0.6f),
                    fontSize = 14.sp,
                    lineHeight = 20.sp
                )
                
                Spacer(Modifier.height(24.dp))
                
                // Optimal Threshold Card
                Surface(
                    color = Color(0xFF1A1C1E),
                    shape = RoundedCornerShape(12.dp),
                    border = BorderStroke(1.dp, Color(0xFF4CAF50).copy(alpha = 0.2f))
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("🎯", fontSize = 18.sp)
                            Spacer(Modifier.width(8.dp))
                            Text("Optimal Threshold: UV Index below 3", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                        }
                        Spacer(Modifier.height(8.dp))
                        Text(
                            "For skin longevity, aim to be outside only when UV is below 3, or before 10am / after 4pm. This is the safest range for unprotected skin exposure.",
                            color = Color.White.copy(alpha = 0.5f),
                            fontSize = 12.sp,
                            lineHeight = 18.sp
                        )
                    }
                }
                
                Spacer(Modifier.height(16.dp))
                
                // Indoor UV Card
                Surface(
                    color = Color(0xFF1A1C1E),
                    shape = RoundedCornerShape(12.dp),
                    border = BorderStroke(1.dp, Color(0xFFFFB74D).copy(alpha = 0.2f))
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.Warning, contentDescription = null, tint = Color(0xFFFFB74D), modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("Indoor UV Exposure", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                        }
                        Spacer(Modifier.height(8.dp))
                        Text(
                            "Standard windows do NOT block all UV rays. UVA penetrates glass and causes skin aging. Consider UV-blocking window film, or apply sunscreen even when indoors near windows.",
                            color = Color.White.copy(alpha = 0.5f),
                            fontSize = 12.sp,
                            lineHeight = 18.sp
                        )
                    }
                }
                
                Spacer(Modifier.height(32.dp))
                
                Text("Sunscreen Guidance", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                Spacer(Modifier.height(12.dp))
                
                Surface(
                    color = NotelSurface,
                    shape = RoundedCornerShape(12.dp),
                    border = BorderStroke(1.dp, Color.White.copy(alpha = 0.05f))
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("🧴", fontSize = 18.sp)
                            Spacer(Modifier.width(8.dp))
                            Text("Mineral Sunscreen (Recommended)", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                        }
                        Spacer(Modifier.height(8.dp))
                        Text(
                            "Use mineral/physical sunscreen with zinc oxide or titanium dioxide. These sit on skin and reflect UV, avoiding chemical absorption. Look for broad-spectrum (UVA + UVB) protection, SPF 30-50+.",
                            color = Color.White.copy(alpha = 0.5f),
                            fontSize = 12.sp,
                            lineHeight = 18.sp
                        )
                    }
                }
                
                Spacer(Modifier.height(12.dp))
                
                Surface(
                    color = NotelSurface,
                    shape = RoundedCornerShape(12.dp),
                    border = BorderStroke(1.dp, Color.White.copy(alpha = 0.05f))
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("🔄", fontSize = 18.sp)
                            Spacer(Modifier.width(8.dp))
                            Text("Reapplication", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                        }
                        Spacer(Modifier.height(8.dp))
                        Text(
                            "Reapply every 2 hours, or immediately after swimming or sweating. Most people apply only 25-50% of the recommended amount.",
                            color = Color.White.copy(alpha = 0.5f),
                            fontSize = 12.sp,
                            lineHeight = 18.sp
                        )
                    }
                }
                
                Spacer(Modifier.height(32.dp))
                
                Text("Protection by Level", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                Spacer(Modifier.height(12.dp))
                
                // Risk Levels
                ProtectionLevelCard(
                    title = "Low (0-2) ✓ Safe Zone",
                    description = "Minimal risk. This is the ideal range for outdoor activities. Wear sunglasses on bright days for eye protection.",
                    color = Color(0xFF66BB6A)
                )
                Spacer(Modifier.height(12.dp))
                ProtectionLevelCard(
                    title = "Moderate (3-5)",
                    description = "Apply mineral sunscreen (SPF 30+), wear UV-blocking sunglasses and a hat. Limit midday exposure (10am-4pm).",
                    color = Color(0xFFFFD54F)
                )
                Spacer(Modifier.height(12.dp))
                ProtectionLevelCard(
                    title = "High (6-7)",
                    description = "Protection essential. Use SPF 30-50 mineral sunscreen, wear UPF clothing, wide-brim hat, and wrap-around sunglasses. Seek shade between 10am-4pm.",
                    color = Color(0xFFFFB74D)
                )
                Spacer(Modifier.height(12.dp))
                ProtectionLevelCard(
                    title = "Very High (8-10)",
                    description = "Avoid sun between 10am-4pm. Use SPF 50+ mineral sunscreen, full coverage UPF clothing, hat, and sunglasses are mandatory. Reapply sunscreen every 2 hours.",
                    color = Color(0xFFEF9A9A)
                )
                Spacer(Modifier.height(12.dp))
                ProtectionLevelCard(
                    title = "Extreme (11+)",
                    description = "Stay indoors during peak hours (10am-4pm). If outside, seek shade, wear full protective UPF clothing, SPF 50+ mineral sunscreen, and wrap-around sunglasses. Unprotected skin burns in minutes.",
                    color = Color(0xFFCE93D8)
                )
            }
        }
    }
}

@Composable
fun ProtectionLevelCard(title: String, description: String, color: Color) {
    Surface(
        color = NotelSurface,
        shape = RoundedCornerShape(12.dp),
        border = BorderStroke(1.dp, color.copy(alpha = 0.2f))
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text(title, color = color, fontWeight = FontWeight.Bold, fontSize = 14.sp)
            Spacer(Modifier.height(8.dp))
            Text(description, color = Color.White.copy(alpha = 0.5f), fontSize = 12.sp, lineHeight = 18.sp)
        }
    }
}

@Composable
fun WeatherMetricBox(
    icon: String,
    value: String,
    label: String,
    subLabel: String? = null,
    modifier: Modifier = Modifier
) {
    Surface(
        modifier = modifier,
        color = NotelSurfaceHigh.copy(alpha = 0.1f),
        shape = RoundedCornerShape(20.dp),
        border = BorderStroke(1.dp, Color.White.copy(alpha = 0.05f))
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(icon, fontSize = 24.sp)
            Spacer(Modifier.height(4.dp))
            Row(verticalAlignment = Alignment.Bottom) {
                Text(value, color = NotelTextPrimary, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                if (subLabel != null) {
                    Spacer(Modifier.width(2.dp))
                    Text(subLabel, color = NotelTextSecondary, fontSize = 10.sp, modifier = Modifier.padding(bottom = 2.dp))
                }
            }
            Text(label, color = NotelTextSecondary, fontSize = 11.sp)
        }
    }
}
