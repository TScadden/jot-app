import 'package:google_sign_in/google_sign_in.dart';

/// Round 24 — Google sign-in (Flutter side).
///
/// Mirrors the native flow in `LoginScreen.kt` + `JotApi.kt`:
/// legacy GMS `GoogleSignIn` with `requestIdToken(webClientId)` +
/// `requestEmail`, `signOut()` first (forces the account chooser),
/// then sign-in, and the resulting ID token is exchanged with the
/// Tabs server by `AuthApiClient.googleLogin`
/// (`POST api/auth/google`). The 7.x plugin is Credential
/// Manager-based — Google's supported path — but the ID-token /
/// server contract is identical to native.
///
/// The web client ID from the native app's `strings.xml`
/// (`google_web_client_id`). This is a public client identifier,
/// not a secret: it names the OAuth client, it does not
/// authenticate it.
const kGoogleServerClientId =
    '309178591258-9da8qs8sigdnr7qvfblbeiid2d0190kn.apps.googleusercontent.com';

/// Typed outcome kinds for a failed Google sign-in attempt, so the
/// UI can switch on the class of failure instead of parsing plugin
/// exception text (Juno N3: raw exception text, status codes, and
/// fingerprints never reach the UI or logs).
enum GoogleSignInOutcomeKind {
  /// The user dismissed the account chooser — a quiet no-op.
  cancelled,

  /// Configuration / registration class failure. The Lab package's
  /// Android OAuth client is not yet registered in Google Cloud, so
  /// this is the expected outcome on a real device until the founder
  /// registers it.
  unavailable,

  /// Everything else.
  failed,
}

/// A failed Google sign-in attempt. Carries only a [kind] and a
/// safe, generic [message] — never plugin exception text and never
/// any part of an ID token (Vera rule: the token is never logged,
/// printed, or included in exceptions).
class GoogleSignInOutcome implements Exception {
  final GoogleSignInOutcomeKind kind;
  final String message;

  const GoogleSignInOutcome(this.kind, this.message);

  const GoogleSignInOutcome.cancelled()
      : kind = GoogleSignInOutcomeKind.cancelled,
        message = '';

  const GoogleSignInOutcome.unavailable()
      : kind = GoogleSignInOutcomeKind.unavailable,
        message = 'Google sign-in is not available right now.';

  const GoogleSignInOutcome.failed()
      : kind = GoogleSignInOutcomeKind.failed,
        message = 'Google sign-in failed. Please try again.';

  @override
  String toString() => 'GoogleSignInOutcome($kind)';
}

/// Injectable wrapper around `GoogleSignIn.instance`.
///
/// Deliberately minimal surface (Juno N2): initialization with the
/// server client ID plus the user-tap authentication call only. No
/// lightweight / silent authentication, no authorization client, no
/// scopes, no access token. Only the ID token is extracted from the
/// resulting account — display name and photo URL are never read,
/// stored, logged, or transmitted.
class GoogleSignInService {
  final GoogleSignIn _googleSignIn;
  bool _initialized = false;

  GoogleSignInService({GoogleSignIn? googleSignIn})
      : _googleSignIn = googleSignIn ?? GoogleSignIn.instance;

  /// Runs one interactive Google sign-in and returns its ID token.
  ///
  /// `signOut()` runs first, matching native, so the account
  /// chooser appears every time. Throws a [GoogleSignInOutcome] —
  /// [GoogleSignInOutcomeKind.cancelled] when the user dismisses
  /// the chooser, [GoogleSignInOutcomeKind.unavailable] for
  /// configuration-class failures, and
  /// [GoogleSignInOutcomeKind.failed] for everything else,
  /// including a missing/blank ID token.
  Future<String> signInForIdToken() async {
    try {
      if (!_initialized) {
        await _googleSignIn.initialize(
          serverClientId: kGoogleServerClientId,
        );
        _initialized = true;
      }
      // Native parity: sign out first so the chooser always shows.
      await _googleSignIn.signOut();
      final account = await _googleSignIn.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null || idToken.trim().isEmpty) {
        throw const GoogleSignInOutcome.failed();
      }
      return idToken;
    } on GoogleSignInOutcome {
      rethrow;
    } on GoogleSignInException catch (e) {
      // Map plugin codes to typed outcomes; e.description / details
      // are deliberately dropped, never surfaced or logged.
      switch (e.code) {
        case GoogleSignInExceptionCode.canceled:
          throw const GoogleSignInOutcome.cancelled();
        case GoogleSignInExceptionCode.clientConfigurationError:
        case GoogleSignInExceptionCode.providerConfigurationError:
        case GoogleSignInExceptionCode.uiUnavailable:
          throw const GoogleSignInOutcome.unavailable();
        default:
          throw const GoogleSignInOutcome.failed();
      }
    } on UnsupportedError {
      // authenticate() is unsupported on this platform/build.
      throw const GoogleSignInOutcome.unavailable();
    } catch (_) {
      throw const GoogleSignInOutcome.failed();
    }
  }
}
