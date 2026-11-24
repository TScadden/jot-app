import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'notification_service.dart';
import 'tabs_backend.dart';

/// Friend Streaks — local notification surfacing (DESIGN §6,
/// Nov 23, 2026).
///
/// Tabs has NO remote push (no FCM): friend events land as in-app
/// notification rows the app polls (`GET /api/friends/notifications`,
/// fetched by the Community screen). When that fetch surfaces a NEW
/// unread row of a friend-class type, this surfacer posts a LOCAL
/// notification for it — once per notification id, ever. The dedupe
/// set is persisted in local storage (flutter_secure_storage, the
/// app's local-storage family) so a row is never re-posted across
/// fetches, resumes, or restarts.
///
/// Copy (Juno, JUNO-COPY.md Nov 23, 2026): one title per type from
/// the fs_local_* table; the body is the SAME string as the row's
/// in-app message (the fs_notif_* string the server inserted) — no
/// second, shorter body is ever written client-side. When a row
/// arrives with an empty message, the body falls back to the Juno
/// fs_notif_* template for that type with {name} interpolated from
/// the row's sender nickname.
///
/// Scope note: friend_request / friend_accepted are friend-class
/// types under DESIGN §6 and are surfaced too, but Juno's fs_local_*
/// table rules titles only for the four friend-STREAK types. The
/// two friend titles below follow the same headline form; flag for
/// Juno at the next copy review — they are Bram's parallel
/// construction, not a Juno ruling.
///
/// Failure rule: surfacing NEVER breaks the fetch that triggered
/// it. Every step is guarded; a failed post simply leaves the id
/// out of the dedupe set so a later fetch can retry it.
class FriendStreakCopy {
  const FriendStreakCopy._();

  // fs_local_* titles (Juno — headlines, not the bare app name).
  static const String inviteTitle = 'New friend streak invite';
  static const String acceptedTitle = 'Friend streak invite accepted';
  static const String removedTitle = 'Friend streak ended';
  static const String endedTitle = 'Friend streak ended';

  // Parallel headline titles for the two non-streak friend-class
  // types (see the scope note above — not Juno-ruled).
  static const String friendRequestTitle = 'New friend request';
  static const String friendAcceptedTitle = 'Friend request accepted';

  // fs_notif_* body templates ({name} interpolated exactly where
  // shown). Used only when a row's own message is empty; the row's
  // message is the primary body by Juno's single-source rule.
  static String notifInvite(String name) =>
      '$name invited you to a friend streak.';
  static String notifAccepted(String name) =>
      '$name accepted your friend streak invite.';
  static String notifRemoved(String name) =>
      '$name ended your friend streak. You can start a new one anytime.';
  static String notifEnded(String name) =>
      'Your friend streak with $name ended. You can start a new one anytime.';
}

/// Posts one local notification for a friend event. Abstract so
/// tests can record calls without the platform plugin.
abstract class FriendLocalNotifier {
  Future<bool> show({
    required int serverNotificationId,
    required String title,
    required String body,
  });
}

/// The production notifier (flutter_local_notifications), modeled
/// on [LocalReportReadyNotifier]: posting-only — it registers no
/// tap handler of its own (the app-level [NotificationBootstrap]
/// owns the ONE plugin.initialize; unknown payloads are its no-op
/// case). Posting NEVER requests the POST_NOTIFICATIONS permission;
/// it posts only when notifications are enabled.
class LocalFriendNotifier implements FriendLocalNotifier {
  static const String channelId = 'friend_notifications';
  static const String channelName = 'Friend notifications';
  static const String channelDescription =
      'Shows when a friend event lands, like a friend streak invite '
      'or an ended friend streak.';
  static const String payloadPrefix = 'friend_notification:';

  /// Plugin notification ids for friend rows: `2000000 + (server id
  /// % 1000000)` → 2000000–2999999.
  ///
  /// Disjointness (checked against every other id owner in lib/):
  /// fixed ids 1003/1004/7301/7303/7304/770001, event ids
  /// 700000–799998, Project Focus 800000–809999, check-in
  /// 810000–819999, streak countdown 820000–829999, user reminders
  /// 101500–699999, and habit scheduled-time ids 900000–1899999 all
  /// lie strictly below this block.
  static int pluginIdFor(int serverNotificationId) =>
      2000000 + (serverNotificationId % 1000000);

  static String payloadFor(int serverNotificationId) =>
      '$payloadPrefix$serverNotificationId';

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  factory LocalFriendNotifier({FlutterLocalNotificationsPlugin? plugin}) =>
      LocalFriendNotifier._(plugin ?? FlutterLocalNotificationsPlugin());

  LocalFriendNotifier._(this._plugin);

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  Future<void> initialize() async {
    if (_initialized) return;
    await _android?.createNotificationChannel(
      const AndroidNotificationChannel(
        channelId,
        channelName,
        description: channelDescription,
        importance: Importance.defaultImportance,
      ),
    );
    if (NotificationBootstrap.initializationStarted) {
      await NotificationBootstrap.initialize(_plugin);
    } else {
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
    }
    _initialized = true;
  }

  @override
  Future<bool> show({
    required int serverNotificationId,
    required String title,
    required String body,
  }) async {
    try {
      await initialize();
      final enabled = await _android?.areNotificationsEnabled() ?? false;
      if (!enabled) return false;
      await _plugin.show(
        pluginIdFor(serverNotificationId),
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            channelName,
            channelDescription: channelDescription,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            visibility: NotificationVisibility.private,
            icon: '@mipmap/ic_launcher',
          ),
        ),
        payload: payloadFor(serverNotificationId),
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// The surfacer: given one fetch's notification rows, posts local
/// notifications for the NEW unread friend-class rows and persists
/// the posted ids. Construct via [FriendNotificationSurfacer.production]
/// in the app; tests inject storage + notifier fakes.
class FriendNotificationSurfacer {
  static const String storageKey = 'friend_notif_surfaced_ids_v1';

  /// The friend-class types DESIGN §6 surfaces locally.
  static const Set<String> friendClassTypes = {
    'friend_request',
    'friend_accepted',
    'friend_streak_invite',
    'friend_streak_accepted',
    'friend_streak_ended',
    'friend_streak_removed',
  };

  /// How many posted ids the persisted dedupe set retains (newest
  /// last). Server notification ids are monotonic, so trimming the
  /// oldest is safe.
  static const int maxRememberedIds = 300;

  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;
  final FriendLocalNotifier _notifier;

  /// In-memory copy of the dedupe set, loaded lazily on first use
  /// and kept in step with storage on every successful post.
  Set<int>? _remembered;

  FriendNotificationSurfacer({
    required this._read,
    required this._write,
    required this._notifier,
  });

  factory FriendNotificationSurfacer.production() {
    return FriendNotificationSurfacer(
      read: (key) => const FlutterSecureStorage().read(key: key),
      write: (key, value) =>
          const FlutterSecureStorage().write(key: key, value: value),
      notifier: LocalFriendNotifier(),
    );
  }

  /// The Juno headline title for [type], or null when the type is
  /// not friend-class.
  static String? titleForType(String type) {
    switch (type) {
      case 'friend_streak_invite':
        return FriendStreakCopy.inviteTitle;
      case 'friend_streak_accepted':
        return FriendStreakCopy.acceptedTitle;
      case 'friend_streak_removed':
        return FriendStreakCopy.removedTitle;
      case 'friend_streak_ended':
        return FriendStreakCopy.endedTitle;
      case 'friend_request':
        return FriendStreakCopy.friendRequestTitle;
      case 'friend_accepted':
        return FriendStreakCopy.friendAcceptedTitle;
      default:
        return null;
    }
  }

  /// The Juno fs_notif_* body template for a streak type, with
  /// {name} interpolated; null for types Juno gave no template
  /// (the friend types rely on the row's own message).
  static String? bodyTemplateFor(String type, String name) {
    switch (type) {
      case 'friend_streak_invite':
        return FriendStreakCopy.notifInvite(name);
      case 'friend_streak_accepted':
        return FriendStreakCopy.notifAccepted(name);
      case 'friend_streak_removed':
        return FriendStreakCopy.notifRemoved(name);
      case 'friend_streak_ended':
        return FriendStreakCopy.notifEnded(name);
      default:
        return null;
    }
  }

  Future<Set<int>> _loadRemembered() async {
    final cached = _remembered;
    if (cached != null) return cached;
    var ids = <int>{};
    try {
      final raw = await _read(storageKey);
      if (raw != null && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          ids = {
            for (final v in decoded)
              if (v is num) v.toInt(),
          };
        }
      }
    } catch (_) {
      // Unreadable storage: start empty in memory. Posts still
      // dedupe within the session via the in-memory set.
      ids = <int>{};
    }
    _remembered = ids;
    return ids;
  }

  Future<void> _persistRemembered(Set<int> ids) async {
    try {
      var list = ids.toList()..sort();
      if (list.length > maxRememberedIds) {
        list = list.sublist(list.length - maxRememberedIds);
      }
      await _write(storageKey, jsonEncode(list));
    } catch (_) {
      // The in-memory set still dedupes this session.
    }
  }

  /// Surfaces [rows] from one notification fetch. Returns how many
  /// local notifications were posted. NEVER throws.
  Future<int> surfaceNew(List<FriendNotificationDto> rows) async {
    var posted = 0;
    try {
      final remembered = await _loadRemembered();
      var changed = false;
      for (final row in rows) {
        try {
          if (row.isRead) continue;
          if (row.id <= 0) continue;
          if (!friendClassTypes.contains(row.type)) continue;
          if (remembered.contains(row.id)) continue;
          final title = titleForType(row.type);
          if (title == null) continue;
          var body = row.message.trim();
          if (body.isEmpty) {
            final name = (row.senderNickname ?? '').trim();
            final template =
                name.isEmpty ? null : bodyTemplateFor(row.type, name);
            if (template == null) continue;
            body = template;
          }
          final ok = await _notifier.show(
            serverNotificationId: row.id,
            title: title,
            body: body,
          );
          if (ok) {
            remembered.add(row.id);
            changed = true;
            posted++;
          }
        } catch (_) {
          // One bad row never blocks the rest of the fetch.
          continue;
        }
      }
      if (changed) await _persistRemembered(remembered);
    } catch (_) {
      // Surfacing is an enhancement on the fetch path; the fetch
      // result stands regardless.
    }
    return posted;
  }

  @visibleForTesting
  void debugResetMemory() {
    _remembered = null;
  }
}
