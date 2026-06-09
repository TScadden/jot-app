package com.notel.notel.ui.screen

import android.content.Intent
import android.net.Uri
import androidx.compose.animation.*
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProjectFocusScreen(
    onBack: () -> Unit,
    viewModel: ProjectFocusViewModel = hiltViewModel()
) {
    val uiState by viewModel.uiState.collectAsState()
    val context = LocalContext.current

    Scaffold(
        containerColor = NotelBackground,
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
                colors = TopAppBarDefaults.topAppBarColors(containerColor = NotelBackground)
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
            uiState.activeTest == null -> {
                // No active project
                Box(
                    modifier = Modifier.fillMaxSize().padding(padding),
                    contentAlignment = Alignment.Center
                ) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.padding(horizontal = 40.dp)
                    ) {
                        Text("🔬", fontSize = 52.sp)
                        Spacer(Modifier.height(20.dp))
                        Text(
                            "No Active Project",
                            color = NotelTextPrimary,
                            fontSize = 22.sp,
                            fontWeight = FontWeight.Bold,
                            textAlign = TextAlign.Center
                        )
                        Spacer(Modifier.height(10.dp))
                        Text(
                            "Start a Project Focus experiment from the website at jottracker.com to track your progress here.",
                            color = NotelTextSecondary,
                            fontSize = 14.sp,
                            textAlign = TextAlign.Center,
                            lineHeight = 20.sp
                        )
                        Spacer(Modifier.height(28.dp))
                        Button(
                            onClick = {
                                val intent = Intent(
                                    Intent.ACTION_VIEW,
                                    Uri.parse("https://jottracker.com/login")
                                )
                                context.startActivity(intent)
                            },
                            colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary),
                            shape = RoundedCornerShape(16.dp),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Icon(Icons.Default.OpenInBrowser, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("Go to jottracker.com", fontWeight = FontWeight.Bold)
                        }
                    }
                }
            }
            else -> {
                val test = uiState.activeTest!!
                val startMs = test.startTimestamp
                val durationMs = test.durationDays.toLong() * 24L * 60L * 60L * 1000L
                val elapsedMs = System.currentTimeMillis() - startMs
                val leftMs = maxOf(0L, durationMs - elapsedMs)
                val isCompleted = leftMs <= 0L
                val daysLeft = ceil(leftMs / (24.0 * 60.0 * 60.0 * 1000.0)).toInt()
                val daysElapsed = minOf(
                    test.durationDays,
                    (elapsedMs / (24L * 60L * 60L * 1000L)).toInt() + 1
                )
                val todayStr = java.time.LocalDate.now().toString()
                val checkedInToday = test.logs[todayStr] == true

                var isExpanded by remember { mutableStateOf(false) }

                LazyColumn(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(padding),
                    contentPadding = PaddingValues(horizontal = 20.dp, vertical = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp)
                ) {
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

                                    if (checkedInToday) {
                                        Surface(
                                            shape = RoundedCornerShape(18.dp),
                                            color = Color(0xFF4CAF50).copy(alpha = 0.1f),
                                            border = BorderStroke(1.dp, Color(0xFF4CAF50).copy(alpha = 0.3f)),
                                            modifier = Modifier.fillMaxWidth()
                                        ) {
                                            Row(
                                                modifier = Modifier.padding(16.dp),
                                                verticalAlignment = Alignment.CenterVertically,
                                                horizontalArrangement = Arrangement.spacedBy(12.dp)
                                            ) {
                                                Text("✅", fontSize = 24.sp)
                                                Column {
                                                    Text(
                                                        "Checked in today!",
                                                        color = Color(0xFF4CAF50),
                                                        fontSize = 15.sp,
                                                        fontWeight = FontWeight.Bold
                                                    )
                                                    Text(
                                                        "Great work. Come back tomorrow to log again.",
                                                        color = Color(0xFF4CAF50).copy(alpha = 0.7f),
                                                        fontSize = 12.sp
                                                    )
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

                                            Box(
                                                modifier = Modifier
                                                    .weight(1f)
                                                    .aspectRatio(1f)
                                                    .clip(RoundedCornerShape(10.dp))
                                                    .background(
                                                        when {
                                                            logValue == true -> Color(0xFF4CAF50).copy(alpha = 0.25f)
                                                            logValue == false -> Color(0xFFEF5350).copy(alpha = 0.15f)
                                                            isToday -> NotelPrimary.copy(alpha = 0.1f)
                                                            else -> Color.White.copy(alpha = 0.04f)
                                                        }
                                                    )
                                                    .border(
                                                        1.dp,
                                                        when {
                                                            logValue == true -> Color(0xFF4CAF50).copy(alpha = 0.4f)
                                                            logValue == false -> Color(0xFFEF5350).copy(alpha = 0.3f)
                                                            isToday -> NotelPrimary.copy(alpha = 0.4f)
                                                            else -> Color.White.copy(alpha = 0.05f)
                                                        },
                                                        RoundedCornerShape(10.dp)
                                                    ),
                                                contentAlignment = Alignment.Center
                                            ) {
                                                when {
                                                    logValue == true -> Text("✓", color = Color(0xFF4CAF50), fontSize = 14.sp, fontWeight = FontWeight.Black)
                                                    logValue == false -> Text("✗", color = Color(0xFFEF5350), fontSize = 14.sp, fontWeight = FontWeight.Black)
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
