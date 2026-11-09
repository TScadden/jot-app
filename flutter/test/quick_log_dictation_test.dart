import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/quick_log_cache.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/widget_sync.dart';
import 'package:tabs_lab/src/features/quicklog/quick_log_screen.dart';

import 'test_helpers.dart';

/// Founder report (Nov 9, 2026, with his own screenshot): dictating a
/// note into Quick Log with voice-to-text, the details field ends up
/// holding the FULL sentence ("feeling very tired after a long week")
/// while the "Your quick note" card below shows only the first words
/// ("feeling very") — his words: it "doesn't capture everything
/// because it's typing too fast."
///
/// Root cause pinned by this suite: the card renders
/// `_composedText()` — a snapshot taken when the State last built.
/// The `_manualController` listener in `_QuickLogScreenState` only
/// calls `setState` when the empty/non-empty boolean flips, so the
/// first dictation delivery builds the card with whatever text had
/// arrived by then, and every later (faster-than-a-frame) delivery
/// updates the controller — and the self-rendering field — without
/// ever rebuilding the card. These tests drive the REAL screen with
/// dictation-speed successive full-value deliveries (exactly how
/// Android voice typing streams results into a field) and require
/// the card to end up showing the complete final text.

const _cat = QuickLogCategory(
  id: 3,
  name: 'Symptoms',
  icon: 'circle',
  colorHex: '#4ECDC4',
  isDefault: true,
  sortOrder: 0,
);

TabsBackend _backend() {
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

/// The "Your quick note" card's composed-text widget: the one plain
/// [Text] on screen whose data starts with the dictated words (the
/// details field itself is an [EditableText], not a [Text]).
String? _cardText(WidgetTester tester) {
  final texts = tester
      .widgetList<Text>(find.byWidgetPredicate(
        (w) => w is Text && (w.data?.startsWith('feeling') ?? false),
      ))
      .toList();
  if (texts.isEmpty) return null;
  return texts.single.data;
}

void main() {
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
    WidgetSync.debugSetBridge(
      save: (key, value) async {},
      update: () async {},
    );
  });

  tearDown(() {
    LogEntryOutbox.instance.debugReset();
    QuickLogCache.instance.debugReset();
    HomeDataCache.instance.debugReset();
    WidgetSync.debugResetBridge();
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: QuickLogScreen(
        backend: _backend(),
        outbox: LogEntryOutbox.instance,
      ),
    ));
    // Let the background refresh fully land BEFORE any dictation, so
    // no refresh setState can mask the card-freeze mid-stream.
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
  }

  testWidgets(
      'control: a single full-sentence delivery shows in full in the '
      'quick note card', (tester) async {
    await pumpScreen(tester);
    await tester.enterText(
      find.byType(TextField),
      'feeling very tired after a long week',
    );
    await tester.pump();
    expect(find.text('Your quick note'), findsOneWidget);
    expect(_cardText(tester), 'feeling very tired after a long week');
  });

  testWidgets(
      'dictation-speed successive deliveries: the quick note card must '
      'end up with the COMPLETE final text, not the first delivery',
      (tester) async {
    await pumpScreen(tester);
    // Android voice typing streams successive full-value results into
    // the field, faster than frames matter. Deliver the sentence the
    // way the founder's recognizer did.
    const deliveries = [
      'feeling',
      'feeling very',
      'feeling very tired',
      'feeling very tired after',
      'feeling very tired after a long',
      'feeling very tired after a long week',
    ];
    for (final chunk in deliveries) {
      await tester.enterText(find.byType(TextField), chunk);
      await tester.pump();
    }
    expect(find.text('Your quick note'), findsOneWidget);
    expect(
      _cardText(tester),
      'feeling very tired after a long week',
      reason:
          'the card froze at an early dictation delivery while the field '
          'itself holds the full sentence — the founder-reported loss',
    );
  });
}
