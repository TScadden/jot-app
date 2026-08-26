package com.notel.notel.data.local

import android.content.ContentValues
import android.database.sqlite.SQLiteDatabase
import androidx.room.testing.MigrationTestHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.IOException

@RunWith(AndroidJUnit4::class)
class RoomMigrationTest {

    private val TEST_DB = "migration-test"

    @get:Rule
    val helper: MigrationTestHelper = MigrationTestHelper(
        InstrumentationRegistry.getInstrumentation(),
        NotelDatabase::class.java.canonicalName,
        FrameworkSQLiteOpenHelperFactory()
    )

    @Test
    @Throws(IOException::class)
    fun migrate22To23_preservesDataAndCreatesIndexes() {
        var db = helper.createDatabase(TEST_DB, 22).apply {
            // Insert category in v22
            execSQL("INSERT INTO categories (id, name, icon, colorHex, isDefault, sortOrder) VALUES (7, 'General', 'Notes', '#B0B0B0', 1, 7)")
            close()
        }

        db = helper.runMigrationsAndValidate(TEST_DB, 23, true, NotelDatabase.MIGRATION_22_23)

        // Verify categories existing record and new column
        val cursorCat = db.query("SELECT id, name, slug FROM categories WHERE id = 7")
        assertNotNull(cursorCat)
        cursorCat.moveToFirst()
        assertEquals(7, cursorCat.getInt(0))
        assertEquals("General", cursorCat.getString(1))
        cursorCat.close()

        // Verify ai_insights table and unique request_id constraint
        db.execSQL("INSERT INTO ai_insights (id, text, timestamp, type, entryId, requestId) VALUES ('i1', 'Insight text', 1000, 'Advice', 42, 'req_100')")
        val cursorInsight = db.query("SELECT id, text, entryId, requestId FROM ai_insights WHERE id = 'i1'")
        cursorInsight.moveToFirst()
        assertEquals("i1", cursorInsight.getString(0))
        assertEquals("Insight text", cursorInsight.getString(1))
        assertEquals(42L, cursorInsight.getLong(2))
        assertEquals("req_100", cursorInsight.getString(3))
        cursorInsight.close()

        // Test unique constraint on requestId
        var uniqueViolation = false
        try {
            db.execSQL("INSERT INTO ai_insights (id, text, timestamp, type, entryId, requestId) VALUES ('i2', 'Dup text', 2000, 'Advice', 43, 'req_100')")
        } catch (e: Exception) {
            uniqueViolation = true
        }
        assertEquals(true, uniqueViolation)
    }

    @Test
    @Throws(IOException::class)
    fun migrate26To27_verifiesNewInsightColumnsAndCrossRefTable() {
        var db = helper.createDatabase(TEST_DB, 26).apply {
            // Insert legacy insight in v26
            execSQL("INSERT INTO ai_insights (id, text, timestamp, type, entryId, requestId) VALUES ('ins_v26_99', 'Existing v26 insight', 1700000000000, 'SUMMARY', 101, 'req_26_99')")
            close()
        }

        // Migrate from 26 to 27 and validate schema
        db = helper.runMigrationsAndValidate(TEST_DB, 27, true, NotelDatabase.MIGRATION_26_27)

        // Verify preserved data and new column defaults
        val cursorInsight = db.query("SELECT id, text, classification, dataUsed, dateRangeText, plainLanguageReason, confidence, feedbackState, isDismissed FROM ai_insights WHERE id = 'ins_v26_99'")
        assertNotNull(cursorInsight)
        cursorInsight.moveToFirst()
        assertEquals("ins_v26_99", cursorInsight.getString(0))
        assertEquals("Existing v26 insight", cursorInsight.getString(1))
        assertEquals("OBSERVATION", cursorInsight.getString(2))
        assertEquals("Symptom logs, medication records", cursorInsight.getString(3))
        assertEquals("Past 7 days", cursorInsight.getString(4))
        assertEquals("Observed consistency in daily tracking records.", cursorInsight.getString(5))
        assertEquals(0.85f, cursorInsight.getFloat(6), 0.01f)
        assertEquals("NONE", cursorInsight.getString(7))
        assertEquals(0, cursorInsight.getInt(8)) // false as 0
        cursorInsight.close()

        // Verify insight_entry_cross_ref table creation and insertion
        db.execSQL("INSERT INTO insight_entry_cross_ref (insightId, entryId) VALUES ('ins_v26_99', 101)")
        val cursorRef = db.query("SELECT insightId, entryId FROM insight_entry_cross_ref WHERE insightId = 'ins_v26_99'")
        assertNotNull(cursorRef)
        cursorRef.moveToFirst()
        assertEquals("ins_v26_99", cursorRef.getString(0))
        assertEquals(101L, cursorRef.getLong(1))
        cursorRef.close()
    }
}
