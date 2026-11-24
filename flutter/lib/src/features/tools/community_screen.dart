import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/friend_notification_surfacer.dart';
import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart';
import 'package:tabs_lab/src/widgets/user_avatar.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/skeleton.dart';

/// The app's streak orange — the lit color of the streak hero's
/// flame (`StreakFlame.litColor`, streak_flame.dart ruling).
const Color _kStreakOrange = Color(0xFFFF6A3D);

/// The friend row's points label. Juno §2.1 conditional hold
/// (Nov 19, 2026) — RESOLVED: Mason's server audit (jot-server
/// PR #42, coordinator-verified) proved `weekly_score` has NO
/// live writer and NO defined weekly window in the current
/// stack, so the mock's "pts this week" would claim a freshness
/// the data does not deliver. Coordinator ruling: ship bare
/// "pts" (current production copy), matching the leaderboard.
/// Kept in exactly ONE place — do not duplicate this string.
String friendWeeklyPointsLabel(int level) => '$level pts';

/// Avatar background palette for the Option A rich rows
/// (founder-approved mock, Nov 19, 2026): purple / blue / green /
/// pink / orange family. The purple is the brand [NotelColors.primary].
const List<Color> _kAvatarPalette = [
  NotelColors.primary,
  Color(0xFF4E8FD0),
  Color(0xFF5FAE7E),
  Color(0xFFD478A8),
  Color(0xFFE79B4B),
];

/// Deterministic avatar color for a friend: FNV-1a hash of the
/// friend's id into [_kAvatarPalette] (String.hashCode is not
/// stable enough to pin a friend's color across runs).
Color friendAvatarColor(String id) {
  var hash = 0x811C9DC5;
  for (final unit in id.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return _kAvatarPalette[hash % _kAvatarPalette.length];
}

/// Avatar initials: the first two alphabetic characters of the
/// nickname, uppercased ("Boston" → "BO", "You" → "YO"). Falls
/// back to "?" when the nickname carries no letters at all.
String friendAvatarInitials(String nickname) {
  final letter = RegExp(r'\p{L}', unicode: true);
  final letters = <String>[];
  for (final ch in nickname.split('')) {
    if (letter.hasMatch(ch)) {
      letters.add(ch);
      if (letters.length == 2) break;
    }
  }
  if (letters.isEmpty) return '?';
  return letters.join().toUpperCase();
}

/// Leaderboard order: friends sorted by weekly level, highest first.
/// Pure and unit-testable.
List<FriendDto> buildLeaderboard(List<FriendDto> friends) {
  final out = List<FriendDto>.of(friends);
  out.sort((a, b) => b.level.compareTo(a.level));
  return out;
}

/// Native `CommunityScreen`'s leaderboard: the user's own row
/// (id "me", their nickname/tag and weekly score) merged with the
/// friends and sorted by level descending. Pure and unit-testable.
List<FriendDto> buildLeaderboardWithSelf(
    List<FriendDto> friends, FriendDto self) {
  return buildLeaderboard([...friends, self]);
}

/// The local user's leaderboard row, mirroring native: blank
/// nickname → "You", blank tag → "00000", level = weeklyScore.
/// Community revamp: the self row also carries MY streak + gems
/// (from the sync pull profile) so it renders the same game stats
/// as every friend row.
FriendDto selfLeaderboardEntry({
  required String nickname,
  required String tag,
  required int weeklyScore,
  int currentStreak = 0,
  int gemBalance = 0,
  String? avatarId,
}) {
  return FriendDto(
    id: 'me',
    nickname: nickname.trim().isEmpty ? 'You' : nickname,
    tag: tag.trim().isEmpty ? '00000' : tag,
    status: '',
    level: weeklyScore,
    currentStreak: currentStreak,
    gemBalance: gemBalance,
    // Carried for completeness only — leaderboard rows render no
    // avatar (Option A), so this changes no rendering.
    avatarId: avatarId,
  );
}

/// Native Add Friend validation: a 5-digit tag, optionally
/// `#`-prefixed (`^\d{5}$` or `#\d{5}$`). Pure and unit-testable.
bool isValidFriendTag(String input) {
  final trimmed = input.trim();
  final digits = trimmed.startsWith('#') ? trimmed.substring(1) : trimmed;
  return RegExp(r'^\d{5}$').hasMatch(digits);
}

/// Friend-detail stat formatting (FriendDetailDialog):
/// sleep minutes → compact "2h5m" / "45m" via the shared
/// [formatSleepMinutes] (R61 — founder ruling, Oct 15, 2026);
/// null → "·".
String formatFriendSleep(int? mins) {
  if (mins == null) return '·';
  return formatSleepMinutes(mins);
}

/// Sleep-debt formatting: 0 → "None"; otherwise the absolute value
/// prefixed with "-", formatted by the shared [formatSleepMinutes].
String formatFriendSleepDebt(int? debt) {
  if (debt == null) return '·';
  if (debt == 0) return 'None';
  return '-${formatSleepMinutes(debt.abs())}';
}

/// Native HR-spikes formatting: 1 → "1 spike", else "N spikes".
String formatFriendSpikes(int? spikes) {
  if (spikes == null) return '·';
  return spikes == 1 ? '1 spike' : '$spikes spikes';
}

/// Round 48, Team D — Community tool screen, full port of native
/// `CommunityScreen.kt` / `CommunityViewModel.kt`:
///
/// - Friends list (`GET /api/friends/list`); tapping a friend opens
///   the detail dialog (`GET /api/friends/data/{friendId}`) with
///   today's shared stats or the sharing-off state.
/// - Weekly leaderboard including the user's own row (nickname/tag
///   from the sync pull, level = profile `weeklyScore`), like native.
/// - "Add Friend" dialog: 5-digit tag validation, then
///   `POST /api/friends/request` — server errors surface verbatim.
/// - Notifications panel (`GET /api/friends/notifications`):
///   opening it marks all read (`POST /api/friends/notifications/read`),
///   and friend-request notifications carry Accept/Decline wired to
///   `POST /api/friends/respond` (enabled by the `friendRequestId`
///   field Round 48 restored to the DTO).
/// - Native's app-bar Messages icon is a dead "coming soon" button
///   in native itself; it is deliberately NOT replicated (no dead
///   buttons). "Last logged" timestamps remain honestly omitted —
///   no friends endpoint exposes one.
class CommunityToolScreen extends StatefulWidget {
  final VoidCallback? onBack;
  final TabsBackend? backend;

  /// Friend Streaks local-notification surfacer (DESIGN §6):
  /// tests inject a fake; production leaves null and the load path
  /// uses [FriendNotificationSurfacer.production].
  final FriendNotificationSurfacer? friendNotificationSurfacer;

  const CommunityToolScreen({
    super.key,
    this.onBack,
    this.backend,
    this.friendNotificationSurfacer,
  });

  @override
  State<CommunityToolScreen> createState() => _CommunityToolScreenState();
}

class _CommunityToolScreenState extends State<CommunityToolScreen> {
  TabsBackend get _backend => widget.backend ?? TabsBackend();

  bool _loading = true;
  List<FriendDto> _friends = const [];
  List<FriendNotificationDto> _notifications = const [];
  String _selfNickname = '';
  String _selfTag = '';
  int _weeklyScore = 0;
  int _selfStreak = 0;
  int _selfGems = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Friend Streaks local surfacing (DESIGN §6): this screen's
  /// load is the app's friend-notification FETCH point — when it
  /// surfaces a new unread friend-class row, the surfacer posts a
  /// local notification once per notification id. Beside the fetch
  /// flow, never in build; fully guarded so a surfacing failure can
  /// never break the load.
  Future<void> _surfaceFriendNotifications(
    List<FriendNotificationDto> rows,
  ) async {
    try {
      final surfacer = widget.friendNotificationSurfacer ??
          FriendNotificationSurfacer.production();
      await surfacer.surfaceNew(rows);
    } catch (_) {
      // The load result stands regardless (surfacer is guarded
      // internally too; this is belt-and-braces).
    }
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        _backend.fetchFriendsList(),
        _backend.fetchFriendNotifications(),
        _backend.fetchSyncPull(),
      ]);
      // Surface friend-class notifications from THIS fetch before
      // the read-state can change (the panel marks rows read only
      // when opened, a separate later action).
      unawaited(
        _surfaceFriendNotifications(
          results[1] as List<FriendNotificationDto>,
        ),
      );
      if (!mounted) return;
      final pull = results[2] as Map<String, dynamic>?;
      final profile = pull?['profile'];
      // Sync-pull profile keys, verified against the pull parsing
      // in tabs_backend.dart (fetchStreak / fetchStreakRecord):
      // current_streak arrives as `currentStreak`, gem_balance as
      // `gem_balance` (the camelCase twin accepted, same as the
      // streak record's parsing).
      final profileMap =
          profile is Map<String, dynamic> ? profile : null;
      int pullInt(dynamic v) =>
          v is num ? v.toInt() : int.tryParse('$v') ?? 0;
      setState(() {
        _friends = results[0] as List<FriendDto>;
        _notifications = results[1] as List<FriendNotificationDto>;
        _selfNickname = '${pull?['nickname'] ?? ''}';
        _selfTag = '${pull?['tag'] ?? ''}';
        _weeklyScore = pullInt(profileMap?['weeklyScore']);
        _selfStreak = pullInt(profileMap?['currentStreak']);
        _selfGems = pullInt(
            profileMap?['gem_balance'] ?? profileMap?['gemBalance']);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load your data. We could not pull your latest '
            'entries. Check your connection and try again.';
        _loading = false;
      });
    }
  }

  bool get _hasUnread => _notifications.any((n) => !n.isRead);

  FriendDto get _self => selfLeaderboardEntry(
        nickname: _selfNickname,
        tag: _selfTag,
        weeklyScore: _weeklyScore,
        currentStreak: _selfStreak,
        gemBalance: _selfGems,
      );

  void _openNotifications() {
    // Native marks notifications read the moment the panel opens
    // (and updates its local state immediately).
    _backend.markFriendNotificationsRead();
    if (_hasUnread) {
      setState(() {
        _notifications = [
          for (final n in _notifications) n.copyWith(isRead: true),
        ];
      });
    }
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: NotelColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            Future<void> respond(
                FriendNotificationDto notification, bool accept) async {
              final requestId = notification.friendRequestId;
              if (requestId == null) return;
              final body =
                  await _backend.respondFriendRequest(requestId, accept);
              if (!mounted) return;
              if (body?['success'] == true) {
                if (!sheetContext.mounted) return;
                Navigator.of(sheetContext).pop();
                _load();
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(body?['error']?.toString() ??
                        'Could not respond to that request. Check your connection and try again.'),
                  ),
                );
              }
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Notifications',
                            style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: NotelColors.textPrimary)),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Flexible(
                      child: _notifications.isEmpty
                          ? const Padding(
                              padding: EdgeInsets.symmetric(vertical: 40),
                              child: Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.notifications_none,
                                        size: 56,
                                        color: NotelColors.textSecondary),
                                    SizedBox(height: 12),
                                    Text('You have no notifications',
                                        style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                            color:
                                                NotelColors.textSecondary)),
                                  ],
                                ),
                              ),
                            )
                          : ListView.separated(
                              shrinkWrap: true,
                              itemCount: _notifications.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 12),
                              itemBuilder: (context, i) =>
                                  _notificationRow(
                                _notifications[i],
                                onAccept: () =>
                                    respond(_notifications[i], true),
                                onDecline: () =>
                                    respond(_notifications[i], false),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _openAddFriend() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => _AddFriendDialog(
        onSend: (tag) => _backend.sendFriendRequest(tag),
        onSent: () {
          if (mounted) _load();
        },
      ),
    );
  }

  void _openFriendDetail(FriendDto friend) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => _FriendDetailDialog(
        friend: friend,
        loadDetail: () => _backend.fetchFriendDetail(friend.id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final leaderboard = buildLeaderboardWithSelf(_friends, _self);
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back,
              color: NotelColors.textPrimary, semanticLabel: 'Back'),
          onPressed: widget.onBack ?? () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Community',
          style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary),
        ),
        actions: [
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.notifications,
                    color: NotelColors.primary,
                    semanticLabel: 'Notifications'),
                onPressed: _loading ? null : _openNotifications,
              ),
              if (_hasUnread)
                const Positioned(
                  top: 10,
                  right: 10,
                  child: SizedBox(
                    width: 8,
                    height: 8,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                          color: Colors.red, shape: BoxShape.circle),
                    ),
                  ),
                ),
            ],
          ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(
              height: 1, thickness: 1, color: NotelColors.divider),
        ),
      ),
      body: _loading
          ? const SkeletonGroup(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 110),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBox(height: 140, radius: 16),
                  SizedBox(height: 16),
                  SkeletonBox(height: 180, radius: 16),
                ],
              ),
            ),
          )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
              children: [
                if (_error != null) ...[
                  _errorBanner(_error!),
                  const SizedBox(height: 16),
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Friends',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: NotelColors.textPrimary)),
                    TextButton(
                      onPressed: _openAddFriend,
                      style: TextButton.styleFrom(
                        backgroundColor:
                            NotelColors.primary.withValues(alpha: 0.2),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text('Add Friend',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: NotelColors.primary)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: NotelColors.surface,
                    borderRadius: BorderRadius.circular(16),
                    border:
                        Border.all(color: NotelColors.cardBorder),
                  ),
                  child: _friends.isEmpty
                      ? const Text(
                          'No friends added yet. Add friends using their Nickname#ID!',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: NotelColors.textSecondary),
                        )
                      : Column(
                          children: _friends
                              .map((f) => _friendRow(f))
                              .toList(),
                        ),
                ),
                const SizedBox(height: 24),
                const Text('Weekly Leaderboard',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: NotelColors.textPrimary)),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: NotelColors.surface,
                    borderRadius: BorderRadius.circular(16),
                    border:
                        Border.all(color: NotelColors.cardBorder),
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < leaderboard.length; i++)
                        _leaderboardRow(i + 1, leaderboard[i]),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _errorBanner(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: NotelColors.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: NotelColors.error.withValues(alpha: 0.4)),
      ),
      child: Text(text,
          style:
              const TextStyle(fontSize: 13, color: NotelColors.textPrimary)),
    );
  }

  Widget _friendRow(FriendDto friend) {
    return InkWell(
      onTap: () => _openFriendDetail(friend),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            _FriendAvatar(friend: friend),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(friend.nickname,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: NotelColors.textPrimary)),
                      ),
                      const SizedBox(width: 4),
                      Text('#${friend.tag}',
                          style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: NotelColors.textSecondary)),
                    ],
                  ),
                  const SizedBox(height: 3),
                  // Option A stats subline: streak (flame, orange),
                  // gems (icon, lavender), points (muted).
                  Row(
                    children: [
                      _StreakStat(streak: friend.currentStreak),
                      const SizedBox(width: 14),
                      _GemStat(gems: friend.gemBalance),
                      const SizedBox(width: 14),
                      Text(friendWeeklyPointsLabel(friend.level),
                          style: const TextStyle(
                              fontSize: 12,
                              color: NotelColors.textSecondary)),
                    ],
                  ),
                ],
              ),
            ),
            // No status/presence badge and no last-active timestamp:
            // native renders neither (the server's `status` field is
            // not presence, and no friends endpoint exposes a
            // last-logged time) — honest omission, kept in Round 48.
            const Icon(Icons.chevron_right,
                size: 18, color: NotelColors.textSecondary),
          ],
        ),
      ),
    );
  }

  Widget _leaderboardRow(int rank, FriendDto person) {
    final isSelf = person.id == 'me';
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      decoration: BoxDecoration(
        color: isSelf
            ? NotelColors.primary.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            child: Text('#$rank',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: rank == 1
                        ? NotelColors.streakGold
                        : NotelColors.textSecondary)),
          ),
          // No #tag on leaderboard rows: the approved Option A
          // mock omits it here (it stays on the friend rows and
          // the detail dialog), and at 360px the tag + the new
          // streak/gem stats crush the nickname column to zero
          // (verified in the 360 capture: "Mom" vanished, "You"
          // and "Boston" truncated). Nickname only, per the mock.
          Expanded(
            child: Text(person.nickname,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight:
                        isSelf ? FontWeight.bold : FontWeight.normal,
                    color: NotelColors.textPrimary)),
          ),
          _StreakStat(streak: person.currentStreak),
          const SizedBox(width: 16),
          _GemStat(gems: person.gemBalance),
          const SizedBox(width: 16),
          SizedBox(
            width: 72,
            child: Text('${person.level} pts',
                textAlign: TextAlign.right,
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: NotelColors.textPrimary)),
          ),
        ],
      ),
    );
  }

  Widget _notificationRow(
    FriendNotificationDto notification, {
    required VoidCallback onAccept,
    required VoidCallback onDecline,
  }) {
    final sender = [
      if ((notification.senderNickname ?? '').isNotEmpty)
        notification.senderNickname!,
      if ((notification.senderTag ?? '').isNotEmpty)
        '#${notification.senderTag}',
    ].join(' ');
    // Native shows Accept/Decline only for friend requests carrying
    // a request id.
    final canRespond = notification.type == 'friend_request' &&
        notification.friendRequestId != null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: notification.isRead
            ? NotelColors.surface
            : NotelColors.surfaceHigh.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NotelColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(notification.message,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: NotelColors.textPrimary)),
              ),
              if (!notification.isRead)
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(left: 8),
                  decoration: const BoxDecoration(
                      color: NotelColors.primary, shape: BoxShape.circle),
                ),
            ],
          ),
          if (sender.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(sender,
                style: const TextStyle(
                    fontSize: 12, color: NotelColors.textSecondary)),
          ],
          if (notification.createdAt.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(notification.createdAt,
                style: TextStyle(
                    fontSize: 11,
                    color: NotelColors.textSecondary
                        .withValues(alpha: 0.8))),
          ],
          if (canRespond) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: onDecline,
                  child: const Text('Decline',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: NotelColors.error)),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: onAccept,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: NotelColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6)),
                  ),
                  child: const Text('Accept',
                      style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Native Add Friend dialog: tag input with native's validation
/// copy, inline error/success, and the send wired to
/// `POST /api/friends/request`.
class _AddFriendDialog extends StatefulWidget {
  final Future<Map<String, dynamic>?> Function(String tag) onSend;
  final VoidCallback onSent;

  const _AddFriendDialog({required this.onSend, required this.onSent});

  @override
  State<_AddFriendDialog> createState() => _AddFriendDialogState();
}

class _AddFriendDialogState extends State<_AddFriendDialog> {
  final TextEditingController _input = TextEditingController();
  String? _error;
  String? _success;
  bool _sending = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final trimmed = _input.text.trim();
    if (!isValidFriendTag(trimmed)) {
      setState(() {
        _error = 'Invalid format. Enter a 5-digit Tag (e.g. 26385)';
        _success = null;
      });
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
      _success = null;
    });
    final body = await widget.onSend(trimmed);
    if (!mounted) return;
    setState(() => _sending = false);
    if (body?['success'] == true) {
      setState(() {
        _success = 'Request sent successfully!';
        _input.clear();
      });
      widget.onSent();
    } else {
      setState(() {
        _error = body?['error']?.toString() ??
            'Failed to send request. Check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: NotelColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Text('Add Friend',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            "Enter your friend's 5-digit Tag (e.g. 26385)",
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: NotelColors.textSecondary),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _input,
            keyboardType: TextInputType.text,
            style: const TextStyle(color: NotelColors.textPrimary),
            decoration: InputDecoration(
              hintText: 'Tag (e.g. 26385)',
              hintStyle:
                  const TextStyle(color: NotelColors.textSecondary),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                    color: NotelColors.textSecondary.withValues(alpha: 0.3)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    const BorderSide(color: NotelColors.primary),
              ),
            ),
            onChanged: (_) => setState(() {
              _error = null;
              _success = null;
            }),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: NotelColors.error)),
          ],
          if (_success != null) ...[
            const SizedBox(height: 8),
            Text(_success!,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: NotelColors.success)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel',
              style: TextStyle(color: NotelColors.textSecondary)),
        ),
        ElevatedButton(
          onPressed: _sending ? null : _send,
          style: ElevatedButton.styleFrom(
            backgroundColor: NotelColors.primary,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
          child: _sending
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2))
              : const Text('Send', style: TextStyle(fontSize: 14)),
        ),
      ],
    );
  }
}

/// Native FriendDetailDialog: header + TODAY stats grid, with the
/// loading, error, and sharing-off states native shows.
class _FriendDetailDialog extends StatefulWidget {
  final FriendDto friend;
  final Future<Map<String, dynamic>?> Function() loadDetail;

  const _FriendDetailDialog(
      {required this.friend, required this.loadDetail});

  @override
  State<_FriendDetailDialog> createState() => _FriendDetailDialogState();
}

class _FriendDetailDialogState extends State<_FriendDetailDialog> {
  bool _loading = true;
  FriendDetail? _detail;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final body = await widget.loadDetail();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (body?['success'] == true) {
        _detail = FriendDetail.fromJson(body?['data']);
        if (_detail == null) {
          _error = 'No data available yet';
        }
      } else {
        _error = body?['error']?.toString() ??
            'Could not load this friend\'s data. Check your connection and try again.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final friend = widget.friend;
    return AlertDialog(
      backgroundColor: NotelColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(friend.nickname,
                    style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: NotelColors.textPrimary)),
                Text('#${friend.tag}',
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: NotelColors.textSecondary)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close,
                color: NotelColors.textSecondary,
                semanticLabel: 'Close'),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      // Scrollable: the game-stat cards added a row to this
      // dialog (community revamp), and on short viewports the
      // full content no longer fits the dialog's max height —
      // scrolling beats clipping the last health card.
      content: SingleChildScrollView(
        child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: CircularProgressIndicator(
                    color: NotelColors.primary),
              ),
            )
          else if (_error != null)
            Text(_error!,
                style: const TextStyle(
                    fontSize: 13, color: NotelColors.error))
          else if (_detail != null) ...[
            // Game stats (community revamp, Option A): streak and
            // gems are shown to confirmed friends and are NOT gated
            // by the health-data sharing opt-in — they render in
            // both sharing states (Juno condition C2a). They sit
            // ABOVE the TODAY header: neither is a today stat
            // (Juno §2.3 placement rule). The TODAY health stats
            // below keep the existing sharing gate exactly.
            Row(
              children: [
                Expanded(
                  child: _FriendStatCard(
                    icon: Icons.local_fire_department,
                    label: 'Current Streak',
                    value: '${_detail!.currentStreak}',
                    accent: _kStreakOrange,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _FriendStatCard(
                    iconWidget: Image.asset(
                      GemCopy.iconAsset,
                      width: 20,
                      height: 20,
                      fit: BoxFit.contain,
                    ),
                    label: 'Gems',
                    value: '${_detail!.gemBalance}',
                    accent: kGemCountColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('TODAY',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1,
                    color: NotelColors.textSecondary)),
            const SizedBox(height: 12),
            if (!_detail!.sharingEnabled)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: NotelColors.surfaceHigh.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  children: [
                    const Icon(Icons.lock_outline,
                        size: 32, color: NotelColors.textSecondary),
                    const SizedBox(height: 8),
                    Text(
                      // Juno condition C2(b): health-qualified —
                      // the game stats above still show, so the
                      // unqualified "data sharing" wording would
                      // be false on its face.
                      '${friend.nickname} has turned off health data sharing',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: NotelColors.textSecondary),
                    ),
                  ],
                ),
              )
            else
              Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _FriendStatCard(
                        icon: Icons.bedtime,
                        label: 'Sleep',
                        value: formatFriendSleep(_detail!.todaySleepMins),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _FriendStatCard(
                        icon: Icons.access_time,
                        label: 'Sleep Debt',
                        value:
                            formatFriendSleepDebt(_detail!.todaySleepDebt),
                        accent: (_detail!.todaySleepDebt ?? 0) < 0
                            ? NotelColors.error
                            : NotelColors.textSecondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _FriendStatCard(
                        icon: Icons.favorite,
                        label: 'Avg HR',
                        value: _detail!.todayAvgHr != null
                            ? '${_detail!.todayAvgHr} bpm'
                            : '·',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _FriendStatCard(
                        icon: Icons.warning_amber,
                        label: 'HR Spikes',
                        value: formatFriendSpikes(_detail!.todaySpikes),
                        accent: (_detail!.todaySpikes ?? 0) > 0
                            ? NotelColors.warning
                            : NotelColors.textSecondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _FriendStatCard(
                  icon: Icons.emoji_events,
                  label: 'Daily Score',
                  value: _detail!.todayScore != null
                      ? '${_detail!.todayScore} pts'
                      : '·',
                  accent: NotelColors.primary,
                ),
              ],
              ),
          ]
          else
            const Text('No data available yet',
                style: TextStyle(
                    fontSize: 13, color: NotelColors.textSecondary)),
        ],
        ),
      ),
    );
  }
}

class _FriendStatCard extends StatelessWidget {
  final IconData? icon;

  /// Rendered instead of [icon] when set (the Gems card carries
  /// the bundled gem image, which has no IconData form).
  final Widget? iconWidget;
  final String label;
  final String value;
  final Color accent;

  const _FriendStatCard({
    this.icon,
    this.iconWidget,
    required this.label,
    required this.value,
    this.accent = NotelColors.textSecondary,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: NotelColors.surfaceHigh.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          iconWidget ?? Icon(icon, size: 20, color: accent),
          const SizedBox(height: 6),
          Text(value,
              style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: NotelColors.textPrimary)),
          Text(label,
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: NotelColors.textSecondary)),
        ],
      ),
    );
  }
}

/// Option A friend-row avatar: the friend's picked profile
/// picture when they have one (Nov 23, 2026); otherwise initials
/// on a deterministic palette color hashed from the friend's id —
/// the pre-feature rendering, kept byte-for-byte as the fallback.
/// Juno a11y ruling (Nov 23, 2026): friend-row avatars are
/// decorative next to the friend's visible name — excluded from
/// semantics; the name is the label.
class _FriendAvatar extends StatelessWidget {
  final FriendDto friend;

  const _FriendAvatar({required this.friend});

  @override
  Widget build(BuildContext context) {
    const size = 40.0;
    return ExcludeSemantics(
      child: UserAvatar(
        avatarId: friend.avatarId,
        size: size,
        fallback: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: friendAvatarColor(friend.id),
          ),
          alignment: Alignment.center,
          child: Text(
            friendAvatarInitials(friend.nickname),
            style: const TextStyle(
              fontSize: 14.4,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

/// The streak stat used by the friend rows and the leaderboard:
/// the app's streak flame glyph (Icons.local_fire_department —
/// streak_flame.dart ruling; no new asset, no emoji) + the count
/// in streak orange, bold. Semantics label per Juno condition C3:
/// "{days} day streak" (streak hero precedent).
class _StreakStat extends StatelessWidget {
  final int streak;

  const _StreakStat({required this.streak});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '$streak day streak',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.local_fire_department,
                size: 16, color: _kStreakOrange),
            const SizedBox(width: 4),
            Text('$streak',
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: _kStreakOrange)),
          ],
        ),
      ),
    );
  }
}

/// The gem stat used by the friend rows and the leaderboard: the
/// bundled gem icon (GemCopy.iconAsset) at 16dp + the count in
/// lavender (kGemCountColor, the Home gem pill's color), bold.
/// Semantics label per Juno condition C3: "{count} gems" /
/// "1 gem" — GemCopy.pillLabel, the Home gem pill precedent.
class _GemStat extends StatelessWidget {
  final int gems;

  const _GemStat({required this.gems});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: GemCopy.pillLabel(gems),
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              GemCopy.iconAsset,
              width: 16,
              height: 16,
              fit: BoxFit.contain,
            ),
            const SizedBox(width: 4),
            Text('$gems',
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: kGemCountColor)),
          ],
        ),
      ),
    );
  }
}
