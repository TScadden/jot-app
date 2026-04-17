package com.notel.notel.data.local

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import com.notel.notel.data.local.dao.CategoryDao
import com.notel.notel.data.local.dao.LogEntryDao
import com.notel.notel.data.local.entity.Category
import com.notel.notel.data.local.entity.LogEntry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

@Database(
    entities = [LogEntry::class, Category::class, com.notel.notel.data.local.entity.KnowledgeDocument::class],
    version = 14, 
    exportSchema = false
)
abstract class NotelDatabase : RoomDatabase() {
    abstract fun logEntryDao(): LogEntryDao
    abstract fun categoryDao(): CategoryDao
    abstract fun knowledgeDocumentDao(): com.notel.notel.data.local.dao.KnowledgeDocumentDao

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
                    .addMigrations(MIGRATION_1_2, MIGRATION_11_12, MIGRATION_13_14)
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
