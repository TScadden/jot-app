package com.notel.notel.ui.screen

import androidx.compose.animation.*
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.TipsAndTricksViewModel
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TipsAndTricksScreen(
    onBack: () -> Unit = {},
    viewModel: TipsAndTricksViewModel = hiltViewModel()
) {
    val topics by viewModel.topics.collectAsState()
    val cachedTips by viewModel.cachedTips.collectAsState()
    val isLoadingTopics by viewModel.isLoadingTopics.collectAsState()
    val loadingTipsTopic by viewModel.loadingTipsTopic.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()

    var selectedTopic by remember { mutableStateOf<String?>(null) }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    // Trigger tips fetch whenever sheet opens
    LaunchedEffect(selectedTopic) {
        val topic = selectedTopic
        if (topic != null) {
            viewModel.fetchTipsForTopic(topic)
        }
    }

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = "Tips & Insights",
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        color = NotelTextPrimary
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back",
                            tint = NotelTextPrimary
                        )
                    }
                },
                actions = {
                    if (topics.isNotEmpty() && !isLoadingTopics) {
                        IconButton(onClick = { viewModel.generateTopics() }) {
                            Icon(
                                imageVector = Icons.Default.Refresh,
                                contentDescription = "Refresh",
                                tint = NotelPrimary
                            )
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = NotelBackground)
            )
        }
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp),
            contentAlignment = Alignment.TopCenter
        ) {
            when {
                isLoadingTopics -> {
                    // Premium loading state
                    Column(
                        modifier = Modifier.fillMaxSize(),
                        verticalArrangement = Arrangement.Center,
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        CircularProgressIndicator(color = NotelPrimary, modifier = Modifier.size(56.dp))
                        Spacer(Modifier.height(24.dp))
                        Text(
                            text = "Analyzing your habits & records...",
                            color = NotelTextPrimary,
                            fontSize = 16.sp,
                            fontWeight = FontWeight.Bold
                        )
                        Spacer(Modifier.height(8.dp))
                        Text(
                            text = "This compiles summaries of notes, lists, and documents.",
                            color = NotelTextSecondary,
                            fontSize = 12.sp,
                            textAlign = TextAlign.Center
                        )
                    }
                }
                topics.isEmpty() -> {
                    // Premium empty onboarding state
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(bottom = 60.dp),
                        verticalArrangement = Arrangement.Center,
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        Box(
                            modifier = Modifier
                                .size(100.dp)
                                .liquidGlass(
                                    shape = RoundedCornerShape(32.dp),
                                    color = NotelSurface,
                                    alpha = 0.5f,
                                    showBorder = true
                                ),
                            contentAlignment = Alignment.Center
                        ) {
                            Text("💡", fontSize = 42.sp)
                        }
                        
                        Spacer(Modifier.height(32.dp))
                        
                        Text(
                            text = "Personalized Insights",
                            color = NotelTextPrimary,
                            fontSize = 24.sp,
                            fontWeight = FontWeight.Bold,
                            textAlign = TextAlign.Center
                        )
                        
                        Spacer(Modifier.height(12.dp))
                        
                        Text(
                            text = "Let AI safely scan your local logs, lists, and document summaries to generate tailored topics and tips for your specific routine.",
                            color = NotelTextSecondary,
                            fontSize = 14.sp,
                            lineHeight = 22.sp,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.padding(horizontal = 24.dp)
                        )
                        
                        Spacer(Modifier.height(40.dp))
                        
                        Button(
                            onClick = { viewModel.generateTopics() },
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(56.dp)
                                .border(
                                    width = 1.dp,
                                    color = NotelPrimary.copy(alpha = 0.5f),
                                    shape = RoundedCornerShape(20.dp)
                                ),
                            shape = RoundedCornerShape(20.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary)
                        ) {
                            Icon(Icons.Default.AutoAwesome, null, tint = Color.White)
                            Spacer(Modifier.width(10.dp))
                            Text(
                                "Generate Custom Tips",
                                color = Color.White,
                                fontWeight = FontWeight.Bold,
                                fontSize = 16.sp
                            )
                        }
                    }
                }
                else -> {
                    // Show custom questions list in premium grid
                    Column(modifier = Modifier.fillMaxSize()) {
                        Text(
                            text = "Tap a question based on your data to uncover custom AI insights and tricks.",
                            color = NotelTextSecondary,
                            fontSize = 13.sp,
                            lineHeight = 18.sp,
                            modifier = Modifier.padding(bottom = 16.dp, top = 4.dp)
                        )
                        
                        LazyColumn(
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                            contentPadding = PaddingValues(bottom = 120.dp),
                            modifier = Modifier.fillMaxSize()
                        ) {
                            items(topics) { topic ->
                                TopicCard(topic = topic) {
                                    selectedTopic = topic
                                }
                            }
                        }
                    }
                }
            }

            // Error alerts
            if (errorMessage != null) {
                AlertDialog(
                    onDismissRequest = { viewModel.clearError() },
                    containerColor = NotelSurface,
                    title = { Text("Failed to Generate", color = NotelTextPrimary, fontWeight = FontWeight.Bold) },
                    text = { Text(errorMessage ?: "An error occurred", color = NotelTextSecondary) },
                    confirmButton = {
                        Button(
                            onClick = { viewModel.clearError() },
                            colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary)
                        ) { Text("OK") }
                    }
                )
            }
        }
    }

    // Modal Sheet for Tips Details
    if (selectedTopic != null) {
        val topic = selectedTopic!!
        val tips = cachedTips[topic]
        val isTipsLoading = loadingTipsTopic == topic

        ModalBottomSheet(
            onDismissRequest = { selectedTopic = null },
            sheetState = sheetState,
            containerColor = NotelSurface,
            dragHandle = { BottomSheetDefaults.DragHandle(color = NotelTextSecondary.copy(alpha = 0.3f)) }
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 24.dp)
                    .padding(bottom = 50.dp)
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = "Tips & Advice",
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        color = NotelPrimary
                    )
                    IconButton(onClick = { selectedTopic = null }) {
                        Icon(Icons.Default.Close, null, tint = NotelTextSecondary)
                    }
                }
                
                Spacer(Modifier.height(12.dp))
                
                Text(
                    text = topic,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.Bold,
                    color = NotelTextPrimary,
                    lineHeight = 22.sp
                )
                
                Spacer(Modifier.height(24.dp))
                
                if (isTipsLoading) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(150.dp),
                        verticalArrangement = Arrangement.Center,
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        CircularProgressIndicator(color = NotelPrimary, modifier = Modifier.size(36.dp))
                        Spacer(Modifier.height(16.dp))
                        Text("Drafting targeted tips...", color = NotelTextSecondary, fontSize = 13.sp)
                    }
                } else if (tips != null) {
                    Column(
                        verticalArrangement = Arrangement.spacedBy(14.dp),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        tips.forEachIndexed { index, tip ->
                            TipRow(index = index + 1, text = tip)
                        }
                    }
                } else {
                    Text(
                        text = "Could not fetch tips. Please check your connection.",
                        color = NotelTextSecondary,
                        fontSize = 14.sp
                    )
                }
            }
        }
    }
}

@Composable
private fun TopicCard(topic: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .border(
                width = 1.dp,
                color = NotelPrimary.copy(alpha = 0.08f),
                shape = RoundedCornerShape(16.dp)
            )
            .clip(RoundedCornerShape(16.dp))
            .clickable { onClick() }
            .liquidGlass(
                shape = RoundedCornerShape(16.dp),
                color = NotelSurface,
                alpha = 0.8f,
                showBorder = true
            )
            .padding(horizontal = 16.dp, vertical = 14.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(36.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(NotelPrimary.copy(alpha = 0.12f)),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = Icons.Default.Lightbulb,
                    contentDescription = null,
                    tint = NotelPrimary,
                    modifier = Modifier.size(18.dp)
                )
            }
            Spacer(Modifier.width(14.dp))
            Text(
                text = topic,
                color = NotelTextPrimary,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                lineHeight = 19.sp,
                modifier = Modifier.weight(1f)
            )
            Spacer(Modifier.width(8.dp))
            Icon(
                imageVector = Icons.Default.ChevronRight,
                contentDescription = null,
                tint = NotelTextSecondary.copy(alpha = 0.5f),
                modifier = Modifier.size(20.dp)
            )
        }
    }
}

@Composable
private fun TipRow(index: Int, text: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .border(
                BorderStroke(1.dp, Color.White.copy(alpha = 0.04f)),
                shape = RoundedCornerShape(16.dp)
            )
            .background(NotelSurfaceHigh.copy(alpha = 0.06f), shape = RoundedCornerShape(16.dp))
            .padding(14.dp),
        verticalAlignment = Alignment.Top
    ) {
        Box(
            modifier = Modifier
                .size(24.dp)
                .clip(RoundedCornerShape(6.dp))
                .background(NotelPrimary.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = index.toString(),
                color = NotelPrimary,
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold
            )
        }
        Spacer(Modifier.width(12.dp))
        Text(
            text = text,
            color = NotelTextPrimary,
            fontSize = 14.sp,
            lineHeight = 20.sp,
            modifier = Modifier.weight(1f)
        )
    }
}
