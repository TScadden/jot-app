package com.notel.notel

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Save
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import com.notel.notel.data.repository.LogRepository
import com.notel.notel.ui.theme.NotelBackground
import com.notel.notel.ui.theme.NotelPrimary
import com.notel.notel.ui.theme.NotelSurface
import com.notel.notel.ui.theme.NotelSurfaceHigh
import com.notel.notel.ui.theme.NotelTextPrimary
import com.notel.notel.ui.theme.NotelTextSecondary
import com.notel.notel.ui.theme.GlassySpinner
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.launch
import java.util.Locale
import javax.inject.Inject

@AndroidEntryPoint
class VoiceLogActivity : ComponentActivity() {

    @Inject
    lateinit var logRepository: LogRepository

    private var speechRecognizer: SpeechRecognizer? = null
    
    // Manage speech state at the activity level using Compose state properties
    private var isListening by mutableStateOf(false)
    private var recognizedText by mutableStateOf("")
    private var partialText by mutableStateOf("")
    private var errorMessage by mutableStateOf<String?>(null)

    // Flag to track active/foreground status to prevent background restarts
    private var isActivityActive = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        initSpeechRecognizer()

        setContent {
            val scope = rememberCoroutineScope()
            var isProcessing by remember { mutableStateOf(false) } // State for AI thinking

            VoiceLogScreen(
                isProcessing = isProcessing,
                isListening = isListening,
                recognizedText = recognizedText,
                partialText = partialText,
                errorMessage = errorMessage,
                onStartListening = { startListening() },
                onFinish = { finish() },
                onSendToAI = { text, useAI ->
                    isProcessing = useAI
                    scope.launch {
                        try {
                            logRepository.handleVoiceNote(text, useAI = useAI)
                            setResult(RESULT_OK, Intent().apply {
                                putExtra("VOICE_LOG_SUCCESS", true)
                                putExtra("VOICE_LOG_MESSAGE", "Voice entry logged")
                            })
                            finish()
                        } catch (e: Exception) {
                            isProcessing = false
                            setResult(RESULT_CANCELED, Intent().apply {
                                putExtra("VOICE_LOG_ERROR", "Note logging failed.")
                            })
                            finish()
                        }
                    }
                }
            )
        }
    }

    private fun initSpeechRecognizer() {
        if (speechRecognizer == null) {
            speechRecognizer = SpeechRecognizer.createSpeechRecognizer(this).apply {
                setRecognitionListener(object : RecognitionListener {
                    override fun onReadyForSpeech(params: Bundle?) {
                        isListening = true
                        errorMessage = null
                    }
                    override fun onBeginningOfSpeech() {
                        isListening = true
                    }
                    override fun onRmsChanged(rmsdB: Float) {}
                    override fun onBufferReceived(buffer: ByteArray?) {}
                    override fun onEndOfSpeech() {
                        isListening = false
                    }
                    override fun onError(error: Int) {
                        isListening = false
                        // Only restart if the activity is explicitly active in the foreground
                        if (isActivityActive && (error == SpeechRecognizer.ERROR_NO_MATCH || error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT)) {
                            startListening()
                        } else {
                            if (error != SpeechRecognizer.ERROR_CLIENT) {
                                errorMessage = "Recognition issue. Try again."
                            }
                        }
                    }
                    override fun onResults(results: Bundle?) {
                        val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        if (!matches.isNullOrEmpty()) {
                            val newText = matches[0]
                            recognizedText = if (recognizedText.isEmpty()) newText else "$recognizedText $newText"
                        }
                        partialText = ""
                        // Only restart if the activity is explicitly active in the foreground
                        if (isActivityActive) {
                            startListening()
                        }
                    }
                    override fun onPartialResults(partialResults: Bundle?) {
                        val matches = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        if (!matches.isNullOrEmpty()) {
                            partialText = matches[0]
                        }
                    }
                    override fun onEvent(eventType: Int, params: Bundle?) {}
                })
            }
        }
    }

    private fun startListening() {
        if (!isActivityActive) return
        
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            initSpeechRecognizer()
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault())
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 30000L)
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 30000L)
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS, 30000L)
            }
            try {
                speechRecognizer?.startListening(intent)
                isListening = true
            } catch (e: Exception) {
                errorMessage = "Failed to start listening."
            }
        }
    }

    private fun stopListening() {
        try {
            speechRecognizer?.stopListening()
        } catch (e: Exception) {
            // Ignore
        }
        isListening = false
    }

    override fun onStart() {
        super.onStart()
        isActivityActive = true
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            startListening()
        }
    }

    override fun onStop() {
        super.onStop()
        isActivityActive = false
        stopListening()
        destroySpeechRecognizer()
    }

    private fun destroySpeechRecognizer() {
        try {
            speechRecognizer?.destroy()
        } catch (e: Exception) {
            // Ignore
        }
        speechRecognizer = null
    }

    override fun onDestroy() {
        super.onDestroy()
        destroySpeechRecognizer()
    }
}

@Composable
fun VoiceLogScreen(
    isProcessing: Boolean = false,
    isListening: Boolean,
    recognizedText: String,
    partialText: String,
    errorMessage: String?,
    onStartListening: () -> Unit,
    onFinish: () -> Unit,
    onSendToAI: (String, Boolean) -> Unit
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    
    if (isProcessing) {
        // AI Thinking State
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black.copy(alpha = 0.6f))
                .padding(24.dp),
            contentAlignment = Alignment.Center
        ) {
            Surface(
                modifier = Modifier.fillMaxWidth().wrapContentHeight().clip(RoundedCornerShape(32.dp)),
                color = NotelSurface,
                tonalElevation = 8.dp
            ) {
                Column(
                    modifier = Modifier.padding(32.dp).fillMaxWidth(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(16.dp)
                ) {
                    GlassySpinner(size = 56.dp)
                    Text("Cleaning with AI...", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = NotelTextPrimary)
                    Text("Performing surgical cleanup of your log...", style = MaterialTheme.typography.bodyMedium, color = NotelTextSecondary, textAlign = TextAlign.Center)
                }
            }
        }
        return
    }
    
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { isGranted ->
        if (isGranted) {
            onStartListening()
        }
    }

    LaunchedEffect(Unit) {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            onStartListening()
        } else {
            permissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    val infiniteTransition = rememberInfiniteTransition(label = "ripple")
    val rippleScale by infiniteTransition.animateFloat(
        initialValue = 1f,
        targetValue = 1.4f,
        animationSpec = infiniteRepeatable(
            animation = tween(1200, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "scale"
    )
    val rippleAlpha by infiniteTransition.animateFloat(
        initialValue = 0.5f,
        targetValue = 0f,
        animationSpec = infiniteRepeatable(
            animation = tween(1200, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "alpha"
    )

    Box(
        modifier = androidx.compose.ui.Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.6f)) // Dim background
            .padding(24.dp),
        contentAlignment = Alignment.Center
    ) {
        Surface(
            modifier = Modifier
                .fillMaxWidth()
                .wrapContentHeight()
                .clip(RoundedCornerShape(32.dp)),
            color = NotelSurface,
            tonalElevation = 8.dp,
            shadowElevation = 12.dp
        ) {
            Column(
                modifier = Modifier.padding(32.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(24.dp)
            ) {
                // Mic Icon with Ripple
                Box(contentAlignment = Alignment.Center) {
                    if (isListening) {
                        Box(
                            modifier = Modifier
                                .size(80.dp)
                                .scale(rippleScale)
                                .background(NotelPrimary.copy(alpha = rippleAlpha), CircleShape)
                        )
                    }
                    Surface(
                        shape = CircleShape,
                        color = if (isListening) NotelPrimary else NotelTextSecondary.copy(alpha = 0.2f),
                        modifier = Modifier.size(80.dp)
                    ) {
                        Icon(
                            Icons.Default.Mic,
                            contentDescription = "Mic",
                            tint = if (isListening) Color.White else NotelTextSecondary,
                            modifier = Modifier.padding(20.dp).fillMaxSize()
                        )
                    }
                }

                Text(
                    text = if (errorMessage != null) "Recognition Issue" else "Voice AI Log",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.ExtraBold,
                    color = NotelTextPrimary
                )

                Text(
                    text = buildAnnotatedString {
                        if (errorMessage != null) {
                            append(errorMessage)
                        } else {
                            append(recognizedText)
                            if (partialText.isNotBlank()) {
                                if (recognizedText.isNotEmpty()) append(" ")
                                withStyle(SpanStyle(color = NotelTextSecondary.copy(alpha = 0.4f))) {
                                    append(partialText)
                                }
                            }
                            if (recognizedText.isEmpty() && partialText.isEmpty()) {
                                withStyle(SpanStyle(color = NotelTextSecondary.copy(alpha = 0.3f))) {
                                    append("Waiting to hear you...")
                                }
                            }
                        }
                    },
                    fontSize = 18.sp,
                    color = if (errorMessage != null) MaterialTheme.colorScheme.error else NotelTextSecondary,
                    fontWeight = FontWeight.Medium,
                    textAlign = TextAlign.Center,
                    lineHeight = 24.sp,
                    modifier = Modifier.fillMaxWidth().heightIn(min = 60.dp)
                )

                Spacer(Modifier.height(8.dp))

                // Action Row
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    // Option 1: Save Raw
                    Button(
                        onClick = { onSendToAI(recognizedText, false) },
                        enabled = recognizedText.isNotBlank() && recognizedText != "Listening...",
                        colors = ButtonDefaults.buttonColors(containerColor = NotelSurfaceHigh),
                        shape = RoundedCornerShape(16.dp),
                        modifier = Modifier.weight(1f)
                    ) {
                        Icon(Icons.Default.Save, null, tint = NotelTextPrimary, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text("Save Raw", color = NotelTextPrimary, fontWeight = FontWeight.Bold, fontSize = 13.sp)
                    }

                    // Option 2: Clean with AI
                    Button(
                        onClick = { onSendToAI(recognizedText, true) },
                        enabled = recognizedText.isNotBlank() && recognizedText != "Listening...",
                        colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary),
                        shape = RoundedCornerShape(16.dp),
                        modifier = Modifier.weight(1f)
                    ) {
                        Icon(Icons.Default.AutoAwesome, null, tint = Color.White, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text("Clean AI", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 13.sp)
                    }
                }

                Button(
                    onClick = onFinish,
                    colors = ButtonDefaults.buttonColors(containerColor = NotelTextSecondary.copy(alpha = 0.1f)),
                    shape = RoundedCornerShape(16.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Icon(Icons.Default.Close, null, tint = NotelTextPrimary, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Cancel", color = NotelTextPrimary, fontWeight = FontWeight.Bold)
                }
            }
        }
    }
}
