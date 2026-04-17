package com.notel.notel.ui.screen

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.*
import androidx.compose.foundation.lazy.LazyColumn
import kotlinx.coroutines.flow.collectLatest
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.CutCornerShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.*
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.drawscope.*
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.BodyLoadState
import com.notel.notel.ui.viewmodel.EventCounterDto
import kotlin.math.PI
import kotlin.math.sin

@Composable
fun BodyLoadCard(
    state: BodyLoadState,
    counters: List<EventCounterDto> = emptyList(),
    onDaySelected: (String) -> Unit = {},
    onFactorSelected: (String?) -> Unit = {},
    onResetSelection: () -> Unit = {},
    onShowTheory: () -> Unit = {},
    onRefresh: () -> Unit = {},
    onBackToToday: () -> Unit = {},
    onLocationUpdate: (Double, Double, String) -> Unit = { _, _, _ -> }
) {
    val score = state.score
    val isLoading = state.isLoading
    val todayStr = java.time.LocalDate.now().toString()
    var showDebtHistory by remember { mutableStateOf(false) }
    
    val activeCounters = counters.filter { !it.isArchived }
    val infinitePageCount = if (activeCounters.size > 1) 10000 else activeCounters.size
    val pagerState = rememberPagerState(
        initialPage = if (activeCounters.size > 1) 5000 else 0,
        pageCount = { infinitePageCount }
    )
    
    // Robust Auto-scroll logic tied to settledPage to prevent mid-transition freezes during background/foreground events
    LaunchedEffect(activeCounters.size) {
        if (activeCounters.size > 1) {
            snapshotFlow { pagerState.settledPage }.collectLatest { settledIndex ->
                kotlinx.coroutines.delay(15000)
                pagerState.animateScrollToPage(settledIndex + 1)
            }
        }
    }
    
    val context = androidx.compose.ui.platform.LocalContext.current

    // ── Location Precision Logic ──────────────────────────────────────
    val locationClient = remember {
        com.google.android.gms.location.LocationServices.getFusedLocationProviderClient(context)
    }
    
    val locationPermissionLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestMultiplePermissions()
    ) { permissions ->
        if (permissions[android.Manifest.permission.ACCESS_COARSE_LOCATION] == true ||
            permissions[android.Manifest.permission.ACCESS_FINE_LOCATION] == true) {
            
            try {
                locationClient.lastLocation.addOnSuccessListener { location ->
                    location?.let {
                        val geocoder = android.location.Geocoder(context, java.util.Locale.getDefault())
                        val addresses = geocoder.getFromLocation(it.latitude, it.longitude, 1)
                        val city = addresses?.firstOrNull()?.locality ?: "Current Location"
                        
                        onLocationUpdate(it.latitude, it.longitude, city)
                    }
                }
            } catch (e: SecurityException) {}
        }
    }

    LaunchedEffect(Unit) {
        locationPermissionLauncher.launch(
            arrayOf(
                android.Manifest.permission.ACCESS_FINE_LOCATION,
                android.Manifest.permission.ACCESS_COARSE_LOCATION
            )
        )
    }

    androidx.lifecycle.compose.LifecycleEventEffect(androidx.lifecycle.Lifecycle.Event.ON_RESUME) {
        onRefresh()
    }

    if (showDebtHistory) {
        SleepDebtHistoryDialog(
            history = state.sleepDebtHistory,
            onDismiss = { showDebtHistory = false }
        )
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 16.dp),
    ) {
        // ── Top Accent Divider ──────────────────────────────────────────
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(2.dp)
                .padding(horizontal = 24.dp)
                .background(NotelSurfaceHigh.copy(alpha = 0.2f), androidx.compose.foundation.shape.RoundedCornerShape(percent = 50))
        )
        Spacer(Modifier.height(16.dp))

        // ── Top Row: Days of the Week ──────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically, // Changed to center for better icon alignment
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                val infiniteTransition = rememberInfiniteTransition()
                val pulseColor by if (!state.cupTheorySeen) {
                    infiniteTransition.animateColor(
                        initialValue = NotelTextPrimary,
                        targetValue = Color(0xFFB388FF), // Light Violet/Purple pulse
                        animationSpec = infiniteRepeatable(
                            animation = tween(1200, easing = FastOutSlowInEasing),
                            repeatMode = RepeatMode.Reverse
                        )
                    )
                } else {
                    remember { mutableStateOf(NotelTextPrimary) }
                }

                Text(
                    "Score",
                    fontWeight = FontWeight.Black,
                    fontSize = 14.sp,
                    color = pulseColor,
                    modifier = Modifier.clickable { onShowTheory() }
                )
            }
            
            val isTodayActual = state.selectedDate == java.time.LocalDate.now().toString()
            if (!isTodayActual) {
                IconButton(
                    onClick = onBackToToday,
                    modifier = Modifier.size(32.dp) // Made it bigger
                ) {
                    Icon(
                        Icons.Default.DateRange,
                        contentDescription = "Back to Today",
                        tint = NotelPrimary,
                        modifier = Modifier.size(20.dp) // Icon itself is bigger
                    )
                }
            }
        }
        
        Spacer(Modifier.height(2.dp))

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 2.dp), // Tightened vertical padding
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            // Generate last 7 days
            val last7Days = (0..6).map { 
                val d = java.time.LocalDate.now().minusDays(it.toLong())
                d.toString() to d.format(java.time.format.DateTimeFormatter.ofPattern("EEE"))
            }.reversed()

            last7Days.forEach { (dateStr, dayLabel) ->
                val historicalScore = state.historyScores.find { it.date == dateStr }?.score ?: 0
                val isSelected = state.selectedDate == dateStr
                val isTodayActual = state.selectedDate == java.time.LocalDate.now().toString()
                
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.width(38.dp).clickable { onDaySelected(dateStr) }
                ) {
                    Text(dayLabel, color = NotelTextSecondary, fontSize = 12.sp, modifier = Modifier.padding(bottom = 6.dp))
                    Box(
                        modifier = Modifier
                            .size(38.dp)
                            .border(
                                width = if (isSelected) 2.dp else 1.dp,
                                brush = if (isSelected) Brush.linearGradient(listOf(NotelPrimary, NotelAccent)) else SolidColor(NotelSurfaceHigh.copy(alpha = 0.5f)),
                                shape = CircleShape
                            ),
                        contentAlignment = Alignment.Center
                     ) {
                        Text(
                            text = if (historicalScore > 0) historicalScore.toString() else "-",
                            color = if (isSelected) NotelTextPrimary else NotelTextSecondary,
                            fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal,
                            fontSize = 13.sp
                        )
                    }
                }
            }
        }

        Spacer(Modifier.height(16.dp))

        Box(modifier = Modifier.fillMaxWidth()) {
            Surface(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                shape = RoundedCornerShape(12.dp),
                color = Color.Black.copy(alpha = 0.3f),
                border = BorderStroke(1.dp, Color.White.copy(alpha = 0.1f))
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(12.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    // Left: Main Score (Replaces Fitbit Logo)
                    val infiniteTransition = rememberInfiniteTransition()
                    val rotation by infiniteTransition.animateFloat(
                        initialValue = 0f,
                        targetValue = 360f,
                        animationSpec = infiniteRepeatable(
                            animation = tween(15000, easing = LinearEasing),
                            repeatMode = RepeatMode.Restart
                        )
                    )

                    Box(
                        modifier = Modifier
                            .size(48.dp)
                            .background(NotelSurfaceHigh.copy(alpha = 0.1f), RoundedCornerShape(8.dp)),
                        contentAlignment = Alignment.Center
                    ) {
                        Canvas(modifier = Modifier.fillMaxSize()) {
                            val strokeWidth = 2.dp.toPx()
                            val colors = listOf(Color(0xFFFF5252), Color(0xFF42A5F5), Color(0xFF7C6EFF), Color(0xFFFF5252))
                            
                            val outerPath = Path().apply {
                                addRoundRect(RoundRect(Rect(Offset.Zero, size), CornerRadius(8.dp.toPx())))
                            }
                            val innerPath = Path().apply {
                                addRoundRect(RoundRect(Rect(strokeWidth, strokeWidth, size.width - strokeWidth, size.height - strokeWidth), CornerRadius((8.dp.toPx() - strokeWidth).coerceAtLeast(0f))))
                            }

                            clipPath(outerPath) {
                                clipPath(innerPath, clipOp = ClipOp.Difference) {
                                    rotate(rotation) {
                                        drawRect(
                                            brush = Brush.sweepGradient(colors),
                                            size = size * 2f,
                                            topLeft = Offset(-size.width / 2f, -size.height / 2f)
                                        )
                                    }
                                }
                            }
                        }

                        if (isLoading) {
                            CircularProgressIndicator(color = NotelPrimary, strokeWidth = 1.dp, modifier = Modifier.size(20.dp))
                        } else {
                            Text(
                                text = if (score > 0) score.toString() else "-",
                                fontSize = 18.sp,
                                fontWeight = FontWeight.Black,
                                color = NotelTextPrimary
                            )
                        }
                    }
                    
                    VerticalDivider(modifier = Modifier.height(32.dp).padding(horizontal = 4.dp), color = Color.White.copy(alpha = 0.1f))

                    // Center Metrics Group
                    if (state.isHealthConnected) {
                        Row(
                            modifier = Modifier.weight(1f).padding(horizontal = 8.dp),
                            horizontalArrangement = Arrangement.SpaceEvenly,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            // Calories
                            MetricItem(
                                icon = Icons.Default.Whatshot,
                                value = "${state.activeCalories}",
                                color = Color(0xFFFF5252)
                            )

                            VerticalDivider(modifier = Modifier.height(20.dp), color = Color.White.copy(alpha = 0.1f))

                            // Jots
                            MetricItem(
                                icon = Icons.Default.Edit,
                                value = "${state.jotCountDaily}",
                                color = Color(0xFF66BB6A)
                            )

                            VerticalDivider(modifier = Modifier.height(20.dp), color = Color.White.copy(alpha = 0.1f))

                            // Sleep + Debt Unified Group
                            Column(
                                horizontalAlignment = Alignment.CenterHorizontally,
                                modifier = Modifier.clickable { showDebtHistory = true }
                            ) {
                                MetricItem(
                                    icon = Icons.Default.Nightlight,
                                    value = formatSleep(state.sleepMinutes),
                                    color = Color(0xFF42A5F5)
                                )
                                
                                val debtMins = state.sleepDebtMins
                                if (!isLoading) {
                                    val isDeficit = debtMins < 0
                                    val h = Math.abs(debtMins) / 60
                                    val m = Math.abs(debtMins) % 60
                                    val dStr = if (isDeficit) "-${h}h ${m}m" else "+${h}h ${m}m"
                                    val bColor = if (!isDeficit) Color(0xFF66BB6A) else if (Math.abs(debtMins) > 600) Color(0xFFFF5252) else Color(0xFFFFB74D)

                                    Text(
                                        text = dStr,
                                        color = bColor,
                                        fontSize = 9.sp,
                                        fontWeight = FontWeight.Bold,
                                        modifier = Modifier.offset(y = (-2).dp)
                                    )
                                }
                            }
                        }
                    } else {
                        Box(
                            modifier = Modifier.weight(1f).padding(horizontal = 16.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            Text(
                                "Connect Health to see data",
                                color = NotelTextSecondary,
                                fontSize = 12.sp,
                                textAlign = TextAlign.Center,
                                fontWeight = FontWeight.Medium
                            )
                        }
                    }
                }
            }

            // Small Sync Button in bottom right corner of the rectangle
            // Small Sync Button ALWAYS visible
            IconButton(
                onClick = onRefresh,
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(end = 16.dp, bottom = 9.dp)
                    .size(28.dp),
                enabled = !isLoading
            ) {
                Icon(
                    imageVector = Icons.Default.Refresh,
                    contentDescription = "Sync",
                    tint = NotelPrimary.copy(alpha = 0.7f),
                    modifier = Modifier.size(16.dp)
                )
            }
        }
        
        // Streak Tiles (Left-Aligned under Main Score)
        // Streak Tiles & Counters Hub
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp)
                .offset(y = (-4).dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                // Current Streak Square
                Surface(
                    modifier = Modifier.size(34.dp),
                    shape = RoundedCornerShape(8.dp),
                    color = NotelSurfaceHigh.copy(alpha = 0.1f),
                    border = BorderStroke(1.dp, Color.White.copy(alpha = 0.05f))
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Text("🔥${state.currentStreak}", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = Color(0xFFFFB74D))
                    }
                }

                // Best Streak Square
                Surface(
                    modifier = Modifier.size(34.dp),
                    shape = RoundedCornerShape(8.dp),
                    color = NotelSurfaceHigh.copy(alpha = 0.1f),
                    border = BorderStroke(1.dp, Color.White.copy(alpha = 0.05f))
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Text("🏆${state.bestStreak}", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = Color(0xFFFFD700))
                    }
                }
            }

            if (activeCounters.isNotEmpty()) {
                Column(
                    modifier = Modifier.weight(1f).padding(start = 16.dp),
                    horizontalAlignment = Alignment.End
                ) {
                    HorizontalPager(
                        state = pagerState,
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically
                    ) { page ->
                        val counterIndex = page % activeCounters.size
                        val counter = activeCounters[counterIndex]
                        
                        // Logic to calculate days remaining/since
                        val targetLocalDate = java.time.Instant.ofEpochMilli(counter.targetDate)
                            .atZone(java.time.ZoneId.systemDefault())
                            .toLocalDate()
                        val today = java.time.LocalDate.now()
                        
                        val diffDays = java.time.temporal.ChronoUnit.DAYS.between(targetLocalDate, today)
                        var isCalculatedUp = counter.isUp
                        var finalDays = diffDays
                        
                        if (!isCalculatedUp && diffDays > 0 && counter.autoUp) {
                            isCalculatedUp = true
                            finalDays = diffDays
                        } else if (isCalculatedUp) {
                            finalDays = diffDays
                        } else {
                            finalDays = -diffDays // "Until" (negative diff means target is in future)
                        }
                        
                        val daysCount = Math.max(0L, finalDays).toString()

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.End
                        ) {
                            Text(
                                text = if (isCalculatedUp) "SINCE ${counter.name.uppercase()}" else "UNTIL ${counter.name.uppercase()}",
                                fontSize = 8.sp,
                                fontWeight = FontWeight.Black,
                                color = NotelPrimary.copy(alpha = 0.6f),
                                letterSpacing = 0.5.sp,
                                maxLines = 1,
                                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f).padding(end = 6.dp),
                                textAlign = TextAlign.End
                            )
                            
                            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(
                                        text = daysCount,
                                        fontSize = 14.sp,
                                        fontWeight = FontWeight.Black,
                                        color = NotelTextPrimary,
                                        modifier = Modifier.padding(end = 2.dp)
                                    )
                                    
                                    Text(
                                        text = "DAYS",
                                        fontSize = 8.sp,
                                        fontWeight = FontWeight.Bold,
                                        color = NotelTextSecondary,
                                        letterSpacing = 0.5.sp
                                    )
                                }
                                
                                // Indicator Dots under the number
                                if (activeCounters.size > 1) {
                                    Row(
                                        modifier = Modifier.padding(top = 2.dp),
                                        horizontalArrangement = Arrangement.spacedBy(3.dp),
                                        verticalAlignment = Alignment.CenterVertically
                                    ) {
                                        repeat(activeCounters.size) { iteration ->
                                            val isCurrent = (pagerState.currentPage % activeCounters.size) == iteration
                                            val color = if (isCurrent) NotelPrimary else NotelSurfaceHigh.copy(alpha = 0.3f)
                                            Box(
                                                modifier = Modifier
                                                    .size(if (isCurrent) 4.dp else 3.dp)
                                                    .background(color, CircleShape)
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                Spacer(Modifier.weight(1f))
            }
        }
            

        

    }
}

@Composable
fun MetricItem(
    icon: ImageVector,
    value: String,
    color: Color
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = color, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(4.dp))
        Text(value, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
fun SmallPillarNode(
    icon: ImageVector,
    value: String,
    label: String,
    progress: Float,
    color: Color
) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.width(38.dp)) {
        Box(
            modifier = Modifier
                .size(38.dp)
                .background(NotelSurface, CircleShape)
                .border(1.5.dp, NotelSurfaceHigh.copy(alpha = 0.2f), CircleShape),
            contentAlignment = Alignment.Center
        ) {
            Canvas(modifier = Modifier.fillMaxSize().padding(2.dp)) {
                drawArc(
                    color = color,
                    startAngle = -90f,
                    sweepAngle = 360f * progress,
                    useCenter = false,
                    style = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round)
                )
            }
            Icon(icon, null, tint = color, modifier = Modifier.size(16.dp))
        }
        Spacer(Modifier.height(4.dp))
        Text(value, color = NotelTextPrimary, fontWeight = FontWeight.Bold, fontSize = 12.sp)
        Text(label, color = NotelTextSecondary, fontSize = 7.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
fun PillarNode(
    modifier: Modifier = Modifier,
    icon: ImageVector,
    value: String,
    target: String,
    label: String,
    progress: Float,
    color: Color
) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = modifier.width(80.dp)) {
        Box(
            modifier = Modifier
                .size(54.dp)
                .background(NotelSurface, CircleShape)
                .border(2.dp, NotelSurfaceHigh.copy(alpha = 0.3f), CircleShape),
            contentAlignment = Alignment.Center
        ) {
            // Circular Progress
            Canvas(modifier = Modifier.fillMaxSize().padding(2.dp)) {
                drawArc(
                    color = color,
                    startAngle = -90f,
                    sweepAngle = 360f * progress,
                    useCenter = false,
                    style = Stroke(width = 3.dp.toPx(), cap = StrokeCap.Round)
                )
            }
            Icon(icon, null, tint = color, modifier = Modifier.size(20.dp))
        }
        Spacer(Modifier.height(8.dp))
        Row(verticalAlignment = Alignment.Bottom) {
            Text(value, color = NotelTextPrimary, fontWeight = FontWeight.Bold, fontSize = 14.sp)
            if (target.isNotEmpty()) {
                Text("/$target", color = NotelTextSecondary, fontSize = 10.sp, modifier = Modifier.padding(bottom = 1.dp))
            }
        }
        Text(label, color = NotelTextSecondary, fontSize = 8.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
    }
}

private fun formatSleep(mins: Int): String {
    val h = mins / 60
    val m = mins % 60
    return if (h > 0) "${h}h${m}m" else "${m}m"
}

private fun getFactorColor(name: String): Color {
    val lowName = name.lowercase()
    return when {
        lowName.contains("hrv") || lowName.contains("ready") -> Color(0xFF4DB6AC) // Teal/Mint for HRV
        lowName.contains("cal") || lowName.contains("activity") || lowName.contains("exercise") -> Color(0xFFFF5252) // Red
        lowName.contains("sleep") || lowName.contains("rest") -> Color(0xFF42A5F5) // Blue
        lowName.contains("jot") || lowName.contains("note") -> Color(0xFF7C6EFF) // Purple
        lowName.contains("cardio") || lowName.contains("pots") || lowName.contains("hr") || lowName.contains("spike") -> Color(0xFF7C6EFF) // Purple
        lowName.contains("mcas") || lowName.contains("histamine") || lowName.contains("allergy") -> Color(0xFFFFB74D) // Orange
        else -> NotelPrimary
    }
}
@Composable
fun SleepDebtHistoryDialog(
    history: List<Triple<String, Double, Double>>,
    onDismiss: () -> Unit
) {
    androidx.compose.ui.window.Dialog(onDismissRequest = onDismiss) {
        Surface(
            modifier = Modifier
                .fillMaxWidth(0.9f)
                .fillMaxHeight(0.7f),
            shape = RoundedCornerShape(16.dp),
            color = NotelBackground
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(16.dp)
            ) {
                val oldestDate = history.firstOrNull()?.first ?: "N/A"
                Text(
                    text = "Sleep Debt",
                    style = MaterialTheme.typography.titleLarge,
                    color = Color.White
                )
                Text(
                    text = "Target: 8h",
                    style = MaterialTheme.typography.bodySmall,
                    color = Color.Gray
                )
                Text(
                    text = "History from $oldestDate",
                    style = MaterialTheme.typography.bodySmall,
                    color = Color.Gray,
                    modifier = Modifier.padding(bottom = 16.dp)
                )
                
                LazyColumn(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    items(history.reversed()) { triple ->
                        val (date, delta, balanceHours) = triple
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .liquidGlass(shape = RoundedCornerShape(8.dp), alpha = 0.1f)
                                .padding(12.dp),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column {
                                Text(date, color = Color.Gray, fontSize = 10.sp)
                                val isSurplus = balanceHours >= 0
                                val balanceColor = if (isSurplus) Color(0xFF66BB6A) else Color(0xFFFF5252)
                                val h = Math.abs(balanceHours).toInt()
                                val m = ((Math.abs(balanceHours) - h) * 60).toInt()
                                val balanceStr = (if (isSurplus) "+" else "-") + "${h}h ${m}m"
                                
                                Text(
                                    text = if (isSurplus) "$balanceStr Surplus" else "$balanceStr Deficit",
                                    color = balanceColor,
                                    fontSize = 14.sp,
                                    fontWeight = FontWeight.Bold
                                )
                                Text(
                                    text = "Total Bank",
                                    color = Color.Gray,
                                    fontSize = 9.sp
                                )
                            }
                            
                            // Daily Delta on the right
                            Column(horizontalAlignment = Alignment.End) {
                                val isPosDelta = delta >= 0
                                val deltaColor = if (isPosDelta) Color(0xFF66BB6A).copy(alpha = 0.8f) else Color(0xFFFFB74D).copy(alpha = 0.8f)
                                val dh = Math.abs(delta).toInt()
                                val dm = ((Math.abs(delta) - dh) * 60).toInt()
                                val deltaStr = (if (isPosDelta) "+" else "-") + "${dh}h ${dm}m"
                                
                                Text(
                                    text = deltaStr,
                                    color = deltaColor,
                                    fontSize = 13.sp,
                                    fontWeight = FontWeight.Medium
                                )
                                Text(
                                    text = "Daily Impact",
                                    color = Color.Gray,
                                    fontSize = 9.sp
                                )
                            }
                        }
                    }
                }
                
                Button(
                    onClick = onDismiss,
                    modifier = Modifier.align(Alignment.End).padding(top = 16.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = Color.White.copy(alpha = 0.1f))
                ) {
                    Text("Close", color = Color.White)
                }
            }
        }
    }
}
