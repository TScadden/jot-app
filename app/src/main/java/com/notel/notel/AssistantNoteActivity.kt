package com.notel.notel

import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import com.notel.notel.data.repository.LogRepository
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Silent Activity that handles notes from Google Assistant.
 * It takes the raw voice text, sends it to Gemini for cleaning and categorization,
 * saves it to the database, and then closes.
 */
@AndroidEntryPoint
class AssistantNoteActivity : ComponentActivity() {

    @Inject lateinit var logRepository: LogRepository

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Handle multiple text extras for maximum compatibility
        val text1 = intent.getStringExtra(Intent.EXTRA_TEXT)
        val text2 = intent.getStringExtra("com.google.android.gms.actions.EXTRA_NOTE_TEXT")
        val text3 = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
        
        val noteText = text1 ?: text2 ?: text3 ?: ""
        
        if (noteText.isBlank()) {
            finish()
            return
        }

        // Quick toast so the user knows Jot is working
        Toast.makeText(this, "Jot: Analysis & Saving...", Toast.LENGTH_SHORT).show()

        lifecycleScope.launch {
            try {
                logRepository.handleAssistantNote(noteText).fold(
                    onSuccess = { msg ->
                        Toast.makeText(this@AssistantNoteActivity, msg, Toast.LENGTH_SHORT).show()
                    },
                    onFailure = { 
                        Toast.makeText(this@AssistantNoteActivity, "Failed to save note", Toast.LENGTH_SHORT).show()
                    }
                )
            } catch (e: Exception) {
                Toast.makeText(this@AssistantNoteActivity, "Error: ${e.message}", Toast.LENGTH_SHORT).show()
            } finally {
                finish()
            }
        }
    }
}
