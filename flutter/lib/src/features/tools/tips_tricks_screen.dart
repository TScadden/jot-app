import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:tabs_lab/src/data/session_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/skeleton.dart';

/// Round 18 (Team C) — Tips & Tricks, Flutter port of the native
/// `TipsAndTricksScreen.kt` + `TipsAndTricksViewModel.kt`.
///
/// Membership-gated like native: when [TabsBackend.fetchIsUnlimited] is
/// false (or the check fails), an honest locked state is shown — no
/// paywall is built, just the lock. When unlocked, topic generation and
/// per-topic tips go through `POST api/ai/advice` with the same
/// `AiRequest`-shaped body the native `GeminiService.getAdvice` sends.
///
/// Round 48 — the topic/answer cache is now PERSISTED, mirroring
/// native: topics and per-topic answers live in local preferences
/// (`tipsAndTricksTopics` / `tipsAndTricksAnswers` in native's
/// DataStore), so reopening the tool shows the last generated topics
/// immediately instead of the onboarding prompt, and cached answers
/// open without a new AI call. Regenerating topics clears the
/// cached answers, exactly like native. The Flutter store is
/// [TipsCacheStore] (secure storage; injectable for tests).
class TipsTricksScreen extends StatefulWidget {
  final TabsBackend? backend;

  /// Injectable for tests (Round 48 cache persistence).
  final TipsCacheStore? cacheStore;

  const TipsTricksScreen({super.key, this.backend, this.cacheStore});

  @override
  State<TipsTricksScreen> createState() => _TipsTricksScreenState();
}

/// Round 48 — persisted topics/answers cache, mirroring native's
/// DataStore preferences (`tipsAndTricksTopics` = a JSON array
/// string, `tipsAndTricksAnswers` = a JSON object of topic →
/// string array). Injectable read/write so tests never touch
/// platform channels (ToolOrderStore pattern).
class TipsCacheStore {
  static const String topicsKey = 'tips_tricks_topics_v1';
  static const String answersKey = 'tips_tricks_answers_v1';
  static const String ownerKey = 'tips_tricks_owner_v1';

  Future<String?> Function(String key) _read =
      (key) => const FlutterSecureStorage().read(key: key);
  Future<void> Function(String key, String value) _write =
      (key, value) =>
          const FlutterSecureStorage().write(key: key, value: value);
  Future<void> Function(String key) _delete =
      (key) => const FlutterSecureStorage().delete(key: key);

  /// Test seam.
  void debugSetIO({
    Future<String?> Function(String key)? read,
    Future<void> Function(String key, String value)? write,
    Future<void> Function(String key)? delete,
  }) {
    if (read != null) _read = read;
    if (write != null) _write = write;
    if (delete != null) _delete = delete;
  }

  // Every IO op is timeout-guarded, mirroring Food's encyclopedia
  // restore: a wedged storage channel (an unmocked MethodChannel in
  // tests never answers) must never block the screen — a timeout
  // behaves exactly like the existing IO-failure path below.
  Future<List<String>> loadTopics() async {
    try {
      final raw =
          await _read(topicsKey).timeout(const Duration(seconds: 3));
      if (raw == null || raw.trim().isEmpty) return const [];
      return decodeCachedTopics(raw);
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveTopics(List<String> topics) async {
    try {
      await _write(topicsKey, jsonEncode(topics))
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      // Cache persistence never breaks the UI.
    }
  }

  Future<Map<String, List<String>>> loadAnswers() async {
    try {
      final raw =
          await _read(answersKey).timeout(const Duration(seconds: 3));
      if (raw == null || raw.trim().isEmpty) return const {};
      return decodeCachedAnswers(raw);
    } catch (_) {
      return const {};
    }
  }

  Future<void> saveAnswers(Map<String, List<String>> answers) async {
    try {
      await _write(answersKey, jsonEncode(answers))
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      // Cache persistence never breaks the UI.
    }
  }

  Future<void> clearAnswers() async {
    try {
      await _delete(answersKey).timeout(const Duration(seconds: 3));
    } catch (_) {
      // Cache persistence never breaks the UI.
    }
  }

  /// Founder seed findings (Oct 28, 2026): the cached topics and
  /// answers are generated from one account's context, but the keys
  /// were global and NO path ever cleared them — a new account
  /// opening Tips & Tricks inherited the previous account's AI
  /// topics/answers. When the stamped owner differs from [email]
  /// (including legacy unstamped cache), both keys are wiped and
  /// the store is re-stamped. Returns true when a wipe happened.
  /// Never throws.
  Future<bool> clearIfOwnerMismatch(String? email) async {
    final e = email?.trim().toLowerCase();
    if (e == null || e.isEmpty) return false;
    try {
      final owner = (await _read(ownerKey).timeout(const Duration(seconds: 3)))
          ?.trim()
          .toLowerCase();
      if (owner == e) return false;
      final had = (owner != null && owner.isNotEmpty) ||
          (await _read(topicsKey).timeout(const Duration(seconds: 3))) !=
              null ||
          (await _read(answersKey).timeout(const Duration(seconds: 3))) !=
              null;
      if (had) {
        await _delete(topicsKey).timeout(const Duration(seconds: 3));
        await _delete(answersKey).timeout(const Duration(seconds: 3));
      }
      await _write(ownerKey, e).timeout(const Duration(seconds: 3));
      return had;
    } catch (_) {
      return false;
    }
  }
}

/// Decodes a cached topics JSON array string (native's stored
/// format). Tolerant: malformed → empty. Never throws.
List<String> decodeCachedTopics(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return [
        for (final item in decoded)
          if ('$item'.trim().isNotEmpty) '$item'.trim(),
      ];
    }
  } catch (_) {}
  return const [];
}

/// Decodes a cached answers JSON object string (topic → tips).
/// Tolerant: malformed entries are skipped. Never throws.
Map<String, List<String>> decodeCachedAnswers(String raw) {
  final out = <String, List<String>>{};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      decoded.forEach((key, value) {
        if (value is List) {
          out['$key'] = [
            for (final item in value)
              if ('$item'.trim().isNotEmpty) '$item'.trim(),
          ];
        }
      });
    }
  } catch (_) {}
  return out;
}

class _TipsTricksScreenState extends State<TipsTricksScreen> {
  TabsBackend get _backend => widget.backend ?? TabsBackend();
  late final TipsCacheStore _cacheStore =
      widget.cacheStore ?? TipsCacheStore();

  /// null = gate check still running; true = unlocked; false = locked.
  bool? _unlocked;
  String? _gateError;

  List<String> _topics = const [];
  final Map<String, List<String>> _tips = {};
  bool _loadingTopics = false;
  String? _loadingTipsTopic;
  String? _error;

  @override
  void initState() {
    super.initState();
    _checkGate();
  }

  Future<void> _checkGate() async {
    try {
      final unlimited = await _backend.fetchIsUnlimited();
      if (!mounted) return;
      setState(() {
        _unlocked = unlimited;
        if (!unlimited) {
          _gateError = null;
        }
      });
      if (unlimited) await _loadCache();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _unlocked = false;
        _gateError = 'Could not verify membership. Check your connection and try again.';
      });
    }
  }

  /// Loads the persisted topics/answers (native shows cached topics
  /// on open; the onboarding prompt appears only when none exist).
  /// Founder seed findings (Oct 28, 2026): ownership is enforced
  /// against the stored session first, so a previous account's
  /// cached topics/answers can never render for this account.
  Future<void> _loadCache() async {
    try {
      final email = await SessionStore().readEmail();
      await _cacheStore.clearIfOwnerMismatch(email);
    } catch (_) {}
    final topics = await _cacheStore.loadTopics();
    final answers = await _cacheStore.loadAnswers();
    if (!mounted) return;
    setState(() {
      if (topics.isNotEmpty && _topics.isEmpty) _topics = topics;
      _tips.addAll(answers);
    });
  }

  Future<void> _generateTopics() async {
    setState(() {
      _loadingTopics = true;
      _error = null;
    });
    try {
      final pull = await _backend.fetchSyncPull();
      if (pull == null) {
        _fail('Could not load your data. Check your connection and try again.');
        return;
      }
      final prompt = _topicsPrompt(pull);
      final body = _adviceBody(pull, prompt);
      final res = await _backend.postAi('/api/ai/advice', body);
      final raw = res?['result'];
      final topics = raw is String ? parseTopics(raw) : const <String>[];
      if (topics.isEmpty) {
        _fail('The AI did not return any topics. Try again.');
        return;
      }
      if (!mounted) return;
      setState(() {
        _topics = topics;
        _tips.clear();
      });
      // Native persists the new topics and clears the old cached
      // answers when topics regenerate.
      await _cacheStore.saveTopics(topics);
      await _cacheStore.clearAnswers();
    } catch (_) {
      _fail('Could not generate topics. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _loadingTopics = false);
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() => _error = message);
  }

  Future<void> _openTopic(String topic) async {
    // Kick off the fetch (skipped when already cached), then show the sheet.
    final future = _fetchTipsForTopic(topic);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: NotelColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => _TipsSheet(
        topic: topic,
        future: future,
        onRefresh: () => _fetchTipsForTopic(topic, force: true),
      ),
    );
  }

  /// Fetches tips for [topic] unless already cached. Returns the cached
  /// or freshly fetched list (empty on failure — the sheet shows the
  /// error state; nothing is invented).
  Future<List<String>> _fetchTipsForTopic(String topic, {bool force = false}) async {
    if (!force && _tips.containsKey(topic)) return _tips[topic]!;
    if (!mounted) return const [];
    setState(() {
      _loadingTipsTopic = topic;
      _error = null;
    });
    try {
      final pull = await _backend.fetchSyncPull();
      if (pull == null) {
        _fail('Could not load your data. Check your connection and try again.');
        return const [];
      }
      final prompt = _tipsPrompt(pull, topic);
      final body = _adviceBody(pull, prompt);
      final res = await _backend.postAi('/api/ai/advice', body);
      final raw = res?['result'];
      final tips = raw is String ? parseTips(raw) : const <String>[];
      if (tips.isEmpty) {
        _fail('Could not load tips for this topic. Check your connection and try again.');
        return const [];
      }
      _tips[topic] = tips;
      // Native persists each fetched answer into the cached map.
      await _cacheStore.saveAnswers(_tips);
      return tips;
    } catch (_) {
      _fail('Could not load tips for this topic. Check your connection and try again.');
      return const [];
    } finally {
      if (mounted) setState(() => _loadingTipsTopic = null);
    }
  }

  /// Mirrors the native VM: last 20 entries, list names, document names,
  /// category map → the topics prompt.
  String _topicsPrompt(Map<String, dynamic> pull) {
    final entries = _recentEntries(pull, 20);
    final jotsContext = entries.isEmpty
        ? '- Welcome to Tabs! Try journaling about your symptoms, habits, or day to get custom tips.'
        : entries
            .map((e) => '- [${e['timestamp']}]: ${e['body'] ?? ''}')
            .join('\n');
    final listsContext = _listNames(pull).join(', ');
    final docsContext = _documentNames(pull).join(', ');
    return '''
You are a personalized assistant helping a user discover insights about their life, habits, health, and data.
Read this compact summary of their records:

JOTS:
$jotsContext

LISTS:
$listsContext

DOCUMENTS UPLOADED:
$docsContext

Based ONLY on their records, propose exactly 4 to 6 specific, open-ended questions they might want to ask to get tips, tricks, and insights (e.g., "How can I improve my sleep pattern based on my sleep logs?", "What tips can help me manage my medication list?", "How should I structure my symptom tracking?"). Make them very personal and tailored to the actual contents of their Tabs, lists, and docs.

You MUST return a JSON array of strings ONLY. No markdown, no wrapping code blocks, no explanation, just raw JSON.
Example format:
["Question 1?", "Question 2?", "Question 3?", "Question 4?"]
''';
  }

  String _tipsPrompt(Map<String, dynamic> pull, String topic) {
    final entries = _recentEntries(pull, 20);
    final jotsContext = entries.isEmpty
        ? '- Welcome to Tabs!'
        : entries.map((e) => '- ${e['body'] ?? ''}').join('\n');
    return '''
The user has chosen to learn more about the following topic based on their personal records:
"$topic"

Here are their recent journal records for reference:
$jotsContext

Provide 3 to 5 highly concise, actionable, and personalized tips or tricks.
- Keep it short, high-density, and structured.
- Return ONLY a JSON array of strings, where each string represents a single tip.
- Do NOT use markdown code blocks, do NOT explain. Just return a raw JSON array.

Example format:
["Tip 1 details...", "Tip 2 details...", "Tip 3 details..."]
''';
  }

  /// The `AiRequest`-shaped body the native `GeminiService.getAdvice`
  /// sends to `POST api/ai/advice`: entries DTOs, category id→name map,
  /// and the prompt as `userContext`.
  Map<String, dynamic> _adviceBody(Map<String, dynamic> pull, String prompt) {
    return {
      'entries': _entryDtos(_recentEntries(pull, 20)),
      'categories': _categoryMap(pull),
      'userContext': prompt,
    };
  }

  List<Map<String, dynamic>> _recentEntries(Map<String, dynamic> pull, int count) {
    final raw = pull['entries'];
    if (raw is! List) return const [];
    final out = <Map<String, dynamic>>[];
    for (final e in raw) {
      if (e is Map<String, dynamic>) out.add(e);
      if (out.length >= count) break;
    }
    return out;
  }

  List<Map<String, dynamic>> _entryDtos(List<Map<String, dynamic>> entries) {
    return [
      for (final e in entries)
        {
          'id': e['id'] ?? 0,
          'categoryId': e['categoryId'] ?? 0,
          'body': '${e['body'] ?? ''}',
          'chips': '${e['chips'] ?? ''}',
          'manualText': '${e['manualText'] ?? ''}',
          'timestamp': e['timestamp'] ?? 0,
        },
    ];
  }

  Map<String, String> _categoryMap(Map<String, dynamic> pull) {
    final out = <String, String>{};
    final raw = pull['categories'];
    if (raw is List) {
      for (final c in raw) {
        if (c is Map<String, dynamic>) {
          out['${c['id'] ?? ''}'] = '${c['name'] ?? ''}';
        }
      }
    }
    return out;
  }

  List<String> _listNames(Map<String, dynamic> pull) {
    final profile = pull['profile'];
    if (profile is! Map<String, dynamic>) return const [];
    final lists = TabsBackend.decodeProfileList(profile['userLists']);
    return [
      for (final l in lists)
        if ('${l['name'] ?? ''}' != '__user_notes__') '${l['name'] ?? ''}',
    ];
  }

  List<String> _documentNames(Map<String, dynamic> pull) {
    final raw = pull['documents'];
    if (raw is! List) return const [];
    return [
      for (final d in raw)
        if (d is Map<String, dynamic> && '${d['name'] ?? ''}'.isNotEmpty)
          '${d['name']}',
    ];
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
          'Tips & Insights',
          style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary),
        ),
        actions: [
          if (_unlocked == true && _topics.isNotEmpty && !_loadingTopics)
            IconButton(
              icon: const Icon(Icons.refresh,
                  color: NotelColors.primary, semanticLabel: 'Refresh'),
              onPressed: _generateTopics,
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_unlocked == null) {
      return const SkeletonGroup(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 110),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonBox(height: 96, radius: 16),
              SizedBox(height: 16),
              SkeletonBox(height: 96, radius: 16),
              SizedBox(height: 16),
              SkeletonBox(height: 96, radius: 16),
            ],
          ),
        ),
      );
    }
    if (_unlocked == false) {
      return _LockedView(
        title: 'Tips & Insights',
        message: _gateError ??
            'Tips & Insights requires a Tabs membership. '
                'Upgrade in the native app to unlock personalized AI tips.',
      );
    }
    if (_error != null && _topics.isEmpty && !_loadingTopics) {
      return _ErrorView(message: _error!, onRetry: _generateTopics);
    }
    if (_loadingTopics) {
      return const _LoadingView();
    }
    if (_topics.isEmpty) {
      return _OnboardingView(onGenerate: _generateTopics);
    }
    return Column(
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _InlineError(message: _error!, onDismiss: () => setState(() => _error = null)),
          ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
            itemCount: _topics.length,
            separatorBuilder: (context, _) => const SizedBox(height: 12),
            itemBuilder: (context, i) {
              final topic = _topics[i];
              final loading = _loadingTipsTopic == topic;
              return _TopicCard(
                topic: topic,
                loading: loading,
                onTap: () => _openTopic(topic),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Honest locked state for membership-gated tools. No paywall is built —
/// just the lock, matching the task's instruction.
class _LockedView extends StatelessWidget {
  final String title;
  final String message;

  const _LockedView({required this.title, required this.message});

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
            Text(
              '$title is locked',
              style: const TextStyle(
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

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off_outlined,
                size: 56, color: NotelColors.textSecondary),
            const SizedBox(height: 16),
            const Text(
              'Could not load your data',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: NotelColors.textPrimary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: const TextStyle(
                  fontSize: 14, height: 1.5, color: NotelColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: onRetry,
              style: ElevatedButton.styleFrom(
                backgroundColor: NotelColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  final String message;
  final VoidCallback onDismiss;

  const _InlineError({required this.message, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: NotelColors.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NotelColors.error.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(message,
                style:
                    const TextStyle(fontSize: 13, color: NotelColors.textPrimary)),
          ),
          IconButton(
            icon: const Icon(Icons.close,
                size: 18, color: NotelColors.textSecondary),
            onPressed: onDismiss,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: NotelColors.primary),
          SizedBox(height: 24),
          Text('Analyzing your habits & records...',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: NotelColors.textPrimary)),
          SizedBox(height: 8),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 48),
            child: Text(
              'This compiles summaries of notes, lists, and documents.',
              style:
                  TextStyle(fontSize: 12, color: NotelColors.textSecondary),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

class _OnboardingView extends StatelessWidget {
  final VoidCallback onGenerate;

  const _OnboardingView({required this.onGenerate});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: NotelColors.surface,
                borderRadius: BorderRadius.circular(32),
                border: Border.all(color: NotelColors.cardBorder),
              ),
              alignment: Alignment.center,
              child: const Text('💡', style: TextStyle(fontSize: 42)),
            ),
            const SizedBox(height: 32),
            const Text(
              'Personalized Insights',
              style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: NotelColors.textPrimary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              'Let AI safely scan your local logs, lists, and document summaries to generate tailored topics and tips for your specific routine.',
              style: TextStyle(
                  fontSize: 14, height: 1.6, color: NotelColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 40),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton.icon(
                onPressed: onGenerate,
                icon: const Icon(Icons.auto_awesome,
                    color: Colors.white, size: 20),
                label: const Text('Generate Custom Tips',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: NotelColors.primary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopicCard extends StatelessWidget {
  final String topic;
  final bool loading;
  final VoidCallback onTap;

  const _TopicCard(
      {required this.topic, required this.loading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: NotelColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: NotelColors.cardBorder),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: NotelColors.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: loading
                  ? const Padding(
                      padding: EdgeInsets.all(8),
                      child: CircularProgressIndicator(
                          color: NotelColors.primary, strokeWidth: 2),
                    )
                  : const Icon(Icons.lightbulb_outline,
                      color: NotelColors.primary, size: 18),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(topic,
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                      color: NotelColors.textPrimary)),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right,
                color: NotelColors.textSecondary, size: 20),
          ],
        ),
      ),
    );
  }
}

class _TipsSheet extends StatefulWidget {
  final String topic;
  final Future<List<String>> future;
  final Future<List<String>> Function() onRefresh;

  const _TipsSheet(
      {required this.topic, required this.future, required this.onRefresh});

  @override
  State<_TipsSheet> createState() => _TipsSheetState();
}

class _TipsSheetState extends State<_TipsSheet> {
  late Future<List<String>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.future;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 12,
          bottom: 24 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Tips & Advice',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: NotelColors.primary)),
                IconButton(
                  icon: const Icon(Icons.close,
                      color: NotelColors.textSecondary),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(widget.topic,
                style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    height: 1.35,
                    color: NotelColors.textPrimary)),
            const SizedBox(height: 20),
            Flexible(
              child: FutureBuilder<List<String>>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(
                            color: NotelColors.primary),
                        SizedBox(height: 16),
                        Text('Drafting targeted tips...',
                            style: TextStyle(
                                fontSize: 13,
                                color: NotelColors.textSecondary)),
                      ],
                    );
                  }
                  final tips = snapshot.data ?? const <String>[];
                  if (tips.isEmpty) {
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Could not load tips for this topic. Check your connection and try again.',
                          style: TextStyle(
                              fontSize: 14,
                              color: NotelColors.textSecondary),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        TextButton(
                          onPressed: () =>
                              setState(() => _future = widget.onRefresh()),
                          child: const Text('Try again',
                              style: TextStyle(
                                  color: NotelColors.primary,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ],
                    );
                  }
                  return ListView.separated(
                    shrinkWrap: true,
                    itemCount: tips.length,
                    separatorBuilder: (context, _) =>
                        const SizedBox(height: 16),
                    itemBuilder: (context, i) =>
                        _TipRow(index: i + 1, text: tips[i]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TipRow extends StatelessWidget {
  final int index;
  final String text;

  const _TipRow({required this.index, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NotelColors.surfaceHigh.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NotelColors.legacyDarkHairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: NotelColors.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: Text('$index',
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: NotelColors.primary)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    fontSize: 14,
                    height: 1.45,
                    color: NotelColors.textPrimary)),
          ),
        ],
      ),
    );
  }
}

// ── Pure parsing helpers (unit-tested) ─────────────────────────────────────

/// Mirrors the native VM's `cleanJsonResponse`: strips markdown fences.
String cleanTipsJson(String raw) {
  var clean = raw.trim();
  if (clean.startsWith('```json')) {
    clean = clean.substring('```json'.length);
  } else if (clean.startsWith('```')) {
    clean = clean.substring('```'.length);
  }
  if (clean.endsWith('```')) {
    clean = clean.substring(0, clean.length - '```'.length);
  }
  return clean.trim();
}

/// Parses a topics JSON array from the AI `result` string. Never throws —
/// malformed content yields an empty list (the UI shows an honest error).
List<String> parseTopics(String result) {
  try {
    final decoded = jsonDecode(cleanTipsJson(result));
    if (decoded is List) {
      return [
        for (final item in decoded)
          if ('$item'.trim().isNotEmpty) '$item'.trim(),
      ];
    }
  } catch (_) {}
  return const [];
}

/// Parses a tips JSON array from the AI `result` string. Never throws.
List<String> parseTips(String result) => parseTopics(result);
