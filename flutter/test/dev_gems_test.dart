import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/settings/dev_gems.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';

import 'test_helpers.dart';

/// Dev gems grant (DEV GEMS package, Nov 27, 2026) — acceptance:
/// (a) the button renders inside the settings dev area ONLY when
///     the pulled `dev_access` is true;
/// (b) a confirmed tap calls POST /api/gems/dev-grant through the
///     gem service and adopts the returned server balance;
/// (c) a 403 (or any failure) leaves the balance untouched and
///     surfaces an honest error;
/// (d) cancelling the confirm dialog calls nothing.
/// The confirm dialog strings are Juno's ruling
/// (build-dev-gems/JUNO-RELEASE-NOTES.md §3), byte-exact.
class _FakeBackend extends TabsBackend {
  final Map<String, dynamic> pull;
  _FakeBackend({super.sessionStore, required this.pull});

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async => pull;
}

SettingsStore _fakeStore(Map<String, String> map) =>
    SettingsStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );

Map<String, dynamic> _pull({bool? devAccess}) {
  return {
    'isUnlimited': false,
    'isAdmin': false,
    'nickname': 'Tyson',
    'tag': '1234',
    'profile': <String, dynamic>{
      'dev_access': ?devAccess,
    },
    'insights': const [],
  };
}

/// A GemService wired to a scripted dev-grant transport, seeded
/// at balance 500 through the real pull path.
GemService _service({
  required Future<GemRequestResult> Function(String grantId) devGrant,
  List<String>? capturedIds,
}) {
  final disk = <String, String>{};
  final s = GemService(
    grant: (_) async => (statusCode: 200, body: null),
    spend: (_) async => (statusCode: 200, body: null),
    pullBalance: () async => 500,
    devGrant: (id) {
      capturedIds?.add(id);
      return devGrant(id);
    },
  );
  s.debugSetStore(
    read: (k) async => disk[k],
    write: (k, v) async => disk[k] = v,
    delete: (k) async => disk.remove(k),
  );
  return s;
}

Future<GemService> _seededService({
  required Future<GemRequestResult> Function(String grantId) devGrant,
  List<String>? capturedIds,
}) async {
  final s = _service(devGrant: devGrant, capturedIds: capturedIds);
  await s.refreshBalance();
  expect(s.balance, 500);
  return s;
}

void main() {
  group('GemService.devGrant', () {
    test('success adopts the returned server balance', () async {
      final ids = <String>[];
      final gems = await _seededService(
        capturedIds: ids,
        devGrant: (_) async => (
          statusCode: 200,
          body: {'granted': 1000, 'balance': 1500, 'replayed': false},
        ),
      );
      final r = await gems.devGrant();
      expect(r.status, GemDevGrantStatus.success);
      expect(r.granted, 1000);
      expect(r.balance, 1500);
      expect(gems.balance, 1500,
          reason: 'the returned balance is adopted, like a spend');
      expect(ids, hasLength(1));
      expect(ids.single, isNotEmpty);
    });

    test('each deliberate grant generates a fresh grantId', () async {
      final ids = <String>[];
      final gems = await _seededService(
        capturedIds: ids,
        devGrant: (_) async => (
          statusCode: 200,
          body: {'granted': 1000, 'balance': 1500, 'replayed': false},
        ),
      );
      await gems.devGrant();
      await gems.devGrant();
      expect(ids, hasLength(2));
      expect(ids[0], isNot(ids[1]),
          reason: 'repeated deliberate grants are separate ledger '
              'entries — never a replay of the first tap');
    });

    test('a replayed grantId answer is a replay, balance adopted',
        () async {
      final gems = await _seededService(
        devGrant: (_) async => (
          statusCode: 200,
          body: {'granted': 1000, 'balance': 1500, 'replayed': true},
        ),
      );
      final r = await gems.devGrant(grantId: 'fixed-id');
      expect(r.status, GemDevGrantStatus.replay);
      expect(gems.balance, 1500);
    });

    test('403 (not a dev account) leaves the balance untouched',
        () async {
      final gems = await _seededService(
        devGrant: (_) async => (
          statusCode: 403,
          body: {'error': 'dev_access_required'},
        ),
      );
      final r = await gems.devGrant();
      expect(r.status, GemDevGrantStatus.forbidden);
      expect(r.balance, isNull);
      expect(gems.balance, 500, reason: 'no credit, no adoption');
    });

    test('transport failure leaves the balance untouched', () async {
      final gems = await _seededService(
        devGrant: (_) async => (statusCode: null, body: null),
      );
      final r = await gems.devGrant();
      expect(r.status, GemDevGrantStatus.failed);
      expect(gems.balance, 500);
    });

    test('server error leaves the balance untouched', () async {
      final gems = await _seededService(
        devGrant: (_) async => (
          statusCode: 500,
          body: {'error': 'internal'},
        ),
      );
      final r = await gems.devGrant();
      expect(r.status, GemDevGrantStatus.failed);
      expect(gems.balance, 500);
    });

    test('a throwing transport is a failure, never a grant', () async {
      final gems = await _seededService(
        devGrant: (_) async => throw StateError('socket gone'),
      );
      final r = await gems.devGrant();
      expect(r.status, GemDevGrantStatus.failed);
      expect(gems.balance, 500);
    });
  });

  group('TabsBackend.devGrantGems — the fixed contract', () {
    test('POSTs {grantId} to /api/gems/dev-grant and returns the '
        'decoded body', () async {
      late http.Request captured;
      final session = FakeSessionStore()..token = 'tok-123';
      final backend = TabsBackend(
        sessionStore: session,
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({'granted': 1000, 'balance': 1500, 'replayed': false}),
            200,
          );
        }),
      );
      final r = await backend.devGrantGems('grant-abc');
      expect(captured.method, 'POST');
      expect(captured.url.path, '/api/gems/dev-grant');
      expect(jsonDecode(captured.body), {'grantId': 'grant-abc'});
      expect(captured.headers['Authorization'], 'Bearer tok-123');
      expect(r.statusCode, 200);
      expect(r.body, {'granted': 1000, 'balance': 1500, 'replayed': false});
    });

    test('a 403 answer passes through with its status', () async {
      final session = FakeSessionStore()..token = 'tok-123';
      final backend = TabsBackend(
        sessionStore: session,
        client: MockClient((_) async =>
            http.Response(jsonEncode({'error': 'dev_access_required'}), 403)),
      );
      final r = await backend.devGrantGems('grant-abc');
      expect(r.statusCode, 403);
    });
  });

  group('DevGemsEntry widget', () {
    Future<void> pumpEntry(WidgetTester tester, GemService gems) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: DevGemsEntry(gemService: gems)),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('button carries the byte-exact label', (tester) async {
      final gems = await _seededService(
        devGrant: (_) async => (statusCode: 200, body: null),
      );
      await pumpEntry(tester, gems);
      expect(find.text('Grant 1,000 gems (dev)'), findsOneWidget);
      expect(find.byKey(const Key('devGemsGrantButton')), findsOneWidget);
    });

    testWidgets('confirm dialog carries Juno\'s ruled strings; '
        'Cancel calls nothing', (tester) async {
      var calls = 0;
      final gems = await _seededService(
        devGrant: (_) async {
          calls++;
          return (statusCode: 200, body: null);
        },
      );
      await pumpEntry(tester, gems);
      await tester.tap(find.byKey(const Key('devGemsGrantButton')));
      await tester.pumpAndSettle();
      expect(find.text('Grant 1,000 gems?'), findsOneWidget);
      expect(
        find.text('This adds 1,000 real, spendable gems to your '
            'account. The grant is logged as a dev grant.'),
        findsOneWidget,
      );
      expect(find.text('Grant gems'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      await tester.tap(find.byKey(const Key('devGemsCancelButton')));
      await tester.pumpAndSettle();
      expect(calls, 0, reason: 'a cancelled confirm grants nothing');
      expect(gems.balance, 500);
      expect(find.byKey(const Key('devGemsStatus')), findsNothing);
    });

    testWidgets('confirmed grant adopts the balance and shows the '
        'new balance', (tester) async {
      final gems = await _seededService(
        devGrant: (_) async => (
          statusCode: 200,
          body: {'granted': 1000, 'balance': 1500, 'replayed': false},
        ),
      );
      await pumpEntry(tester, gems);
      await tester.tap(find.byKey(const Key('devGemsGrantButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('devGemsConfirmButton')));
      await tester.pumpAndSettle();
      expect(gems.balance, 1500);
      expect(
        find.text('Granted 1,000 gems. New balance: 1500 gems.'),
        findsOneWidget,
      );
    });

    testWidgets('403 surfaces an honest error and changes no '
        'balance', (tester) async {
      final gems = await _seededService(
        devGrant: (_) async => (
          statusCode: 403,
          body: {'error': 'dev_access_required'},
        ),
      );
      await pumpEntry(tester, gems);
      await tester.tap(find.byKey(const Key('devGemsGrantButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('devGemsConfirmButton')));
      await tester.pumpAndSettle();
      expect(gems.balance, 500);
      final status = find.byKey(const Key('devGemsStatus'));
      expect(status, findsOneWidget);
      expect(
        (tester.widget<Text>(status)).data,
        contains('403'),
      );
      expect((tester.widget<Text>(status)).data,
          contains('Nothing was granted'));
    });
  });

  group('Settings render — the dev gems gate', () {
    Future<void> pumpSettings(
      WidgetTester tester,
      Map<String, dynamic> pull,
    ) async {
      tester.view.physicalSize = const Size(1080, 3400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          backend: _FakeBackend(
            sessionStore: FakeSessionStore(),
            pull: pull,
          ),
          settingsStore: _fakeStore(<String, String>{}),
          notificationService: FakeReminderNotificationService(),
          urlLauncher: (uri) async => true,
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('(a) dev_access true → the grant button renders '
        'inside the Developer Terminal', (tester) async {
      await pumpSettings(tester, _pull(devAccess: true));
      final entry = find.byKey(const ValueKey('developer_terminal_entry'));
      expect(entry, findsOneWidget);
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.text('Grant 1,000 gems (dev)'), findsOneWidget);
      expect(find.byKey(const Key('devGemsGrantButton')), findsOneWidget);
    });

    testWidgets('(b) dev_access false → no grant button anywhere',
        (tester) async {
      await pumpSettings(tester, _pull(devAccess: false));
      expect(find.text('Grant 1,000 gems (dev)'), findsNothing);
      expect(find.byKey(const Key('devGemsGrantButton')), findsNothing);
    });

    testWidgets('(b) dev_access absent → no grant button anywhere',
        (tester) async {
      await pumpSettings(tester, _pull());
      expect(find.text('Grant 1,000 gems (dev)'), findsNothing);
      expect(find.byKey(const Key('devGemsGrantButton')), findsNothing);
    });
  });
}
