package com.notel.notel.data.local.entity

import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * A generated Progress Report persisted for later open/share/delete
 * (Phase 2, WS-G).
 *
 * The PDF itself lives in Downloads (via MediaStore); this row holds the
 * durable content-URI reference plus the metadata that identifies the
 * version. Refresh never overwrites: it inserts a new row with a bumped
 * [version]. A null/empty [pdfUri], or a URI that no longer resolves,
 * surfaces as an honest "file unavailable" state in the UI.
 */
@Entity(tableName = "saved_reports")
data class SavedReport(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    /** Human title, e.g. "Health report · Last 30 days". Version is separate. */
    val title: String,
    val focusKey: String,
    val focusText: String = "",
    /** ReportRange.prefsKey: last30days | alltime | sincelastmeeting | custom */
    val rangeType: String,
    val rangeStartMs: Long,
    val rangeEndMs: Long,
    val generatedAtMs: Long = System.currentTimeMillis(),
    /** ScheduledReportEvent id that produced this draft (WS-H); null for manual. */
    val eventId: String? = null,
    /** Downloads MediaStore content URI string; null when the copy failed. */
    val pdfUri: String? = null,
    val version: Int = 1,
    val isRawFallback: Boolean = false,
    val isSynthetic: Boolean = false,
    /** CSV of the custom-focus category ids (for faithful refresh). */
    val customCategoryIdsCsv: String = ""
)
