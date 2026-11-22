import 'package:sign_in_with_apple/sign_in_with_apple.dart';

/// Sign in with Apple (Flutter side) — the iOS mirror of
/// GoogleSignInService in `google_sign_in_service.dart`.
///
/// Runs one interactive Apple authorization via the
/// `sign_in_with_apple` plugin (`SignInWithApple.getAppleIDCredential`
/// with the email + fullName scopes) and hands the resulting identity
/// token to `AuthApiClient.appleLogin` (`POST api/auth/apple`; server
/// contract in `~/workspace/build-apple-readiness/siwa-server-contract.md`).
/// The server needs ONLY the identity token — the authorization code
/// is never read, stored, logged, or transmitted.
///
/// Apple returns the user's name and email ONLY on the first
/// authorization for this app, and neither is inside the identity
/// token: the credential therefore carries `givenName`/`familyName`
/// (and `email`, for the Settings linking flow) alongside the token
/// so the caller can forward them on that first flow.
///
/// iOS only: the login screen never builds the Apple button on
/// non-iOS platforms, and Settings linking is reached the same way.
/// Real-device sign-in additionally needs the Sign in with Apple
/// capability on the App ID (founder Apple Developer account) plus
/// the `com.apple.developer.applesignin` entitlement (Runner.entitlements).

/// Typed outcome kinds for a failed Apple sign-in attempt, mirroring
/// GoogleSignInOutcomeKind: the UI switches on the class of failure
/// instead of parsing plugin exception text (raw exception text,
/// codes, and messages never reach the UI or logs).
enum AppleSignInOutcomeKind {
  /// The user dismissed the authorization sheet — a quiet no-op.
  cancelled,

  /// Sign in with Apple is not supported/available on this device
  /// or build (e.g. iOS < 13, missing capability).
  unavailable,

  /// Everything else.
  failed,
}

/// A failed Apple sign-in attempt. Carries only a [kind] and a safe,
/// generic [message] — never plugin exception text and never any
/// part of an identity token (Vera rule: the token is never logged,
/// printed, or included in exceptions).
class AppleSignInOutcome implements Exception {
  final AppleSignInOutcomeKind kind;
  final String message;

  const AppleSignInOutcome(this.kind, this.message);

  const AppleSignInOutcome.cancelled()
      : kind = AppleSignInOutcomeKind.cancelled,
        message = '';

  const AppleSignInOutcome.unavailable()
      : kind = AppleSignInOutcomeKind.unavailable,
        message = 'Apple sign-in is not available right now.';

  const AppleSignInOutcome.failed()
      : kind = AppleSignInOutcomeKind.failed,
        message = 'Apple sign-in failed. Please try again.';

  @override
  String toString() => 'AppleSignInOutcome($kind)';
}

/// The Apple credential a login/register flow needs: the identity
/// token (for the server exchange) plus the name parts Apple returns
/// only on the first authorization (null on later sign-ins). The
/// token is never logged, printed, or included in exceptions.
class AppleCredential {
  final String idToken;
  final String? givenName;
  final String? familyName;

  const AppleCredential({
    required this.idToken,
    this.givenName,
    this.familyName,
  });
}

/// The Apple identity a Settings linking flow needs: the identity
/// token (for `POST api/auth/link-apple`) plus the account email for
/// the connected-state display. Apple returns the email only on the
/// first authorization, so [email] may be null — the link endpoint's
/// success body carries `appleEmail` as the fallback display value.
/// The token is never logged, printed, or included in exceptions.
class AppleAccountIdentity {
  final String idToken;
  final String? email;

  const AppleAccountIdentity({required this.idToken, this.email});
}

/// Injectable wrapper around the `sign_in_with_apple` plugin.
///
/// Deliberately minimal surface, mirroring GoogleSignInService:
/// the user-tap authorization call only. No credential-state checks,
/// no keychain reads. Only the identity token, the first-flow name
/// parts, and (for the Settings variant) the email are extracted
/// from the plugin credential.
class AppleSignInService {
  AppleSignInService();

  /// Runs one interactive Apple authorization and returns its
  /// credential (identity token + first-flow name parts).
  ///
  /// Throws an [AppleSignInOutcome] —
  /// [AppleSignInOutcomeKind.cancelled] when the user dismisses the
  /// sheet (the plugin's `AuthorizationErrorCode.canceled`),
  /// [AppleSignInOutcomeKind.unavailable] when Sign in with Apple
  /// is not supported on this device/build, and
  /// [AppleSignInOutcomeKind.failed] for every other authorization
  /// code and for a missing/blank identity token.
  Future<AppleCredential> signInForCredential() async {
    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );
      final idToken = credential.identityToken;
      if (idToken == null || idToken.trim().isEmpty) {
        throw const AppleSignInOutcome.failed();
      }
      return AppleCredential(
        idToken: idToken,
        givenName: credential.givenName,
        familyName: credential.familyName,
      );
    } on AppleSignInOutcome {
      rethrow;
    } on SignInWithAppleAuthorizationException catch (e) {
      // Map plugin codes to typed outcomes; e.message is
      // deliberately dropped, never surfaced or logged.
      if (e.code == AuthorizationErrorCode.canceled) {
        throw const AppleSignInOutcome.cancelled();
      }
      throw const AppleSignInOutcome.failed();
    } on SignInWithAppleNotSupportedException {
      throw const AppleSignInOutcome.unavailable();
    } catch (_) {
      throw const AppleSignInOutcome.failed();
    }
  }

  /// Settings linking variant, mirroring Google's
  /// `signInForIdentity()`: same authorization flow, but the caller
  /// also needs the account EMAIL for the Connected Apps display.
  /// The email is present only on the first authorization and may
  /// legitimately be null here (see [AppleAccountIdentity]).
  Future<AppleAccountIdentity> signInForIdentity() async {
    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );
      final idToken = credential.identityToken;
      if (idToken == null || idToken.trim().isEmpty) {
        throw const AppleSignInOutcome.failed();
      }
      final email = credential.email?.trim();
      return AppleAccountIdentity(
        idToken: idToken,
        email: (email == null || email.isEmpty) ? null : email,
      );
    } on AppleSignInOutcome {
      rethrow;
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) {
        throw const AppleSignInOutcome.cancelled();
      }
      throw const AppleSignInOutcome.failed();
    } on SignInWithAppleNotSupportedException {
      throw const AppleSignInOutcome.unavailable();
    } catch (_) {
      throw const AppleSignInOutcome.failed();
    }
  }
}
