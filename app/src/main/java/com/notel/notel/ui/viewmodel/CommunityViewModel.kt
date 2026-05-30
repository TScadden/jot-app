package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.remote.FriendDto
import com.notel.notel.data.remote.FriendNotificationDto
import com.notel.notel.data.remote.FriendRequestApiRequest
import com.notel.notel.data.remote.JotApi
import com.notel.notel.data.remote.RespondFriendRequestApiRequest
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class CommunityViewModel @Inject constructor(
    private val jotApi: JotApi,
    private val preferences: NotelPreferences
) : ViewModel() {

    val userStreak: StateFlow<Int> = preferences.currentStreak
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0)

    val userNickname: StateFlow<String> = preferences.userNickname
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")

    val userTag: StateFlow<String> = preferences.userTag
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")

    private val _friends = MutableStateFlow<List<FriendDto>>(emptyList())
    val friends: StateFlow<List<FriendDto>> = _friends.asStateFlow()

    private val _notifications = MutableStateFlow<List<FriendNotificationDto>>(emptyList())
    val notifications: StateFlow<List<FriendNotificationDto>> = _notifications.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    fun fetchFriendsAndNotifications() {
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            try {
                // Fetch friends
                val friendsRes = jotApi.getFriendsList()
                if (friendsRes.isSuccessful) {
                    _friends.value = friendsRes.body()?.friends ?: emptyList()
                } else {
                    _error.value = "Failed to fetch friends list"
                }

                // Fetch notifications
                val notifRes = jotApi.getFriendNotifications()
                if (notifRes.isSuccessful) {
                    _notifications.value = notifRes.body()?.notifications ?: emptyList()
                }
            } catch (e: Exception) {
                _error.value = e.message ?: "Network error occurred"
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun sendFriendRequest(friendIdString: String, onResult: (Boolean, String?) -> Unit) {
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            try {
                val res = jotApi.sendFriendRequest(FriendRequestApiRequest(friendIdString))
                if (res.isSuccessful && res.body()?.success == true) {
                    onResult(true, null)
                    fetchFriendsAndNotifications() // Refresh list & requests
                } else {
                    val errorBody = res.errorBody()?.string()
                    val errorMsg = if (!errorBody.isNullOrBlank() && errorBody.contains("\"error\":")) {
                        errorBody.substringAfter("\"error\":\"").substringBefore("\"")
                    } else {
                        res.body()?.error ?: "Failed to send friend request"
                    }
                    onResult(false, errorMsg)
                }
            } catch (e: Exception) {
                onResult(false, e.message ?: "Network error occurred")
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun respondFriendRequest(requestId: Int, accept: Boolean, onResult: (Boolean, String?) -> Unit) {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                val action = if (accept) "accept" else "reject"
                val res = jotApi.respondFriendRequest(RespondFriendRequestApiRequest(requestId, action))
                if (res.isSuccessful && res.body()?.success == true) {
                    onResult(true, null)
                    fetchFriendsAndNotifications() // Refresh
                } else {
                    onResult(false, res.body()?.error ?: "Failed to respond to request")
                }
            } catch (e: Exception) {
                onResult(false, e.message ?: "Network error occurred")
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun markNotificationsRead() {
        viewModelScope.launch {
            try {
                jotApi.markFriendNotificationsRead()
                // Update local state to reflect all is read
                _notifications.value = _notifications.value.map { it.copy(isRead = true) }
            } catch (e: Exception) {
                // Ignore silent mark read failures
            }
        }
    }
}
