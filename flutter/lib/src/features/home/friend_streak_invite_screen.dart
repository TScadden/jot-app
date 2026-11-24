import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/widgets/user_avatar.dart';

// ── Mock v3 design tokens (matching streak_screen.dart) ────────
const Color _duoBg = Color(0xFF0A0A0B);
const Color _duoPrimary = Color(0xFF7C6EFF);
const Color _duoText = Color(0xFFF0EEFF);
const Color _duoMuted = Color(0xFF9A9AA3);
const Color _duoBorder = Color(0xFF39434E);
const Color _duoNavyBtn = Color(0xFF152040);
const Color _duoOnBright = Color(0xFF150F24);

TextStyle _duo(
  double size,
  double wght,
  Color color, {
  double? letterSpacing,
  double? height,
}) {
  final index = ((wght / 100).round() - 1).clamp(0, 8);
  return TextStyle(
    fontFamily: 'Nunito',
    fontSize: size,
    fontWeight: FontWeight.values[index],
    fontVariations: [FontVariation('wght', wght)],
    color: color,
    letterSpacing: letterSpacing,
    height: height,
  );
}

/// User-facing strings for the Friend Streaks picker screen
/// (Design §7, mock part 2). Kept in one obvious place so copy
/// reviews and widget tests reference a single source of truth.
///
/// All strings are Juno's SIGNED final copy (JUNO-COPY.md, Nov 23,
/// 2026). In particular footerLine1 is fs_picker_footer_delivery —
/// the AMENDED line. The mock's original line ("They get it as a
/// phone notification and in the app.") was superseded for a truth
/// defect (Tabs has no remote push; the local notification posts on
/// the friend's next app open) and must never come back.
class FriendStreakInviteCopy {
  const FriendStreakInviteCopy._();

  // fs_picker_title / fs_picker_subtitle / fs_picker_invite_button /
  // fs_picker_pending / fs_picker_active.
  static const String title = 'Invite a friend';
  static const String subtitle = 'Pick from your friends';
  static const String invite = 'INVITE';
  static const String requestPending = 'Request pending';
  static const String streakActive = 'Streak active';

  // fs_picker_footer_delivery (AMENDED) / fs_picker_footer_consent.
  static const String footerLine1 =
      'They will see it in the app, and as a phone notification the '
      'next time they open Tabs.';
  static const String footerLine2 = 'Nothing starts until they accept.';
  static const String emptyFriends =
      'No friends added yet. Add friends using their Nickname#ID!';
  static const String loadError =
      "Couldn't load your friends right now. Try again later.";
}

/// Right-side state for each accepted friend row in the picker
/// (Design §7): exactly one of tappable `INVITE` pill, plain
/// `Request pending` text, or plain `Streak active` text.
enum FriendStreakInviteRowState {
  invitable,
  pending,
  active,
}

/// Friend Streaks invite picker screen (Design §7, mock part 2).
class FriendStreakInviteScreen extends StatefulWidget {
  final DateTime? now;
  final TabsBackend? backend;
  final Future<List<FriendDto>> Function()? friendsLoader;
  final List<FriendDto>? initialFriends;
  final Set<String> initialOutgoingPending;
  final Set<String> activePartnerIds;
  final Future<Map<String, dynamic>?> Function(
    String friendId,
    String clientTabsDate,
  )?
  onInviteFriend;
  final void Function(
    String friendId, {
    String? pairId,
    FriendDto? friend,
  })?
  onInvited;

  const FriendStreakInviteScreen({
    super.key,
    this.now,
    this.backend,
    this.friendsLoader,
    this.initialFriends,
    this.initialOutgoingPending = const <String>{},
    this.activePartnerIds = const <String>{},
    this.onInviteFriend,
    this.onInvited,
  });

  @override
  State<FriendStreakInviteScreen> createState() =>
      _FriendStreakInviteScreenState();
}

class _FriendStreakInviteScreenState extends State<FriendStreakInviteScreen> {
  List<FriendDto>? _friends;
  bool _loading = false;
  bool _failed = false;

  late final Set<String> _outgoingPending;
  late final Set<String> _activePartnerIds;
  final Set<String> _invitingIds = <String>{};

  DateTime get _now => widget.now ?? DateTime.now();
  TabsBackend get _backend => widget.backend ?? TabsBackend();

  bool get _hasTestFixtures =>
      widget.backend == null &&
      (widget.initialFriends != null || widget.friendsLoader != null);

  static bool _isAcceptedFriend(FriendDto friend) {
    final status = friend.status.trim().toLowerCase();
    return status != 'pending' &&
        status != 'declined' &&
        status != 'rejected' &&
        status != 'blocked';
  }

  @override
  void initState() {
    super.initState();
    _outgoingPending = Set<String>.of(widget.initialOutgoingPending);
    _activePartnerIds = Set<String>.of(widget.activePartnerIds);
    if (widget.initialFriends != null) {
      _friends = widget.initialFriends!.where(_isAcceptedFriend).toList();
    } else {
      unawaited(_loadFriends());
    }
  }

  Future<void> _loadFriends() async {
    if (_loading) return;
    _loading = true;
    try {
      final loader =
          widget.friendsLoader ?? () => _backend.fetchFriendsList();
      final list = await loader();
      if (!mounted) return;
      setState(() {
        _friends = list.where(_isAcceptedFriend).toList();
        _failed = false;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      _loading = false;
    }
  }

  FriendStreakInviteRowState _rowStateFor(String friendId) {
    if (_activePartnerIds.contains(friendId)) {
      return FriendStreakInviteRowState.active;
    }
    if (_outgoingPending.contains(friendId)) {
      return FriendStreakInviteRowState.pending;
    }
    return FriendStreakInviteRowState.invitable;
  }

  Future<void> _sendInvite(FriendDto friend) async {
    final friendId = friend.id;
    if (_invitingIds.contains(friendId) ||
        _rowStateFor(friendId) != FriendStreakInviteRowState.invitable) {
      return;
    }
    setState(() => _invitingIds.add(friendId));
    try {
      final todayStr = tabsDayStr(_now);
      Map<String, dynamic>? res;
      if (widget.onInviteFriend != null) {
        res = await widget.onInviteFriend!(friendId, todayStr);
      } else {
        res = await _backend.inviteFriendStreak(
          friendId,
          clientTabsDate: todayStr,
        );
        if (res == null && _hasTestFixtures) {
          res = <String, dynamic>{
            'success': true,
            'pairId': 'pair-$friendId',
            'status': 'pending',
          };
        }
      }
      if (!mounted) return;
      final ok = res != null && res['success'] != false;
      if (ok) {
        final rawPairId = res['pairId'] ?? res['id'];
        final pairId = (rawPairId != null && '$rawPairId'.trim().isNotEmpty)
            ? '$rawPairId'
            : null;
        setState(() {
          _outgoingPending.add(friendId);
        });
        widget.onInvited?.call(friendId, pairId: pairId, friend: friend);
      }
    } finally {
      if (mounted) setState(() => _invitingIds.remove(friendId));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _duoBg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(context),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 2),
                      child: Text(
                        FriendStreakInviteCopy.subtitle,
                        key: const Key('friendStreakInviteSubtitle'),
                        // Mock v3 part 2: subtitle is 14.5/800 in
                        // SECONDARY grey, not a second heading.
                        style: _duo(14.5, 800, const Color(0xFFA4A4AD)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _bodyContent(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Text(
            FriendStreakInviteCopy.title,
            key: const Key('friendStreakInviteTitle'),
            style: _duo(19.5, 900, _duoText),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              key: const Key('friendStreakInviteBack'),
              tooltip: 'Back',
              // Mock v3 part 2 header carries the close (X) glyph,
              // matching the Streak screen header — not a back arrow.
              icon: const Icon(Icons.close, size: 24, color: _duoText),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bodyContent() {
    final friends = _friends;
    if (friends == null) {
      if (_failed) {
        return Padding(
          padding: const EdgeInsets.only(top: 48),
          child: Center(
            child: Text(
              FriendStreakInviteCopy.loadError,
              key: const Key('friendStreakInviteError'),
              textAlign: TextAlign.center,
              style: _duo(15, 700, _duoMuted),
            ),
          ),
        );
      }
      return const Padding(
        padding: EdgeInsets.only(top: 48),
        child: Center(
          child: CircularProgressIndicator(color: _duoPrimary),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (friends.isEmpty)
          Container(
            key: const Key('friendStreakInviteCard'),
            width: double.infinity,
            decoration: BoxDecoration(
              border: Border.all(color: _duoBorder, width: 1.2),
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
            child: Text(
              FriendStreakInviteCopy.emptyFriends,
              key: const Key('friendStreakInviteEmpty'),
              textAlign: TextAlign.center,
              style: _duo(15, 700, _duoMuted),
            ),
          )
        else
          Container(
            key: const Key('friendStreakInviteCard'),
            width: double.infinity,
            decoration: BoxDecoration(
              border: Border.all(color: _duoBorder, width: 1.2),
              borderRadius: BorderRadius.circular(16),
            ),
            // Mock: hairlines inset 16 from the card edge; rows
            // carry the rest of their own insets.
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
            child: Column(
              children: [
                for (var i = 0; i < friends.length; i++) ...[
                  if (i > 0)
                    const Divider(
                      height: 1,
                      thickness: 1,
                      indent: 11,
                      endIndent: 11,
                      color: Color(0xFF2A343C),
                    ),
                  _friendRow(friends[i]),
                ],
              ],
            ),
          ),
        const SizedBox(height: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              FriendStreakInviteCopy.footerLine1,
              key: const Key('friendStreakInviteFooterLine1'),
              style: _duo(13.5, 700, const Color(0xFF69727E), height: 1.3),
            ),
            const SizedBox(height: 4),
            Text(
              FriendStreakInviteCopy.footerLine2,
              key: const Key('friendStreakInviteFooterLine2'),
              style: _duo(13.5, 700, const Color(0xFF69727E), height: 1.3),
            ),
          ],
        ),
      ],
    );
  }

  Widget _friendRow(FriendDto friend) {
    final initial = friend.nickname.trim().isEmpty
        ? '?'
        : friend.nickname.trim()[0].toUpperCase();
    final rawTag = friend.tag.trim();
    final formattedTag = rawTag.startsWith('#') ? rawTag : '#$rawTag';
    final state = _rowStateFor(friend.id);
    final busy = _invitingIds.contains(friend.id);

    // Mock v3 part 2: avatar r24 centered on the two-line text
    // block (nickname 16.5/900 over #tag 13/700 muted); rows pitch
    // 84 (48 avatar + 18 vertical padding each side).
    return Padding(
      key: Key('friendStreakInviteRow-${friend.id}'),
      padding: const EdgeInsets.fromLTRB(7, 18, 11, 18),
      child: Row(
        children: [
          ExcludeSemantics(
            child: UserAvatar(
              avatarId: friend.avatarId,
              size: 48,
              fallback: Container(
                width: 48,
                height: 48,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF1F2A4A),
                ),
                child: Center(
                  child: Text(initial, style: _duo(22, 1000, _duoText)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  friend.nickname,
                  style: _duo(16.5, 900, _duoText),
                  overflow: TextOverflow.ellipsis,
                ),
                if (rawTag.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    formattedTag,
                    style: _duo(13, 700, const Color(0xFF69727E)),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          _rightStateWidget(friend, state, busy),
        ],
      ),
    );
  }

  Widget _rightStateWidget(
    FriendDto friend,
    FriendStreakInviteRowState state,
    bool busy,
  ) {
    switch (state) {
      case FriendStreakInviteRowState.invitable:
        return InkWell(
          key: Key('friendStreakInviteButton-${friend.id}'),
          onTap: busy ? null : () => unawaited(_sendInvite(friend)),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 13,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: _duoPrimary,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              FriendStreakInviteCopy.invite,
              // Mock v3 part 2: INVITE is 13/1000 in white.
              style: _duo(13, 1000, Colors.white),
            ),
          ),
        );
      case FriendStreakInviteRowState.pending:
        return Text(
          FriendStreakInviteCopy.requestPending,
          key: Key('friendStreakInvitePending-${friend.id}'),
          style: _duo(13.5, 800, const Color(0xFF69727E)),
        );
      case FriendStreakInviteRowState.active:
        return Text(
          FriendStreakInviteCopy.streakActive,
          key: Key('friendStreakInviteActive-${friend.id}'),
          style: _duo(13.5, 800, const Color(0xFF69727E)),
        );
    }
  }
}
