import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel, appFlavor;
import 'package:sentry_flutter/sentry_flutter.dart';

/// Crash and non-fatal error reporting — Juno Ruling
/// 2026-10-27-crash-tracking (Ruling 4, C1–C14) is the constraints
/// document for this file. Read it before changing anything here.
///
/// Design summary (all points are ruling conditions, not taste):
///
/// - The Sentry SDK is initialised ONLY when a DSN is injected at
///   build time via `--dart-define=SENTRY_DSN=...`. With an empty DSN
///   the SDK is never initialised, no transport exists, and nothing
///   can leave the device (C11); the app installs local handlers
///   that log via [debugPrint] and otherwise runs identically.
/// - Events are rebuilt to an ALLOWLIST in [scrubEvent] (C1): the
///   full SDK event is never forwarded. User, request, breadcrumbs,
///   extras, modules and every non-allowlisted context are dropped;
///   exception values are replaced with a static scrubbed marker
///   (exception messages can embed user content — C7); tags are
///   limited to `release` and `environment`.
/// - Breadcrumbs are closed at the flag level, not only in
///   callbacks (C3): every breadcrumb-producing flag is off,
///   `maxBreadcrumbs` is 0, and `beforeBreadcrumb` returns null as a
///   backstop. No navigator/route observer, no HTTP, file-I/O or
///   database integration is installed anywhere in the app.
/// - Tracing, profiling, replay, screenshots, view hierarchy,
///   attachments and the feedback widget stay off (C4). Error
///   `sampleRate` is 1.0 (C12). Auto session tracking is ON so
///   release health can compute crash-free sessions/users (C5);
///   the distinct identifier is the SDK-generated random on-device
///   identifier only — this codebase NEVER sets a user or distinct
///   id from account data, anywhere (enforced by a source-scan
///   test in test/crash_reporting_test.dart).
/// - Global handlers report and then PRESERVE prior behaviour (C6,
///   must not swallow): [FlutterError.onError] chains to the handler
///   that was installed before ours (which, when Sentry is enabled,
///   is Sentry's own integration handler — it in turn chains to the
///   framework default that presents errors in debug);
///   [PlatformDispatcher.onError] returns the prior handler's result
///   or `false`; the [runZonedGuarded] zone handler reports and then
///   forwards the error to the parent zone's uncaught-error handler.
abstract final class CrashReporting {
  /// Build-time DSN injection (C9). Never a committed literal.
  static const String dsn = String.fromEnvironment('SENTRY_DSN');

  /// Optional environment override. When absent, the environment is
  /// derived from the build flavor: `production` for the prod
  /// flavor, `lab` otherwise.
  static const String environmentDefine =
      String.fromEnvironment('SENTRY_ENVIRONMENT');

  /// True when this build carries a DSN and may initialise Sentry.
  static bool get isEnabled => dsn.isNotEmpty;

  /// The flavor this build was produced with (`--flavor`), or null
  /// when built without one. Injectable in [resolveEnvironment] and
  /// [isLabFlavor] for tests.
  static String? get buildFlavor => appFlavor;

  /// Environment resolution (C9): an explicit SENTRY_ENVIRONMENT
  /// define wins; otherwise the prod flavor is `production` and
  /// everything else is `lab`.
  static String resolveEnvironment({String? flavor, String? defineValue}) {
    final define = defineValue ?? environmentDefine;
    if (define.isNotEmpty) return define;
    return (flavor ?? buildFlavor) == 'prod' ? 'production' : 'lab';
  }

  /// The forced-crash test hook (C6 evidence) is reachable ONLY in
  /// the lab flavor. A prod-flavor build can never satisfy this.
  static bool isLabFlavor({String? flavor}) =>
      (flavor ?? buildFlavor) == 'lab';

  // ── Options (C1–C5, C12) ────────────────────────────────────────

  /// The ONE options configurator. Used by [run] for the real
  /// SentryFlutter init, and directly by tests (including the
  /// capturing-transport canary gate) so the tested configuration
  /// is byte-for-byte the shipped configuration.
  ///
  /// [transport] is a test seam: production passes null and the SDK
  /// uses its platform transport. Tests pass a capturing transport
  /// wired into this same configuration path.
  static void configureOptions(
    SentryFlutterOptions options, {
    required String dsnValue,
    required String environment,
    Transport? transport,
  }) {
    options.dsn = dsnValue;
    options.environment = environment;
    // C3: pinned, and asserted in a unit test against the built
    // options (test/crash_reporting_test.dart).
    options.sendDefaultPii = false;
    // C12: unsampled errors — Gate 2's crash-free percentages are
    // computed on the full dataset.
    options.sampleRate = 1.0;
    // C4: performance tracing fully off — no sampler, no rate.
    options.tracesSampleRate = 0;
    options.tracesSampler = null;
    // C3: request bodies are never captured.
    options.maxRequestBodySize = MaxRequestBodySize.never;
    // C3: no failed-request capture (request URLs can carry record
    // identifiers and query strings).
    options.captureFailedRequests = false;
    options.captureNativeFailedRequests = false;
    options.recordHttpBreadcrumbs = false;
    // C3: breadcrumbs closed at the flag level. Every producer flag
    // off; zero retained; beforeBreadcrumb is the backstop.
    options.maxBreadcrumbs = 0;
    options.enablePrintBreadcrumbs = false;
    options.beforeBreadcrumb = (breadcrumb, hint) => null;
    // C1/C2 backstop: every event is rebuilt to the allowlist.
    // The one exception: an event built by [captureError] carries
    // the static-message hint, and its (code-defined) value is
    // preserved by the scrub — see [scrubEvent].
    options.beforeSend = (event, hint) => scrubEvent(
          event,
          preserveStaticValue: hint.get(staticMessageHintKey) == true,
        );
    // Sessions (release health) are handled by the native SDKs;
    // the Dart hub must not attach threads (thread names/stack
    // state are outside the C1 allowlist; the exception carries
    // the stack trace).
    options.attachThreads = false;
    options.attachStacktrace = true;
    if (transport != null) {
      options.transport = transport;
    }

    // Flutter-level flags (SentryFlutterOptions).
    // C5: auto session tracking ON for crash-free sessions (and,
    // via the native SDK's own random installation identifier,
    // crash-free users). Code never supplies the identifier.
    options.enableAutoSessionTracking = true;
    // C3: native + flutter breadcrumb producers off.
    options.enableAutoNativeBreadcrumbs = false;
    options.enableAppLifecycleBreadcrumbs = false;
    options.enableWindowMetricBreadcrumbs = false;
    options.enableBrightnessChangeBreadcrumbs = false;
    options.enableTextScaleChangeBreadcrumbs = false;
    options.enableMemoryPressureBreadcrumbs = false;
    // C3/C4: user-interaction breadcrumbs + tracing off.
    options.enableUserInteractionBreadcrumbs = false;
    options.enableUserInteractionTracing = false;
    // C4: no auto performance tracing, no frames tracking (it feeds
    // performance spans), no native trace sync.
    options.enableAutoPerformanceTracing = false;
    options.enableFramesTracking = false;
    options.enableNativeTraceSync = false;
    // C4: screenshots and view hierarchy off.
    options.attachScreenshot = false;
    options.attachViewHierarchy = false;
    // Module/package reporting can enumerate the full dependency
    // set into event modules — outside the C1 allowlist.
    options.reportPackages = false;
    // C4: Session Replay rates pinned to zero (never initialised
    // with a non-zero rate; replay payloads are screen content).
    options.replay.sessionSampleRate = 0;
    options.replay.onErrorSampleRate = 0;
    // NOTE: the feedback options getter is deliberately never
    // touched — accessing it registers the feedback integration.
  }

  // ── C1 allowlist scrub ──────────────────────────────────────────

  /// Static replacement for every exception value (C1/C7). An
  /// exception's rendered message can embed user content (a log
  /// sentence, a file name, a URL), so the value never leaves the
  /// device; the exception TYPE and stack trace (code identifiers
  /// only) carry the diagnostic signal.
  static const String scrubbedExceptionValue =
      '[scrubbed: exception value withheld — type and stack trace only]';

  /// Hint key marking an event as built by [captureError]: its
  /// exception value is a static, code-defined message (C7) and
  /// [scrubEvent] preserves it instead of substituting
  /// [scrubbedExceptionValue]. The hint never leaves the device —
  /// hints are SDK-internal and are not serialised into envelopes.
  static const String staticMessageHintKey = 'tabs.staticMessage';

  /// An exception type is a code identifier (a class name, possibly
  /// dotted). Anything else — spaces, '@', '/', a URL, free text —
  /// is not a type and is replaced, so a canary planted in the type
  /// field cannot ride out on the one field C1 keeps verbatim.
  static String sanitizeExceptionType(String? type) {
    if (type != null &&
        type.length <= 128 &&
        RegExp(r'^[A-Za-z_][A-Za-z0-9_.$]*$').hasMatch(type)) {
      return type;
    }
    return 'ScrubbedExceptionType';
  }

  // ── Condition 6 hardening (Juno diff review, C1 verbatim copies) ──

  /// Runtime names permitted in a scrubbed event (C1 permits the
  /// runtime context — Dart/Flutter version — and nothing else).
  /// Any other runtime name is a free-text string that could carry
  /// verbatim seeded/user text, so the whole runtime entry is
  /// dropped. Observed SDK runtimes are exactly these two
  /// (`Dart`, `Flutter`; see the Step-2 captured envelopes).
  static const Set<String> allowedRuntimeNames = {'Dart', 'Flutter'};

  /// A runtime version survives only when it is shaped like a
  /// version (`3.13.5`, `3.13.5 (stable)`, `3.47.7-dev.1`). Anything
  /// else — free text, an email, a URL, a medication string — is
  /// dropped (the runtime entry itself survives on its whitelisted
  /// name alone).
  static String? sanitizeRuntimeVersion(String? version) {
    if (version != null &&
        version.length <= 64 &&
        RegExp(r'^\d+(?:\.\d+){1,3}(?:[-+][0-9A-Za-z.-]+)?'
                r'(?: \([A-Za-z]+\))?$')
            .hasMatch(version)) {
      return version;
    }
    return null;
  }

  /// Mechanism scrub (Condition 6): `mechanism.data` is dropped
  /// ENTIRELY, along with `meta`, `description`, `helpLink`,
  /// `source` and any unknown fields — all are free-text / arbitrary
  /// maps that Juno recorded as verbatim copies of the source
  /// event. Only the mechanism's code-shaped fields survive: its
  /// type (identifier-shaped, else `generic`) and its boolean /
  /// numeric flags.
  static Mechanism? _scrubMechanism(Mechanism? mechanism) {
    if (mechanism == null) return null;
    final type = mechanism.type;
    return Mechanism(
      type: (type.length <= 128 &&
              RegExp(r'^[A-Za-z_][A-Za-z0-9_.$-]*$').hasMatch(type))
          ? type
          : 'generic',
      handled: mechanism.handled,
      synthetic: mechanism.synthetic,
      isExceptionGroup: mechanism.isExceptionGroup,
      exceptionId: mechanism.exceptionId,
      parentId: mechanism.parentId,
      // data: null, meta: null — dropped entirely (Condition 6).
    );
  }

  /// Frame-level scrub for stack traces (C1: frames/module/
  /// function — code identifiers only). Dropped per frame:
  /// absPath (absolute paths can contain the user's name), source
  /// context lines and frame vars (source text and runtime values
  /// can embed user content). fileName survives only when it names
  /// a Dart source — anything else (a document name planted in a
  /// frame, a data path) is dropped.
  static SentryStackTrace _scrubStackTrace(SentryStackTrace trace) {
    return SentryStackTrace(
      frames: trace.frames
          .map(
            (f) => SentryStackFrame(
              fileName: (f.fileName != null &&
                      (f.fileName!.endsWith('.dart') ||
                          f.fileName!.startsWith('dart:') ||
                          f.fileName!.startsWith('package:')))
                  ? f.fileName
                  : null,
              function: f.function,
              module: f.module,
              lineNo: f.lineNo,
              colNo: f.colNo,
              inApp: f.inApp,
              package: f.package,
            ),
          )
          .toList(),
    );
  }

  /// Rebuilds [event] from the C1 allowlist. Anything not listed
  /// here — including anything a future SDK version adds by
  /// default — is dropped.
  /// When [preserveStaticValue] is true (only for [captureError]
  /// events, signalled via [staticMessageHintKey]), exception
  /// values are kept: they are static code-defined literals by
  /// construction of the helper, never original exception text.
  static SentryEvent scrubEvent(SentryEvent event,
      {bool preserveStaticValue = false}) {
    final contexts = event.contexts;
    final app = contexts.app;
    final os = contexts.operatingSystem;
    final device = contexts.device;
    final tags = <String, String>{
      if (event.release != null) 'release': event.release!,
      if (event.environment != null) 'environment': event.environment!,
    };
    return SentryEvent(
      eventId: event.eventId,
      timestamp: event.timestamp,
      platform: event.platform,
      level: event.level,
      type: event.type,
      sdk: event.sdk,
      release: event.release,
      dist: event.dist,
      environment: event.environment,
      tags: tags,
      // user: null (C2) — never copied.
      // request: null (C3) — never copied.
      // breadcrumbs / extra / modules / fingerprint / threads /
      // message / transaction / serverName: never copied.
      exceptions: event.exceptions
          ?.map(
            (e) => SentryException(
              type: sanitizeExceptionType(e.type),
              value: preserveStaticValue
                  ? (e.value ?? scrubbedExceptionValue)
                  : scrubbedExceptionValue,
              module: e.module,
              stackTrace: e.stackTrace == null
                  ? null
                  : _scrubStackTrace(e.stackTrace!),
              // Condition 6: mechanism.data (and the other
              // free-text mechanism fields) never survive.
              mechanism: _scrubMechanism(e.mechanism),
              threadId: e.threadId,
            ),
          )
          .toList(),
      contexts: Contexts(
        app: app == null
            ? null
            : SentryApp(name: app.name, version: app.version, build: app.build),
        operatingSystem: os == null
            ? null
            : SentryOperatingSystem(name: os.name, version: os.version),
        device: device == null
            ? null
            : SentryDevice(
                // name and deviceUniqueIdentifier deliberately NOT
                // copied: a device name is user-chosen text and the
                // unique identifier is a hardware-class identifier —
                // both are outside C1/C5.
                model: device.model,
                manufacturer: device.manufacturer,
                family: device.family,
                arch: device.arch,
              ),
        // Condition 6: runtime context is whitelisted — only the
        // expected runtime names (Dart / Flutter) survive, and a
        // version survives only when it is version-shaped; a
        // seeded name or version string is dropped, never copied.
        runtimes: contexts.runtimes
            .where((r) => allowedRuntimeNames.contains(r.name))
            .map((r) => SentryRuntime(
                  name: r.name,
                  version: sanitizeRuntimeVersion(r.version),
                ))
            .toList(),
      ),
    );
  }

  // ── C7 captureError ─────────────────────────────────────────────

  /// Reports a handled (non-fatal) error from an ALLOWLISTED call
  /// site (the allowlist is filed with the diff in
  /// CRASH_REPORTING_CALLSITES.md; Juno reviews it under C7).
  ///
  /// Only the exception TYPE and [staticMessage] — a code-defined
  /// literal from the call site — are sent, plus a stack trace
  /// parsed to code identifiers (function / file / line). The
  /// original exception object and its rendered message NEVER reach
  /// the SDK, so a call site cannot leak user content through this
  /// helper even if the underlying exception embeds it.
  ///
  /// Never throws and never blocks the caller: fire-and-forget.
  /// With no DSN the SDK is uninitialised and this is a debugPrint
  /// line only.
  static void captureError(
    Object error, {
    StackTrace? stackTrace,
    required String staticMessage,
  }) {
    try {
      debugPrint(
          '[crash-reporting] captureError type=${error.runtimeType} msg=$staticMessage');
      // The SDK's own live state is the gate — not the compile-time
      // DSN constant — so this stays correct whatever path [run]
      // took (and in the inert path the hub simply does not exist).
      if (!Sentry.isEnabled) return;
      final event = SentryEvent(
        level: SentryLevel.error,
        exceptions: [
          SentryException(
            type: error.runtimeType.toString(),
            value: staticMessage,
            stackTrace: stackTrace == null
                ? null
                : parseStackTraceToFrames(stackTrace),
          ),
        ],
      );
      unawaited(Sentry.captureEvent(
        event,
        hint: Hint.withMap({staticMessageHintKey: true}),
      ));
    } catch (_) {
      // Reporting must never become a failure source itself.
    }
  }

  /// Parses a [StackTrace] into Sentry frames using only code
  /// identifiers (function, file, line, column). Lines that do not
  /// parse are skipped. Exposed for the canary/allowlist tests.
  static SentryStackTrace parseStackTraceToFrames(StackTrace stackTrace) {
    final frames = <SentryStackFrame>[];
    final linePattern = RegExp(r'^#\d+\s+(.+?)\s+\((.+?):(\d+):(\d+)\)\s*$');
    for (final line in stackTrace.toString().split('\n')) {
      final match = linePattern.firstMatch(line.trim());
      if (match == null) continue;
      frames.add(
        SentryStackFrame(
          function: match.group(1),
          fileName: match.group(2),
          lineNo: int.tryParse(match.group(3)!),
          colNo: int.tryParse(match.group(4)!),
        ),
      );
    }
    return SentryStackTrace(frames: frames.reversed.toList());
  }

  // ── Bootstrap + global handlers (C6) ────────────────────────────

  /// Runs the app behind the crash-reporting bootstrap.
  ///
  /// [appRunner] is the app's existing bootstrap (everything the old
  /// `main()` did, ending in `runApp`). With a DSN, the runner is
  /// executed inside SentryFlutter.init's appRunner so the SDK's
  /// own integrations are installed first; our handlers are then
  /// installed INSIDE the runner (see [_installHandlers]) so they
  /// chain onto Sentry's instead of competing with them. Without a
  /// DSN, only our local handlers are installed.
  ///
  /// [dsnOverride] / [transportOverride] / [environmentOverride]
  /// are test seams (capturing-transport canary gate + inertness
  /// proof); production calls [run] with no overrides.
  static Future<void> run(
    FutureOr<void> Function() appRunner, {
    String? dsnOverride,
    String? environmentOverride,
    Transport? transportOverride,
  }) async {
    final effectiveDsn = dsnOverride ?? dsn;
    if (effectiveDsn.isEmpty) {
      // C11 inert path: no SDK, no transport, no envelope can be
      // produced. Local handlers still improve on today's silence.
      _installHandlers(report: _reportLocally);
      final parentZone = Zone.current;
      await runZonedGuarded<Future<void>>(
        () async => appRunner(),
        _zoneErrorHandler(report: _reportLocally, parentZone: parentZone),
      );
      return;
    }
    await SentryFlutter.init(
      (options) => configureOptions(
        options,
        dsnValue: effectiveDsn,
        environment: environmentOverride ?? resolveEnvironment(),
        transport: transportOverride,
      ),
      appRunner: () async {
        _installHandlers(report: _reportToSentry);
        final parentZone = Zone.current;
        await runZonedGuarded<Future<void>>(
          () async => appRunner(),
          _zoneErrorHandler(report: _reportToSentry, parentZone: parentZone),
        );
      },
    );
  }

  /// Installs the global handlers (C6). [report] is the reporting
  /// sink for the mode we are in (Sentry when enabled, debugPrint
  /// when inert). Chaining contract:
  ///
  /// - FlutterError.onError: report, then call the previously
  ///   installed handler (Sentry's integration handler when
  ///   enabled — it reports through the SDK and chains to the
  ///   framework default; the framework default in the inert path —
  ///   it presents the error in debug). When no prior handler
  ///   exists, fall back to [FlutterError.presentError] in debug.
  /// - PlatformDispatcher.onError: report, then return the prior
  ///   handler's result, or `false` — never `true`, so the error is
  ///   never marked handled on our account.
  static void _installHandlers({
    required void Function(Object error, StackTrace stackTrace) report,
  }) {
    final priorFlutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      report(details.exception, details.stack ?? StackTrace.current);
      if (priorFlutterError != null) {
        priorFlutterError(details);
      } else if (kDebugMode) {
        FlutterError.presentError(details);
      }
    };

    final priorPlatformError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stackTrace) {
      report(error, stackTrace);
      return priorPlatformError?.call(error, stackTrace) ?? false;
    };
  }

  /// The zone handler used by [run]: reports, then FORWARDS the
  /// error to the parent zone's uncaught-error handler, so the
  /// error is treated exactly as it would be without us (C6 — no
  /// suppression, no silently-continuing app). Forwarding (rather
  /// than completing the zone future with the error or swallowing
  /// it) keeps the platform's uncaught-error path in charge.
  static void Function(Object, StackTrace) _zoneErrorHandler({
    required void Function(Object error, StackTrace stackTrace) report,
    required Zone parentZone,
  }) {
    return (error, stackTrace) {
      report(error, stackTrace);
      parentZone.handleUncaughtError(error, stackTrace);
    };
  }

  /// Inert-mode sink: log only. Nothing is stored, nothing is sent.
  static void _reportLocally(Object error, StackTrace stackTrace) {
    debugPrint('[crash-reporting] uncaught ${error.runtimeType}: $error');
    debugPrint('$stackTrace');
  }

  /// Enabled-mode sink: hand the error to the SDK. The event still
  /// passes through [scrubEvent] via beforeSend before any
  /// transport sees it.
  static void _reportToSentry(Object error, StackTrace stackTrace) {
    unawaited(Sentry.captureException(error, stackTrace: stackTrace));
  }

  // ── Lab-hook extension (Step-2 evidence; Juno Conditions 1 + 6, §7) ──

  /// MethodChannel to the Lab-only native crash trigger in
  /// MainActivity. The Kotlin side registers this channel ONLY when
  /// the build's applicationId is the Lab identity
  /// (`com.notel.notel.playground.flutter`); a production-flavor
  /// build (applicationId `com.notel.notel`) never registers it, so
  /// the method is unreachable there even before this Dart-side
  /// flavor gate is consulted.
  static const String nativeCrashChannelName =
      'com.notel.notel.playground.flutter/crash_test';
  static const String nativeCrashMethod = 'triggerNativeCrash';

  /// Fires the Kotlin-side native crash (Juno Condition 1: a
  /// native/Java event bypasses the Dart beforeSend allowlist, so
  /// only a genuine native crash can exercise that pipeline).
  ///
  /// Returns false WITHOUT touching the channel when this is not
  /// the Lab flavor — the production flavor can never reach the
  /// native trigger through Dart either. Channel errors
  /// (PlatformException / MissingPluginException) propagate to the
  /// caller: the hook card is UI code and must surface the error
  /// code visibly (team lesson — no silent channel failures).
  static Future<bool> triggerNativeTestCrash({
    String? flavor,
    MethodChannel? channel,
  }) async {
    if (!isLabFlavor(flavor: flavor)) return false;
    final ch = channel ?? const MethodChannel(nativeCrashChannelName);
    await ch.invokeMethod<void>(nativeCrashMethod);
    return true;
  }

  /// The R11 canary seed set (C8): exactly the nine synthetic
  /// values the canary gate in test/crash_reporting_test.dart uses.
  /// Synthetic values only — no real user data ever appears here,
  /// and the gate test asserts this map equals its own independent
  /// copy so the two can never drift apart silently.
  static const Map<String, String> labCanarySeeds = {
    'email': 'canary-email-7f3a@example.com',
    'accountId': 'canary-account-9182',
    'medication': 'CanaryMedication 42mg',
    'healthValue': 'canary-healthvalue-231',
    'logSentence': 'canary log sentence about my morning walk',
    'calendarTitle': 'canary-calendar-dentist-appointment',
    'documentFilename': 'canary-document-lab-results.pdf',
    'bearerToken': 'canary-bearer-token-abcdef0123',
    'urlWithQuery': 'https://example.com/path?canary-query=secret99',
  };

  /// Builds the seeded canary event for the LIVE pipeline (R11
  /// console-level repeat, Juno §7): the nine seeds sit in the same
  /// event positions the test gate seeds — exception type/value,
  /// user, request + auth header, breadcrumbs, message, extra,
  /// tags, device name/unique-id, custom contexts, and a stack
  /// frame's file name / abs path — PLUS the Condition 6 positions:
  /// exception `mechanism.data` and a runtime's name/version. The
  /// event is built to be captured through the real SDK pipeline;
  /// [scrubEvent] (via beforeSend) is what must strip every seed
  /// before transport.
  ///
  /// NOTE on the one SentryUser construction in lib/: it builds
  /// this SYNTHETIC seed (the canary account id/email above) so the
  /// live event proves the scrub drops `user` entirely. It is
  /// never fed account data — no other code in lib/ constructs a
  /// SentryUser, and the source-scan test pins the occurrence
  /// count to this one site.
  static SentryEvent buildLabCanaryEvent() {
    final c = labCanarySeeds;
    final contexts = Contexts(
      device: SentryDevice(
        name: c['calendarTitle'],
        model: 'Pixel 9a',
        manufacturer: 'Google',
        family: 'Pixel',
        arch: 'arm64',
        deviceUniqueIdentifier: c['accountId'],
      ),
      operatingSystem: SentryOperatingSystem(name: 'Android', version: '16'),
      app: SentryApp(name: 'Tabs Lab', version: '1.0.0', build: '1'),
      runtimes: [
        SentryRuntime(name: 'Dart', version: '3.13.5'),
        // Condition 6 seeds: canary runtime name + version.
        SentryRuntime(name: c['email'], version: c['medication']),
      ],
    );
    contexts['health'] = {'reading': c['healthValue']};
    contexts['flutter_error_details'] = {'information': c['logSentence']};
    return SentryEvent(
      level: SentryLevel.error,
      release: 'tabs_lab@1.0.0+1',
      environment: 'lab',
      // ignore: deprecated_member_use
      extra: {'note': c['logSentence'], 'med': c['medication']},
      tags: {'release': 'tabs_lab@1.0.0+1', 'evil': c['accountId']!},
      message: SentryMessage(c['logSentence']!),
      user: SentryUser(id: c['accountId'], email: c['email']),
      request: SentryRequest(
        url: c['urlWithQuery'],
        headers: {'Authorization': 'Bearer ${c['bearerToken']}'},
      ),
      breadcrumbs: [Breadcrumb(message: c['logSentence'])],
      exceptions: [
        SentryException(
          type: 'SeededException ${c['email']}',
          value:
              '${c['medication']} ${c['healthValue']} ${c['logSentence']} ${c['urlWithQuery']}',
          // Condition 6 seed: canaries inside mechanism.data.
          mechanism: Mechanism(
            type: 'generic',
            handled: false,
            data: {
              'seed_email': c['email']!,
              'seed_detail': c['logSentence']!,
              'seed_token': c['bearerToken']!,
            },
          ),
          stackTrace: SentryStackTrace(
            frames: [
              SentryStackFrame(
                function: 'seededFunction',
                fileName: c['documentFilename'],
                absPath: '/data/user/${c['accountId']}/seeded.dart',
                lineNo: 7,
                colNo: 3,
              ),
            ],
          ),
        ),
      ],
      contexts: contexts,
    );
  }

  /// Emits [buildLabCanaryEvent] through the LIVE pipeline
  /// (Juno §7 console-level R11 repeat): the app is already running
  /// under [run]'s real Sentry init on a DSN-live Lab build, so a
  /// plain capture here is the genuine init/capture path, not a
  /// test harness. Returns false — and captures nothing — when
  /// this is not the Lab flavor, or when Sentry is not enabled
  /// (empty DSN: there is no live pipeline to emit through, and
  /// claiming a send would be false evidence).
  static Future<bool> triggerLabCanaryTestEvent({String? flavor}) async {
    if (!isLabFlavor(flavor: flavor)) return false;
    if (!Sentry.isEnabled) return false;
    await Sentry.captureEvent(buildLabCanaryEvent());
    return true;
  }

  // ── Lab-only forced crash (C6 evidence hook) ────────────────────

  /// Throws an uncaught error on demand so the C6 evidence ("app
  /// visibly crashes; event arrives") can be exercised in the Lab
  /// flavor. Reachable only through the Lab-gated Settings hook
  /// (see CrashTestHook); [isLabFlavor] is the gate and a
  /// production-flavor build can never render that hook.
  static void forceTestCrash() {
    // Deliberately uncaught and asynchronous: it must travel the
    // real uncaught-error path (zone / PlatformDispatcher), not a
    // caught try/catch, or the evidence proves nothing.
    Future<void>(() {
      throw StateError(
          'Tabs Lab forced test crash (crash_reporting.dart forceTestCrash)');
    });
  }
}
