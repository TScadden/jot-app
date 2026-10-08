package com.notel.notel.ui.screen

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.notel.notel.ui.theme.*

/**
 * About screen with the third-party licenses section. New entries slot into
 * [THIRD_PARTY_LICENSES]; each entry carries its notice text plus an optional
 * asset path to the full license text, shown in a scrollable expansion.
 */
data class ThirdPartyLicenseEntry(
    val title: String,
    val body: String,
    val licenseAssetPath: String? = null
)

// NB: the Manawa Pace title/body wording below is Libby's paste-ready attribution
// text (Oct 8, 2026). Per Otto's Oct 8 ruling, the descriptive title uses a colon
// ("Manawa Pace: HRV algorithm") per Tabs' no-dashes UI convention; the em dash
// was Libby's, not the legal NOTICE text. The legal lines ("Manawa Pace" /
// "Copyright 2026 Chris Hilder") are kept verbatim for Apache 2.0 Section 4.
private val MANAWA_PACE_ENTRY = ThirdPartyLicenseEntry(
    title = "Manawa Pace: HRV algorithm",
    body = "Tabs adapts heart rate variability calculation algorithms from Manawa Pace.\n\n" +
        "Copyright 2026 Chris Hilder\n" +
        "Source: https://github.com/cj-hilder/ble-hr-tool\n\n" +
        "The HRV algorithms used in Tabs are adapted from the original Manawa Pace source code and have been modified for use in this app.\n\n" +
        "Licensed under the Apache License, Version 2.0. You can read the full license below.",
    licenseAssetPath = "licenses/apache_2_0_manawa_pace.txt"
)

private val THIRD_PARTY_LICENSES = listOf(MANAWA_PACE_ENTRY)

@Composable
fun AboutScreen(
    onBack: () -> Unit
) {
    val context = LocalContext.current
    val versionName = remember {
        try {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: ""
        } catch (e: Exception) {
            ""
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(NotelBackground)
            .statusBarsPadding()
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = onBack) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    tint = NotelTextPrimary
                )
            }
            Text(
                "About",
                color = NotelTextPrimary,
                fontWeight = FontWeight.Bold,
                fontSize = 20.sp
            )
        }

        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                start = 16.dp,
                end = 16.dp,
                top = 8.dp,
                // Clears the floating bottom navigation dock.
                bottom = 130.dp
            ),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            item {
                Surface(
                    shape = RoundedCornerShape(20.dp),
                    color = NotelSurface,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(modifier = Modifier.padding(20.dp)) {
                        Text(
                            "Tabs Lab",
                            color = NotelTextPrimary,
                            fontWeight = FontWeight.Bold,
                            fontSize = 18.sp
                        )
                        if (versionName.isNotBlank()) {
                            Spacer(Modifier.height(4.dp))
                            Text(
                                "Version $versionName",
                                color = NotelTextSecondary,
                                fontSize = 13.sp
                            )
                        }
                    }
                }
            }

            item {
                Text(
                    "Third party licenses",
                    color = NotelTextPrimary,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 16.sp
                )
            }

            items(THIRD_PARTY_LICENSES.size) { index ->
                ThirdPartyLicenseCard(entry = THIRD_PARTY_LICENSES[index])
            }
        }
    }
}

@Composable
private fun ThirdPartyLicenseCard(entry: ThirdPartyLicenseEntry) {
    val context = LocalContext.current
    var expanded by remember { mutableStateOf(false) }
    val fullText = remember(entry.licenseAssetPath) {
        if (entry.licenseAssetPath == null) null
        else try {
            context.assets.open(entry.licenseAssetPath).bufferedReader().use { it.readText() }
        } catch (e: Exception) {
            null
        }
    }

    Surface(
        shape = RoundedCornerShape(20.dp),
        color = NotelSurface,
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(modifier = Modifier.padding(20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Default.Info,
                    contentDescription = null,
                    tint = NotelPrimary,
                    modifier = Modifier.size(22.dp)
                )
                Spacer(Modifier.width(12.dp))
                Text(
                    entry.title,
                    color = NotelTextPrimary,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 15.sp,
                    modifier = Modifier.weight(1f)
                )
            }
            Spacer(Modifier.height(12.dp))
            entry.body.split("\n\n").forEach { paragraph ->
                Text(
                    paragraph.trim(),
                    color = NotelTextSecondary,
                    fontSize = 13.sp,
                    lineHeight = 19.sp
                )
                Spacer(Modifier.height(8.dp))
            }

            if (fullText != null) {
                Spacer(Modifier.height(4.dp))
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { expanded = !expanded }
                        .padding(vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        if (expanded) "Hide full license" else "View full license",
                        color = NotelPrimary,
                        fontWeight = FontWeight.Medium,
                        fontSize = 14.sp,
                        modifier = Modifier.weight(1f)
                    )
                    Icon(
                        if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                        contentDescription = null,
                        tint = NotelPrimary
                    )
                }
                if (expanded) {
                    Surface(
                        shape = RoundedCornerShape(12.dp),
                        color = NotelBackground,
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 420.dp)
                    ) {
                        Text(
                            fullText,
                            color = NotelTextSecondary,
                            fontSize = 11.sp,
                            lineHeight = 16.sp,
                            modifier = Modifier
                                .padding(12.dp)
                                .verticalScroll(rememberScrollState())
                        )
                    }
                }
            }
        }
    }
}
