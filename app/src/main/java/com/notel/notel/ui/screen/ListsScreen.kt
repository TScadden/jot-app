package com.notel.notel.ui.screen

import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.List
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.data.local.entity.UserList
import com.notel.notel.data.local.entity.UserListItem
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.ListsViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ListsScreen(
    onBack: () -> Unit = {},
    viewModel: ListsViewModel = hiltViewModel()
) {
    val lists by viewModel.lists.collectAsState()
    val selectedList by viewModel.selectedList.collectAsState()
    val items by viewModel.items.collectAsState()

    var showNewListDialog by remember { mutableStateOf(false) }
    var newListName by remember { mutableStateOf("") }
    var showDeleteConfirm by remember { mutableStateOf<UserList?>(null) }

    // When lists load and nothing is selected, auto-select the first
    LaunchedEffect(lists) {
        if (selectedList == null && lists.isNotEmpty()) {
            viewModel.selectList(lists.first())
        }
    }

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(
                            "Lists",
                            style = MaterialTheme.typography.titleLarge,
                            fontWeight = FontWeight.Bold,
                            color = NotelTextPrimary
                        )
                        if (selectedList != null) {
                            Text(
                                selectedList!!.name,
                                style = MaterialTheme.typography.labelSmall,
                                color = NotelPrimary,
                                fontWeight = FontWeight.SemiBold
                            )
                        }
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = NotelTextPrimary)
                    }
                },
                actions = {
                    // Add new list button
                    FilledTonalIconButton(
                        onClick = { showNewListDialog = true },
                        modifier = Modifier.padding(end = 8.dp),
                        colors = IconButtonDefaults.filledTonalIconButtonColors(
                            containerColor = NotelPrimary.copy(alpha = 0.15f),
                            contentColor = NotelPrimary
                        )
                    ) {
                        Icon(Icons.Default.Add, "New List")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = NotelBackground)
            )
        }
    ) { padding ->
        if (lists.isEmpty()) {
            // Empty state
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .padding(bottom = 80.dp),
                contentAlignment = Alignment.Center
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("📋", fontSize = 52.sp)
                    Spacer(Modifier.height(16.dp))
                    Text(
                        "No lists yet",
                        color = NotelTextPrimary,
                        fontSize = 20.sp,
                        fontWeight = FontWeight.Bold
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        "Tap + in the top right to create your first list",
                        color = NotelTextSecondary,
                        fontSize = 14.sp
                    )
                    Spacer(Modifier.height(24.dp))
                    Button(
                        onClick = { showNewListDialog = true },
                        colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary),
                        shape = RoundedCornerShape(14.dp)
                    ) {
                        Icon(Icons.Default.Add, null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text("New List")
                    }
                }
            }
        } else {
            Row(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .padding(bottom = 80.dp)
            ) {
                // ── Left panel: list sidebar ──────────────────────────────────
                Column(
                    modifier = Modifier
                        .width(160.dp)
                        .fillMaxHeight()
                        .background(NotelSurface.copy(alpha = 0.4f))
                        .padding(vertical = 12.dp)
                ) {
                    Text(
                        "MY LISTS",
                        color = NotelTextSecondary,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Black,
                        letterSpacing = 1.2.sp,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp)
                    )
                    Spacer(Modifier.height(4.dp))

                    LazyColumn(
                        modifier = Modifier.weight(1f),
                        contentPadding = PaddingValues(bottom = 16.dp)
                    ) {
                        items(lists, key = { it.id }) { list ->
                            val isSelected = selectedList?.id == list.id
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = 8.dp, vertical = 3.dp)
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(
                                        if (isSelected) NotelPrimary.copy(alpha = 0.18f)
                                        else Color.Transparent
                                    )
                                    .border(
                                        width = if (isSelected) 1.dp else 0.dp,
                                        color = if (isSelected) NotelPrimary.copy(alpha = 0.3f)
                                        else Color.Transparent,
                                        shape = RoundedCornerShape(12.dp)
                                    )
                                    .clickable { viewModel.selectList(list) }
                                    .padding(horizontal = 10.dp, vertical = 10.dp)
                            ) {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    modifier = Modifier.fillMaxWidth()
                                ) {
                                    Text(
                                        "📋",
                                        fontSize = 14.sp,
                                        modifier = Modifier.padding(end = 6.dp)
                                    )
                                    Text(
                                        list.name,
                                        color = if (isSelected) NotelPrimary else NotelTextPrimary,
                                        fontSize = 13.sp,
                                        fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal,
                                        maxLines = 2,
                                        overflow = TextOverflow.Ellipsis,
                                        modifier = Modifier.weight(1f)
                                    )
                                }
                            }
                        }
                    }

                    // Add list button at bottom of sidebar
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 8.dp, vertical = 4.dp)
                            .clip(RoundedCornerShape(12.dp))
                            .background(NotelPrimary.copy(alpha = 0.1f))
                            .clickable { showNewListDialog = true }
                            .padding(vertical = 10.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(
                                Icons.Default.Add,
                                null,
                                tint = NotelPrimary,
                                modifier = Modifier.size(15.dp)
                            )
                            Spacer(Modifier.width(4.dp))
                            Text("New List", color = NotelPrimary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }

                // ── Right panel: items ────────────────────────────────────────
                if (selectedList != null) {
                    ListItemsPanel(
                        list = selectedList!!,
                        items = items,
                        onAddItem = { viewModel.addItem(it) },
                        onDeleteItem = { viewModel.deleteItem(it) },
                        onEditItem = { item, text -> viewModel.editItem(item, text) },
                        onDeleteList = { showDeleteConfirm = selectedList }
                    )
                }
            }
        }
    }

    // ── New List Dialog ───────────────────────────────────────────────────────
    if (showNewListDialog) {
        val focusRequester = remember { FocusRequester() }
        AlertDialog(
            onDismissRequest = {
                showNewListDialog = false
                newListName = ""
            },
            containerColor = NotelSurface,
            title = {
                Text(
                    "New List",
                    color = NotelTextPrimary,
                    fontWeight = FontWeight.Bold
                )
            },
            text = {
                OutlinedTextField(
                    value = newListName,
                    onValueChange = { newListName = it },
                    placeholder = { Text("e.g. Foods good for MCAS", color = NotelTextSecondary) },
                    singleLine = true,
                    modifier = Modifier
                        .fillMaxWidth()
                        .focusRequester(focusRequester),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = NotelPrimary,
                        unfocusedBorderColor = NotelSurfaceHigh.copy(alpha = 0.3f),
                        focusedTextColor = NotelTextPrimary,
                        unfocusedTextColor = NotelTextPrimary,
                        cursorColor = NotelPrimary
                    ),
                    keyboardOptions = KeyboardOptions(
                        capitalization = KeyboardCapitalization.Words,
                        imeAction = ImeAction.Done
                    ),
                    keyboardActions = KeyboardActions(onDone = {
                        if (newListName.isNotBlank()) {
                            viewModel.createList(newListName)
                            newListName = ""
                            showNewListDialog = false
                        }
                    })
                )
                LaunchedEffect(Unit) { focusRequester.requestFocus() }
            },
            confirmButton = {
                Button(
                    onClick = {
                        if (newListName.isNotBlank()) {
                            viewModel.createList(newListName)
                            newListName = ""
                            showNewListDialog = false
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary),
                    enabled = newListName.isNotBlank()
                ) {
                    Text("Create")
                }
            },
            dismissButton = {
                TextButton(onClick = {
                    showNewListDialog = false
                    newListName = ""
                }) {
                    Text("Cancel", color = NotelTextSecondary)
                }
            }
        )
    }

    // ── Delete List Confirm Dialog ────────────────────────────────────────────
    showDeleteConfirm?.let { listToDelete ->
        AlertDialog(
            onDismissRequest = { showDeleteConfirm = null },
            containerColor = NotelSurface,
            title = {
                Text("Delete \"${listToDelete.name}\"?", color = NotelTextPrimary, fontWeight = FontWeight.Bold)
            },
            text = {
                Text(
                    "This will permanently delete the list and all its items.",
                    color = NotelTextSecondary,
                    fontSize = 14.sp
                )
            },
            confirmButton = {
                Button(
                    onClick = {
                        viewModel.deleteList(listToDelete)
                        showDeleteConfirm = null
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFFF5252))
                ) {
                    Text("Delete")
                }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteConfirm = null }) {
                    Text("Cancel", color = NotelTextSecondary)
                }
            }
        )
    }
}

@Composable
private fun ListItemsPanel(
    list: UserList,
    items: List<UserListItem>,
    onAddItem: (String) -> Unit,
    onDeleteItem: (UserListItem) -> Unit,
    onEditItem: (UserListItem, String) -> Unit,
    onDeleteList: () -> Unit
) {
    var itemText by remember { mutableStateOf("") }
    var editingItem by remember { mutableStateOf<UserListItem?>(null) }
    var editText by remember { mutableStateOf("") }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 16.dp, vertical = 12.dp)
    ) {
        // ── List header ───────────────────────────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    list.name,
                    color = NotelTextPrimary,
                    fontSize = 20.sp,
                    fontWeight = FontWeight.ExtraBold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
                Spacer(Modifier.height(2.dp))
                Text(
                    if (items.isEmpty()) "No items yet" else "${items.size} item${if (items.size == 1) "" else "s"}",
                    color = NotelTextSecondary,
                    fontSize = 12.sp
                )
            }
            IconButton(onClick = onDeleteList) {
                Icon(Icons.Default.Delete, "Delete list", tint = Color(0xFFFF5252).copy(alpha = 0.6f))
            }
        }

        Spacer(Modifier.height(4.dp))
        HorizontalDivider(color = Color.White.copy(alpha = 0.06f))
        Spacer(Modifier.height(12.dp))

        // ── Add item input ────────────────────────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            OutlinedTextField(
                value = itemText,
                onValueChange = { itemText = it },
                placeholder = { Text("Add an item...", color = NotelTextSecondary, fontSize = 14.sp) },
                modifier = Modifier.weight(1f),
                singleLine = true,
                shape = RoundedCornerShape(14.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = NotelPrimary.copy(alpha = 0.6f),
                    unfocusedBorderColor = NotelSurfaceHigh.copy(alpha = 0.2f),
                    focusedTextColor = NotelTextPrimary,
                    unfocusedTextColor = NotelTextPrimary,
                    cursorColor = NotelPrimary,
                    focusedContainerColor = NotelSurfaceHigh.copy(alpha = 0.08f),
                    unfocusedContainerColor = NotelSurfaceHigh.copy(alpha = 0.04f)
                ),
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.Sentences,
                    imeAction = ImeAction.Done
                ),
                keyboardActions = KeyboardActions(onDone = {
                    if (itemText.isNotBlank()) {
                        onAddItem(itemText)
                        itemText = ""
                    }
                })
            )
            Spacer(Modifier.width(8.dp))
            FilledIconButton(
                onClick = {
                    if (itemText.isNotBlank()) {
                        onAddItem(itemText)
                        itemText = ""
                    }
                },
                enabled = itemText.isNotBlank(),
                shape = CircleShape,
                colors = IconButtonDefaults.filledIconButtonColors(
                    containerColor = if (itemText.isNotBlank()) NotelPrimary else NotelSurfaceHigh.copy(alpha = 0.3f),
                    contentColor = Color.White
                ),
                modifier = Modifier.size(48.dp)
            ) {
                Icon(Icons.Default.Add, "Add item")
            }
        }

        Spacer(Modifier.height(16.dp))

        // ── Items list ────────────────────────────────────────────────────────
        if (items.isEmpty()) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
                contentAlignment = Alignment.Center
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("✏️", fontSize = 36.sp)
                    Spacer(Modifier.height(10.dp))
                    Text(
                        "This list is empty",
                        color = NotelTextPrimary,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold
                    )
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "Add your first item above",
                        color = NotelTextSecondary,
                        fontSize = 13.sp
                    )
                }
            }
        } else {
            LazyColumn(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                contentPadding = PaddingValues(bottom = 40.dp)
            ) {
                items(items, key = { it.id }) { item ->
                    AnimatedVisibility(
                        visible = true,
                        enter = fadeIn() + expandVertically(),
                        exit = fadeOut() + shrinkVertically()
                    ) {
                        if (editingItem?.id == item.id) {
                            // ── Inline edit row ───────────────────────────
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                OutlinedTextField(
                                    value = editText,
                                    onValueChange = { editText = it },
                                    modifier = Modifier.weight(1f),
                                    singleLine = true,
                                    shape = RoundedCornerShape(12.dp),
                                    colors = OutlinedTextFieldDefaults.colors(
                                        focusedBorderColor = NotelPrimary,
                                        unfocusedBorderColor = NotelSurfaceHigh.copy(alpha = 0.2f),
                                        focusedTextColor = NotelTextPrimary,
                                        unfocusedTextColor = NotelTextPrimary,
                                        cursorColor = NotelPrimary
                                    ),
                                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                                    keyboardActions = KeyboardActions(onDone = {
                                        onEditItem(item, editText)
                                        editingItem = null
                                    })
                                )
                                Spacer(Modifier.width(8.dp))
                                IconButton(
                                    onClick = {
                                        onEditItem(item, editText)
                                        editingItem = null
                                    },
                                    modifier = Modifier
                                        .size(40.dp)
                                        .clip(CircleShape)
                                        .background(NotelPrimary.copy(alpha = 0.15f))
                                ) {
                                    Icon(Icons.Default.Check, "Save", tint = NotelPrimary, modifier = Modifier.size(18.dp))
                                }
                                Spacer(Modifier.width(4.dp))
                                IconButton(
                                    onClick = { editingItem = null },
                                    modifier = Modifier.size(40.dp)
                                ) {
                                    Icon(Icons.Default.Close, "Cancel", tint = NotelTextSecondary, modifier = Modifier.size(18.dp))
                                }
                            }
                        } else {
                            // ── Normal item row ───────────────────────────
                            Surface(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        editingItem = item
                                        editText = item.text
                                    },
                                shape = RoundedCornerShape(14.dp),
                                color = NotelSurfaceHigh.copy(alpha = 0.08f),
                                border = androidx.compose.foundation.BorderStroke(
                                    1.dp,
                                    Color.White.copy(alpha = 0.05f)
                                )
                            ) {
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(horizontal = 14.dp, vertical = 12.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Box(
                                        modifier = Modifier
                                            .size(7.dp)
                                            .clip(CircleShape)
                                            .background(NotelPrimary.copy(alpha = 0.6f))
                                    )
                                    Spacer(Modifier.width(12.dp))
                                    Text(
                                        item.text,
                                        color = NotelTextPrimary,
                                        fontSize = 14.sp,
                                        modifier = Modifier.weight(1f),
                                        lineHeight = 20.sp
                                    )
                                    Spacer(Modifier.width(8.dp))
                                    IconButton(
                                        onClick = { onDeleteItem(item) },
                                        modifier = Modifier.size(28.dp)
                                    ) {
                                        Icon(
                                            Icons.Default.Close,
                                            "Delete item",
                                            tint = NotelTextSecondary.copy(alpha = 0.4f),
                                            modifier = Modifier.size(14.dp)
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
