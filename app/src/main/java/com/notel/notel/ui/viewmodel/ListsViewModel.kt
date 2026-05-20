package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.local.entity.UserList
import com.notel.notel.data.local.entity.UserListItem
import com.notel.notel.data.repository.UserListRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class ListsViewModel @Inject constructor(
    private val repository: UserListRepository
) : ViewModel() {

    val lists: StateFlow<List<UserList>> = repository.lists
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    private val _selectedList = MutableStateFlow<UserList?>(null)
    val selectedList: StateFlow<UserList?> = _selectedList.asStateFlow()

    @OptIn(ExperimentalCoroutinesApi::class)
    val items: StateFlow<List<UserListItem>> = _selectedList
        .flatMapLatest { list ->
            if (list == null) flowOf(emptyList())
            else repository.getItemsForList(list.id)
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    fun selectList(list: UserList) {
        _selectedList.value = list
    }

    fun clearSelection() {
        _selectedList.value = null
    }

    fun createList(name: String) {
        if (name.isBlank()) return
        viewModelScope.launch {
            val created = repository.createList(name)
            // Auto-select the new list
            _selectedList.value = created
        }
    }

    fun deleteList(list: UserList) {
        viewModelScope.launch {
            if (_selectedList.value?.id == list.id) _selectedList.value = null
            repository.deleteList(list)
        }
    }

    fun addItem(text: String) {
        val listId = _selectedList.value?.id ?: return
        if (text.isBlank()) return
        viewModelScope.launch {
            repository.addItem(listId, text)
        }
    }

    fun deleteItem(item: UserListItem) {
        viewModelScope.launch {
            repository.deleteItem(item)
        }
    }

    fun editItem(item: UserListItem, newText: String) {
        if (newText.isBlank()) return
        viewModelScope.launch {
            repository.updateItem(item, newText)
        }
    }
}
