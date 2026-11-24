import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/connections/connect_ai_screen.dart';

import 'test_helpers.dart';

/// MCP v1.1 — Connect an AI screen (Bram). The screen is see +
/// revoke only: these tests pin the list rendering (name +
/// connected date + last used), Juno's empty state, the
/// disconnect happy path (row removed after a successful
/// revoke), the failure path (error surfaced, row kept), and
/// the absence of any creation affordance or credential
/// display. Copy assertions use Juno's FINAL strings verbatim
/// (JUNO-COPY.md §c).

class FakeAiBackend extends TabsBackend {
  FakeAiBackend({
    required this.fetchResult,
    this.revokeResult = true,
    this.membershipResult =
        const (isUnlimited: true, isAdmin: false),
  }) : super(
          client: MockClient((_) async => http.Response('{}', 200)),
          sessionStore: FakeSessionStore(),
        );

  List<AiConnectionDto>? fetchResult;
  bool revokeResult;

  /// Premium-gate membership override. The default is a Premium
  /// verdict, so every pre-gate test below keeps exercising the
  /// shipped v1.1 list behavior with identical assertions. A
  /// null value simulates the entitlement fetch itself failing
  /// (fetchMembershipOrNull's failure shape).
  ({bool isUnlimited, bool isAdmin})? membershipResult;
  final List<String> revokedIds = [];

  @override
  Future<List<AiConnectionDto>?> fetchAiConnections() async => fetchResult;

  @override
  Future<({bool isUnlimited, bool isAdmin})?> fetchMembershipOrNull() async =>
      membershipResult;

  @override
  Future<bool> revokeAiConnection(String id) async {
    revokedIds.add(id);
    return revokeResult;
  }
}

AiConnectionDto _conn(
  String id,
  String name, {
  DateTime? connectedAt,
  DateTime? lastUsedAt,
}) =>
    AiConnectionDto(
      id: id,
      name: name,
      connectedAt: connectedAt,
      lastUsedAt: lastUsedAt,
    );

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  // Sync-settings package (Nov 23, 2026): the premium list grew
  // by the Part 3 header cards (address + Meta AI ID), which
  // pushed the connections section below the default 800x600
  // test viewport — and the screen's ListView builds lazily, so
  // the rows simply did not exist for the finders. Every test
  // in this file gets a tall surface instead.
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .single;
    view.physicalSize = const Size(1080, 3400);
    view.devicePixelRatio = 1.0;
    addTearDown(view.reset);
  });

  group('ConnectAiScreen', () {
    testWidgets('lists connections with name, connected date, last used',
        (tester) async {
      final backend = FakeAiBackend(fetchResult: [
        _conn('7', 'Claude',
            connectedAt: DateTime(2026, 11, 20),
            lastUsedAt: DateTime(2026, 11, 22)),
        _conn('9', 'My AI notes', connectedAt: DateTime(2026, 10, 3)),
      ]);
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      expect(find.text('Connect an AI'), findsOneWidget);
      expect(find.text('Claude'), findsOneWidget);
      expect(find.text('Connected Nov 20, 2026'), findsOneWidget);
      expect(find.text('Last used Nov 22, 2026'), findsOneWidget);
      expect(find.text('My AI notes'), findsOneWidget);
      expect(find.text('Connected Oct 3, 2026'), findsOneWidget);
      // No last-used line for a connection the server has
      // never reported use for.
      expect(find.textContaining('Last used'), findsOneWidget);
      // Juno's how-it-works line + blurb are on the screen.
      expect(find.text(ConnectAiCopy.howItWorks), findsOneWidget);
      expect(find.text(ConnectAiCopy.blurb), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);
    });

    testWidgets('empty state shows Juno copy when nothing is connected',
        (tester) async {
      final backend = FakeAiBackend(fetchResult: const []);
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      expect(find.text(ConnectAiCopy.emptyState), findsOneWidget);
      expect(find.text(ConnectAiCopy.disconnectButton), findsNothing);
    });

    testWidgets('load failure surfaces an error, not a silent empty list',
        (tester) async {
      final backend = FakeAiBackend(fetchResult: null);
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      expect(find.text(ConnectAiCopy.loadError), findsOneWidget);
      // A load failure must never assert "nothing connected":
      // Juno's empty state renders only when there is no load
      // error (Vera's condition on PR #144).
      expect(find.text(ConnectAiCopy.emptyState), findsNothing);
    });

    testWidgets('disconnect happy path: confirm removes the row',
        (tester) async {
      final backend = FakeAiBackend(fetchResult: [
        _conn('7', 'Claude', connectedAt: DateTime(2026, 11, 20)),
        _conn('9', 'My AI notes', connectedAt: DateTime(2026, 10, 3)),
      ]);
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('disconnect_7')));
      await tester.pumpAndSettle();

      // Juno's confirmation, verbatim with the name slotted in.
      expect(find.text('Disconnect Claude?'), findsOneWidget);
      expect(
        find.text(
            'Claude will stop being able to read your Tabs data right '
            'away. Anything it already read stays with that company, '
            'under its own privacy policy.'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('confirm_disconnect')));
      await tester.pumpAndSettle();

      expect(backend.revokedIds, ['7']);
      expect(find.text('Claude'), findsNothing);
      expect(find.text('My AI notes'), findsOneWidget);
    });

    testWidgets('disconnecting the last connection lands on the empty state',
        (tester) async {
      final backend = FakeAiBackend(fetchResult: [
        _conn('7', 'Claude', connectedAt: DateTime(2026, 11, 20)),
      ]);
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('disconnect_7')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm_disconnect')));
      await tester.pumpAndSettle();

      expect(find.text(ConnectAiCopy.emptyState), findsOneWidget);
    });

    testWidgets('disconnect failure keeps the row and surfaces an error',
        (tester) async {
      final backend = FakeAiBackend(
        fetchResult: [
          _conn('7', 'Claude', connectedAt: DateTime(2026, 11, 20)),
        ],
        revokeResult: false,
      );
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('disconnect_7')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm_disconnect')));
      await tester.pumpAndSettle();

      expect(backend.revokedIds, ['7']);
      expect(find.text('Claude'), findsOneWidget);
      expect(find.text(ConnectAiCopy.disconnectError), findsOneWidget);
    });

    testWidgets('cancelling the confirmation revokes nothing',
        (tester) async {
      final backend = FakeAiBackend(fetchResult: [
        _conn('7', 'Claude', connectedAt: DateTime(2026, 11, 20)),
      ]);
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('disconnect_7')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(ConnectAiCopy.cancelButton));
      await tester.pumpAndSettle();

      expect(backend.revokedIds, isEmpty);
      expect(find.text('Claude'), findsOneWidget);
    });

    testWidgets('help link opens the help page in the browser',
        (tester) async {
      Uri? opened;
      final backend = FakeAiBackend(fetchResult: const []);
      await tester.pumpWidget(_wrap(ConnectAiScreen(
        backend: backend,
        openUrl: (uri) async {
          opened = uri;
          return true;
        },
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.text(ConnectAiCopy.helpLinkLabel));
      await tester.pumpAndSettle();

      expect(
        opened,
        Uri.parse('https://jottracker.com/use-tabs-with-ai.html'),
      );
    });

    testWidgets('no creation affordance and no credential display',
        (tester) async {
      final backend = FakeAiBackend(fetchResult: [
        _conn('7', 'Claude', connectedAt: DateTime(2026, 11, 20)),
      ]);
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
      for (final banned in [
        'Create',
        'Add connection',
        'Add a connection',
        'Generate',
        'New connection',
      ]) {
        expect(find.textContaining(banned), findsNothing,
            reason: 'creation affordance leaked: $banned');
      }
      // No credential material of any kind renders.
      expect(find.textContaining('tabs_mcp_'), findsNothing);
      expect(find.textContaining('Bearer'), findsNothing);
    });

    // ── Premium gate (Juno Premium-gate pack §c, verbatim) ──

    testWidgets('free user sees the Premium state and no list',
        (tester) async {
      final backend = FakeAiBackend(
        fetchResult: const [],
        membershipResult: const (isUnlimited: false, isAdmin: false),
      );
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      // Screen title unchanged; Juno §c heading + explainer +
      // third-party line, verbatim literals.
      expect(find.text('Connect an AI'), findsOneWidget);
      expect(find.text('Connecting an AI needs Premium'), findsOneWidget);
      expect(
        find.text(
            'Connecting an AI lets it read your Tabs data — your log '
            'entries, Daily Scores, streak, gems, badges, and '
            'medications list — so you can ask it questions about '
            'your own data. It can only read, never change anything.'),
        findsOneWidget,
      );
      expect(
        find.text(
            "Once an app reads your data, that company keeps what "
            "it read under its own privacy policy — not Tabs'."),
        findsOneWidget,
      );
      expect(find.text('Upgrade to Premium'), findsOneWidget);
      expect(
          find.byKey(const ValueKey('upgrade_to_premium')), findsOneWidget);
      // No list, no v1.1 Premium-path copy, no empty state, and
      // no lapsed note for an account with no connections.
      expect(find.text(ConnectAiCopy.howItWorks), findsNothing);
      expect(find.text(ConnectAiCopy.blurb), findsNothing);
      expect(find.text(ConnectAiCopy.connectedLabel), findsNothing);
      expect(find.text(ConnectAiCopy.emptyState), findsNothing);
      expect(find.text(ConnectAiCopy.lapsedNote), findsNothing);
      expect(find.text(ConnectAiCopy.disconnectButton), findsNothing);
    });

    testWidgets(
        'lapsed user with connections sees the conditional note, '
        'never the rows', (tester) async {
      final backend = FakeAiBackend(
        fetchResult: [
          _conn('7', 'Claude', connectedAt: DateTime(2026, 11, 20)),
        ],
        membershipResult: const (isUnlimited: false, isAdmin: false),
      );
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      expect(find.text(ConnectAiCopy.premiumHeading), findsOneWidget);
      expect(
        find.text(
            "You already have connections. They're paused while "
            "Premium isn't active — not deleted, and if you "
            "resubscribe they'll work again with no need to "
            "reconnect."),
        findsOneWidget,
      );
      // The rows themselves never render in this state.
      expect(find.text('Claude'), findsNothing);
      expect(find.text(ConnectAiCopy.disconnectButton), findsNothing);
      expect(find.text(ConnectAiCopy.emptyState), findsNothing);
    });

    testWidgets('trial verdict takes the Premium path', (tester) async {
      // A running trial arrives as the same isUnlimited verdict
      // the server computes (the membershipLoader seam is where
      // that verdict enters the screen).
      final backend = FakeAiBackend(fetchResult: [
        _conn('7', 'Claude', connectedAt: DateTime(2026, 11, 20)),
      ]);
      await tester.pumpWidget(_wrap(ConnectAiScreen(
        backend: backend,
        membershipLoader: () async => true,
      )));
      await tester.pumpAndSettle();

      expect(find.text('Claude'), findsOneWidget);
      expect(find.text(ConnectAiCopy.premiumHeading), findsNothing);
      expect(find.text(ConnectAiCopy.upgradeButton), findsNothing);
    });

    testWidgets('admin verdict takes the Premium path', (tester) async {
      final backend = FakeAiBackend(
        fetchResult: [
          _conn('7', 'Claude', connectedAt: DateTime(2026, 11, 20)),
        ],
        membershipResult: const (isUnlimited: true, isAdmin: true),
      );
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      expect(find.text('Claude'), findsOneWidget);
      expect(find.text(ConnectAiCopy.premiumHeading), findsNothing);
    });

    testWidgets(
        'entitlement fetch failure fails closed: honest error, '
        'no list, no upsell', (tester) async {
      final backend = FakeAiBackend(
        fetchResult: [
          _conn('7', 'Claude', connectedAt: DateTime(2026, 11, 20)),
        ],
        membershipResult: null,
      );
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      expect(find.text(ConnectAiCopy.loadError), findsOneWidget);
      expect(find.text('Claude'), findsNothing);
      expect(find.text(ConnectAiCopy.premiumHeading), findsNothing);
      expect(find.text(ConnectAiCopy.upgradeButton), findsNothing);
      expect(find.text(ConnectAiCopy.emptyState), findsNothing);
    });

    testWidgets('explicit isUnlimited seam wins over the backend',
        (tester) async {
      // The fake backend's default verdict is Premium; the
      // explicit seam must still win (PatternsScreen pattern).
      final backend = FakeAiBackend(fetchResult: const []);
      await tester.pumpWidget(_wrap(ConnectAiScreen(
        backend: backend,
        isUnlimited: false,
      )));
      await tester.pumpAndSettle();

      expect(find.text(ConnectAiCopy.premiumHeading), findsOneWidget);
      expect(find.text(ConnectAiCopy.emptyState), findsNothing);
    });

    testWidgets(
        'RevenueCat verdict ORs in: Premium path even when the '
        'pull says non-member', (tester) async {
      final backend = FakeAiBackend(
        fetchResult: [
          _conn('7', 'Claude', connectedAt: DateTime(2026, 11, 20)),
        ],
        membershipResult: const (isUnlimited: false, isAdmin: false),
      );
      await tester.pumpWidget(_wrap(ConnectAiScreen(
        backend: backend,
        revenueCatPremium: true,
      )));
      await tester.pumpAndSettle();

      expect(find.text('Claude'), findsOneWidget);
      expect(find.text(ConnectAiCopy.premiumHeading), findsNothing);
    });

    testWidgets(
        'RevenueCat verdict ORs in: Premium path even when the '
        'entitlement fetch fails', (tester) async {
      final backend = FakeAiBackend(
        fetchResult: [
          _conn('7', 'Claude', connectedAt: DateTime(2026, 11, 20)),
        ],
        membershipResult: null,
      );
      await tester.pumpWidget(_wrap(ConnectAiScreen(
        backend: backend,
        revenueCatPremium: true,
      )));
      await tester.pumpAndSettle();

      expect(find.text('Claude'), findsOneWidget);
      expect(find.text(ConnectAiCopy.loadError), findsNothing);
    });

    testWidgets('upgrade button pops with the upgrade-request result',
        (tester) async {
      final backend = FakeAiBackend(
        fetchResult: const [],
        membershipResult: const (isUnlimited: false, isAdmin: false),
      );
      Object? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              result = await Navigator.of(ctx).push<String>(
                MaterialPageRoute<String>(
                  builder: (_) => ConnectAiScreen(backend: backend),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text(ConnectAiCopy.premiumHeading), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('upgrade_to_premium')));
      await tester.pumpAndSettle();

      expect(result, ConnectAiScreen.upgradeRequestResult);
      expect(find.text(ConnectAiCopy.premiumHeading), findsNothing);
    });
  });

  group('AiConnectionDto.fromJson', () {
    test('parses the v1 payload shape', () {
      final dto = AiConnectionDto.fromJson({
        'id': 7,
        'name': 'Claude',
        'token_prefix': 'tabs_mcp_ab12',
        'created_at': '2026-11-20T15:04:05.000Z',
        'last_used_at': null,
        'revoked_at': null,
      });
      expect(dto, isNotNull);
      expect(dto!.id, '7');
      expect(dto.name, 'Claude');
      expect(dto.connectedAt, isNotNull);
      expect(dto.lastUsedAt, isNull);
    });

    test('revoked rows (either flag shape) are excluded', () {
      expect(
        AiConnectionDto.fromJson({
          'id': 1,
          'name': 'Old',
          'revoked_at': '2026-11-21T00:00:00.000Z',
        }),
        isNull,
      );
      expect(
        AiConnectionDto.fromJson({'id': 2, 'name': 'Old', 'revoked': true}),
        isNull,
      );
    });

    test('unknown extra fields are tolerated', () {
      final dto = AiConnectionDto.fromJson({
        'id': 'abc',
        'name': 'Future Client',
        'created_at': '2026-11-20T15:04:05.000Z',
        'source': 'oauth',
        'expires_at': '2027-01-01T00:00:00.000Z',
      });
      expect(dto, isNotNull);
      expect(dto!.name, 'Future Client');
    });
  });

  group('TabsBackend.fetchAiConnections', () {
    TabsBackend backendFor(http.Response Function(http.Request) handler) {
      final store = FakeSessionStore()..token = 'test-token';
      return TabsBackend(
        client: MockClient((req) async => handler(req)),
        sessionStore: store,
      );
    }

    test('reads the tokens envelope and filters revoked rows', () async {
      final backend = backendFor((req) {
        expect(req.url.path, '/api/api-tokens');
        return http.Response(
          jsonEncode({
            'success': true,
            'tokens': [
              {
                'id': 7,
                'name': 'Claude',
                'token_prefix': 'tabs_mcp_ab12',
                'created_at': '2026-11-20T15:04:05.000Z',
                'last_used_at': '2026-11-22T09:00:00.000Z',
                'revoked_at': null,
              },
              {
                'id': 8,
                'name': 'Revoked One',
                'created_at': '2026-11-01T00:00:00.000Z',
                'revoked_at': '2026-11-02T00:00:00.000Z',
              },
            ],
          }),
          200,
        );
      });
      final list = await backend.fetchAiConnections();
      expect(list, isNotNull);
      expect(list!.map((c) => c.name), ['Claude']);
      expect(list.single.lastUsedAt, isNotNull);
    });

    test('returns null on a non-200 so the screen can show its error',
        () async {
      final backend = backendFor((_) => http.Response('nope', 500));
      expect(await backend.fetchAiConnections(), isNull);
    });

    test('revoke posts to the per-connection revoke path', () async {
      Uri? seen;
      final backend = backendFor((req) {
        seen = req.url;
        return http.Response('{"success":true}', 200);
      });
      expect(await backend.revokeAiConnection('7'), isTrue);
      expect(seen!.path, '/api/api-tokens/7/revoke');
    });
  });
}
