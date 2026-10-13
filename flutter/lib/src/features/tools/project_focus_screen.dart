import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:url_launcher/url_launcher.dart';

/// Round 48 (Team B) — Project Focus tool, FULL port of native
/// `ProjectFocusScreen.kt` + `ProjectFocusViewModel.kt`.
///
/// Data source: `decodeProfileList((await fetchProfile())['focusState'])`
/// — the server-synced `FocusStateDto` JSON blob. Every write mirrors
/// native `saveCurrentState`: the WHOLE state object is re-encoded
/// and pushed via `POST /api/sync/profile {focusState}`. Writes start
/// from the freshest decoded blob and preserve keys this screen does
/// not own, so no test or flow state is ever dropped (PR #28 lesson).
///
/// Round 18 shipped the details view read-only. Round 48 wires the
/// rest of native's surface:
/// - Creation flow: struggle input → `POST /api/ai/focus-suggestions`
///   → select a suggestion → target metric → duration (3–30 days) +
///   start today/tomorrow → "Lock it In" → splash → details.
/// - Daily check-in logging ("Yes, I did it" / "Not today") + Undo.
/// - Cancel Experiment (with native's confirm dialog).
/// - Selector chips persist the selection; "Create Project" in the
///   app bar; the help dialog; the completed-test results link and
///   the "Manage projects on jottracker.com" link.
/// Write failures are honest: the visible state only changes after
/// the server push succeeds, and a visible error is shown otherwise.

/// One read-only active test — mirrors native `ActiveProjectTest`.
class FocusTest {
  final String? id;
  final String title;
  final String? desc;
  final int durationDays;
  final int startTimestamp; // epoch ms
  final String? lockDayStr;
  final Map<String, bool> logs; // "YYYY-MM-DD" → did it
  final String? measureMetric;

  const FocusTest({
    this.id,
    required this.title,
    this.desc,
    required this.durationDays,
    required this.startTimestamp,
    this.lockDayStr,
    this.logs = const {},
    this.measureMetric,
  });

  /// Tolerant parse: null on a map that isn't test-shaped. Numbers
  /// may arrive as strings (server serialization) — both are
  /// accepted. Never throws.
  static FocusTest? fromJson(Map<String, dynamic> json) {    try {
      final title = json['title']?.toString().trim() ?? '';
      int? asInt(dynamic v) =>
          v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
      final durationRaw = asInt(json['durationDays']);
      final startRaw = asInt(json['startTimestamp']);
      if (title.isEmpty ||
          durationRaw == null ||
          startRaw == null ||
          durationRaw <= 0) {
        return null;
      }
      final logs = <String, bool>{};
      final logsRaw = json['logs'];
      if (logsRaw is Map) {
        logsRaw.forEach((k, v) {
          if (v is bool) logs[k.toString()] = v;
        });
      } else if (logsRaw is String && logsRaw.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(logsRaw);
          if (decoded is Map) {
            decoded.forEach((k, v) {
              if (v is bool) logs[k.toString()] = v;
            });
          }
        } catch (_) {}
      }
      return FocusTest(
        id: json['id']?.toString(),
        title: title,
        desc: json['desc']?.toString(),
        durationDays: durationRaw,
        startTimestamp: startRaw,
        lockDayStr: json['lockDayStr']?.toString(),
        logs: logs,
        measureMetric: json['measureMetric']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }

  FocusTest copyWith({Map<String, bool>? logs}) {
    return FocusTest(
      id: id,
      title: title,
      desc: desc,
      durationDays: durationDays,
      startTimestamp: startTimestamp,
      lockDayStr: lockDayStr,
      logs: logs ?? this.logs,
      measureMetric: measureMetric,
    );
  }

  /// Serializes back to the native `ActiveProjectTest` blob shape.
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'desc': desc,
        'durationDays': durationDays,
        'startTimestamp': startTimestamp,
        'lockDayStr': lockDayStr,
        'logs': logs,
        'measureMetric': measureMetric,
      };

  /// Mirrors native `ProjectFocusScreen.kt` (`leftMs <= 0` where
  /// `leftMs = max(durationMs - elapsedMs, 0)`).
  /// Pure and unit-testable via [nowMs].
  bool isCompletedAt(int nowMs) {
    const msPerDay = 24 * 60 * 60 * 1000;
    final durationMs = durationDays * msPerDay;
    final elapsedMs = nowMs - startTimestamp;
    final leftMs =
        elapsedMs < 0 ? durationMs : (durationMs - elapsedMs).clamp(0, durationMs);
    return leftMs <= 0;
  }

  /// True when the test's window has fully elapsed, device-local now.
  bool get isCompleted =>
      isCompletedAt(DateTime.now().millisecondsSinceEpoch);
}

/// Collects every active test from the decoded focusState maps.
/// Accepts the native `FocusStateDto` shape (`activeTests` / `activeTest`
/// arrays) and, tolerantly, a lone test-shaped map.
List<FocusTest> collectFocusTests(List<Map<String, dynamic>> decoded) {
  final out = <FocusTest>[];
  final seen = <String>{};
  void add(FocusTest t) {
    final key = t.id ?? '${t.title}|${t.startTimestamp}';
    if (seen.add(key)) out.add(t);
  }

  for (final map in decoded) {
    for (final key in const ['activeTests', 'tests']) {
      final raw = map[key];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map<String, dynamic>) {
            final t = FocusTest.fromJson(item);
            if (t != null) add(t);
          }
        }
      }
    }
    final active = map['activeTest'];
    if (active is Map<String, dynamic>) {
      final t = FocusTest.fromJson(active);
      if (t != null) add(t);
    }
    // Tolerate a blob that IS a single test.
    if (!map.containsKey('activeTests') && !map.containsKey('activeTest')) {
      final t = FocusTest.fromJson(map);
      if (t != null) add(t);
    }
  }
  return out;
}

/// Default test selection on open.
///
/// Founder-directed behavior (deliberate divergence from native, which
/// falls back to `tests.firstOrNull()` even when that test completed):
/// - If an in-progress test exists, select it — preferring the blob's
///   persisted `selectedTestId`, then the blob's `activeTest`, then the
///   first in-progress test.
/// - If NO in-progress test exists, return null so the screen opens in
///   the new-project/empty flow ("What are you trying to work towards?").
///   Completed tests stay reachable via the selector chips (manual tap).
/// A `selectedTestId`/`activeTest` naming a completed test is never
/// auto-selected. Pure and unit-tested.
String? defaultSelectedTestId(
    List<Map<String, dynamic>> decoded, List<FocusTest> tests) {
  String keyOf(FocusTest t) => t.id ?? t.title;
  final inProgress = tests.where((t) => !t.isCompleted).toList();
  if (inProgress.isEmpty) return null;
  final inProgressKeys = {for (final t in inProgress) keyOf(t)};
  for (final map in decoded) {
    final sid = map['selectedTestId']?.toString().trim();
    if (sid != null && sid.isNotEmpty && inProgressKeys.contains(sid)) {
      return sid;
    }
  }
  for (final map in decoded) {
    final active = map['activeTest'];
    if (active is Map<String, dynamic>) {
      final t = FocusTest.fromJson(active);
      final key = t == null ? null : keyOf(t);
      // inProgressKeys membership already guarantees not-completed.
      if (key != null && key.isNotEmpty && inProgressKeys.contains(key)) {
        return key;
      }
    }
  }
  final first = inProgress.first;
  return first.id ?? first.title;
}

/// One AI focus suggestion — mirrors native `FocusSuggestion`
/// (`{title, desc}` from `POST /api/ai/focus-suggestions`).
class FocusSuggestion {
  final String title;
  final String desc;

  const FocusSuggestion({required this.title, required this.desc});

  Map<String, dynamic> toJson() => {'title': title, 'desc': desc};

  static FocusSuggestion? fromJson(dynamic raw) {
    if (raw is! Map<String, dynamic>) return null;
    final title = '${raw['title'] ?? ''}'.trim();
    if (title.isEmpty) return null;
    return FocusSuggestion(title: title, desc: '${raw['desc'] ?? ''}'.trim());
  }
}

/// Parses the `result` list of a focus-suggestions response.
/// Skips malformed rows; never throws.
List<FocusSuggestion> parseFocusSuggestions(dynamic raw) {
  if (raw is! List) return const [];
  return [
    for (final item in raw)
      if (FocusSuggestion.fromJson(item) != null)
        FocusSuggestion.fromJson(item)!,
  ];
}

/// Native's target-metric options (ProjectFocusScreen.kt "measure"
/// step), in native's order: (key, label). The empty key is
/// "None / Subjective".
const List<(String, String)> focusMeasureMetrics = [
  ('sleepMins', 'Sleep Duration 🛌'),
  ('deepSleepMins', 'Deep Sleep 🌌'),
  ('avgHr', 'Heart Rate ❤️'),
  ('hrv', 'HRV ⚡'),
  ('calories', 'Calories 🍏'),
  ('spikes', 'HR Spikes 📈'),
  ('jots', 'Number of Tabs 📝'),
  ('', 'None / Subjective 🧠'),
];

String _dateStr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _lockDayStr(DateTime d) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  return '${days[d.weekday - 1]} ${months[d.month - 1]} '
      '${d.day.toString().padLeft(2, '0')} ${d.year}';
}

class ProjectFocusScreen extends StatefulWidget {
  /// Injectable for tests.
  final TabsBackend? backend;

  const ProjectFocusScreen({super.key, this.backend});

  @override
  State<ProjectFocusScreen> createState() => _ProjectFocusScreenState();
}

class _ProjectFocusScreenState extends State<ProjectFocusScreen> {
  late final TabsBackend _backend;
  bool _loading = true;
  List<FocusTest> _tests = const [];
  String? _selectedId;

  /// The freshest decoded focusState blob, retained verbatim so a
  /// push can splice this screen's changes over it without dropping
  /// keys it does not own (native `FocusStateDto` round-trip).
  Map<String, dynamic> _rawBlob = const {};

  /// Native sub-view: input | suggestions | measure | setup |
  /// splash | details.
  String _subView = 'input';
  List<FocusSuggestion> _suggestions = const [];
  FocusSuggestion? _selectedSuggestion;
  String _measureMetric = '';
  int _setupDuration = 7;
  bool _startTomorrow = false;
  bool _suggestionsLoading = false;
  bool _saving = false;
  String? _flowError;
  String? _writeError;
  final TextEditingController _struggleController =
      TextEditingController();

  @override
  void initState() {
    super.initState();
    _backend = widget.backend ?? TabsBackend();
    _load();
  }

  @override
  void dispose() {
    _struggleController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final profile = await _backend.fetchProfile();
      final decoded = TabsBackend.decodeProfileList(profile?['focusState']);
      final tests = collectFocusTests(decoded);
      if (!mounted) return;
      setState(() {
        _rawBlob = decoded.isNotEmpty ? decoded.first : const {};
        _tests = tests;
        // Founder-directed: an in-progress test is selected; with none,
        // the screen opens in the new-project/empty flow (completed tests
        // stay reachable via the selector chips).
        _selectedId = defaultSelectedTestId(decoded, tests);
        // Restore the persisted creation-flow state like native.
        _suggestions = parseFocusSuggestions(_rawBlob['suggestions']);
        _selectedSuggestion =
            FocusSuggestion.fromJson(_rawBlob['selectedSuggestion']);
        final duration = _rawBlob['setupDuration'];
        _setupDuration = duration is num
            ? duration.toInt()
            : int.tryParse('$duration') ?? 7;
        _measureMetric =
            _rawBlob['selectedMeasureMetric']?.toString() ?? '';
        // Native opens on details when a test is selected, else the
        // creation flow's input step.
        _subView = _selectedId != null ? 'details' : 'input';
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      // Honest empty on any failure — nothing is invented.
      setState(() {
        _tests = const [];
        _subView = 'input';
        _loading = false;
      });
    }
  }

  FocusTest? get _selected {
    final id = _selectedId;
    if (id == null) return null; // new-project/empty flow
    for (final t in _tests) {
      if ((t.id ?? t.title) == id) return t;
    }
    return null;
  }

  bool get _inCreationFlow =>
      const ['input', 'suggestions', 'measure', 'setup']
          .contains(_subView);

  /// Pushes the whole focus state, mirroring native
  /// `saveCurrentState` → `POST /api/sync/profile {focusState}`.
  /// Starts from the freshest retained blob and overwrites only the
  /// `FocusStateDto` keys, so unknown keys survive.
  Future<bool> _pushState({
    required List<FocusTest> tests,
    required String? selectedId,
    required String subView,
  }) async {
    final blob = Map<String, dynamic>.of(_rawBlob);
    blob['activeTests'] = [for (final t in tests) t.toJson()];
    FocusTest? active;
    for (final t in tests) {
      if ((t.id ?? t.title) == selectedId) active = t;
    }
    blob['activeTest'] = active?.toJson();
    blob['selectedTestId'] = selectedId;
    blob['currentSubView'] = subView;
    blob['suggestions'] = [for (final s in _suggestions) s.toJson()];
    blob['selectedSuggestion'] = _selectedSuggestion?.toJson();
    blob['setupDuration'] = _setupDuration;
    blob['selectedMeasureMetric'] = _measureMetric;
    blob['lastUpdated'] = DateTime.now().millisecondsSinceEpoch;
    final ok =
        await _backend.postSyncProfile({'focusState': jsonEncode(blob)});
    if (ok) _rawBlob = blob;
    return ok;
  }

  /// Best-effort push for intermediate flow steps (native saves
  /// them fire-and-forget; a failure never traps the user mid-flow).
  void _pushFlowStep() {
    _pushState(tests: _tests, selectedId: _selectedId, subView: _subView);
  }

  void _setSubView(String subView) {
    setState(() => _subView = subView);
    _pushFlowStep();
  }

  // ── Creation flow actions (native ProjectFocusViewModel) ────────────────

  Future<void> _submitStruggle() async {
    final struggle = _struggleController.text.trim();
    if (struggle.isEmpty || _suggestionsLoading) return;
    setState(() {
      _suggestionsLoading = true;
      _flowError = null;
    });
    try {
      final res = await _backend
          .postAi('/api/ai/focus-suggestions', {'struggle': struggle});
      final parsed = parseFocusSuggestions(res?['result']);
      if (!mounted) return;
      if (parsed.isEmpty) {
        setState(() {
          _suggestionsLoading = false;
          _flowError =
              'Could not load suggestions. Check your connection and try again.';
        });
        return;
      }
      setState(() {
        _suggestions = parsed;
        _suggestionsLoading = false;
        _subView = 'suggestions';
      });
      _pushFlowStep();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _suggestionsLoading = false;
        _flowError =
            'Could not load suggestions. Check your connection and try again.';
      });
    }
  }

  void _selectSuggestion(FocusSuggestion suggestion) {
    setState(() {
      _selectedSuggestion = suggestion;
      _measureMetric = '';
      _startTomorrow = false;
      _subView = 'measure';
    });
    _pushFlowStep();
  }

  void _selectMeasureMetric(String metric) {
    setState(() {
      _measureMetric = metric;
      _subView = 'setup';
    });
    _pushFlowStep();
  }

  void _changeDuration(bool increment) {
    setState(() {
      _setupDuration = increment
          ? (_setupDuration + 1).clamp(3, 30)
          : (_setupDuration - 1).clamp(3, 30);
    });
    _pushFlowStep();
  }

  Future<void> _lockInProject() async {
    final suggestion = _selectedSuggestion;
    if (suggestion == null || _saving) return;
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    final startMs =
        _startTomorrow ? nowMs + 24 * 60 * 60 * 1000 : nowMs;
    final test = FocusTest(
      id: 'test_${nowMs}_${Random().nextInt(10000)}',
      title: suggestion.title,
      desc: suggestion.desc.isEmpty ? null : suggestion.desc,
      durationDays: _setupDuration,
      startTimestamp: startMs,
      lockDayStr: _lockDayStr(now),
      logs: const {},
      measureMetric: _measureMetric.isEmpty ? null : _measureMetric,
    );
    final newTests = [..._tests, test];
    setState(() => _saving = true);
    final ok = await _pushState(
        tests: newTests, selectedId: test.id, subView: 'splash');
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok) {
      setState(() {
        _flowError =
            'Could not save your project. Check your connection and try again.';
      });
      return;
    }
    setState(() {
      _tests = newTests;
      _selectedId = test.id;
      _subView = 'splash';
      _flowError = null;
    });
    // Native shows the splash for 2 seconds, then opens details.
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && _subView == 'splash') {
        setState(() => _subView = 'details');
        _pushState(
            tests: _tests, selectedId: _selectedId, subView: 'details');
      }
    });
  }

  // ── Details actions ─────────────────────────────────────────────────────

  Future<void> _selectTest(String key) async {
    setState(() {
      _selectedId = key;
      _subView = 'details';
    });
    await _pushState(tests: _tests, selectedId: key, subView: 'details');
  }

  Future<void> _applyLogs(FocusTest test, Map<String, bool> logs) async {
    if (_saving) return;
    final updated = test.copyWith(logs: logs);
    final newTests = [
      for (final t in _tests)
        if ((t.id ?? t.title) == (test.id ?? test.title)) updated else t,
    ];
    setState(() => _saving = true);
    final ok = await _pushState(
        tests: newTests, selectedId: _selectedId, subView: 'details');
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) {
        _tests = newTests;
        _writeError = null;
      } else {
        _writeError =
            'Could not save your check-in. Check your connection and try again.';
      }
    });
  }

  Future<void> _checkIn(bool didIt) async {
    final test = _selected;
    if (test == null) return;
    final todayStr = _dateStr(DateTime.now());
    await _applyLogs(test, {...test.logs, todayStr: didIt});
  }

  Future<void> _undoCheckIn() async {
    final test = _selected;
    if (test == null) return;
    final todayStr = _dateStr(DateTime.now());
    await _applyLogs(test, {...test.logs}..remove(todayStr));
  }

  Future<void> _cancelTest() async {
    final test = _selected;
    if (test == null || _saving) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: NotelColors.surface,
        title: const Text('Cancel Experiment',
            style: TextStyle(color: NotelColors.textPrimary)),
        content: const Text(
          'Are you sure you want to cancel this experiment? This will delete all logged progress for it.',
          style: TextStyle(color: NotelColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('No',
                style: TextStyle(color: NotelColors.textPrimary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Yes',
                style: TextStyle(
                    color: NotelColors.error,
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final newTests = [
      for (final t in _tests)
        if ((t.id ?? t.title) != (test.id ?? test.title)) t,
    ];
    final fallback = newTests.isNotEmpty ? newTests.first : null;
    final fallbackId =
        fallback == null ? null : (fallback.id ?? fallback.title);
    setState(() => _saving = true);
    final ok = await _pushState(
      tests: newTests,
      selectedId: fallbackId,
      subView: fallback != null ? 'details' : 'input',
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) {
        _tests = newTests;
        _selectedId = fallbackId;
        _subView = fallback != null ? 'details' : 'input';
        _suggestions = const [];
        _selectedSuggestion = null;
        _writeError = null;
      } else {
        _writeError =
            'Could not cancel this experiment. Check your connection and try again.';
      }
    });
  }

  void _showHelp() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: NotelColors.surface,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('About Project Focus',
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: NotelColors.textPrimary)),
        content: const Text(
          'Project Focus helps you run self-experiments to tackle personal struggles (like improving sleep, managing stress, or optimizing productivity) by generating custom AI suggestions and tracking your progress over time.\n\nOur core goal is to use data to generate outcomes.',
          style: TextStyle(
              fontSize: 14, height: 1.45, color: NotelColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Got it',
                style: TextStyle(
                    color: NotelColors.primary,
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _openJotTracker() async {
    final uri = Uri.parse('https://jottracker.com/login');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Link is informational; a failed launch is silent like the
      // research screen's source links.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back,
            color: NotelColors.textPrimary,
            semanticLabel: 'Back',
          ),
          onPressed: () {
            // Native: back from a creation step returns to details
            // when tests exist; otherwise it leaves the screen.
            if (_tests.isNotEmpty && _inCreationFlow) {
              _setSubView('details');
            } else {
              Navigator.of(context).pop();
            }
          },
        ),
        title: const Text(
          'Project Focus',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
        actions: [
          if (!_loading && _subView == 'details' && _selected != null)
            TextButton(
              onPressed: () => _setSubView('input'),
              child: const Text('Create Project',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: NotelColors.primary)),
            ),
          if (!_loading && _subView == 'input')
            IconButton(
              icon: const Icon(Icons.help_outline,
                  color: NotelColors.textPrimary, semanticLabel: 'Help'),
              onPressed: _showHelp,
            ),
        ],
      ),
      body: _loading
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: NotelColors.primary),
                  SizedBox(height: 16),
                  Text(
                    'Syncing your projects…',
                    style: TextStyle(
                      fontSize: 14,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                ],
              ),
            )
          : _subView == 'details' && _selected != null
              ? _detailsView(_selected!)
              : _creationFlow(),
    );
  }

  /// The creation flow (native's centered glass card): input →
  /// suggestions → measure → setup → splash. Completed tests stay
  /// reachable via the selector chips above the card (founder
  /// direction).
  Widget _creationFlow() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_tests.isNotEmpty) ...[
            _testSelector(),
            const SizedBox(height: 16),
          ],
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0x590A0A0E),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.08),
              ),
            ),
            child: switch (_subView) {
              'suggestions' => _suggestionsView(),
              'measure' => _measureView(),
              'setup' => _setupView(),
              'splash' => _splashView(),
              _ => _inputView(),
            },
          ),
        ],
      ),
    );
  }

  Widget _inputView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Project Focus',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w900,
            color: NotelColors.textPrimary,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        const Text(
          'What are you trying to work towards?',
          style: TextStyle(
            fontSize: 14,
            color: NotelColors.textSecondary,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.08),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _struggleController,
                  minLines: 2,
                  maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  style: const TextStyle(
                      fontSize: 15, color: NotelColors.textPrimary),
                  decoration: const InputDecoration(
                    hintText:
                        'Type something you are struggling with (e.g., sleep, stress)...',
                    hintStyle: TextStyle(
                        fontSize: 14, color: NotelColors.textSecondary),
                    border: InputBorder.none,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: ElevatedButton(
                    onPressed: _struggleController.text.trim().isEmpty ||
                            _suggestionsLoading
                        ? null
                        : _submitStruggle,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: NotelColors.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      padding: EdgeInsets.zero,
                      disabledBackgroundColor: NotelColors.surfaceHigh,
                    ),
                    child: _suggestionsLoading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2),
                          )
                        : const Icon(Icons.send, size: 16),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_flowError != null) ...[
          const SizedBox(height: 12),
          Text(_flowError!,
              style: const TextStyle(
                  fontSize: 12, color: NotelColors.error),
              textAlign: TextAlign.center),
        ],
        if (_tests.isNotEmpty) ...[
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => _setSubView('details'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white.withValues(alpha: 0.08),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
              child: const Text('Cancel'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _suggestionsView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Select a Test',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        const Text(
          'Pick one of the weekly tests compiled from your struggle to begin:',
          style: TextStyle(
            fontSize: 13,
            color: NotelColors.textSecondary,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        for (final s in _suggestions) ...[
          _flowOptionCard(
            title: s.title,
            subtitle: s.desc,
            onTap: () => _selectSuggestion(s),
          ),
          const SizedBox(height: 12),
        ],
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () => _setSubView('input'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.08),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
            ),
            child: const Text('Back'),
          ),
        ),
      ],
    );
  }

  Widget _measureView() {
    final selected = _selectedSuggestion;
    if (selected == null) return _inputView();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Target Metric',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        const Text(
          'What metric do you want to measure to track success?',
          style: TextStyle(
            fontSize: 13,
            color: NotelColors.textSecondary,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        for (final (key, label) in focusMeasureMetrics) ...[
          _flowOptionCard(
            title: label,
            onTap: () => _selectMeasureMetric(key),
          ),
          const SizedBox(height: 10),
        ],
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () => _setSubView('suggestions'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.08),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
            ),
            child: const Text('Back'),
          ),
        ),
      ],
    );
  }

  Widget _setupView() {
    final selected = _selectedSuggestion;
    if (selected == null) return _inputView();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Test Duration',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Text(
          selected.title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: NotelColors.primary,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          selected.desc,
          style: const TextStyle(
            fontSize: 13,
            height: 1.4,
            color: NotelColors.textSecondary,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 28),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            OutlinedButton(
              onPressed: () => _changeDuration(false),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(
                    color: Colors.white.withValues(alpha: 0.08)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('- Remove Day',
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 12),
            Text(
              '$_setupDuration Days',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: () => _changeDuration(true),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(
                    color: Colors.white.withValues(alpha: 0.08)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('+ Add Day',
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        const SizedBox(height: 24),
        const Text(
          'Start Date',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: NotelColors.textSecondary,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _startOption(
                label: 'Today',
                selected: !_startTomorrow,
                onTap: () => setState(() => _startTomorrow = false),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _startOption(
                label: 'Tomorrow',
                selected: _startTomorrow,
                onTap: () => setState(() => _startTomorrow = true),
              ),
            ),
          ],
        ),
        if (_flowError != null) ...[
          const SizedBox(height: 12),
          Text(_flowError!,
              style: const TextStyle(
                  fontSize: 12, color: NotelColors.error),
              textAlign: TextAlign.center),
        ],
        const SizedBox(height: 32),
        Row(
          children: [
            Expanded(
              child: ElevatedButton(
                onPressed: () => _setSubView('measure'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white.withValues(alpha: 0.08),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                child: const Text('Back'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: _saving ? null : _lockInProject,
                style: ElevatedButton.styleFrom(
                  backgroundColor: NotelColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2),
                      )
                    : const Text('Lock it In'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _splashView() {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('🔒', style: TextStyle(fontSize: 64)),
        SizedBox(height: 16),
        Text(
          'Test Locked In!',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w900,
            color: Colors.white,
          ),
          textAlign: TextAlign.center,
        ),
        SizedBox(height: 8),
        Text(
          "Your wellness experiment has been synced. Let's get to work!",
          style: TextStyle(
            fontSize: 14,
            height: 1.45,
            color: NotelColors.textSecondary,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _flowOptionCard({
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            if (subtitle != null && subtitle.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.35,
                  color: NotelColors.textSecondary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _startOption({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? NotelColors.primary.withValues(alpha: 0.2)
              : Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? NotelColors.primary
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: selected ? NotelColors.primary : Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _detailsView(FocusTest test) {
    final isCompleted = test.isCompleted;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 90),
      children: [
        if (_tests.length > 1) _testSelector(),
        if (_tests.length > 1) const SizedBox(height: 16),
        _headerCard(test),
        if (_writeError != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: NotelColors.error.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: NotelColors.error.withValues(alpha: 0.4)),
            ),
            child: Text(_writeError!,
                style: const TextStyle(
                    fontSize: 13, color: NotelColors.textPrimary)),
          ),
        ],
        if (isCompleted) ...[
          const SizedBox(height: 16),
          _resultsLink(),
        ],
        if (!isCompleted) ...[
          const SizedBox(height: 16),
          const Text(
            "Today's Check-In",
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w900,
              letterSpacing: 1,
              color: NotelColors.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          _checkInCard(test),
        ],
        const SizedBox(height: 16),
        const Text(
          'Log History',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w900,
            letterSpacing: 1,
            color: NotelColors.textSecondary,
          ),
        ),
        const SizedBox(height: 10),
        _logCalendar(test),
        const SizedBox(height: 12),
        _legend(),
        const SizedBox(height: 24),
        OutlinedButton(
          onPressed: _saving ? null : _cancelTest,
          style: OutlinedButton.styleFrom(
            backgroundColor: NotelColors.error.withValues(alpha: 0.1),
            side: BorderSide(
                color: NotelColors.error.withValues(alpha: 0.35)),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: const Text('Cancel Experiment',
              style: TextStyle(
                  fontWeight: FontWeight.bold, color: NotelColors.error)),
        ),
        const SizedBox(height: 8),
        InkWell(
          onTap: _openJotTracker,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: NotelColors.primary.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: NotelColors.primary.withValues(alpha: 0.2)),
            ),
            child: Row(
              children: [
                Icon(Icons.open_in_browser,
                    size: 18,
                    color: NotelColors.primary.withValues(alpha: 0.7)),
                const SizedBox(width: 10),
                Text(
                  'Manage projects on jottracker.com',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: NotelColors.primary.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Native's completed-test results card.
  Widget _resultsLink() {
    return InkWell(
      onTap: _openJotTracker,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: NotelColors.success.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: NotelColors.success.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Icon(Icons.open_in_browser,
                size: 28, color: NotelColors.success),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'View Your Results',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: NotelColors.success,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Tap to open jottracker.com and see your full analysis',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                size: 20,
                color: NotelColors.success.withValues(alpha: 0.7)),
          ],
        ),
      ),
    );
  }

  Widget _testSelector() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final t in _tests) ...[
            _testChip(t),
            const SizedBox(width: 10),
          ],
        ],
      ),
    );
  }

  Widget _testChip(FocusTest t) {
    final key = t.id ?? t.title;
    final selected = key == _selectedId;
    return GestureDetector(
      onTap: () => _selectTest(key),
      child: Container(
        constraints: const BoxConstraints(minWidth: 120, maxWidth: 180),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? NotelColors.primary.withValues(alpha: 0.20)
              : Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? NotelColors.primary
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              t.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${t.durationDays} Days',
              style: const TextStyle(
                fontSize: 10,
                color: NotelColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _headerCard(FocusTest test) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final startMs = test.startTimestamp;
    final durationMs = test.durationDays * 24 * 60 * 60 * 1000;
    final elapsedMs = nowMs - startMs;
    final leftMs =
        elapsedMs < 0 ? durationMs : (durationMs - elapsedMs).clamp(0, durationMs);
    final isCompleted = leftMs <= 0;
    final daysLeft = elapsedMs < 0
        ? test.durationDays
        : (leftMs / (24 * 60 * 60 * 1000)).ceil();
    final daysElapsed = elapsedMs < 0
        ? 0
        : (elapsedMs ~/ (24 * 60 * 60 * 1000) + 1).clamp(0, test.durationDays);
    final progress = test.durationDays > 0
        ? (daysElapsed / test.durationDays).clamp(0.0, 1.0)
        : 1.0;

    final badgeColor = isCompleted ? NotelColors.success : NotelColors.primary;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            NotelColors.primary.withValues(alpha: 0.08),
            Colors.transparent,
          ],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: NotelColors.primary.withValues(alpha: 0.4),
          width: 2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  isCompleted
                      ? '✅ Complete. Results ready.'
                      : '⏳ In Progress',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5,
                    color: badgeColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            test.title,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              height: 1.27,
              color: NotelColors.textPrimary,
            ),
          ),
          if (test.desc != null && test.desc!.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              test.desc!,
              style: const TextStyle(
                fontSize: 13,
                height: 1.38,
                color: NotelColors.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Day $daysElapsed of ${test.durationDays}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: NotelColors.textSecondary,
                ),
              ),
              Text(
                isCompleted
                    ? 'Done!'
                    : '$daysLeft day${daysLeft == 1 ? '' : 's'} left',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: isCompleted
                      ? NotelColors.success
                      : NotelColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: Colors.white.withValues(alpha: 0.07),
              valueColor: AlwaysStoppedAnimation<Color>(
                isCompleted ? NotelColors.success : NotelColors.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _checkInCard(FocusTest test) {
    final now = DateTime.now();
    final todayStr = _dateStr(now);
    final startMs = test.startTimestamp;
    final elapsedMs = now.millisecondsSinceEpoch - startMs;
    final isFirstDay = test.lockDayStr == _lockDayStr(now);
    final checkedInToday =
        test.logs.containsKey(todayStr) || isFirstDay;

    if (elapsedMs < 0) {
      return _statusCard(
        emoji: '🔒',
        title: 'Day 0: Waiting to start',
        subtitle: 'Your experiment will begin tomorrow. Get ready!',
        accent: NotelColors.primary,
      );
    }
    if (checkedInToday) {
      return _statusCard(
        emoji: isFirstDay ? '🔒' : '✅',
        title: isFirstDay
            ? 'New test locked in!'
            : 'Response logged for today!',
        subtitle: isFirstDay
            ? 'Your check-in opens at midnight (12:00 AM) so you have time to perform the experiment first.'
            : 'Resets at midnight (12:00 AM)',
        accent: isFirstDay ? NotelColors.primary : NotelColors.success,
        // Native offers Undo on a logged response (not on lock-in day).
        trailing: isFirstDay
            ? null
            : TextButton(
                onPressed: _saving ? null : _undoCheckIn,
                child: const Text('Undo',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: NotelColors.error)),
              ),
      );
    }
    // Native's Yes/No check-in buttons.
    final isYes = test.logs[todayStr] == true;
    final isNo = test.logs[todayStr] == false;
    return Row(
      children: [
        Expanded(
          child: _checkInOption(
            emoji: '✅',
            label: 'Yes, I did it',
            selected: isYes,
            accent: NotelColors.primary,
            onTap: _saving ? null : () => _checkIn(true),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _checkInOption(
            emoji: '😞',
            label: 'Not today',
            selected: isNo,
            accent: NotelColors.error,
            onTap: _saving ? null : () => _checkIn(false),
          ),
        ),
      ],
    );
  }

  Widget _checkInOption({
    required String emoji,
    required String label,
    required bool selected,
    required Color accent,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(alpha: 0.2)
              : Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected
                ? accent
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Column(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 28)),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: selected ? accent : NotelColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusCard({
    required String emoji,
    required String title,
    required String subtitle,
    required Color accent,
    Widget? trailing,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: accent.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Text(emoji, style: const TextStyle(fontSize: 24)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: accent,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11,
                    color: accent.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }

  Widget _logCalendar(FocusTest test) {
    final startDate = DateTime.fromMillisecondsSinceEpoch(
      test.startTimestamp,
      isUtc: true,
    ).toLocal();
    final startDay =
        DateTime(startDate.year, startDate.month, startDate.day);
    final today = DateTime.now();
    final todayStr = _dateStr(today);
    final nowDay = DateTime(today.year, today.month, today.day);

    // Cap the grid so a corrupt duration can't build a huge list.
    final totalDays = test.durationDays.clamp(1, 91);
    final weeks = <List<int>>[];
    for (var i = 0; i < totalDays; i += 7) {
      weeks.add([
        for (var j = i; j < i + 7 && j < totalDays; j++) j,
      ]);
    }

    return Column(
      children: [
        for (final week in weeks)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                for (final dayOffset in week) ...[
                  Expanded(
                    child: _dayCell(
                      test: test,
                      date: startDay.add(Duration(days: dayOffset)),
                      dayNumber: dayOffset + 1,
                      todayStr: todayStr,
                      nowDay: nowDay,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                for (var k = week.length; k < 7; k++)
                  const Expanded(child: SizedBox()),
              ],
            ),
          ),
      ],
    );
  }

  Widget _dayCell({
    required FocusTest test,
    required DateTime date,
    required int dayNumber,
    required String todayStr,
    required DateTime nowDay,
  }) {
    final dateStr = _dateStr(date);
    final isToday = dateStr == todayStr;
    final isFuture = date.isAfter(nowDay);
    final logValue = test.logs[dateStr];
    final missed = logValue == false || (logValue == null && !isToday && !isFuture);

    late final Color bg;
    late final Color border;
    late final Widget inner;
    if (logValue == true) {
      bg = NotelColors.success.withValues(alpha: 0.25);
      border = NotelColors.success.withValues(alpha: 0.4);
      inner = const Text(
        '✓',
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w900,
          color: NotelColors.success,
        ),
      );
    } else if (missed) {
      bg = NotelColors.error.withValues(alpha: 0.15);
      border = NotelColors.error.withValues(alpha: 0.3);
      inner = const Text(
        '✗',
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w900,
          color: NotelColors.error,
        ),
      );
    } else if (isToday) {
      bg = NotelColors.primary.withValues(alpha: 0.1);
      border = NotelColors.primary.withValues(alpha: 0.4);
      inner = Text(
        '$dayNumber',
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: NotelColors.primary,
        ),
      );
    } else if (isFuture) {
      bg = Colors.white.withValues(alpha: 0.04);
      border = Colors.white.withValues(alpha: 0.05);
      inner = Text(
        '$dayNumber',
        style: TextStyle(
          fontSize: 10,
          color: Colors.white.withValues(alpha: 0.15),
        ),
      );
    } else {
      bg = Colors.white.withValues(alpha: 0.04);
      border = Colors.white.withValues(alpha: 0.05);
      inner = Text(
        '$dayNumber',
        style: const TextStyle(
          fontSize: 10,
          color: NotelColors.textSecondary,
        ),
      );
    }

    return AspectRatio(
      aspectRatio: 1,
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: border),
        ),
        alignment: Alignment.center,
        child: inner,
      ),
    );
  }

  Widget _legend() {
    return Row(
      children: [
        _legendItem(NotelColors.success, 'Completed'),
        const SizedBox(width: 16),
        _legendItem(NotelColors.error, 'Missed'),
        const SizedBox(width: 16),
        _legendItem(NotelColors.legacyDarkHairline, 'Upcoming'),
      ],
    );
  }

  Widget _legendItem(Color dot, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            color: NotelColors.textSecondary,
          ),
        ),
      ],
    );
  }
}
