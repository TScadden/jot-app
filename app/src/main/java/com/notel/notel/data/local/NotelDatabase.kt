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
        com.notel.notel.data.local.entity.MedicationSideEffectCache::class
    ],
    version = 22,
    exportSchema = false
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

    companion object {
        @Volatile private var INSTANCE: NotelDatabase? = null

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
                    .addMigrations(MIGRATION_1_2, MIGRATION_11_12, MIGRATION_13_14, MIGRATION_14_15, MIGRATION_15_16, MIGRATION_16_17, MIGRATION_17_18, MIGRATION_18_19, MIGRATION_19_20, MIGRATION_20_21, MIGRATION_21_22)
                    .addCallback(object : Callback() {
                        override fun onCreate(db: SupportSQLiteDatabase) {
                            super.onCreate(db)
                            // Seed default categories on first launch using raw SQL for reliability
                            DefaultCategories.all.forEach { cat ->
                                db.execSQL("""
                                    INSERT INTO categories (id, name, icon, colorHex, isDefault, sortOrder)
                                    VALUES (${cat.id}, '${cat.name}', '${cat.icon}', '${cat.colorHex}', ${if (cat.isDefault) 1 else 0}, ${cat.sortOrder})
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
