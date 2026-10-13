import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/common_conditions.dart';
import 'package:tabs_lab/src/data/onboarding_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_header.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 32 — port of native `ConditionsScreen.kt` (route
/// `conditions`), the health-conditions step.
///
/// Native behavior:
/// - Header carries Back AND Skip (TopLogoHeader onSkip); both Skip
///   and "Next" advance to the notifications step — the step is
///   fully skippable with zero conditions selected.
/// - The catalog is `CommonConditionsList.list` (244 entries,
///   deduplicated + case-insensitively sorted) — ported verbatim in
///   `common_conditions.dart`.
/// - Tapping the search bar opens a full-screen search overlay
///   ("Search conditions" / "Search all conditions"); tapping a
///   result toggles it and closes the overlay. Matching is a
///   case-insensitive substring filter, as native.
/// - Selection persists through native's ConditionRepository:
///   local `user_conditions` (JSON array string) immediately, and a
///   profile push debounced 1.5s carrying `conditions` as that same
///   JSON string (`SyncManager.pushProfileData`). Server conditions
///   merge in on pull (local order first, server extras appended,
///   case-insensitive dedupe) — mirrored here on entry.
class OnboardingConditionsScreen extends StatefulWidget {
  final VoidCallback onBack;
  final VoidCallback onNavigateNext;
  final VoidCallback onSkip;
  final OnboardingStore? onboardingStore;
  final TabsBackend? backend;

  const OnboardingConditionsScreen({
    super.key,
    required this.onBack,
    required this.onNavigateNext,
    required this.onSkip,
    this.onboardingStore,
    this.backend,
  });

  @override
  State<OnboardingConditionsScreen> createState() =>
      _OnboardingConditionsScreenState();
}

class _OnboardingConditionsScreenState
    extends State<OnboardingConditionsScreen> {
  late final OnboardingStore _store;
  late final TabsBackend _backend;
  List<String> _selected = <String>[];
  bool _searching = false;
  String _query = '';
  Timer? _pushDebounce;

  List<String> get _filtered {
    if (_query.isEmpty) return commonConditions;
    final q = _query.toLowerCase();
    return commonConditions
        .where((c) => c.toLowerCase().contains(q))
        .toList();
  }

  bool _isSelected(String condition) =>
      _selected.any((s) => s.toLowerCase() == condition.toLowerCase());

  @override
  void initState() {
    super.initState();
    _store = widget.onboardingStore ?? OnboardingStore();
    _backend = widget.backend ?? TabsBackend();
    _load();
  }

  @override
  void dispose() {
    _pushDebounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final local = await _store.getConditions();
      if (!mounted) return;
      setState(() => _selected = List.of(local));
    } catch (_) {}
    // Native pull-merge: server conditions join the local selection
    // (local order preserved, no case-insensitive duplicates).
    try {
      final profile = await _backend.fetchProfile();
      if (!mounted) return;
      final raw = profile?['conditions'];
      if (raw == null) return;
      final serverNames = TabsBackend.decodeProfileList(raw)
          .map((m) => '${m['name'] ?? ''}')
          .where((n) => n.isNotEmpty)
          .toList();
      if (serverNames.isEmpty) return;
      final merged = List<String>.of(_selected);
      for (final name in serverNames) {
        if (!merged.any((s) => s.toLowerCase() == name.toLowerCase())) {
          merged.add(name);
        }
      }
      if (merged.length != _selected.length) {
        setState(() => _selected = merged);
        try {
          await _store.setConditions(merged);
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _toggle(String condition) async {
    final next = List<String>.of(_selected);
    if (_isSelected(condition)) {
      next.removeWhere((s) => s.toLowerCase() == condition.toLowerCase());
    } else {
      next.add(condition);
    }
    setState(() => _selected = next);
    try {
      await _store.setConditions(next);
    } catch (_) {}
    _schedulePush();
  }

  /// Native ConditionRepository debounce: 1.5s after the last edit,
  /// one profile push with the full conditions JSON string.
  void _schedulePush() {
    _pushDebounce?.cancel();
    _pushDebounce = Timer(const Duration(milliseconds: 1500), () {
      unawaited(_backend
          .postSyncProfile({'conditions': jsonEncode(_selected)}));
    });
  }

  Future<void> _onNext() async {
    // Flush any pending debounced push so the server holds the final
    // selection before the flow moves on (native's later syncs push
    // the same field; this only tightens the timing).
    _pushDebounce?.cancel();
    try {
      await _backend
          .postSyncProfile({'conditions': jsonEncode(_selected)});
    } catch (_) {}
    if (!mounted) return;
    widget.onNavigateNext();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      body: SafeArea(
        child: _searching ? _buildSearch() : _buildMain(),
      ),
    );
  }

  Widget _buildMain() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OnboardingHeader(
              onBack: widget.onBack,
              onSkip: widget.onSkip,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Add conditions',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: NotelColors.primary,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'This helps us personalize your experience by suggesting '
            'the most relevant symptoms to track.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: NotelColors.textSecondary,
              height: 20 / 14,
            ),
          ),
          const SizedBox(height: 20),
          Material(
            color: NotelColors.surface,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => setState(() => _searching = true),
              child: Container(
                height: 50,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: const Row(
                  children: [
                    Icon(Icons.search, color: NotelColors.primary, size: 20),
                    SizedBox(width: 12),
                    Text(
                      'Search conditions...',
                      style: TextStyle(
                        color: NotelColors.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Expanded(
            child: SingleChildScrollView(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: NotelColors.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: NotelColors.cardBorder),
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color:
                                NotelColors.primary.withValues(alpha: 0.2),
                          ),
                          child: const Icon(
                            Icons.medical_services,
                            color: NotelColors.primary,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Your conditions',
                                style: TextStyle(
                                  color: NotelColors.textPrimary,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                              Text(
                                'Diagnosed or suspected conditions.',
                                style: TextStyle(
                                  color: NotelColors.textSecondary,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (_selected.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 240),
                        child: SingleChildScrollView(
                          child: Column(
                            children: [
                              for (final condition in _selected)
                                Padding(
                                  padding:
                                      const EdgeInsets.only(bottom: 8),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      color: NotelColors.surfaceHigh
                                          .withValues(alpha: 0.4),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            condition,
                                            style: const TextStyle(
                                              color: NotelColors.textPrimary,
                                              fontSize: 14,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                        IconButton(
                                          onPressed: () => _toggle(condition),
                                          iconSize: 18,
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(
                                            minWidth: 24,
                                            minHeight: 24,
                                          ),
                                          icon: Icon(
                                            Icons.delete,
                                            color: NotelColors.error
                                                .withValues(alpha: 0.8),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          OnboardingPrimaryButton(label: 'Next', onPressed: _onNext),
        ],
      ),
    );
  }

  Widget _buildSearch() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              Material(
                color: NotelColors.surfaceHigh,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => setState(() => _searching = false),
                  child: const SizedBox(
                    width: 36,
                    height: 36,
                    child: Icon(
                      Icons.close,
                      color: NotelColors.textPrimary,
                      size: 20,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              const Text(
                'Search conditions',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: NotelColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            autofocus: true,
            style: const TextStyle(
              color: NotelColors.textPrimary,
              fontSize: 14,
            ),
            cursorColor: NotelColors.primary,
            decoration: InputDecoration(
              hintText: 'Search all conditions',
              hintStyle: const TextStyle(color: NotelColors.textSecondary),
              prefixIcon: const Icon(
                Icons.search,
                color: NotelColors.textSecondary,
              ),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      onPressed: () => setState(() => _query = ''),
                      icon: const Icon(
                        Icons.close,
                        color: NotelColors.textSecondary,
                      ),
                    ),
              enabledBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: NotelColors.textSecondary),
              ),
              focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: NotelColors.primary),
              ),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ListView.separated(
              itemCount: _filtered.length,
              separatorBuilder: (_, __) => Divider(
                color: NotelColors.surfaceHigh.withValues(alpha: 0.5),
                height: 1,
              ),
              itemBuilder: (context, index) {
                final condition = _filtered[index];
                final selected = _isSelected(condition);
                return InkWell(
                  onTap: () async {
                    await _toggle(condition);
                    if (!mounted) return;
                    setState(() => _searching = false);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 12,
                      horizontal: 8,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            condition,
                            style: const TextStyle(
                              fontSize: 14,
                              color: NotelColors.textPrimary,
                            ),
                          ),
                        ),
                        if (selected)
                          const Icon(
                            Icons.check,
                            color: NotelColors.primary,
                            size: 20,
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
