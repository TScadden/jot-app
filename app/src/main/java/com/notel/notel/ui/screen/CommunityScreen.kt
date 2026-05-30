package com.notel.notel.ui.screen

import androidx.compose.animation.*
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.CommunityViewModel
import com.notel.notel.data.remote.FriendDto

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CommunityScreen(
    onBack: () -> Unit = {},
    viewModel: CommunityViewModel = hiltViewModel()
) {
    var showNotifications by remember { mutableStateOf(false) }
    var showAddFriendDialog by remember { mutableStateOf(false) }
    var friendIdInput by remember { mutableStateOf("") }
    var addFriendError by remember { mutableStateOf<String?>(null) }
    var addFriendSuccess by remember { mutableStateOf<String?>(null) }

    val friends by viewModel.friends.collectAsState()
    val notifications by viewModel.notifications.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val error by viewModel.error.collectAsState()

    val userStreak by viewModel.userStreak.collectAsState()
    val userNickname by viewModel.userNickname.collectAsState()
    val userTag by viewModel.userTag.collectAsState()
    val userWeeklyScore by viewModel.userWeeklyScore.collectAsState()

    // Fetch initial data
    LaunchedEffect(Unit) {
        viewModel.fetchFriendsAndNotifications()
    }

    Box(modifier = Modifier.fillMaxSize()) {
        Scaffold(
            containerColor = NotelBackground,
            topBar = {
                Column {
                    TopAppBar(
                        title = {
                            Text(
                                text = "Community",
                                fontWeight = FontWeight.Bold,
                                color = NotelTextPrimary,
                                fontSize = 22.sp
                            )
                        },
                        navigationIcon = {
                            IconButton(onClick = onBack) {
                                Icon(
                                    imageVector = Icons.Default.ArrowBack,
                                    contentDescription = "Back",
                                    tint = NotelTextPrimary
                                )
                            }
                        },
                        actions = {
                            IconButton(onClick = { /* Message action coming soon */ }) {
                                Icon(
                                    imageVector = Icons.Default.Chat,
                                    contentDescription = "Messages",
                                    tint = NotelPrimary,
                                    modifier = Modifier.size(24.dp)
                                )
                            }
                            IconButton(onClick = { 
                                showNotifications = true 
                                viewModel.markNotificationsRead()
                            }) {
                                val hasUnread = notifications.any { !it.isRead }
                                Box {
                                    Icon(
                                        imageVector = Icons.Default.Notifications,
                                        contentDescription = "Notifications",
                                        tint = NotelPrimary,
                                        modifier = Modifier.size(24.dp)
                                    )
                                    if (hasUnread) {
                                        Box(
                                            modifier = Modifier
                                                .size(8.dp)
                                                .background(Color.Red, RoundedCornerShape(50))
                                                .align(Alignment.TopEnd)
                                        )
                                    }
                                }
                            }
                        },
                        colors = TopAppBarDefaults.topAppBarColors(
                            containerColor = NotelBackground
                        )
                    )
                    // Gray line going across right under the text/topbar
                    HorizontalDivider(
                        color = Color.White.copy(alpha = 0.08f),
                        thickness = 1.dp,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            }
        ) { padding ->
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
            ) {
                if (isLoading && friends.isEmpty()) {
                    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        GlassySpinner()
                    }
                } else {
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(horizontal = 16.dp)
                            .verticalScroll(rememberScrollState())
                    ) {
                        Spacer(Modifier.height(16.dp))

                        // Friends Header Row with "Add Friend" Button
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(bottom = 12.dp),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = "Friends",
                                color = NotelTextPrimary,
                                fontSize = 18.sp,
                                fontWeight = FontWeight.Bold
                            )
                            GlassyButton(
                                onClick = { 
                                    friendIdInput = ""
                                    addFriendError = null
                                    addFriendSuccess = null
                                    showAddFriendDialog = true 
                                },
                                containerColor = NotelPrimary.copy(alpha = 0.2f),
                                shape = RoundedCornerShape(8.dp)
                            ) {
                                Text("Add Friend", color = NotelPrimary, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                            }
                        }

                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .liquidGlass(
                                    shape = RoundedCornerShape(16.dp),
                                    color = NotelSurface,
                                    alpha = 0.8f,
                                    showBorder = true
                                )
                                .padding(16.dp)
                        ) {
                            if (friends.isEmpty()) {
                                Text(
                                    text = "No friends added yet. Add friends using their Nickname#ID!",
                                    color = NotelTextSecondary,
                                    fontSize = 14.sp,
                                    fontWeight = FontWeight.Medium
                                )
                            } else {
                                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                    friends.forEach { friend ->
                                        FriendItem(
                                            name = friend.nickname,
                                            tag = friend.tag,
                                            status = friend.status,
                                            level = "${friend.level} pts"
                                        )
                                    }
                                }
                            }
                        }

                        Spacer(Modifier.height(24.dp))

                        // Leaderboard Section
                        Text(
                            text = "Weekly Leaderboard",
                            color = NotelTextPrimary,
                            fontSize = 18.sp,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier.padding(bottom = 12.dp)
                        )

                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .liquidGlass(
                                    shape = RoundedCornerShape(16.dp),
                                    color = NotelSurface,
                                    alpha = 0.8f,
                                    showBorder = true
                                )
                                .padding(16.dp)
                        ) {
                            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                // Dynamic Leaderboard representation from live friends + user (no placeholder levels)
                                val leaderboardList = (friends + FriendDto(
                                    id = "me",
                                    nickname = userNickname.ifBlank { "You" },
                                    tag = userTag.ifBlank { "00000" },
                                    status = "Online",
                                    level = userWeeklyScore
                                )).sortedByDescending { it.level }

                                leaderboardList.forEachIndexed { index, person ->
                                    LeaderboardItem(
                                        rank = index + 1,
                                        name = person.nickname,
                                        tag = person.tag,
                                        score = "${person.level} pts",
                                        isCurrentUser = person.id == "me"
                                    )
                                }
                            }
                        }

                        Spacer(Modifier.height(100.dp)) // Avoid navbar cutoff
                    }
                }
            }
        }

        // Add Friend Glassy Dialog
        if (showAddFriendDialog) {
            Dialog(onDismissRequest = { showAddFriendDialog = false }) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth(0.95f)
                        .liquidGlass(
                            shape = RoundedCornerShape(20.dp),
                            color = NotelSurface,
                            alpha = 0.95f,
                            showBorder = true
                        )
                        .padding(24.dp)
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(
                            text = "Add Friend",
                            color = NotelTextPrimary,
                            fontSize = 18.sp,
                            fontWeight = FontWeight.Bold
                        )
                        Spacer(Modifier.height(8.dp))
                        Text(
                            text = "Enter your friend's 5-digit Tag (e.g. 26385)",
                            color = NotelTextSecondary,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Medium
                        )
                        Spacer(Modifier.height(16.dp))

                        OutlinedTextField(
                            value = friendIdInput,
                            onValueChange = { 
                                friendIdInput = it
                                addFriendError = null
                                addFriendSuccess = null
                            },
                            placeholder = { Text("Tag (e.g. 26385)", color = NotelTextSecondary) },
                            singleLine = true,
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedTextColor = NotelTextPrimary,
                                unfocusedTextColor = NotelTextPrimary,
                                focusedBorderColor = NotelPrimary,
                                unfocusedBorderColor = NotelTextSecondary.copy(alpha = 0.3f),
                                focusedContainerColor = Color.Transparent,
                                unfocusedContainerColor = Color.Transparent
                            ),
                            modifier = Modifier.fillMaxWidth()
                        )

                        if (addFriendError != null) {
                            Spacer(Modifier.height(8.dp))
                            Text(text = addFriendError!!, color = Color.Red, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                        }

                        if (addFriendSuccess != null) {
                            Spacer(Modifier.height(8.dp))
                            Text(text = addFriendSuccess!!, color = Color.Green, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                        }

                        Spacer(Modifier.height(24.dp))

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.End,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            TextButton(onClick = { showAddFriendDialog = false }) {
                                Text("Cancel", color = NotelTextSecondary)
                            }
                            Spacer(Modifier.width(16.dp))
                            GlassyButton(
                                onClick = {
                                    val trimmed = friendIdInput.trim()
                                    val isValidTag = trimmed.matches(Regex("^\\d{5}$"))
                                    val isValidHashTag = trimmed.startsWith("#") && trimmed.substring(1).matches(Regex("^\\d{5}$"))

                                    if (trimmed.isBlank() || !(isValidTag || isValidHashTag)) {
                                        addFriendError = "Invalid format. Enter a 5-digit Tag (e.g. 26385)"
                                        return@GlassyButton
                                    }
                                    viewModel.sendFriendRequest(trimmed) { success, err ->
                                        if (success) {
                                            addFriendSuccess = "Request sent successfully!"
                                            friendIdInput = ""
                                        } else {
                                            addFriendError = err ?: "Failed to send request"
                                        }
                                    }
                                },
                                shape = RoundedCornerShape(8.dp)
                            ) {
                                Text("Send", color = NotelTextPrimary, fontSize = 14.sp)
                            }
                        }
                    }
                }
            }
        }

        // Sliding Notifications Overlay
        AnimatedVisibility(
            visible = showNotifications,
            enter = slideInHorizontally(initialOffsetX = { it }),
            exit = slideOutHorizontally(targetOffsetX = { it }),
            modifier = Modifier.fillMaxSize()
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.5f))
                    .clickable { showNotifications = false }
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxHeight()
                        .fillMaxWidth(0.85f)
                        .align(Alignment.CenterEnd)
                        .clickable(enabled = false) {}
                        .statusBarsPadding()
                        .navigationBarsPadding()
                        .padding(bottom = 72.dp)
                        .liquidGlass(
                            shape = RoundedCornerShape(topStart = 24.dp, bottomStart = 24.dp),
                            color = NotelSurface,
                            alpha = 0.95f,
                            showBorder = true
                        )
                        .padding(24.dp)
                ) {
                    Column(modifier = Modifier.fillMaxSize()) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Text(
                                text = "Notifications",
                                color = NotelTextPrimary,
                                fontSize = 20.sp,
                                fontWeight = FontWeight.Bold
                            )
                            IconButton(onClick = { showNotifications = false }) {
                                Icon(
                                    imageVector = Icons.Default.Close,
                                    contentDescription = "Close",
                                    tint = NotelTextPrimary
                                )
                            }
                        }

                        Spacer(Modifier.height(24.dp))

                        Box(
                            contentAlignment = Alignment.TopCenter,
                            modifier = Modifier.weight(1f).fillMaxWidth()
                        ) {
                            if (notifications.isEmpty()) {
                                Column(
                                    horizontalAlignment = Alignment.CenterHorizontally,
                                    verticalArrangement = Arrangement.Center,
                                    modifier = Modifier.fillMaxSize()
                                ) {
                                    Icon(
                                        imageVector = Icons.Default.NotificationsNone,
                                        contentDescription = null,
                                        tint = NotelTextSecondary.copy(alpha = 0.4f),
                                        modifier = Modifier.size(64.dp)
                                    )
                                    Spacer(Modifier.height(16.dp))
                                    Text(
                                        text = "You have no notifications",
                                        color = NotelTextSecondary,
                                        fontSize = 14.sp,
                                        fontWeight = FontWeight.Medium
                                    )
                                }
                            } else {
                                Column(
                                    verticalArrangement = Arrangement.spacedBy(12.dp),
                                    modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                                ) {
                                    notifications.forEach { notif ->
                                        NotificationItemRow(
                                            notification = notif,
                                            onAccept = {
                                                notif.friendRequestId?.let { reqId ->
                                                    viewModel.respondFriendRequest(reqId, true) { _, _ -> }
                                                }
                                            },
                                            onDecline = {
                                                notif.friendRequestId?.let { reqId ->
                                                    viewModel.respondFriendRequest(reqId, false) { _, _ -> }
                                                }
                                            }
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

@Composable
fun FriendItem(name: String, tag: String, status: String, level: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .background(
                        color = if (status == "Online") Color.Green else Color.Gray,
                        shape = RoundedCornerShape(50)
                    )
            )
            Spacer(Modifier.width(12.dp))
            Column {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(text = name, color = NotelTextPrimary, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
                    Spacer(Modifier.width(4.dp))
                    Text(text = "#$tag", color = NotelTextSecondary, fontSize = 11.sp, fontWeight = FontWeight.Medium)
                }
                Text(text = level, color = NotelTextSecondary, fontSize = 12.sp)
            }
        }
        Text(
            text = status,
            color = if (status == "Online") NotelPrimary else NotelTextSecondary,
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium
        )
    }
}

@Composable
fun LeaderboardItem(rank: Int, name: String, tag: String, score: String, isCurrentUser: Boolean) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(
                color = if (isCurrentUser) NotelPrimary.copy(alpha = 0.1f) else Color.Transparent,
                shape = RoundedCornerShape(8.dp)
            )
            .padding(vertical = 6.dp, horizontal = 8.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = "#$rank",
                color = if (rank == 1) Color(0xFFFFD700) else NotelTextSecondary,
                fontWeight = FontWeight.Bold,
                fontSize = 15.sp,
                modifier = Modifier.width(32.dp)
            )
            Text(
                text = name,
                color = if (isCurrentUser) NotelPrimary else NotelTextPrimary,
                fontWeight = if (isCurrentUser) FontWeight.Bold else FontWeight.Normal,
                fontSize = 15.sp
            )
            if (tag != "00000") {
                Spacer(Modifier.width(4.dp))
                Text(
                    text = "#$tag",
                    color = NotelTextSecondary,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Medium
                )
            }
        }
        Text(
            text = score,
            color = NotelTextPrimary,
            fontWeight = FontWeight.Bold,
            fontSize = 14.sp
        )
    }
}

@Composable
fun NotificationItemRow(
    notification: com.notel.notel.data.remote.FriendNotificationDto,
    onAccept: () -> Unit,
    onDecline: () -> Unit
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .liquidGlass(
                shape = RoundedCornerShape(12.dp),
                color = if (notification.isRead) NotelSurface else NotelSurfaceHigh,
                alpha = 0.8f,
                showBorder = true
            )
            .padding(12.dp)
    ) {
        Column(modifier = Modifier.fillMaxWidth()) {
            Text(
                text = notification.message,
                color = NotelTextPrimary,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium
            )

            if (notification.type == "friend_request" && notification.friendRequestId != null) {
                Spacer(Modifier.height(12.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.End
                ) {
                    TextButton(onClick = onDecline) {
                        Text("Decline", color = Color.Red, fontSize = 13.sp, fontWeight = FontWeight.Bold)
                    }
                    Spacer(Modifier.width(8.dp))
                    GlassyButton(
                        onClick = onAccept,
                        shape = RoundedCornerShape(6.dp)
                    ) {
                        Text("Accept", color = NotelTextPrimary, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }
        }
    }
}
