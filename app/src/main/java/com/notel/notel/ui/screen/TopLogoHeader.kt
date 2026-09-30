package com.notel.notel.ui.screen

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.notel.notel.R
import com.notel.notel.ui.theme.NotelPrimary
import com.notel.notel.ui.theme.NotelSurfaceHigh
import com.notel.notel.ui.theme.NotelTextPrimary
import com.notel.notel.ui.theme.NotelTextSecondary

@Composable
fun TopLogoHeader(
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    onSkip: (() -> Unit)? = null
) {
    Box(
        modifier = modifier.fillMaxWidth()
    ) {
        if (onBack != null) {
            IconButton(
                onClick = onBack,
                modifier = Modifier
                    .size(40.dp)
                    .clip(CircleShape)
                    .background(NotelSurfaceHigh)
                    .align(Alignment.CenterStart)
            ) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    tint = NotelTextPrimary
                )
            }
        }

        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center,
            modifier = Modifier.align(Alignment.Center)
        ) {
            Image(
                painter = painterResource(id = R.drawable.ic_tabs_note),
                contentDescription = "Tabs Logo",
                modifier = Modifier.size(28.dp)
            )
            Spacer(Modifier.width(8.dp))
            Text(
                text = "Tabs",
                fontSize = 26.sp,
                fontWeight = FontWeight.Black,
                color = NotelPrimary,
                letterSpacing = 1.sp
            )
        }

        if (onSkip != null) {
            TextButton(
                onClick = onSkip,
                modifier = Modifier.align(Alignment.CenterEnd)
            ) {
                Text(
                    text = "Skip",
                    color = NotelTextSecondary,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Medium
                )
            }
        }
    }
}
