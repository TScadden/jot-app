package com.notel.notel.data.local

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import com.notel.notel.data.local.dao.CategoryDao
import com.notel.notel.data.local.dao.LogEntryDao
import com.notel.notel.data.local.dao.ReminderDao
import com.notel.notel.data.local.dao.UserListDao
import com.notel.notel.data.local.entity.Category
import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.local.entity.Reminder
import com.notel.notel.data.local.entity.UserList
import com.notel.notel.data.local.entity.UserListItem
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

@Database(
    entities = [
        LogEntry::class,
        Category::class,
        com.notel.notel.data.local.entity.KnowledgeDocument::class,
        Reminder::class,
        com.notel.notel.data.local.entity.CoachSession::class,
        com.notel.notel.data.local.entity.CoachMessageEntity::class,
        UserList::class,
        UserListItem::class,
        com.notel.notel.data.local.entity.Medication::class,
        com.notel.notel.data.local.entity.MedicationSideEffectCache::class,
        com.notel.notel.data.local.entity.AiInsight::class,
        com.notel.notel.data.local.entity.ScheduledDoseOccurrence::class,
        com.notel.notel.data.local.entity.InsightEntryCrossRef::class,
        com.notel.notel.data.local.entity.SavedReport::class
    ],
    version = 32,
    exportSchema = true
)
abstract class NotelDatabase : RoomDatabase() {
    abstract fun logEntryDao(): LogEntryDao
    abstract fun categoryDao(): CategoryDao
    abstract fun knowledgeDocumentDao(): com.notel.notel.data.local.dao.KnowledgeDocumentDao
    abstract fun reminderDao(): ReminderDao
    abstract fun coachSessionDao(): com.notel.notel.data.local.dao.CoachSessionDao
    abstract fun coachMessageDao(): com.notel.notel.data.local.dao.CoachMessageDao
    abstract fun userListDao(): UserListDao
    abstract fun medicationDao(): com.notel.notel.data.local.dao.MedicationDao
    abstract fun aiInsightDao(): com.notel.notel.data.local.dao.AiInsightDao
    abstract fun scheduledDoseOccurrenceDao(): com.notel.notel.data.local.dao.ScheduledDoseOccurrenceDao
    abstract fun savedReportDao(): com.notel.notel.data.local.dao.SavedReportDao

    companion object {
        @Volatile private var INSTANCE: NotelDatabase? = null

        val MIGRATION_31_32 = object : Migration(31, 32) {
            override fun migrate(db: SupportSQLiteDatabase) {
                // Phase 2 (WS-G): saved Progress Reports.
                db.execSQL(
                    """
                    CREATE TABLE IF NOT EXISTS saved_reports (
                        id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                        title TEXT NOT NULL,
                        focusKey TEXT NOT NULL,
                        focusText TEXT NOT NULL DEFAULT '',
                        rangeType TEXT NOT NULL,
                        rangeStartMs INTEGER NOT NULL,
                        rangeEndMs INTEGER NOT NULL,
                        generatedAtMs INTEGER NOT NULL,
                        eventId TEXT,
                        pdfUri TEXT,
                        version INTEGER NOT NULL DEFAULT 1,
                        isRawFallback INTEGER NOT NULL DEFAULT 0,
                        isSynthetic INTEGER NOT NULL DEFAULT 0,
                        customCategoryIdsCsv TEXT NOT NULL DEFAULT ''
                    )
                    """.trimIndent()
                )
            }
        }

        val MIGRATION_29_30 = object : Migration(29, 30) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("DROP TABLE IF EXISTS pinned_templates")
            }
        }

        val MIGRATION_30_31 = object : Migration(30, 31) {
            override fun migrate(db: SupportSQLiteDatabase) {
                // Backfill category slugs. The slug column was added in
                // MIGRATION_22_23 without backfilling existing rows, and the
                // onCreate seed did not write slugs, so databases created
                // before this migration have NULL slugs — which broke
                // slug-based filtering (Progress Reports showed 0 entries /
                // 0 categories on the Health preset).
                db.execSQL(
                    """
                    UPDATE categories SET slug = CASE id
                        WHEN 1 THEN 'symptoms'
                        WHEN 2 THEN 'calories'
                        WHEN 3 THEN 'heart_rate'
                        WHEN 4 THEN 'personal'
                        WHEN 5 THEN 'sleep'
                        WHEN 6 THEN 'mood'
                        WHEN 7 THEN 'general'
                        WHEN 8 THEN 'medication'
                        ELSE slug END
                    WHERE slug IS NULL
                    """.trimIndent()
                )
            }
        }

        val MIGRATION_28_29 = object : Migration(28, 29) {
            override fun migrate(db: SupportSQLiteDatabase) {
                try { db.execSQL("ALTER TABLE log_entries ADD COLUMN updatedAt INTEGER NOT NULL DEFAULT 0") } catch (e: Exception) {}
                try { db.execSQL("ALTER TABLE log_entries ADD COLUMN syncState TEXT NOT NULL DEFAULT 'DIRTY'") } catch (e: Exception) {}
            }
        }

        val MIGRATION_27_28 = object : Migration(27, 28) {
            override fun migrate(db: SupportSQLiteDatabase) {
                try { db.execSQL("ALTER TABLE medications ADD COLUMN uuid TEXT NOT NULL DEFAULT ''") } catch (e: Exception) {}
                try { db.execSQL("ALTER TABLE medications ADD COLUMN updatedAt INTEGER NOT NULL DEFAULT 0") } catch (e: Exception) {}
                try { db.execSQL("ALTER TABLE medications ADD COLUMN isDeleted INTEGER NOT NULL DEFAULT 0") } catch (e: Exception) {}
            }
        }

        val MIGRATION_26_27 = object : Migration(26, 27) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE ai_insights ADD COLUMN classification TEXT NOT NULL DEFAULT 'OBSERVATION'")
                db.execSQL("ALTER TABLE ai_insights ADD COLUMN dataUsed TEXT NOT NULL DEFAULT 'Symptom logs, medication records'")
                db.execSQL("ALTER TABLE ai_insights ADD COLUMN dateRangeText TEXT NOT NULL DEFAULT 'Past 7 days'")
                db.execSQL("ALTER TABLE ai_insights ADD COLUMN plainLanguageReason TEXT NOT NULL DEFAULT 'Observed consistency in daily tracking records.'")
                db.execSQL("ALTER TABLE ai_insights ADD COLUMN confidence REAL NOT NULL DEFAULT 0.85")
                db.execSQL("ALTER TABLE ai_insights ADD COLUMN feedbackState TEXT NOT NULL DEFAULT 'NONE'")
                db.execSQL("ALTER TABLE ai_insights ADD COLUMN isDismissed INTEGER NOT NULL DEFAULT 0")

                db.execSQL("""
                    CREATE TABLE IF NOT EXISTS insight_entry_cross_ref (
                        insightId TEXT NOT NULL,
                        entryId INTEGER NOT NULL,
                        PRIMARY KEY(insightId, entryId)
                    )
                """.trimIndent())
                db.execSQL("CREATE INDEX IF NOT EXISTS index_insight_entry_cross_ref_entryId ON insight_entry_cross_ref(entryId)")
            }
        }

        val MIGRATION_25_26 = object : Migration(25, 26) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("DROP INDEX IF EXISTS index_scheduled_dose_occurrences_medicationId_scheduledDate")
                db.execSQL("CREATE UNIQUE INDEX IF NOT EXISTS index_scheduled_dose_occurrences_occurrenceKey ON scheduled_dose_occurrences(occurrenceKey)")
            }
        }

        val MIGRATION_24_25 = object : Migration(24, 25) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("""
                    CREATE TABLE IF NOT EXISTS scheduled_dose_occurrences (
                        id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                        occurrenceKey TEXT NOT NULL,
                        medicationId INTEGER NOT NULL,
                        scheduledDate TEXT NOT NULL,
                        scheduledTime TEXT,
                        status TEXT NOT NULL,
                        actionTimestamp INTEGER NOT NULL,
                        snoozedUntilTimestamp INTEGER,
                        associatedLogEntryId INTEGER,
                        syncState TEXT NOT NULL DEFAULT 'SAVED_LOCALLY'
                    )
                """.trimIndent())
                db.execSQL("CREATE UNIQUE INDEX IF NOT EXISTS index_scheduled_dose_occurrences_medicationId_scheduledDate ON scheduled_dose_occurrences(medicationId, scheduledDate)")
            }
        }

        val MIGRATION_23_24 = object : Migration(23, 24) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("""
                    CREATE TABLE IF NOT EXISTS pinned_templates (
                        id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                        title TEXT NOT NULL,
                        categorySlug TEXT NOT NULL,
                        body TEXT NOT NULL,
                        chipsJson TEXT NOT NULL DEFAULT '[]',
                        sortOrder INTEGER NOT NULL DEFAULT 0,
                        isMedication INTEGER NOT NULL DEFAULT 0
                    )
                """.trimIndent())
            }
        }

        val MIGRATION_22_23 = object : Migration(22, 23) {
            override fun migrate(db: SupportSQLiteDatabase) {
                try {
                    db.execSQL("ALTER TABLE categories ADD COLUMN slug TEXT")
                } catch (e: Exception) { }

                db.execSQL("""
                    CREATE TABLE IF NOT EXISTS ai_insights (
                        id TEXT NOT NULL PRIMARY KEY,
                        text TEXT NOT NULL,
                        timestamp INTEGER NOT NULL,
                        type TEXT NOT NULL,
                        entryId INTEGER,
                        requestId TEXT
                    )
                """.trimIndent())

                db.execSQL("CREATE INDEX IF NOT EXISTS index_ai_insights_entryId ON ai_insights(entryId)")
                db.execSQL("CREATE UNIQUE INDEX IF NOT EXISTS index_ai_insights_requestId ON ai_insights(requestId)")
            }
        }

        private val MIGRATION_11_12 = object : Migration(11, 12) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE log_entries ADD COLUMN source TEXT")
            }
        }

        private val MIGRATION_13_14 = object : Migration(13, 14) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE knowledge_documents ADD COLUMN extractedText TEXT")
            }
        }

        private val MIGRATION_14_15 = object : Migration(14, 15) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("""
                    CREATE TABLE IF NOT EXISTS reminders (
                        id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                        title TEXT NOT NULL,
                        type TEXT NOT NULL,
                        fixedHour INTEGER NOT NULL DEFAULT 12,
                        fixedMinute INTEGER NOT NULL DEFAULT 0,
                        intervalHours INTEGER NOT NULL DEFAULT 2,
                        startHour INTEGER NOT NULL DEFAULT 8,
                        startMinute INTEGER NOT NULL DEFAULT 0,
                        endHour INTEGER NOT NULL DEFAULT 21,
                        endMinute INTEGER NOT NULL DEFAULT 0,
                        isEnabled INTEGER NOT NULL DEFAULT 1
                    )
                """.trimIndent())
            }
        }

        private val MIGRATION_15_16 = object : Migration(15, 16) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("""
                    CREATE TABLE IF NOT EXISTS coach_sessions (
                        id TEXT PRIMARY KEY NOT NULL,
                        title TEXT NOT NULL,
                        createdAt INTEGER NOT NULL,
                        updatedAt INTEGER NOT NULL,
                        isSynced INTEGER NOT NULL DEFAULT 0
                    )
                """.trimIndent())
                
                db.execSQL("""
                    CREATE TABLE IF NOT EXISTS coach_messages (
                        id TEXT PRIMARY KEY NOT NULL,
                        sessionId TEXT NOT NULL,
                        role TEXT NOT NULL,
                        content TEXT NOT NULL,
                        timestamp INTEGER NOT NULL,
                        isSynced INTEGER NOT NULL DEFAULT 0,
                        FOREIGN KEY(sessionId) REFERENCES coach_sessions(id) ON DELETE CASCADE
                    )
                """.trimIndent())
                
                db.execSQL("CREATE INDEX IF NOT EXISTS index_coach_messages_sessionId ON coach_messages(sessionId)")
            }
        }

        private val MIGRATION_16_17 = object : Migration(16, 17) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE reminders ADD COLUMN intervalMinutes INTEGER NOT NULL DEFAULT 0")
            }
        }

        private val MIGRATION_17_18 = object : Migration(17, 18) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("""
                    CREATE TABLE IF NOT EXISTS user_lists (
                        id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                        name TEXT NOT NULL,
                        createdAt INTEGER NOT NULL DEFAULT 0
                    )
                """.trimIndent())
                db.execSQL("""
                    CREATE TABLE IF NOT EXISTS user_list_items (
                        id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                        listId INTEGER NOT NULL,
                        text TEXT NOT NULL,
                        sortOrder INTEGER NOT NULL DEFAULT 0,
                        FOREIGN KEY(listId) REFERENCES user_lists(id) ON DELETE CASCADE
                    )
                """.trimIndent())
                db.execSQL("CREATE INDEX IF NOT EXISTS index_user_list_items_listId ON user_list_items(listId)")
            }
        }

        private val MIGRATION_18_19 = object : Migration(18, 19) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE reminders ADD COLUMN daysOfWeekConfig TEXT NOT NULL DEFAULT ''")
            }
        }

        private val MIGRATION_19_20 = object : Migration(19, 20) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("""
                    CREATE TABLE IF NOT EXISTS medications (
                        id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                        name TEXT NOT NULL,
                        dose TEXT NOT NULL,
                        frequency TEXT NOT NULL,
                        timesPerDay INTEGER NOT NULL DEFAULT 1,
                        notes TEXT NOT NULL DEFAULT '',
                        isArchived INTEGER NOT NULL DEFAULT 0,
                        endedDate TEXT
                    )
                """.trimIndent())

                db.execSQL("""
                    CREATE TABLE IF NOT EXISTS medication_side_effect_cache (
                        medKey TEXT PRIMARY KEY NOT NULL,
                        sideEffectsJson TEXT NOT NULL,
                        timestamp INTEGER NOT NULL
                    )
                """.trimIndent())
            }
        }

        private val MIGRATION_20_21 = object : Migration(20, 21) {
            override fun migrate(db: SupportSQLiteDatabase) {
                // Ensure columns isArchived and endedDate exist if medications table was created under v20
                try {
                    db.execSQL("ALTER TABLE medications ADD COLUMN isArchived INTEGER NOT NULL DEFAULT 0")
                } catch (e: Exception) {
                    // Column already exists
                }

                try {
                    db.execSQL("ALTER TABLE medications ADD COLUMN endedDate TEXT")
                } catch (e: Exception) {
                    // Column already exists
                }

                db.execSQL("""
                    CREATE TABLE IF NOT EXISTS medication_side_effect_cache (
                        medKey TEXT PRIMARY KEY NOT NULL,
                        sideEffectsJson TEXT NOT NULL,
                        timestamp INTEGER NOT NULL
                    )
                """.trimIndent())
            }
        }

        private val MIGRATION_21_22 = object : Migration(21, 22) {
            override fun migrate(db: SupportSQLiteDatabase) {
                try {
                    db.execSQL("ALTER TABLE medications ADD COLUMN startedDate TEXT")
                } catch (e: Exception) {
                    // Column already exists
                }
            }
        }

        private val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                // Insert new Medication category
                db.execSQL("""
                    INSERT INTO categories (id, name, icon, colorHex, isDefault, sortOrder) 
                    VALUES (8, 'Medication', 'Medication', '#4ECDC4', 1, 3)
                """.trimIndent())
                
                // Adjust sort orders for existing categories that follow Medication
                db.execSQL("UPDATE categories SET sortOrder = 4 WHERE id = 4")
                db.execSQL("UPDATE categories SET sortOrder = 5 WHERE id = 5")
                db.execSQL("UPDATE categories SET sortOrder = 6 WHERE id = 6")
                db.execSQL("UPDATE categories SET sortOrder = 7 WHERE id = 7")
            }
        }

        fun getInstance(context: Context): NotelDatabase {
            return INSTANCE ?: synchronized(this) {
                Room.databaseBuilder(
                    context.applicationContext,
                    NotelDatabase::class.java,
                    "notel_db"
                )
                    .fallbackToDestructiveMigration()
                    .addMigrations(MIGRATION_1_2, MIGRATION_11_12, MIGRATION_13_14, MIGRATION_14_15, MIGRATION_15_16, MIGRATION_16_17, MIGRATION_17_18, MIGRATION_18_19, MIGRATION_19_20, MIGRATION_20_21, MIGRATION_21_22, MIGRATION_22_23, MIGRATION_23_24, MIGRATION_24_25, MIGRATION_25_26, MIGRATION_26_27, MIGRATION_27_28, MIGRATION_28_29, MIGRATION_29_30, MIGRATION_30_31, MIGRATION_31_32)
                    .addCallback(object : Callback() {
                        override fun onCreate(db: SupportSQLiteDatabase) {
                            super.onCreate(db)
                            // Seed default categories on first launch using raw SQL for reliability
                            DefaultCategories.all.forEach { cat ->
                                val slugValue = cat.slug?.let { "'$it'" } ?: "NULL"
                                db.execSQL("""
                                    INSERT INTO categories (id, name, icon, colorHex, isDefault, sortOrder, slug)
                                    VALUES (${cat.id}, '${cat.name}', '${cat.icon}', '${cat.colorHex}', ${if (cat.isDefault) 1 else 0}, ${cat.sortOrder}, $slugValue)
                                """.trimIndent())
                            }
                        }
                    })
                    .build()
                    .also { INSTANCE = it }
            }
        }
    }
}
