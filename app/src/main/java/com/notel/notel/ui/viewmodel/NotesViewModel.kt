package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.local.entity.UserList
import com.notel.notel.data.local.entity.UserListItem
import com.notel.notel.data.repository.UserListRepository
import com.notel.notel.data.sync.SyncManager
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class NotesViewModel @Inject constructor(
    private val repository: UserListRepository,
    private val syncManager: SyncManager
) : ViewModel() {

    private val notesListFlow: Flow<UserList?> = repository.lists.map { lists ->
        lists.find { it.name == "__user_notes__" }
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    val notes: StateFlow<List<UserListItem>> = notesListFlow
        .flatMapLatest { list ->
            if (list == null) flowOf(emptyList())
            else repository.getItemsForList(list.id)
        }
        .map { items ->
            items.sortedByDescending { it.id }
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    fun addNote(title: String, body: String) {
        if (body.isBlank() && title.isBlank()) return
        viewModelScope.launch {
            val lists = repository.lists.first()
            var list = lists.find { it.name == "__user_notes__" }
            if (list == null) {
                list = repository.createList("__user_notes__")
            }
            
            val finalTitle = if (title.trim().isBlank()) "New Note" else title.trim()
            val timestamp = System.currentTimeMillis()
            val combinedText = "$finalTitle_||_${body.trim()}_||_$timestamp"
            repository.addItem(list.id, combinedText)
            syncManager.pushProfileData()
        }
    }

    fun editNote(item: UserListItem, newTitle: String, newBody: String) {
        viewModelScope.launch {
            val finalTitle = if (newTitle.trim().isBlank()) "New Note" else newTitle.trim()
            val parts = item.text.split("_||_")
            val timestamp = if (parts.size == 3) {
                parts.getOrNull(2)?.toLongOrNull()
            } else if (parts.size == 2) {
                parts.getOrNull(1)?.toLongOrNull()
            } else null ?: System.currentTimeMillis()
            
            val combinedText = "$finalTitle_||_${newBody.trim()}_||_$timestamp"
            repository.updateItem(item, combinedText)
            syncManager.pushProfileData()
        }
    }

    fun deleteNote(item: UserListItem) {
        viewModelScope.launch {
            repository.deleteItem(item)
            syncManager.pushProfileData()
        }
    }
}
