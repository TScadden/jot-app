import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 18 (Team C) — Health Coach, Flutter port of the native
/// `CoachHistoryScreen.kt` + `CoachScreen.kt` (chat core only).
///
/// Membership-gated like native: a non-unlimited account sees an honest
/// locked state (no paywall built). The session list comes from the
/// sync pull's `coachSessions` (+ `coachMessages` for prior messages).
/// Sending a message calls `POST api/ai/coach` with the real
/// `CoachRequest`-shaped body; the reply renders verbatim. AI failures
/// show a visible error bubble — a reply is never fabricated.
///
/// Deferred (reported to parent): session deletion (server write only),
/// file attachments, and the coach's action-proposal cards (approve/deny
/// for notes, lists, reminders, calendar, meds) — all need writes to
/// native repositories that don't exist on this branch.

/// A coach session from the sync pull.
class CoachSessionSummary {
  final String id;
  final String title;
  final int updatedAt;

  const CoachSessionSummary({
    required this.id,
    required this.title,
    required this.updatedAt,
  });

  factory CoachSessionSummary.fromJson(Map<String, dynamic> json) {
    final updated = json['updatedAt'];
    return CoachSessionSummary(
      id: '${json['id'] ?? ''}',
      title: '${json['title'] ?? 'Chat'}',
      updatedAt: updated is num ? updated.toInt() : 0,
    );
  }
}

/// A coach chat message (local view model, mirrors `CoachMessageDto`).
class CoachChatMessage {
  final String id;
  final String sessionId;
  final String role; // 'user' | 'coach' | 'error'
  final String content;
  final int timestamp;

  const CoachChatMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.content,
    required this.timestamp,
  });

  factory CoachChatMessage.fromJson(Map<String, dynamic> json) {
    final ts = json['timestamp'];
    return CoachChatMessage(
      id: '${json['id'] ?? ''}',
      sessionId: '${json['sessionId'] ?? ''}',
      role: '${json['role'] ?? 'coach'}',
      content: '${json['content'] ?? ''}',
      timestamp: ts is num ? ts.toInt() : 0,
    );
  }
}

// ── History screen ──────────────────────────────────────────────────────────

class HealthCoachScreen extends StatefulWidget {
  final TabsBackend? backend;

  const HealthCoachScreen({super.key, this.backend});

  @override
  State<HealthCoachScreen> createState() => _HealthCoachScreenState();
}

class _HealthCoachScreenState extends State<HealthCoachScreen> {
  TabsBackend get _backend => widget.backend ?? TabsBackend();

  bool? _unlocked;
  String? _gateError;
  List<CoachSessionSummary> _sessions = const [];
  Map<String, List<CoachChatMessage>> _messagesBySession = const {};
  Map<String, dynamic>? _pull;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final pull = await _backend.fetchSyncPull();
      if (!mounted) return;
      final unlimited = pull?['isUnlimited'] == true;
      setState(() {
        _pull = pull;
        _unlocked = unlimited;
        _loading = false;
        if (unlimited && pull != null) {
          _sessions = parseCoachSessions(pull['coachSessions']);
          _messagesBySession = groupCoachMessages(pull['coachMessages']);
        }
        _error = (!unlimited && pull == null)
            ? 'Could not verify membership. Check your connection and try again.'
            : null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _unlocked = false;
        _gateError = 'Could not verify membership. Check your connection and try again.';
      });
    }
  }

  Future<void> _openChat({CoachSessionSummary? session}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CoachChatScreen(
          backend: widget.backend,
          sessionId: session?.id,
          sessionTitle: session?.title ?? 'New Chat',
          initialMessages:
              session == null ? const [] : (_messagesBySession[session.id] ?? const []),
          profile: (_pull?['profile'] is Map<String, dynamic>)
              ? _pull!['profile'] as Map<String, dynamic>
              : null,
          pullEntries: _pullEntries(),
        ),
      ),
    );
    // A chat may have created a new session locally; re-pull to refresh.
    if (mounted) _load();
  }

  List<Map<String, dynamic>> _pullEntries() {
    final raw = _pull?['entries'];
    if (raw is! List) return const [];
    return [for (final e in raw) if (e is Map<String, dynamic>) e];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back,
              color: NotelColors.textPrimary, semanticLabel: 'Back'),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Tabs Coach History',
          style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary),
        ),
      ),
      floatingActionButton: _unlocked == true
          ? Padding(
              padding: const EdgeInsets.only(bottom: 72),
              child: FloatingActionButton(
                onPressed: () => _openChat(),
                backgroundColor: NotelColors.primary,
                foregroundColor: Colors.white,
                tooltip: 'New Chat',
                child: const Icon(Icons.add),
              ),
            )
          : null,
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: NotelColors.primary));
    }
    if (_unlocked == false) {
      return _LockedCoachView(
        message: _gateError ??
            _error ??
            'Health Coach requires a Tabs membership. '
                'Upgrade in the native app to unlock it.',
      );
    }
    if (_sessions.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.chat_bubble_outline,
                  size: 64, color: NotelColors.textSecondary),
              SizedBox(height: 16),
              Text('No chats yet.',
                  style: TextStyle(
                      fontSize: 16, color: NotelColors.textSecondary)),
              SizedBox(height: 4),
              Text('Tap the + button to start a conversation.',
                  style: TextStyle(
                      fontSize: 14, color: NotelColors.textSecondary)),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
      itemCount: _sessions.length,
      separatorBuilder: (context, _) => const SizedBox(height: 12),
      itemBuilder: (context, i) {
        final session = _sessions[i];
        return InkWell(
          onTap: () => _openChat(session: session),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: NotelColors.surfaceHigh,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(session.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: NotelColors.textPrimary)),
                      const SizedBox(height: 4),
                      Text(formatCoachDate(session.updatedAt),
                          style: const TextStyle(
                              fontSize: 12,
                              color: NotelColors.textSecondary)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right,
                    color: NotelColors.textSecondary),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LockedCoachView extends StatelessWidget {
  final String message;

  const _LockedCoachView({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: NotelColors.surface,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: NotelColors.cardBorder),
              ),
              child: const Icon(Icons.lock_outline,
                  size: 44, color: NotelColors.textSecondary),
            ),
            const SizedBox(height: 24),
            const Text(
              'Health Coach is locked',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: NotelColors.textPrimary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              style: const TextStyle(
                  fontSize: 14, height: 1.5, color: NotelColors.textSecondary),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Chat screen ─────────────────────────────────────────────────────────────

class CoachChatScreen extends StatefulWidget {
  final TabsBackend? backend;
  final String? sessionId;
  final String sessionTitle;
  final List<CoachChatMessage> initialMessages;
  final Map<String, dynamic>? profile;
  final List<Map<String, dynamic>> pullEntries;

  const CoachChatScreen({
    super.key,
    this.backend,
    this.sessionId,
    this.sessionTitle = 'New Chat',
    this.initialMessages = const [],
    this.profile,
    this.pullEntries = const [],
  });

  @override
  State<CoachChatScreen> createState() => _CoachChatScreenState();
}

class _CoachChatScreenState extends State<CoachChatScreen> {
  TabsBackend get _backend => widget.backend ?? TabsBackend();

  late final String _sessionId;
  late List<CoachChatMessage> _messages;
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  bool _sending = false;
  int _msgSeq = 0;

  @override
  void initState() {
    super.initState();
    _sessionId = widget.sessionId ??
        'local-${DateTime.now().millisecondsSinceEpoch}';
    _messages = List.of(widget.initialMessages);
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String _nextId() => 'local-${_msgSeq++}-${DateTime.now().millisecondsSinceEpoch}';

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _input.clear();
      _messages = [
        ..._messages,
        CoachChatMessage(
          id: _nextId(),
          sessionId: _sessionId,
          role: 'user',
          content: text,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
        CoachChatMessage(
          id: _nextId(),
          sessionId: _sessionId,
          role: 'coach',
          content: '',
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      ];
    });
    _scrollToBottom();

    // CoachRequest body, matching JotApi.kt: messages, userContext,
    // knowledgeBase, recentEntries (last 10 entry DTOs).
    final history = _messages
        .where((m) => m.role == 'user' || m.role == 'coach')
        .where((m) => m.content.isNotEmpty)
        .map((m) => {
              'id': m.id,
              'sessionId': m.sessionId,
              'role': m.role,
              'content': m.content,
              'timestamp': m.timestamp,
            })
        .toList();
    final body = {
      'messages': history,
      'userContext': widget.profile?['userContext'],
      'knowledgeBase': widget.profile?['knowledgeBase'],
      'recentEntries': [
        for (final e in widget.pullEntries.take(10))
          {
            'id': e['id'] ?? 0,
            'categoryId': e['categoryId'] ?? 0,
            'body': '${e['body'] ?? ''}',
            'chips': '${e['chips'] ?? ''}',
            'manualText': '${e['manualText'] ?? ''}',
            'timestamp': e['timestamp'] ?? 0,
          },
      ],
    };

    final res = await _backend.postAi('/api/ai/coach', body);
    if (!mounted) return;
    final reply = res?['result'];
    setState(() {
      _sending = false;
      final withoutLoading = _messages
          .where((m) => !(m.role == 'coach' && m.content.isEmpty))
          .toList();
      if (reply is String && reply.trim().isNotEmpty) {
        _messages = [
          ...withoutLoading,
          CoachChatMessage(
            id: _nextId(),
            sessionId: _sessionId,
            role: 'coach',
            content: reply,
            timestamp: DateTime.now().millisecondsSinceEpoch,
          ),
        ];
      } else {
        // Visible error — never a fabricated reply.
        _messages = [
          ...withoutLoading,
          CoachChatMessage(
            id: _nextId(),
            sessionId: _sessionId,
            role: 'error',
            content:
                'The coach could not reply right now. Check your connection and try again.',
            timestamp: DateTime.now().millisecondsSinceEpoch,
          ),
        ];
      }
    });
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back,
              color: NotelColors.textPrimary, semanticLabel: 'Back'),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: NotelColors.primary.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const Text('✨', style: TextStyle(fontSize: 16)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                widget.sessionTitle,
                style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: NotelColors.textPrimary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          const _DisclaimerBanner(),
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 40),
                      child: Text(
                        'Ask Coach anything about your health, habits, and data.',
                        style: TextStyle(
                            fontSize: 14,
                            color: NotelColors.textSecondary),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.separated(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    itemCount: _messages.length,
                    separatorBuilder: (context, _) =>
                        const SizedBox(height: 14),
                    itemBuilder: (context, i) =>
                        _ChatBubble(message: _messages[i]),
                  ),
          ),
          _InputBar(
            controller: _input,
            sending: _sending,
            onSend: _send,
          ),
        ],
      ),
    );
  }
}

class _DisclaimerBanner extends StatelessWidget {
  const _DisclaimerBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: NotelColors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: NotelColors.warning.withValues(alpha: 0.3)),
      ),
      child: const Text(
        'AI can make mistakes. This is not medical advice — always check with your care team.',
        style: TextStyle(fontSize: 12, color: NotelColors.textSecondary),
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  final CoachChatMessage message;

  const _ChatBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    final isError = message.role == 'error';
    final isLoading = message.role == 'coach' && message.content.isEmpty;

    final color = isUser
        ? NotelColors.primary.withValues(alpha: 0.15)
        : isError
            ? NotelColors.error.withValues(alpha: 0.12)
            : NotelColors.surfaceHigh.withValues(alpha: 0.5);
    final radius = isUser
        ? const BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
            bottomLeft: Radius.circular(20),
            bottomRight: Radius.circular(4),
          )
        : const BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(20),
          );

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Column(
          crossAxisAlignment:
              isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!isUser && !isError)
              const Padding(
                padding: EdgeInsets.only(left: 4, bottom: 4),
                child: Text('✨ Tabs Coach',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: NotelColors.primary)),
              ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(color: color, borderRadius: radius),
              child: isLoading
                  ? const SizedBox(
                      width: 40,
                      child: LinearProgressIndicator(
                          color: NotelColors.primary),
                    )
                  : Text(
                      message.content,
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.45,
                        color: isUser
                            ? NotelColors.primary
                            : isError
                                ? NotelColors.error
                                : NotelColors.textPrimary,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  const _InputBar(
      {required this.controller, required this.sending, required this.onSend});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        color: NotelColors.background,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                maxLines: 4,
                minLines: 1,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(
                    color: NotelColors.textPrimary, fontSize: 15),
                decoration: InputDecoration(
                  hintText: 'Ask Coach anything...',
                  hintStyle: const TextStyle(
                      color: NotelColors.textSecondary),
                  filled: true,
                  fillColor:
                      NotelColors.surfaceHigh.withValues(alpha: 0.25),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide(
                        color: NotelColors.surfaceHigh
                            .withValues(alpha: 0.5)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide(
                        color: NotelColors.surfaceHigh
                            .withValues(alpha: 0.5)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide(
                        color: NotelColors.primary.withValues(alpha: 0.5)),
                  ),
                ),
                onSubmitted: (_) => onSend(),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 48,
              height: 48,
              child: ElevatedButton(
                onPressed: sending ? null : onSend,
                style: ElevatedButton.styleFrom(
                  backgroundColor: NotelColors.primary,
                  foregroundColor: Colors.white,
                  shape: const CircleBorder(),
                  padding: EdgeInsets.zero,
                  disabledBackgroundColor: NotelColors.surfaceHigh,
                ),
                child: sending
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2),
                      )
                    : const Icon(Icons.send, semanticLabel: 'Send'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Pure parsing/formatting helpers (unit-tested) ───────────────────────────

/// Parses sync-pull `coachSessions` → newest-first summaries.
/// Skips malformed rows; never throws.
List<CoachSessionSummary> parseCoachSessions(dynamic raw) {
  if (raw is! List) return const [];
  final out = <CoachSessionSummary>[];
  for (final item in raw) {
    if (item is Map<String, dynamic> && '${item['id'] ?? ''}'.isNotEmpty) {
      out.add(CoachSessionSummary.fromJson(item));
    }
  }
  out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return out;
}

/// Groups sync-pull `coachMessages` by session id, oldest-first.
/// Skips malformed rows; never throws.
Map<String, List<CoachChatMessage>> groupCoachMessages(dynamic raw) {
  final out = <String, List<CoachChatMessage>>{};
  if (raw is! List) return out;
  for (final item in raw) {
    if (item is Map<String, dynamic> &&
        '${item['sessionId'] ?? ''}'.isNotEmpty) {
      final msg = CoachChatMessage.fromJson(item);
      out.putIfAbsent(msg.sessionId, () => []).add(msg);
    }
  }
  for (final list in out.values) {
    list.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }
  return out;
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];

/// Formats an epoch-ms timestamp like the native history list:
/// "Oct 11, 6:16 PM".
String formatCoachDate(int epochMs) {
  final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final amPm = dt.hour < 12 ? 'AM' : 'PM';
  final minute = dt.minute.toString().padLeft(2, '0');
  return '${_months[dt.month - 1]} ${dt.day}, $hour12:$minute $amPm';
}
