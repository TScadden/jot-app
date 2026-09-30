package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.remote.FriendDto
import com.notel.notel.data.remote.FriendNotificationDto
import com.notel.notel.data.remote.FriendRequestApiRequest
import com.notel.notel.data.remote.TabsApi
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
    private val tabsApi: TabsApi,
    private val preferences: NotelPreferences
) : ViewModel() {

    companion object {
        private const val TAG = "CommunityViewModel"
    }

    val userStreak: StateFlow<Int> = preferences.currentStreak
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0)

    val userNickname: StateFlow<String> = preferences.userNickname
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")

    val userTag: StateFlow<String> = preferences.userTag
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")

    val userWeeklyScore: StateFlow<Int> = preferences.weeklyScore
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0)

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
                val friendsRes = tabsApi.getFriendsList()
                if (friendsRes.isSuccessful) {
                    _friends.value = friendsRes.body()?.friends ?: emptyList()
                } else {
                    android.util.Log.e(TAG, "getFriendsList failed: ${friendsRes.code()}")
                    _error.value = com.notel.notel.util.FriendlyErrors.forBackendError(
                        TAG, null, com.notel.notel.util.FriendlyErrors.Kind.LOAD
                    ).banner
                }

                // Fetch notifications
                val notifRes = tabsApi.getFriendNotifications()
                if (notifRes.isSuccessful) {
                    _notifications.value = notifRes.body()?.notifications ?: emptyList()
                }
            } catch (e: Exception) {
                _error.value = com.notel.notel.util.FriendlyErrors.forBackendError(
                    TAG, e, com.notel.notel.util.FriendlyErrors.Kind.LOAD
                ).banner
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
                val res = tabsApi.sendFriendRequest(FriendRequestApiRequest(friendIdString))
                if (res.isSuccessful && res.body()?.success == true) {
                    onResult(true, null)
                    fetchFriendsAndNotifications() // Refresh list & requests
                } else {
                    android.util.Log.e(TAG, "sendFriendRequest failed: ${res.code()}")
                    onResult(
                        false,
                        com.notel.notel.util.FriendlyErrors.forBackendError(
                            TAG, null, com.notel.notel.util.FriendlyErrors.Kind.UNKNOWN
                        ).banner
                    )
                }
            } catch (e: Exception) {
                onResult(
                    false,
                    com.notel.notel.util.FriendlyErrors.forBackendError(
                        TAG, e, com.notel.notel.util.FriendlyErrors.Kind.UNKNOWN
                    ).banner
                )
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
                val res = tabsApi.respondFriendRequest(RespondFriendRequestApiRequest(requestId, action))
                if (res.isSuccessful && res.body()?.success == true) {
                    onResult(true, null)
                    fetchFriendsAndNotifications() // Refresh
                } else {
                    android.util.Log.e(TAG, "respondFriendRequest failed: ${res.code()}")
                    onResult(
                        false,
                        com.notel.notel.util.FriendlyErrors.forBackendError(
                            TAG, null, com.notel.notel.util.FriendlyErrors.Kind.UNKNOWN
                        ).banner
                    )
                }
            } catch (e: Exception) {
                onResult(
                    false,
                    com.notel.notel.util.FriendlyErrors.forBackendError(
                        TAG, e, com.notel.notel.util.FriendlyErrors.Kind.UNKNOWN
                    ).banner
                )
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun markNotificationsRead() {
        viewModelScope.launch {
            try {
                tabsApi.markFriendNotificationsRead()
                // Update local state to reflect all is read
                _notifications.value = _notifications.value.map { it.copy(isRead = true) }
            } catch (e: Exception) {
                // Ignore silent mark read failures
            }
        }
    }

    fun fetchFriendDetail(friendId: String, onResult: (com.notel.notel.data.remote.FriendDetailDto?, String?) -> Unit) {
        viewModelScope.launch {
            try {
                val res = tabsApi.getFriendDetail(friendId)
                if (res.isSuccessful && res.body()?.success == true) {
                    onResult(res.body()?.data, null)
                } else {
                    android.util.Log.e(TAG, "getFriendDetail failed: ${res.code()}")
                    onResult(
                        null,
                        com.notel.notel.util.FriendlyErrors.forBackendError(
                            TAG, null, com.notel.notel.util.FriendlyErrors.Kind.LOAD
                        ).banner
                    )
                }
            } catch (e: Exception) {
                onResult(
                    null,
                    com.notel.notel.util.FriendlyErrors.forBackendError(
                        TAG, e, com.notel.notel.util.FriendlyErrors.Kind.LOAD
                    ).banner
                )
            }
        }
    }
}
