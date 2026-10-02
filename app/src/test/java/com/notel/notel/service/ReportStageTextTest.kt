package com.notel.notel.service

import com.notel.notel.ui.state.ReportGenerationState
import org.junit.Assert.*
import org.junit.Test
import java.io.File

/**
 * Foreground-service notification copy: every pipeline stage maps to a
 * short plain-language line, and terminal states fall back to the generic
 * "generating" text (they're transient on the persistent notification).
 */
class ReportStageTextTest {

    @Test
    fun `each processing stage has its own text`() {
        assertEquals(
            "Collecting your health data…",
            ReportStageText.text(ReportGenerationState.CollectingData())
        )
        assertEquals(
            "Syncing health metrics…",
            ReportStageText.text(ReportGenerationState.RefreshingHealthData())
        )
        assertEquals(
            "Generating AI clinical summary…",
            ReportStageText.text(ReportGenerationState.BuildingSummary())
        )
        assertEquals(
            "Rendering your PDF…",
            ReportStageText.text(ReportGenerationState.RenderingPdf())
        )
        assertEquals(
            "Saving your report…",
            ReportStageText.text(ReportGenerationState.SavingFile())
        )
    }

    @Test
    fun `terminal states fall back to generic text`() {
        val generic = "Generating your report…"
        assertEquals(generic, ReportStageText.text(ReportGenerationState.Idle))
        assertEquals(generic, ReportStageText.text(ReportGenerationState.Cancelled))
        assertEquals(
            generic,
            ReportStageText.text(ReportGenerationState.Ready(File("x.pdf")))
        )
        assertEquals(
            generic,
            ReportStageText.text(ReportGenerationState.Failed("nope"))
        )
    }
}
