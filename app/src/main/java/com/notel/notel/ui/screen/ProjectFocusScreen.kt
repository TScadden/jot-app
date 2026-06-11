package com.notel.notel.ui.screen

import android.content.Intent
import android.net.Uri
import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.*
import androidx.compose.ui.graphics.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.ProjectFocusViewModel
import kotlin.math.ceil

@Composable
fun BlobBackground() {
    val infiniteTransition = rememberInfiniteTransition(label = "goo_liquid")

    val phase1 by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = 2f * Math.PI.toFloat(),
        animationSpec = infiniteRepeatable(
            animation = tween(25000, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "phase1"
    )

    val phase2 by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = -2f * Math.PI.toFloat(),
        animationSpec = infiniteRepeatable(
            animation = tween(30000, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "phase2"
    )

    val phase3 by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = 2f * Math.PI.toFloat(),
        animationSpec = infiniteRepeatable(
            animation = tween(35000, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "phase3"
    )

    val phase4 by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = -2f * Math.PI.toFloat(),
        animationSpec = infiniteRepeatable(
            animation = tween(40000, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "phase4"
    )

    androidx.compose.foundation.Canvas(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFF0A0A0E))
            .blur(60.dp)
    ) {
        val width = size.width
        val height = size.height

        // 1. Violet Goo Layer (Back) - flows slowly
        val path1 = Path().apply {
            moveTo(0f, height)
            val baseHeight = height * 0.25f
            val amplitude = 90f
            for (x in 0..width.toInt() step 6) {
                val xFloat = x.toFloat()
                val y = baseHeight + amplitude * kotlin.math.sin((xFloat / width * 2f * Math.PI.toFloat()) + phase1)
                lineTo(xFloat, y)
            }
            lineTo(width, height)
            close()
        }
        drawPath(
            path = path1,
            brush = Brush.verticalGradient(
                colors = listOf(Color(0xFF9C27B0).copy(alpha = 0.50f), Color.Transparent)
            )
        )

        // 2. Cyan Goo Layer - flows opposite direction
        val path2 = Path().apply {
            moveTo(0f, height)
            val baseHeight = height * 0.40f
            val amplitude = 110f
            for (x in 0..width.toInt() step 6) {
                val xFloat = x.toFloat()
                val y = baseHeight + amplitude * kotlin.math.sin((xFloat / width * 1.5f * Math.PI.toFloat()) + phase2)
                lineTo(xFloat, y)
            }
            lineTo(width, height)
            close()
        }
        drawPath(
            path = path2,
            brush = Brush.verticalGradient(
                colors = listOf(Color(0xFF00BCD4).copy(alpha = 0.45f), Color.Transparent)
            )
        )

        // 3. Orange Goo Layer
        val path3 = Path().apply {
            moveTo(0f, height)
            val baseHeight = height * 0.55f
            val amplitude = 100f
            for (x in 0..width.toInt() step 6) {
                val xFloat = x.toFloat()
                val y = baseHeight + amplitude * kotlin.math.sin((xFloat / width * 2.5f * Math.PI.toFloat()) + phase3)
                lineTo(xFloat, y)
            }
            lineTo(width, height)
            close()
        }
        drawPath(
            path = path3,
            brush = Brush.verticalGradient(
                colors = listOf(Color(0xFFFF7E6E).copy(alpha = 0.42f), Color.Transparent)
            )
        )

        // 4. Purple Goo Layer (Front)
        val path4 = Path().apply {
            moveTo(0f, height)
            val baseHeight = height * 0.68f
            val amplitude = 120f
            for (x in 0..width.toInt() step 6) {
                val xFloat = x.toFloat()
                val y = baseHeight + amplitude * kotlin.math.sin((xFloat / width * 1.8f * Math.PI.toFloat()) + phase4)
                lineTo(xFloat, y)
            }
            lineTo(width, height)
            close()
        }
        drawPath(
            path = path4,
            brush = Brush.verticalGradient(
                colors = listOf(Color(0xFF7C6EFF).copy(alpha = 0.55f), Color.Transparent)
            )
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProjectFocusScreen(
    onBack: () -> Unit,
    viewModel: ProjectFocusViewModel = hiltViewModel()
) {
    val uiState by viewModel.uiState.collectAsState()
    val context = LocalContext.current

    LaunchedEffect(Unit) {
        viewModel.syncFromServer()
    }

    Box(modifier = Modifier.fillMaxSize()) {
        BlobBackground()

        Scaffold(
            containerColor = Color.Transparent,
            topBar = {
                TopAppBar(
                    title = {
                        Text(
                            "Project Focus",
                            style = MaterialTheme.typography.titleLarge,
                            fontWeight = FontWeight.Bold,
                            color = NotelTextPrimary
                        )
                    },
                    navigationIcon = {
                        IconButton(onClick = onBack) {
                            Icon(
                                Icons.AutoMirrored.Filled.ArrowBack,
                                contentDescription = "Back",
                                tint = NotelTextPrimary
                            )
                        }
                    },
                    actions = {
                        if (uiState.activeTest != null && uiState.currentSubView == "details") {
                            TextButton(
                                onClick = { viewModel.setSubView("input") }
                            ) {
                                Text(
                                    text = "Create Project",
                                    color = NotelPrimary,
                                    fontWeight = FontWeight.Bold,
                                    fontSize = 14.sp
                                )
                            }
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent)
                )
            }
        ) { padding ->
            when {
                uiState.isLoading -> {
                    Box(
                        modifier = Modifier.fillMaxSize().padding(padding),
                        contentAlignment = Alignment.Center
                    ) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            CircularProgressIndicator(color = NotelPrimary, modifier = Modifier.size(36.dp))
                            Spacer(Modifier.height(16.dp))
                            Text("Syncing your projects…", color = NotelTextSecondary, fontSize = 14.sp)
                        }
                    }
                }
                uiState.activeTest == null || uiState.currentSubView in listOf("input", "suggestions", "setup", "splash") -> {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(padding)
                            .padding(horizontal = 20.dp, vertical = 10.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        // Glassmorphic Card Container centered
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .offset(y = (-40).dp)
                                .clip(RoundedCornerShape(28.dp))
                                .background(Color(0x590A0A0E))
                                .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(28.dp))
                                .padding(24.dp)
                        ) {
                            when (uiState.currentSubView) {
                                "suggestions" -> {
                                    Column(
                                        modifier = Modifier.fillMaxWidth(),
                                        horizontalAlignment = Alignment.CenterHorizontally
                                    ) {
                                        Text(
                                            text = "Select a Test",
                                            color = NotelTextPrimary,
                                            fontSize = 22.sp,
                                            fontWeight = FontWeight.Bold
                                        )
                                        Spacer(Modifier.height(6.dp))
                                        Text(
                                            text = "Pick one of the weekly tests compiled from your struggle to begin:",
                                            color = NotelTextSecondary,
                                            fontSize = 13.sp,
                                            textAlign = TextAlign.Center
                                        )
                                        Spacer(Modifier.height(16.dp))
                                        
                                        // Hardcap height for suggestion list so it fits nicely on smaller screens
                                        Box(modifier = Modifier.heightIn(max = 280.dp)) {
                                            LazyColumn(
                                                verticalArrangement = Arrangement.spacedBy(12.dp)
                                            ) {
                                                items(uiState.suggestions.size) { idx ->
                                                    val s = uiState.suggestions[idx]
                                                    Surface(
                                                        onClick = { viewModel.selectSuggestion(s) },
                                                        shape = RoundedCornerShape(20.dp),
                                                        color = Color.White.copy(alpha = 0.03f),
                                                        border = BorderStroke(1.dp, Color.White.copy(alpha = 0.08f)),
                                                        modifier = Modifier.fillMaxWidth()
                                                    ) {
                                                        Column(modifier = Modifier.padding(16.dp)) {
                                                            Text(s.title, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 15.sp)
                                                            Spacer(Modifier.height(4.dp))
                                                            Text(s.desc, color = NotelTextSecondary, fontSize = 12.sp, lineHeight = 16.sp)
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                        
                                        Spacer(Modifier.height(16.dp))
                                        Button(
                                            onClick = { viewModel.setSubView("input") },
                                            colors = ButtonDefaults.buttonColors(containerColor = Color.White.copy(alpha = 0.08f)),
                                            shape = RoundedCornerShape(16.dp),
                                            modifier = Modifier.fillMaxWidth()
                                        ) {
                                            Text("Back", color = Color.White)
                                        }
                                    }
                                }
                                "setup" -> {
                                    val selected = uiState.selectedSuggestion
                                    if (selected != null) {
                                        Column(
                                            modifier = Modifier.fillMaxWidth(),
                                            horizontalAlignment = Alignment.CenterHorizontally
                                        ) {
                                            Text(
                                                "Test Duration",
                                                color = NotelTextPrimary,
                                                fontSize = 22.sp,
                                                fontWeight = FontWeight.Bold
                                            )
                                            Spacer(Modifier.height(16.dp))
                                            Text(
                                                selected.title,
                                                color = NotelPrimary,
                                                fontSize = 18.sp,
                                                fontWeight = FontWeight.Bold,
                                                textAlign = TextAlign.Center
                                            )
                                            Spacer(Modifier.height(8.dp))
                                            Text(
                                                selected.desc,
                                                color = NotelTextSecondary,
                                                fontSize = 13.sp,
                                                textAlign = TextAlign.Center,
                                                lineHeight = 18.sp
                                            )
                                            Spacer(Modifier.height(28.dp))
                                            
                                            // Setup controls styled exactly like website buttons
                                            Row(
                                                verticalAlignment = Alignment.CenterVertically,
                                                horizontalArrangement = Arrangement.spacedBy(12.dp)
                                            ) {
                                                Button(
                                                    onClick = { viewModel.changeDuration(false) },
                                                    colors = ButtonDefaults.buttonColors(containerColor = Color.White.copy(alpha = 0.05f)),
                                                    border = BorderStroke(1.dp, Color.White.copy(alpha = 0.08f)),
                                                    shape = RoundedCornerShape(12.dp),
                                                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp)
                                                ) {
                                                    Text("- Remove Day", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                                                }
                                                
                                                Text(
                                                    "${uiState.setupDuration} Days",
                                                    color = Color.White,
                                                    fontSize = 20.sp,
                                                    fontWeight = FontWeight.Black
                                                )
                                                
                                                Button(
                                                    onClick = { viewModel.changeDuration(true) },
                                                    colors = ButtonDefaults.buttonColors(containerColor = Color.White.copy(alpha = 0.05f)),
                                                    border = BorderStroke(1.dp, Color.White.copy(alpha = 0.08f)),
                                                    shape = RoundedCornerShape(12.dp),
                                                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp)
                                                ) {
                                                    Text("+ Add Day", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                                                }
                                            }
                                            
                                            Spacer(Modifier.height(24.dp))
                                            Text(
                                                "Start Date",
                                                color = NotelTextSecondary,
                                                fontSize = 12.sp,
                                                fontWeight = FontWeight.Bold
                                            )
                                            Spacer(Modifier.height(8.dp))
                                            Row(
                                                horizontalArrangement = Arrangement.spacedBy(12.dp)
                                            ) {
                                                Surface(
                                                    onClick = { viewModel.setStartTomorrow(false) },
                                                    shape = RoundedCornerShape(12.dp),
                                                    color = if (!uiState.startTomorrow) NotelPrimary.copy(alpha = 0.2f) else Color.White.copy(alpha = 0.03f),
                                                    border = BorderStroke(1.dp, if (!uiState.startTomorrow) NotelPrimary else Color.White.copy(alpha = 0.08f)),
                                                    modifier = Modifier.weight(1f)
                                                ) {
                                                    Text(
                                                        text = "Today",
                                                        color = if (!uiState.startTomorrow) NotelPrimary else Color.White,
                                                        fontWeight = FontWeight.Bold,
                                                        fontSize = 13.sp,
                                                        modifier = Modifier.padding(vertical = 10.dp),
                                                        textAlign = TextAlign.Center
                                                    )
                                                }
                                                Surface(
                                                    onClick = { viewModel.setStartTomorrow(true) },
                                                    shape = RoundedCornerShape(12.dp),
                                                    color = if (uiState.startTomorrow) NotelPrimary.copy(alpha = 0.2f) else Color.White.copy(alpha = 0.03f),
                                                    border = BorderStroke(1.dp, if (uiState.startTomorrow) NotelPrimary else Color.White.copy(alpha = 0.08f)),
                                                    modifier = Modifier.weight(1f)
                                                ) {
                                                    Text(
                                                        text = "Tomorrow",
                                                        color = if (uiState.startTomorrow) NotelPrimary else Color.White,
                                                        fontWeight = FontWeight.Bold,
                                                        fontSize = 13.sp,
                                                        modifier = Modifier.padding(vertical = 10.dp),
                                                        textAlign = TextAlign.Center
                                                    )
                                                }
                                            }

                                            Spacer(Modifier.height(32.dp))
                                            Row(
                                                modifier = Modifier.fillMaxWidth(),
                                                horizontalArrangement = Arrangement.spacedBy(12.dp)
                                            ) {
                                                Button(
                                                    onClick = { viewModel.setSubView("suggestions") },
                                                    colors = ButtonDefaults.buttonColors(containerColor = Color.White.copy(alpha = 0.08f)),
                                                    shape = RoundedCornerShape(16.dp),
                                                    modifier = Modifier.weight(1f)
                                                ) {
                                                    Text("Back", color = Color.White)
                                                }
                                                Button(
                                                    onClick = { viewModel.lockInProject() },
                                                    colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary),
                                                    shape = RoundedCornerShape(16.dp),
                                                    modifier = Modifier.weight(1f)
                                                ) {
                                                    Text("Lock it In", color = Color.White)
                                                }
                                            }
                                        }
                                    }
                                }
                                "splash" -> {
                                    LaunchedEffect(Unit) {
                                        kotlinx.coroutines.delay(2000)
                                        viewModel.setSubView("details")
                                    }
                                    Column(
                                        modifier = Modifier.fillMaxWidth(),
                                        horizontalAlignment = Alignment.CenterHorizontally,
                                        verticalArrangement = Arrangement.Center
                                    ) {
                                        Text("🔒", fontSize = 64.sp)
                                        Spacer(Modifier.height(16.dp))
                                        Text(
                                            "Test Locked In!",
                                            color = Color.White,
                                            fontSize = 24.sp,
                                            fontWeight = FontWeight.Black
                                        )
                                        Spacer(Modifier.height(8.dp))
                                        Text(
                                            "Your wellness experiment has been synced. Let's get to work!",
                                            color = NotelTextSecondary,
                                            fontSize = 14.sp,
                                            textAlign = TextAlign.Center,
                                            lineHeight = 20.sp
                                        )
                                    }
                                }
                                else -> {
                                    var struggleText by remember { mutableStateOf("") }
                                    Column(
                                        modifier = Modifier.fillMaxWidth(),
                                        horizontalAlignment = Alignment.CenterHorizontally,
                                        verticalArrangement = Arrangement.Center
                                    ) {
                                        Text(
                                            "Project Focus",
                                            color = NotelTextPrimary,
                                            fontSize = 24.sp,
                                            fontWeight = FontWeight.Black
                                        )
                                        Spacer(Modifier.height(6.dp))
                                        Text(
                                            "What are you trying to work towards?",
                                            color = NotelTextSecondary,
                                            fontSize = 14.sp,
                                            textAlign = TextAlign.Center
                                        )
                                        Spacer(Modifier.height(24.dp))
                                        
                                        // Glassmorphic Text Box exactly matching website's focus-input-wrapper
                                        Box(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .background(Color.White.copy(alpha = 0.03f), RoundedCornerShape(18.dp))
                                                .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(18.dp))
                                                .padding(horizontal = 16.dp, vertical = 12.dp)
                                        ) {
                                            androidx.compose.foundation.text.BasicTextField(
                                                value = struggleText,
                                                onValueChange = { struggleText = it },
                                                textStyle = LocalTextStyle.current.copy(color = Color.White, fontSize = 15.sp),
                                                modifier = Modifier
                                                    .fillMaxWidth()
                                                    .padding(end = 44.dp)
                                                    .heightIn(min = 60.dp, max = 150.dp),
                                                decorationBox = { innerTextField ->
                                                    if (struggleText.isEmpty()) {
                                                        Text(
                                                            text = "Type something you are struggling with (e.g., sleep, stress)...",
                                                            color = NotelTextSecondary.copy(alpha = 0.5f),
                                                            fontSize = 14.sp
                                                        )
                                                    }
                                                    innerTextField()
                                                }
                                            )
                                            
                                            IconButton(
                                                onClick = { viewModel.submitStruggle(struggleText) },
                                                modifier = Modifier
                                                    .align(Alignment.BottomEnd)
                                                    .size(36.dp)
                                                    .background(NotelPrimary, RoundedCornerShape(12.dp)),
                                                enabled = struggleText.isNotBlank() && !uiState.isSuggestionsLoading
                                            ) {
                                                if (uiState.isSuggestionsLoading) {
                                                    CircularProgressIndicator(color = Color.White, modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                                                } else {
                                                    Icon(
                                                        imageVector = Icons.Default.Send,
                                                        contentDescription = "Send",
                                                        tint = Color.White,
                                                        modifier = Modifier.size(16.dp)
                                                    )
                                                }
                                            }
                                        }
                                        
                                        uiState.error?.let { err ->
                                            Spacer(Modifier.height(12.dp))
                                            Text(err, color = MaterialTheme.colorScheme.error, fontSize = 12.sp, textAlign = TextAlign.Center)
                                        }

                                        if (uiState.activeTests.isNotEmpty()) {
                                            Spacer(Modifier.height(16.dp))
                                            Button(
                                                onClick = { viewModel.setSubView("details") },
                                                colors = ButtonDefaults.buttonColors(containerColor = Color.White.copy(alpha = 0.08f)),
                                                shape = RoundedCornerShape(16.dp),
                                                modifier = Modifier.fillMaxWidth()
                                            ) {
                                                Text("Cancel", color = Color.White)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                else -> {
                val test = uiState.activeTest!!
                val startMs = test.startTimestamp
                val durationMs = test.durationDays.toLong() * 24L * 60L * 60L * 1000L
                val elapsedMs = System.currentTimeMillis() - startMs
                val leftMs = if (elapsedMs < 0L) durationMs else maxOf(0L, durationMs - elapsedMs)
                val isCompleted = leftMs <= 0L
                val daysLeft = if (elapsedMs < 0L) test.durationDays else ceil(leftMs / (24.0 * 60.0 * 60.0 * 1000.0)).toInt()
                val daysElapsed = if (elapsedMs < 0L) 0 else minOf(
                    test.durationDays,
                    (elapsedMs / (24L * 60L * 60L * 1000L)).toInt() + 1
                )
                val todayStr = java.time.LocalDate.now().toString()
                val todayToDateString = java.time.format.DateTimeFormatter.ofPattern("EEE MMM dd yyyy", java.util.Locale.US)
                    .format(java.time.ZonedDateTime.now(java.time.ZoneId.systemDefault()))
                val isFirstDay = test.lockDayStr == todayToDateString
                val checkedInToday = test.logs.containsKey(todayStr) || isFirstDay

                var isExpanded by remember { mutableStateOf(false) }

                LazyColumn(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(padding),
                    contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 16.dp, bottom = 90.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp)
                ) {
                    // ── Active Projects Row ──────────────────────────────
                    if (uiState.activeTests.isNotEmpty()) {
                        item {
                            LazyRow(
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                                contentPadding = PaddingValues(bottom = 8.dp),
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                items(uiState.activeTests.size) { idx ->
                                    val t = uiState.activeTests[idx]
                                    val isSelected = t.id == uiState.selectedTestId
                                    Surface(
                                        onClick = { viewModel.selectActiveTest(t.id ?: "") },
                                        shape = RoundedCornerShape(14.dp),
                                        color = if (isSelected) NotelPrimary.copy(alpha = 0.20f) else Color.White.copy(alpha = 0.03f),
                                        border = BorderStroke(1.dp, if (isSelected) NotelPrimary else Color.White.copy(alpha = 0.08f)),
                                        modifier = Modifier.widthIn(min = 120.dp, max = 180.dp)
                                    ) {
                                        Column(modifier = Modifier.padding(12.dp)) {
                                            Text(
                                                text = t.title,
                                                color = Color.White,
                                                fontWeight = FontWeight.Bold,
                                                fontSize = 13.sp,
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis
                                            )
                                            Spacer(Modifier.height(4.dp))
                                            Text(
                                                text = "${t.durationDays} Days",
                                                color = NotelTextSecondary,
                                                fontSize = 10.sp
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ── Header Card ──────────────────────────────────────
                    item {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .border(
                                    width = 2.dp,
                                    brush = Brush.linearGradient(
                                        listOf(
                                            NotelPrimary.copy(alpha = 0.4f),
                                            NotelAccent.copy(alpha = 0.2f)
                                        )
                                    ),
                                    shape = RoundedCornerShape(24.dp)
                                )
                                .background(
                                    Brush.verticalGradient(
                                        listOf(
                                            NotelPrimary.copy(alpha = 0.08f),
                                            Color.Transparent
                                        )
                                    ),
                                    shape = RoundedCornerShape(24.dp)
                                )
                                .clickable { isExpanded = !isExpanded }
                                .padding(20.dp)
                        ) {
                            Column {
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    // Status badge
                                    Surface(
                                        shape = RoundedCornerShape(8.dp),
                                        color = if (isCompleted) Color(0xFF4CAF50).copy(alpha = 0.15f)
                                               else NotelPrimary.copy(alpha = 0.12f)
                                    ) {
                                        Text(
                                            text = if (isCompleted) "✅ Complete — Results Ready" else "⏳ In Progress",
                                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                                            color = if (isCompleted) Color(0xFF4CAF50) else NotelPrimary,
                                            fontSize = 11.sp,
                                            fontWeight = FontWeight.Black,
                                            letterSpacing = 0.5.sp
                                        )
                                    }

                                    Icon(
                                        imageVector = if (isExpanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                                        contentDescription = if (isExpanded) "Collapse" else "Expand",
                                        tint = NotelTextSecondary,
                                        modifier = Modifier.size(24.dp)
                                    )
                                }

                                Spacer(Modifier.height(12.dp))

                                Text(
                                    text = test.title,
                                    color = NotelTextPrimary,
                                    fontSize = 22.sp,
                                    fontWeight = FontWeight.ExtraBold,
                                    lineHeight = 28.sp
                                )

                                if (!test.desc.isNullOrBlank()) {
                                    Spacer(Modifier.height(6.dp))
                                    Text(
                                        text = test.desc,
                                        color = NotelTextSecondary,
                                        fontSize = 13.sp,
                                        lineHeight = 18.sp
                                    )
                                }

                                Spacer(Modifier.height(20.dp))

                                // Progress bar
                                val progress = if (test.durationDays > 0)
                                    (daysElapsed.toFloat() / test.durationDays.toFloat()).coerceIn(0f, 1f)
                                else 1f

                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Text(
                                        text = "Day $daysElapsed of ${test.durationDays}",
                                        color = NotelTextSecondary,
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.Medium
                                    )
                                    Text(
                                        text = if (isCompleted) "Done!" else "$daysLeft day${if (daysLeft == 1) "" else "s"} left",
                                        color = if (isCompleted) Color(0xFF4CAF50) else NotelTextSecondary,
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.Medium
                                    )
                                }

                                Spacer(Modifier.height(8.dp))

                                Box(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .height(6.dp)
                                        .clip(CircleShape)
                                        .background(Color.White.copy(alpha = 0.07f))
                                ) {
                                    Box(
                                        modifier = Modifier
                                            .fillMaxWidth(progress)
                                            .fillMaxHeight()
                                            .background(
                                                if (isCompleted) Color(0xFF4CAF50) else NotelPrimary,
                                                CircleShape
                                            )
                                    )
                                }
                            }
                        }
                    }

                    // ── Everything below is only shown when expanded ─────
                    if (isExpanded) {
                        // ── Completed: Show results link ─────────────────────
                        if (isCompleted) {
                            item {
                                Surface(
                                    onClick = {
                                        val intent = Intent(
                                            Intent.ACTION_VIEW,
                                            Uri.parse("https://jottracker.com/login")
                                        )
                                        context.startActivity(intent)
                                    },
                                    shape = RoundedCornerShape(20.dp),
                                    color = Color(0xFF4CAF50).copy(alpha = 0.1f),
                                    border = BorderStroke(1.dp, Color(0xFF4CAF50).copy(alpha = 0.35f)),
                                    modifier = Modifier.fillMaxWidth()
                                ) {
                                    Row(
                                        modifier = Modifier.padding(18.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(14.dp)
                                    ) {
                                        Icon(
                                            Icons.Default.OpenInBrowser,
                                            contentDescription = null,
                                            tint = Color(0xFF4CAF50),
                                            modifier = Modifier.size(28.dp)
                                        )
                                        Column(modifier = Modifier.weight(1f)) {
                                            Text(
                                                "View Your Results",
                                                color = Color(0xFF4CAF50),
                                                fontSize = 16.sp,
                                                fontWeight = FontWeight.ExtraBold
                                            )
                                            Text(
                                                "Tap to open jottracker.com and see your full analysis",
                                                color = Color(0xFF4CAF50).copy(alpha = 0.75f),
                                                fontSize = 12.sp,
                                                lineHeight = 16.sp
                                            )
                                        }
                                        Icon(
                                            Icons.Default.ChevronRight,
                                            contentDescription = null,
                                            tint = Color(0xFF4CAF50).copy(alpha = 0.7f),
                                            modifier = Modifier.size(20.dp)
                                        )
                                    }
                                }
                            }
                        }

                        // ── Daily Check-In Card ──────────────────────────────
                        if (!isCompleted) {
                            item {
                                Column {
                                    Text(
                                        "Today's Check-In",
                                        color = NotelTextSecondary,
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.Black,
                                        letterSpacing = 1.sp
                                    )
                                    Spacer(Modifier.height(10.dp))

                                    if (elapsedMs < 0L) {
                                        Surface(
                                            shape = RoundedCornerShape(18.dp),
                                            color = Color.White.copy(alpha = 0.03f),
                                            border = BorderStroke(1.dp, Color.White.copy(alpha = 0.08f)),
                                            modifier = Modifier.fillMaxWidth()
                                        ) {
                                            Row(
                                                modifier = Modifier.padding(16.dp),
                                                verticalAlignment = Alignment.CenterVertically,
                                                horizontalArrangement = Arrangement.spacedBy(12.dp)
                                            ) {
                                                Text("🔒", fontSize = 24.sp)
                                                Column {
                                                    Text(
                                                        "Day 0: Waiting to start",
                                                        color = NotelPrimary,
                                                        fontSize = 15.sp,
                                                        fontWeight = FontWeight.Bold
                                                    )
                                                    Text(
                                                        "Your experiment will begin tomorrow. Get ready!",
                                                        color = NotelTextSecondary,
                                                        fontSize = 11.sp
                                                    )
                                                }
                                            }
                                        }
                                    } else if (checkedInToday) {
                                        Surface(
                                            shape = RoundedCornerShape(18.dp),
                                            color = if (isFirstDay) NotelPrimary.copy(alpha = 0.1f) else Color(0xFF4CAF50).copy(alpha = 0.1f),
                                            border = BorderStroke(1.dp, if (isFirstDay) NotelPrimary.copy(alpha = 0.3f) else Color(0xFF4CAF50).copy(alpha = 0.3f)),
                                            modifier = Modifier.fillMaxWidth()
                                        ) {
                                            Row(
                                                modifier = Modifier.padding(16.dp),
                                                verticalAlignment = Alignment.CenterVertically,
                                                horizontalArrangement = Arrangement.SpaceBetween
                                            ) {
                                                Row(
                                                    verticalAlignment = Alignment.CenterVertically,
                                                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                                                    modifier = Modifier.weight(1f)
                                                ) {
                                                    Text(if (isFirstDay) "🔒" else "✅", fontSize = 24.sp)
                                                    Column {
                                                        Text(
                                                            text = if (isFirstDay) "New test locked in!" else "Response logged for today!",
                                                            color = if (isFirstDay) NotelPrimary else Color(0xFF4CAF50),
                                                            fontSize = 15.sp,
                                                            fontWeight = FontWeight.Bold
                                                        )
                                                        Text(
                                                            text = if (isFirstDay) "Your check-in opens at midnight (12:00 AM) so you have time to perform the experiment first." else "Resets at midnight (12:00 AM)",
                                                            color = (if (isFirstDay) NotelPrimary else Color(0xFF4CAF50)).copy(alpha = 0.7f),
                                                            fontSize = 11.sp
                                                        )
                                                    }
                                                }
                                                if (!isFirstDay) {
                                                    TextButton(
                                                        onClick = { viewModel.undoCheckIn(todayStr) }
                                                    ) {
                                                        Text("Undo", color = Color(0xFFEF5350), fontWeight = FontWeight.Bold, fontSize = 13.sp)
                                                    }
                                                }
                                            }
                                        }
                                    } else {
                                        Row(
                                            modifier = Modifier.fillMaxWidth(),
                                            horizontalArrangement = Arrangement.spacedBy(12.dp)
                                        ) {
                                            // Yes button
                                            val isLocalYes = test.logs[todayStr] == true
                                            Surface(
                                                onClick = { viewModel.checkIn(todayStr, true) },
                                                modifier = Modifier.weight(1f),
                                                shape = RoundedCornerShape(18.dp),
                                                color = if (isLocalYes) NotelPrimary.copy(alpha = 0.2f) else Color.White.copy(alpha = 0.03f),
                                                border = BorderStroke(1.dp, if (isLocalYes) NotelPrimary else Color.White.copy(alpha = 0.08f))
                                            ) {
                                                Column(
                                                    modifier = Modifier.padding(16.dp),
                                                    horizontalAlignment = Alignment.CenterHorizontally
                                                ) {
                                                    Text("✅", fontSize = 28.sp)
                                                    Spacer(Modifier.height(6.dp))
                                                    Text(
                                                        "Yes, I did it",
                                                        color = if (isLocalYes) NotelPrimary else NotelTextSecondary,
                                                        fontSize = 13.sp,
                                                        fontWeight = FontWeight.Bold,
                                                        textAlign = TextAlign.Center
                                                    )
                                                }
                                            }
                                            // No button
                                            val isLocalNo = test.logs[todayStr] == false
                                            Surface(
                                                onClick = { viewModel.checkIn(todayStr, false) },
                                                modifier = Modifier.weight(1f),
                                                shape = RoundedCornerShape(18.dp),
                                                color = if (isLocalNo) Color(0xFFEF5350).copy(alpha = 0.2f) else Color.White.copy(alpha = 0.03f),
                                                border = BorderStroke(1.dp, if (isLocalNo) Color(0xFFEF5350) else Color.White.copy(alpha = 0.08f))
                                            ) {
                                                Column(
                                                    modifier = Modifier.padding(16.dp),
                                                    horizontalAlignment = Alignment.CenterHorizontally
                                                ) {
                                                    Text("😞", fontSize = 28.sp)
                                                    Spacer(Modifier.height(6.dp))
                                                    Text(
                                                        "Not today",
                                                        color = if (isLocalNo) Color(0xFFEF5350) else NotelTextSecondary,
                                                        fontSize = 13.sp,
                                                        fontWeight = FontWeight.Bold,
                                                        textAlign = TextAlign.Center
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // ── Log Calendar ─────────────────────────────────────
                        item {
                            Column {
                                Text(
                                    "Log History",
                                    color = NotelTextSecondary,
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.Black,
                                    letterSpacing = 1.sp
                                )
                                Spacer(Modifier.height(10.dp))

                                val startDate = java.time.Instant.ofEpochMilli(startMs)
                                    .atZone(java.time.ZoneOffset.UTC)
                                    .toLocalDate()

                                val totalDays = test.durationDays
                                val dayRows = (0 until totalDays).chunked(7)

                                dayRows.forEach { week ->
                                    Row(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .padding(vertical = 3.dp),
                                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                                    ) {
                                        week.forEach { dayOffset ->
                                            val date = startDate.plusDays(dayOffset.toLong())
                                            val dateStr = date.toString()
                                            val isToday = dateStr == todayStr
                                            val isFuture = date.isAfter(java.time.LocalDate.now())
                                            val logValue = test.logs[dateStr]
                                            val hasLog = logValue != null
                                            val logOrMissed = logValue ?: (!isToday && !isFuture)

                                            Box(
                                                modifier = Modifier
                                                    .weight(1f)
                                                    .aspectRatio(1f)
                                                    .clip(RoundedCornerShape(10.dp))
                                                    .background(
                                                        when {
                                                            logValue == true -> Color(0xFF4CAF50).copy(alpha = 0.25f)
                                                            logValue == false || (!hasLog && !isToday && !isFuture) -> Color(0xFFEF5350).copy(alpha = 0.15f)
                                                            isToday -> NotelPrimary.copy(alpha = 0.1f)
                                                            else -> Color.White.copy(alpha = 0.04f)
                                                        }
                                                    )
                                                    .border(
                                                        1.dp,
                                                        when {
                                                            logValue == true -> Color(0xFF4CAF50).copy(alpha = 0.4f)
                                                            logValue == false || (!hasLog && !isToday && !isFuture) -> Color(0xFFEF5350).copy(alpha = 0.3f)
                                                            isToday -> NotelPrimary.copy(alpha = 0.4f)
                                                            else -> Color.White.copy(alpha = 0.05f)
                                                        },
                                                        RoundedCornerShape(10.dp)
                                                    ),
                                                contentAlignment = Alignment.Center
                                            ) {
                                                when {
                                                    logValue == true -> Text("✓", color = Color(0xFF4CAF50), fontSize = 14.sp, fontWeight = FontWeight.Black)
                                                    logValue == false || (!hasLog && !isToday && !isFuture) -> Text("✗", color = Color(0xFFEF5350), fontSize = 14.sp, fontWeight = FontWeight.Black)
                                                    isFuture -> Text(
                                                        "${dayOffset + 1}",
                                                        color = Color.White.copy(alpha = 0.15f),
                                                        fontSize = 10.sp
                                                    )
                                                    else -> Text(
                                                        "${dayOffset + 1}",
                                                        color = if (isToday) NotelPrimary else NotelTextSecondary,
                                                        fontSize = 10.sp,
                                                        fontWeight = if (isToday) FontWeight.Bold else FontWeight.Normal
                                                    )
                                                }
                                            }
                                        }
                                        // Fill remaining empty cells in last row
                                        if (week.size < 7) {
                                            repeat(7 - week.size) {
                                                Spacer(modifier = Modifier.weight(1f))
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // ── Legend ───────────────────────────────────────────
                        item {
                            Row(
                                horizontalArrangement = Arrangement.spacedBy(16.dp),
                                modifier = Modifier.padding(top = 4.dp)
                            ) {
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                    Box(Modifier.size(8.dp).background(Color(0xFF4CAF50).copy(alpha = 0.7f), CircleShape))
                                    Text("Completed", color = NotelTextSecondary, fontSize = 11.sp)
                                }
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                    Box(Modifier.size(8.dp).background(Color(0xFFEF5350).copy(alpha = 0.7f), CircleShape))
                                    Text("Missed", color = NotelTextSecondary, fontSize = 11.sp)
                                }
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                    Box(Modifier.size(8.dp).background(Color.White.copy(alpha = 0.1f), CircleShape))
                                    Text("Upcoming", color = NotelTextSecondary, fontSize = 11.sp)
                                }
                            }
                        }

                        // ── Cancel Experiment Button ─────────────────────────
                        item {
                            var showCancelDialog by remember { mutableStateOf(false) }

                            if (showCancelDialog) {
                                AlertDialog(
                                    onDismissRequest = { showCancelDialog = false },
                                    title = { Text("Cancel Experiment", color = Color.White) },
                                    text = { Text("Are you sure you want to cancel this experiment? This will delete all logged progress for it.", color = NotelTextSecondary) },
                                    confirmButton = {
                                        TextButton(
                                            onClick = {
                                                showCancelDialog = false
                                                viewModel.cancelActiveTest()
                                            }
                                        ) {
                                            Text("Yes", color = Color(0xFFEF5350), fontWeight = FontWeight.Bold)
                                        }
                                    },
                                    dismissButton = {
                                        TextButton(onClick = { showCancelDialog = false }) {
                                            Text("No", color = Color.White)
                                        }
                                    },
                                    containerColor = Color(0xFF161622)
                                )
                            }

                            Spacer(Modifier.height(8.dp))
                            Button(
                                onClick = { showCancelDialog = true },
                                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFEF5350).copy(alpha = 0.1f)),
                                border = BorderStroke(1.dp, Color(0xFFEF5350).copy(alpha = 0.35f)),
                                shape = RoundedCornerShape(16.dp),
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Text("Cancel Experiment", color = Color(0xFFEF5350), fontWeight = FontWeight.Bold)
                            }
                        }

                        // ── Bottom link to website ───────────────────────────
                        item {
                            Spacer(Modifier.height(8.dp))
                            Surface(
                                onClick = {
                                    val intent = Intent(
                                        Intent.ACTION_VIEW,
                                        Uri.parse("https://jottracker.com/login")
                                    )
                                    context.startActivity(intent)
                                },
                                shape = RoundedCornerShape(16.dp),
                                color = NotelPrimary.copy(alpha = 0.07f),
                                border = BorderStroke(1.dp, NotelPrimary.copy(alpha = 0.2f)),
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Row(
                                    modifier = Modifier.padding(14.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                                ) {
                                    Icon(
                                        Icons.Default.OpenInBrowser,
                                        contentDescription = null,
                                        tint = NotelPrimary.copy(alpha = 0.7f),
                                        modifier = Modifier.size(18.dp)
                                    )
                                    Text(
                                        "Manage projects on jottracker.com",
                                        color = NotelPrimary.copy(alpha = 0.8f),
                                        fontSize = 13.sp,
                                        fontWeight = FontWeight.Medium
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
}


