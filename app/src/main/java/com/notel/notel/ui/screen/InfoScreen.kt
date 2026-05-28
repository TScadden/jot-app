package com.notel.notel.ui.screen

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.notel.notel.ui.theme.*

data class InfoTile(
    val title: String,
    val icon: ImageVector,
    val description: String
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InfoScreen(
    onBack: () -> Unit = {},
    onSleepClick: () -> Unit = {},
    onKeyMetricsClick: () -> Unit = {},
    onCoachClick: () -> Unit = {},
    onTipsAndTricksClick: () -> Unit = {},
    onFoodClick: () -> Unit = {}
) {
    val tiles = listOf(
        InfoTile("Sleep", Icons.Default.Bedtime, "Analysis & Debt"),
        InfoTile("Tips and Tricks", Icons.Default.Lightbulb, "Master your data"),
        InfoTile("Health Coach", Icons.Default.QuestionMark, "Personalized Advice"),
        InfoTile("Key Metrics", Icons.Default.BarChart, "Your Body Data"),
        InfoTile("Food", Icons.Default.Restaurant, "Sensitivity Checker")
    )

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = { 
                    Text(
                        "Information Center", 
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        color = NotelTextPrimary
                    ) 
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = NotelBackground)
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp)
        ) {
            Text(
                text = "Explore your health resources and deep insights.",
                color = NotelTextSecondary,
                fontSize = 14.sp,
                modifier = Modifier.padding(bottom = 24.dp)
            )

            LazyVerticalGrid(
                columns = GridCells.Fixed(2),
                horizontalArrangement = Arrangement.spacedBy(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
                contentPadding = PaddingValues(bottom = 100.dp),
                modifier = Modifier.fillMaxSize()
            ) {
                items(tiles) { tile ->
                    InfoTileCard(
                        tile = tile,
                        onSleepClick = onSleepClick,
                        onKeyMetricsClick = onKeyMetricsClick,
                        onCoachClick = onCoachClick,
                        onTipsAndTricksClick = onTipsAndTricksClick,
                        onFoodClick = onFoodClick
                    )
                }
            }
        }
    }
}

@Composable
fun InfoTileCard(
    tile: InfoTile,
    onSleepClick: () -> Unit,
    onKeyMetricsClick: () -> Unit,
    onCoachClick: () -> Unit,
    onTipsAndTricksClick: () -> Unit,
    onFoodClick: () -> Unit
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(1f) // Square tiles
            // Neon Glow layers
            .border(
                width = 3.dp,
                color = NotelPrimary.copy(alpha = 0.12f),
                shape = RoundedCornerShape(26.dp)
            )
            .border(
                width = 6.dp,
                color = NotelPrimary.copy(alpha = 0.04f),
                shape = RoundedCornerShape(28.dp)
            )
            .clip(RoundedCornerShape(24.dp))
            .clickable { 
                when (tile.title) {
                    "Sleep" -> onSleepClick()
                    "Key Metrics" -> onKeyMetricsClick()
                    "Health Coach" -> onCoachClick()
                    "Tips and Tricks" -> onTipsAndTricksClick()
                    "Food" -> onFoodClick()
                }
            }
            .liquidGlass(
                shape = RoundedCornerShape(24.dp),
                color = NotelSurface,
                alpha = 0.8f,
                showBorder = true
            )
            .padding(20.dp)
    ) {
        Column(
            modifier = Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.SpaceBetween,
            horizontalAlignment = Alignment.Start
        ) {
            Icon(
                imageVector = tile.icon,
                contentDescription = null,
                tint = NotelPrimary,
                modifier = Modifier.size(32.dp)
            )
            
            Column {
                Text(
                    text = tile.title,
                    color = NotelTextPrimary,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.Bold,
                    lineHeight = 22.sp
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    text = tile.description,
                    color = NotelTextSecondary,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium
                )
            }
        }
    }
}
