import 'package:tabs_lab/src/data/onboarding_store.dart';

/// Flow3 resume — ONE-SHOT per login session (Vera B1 fix round 1).
///
/// The ruled behavior: a returning user who logs in mid-flow
/// resumes ONCE at the step they left. The failure this guards
/// against: the persisted step marker survives an exit back to
/// Welcome (the flow's completion flag is still false), so a naive
/// "marker present → advance" check re-fires on EVERY subsequent
/// login in the same session, silently blowing past the ruled
/// sign-up-first screen.
///
/// The gate is session-scoped (process lifetime): the first login
/// that finds a marker consumes the one advance; any later login in
/// the same process gets no advance. A genuinely new login session
/// (new process / cold start) starts unconsumed, so resume works
/// again there.
class OnboardingResumeGate {
  OnboardingResumeGate._();

  static bool _consumed = false;

  /// True exactly once per session: the first call consumes the
  /// session's single resume advance.
  static bool tryConsume() {
    if (_consumed) return false;
    _consumed = true;
    return true;
  }

  static bool get consumed => _consumed;

  /// Starts a fresh session (tests; also the semantic marker that
  /// a new process is a new session — statics start unconsumed).
  static void startNewSession() => _consumed = false;
}

/// The login-routing resume decision, factored out of AppFlow so
/// widget/unit tests drive the REAL logic (Vera B1: the regression
/// test must fail if the advance is deleted OR if it re-fires).
class OnboardingResumeCoordinator {
  final OnboardingStore store;

  const OnboardingResumeCoordinator(this.store);

  /// Returns the step index to resume at on this login, or null
  /// when no advance should happen: no marker, the marker was
  /// already consumed this session, or onboarding is complete.
  ///
  /// Vera m1 hardening: a marker at/past the Profile step is only
  /// trusted when the profile text actually exists locally — a
  /// marker can outlive the context write (e.g. marker=5 with no
  /// profile), and resuming past Profile would skip the one
  /// unskippable step. In that case the resume clamps back to the
  /// Profile step (index 1).
  Future<int?> advanceOnLogin() async {
    final complete = await store.getOnboardingComplete();
    if (complete) return null;
    final marker = await store.getStepMarker();
    if (marker == null) return null;
    if (!OnboardingResumeGate.tryConsume()) return null;
    var step = marker;
    if (step < 0) step = 0;
    if (step > 5) step = 5;
    if (step > 1) {
      final context = await store.getUserContext();
      if (context.trim().isEmpty) step = 1;
    }
    return step;
  }
}
