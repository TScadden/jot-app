import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:video_player/video_player.dart';

/// Opening-sequence LAB gate (founder-approved clip, Oct 29, 2026).
///
/// Compile-time flag: `--dart-define=TABS_OPENING_SEQUENCE=true`
/// turns the sequence on. Default false — with the flag off, AppFlow
/// behaves exactly as before (splash + welcome), and this screen is
/// never built.
const bool tabsOpeningSequenceEnabled =
    bool.fromEnvironment('TABS_OPENING_SEQUENCE');

/// Bundled opening clip (beats 1–5): flat cartoon Bandit pushes the
/// tile in, the "Tabs" letters build, brow wipe, lean hold. Its
/// generated AAC track is NOT part of the feature — the player is
/// always muted (see [OpeningSequenceScreen] phase B).
const String openingVideoAsset = 'assets/video/opening_beats1_5.mp4';

/// The clip's literal first frame (phase A poster; also the
/// fallback path's held frame).
const String openingPosterAsset = 'assets/images/opening_poster.png';

/// The clip's literal last frame. Founder correction (Oct 29,
/// 2026): the clip's drawn "Tabs" lettering must never rest on
/// screen as the presented logo, so this still is NOT part of the
/// layer stack anymore — phase C crossfades the clip directly into
/// the native lockup. The asset stays bundled and pixel-exact; it
/// is simply never displayed.
const String openingEndAsset = 'assets/images/opening_end.png';

/// The canonical Tabs mark — the ONLY logo used natively anywhere
/// in the sequence (handoff lockup, beat-6 header, beat 7). The
/// same asset the splash / login / welcome / onboarding headers
/// use; never a generated approximation.
const String openingLogoAsset = 'assets/images/ic_tabs_note.png';

/// In-app Bandit used by the native (post-clip) elements.
const String openingBanditAsset = 'assets/images/bandit_full.png';

/// Source frame size of the clip / poster / end still.
const Size openingFrameSize = Size(832, 976);

// ── Player seam ──────────────────────────────────────────────────────
//
// The screen talks to the clip only through [OpeningPlayer], so
// tests can inject init failures / hangs / completions without the
// real plugin (the tmp-CI and widget-test environments have no
// video pipeline).

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

// ── Measured end-frame geometry ──────────────────────────────────────
//
// Bounding boxes measured from opening_end.png (832×976) by pixel
// sampling, as fractions of the frame (x, y, w, h):
// - tile interior (34,36,120): x 4–353, y 429–799
//     → (0.005, 0.440, 0.421, 0.380); with its purple border the tile
//     reads ≈ (0.000, 0.430, 0.435, 0.390).
// - Bandit body purple: x 0–465, y 186–833
//     → (0.000, 0.191, 0.560, 0.664).
// - wordmark (white letters + purple "b"): x 390–827, y 549–708
//     → (0.469, 0.563, 0.526, 0.163).
const Rect _tileEndFrac = Rect.fromLTWH(0.000, 0.430, 0.435, 0.390);
const Rect _banditEndFrac = Rect.fromLTWH(0.000, 0.191, 0.560, 0.664);
const Rect _wordmarkEndFrac = Rect.fromLTWH(0.469, 0.563, 0.526, 0.163);

enum _Phase { poster, clip, fallback, handoff, rise, content, done }

/// The LAB front-door opening sequence (beats 1–7).
///
/// Phases:
/// A. Poster — [openingPosterAsset] full-bleed (BoxFit.contain) from
///    the first frame; covers the wait while AppFlow resolves the
///    cold-start session. Playback never starts before
///    [signedOutConfirmed] is true.
/// B. Clip — the bundled mp4 (silent encode; the player is still
///    hard-muted as belt-and-suspenders), not looping, faded in
///    over the poster. Init error, or init not complete within
///    ~700ms of the signed-out confirmation, takes the fallback:
///    the poster holds for ~900ms, then the identical handoff —
///    the end state is unchanged.
/// C. Handoff — the clip crossfades DIRECTLY into the native
///    lockup (real [openingLogoAsset] mark + native-text wordmark,
///    see [_LockupLayer]) laid out at the end-frame geometry, one
///    ~200ms blend. The clip's drawn lettering never rests on
///    screen: there is no end-still layer in the stack at all.
/// D. Beat 6 — the lockup animates up into the header position
///    (650ms, fastOutSlowIn).
/// E. Beat 7 — headline + Bandit card + the welcome actions fade /
///    rise in. The screen then REMAINS as the welcome surface: its
///    buttons are [onRegister] / [onLogin], the exact callbacks
///    AppFlow passes WelcomeScreen. No navigation happens.
///
/// A tap during D–E jumps every animation to its end state; taps
/// during A–C are inert. Reduced motion (the app's
/// [animationsDisabled] convention) skips straight to the beat-7
/// end state and never creates a player.
class OpeningSequenceScreen extends StatefulWidget {
  final VoidCallback onRegister;
  final VoidCallback onLogin;

  /// Playback may begin only once this is true (AppFlow has resolved
  /// the cold start as signed-out). Until then, phase A covers.
  final bool signedOutConfirmed;

  /// Test seam; defaults to the real video_player-backed player.
  final OpeningPlayerFactory? playerFactory;

  /// Fired once when the sequence reaches its end state (beat 7
  /// complete, tap-skipped, or reduced-motion direct render), so
  /// AppFlow can record that it has played this process.
  final VoidCallback? onCompleted;

  const OpeningSequenceScreen({
    super.key,
    required this.onRegister,
    required this.onLogin,
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
  late final AnimationController _handoff; // 200ms direct crossfade
  late final AnimationController _rise; // 650ms beat 6
  late final Animation<double> _riseCurved;
  late final AnimationController _content; // 550ms beat 7

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
    _handoff = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 200))
      ..addStatusListener(_onHandoffStatus);
    _rise = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 650))
      ..addStatusListener(_onRiseStatus);
    _riseCurved =
        CurvedAnimation(parent: _rise, curve: Curves.fastOutSlowIn);
    _content = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 550))
      ..addStatusListener(_onContentStatus);
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
      // anyway as belt-and-suspenders — no audio is ever part of
      // this feature.
      await player.setVolume(0);
      if (_fallbackTaken || !mounted) return;
      setState(() {
        _playerReady = true;
        _phase = _Phase.clip;
      });
      unawaited(_videoFade.forward());
      await player.play();
      // Safety net: if the completion listener never fires, end the
      // clip on its own duration rather than stalling the door.
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
        _phase == _Phase.handoff ||
        _phase == _Phase.rise ||
        _phase == _Phase.content ||
        _phase == _Phase.done) {
      return;
    }
    _fallbackTaken = true;
    _initTimer?.cancel();
    _disposePlayer();
    if (!mounted) return;
    setState(() => _phase = _Phase.fallback);
    _fallbackTimer = Timer(_fallbackHold, _beginHandoff);
  }

  void _onClipFinished() {
    if (_clipFinished || _fallbackTaken || _finished) return;
    _clipFinished = true;
    _endTimer?.cancel();
    _beginHandoff();
  }

  // ── Phase C–E sequencing ──────────────────────────────────────────

  void _beginHandoff() {
    if (!mounted || _finished) return;
    setState(() => _phase = _Phase.handoff);
    // One direct crossfade, both paths: clip→native lockup, or (on
    // the fallback path, where there is no clip) poster→native
    // lockup — the poster opacity is driven by the same controller.
    unawaited(_handoff.forward());
  }

  void _onHandoffStatus(AnimationStatus status) {
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
    setState(() => _phase = _Phase.content);
    unawaited(_content.forward());
  }

  void _onContentStatus(AnimationStatus status) {
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

  /// Tap during phases D–E, and the reduced-motion direct render:
  /// every animation jumps to its end state.
  void _completeInstantly() {
    _instantCompleting = true;
    _initTimer?.cancel();
    _fallbackTimer?.cancel();
    _endTimer?.cancel();
    _disposePlayer();
    _videoFade.value = 1.0;
    _handoff.value = 1.0;
    _rise.value = 1.0;
    _content.value = 1.0;
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
    // Taps during A–C are inert; during D–E they finish the beats.
    if (_phase == _Phase.rise || _phase == _Phase.content) {
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
    _handoff.dispose();
    _rise.dispose();
    _content.dispose();
    super.dispose();
  }

  // ── Layer opacities ───────────────────────────────────────────────

  double get _nativeOpacity => _handoff.value.clamp(0.0, 1.0);

  double get _videoOpacity {
    if (_reducedMotion || !_playerReady) return 0.0;
    final v = _handoff.value;
    if (v > 0) return (1.0 - v).clamp(0.0, 1.0);
    return _videoFade.value;
  }

  double get _posterOpacity {
    if (_reducedMotion) return 0.0;
    if (_fallbackTaken) {
      // Held through the fallback, then crossfaded out by the same
      // handoff that fades the native lockup in.
      return (1.0 - _handoff.value).clamp(0.0, 1.0);
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
    return Scaffold(
      backgroundColor: NotelColors.background,
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _onTap,
        child: AnimatedBuilder(
          animation: Listenable.merge(
              [_videoFade, _handoff, _riseCurved, _content]),
          builder: (context, _) {
            final size = MediaQuery.sizeOf(context);
            final frame = _containRect(size);
            return Stack(
              fit: StackFit.expand,
              children: [
                // A. Poster (bottom).
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
                // C. Native lockup (under the video it replaces).
                if (_nativeOpacity > 0)
                  Opacity(
                    opacity: _nativeOpacity,
                    child: _LockupLayer(
                      frame: frame,
                      screenSize: size,
                      safeTop: MediaQuery.paddingOf(context).top,
                      t: _riseCurved.value,
                    ),
                  ),
                // (No end-still layer: phase C crossfades the clip
                // directly into the native lockup above — founder
                // correction, the clip's drawn lettering never
                // rests on screen.)
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
                // E. Beat-7 content (the welcome surface).
                if (_content.value > 0)
                  Opacity(
                    opacity: _content.value,
                    child: Transform.translate(
                      offset: Offset(0, (1 - _content.value) * 24),
                      child: _Beat7Content(
                        buttonsLive: _phase == _Phase.done,
                        onRegister: widget.onRegister,
                        onLogin: widget.onLogin,
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
}

/// The native lockup: the real Tabs mark + native wordmark + Bandit,
/// each element lerped from its measured end-frame rect (inside the
/// clip's contain rect) to its header rect (beat 6).
///
/// Founder logo rule (Oct 29, 2026): the mark is ALWAYS
/// [openingLogoAsset] (`ic_tabs_note.png`) — the clip's pushed tile
/// is plain, and the real logo lands natively here at the handoff.
/// The wordmark is native TEXT in the app's own treatments: the
/// SplashScreen wordmark (36sp, FontWeight.w900 Black, NotelPrimary,
/// letterSpacing 2) scaled proportionally for this lockup's larger
/// resting size, settling to the TopLogoHeader treatment (28dp
/// logo + 26sp Black NotelPrimary, 1sp spacing) in the header. The
/// video model's drawn lettering is never rendered natively.
///
/// Header composition, per the beat-7 board: small mark + "Tabs" +
/// small Bandit at the wordmark's right, centered at the top.
class _LockupLayer extends StatelessWidget {
  final Rect frame;
  final Size screenSize;
  final double safeTop;
  final double t; // 0 = end-frame position, 1 = header position

  const _LockupLayer({
    required this.frame,
    required this.screenSize,
    required this.safeTop,
    required this.t,
  });

  Rect _frac(Rect f) => Rect.fromLTWH(
        frame.left + f.left * frame.width,
        frame.top + f.top * frame.height,
        f.width * frame.width,
        f.height * frame.height,
      );

  @override
  Widget build(BuildContext context) {
    const headerH = 38.0;
    final headerTop = safeTop + 10;
    // mark 30 + gap 8 + wordmark 78 + gap 6 + Bandit 38 = 160 wide.
    final headerLeft = (screenSize.width - 160) / 2;
    final markHeader =
        Rect.fromLTWH(headerLeft, headerTop + 4, 30, 30);
    final wordmarkHeader =
        Rect.fromLTWH(headerLeft + 38, headerTop, 78, headerH);
    final banditHeader =
        Rect.fromLTWH(headerLeft + 122, headerTop, 38, headerH);

    final markRect = Rect.lerp(_frac(_tileEndFrac), markHeader, t)!;
    final wordmarkRect =
        Rect.lerp(_frac(_wordmarkEndFrac), wordmarkHeader, t)!;
    final banditRect =
        Rect.lerp(_frac(_banditEndFrac), banditHeader, t)!;

    return Stack(
      fit: StackFit.expand,
      children: [
        // The real mark, in the pushed tile's end-frame rect (the
        // tile itself stays plain in the clip; the logo is native).
        Positioned.fromRect(
          rect: markRect,
          child: Image.asset(
            openingLogoAsset,
            key: const ValueKey('opening_logo_mark'),
            fit: BoxFit.contain,
          ),
        ),
        Positioned.fromRect(
          rect: banditRect,
          child: Image.asset(openingBanditAsset, fit: BoxFit.contain),
        ),
        Positioned.fromRect(
          rect: wordmarkRect,
          child: const FittedBox(
            fit: BoxFit.contain,
            child: Text(
              'Tabs',
              style: TextStyle(
                // SplashScreen wordmark treatment (36sp Black,
                // NotelPrimary, letterSpacing 2) at this lockup's
                // scale: the FittedBox child is drawn at 100sp, so
                // spacing scales proportionally (2 × 100/36 ≈ 5.6,
                // settling toward the header's 1sp-at-26sp ≈ 3.8
                // as the fitted size shrinks in beat 6).
                fontSize: 100,
                fontWeight: FontWeight.w900,
                color: NotelColors.primary,
                letterSpacing: 5.6,
                height: 1.0,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Beat 7: headline, the big Bandit card, and the welcome actions.
/// Buttons are inert ([IgnorePointer] + null callbacks) until the
/// sequence reports done — they are live only once fully visible.
class _Beat7Content extends StatelessWidget {
  final bool buttonsLive;
  final VoidCallback onRegister;
  final VoidCallback onLogin;

  const _Beat7Content({
    required this.buttonsLive,
    required this.onRegister,
    required this.onLogin,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header space: the lockup lands here in beat 6.
            const SizedBox(height: 72),
            const Text(
              'Your health, all in one place',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: NotelColors.textPrimary,
              ),
            ),
            const SizedBox(height: 44),
            // Big surface card with Bandit leaning on its top edge.
            Container(
              height: 216,
              decoration: BoxDecoration(
                color: NotelColors.surface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: NotelColors.cardBorder),
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    right: 16,
                    top: -34,
                    child: Image.asset(
                      openingBanditAsset,
                      height: 190,
                      fit: BoxFit.contain,
                    ),
                  ),
                ],
              ),
            ),
            const Spacer(),
            IgnorePointer(
              ignoring: !buttonsLive,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 52,
                    child: FilledButton(
                      onPressed: buttonsLive ? onRegister : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: NotelColors.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      child: const Text('Get started'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 52,
                    child: TextButton(
                      onPressed: buttonsLive ? onLogin : null,
                      style: TextButton.styleFrom(
                        foregroundColor: NotelColors.textSecondary,
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: const Text('I have an account'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
