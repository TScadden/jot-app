import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// One topic verdict inside a food check (verbatim port of native
/// `FoodTopicLevel`).
class FoodTopicLevel {
  final String topicName;
  final String level; // "High", "Medium", or "Low"
  final String reasoning;

  const FoodTopicLevel({
    required this.topicName,
    required this.level,
    required this.reasoning,
  });
}

/// One food's full verdict (verbatim port of native `FoodCheckResult`).
class FoodCheckResult {
  final String foodName;
  final List<FoodTopicLevel> levels;

  const FoodCheckResult({required this.foodName, required this.levels});
}

/// The five topics the AI must evaluate, verbatim from the native prompt.
const List<String> foodCoreTopics = [
  'Histamine',
  'Sugar',
  'FODMAP',
  'Inflammation',
  'Oxalate',
];

/// Split a raw search into distinct lowercase items on commas/newlines
/// (native Bug 4/3 fix).
List<String> splitFoodItems(String rawInput) {
  final seen = <String>{};
  final out = <String>[];
  for (final part in rawInput.split(RegExp(r'[,\n]'))) {
    final item = part.trim().toLowerCase();
    if (item.isNotEmpty && seen.add(item)) out.add(item);
  }
  return out;
}

/// The AI prompt the native `FoodViewModel.checkFoodLevels` builds —
/// five topics, strict JSON, no markdown. Kept byte-faithful to native.
String buildFoodPrompt(List<String> items) {
  final missingListContext = items.join(', ');
  return '''
Analyze the following list of food items and evaluate their levels/concentrations of key health sensitivity markers:
Foods to analyze: $missingListContext

Evaluate each food against these exactly five topics:
1. "Histamine" (Histamine content or histamine-releasing potential)
2. "Sugar" (Sugar content or high Glycemic index load)
3. "FODMAP" (High FODMAP content that triggers bloating or IBS)
4. "Inflammation" (General inflammatory potential or immune triggers)
5. "Oxalate" (Oxalate concentrations triggering kidney or pain symptoms)

For each food and each topic, you MUST provide:
- "level": MUST be exactly one of "High", "Medium", or "Low".
- "reasoning": A very concise, maximum 1-sentence description explaining WHY.

You MUST respond with a valid JSON object matching the format below. Do NOT wrap in markdown, do NOT include anything but the raw JSON object.

JSON Format Example:
{
  "spinach": {
    "Histamine": { "level": "High", "reasoning": "Spinach is naturally rich in histamine and can trigger mast cell reactions." },
    "Sugar": { "level": "Low", "reasoning": "Extremely low glycemic load with negligible sugar." },
    "FODMAP": { "level": "Low", "reasoning": "Monash rated as low FODMAP and safe for IBS in standard servings." },
    "Inflammation": { "level": "Low", "reasoning": "Packed with anti-inflammatory antioxidants and flavonoids." },
    "Oxalate": { "level": "High", "reasoning": "Contains exceptionally high oxalate levels, which can irritate kidneys or tissues." }
  }
}
'''.trim();
}

/// Strip markdown code fences (native `cleanJsonResponse`).
String cleanFoodJsonResponse(String raw) {
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

/// Cut to the outermost `{...}` block (native `extractJsonBlock`).
String extractFoodJsonBlock(String raw) {
  final trimmed = raw.trim();
  final start = trimmed.indexOf('{');
  final end = trimmed.lastIndexOf('}');
  if (start != -1 && end != -1 && end > start) {
    return trimmed.substring(start, end + 1);
  }
  return trimmed;
}

/// Parse the AI's raw text into [FoodCheckResult]s.
///
/// Defaults per native: a missing topic falls back to level "Low" and
/// reasoning "No details available.". Throws [FormatException] when the
/// text cannot be parsed at all — callers turn that into the visible AI
/// error, never into fake results.
List<FoodCheckResult> parseFoodAiResponse(String raw) {
  final block = extractFoodJsonBlock(cleanFoodJsonResponse(raw));
  final decoded = jsonDecode(block);
  if (decoded is! Map<String, dynamic> || decoded.isEmpty) {
    throw const FormatException('Empty food AI result');
  }
  final out = <FoodCheckResult>[];
  for (final entry in decoded.entries) {
    final foodKey = entry.key.toString().trim().toLowerCase();
    if (foodKey.isEmpty) continue;
    final foodObj =
        entry.value is Map<String, dynamic> ? entry.value as Map : null;
    final levels = <FoodTopicLevel>[];
    for (final topic in foodCoreTopics) {
      final topicValue = foodObj?[topic];
      final levelObj = topicValue is Map ? topicValue : null;
      levels.add(FoodTopicLevel(
        topicName: topic,
        level: levelObj?['level']?.toString() ?? 'Low',
        reasoning: levelObj?['reasoning']?.toString() ??
            'No details available.',
      ));
    }
    out.add(FoodCheckResult(foodName: foodKey, levels: levels));
  }
  if (out.isEmpty) throw const FormatException('Empty food AI result');
  return out;
}

/// The request body the native screen sends to `POST api/ai/advice`:
/// a dummy "Food Sensitivity Scan" log entry plus the prompt as userContext.
Map<String, dynamic> buildFoodAiRequestBody(List<String> items) {
  return {
    'entries': [
      {
        'id': 99999,
        'categoryId': 7,
        'body': 'Food Sensitivity Scan',
        'chips': '',
        'manualText': 'Food Sensitivity Scan',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'updatedAt': 0,
      },
    ],
    'categories': <String, dynamic>{},
    'userContext': buildFoodPrompt(items),
  };
}

/// Round 18, Team D — Food Sensitivity tool screen.
///
/// AI sensitivity checker ported from `FoodScreen.kt` + `FoodViewModel.kt`:
/// type food(s) → the VM's prompt is sent to `POST api/ai/advice` →
/// parsed results render as expandable cards. Results that were already
/// checked this session answer instantly from a memory-only cache (the
/// native screen persisted this in preferences; this round keeps it
/// session-memory per the round brief). AI failures surface as a visible
/// error banner — results are never invented.
class FoodToolScreen extends StatefulWidget {
  final VoidCallback? onBack;
  final TabsBackend? backend;

  const FoodToolScreen({super.key, this.onBack, this.backend});

  @override
  State<FoodToolScreen> createState() => _FoodToolScreenState();
}

class _FoodToolScreenState extends State<FoodToolScreen> {
  TabsBackend get _backend => widget.backend ?? TabsBackend();

  final TextEditingController _input = TextEditingController();

  bool _loading = false;
  String? _error;
  List<FoodCheckResult> _results = const [];
  final Map<String, FoodCheckResult> _encyclopedia = {};
  final List<String> _recentOrder = [];
  final Map<String, bool> _expanded = {};
  bool _checkInFlight = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  /// Verbatim-style calm copy from the native AI-failure banner
  /// (`FriendlyErrors` load template, dash-free by design).
  static const String aiErrorCopy =
      'Could not load your data. We could not pull your latest entries. '
      'Anything already saved is still here. Check your connection and try again.';

  Future<void> checkFoodLevels(String rawInput) async {
    if (_checkInFlight) return;
    final items = splitFoodItems(rawInput);
    if (items.isEmpty) return;
    setState(() {
      _checkInFlight = true;
      _loading = true;
      _error = null;
    });
    try {
      final foundInCache = <FoodCheckResult>[];
      final missing = <String>[];
      for (final item in items) {
        final cached = _encyclopedia[item];
        if (cached != null) {
          foundInCache.add(cached);
        } else {
          missing.add(item);
        }
      }
      if (missing.isNotEmpty) {
        const maxAttempts = 3;
        List<FoodCheckResult>? newResults;
        for (var attempt = 1; attempt <= maxAttempts; attempt++) {
          try {
            final response = await _backend.postAi(
                '/api/ai/advice', buildFoodAiRequestBody(missing));
            final resultText = response?['result']?.toString();
            if (resultText == null || resultText.trim().isEmpty) {
              throw const FormatException('Empty AI response');
            }
            newResults = parseFoodAiResponse(resultText);
            break;
          } catch (_) {
            if (attempt < maxAttempts) {
              await Future.delayed(Duration(milliseconds: 400 * attempt));
            }
          }
        }
        if (newResults == null) {
          // AI failed after retries: visible error, no fake results.
          if (!mounted) return;
          setState(() => _error = aiErrorCopy);
          return;
        }
        for (final r in newResults) {
          _encyclopedia[r.foodName] = r;
        }
      }
      // Assemble results in the user's query order.
      final finalResults = <FoodCheckResult>[];
      for (final item in items) {
        final r = _encyclopedia[item];
        if (r != null) finalResults.add(r);
      }
      if (!mounted) return;
      setState(() {
        _results = finalResults;
        for (final r in finalResults) {
          _expanded[r.foodName] = true;
        }
        for (final item in items) {
          _recentOrder.remove(item);
          _recentOrder.insert(0, item);
        }
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _checkInFlight = false;
        });
      }
    }
  }

  List<String> get _recentSearches => _recentOrder.take(20).toList();

  String _capitalize(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

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
          onPressed: widget.onBack ?? () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Food Sensitivity',
          style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 60),
        children: [
          const Text(
            'Check sensitivity triggers and nutritional levels.',
            style:
                TextStyle(fontSize: 13, color: NotelColors.textSecondary),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _input,
            maxLines: 4,
            style: const TextStyle(color: NotelColors.textPrimary),
            decoration: InputDecoration(
              hintText: 'e.g. spinach, coffee, avocado, aged cheese',
              hintStyle: TextStyle(
                  color: NotelColors.textSecondary.withValues(alpha: 0.6)),
              filled: true,
              fillColor: NotelColors.surfaceHigh.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(
                    color: NotelColors.surfaceHigh.withValues(alpha: 0.2)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(
                    color: NotelColors.surfaceHigh.withValues(alpha: 0.2)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(
                    color: NotelColors.primary.withValues(alpha: 0.5)),
              ),
              suffixIcon: _input.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close,
                          color: NotelColors.textSecondary),
                      onPressed: () => setState(_input.clear),
                    )
                  : null,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          Text(
            'To check multiple items, separate them with a comma (e.g. spinach, coffee) or type them on new lines.',
            style: TextStyle(
                fontSize: 11,
                height: 1.4,
                color: NotelColors.textSecondary.withValues(alpha: 0.7)),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton(
              onPressed: (_input.text.trim().isNotEmpty && !_loading)
                  ? () => checkFoodLevels(_input.text)
                  : null,
              style: FilledButton.styleFrom(
                backgroundColor: NotelColors.primary,
                disabledBackgroundColor:
                    NotelColors.surfaceHigh.withValues(alpha: 0.15),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
              child: _loading
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2),
                    )
                  : const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.search, color: Colors.white),
                        SizedBox(width: 8),
                        Text('Check Sensitivity',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold)),
                      ],
                    ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            _errorBanner(_error!),
          ],
          if (_results.isNotEmpty && !_loading) ...[
            const SizedBox(height: 16),
            const Text('Results',
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: NotelColors.textPrimary)),
            const SizedBox(height: 12),
            ..._results.map(_resultCard),
          ],
          if (_recentSearches.isNotEmpty) ...[
            const SizedBox(height: 26),
            const Text('Recently Checked',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: NotelColors.textPrimary)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _recentSearches
                  .map((name) => _recentChip(name))
                  .toList(),
            ),
          ],
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
        border: Border.all(color: NotelColors.error.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_off, color: NotelColors.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    fontSize: 13, color: NotelColors.textPrimary)),
          ),
          IconButton(
            icon: const Icon(Icons.close,
                size: 16, color: NotelColors.textSecondary),
            onPressed: () => setState(() => _error = null),
          ),
        ],
      ),
    );
  }

  Widget _resultCard(FoodCheckResult result) {
    final expanded = _expanded[result.foodName] ?? true;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: NotelColors.surface.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(20),
        border:
            Border.all(color: NotelColors.primary.withValues(alpha: 0.08)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => setState(
            () => _expanded[result.foodName] = !expanded),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: NotelColors.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.restaurant,
                            size: 16, color: NotelColors.primary),
                      ),
                      const SizedBox(width: 12),
                      Text(_capitalize(result.foodName),
                          style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                              color: NotelColors.textPrimary)),
                    ],
                  ),
                  Icon(
                      expanded
                          ? Icons.expand_less
                          : Icons.expand_more,
                      color: NotelColors.textSecondary),
                ],
              ),
              if (expanded) ...[
                const SizedBox(height: 18),
                ...result.levels.map(_topicRow),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _topicRow(FoodTopicLevel topic) {
    final badgeColor = switch (topic.level) {
      'High' => NotelColors.error,
      'Medium' => NotelColors.warning,
      _ => NotelColors.success,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(topic.topicName,
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: NotelColors.textPrimary)),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: badgeColor.withValues(alpha: 0.4)),
                ),
                child: Text(topic.level,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: badgeColor)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(topic.reasoning,
              style: const TextStyle(
                  fontSize: 13, height: 1.4, color: NotelColors.textSecondary)),
        ],
      ),
    );
  }

  Widget _recentChip(String name) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: _loading
          ? null
          : () {
              _input.text = name;
              checkFoodLevels(name);
            },
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: NotelColors.surfaceHigh.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
        ),
        child: Text(_capitalize(name),
            style: const TextStyle(
                fontSize: 12, color: NotelColors.textSecondary)),
      ),
    );
  }
}
