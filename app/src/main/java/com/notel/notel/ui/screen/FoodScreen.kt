package com.notel.notel.ui.screen

import androidx.compose.animation.*
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
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
import com.notel.notel.ui.viewmodel.FoodCheckResult
import com.notel.notel.ui.viewmodel.FoodTopicLevel
import com.notel.notel.ui.viewmodel.FoodViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FoodScreen(
    onBack: () -> Unit = {},
    viewModel: FoodViewModel = hiltViewModel()
) {
    val searchQuery by viewModel.searchQuery.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    val lastCheckResults by viewModel.lastCheckResults.collectAsState()
    val recentSearches by viewModel.recentSearches.collectAsState()

    var inputVal by remember { mutableStateOf("") }
    
    // Update input text when search query updates (useful for tapping recent items)
    LaunchedEffect(searchQuery) {
        if (searchQuery.isNotEmpty()) {
            inputVal = searchQuery
        }
    }

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = "Food Sensitivity",
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
            contentPadding = PaddingValues(bottom = 60.dp, top = 8.dp)
        ) {
            // Search Input Block
            item {
                Column(modifier = Modifier.fillMaxWidth()) {
                    Text(
                        text = "Check sensitivity triggers and nutritional levels.",
                        color = NotelTextSecondary,
                        fontSize = 13.sp,
                        modifier = Modifier.padding(bottom = 12.dp)
                    )
                    
                    OutlinedTextField(
                        value = inputVal,
                        onValueChange = { inputVal = it },
                        placeholder = { Text("e.g. spinach, coffee, avocado, aged cheese") },
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(16.dp),
                        singleLine = true,
                        trailingIcon = {
                            if (inputVal.isNotEmpty()) {
                                IconButton(onClick = { inputVal = "" }) {
                                    Icon(Icons.Default.Close, null, tint = NotelTextSecondary)
                                }
                            }
                        },
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor    = NotelPrimary.copy(alpha = 0.5f),
                            unfocusedBorderColor  = NotelSurfaceHigh.copy(alpha = 0.2f),
                            focusedTextColor      = NotelTextPrimary,
                            unfocusedTextColor    = NotelTextPrimary,
                            focusedContainerColor   = NotelSurfaceHigh.copy(alpha = 0.05f),
                            unfocusedContainerColor = NotelSurfaceHigh.copy(alpha = 0.05f)
                        )
                    )
                    
                    Spacer(Modifier.height(12.dp))
                    
                    Button(
                        onClick = {
                            viewModel.setSearchQuery(inputVal)
                            viewModel.checkFoodLevels(inputVal)
                        },
                        enabled = inputVal.isNotBlank() && !isLoading,
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(50.dp),
                        shape = RoundedCornerShape(16.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = NotelPrimary,
                            disabledContainerColor = NotelSurfaceHigh.copy(alpha = 0.15f)
                        )
                    ) {
                        if (isLoading) {
                            CircularProgressIndicator(
                                color = Color.White,
                                modifier = Modifier.size(24.dp),
                                strokeWidth = 2.dp
                            )
                        } else {
                            Icon(Icons.Default.Search, null, tint = Color.White)
                            Spacer(Modifier.width(8.dp))
                            Text("Check Sensitivity", color = Color.White, fontWeight = FontWeight.Bold)
                        }
                    }
                }
            }

            // Error Display
            if (errorMessage != null) {
                item {
                    Surface(
                        color = Color(0xFF2C1E1E),
                        border = BorderStroke(1.dp, Color(0xFFD32F2F).copy(alpha = 0.3f)),
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Row(
                            modifier = Modifier.padding(14.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Icon(Icons.Default.Error, null, tint = Color(0xFFEF5350))
                            Spacer(Modifier.width(10.dp))
                            Text(
                                text = errorMessage ?: "",
                                color = Color(0xFFFFCDD2),
                                fontSize = 13.sp,
                                modifier = Modifier.weight(1f)
                            )
                            IconButton(onClick = { viewModel.clearError() }) {
                                Icon(Icons.Default.Close, null, tint = Color(0xFFFFCDD2), modifier = Modifier.size(16.dp))
                            }
                        }
                    }
                }
            }

            // Results Section
            if (lastCheckResults.isNotEmpty() && !isLoading) {
                item {
                    Text(
                        text = "Results",
                        fontSize = 17.sp,
                        fontWeight = FontWeight.Bold,
                        color = NotelTextPrimary
                    )
                }

                items(lastCheckResults, key = { it.foodName }) { result ->
                    FoodResultCard(result = result)
                }
            }

            // Recent Queries (Encyclopedia history)
            if (recentSearches.isNotEmpty()) {
                item {
                    Spacer(Modifier.height(10.dp))
                    Text(
                        text = "Recently Checked",
                        fontSize = 15.sp,
                        fontWeight = FontWeight.Bold,
                        color = NotelTextPrimary
                    )
                }

                item {
                    FlowRow(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        recentSearches.forEach { name ->
                            Surface(
                                shape = RoundedCornerShape(10.dp),
                                color = NotelSurfaceHigh.copy(alpha = 0.08f),
                                border = BorderStroke(1.dp, Color.White.copy(alpha = 0.05f)),
                                modifier = Modifier.clickable {
                                    viewModel.setSearchQuery(name)
                                    viewModel.checkFoodLevels(name)
                                }
                            ) {
                                Text(
                                    text = name.replaceFirstChar { it.uppercase() },
                                    color = NotelTextSecondary,
                                    fontSize = 12.sp,
                                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp)
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun FoodResultCard(result: FoodCheckResult) {
    var expanded by remember { mutableStateOf(true) }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .border(
                width = 1.dp,
                color = NotelPrimary.copy(alpha = 0.08f),
                shape = RoundedCornerShape(20.dp)
            )
            .clip(RoundedCornerShape(20.dp))
            .clickable { expanded = !expanded }
            .liquidGlass(
                shape = RoundedCornerShape(20.dp),
                color = NotelSurface,
                alpha = 0.8f,
                showBorder = true
            )
            .padding(16.dp)
    ) {
        Column(modifier = Modifier.fillMaxWidth()) {
            // Card Title Row
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        modifier = Modifier
                            .size(34.dp)
                            .clip(RoundedCornerShape(8.dp))
                            .background(NotelPrimary.copy(alpha = 0.12f)),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            imageVector = Icons.Default.Restaurant,
                            contentDescription = null,
                            tint = NotelPrimary,
                            modifier = Modifier.size(16.dp)
                        )
                    }
                    Spacer(Modifier.width(12.dp))
                    Text(
                        text = result.foodName.replaceFirstChar { it.uppercase() },
                        fontSize = 17.sp,
                        fontWeight = FontWeight.Bold,
                        color = NotelTextPrimary
                    )
                }
                
                Icon(
                    imageVector = if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                    contentDescription = null,
                    tint = NotelTextSecondary
                )
            }

            AnimatedVisibility(
                visible = expanded,
                enter = expandVertically() + fadeIn(),
                exit = shrinkVertically() + fadeOut()
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 18.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp)
                ) {
                    result.levels.forEach { topicLevel ->
                        TopicLevelRow(topicLevel = topicLevel)
                    }
                }
            }
        }
    }
}

@Composable
private fun TopicLevelRow(topicLevel: FoodTopicLevel) {
    // Determine colors for level badges
    val (badgeColor, badgeBg) = when (topicLevel.level) {
        "High" -> Pair(Color(0xFFFF5252), Color(0xFFFF5252).copy(alpha = 0.12f))     // Crimson Red
        "Medium" -> Pair(Color(0xFFFFA726), Color(0xFFFFA726).copy(alpha = 0.12f))   // Warm Amber/Orange
        else -> Pair(Color(0xFF66BB6A), Color(0xFF66BB6A).copy(alpha = 0.12f))       // Emerald Green
    }

    Column(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = topicLevel.topicName,
                fontSize = 14.sp,
                fontWeight = FontWeight.Bold,
                color = NotelTextPrimary
            )
            
            Surface(
                color = badgeBg,
                shape = RoundedCornerShape(8.dp),
                border = BorderStroke(1.dp, badgeColor.copy(alpha = 0.4f))
            ) {
                Text(
                    text = topicLevel.level,
                    color = badgeColor,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp)
                )
            }
        }
        
        Spacer(Modifier.height(4.dp))
        
        Text(
            text = topicLevel.reasoning,
            fontSize = 13.sp,
            color = NotelTextSecondary,
            lineHeight = 18.sp,
            modifier = Modifier.padding(start = 2.dp, end = 12.dp)
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun FlowRow(
    modifier: Modifier = Modifier,
    horizontalArrangement: Arrangement.Horizontal = Arrangement.Start,
    verticalArrangement: Arrangement.Vertical = Arrangement.Top,
    content: @Composable () -> Unit
) {
    androidx.compose.foundation.layout.FlowRow(
        modifier = modifier,
        horizontalArrangement = horizontalArrangement,
        verticalArrangement = verticalArrangement
    ) {
        content()
    }
}
