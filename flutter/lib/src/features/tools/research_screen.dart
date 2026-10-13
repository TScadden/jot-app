import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/slide_page_route.dart';
import 'package:url_launcher/url_launcher.dart';

/// Medical disclaimer — always visible at the top (native ResearchScreen.kt,
/// verbatim copy).
const String researchDisclaimer =
    'For educational purposes only. This is not medical advice. '
    'Talk to your doctor before trying anything here.';

/// Round 18b — the research library is BUNDLED, not server data.
///
/// Native ground truth (`ResearchViewModel` + `ResearchEntryLoader`):
/// entries are JSON files under `app/src/main/assets/research/`, loaded
/// from the app bundle and filtered by the user's conditions
/// (`conditionTags`). Round 18 wrongly wired this screen to sync-pull
/// `documents` (the knowledge-base upload store), so it showed
/// "Nothing here yet" despite the library existing.
///
/// The 15 JSON files are copied verbatim to `flutter/assets/research/`
/// and registered in `pubspec.yaml`. Entries whose `conditionTags`
/// contain the selected condition are shown, like native.

/// One research library entry — mirrors native `ResearchEntry`.
class ResearchEntry {
  final String id;
  final String title;
  final String summary;
  final List<String> takeaways;
  final String detail;
  final String sourceName;
  final String sourceUrl;
  final List<String> conditionTags;

  const ResearchEntry({
    required this.id,
    required this.title,
    required this.summary,
    required this.takeaways,
    required this.detail,
    required this.sourceName,
    required this.sourceUrl,
    required this.conditionTags,
  });

  /// Tolerant parse; null when the map isn't entry-shaped. Never throws.
  static ResearchEntry? fromJson(Map<String, dynamic> json) {
    try {
      final id = '${json['id'] ?? ''}'.trim();
      final title = '${json['title'] ?? ''}'.trim();
      if (id.isEmpty || title.isEmpty) return null;
      List<String> asStrings(dynamic v) {
        if (v is List) {
          return [
            for (final e in v)
              if ('$e'.trim().isNotEmpty) '$e'.trim()
          ];
        }
        return const [];
      }

      return ResearchEntry(
        id: id,
        title: title,
        summary: '${json['summary'] ?? ''}'.trim(),
        takeaways: asStrings(json['takeaways']),
        detail: '${json['detail'] ?? ''}'.trim(),
        sourceName: '${json['sourceName'] ?? ''}'.trim(),
        sourceUrl: '${json['sourceUrl'] ?? ''}'.trim(),
        conditionTags: asStrings(json['conditionTags']),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Loads every `assets/research/*.json` entry via [bundle].
/// Malformed files are skipped; never throws.
Future<List<ResearchEntry>> loadResearchEntries(AssetBundle bundle) async {
  final out = <ResearchEntry>[];
  try {
    final manifestRaw = await bundle.loadString('AssetManifest.json');
    final manifest = jsonDecode(manifestRaw);
    if (manifest is! Map) return out;
    final files = manifest.keys
        .where((k) =>
            k is String &&
            k.startsWith('assets/research/') &&
            k.endsWith('.json'))
        .toList()
      ..sort();
    for (final path in files) {
      try {
        final raw = await bundle.loadString(path as String);
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          final entry = ResearchEntry.fromJson(decoded);
          if (entry != null) out.add(entry);
        }
      } catch (_) {
        // Skip malformed entry files — never fail the whole library.
      }
    }
  } catch (_) {
    // Manifest unreadable → empty library.
  }
  return out;
}

/// Entries whose [ResearchEntry.conditionTags] contain [condition],
/// mirroring native's filter. Never throws.
List<ResearchEntry> entriesForCondition(
    List<ResearchEntry> entries, String? condition) {
  if (condition == null || condition.isEmpty) return const [];
  return entries
      .where((e) => e.conditionTags.contains(condition))
      .toList();
}

/// Round 18b — Research tool screen backed by the bundled library.
///
/// [bundle] is injectable so widget tests can drive the screen with a
/// fake asset bundle; production defaults to [rootBundle].
///
/// Round 48 — the no-conditions card gains native's
/// "Go to Profile → Conditions" button (native `ResearchScreen`
/// navigates to Profile). In this app the conditions editor lives
/// in Settings → User Profile, so the button pushes Settings; on
/// return the conditions are reloaded so newly added ones apply.
class ResearchToolScreen extends StatefulWidget {
  final VoidCallback? onBack;
  final TabsBackend? backend;
  final AssetBundle? bundle;

  const ResearchToolScreen(
      {super.key, this.onBack, this.backend, this.bundle});

  @override
  State<ResearchToolScreen> createState() => _ResearchToolScreenState();
}

class _ResearchToolScreenState extends State<ResearchToolScreen> {
  TabsBackend get _backend => widget.backend ?? TabsBackend();
  AssetBundle get _bundle => widget.bundle ?? rootBundle;

  bool _loading = true;
  List<ResearchEntry> _entries = const [];
  List<String> _conditions = const [];
  String? _selectedCondition;
  String? _error;
  String? _expandedId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final entries = await loadResearchEntries(_bundle);
      final profile = await _backend.fetchProfile();
      final conditions = profile is Map<String, dynamic>
          ? TabsBackend.decodeProfileList(profile['conditions'])
              .map((c) => '${c['name'] ?? ''}'.trim())
              .where((n) => n.isNotEmpty)
              .toList()
          : <String>[];
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _conditions = conditions;
        // Native: default to the first saved condition.
        if (_selectedCondition == null ||
            !_conditions.contains(_selectedCondition)) {
          _selectedCondition =
              _conditions.isNotEmpty ? _conditions.first : null;
        }
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load your data. Check your connection and try again.';
        _loading = false;
      });
    }
  }

  List<ResearchEntry> get _visible =>
      entriesForCondition(_entries, _selectedCondition);

  Future<void> _openSource(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Silent on failure — the link is informational.
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
          icon: const Icon(Icons.arrow_back,
              color: NotelColors.textPrimary, semanticLabel: 'Back'),
          onPressed: widget.onBack ?? () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Research',
          style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary),
        ),
      ),
      body: Column(
        children: [
          _disclaimerBanner(),
          const SizedBox(height: 14),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _disclaimerBanner() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: NotelColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: NotelColors.warning.withValues(alpha: 0.4)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber, size: 20, color: NotelColors.warning),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              researchDisclaimer,
              style: TextStyle(
                  fontSize: 13,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                  color: NotelColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: NotelColors.primary));
    }
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [_errorBanner(_error!)],
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        if (_conditions.isEmpty)
          _noConditionsCard()
        else ...[
          _conditionSelector(),
          const SizedBox(height: 14),
          if (_visible.isEmpty)
            _nothingHereCard()
          else
            ..._visible.map(_entryCard),
        ],
      ],
    );
  }

  /// Native's `onNavigateToProfile`: opens the profile surface
  /// that owns the conditions editor (Settings → User Profile in
  /// this app). On return, conditions reload so additions apply
  /// immediately.
  Future<void> _goToConditions() async {
    await Navigator.of(context).push(
      SlidePageRoute<void>(
        reducedMotion: animationsDisabled(context),
        builder: (_) => SettingsScreen(backend: _backend),
      ),
    );
    if (!mounted) return;
    _backend.invalidateSyncPull();
    await _load();
  }

  Widget _noConditionsCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NotelColors.divider),
      ),
      child: Column(
        children: [
          const Icon(Icons.person_add,
              size: 40, color: NotelColors.primary),
          const SizedBox(height: 12),
          const Text('No conditions saved yet',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: NotelColors.textPrimary)),
          const SizedBox(height: 6),
          const Text(
            'Research is personalized to your conditions. Add them in Profile → Conditions to see relevant entries.',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 13, height: 1.4, color: NotelColors.textSecondary),
          ),
          const SizedBox(height: 14),
          ElevatedButton(
            onPressed: _goToConditions,
            style: ElevatedButton.styleFrom(
              backgroundColor: NotelColors.primary,
              foregroundColor: Colors.white,
            ),
            child: const Text('Go to Profile → Conditions',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _nothingHereCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NotelColors.divider),
      ),
      child: const Column(
        children: [
          Icon(Icons.science, size: 40, color: NotelColors.textSecondary),
          SizedBox(height: 12),
          Text('Nothing here yet',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: NotelColors.textPrimary)),
          SizedBox(height: 6),
          Text(
            'The founder adds new research as he finds it.',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 13, height: 1.4, color: NotelColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _conditionSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Your conditions',
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: NotelColors.textSecondary),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: NotelColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: NotelColors.divider),
          ),
          child: DropdownButton<String>(
            value: _selectedCondition,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            dropdownColor: NotelColors.surface,
            style: const TextStyle(
                fontSize: 14, color: NotelColors.textPrimary),
            items: [
              for (final c in _conditions)
                DropdownMenuItem(value: c, child: Text(c)),
            ],
            onChanged: (v) => setState(() {
              _selectedCondition = v;
              _expandedId = null;
            }),
          ),
        ),
      ],
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

  Widget _entryCard(ResearchEntry entry) {
    final expanded = _expandedId == entry.id;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () =>
            setState(() => _expandedId = expanded ? null : entry.id),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: NotelColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: NotelColors.divider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.title,
                          style: const TextStyle(
                              fontSize: 15,
                              height: 1.3,
                              fontWeight: FontWeight.bold,
                              color: NotelColors.textPrimary),
                        ),
                        const SizedBox(height: 8),
                        if (entry.takeaways.isNotEmpty)
                          ...entry.takeaways.map((t) => Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 3),
                                child: Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    const Text('•  ',
                                        style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.bold,
                                            color: NotelColors.primary)),
                                    Expanded(
                                      child: Text(t,
                                          style: const TextStyle(
                                              fontSize: 13,
                                              height: 1.4,
                                              color:
                                                  NotelColors.textPrimary)),
                                    ),
                                  ],
                                ),
                              ))
                        else if (entry.summary.isNotEmpty)
                          Text(entry.summary,
                              style: const TextStyle(
                                  fontSize: 13,
                                  height: 1.4,
                                  color: NotelColors.textSecondary)),
                      ],
                    ),
                  ),
                  Icon(
                      expanded
                          ? Icons.expand_less
                          : Icons.expand_more,
                      color: NotelColors.textSecondary),
                ],
              ),
              if (entry.sourceUrl.isNotEmpty) ...[
                const SizedBox(height: 4),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _openSource(entry.sourceUrl),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.open_in_new,
                            size: 12, color: NotelColors.textSecondary),
                        SizedBox(width: 4),
                        Text('Source',
                            style: TextStyle(
                                fontSize: 12,
                                color: NotelColors.textSecondary)),
                      ],
                    ),
                  ),
                ),
              ],
              if (expanded && entry.detail.isNotEmpty) ...[
                const Divider(color: NotelColors.divider),
                const SizedBox(height: 12),
                Text(entry.detail,
                    style: const TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: NotelColors.textPrimary)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
