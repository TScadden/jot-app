import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/onboarding_store.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_header.dart';
import 'package:tabs_lab/src/features/tools/coach_mascot.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 32 — port of native `SetupLoadingScreen.kt` (route
/// `setup_loading`), the final onboarding step.
///
/// Native `SetupLoadingViewModel.finalizeSetup`:
/// 1. Reads the stored user context. When it is non-blank, asks the
///    server to generate tracking categories from it
///    (`POST /api/ai/generate-categories` `{userContext}` →
///    `{result: [names]}` — JotApi.kt:616-617); on any failure or an
///    empty context, falls back to Sleep / Energy / Mood / Diet /
///    Activity.
/// 2. Replaces the account's CUSTOM categories with up to 5 generated
///    ones (ids from 8 upward, native's color/icon cycles) — the
///    built-in default categories are never touched.
/// 3. Waits 2s, sets `onboarding_complete` true, pushes categories
///    and the profile, then shows "Your profile is all set up!" with
///    the "Start keeping Tabs" button.
///
/// Flutter mapping: categories are server-owned, so the generated
/// set is merged into the pulled list — existing rows (defaults and
/// any prior customs) are preserved in the payload because
/// `POST /api/sync/categories` is a full-list replace (see
/// [TabsBackend.postLogCategories]); previously generated onboarding
/// customs (isDefault == false with ids >= 8) are dropped first,
/// mirroring native's clearCustomCategories. The completion write is
/// the same pair native makes: local flag + profile push carrying
/// `onboardingComplete: true` alongside the onboarding-owned fields
/// (userContext, conditions) in native's payload shape.
///
/// Push failures do not trap the user here: the local flag is the
/// routing source of truth (as in native), and the server copy is
/// reconciled by later pulls/syncs. The step never fabricates a
/// finished state before the finalize work has actually run.
class SetupLoadingScreen extends StatefulWidget {
  final VoidCallback onNavigateMain;
  final OnboardingStore? onboardingStore;
  final TabsBackend? backend;

  const SetupLoadingScreen({
    super.key,
    required this.onNavigateMain,
    this.onboardingStore,
    this.backend,
  });

  @override
  State<SetupLoadingScreen> createState() => _SetupLoadingScreenState();
}

class _SetupLoadingScreenState extends State<SetupLoadingScreen> {
  /// Bandit's box on this screen: 84 tall, and the width the
  /// 438×512 master art (bandit_full.png / bandit_full_blink.png,
  /// same aspect) occupies at that height. The slot is reserved so
  /// the figure cannot pop in at zero width while its asset
  /// decodes — see the first-frame note in [build].
  static const double _banditHeight = 84;
  static const double _banditWidth = _banditHeight * 438 / 512;

  static const _fallbackCategories = <String>[
    'Sleep',
    'Energy',
    'Mood',
    'Diet',
    'Activity',
  ];
  static const _colors = <String>[
    '#FF6B6B',
    '#FFB347',
    '#6BCB77',
    '#4ECDC4',
    '#4D96FF',
    '#A566FF',
    '#FFD93D',
  ];
  static const _icons = <String>[
    'Favorite',
    'Restaurant',
    'MonitorWeight',
    'Medication',
    'EmojiEvents',
    'Bedtime',
    'Mood',
  ];

  late final OnboardingStore _store;
  late final TabsBackend _backend;
  bool _finished = false;
  int _dotCount = 1;
  Timer? _dotTimer;

  @override
  void initState() {
    super.initState();
    _store = widget.onboardingStore ?? OnboardingStore();
    _backend = widget.backend ?? TabsBackend();
    _dotTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted && !_finished) {
        setState(() => _dotCount = (_dotCount % 3) + 1);
      }
    });
    unawaited(_finalize());
  }

  @override
  void dispose() {
    _dotTimer?.cancel();
    super.dispose();
  }

  Future<void> _finalize() async {
    final started = DateTime.now();
    var userContext = '';
    try {
      userContext = await _store.getUserContext();
    } catch (_) {}

    // 1. Category names: server-generated from the context when
    // possible, native's fallback list otherwise.
    var names = _fallbackCategories;
    if (userContext.isNotEmpty) {
      try {
        final generated = await _backend.generateCategories(userContext);
        if (generated != null && generated.isNotEmpty) {
          names = generated;
        }
      } catch (_) {}
    }

    // 2. Merge into the server category list (full-list replace
    // endpoint — existing rows must ride along or they'd be deleted
    // server-side).
    try {
      final existing = await _backend.fetchLogCategories();
      final kept = existing
          .where((c) => c.isDefault || c.id < 8)
          .toList();
      final maxId = existing.fold<int>(0, (m, c) => math.max(m, c.id));
      var nextId = maxId < 7 ? 8 : maxId + 1;
      final merged = List<QuickLogCategory>.of(kept);
      final takenNames = merged.map((c) => c.name.toLowerCase()).toSet();
      var added = 0;
      for (final name in names) {
        if (added >= 5) break;
        if (takenNames.contains(name.toLowerCase())) continue;
        merged.add(QuickLogCategory(
          id: nextId++,
          name: name,
          icon: _icons[added % _icons.length],
          colorHex: _colors[added % _colors.length],
          isDefault: false,
          sortOrder: added,
        ));
        takenNames.add(name.toLowerCase());
        added++;
      }
      if (merged.length != existing.length || added > 0) {
        await _backend.postLogCategories(merged);
      }
    } catch (_) {}

    // 3. Native's 2s settle, then the completion writes.
    final elapsed = DateTime.now().difference(started);
    if (elapsed < const Duration(seconds: 2)) {
      await Future<void>.delayed(const Duration(seconds: 2) - elapsed);
    }
    try {
      await _store.setOnboardingComplete(true);
    } catch (_) {}
    try {
      var conditionsRaw = '[]';
      try {
        conditionsRaw = await _store.getUserConditionsRaw();
      } catch (_) {}
      await _backend.postSyncProfile({
        'userContext': userContext,
        'conditions': conditionsRaw,
        'onboardingComplete': true,
      });
    } catch (_) {}

    if (!mounted) return;
    setState(() => _finished = true);
  }

  @override
  Widget build(BuildContext context) {
    final dots = '.' * _dotCount;
    return Scaffold(
      backgroundColor: NotelColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          // First-frame layout (founder finding, Oct 28, 2026):
          // Scaffold hands its body LOOSE constraints, so a bare
          // Column sizes its width to its widest child — here the
          // title/status texts during loading (the status text even
          // wobbles as its ellipsis dots cycle) and the full-width
          // button once finalize completes. The under-wide column
          // hugged the left padding, drifted with the dots, and
          // snapped to true center when the button arrived. Pinning
          // the width makes the first painted frame the settled,
          // centered layout.
          child: SizedBox(
            width: double.infinity,
            child: Column(
              children: [
                const Spacer(),
                Container(
                  width: 180,
                  height: 180,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const RadialGradient(
                      colors: [
                        Color(0xFFE8D5FF),
                        Color(0xB37C6EFF),
                        NotelColors.primary,
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: NotelColors.primary.withValues(alpha: 0.5),
                        blurRadius: 24,
                      ),
                    ],
                  ),
                  child: Center(
                    child: Image.asset(
                      'assets/images/ic_tabs_note.png',
                      width: 110,
                      height: 110,
                    ),
                  ),
                ),
                const SizedBox(height: 48),
                const Text(
                  'Welcome to Tabs',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: NotelColors.primary,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  _finished
                      ? 'Your profile is all set up!'
                      : 'Getting your profile ready$dots',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: NotelColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 24),
                // Bandit, the app mascot, keeps the user company while
                // setup finishes — visual only, no copy changes. The
                // slot reserves the figure's exact box (see
                // [_banditWidth]) so it paints at its settled size on
                // the first frame instead of popping in at zero width
                // once the PNG decodes.
                const SizedBox(
                  width: _banditWidth,
                  height: _banditHeight,
                  child: CoachMascotFigure(height: _banditHeight),
                ),
                const Spacer(),
                if (_finished) ...[
                  OnboardingPrimaryButton(
                    label: 'Start keeping Tabs',
                    onPressed: widget.onNavigateMain,
                  ),
                  const SizedBox(height: 16),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
