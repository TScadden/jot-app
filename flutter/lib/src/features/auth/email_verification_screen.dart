import 'dart:async';
import 'dart:math' as math;

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
/// - helper, field label, Verify / Resend labels, the
///   `Resend code in {m}:{ss}` cooldown shape, the sent
///   confirmation, and the error strings in §2.1.
/// Verify failures are ONE generic string for wrong, expired,
/// burned, and malformed alike — the server returns one generic
/// 400 and this screen never surfaces server strings for verify
/// failures, never shows attempts remaining, and adds no
/// shake/red-border inventions (the login error language is
/// text-only).
///
/// Founder-directed change (Tyson, Nov 14, 2026, on the VC 100134
/// screen): "I don't want text in the box. Make it so each number
/// has its own box." The single code field is therefore six
/// individual digit boxes, each empty until filled, with NO text
/// or hint inside any box — the Juno §2 in-field hint
/// (`6-digit code`) is removed by this direction, and the
/// `Verification code` label now renders as a plain label ABOVE
/// the box row (there is no floating label). No other copy
/// changes; the label arrangement is flagged for Juno's micro
/// copy sign in the build report.
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

  static const int _codeLength = 6;

  static String _formatCountdown(int totalSeconds) {
    final m = totalSeconds ~/ 60;
    final ss = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$m:$ss';
  }

  // Six digit boxes: one controller + one focus node per box.
  final List<TextEditingController> _digitControllers =
      List<TextEditingController>.generate(
        _codeLength,
        (_) => TextEditingController(),
      );
  final List<FocusNode> _digitFocusNodes = List<FocusNode>.generate(
    _codeLength,
    (_) => FocusNode(),
  );

  // The digit each box held before the current edit, per box.
  // _onDigitChanged needs this snapshot: by the time it runs, the
  // box's controller already holds the NEW value, so the previous
  // digit cannot be read back from it — and distinguishing a
  // replace-on-type delivery (previous digit + one typed digit)
  // from a paste depends on knowing that previous digit. Kept in
  // sync by _setDigit, _clearAllDigits, the empty-value path, the
  // single-digit path, and the backspace key handler.
  final List<String> _previousDigits =
      List<String>.filled(_codeLength, '');

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

  /// The entered digits joined in box order.
  String get _enteredCode => _digitControllers.map((c) => c.text).join();

  bool get _codeComplete => _digitControllers.every((c) => c.text.length == 1);

  @override
  void initState() {
    super.initState();
    _resendDeadline = _now().add(const Duration(seconds: 60));
    _startCooldownTimer();
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    for (final controller in _digitControllers) {
      controller.dispose();
    }
    for (final node in _digitFocusNodes) {
      node.dispose();
    }
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

  void _setDigit(int index, String digit) {
    _previousDigits[index] = digit;
    _digitControllers[index].value = TextEditingValue(
      text: digit,
      selection: TextSelection.collapsed(offset: digit.length),
    );
  }

  void _clearAllDigits() {
    for (var i = 0; i < _codeLength; i++) {
      _previousDigits[i] = '';
      _digitControllers[i].clear();
    }
  }

  /// VC 100136 — auto-submit on a completed code (founder
  /// direction, Tyson, Nov 14, 2026: "It should do that. If it
  /// doesn't then fix it then push").
  ///
  /// Called at the end of every completion-capable path in
  /// [_onDigitChanged] — after that path's digits and focus have
  /// settled — so all three ways a code can become complete fire
  /// it: (a) a single digit typed into the last empty box, (b)
  /// replace-on-type in an already-complete code (which submits
  /// the corrected code), and (c) paste/autofill distribution
  /// that fills all six boxes. It invokes the SAME
  /// [_onVerifyPressed] the Verify button uses.
  ///
  /// Double-submit is impossible: [_onVerifyPressed] guards on
  /// `code.length != _codeLength || _isVerifying` and sets
  /// `_isVerifying = true` synchronously (before its first
  /// await), so a second invocation — from a further edit while
  /// a verify is in flight, or from the Verify button racing the
  /// auto-fire — returns immediately without a backend call.
  void _maybeAutoSubmit() {
    if (!_codeComplete) return;
    unawaited(_onVerifyPressed());
  }

  /// One box's text changed (typing, paste, or Android
  /// oneTimeCode autofill landing in that box).
  ///
  /// A single digit fills just its box and advances focus to the
  /// next box. A multi-digit string is distributed across boxes:
  /// a full 6-digit code fills all six boxes in order wherever it
  /// lands; a shorter multi-digit string fills forward from the
  /// box it landed in. An empty value (backspace on a filled box)
  /// simply clears that box — focus stays. The one exception to
  /// distribution is a 2-char delivery into an already-filled
  /// box (previous digit + one typed digit): that replaces this
  /// box's digit only — see the replace-on-type branch below.
  void _onDigitChanged(int index, String value) {
    final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) {
      _previousDigits[index] = '';
      setState(() {});
      return;
    }
    if (digits.length == 1) {
      // The box already holds the digit via its controller; make
      // sure it holds exactly that digit, then advance.
      if (_digitControllers[index].text != digits) {
        _setDigit(index, digits);
      } else {
        _previousDigits[index] = digits;
      }
      setState(() {});
      if (index < _codeLength - 1) {
        _digitFocusNodes[index + 1].requestFocus();
      }
      _maybeAutoSubmit();
      return;
    }
    if (digits.length == 2) {
      // Replace-on-type (Vera NO SIGN fix): a digit typed into an
      // already-FILLED box is delivered by the platform as a
      // 2-char value — the box's previous digit plus the typed
      // digit, appended (caret at end: '39') or prepended (caret
      // at start: '93'). That is NOT a paste: the typed digit
      // must REPLACE this box's digit only, then advance as a
      // normal single-digit entry. Distributing it forward (the
      // paste path below) silently overwrote the NEXT box's
      // digit, and in the last box the typed digit vanished.
      // Distinction from paste/autofill: exactly 2 chars, this
      // box previously held exactly one digit (the snapshot in
      // _previousDigits), and one of the two chars IS that
      // previous digit — the other char is the newly typed one.
      // A paste/autofill of >= 3 chars, and a 2-char delivery
      // into an EMPTY box, keep the distribution behaviour below.
      final previous = _previousDigits[index];
      if (previous.length == 1) {
        String? replacement;
        if (digits[0] == previous && digits[1] == previous) {
          replacement = digits[0];
        } else if (digits[0] == previous) {
          // Appended delivery: previous digit first, typed second.
          replacement = digits[1];
        } else if (digits[1] == previous) {
          // Prepended delivery: typed digit first, previous second.
          replacement = digits[0];
        }
        if (replacement != null) {
          _setDigit(index, replacement);
          setState(() {});
          if (index < _codeLength - 1) {
            _digitFocusNodes[index + 1].requestFocus();
          }
          _maybeAutoSubmit();
          return;
        }
      }
    }
    // Multi-digit input (paste / autofill).
    final start = digits.length >= _codeLength ? 0 : index;
    final count = math.min(digits.length, _codeLength - start);
    for (var i = 0; i < count; i++) {
      _setDigit(start + i, digits[i]);
    }
    // If this box was the start and the platform left the whole
    // string in it, the loop above already reduced it to its one
    // digit; any boxes past the distributed range are untouched.
    setState(() {});
    final next = math.min(start + count, _codeLength - 1);
    _digitFocusNodes[next].requestFocus();
    _maybeAutoSubmit();
  }

  /// Backspace on an EMPTY box deletes the previous box's digit
  /// and moves focus back to it (standard OTP behavior). Returns
  /// handled only for that case; every other key — including
  /// backspace on a filled box, which the field itself clears —
  /// is left to the field.
  KeyEventResult _onDigitBoxKeyEvent(int index, KeyEvent event) {
    if ((event is KeyDownEvent || event is KeyRepeatEvent) &&
        event.logicalKey == LogicalKeyboardKey.backspace &&
        _digitControllers[index].text.isEmpty &&
        index > 0) {
      setState(() {
        _previousDigits[index - 1] = '';
        _digitControllers[index - 1].clear();
      });
      _digitFocusNodes[index - 1].requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _onVerifyPressed() async {
    final code = _enteredCode;
    if (code.length != _codeLength || _isVerifying) return;
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
          // One generic error for every rejection class; all six
          // boxes clear so a stale wrong code can never be
          // re-submitted by a double-tap, and focus returns to
          // the first box.
          setState(() {
            _isVerifying = false;
            _errorMessage = _genericError;
            _clearAllDigits();
          });
          _digitFocusNodes[0].requestFocus();
        case VerifyEmailUnreachable():
          // Transport failure must not punish the user by erasing
          // a possibly-correct code — the digits are kept.
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

  Widget _buildDigitBox(int index) {
    return Focus(
      onKeyEvent: (_, event) => _onDigitBoxKeyEvent(index, event),
      child: SizedBox(
        height: 52,
        child: TextField(
          key: ValueKey('verify_digit_$index'),
          controller: _digitControllers[index],
          focusNode: _digitFocusNodes[index],
          keyboardType: TextInputType.number,
          autofillHints: index == 0
              ? const [AutofillHints.oneTimeCode]
              : const <String>[],
          autofocus: index == 0,
          autocorrect: false,
          enableSuggestions: false,
          textAlign: TextAlign.center,
          style: const TextStyle(color: NotelColors.textPrimary, fontSize: 24),
          cursorColor: NotelColors.primary,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (value) => _onDigitChanged(index, value),
          decoration: InputDecoration(
            // Founder direction: nothing inside the box — no
            // label, no hint, no placeholder. Only the entered
            // digit (or the caret when focused) renders here.
            filled: false,
            contentPadding: EdgeInsets.zero,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: NotelColors.fieldBorderIdle),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: NotelColors.primary),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCard() {
    final codeComplete = _codeComplete;
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
            style: TextStyle(fontSize: 13, color: NotelColors.textSecondary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Verification code',
              style: TextStyle(color: NotelColors.textSecondary),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            key: const ValueKey('verify_code_boxes'),
            children: [
              for (var i = 0; i < _codeLength; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: _buildDigitBox(i)),
              ],
            ],
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
