package com.notel.notel.ui.screen

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.material.icons.Icons
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.sync.SyncManager
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.SettingsViewModel
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class ProfileSetupViewModel @Inject constructor(
    private val preferences: NotelPreferences,
    private val syncManager: SyncManager
) : ViewModel() {
    val existingContext = preferences.userContext

    init {
        // Trigger a pull on start to ensure we have the latest server context
        viewModelScope.launch {
            syncManager.pullAllData()
        }
    }

    fun saveProfileData(profile: String) {
        viewModelScope.launch {
            preferences.setUserContext(profile)
            syncManager.syncAllData()
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProfileSetupScreen(
    viewModel: ProfileSetupViewModel = hiltViewModel(),
    settingsViewModel: SettingsViewModel = hiltViewModel(),
    onNavigateNext: () -> Unit
) {
    val context = LocalContext.current
    val serverContext by viewModel.existingContext.collectAsState(initial = "")
    var profileText by remember { mutableStateOf("") }

    // Track multiple uploaded documents
    val uploadedFiles = remember { mutableStateListOf<String>() }

    // Observe processing state from SettingsViewModel
    val isProcessingFile by settingsViewModel.isProcessingFile.collectAsState()

    val filePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.GetMultipleContents()
    ) { uris ->
        uris.forEach { uri ->
            val cursor = context.contentResolver.query(uri, null, null, null, null)
            val displayName = cursor?.use { c ->
                if (c.moveToFirst()) {
                    val idx = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                    if (idx != -1) c.getString(idx) else null
                } else null
            } ?: "Document"

            if (!uploadedFiles.contains(displayName)) {
                uploadedFiles.add(displayName)
            }
            settingsViewModel.ingestFile(uri, context.contentResolver)
        }
    }

    // Pre-fill once when server data arrives
    LaunchedEffect(serverContext) {
        if (profileText.isBlank() && serverContext.isNotBlank()) {
            profileText = serverContext
        }
    }

    val wordCount = if (profileText.isBlank()) 0 else profileText.trim().split("\\s+".toRegex()).count { it.isNotBlank() }
    val isReady = wordCount >= 10 && !isProcessingFile

    val (feedbackText, feedbackColor) = when {
        wordCount == 0 -> "Provide more context for better AI." to NotelTextSecondary
        wordCount < 10 -> "Keep typing ($wordCount/10 words min)..." to Color(0xFFFF9800)
        wordCount < 30 -> "Good start! Add more details." to NotelPrimary
        wordCount < 60 -> "More detail helps AI personalize results." to Color(0xFF0288D1)
        wordCount < 100 -> "Great context! Almost at 100 words." to Color(0xFF689F38)
        else -> "Optimal AI context reached!" to Color(0xFF4CAF50)
    }

    Scaffold(
        containerColor = NotelBackground
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Spacer(modifier = Modifier.height(16.dp))

            // CENTER FLOATING ORB & HEALTH ICONS GRAPHIC (Same theme as intro)
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(200.dp),
                contentAlignment = Alignment.Center
            ) {
                // Central Glowing Gradient Orb
                Box(
                    modifier = Modifier
                        .size(120.dp)
                        .clip(CircleShape)
                        .background(
                            Brush.radialGradient(
                                colors = listOf(
                                    NotelPrimary.copy(alpha = 0.8f),
                                    NotelAccent.copy(alpha = 0.5f),
                                    Color.Transparent
                                )
                            )
                        )
                )

                // Surrounding Icon Bubble 1 (Top Left)
                IconBubble(
                    icon = Icons.Default.MedicalServices,
                    bubbleColor = Color(0xFF38BDF8),
                    modifier = Modifier
                        .align(Alignment.TopStart)
                        .offset(x = 30.dp, y = 10.dp)
                )

                // Surrounding Icon Bubble 2 (Top Right)
                IconBubble(
                    icon = Icons.Default.Favorite,
                    bubbleColor = Color(0xFFEC4899),
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .offset(x = (-30).dp, y = 20.dp)
                )

                // Surrounding Icon Bubble 3 (Mid Left)
                IconBubble(
                    icon = Icons.Default.Search,
                    bubbleColor = Color(0xFFA855F7),
                    modifier = Modifier
                        .align(Alignment.CenterStart)
                        .offset(x = 10.dp, y = 0.dp)
                )

                // Surrounding Icon Bubble 4 (Mid Right)
                IconBubble(
                    icon = Icons.Default.Psychology,
                    bubbleColor = Color(0xFF8B5CF6),
                    modifier = Modifier
                        .align(Alignment.CenterEnd)
                        .offset(x = (-10).dp, y = 10.dp)
                )

                // Surrounding Icon Bubble 5 (Bottom Left)
                IconBubble(
                    icon = Icons.Default.LocalHospital,
                    bubbleColor = Color(0xFF22C55E),
                    modifier = Modifier
                        .align(Alignment.BottomStart)
                        .offset(x = 40.dp, y = (-10).dp)
                )
            }

            Spacer(modifier = Modifier.height(16.dp))

            OutlinedTextField(
                value = profileText,
                onValueChange = { profileText = it },
                label = { Text("I am training for a race and I want to focus on...", color = NotelTextSecondary) },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(180.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = NotelPrimary,
                    unfocusedBorderColor = NotelTextSecondary,
                    focusedTextColor = NotelTextPrimary,
                    unfocusedTextColor = NotelTextPrimary,
                    cursorColor = NotelPrimary
                ),
                maxLines = 8
            )

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 12.dp),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text(
                    text = feedbackText,
                    color = feedbackColor,
                    fontSize = 12.sp,
                    maxLines = 1,
                    modifier = Modifier.weight(1f).alignByBaseline()
                )
                Text(
                    text = "$wordCount / 100 words",
                    color = NotelTextSecondary,
                    fontSize = 12.sp,
                    maxLines = 1,
                    softWrap = false,
                    modifier = Modifier.padding(start = 8.dp).alignByBaseline()
                )
            }

            Spacer(modifier = Modifier.height(24.dp))

            // Upload Documents section
            Column(modifier = Modifier.fillMaxWidth()) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Text("Upload Documents (Optional)", color = NotelTextPrimary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                    if (isProcessingFile) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            CircularProgressIndicator(
                                color = NotelPrimary,
                                modifier = Modifier.size(16.dp),
                                strokeWidth = 2.dp
                            )
                            Spacer(Modifier.width(6.dp))
                            Text("AI reading...", color = NotelTextSecondary, fontSize = 12.sp)
                        }
                    }
                }

                Spacer(Modifier.height(4.dp))

                Text(
                    "PDF, images with text, text files, etc.",
                    color = NotelTextSecondary,
                    fontSize = 12.sp
                )

                Spacer(Modifier.height(12.dp))

                // Show uploaded files
                if (uploadedFiles.isNotEmpty()) {
                    uploadedFiles.forEachIndexed { index, name ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = 4.dp)
                                .clip(RoundedCornerShape(10.dp))
                                .background(NotelSurface)
                                .border(1.dp, NotelPrimary.copy(alpha = 0.2f), RoundedCornerShape(10.dp))
                                .padding(horizontal = 12.dp, vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Icon(Icons.Default.CheckCircle, "Done", tint = Color(0xFF4CAF50), modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(8.dp))
                            Text(name, color = NotelTextPrimary, fontSize = 13.sp, modifier = Modifier.weight(1f), maxLines = 1)
                            IconButton(
                                onClick = { uploadedFiles.removeAt(index) },
                                modifier = Modifier.size(20.dp)
                            ) {
                                Icon(Icons.Default.Close, "Remove", tint = NotelTextSecondary, modifier = Modifier.size(14.dp))
                            }
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                }

                GlassyButton(
                    onClick = { filePicker.launch("*/*") },
                    modifier = Modifier.fillMaxWidth(),
                    containerColor = NotelSurfaceHigh,
                    enabled = !isProcessingFile
                ) {
                    Icon(Icons.Default.UploadFile, "Upload", tint = if (isProcessingFile) NotelTextSecondary else NotelPrimary)
                    Spacer(Modifier.width(8.dp))
                    Text(
                        if (uploadedFiles.isEmpty()) "Add Documents" else "Add More Documents",
                        color = if (isProcessingFile) NotelTextSecondary else NotelTextPrimary,
                        fontWeight = FontWeight.SemiBold
                    )
                }
            }

            Spacer(modifier = Modifier.height(36.dp))

            GlassyButton(
                onClick = {
                    viewModel.saveProfileData(profileText)
                    onNavigateNext()
                },
                modifier = Modifier.fillMaxWidth(),
                enabled = isReady
            ) {
                if (isProcessingFile) {
                    CircularProgressIndicator(color = Color.White, modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(8.dp))
                    Text("AI is reading your documents...", color = Color.Gray, fontWeight = FontWeight.Bold, fontSize = 16.sp)
                } else {
                    Text("Next Step", color = if (isReady) Color.White else Color.Gray, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                }
            }

            Spacer(modifier = Modifier.height(32.dp))
        }
    }
}

@Composable
private fun IconBubble(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    bubbleColor: Color,
    modifier: Modifier = Modifier
) {
    Box(
        modifier = modifier
            .size(38.dp)
            .clip(CircleShape)
            .background(
                Brush.linearGradient(
                    colors = listOf(bubbleColor, bubbleColor.copy(alpha = 0.7f))
                )
            )
            .border(1.5.dp, Color.White.copy(alpha = 0.6f), CircleShape),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier.size(18.dp)
        )
    }
}
