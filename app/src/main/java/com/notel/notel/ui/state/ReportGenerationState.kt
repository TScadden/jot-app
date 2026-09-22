package com.notel.notel.ui.state

import com.notel.notel.data.model.ClinicalReportData
import java.io.File

sealed class ReportGenerationState {
    object Idle : ReportGenerationState()
    
    data class CollectingData(val stageLabel: String = "Collecting patient data...") : ReportGenerationState()
    
    data class RefreshingHealthData(val stageLabel: String = "Syncing health metrics...") : ReportGenerationState()
    
    data class BuildingSummary(val stageLabel: String = "Generating AI clinical summary...") : ReportGenerationState()
    
    data class RenderingPdf(val stageLabel: String = "Rendering charts and PDF document...") : ReportGenerationState()
    
    data class SavingFile(val stageLabel: String = "Saving PDF file...") : ReportGenerationState()
    
    data class Ready(
        val file: File,
        val isPartial: Boolean = false,
        val isRawFallback: Boolean = false
    ) : ReportGenerationState()
    
    data class Failed(
        val message: String,
        val allowRawFallback: Boolean = false,
        val reportData: ClinicalReportData? = null
    ) : ReportGenerationState()
    
    object Cancelled : ReportGenerationState()

    val isProcessing: Boolean
        get() = this is CollectingData ||
                this is RefreshingHealthData ||
                this is BuildingSummary ||
                this is RenderingPdf ||
                this is SavingFile
}
