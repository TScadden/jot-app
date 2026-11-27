import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// MCP v1.1 — "Connect an AI" screen (Juno copy pack §c, FINAL,
/// `build-tabs-mcp-v11/JUNO-COPY.md`). Every user-facing string
/// on this screen is Juno's verbatim text from [ConnectAiCopy];
/// any change needs her re-sign. The two failure lines
/// ([ConnectAiCopy.loadError] / [ConnectAiCopy.disconnectError])
/// are the exceptions: Juno's pack carries no error strings, so
/// they follow the app's existing failure-line patterns
/// (streak_screen / history_screen) and are flagged for her in
/// the PR.
///
/// This screen is SEE + REVOKE ONLY. There is deliberately no
/// connection-creation UI and no credential display anywhere:
/// connecting happens in the AI app's own sign-in flow, and the
/// list payload is metadata only (name, connected date,
/// last-used date). Rows come from `GET /api/api-tokens` via
/// [TabsBackend.fetchAiConnections]; Disconnect confirms, then
/// POSTs the revoke and removes the row only on success — a
/// failed revoke keeps the row and surfaces an error (never a
/// silent no-op).
///
/// Premium gate (MCP Premium-only gate package, Juno copy pack
/// §c, FINAL, `build-mcp-premium-gate/JUNO-COPY.md`): connecting
/// an AI is a Premium feature. Entitlement resolves tri-state
/// (the PatternsScreen pattern): an explicit
/// [ConnectAiScreen.isUnlimited] seam wins, else the injectable
/// [ConnectAiScreen.membershipLoader] (default: the backend's
/// failure-distinguishing `fetchMembershipOrNull` — the sync
/// pull's `isUnlimited`, which the server computes as
/// `isAdmin || users.is_unlimited`, so trial and admin count
/// exactly as they do on every other gated surface), OR-ed with
/// the optional RevenueCat premium verdict threaded from
/// Settings (the Membership surface's iOS OR). A KNOWN Premium
/// verdict renders the v1.1 screen byte-unchanged. A KNOWN
/// non-Premium verdict renders Juno's §c Premium state instead
/// of the list (rows never render there, and neither does the
/// v1.1 empty state; the conditional lapsed note renders only
/// when a connections fetch shows the account has connections).
/// An UNKNOWN verdict (the entitlement fetch itself failed)
/// fails closed: the honest [ConnectAiCopy.loadError] line, no
/// list, no upsell — pull-to-refresh retries.
class ConnectAiCopy {
  // Juno §c — verbatim.
  static const String title = 'Connect an AI';
  static const String howItWorks =
      "Start in your AI app: add Tabs as a connection, sign in, and "
      "approve. That's it — nothing connects without your say-so.";
  static const String blurb =
      'Connecting an AI lets it read your Tabs data — your log '
      'entries, Daily Scores, streak, gems, badges, and medications '
      'list. It can only read, never change anything. Disconnect '
      'anytime here, and access stops right away.';
  static const String connectedLabel = 'Connected';
  static const String emptyState =
      'Nothing is connected yet. To connect an AI, open your AI app '
      "and add Tabs as a connection — you'll sign in and approve "
      'it there.';
  static const String disconnectButton = 'Disconnect';
  static String disconnectConfirmTitle(String name) =>
      'Disconnect $name?';
  static String disconnectConfirmBody(String name) =>
      '$name will stop being able to read your Tabs data right '
      'away. Anything it already read stays with that company, '
      'under its own privacy policy.';
  static const String confirmButton = 'Disconnect';
  static const String cancelButton = 'Cancel';
  static const String helpLinkLabel = 'How to connect an AI';

  // Sync-settings package — Juno Part 3 (JUNO-COPY.md Items
  // 5–9), verbatim. The address and ID values are BOUND into
  // the approved share text: if either value ever changes,
  // the share text needs Juno's re-approval — it is not a
  // template with values swapped in silently.
  static const String connectionAddress = 'https://api.jottracker.com/mcp';
  static const String copyAddressLabel = 'Copy address';
  static const String addressCopied = 'Address copied';
  static const String metaAiIdLabel = 'Meta AI ID';
  static const String metaAiIdHelper =
      'Meta AI asks for an ID too. This one is the same for '
      'everyone, and it is not a password.';
  static const String metaAiId = '6ESJxB8bNERxr3VtRulg0w';
  static const String idCopied = 'ID copied';
  static const String sendStepsLabel = 'Send these steps to a friend';
  static const String shareStepsText =
      'Connect your AI to Tabs:\n'
      '1. In your AI app, add a new connection and paste in this address: https://api.jottracker.com/mcp\n'
      '2. If it asks for an ID (Meta AI does), use this one, the same for everyone: 6ESJxB8bNERxr3VtRulg0w\n'
      '3. Sign in with your own Tabs account and tap Approve.\n'
      'This lets your AI read your own Tabs data. It gives me no access to anything, and nothing connects until you approve it.';

  // Premium-gate §c — verbatim (Juno Premium-gate pack §c).
  // The screen title above is unchanged in this state.
  static const String premiumHeading = 'Connecting an AI needs Premium';
  static const String premiumExplainer =
      'Connecting an AI lets it read your Tabs data — your log '
      'entries, Daily Scores, streak, gems, badges, and medications '
      'list — so you can ask it questions about your own data. It '
      'can only read, never change anything.';
  static const String premiumThirdParty =
      "Once an app reads your data, that company keeps what it "
      "read under its own privacy policy — not Tabs'.";
  static const String upgradeButton = 'Upgrade to Premium';
  static const String lapsedNote =
      "You already have connections. They're paused while Premium "
      "isn't active — not deleted, and if you resubscribe they'll "
      "work again with no need to reconnect.";

  // Failure lines — app-pattern chrome, flagged for Juno (see
  // the class doc). NOT from her pack.
  static const String loadError =
      "Couldn't load your connections right now. Try again later.";
  static const String disconnectError =
      "Couldn't disconnect that app — try again.";
  static const String helpOpenError =
      "Couldn't open that page — try again.";
}

/// Friend data sharing copy — Juno's SIGNED pack
/// (`build-mcp-sharing/JUNO-COPY.md` §a + §b), verbatim. Any
/// change to a string here needs her re-sign. Slot rules:
/// {friend}/{sharer} are display names; {categories} is the
/// exact §a2 display names, complete, in §a2 order,
/// comma-separated — never truncated or paraphrased.
class ShareCopy {
  // §a1 — Share my data.
  static const String shareTitle = 'Share my data';
  static const String shareExplainer =
      'Share some of your Tabs data with a friend, so their AI '
      'can read it and answer their questions about it — like how '
      'your sleep has been lately. You pick the friend, and you '
      'pick exactly what they can see. They can only read, never '
      'change anything.';

  // §a2 — the 8 categories, in order, names + descriptions.
  static const List<(String, String, String)> categories = [
    (
      'medications',
      'Medications',
      'Your medications list, exactly as you entered it in Tabs.'
    ),
    (
      'sleep',
      'Sleep',
      'Only your sleep numbers: how long you slept, your Sleep '
          'Need, and your sleep score. Nothing else from your '
          'Daily Scores.'
    ),
    (
      'daily_scores',
      'Daily Scores',
      'Your full Daily Scores, including the sleep, HRV, and '
          'resting heart rate numbers behind each score.'
    ),
    (
      'heart_rate_spikes',
      'Heart rate spikes',
      'Your daily spike summaries: how many spikes you had, your '
          'highest heart rate, and minutes over 100 and over 120.'
    ),
    (
      'streak',
      'Streak',
      'Your current streak, your best streak, and your streak '
          'freezes.'
    ),
    (
      'badges_and_gems',
      'Badges and gems',
      "Your gems balance and history, and the badges you've "
          'earned.'
    ),
    (
      'log_entries',
      'Log entries',
      'The entries you record in Tabs, including the text, '
          'categories, and times.'
    ),
    (
      'summaries',
      'Summaries',
      'Basic facts about your generated reports — when one was '
          'made and how many entries it covered. Never the report '
          'itself.'
    ),
  ];

  static String categoryName(String key) {
    for (final c in categories) {
      if (c.$1 == key) return c.$2;
    }
    return key;
  }

  /// The {categories} slot: exact display names, complete, in
  /// §a2 order, comma-separated.
  static String categoryList(List<String> keys) {
    final ordered = [...keys]..sort((a, b) {
        int idx(String k) {
          final i = categories.indexWhere((c) => c.$1 == k);
          return i < 0 ? categories.length : i;
        }

        return idx(a).compareTo(idx(b));
      });
    return ordered.map(categoryName).join(', ');
  }

  // §a3 — friend picker.
  static const String pickerHeading = 'Pick a friend';
  static const String pickerSubline =
      "You can only share with friends you've already accepted "
      'in Community.';
  static const String pickerEmpty =
      'No friends to share with yet. Add a friend in Community '
      'first, then come back here.';
  static const String categoryStepHeading = 'Choose what to share';
  static const String categoryStepSubline =
      "Everything starts off. Turn on only what you're okay "
      'sharing.';
  static const String nothingSelected =
      'Pick at least one thing to share first.';

  // §a4 — honesty block + send (shown above the send button,
  // every time).
  static const String thirdPartyLine =
      "Heads up: what you share doesn't go straight to your "
      "friend. It goes through your friend's AI app, on that "
      "company's systems, under that company's privacy policy — "
      "not Tabs'.";
  static const String cantPullBackLine =
      'If you stop sharing later, or turn a category off, that '
      'stops future reads right away. It can\'t take back '
      'anything their AI already read.';
  static const String sendLabel = 'Send share request';

  // §a5 — pending state.
  static String pendingLabel(String friend) =>
      'Waiting for $friend to accept';
  static String pendingExplainer(String friend) =>
      "$friend hasn't accepted yet, so their AI can't read "
      "anything. Nothing is shared until they say yes.";
  static const String cancelRequestLabel = 'Cancel request';

  // §a6 — manage view (accepted share).
  static String manageHeading(String friend) =>
      'What $friend can see';
  static const String toggleHeading = 'Categories';
  static const String toggleSubline =
      'Changes take effect right away. Turning a category off '
      "stops future reads of it — it can't take back what their "
      'AI already read.';
  static String turnOnNote(String friend) =>
      'Turning a category on shares it right away. $friend '
      "doesn't need to accept again.";
  static const String revokeLabel = 'Stop sharing';
  static String revokeConfirmTitle(String friend) =>
      'Stop sharing with $friend?';
  static const String revokeConfirmBody =
      'Their AI will stop being able to read your data right '
      'away. Anything it already read stays with that company, '
      'under its own privacy policy — stopping can\'t take that '
      'back.';
  static const String revokeConfirmButton = 'Stop sharing';
  static const String revokeCancelButton = 'Cancel';
  static const String noSharesEmpty =
      "You're not sharing anything with anyone right now.";

  // §a7 — last-read line.
  static String lastReadLine(
          String friend, String category, String when) =>
      "$friend's AI last viewed your $category $when";
  static String neverReadLine(String friend) =>
      "$friend's AI hasn't viewed your data yet";

  // §b1 — Shared with you.
  static const String sharedWithYouTitle = 'Shared with you';

  // §b2 — incoming pending offer.
  static String offerHeading(String sharer) =>
      '$sharer wants to share their Tabs data with you';
  static String offerBody(String sharer, String categories) =>
      '$sharer is offering to share: $categories. If you accept, '
      'your AI can read those parts of $sharer\'s Tabs data and '
      'answer your questions about them. It can only read — it '
      "can't change anything in their account.";
  static String incomingThirdPartyLine(String sharer) =>
      "What your AI reads doesn't stay just between you and "
      "$sharer. It goes through your AI app, on that company's "
      "systems, under that company's privacy policy — not Tabs'.";
  static String incomingCantPullBackLine(String sharer) =>
      'If $sharer stops sharing later, or turns a category off, '
      "that stops future reads. It can't take back anything "
      'your AI already read.';
  static const String acceptLabel = 'Accept';
  static const String declineLabel = 'Decline';
  static String declinedLine(String sharer) =>
      "You said no to $sharer's share, so your AI can't read "
      'any of their data.';

  // §b3 — active share row.
  static String activeRowLine(String categories, String date) =>
      'Sharing $categories with you since $date';

  // §b4 — paused lines.
  static String pausedSharerLapsed(String sharer) =>
      "Paused — $sharer's Premium isn't active right now, so "
      "your AI can't read their data. Nothing was deleted. It'll "
      "work again if they resubscribe — you don't need to do "
      'anything.';
  static const String pausedRecipientLapsed =
      "Paused — sharing needs Premium on both sides, and yours "
      "isn't active right now. Nothing was deleted. It'll work "
      'again if you resubscribe — no need to accept again.';
  static String pausedManageLine(String friend) =>
      "Paused — your Premium isn't active, so $friend's AI "
      "can't read your data right now. Your sharing choices are "
      "saved, not deleted, and they'll work again if you "
      'resubscribe.';

  // Failure lines — app-pattern chrome (the loadError pattern
  // above), NOT from Juno's pack; flagged for her in the PR.
  static const String sharesLoadError =
      "Couldn't load your sharing right now. Try again later.";
  static const String shareActionError =
      "Couldn't do that right now — try again.";
}

/// The help page (Juno copy pack §d), live with the v1.1 server
/// deploy. Opened in the browser, never in-app.
const String connectAiHelpUrl =
    'https://jottracker.com/use-tabs-with-ai.html';

/// Hands the Juno Item 9 steps text to the system share sheet.
/// The production implementation is share_plus; tests
/// substitute a recorder through
/// [ConnectAiShareService.debugSetShareFn] (the
/// StreakShareService seam pattern).
typedef ConnectAiShareFn = Future<void> Function(String text);

class ConnectAiShareService {
  ConnectAiShareService._();

  static ConnectAiShareFn? _shareOverride;

  @visibleForTesting
  static void debugSetShareFn(ConnectAiShareFn? share) {
    _shareOverride = share;
  }

  static Future<void> shareSteps(String text) async {
    final override = _shareOverride;
    if (override != null) return override(text);
    await SharePlus.instance.share(ShareParams(text: text));
  }
}

class ConnectAiScreen extends StatefulWidget {
  final TabsBackend? backend;

  /// Test seam for the help link (url_launcher's platform channel
  /// is awkward to drive in widget tests). Returns true when the
  /// browser opened. Production default: [launchUrl] external.
  final Future<bool> Function(Uri uri)? openUrl;

  /// Premium flag — tri-state (the PatternsScreen pattern). An
  /// explicit value wins. When null, membership resolves via
  /// [membershipLoader] (default: the backend's
  /// `fetchMembershipOrNull`); a failed resolution fails closed
  /// (the load-error state) and never reads as non-member, so a
  /// Premium user's list is never silently replaced by the
  /// Premium state on a cold or failed fetch.
  final bool? isUnlimited;

  /// Injectable membership resolver for the unknown-gate path:
  /// returns the resolved `isUnlimited`, or null when the
  /// resolution itself failed.
  final Future<bool?> Function()? membershipLoader;

  /// RevenueCat's validated premium verdict, threaded from
  /// Settings (iOS only there, exactly as the Membership surface
  /// receives it). OR-ed into the gate: a true verdict makes the
  /// user Premium even when the sync pull says otherwise (or
  /// cannot answer). Null = no verdict.
  final bool? revenueCatPremium;

  /// Route result popped when the free-user Premium state's
  /// upgrade button is tapped. Settings' `_openConnectAi` — this
  /// screen's only production opener — listens for it and
  /// switches its own page to Membership in the same Settings
  /// instance (no new purchase flow; the billing / RevenueCat
  /// services that instance already owns stay threaded).
  static const String upgradeRequestResult = 'upgrade';

  /// Test seam for the copy buttons (Clipboard's platform
  /// channel is awkward to drive in widget tests). Returns
  /// true when the text actually reached the clipboard — the
  /// copied confirmation shows ONLY on true (Juno Item 6).
  /// Production default: [Clipboard.setData].
  final Future<bool> Function(String text)? copyToClipboard;

  const ConnectAiScreen({
    super.key,
    this.backend,
    this.openUrl,
    this.isUnlimited,
    this.membershipLoader,
    this.revenueCatPremium,
    this.copyToClipboard,
  });

  @override
  State<ConnectAiScreen> createState() => _ConnectAiScreenState();
}

class _ConnectAiScreenState extends State<ConnectAiScreen> {
  late final TabsBackend _backend;

  /// Null until the first load lands (the loading row renders).
  List<AiConnectionDto>? _connections;
  String? _loadError;

  /// Tri-state Premium gate: null = genuinely unknown (pending,
  /// or the resolution failed — see [_entitlementFailed]).
  /// Gated content (the list AND the Premium state) renders only
  /// on a KNOWN verdict.
  bool? _isUnlimitedResolved;

  /// The entitlement fetch itself failed: fail closed with the
  /// honest load-error line — no list, no upsell.
  bool _entitlementFailed = false;

  /// Ids with a revoke in flight — their Disconnect buttons are
  /// disabled so a connection can't be double-revoked.
  final Set<String> _revoking = {};

  // ── Friend data sharing state ──
  // Null until the first shares load lands; a failed load sets
  // [_sharesLoadError] and NEVER renders an empty-state claim.
  List<FriendDto>? _friends;
  List<DataShareDto>? _outgoing;
  List<DataShareDto>? _incoming;
  List<ShareLastReadDto>? _lastReads;
  bool _sharesLoaded = false;
  String? _sharesLoadError;

  /// The friend whose category step is open in the picker, and
  /// its working toggle set (Juno §a2: everything starts off).
  String? _pickerFriendId;
  final Set<String> _pickerCategories = {};

  /// Per-share working category sets for the manage view,
  /// seeded from the share row when its manage view opens.
  final Map<String, Set<String>> _manageCategories = {};
  final Set<String> _manageOpen = {};

  /// Share/friend ids with a write in flight.
  final Set<String> _shareBusy = {};
  bool _sending = false;

  /// Friends the user declined an offer from this session —
  /// Juno §b2's declined line renders for them until refresh.
  final Set<String> _declinedThisSession = {};

  @override
  void initState() {
    super.initState();
    _backend = widget.backend ?? TabsBackend();
    _load();
  }

  Future<void> _load() async {
    await Future.wait(
        [_resolveEntitlement(), _loadConnections(), _loadShares()]);
  }

  /// Loads every sharing input. Any failure fails closed with
  /// Juno-pattern honest error (never an empty-state claim);
  /// partial successes are kept so a retry only needs the rest.
  Future<void> _loadShares() async {
    List<FriendDto>? friends;
    var friendsFailed = false;
    try {
      friends = await _backend.fetchFriendsList();
    } catch (_) {
      friendsFailed = true;
    }
    List<DataShareDto>? outgoing;
    List<DataShareDto>? incoming;
    List<ShareLastReadDto>? lastReads;
    try {
      outgoing = await _backend.fetchOutgoingShares();
    } catch (_) {
      outgoing = null;
    }
    try {
      incoming = await _backend.fetchIncomingShares();
    } catch (_) {
      incoming = null;
    }
    try {
      lastReads = await _backend.fetchShareLastReads();
    } catch (_) {
      lastReads = null;
    }
    if (!mounted) return;
    setState(() {
      if (!friendsFailed && friends != null) _friends = friends;
      if (outgoing != null) _outgoing = outgoing;
      if (incoming != null) _incoming = incoming;
      if (lastReads != null) _lastReads = lastReads;
      final failed = friendsFailed ||
          outgoing == null ||
          incoming == null ||
          lastReads == null;
      _sharesLoaded = !failed &&
          _friends != null &&
          _outgoing != null &&
          _incoming != null &&
          _lastReads != null;
      _sharesLoadError = _sharesLoaded ? null : ShareCopy.sharesLoadError;
    });
  }

  /// SCORECARD-3 #9 (mobile form): the screen's snackbar-only
  /// ERRORS route through here — 8s on screen plus a close icon, so
  /// a failure the user must act on cannot vanish at the 4s default
  /// while it is still being read. Confirmations and notices keep
  /// the stock behaviour; only the three error sites use this.
  void _showErrorSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 8),
        showCloseIcon: true,
      ),
    );
  }

  void _shareErrorSnack() {
    _showErrorSnack(ShareCopy.shareActionError);
  }

  Future<void> _sendShare() async {
    final friendId = _pickerFriendId;
    if (friendId == null || _sending) return;
    if (_pickerCategories.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(ShareCopy.nothingSelected)),
      );
      return;
    }
    setState(() => _sending = true);
    DataShareDto? created;
    try {
      created = await _backend.createDataShare(
          friendId, _orderedKeys(_pickerCategories));
    } catch (_) {
      created = null;
    }
    if (!mounted) return;
    setState(() => _sending = false);
    if (created == null) {
      _shareErrorSnack();
      return;
    }
    // The create answer carries flat ids only; re-fetch so the
    // pending row renders with the friend's name.
    await _loadShares();
    if (!mounted) return;
    setState(() {
      _pickerFriendId = null;
      _pickerCategories.clear();
    });
  }

  Future<void> _cancelPending(DataShareDto share) async {
    // Juno §a5's Cancel request IS the sharer's revoke on a
    // pending share (the server's revoke covers pending).
    await _revokeShare(share);
  }

  Future<void> _confirmRevoke(DataShareDto share) async {
    final name = share.otherNickname;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NotelColors.surface,
        title: Text(
          ShareCopy.revokeConfirmTitle(name),
          style: TextStyle(
            color: NotelColors.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          ShareCopy.revokeConfirmBody,
          style: TextStyle(color: NotelColors.textPrimary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              ShareCopy.revokeCancelButton,
              style: TextStyle(color: NotelColors.textSecondary),
            ),
          ),
          TextButton(
            key: const ValueKey('confirm_stop_sharing'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              ShareCopy.revokeConfirmButton,
              style: TextStyle(color: NotelColors.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _revokeShare(share);
  }

  Future<void> _revokeShare(DataShareDto share) async {
    if (_shareBusy.contains(share.id)) return;
    setState(() => _shareBusy.add(share.id));
    var ok = false;
    try {
      ok = await _backend.revokeDataShare(share.id);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _shareBusy.remove(share.id);
      if (ok) {
        _outgoing = _outgoing
            ?.map((s) => s.id == share.id
                ? s.copyWith(status: 'revoked')
                : s)
            .toList();
        _manageOpen.remove(share.id);
      }
    });
    if (!ok) _shareErrorSnack();
  }

  Future<void> _toggleManageCategory(
      DataShareDto share, String key, bool on) async {
    final current =
        _manageCategories[share.id] ?? share.categories.toSet();
    final next = {...current};
    if (on) {
      next.add(key);
    } else {
      next.remove(key);
    }
    if (next.isEmpty) {
      // The server rejects an empty set (Juno §a3's line is its
      // error verbatim); ending a share is Stop sharing, not an
      // empty category list.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(ShareCopy.nothingSelected)),
      );
      return;
    }
    setState(() => _manageCategories[share.id] = next);
    var ok = false;
    try {
      ok = await _backend.updateDataShareCategories(
          share.id, _orderedKeys(next));
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    if (ok) {
      setState(() {
        _outgoing = _outgoing
            ?.map((s) => s.id == share.id
                ? s.copyWith(categories: _orderedKeys(next))
                : s)
            .toList();
      });
    } else {
      setState(() => _manageCategories[share.id] = current);
      _shareErrorSnack();
    }
  }

  Future<void> _respondIncoming(DataShareDto share, bool accept) async {
    if (_shareBusy.contains(share.id)) return;
    setState(() => _shareBusy.add(share.id));
    var ok = false;
    try {
      ok = accept
          ? await _backend.acceptDataShare(share.id)
          : await _backend.declineDataShare(share.id);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _shareBusy.remove(share.id);
      if (ok) {
        _incoming = _incoming
            ?.map((s) => s.id == share.id
                ? s.copyWith(
                    status: accept ? 'accepted' : 'declined',
                    respondedAt: accept ? DateTime.now() : s.respondedAt)
                : s)
            .toList();
        if (!accept) _declinedThisSession.add(share.id);
      }
    });
    if (!ok) _shareErrorSnack();
  }

  static List<String> _orderedKeys(Set<String> keys) {
    final list = keys.toList();
    list.sort((a, b) => dataShareCategoryKeys
        .indexOf(a)
        .compareTo(dataShareCategoryKeys.indexOf(b)));
    return list;
  }

  /// Resolves the Premium gate (see the widget docs). The
  /// RevenueCat verdict ORs in exactly as on the Membership
  /// surface: a true RC verdict is Premium even when the pull
  /// says non-member or cannot answer at all.
  Future<void> _resolveEntitlement() async {
    bool? base;
    if (widget.isUnlimited != null) {
      base = widget.isUnlimited;
    } else {
      try {
        base = await (widget.membershipLoader != null
            ? widget.membershipLoader!()
            : _fetchMembershipFromBackend());
      } catch (_) {
        base = null;
      }
    }
    if (!mounted) return;
    final rcPremium = widget.revenueCatPremium ?? false;
    setState(() {
      if (base == null) {
        if (rcPremium) {
          _isUnlimitedResolved = true;
          _entitlementFailed = false;
        } else {
          _isUnlimitedResolved = null;
          _entitlementFailed = true;
        }
      } else {
        _isUnlimitedResolved = base || rcPremium;
        _entitlementFailed = false;
      }
    });
  }

  Future<bool?> _fetchMembershipFromBackend() async {
    final membership = await _backend.fetchMembershipOrNull();
    return membership?.isUnlimited;
  }

  Future<void> _loadConnections() async {
    List<AiConnectionDto>? list;
    try {
      list = await _backend.fetchAiConnections();
    } catch (_) {
      list = null;
    }
    if (!mounted) return;
    setState(() {
      if (list == null) {
        // Keep any already-shown rows on a refresh failure; the
        // error line explains, and pull-to-refresh can retry.
        _loadError = ConnectAiCopy.loadError;
        _connections ??= const [];
      } else {
        _connections = list;
        _loadError = null;
      }
    });
  }

  Future<void> _confirmDisconnect(AiConnectionDto connection) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NotelColors.surface,
        title: Text(
          ConnectAiCopy.disconnectConfirmTitle(connection.name),
          style: TextStyle(
            color: NotelColors.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          ConnectAiCopy.disconnectConfirmBody(connection.name),
          style: TextStyle(color: NotelColors.textPrimary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              ConnectAiCopy.cancelButton,
              style: TextStyle(color: NotelColors.textSecondary),
            ),
          ),
          TextButton(
            key: const ValueKey('confirm_disconnect'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              ConnectAiCopy.confirmButton,
              style: TextStyle(color: NotelColors.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _revoking.add(connection.id));
    var success = false;
    try {
      success = await _backend.revokeAiConnection(connection.id);
    } catch (_) {
      success = false;
    }
    if (!mounted) return;
    setState(() {
      _revoking.remove(connection.id);
      if (success) {
        _connections = _connections
            ?.where((c) => c.id != connection.id)
            .toList();
      }
    });
    if (!success) {
      _showErrorSnack(ConnectAiCopy.disconnectError);
    }
  }

  Future<void> _openHelp() async {
    final uri = Uri.parse(connectAiHelpUrl);
    var opened = false;
    try {
      opened = await (widget.openUrl ??
          (u) => launchUrl(u, mode: LaunchMode.externalApplication))(
        uri,
      );
    } catch (_) {
      opened = false;
    }
    if (!opened && mounted) {
      _showErrorSnack(ConnectAiCopy.helpOpenError);
    }
  }

  /// Sync-settings package — the copy buttons' shared action
  /// (Juno Items 5–7): the confirmation snack shows ONLY when
  /// the copy actually happened. On failure NO success text
  /// shows (and no failure wording exists in Juno's approved
  /// set for this action — flagged in the package stage log;
  /// nothing was invented).
  Future<void> _copyText(String value, String confirmation) async {
    var ok = false;
    try {
      ok = await (widget.copyToClipboard ??
          (text) async {
            await Clipboard.setData(ClipboardData(text: text));
            return true;
          })(value);
    } catch (_) {
      ok = false;
    }
    if (!ok || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(confirmation)),
    );
  }

  /// Juno Item 8/9 — sends the approved steps text through the
  /// system share sheet, verbatim including line breaks.
  Future<void> _shareSteps() async {
    try {
      await ConnectAiShareService.shareSteps(
          ConnectAiCopy.shareStepsText);
    } catch (_) {
      _shareErrorSnack();
    }
  }

  @override
  Widget build(BuildContext context) {
    final connections = _connections;
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back, color: NotelColors.primary),
          tooltip: 'Back',
        ),
        title: Text(
          ConnectAiCopy.title,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
        centerTitle: true,
        actions: const [SizedBox(width: 48)],
      ),
      body: RefreshIndicator(
        color: NotelColors.primary,
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(24),
          children: [
            // Fail closed on an unknown verdict: the honest
            // error line only — no list, no upsell.
            if (_entitlementFailed)
              Text(
                ConnectAiCopy.loadError,
                style: TextStyle(
                  color: NotelColors.error,
                  fontSize: 13,
                ),
              )
            // Verdict still pending: hold every gated surface.
            else if (_isUnlimitedResolved == null)
              const _LoadingRow()
            else if (_isUnlimitedResolved == true)
              ..._premiumChildren(connections)
            else
              ..._premiumStateChildren(),
          ],
        ),
      ),
    );
  }

  /// The v1.1 screen, byte-unchanged — rendered only on a KNOWN
  /// Premium verdict.
  List<Widget> _premiumChildren(List<AiConnectionDto>? connections) {
    return [
      Text(
        ConnectAiCopy.howItWorks,
        style: TextStyle(
          color: NotelColors.textPrimary,
          fontSize: 14,
          height: 20 / 14,
        ),
      ),
      const SizedBox(height: 12),
      Text(
        ConnectAiCopy.blurb,
        style: TextStyle(
          color: NotelColors.textSecondary,
          fontSize: 14,
          height: 20 / 14,
        ),
      ),
      const SizedBox(height: 16),
      // Sync-settings package (Juno Items 5–7) — the address
      // row and the Meta AI ID row, in the header block under
      // the blurb: the values a user pastes into their AI app,
      // each with its own copy action.
      _ShareCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ConnectAiCopy.connectionAddress,
              style: TextStyle(
                color: NotelColors.textPrimary,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey('copy_address_button'),
                onPressed: () => _copyText(
                    ConnectAiCopy.connectionAddress,
                    ConnectAiCopy.addressCopied),
                child: const Text(ConnectAiCopy.copyAddressLabel),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      _ShareCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ConnectAiCopy.metaAiIdLabel,
              style: TextStyle(
                color: NotelColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              ConnectAiCopy.metaAiIdHelper,
              style: TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 13,
                height: 18 / 13,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    ConnectAiCopy.metaAiId,
                    style: TextStyle(
                      color: NotelColors.textPrimary,
                      fontSize: 14,
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('copy_meta_id_button'),
                  onPressed: () => _copyText(ConnectAiCopy.metaAiId,
                      ConnectAiCopy.idCopied),
                  icon: const Icon(Icons.copy,
                      color: NotelColors.primary, size: 20),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 24),
      const _SectionLabel(ConnectAiCopy.connectedLabel),
      const SizedBox(height: 8),
      if (connections == null)
        const _LoadingRow()
      else if (connections.isEmpty && _loadError == null)
        Padding(
          padding: EdgeInsets.only(left: 4),
          child: Text(
            ConnectAiCopy.emptyState,
            style: TextStyle(
              color: NotelColors.textSecondary,
              fontSize: 14,
              height: 20 / 14,
            ),
          ),
        )
      else
        for (var i = 0; i < connections.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          _AiConnectionRow(
            key: ValueKey('ai_connection_${connections[i].id}'),
            connection: connections[i],
            revoking: _revoking.contains(connections[i].id),
            onDisconnect: () => _confirmDisconnect(connections[i]),
          ),
        ],
      if (_loadError != null) ...[
        const SizedBox(height: 12),
        Text(
          _loadError!,
          style: TextStyle(
            color: NotelColors.error,
            fontSize: 13,
          ),
        ),
      ],
      const SizedBox(height: 24),
      _HelpLinkRow(onTap: _openHelp),
      const SizedBox(height: 12),
      // Juno Item 8 — immediately after the help-link row,
      // same card-row shape.
      _SendStepsRow(onTap: _shareSteps),
      const SizedBox(height: 32),
      ..._shareMyDataChildren(),
      const SizedBox(height: 32),
      ..._sharedWithYouChildren(),
      const SizedBox(height: 32),
    ];
  }

  // ── Share my data (Juno §a) ──
  // Renders only inside _premiumChildren (KNOWN Premium
  // verdict). A failed shares load shows the honest error line
  // and NO empty-state claim; the empty state renders only on a
  // completed load.
  List<Widget> _shareMyDataChildren() {
    final children = <Widget>[
      const _SectionLabel(ShareCopy.shareTitle),
      const SizedBox(height: 8),
      Text(
        ShareCopy.shareExplainer,
        style: TextStyle(
          color: NotelColors.textSecondary,
          fontSize: 14,
          height: 20 / 14,
        ),
      ),
      const SizedBox(height: 16),
    ];
    if (!_sharesLoaded) {
      if (_sharesLoadError != null) {
        children.add(Text(
          _sharesLoadError!,
          style:
              TextStyle(color: NotelColors.error, fontSize: 13),
        ));
      } else {
        children.add(const _LoadingRow());
      }
      return children;
    }
    final outgoing = _outgoing!;
    final active =
        outgoing.where((s) => s.isPending || s.isAccepted).toList();
    if (active.isEmpty) {
      children.add(Padding(
        padding: EdgeInsets.only(left: 4),
        child: Text(
          ShareCopy.noSharesEmpty,
          style: TextStyle(
            color: NotelColors.textSecondary,
            fontSize: 14,
            height: 20 / 14,
          ),
        ),
      ));
      children.add(const SizedBox(height: 16));
    } else {
      for (var i = 0; i < active.length; i++) {
        if (i > 0) children.add(const SizedBox(height: 12));
        children.add(active[i].isPending
            ? _pendingShareCard(active[i])
            : _acceptedShareCard(active[i]));
      }
      children.add(const SizedBox(height: 16));
    }
    children.addAll(_pickerChildren());
    return children;
  }

  Widget _pendingShareCard(DataShareDto share) {
    final name = share.otherNickname;
    return _ShareCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ShareCopy.pendingLabel(name),
            style: TextStyle(
              color: NotelColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            ShareCopy.pendingExplainer(name),
            style: TextStyle(
              color: NotelColors.textSecondary,
              fontSize: 13,
              height: 18 / 13,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: ValueKey('cancel_share_${share.id}'),
              onPressed: _shareBusy.contains(share.id)
                  ? null
                  : () => _cancelPending(share),
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                foregroundColor: NotelColors.error,
              ),
              child: const Text(ShareCopy.cancelRequestLabel),
            ),
          ),
        ],
      ),
    );
  }

  Widget _acceptedShareCard(DataShareDto share) {
    final name = share.otherNickname;
    final open = _manageOpen.contains(share.id);
    final lastRead = _lastReadFor(share);
    return _ShareCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  style: TextStyle(
                    color: NotelColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              TextButton(
                key: ValueKey('manage_share_${share.id}'),
                onPressed: () => setState(() {
                  if (open) {
                    _manageOpen.remove(share.id);
                  } else {
                    _manageOpen.add(share.id);
                    _manageCategories[share.id] =
                        share.categories.toSet();
                  }
                }),
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                ),
                child: Text(open ? 'Done' : 'Manage'),
              ),
            ],
          ),
          Text(
            lastRead,
            style: TextStyle(
              color: NotelColors.textSecondary,
              fontSize: 12,
              height: 16 / 12,
            ),
          ),
          if (open) ...[
            const SizedBox(height: 8),
            Text(
              ShareCopy.manageHeading(name),
              style: TextStyle(
                color: NotelColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const _SectionLabel(ShareCopy.toggleHeading),
            Text(
              ShareCopy.toggleSubline,
              style: TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 13,
                height: 18 / 13,
              ),
            ),
            const SizedBox(height: 4),
            for (final cat in ShareCopy.categories)
              SwitchListTile(
                key: ValueKey('manage_cat_${share.id}_${cat.$1}'),
                contentPadding: EdgeInsets.zero,
                title: Text(
                  cat.$2,
                  style: TextStyle(
                    color: NotelColors.textPrimary,
                    fontSize: 14,
                  ),
                ),
                value: (_manageCategories[share.id] ??
                        share.categories.toSet())
                    .contains(cat.$1),
                onChanged: _shareBusy.contains(share.id)
                    ? null
                    : (v) => _toggleManageCategory(share, cat.$1, v),
              ),
            Text(
              ShareCopy.turnOnNote(name),
              style: TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 13,
                height: 18 / 13,
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: ValueKey('stop_sharing_${share.id}'),
                onPressed: _shareBusy.contains(share.id)
                    ? null
                    : () => _confirmRevoke(share),
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  foregroundColor: NotelColors.error,
                ),
                child: const Text(ShareCopy.revokeLabel),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Juno §a7: the latest read for this share's friend, or the
  /// never-read line. The endpoint returns one row per
  /// (recipient, category); the line shows the most recent.
  String _lastReadFor(DataShareDto share) {
    final name = share.otherNickname;
    final rows = (_lastReads ?? const <ShareLastReadDto>[])
        .where((r) =>
            r.recipientId == share.otherId && r.readAt != null)
        .toList()
      ..sort((a, b) => b.readAt!.compareTo(a.readAt!));
    if (rows.isEmpty) return ShareCopy.neverReadLine(name);
    final latest = rows.first;
    return ShareCopy.lastReadLine(
      name,
      ShareCopy.categoryName(latest.category),
      _formatShareWhen(latest.readAt!),
    );
  }

  List<Widget> _pickerChildren() {
    final friends = _friends!;
    final children = <Widget>[
      const _SectionLabel(ShareCopy.pickerHeading),
      Padding(
        padding: EdgeInsets.only(left: 4),
        child: Text(
          ShareCopy.pickerSubline,
          style: TextStyle(
            color: NotelColors.textSecondary,
            fontSize: 13,
            height: 18 / 13,
          ),
        ),
      ),
      const SizedBox(height: 8),
    ];
    if (friends.isEmpty) {
      children.add(Padding(
        padding: EdgeInsets.only(left: 4),
        child: Text(
          ShareCopy.pickerEmpty,
          style: TextStyle(
            color: NotelColors.textSecondary,
            fontSize: 14,
            height: 20 / 14,
          ),
        ),
      ));
      return children;
    }
    // Picker population is fetchFriendsList() output exactly —
    // accepted friends by construction (the server's friends
    // table). FriendDto.status is a hardcoded server literal and
    // is never filtered or labelled on.
    final sharedIds = (_outgoing ?? const <DataShareDto>[])
        .where((s) => s.isPending || s.isAccepted)
        .map((s) => s.otherId)
        .toSet();
    for (final friend in friends) {
      if (sharedIds.contains(friend.id)) continue;
      children.add(_ShareCard(
        child: InkWell(
          key: ValueKey('pick_friend_${friend.id}'),
          onTap: () => setState(() {
            if (_pickerFriendId == friend.id) {
              _pickerFriendId = null;
            } else {
              _pickerFriendId = friend.id;
              _pickerCategories.clear();
            }
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    friend.nickname,
                    style: TextStyle(
                      color: NotelColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Icon(
                  _pickerFriendId == friend.id
                      ? Icons.expand_less
                      : Icons.expand_more,
                  color: NotelColors.textSecondary,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ));
      children.add(const SizedBox(height: 8));
      if (_pickerFriendId == friend.id) {
        children.addAll(_categoryStepChildren());
        children.add(const SizedBox(height: 8));
      }
    }
    return children;
  }

  List<Widget> _categoryStepChildren() {
    return [
      const _SectionLabel(ShareCopy.categoryStepHeading),
      Padding(
        padding: EdgeInsets.only(left: 4),
        child: Text(
          ShareCopy.categoryStepSubline,
          style: TextStyle(
            color: NotelColors.textSecondary,
            fontSize: 13,
            height: 18 / 13,
          ),
        ),
      ),
      const SizedBox(height: 4),
      for (final cat in ShareCopy.categories)
        SwitchListTile(
          key: ValueKey('pick_cat_${cat.$1}'),
          contentPadding: EdgeInsets.zero,
          title: Text(
            cat.$2,
            style: TextStyle(
              color: NotelColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          subtitle: Text(
            cat.$3,
            style: TextStyle(
              color: NotelColors.textSecondary,
              fontSize: 12,
              height: 16 / 12,
            ),
          ),
          value: _pickerCategories.contains(cat.$1),
          onChanged: (v) => setState(() {
            if (v) {
              _pickerCategories.add(cat.$1);
            } else {
              _pickerCategories.remove(cat.$1);
            }
          }),
        ),
      const SizedBox(height: 8),
      // Juno §a4: the honesty block sits directly above the send
      // button, every time.
      Text(
        ShareCopy.thirdPartyLine,
        style: TextStyle(
          color: NotelColors.textSecondary,
          fontSize: 13,
          height: 18 / 13,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        ShareCopy.cantPullBackLine,
        style: TextStyle(
          color: NotelColors.textSecondary,
          fontSize: 13,
          height: 18 / 13,
        ),
      ),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          key: const ValueKey('send_share_request'),
          style: ElevatedButton.styleFrom(
            backgroundColor: NotelColors.primary,
            foregroundColor: NotelColors.onPrimary,
            minimumSize: const Size(64, 48),
          ),
          onPressed: _sending ? null : _sendShare,
          child: const Text(
            ShareCopy.sendLabel,
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ),
    ];
  }

  // ── Shared with you (Juno §b) ──
  List<Widget> _sharedWithYouChildren() {
    final children = <Widget>[
      const _SectionLabel(ShareCopy.sharedWithYouTitle),
      const SizedBox(height: 8),
    ];
    if (!_sharesLoaded) {
      if (_sharesLoadError != null) {
        children.add(Text(
          _sharesLoadError!,
          style:
              TextStyle(color: NotelColors.error, fontSize: 13),
        ));
      } else {
        children.add(const _LoadingRow());
      }
      return children;
    }
    final incoming = _incoming!;
    final pending = incoming.where((s) => s.isPending).toList();
    final accepted = incoming.where((s) => s.isAccepted).toList();
    final declined = incoming
        .where((s) =>
            s.status == 'declined' &&
            _declinedThisSession.contains(s.id))
        .toList();
    var first = true;
    for (final share in pending) {
      if (!first) children.add(const SizedBox(height: 12));
      first = false;
      children.add(_incomingOfferCard(share));
    }
    for (final share in accepted) {
      if (!first) children.add(const SizedBox(height: 12));
      first = false;
      children.add(_activeIncomingCard(share));
    }
    for (final share in declined) {
      if (!first) children.add(const SizedBox(height: 12));
      first = false;
      children.add(Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Text(
          ShareCopy.declinedLine(share.otherNickname),
          style: TextStyle(
            color: NotelColors.textSecondary,
            fontSize: 13,
            height: 18 / 13,
          ),
        ),
      ));
    }
    return children;
  }

  Widget _incomingOfferCard(DataShareDto share) {
    final name = share.otherNickname;
    final cats = ShareCopy.categoryList(share.categories);
    return _ShareCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ShareCopy.offerHeading(name),
            style: TextStyle(
              color: NotelColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            ShareCopy.offerBody(name, cats),
            style: TextStyle(
              color: NotelColors.textSecondary,
              fontSize: 13,
              height: 18 / 13,
            ),
          ),
          const SizedBox(height: 8),
          // Juno §b2: both honesty lines directly above Accept.
          Text(
            ShareCopy.incomingThirdPartyLine(name),
            style: TextStyle(
              color: NotelColors.textSecondary,
              fontSize: 13,
              height: 18 / 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            ShareCopy.incomingCantPullBackLine(name),
            style: TextStyle(
              color: NotelColors.textSecondary,
              fontSize: 13,
              height: 18 / 13,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                key: ValueKey('decline_share_${share.id}'),
                onPressed: _shareBusy.contains(share.id)
                    ? null
                    : () => _respondIncoming(share, false),
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  foregroundColor: NotelColors.textSecondary,
                ),
                child: const Text(ShareCopy.declineLabel),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                key: ValueKey('accept_share_${share.id}'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: NotelColors.primary,
                  foregroundColor: NotelColors.onPrimary,
                  minimumSize: const Size(64, 48),
                ),
                onPressed: _shareBusy.contains(share.id)
                    ? null
                    : () => _respondIncoming(share, true),
                child: const Text(
                  ShareCopy.acceptLabel,
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _activeIncomingCard(DataShareDto share) {
    final since = share.respondedAt ?? share.createdAt;
    return _ShareCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            share.otherNickname,
            style: TextStyle(
              color: NotelColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            ShareCopy.activeRowLine(
              ShareCopy.categoryList(share.categories),
              since == null ? '' : _formatShareDate(since),
            ),
            style: TextStyle(
              color: NotelColors.textSecondary,
              fontSize: 12,
              height: 16 / 12,
            ),
          ),
          // NOTE: no recipient-side remove/end-share action is
          // surfaced — it has no signed copy (Juno flag 8).
        ],
      ),
    );
  }

  /// Juno §c Premium state — rendered only on a KNOWN
  /// non-Premium verdict, instead of the connections list. The
  /// rows never render here and neither does the v1.1 empty
  /// state; the lapsed note renders only when the connections
  /// fetch shows the account actually has connections.
  List<Widget> _premiumStateChildren() {
    final hasConnections =
        _connections != null && _connections!.isNotEmpty;
    return [
      Text(
        ConnectAiCopy.premiumHeading,
        style: TextStyle(
          color: NotelColors.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.bold,
          height: 24 / 18,
        ),
      ),
      const SizedBox(height: 12),
      Text(
        ConnectAiCopy.premiumExplainer,
        style: TextStyle(
          color: NotelColors.textPrimary,
          fontSize: 14,
          height: 20 / 14,
        ),
      ),
      const SizedBox(height: 12),
      Text(
        ConnectAiCopy.premiumThirdParty,
        style: TextStyle(
          color: NotelColors.textSecondary,
          fontSize: 14,
          height: 20 / 14,
        ),
      ),
      if (hasConnections) ...[
        const SizedBox(height: 12),
        Text(
          ConnectAiCopy.lapsedNote,
          style: TextStyle(
            color: NotelColors.textSecondary,
            fontSize: 14,
            height: 20 / 14,
          ),
        ),
      ],
      const SizedBox(height: 24),
      SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          key: const ValueKey('upgrade_to_premium'),
          style: ElevatedButton.styleFrom(
            backgroundColor: NotelColors.primary,
            // Dark ink on primary, the Membership CTA pairing
            // (5.21:1; settings_screen.dart's _chipInk).
            foregroundColor: NotelColors.onPrimary,
            minimumSize: const Size(64, 48),
          ),
          onPressed: () => Navigator.of(context)
              .pop(ConnectAiScreen.upgradeRequestResult),
          child: const Text(
            ConnectAiCopy.upgradeButton,
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ),
      const SizedBox(height: 32),
    ];
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 4),
      child: Text(
        text,
        style: TextStyle(
          color: NotelColors.textSecondary,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _LoadingRow extends StatelessWidget {
  const _LoadingRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: NotelColors.primary,
          ),
        ),
      ),
    );
  }
}

/// One connected AI app: name, when it connected, when it was
/// last used (when the server reports it), and its Disconnect
/// button. Styled to match the Data connections rows (20dp
/// radius surface card, 14sp bold name, 12sp status lines).
class _AiConnectionRow extends StatelessWidget {
  final AiConnectionDto connection;
  final bool revoking;
  final VoidCallback onDisconnect;

  const _AiConnectionRow({
    super.key,
    required this.connection,
    required this.revoking,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final connectedAt = connection.connectedAt;
    final lastUsedAt = connection.lastUsedAt;
    return Container(
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: NotelColors.surfaceHigh.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: NotelColors.legacyDarkHairlineFaint,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.smart_toy_outlined,
                color: NotelColors.primary,
                size: 24,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    connection.name,
                    style: TextStyle(
                      color: NotelColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (connectedAt != null)
                    Text(
                      'Connected ${_formatConnectionDate(connectedAt)}',
                      style: TextStyle(
                        color: NotelColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  if (lastUsedAt != null)
                    Text(
                      'Last used ${_formatConnectionDate(lastUsedAt)}',
                      style: TextStyle(
                        color: NotelColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
            TextButton(
              key: ValueKey('disconnect_${connection.id}'),
              onPressed: revoking ? null : onDisconnect,
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                foregroundColor: NotelColors.error,
              ),
              child: revoking
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: NotelColors.primary,
                      ),
                    )
                  : const Text(ConnectAiCopy.disconnectButton),
            ),
          ],
        ),
      ),
    );
  }
}

/// The help link row: Juno's label, opens the help page in the
/// browser. A full-width tappable row (48dp+ hit area).
class _HelpLinkRow extends StatelessWidget {
  final VoidCallback onTap;
  const _HelpLinkRow({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: NotelColors.surfaceHigh.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(
                  Icons.help_outline,
                  color: NotelColors.primary,
                  size: 24,
                ),
                SizedBox(width: 16),
                Expanded(
                  child: Text(
                    ConnectAiCopy.helpLinkLabel,
                    style: TextStyle(
                      color: NotelColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Icon(
                  Icons.open_in_new,
                  color: NotelColors.textSecondary,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The "Send these steps to a friend" row (Juno Item 8): the
/// help-link row's shape, with a share action instead of a
/// browser hand-off.
class _SendStepsRow extends StatelessWidget {
  final VoidCallback onTap;
  const _SendStepsRow({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: NotelColors.surfaceHigh.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          key: const ValueKey('send_steps_row'),
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(
                  Icons.share,
                  color: NotelColors.primary,
                  size: 24,
                ),
                SizedBox(width: 16),
                Expanded(
                  child: Text(
                    ConnectAiCopy.sendStepsLabel,
                    style: TextStyle(
                      color: NotelColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Card chrome for the sharing sections — the connection rows'
/// surface card (20dp radius, hairline border).
class _ShareCard extends StatelessWidget {
  final Widget child;
  const _ShareCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: NotelColors.surfaceHigh.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        // Material so the SwitchListTiles / InkWells inside
        // paint their ink on this card, not the scaffold behind
        // the DecoratedBox (the ListTile-background assertion).
        child: Material(color: Colors.transparent, child: child),
      ),
    );
  }
}

/// Juno §a7's {when} rule: `today` / `yesterday` for the last
/// two days; `on {weekday}` within the last 7 days;
/// `on {Month D, YYYY}` for anything older. Calendar days are
/// compared device-local.
String _formatShareWhen(DateTime readAt, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final readDay = DateTime(readAt.year, readAt.month, readAt.day);
  final days = today.difference(readDay).inDays;
  if (days <= 0) return 'today';
  if (days == 1) return 'yesterday';
  if (days < 7) {
    const weekdays = [
      '', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday',
      'Saturday', 'Sunday'
    ];
    return 'on ${weekdays[readAt.weekday]}';
  }
  return 'on ${_formatShareDate(readAt)}';
}

/// `{Month D, YYYY}` in full (e.g. "November 9, 2026") — Juno
/// §a7/§b3's long form, NOT the abbreviated house format.
String _formatShareDate(DateTime d) {
  const months = [
    '', 'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November',
    'December'
  ];
  return '${months[d.month]} ${d.day}, ${d.year}';
}

/// `MMM d, yyyy` (e.g. "Nov 22, 2026"), device-local — the app's
/// house date format (hand-rolled month table, the
/// medications.dart / heart_data.dart pattern; no intl).
String _formatConnectionDate(DateTime d) {
  const months = [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  return '${months[d.month]} ${d.day}, ${d.year}';
}
