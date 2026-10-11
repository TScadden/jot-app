import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/session_store.dart';
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
/// - nonexistent account (HTTP 404): "That account doesn't exist."
/// - wrong password (HTTP 401): "Wrong password or email."
/// - network/server problems: a generic message.
/// The password is never logged or stored — it lives in memory only for
/// the request duration.
///
/// "Sign Up", "Send Reset Link" and Google stay no-ops this round.
/// The login/register/forgot mode switch is live UI state, as is the
/// password-visibility toggle.
///
/// [initialRegisterMode] mirrors the native `mode` query arg: `true`
/// starts on "Create Your Account", `false` on "Welcome Back".
/// [onBack] pops to the welcome screen (native back button).
/// [onLoginSuccess] fires with the account email after a real login.
class LoginScreen extends StatefulWidget {
  final bool initialRegisterMode;
  final VoidCallback? onBack;
  final ValueChanged<String>? onLoginSuccess;

  /// Injectable for tests; defaults to the real backend client.
  final AuthApiClient? authApi;

  /// Injectable for tests; defaults to flutter_secure_storage.
  final SessionStore? sessionStore;

  const LoginScreen({
    super.key,
    this.initialRegisterMode = true,
    this.onBack,
    this.onLoginSuccess,
    this.authApi,
    this.sessionStore,
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
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// Round 5: real login. Mirrors the native `LoginViewModel.login()`
  /// flow: blank-field guard, loading state, API call, then either
  /// session persistence + [LoginScreen.onLoginSuccess] or an inline
  /// error message.
  Future<void> _onLoginPressed() async {
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
          );
          if (!mounted) return;
          setState(() => _isLoading = false);
          widget.onLoginSuccess?.call(result.email);
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

  void _onToggleMode() {
    setState(() {
      _errorMessage = null;
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
    return Scaffold(
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
                      child: _TopLogoHeader(onBack: widget.onBack),
                    ),
                  ),
                ),
              ],
            );
          },
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
                onPressed: () =>
                    setState(() => _isForgotPasswordMode = true),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
          // Main action button. "Log In" (login mode) performs the real
          // login (Round 5); "Sign Up" and "Send Reset Link" stay
          // no-ops (their real destinations don't exist yet).
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: _isLoading
                  ? null
                  : () {
                      if (!_isRegisterMode && !_isForgotPasswordMode) {
                        _onLoginPressed();
                      }
                    },
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
                        color: NotelColors.background,
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
          // Inline auth error (Round 5): wrong password / nonexistent
          // account / network. Cleared on mode switch and on each
          // new attempt.
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
          // Google button (no-op this round).
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: () {},
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
        ],
      ),
    );
  }

  Widget _buildEmailField() {
    return TextField(
      controller: _emailController,
      keyboardType: TextInputType.emailAddress,
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
      obscureText: !_passwordVisible,
      keyboardType: TextInputType.visiblePassword,
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

/// Port of the native `TopLogoHeader`: circular back button on the left,
/// centered Tabs logo + wordmark.
class _TopLogoHeader extends StatelessWidget {
  final VoidCallback? onBack;

  const _TopLogoHeader({this.onBack});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: Stack(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(
                color: NotelColors.surfaceHigh,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                onPressed: onBack,
                padding: EdgeInsets.zero,
                icon: const Icon(
                  Icons.arrow_back,
                  color: NotelColors.textPrimary,
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  'assets/images/ic_tabs_note.png',
                  width: 28,
                  height: 28,
                ),
                const SizedBox(width: 8),
                const Text(
                  'Tabs',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    color: NotelColors.primary,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
