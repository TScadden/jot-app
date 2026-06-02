package com.notel.notel.worker

import android.content.Context
import androidx.hilt.work.HiltWorker
import androidx.work.*
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.remote.FetchSubredditRequest
import com.notel.notel.data.remote.JotApi
import com.notel.notel.ui.viewmodel.LinkedSubreddit
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.Json
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.concurrent.TimeUnit

@HiltWorker
class RedditRefreshWorker @AssistedInject constructor(
    @Assisted context: Context,
    @Assisted params: WorkerParameters,
    private val preferences: NotelPreferences,
    private val api: JotApi
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        if (!preferences.loggedIn.first()) return Result.success()

        val subredditsStr = preferences.redditSubreddits.first()
        val subreddits: List<LinkedSubreddit> = try {
            if (subredditsStr.isNotBlank() && subredditsStr != "[]") Json.decodeFromString(subredditsStr) else emptyList()
        } catch (e: Exception) { emptyList() }

        val aDayAgoMs = System.currentTimeMillis() - (24 * 60 * 60 * 1000L)
        val toUpdate = subreddits.filter { it.autoUpdate && it.lastFetched < aDayAgoMs }

        if (toUpdate.isEmpty()) return Result.success()

        val userContext = preferences.userContext.first()
        val mutableSubs = subreddits.toMutableList()

        for (sub in toUpdate) {
            try {
                val response = api.fetchSubreddit(FetchSubredditRequest(sub.name, userContext))
                if (response.isSuccessful) {
                    val body = response.body()
                    if (body != null) {
                        // Update knowledge base
                        val summaries = preferences.redditSummaries.first()
                        val marker = "[REDDIT r/${sub.name}]"
                        val timestamp = DateTimeFormatter.ofPattern("MMM dd, yyyy").format(LocalDate.now())
                        val newEntry = "[ADDED $timestamp] $marker\n${body.result}"
                        
                        val updatedSummaries = if (summaries.contains(marker)) {
                            val entries = summaries.split("\n\n").filter { !it.contains(marker) }
                            (entries + newEntry).joinToString("\n\n")
                        } else {
                            if (summaries.isBlank()) newEntry else "$summaries\n\n$newEntry"
                        }
                        preferences.setRedditSummaries(updatedSummaries)

                        // Update list
                        val idx = mutableSubs.indexOfFirst { it.name == sub.name }
                        if (idx >= 0) {
                            mutableSubs[idx] = mutableSubs[idx].copy(
                                lastFetched = System.currentTimeMillis(),
                                postsAnalyzed = body.posts?.size ?: 0,
                                scannedPosts = body.posts ?: emptyList()
                            )
                        }
                    }
                }
            } catch (e: Exception) {
                // Log error and continue to next subreddit
                e.printStackTrace()
            }
        }

        preferences.setRedditSubreddits(Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(LinkedSubreddit.serializer()), mutableSubs))

        return Result.success()
    }

    companion object {
        fun schedule(context: Context) {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .setRequiresBatteryNotLow(true)
                .build()

            val request = PeriodicWorkRequestBuilder<RedditRefreshWorker>(1, TimeUnit.DAYS)
                .setConstraints(constraints)
                .addTag("REDDIT_REFRESH")
                .build()

            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                "REDDIT_REFRESH",
                ExistingPeriodicWorkPolicy.UPDATE,
                request
            )
        }
    }
}
