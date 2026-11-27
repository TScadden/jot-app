import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/onboarding_store.dart';
import 'package:tabs_lab/src/data/quick_log_cache.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/voice_input.dart';
import 'package:tabs_lab/src/data/widget_sync.dart';
import 'package:tabs_lab/src/features/onboarding/profile_setup_screen.dart';
import 'package:tabs_lab/src/features/quicklog/quick_log_screen.dart';

import 'test_helpers.dart';

/// Juno pre-submission sweep (Nov 22, 2026) — Item A pins.
///
/// Voice input has a native handler only on Android
/// (MainActivity.kt's RecognizerIntent path); iOS never registered
/// one, so every iOS mic tap used to surface the fallback string.
/// The ruling: hide the mic affordances on iOS (Quick Log suffix,
/// Profile Setup button + 'Tap the mic to talk' label, Body workout
/// button), keep them untouched on Android, and make the fallback
/// string a device truth. These tests pin the Quick Log and Profile
/// Setup surfaces plus the gate and the fallback string.
///
/// The platform override follows the revenuecat_service_test.dart
/// pattern: reset in a finally INSIDE the test body (the binding
/// verifies foundation debug vars are unset before tearDown runs).

const _cat = QuickLogCategory(
  id: '3',
  name: 'Symptoms',
  icon: 'circle',
  colorHex: '#4ECDC4',
  isDefault: true,
  sortOrder: 0,
);

TabsBackend _quickLogBackend() {
  final store = FakeSessionStore()..token = 'test-token';
  final client = MockClient((request) async {
    if (request.url.path == '/api/sync/pull') {
      return http.Response(
        jsonEncode({
          'entries': <dynamic>[],
          'categories': [_cat.toSyncJson()],
          'profile': <String, dynamic>{},
          'isUnlimited': true,
          'isAdmin': false,
        }),
        200,
      );
    }
    return http.Response('not found', 404);
  });
  return TabsBackend(client: client, sessionStore: store);
}

class _FakeProfileBackend extends TabsBackend {
  @override
  Future<Map<String, dynamic>?> fetchProfile() async => null;
  @override
  Future<bool> fetchIsUnlimited() async => false;
  @override
  Future<bool> postSyncProfile(Map<String, dynamic> fields) async => true;
}

class _FakeVoice extends VoiceInput {
  @override
  Future<String> startVoiceInput() async => 'dictated words';
}

OnboardingStore _fakeOnboardingStore(Map<String, String> map) =>
    OnboardingStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );

void _platformTestWidgets(
  String name,
  TargetPlatform platform,
  Future<void> Function(WidgetTester tester) body,
) {
  testWidgets(name, (tester) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final outboxDisk = <String, String>{};
    LogEntryOutbox.instance.debugReset();
    LogEntryOutbox.instance.debugSetStore(
      read: (key) async => outboxDisk[key],
      write: (key, value) async => outboxDisk[key] = value,
      delete: (key) async => outboxDisk.remove(key),
    );
    final quickDisk = <String, String>{};
    QuickLogCache.instance.debugReset();
    QuickLogCache.instance.debugSetStore(
      read: (key) async => quickDisk[key],
      write: (key, value) async => quickDisk[key] = value,
      delete: (key) async => quickDisk.remove(key),
    );
    final homeDisk = <String, String>{};
    HomeDataCache.instance.debugReset();
    HomeDataCache.instance.debugSetStore(
      read: (key) async => homeDisk[key],
      write: (key, value) async => homeDisk[key] = value,
      delete: (key) async => homeDisk.remove(key),
    );
    WidgetSync.debugSetBridge(save: (key, value) async {}, update: () async {});
  });

  tearDown(() {
    LogEntryOutbox.instance.debugReset();
    QuickLogCache.instance.debugReset();
    HomeDataCache.instance.debugReset();
    WidgetSync.debugResetBridge();
  });

  group('VoiceInput.isSupported gate', () {
    test('true on Android, false on iOS', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        expect(VoiceInput.isSupported, isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        expect(VoiceInput.isSupported, isFalse);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test(
      'missing-handler fallback message is the device-truth string',
      () async {
        // No handler is registered for the voice channel in tests, so
        // the call lands in the MissingPluginException branch — the
        // exact path every iOS tap used to take.
        await expectLater(
          VoiceInput().startVoiceInput(),
          throwsA(
            isA<VoiceInputException>().having(
              (e) => e.message,
              'message',
              'Voice input is not available on this device.',
            ),
          ),
        );
      },
    );
  });

  group('Quick Log mic affordance (A-S1)', () {
    Future<void> pumpQuickLog(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: QuickLogScreen(
            backend: _quickLogBackend(),
            outbox: LogEntryOutbox.instance,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);
    }

    _platformTestWidgets(
      'Android: mic suffix shows while the details field is empty',
      TargetPlatform.android,
      (tester) async {
        await pumpQuickLog(tester);
        expect(find.byTooltip('Voice Input'), findsOneWidget);
        expect(find.byIcon(Icons.mic), findsOneWidget);
      },
    );

    _platformTestWidgets(
      'iOS: no mic suffix while the details field is empty',
      TargetPlatform.iOS,
      (tester) async {
        await pumpQuickLog(tester);
        expect(find.byTooltip('Voice Input'), findsNothing);
        expect(find.byIcon(Icons.mic), findsNothing);
      },
    );
  });

  group('Profile Setup mic affordance (A-S2)', () {
    Future<void> pumpProfile(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileSetupScreen(
            onBack: () {},
            onNavigateNext: () {},
            onboardingStore: _fakeOnboardingStore({}),
            backend: _FakeProfileBackend(),
            voiceInput: _FakeVoice(),
          ),
        ),
      );
      await tester.pump();
    }

    _platformTestWidgets(
      'Android: mic button and talk label show',
      TargetPlatform.android,
      (tester) async {
        await pumpProfile(tester);
        expect(
          find.byKey(const ValueKey('profile_mic_button')),
          findsOneWidget,
        );
        expect(find.text('Tap the mic to talk'), findsOneWidget);
      },
    );

    _platformTestWidgets(
      'iOS: mic button and talk label are both hidden',
      TargetPlatform.iOS,
      (tester) async {
        await pumpProfile(tester);
        expect(find.byKey(const ValueKey('profile_mic_button')), findsNothing);
        expect(find.text('Tap the mic to talk'), findsNothing);
      },
    );
  });
}
