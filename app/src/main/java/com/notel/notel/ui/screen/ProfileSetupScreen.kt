package com.notel.notel.ui.screen

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.UploadFile
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
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
    var uploadedFileName by remember { mutableStateOf<String?>( null) }

    val filePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.GetContent()
    ) { uri ->
        uri?.let {
            // Derive display name
            val cursor = context.contentResolver.query(it, null, null, null, null)
            val displayName = cursor?.use { c ->
                if (c.moveToFirst()) {
                    val idx = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                    if (idx != -1) c.getString(idx) else null
                } else null
            } ?: "Document"
            uploadedFileName = displayName
            settingsViewModel.ingestFile(it, context.contentResolver)
        }
    }
    
    // Pre-fill once when server data arrives
    LaunchedEffect(serverContext) {
        if (profileText.isBlank() && serverContext.isNotBlank()) {
            profileText = serverContext
        }
    }

    val wordCount = profileText.trim().split("\\s+".toRegex()).count { it.isNotBlank() }
    val isReady = wordCount >= 10

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = { Text("Profile Setup", fontWeight = FontWeight.Black, color = NotelTextPrimary) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = NotelBackground)
            )
        }
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
            
            Text("Welcome to Jot", fontSize = 28.sp, fontWeight = FontWeight.ExtraBold, color = NotelPrimary)
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                "Let's build your Jot experience. Tell us why you're using this app. Are you training for a race? Managing a health condition? Detail your goals below so Jot can customize its AI models to your lifestyle.",
                color = NotelTextSecondary,
                fontSize = 14.sp
            )
            
            Spacer(modifier = Modifier.height(24.dp))
            
            OutlinedTextField(
                value = profileText,
                onValueChange = { profileText = it },
                label = { Text("I am training for a race and I want to focus on...", color = NotelTextSecondary) },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(200.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = NotelPrimary,
                    unfocusedBorderColor = NotelTextSecondary,
                    focusedTextColor = NotelTextPrimary,
                    unfocusedTextColor = NotelTextPrimary,
                    cursorColor = NotelPrimary
                ),
                maxLines = 10
            )
            
            Row(modifier = Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(if (wordCount < 100) "Keep going! The more context, the better the AI." else "Great context!", color = if (wordCount < 100) NotelPrimary else Color.Green, fontSize = 12.sp)
                Text("$wordCount / 100 words", color = NotelTextSecondary, fontSize = 12.sp)
            }
            
            Spacer(modifier = Modifier.height(24.dp))
            
            GlassyButton(
                onClick = { filePicker.launch("*/*") },
                modifier = Modifier.fillMaxWidth(),
                containerColor = NotelSurfaceHigh
            ) {
                if (uploadedFileName != null) {
                    Icon(Icons.Default.CheckCircle, "Uploaded", tint = Color(0xFF4CAF50))
                    Spacer(Modifier.width(8.dp))
                    Text(uploadedFileName!!, color = Color(0xFF4CAF50), fontWeight = FontWeight.SemiBold, maxLines = 1)
                } else {
                    Icon(Icons.Default.UploadFile, "Upload", tint = NotelPrimary)
                    Spacer(Modifier.width(8.dp))
                    Text("Upload Documents (Optional)", color = NotelTextPrimary, fontWeight = FontWeight.SemiBold)
                }
            }
            
            Spacer(modifier = Modifier.height(48.dp))
            
            GlassyButton(
                onClick = {
                    viewModel.saveProfileData(profileText)
                    onNavigateNext()
                },
                modifier = Modifier.fillMaxWidth(),
                enabled = isReady
            ) {
                Text("Next Step", color = if (isReady) Color.White else Color.Gray, fontWeight = FontWeight.Bold, fontSize = 18.sp)
            }
            
            Spacer(modifier = Modifier.height(32.dp))
        }
    }
}
