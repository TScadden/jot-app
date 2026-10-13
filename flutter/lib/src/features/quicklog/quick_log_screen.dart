import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/quick_log_cache.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/voice_input.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/quicklog/history_screen.dart';
import 'package:tabs_lab/src/features/tools/trends_screen.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/skeleton.dart';
import 'package:tabs_lab/src/theme/slide_page_route.dart';

/// Round 19 — the Quick Log screen (the log tab — pencil icon in the
/// bottom dock). A faithful Flutter port of native `QuickLogScreen.kt`
/// + `QuickLogViewModel.kt`, with the founder's four explicit changes:
///
/// 1. (Superseded in Round 19b, founder Oct 12 2026: the "Today so
///    far" top-bar icon was removed as redundant next to the history
///    button. The top bar keeps just Trends + History.)
/// 2. "Load Suggestions" calls the REAL backend endpoint
///    `POST /api/ai/suggestions` — no stubs, no fake chips.
/// 3. Membership truth: the AI tray is gated on the sync pull's real
///    `isUnlimited`/`isAdmin` fields — the same fields native
///    `SyncManager` reads (server computes
///    `isUnlimited = isAdmin || users.is_unlimited`). Without membership
///    the UI shows native's honest "Standard Access" state, never a
///    silently broken button.
/// 4. Categories come from the account's REAL category set
///    (sync-pull `categories[]`) — never hardcoded. Honest empty/error
///    states when unreachable.
///
/// Founder addendum: the circular-arrow (replay) button moved OFF this
/// screen into the history view. Per native source it is
/// `repeatLastEntry()` — it re-logs a duplicate of the most recent entry
/// (it is NOT an undo/delete); that exact behavior is preserved in its
/// new home on the history screen.
///
/// All data is real: today's count from the sync-pull entries, recent
/// suggestions derived like native
/// (`TemplateAndDefaultsRepository.getDeduplicatedRecentSuggestions`),
/// saves via `POST /api/sync/entries` (server upserts on local_id).
/// Nothing is invented; unreachable backend → honest error states.
///
/// Round 19c — instant render (founder's directive): the screen draws
/// its static shell on the first frame and NEVER shows a blocking
/// spinner on open. Last-known categories / recent suggestions /
/// today's count / membership seed synchronously from
/// [QuickLogCache] (the Home stale-while-revalidate pattern, round
/// 16); the server refresh runs quietly in the background on every
/// open and merges in without blanking. A cold start (empty cache)
/// shows skeleton loaders shaped like the real content for the
/// sections still loading. A failed refresh keeps the cached values;
/// the full error state appears only when there is nothing cached
/// to show. Membership gating renders the CACHED gate state first —
/// the wrong gate never flashes.
///
/// Round 19c fix (Vera BLOCKING 2): the cached gate state is a
/// VISUAL seed only. No live AI action — Load Suggestions, Retry, or
/// the category-tap auto-fetch — may fire until this session's first
/// fresh refresh has completed with a successful membership fetch
/// (`_freshMembershipVerified`). `_fetchSuggestions` itself refuses
/// to POST before that point, so no caller can weaken the gate.
/// Round 19's rule stands: no interaction until fresh membership
/// arrives; 19c only lets the tray *render* in the meantime.
class QuickLogScreen extends StatefulWidget {
  final TabsBackend? backend;
  final WeatherApiClient? weatherApi;
  final VoiceInput? voiceInput;

  const QuickLogScreen({super.key, this.backend, this.weatherApi, this.voiceInput});

  @override
  State<QuickLogScreen> createState() => _QuickLogScreenState();
}

class _QuickLogScreenState extends State<QuickLogScreen> {
  TabsBackend get _backend => widget.backend ?? TabsBackend();
  VoiceInput get _voice => widget.voiceInput ?? VoiceInput();

  /// Round 19c: no blocking `_loading` flag exists anymore. The first
  /// background refresh flips this when it lands; until then, any
  /// section without a cache seed shows its skeleton. [_loadError] is
  /// only surfaced when there is no cached data to show.
  bool _firstRefreshDone = false;

  /// True once real categories have been on screen (cache seed or a
  /// completed refresh). A failed refresh surfaces the error state
  /// only while this is false — afterwards it keeps what's shown.
  bool _everHadCategories = false;
  String? _loadError;

  List<QuickLogEntry> _entries = const [];
  List<QuickLogCategory> _categories = const [];
  QuickLogCategory? _selectedCategory;

  final Map<int, List<String>> _chipCache = {};
  List<String> _chips = const [];
  List<String> _selectedChips = const [];
  bool _chipsLoading = false;
  String? _chipsError;

  final TextEditingController _manualController = TextEditingController();
  bool _hasTypedText = false;

  List<QuickLogEntry> _recentSuggestions = const [];
  int? _medicationCategoryId;

  bool _isUnlimited = false;
  bool _isAdmin = false;
  bool _membershipKnown = false;

  /// Round 19c fix (Vera BLOCKING 2): true only after THIS session's
  /// first fresh refresh completes with a successful membership
  /// fetch. Deliberately NEVER seeded from [QuickLogCache] — the
  /// cached `_isUnlimited`/`_isAdmin`/`_membershipKnown` above are a
  /// visual seed only, and every live AI action (Load Suggestions,
  /// Retry, category-tap fetch, and `_fetchSuggestions` itself) is
  /// locked until this flips. A failed refresh leaves it false, so
  /// a stale gate can never fire a real `POST /api/ai/suggestions`.
  bool _freshMembershipVerified = false;
  bool _autoAiSuggestions = false;
  String _profileUserContext = '';

  int _todayCount = 0;
  bool _saving = false;
  String? _saveError;

  static const _chipInk = Color(0xFF0A0A0E); // native LegacyDarkChipInk

  @override
  void initState() {
    super.initState();
    _manualController.addListener(() {
      final has = _manualController.text.trim().isNotEmpty;
      if (has != _hasTypedText) setState(() => _hasTypedText = has);
    });
    // Round 19c — stale-while-revalidate: seed synchronously from the
    // cache so the first frame already carries real last-known values
    // (cached gate state included), then refresh in the background.
    final cached = QuickLogCache.instance.snapshot;
    if (cached.categoriesLoaded) {
      _categories = cached.categories;
      _selectedCategory = cached.categories.firstOrNull;
    }
    if (cached.recentsLoaded) _recentSuggestions = cached.recentSuggestions;
    if (cached.todayCountLoaded) _todayCount = cached.todayCount;
    if (cached.membershipKnown) {
      _isUnlimited = cached.isUnlimited;
      _isAdmin = cached.isAdmin;
      _membershipKnown = true;
    }
    _everHadCategories = cached.categoriesLoaded;
    _refresh();
  }

  @override
  void dispose() {
    _manualController.dispose();
    super.dispose();
  }

  // ── Load (round 19c: background refresh, never blocking) ─────────

  /// Stale-while-revalidate refresh. Runs on every open (and on
  /// pull-to-refresh / retry / category mutations, as `_load` did in
  /// round 19). NEVER blanks the screen: state is swapped atomically
  /// when the fresh data lands, a failed refresh keeps whatever is on
  /// screen (cached seed or previous data), and the error state is
  /// surfaced only when nothing has ever been shown.
  Future<void> _refresh() async {
    try {
      final pull = await _backend.fetchSyncPull();
      if (!mounted) return;
      if (pull == null) {
        setState(() {
          _firstRefreshDone = true;
          if (!_everHadCategories) {
            _loadError = "Couldn't reach the Tabs server. "
                'Check your connection and pull down to retry.';
          }
        });
        return;
      }
      final entries = await _backend.fetchLogEntryDtos();
      final rawCategories = await _backend.fetchLogCategories();
      final membership = await _backend.fetchMembership();
      final profile = await _backend.fetchProfile();

      final ranked = rankCategories(rawCategories, entries);
      final medCat = rawCategories
          .where((c) =>
              c.name.trim().toLowerCase() == 'medication' ||
              c.name.trim().toLowerCase() == 'medications')
          .firstOrNull;
      final medNames = _activeMedicationNames(profile);
      final recents = recentSuggestions(
        entries,
        activeMedicationNames: medNames,
        medicationCategoryId: medCat?.id,
      );
      final auto = profile?['autoAiSuggestions'] == true;
      final userContext = '${profile?['userContext'] ?? ''}'.trim();

      final selected = _selectedCategory == null
          ? ranked.firstOrNull
          : ranked.where((c) => c.id == _selectedCategory!.id).firstOrNull ??
              ranked.firstOrNull;

      if (!mounted) return;
      setState(() {
        _entries = entries;
        _categories = ranked;
        _selectedCategory = selected;
        _isUnlimited = membership.isUnlimited;
        _isAdmin = membership.isAdmin;
        _membershipKnown = true;
        // Vera BLOCKING 2: reaching this line means the sync pull
        // succeeded above and fetchMembership() read real membership
        // from it in THIS session — only now may live AI actions
        // fire. The pull==null and catch paths below never set this.
        _freshMembershipVerified = true;
        _autoAiSuggestions = auto;
        _profileUserContext = userContext;
        _medicationCategoryId = medCat?.id;
        _recentSuggestions = recents;
        _todayCount = todayEntryCount(entries);
        _firstRefreshDone = true;
        _everHadCategories = true;
        _loadError = null;
      });
      // Round 19c: this completed load becomes the next open's seed.
      final cache = QuickLogCache.instance;
      cache.applyLoad(
        categories: ranked,
        recentSuggestions: recents,
        todayCount: _todayCount,
        isUnlimited: membership.isUnlimited,
        isAdmin: membership.isAdmin,
      );
      unawaited(cache.persist());

      // Native auto-fetch: Auto Ping on + category + access + no chips.
      if (auto &&
          (_isUnlimited || _isAdmin) &&
          selected != null &&
          _chips.isEmpty &&
          !_chipsLoading &&
          _chipsError == null) {
        _fetchSuggestions();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _firstRefreshDone = true;
        // Keep cached/on-screen values on failure (Home pattern);
        // surface the error only when nothing has ever been shown.
        if (!_everHadCategories) {
          _loadError = 'Something went wrong loading Quick Log: $e';
        }
      });
    }
  }

  /// Active (non-archived) medication names from the profile
  /// `medications` blob — mirrors the native recent-suggestions filter.
  Set<String> _activeMedicationNames(Map<String, dynamic>? profile) {
    final raw = profile?['medications'];
    final decoded = TabsBackend.decodeProfileList(raw);
    final out = <String>{};
    for (final m in decoded) {
      if (m['isArchived'] == true) continue;
      final name = '${m['name'] ?? ''}'.trim().toLowerCase();
      if (name.isNotEmpty) out.add(name);
    }
    return out;
  }

  // ── Suggestions ───────────────────────────────────────────────────

  /// Native `QuickLogViewModel.fetchSuggestions`, hitting the real
  /// `POST /api/ai/suggestions` endpoint. Membership is checked first,
  /// exactly like native `LogRepository.getChipSuggestions` (which fails
  /// with "Unlimited membership required for AI features.").
  Future<void> _fetchSuggestions({bool forceRefresh = false}) async {
    // Vera BLOCKING 2: refuse to POST on a stale cache gate. Until
    // this session's first fresh refresh has verified membership
    // against the server, the cached flags are visual-only and this
    // method is a no-op — no caller (Load, Retry, category tap, or
    // the refresh's own auto-fetch, which runs only after the flag
    // is set) can reach `POST /api/ai/suggestions` before that.
    if (!_freshMembershipVerified) return;
    final cat = _selectedCategory;
    if (cat == null) return;
    if (!_isUnlimited && !_isAdmin) {
      setState(() => _chipsError =
          'Unlimited membership required for AI features. Please check Membership in Settings.');
      return;
    }
    if (!forceRefresh) {
      final cached = _chipCache[cat.id];
      if (cached != null) {
        setState(() {
          _chips = cached;
          _chipsLoading = false;
          _chipsError = null;
        });
        return;
      }
    }
    setState(() {
      _chipsLoading = true;
      _chipsError = null;
    });
    try {
      final recent =
          _entries.where((e) => e.categoryId == cat.id).take(20).toList();
      final weather = await _weatherContext();
      final chips = await _backend.postSuggestions(
        category: cat,
        recentEntries: recent,
        userContext: _buildUserContext(cat),
        weatherContext: weather,
      );
      if (chips == null) {
        setState(() {
          _chipsLoading = false;
          _chipsError =
              "Couldn't load suggestions. Check your connection and retry.";
        });
        return;
      }
      final cleaned = cleanChips(chips, cat.name);
      _chipCache[cat.id] = cleaned;
      setState(() {
        _chips = cleaned;
        _chipsLoading = false;
        _chipsError = null;
      });
    } catch (e) {
      setState(() {
        _chipsLoading = false;
        _chipsError = 'Suggestions failed: $e';
      });
    }
  }

  /// Native appends its suggestion-engine rules to the enriched user
  /// context; the profile's `userContext` + demographics stand in for
  /// the native DataStore-backed enriched context here.
  String _buildUserContext(QuickLogCategory cat) {
    final sb = StringBuffer();
    if (_profileUserContext.isNotEmpty) {
      sb.writeln('USER BACKGROUND CONTEXT:');
      sb.writeln(_profileUserContext);
      sb.writeln();
    }
    sb.writeln('[SYSTEM: SUGGESTION_ENGINE_RULES]');
    sb.writeln("Return 6-10 'Quick Note' chips. Rules:");
    sb.writeln(
        '1. STRICTURE: Each chip MUST BE 20 CHARACTERS OR LESS (including spaces).');
    sb.writeln('2. Each chip MUST be 1-3 words total.');
    sb.writeln(
        "3. Focus only on specific symptoms, actions, or status updates appropriate for the category '${cat.name}'.");
    sb.writeln("4. NO full sentences. NO punctuation. NO trailing conjunctions ('and', 'with', 'for').");
    sb.writeln(
        "5. Use clear health abbreviations if necessary (e.g., 'RLS', 'POTs', 'OI', 'MCAS').");
    sb.writeln(
        '6. Priorities matching current user data (HR spikes, sleep debt, past logs).');
    sb.writeln("Example: 'Brain Fog', 'Chest Pain', 'High HR Spike', 'Restless Legs'.");
    return sb.toString();
  }

  Future<String?> _weatherContext() async {
    try {
      final w = await widget.weatherApi?.getCurrentWeather();
      final temp = w?.temp;
      if (temp == null) return null;
      return 'Current weather: $temp°F';
    } catch (_) {
      return null;
    }
  }

  void _selectCategory(QuickLogCategory cat) {
    final cached = _chipCache[cat.id];
    setState(() {
      _selectedCategory = cat;
      _selectedChips = const [];
      _chips = cached ?? const [];
      // Vera BLOCKING 2: no AI fetch (and no fetch spinner) from a
      // category tap until fresh membership is verified this session.
      _chipsLoading =
          cached == null && _autoAiSuggestions && _freshMembershipVerified;
      _chipsError = null;
    });
    if (cached != null) return;
    if (!_autoAiSuggestions) return;
    if (!_freshMembershipVerified) return;
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted && _selectedCategory?.id == cat.id) _fetchSuggestions();
    });
  }

  void _toggleChip(String chip) {
    final current = _selectedChips.toList();
    if (current.contains(chip)) {
      current.remove(chip);
    } else {
      current.add(chip);
    }
    setState(() => _selectedChips = current);
  }

  // ── Save ──────────────────────────────────────────────────────────

  bool get _isLogEnabled =>
      !_saving && (_selectedChips.isNotEmpty || _hasTypedText);

  String _composedText() {
    final parts = <String>[];
    if (_selectedChips.isNotEmpty) parts.add(_selectedChips.join(' · '));
    final manual = _manualController.text.trim();
    if (manual.isNotEmpty) parts.add(manual);
    return parts.join(' · ');
  }

  int _nextEntryId() {
    var maxId = 0;
    for (final e in _entries) {
      if (e.id > maxId) maxId = e.id;
    }
    return maxId + 1;
  }

  /// Native `saveEntry()`: chipless manual notes file under the
  /// "general" category (native `findCategoryIdBySlug("general",
  /// defaultId = 7)`); here resolved against the real category set.
  Future<void> _saveEntry() async {
    final cat = _selectedCategory;
    if (cat == null || !_isLogEnabled) return;
    final body = _composedText();
    if (body.isEmpty) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final categoryId = _selectedChips.isEmpty
        ? _categories
                .where((c) => c.name.trim().toLowerCase() == 'general')
                .firstOrNull
                ?.id ??
            cat.id
        : cat.id;
    final entry = QuickLogEntry(
      id: _nextEntryId(),
      categoryId: categoryId,
      body: body,
      chips: _selectedChips.isEmpty ? '' : _selectedChips.join(', '),
      manualText: _manualController.text.trim(),
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    try {
      final ok = await _backend.postLogEntries([entry]);
      if (!ok) {
        setState(() {
          _saving = false;
          _saveError =
              "Couldn't save that entry. Check your connection and try again.";
        });
        return;
      }
      _backend.invalidateSyncPull();
      final entries = await _backend.fetchLogEntryDtos();
      final medNames = _activeMedicationNames(await _backend.fetchProfile());
      setState(() {
        _entries = entries;
        _todayCount = todayEntryCount(entries);
        _recentSuggestions = recentSuggestions(
          entries,
          activeMedicationNames: medNames,
          medicationCategoryId: _medicationCategoryId,
        );
        _saving = false;
        _saveError = null;
        _selectedChips = const [];
        _manualController.clear();
      });
      // Round 19c: keep the cache seed in step with the mutation.
      QuickLogCache.instance.applyCounts(
        todayCount: _todayCount,
        recentSuggestions: _recentSuggestions,
      );
      unawaited(QuickLogCache.instance.persist());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Entry logged · $_todayCount today')),
        );
      }
    } catch (e) {
      setState(() {
        _saving = false;
        _saveError = 'Save failed: $e';
      });
    }
  }

  /// Native `logFromRecent()`: taps a recent-suggestion chip to
  /// immediately re-log that entry's content.
  Future<void> _logFromRecent(QuickLogEntry entry) async {
    final dupe = QuickLogEntry(
      id: _nextEntryId(),
      categoryId: entry.categoryId,
      body: entry.body,
      chips: entry.chips,
      manualText: entry.manualText,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    final ok = await _backend.postLogEntries([dupe]);
    if (!mounted) return;
    if (ok) {
      _backend.invalidateSyncPull();
      final entries = await _backend.fetchLogEntryDtos();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _todayCount = todayEntryCount(entries);
      });
      QuickLogCache.instance.applyCounts(todayCount: _todayCount);
      unawaited(QuickLogCache.instance.persist());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Entry logged · $_todayCount today')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't log that entry — try again.")),
      );
    }
  }

  // ── Mic ───────────────────────────────────────────────────────────

  /// Native mic launches `VoiceLogActivity`; here the system recognizer
  /// fills the details field (the user then taps Log — same data path
  /// as typed text). Errors surface their `[CODE]` visibly (team rule:
  /// no silent channel failures).
  Future<void> _mic() async {
    try {
      final text = await _voice.startVoiceInput();
      final current = _manualController.text.trim();
      _manualController.text =
          current.isEmpty ? text : '$current $text';
    } on VoiceInputException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  // ── Categories: add / delete ──────────────────────────────────────

  /// Native "Add" opens the AI category-ideas dialog; the Lab port keeps
  /// the honest subset — a manual name via the real
  /// `POST /api/sync/categories` full-list write. (AI ideas deferred.)
  Future<void> _addCategory() async {
    final nameController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: NotelColors.surface,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('New category',
            style: TextStyle(
                color: NotelColors.textPrimary,
                fontWeight: FontWeight.bold)),
        content: TextField(
          controller: nameController,
          autofocus: true,
          style: const TextStyle(color: NotelColors.textPrimary),
          decoration: const InputDecoration(
            hintText: 'Category name…',
            hintStyle: TextStyle(color: NotelColors.textSecondary),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel',
                style: TextStyle(color: NotelColors.textPrimary)),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, nameController.text.trim()),
            child: const Text('Add',
                style: TextStyle(
                    color: NotelColors.primary,
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    const palette = [
      '#FF6B6B',
      '#FFB347',
      '#6BCB77',
      '#4ECDC4',
      '#4D96FF',
      '#A566FF',
      '#FFD93D'
    ];
    final nextId =
        _categories.fold<int>(0, (m, c) => c.id > m ? c.id : m) + 1;
    final nextSort =
        _categories.fold<int>(0, (m, c) => c.sortOrder > m ? c.sortOrder : m) +
            1;
    final updated = [
      ..._categories,
      QuickLogCategory(
        id: nextId,
        name: name[0].toUpperCase() + name.substring(1),
        icon: 'circle',
        colorHex: palette[nextId % palette.length],
        isDefault: false,
        sortOrder: nextSort,
      ),
    ];
    final ok = await _backend.postLogCategories(updated);
    if (!mounted) return;
    if (ok) {
      _backend.invalidateSyncPull();
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Added "$name"')));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't add that category.")),
      );
    }
  }

  /// Native `confirmDeleteCategory()` with its confirmation dialog.
  /// The server has no single-row category DELETE, so delete = full-list
  /// POST minus the removed row (the server prunes missing ids).
  Future<void> _confirmDeleteCategory(QuickLogCategory cat) async {
    if (cat.id == 7 || cat.isDefault) return; // native guard, verbatim
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: NotelColors.surface,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Subject?',
            style: TextStyle(
                color: NotelColors.textPrimary,
                fontWeight: FontWeight.bold)),
        content: Text(
          "Are you sure you want to delete '${cat.name}'? This will remove the subject from your quick logging list.",
          style: const TextStyle(color: NotelColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel',
                style: TextStyle(color: NotelColors.textPrimary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete',
                style: TextStyle(
                    color: NotelColors.error, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final updated = _categories.where((c) => c.id != cat.id).toList();
    final ok = await _backend.postLogCategories(updated);
    if (!mounted) return;
    if (ok) {
      _backend.invalidateSyncPull();
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Deleted "${cat.name}"')));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't delete that category.")),
      );
    }
  }

  // ── Navigation ────────────────────────────────────────────────────

  // Round 22 — SlidePageRoute, not MaterialPageRoute: Material 3's
  // default fade transition ghosted against the Quick Log screen
  // underneath (the founder's recording). Every push in the app now
  // uses the one shared slide-in-from-right.
  void _openHistory() {
    Navigator.of(context).push(
      SlidePageRoute(
        reducedMotion: animationsDisabled(context),
        builder: (_) => HistoryScreen(backend: widget.backend),
      ),
    );
  }

  void _openTrends() {
    Navigator.of(context).push(
      SlidePageRoute(
        reducedMotion: animationsDisabled(context),
        builder: (_) => TrendsScreen(backend: widget.backend),
      ),
    );
  }

  /// Founder change #3: without membership the AI tray shows native's
  /// honest "Standard Access" state. The trial link opens an explainer —
  /// membership signup lives in the main Tabs app / Play Store, which
  /// the Lab build cannot provision.
  void _showMembershipExplainer() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: NotelColors.surface,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Tabs Premium',
            style: TextStyle(
                color: NotelColors.textPrimary, fontWeight: FontWeight.bold)),
        content: const Text(
          'AI suggestions need Tabs Premium. Membership is managed in the main Tabs app — this Lab build shows your real membership state but can\u2019t start a trial.',
          style: TextStyle(color: NotelColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it',
                style: TextStyle(
                    color: NotelColors.primary,
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final activeCatColor =
        _selectedCategory?.color ?? NotelColors.primary;
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        title: const Text(
          'Quick Log',
          style: TextStyle(
            color: NotelColors.textPrimary,
            fontWeight: FontWeight.bold,
            fontSize: 22, // M3 titleLarge, native parity
          ),
        ),
        actions: [
          // Round 19b (founder, Oct 12 2026): the "Today so far"
          // calendar icon that sat here was removed — redundant next
          // to the History button. Top bar is Trends + History only.
          IconButton(
            onPressed: _openTrends,
            icon: const Icon(Icons.trending_up),
            tooltip: 'Trends',
            color: NotelColors.textSecondary,
          ),
          IconButton(
            onPressed: () => _openHistory(),
            icon: const Icon(Icons.history),
            tooltip: 'History',
            color: NotelColors.textSecondary,
          ),
        ],
      ),
      // Round 19c: the shell (details field, labels, Log flow) draws
      // on the FIRST frame — no blocking spinner branch exists. The
      // error body appears only when a refresh failed AND nothing
      // cached was ever shown; otherwise sections render their cache
      // seed or their skeleton while the refresh runs behind them.
      body: _loadError != null
          ? _buildLoadError()
          : RefreshIndicator(
              color: NotelColors.primary,
              onRefresh: () async {
                _backend.invalidateSyncPull();
                await _refresh();
              },
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(top: 8, bottom: 110),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildDetailsRow(activeCatColor),
                    _buildCategoriesLabel(),
                    _buildCategoryRow(),
                    if (_recentSuggestions.isNotEmpty)
                      _buildRecentSuggestions()
                    else if (!_firstRefreshDone)
                      _buildRecentSuggestionsSkeleton(),
                    _buildAiTray(activeCatColor),
                    _buildQuickNoteCard(activeCatColor),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildLoadError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _loadError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: NotelColors.textSecondary),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () {
                setState(() => _loadError = null);
                _backend.invalidateSyncPull();
                _refresh();
              },
              child: const Text('Retry',
                  style: TextStyle(
                      color: NotelColors.primary,
                      fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  /// Details text field. Native trailing-icon behavior: saving →
  /// spinner; typed text → Add (saves); empty → Mic (voice input).
  /// The circular-arrow replay button is NOT here — founder addendum
  /// moved it into the history view.
  Widget _buildDetailsRow(Color activeCatColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TextField(
        controller: _manualController,
        style:
            const TextStyle(color: NotelColors.textPrimary, fontSize: 14),
        cursorColor: activeCatColor,
        decoration: InputDecoration(
          hintText: 'Add optional details about these symptoms…',
          hintStyle: const TextStyle(
              color: NotelColors.textSecondary, fontSize: 13),
          filled: true,
          fillColor: NotelColors.surface,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide:
                BorderSide(color: activeCatColor.withValues(alpha: 0.25)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: activeCatColor),
          ),
          suffixIcon: _saving
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: activeCatColor,
                    ),
                  ),
                )
              : _hasTypedText
                  ? IconButton(
                      onPressed: _saveEntry,
                      icon: const Icon(Icons.add),
                      tooltip: 'Log typed note',
                      color: activeCatColor,
                    )
                  : IconButton(
                      onPressed: _mic,
                      icon: const Icon(Icons.mic),
                      tooltip: 'Voice Input',
                      color: activeCatColor,
                    ),
        ),
      ),
    );
  }

  Widget _buildCategoriesLabel() {
    return const Padding(
      padding: EdgeInsets.only(left: 16, top: 12, bottom: 4),
      child: Text(
        'Categories',
        style: TextStyle(
          color: NotelColors.textPrimary,
          fontWeight: FontWeight.bold,
          fontSize: 14,
        ),
      ),
    );
  }

  /// The REAL category set (sync pull) — never hardcoded. Honest empty
  /// state when the pull carried none.
  ///
  /// Round 19c: while the first refresh is still running and no cache
  /// seed exists, the row is chip-shaped skeletons (same 48dp row
  /// height, same 12dp chip radius) — never a spinner.
  Widget _buildCategoryRow() {
    if (_categories.isEmpty) {
      if (!_firstRefreshDone) return _buildCategorySkeleton();
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Text(
          'No categories found on your account.',
          style: TextStyle(color: NotelColors.textSecondary, fontSize: 12),
        ),
      );
    }
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemCount: _categories.length + 1,
        itemBuilder: (context, index) {
          if (index == _categories.length) return _buildAddCategoryBox();
          final cat = _categories[index];
          final selected = cat.id == _selectedCategory?.id;
          final catColor = cat.color;
          final deletable = !(cat.id == 7 || cat.isDefault);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _selectCategory(cat),
            onLongPress:
                deletable ? () => _confirmDeleteCategory(cat) : null,
            // R49 Q1: the full 48dp row height is the hit area
            // (was a 36dp chip inside v6 list padding).
            child: SizedBox(
              height: 48,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: selected ? catColor : NotelColors.surface,
                    border: Border.all(
                      color: selected
                          ? catColor
                          : catColor.withValues(alpha: 0.35),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    cat.name,
                    style: TextStyle(
                      color: selected
                          ? _chipInk
                          : NotelColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Chip-shaped skeleton row for the category area (cold start).
  Widget _buildCategorySkeleton() {
    return const SkeletonGroup(
      child: SizedBox(
        height: 48,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: NeverScrollableScrollPhysics(),
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              SkeletonBox(width: 92, height: 36, radius: 12),
              SizedBox(width: 8),
              SkeletonBox(width: 118, height: 36, radius: 12),
              SizedBox(width: 8),
              SkeletonBox(width: 74, height: 36, radius: 12),
              SizedBox(width: 8),
              SkeletonBox(width: 96, height: 36, radius: 12),
            ],
          ),
        ),
      ),
    );
  }

  /// Label + chip-shaped skeleton row for recent suggestions (cold
  /// start, first refresh pending). Mirrors the real section's label
  /// position and 48dp chip row.
  Widget _buildRecentSuggestionsSkeleton() {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(left: 16, top: 8, bottom: 4),
          child: SkeletonGroup(
            child: SkeletonBox(width: 130, height: 14, radius: 4),
          ),
        ),
        SkeletonGroup(
          child: SizedBox(
            height: 48,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: NeverScrollableScrollPhysics(),
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  SkeletonBox(width: 120, height: 36, radius: 12),
                  SizedBox(width: 8),
                  SkeletonBox(width: 96, height: 36, radius: 12),
                  SizedBox(width: 8),
                  SkeletonBox(width: 110, height: 36, radius: 12),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAddCategoryBox() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _addCategory,
      // R49 Q1: same 48dp hit area as the category chips it sits
      // beside (visual box unchanged, centered in the row).
      child: SizedBox(
        height: 48,
        child: Center(
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: NotelColors.surface,
              border: Border.all(
                  color: NotelColors.primary.withValues(alpha: 0.25)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add, size: 16, color: NotelColors.primary),
                SizedBox(width: 4),
                Text(
                  'Add',
                  style: TextStyle(
                    color: NotelColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRecentSuggestions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 16, top: 8, bottom: 4),
          child: Text(
            'Recent suggestions',
            style: TextStyle(
              color: NotelColors.textPrimary,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ),
        SizedBox(
          // R49 Q2: row 44→48 so the chips' hit area reaches 48dp
          // (was 36dp); visual chip unchanged, centered in the row.
          height: 48,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemCount: _recentSuggestions.length,
            itemBuilder: (context, index) {
              final entry = _recentSuggestions[index];
              final label = entry.body.length > 25
                  ? entry.body.substring(0, 25)
                  : entry.body;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _logFromRecent(entry),
                child: SizedBox(
                  height: 48,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: NotelColors.surfaceHigh,
                        border: Border.all(
                            color: NotelColors.surfaceHigh
                                .withValues(alpha: 0.5)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.history,
                              size: 14,
                              color: NotelColors.textSecondary),
                          const SizedBox(width: 6),
                          Text(
                            label,
                            style: const TextStyle(
                              color: NotelColors.textPrimary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// AI chip tray with native's exact state machine + the membership
  /// gate on the real `isUnlimited`/`isAdmin` fields.
  Widget _buildAiTray(Color activeCatColor) {
    Widget body;
    if (!_membershipKnown) {
      // Round 19c: gate state unknown (no cache seed, first refresh
      // pending) → shaped skeleton, NEVER a guessed gate. A cached
      // gate state renders here instead, from the first frame.
      body = const SkeletonGroup(
        child: Column(
          children: [
            SkeletonBox(width: 140, height: 16, radius: 4),
            SizedBox(height: 12),
            SkeletonBox(width: 190, height: 14, radius: 4),
          ],
        ),
      );
    } else if (!_isUnlimited && !_isAdmin) {
      body = Column(
        children: [
          const Text(
            'Standard Access',
            style: TextStyle(
              color: NotelColors.textSecondary,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _showMembershipExplainer,
            child: const Text(
              'Click here to start Free Trial',
              style: TextStyle(
                  color: NotelColors.primary,
                  fontWeight: FontWeight.bold),
            ),
          ),
        ],
      );
    } else if (_chipsLoading) {
      body = const Column(
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(
                color: NotelColors.primary),
          ),
          SizedBox(height: 12),
          Text('Getting suggestions…',
              style: TextStyle(
                  color: NotelColors.textSecondary, fontSize: 14)),
        ],
      );
    } else if (_chipsError != null) {
      body = Column(
        children: [
          Text(
            _chipsError!,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: NotelColors.error, fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextButton(
            // Vera BLOCKING 2: rendered from the cache seed, but
            // disabled until fresh membership is verified this
            // session (`_fetchSuggestions` also refuses pre-refresh).
            onPressed: _freshMembershipVerified
                ? () => _fetchSuggestions(forceRefresh: true)
                : null,
            child: const Text('Retry',
                style: TextStyle(
                    color: NotelColors.primary,
                    fontWeight: FontWeight.bold)),
          ),
        ],
      );
    } else if (!_autoAiSuggestions && _chips.isEmpty) {
      body = Column(
        children: [
          const Text(
            'No suggestions loaded',
            style: TextStyle(
                color: NotelColors.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 8),
          TextButton(
            // Vera BLOCKING 2: rendered from the cache seed, but
            // disabled until fresh membership is verified this
            // session (`_fetchSuggestions` also refuses pre-refresh).
            onPressed: _freshMembershipVerified
                ? () => _fetchSuggestions(forceRefresh: true)
                : null,
            child: const Text(
              'Load Suggestions',
              style: TextStyle(
                  color: NotelColors.primary,
                  fontWeight: FontWeight.bold),
            ),
          ),
        ],
      );
    } else {
      body = _buildChipGrid(activeCatColor);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: body,
    );
  }

  Widget _buildChipGrid(Color activeCatColor) {
    final rows = <Widget>[];
    for (var i = 0; i < _chips.length; i += 2) {
      final rowChips = _chips.sublist(
          i, i + 2 > _chips.length ? _chips.length : i + 2);
      rows.add(
        Row(
          children: [
            for (final chip in rowChips)
              Expanded(child: _buildChip(chip, activeCatColor)),
            if (rowChips.length == 1) const Expanded(child: SizedBox()),
          ],
        ),
      );
      rows.add(const SizedBox(height: 10));
    }
    return Column(
      children: [
        ...rows,
        const Padding(
          padding: EdgeInsets.only(top: 4, bottom: 8),
          child: Text(
            'Quick notes are generated with AI using your data, so they may not always represent exactly what you are looking for.',
            style: TextStyle(
              color: NotelColors.textSecondary,
              fontSize: 10,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildChip(String chip, Color activeCatColor) {
    final selected = _selectedChips.contains(chip);
    return GestureDetector(
      onTap: () => _toggleChip(chip),
      child: Container(
        // R49 Q4: min height 48 (was ≈41 from v12 padding + 13sp).
        constraints: const BoxConstraints(minHeight: 48),
        alignment: Alignment.centerLeft,
        margin: const EdgeInsets.only(right: 10),
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: selected ? activeCatColor : NotelColors.surface,
          border: Border.all(
            color: selected
                ? activeCatColor
                : activeCatColor.withValues(alpha: 0.25),
          ),
        ),
        child: Text(
          chip,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            // R49 Q3/S1: selected ink is the in-file _chipInk
            // precedent (5.21:1 on primary), not white (3.80:1).
            color: selected ? _chipInk : NotelColors.textPrimary,
            fontSize: 13,
            fontWeight:
                selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  /// "Your quick note" card — visible when chips are selected, text is
  /// typed, or a save error exists (native AnimatedVisibility rule).
  Widget _buildQuickNoteCard(Color activeCatColor) {
    final visible = _selectedChips.isNotEmpty ||
        _hasTypedText ||
        _saveError != null;
    if (!visible) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: NotelColors.surface,
        border: Border.all(
            color: NotelColors.primary.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Your quick note',
                style: TextStyle(
                    color: NotelColors.textSecondary, fontSize: 12),
              ),
              SizedBox(
                height: 48,
                child: ElevatedButton(
                  onPressed: _isLogEnabled ? _saveEntry : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: activeCatColor,
                    disabledBackgroundColor:
                        activeCatColor.withValues(alpha: 0.35),
                    foregroundColor: Colors.white,
                    disabledForegroundColor:
                        Colors.white.withValues(alpha: 0.5),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check, size: 14),
                            SizedBox(width: 4),
                            Text(
                              'Log',
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _composedText(),
            style: const TextStyle(
              color: NotelColors.textPrimary,
              // R49 HI7: entry-body role is 15sp (History parity).
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (_saveError != null) ...[
            const SizedBox(height: 8),
            Text(
              _saveError!,
              style: const TextStyle(
                color: NotelColors.error,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
