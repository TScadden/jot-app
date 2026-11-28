import 'dart:async';

import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/onboarding_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/voice_input.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_header.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Flow3 (Nov 19, 2026) — the Profile step. The old
/// consultation-intro interstitial is CUT; its heading "Let's get
/// you set up!" is this screen's heading.
///
/// Founder rulings implemented here:
/// - Real free-text box with the worked EXAMPLE as its placeholder
///   (verbatim below).
/// - Mic button in the box with hint "Tap the mic to talk", wired
///   to the app's existing dictation path ([VoiceInput] — the same
///   system-recognizer service Quick Log uses; no new dependency).
/// - Word counter as before (10-word minimum, /100 display).
/// - "You can also add documents from your doctors" + the existing
///   optional-upload affordance (same availability dialog as
///   before — the Flutter build has no ingestion pipeline yet).
/// - Explainer line: "Tabs builds your tracking categories from
///   what you write here, and your coach uses it from day one."
/// - NO skip: the header's trailing slot shows a muted,
///   non-interactive "Can't skip" label.
/// - Cheer Bandit over a soft purple radial glow above the
///   heading; the whole content block is vertically centered
///   between the bar and the pinned bottom button.
/// - The saved text flows to the same consumers as before:
///   [OnboardingStore.setUserContext] + the profile push
///   (`userContext`) that setup-loading finalize and the coach /
///   category generation read.
///
/// Deviation from the pre-flow3 screen, per the founder's mock:
/// the rotating placeholder prompts are replaced by the single
/// ruled example placeholder.
class ProfileSetupScreen extends StatefulWidget {
  final VoidCallback onBack;
  final VoidCallback onNavigateNext;
  final OnboardingStore? onboardingStore;
  final TabsBackend? backend;

  /// Injectable dictation service (tests); defaults to the real
  /// [VoiceInput] — the Quick Log mic path.
  final VoiceInput? voiceInput;

  /// Onboarding reorder (Nov 27, 2026) — pre-account phase: when
  /// true, this step is LOCAL ONLY (Juno ruling 3): no prefill
  /// fetch and no profile push may carry the user's text anywhere
  /// before an account exists. Default false = today's behavior.
  final bool deferServerSync;

  const ProfileSetupScreen({
    super.key,
    required this.onBack,
    required this.onNavigateNext,
    this.onboardingStore,
    this.backend,
    this.voiceInput,
    this.deferServerSync = false,
  });

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  /// The ruled example placeholder (flow3_03_profile_v9).
  static const examplePlaceholder =
      'Example: I have POTS and chronic migraines. Standing too '
      'long makes me dizzy, and I crash hard most afternoons. '
      'Heat makes everything worse. I want to figure out what '
      'triggers my bad days so I can plan around them.';

  late final OnboardingStore _store;
  late final TabsBackend _backend;
  final _controller = TextEditingController();
  bool _saving = false;
  bool _listening = false;

  VoiceInput get _voice => widget.voiceInput ?? VoiceInput();

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
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  /// Native pre-fill: stored context first, then the server's —
  /// each only lands while the field is still blank.
  Future<void> _prefill() async {
    try {
      final local = await _store.getUserContext();
      if (!mounted) return;
      if (_controller.text.isEmpty && local.isNotEmpty) {
        _controller.text = local;
      }
    } catch (_) {}
    // Pre-account: zero network — the server prefill fetch is
    // skipped entirely (Juno ruling 3, defer flag).
    if (widget.deferServerSync) return;
    try {
      final profile = await _backend.fetchProfile();
      if (!mounted) return;
      final server = profile?['userContext'];
      if (_controller.text.isEmpty && server is String && server.isNotEmpty) {
        _controller.text = server;
      }
    } catch (_) {}
  }

  /// Mic: the Quick Log dictation path — recognized text appends
  /// to the field exactly as typed text. Errors surface visibly
  /// (team rule: no silent channel failures).
  Future<void> _onMicTap() async {
    if (_listening) return;
    setState(() => _listening = true);
    try {
      final text = await _voice.startVoiceInput();
      final current = _controller.text.trim();
      _controller.text = current.isEmpty ? text : '$current $text';
    } on VoiceInputException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _listening = false);
    }
  }

  Future<void> _onNext() async {
    if (!_isReady) return;
    setState(() => _saving = true);
    final text = _controller.text;
    try {
      await _store.setUserContext(text);
    } catch (_) {}
    // Pre-account: local write only — no push (Juno ruling 3).
    if (!widget.deferServerSync) {
      try {
        await _backend.postSyncProfile({'userContext': text});
      } catch (_) {}
    }
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
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 8),
                // No skip on this step: muted "Can't skip" label in
                // the trailing slot (non-interactive).
                child: OnboardingHeader(
                  onBack: widget.onBack,
                  trailingLabel: "Can't skip",
                ),
              ),
              const SizedBox(height: 12),
              const OnboardingProgressBar(currentSegment: 2),
              // Content block vertically centered between the bar
              // and the pinned button.
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const SizedBox(height: 16),
                      // Cheer Bandit over a soft purple radial glow.
                      Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              NotelColors.primary.withValues(alpha: 0.35),
                              Colors.transparent,
                            ],
                          ),
                        ),
                        child: Image.asset(
                          'assets/images/bandit_cheer_cut_v3.png',
                          width: 110,
                          height: 110,
                          fit: BoxFit.contain,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        "Let's get you set up!",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: NotelColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Start by sharing your goals and why you are '
                        'using this app, so we can make sure the AI '
                        'knows how to best help you.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          color: NotelColors.textSecondary,
                          height: 20 / 14,
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Tell it like you would tell a new doctor.',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: NotelColors.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Container(
                        decoration: BoxDecoration(
                          color: NotelColors.surface,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: NotelColors.cardBorder),
                        ),
                        child: Column(
                          children: [
                            TextField(
                              controller: _controller,
                              maxLines: 5,
                              style: const TextStyle(
                                color: NotelColors.textPrimary,
                                fontSize: 14,
                              ),
                              cursorColor: NotelColors.primary,
                              decoration: const InputDecoration(
                                hintText: examplePlaceholder,
                                hintMaxLines: 8,
                                hintStyle: TextStyle(
                                  color: NotelColors.textSecondary,
                                  fontSize: 14,
                                  height: 20 / 14,
                                ),
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.all(16),
                              ),
                            ),
                            Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(12, 0, 16, 10),
                              child: Row(
                                children: [
                                  // Voice input has no iOS handler —
                                  // hide the mic AND its 'Tap the mic
                                  // to talk' label where
                                  // VoiceInput.isSupported is false
                                  // (Juno sweep A-S2).
                                  if (VoiceInput.isSupported) ...[
                                    IconButton(
                                      key:
                                          const ValueKey('profile_mic_button'),
                                      onPressed:
                                          _listening ? null : _onMicTap,
                                      icon: Icon(
                                        _listening
                                            ? Icons.mic
                                            : Icons.mic_none,
                                        color: NotelColors.primary,
                                      ),
                                    ),
                                    const Expanded(
                                      child: Text(
                                        'Tap the mic to talk',
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: NotelColors.textSecondary,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                  ],
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
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            feedbackText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                TextStyle(color: feedbackColor, fontSize: 12),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: _showDocumentsUnavailable,
                        child: const Text(
                          'You can also add documents from your doctors',
                          style: TextStyle(
                            color: NotelColors.primary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Tabs builds your tracking categories from '
                        'what you write here, and your coach uses it '
                        'from day one.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: NotelColors.textSecondary,
                          height: 19 / 13,
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.only(bottom: kOnboardingBottomPadding),
                child: SizedBox(
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
              ),
            ],
          ),
        ),
      ),
    );
  }
}
