import 'package:flutter/material.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

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
/// UI only this round: the Log In / Sign Up / Google / reset buttons are
/// no-ops (auth logic lands later). The login/register/forgot mode switch
/// is live UI state, as is the password-visibility toggle.
///
/// [initialRegisterMode] mirrors the native `mode` query arg: `true`
/// starts on "Create Your Account", `false` on "Welcome Back".
/// [onBack] pops to the welcome screen (native back button).
class LoginScreen extends StatefulWidget {
  final bool initialRegisterMode;
  final VoidCallback? onBack;

  const LoginScreen({
    super.key,
    this.initialRegisterMode = true,
    this.onBack,
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
        child: Stack(
          children: [
            // Card + terms — centered vertically and horizontally.
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                    horizontal: 20.0, vertical: 16.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildCard(),
                    const SizedBox(height: 10),
                    _buildTermsLine(),
                  ],
                ),
              ),
            ),
            // Logo header — pinned to the top.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Padding(
                padding:
                    EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
                child: Padding(
                  padding: EdgeInsets.only(top: 8.0),
                  child: _TopLogoHeader(onBack: widget.onBack),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard() {
    return Container(
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
          // Main action button (no-op this round).
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: () {},
              style: ElevatedButton.styleFrom(
                backgroundColor: NotelColors.primary,
                foregroundColor: NotelColors.background,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 0,
              ),
              child: Text(
                _mainButtonLabel,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
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
                  Text(
                    _googleButtonLabel,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
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
      keyboardType: TextInputType.emailAddress,
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
      obscureText: !_passwordVisible,
      keyboardType: TextInputType.visiblePassword,
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
      children: const [
        Text('By signing up you agree to our ', style: base),
        Text('Terms of Use', style: link),
        Text(' and ', style: base),
        Text('Privacy Policy', style: link),
        Text('.', style: base),
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
