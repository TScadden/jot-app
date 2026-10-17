import 'dart:async';

import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/onboarding_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_header.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 32 — port of native `ProfileSetupScreen.kt` (route
/// `profile_setup`), the personal-context step.
///
/// Native behavior (`ProfileSetupScreen.kt` + `ProfileSetupViewModel`):
/// - On entry the view model pulls the latest server data; the text
///   field pre-fills ONCE from the stored context when it arrives and
///   the field is still blank.
/// - The field collects the user's free-text context (goals, health
///   background) — the profile field `userContext`. "Next Step" is
///   enabled only at 10+ words; the feedback line and word counter
///   are native's exact strings/thresholds.
/// - Rotating placeholder prompts cycle every 3s (600ms fade out/in)
///   while the field is empty — native's seven prompts, verbatim.
/// - Saving writes the context locally and pushes it to the server
///   (`setUserContext` + sync → `POST /api/sync/profile` with
///   `userContext` — native `SyncManager.pushProfileData`).
///
/// Documents: native's optional upload feeds its on-device knowledge
/// ingestion pipeline (SettingsViewModel.ingestFile → Gemini). The
/// Flutter app has no equivalent pipeline (Round 29 flagged knowledge
/// ingestion as not-yet-available in the Lab), so the section keeps
/// native's presentation and the button explains that honestly
/// instead of silently dropping the files.
class ProfileSetupScreen extends StatefulWidget {
  final VoidCallback onBack;
  final VoidCallback onNavigateNext;
  final OnboardingStore? onboardingStore;
  final TabsBackend? backend;

  const ProfileSetupScreen({
    super.key,
    required this.onBack,
    required this.onNavigateNext,
    this.onboardingStore,
    this.backend,
  });

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  static const _placeholderPrompts = <String>[
    'I am training for a race and I want to focus on...',
    'I want to learn more about my health and why...',
    'I want to know why I am getting migraines and how...',
    'I want to track my symptoms and recovery after...',
    'I want to improve my sleep quality and daily energy...',
    'I am managing a chronic condition and want to track...',
    'I want to prepare detailed health summaries for my doctor...',
  ];

  late final OnboardingStore _store;
  late final TabsBackend _backend;
  final _controller = TextEditingController();
  int _promptIndex = 0;
  double _promptOpacity = 1;
  bool _promptLoopAlive = true;
  bool _saving = false;

  /// Native word count: trimmed split on whitespace, non-blank tokens.
  int get _wordCount {
    final text = _controller.text;
    if (text.trim().isEmpty) return 0;
    return text
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .length;
  }

  bool get _isReady => _wordCount >= 10 && !_saving;

  (String, Color) get _feedback {
    final count = _wordCount;
    return switch (count) {
      0 => ('Provide more context for better AI.', NotelColors.textSecondary),
      < 10 => (
          'Keep typing ($count/10 words min)...',
          const Color(0xFFFF9800)
        ),
      < 30 => ('Good start! Add more details.', NotelColors.primary),
      < 60 => (
          'More detail helps AI personalize results.',
          const Color(0xFF0288D1)
        ),
      < 100 => (
          'Great context! Almost at 100 words.',
          const Color(0xFF689F38)
        ),
      _ => ('Optimal AI context reached!', NotelColors.success),
    };
  }

  @override
  void initState() {
    super.initState();
    _store = widget.onboardingStore ?? OnboardingStore();
    _backend = widget.backend ?? TabsBackend();
    _controller.addListener(_onTextChanged);
    _prefill();
    unawaited(_runPromptLoop());
  }

  @override
  void dispose() {
    _promptLoopAlive = false;
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  /// Native pre-fill: stored context first, then the server's (the
  /// view model pulls on init) — each only lands while the field is
  /// still blank, exactly like native's LaunchedEffect(serverContext).
  Future<void> _prefill() async {
    try {
      final local = await _store.getUserContext();
      if (!mounted) return;
      if (_controller.text.isEmpty && local.isNotEmpty) {
        _controller.text = local;
      }
    } catch (_) {}
    try {
      final profile = await _backend.fetchProfile();
      if (!mounted) return;
      final server = profile?['userContext'];
      if (_controller.text.isEmpty && server is String && server.isNotEmpty) {
        _controller.text = server;
      }
    } catch (_) {}
  }

  /// Native prompt rotation: while the field is empty, wait 3s, fade
  /// out over 600ms, swap the prompt, fade back in over 600ms.
  Future<void> _runPromptLoop() async {
    while (_promptLoopAlive) {
      await Future<void>.delayed(const Duration(seconds: 3));
      if (!_promptLoopAlive || !mounted) return;
      if (_controller.text.isNotEmpty) continue;
      setState(() => _promptOpacity = 0);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (!_promptLoopAlive || !mounted) return;
      setState(() {
        _promptIndex = (_promptIndex + 1) % _placeholderPrompts.length;
        _promptOpacity = 1;
      });
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }
  }

  Future<void> _onNext() async {
    if (!_isReady) return;
    setState(() => _saving = true);
    final text = _controller.text;
    // Native saveProfileData: setUserContext locally, then sync (the
    // profile push carries userContext). The local write is what the
    // setup-loading finalize re-reads; the push is best-effort here
    // because finalize pushes the full onboarding profile again.
    try {
      await _store.setUserContext(text);
    } catch (_) {}
    try {
      await _backend.postSyncProfile({'userContext': text});
    } catch (_) {}
    if (!mounted) return;
    setState(() => _saving = false);
    widget.onNavigateNext();
  }

  Future<void> _showDocumentsUnavailable() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: NotelColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: const Text(
          'Upload Documents',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
        content: const Text(
          'Document upload is not available in this build yet. Your '
          'written context above is saved and used the same way.',
          style: TextStyle(color: NotelColors.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text(
              'OK',
              style: TextStyle(
                color: NotelColors.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final (feedbackText, feedbackColor) = _feedback;
    final count = _wordCount;
    final denominator = count > 100 ? count : 100;
    return Scaffold(
      backgroundColor: NotelColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OnboardingHeader(onBack: widget.onBack),
              ),
              const SizedBox(height: 12),
              // Orb + bubbles stage (native: 200dp, 120dp orb).
              SizedBox(
                width: double.infinity,
                height: 200,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            NotelColors.primary.withValues(alpha: 0.8),
                            const Color(0xFFA566FF).withValues(alpha: 0.5),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                    const Positioned(
                      top: 10,
                      left: 30,
                      child: _Bubble(
                        icon: Icons.medical_services,
                        color: NotelColors.info,
                      ),
                    ),
                    const Positioned(
                      top: 20,
                      right: 30,
                      child: _Bubble(
                        icon: Icons.favorite,
                        color: Color(0xFFEC4899),
                      ),
                    ),
                    const Positioned(
                      left: 10,
                      child: _Bubble(
                        icon: Icons.search,
                        color: Color(0xFFA855F7),
                      ),
                    ),
                    const Positioned(
                      right: 10,
                      child: _Bubble(
                        icon: Icons.psychology,
                        color: Color(0xFF8B5CF6),
                      ),
                    ),
                    const Positioned(
                      bottom: 10,
                      left: 40,
                      child: _Bubble(
                        icon: Icons.local_hospital,
                        color: Color(0xFF22C55E),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _controller,
                maxLines: 8,
                style: const TextStyle(
                  color: NotelColors.textPrimary,
                  fontSize: 14,
                ),
                cursorColor: NotelColors.primary,
                decoration: InputDecoration(
                  hintText: _placeholderPrompts[_promptIndex],
                  hintStyle: TextStyle(
                    color: NotelColors.textSecondary
                        .withValues(alpha: _promptOpacity),
                    fontSize: 14,
                  ),
                  enabledBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: NotelColors.textSecondary),
                  ),
                  focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: NotelColors.primary),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Expanded(
                      child: Text(
                        feedbackText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: feedbackColor, fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$count / $denominator words',
                      style: const TextStyle(
                        color: NotelColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              // Upload Documents (Optional) — native section, verbatim
              // labels; see the class doc for the availability note.
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Upload Documents (Optional)',
                    style: TextStyle(
                      color: NotelColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'PDF, images with text, text files, etc.',
                    style: TextStyle(
                      color: NotelColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 50,
                    child: FilledButton(
                      onPressed: _showDocumentsUnavailable,
                      style: FilledButton.styleFrom(
                        backgroundColor: NotelColors.surfaceHigh,
                        foregroundColor: NotelColors.textPrimary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.upload_file,
                            color: NotelColors.primary,
                            size: 20,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Add Documents',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 36),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: FilledButton(
                  onPressed: _isReady ? _onNext : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: NotelColors.primary,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor:
                        NotelColors.primary.withValues(alpha: 0.4),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : Text(
                          'Next Step',
                          style: TextStyle(
                            color: _isReady
                                ? Colors.white
                                : Colors.white.withValues(alpha: 0.6),
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

/// Native profile-setup `IconBubble`: 38dp variant of the intro's.
class _Bubble extends StatelessWidget {
  final IconData icon;
  final Color color;

  const _Bubble({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [color, color.withValues(alpha: 0.7)],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.6),
          width: 1.5,
        ),
      ),
      child: Icon(icon, color: Colors.white, size: 18),
    );
  }
}
