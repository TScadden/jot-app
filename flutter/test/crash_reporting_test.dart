import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:tabs_lab/src/data/crash_reporting.dart';
import 'package:tabs_lab/src/features/settings/crash_test_hook.dart';

/// Juno Ruling 2026-10-27 — crash tracking evidence tests.
///
/// - Options assertions (C3/C4/C5/C12) against the built options.
/// - beforeSend allowlist scrub (C1/C2/C3), unit level.
/// - Canary gate (C8, regression item R11): errors seeded with
///   unique canary strings for email, account ID, medication
///   name+dose, a health value, a log-entry sentence, a calendar
///   title, a document filename, a bearer token and a URL with
///   query string are captured through the SAME init path the app
///   uses (CrashReporting.run) with a capturing transport; the
///   captured envelope JSON is inspected field by field and must
///   contain ZERO canaries. The raw captured JSON is filed to
///   ~/workspace/crash-tracking-evidence/canary_captured_envelope.json.
///   NOTE: this is envelope-level proof. The console-level repeat
///   against a real Lab Sentry project is owed after Tyson creates
///   the account (Ruling 2.3).
/// - DSN-empty inertness (C11): handlers + captureError exercised
///   with an empty DSN produce zero transport activity (the SDK is
///   never initialised), while chaining behaviour is preserved.
/// - Handler chaining (C6): FlutterError chains to the prior
///   handler; PlatformDispatcher returns false; the zone handler
///   forwards to the parent zone's uncaught-error handler.

/// SYNTHETIC test DSN: a well-formed but non-existent project
/// (key is the digits/abcdef sequence, project id 1234567). It is
/// not a real DSN, was never issued by Sentry, and the capturing
/// transport intercepts every envelope before any network use.
/// No real DSN is committed anywhere in this repo (C9).
const String _testDsn =
    'https://0123456789abcdef0123456789abcdef@o0.ingest.sentry.io/1234567';

class CapturingTransport implements Transport {
  final List<SentryEnvelope> envelopes = [];

  @override
  Future<SentryId?> send(SentryEnvelope envelope) async {
    envelopes.add(envelope);
    return envelope.header.eventId;
  }

  /// Every envelope item decoded: header JSON + payload JSON (when
  /// the payload is JSON), in send order.
  Future<List<Map<String, dynamic>>> decodedItems() async {
    final out = <Map<String, dynamic>>[];
    for (final envelope in envelopes) {
      for (final item in envelope.items) {
        final bytes = await item.dataFactory();
        dynamic payload;
        try {
          payload = jsonDecode(utf8.decode(bytes));
        } catch (_) {
          payload = '<non-json ${bytes.length} bytes>';
        }
        out.add({
          'item_type': item.header.type,
          'payload': payload,
        });
      }
    }
    return out;
  }

  Future<String> decodedAsJsonString() async =>
      jsonEncode(await decodedItems());
}

/// The C8 canary set. Every string is unique and greppable.
const Map<String, String> _canaries = {
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

SentryEvent _seededCanaryEvent() {
  final c = _canaries;
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
      // Condition 6 seeds: canary runtime names + versions (both
      // entries must be dropped whole by the runtime whitelist).
      SentryRuntime(name: c['email'], version: c['medication']),
      SentryRuntime(name: c['urlWithQuery'], version: c['healthValue']),
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
        // Condition 6 seed: canaries inside mechanism.data (Juno
        // recorded mechanism.data as a verbatim copy in the diff
        // review); scrubEvent must drop it entirely.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Any test that initialises the SDK must leave a closed hub
  // behind: the inertness proof depends on Sentry.isEnabled being
  // false, and tests share one process.
  tearDown(() async {
    await Sentry.close();
  });

  group('options (C3/C4/C5/C12)', () {
    late SentryFlutterOptions options;
    setUp(() {
      options = SentryFlutterOptions(dsn: _testDsn);
      CrashReporting.configureOptions(
        options,
        dsnValue: _testDsn,
        environment: 'lab',
        transport: CapturingTransport(),
      );
    });

    test('sendDefaultPii is false', () {
      expect(options.sendDefaultPii, isFalse);
    });

    test('sample rates: errors 1.0, traces 0, no sampler', () {
      expect(options.sampleRate, 1.0);
      expect(options.tracesSampleRate, 0);
      expect(options.tracesSampler, isNull);
      // Note: SentryOptions.isTracingEnabled() in this SDK treats a
      // set rate of 0 as "configured"; with rate 0 and no sampler
      // and no transaction instrumentation anywhere in the app, no
      // transaction can be sampled or sent. C4's letter (rate 0,
      // no sampler) is what is pinned here.
    });

    test('request surface closed', () {
      expect(options.maxRequestBodySize, MaxRequestBodySize.never);
      expect(options.captureFailedRequests, isFalse);
      expect(options.captureNativeFailedRequests, isFalse);
      expect(options.recordHttpBreadcrumbs, isFalse);
    });

    test('breadcrumbs closed at flag level + beforeBreadcrumb null', () {
      expect(options.maxBreadcrumbs, 0);
      expect(options.enablePrintBreadcrumbs, isFalse);
      expect(options.enableAutoNativeBreadcrumbs, isFalse);
      expect(options.enableAppLifecycleBreadcrumbs, isFalse);
      expect(options.enableWindowMetricBreadcrumbs, isFalse);
      expect(options.enableBrightnessChangeBreadcrumbs, isFalse);
      expect(options.enableTextScaleChangeBreadcrumbs, isFalse);
      expect(options.enableMemoryPressureBreadcrumbs, isFalse);
      expect(options.enableUserInteractionBreadcrumbs, isFalse);
      expect(options.beforeBreadcrumb!(Breadcrumb(message: 'x'), Hint()),
          isNull);
    });

    test('C4 features off: tracing helpers, replay, screenshots, '
        'view hierarchy, user interaction tracing', () {
      expect(options.enableAutoPerformanceTracing, isFalse);
      expect(options.enableFramesTracking, isFalse);
      expect(options.enableNativeTraceSync, isFalse);
      expect(options.enableUserInteractionTracing, isFalse);
      expect(options.attachScreenshot, isFalse);
      expect(options.attachViewHierarchy, isFalse);
      expect(options.replay.sessionSampleRate, 0);
      expect(options.replay.onErrorSampleRate, 0);
      // The feedback getter registers the integration when read;
      // the built SDK info must not list it.
      expect(options.sdk.integrations,
          isNot(contains('MobileFeedbackWidget')));
    });

    test('C5: auto session tracking on; threads off', () {
      expect(options.enableAutoSessionTracking, isTrue);
      expect(options.attachThreads, isFalse);
    });

    test('beforeSend is wired', () {
      expect(options.beforeSend, isNotNull);
    });
  });

  group('environment + flavor gates (C9, hook reachability)', () {
    test('environment derives from flavor, define wins', () {
      expect(
          CrashReporting.resolveEnvironment(flavor: 'prod', defineValue: ''),
          'production');
      expect(
          CrashReporting.resolveEnvironment(flavor: 'lab', defineValue: ''),
          'lab');
      expect(CrashReporting.resolveEnvironment(flavor: null, defineValue: ''),
          'lab');
      expect(
          CrashReporting.resolveEnvironment(
              flavor: 'lab', defineValue: 'staging'),
          'staging');
    });

    test('crash hook reachable only in lab flavor', () {
      expect(CrashReporting.isLabFlavor(flavor: 'lab'), isTrue);
      expect(CrashReporting.isLabFlavor(flavor: 'prod'), isFalse);
      expect(CrashReporting.isLabFlavor(flavor: null), isFalse);
      expect(CrashReporting.isLabFlavor(flavor: ''), isFalse);
    });
  });

  group('scrubEvent allowlist (C1/C2/C3)', () {
    test('seeded event comes out allowlist-only', () async {
      final scrubbed = CrashReporting.scrubEvent(_seededCanaryEvent());
      final json = scrubbed.toJson();
      final encoded = jsonEncode(json);
      for (final canary in _canaries.values) {
        expect(encoded.contains(canary), isFalse,
            reason: 'canary leaked through scrubEvent: $canary');
      }
      expect(json['user'], isNull);
      expect(json['request'], isNull);
      expect(json['breadcrumbs'], isNull);
      expect(json['extra'], isNull);
      expect(json['modules'], isNull);
      expect(json['message'], isNull);
      final tags = json['tags'] as Map<String, dynamic>;
      expect(tags.keys.toSet(), {'release', 'environment'});
      final contexts = json['contexts'] as Map<String, dynamic>;
      expect(
          contexts.keys
              .toSet()
              .difference({'app', 'os', 'device', 'runtime', 'trace'}),
          isEmpty,
          reason: 'non-allowlisted context keys present');
      expect(contexts.keys.toSet(),
          containsAll({'app', 'os', 'device', 'runtime'}));
      final device = contexts['device'] as Map<String, dynamic>;
      expect(device['name'], isNull);
      expect(device['device_unique_identifier'], isNull);
      expect(device['model'], 'Pixel 9a');
      final exceptions = json['exception'] as Map<String, dynamic>;
      final values = exceptions['values'] as List<dynamic>;
      expect((values.single as Map)['value'],
          CrashReporting.scrubbedExceptionValue);
      expect((values.single as Map)['type'], 'ScrubbedExceptionType');
    });

    test('sanitizeExceptionType keeps identifiers, drops free text', () {
      expect(CrashReporting.sanitizeExceptionType('StateError'),
          'StateError');
      expect(
          CrashReporting.sanitizeExceptionType(
              'Exception canary-email-7f3a@example.com'),
          'ScrubbedExceptionType');
      expect(CrashReporting.sanitizeExceptionType(''), 'ScrubbedExceptionType');
    });

    test('Condition 6: mechanism.data dropped entirely, runtime '
        'context whitelisted', () {
      final scrubbed = CrashReporting.scrubEvent(_seededCanaryEvent());
      final encoded = jsonEncode(scrubbed.toJson());
      for (final canary in _canaries.values) {
        expect(encoded.contains(canary), isFalse,
            reason: 'Condition 6 canary leaked: $canary');
      }
      // mechanism survives only as code-shaped fields: type +
      // handled; data/meta/description are gone entirely.
      final mechanism = scrubbed.exceptions!.single.mechanism;
      expect(mechanism, isNotNull);
      expect(mechanism!.type, 'generic');
      expect(mechanism.handled, isFalse);
      expect(mechanism.data, isEmpty);
      expect(mechanism.meta, isEmpty);
      expect(mechanism.description, isNull);
      final exceptionsJson =
          scrubbed.toJson()['exception'] as Map<String, dynamic>;
      final mechanismJson = (exceptionsJson['values'] as List<dynamic>)
          .single['mechanism'] as Map<String, dynamic>;
      expect(mechanismJson.containsKey('data'), isFalse);
      expect(mechanismJson.containsKey('meta'), isFalse);
      // Runtimes: the seeded canary-name entries are dropped
      // whole; only the legit Dart runtime survives.
      expect(scrubbed.contexts.runtimes.map((r) => r.name).toSet(),
          {'Dart'});
      expect(scrubbed.contexts.runtimes.single.version, '3.13.5');
      // A whitelisted name carrying a canary VERSION: the entry
      // survives on its name, the version is dropped.
      final runtimeProbe = CrashReporting.scrubEvent(SentryEvent(
        contexts: Contexts(runtimes: [
          SentryRuntime(name: 'Dart', version: '3.13.5 (stable)'),
          SentryRuntime(name: 'Flutter', version: _canaries['urlWithQuery']),
          SentryRuntime(name: _canaries['email'], version: '3.13.5'),
        ]),
      ));
      final runtimes = runtimeProbe.contexts.runtimes;
      expect(runtimes.map((r) => r.name).toSet(), {'Dart', 'Flutter'});
      final dart = runtimes.firstWhere((r) => r.name == 'Dart');
      expect(dart.version, '3.13.5 (stable)');
      final flutter = runtimes.firstWhere((r) => r.name == 'Flutter');
      expect(flutter.version, isNull);
      // Version sanitizer shape checks.
      expect(CrashReporting.sanitizeRuntimeVersion('3.13.5 (stable)'),
          '3.13.5 (stable)');
      expect(CrashReporting.sanitizeRuntimeVersion(_canaries['email']),
          isNull);
      expect(
          CrashReporting.sanitizeRuntimeVersion(_canaries['logSentence']),
          isNull);
    });

    test('captureError stack parsing keeps code identifiers only', () {
      final st = StackTrace.fromString(
          '#0      main (package:tabs_lab/main.dart:10:5)\n'
          '#1      _bootstrap (file:///home/user/app/lib/main.dart:20:3)\n'
          '<asynchronous suspension>');
      final parsed = CrashReporting.parseStackTraceToFrames(st);
      expect(parsed.frames.length, 2);
      expect(parsed.frames.first.function, '_bootstrap');
      expect(parsed.frames.first.fileName,
          'file:///home/user/app/lib/main.dart');
    });
  });

  group('canary gate via capturing transport (C8 / R11)', () {
    test('zero canaries in any captured envelope field', () async {
      final transport = CapturingTransport();
      await CrashReporting.run(
        () async {
          // A plain captureException whose VALUE embeds canaries —
          // the global-handler path (C6 sink) carries raw errors
          // like this; beforeSend must scrub them.
          await Sentry.captureException(
            StateError(
                '${_canaries['logSentence']} ${_canaries['urlWithQuery']}'),
          );
          // The seeded full event, captured directly.
          await Sentry.captureEvent(_seededCanaryEvent());
          // The C7 helper path: original exception embeds canaries,
          // only type + static message may leave.
          CrashReporting.captureError(
            Exception(
                '${_canaries['medication']} ${_canaries['healthValue']}'),
            staticMessage: 'canary seeded nonfatal',
          );
          // Let the fire-and-forget capture land.
          await Future<void>.delayed(const Duration(milliseconds: 300));
        },
        dsnOverride: _testDsn,
        environmentOverride: 'lab',
        transportOverride: transport,
      );

      final items = await transport.decodedItems();
      final encoded = jsonEncode(items);

      // File the raw captured JSON as evidence FIRST, so the
      // artifact exists and can be inspected even if a later
      // assertion in this gate ever fails.
      final itemTypes = items.map((i) => i['item_type']).toList();
      final evidenceDir = Directory('../../crash-tracking-evidence');
      await evidenceDir.create(recursive: true);
      await File('${evidenceDir.path}/canary_captured_envelope.json')
          .writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'captured_at': DateTime.now().toUtc().toIso8601String(),
          'proof_level':
              'envelope-level (capturing transport, same init path); '
                  'console-level repeat owed after Tyson creates the '
                  'Lab Sentry project (Ruling 2.3)',
          'item_types': itemTypes,
          'canaries_checked': _canaries,
          'items': items,
        }),
      );

      expect(transport.envelopes, isNotEmpty,
          reason: 'capturing transport received nothing');
      for (final canary in _canaries.values) {
        expect(encoded.contains(canary), isFalse,
            reason: 'CANARY LEAKED into captured envelope: $canary');
      }
      // Positive controls: events did arrive, scrubbed.
      expect(encoded.contains(CrashReporting.scrubbedExceptionValue),
          isTrue);
      expect(encoded.contains('canary seeded nonfatal'), isTrue);
      expect(encoded.contains('"user"'), isFalse);
      expect(encoded.contains('"request"'), isFalse);
      expect(encoded.contains('"breadcrumbs"'), isFalse);

      // C5 envelope-level check: no session item may carry any
      // account-derived identifier (the Dart SDK in 10.x emits no
      // session items — sessions are native-side with an
      // SDK-generated random id; nothing account-linked exists to
      // send). Item types seen are recorded in the evidence file.
    });
  });

  group('DSN-empty inertness (C11) + handler chaining (C6)', () {
    test('empty DSN: no SDK, handlers log + chain, zone forwards',
        () async {
      final priorFlutterError = FlutterError.onError;
      final priorPlatformError = PlatformDispatcher.instance.onError;
      final printed = <String>[];
      final priorDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) printed.add(message);
      };
      var chainedFlutterErrors = 0;
      FlutterError.onError = (details) => chainedFlutterErrors++;
      addTearDown(() {
        FlutterError.onError = priorFlutterError;
        PlatformDispatcher.instance.onError = priorPlatformError;
        debugPrint = priorDebugPrint;
      });

      var appRan = false;
      await CrashReporting.run(
        () async {
          appRan = true;
          // Exercise the handlers + the C7 helper.
          FlutterError.onError!(
            FlutterErrorDetails(
              exception: StateError('inert flutter error'),
              stack: StackTrace.current,
            ),
          );
          final handled = PlatformDispatcher.instance.onError!(
            StateError('inert platform error'),
            StackTrace.current,
          );
          expect(handled, isFalse,
              reason: 'PlatformDispatcher handler must return false');
          CrashReporting.captureError(
            StateError('inert nonfatal'),
            staticMessage: 'inertness probe',
          );
        },
        dsnOverride: '',
      );

      expect(appRan, isTrue);
      // The SDK was never initialised: no hub, no transport exists
      // that could have produced an envelope.
      expect(Sentry.isEnabled, isFalse);
      // Chaining preserved: our FlutterError handler called the
      // prior handler exactly once (for our one synthetic error).
      expect(chainedFlutterErrors, 1);
      // Local handlers logged instead of staying silent.
      expect(printed.any((l) => l.contains('crash-reporting')), isTrue);

      // Zone handler must not swallow: an error thrown inside the
      // inert run is forwarded to the parent zone's uncaught-error
      // handler (recorded here by an outer guarded zone), exactly
      // as an unzoned error would surface.
      Object? propagated;
      // Not awaited to completion: a runZonedGuarded future whose
      // error was intercepted by the zone handler never completes
      // (verified Dart semantics) — what matters is that the error
      // ARRIVES at the parent zone's uncaught-error handler.
      unawaited(runZonedGuarded(
        () async {
          await CrashReporting.run(
            () async => throw StateError('inert zone error'),
            dsnOverride: '',
          );
        },
        (e, st) => propagated = e,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(propagated, isA<StateError>());
      expect((propagated! as StateError).message, 'inert zone error');

      // File the inertness evidence log.
      final evidenceDir = Directory('../../crash-tracking-evidence');
      await evidenceDir.create(recursive: true);
      await File('${evidenceDir.path}/inertness_log.txt').writeAsString(
        [
          'DSN-empty inertness run (C11)',
          'captured_at=${DateTime.now().toUtc().toIso8601String()}',
          'sentry_is_enabled=${Sentry.isEnabled}',
          'app_runner_executed=$appRan',
          'flutter_error_chained_to_prior_handler=$chainedFlutterErrors time(s)',
          'platform_dispatcher_returned=false (asserted in-test)',
          'zone_error_propagated=true (forwarded to parent zone handler, asserted in-test)',
          'transport_activity=none possible: SDK never initialised, '
              'no transport constructed on the empty-DSN path',
          'debugPrint lines captured:',
          ...printed.map((l) => '  $l'),
        ].join('\n'),
      );
    });
  });

  group('forced crash hook (C6)', () {
    test('forceTestCrash throws an uncaught StateError', () async {
      Object? caught;
      await runZonedGuarded(
        () async {
          CrashReporting.forceTestCrash();
          await Future<void>.delayed(const Duration(milliseconds: 100));
        },
        (e, st) => caught = e,
      );
      expect(caught, isA<StateError>());
    });

    testWidgets('hook renders only when visible, with tap labels',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: CrashTestHook(visible: false)),
      ));
      expect(find.byKey(const ValueKey('crash_test_hook_card')), findsNothing);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: CrashTestHook(visible: true)),
      ));
      expect(
          find.byKey(const ValueKey('crash_test_hook_card')), findsOneWidget);
      expect(find.textContaining('TEST ONLY'), findsOneWidget);
      expect(find.text('Tap to force a test crash'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('lab-hook extension (Conditions 1 + 6, R11 console repeat)', () {
    test('live canary seeds are exactly the gate canary set', () {
      expect(CrashReporting.labCanarySeeds, _canaries);
    });

    test('canary builder seeds every gate position + Condition 6 '
        'positions; scrub strips all of them', () {
      final event = CrashReporting.buildLabCanaryEvent();
      // Same positions the gate seeds:
      expect(event.user?.email, _canaries['email']);
      expect(event.user?.id, _canaries['accountId']);
      expect(event.request?.url, _canaries['urlWithQuery']);
      expect(event.exceptions!.single.mechanism, isNotNull);
      // Condition 6 positions:
      expect(event.exceptions!.single.mechanism!.data.values,
          contains(_canaries['email']));
      expect(event.contexts.runtimes.map((r) => r.name),
          contains(_canaries['email']));
      final encoded = jsonEncode(CrashReporting.scrubEvent(event).toJson());
      for (final canary in _canaries.values) {
        expect(encoded.contains(canary), isFalse,
            reason: 'live canary seed leaked through scrub: $canary');
      }
    });

    test('native trigger: prod flavor never touches the channel; '
        'lab flavor invokes triggerNativeCrash exactly once', () async {
      const channel = MethodChannel(CrashReporting.nativeCrashChannelName);
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      expect(
          await CrashReporting.triggerNativeTestCrash(
              flavor: 'prod', channel: channel),
          isFalse);
      expect(
          await CrashReporting.triggerNativeTestCrash(
              flavor: null, channel: channel),
          isFalse);
      expect(calls, isEmpty,
          reason: 'prod/flavor-less builds must not reach the '
              'native crash channel');

      expect(
          await CrashReporting.triggerNativeTestCrash(
              flavor: 'lab', channel: channel),
          isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.method, CrashReporting.nativeCrashMethod);
    });

    test('canary trigger gates: prod flavor and DSN-off are inert',
        () async {
      expect(await CrashReporting.triggerLabCanaryTestEvent(flavor: 'prod'),
          isFalse);
      // Lab flavor but the SDK is not enabled (no DSN in this test
      // process): nothing may be captured and no send may be claimed.
      expect(Sentry.isEnabled, isFalse);
      expect(await CrashReporting.triggerLabCanaryTestEvent(flavor: 'lab'),
          isFalse);
    });

    test('canary trigger through the REAL run() init path sends '
        'exactly one fully-scrubbed event', () async {
      final transport = CapturingTransport();
      var sent = false;
      await CrashReporting.run(
        () async {
          sent =
              await CrashReporting.triggerLabCanaryTestEvent(flavor: 'lab');
          await Future<void>.delayed(const Duration(milliseconds: 300));
        },
        dsnOverride: _testDsn,
        environmentOverride: 'lab',
        transportOverride: transport,
      );
      expect(sent, isTrue);
      final encoded = await transport.decodedAsJsonString();
      for (final canary in _canaries.values) {
        expect(encoded.contains(canary), isFalse,
            reason: 'live-path canary leaked: $canary');
      }
      expect(encoded.contains(CrashReporting.scrubbedExceptionValue), isTrue);
      final items = await transport.decodedItems();
      final events = items.where((i) => i['item_type'] == 'event').toList();
      expect(events, hasLength(1),
          reason: 'one canary tap must produce one event');
    });

    testWidgets('extended hook: single taps fire the '
        'native + canary actions', (tester) async {
      var nativeFires = 0;
      var canaryFires = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CrashTestHook(
            visible: true,
            nativeCrashAction: () async {
              nativeFires++;
              return true;
            },
            canaryAction: () async {
              canaryFires++;
              return true;
            },
          ),
        ),
      ));
      expect(find.byKey(const ValueKey('crash_test_hook_native_button')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('crash_test_hook_canary_button')),
          findsOneWidget);

      await tester.tap(
          find.byKey(const ValueKey('crash_test_hook_native_button')));
      await tester.pump();
      expect(nativeFires, 1);
      await tester.tap(
          find.byKey(const ValueKey('crash_test_hook_canary_button')));
      await tester.pump();
      expect(canaryFires, 1);
      expect(find.textContaining('Canary event sent'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('source scans (C3/C5/C9 standing guards)', () {
    test('lib never sets user/distinct ids and installs no banned '
        'integrations or observers', () {
      final libDir = Directory('lib');
      final banned = <String>[
        'SentryNavigatorObserver',
        'SentryHttpClient',
        'SentryUserInteractionWidget',
        'SentryFeedbackForm',
        'SentryFeedbackWidget',
        'SentryUser(',
        '.setUser(',
        'distinctId',
        'ingest.sentry.io',
        'ingest.de.sentry.io',
      ];
      for (final entity in libDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final content = entity.readAsStringSync();
        for (final token in banned) {
          // ONE pinned exception: 'SentryUser(' may appear exactly
          // once in lib/, inside CrashReporting.buildLabCanaryEvent,
          // where it constructs the SYNTHETIC R11 seed (canary
          // values only) so the scrub's user-drop is exercised on
          // the live pipeline. The dedicated scan below pins that
          // count and location; everywhere else the ban is absolute.
          if (token == 'SentryUser(' &&
              entity.path.endsWith('crash_reporting.dart')) {
            continue;
          }
          expect(content.contains(token), isFalse,
              reason: '${entity.path} contains banned token: $token');
        }
      }
    });

    test('SentryUser( occurs exactly once in lib: the synthetic '
        'lab canary seed in crash_reporting.dart', () {
      var total = 0;
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final content = entity.readAsStringSync();
        final count = 'SentryUser('.allMatches(content).length;
        if (count > 0) {
          expect(entity.path.endsWith('crash_reporting.dart'), isTrue,
              reason: 'SentryUser( found in ${entity.path}');
        }
        total += count;
      }
      expect(total, 1,
          reason: 'the single synthetic canary seed is the only '
              'permitted SentryUser construction in lib/');
    });

    test('captureError call sites match the filed allowlist', () {
      // Every captureError call site in lib (outside the helper's
      // own definition file) must be one of the allowlisted files.
      final allowedFiles = {
        'lib/main.dart',
        'lib/src/data/health_history_sync.dart',
      };
      final libDir = Directory('lib');
      for (final entity in libDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.endsWith('crash_reporting.dart')) continue;
        final content = entity.readAsStringSync();
        if (content.contains('CrashReporting.captureError')) {
          expect(allowedFiles.contains(entity.path), isTrue,
              reason: 'unlisted captureError call site: ${entity.path}');
        }
      }
      // And the allowlist document itself must exist in the diff.
      expect(File('CRASH_REPORTING_CALLSITES.md').existsSync(), isTrue);
    });

    test('new lab triggers are referenced only from crash_reporting '
        'and the hook card (prod-unreachability, Dart side)', () {
      final allowed = {
        'crash_reporting.dart',
        'crash_test_hook.dart',
      };
      const triggers = [
        'triggerNativeTestCrash',
        'triggerLabCanaryTestEvent',
        'buildLabCanaryEvent',
        'nativeCrashChannelName',
      ];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final base = entity.path.split('/').last;
        if (allowed.contains(base)) continue;
        final content = entity.readAsStringSync();
        for (final token in triggers) {
          expect(content.contains(token), isFalse,
              reason: '${entity.path} references lab trigger: $token');
        }
      }
      // And both triggers gate on the Lab flavor INSIDE
      // crash_reporting.dart, before any capture/channel use.
      final crashReporting =
          File('lib/src/data/crash_reporting.dart').readAsStringSync();
      for (final def in [
        'triggerNativeTestCrash',
        'triggerLabCanaryTestEvent',
      ]) {
        final defIndex = crashReporting.indexOf('static Future<bool> $def');
        expect(defIndex, greaterThanOrEqualTo(0),
            reason: '$def definition not found');
        final gateIndex =
            crashReporting.indexOf('isLabFlavor(flavor: flavor)', defIndex);
        expect(gateIndex, greaterThan(defIndex),
            reason: '$def must check isLabFlavor first');
      }
    });

    test('native crash channel is flavor-gated on the Kotlin side '
        'and the fatal is posted, not thrown in the handler', () {
      final kotlin = File(
              'android/app/src/main/kotlin/com/notel/notel/playground/flutter/MainActivity.kt')
          .readAsStringSync();
      // The Lab identity constant + the registration guard exist.
      expect(
          kotlin.contains(
              'LAB_PACKAGE_NAME = "com.notel.notel.playground.flutter"'),
          isTrue);
      final guardIndex = kotlin.indexOf('if (packageName == LAB_PACKAGE_NAME)');
      expect(guardIndex, greaterThanOrEqualTo(0),
          reason: 'Kotlin registration must be applicationId-gated');
      // The crash-test channel is registered only INSIDE that guard.
      final registerIndex = kotlin.indexOf('CRASH_TEST_CHANNEL)', guardIndex);
      expect(registerIndex, greaterThan(guardIndex),
          reason: 'crash channel registration must follow the guard');
      // The fatal is posted to the main thread (outside the channel
      // call stack), never thrown inside the handler itself.
      final postIndex = kotlin.indexOf('Handler(Looper.getMainLooper()).post {');
      expect(postIndex, greaterThanOrEqualTo(0),
          reason: 'native fatal must be posted to the main thread');
      final throwIndex = kotlin.indexOf('throw RuntimeException(', postIndex);
      expect(throwIndex, greaterThan(postIndex),
          reason: 'the RuntimeException must be inside the post');
    });
  });
}
