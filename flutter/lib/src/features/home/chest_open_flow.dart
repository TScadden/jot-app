import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/chest_service.dart';
import 'package:tabs_lab/src/data/gem_service.dart';

/// Chest open flow (CHESTS package, Nov 26, 2026) — built to
/// `tabs-chests/anim/REF-SPEC-V5.md`, mirroring the founder-approved
/// mock v5 (`make_mock_v5.py`) timings and geometry:
///
/// - Dark stage #121B20, tier label in tier color, chest rocking
///   idle (±2.5° about the bottom-center pivot, ~1.1s period — NO
///   hops, NO squash in idle).
/// - Chances phase: 3 dots (spent dark / current orange + white
///   up-arrow / upcoming dark + faint arrow), "Tap! Tap!" while
///   more than 1 chance remains, "1 chance left!" on the last.
///   Each tap fires a harder rock impulse AND one smooth golden
///   ribbon orbit (~0.43s) on a tilted ellipse, depth-layered
///   behind/in front of the chest, tapering and fading at the
///   ends; the dot spends at orbit start and the tier label
///   upgrades at that same moment when the server script says so.
/// - After the last orbit: dots + prompt fade, a short beat, then
///   "Tap to open!".
/// - Open tap: label + prompt fade; the chest SQUASHES (sy ~0.82)
///   then STRETCHES (sy ~1.13) while crossfading to the
///   pre-rendered GOLD sprite; soft gold halo + white 4-point
///   sparkles rise and elongate (NO lid flip, NO white flash).
///   The golden chest settles, holds, sinks and fades.
/// - Reward: a hexagon gem pile pops in low one by one, hops to
///   center with a landing squash; "+{gems} gems", the caption and
///   CONTINUE fade in; the gem counter (top-right) ticks up to the
///   server [ChestOpenResult.newBalance].
///
/// The flow calls `POST /chests/:id/open` ON ENTRY (via
/// [ChestService.openChest]) and animates the returned script —
/// gems are granted server-side in that call, so abandoning the
/// animation never loses them.

/// Tier label colors. STREAK is the founder-approved mock's
/// lavender (#A78BFA); DAILY and MEGA were sampled from the banked
/// chest art (Bram, Nov 26, 2026): DAILY #C9A7EB is the daily
/// chest's pale lavender diamond; MEGA #FFD74A is the mock's GOLD,
/// matching the mega chest's gold trim. Vera verifies.
abstract final class ChestTierColors {
  static const Color daily = Color(0xFFC9A7EB);
  static const Color streak = Color(0xFFA78BFA);
  static const Color mega = Color(0xFFFFD74A);

  static Color of(ChestTier tier) => switch (tier) {
    ChestTier.daily => daily,
    ChestTier.streak => streak,
    ChestTier.mega => mega,
  };
}

enum ChestOpenPhase {
  /// The open call is in flight (entered the flow, no script yet).
  loading,

  /// The open call failed; the chest stays in the inbox.
  loadFailed,

  /// Chances phase: taps spend dots and may upgrade the label.
  chances,

  /// All chances spent; "Tap to open!" is showing.
  readyToOpen,

  /// The squash/stretch/gold sequence is playing.
  opening,

  /// The gem-pile reward card is showing.
  reveal,
}

/// The open flow's state machine — pure Dart, driven by the screen
/// (which owns the clocks), so scripted outcomes are unit-testable
/// without timers: no upgrade / one upgrade / two upgrades / MEGA
/// start.
class ChestOpenController extends ChangeNotifier {
  ChestOpenController({
    required this.chest,
    required this._opener,
    this._onBalance,
  });

  final ChestItem chest;
  final Future<ChestOpenResult?> Function(String chestId) _opener;
  final void Function(int newBalance)? _onBalance;

  ChestOpenPhase _phase = ChestOpenPhase.loading;
  ChestOpenResult? _result;
  int _tapsUsed = 0;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  ChestOpenPhase get phase => _phase;
  ChestOpenResult? get result => _result;
  int get tapsUsed => _tapsUsed;
  int get chancesLeft => 3 - _tapsUsed;

  /// The tier the stage label shows right now: the start tier
  /// upgraded by the scripted outcomes of the taps already spent.
  ChestTier get displayTier {
    final r = _result;
    if (r == null) return chest.tier;
    return ChestOpenResult.tierAfter(chest.tier, r.tapOutcomes, _tapsUsed);
  }

  /// Balance the reward counter ticks FROM (the server balance
  /// before this chest's grant).
  int? get balanceBefore =>
      _result == null ? null : _result!.newBalance - _result!.gemsGranted;

  /// Entry: fire the one idempotent open call and adopt the
  /// returned script. The gems land server-side in this call.
  Future<void> start() async {
    if (_phase != ChestOpenPhase.loading || _result != null) return;
    final result = await _opener(chest.id);
    if (result == null) {
      _phase = ChestOpenPhase.loadFailed;
      notifyListeners();
      return;
    }
    _result = result;
    _onBalance?.call(result.newBalance);
    _phase = ChestOpenPhase.chances;
    notifyListeners();
  }

  /// Ruling #22: retry the same open call after a failure. Safe
  /// because the endpoint is idempotent — a lost response replays
  /// the recorded outcome, never a second grant.
  Future<void> retry() async {
    if (_phase != ChestOpenPhase.loadFailed) return;
    _phase = ChestOpenPhase.loading;
    notifyListeners();
    await start();
  }

  /// One chance tap. Returns true when the tap spent a chance (the
  /// screen runs the ribbon orbit + rock impulse); the dot spends
  /// and any scripted upgrade applies at orbit start — i.e. here.
  bool tapChance() {
    if (_phase != ChestOpenPhase.chances || _tapsUsed >= 3) return false;
    _tapsUsed++;
    notifyListeners();
    return true;
  }

  /// After the final orbit + the fade/beat, show "Tap to open!".
  void completeChances() {
    if (_phase != ChestOpenPhase.chances || _tapsUsed < 3) return;
    _phase = ChestOpenPhase.readyToOpen;
    notifyListeners();
  }

  /// The open tap: only from [ChestOpenPhase.readyToOpen].
  bool beginOpen() {
    if (_phase != ChestOpenPhase.readyToOpen) return false;
    _phase = ChestOpenPhase.opening;
    notifyListeners();
    return true;
  }

  /// The open sequence finished; the reward card takes the stage.
  void showReveal() {
    if (_phase != ChestOpenPhase.opening) return;
    _phase = ChestOpenPhase.reveal;
    notifyListeners();
  }
}

/// Push the open flow for [chest]. [service] is injectable for
/// tests; production uses [ChestService.instance].
Future<void> showChestOpenFlow(
  BuildContext context, {
  required ChestItem chest,
  ChestService? service,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => ChestOpenScreen(chest: chest, service: service),
      fullscreenDialog: true,
    ),
  );
}

class ChestOpenScreen extends StatefulWidget {
  final ChestItem chest;
  final ChestService? service;

  const ChestOpenScreen({super.key, required this.chest, this.service});

  @override
  State<ChestOpenScreen> createState() => _ChestOpenScreenState();
}

class _ChestOpenScreenState extends State<ChestOpenScreen>
    with TickerProviderStateMixin {
  late final ChestService _service;
  late final ChestOpenController _controller;

  /// Idle rock clock: continuous, drives the ±2.5° rock, the
  /// impulse decay, the ambient diamonds and the sparkles.
  late final AnimationController _clock;

  /// Ribbon orbit clock (one orbit per chance tap, ~0.43s — the
  /// mock's 13 frames at 30fps).
  late final AnimationController _orbit;

  /// Open + reveal sequence clock (squash → gold → fade → gems).
  late final AnimationController _seq;

  /// Rock impulse start times (seconds on [_clock]) per tap.
  final List<double> _impulses = [];

  /// Whether the chances UI (dots + prompt) has faded after the
  /// last orbit, before "Tap to open!" fades in.
  bool _chancesFaded = false;
  bool _tapToOpenShown = false;

  static const double _seqSeconds = 4.4;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? ChestService.instance;
    _controller = ChestOpenController(
      chest: widget.chest,
      opener: _service.openChest,
      onBalance: (b) => GemService.instance.adoptServerBalance(b),
    )..addListener(_onPhase);
    _clock = AnimationController(
      vsync: this,
      // 11.3s = exactly 10 idle-rock periods, so the repeat wrap
      // is seamless.
      duration: const Duration(milliseconds: 11300),
    )..repeat();
    _orbit = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 430),
    );
    _seq = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (_seqSeconds * 1000).round()),
    );
    unawaited(_controller.start());
  }

  @override
  void dispose() {
    _controller.removeListener(_onPhase);
    _controller.dispose();
    _clock.dispose();
    _orbit.dispose();
    _seq.dispose();
    super.dispose();
  }

  void _onPhase() {
    if (!mounted) return;
    if (_controller.phase == ChestOpenPhase.opening) {
      unawaited(_seq.forward(from: 0));
    }
    setState(() {});
  }

  void _onStageTap() {
    switch (_controller.phase) {
      case ChestOpenPhase.chances:
        if (_orbit.isAnimating) return;
        if (!_controller.tapChance()) return;
        _impulses.add(_clock.value * 11.3);
        unawaited(_orbit.forward(from: 0));
        if (_controller.tapsUsed >= 3) {
          // After the last orbit: dots + prompt fade (~0.15s), a
          // beat (~0.25s), then "Tap to open!" — the mock's frames
          // 136–161.
          Future<void>.delayed(const Duration(milliseconds: 430), () {
            if (!mounted) return;
            setState(() => _chancesFaded = true);
            Future<void>.delayed(const Duration(milliseconds: 400), () {
              if (!mounted) return;
              setState(() => _tapToOpenShown = true);
              _controller.completeChances();
            });
          });
        }
      case ChestOpenPhase.readyToOpen:
        _controller.beginOpen();
      default:
        break;
    }
  }

  /// Rock angle in radians at clock time [t] seconds: idle ±2.5°
  /// at ~1.1s period plus each tap's decaying ±6° impulse (the
  /// mock's exact curves).
  double _rockAngle(double t) {
    var deg = 2.5 * math.sin(2 * math.pi * t / 1.13);
    for (final t0 in _impulses) {
      final dt = t - t0;
      if (dt > 0) {
        deg += 6.0 * math.sin(2 * math.pi * dt / 0.55) * math.exp(-dt * 3.2);
      }
    }
    return deg * math.pi / 180;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121B20),
      body: GestureDetector(
        key: const Key('chestOpenStage'),
        behavior: HitTestBehavior.opaque,
        onTap: _onStageTap,
        child: AnimatedBuilder(
          animation: Listenable.merge([_clock, _orbit, _seq]),
          builder: (context, _) => _buildStage(context),
        ),
      ),
    );
  }

  Widget _buildStage(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final w = size.width;
    final h = size.height;
    final t = _clock.value * 11.3;
    final phase = _controller.phase;
    final inReveal =
        phase == ChestOpenPhase.reveal ||
        (phase == ChestOpenPhase.opening && _seq.value * _seqSeconds >= 1.9);
    if (phase == ChestOpenPhase.opening && _seq.value * _seqSeconds >= 1.9) {
      // Hand the phase over once the gems start (post-frame safe:
      // the controller guards on phase, repeat calls are no-ops).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _controller.showReveal();
      });
    }

    final chestW = w * 0.50;
    final pivotY = h * 0.583; // chest base line (mock PIVOT_Y)
    final chestCy = h * 0.48;

    return Stack(
      children: [
        // ── Golden ribbon, back half (behind the chest) ──────
        if (_orbit.isAnimating)
          Positioned.fill(
            child: CustomPaint(
              painter: _RibbonPainter(
                progress: _orbit.value,
                front: false,
                center: Offset(w / 2, chestCy),
                rx: w * 0.324,
                ry: h * 0.086,
              ),
            ),
          ),

        // ── Reward gem pile (behind its texts, above stage) ──
        if (inReveal) _buildGemPile(w, h),

        // ── Chest group: halo, pedestal, sprite, sparkles ────
        if (!inReveal || _seq.value * _seqSeconds < 2.0)
          ..._buildChest(w, h, t, pivotY, chestCy, chestW),

        // ── Ribbon, front half ───────────────────────────────
        if (_orbit.isAnimating)
          Positioned.fill(
            child: CustomPaint(
              painter: _RibbonPainter(
                progress: _orbit.value,
                front: true,
                center: Offset(w / 2, chestCy),
                rx: w * 0.324,
                ry: h * 0.086,
              ),
            ),
          ),

        // ── Tier label ───────────────────────────────────────
        _buildLabel(w, h),

        // ── Chances dots + prompt ────────────────────────────
        if (phase == ChestOpenPhase.chances ||
            phase == ChestOpenPhase.loading ||
            phase == ChestOpenPhase.loadFailed)
          _buildChancesUi(w, h),
        if (_tapToOpenShown && phase == ChestOpenPhase.readyToOpen)
          _promptText(
            w,
            h,
            ChestCopy.tapToOpen,
            key: const Key('chestTapToOpen'),
          ),

        // ── Reward texts ─────────────────────────────────────
        if (inReveal) ..._buildRewardTexts(w, h),

        // ── Abandon affordance (pre-open phases only). The gems
        // are already granted server-side once the script loads,
        // so leaving early never loses them.
        if (phase == ChestOpenPhase.loading ||
            phase == ChestOpenPhase.loadFailed ||
            phase == ChestOpenPhase.chances ||
            phase == ChestOpenPhase.readyToOpen)
          Positioned(
            left: 8,
            top: MediaQuery.paddingOf(context).top + 4,
            child: IconButton(
              key: const Key('chestOpenClose'),
              icon: const Icon(Icons.close, color: Colors.white70),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
      ],
    );
  }

  List<Widget> _buildChest(
    double w,
    double h,
    double t,
    double pivotY,
    double chestCy,
    double chestW,
  ) {
    final seqT = _seq.value * _seqSeconds;
    final opening =
        _controller.phase == ChestOpenPhase.opening ||
        _controller.phase == ChestOpenPhase.reveal;
    var sx = 1.0;
    var sy = 1.0;
    var goldK = 0.0;
    var glowK = 0.0;
    var fade = 1.0;
    var sink = 0.0;
    if (opening) {
      // Mock frames from T_OPEN: squash 6f, stretch 7f, settle 8f
      // (30fps → 0.20s / 0.23s / 0.27s), gold crossfade from +4f
      // over 6f, glow ramp +6f..+17f, sink+fade at +37f over 7f.
      if (seqT < 0.20) {
        final k = _easeIn(seqT / 0.20);
        sx = _lerp(1, 1.09, k);
        sy = _lerp(1, 0.80, k);
      } else if (seqT < 0.43) {
        final k = _easeOut((seqT - 0.20) / 0.23);
        sx = _lerp(1.09, 0.93, k);
        sy = _lerp(0.80, 1.13, k);
      } else if (seqT < 0.70) {
        final k = _easeOutBack((seqT - 0.43) / 0.27, 1.1);
        sx = _lerp(0.93, 1.0, k);
        sy = _lerp(1.13, 1.0, k);
      }
      goldK = ((seqT - 0.13) / 0.20).clamp(0.0, 1.0);
      glowK = ((seqT - 0.20) / 0.37).clamp(0.0, 1.0);
      if (seqT >= 1.23) {
        final k = ((seqT - 1.23) / 0.23).clamp(0.0, 1.0);
        fade = 1 - k;
        sink = h * 0.016 * k;
        glowK *= 1 - k;
      }
    }
    final angle = _rockAngle(t);
    final tier = _controller.displayTier;

    return [
      // Soft gold halo behind the golden chest.
      if (glowK > 0)
        Positioned(
          left: w / 2 - w * 0.37,
          top: chestCy - w * 0.37,
          width: w * 0.74,
          height: w * 0.74,
          child: Opacity(
            opacity: glowK * fade,
            child: const DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [Color(0xC7FFCD50), Color(0x00FFCD50)],
                ),
              ),
            ),
          ),
        ),
      // Pedestal slab (dark slate, ~1.03× chest width).
      Positioned(
        left: w / 2 - chestW * 1.03 / 2,
        top: pivotY - h * 0.008,
        width: chestW * 1.03,
        height: h * 0.024,
        child: Opacity(
          opacity: fade,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF242D33),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
      ),
      // The chest sprite itself: rock about the bottom-center
      // pivot; squash/stretch about the same base.
      Positioned(
        left: w / 2 - chestW / 2,
        top: pivotY + sink - chestW, // square box; sprite sits at its base
        width: chestW,
        height: chestW,
        child: Opacity(
          opacity: fade,
          child: Transform.rotate(
            angle: angle,
            alignment: Alignment.bottomCenter,
            child: Transform.scale(
              scaleX: sx,
              scaleY: sy,
              alignment: Alignment.bottomCenter,
              child: Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  Image.asset(
                    tier.spriteAsset,
                    key: const Key('chestSprite'),
                    width: chestW,
                    fit: BoxFit.contain,
                  ),
                  if (goldK > 0)
                    Opacity(
                      opacity: goldK,
                      child: Image.asset(
                        tier.goldSpriteAsset,
                        key: const Key('chestGoldSprite'),
                        width: chestW,
                        fit: BoxFit.contain,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
      // White 4-point sparkles bursting on the chest (open only).
      if (opening && seqT >= 0.13 && seqT < 1.6)
        Positioned.fill(
          child: CustomPaint(
            painter: _SparklePainter(
              age: seqT - 0.13,
              centerX: w / 2,
              chestTop: chestCy - chestW * 0.25,
              chestW: chestW,
            ),
          ),
        ),
      // Ambient muted-gold diamonds drifting around the chest.
      if (!opening)
        Positioned.fill(
          child: CustomPaint(
            painter: _AmbientPainter(time: t, w: w, h: h),
          ),
        ),
    ];
  }

  Widget _buildLabel(double w, double h) {
    final phase = _controller.phase;
    var opacity = 1.0;
    if (phase == ChestOpenPhase.opening) {
      opacity = (1 - _seq.value * _seqSeconds / 0.27).clamp(0.0, 1.0);
    } else if (phase == ChestOpenPhase.reveal) {
      opacity = 0;
    }
    final tier = _controller.displayTier;
    return Positioned(
      left: 0,
      right: 0,
      top: h * 0.313 - w * 0.05,
      child: Opacity(
        opacity: opacity,
        child: Text(
          tier.stageLabel,
          key: const Key('chestTierLabel'),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: w * 0.085,
            fontWeight: FontWeight.w800,
            letterSpacing: 2,
            color: ChestTierColors.of(tier),
          ),
        ),
      ),
    );
  }

  Widget _buildChancesUi(double w, double h) {
    final phase = _controller.phase;
    if (phase == ChestOpenPhase.loadFailed) {
      // Ruling #21–#23: ruled message, retry the same open call,
      // or leave (the chest stays in the inbox either way).
      return Stack(
        children: [
          _promptText(
            w,
            h,
            ChestCopy.openError,
            key: const Key('chestOpenFailed'),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: h * 0.693 + w * 0.09,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  key: const Key('chestOpenLater'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text(
                    ChestCopy.openLater,
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
                const SizedBox(width: 16),
                FilledButton(
                  key: const Key('chestOpenRetry'),
                  onPressed: () => unawaited(_controller.retry()),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF7C6EFF),
                  ),
                  child: const Text(ChestCopy.openRetry),
                ),
              ],
            ),
          ),
        ],
      );
    }
    final used = _controller.tapsUsed;
    final dotD = w * 0.089;
    final spacing = w * 0.132;
    final dotsOpacity = _chancesFaded ? 0.0 : 1.0;
    return Stack(
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: h * 0.622 - dotD / 2,
          child: AnimatedOpacity(
            opacity: dotsOpacity,
            duration: const Duration(milliseconds: 150),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < 3; i++) ...[
                  if (i > 0) SizedBox(width: spacing - dotD),
                  _ChanceDot(
                    key: Key('chestDot$i'),
                    size: dotD,
                    state: i < used
                        ? _DotState.spent
                        : (i == used ? _DotState.current : _DotState.upcoming),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (!_chancesFaded && phase == ChestOpenPhase.chances)
          _promptText(
            w,
            h,
            _controller.chancesLeft == 1
                ? ChestCopy.oneChanceLeft
                : ChestCopy.tapTap,
            key: const Key('chestChancePrompt'),
          ),
      ],
    );
  }

  Widget _promptText(double w, double h, String text, {Key? key}) {
    return Positioned(
      left: 0,
      right: 0,
      top: h * 0.693 - w * 0.035,
      child: Text(
        text,
        key: key,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: w * 0.054,
          fontWeight: FontWeight.w800,
          color: Colors.white.withValues(alpha: 0.96),
        ),
      ),
    );
  }

  // ── Reward phase ────────────────────────────────────────────

  /// Gem pile geometry (mock PILE, in mock px at 1080 wide):
  /// (dx, dy, size, rotation, shade index).
  static const List<(double, double, double, double, int)> _pile = [
    (-165, 0, 195, -0.06, 1),
    (5, 10, 205, 0.04, 0),
    (170, 0, 190, 0.09, 2),
    (-95, -118, 175, 0.12, 3),
    (88, -112, 180, -0.10, 1),
    (-8, -228, 168, 0.05, 2),
    (118, -205, 130, -0.16, 4),
  ];
  static const List<int> _pileSpawnOrder = [0, 2, 4, 6, 7, 9, 11];

  Widget _buildGemPile(double w, double h) {
    final seqT = _seq.value * _seqSeconds;
    final scale = w / 1080;
    // Gems pop in low from 1.9s (mock frame 246), staggered; the
    // pile hops to center at 2.33s (mock frames 259–267) and
    // lands with a squash through 2.9s.
    var hopY = 320.0; // mock px below final position
    var squashY = 1.0;
    if (seqT >= 2.33 && seqT < 2.60) {
      hopY = 320 * (1 - _easeOut((seqT - 2.33) / 0.27));
    } else if (seqT >= 2.60) {
      hopY = 0;
      if (seqT < 2.90) {
        final k = (seqT - 2.60) / 0.30;
        squashY = 1 - 0.14 * math.sin(math.pi * k) * (1 - k * 0.4);
      }
    }
    final baseY = h * 0.542 + hopY * scale;
    return Positioned.fill(
      key: const Key('chestGemPile'),
      child: CustomPaint(
        painter: _GemPilePainter(
          pile: _pile,
          spawnOrder: _pileSpawnOrder,
          seqT: seqT,
          popStart: 1.9,
          centerX: w / 2,
          baseY: baseY,
          scale: scale,
          squashY: squashY,
        ),
      ),
    );
  }

  List<Widget> _buildRewardTexts(double w, double h) {
    final seqT = _seq.value * _seqSeconds;
    final result = _controller.result;
    if (result == null) return const [];
    double fadeAt(double start) => ((seqT - start) / 0.27).clamp(0.0, 1.0);
    // Counter ticks up across the hold (mock frames 280–292).
    final tickK = seqT < 2.80
        ? 0.0
        : _easeOut(((seqT - 2.80) / 0.40).clamp(0.0, 1.0));
    final shownBalance = _controller.balanceBefore == null
        ? result.newBalance
        : _controller.balanceBefore! + (result.gemsGranted * tickK).round();
    return [
      // "+{n} gems" above the pile.
      Positioned(
        left: 0,
        right: 0,
        top: h * 0.314 - w * 0.045,
        child: Opacity(
          opacity: fadeAt(2.70),
          child: Text(
            ChestCopy.plusGems(result.gemsGranted),
            key: const Key('chestPlusGems'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: w * 0.072,
              fontWeight: FontWeight.w800,
              color: const Color(0xFFA99CFF),
            ),
          ),
        ),
      ),
      // Caption below the pile.
      Positioned(
        left: w * 0.06,
        right: w * 0.06,
        top: h * 0.595 - w * 0.03,
        child: Opacity(
          opacity: fadeAt(2.83),
          child: Text(
            ChestCopy.rewardCaption,
            key: const Key('chestRewardCaption'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: w * 0.043,
              fontWeight: FontWeight.w600,
              color: const Color(0xFFD8DCF0),
            ),
          ),
        ),
      ),
      // Gem counter, top-right (icon + number, no pill).
      Positioned(
        right: w * 0.05,
        top: h * 0.09 - w * 0.03,
        child: Opacity(
          opacity: fadeAt(2.77),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CustomPaint(
                size: Size(w * 0.041, w * 0.041),
                painter: _GemPainter(
                  color: const Color(0xFF7C6EFF),
                  rotation: 0.2,
                ),
              ),
              SizedBox(width: w * 0.012),
              Text(
                '$shownBalance',
                key: const Key('chestRewardBalance'),
                style: TextStyle(
                  fontSize: w * 0.05,
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFFA99CFF),
                ),
              ),
            ],
          ),
        ),
      ),
      // CONTINUE bar.
      Positioned(
        left: w * 0.04,
        right: w * 0.04,
        top: h * 0.90,
        height: h * 0.05,
        child: Opacity(
          opacity: fadeAt(2.93),
          child: FilledButton(
            key: const Key('chestContinue'),
            onPressed: () => Navigator.of(context).pop(),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF7C6EFF),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(
              ChestCopy.continueLabel,
              style: TextStyle(
                fontSize: w * 0.046,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    ];
  }

  static double _clamp01(double t) => t.clamp(0.0, 1.0);
  static double _easeOut(double t) {
    t = _clamp01(t);
    return 1 - math.pow(1 - t, 3).toDouble();
  }

  static double _easeIn(double t) {
    t = _clamp01(t);
    return t * t;
  }

  static double _easeOutBack(double t, double s) {
    t = _clamp01(t);
    return 1 +
        (s + 1) * math.pow(t - 1, 3).toDouble() +
        s * math.pow(t - 1, 2).toDouble();
  }

  static double _lerp(double a, double b, double k) => a + (b - a) * k;
}

enum _DotState { spent, current, upcoming }

/// One chances dot, drawn exactly as the mock's draw_dot: spent =
/// plain dark; current = bright orange with a white up-arrow and a
/// soft shadow; upcoming = dark with a faint arrow.
class _ChanceDot extends StatelessWidget {
  final double size;
  final _DotState state;

  const _ChanceDot({super.key, required this.size, required this.state});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size(size, size), painter: _DotPainter(state));
  }
}

class _DotPainter extends CustomPainter {
  final _DotState state;
  const _DotPainter(this.state);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;
    final fill = switch (state) {
      _DotState.current => const Color(0xFFE39A3B),
      _DotState.upcoming => const Color(0xFF4A3A24),
      _DotState.spent => const Color(0xFF342C22),
    };
    if (state == _DotState.current) {
      canvas.drawOval(
        Rect.fromCenter(
          center: c + Offset(0, r * 0.95),
          width: size.width * 0.71,
          height: size.height * 0.16,
        ),
        Paint()..color = Colors.black.withValues(alpha: 0.35),
      );
    }
    canvas.drawCircle(c, r, Paint()..color = fill);
    if (state != _DotState.spent) {
      final arrow = state == _DotState.current
          ? Colors.white
          : const Color(0xFFA89E94);
      final p = Path()
        ..moveTo(c.dx, c.dy - r * 0.50)
        ..lineTo(c.dx + r * 0.40, c.dy + r * 0.04)
        ..lineTo(c.dx + r * 0.15, c.dy + r * 0.04)
        ..lineTo(c.dx + r * 0.15, c.dy + r * 0.50)
        ..lineTo(c.dx - r * 0.15, c.dy + r * 0.50)
        ..lineTo(c.dx - r * 0.15, c.dy + r * 0.04)
        ..lineTo(c.dx - r * 0.40, c.dy + r * 0.04)
        ..close();
      canvas.drawPath(p, Paint()..color = arrow);
    }
  }

  @override
  bool shouldRepaint(_DotPainter old) => old.state != state;
}

/// The golden ribbon: a thick gold band on a tilted elliptical
/// orbit around the chest, drawn as tapering dots along an arc
/// that sweeps 205° behind the moving head (the mock's exact
/// construction). [front] selects the depth half: points whose
/// orbit sine is positive render in front of the chest, the rest
/// behind it.
class _RibbonPainter extends CustomPainter {
  final double progress;
  final bool front;
  final Offset center;
  final double rx;
  final double ry;

  const _RibbonPainter({
    required this.progress,
    required this.front,
    required this.center,
    required this.rx,
    required this.ry,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final p = progress.clamp(0.0, 1.0);
    if (p <= 0 || p >= 1) return;
    final fade = math.pow(math.sin(math.pi * p), 0.6).toDouble();
    final head = (90 - p * 360) * math.pi / 180;
    final tilt = -10 * math.pi / 180;
    const steps = 150;
    final paint = Paint();
    for (var s = 0; s <= steps; s++) {
      final a = head + (s / steps) * 205 * math.pi / 180;
      final isFront = math.sin(a) > 0;
      if (isFront != front) continue;
      final taper = 1 - (s / steps) * 0.72;
      final ex = math.cos(a) * rx;
      final ey = math.sin(a) * ry;
      final x = ex * math.cos(tilt) - ey * math.sin(tilt);
      final y = ex * math.sin(tilt) + ey * math.cos(tilt);
      final r = rx * 0.04 * taper * (0.55 + 0.45 * fade);
      final alpha = (255 * fade * taper).round();
      if (r < 1.2 || alpha < 8) continue;
      paint.color = const Color(0xFFFFD54A).withValues(alpha: alpha / 255);
      canvas.drawCircle(center + Offset(x, y), r, paint);
    }
  }

  @override
  bool shouldRepaint(_RibbonPainter old) =>
      old.progress != progress || old.front != front;
}

/// White 4-point sparkles that burst on the chest at the open,
/// rise, elongate vertically to ~2.2x, thin and fade over ~0.9s
/// (the mock's BURST table, deterministic seed).
class _SparklePainter extends CustomPainter {
  final double age; // seconds since the burst started
  final double centerX;
  final double chestTop;
  final double chestW;

  const _SparklePainter({
    required this.age,
    required this.centerX,
    required this.chestTop,
    required this.chestW,
  });

  // (xFrac, yFrac, vxFrac, vyFrac, life, rFrac) — spread mirrors
  // the mock's two burst groups around the chest's upper body.
  static const List<(double, double, double, double, double, double)> _burst = [
    (-0.28, 0.10, -0.06, -0.62, 1.00, 0.045),
    (-0.15, 0.02, 0.02, -0.78, 1.10, 0.052),
    (0.00, 0.08, 0.05, -0.66, 0.90, 0.042),
    (0.14, 0.00, -0.03, -0.84, 1.15, 0.055),
    (0.27, 0.12, 0.07, -0.58, 0.95, 0.040),
    (-0.22, 0.22, -0.04, -0.50, 1.20, 0.036),
    (0.08, 0.20, 0.03, -0.55, 1.05, 0.038),
    (0.22, 0.26, -0.05, -0.46, 1.18, 0.034),
    (-0.05, 0.16, 0.00, -0.72, 1.08, 0.048),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (final (fx, fy, vx, vy, life, rf) in _burst) {
      if (age < 0 || age >= life) continue;
      final k = age / life;
      final x = centerX + (fx + vx * age) * chestW;
      final y = chestTop + (fy + vy * age + 0.17 * age * age) * chestW;
      final r = rf * chestW * (1 - 0.3 * k);
      final a = math.pow(math.sin(math.pi * k), 0.7).toDouble();
      if (a <= 0 || r <= 0) continue;
      final elong = 1 + 0.5 * math.sin(math.pi * k);
      _drawStar(canvas, Offset(x, y), r, elong, a, paint);
    }
  }

  void _drawStar(
    Canvas canvas,
    Offset c,
    double r,
    double elong,
    double a,
    Paint paint,
  ) {
    const waist = 0.32;
    final pts = [
      Offset(c.dx, c.dy - r * elong),
      Offset(c.dx + r * waist, c.dy - r * waist),
      Offset(c.dx + r, c.dy),
      Offset(c.dx + r * waist, c.dy + r * waist),
      Offset(c.dx, c.dy + r * elong),
      Offset(c.dx - r * waist, c.dy + r * waist),
      Offset(c.dx - r, c.dy),
      Offset(c.dx - r * waist, c.dy - r * waist),
    ];
    final path = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (final pt in pts.skip(1)) {
      path.lineTo(pt.dx, pt.dy);
    }
    path.close();
    paint.color = Colors.white.withValues(alpha: a);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_SparklePainter old) => old.age != age;
}

/// Ambient chunky muted-gold diamonds drifting and twinkling
/// slowly around the chest (the mock's AMBIENT table, positions as
/// fractions of the 1080×1920 mock stage).
class _AmbientPainter extends CustomPainter {
  final double time;
  final double w;
  final double h;

  const _AmbientPainter({required this.time, required this.w, required this.h});

  static const List<(double, double, double, double)> _spots = [
    (0.156, 0.417, 0.024, 0.0),
    (0.859, 0.392, 0.020, 0.9),
    (0.109, 0.530, 0.019, 1.7),
    (0.887, 0.543, 0.023, 2.4),
    (0.733, 0.331, 0.017, 3.1),
    (0.261, 0.322, 0.018, 3.9),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (final (fx, fy, rf, ph) in _spots) {
      final dx = 0.013 * w * math.sin(time * 0.55 + ph * 2.1);
      final dy = 0.006 * h * math.cos(time * 0.42 + ph * 1.7);
      final pulse = 0.5 + 0.5 * math.sin(time * 2.2 + ph * 2.0);
      final r = rf * w * (0.7 + 0.3 * pulse);
      final a = 0.20 + 0.38 * pulse;
      final c = Offset(fx * w + dx, fy * h + dy);
      final path = Path()
        ..moveTo(c.dx, c.dy - r)
        ..lineTo(c.dx + r * 0.72, c.dy)
        ..lineTo(c.dx, c.dy + r)
        ..lineTo(c.dx - r * 0.72, c.dy)
        ..close();
      paint.color = const Color(0xFFD8B660).withValues(alpha: a * 0.55);
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_AmbientPainter old) => old.time != time;
}

/// One chunky hexagon gem (the mock's draw_gem: hexagon + lighter
/// top facet).
class _GemPainter extends CustomPainter {
  final Color color;
  final double rotation;

  const _GemPainter({required this.color, required this.rotation});

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    _drawGem(canvas, c, size.width, rotation, color, 1.0);
  }

  static void _drawGem(
    Canvas canvas,
    Offset c,
    double s,
    double rot,
    Color fill,
    double alpha,
  ) {
    final r = s / 2;
    Offset rp(double dx, double dy) {
      final ca = math.cos(rot);
      final sa = math.sin(rot);
      return Offset(c.dx + dx * ca - dy * sa, c.dy + dx * sa + dy * ca);
    }

    final hex = Path();
    for (var k = 0; k < 6; k++) {
      final pt = rp(
        r * math.cos(math.pi / 3 * k),
        r * 0.88 * math.sin(math.pi / 3 * k),
      );
      if (k == 0) {
        hex.moveTo(pt.dx, pt.dy);
      } else {
        hex.lineTo(pt.dx, pt.dy);
      }
    }
    hex.close();
    canvas.drawPath(hex, Paint()..color = fill.withValues(alpha: alpha));
    final facet = Path()
      ..moveTo(rp(-r * 0.34, -r * 0.52).dx, rp(-r * 0.34, -r * 0.52).dy)
      ..lineTo(rp(r * 0.34, -r * 0.52).dx, rp(r * 0.34, -r * 0.52).dy)
      ..lineTo(rp(r * 0.18, -r * 0.16).dx, rp(r * 0.18, -r * 0.16).dy)
      ..lineTo(rp(-r * 0.18, -r * 0.16).dx, rp(-r * 0.18, -r * 0.16).dy)
      ..close();
    final lt = Color.fromARGB(
      255,
      math.min(255, fill.r * 255 + 62).round(),
      math.min(255, fill.g * 255 + 62).round(),
      math.min(255, fill.b * 255 + 62).round(),
    );
    canvas.drawPath(facet, Paint()..color = lt.withValues(alpha: alpha));
  }

  @override
  bool shouldRepaint(_GemPainter old) =>
      old.color != color || old.rotation != rotation;
}

/// The reward pile: ~7 hexagon gems popping in one by one at the
/// low position, then (via the caller's [baseY]) hopping to center
/// with a landing squash. Draws the flat ellipse shadow too.
class _GemPilePainter extends CustomPainter {
  final List<(double, double, double, double, int)> pile;
  final List<int> spawnOrder;
  final double seqT;
  final double popStart;
  final double centerX;
  final double baseY;
  final double scale;
  final double squashY;

  const _GemPilePainter({
    required this.pile,
    required this.spawnOrder,
    required this.seqT,
    required this.popStart,
    required this.centerX,
    required this.baseY,
    required this.scale,
    required this.squashY,
  });

  static const List<Color> _shades = [
    Color(0xFF5A4BD1),
    Color(0xFF7C6EFF),
    Color(0xFF9284FF),
    Color(0xFFA99CFF),
    Color(0xFF685AEB),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    // Flat ellipse shadow under the pile.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(centerX, baseY + 30 * scale),
        width: 580 * scale,
        height: 60 * scale,
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.41),
    );
    for (var i = 0; i < pile.length; i++) {
      final (gx, gy, gs, gr, shade) = pile[i];
      final spawn = popStart + spawnOrder[i] / 30.0;
      if (seqT < spawn) continue;
      final sk = ((seqT - spawn) / 0.20).clamp(0.0, 1.0);
      final gscale = sk < 1 ? 0.55 + 0.5 * _easeOutBack(sk, 1.8) : 1.0;
      _GemPainter._drawGem(
        canvas,
        Offset(centerX + gx * scale, baseY + gy * squashY * scale),
        gs * gscale * (0.6 + 0.4 * squashY) * scale,
        gr,
        _shades[shade],
        1.0,
      );
    }
  }

  static double _easeOutBack(double t, double s) {
    t = t.clamp(0.0, 1.0);
    return 1 +
        (s + 1) * math.pow(t - 1, 3).toDouble() +
        s * math.pow(t - 1, 2).toDouble();
  }

  @override
  bool shouldRepaint(_GemPilePainter old) =>
      old.seqT != seqT || old.baseY != baseY || old.squashY != squashY;
}
