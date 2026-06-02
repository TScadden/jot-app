package com.notel.notel.util

object RedditCommentFilter {
    private val botKeywords = listOf(
        "automoderator",
        "i am a bot",
        "performed automatically",
        "contact the moderator",
        "submission has been",
        "post has been",
        "rules of this subreddit",
        "welcome to r/",
        "moderator team",
        "your post",
        "action was performed",
        "questions or concerns",
        "contact the moderators",
        "deleted",
        "removed",
        "submission was removed",
        "comment was removed",
        "post was removed"
    )

    fun filterComments(comments: List<String>): List<String> {
        return comments.filter { comment ->
            val lower = comment.lowercase()
            botKeywords.none { keyword -> lower.contains(keyword) }
        }
    }
}
