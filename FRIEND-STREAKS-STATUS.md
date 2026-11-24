# Friend Streaks (App) — Implementation Status

Branch: `agy/friend-streaks-ui`
Design reference: `../FRIEND-STREAKS-DESIGN.md` (locked Nov 23, 2026)

## Done
- [x] **Step 1 — Backend client (`flutter/lib/src/data/tabs_backend.dart`)**:
  - Added DTOs for Design §4 (`FriendStreakPartnerDto`, `FriendStreakIncomingDto`, `FriendStreakPairDto`, `FriendStreaksDto`) with tolerant JSON parsing and `avatarId` support matching `FriendDto`.
  - Extended `FriendNotificationDto` with optional `senderAvatarId` support.
  - Added `TabsBackend` methods: `fetchFriendStreaks`, `fetchFriendStreaksOrNull`, `inviteFriendStreak`, `respondFriendStreak`, and `removeFriendStreak`.
- [ ] **Step 2 — FRIENDS tab (`flutter/lib/src/features/home/streak_screen.dart`)**: Replace old friends list body with Friend Streaks empty state, populated state (incoming invites + active pairs + bottom invite row), and EDIT mode (remove/cancel actions).
- [ ] **Step 3 — Picker screen (`flutter/lib/src/features/home/friend_streak_invite_screen.dart`)**: Accepted friends picker with `INVITE` pill, `Request pending`, and active pair state.
- [ ] **Step 4 — Local notification surfacing**: Post local notification once per unread friend-class notification id (`friend_request`, `friend_accepted`, `friend_streak_invite`, `friend_streak_accepted`, `friend_streak_ended`, `friend_streak_removed`), tracked in local storage beside the notification fetch flow.
- [ ] **Step 5 — Widget tests (`flutter/test/`)**: Tests covering empty state, incoming invite accept/decline, active pair count + status lines, EDIT remove flow, picker pending state, and local notification deduplication.
- [ ] **Step 6 — Toolchain verification**: Check/run `flutter analyze` and streak tests.

## Unverified / Toolchain Notes
- `flutter` / `dart` CLI is not installed on this Windows host (checked `PATH`, `C:\`, `C:\Users\tyson`, `C:\Users\tyson\AppData`, and WSL). Static analysis and widget test execution cannot be run locally on this machine.

## Design Ambiguities Resolved
1. **Outgoing pending representation & EDIT cancel (`GET /api/friends/streaks`)**:
   - Design §4 specifies `outgoingPending: [friendId...]` (a list of partner userId strings), while Design §7 states that in EDIT mode "outgoing pending rows gain cancel" and §4 states `POST /api/friends/streaks/remove { pairId }` handles both active remove and pending cancel.
   - `FriendStreaksDto.fromJson` accepts `outgoingPending` entries as either raw `friendId` strings or `{ pairId, friendId / partner }` maps, and stores any known `pairId` mapping in `outgoingPendingPairIds` (also populated when an invite is sent in-session). When cancelling an outgoing pending invite in EDIT mode, the client sends the mapped `pairId` (falling back to the `friendId` key if no separate `pairId` was supplied by the fixture/server).
