import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:video_player/video_player.dart';

/// Opening-sequence LAB gate.
///
/// Compile-time flag: `--dart-define=TABS_OPENING_SEQUENCE=true`
/// turns the sequence on. Default false — with the flag off, AppFlow
/// behaves exactly as before (splash + welcome), and this overlay is
/// never built.
const bool tabsOpeningSequenceEnabled =
    bool.fromEnvironment('TABS_OPENING_SEQUENCE');

/// Bundled opening clip (beats 1–5): flat cartoon Bandit pushes the
/// tile in, the "Tabs" letters build, brow wipe, lean hold. Silent
/// encode (video-only stream); the player is still hard-muted as
/// belt-and-suspenders — no audio is ever part of this feature.
const String openingVideoAsset = 'assets/video/opening_beats1_5.mp4';

/// The clip's literal first frame (phase A poster; also the
/// fallback path's held frame — frame 0, no lettering).
const String openingPosterAsset = 'assets/images/opening_poster.png';

/// The canonical Tabs mark — the ONLY logo used natively anywhere
/// in the sequence (the center lockup and the rise into the welcome
/// header). The same asset the splash / login / welcome /
/// onboarding headers use; never a generated approximation, and
/// never the clip's drawn lettering rendered natively.
const String openingLogoAsset = 'assets/images/ic_tabs_note.png';

/// Source frame size of the clip / poster.
const Size openingFrameSize = Size(832, 976);

// ── Player seam ──────────────────────────────────────────────────────
//
// The sequence talks to the clip only through [OpeningPlayer], so
// tests can inject init failures / hangs / completions without the
// real plugin (the widget-test environment has no video pipeline).

/// Minimal player surface the opening sequence needs.
abstract interface class OpeningPlayer {
  bool get isInitialized;
  bool get isCompleted;

  /// Clip duration once initialized; [Duration.zero] when unknown.
  Duration get duration;

  void addListener(VoidCallback listener);
  void removeListener(VoidCallback listener);
  Future<void> initialize();
  Future<void> setVolume(double volume);
  Future<void> play();

  /// The video surface, sized by the caller.
  Widget buildVideo(BuildContext context);
  void dispose();
}

typedef OpeningPlayerFactory = OpeningPlayer Function();

/// The production player: the bundled asset through video_player.
class VideoPlayerOpeningPlayer implements OpeningPlayer {
  VideoPlayerOpeningPlayer(String asset)
      : _controller = VideoPlayerController.asset(asset);

  final VideoPlayerController _controller;

  @override
  bool get isInitialized => _controller.value.isInitialized;

  @override
  bool get isCompleted {
    final value = _controller.value;
    return value.isInitialized &&
        value.duration > Duration.zero &&
        value.position >= value.duration;
  }

  @override
  Duration get duration => _controller.value.duration;

  @override
  void addListener(VoidCallback listener) =>
      _controller.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _controller.removeListener(listener);

  @override
  Future<void> initialize() => _controller.initialize();

  @override
  Future<void> setVolume(double volume) => _controller.setVolume(volume);

  @override
  Future<void> play() => _controller.play();

  @override
  Widget buildVideo(BuildContext context) => VideoPlayer(_controller);

  @override
  void dispose() => _controller.dispose();
}

OpeningPlayer createDefaultOpeningPlayer() =>
    VideoPlayerOpeningPlayer(openingVideoAsset);

enum _Phase { poster, clip, fallback, resolve, rise, reveal, done }

/// The LAB front-door opening sequence — an opaque overlay above
/// the REAL WelcomeScreen, which AppFlow renders underneath it
/// exactly as it does today (founder-directed landing, Oct 29,
/// 2026; no invented welcome content exists in this overlay).
///
/// Phases:
/// A. Poster — [openingPosterAsset] full-bleed (BoxFit.contain)
///    from the first frame; covers the wait while AppFlow resolves
///    the cold-start session. Playback never starts before
///    [signedOutConfirmed] is true.
/// B. Clip — the bundled mp4, muted, not looping, faded in over the
///    poster. Init error, or init not complete within ~700ms of
///    the signed-out confirmation, takes the fallback: the poster
///    holds for ~900ms, then the identical resolve/rise/reveal.
/// C. Resolve — as the clip ends, it crossfades out (~200ms) while
///    a native lockup resolves at screen CENTER, larger than
///    header size: the real [openingLogoAsset] mark + native
///    "Tabs" text (NotelPrimary, w900). The clip's Bandit, tile,
///    and drawn lettering all fade out with the clip.
/// D. Rise — the lockup animates up and scales down (650ms,
///    fastOutSlowIn) into the WelcomeScreen's OWN header position
///    and size (see [_LockupLayer] for the exact geometry), ending
///    pixel-coincident with the real header beneath.
/// E. Reveal — the overlay's opaque background fades out, so the
///    real welcome content fades in under the landed lockup; then
///    the overlay's lockup fades out (it is identical to the real
///    header beneath it) and [onCompleted] removes the overlay.
///    The real WelcomeScreen, live and tappable, remains.
///
/// The overlay absorbs pointers throughout. A tap during the
/// native phases (C–E) snaps the lockup to the header position and
/// completes the reveal instantly; taps during A–B are inert.
/// Reduced motion (the app's [animationsDisabled] convention):
/// no overlay is rendered at all — the sequence completes
/// immediately and AppFlow shows the real WelcomeScreen directly,
/// and no player is ever created.
class OpeningSequenceScreen extends StatefulWidget {
  /// Playback may begin only once this is true (AppFlow has
  /// resolved the cold start as signed-out). Until then, phase A
  /// covers.
  final bool signedOutConfirmed;

  /// Test seam; defaults to the real video_player-backed player.
  final OpeningPlayerFactory? playerFactory;

  /// Fired once when the reveal completes (or instantly, for
  /// reduced motion / tap-to-complete), so AppFlow can remove the
  /// overlay and record that the sequence has played this process.
  final VoidCallback? onCompleted;

  const OpeningSequenceScreen({
    super.key,
    this.signedOutConfirmed = true,
    this.playerFactory,
    this.onCompleted,
  });

  @override
  State<OpeningSequenceScreen> createState() =>
      _OpeningSequenceScreenState();
}

class _OpeningSequenceScreenState extends State<OpeningSequenceScreen>
    with TickerProviderStateMixin {
  static const _initTimeout = Duration(milliseconds: 700);
  static const _fallbackHold = Duration(milliseconds: 900);

  late final AnimationController _videoFade; // 150ms poster→clip
  late final AnimationController _resolve; // 200ms clip→lockup
  late final AnimationController _rise; // 650ms center→header
  late final Animation<double> _riseCurved;
  late final AnimationController _reveal; // 500ms bg out, lockup out

  _Phase _phase = _Phase.poster;
  OpeningPlayer? _player;
  bool _startAttempted = false;
  bool _initDone = false;
  bool _fallbackTaken = false;
  bool _playerReady = false;
  bool _clipFinished = false;
  bool _reducedMotion = false;
  bool _instantCompleting = false;
  bool _finished = false;
  bool _completedNotified = false;

  Timer? _initTimer;
  Timer? _fallbackTimer;
  Timer? _endTimer;

  @override
  void initState() {
    super.initState();
    _videoFade = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 150));
    _resolve = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 200))
      ..addStatusListener(_onResolveStatus);
    _rise = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 650))
      ..addStatusListener(_onRiseStatus);
    _riseCurved =
        CurvedAnimation(parent: _rise, curve: Curves.fastOutSlowIn);
    _reveal = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 500))
      ..addStatusListener(_onRevealStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeStart();
  }

  @override
  void didUpdateWidget(OpeningSequenceScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.signedOutConfirmed && !oldWidget.signedOutConfirmed) {
      _maybeStart();
    }
  }

  void _maybeStart() {
    if (_startAttempted || _finished) return;
    if (animationsDisabled(context)) {
      _startAttempted = true;
      _reducedMotion = true;
      _completeInstantly();
      return;
    }
    if (!widget.signedOutConfirmed) return; // poster covers the wait
    _startAttempted = true;
    unawaited(_startPlayer());
  }

  // ── Phase B: clip (or fallback) ───────────────────────────────────

  Future<void> _startPlayer() async {
    final player =
        (widget.playerFactory ?? createDefaultOpeningPlayer)();
    _player = player;
    player.addListener(_onPlayerUpdate);
    _initTimer = Timer(_initTimeout, () {
      if (!_initDone) _takeFallback();
    });
    try {
      await player.initialize();
      _initDone = true;
      _initTimer?.cancel();
      // Fallback already taken (timeout) or the widget is gone: the
      // late-initialized player was disposed by the fallback path —
      // never start playback on it.
      if (_fallbackTaken || !mounted) return;
      // The bundled encode is silent (video-only stream); mute
      // anyway as belt-and-suspenders.
      await player.setVolume(0);
      if (_fallbackTaken || !mounted) return;
      setState(() {
        _playerReady = true;
        _phase = _Phase.clip;
      });
      unawaited(_videoFade.forward());
      await player.play();
      // Safety net: if the completion listener never fires, end
      // the clip on its own duration rather than stalling the door.
      final d = player.duration;
      if (d > Duration.zero && mounted && !_clipFinished) {
        _endTimer =
            Timer(d + const Duration(milliseconds: 500), _onClipFinished);
      }
    } catch (_) {
      _initTimer?.cancel();
      if (!mounted) return;
      _takeFallback();
    }
  }

  void _onPlayerUpdate() {
    final player = _player;
    if (player != null && player.isCompleted) _onClipFinished();
  }

  void _takeFallback() {
    if (_fallbackTaken ||
        _finished ||
        _phase == _Phase.resolve ||
        _phase == _Phase.rise ||
        _phase == _Phase.reveal ||
        _phase == _Phase.done) {
      return;
    }
    _fallbackTaken = true;
    _initTimer?.cancel();
    _disposePlayer();
    if (!mounted) return;
    setState(() => _phase = _Phase.fallback);
    _fallbackTimer = Timer(_fallbackHold, _beginResolve);
  }

  void _onClipFinished() {
    if (_clipFinished || _fallbackTaken || _finished) return;
    _clipFinished = true;
    _endTimer?.cancel();
    _beginResolve();
  }

  // ── Phase C–E sequencing ──────────────────────────────────────────

  void _beginResolve() {
    if (!mounted || _finished) return;
    setState(() => _phase = _Phase.resolve);
    // One crossfade, both paths: clip→center lockup, or (fallback)
    // poster→center lockup — the poster opacity is driven by the
    // same controller.
    unawaited(_resolve.forward());
  }

  void _onResolveStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed ||
        _instantCompleting ||
        _finished) {
      return;
    }
    _disposePlayer();
    setState(() => _phase = _Phase.rise);
    unawaited(_rise.forward());
  }

  void _onRiseStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed ||
        _instantCompleting ||
        _finished) {
      return;
    }
    setState(() => _phase = _Phase.reveal);
    unawaited(_reveal.forward());
  }

  void _onRevealStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed ||
        _instantCompleting ||
        _finished) {
      return;
    }
    _finish();
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    if (mounted) setState(() => _phase = _Phase.done);
    _notifyCompleted();
  }

  /// Tap during phases C–E, and the reduced-motion direct path:
  /// every animation jumps to its end state.
  void _completeInstantly() {
    _instantCompleting = true;
    _initTimer?.cancel();
    _fallbackTimer?.cancel();
    _endTimer?.cancel();
    _disposePlayer();
    _videoFade.value = 1.0;
    _resolve.value = 1.0;
    _rise.value = 1.0;
    _reveal.value = 1.0;
    _instantCompleting = false;
    _finish();
  }

  void _notifyCompleted() {
    if (_completedNotified) return;
    _completedNotified = true;
    final callback = widget.onCompleted;
    if (callback == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) callback();
    });
  }

  void _onTap() {
    // Taps during A–B are inert; during C–E they finish the beats.
    if (_phase == _Phase.resolve ||
        _phase == _Phase.rise ||
        _phase == _Phase.reveal) {
      _completeInstantly();
    }
  }

  void _disposePlayer() {
    final player = _player;
    if (player == null) return;
    _player = null;
    player.removeListener(_onPlayerUpdate);
    player.dispose();
  }

  @override
  void dispose() {
    _initTimer?.cancel();
    _fallbackTimer?.cancel();
    _endTimer?.cancel();
    _disposePlayer();
    _videoFade.dispose();
    _resolve.dispose();
    _rise.dispose();
    _reveal.dispose();
    super.dispose();
  }

  // ── Layer opacities ───────────────────────────────────────────────

  /// Overlay background: opaque until the reveal, fading out over
  /// the reveal's first 60% so the real welcome content fades in
  /// under the landed lockup.
  double get _backgroundOpacity {
    final v = _reveal.value;
    if (v <= 0) return 1.0;
    if (v >= 0.6) return 0.0;
    return (1.0 - v / 0.6).clamp(0.0, 1.0);
  }

  /// Lockup: in with the resolve crossfade; out over the reveal's
  /// final 40% (the real header beneath it is identical).
  double get _lockupOpacity {
    var o = _resolve.value.clamp(0.0, 1.0);
    final v = _reveal.value;
    if (v > 0.6) o *= (1.0 - (v - 0.6) / 0.4).clamp(0.0, 1.0);
    return o;
  }

  double get _videoOpacity {
    if (_reducedMotion || !_playerReady) return 0.0;
    final v = _resolve.value;
    if (v > 0) return (1.0 - v).clamp(0.0, 1.0);
    return _videoFade.value;
  }

  double get _posterOpacity {
    if (_reducedMotion) return 0.0;
    if (_fallbackTaken) {
      // Held through the fallback, then crossfaded out by the
      // resolve that fades the center lockup in.
      return (1.0 - _resolve.value).clamp(0.0, 1.0);
    }
    return _playerReady ? 0.0 : 1.0;
  }

  // ── Build ─────────────────────────────────────────────────────────

  Rect _containRect(Size size) {
    final aspect = openingFrameSize.width / openingFrameSize.height;
    var w = size.width;
    var h = w / aspect;
    if (h > size.height) {
      h = size.height;
      w = h * aspect;
    }
    return Rect.fromLTWH(
        (size.width - w) / 2, (size.height - h) / 2, w, h);
  }

  @override
  Widget build(BuildContext context) {
    // Reduced motion: no overlay at all — AppFlow removes this
    // widget via onCompleted and the real WelcomeScreen stands.
    if (_reducedMotion) return const SizedBox.shrink();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _onTap,
      child: AnimatedBuilder(
        animation: Listenable.merge(
            [_videoFade, _resolve, _riseCurved, _reveal]),
        builder: (context, _) {
          final size = MediaQuery.sizeOf(context);
          final frame = _containRect(size);
          return Stack(
            fit: StackFit.expand,
            children: [
              // Opaque overlay background (fades in the reveal).
              if (_backgroundOpacity > 0)
                Positioned.fill(
                  child: Opacity(
                    opacity: _backgroundOpacity,
                    child: const ColoredBox(
                        color: NotelColors.background),
                  ),
                ),
              // A. Poster.
              if (_posterOpacity > 0)
                Positioned.fromRect(
                  rect: frame,
                  child: Opacity(
                    opacity: _posterOpacity,
                    child: Image.asset(
                      openingPosterAsset,
                      key: const ValueKey('opening_poster'),
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              // C–D. Native lockup (under the clip it replaces).
              if (_lockupOpacity > 0)
                Opacity(
                  opacity: _lockupOpacity,
                  child: _LockupLayer(
                    screenSize: size,
                    safeTop: MediaQuery.paddingOf(context).top,
                    t: _riseCurved.value,
                  ),
                ),
              // B. Clip (top media layer).
              if (_videoOpacity > 0 && _player != null)
                Positioned.fromRect(
                  rect: frame,
                  child: Opacity(
                    key: const ValueKey('opening_video_layer'),
                    opacity: _videoOpacity,
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: SizedBox(
                        width: openingFrameSize.width,
                        height: openingFrameSize.height,
                        child: _player!.buildVideo(context),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// The native lockup: the real Tabs mark + the native "Tabs"
/// wordmark, resolving at screen center (scaled by [_centerScale])
/// and rising into the WelcomeScreen's own header.
///
/// Final-frame geometry is DERIVED from welcome_screen.dart, not
/// eyeballed: the welcome body is SafeArea → Padding(horizontal 20,
/// vertical 16) → Column (crossAxisAlignment.center) → Padding(top
/// 8) → _WelcomeHeader, a min-size Row of [28×28 logo, 8dp gap,
/// "Tabs" 26sp w900 NotelPrimary letterSpacing 1]. So the header
/// row's top is safeTop + 16 + 8, the row is horizontally centered,
/// and its height is max(28, the wordmark's laid-out height). The
/// wordmark's laid-out size is measured here with a [TextPainter]
/// under the ambient text scaler — the same metrics the real Text
/// will get — and the overlay wordmark is that very Text in a
/// FittedBox: at t=1 the rect equals the text's intrinsic size, the
/// FittedBox is a no-op, and the overlay header is pixel-coincident
/// with the real one beneath it. At t=0 every rect is the header
/// layout scaled uniformly about the screen center.
class _LockupLayer extends StatelessWidget {
  final Size screenSize;
  final double safeTop;
  final double t; // 0 = centered resolve, 1 = welcome header

  static const double _centerScale = 2.4;

  const _LockupLayer({
    required this.screenSize,
    required this.safeTop,
    required this.t,
  });

  @override
  Widget build(BuildContext context) {
    // The _WelcomeHeader treatment, verbatim.
    const markSize = 28.0;
    const gap = 8.0;
    const wordmarkStyle = TextStyle(
      fontSize: 26,
      fontWeight: FontWeight.w900,
      color: NotelColors.primary,
      letterSpacing: 1,
    );
    final painter = TextPainter(
      text: const TextSpan(text: 'Tabs', style: wordmarkStyle),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final wordW = painter.width;
    final wordH = painter.height;

    final rowW = markSize + gap + wordW;
    final rowH = math.max(markSize, wordH);
    // Header rects (t=1): row top at SafeArea + 16dp vertical
    // content padding + 8dp header top padding; row centered.
    final hx = (screenSize.width - rowW) / 2;
    final hy = safeTop + 16 + 8;
    final headerMark =
        Rect.fromLTWH(hx, hy + (rowH - markSize) / 2, markSize, markSize);
    final headerWord = Rect.fromLTWH(
        hx + markSize + gap, hy + (rowH - wordH) / 2, wordW, wordH);
    // Center rects (t=0): the header layout scaled by _centerScale
    // about the screen center.
    final cx = (screenSize.width - rowW * _centerScale) / 2;
    final cy = (screenSize.height - rowH * _centerScale) / 2;
    Rect scaled(Rect r) => Rect.fromLTWH(
          cx + (r.left - hx) * _centerScale,
          cy + (r.top - hy) * _centerScale,
          r.width * _centerScale,
          r.height * _centerScale,
        );
    final markRect = Rect.lerp(scaled(headerMark), headerMark, t)!;
    final wordRect = Rect.lerp(scaled(headerWord), headerWord, t)!;

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fromRect(
          rect: markRect,
          child: Image.asset(
            openingLogoAsset,
            key: const ValueKey('opening_logo_mark'),
            fit: BoxFit.contain,
          ),
        ),
        Positioned.fromRect(
          rect: wordRect,
          child: const FittedBox(
            fit: BoxFit.contain,
            child: Text('Tabs', style: wordmarkStyle),
          ),
        ),
      ],
    );
  }
}
