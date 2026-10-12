import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Leaderboard order: friends sorted by weekly level, highest first.
/// Pure and unit-testable.
List<FriendDto> buildLeaderboard(List<FriendDto> friends) {
  final out = List<FriendDto>.of(friends);
  out.sort((a, b) => b.level.compareTo(a.level));
  return out;
}

/// Round 18, Team D — Community tool screen (read-only).
///
/// Ports `CommunityScreen.kt` / `CommunityViewModel.kt` display paths:
/// friends list, weekly leaderboard (friends only, sorted by `level`), and
/// the notifications panel with unread badges. Data comes from
/// [TabsBackend.fetchFriendsList] and [TabsBackend.fetchFriendNotifications].
///
/// DEFERRED for this round (per the round brief): sending friend requests
/// and accepting/declining requests (the shared data layer has no POST
/// helpers for those endpoints and `FriendNotificationDto` carries no
/// request id), plus the friend-detail dialog (`getFriendDetail` is not in
/// the shared layer).
class CommunityToolScreen extends StatefulWidget {
  final VoidCallback? onBack;
  final TabsBackend? backend;

  const CommunityToolScreen({super.key, this.onBack, this.backend});

  @override
  State<CommunityToolScreen> createState() => _CommunityToolScreenState();
}

class _CommunityToolScreenState extends State<CommunityToolScreen> {
  TabsBackend get _backend => widget.backend ?? TabsBackend();

  bool _loading = true;
  List<FriendDto> _friends = const [];
  List<FriendNotificationDto> _notifications = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        _backend.fetchFriendsList(),
        _backend.fetchFriendNotifications(),
      ]);
      if (!mounted) return;
      setState(() {
        _friends = results[0] as List<FriendDto>;
        _notifications = results[1] as List<FriendNotificationDto>;
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

  void _openNotifications() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: NotelColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
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
                              _notificationRow(_notifications[i]),
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final leaderboard = buildLeaderboard(_friends);
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
          ? const Center(
              child: CircularProgressIndicator(color: NotelColors.primary))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
              children: [
                if (_error != null) ...[
                  _errorBanner(_error!),
                  const SizedBox(height: 16),
                ],
                const Text('Friends',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: NotelColors.textPrimary)),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: NotelColors.surface.withValues(alpha: 0.8),
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
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: NotelColors.textPrimary)),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: NotelColors.surface.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(16),
                    border:
                        Border.all(color: NotelColors.cardBorder),
                  ),
                  child: leaderboard.isEmpty
                      ? const Text(
                          'No scores yet. Add friends to see how you rank.',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: NotelColors.textSecondary),
                        )
                      : Column(
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
      padding: const EdgeInsets.all(14),
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(friend.nickname,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: NotelColors.textPrimary)),
                  const SizedBox(width: 4),
                  Text('#${friend.tag}',
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: NotelColors.textSecondary)),
                ],
              ),
              Text('${friend.level} pts',
                  style: const TextStyle(
                      fontSize: 12, color: NotelColors.textSecondary)),
            ],
          ),
          // Round 18b: no status/presence badge. Native never renders one
          // (the server's `status` field is not presence), and no
          // last-active timestamp exists in any friends endpoint — so
          // nothing is rendered instead of a fake "Online".
        ],
      ),
    );
  }

  Widget _leaderboardRow(int rank, FriendDto person) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
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
              Text(person.nickname,
                  style: const TextStyle(
                      fontSize: 15, color: NotelColors.textPrimary)),
              if (person.tag.isNotEmpty && person.tag != '00000') ...[
                const SizedBox(width: 4),
                Text('#${person.tag}',
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: NotelColors.textSecondary)),
              ],
            ],
          ),
          Text('${person.level} pts',
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: NotelColors.textPrimary)),
        ],
      ),
    );
  }

  Widget _notificationRow(FriendNotificationDto notification) {
    final sender = [
      if ((notification.senderNickname ?? '').isNotEmpty)
        notification.senderNickname!,
      if ((notification.senderTag ?? '').isNotEmpty)
        '#${notification.senderTag}',
    ].join(' ');
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
        ],
      ),
    );
  }
}
