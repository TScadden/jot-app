import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:tabs_lab/src/data/apple_sign_in_service.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/google_sign_in_service.dart';
import 'package:tabs_lab/src/data/session_store.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/features/auth/auth_top_logo_header.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:url_launcher/url_launcher.dart';

/// Round 2 — login / register screen.
///
/// Pixel-port of the native app's `LoginScreen.kt` (`login?mode={mode}`
/// route, dark theme). Values taken straight from the Kotlin source:
/// - Scaffold background: NotelBackground #080E1A
/// - Card: 28dp radius, NotelSurface #0D1428, 8dp elevation,
///   1dp NotelPrimary @ 15% border, 24dp padding
/// - Title: 22sp Bold, NotelTextPrimary, centered
/// - Text fields: 14dp radius, label + leading icon, focused border
///   NotelPrimary, idle border NotelTextSecondary @ 40%
/// - Main button: full width, 50dp, 16dp radius, NotelPrimary fill,
///   16sp Bold label in NotelBackground
/// - Google button: NotelSurfaceHigh #152040 fill, 20dp logo,
///   15sp SemiBold NotelTextPrimary label
/// - Terms line: 8.5sp, centered below the card
///
/// Round 5 — REAL authentication (login mode only):
/// tapping "Log In" calls `POST https://api.jottracker.com/api/auth/login`
/// (see [AuthApiClient]) with the typed email + password. While the
/// request is in flight the button shows a spinner and is disabled.
/// On success the session (token + refresh token + email) is written to
/// secure storage and [onLoginSuccess] fires with the account email.
/// On failure an error line appears under the fields:
/// - credential failure (HTTP 401, unknown email or wrong password —
///   indistinguishable by design): "Email or password is incorrect."
/// - network/server problems: a generic message.
/// The password is never logged or stored — it lives in memory only for
/// the request duration.
///
/// "Sign Up" was a no-op in this round (implemented in Round 32);
/// "Send Reset Link" stayed a no-op until the audit GAP-2 fix below.
/// The login/register/forgot mode switch is live UI state, as is the
/// password-visibility toggle.
///
/// Audit GAP-2 fix — REAL password reset ("Send Reset Link"):
/// tapping the button in forgot-password mode calls
/// `AuthApiClient.forgotPassword` (`POST /api/auth/forgot-password`)
/// with the email in the (shared) email field, so an email typed on
/// the login form carries into the reset form. While the request is
/// in flight the shared loading state disables the button (no
/// double-submit). On success an inline confirmation shows — worded
/// so it is true whether or not the account exists
/// (anti-enumeration: the server answers identically either way,
/// and this screen never shows "account not found"). The emailed
/// link opens the server-hosted reset page where the user sets the
/// new password; from there the "Back to Log In" toggle returns
/// them here to log in. On failure the error line shows with the
/// button re-enabled, so tapping again is the retry. All
/// user-facing strings in this flow are DRAFT copy pending Juno's
/// ruling (see the PR description).
///
/// Round 24 — REAL Google sign-in (both modes): tapping the Google
/// button runs `GoogleSignInService.signInForIdToken()` (native
/// parity: sign-out first so the chooser always shows, then the
/// Credential Manager authentication call) and exchanges the ID
/// token via `AuthApiClient.googleLogin`. Register mode is gated on
/// the 13+ attestation first, with the native age-gate error, and
/// never launches sign-in without it. On success the session goes
/// through the EXACT same SessionStore + [onLoginSuccess] path as
/// password login. Cancellation is a quiet return with no error;
/// configuration-class failures show the Lab-build message below;
/// server rejections show the server's own message.
///
/// Round 32 — REAL registration ("Sign Up" button): native parity
/// with `LoginViewModel.register()` — blank-field guard, the 13+
/// age gate with the exact native block message, then
/// `AuthApiClient.register`. On success the session is stored the
/// same way as login, but [onRegisterSuccess] fires instead of
/// [onLoginSuccess]: a brand-new account has NOT completed
/// onboarding (native sets `onboardingCompleteByServer = false` for
/// register, `true` for login/Google), and AppFlow routes register
/// successes into the onboarding flow. Google sign-in keeps using
/// [onLoginSuccess] in both modes, exactly like native
/// (`loginWithGoogleAccount` marks onboarding complete).
///
/// Round 51 — Google sign-in also seeds the SettingsStore Google
/// Account connected flag + email, exactly like native
/// (`LoginScreen.kt` `loginWithGoogleAccount`: after
/// saveSessionAtomically, `setGoogleAccountConnected(true)` +
/// `setGoogleAccountEmail(email)`). The server links the Google
/// identity on this very call (`POST api/auth/google` sets
/// `users.google_connected`), and Settings' Connected Apps row
/// reads that local flag — without the seed, the row showed
/// "Connect Google Account" to users who sign in with Google.
/// The sync pull carries no Google state, so the flag seeded at
/// sign-in (and by the Settings link flow) is the only source —
/// native's design. Email/password login does NOT seed it
/// (native parity).
///
/// Sign in with Apple — the iOS mirror of Round 24: tapping the
/// Apple button runs `AppleSignInService.signInForCredential()` and
/// exchanges the identity token via `AuthApiClient.appleLogin`,
/// with the same register-mode 13+ gate, the same SessionStore +
/// [onLoginSuccess] success path (BOTH modes — never
/// [onRegisterSuccess], exactly like Google), quiet cancellation,
/// and verbatim server messages. The first-authorization name parts
/// ride along in register mode only (the server contract's
/// `fullName`). The button itself is the package's
/// `SignInWithAppleButton` (black, Apple logo) and builds ONLY on
/// iOS — see [_LoginScreenState._isApplePlatform]. A successful
/// Apple sign-in also seeds the SettingsStore Apple Account
/// connected flag + email, mirroring the Round 51 Google seed.
///
/// [initialRegisterMode] mirrors the native `mode` query arg: `true`
/// starts on "Create Your Account", `false` on "Welcome Back".
/// [onBack] pops to the welcome screen (native back button).
/// [onLoginSuccess] fires with the account email after a real login.
/// VC 100134 — the payload every auth success callback carries:
/// the account email plus its email-verification state (only an
/// explicit server `false` is unverified; see
/// [LoginSuccess.emailVerified]). AppFlow routes on the flag.
typedef AuthSuccess = ({String email, bool emailVerified});

class LoginScreen extends StatefulWidget {
  final bool initialRegisterMode;
  final VoidCallback? onBack;
  final ValueChanged<AuthSuccess>? onLoginSuccess;

  /// Round 32 — fires with the account email after a real
  /// email+password REGISTRATION (see the class doc). Falls back to
  /// [onLoginSuccess] when unset so older call sites keep working.
  final ValueChanged<AuthSuccess>? onRegisterSuccess;

  /// Injectable for tests; defaults to the real backend client.
  final AuthApiClient? authApi;

  /// Injectable for tests; defaults to flutter_secure_storage.
  final SessionStore? sessionStore;

  /// Injectable for tests; defaults to the real Google sign-in
  /// service (Round 24).
  final GoogleSignInService? googleSignInService;

  /// Injectable for tests; defaults to the real Apple sign-in
  /// service (Sign in with Apple).
  final AppleSignInService? appleSignInService;

  /// Injectable for tests (Round 51 Google-account flag seeding);
  /// defaults to the real on-device settings store.
  final SettingsStore? settingsStore;

  const LoginScreen({
    super.key,
    this.initialRegisterMode = true,
    this.onBack,
    this.onLoginSuccess,
    this.onRegisterSuccess,
    this.authApi,
    this.sessionStore,
    this.googleSignInService,
    this.appleSignInService,
    this.settingsStore,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  // Native default: initialMode = "register".
  late bool _isRegisterMode = widget.initialRegisterMode;
  bool _isForgotPasswordMode = false;
  bool _passwordVisible = false;
  bool _ageConfirmed = false;

  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _emailFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();
  bool _isLoading = false;
  String? _errorMessage;

  /// Audit GAP-2 fix — true once a reset request has been accepted
  /// in forgot-password mode. Drives the inline confirmation under
  /// the button; reset whenever the mode changes or a new request
  /// starts, so a stale confirmation can never sit over a new form.
  bool _resetSent = false;

  /// Wave A (SCORECARD-3 #7): the blur-validation message, kept as a
  /// constant so the focus-loss check can recognise (and clear) its
  /// own error without ever wiping a server or submit-time error.
  static const String _blurEmailError =
      'Please enter a valid email address.';

  @override
  void initState() {
    super.initState();
    _emailFocusNode.addListener(_onEmailFocusChange);
  }

  /// Blur validation (SCORECARD-3 #7): when the email field loses
  /// focus holding a non-empty value that is not shaped like an
  /// email address, flag it on the existing inline error line right
  /// away instead of waiting for a server round-trip. A later blur
  /// with a well-formed address clears only this check's own error;
  /// every submit-time check stays in place as the backstop.
  void _onEmailFocusChange() {
    if (_emailFocusNode.hasFocus || !mounted) return;
    final email = _emailController.text.trim();
    if (email.isEmpty) return;
    if (!_isPlausibleEmail(email)) {
      if (_errorMessage != _blurEmailError) {
        setState(() => _errorMessage = _blurEmailError);
      }
    } else if (_errorMessage == _blurEmailError) {
      setState(() => _errorMessage = null);
    }
  }

  /// Deliberately basic shape check for blur feedback only (one `@`,
  /// a dotted domain, no spaces) — the server remains the authority
  /// on whether an address is real.
  static bool _isPlausibleEmail(String email) {
    if (email.contains(' ')) return false;
    final at = email.indexOf('@');
    if (at <= 0 || at != email.lastIndexOf('@')) return false;
    final domain = email.substring(at + 1);
    return domain.contains('.') &&
        !domain.startsWith('.') &&
        !domain.endsWith('.');
  }

  @override
  void dispose() {
    _emailFocusNode.removeListener(_onEmailFocusChange);
    _emailController.dispose();
    _passwordController.dispose();
    _emailFocusNode.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  /// Video-lessons Wave A (SCORECARD-3 #5): the one submit dispatch
  /// shared by the main button and the password field's keyboard
  /// submit (Enter / Done), so both paths run the exact same mode
  /// logic. The handlers themselves carry the `_isLoading` entry
  /// guards, so a keyboard submit cannot double-fire while a request
  /// is in flight.
  void _submitFromKeyboard() {
    if (_isForgotPasswordMode) {
      _onForgotPasswordPressed();
    } else if (_isRegisterMode) {
      _onRegisterPressed();
    } else {
      _onLoginPressed();
    }
  }

  /// Round 5: real login. Mirrors the native `LoginViewModel.login()`
  /// flow: blank-field guard, loading state, API call, then either
  /// session persistence + [LoginScreen.onLoginSuccess] or an inline
  /// error message.
  Future<void> _onLoginPressed() async {
    // Wave A prerequisite (SCORECARD-3 #1/#5): the keyboard submit
    // path calls this directly, bypassing the button's disabled
    // state — the entry guard is what stops a double submit.
    if (_isLoading) return;
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _errorMessage = 'Please fill in all fields');
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final api = widget.authApi ?? AuthApiClient();
      final result = await api.login(email: email, password: password);
      if (!mounted) return;
      switch (result) {
        case LoginSuccess(:final token, :final refreshToken):
          final store = widget.sessionStore ?? SessionStore();
          await store.saveSession(
            token: token,
            refreshToken: refreshToken,
            email: result.email,
            emailVerified: result.emailVerified,
            userId: result.userId,
          );
          if (!mounted) return;
          setState(() => _isLoading = false);
          widget.onLoginSuccess?.call(
            (email: result.email, emailVerified: result.emailVerified),
          );
        case LoginFailure(:final message):
          setState(() {
            _isLoading = false;
            _errorMessage = message;
          });
      }
    } catch (_) {
      // The API client already maps transport failures; this is a
      // last-resort guard so the button can never wedge loading.
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Something went wrong. Please try again.';
      });
    }
  }

  /// Audit GAP-2 fix: real password-reset request. Blank email →
  /// an inline prompt and NO request (native parity:
  /// `LoginViewModel.forgotPassword`). Otherwise the shared
  /// loading state runs (button disabled + spinner, so a second
  /// tap cannot double-submit), then either the anti-enumeration
  /// confirmation ([_resetSent]) or Juno's fixed failure line on the
  /// error line with the button re-enabled for retry. The server's
  /// own error message is never shown in reset mode (Juno ruling,
  /// audit-fixes package JUNO-COPY.md, Nov 26, 2026).
  Future<void> _onForgotPasswordPressed() async {
    if (_isLoading) return;
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(() {
        _resetSent = false;
        _errorMessage = 'Please enter your email first.';
      });
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _resetSent = false;
    });
    try {
      final api = widget.authApi ?? AuthApiClient();
      final result = await api.forgotPassword(email: email);
      if (!mounted) return;
      switch (result) {
        case ForgotPasswordSuccess():
          setState(() {
            _isLoading = false;
            _resetSent = true;
          });
        case ForgotPasswordFailure():
          setState(() {
            _isLoading = false;
            _errorMessage =
                "Couldn't send that right now. Check your connection and try again in a bit.";
          });
      }
    } catch (_) {
      // The API client already maps transport failures; this is a
      // last-resort guard so the button can never wedge loading.
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage =
            "Couldn't send that right now. Check your connection and try again in a bit.";
      });
    }
  }

  /// Round 32: real registration. Mirrors native
  /// `LoginViewModel.register()` + the Sign Up button handler
  /// (`LoginScreen.kt:546-554`): blank fields → "Please fill in all
  /// fields"; register mode without the 13+ attestation → the exact
  /// native age-gate block message and NO request; otherwise the
  /// register call. Success stores the session exactly like login,
  /// then fires [LoginScreen.onRegisterSuccess] (onboarding entry —
  /// see the class doc).
  Future<void> _onRegisterPressed() async {
    // Wave A prerequisite (SCORECARD-3 #1/#5): same keyboard-submit
    // entry guard as [_onLoginPressed].
    if (_isLoading) return;
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _errorMessage = 'Please fill in all fields');
      return;
    }
    if (!_ageConfirmed) {
      setState(() => _errorMessage =
          'Tabs is for people 13 and older. You cannot create an account yet.');
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final api = widget.authApi ?? AuthApiClient();
      final result = await api.register(
        email: email,
        password: password,
        ageConfirmed: _ageConfirmed,
      );
      if (!mounted) return;
      switch (result) {
        case LoginSuccess success:
          final store = widget.sessionStore ?? SessionStore();
          await store.saveSession(
            token: success.token,
            refreshToken: success.refreshToken,
            email: success.email,
            emailVerified: success.emailVerified,
            userId: success.userId,
          );
          if (!mounted) return;
          setState(() => _isLoading = false);
          (widget.onRegisterSuccess ?? widget.onLoginSuccess)?.call(
            (email: success.email, emailVerified: success.emailVerified),
          );
        case LoginFailure(:final message):
          setState(() {
            _isLoading = false;
            _errorMessage = message;
          });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Something went wrong. Please try again.';
      });
    }
  }

  /// Round 24: real Google sign-in. Mirrors the native flow
  /// (`LoginScreen.kt`): register mode requires the 13+
  /// attestation before sign-in is even launched, with the exact
  /// native age-gate error; otherwise the ID token comes from
  /// [GoogleSignInService] and is exchanged via
  /// `AuthApiClient.googleLogin`. Success takes the exact same
  /// downstream path as [_onLoginPressed] — SessionStore, then
  /// [LoginScreen.onLoginSuccess] with the account email.
  Future<void> _onGooglePressed() async {
    if (_isLoading) return;
    if (_isRegisterMode && !_ageConfirmed) {
      setState(() => _errorMessage =
          'Tabs is for people 13 and older. You cannot create an account yet.');
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final service = widget.googleSignInService ?? GoogleSignInService();
      final idToken = await service.signInForIdToken();
      if (!mounted) return;
      final api = widget.authApi ?? AuthApiClient();
      final result = await api.googleLogin(
        idToken: idToken,
        isRegisterMode: _isRegisterMode,
        ageConfirmed: _ageConfirmed,
      );
      if (!mounted) return;
      switch (result) {
        case LoginSuccess(:final token, :final refreshToken):
          final store = widget.sessionStore ?? SessionStore();
          await store.saveSession(
            token: token,
            refreshToken: refreshToken,
            email: result.email,
            // VC 100134 — Google is verified by definition: force
            // true here regardless of payload, so the Google path
            // can never land on the code screen (client invariant).
            emailVerified: true,
            userId: result.userId,
          );
          // Round 51 — native parity (LoginScreen.kt:220-221):
          // seed the Google Account connection state Settings'
          // Connected Apps row reads. Best-effort and NOT awaited:
          // a storage failure (or slowness) here must never fail
          // or delay a successful sign-in — the seed is queued on
          // the store and lands within milliseconds, long before
          // the user can reach Settings.
          final settings = widget.settingsStore ?? SettingsStore();
          unawaited(() async {
            try {
              await settings.setGoogleAccountConnected(true);
              await settings.setGoogleAccountEmail(result.email);
            } catch (_) {}
          }());
          if (!mounted) return;
          setState(() => _isLoading = false);
          widget.onLoginSuccess
              ?.call((email: result.email, emailVerified: true));
        case LoginFailure(:final message):
          setState(() {
            _isLoading = false;
            _errorMessage = message;
          });
      }
    } on GoogleSignInOutcome catch (outcome) {
      if (!mounted) return;
      switch (outcome.kind) {
        case GoogleSignInOutcomeKind.cancelled:
          // Quiet return: the user dismissed the chooser, so no
          // error is shown.
          setState(() => _isLoading = false);
        case GoogleSignInOutcomeKind.unavailable:
          // Configuration-class failure (Juno N3): exact Lab-build
          // message, never raw plugin exception text.
          setState(() {
            _isLoading = false;
            _errorMessage =
                "Google sign-in isn't available in this Lab build yet.";
          });
        case GoogleSignInOutcomeKind.failed:
          setState(() {
            _isLoading = false;
            _errorMessage = outcome.message;
          });
      }
    } catch (_) {
      // Last-resort guard so the button can never wedge loading.
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Something went wrong. Please try again.';
      });
    }
  }

  /// Sign in with Apple: a deliberate mirror of [_onGooglePressed].
  /// Register mode requires the 13+ attestation before sign-in is
  /// even launched, with the exact same age-gate error; otherwise
  /// the credential comes from [AppleSignInService] and is exchanged
  /// via `AuthApiClient.appleLogin` (the first-authorization name
  /// parts ride along; the API layer sends them only in register
  /// mode). Success takes the exact same downstream path as Google —
  /// SessionStore, then [LoginScreen.onLoginSuccess] in BOTH modes.
  Future<void> _onApplePressed() async {
    if (_isLoading) return;
    if (_isRegisterMode && !_ageConfirmed) {
      setState(() => _errorMessage =
          'Tabs is for people 13 and older. You cannot create an account yet.');
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final service = widget.appleSignInService ?? AppleSignInService();
      final credential = await service.signInForCredential();
      if (!mounted) return;
      final api = widget.authApi ?? AuthApiClient();
      final result = await api.appleLogin(
        idToken: credential.idToken,
        isRegisterMode: _isRegisterMode,
        ageConfirmed: _ageConfirmed,
        givenName: credential.givenName,
        familyName: credential.familyName,
      );
      if (!mounted) return;
      switch (result) {
        case LoginSuccess(:final token, :final refreshToken):
          final store = widget.sessionStore ?? SessionStore();
          await store.saveSession(
            token: token,
            refreshToken: refreshToken,
            email: result.email,
            // Apple is verified by definition, exactly like Google:
            // force true so this path can never land on the code
            // screen (client invariant).
            emailVerified: true,
            userId: result.userId,
          );
          // Round 51 parity: seed the Apple Account connection
          // state Settings' Connected Apps row reads (the server
          // links the Apple identity on this very call). Best-effort
          // and NOT awaited, exactly like the Google seed.
          final settings = widget.settingsStore ?? SettingsStore();
          unawaited(() async {
            try {
              await settings.setAppleAccountConnected(true);
              await settings.setAppleAccountEmail(result.email);
            } catch (_) {}
          }());
          if (!mounted) return;
          setState(() => _isLoading = false);
          widget.onLoginSuccess
              ?.call((email: result.email, emailVerified: true));
        case LoginFailure(:final message):
          setState(() {
            _isLoading = false;
            _errorMessage = message;
          });
      }
    } on AppleSignInOutcome catch (outcome) {
      if (!mounted) return;
      switch (outcome.kind) {
        case AppleSignInOutcomeKind.cancelled:
          // Quiet return: the user dismissed the sheet, so no
          // error is shown.
          setState(() => _isLoading = false);
        case AppleSignInOutcomeKind.unavailable:
        case AppleSignInOutcomeKind.failed:
          setState(() {
            _isLoading = false;
            _errorMessage = outcome.message;
          });
      }
    } catch (_) {
      // Last-resort guard so the button can never wedge loading.
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Something went wrong. Please try again.';
      });
    }
  }

  /// Total vertical footprint of the pinned logo header: the outer
  /// vertical padding (16) + the extra top padding (8) + the header
  /// itself (40). Keep in sync with the header Padding widgets below.
  static const double _headerFootprint = 64.0;

  /// Breathing room between the pinned header and the card's scroll
  /// region. The scroll region starts at _headerFootprint + _headerGap,
  /// so card content can never slide under the header, in any viewport
  /// configuration (keyboard open or closed).
  static const double _headerGap = 16.0;

  /// Breathing room between the pinned header and the card's scroll
  /// region. The scroll region starts at _headerFootprint + _headerGap,
  /// so card content can never slide under the header, in any viewport
  /// configuration (keyboard open or closed).

  String get _title => _isForgotPasswordMode
      ? 'Reset Password'
      : _isRegisterMode
          ? 'Create Your Account'
          : 'Welcome Back';

  String get _mainButtonLabel => _isForgotPasswordMode
      ? 'Send Reset Link'
      : _isRegisterMode
          ? 'Sign Up'
          : 'Log In';

  String get _toggleLabel => _isForgotPasswordMode
      ? 'Back to Log In'
      : _isRegisterMode
          ? 'Already have an account? Log In'
          : "Don't have an account? Sign Up";

  String get _googleButtonLabel =>
      _isRegisterMode ? 'Continue with Google' : 'Log in with Google';

  String get _appleButtonLabel =>
      _isRegisterMode ? 'Sign up with Apple' : 'Sign in with Apple';

  /// Platform gate for the Apple button: Sign in with Apple is an
  /// iOS flow in this app, so the button must never build on
  /// non-iOS. Reads [defaultTargetPlatform] — the overridable
  /// platform check — so widget tests exercise both branches via
  /// `debugDefaultTargetPlatformOverride` (iOS shows the button;
  /// the default Android test platform does not, which is the
  /// Android-parity evidence for the existing login tests).
  bool get _isApplePlatform => defaultTargetPlatform == TargetPlatform.iOS;

  void _onToggleMode() {
    setState(() {
      _errorMessage = null;
      _resetSent = false;
      if (_isForgotPasswordMode) {
        _isForgotPasswordMode = false;
      } else {
        _isRegisterMode = !_isRegisterMode;
        _ageConfirmed = false; // reset the 13+ attestation when switching modes
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // System-back parity with the header back arrow (founder fix,
    // Oct 27, 2026): in the pre-shell flow this screen is a stage
    // swap inside AppFlow's single root route (see main.dart's
    // _FlowStage machine), so without interception the Navigator
    // has nothing to pop on Android back and the gesture exits the
    // app — while the arrow returns to the welcome stage via
    // [onBack]. Intercept whenever an [onBack] is wired and run
    // that SAME callback, in every mode (register, login, forgot
    // password — the arrow goes to welcome from all three).
    // Standalone uses with no [onBack] keep the default pop.
    final onBack = widget.onBack;
    return PopScope(
      canPop: onBack == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        onBack?.call();
      },
      child: Scaffold(
      backgroundColor: NotelColors.background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // The card's scroll region starts below the pinned header and
            // can never slide under it. When the keyboard shrinks the
            // viewport, this whole region shrinks with it and the card
            // scrolls internally.
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
                        children: [
                          _buildCard(),
                          const SizedBox(height: 10),
                          _buildTermsLine(),
                        ],
                      ),
                    ),
                  ),
                ),
                // Logo header — pinned to the top.
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20.0, vertical: 16.0),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: AuthTopLogoHeader(onBack: widget.onBack),
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
    return Container(
      key: const ValueKey('login_card'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: NotelColors.cardBorder, width: 1),
        boxShadow: const [
          BoxShadow(
            color: Color(0x4D000000),
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
          Text(
            _title,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          // 13+ attestation (sign-up form only).
          if (_isRegisterMode && !_isForgotPasswordMode) ...[
            GestureDetector(
              onTap: () =>
                  setState(() => _ageConfirmed = !_ageConfirmed),
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  Checkbox(
                    value: _ageConfirmed,
                    onChanged: (v) =>
                        setState(() => _ageConfirmed = v ?? false),
                    activeColor: NotelColors.primary,
                    checkColor: NotelColors.background,
                    side: BorderSide(
                      color: NotelColors.checkboxBorderIdle,
                      width: 2,
                    ),
                    materialTapTargetSize:
                        MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  const Text(
                    'I confirm I am 13 or older.',
                    style: TextStyle(
                      fontSize: 13,
                      color: NotelColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
          ],
          // Forgot-password explainer (copy ruled by Juno,
          // audit-fixes JUNO-COPY.md): what happens next, in one
          // plain line above the email
          // field (which keeps whatever email was typed on the
          // login form — the controller is shared across modes).
          if (_isForgotPasswordMode) ...[
            const Text(
              "Enter your email. If there's an account for it, we'll send you a link to set a new password.",
              style: TextStyle(
                fontSize: 13,
                color: NotelColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
          ],
          _buildEmailField(),
          const SizedBox(height: 14),
          if (!_isForgotPasswordMode) ...[
            _buildPasswordField(),
            const SizedBox(height: 8),
          ],
          // Forgot-password link (login mode only), right aligned.
          if (!_isRegisterMode && !_isForgotPasswordMode)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(() {
                  _isForgotPasswordMode = true;
                  _errorMessage = null;
                  _resetSent = false;
                }),
                style: TextButton.styleFrom(
                  // Wave A (SCORECARD-3 #2 / SCORECARD-9 #13): 48dp
                  // hit box, visual text unchanged — the glyph, its
                  // size and its colour are exactly as before; only
                  // the tappable area grows to the 48dp floor.
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(48, 48),
                ),
                child: const Text(
                  'Forgot Password?',
                  style: TextStyle(
                    color: NotelColors.primary,
                    fontSize: 13,
                  ),
                ),
              ),
            )
          else
            const SizedBox(height: 8),
          // Main action button. "Log In" (login mode) performs the real
          // login (Round 5); "Sign Up" (register mode) performs the
          // real registration (Round 32); "Send Reset Link"
          // (forgot-password mode) performs the real reset request
          // (audit GAP-2 fix). Disabled with a spinner while any of
          // them is in flight, so none can double-submit.
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: _isLoading ? null : _submitFromKeyboard,
              style: ElevatedButton.styleFrom(
                backgroundColor: NotelColors.primary,
                foregroundColor: NotelColors.background,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 0,
              ),
              child: _isLoading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: NotelColors.defaultBackground,
                      ),
                    )
                  : Text(
                      _mainButtonLabel,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ),
          // Reset confirmation (audit GAP-2 fix, DRAFT copy pending
          // Juno): shown after an accepted reset request. The
          // wording is deliberately conditional — it is identical
          // whether or not the email has an account
          // (anti-enumeration), and the path back is the
          // "Back to Log In" toggle directly below.
          if (_isForgotPasswordMode && _resetSent) ...[
            const SizedBox(height: 10),
            const Text(
              "If there's an account for that email, a reset link is on its way. Check your inbox, open the link to set your new password, then come back and log in with your new password.",
              key: ValueKey('forgot_password_success'),
              style: TextStyle(
                fontSize: 13,
                color: NotelColors.success,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          // Inline auth error (Round 5): credential failure / network.
          // Cleared on mode switch and on each new attempt.
          if (_errorMessage != null) ...[
            const SizedBox(height: 10),
            Text(
              _errorMessage!,
              key: const ValueKey('login_error'),
              style: const TextStyle(
                fontSize: 13,
                color: NotelColors.error,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 12),
          TextButton(
            onPressed: _onToggleMode,
            child: Text(
              _toggleLabel,
              style: const TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Divider(color: NotelColors.divider, thickness: 1),
              ),
              const Text(
                '  or  ',
                style: TextStyle(
                  fontSize: 12,
                  color: NotelColors.textSecondary,
                ),
              ),
              Expanded(
                child: Divider(color: NotelColors.divider, thickness: 1),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Google button (Round 24: real sign-in; disabled while
          // any auth attempt is in flight so it cannot double-fire).
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: _isLoading ? null : _onGooglePressed,
              style: ElevatedButton.styleFrom(
                backgroundColor: NotelColors.surfaceHigh,
                foregroundColor: NotelColors.textPrimary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 0,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset(
                    'assets/images/ic_google_logo.png',
                    width: 20,
                    height: 20,
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      _googleButtonLabel,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Apple button (Sign in with Apple): DIRECTLY BELOW the
          // Google button, iOS only (see _isApplePlatform — it never
          // builds on Android). The package's own button is the
          // HIG-faithful rendering (black style, Apple logo); it is
          // disabled while any auth attempt is in flight so it
          // cannot double-fire.
          if (_isApplePlatform) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: SignInWithAppleButton(
                key: const ValueKey('sign_in_with_apple_button'),
                text: _appleButtonLabel,
                style: SignInWithAppleButtonStyle.black,
                height: 50,
                onPressed: _isLoading ? null : _onApplePressed,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmailField() {
    return TextField(
      controller: _emailController,
      focusNode: _emailFocusNode,
      keyboardType: TextInputType.emailAddress,
      // Wave A (SCORECARD-3 #5 + SCORECARD-9 #15-adjacent): Enter
      // advances to the password field (in forgot-password mode, to
      // the reset submit), and credential managers get the email hint
      // they need to offer saved logins.
      textInputAction: _isForgotPasswordMode
          ? TextInputAction.done
          : TextInputAction.next,
      onSubmitted: (_) {
        if (_isForgotPasswordMode) {
          _submitFromKeyboard();
        } else {
          _passwordFocusNode.requestFocus();
        }
      },
      autofillHints: const [AutofillHints.email],
      autocorrect: false,
      style: const TextStyle(color: NotelColors.textPrimary, fontSize: 16),
      cursorColor: NotelColors.primary,
      decoration: InputDecoration(
        labelText: 'Email Address',
        labelStyle:
            const TextStyle(color: NotelColors.textSecondary),
        floatingLabelStyle:
            const TextStyle(color: NotelColors.primary),
        prefixIcon: const Icon(Icons.email,
            color: NotelColors.textSecondary),
        filled: false,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide:
              BorderSide(color: NotelColors.fieldBorderIdle),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide:
              const BorderSide(color: NotelColors.primary),
        ),
      ),
    );
  }

  Widget _buildPasswordField() {
    return TextField(
      controller: _passwordController,
      focusNode: _passwordFocusNode,
      obscureText: !_passwordVisible,
      keyboardType: TextInputType.visiblePassword,
      // Wave A (SCORECARD-3 #5 + SCORECARD-9 #15-adjacent): Enter
      // submits through the same dispatch as the main button; the
      // autofill hint is newPassword in register mode so credential
      // managers offer to save (not fill) the new credential.
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _submitFromKeyboard(),
      autofillHints: _isRegisterMode
          ? const [AutofillHints.newPassword]
          : const [AutofillHints.password],
      autocorrect: false,
      style: const TextStyle(color: NotelColors.textPrimary, fontSize: 16),
      cursorColor: NotelColors.primary,
      decoration: InputDecoration(
        labelText: 'Password',
        labelStyle:
            const TextStyle(color: NotelColors.textSecondary),
        floatingLabelStyle:
            const TextStyle(color: NotelColors.primary),
        prefixIcon:
            const Icon(Icons.lock, color: NotelColors.textSecondary),
        suffixIcon: IconButton(
          onPressed: () =>
              setState(() => _passwordVisible = !_passwordVisible),
          icon: Icon(
            _passwordVisible ? Icons.visibility : Icons.visibility_off,
            color: NotelColors.textSecondary,
          ),
        ),
        filled: false,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide:
              BorderSide(color: NotelColors.fieldBorderIdle),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide:
              const BorderSide(color: NotelColors.primary),
        ),
      ),
    );
  }

  /// MF-2 (Juno compliance, Oct 2026): the Terms/Privacy links open the
  /// hosted legal pages in the external browser, matching native
  /// (`LoginScreen.kt`: ACTION_VIEW intents). Silent on failure — the
  /// links simply don't open rather than surfacing an error.
  Future<void> _openLegalPage(String url) async {
    final uri = Uri.parse(url);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      // Link doesn't open; keep the user on the login screen.
    }
  }

  Widget _buildTermsLine() {
    const base = TextStyle(
        fontSize: 8.5, color: NotelColors.textSecondary);
    const link = TextStyle(
        fontSize: 8.5,
        fontWeight: FontWeight.bold,
        color: NotelColors.primary);
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Text('By signing up you agree to our ', style: base),
        GestureDetector(
          onTap: () =>
              _openLegalPage('https://api.jottracker.com/terms.html'),
          child: const Text('Terms of Use', style: link),
        ),
        const Text(' and ', style: base),
        GestureDetector(
          onTap: () =>
              _openLegalPage('https://api.jottracker.com/privacy.html'),
          child: const Text('Privacy Policy', style: link),
        ),
        const Text('.', style: base),
      ],
    );
  }
}
