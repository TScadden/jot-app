import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:tabs_lab/src/data/crash_reporting.dart';
import 'package:tabs_lab/src/features/settings/crash_test_hook.dart';

/// Juno Ruling 2026-10-28 (Sentry Step-2 Phase 3) evidence tests.
///
/// - Registration verification (§1.6 Layer 1(2)): the Kotlin side's
///   present/replaced report is honoured, every failure shape lands
///   in [CrashReporting.nativeScrubRegistration] with a visible
///   error code, and the call order — registration immediately after
///   `SentryFlutter.init` returns, before the app runner / `runApp`
///   — is proven both dynamically (the outcome is already recorded
///   when the app runner executes) and by source scan.
/// - §3.2 geo removal: the send-path guard
///   ([NoUserKeyTransport]) strips a top-level `user` key from
///   outgoing event items and leaves everything else byte-identical;
///   through the real `CrashReporting.run` init path, captured Dart
///   envelopes carry no `user` key in any event item.
/// - Manifest (§1.4): both `io.sentry.*` meta-data entries are in
///   the app manifest (the merged-manifest-from-APK proof is filed
///   separately from the built Lab APK).

const String _testDsn =
    'https://0123456789abcdef0123456789abcdef@o0.ingest.sentry.io/1234567';

class _CapturingTransport implements Transport {
  final List<SentryEnvelope> envelopes = [];

  @override
  Future<SentryId?> send(SentryEnvelope envelope) async {
    envelopes.add(envelope);
    return envelope.header.eventId;
  }

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
        out.add({'item_type': item.header.type, 'payload': payload});
      }
    }
    return out;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await Sentry.close();
    CrashReporting.nativeScrubRegistration = null;
  });

  group('native scrub registration (§1.6 Layer 1(2))', () {
    const channel = MethodChannel(CrashReporting.nativeScrubChannelName);

    void mockHandler(Future<Object?> Function(MethodCall) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
    }

    test('success: present + replaced report is honoured', () async {
      var calls = 0;
      mockHandler((call) async {
        calls++;
        expect(call.method, CrashReporting.nativeScrubRegisterMethod);
        return <String, dynamic>{
          'sdkEnabled': true,
          'beforeSendPresent': true,
          'replaced': true,
        };
      });
      final outcome = await CrashReporting.registerNativeScrub();
      expect(calls, 1);
      expect(outcome.replaced, isTrue);
      expect(outcome.beforeSendPresent, isTrue);
      expect(outcome.errorCode, isNull);
      expect(CrashReporting.nativeScrubRegistration, same(outcome));
      expect(outcome.display, contains('REGISTERED'));
    });

    test('not replaced is a visible failure, never silent', () async {
      mockHandler((call) async => <String, dynamic>{
            'sdkEnabled': true,
            'beforeSendPresent': true,
            'replaced': false,
          });
      final outcome = await CrashReporting.registerNativeScrub();
      expect(outcome.replaced, isFalse);
      expect(outcome.errorCode, 'NATIVE_SCRUB_NOT_REPLACED');
      expect(outcome.display, contains('[NATIVE_SCRUB_NOT_REPLACED]'));
    });

    test('SDK not enabled is a visible failure', () async {
      mockHandler((call) async => <String, dynamic>{
            'sdkEnabled': false,
            'beforeSendPresent': false,
            'replaced': false,
          });
      final outcome = await CrashReporting.registerNativeScrub();
      expect(outcome.errorCode, 'NATIVE_SCRUB_SDK_NOT_ENABLED');
    });

    test('platform exception code is surfaced verbatim', () async {
      mockHandler((call) async {
        throw PlatformException(
            code: 'NATIVE_SCRUB_REGISTER_FAILED', message: 'boom');
      });
      final outcome = await CrashReporting.registerNativeScrub();
      expect(outcome.replaced, isFalse);
      expect(outcome.errorCode, 'NATIVE_SCRUB_REGISTER_FAILED');
      expect(outcome.display, contains('[NATIVE_SCRUB_REGISTER_FAILED]'));
    });

    test('missing plugin is a visible failure', () async {
      // No mock handler registered: the channel has no native side.
      final outcome = await CrashReporting.registerNativeScrub();
      expect(outcome.replaced, isFalse);
      expect(
        outcome.errorCode,
        anyOf('MISSING_PLUGIN', 'NATIVE_SCRUB_NO_RESULT'),
      );
    });

    test('run(): registration completes BEFORE the app runner runs',
        () async {
      mockHandler((call) async => <String, dynamic>{
            'sdkEnabled': true,
            'beforeSendPresent': true,
            'replaced': true,
          });
      NativeScrubRegistration? seenInsideRunner;
      await CrashReporting.run(
        () async {
          // The app runner is where _bootstrap ends in runApp: the
          // registration outcome must already be recorded here.
          seenInsideRunner = CrashReporting.nativeScrubRegistration;
        },
        dsnOverride: _testDsn,
        environmentOverride: 'lab',
        transportOverride: _CapturingTransport(),
      );
      expect(seenInsideRunner, isNotNull);
      expect(seenInsideRunner!.replaced, isTrue);
    });
  });

  group('call-order + wiring source scans (§1.6 Layer 1(2), §1.2)', () {
    final dart = File('lib/src/data/crash_reporting.dart').readAsStringSync();
    final mainActivity = File(
            'android/app/src/main/kotlin/com/notel/notel/playground/flutter/MainActivity.kt')
        .readAsStringSync();
    final scrubKotlin = File(
            'android/app/src/main/kotlin/com/notel/notel/playground/flutter/NativeCrashScrub.kt')
        .readAsStringSync();
    final registrationKotlin = File(
            'android/app/src/main/kotlin/com/notel/notel/playground/flutter/NativeScrubRegistration.kt')
        .readAsStringSync();

    test('run(): init returns, then registration, then the runner', () {
      final runStart = dart.indexOf('static Future<void> run(');
      expect(runStart, greaterThanOrEqualTo(0));
      final body = dart.substring(runStart);
      final initIndex = body.indexOf('await SentryFlutter.init(');
      final registerIndex = body.indexOf('await registerNativeScrub(');
      final runnerIndex = body.indexOf('() async => appRunner()', registerIndex);
      expect(initIndex, greaterThanOrEqualTo(0));
      expect(registerIndex, greaterThan(initIndex),
          reason: 'registration must follow SentryFlutter.init');
      expect(runnerIndex, greaterThan(registerIndex),
          reason: 'the app runner (runApp) must follow registration');
      // The init call itself takes no appRunner: nothing may run
      // the app before init has returned and registration has run.
      final initCall = body.substring(initIndex, registerIndex);
      expect(initCall.contains('appRunner:'), isFalse,
          reason: 'SentryFlutter.init must not receive the app runner');
    });

    test('Kotlin handler registered in configureFlutterEngine', () {
      final configureIndex = mainActivity.indexOf('fun configureFlutterEngine');
      expect(configureIndex, greaterThanOrEqualTo(0));
      final channelIndex =
          mainActivity.indexOf('SENTRY_SCRUB_CHANNEL', configureIndex);
      expect(channelIndex, greaterThan(configureIndex),
          reason: 'scrub channel must be registered in '
              'configureFlutterEngine (runs before the Dart entrypoint)');
      expect(mainActivity.contains('NativeScrubRegistration.register()'),
          isTrue);
    });

    test('registration replaces the slot on the live options', () {
      expect(registrationKotlin.contains('ScopesAdapter.getInstance()'), isTrue);
      expect(registrationKotlin.contains('getBeforeSend()'), isTrue);
      expect(registrationKotlin.contains('setBeforeSend('), isTrue);
      // Replace, do not chain: the registration never invokes a
      // previously installed callback.
      expect(registrationKotlin.contains('execute(event'), isFalse);
    });

    test('Kotlin scrub carries the exact Dart marker', () {
      expect(
        scrubKotlin.contains(
            '[scrubbed: exception value withheld — type and stack trace only]'),
        isTrue,
      );
      expect(
        CrashReporting.scrubbedExceptionValue,
        '[scrubbed: exception value withheld — type and stack trace only]',
      );
    });
  });

  group('§3.2 send-path guard (NoUserKeyTransport)', () {
    SentryEvent eventWithGeoUser() {
      return SentryEvent(
        platform: 'dart',
        user: SentryUser(
          id: 'geo-only-no-identity',
          geo: SentryGeo(city: 'Orem', countryCode: 'US', region: 'Utah'),
        ),
        exceptions: [
          SentryException(
            type: 'StateError',
            value: CrashReporting.scrubbedExceptionValue,
          ),
        ],
      );
    }

    test('an event item with a user key is stripped; others untouched',
        () async {
      // A non-event item stands in for the session item class:
      // the guard must never touch non-event items (§1.5 sessions
      // note) — verified here by object identity + byte identity.
      final attachmentItem = SentryEnvelopeItem.fromAttachment(
        SentryAttachment.fromIntList(
          utf8.encode('session-shaped-bytes'),
          'session.bin',
        ),
      );
      final base = SentryEnvelope.fromEvent(
        eventWithGeoUser(),
        SdkVersion(name: 'test', version: '0'),
      );
      final envelope = SentryEnvelope(
        base.header,
        [...base.items, attachmentItem],
        containsUnhandledException: true,
      );
      // Sanity: the seeded event item really carries a user key.
      final seededPayload = jsonDecode(
              utf8.decode(await envelope.items.first.dataFactory()))
          as Map<String, dynamic>;
      expect(seededPayload.containsKey('user'), isTrue);
      expect((seededPayload['user'] as Map)['geo']['city'], 'Orem');

      final stripped = await NoUserKeyTransport.stripUserKey(envelope);
      expect(identical(stripped, envelope), isFalse);
      expect(stripped.containsUnhandledException, isTrue);
      expect(identical(stripped.items[1], attachmentItem), isTrue);
      final payload = jsonDecode(
          utf8.decode(await stripped.items[0].dataFactory())) as Map;
      expect(payload.containsKey('user'), isFalse,
          reason: 'event item must carry NO user key at all (§3)');
      expect(payload['platform'], 'dart');
      expect(
        ((payload['exception'] as Map)['values'] as List).single['value'],
        CrashReporting.scrubbedExceptionValue,
      );
    });

    test('an envelope with no user key passes through as the same object',
        () async {
      final envelope = SentryEnvelope.fromEvent(
        SentryEvent(platform: 'dart'),
        SdkVersion(name: 'test', version: '0'),
      );
      final out = await NoUserKeyTransport.stripUserKey(envelope);
      expect(identical(out, envelope), isTrue,
          reason: 'byte-identity: nothing to strip, nothing re-encoded');
    });

    test('configureOptions installs the guard around the transport', () {
      final inner = _CapturingTransport();
      final options = SentryFlutterOptions(dsn: _testDsn);
      CrashReporting.configureOptions(
        options,
        dsnValue: _testDsn,
        environment: 'lab',
        transport: inner,
      );
      expect(options.transport, isA<NoUserKeyTransport>());
    });

    test('through run(): captured Dart envelopes carry no user key',
        () async {
      final transport = _CapturingTransport();
      await CrashReporting.run(
        () async {
          await Sentry.captureException(StateError('geo guard probe'));
          await Future<void>.delayed(const Duration(milliseconds: 300));
        },
        dsnOverride: _testDsn,
        environmentOverride: 'lab',
        transportOverride: transport,
      );
      final items = await transport.decodedItems();
      final events =
          items.where((i) => i['item_type'] == 'event').toList();
      expect(events, isNotEmpty);
      for (final item in events) {
        final payload = item['payload'] as Map<String, dynamic>;
        expect(payload.containsKey('user'), isFalse,
            reason: 'captured Dart event carries a user key (§3.2)');
      }
      expect(jsonEncode(items).contains('"user"'), isFalse);
    });
  });

  group('§1.4 manifest entries (source half)', () {
    test('both io.sentry meta-data entries are present and false', () {
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      for (final key in [
        'io.sentry.additional-context',
        'io.sentry.external-storage-context',
      ]) {
        final nameIndex = manifest.indexOf('android:name="$key"');
        expect(nameIndex, greaterThanOrEqualTo(0), reason: '$key missing');
        final valueIndex =
            manifest.indexOf('android:value="false"', nameIndex);
        expect(valueIndex, greaterThan(nameIndex),
            reason: '$key must be set to false');
      }
    });
  });

  group('Lab hook surface (§1.6 Layer 1(2) visible failure)', () {
    testWidgets('hook card renders the registration outcome with its code',
        (tester) async {
      CrashReporting.nativeScrubRegistration =
          const NativeScrubRegistration.failure(
        'NATIVE_SCRUB_NOT_REPLACED',
        'Native beforeSend slot was not replaced.',
      );
      addTearDown(() => CrashReporting.nativeScrubRegistration = null);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: CrashTestHook(visible: true)),
      ));
      expect(
          find.byKey(const ValueKey('crash_test_hook_scrub_status')),
          findsOneWidget);
      expect(find.textContaining('[NATIVE_SCRUB_NOT_REPLACED]'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
