package com.notel.notel.ui.component

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.notel.notel.ui.theme.NotelPrimary
import com.notel.notel.ui.theme.NotelTextPrimary
import com.notel.notel.ui.theme.NotelTextSecondary

/**
 * Tabs Lab quick actions row on Home: one-tap migraine attack start and
 * fast syncope/near-syncope logging.
 */
@Composable
fun LabQuickActions(
    onMigraine: () -> Unit,
    onSyncope: () -> Unit,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
    ) {
        Text(
            text = "Quick log",
            fontWeight = FontWeight.SemiBold,
            fontSize = 13.sp,
            color = NotelTextSecondary,
            modifier = Modifier.padding(bottom = 8.dp)
        )
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Surface(
                modifier = Modifier
                    .weight(1f)
                    .clickable(onClick = onMigraine),
                shape = RoundedCornerShape(14.dp),
                color = NotelPrimary.copy(alpha = 0.08f),
                border = BorderStroke(1.dp, NotelPrimary.copy(alpha = 0.22f))
            ) {
                Row(
                    modifier = Modifier.padding(vertical = 14.dp, horizontal = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Icon(Icons.Default.Bolt, contentDescription = null, tint = NotelPrimary)
                    Column {
                        Text("Migraine", fontWeight = FontWeight.SemiBold, fontSize = 15.sp, color = NotelTextPrimary)
                        Text("Attack mode", fontSize = 12.sp, color = NotelTextSecondary)
                    }
                }
            }
            Surface(
                modifier = Modifier
                    .weight(1f)
                    .clickable(onClick = onSyncope),
                shape = RoundedCornerShape(14.dp),
                color = NotelPrimary.copy(alpha = 0.08f),
                border = BorderStroke(1.dp, NotelPrimary.copy(alpha = 0.22f))
            ) {
                Row(
                    modifier = Modifier.padding(vertical = 14.dp, horizontal = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Icon(Icons.Default.Favorite, contentDescription = null, tint = NotelPrimary)
                    Column {
                        Text("Faint episode", fontWeight = FontWeight.SemiBold, fontSize = 15.sp, color = NotelTextPrimary)
                        Text("Log syncope", fontSize = 12.sp, color = NotelTextSecondary)
                    }
                }
            }
        }
    }
}
