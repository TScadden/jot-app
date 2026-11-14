import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tabs_lab/src/data/session_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/auth/auth_top_logo_header.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// VC 100134 Package C — email verification by code.
///
/// Shown as AppFlow's `_FlowStage.verifyEmail` stage (there is no
/// router in this app) when a register/login payload — or a stored
/// session at cold-start restore — carries an EXPLICIT
/// `emailVerified == false`. Built piece-for-piece from
/// [LoginScreen]'s card / button / error language, referencing
/// NotelColors tokens by name only.
///
/// ALL user-visible strings are Juno's, verbatim
/// (~/workspace/build-100134/juno-copy-privacy.md §2):
/// - title `Verify your email`
/// - instruction `We sent a code to {email}` (the account's own
///   email, shown back to its owner — §2.2 oracle check)
/// - helper, field label/hint, Verify / Resend labels, the
///   `Resend code in {m}:{ss}` cooldown shape, the sent
///   confirmation, and the error strings in §2.1.
/// Verify failures are ONE generic string for wrong, expired,
/// burned, and malformed alike — the server returns one generic
/// 400 and this screen never surfaces server strings for verify
/// failures, never shows attempts remaining, and adds no
/// shake/red-border inventions (the login error language is
/// text-only).
///
/// The ONE string without a verbatim Juno §2 slot is the escape
/// label: §2's table carries no sign-out string, so the button
/// uses `Sign out` — the term Juno's §5 gate position itself uses
/// for this affordance ("sign out (always available on the code
/// screen)"). Flagged in the build report for a Juno pass.
///
/// Verify/resend go through [TabsBackend] — the layer with the
/// 401→refresh wrapper — because the session already exists and a
/// user can sit on this screen past the access token's life.
class EmailVerificationScreen extends StatefulWidget {
  /// The pending account's own email, interpolated into Juno's
  /// instruction and resend-confirmation lines.
  final String email;

  /// Injectable for tests; defaults to a real backend bound to
  /// [sessionStore] (or a default store).
  final TabsBackend? backend;

  /// Injectable for tests; used only to construct the default
  /// backend.
  final SessionStore? sessionStore;

  /// Injectable clock for the resend countdown's deadline math;
  /// defaults to [DateTime.now]. Tests inject a fake clock because
  /// FakeAsync advances timers but not the wall clock.
  final DateTime Function()? now;

  /// Fires exactly once on a successful verify. The screen never
  /// navigates itself — AppFlow owns the stage change.
  final VoidCallback? onVerified;

  /// The escape: sign out and return to welcome (AppFlow's
  /// lightweight logout-to-welcome path). Wired to the in-card
  /// button, the header back arrow, and Android system back.
  final VoidCallback? onEscape;

  const EmailVerificationScreen({
    super.key,
    required this.email,
    this.backend,
    this.sessionStore,
    this.now,
    this.onVerified,
    this.onEscape,
  });

  @override
  State<EmailVerificationScreen> createState() =>
      _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen> {
  // Juno §2 / §2.1 — verbatim.
  static const _genericError =
      "That code didn't work. Check the code and try again, or resend a new code.";
  static const _networkError =
      'Network error. Please check your connection and try again.';
  static const _catchAllError = 'Something went wrong. Please try again.';

  static String _formatCountdown(int totalSeconds) {
    final m = totalSeconds ~/ 60;
    final ss = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$m:$ss';
  }

  final _codeController = TextEditingController();
  bool _isVerifying = false;
  bool _isResending = false;
  String? _errorMessage;
  String? _infoMessage;

  // Deadline-based resend cooldown (60s): the deadline is stored
  // and the remaining time computed per tick, so a backgrounded
  // app never returns showing time the server no longer requires.
  late DateTime _resendDeadline;
  int _resendRemainingSeconds = 60;
  Timer? _resendTimer;

  DateTime _now() => widget.now?.call() ?? DateTime.now();

  TabsBackend get _backend =>
      widget.backend ??
      TabsBackend(sessionStore: widget.sessionStore ?? SessionStore());

  @override
  void initState() {
    super.initState();
    _resendDeadline = _now().add(const Duration(seconds: 60));
    _startCooldownTimer();
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  void _startCooldownTimer() {
    _resendTimer?.cancel();
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final remaining = _resendDeadline.difference(_now()).inSeconds;
      setState(() => _resendRemainingSeconds = remaining < 0 ? 0 : remaining);
      if (_resendRemainingSeconds <= 0) _resendTimer?.cancel();
    });
  }

  void _restartCooldown(int seconds) {
    _resendDeadline = _now().add(Duration(seconds: seconds));
    setState(() => _resendRemainingSeconds = seconds);
    _startCooldownTimer();
  }

  Future<void> _onVerifyPressed() async {
    final code = _codeController.text;
    if (code.length != 6 || _isVerifying) return;
    setState(() {
      _isVerifying = true;
      _errorMessage = null;
      _infoMessage = null;
    });
    try {
      final outcome = await _backend.verifyEmailCode(code);
      if (!mounted) return;
      switch (outcome) {
        case VerifyEmailSuccess():
          setState(() => _isVerifying = false);
          widget.onVerified?.call();
        case VerifyEmailRejected():
          // One generic error for every rejection class; the field
          // clears so a stale wrong code can never be re-submitted
          // by a double-tap.
          setState(() {
            _isVerifying = false;
            _errorMessage = _genericError;
          });
          _codeController.clear();
        case VerifyEmailUnreachable():
          // Transport failure must not punish the user by erasing
          // a possibly-correct code — the field is kept.
          setState(() {
            _isVerifying = false;
            _errorMessage = _networkError;
          });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isVerifying = false;
        _errorMessage = _catchAllError;
      });
    }
  }

  Future<void> _onResendPressed() async {
    if (_resendRemainingSeconds > 0 || _isVerifying || _isResending) {
      return;
    }
    setState(() {
      _isResending = true;
      _errorMessage = null;
      _infoMessage = null;
    });
    try {
      final outcome = await _backend.resendVerificationCode();
      if (!mounted) return;
      switch (outcome) {
        case ResendVerificationSent():
          setState(() {
            _isResending = false;
            _infoMessage = 'A new code was sent to ${widget.email}';
          });
          _restartCooldown(60);
        case ResendVerificationCooldown(:final retryAfterSeconds):
          // The server's clock governs: adopt its remaining time.
          setState(() {
            _isResending = false;
            _errorMessage =
                'Please wait ${_formatCountdown(retryAfterSeconds)} before requesting another code.';
          });
          _restartCooldown(retryAfterSeconds);
        case ResendVerificationUnreachable():
          setState(() {
            _isResending = false;
            _errorMessage = _networkError;
          });
        case ResendVerificationFailed():
          setState(() {
            _isResending = false;
            _errorMessage = _catchAllError;
          });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isResending = false;
        _errorMessage = _catchAllError;
      });
    }
  }

  static const double _headerFootprint = 64.0;
  static const double _headerGap = 16.0;

  @override
  Widget build(BuildContext context) {
    // System back = the escape, exactly like LoginScreen's
    // PopScope precedent: this screen is a stage swap inside
    // AppFlow's single root route, so without interception the
    // gesture would exit the app while the session stays live.
    final onEscape = widget.onEscape;
    return PopScope(
      canPop: onEscape == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        onEscape?.call();
      },
      child: Scaffold(
        backgroundColor: NotelColors.background,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final double regionTop = _headerFootprint + _headerGap;
              final double regionMinHeight =
                  (constraints.maxHeight - regionTop - 32.0)
                      .clamp(0.0, double.infinity);
              return Stack(
                children: [
                  Padding(
                    padding: EdgeInsets.only(top: regionTop),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20.0, vertical: 16.0),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: regionMinHeight,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [_buildCard()],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20.0, vertical: 16.0),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8.0),
                        child: AuthTopLogoHeader(onBack: widget.onEscape),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildCard() {
    final codeComplete = _codeController.text.length == 6;
    final busy = _isVerifying || _isResending;
    return Container(
      key: const ValueKey('verify_card'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: NotelColors.cardBorder, width: 1),
        boxShadow: const [
          BoxShadow(
            // Same value as LoginScreen's card shadow literal,
            // referenced by token name here (legacyDarkScrim is
            // black @ 30%).
            color: NotelColors.legacyDarkScrim,
            blurRadius: 8,
            offset: Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Text(
            'Verify your email',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            'We sent a code to ${widget.email}',
            style: const TextStyle(
              fontSize: 14,
              color: NotelColors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text(
            "Enter the 6-digit code to finish creating your account. If you don't see the email, check your spam folder.",
            style: TextStyle(
              fontSize: 13,
              color: NotelColors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          TextField(
            key: const ValueKey('verify_code_field'),
            controller: _codeController,
            keyboardType: TextInputType.number,
            autofillHints: const [AutofillHints.oneTimeCode],
            autofocus: true,
            autocorrect: false,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: NotelColors.textPrimary,
              fontSize: 24,
              letterSpacing: 8,
            ),
            cursorColor: NotelColors.primary,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Verification code',
              hintText: '6-digit code',
              labelStyle:
                  const TextStyle(color: NotelColors.textSecondary),
              floatingLabelStyle:
                  const TextStyle(color: NotelColors.primary),
              hintStyle:
                  const TextStyle(color: NotelColors.textSecondary),
              filled: false,
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide:
                    const BorderSide(color: NotelColors.fieldBorderIdle),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide:
                    const BorderSide(color: NotelColors.primary),
              ),
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              key: const ValueKey('verify_submit'),
              onPressed:
                  (codeComplete && !_isVerifying) ? _onVerifyPressed : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: NotelColors.primary,
                foregroundColor: NotelColors.background,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 0,
              ),
              child: _isVerifying
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: NotelColors.background,
                      ),
                    )
                  : const Text(
                      'Verify',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 10),
            Text(
              _errorMessage!,
              key: const ValueKey('verify_error'),
              style: const TextStyle(
                fontSize: 13,
                color: NotelColors.error,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          if (_infoMessage != null) ...[
            const SizedBox(height: 10),
            Text(
              _infoMessage!,
              key: const ValueKey('verify_info'),
              style: const TextStyle(
                fontSize: 13,
                color: NotelColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 12),
          TextButton(
            key: const ValueKey('verify_resend'),
            onPressed:
                (_resendRemainingSeconds == 0 && !busy)
                    ? _onResendPressed
                    : null,
            child: Text(
              _resendRemainingSeconds > 0
                  ? 'Resend code in ${_formatCountdown(_resendRemainingSeconds)}'
                  : 'Resend code',
              style: const TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 13,
              ),
            ),
          ),
          TextButton(
            key: const ValueKey('verify_escape'),
            onPressed: busy ? null : widget.onEscape,
            child: const Text(
              'Sign out',
              style: TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
