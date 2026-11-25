import 'package:flutter/foundation.dart';

/// Rich streak reminder — the app-level "open the Daily Summary
/// sheet" signal (Juno ruling 2026-11-24 tap destination; Mason
/// recon §5).
///
/// Why a signal, and why this shape: the Daily Summary is not a
/// route — it is a modal sheet hosted by `TodaySummaryCard` on
/// Home, and the card is the ONLY legitimate host (a second host
/// would risk the documented entry-id collision in
/// today_summary_card.dart). A notification tap therefore cannot
/// navigate to it; it has to ASK the card, wherever it currently
/// lives, to open its own sheet. The codebase's mechanism for
/// exactly that kind of cross-widget ask is a shared
/// [ChangeNotifier] the interested widgets subscribe to
/// (`AppBackgroundController.instance`, the SettingsStore
/// listeners in MainShell, MigraineController's one-shot pending
/// signals) — this class is that pattern, kept as small as the
/// job allows:
///
/// - The app flow raises [requestOpen] when a Daily Summary tap
///   has been delivered to the home stage (foreground dispatch
///   and the terminated-state launch payload both funnel there).
/// - `MainShell` listens: a pending request selects the Home tab
///   (the card exists only there), degrading the tap to "land on
///   Home" when nothing more can be done.
/// - `TodaySummaryCard` listens AND polls the pending flag when
///   its data first lands: it consumes the request exactly once
///   and opens its sheet through its own public `openSheet()`.
///   Consuming is the card's alone — the shell never clears the
///   flag, so a request raised before the card mounts (cold
///   start, tab switch) survives until the card can honor it.
///
/// Freshness: a request is honored only within
/// [freshnessWindow] of being raised. A request nobody could
/// consume (signed out, Home never reached, the card's load
/// never landed) must not pop a sheet minutes later over an
/// unrelated screen state; past the window it is simply dropped
/// (the user still landed on Home, which is the ruled degrade).
class DailySummaryOpenSignal extends ChangeNotifier {
  DailySummaryOpenSignal({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  /// The app-wide instance: the app flow raises requests on it,
  /// the shell and the card consume from it.
  static final DailySummaryOpenSignal instance = DailySummaryOpenSignal();

  /// How long a raised request stays honorable (see class doc).
  static const Duration freshnessWindow = Duration(seconds: 30);

  final DateTime Function() _clock;
  DateTime? _requestedAt;

  /// Whether an unconsumed, still-fresh request is pending.
  bool get hasPendingRequest {
    final at = _requestedAt;
    if (at == null) return false;
    if (_clock().difference(at) > freshnessWindow) {
      // Stale: drop it rather than let it fire late. (Lazy
      // clear — no notify; nobody's rendering depends on this
      // flag, consumers only poll it at decision points.)
      _requestedAt = null;
      return false;
    }
    return true;
  }

  /// Raises (or refreshes) the open request and notifies
  /// listeners. Safe to call when nobody is listening: the
  /// pending flag is what late subscribers poll.
  void requestOpen() {
    _requestedAt = _clock();
    notifyListeners();
  }

  /// Consumes the pending request: returns true exactly once
  /// per fresh [requestOpen], false when there is nothing fresh
  /// to consume. The card calls this before opening its sheet,
  /// so a request can never open two sheets.
  bool consumePendingRequest() {
    if (!hasPendingRequest) return false;
    _requestedAt = null;
    return true;
  }

  @visibleForTesting
  void debugReset() {
    _requestedAt = null;
  }
}
