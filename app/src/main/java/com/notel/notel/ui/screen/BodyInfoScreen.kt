package com.notel.notel.ui.screen

import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.BodyInfoViewModel
import com.notel.notel.util.EvaluatedBodyImpact

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BodyInfoScreen(
    viewModel: BodyInfoViewModel = hiltViewModel(),
    onBack: () -> Unit = {}
) {
    val activeImpacts by viewModel.activeImpacts.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    var expandedImpactId by remember { mutableStateOf<String?>(null) }

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        "Body Info & Impact Map",
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        color = NotelTextPrimary
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector = Icons.Default.ArrowBack,
                            contentDescription = "Back",
                            tint = NotelTextPrimary
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = NotelBackground)
            )
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
            contentPadding = PaddingValues(bottom = 100.dp)
        ) {
            item {
                Text(
                    text = "Track how medications, labs, peptide shots, and symptoms affect your body zones in real time.",
                    color = NotelTextSecondary,
                    fontSize = 14.sp
                )
            }

            // Prominent, Large Human Body Icon Display
            item {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(310.dp)
                        .clip(RoundedCornerShape(24.dp))
                        .liquidGlass(
                            shape = RoundedCornerShape(24.dp),
                            color = NotelSurface,
                            alpha = 0.85f,
                            showBorder = true
                        )
                        .padding(20.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center
                    ) {
                        Icon(
                            imageVector = Icons.Default.AccessibilityNew,
                            contentDescription = "Body Visualizer",
                            tint = NotelPrimary,
                            modifier = Modifier.size(140.dp)
                        )
                        Spacer(Modifier.height(16.dp))
                        Text(
                            text = "Body Impact Visualizer",
                            style = MaterialTheme.typography.titleLarge,
                            fontWeight = FontWeight.Bold,
                            color = NotelTextPrimary
                        )
                        Spacer(Modifier.height(4.dp))
                        Text(
                            text = if (activeImpacts.isEmpty()) "All body zones normal" else "${activeImpacts.size} active body zones tracked",
                            style = MaterialTheme.typography.bodyMedium,
                            color = NotelTextSecondary
                        )
                    }
                }
            }

            item {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = "Active Body Impact Zones",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        color = NotelTextPrimary
                    )

                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        if (isLoading) {
                            Surface(
                                color = NotelPrimary.copy(alpha = 0.12f),
                                shape = RoundedCornerShape(12.dp)
                            ) {
                                Row(
                                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                                ) {
                                    CircularProgressIndicator(
                                        modifier = Modifier.size(12.dp),
                                        color = NotelPrimary,
                                        strokeWidth = 1.5.dp
                                    )
                                    Text(
                                        text = "AI Analyzing...",
                                        color = NotelPrimary,
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.Bold
                                    )
                                }
                            }
                        }

                        Surface(
                            color = NotelPrimary.copy(alpha = 0.15f),
                            shape = RoundedCornerShape(12.dp)
                        ) {
                            Text(
                                text = "${activeImpacts.size} Active",
                                color = NotelPrimary,
                                fontSize = 12.sp,
                                fontWeight = FontWeight.Bold,
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp)
                            )
                        }
                    }
                }
            }

            if (activeImpacts.isEmpty()) {
                item {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 32.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Icon(
                                imageVector = Icons.Default.CheckCircle,
                                contentDescription = null,
                                tint = NotelPrimary.copy(alpha = 0.6f),
                                modifier = Modifier.size(48.dp)
                            )
                            Spacer(Modifier.height(12.dp))
                            Text(
                                text = "All Body Zones Normal",
                                style = MaterialTheme.typography.titleSmall,
                                fontWeight = FontWeight.Bold,
                                color = NotelTextPrimary
                            )
                            Spacer(Modifier.height(4.dp))
                            Text(
                                text = "Log a lab draw, peptide shot, or medication entry to see real-time body impact tracking.",
                                style = MaterialTheme.typography.bodySmall,
                                color = NotelTextSecondary
                            )
                        }
                    }
                }
            } else {
                items(activeImpacts) { impact ->
                    val isExpanded = expandedImpactId == impact.id
                    ExpandableBodyZoneCard(
                        zone = impact,
                        isExpanded = isExpanded,
                        onToggleExpand = {
                            expandedImpactId = if (isExpanded) null else impact.id
                        }
                    )
                }
            }
        }
    }
}

@Composable
fun ExpandableBodyZoneCard(
    zone: EvaluatedBodyImpact,
    isExpanded: Boolean,
    onToggleExpand: () -> Unit
) {
    val formattedTime = remember(zone.timestamp) {
        java.text.SimpleDateFormat("MMM d, yyyy 'at' h:mm a", java.util.Locale.getDefault())
            .format(java.util.Date(zone.timestamp))
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(20.dp))
            .border(
                width = if (isExpanded) 2.dp else 1.dp,
                color = if (isExpanded) zone.color else Color.White.copy(alpha = 0.05f),
                shape = RoundedCornerShape(20.dp)
            )
            .liquidGlass(
                shape = RoundedCornerShape(20.dp),
                color = NotelSurface,
                alpha = if (isExpanded) 0.95f else 0.8f,
                showBorder = false
            )
            .clickable { onToggleExpand() }
            .animateContentSize()
            .padding(16.dp)
    ) {
        Column {
            Row(
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                Box(
                    modifier = Modifier
                        .size(44.dp)
                        .background(zone.color.copy(alpha = 0.15f), CircleShape)
                        .border(1.5.dp, zone.color, CircleShape),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        imageVector = zone.icon,
                        contentDescription = null,
                        tint = zone.color,
                        modifier = Modifier.size(22.dp)
                    )
                }

                Column(modifier = Modifier.weight(1f)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            text = zone.regionName,
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.Bold,
                            color = NotelTextPrimary
                        )

                        // Timer Badge showing time remaining until it fades
                        Surface(
                            color = zone.color.copy(alpha = 0.15f),
                            shape = RoundedCornerShape(6.dp)
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(3.dp)
                            ) {
                                Icon(
                                    imageVector = Icons.Default.Schedule,
                                    contentDescription = null,
                                    tint = zone.color,
                                    modifier = Modifier.size(10.dp)
                                )
                                Text(
                                    text = zone.getTimeRemainingText(),
                                    color = zone.color,
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.Bold
                                )
                            }
                        }
                    }

                    Spacer(Modifier.height(2.dp))
                    Text(
                        text = zone.status,
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.SemiBold,
                        color = zone.color
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        text = zone.details,
                        style = MaterialTheme.typography.bodySmall,
                        color = NotelTextSecondary,
                        lineHeight = 16.sp
                    )
                }

                Icon(
                    imageVector = if (isExpanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                    contentDescription = "Expand details",
                    tint = NotelTextSecondary,
                    modifier = Modifier.padding(top = 4.dp)
                )
            }

            // Dropdown expansion showing the exact logged entry text
            AnimatedVisibility(
                visible = isExpanded,
                enter = fadeIn() + expandVertically(),
                exit = fadeOut() + shrinkVertically()
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 14.dp)
                        .background(NotelSurfaceHigh.copy(alpha = 0.4f), RoundedCornerShape(12.dp))
                        .padding(12.dp)
                ) {
                    Text(
                        text = "LOGGED ENTRY DETAILS",
                        style = MaterialTheme.typography.labelSmall,
                        color = zone.color,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 0.5.sp
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        text = if (zone.originalLogText.isNotBlank()) "\"${zone.originalLogText}\"" else "Logged Entry #${zone.relatedLogId}",
                        style = MaterialTheme.typography.bodyMedium,
                        color = NotelTextPrimary,
                        fontWeight = FontWeight.Medium
                    )
                    Spacer(Modifier.height(8.dp))
                    Column(
                        modifier = Modifier.fillMaxWidth(),
                        verticalArrangement = Arrangement.spacedBy(2.dp)
                    ) {
                        Text(
                            text = "Logged: $formattedTime",
                            style = MaterialTheme.typography.bodySmall,
                            color = NotelTextSecondary,
                            fontSize = 11.sp
                        )
                        val totalMins = zone.durationMinutes
                        val hrs = totalMins / 60
                        val mins = totalMins % 60
                        val durationStr = when {
                            hrs > 0 && mins > 0 -> "${hrs}h ${mins}m"
                            hrs > 0 -> "${hrs}h"
                            else -> "${mins}m"
                        }
                        Text(
                            text = "Active Window: $durationStr",
                            style = MaterialTheme.typography.bodySmall,
                            color = zone.color,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Bold
                        )
                    }
                }
            }
        }
    }
}
