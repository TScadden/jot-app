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

    fun addNote(text: String) {
        if (text.isBlank()) return
        viewModelScope.launch {
            val lists = repository.lists.first()
            var list = lists.find { it.name == "__user_notes__" }
            if (list == null) {
                list = repository.createList("__user_notes__")
            }
            
            val timestamp = System.currentTimeMillis()
            val combinedText = "${text.trim()}_||_$timestamp"
            repository.addItem(list.id, combinedText)
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
