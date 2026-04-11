package com.notel.notel.ui.screen

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircleOutline
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.HelpOutline
import androidx.compose.material.icons.filled.Link
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.notel.notel.ui.theme.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DataConnectionsScreen(
    onBack: () -> Unit
) {
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
                    Spacer(Modifier.width(48.dp)) // To keep title centered if navigationIcon is present
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
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            ConnectionSection(
                title = "Your connections",
                icon = Icons.Default.Link,
                onClick = { /* TODO */ }
            )

            ConnectionSection(
                title = "Add connections",
                icon = Icons.Default.AddCircleOutline,
                onClick = { /* TODO */ }
            )

            ConnectionSection(
                title = "How to connect a tracker",
                icon = Icons.Default.HelpOutline,
                onClick = { /* TODO */ }
            )
        }
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
        shape = RoundedCornerShape(16.dp),
        color = NotelSurface,
        border = androidx.compose.foundation.BorderStroke(1.dp, NotelSurfaceHigh.copy(alpha = 0.5f))
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
                imageVector = Icons.Default.Link, // Or a ChevronRight equivalent
                contentDescription = null,
                tint = NotelTextSecondary.copy(alpha = 0.5f),
                modifier = Modifier.size(16.dp)
            )
        }
    }
}
