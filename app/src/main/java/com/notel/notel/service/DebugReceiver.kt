package com.notel.notel.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.notel.notel.data.repository.CategoryRepository
import com.notel.notel.data.repository.LogRepository
import com.notel.notel.util.NotificationHelper
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import javax.inject.Inject

@AndroidEntryPoint
class DebugReceiver : BroadcastReceiver() {

    @Inject
    lateinit var logRepository: LogRepository

    @Inject
    lateinit var categoryRepository: CategoryRepository

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        val helper = NotificationHelper(context)

        when (action) {
            "com.notel.notel.TEST_BODY_LOAD" -> {
                CoroutineScope(Dispatchers.IO).launch {
                    val categories = categoryRepository.getAllCategories().first()
                    logRepository.getBodyLoad(categories).fold(
                        onSuccess = { res ->
                            helper.showBodyLoadUpdate(res.score)
                        },
                        onFailure = {
                            helper.showBodyLoadReminder()
                        }
                    )
                }
            }
            "com.notel.notel.TEST_MIDDAY_BODY_LOAD" -> {
                helper.showMidDayBodyLoadRefresh()
            }
            "com.notel.notel.TEST_BODY_LOAD_REMINDER" -> {
                helper.showBodyLoadReminder()
            }
            "com.notel.notel.TEST_HABIT" -> {
                helper.showHabitReminder()
            }
            "com.notel.notel.TEST_SPIKE" -> {
                helper.showSpikeAlert(102, 72, 30)
            }
            "com.notel.notel.TEST_REMINDER" -> {
                helper.showTestReminder("Drink a glass of water")
            }
        }
    }
}
