package com.notel.notel.util

import android.util.Log
import com.notel.notel.data.remote.RedditPost
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

object RedditScraper {
    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()

    // Bulletproof browser User-Agent to bypass Reddit CDN blocking
    private const val BROWSER_USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    fun fetchSubreddit(subreddit: String): List<RedditPost> {
        val posts = mutableListOf<RedditPost>()
        try {
            val url = "https://www.reddit.com/r/$subreddit/hot.json?limit=5"
            val request = Request.Builder()
                .url(url)
                .header("User-Agent", BROWSER_USER_AGENT)
                .build()

            Log.d("RedditScraper", "Scraping subreddit URL: $url")
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    Log.e("RedditScraper", "Failed to fetch subreddit hot posts: HTTP ${response.code} ${response.message}")
                    return emptyList()
                }
                val bodyString = response.body?.string() ?: return emptyList()
                
                val root = JSONObject(bodyString)
                val dataObj = root.optJSONObject("data") ?: return emptyList()
                val children = dataObj.optJSONArray("children") ?: return emptyList()

                for (i in 0 until children.length()) {
                    val child = children.optJSONObject(i) ?: continue
                    val p = child.optJSONObject("data") ?: continue
                    
                    val title = p.optString("title", "")
                    val author = p.optString("author", "anonymous")
                    val permalink = p.optString("permalink", "")
                    val postUrl = p.optString("url", "https://reddit.com$permalink")

                    // Fetch comments
                    var comments = emptyList<String>()
                    if (permalink.isNotBlank()) {
                        comments = fetchComments(permalink)
                    }

                    posts.add(RedditPost(
                        title = title,
                        author = author,
                        url = postUrl,
                        comments = comments
                    ))
                }
            }
        } catch (e: Exception) {
            Log.e("RedditScraper", "Exception fetching subreddit $subreddit", e)
        }
        Log.d("RedditScraper", "Successfully scraped ${posts.size} posts for r/$subreddit")
        return posts
    }

    private fun fetchComments(permalink: String): List<String> {
        val comments = mutableListOf<String>()
        try {
            val url = "https://www.reddit.com${permalink}.json?limit=5"
            val request = Request.Builder()
                .url(url)
                .header("User-Agent", BROWSER_USER_AGENT)
                .build()

            client.newCall(request).execute().use { response ->
                if (response.isSuccessful) {
                    val bodyString = response.body?.string() ?: return emptyList()
                    val rootArray = JSONArray(bodyString)
                    if (rootArray.length() > 1) {
                        val commentsObj = rootArray.optJSONObject(1) ?: return emptyList()
                        val dataObj = commentsObj.optJSONObject("data") ?: return emptyList()
                        val children = dataObj.optJSONArray("children") ?: return emptyList()

                        for (i in 0 until children.length()) {
                            val child = children.optJSONObject(i) ?: continue
                            val cData = child.optJSONObject("data") ?: continue
                            val body = cData.optString("body", "")
                            if (body.isNotBlank()) {
                                comments.add(body)
                            }
                        }
                    }
                } else {
                    Log.e("RedditScraper", "Failed to fetch comments for $permalink: HTTP ${response.code}")
                }
            }
        } catch (e: Exception) {
            Log.e("RedditScraper", "Exception fetching comments for $permalink", e)
        }
        return RedditCommentFilter.filterComments(comments).take(5)
    }
}
