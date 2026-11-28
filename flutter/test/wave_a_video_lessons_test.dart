import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/quick_log_cache.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/widget_sync.dart';
import 'package:tabs_lab/src/features/auth/login_screen.dart';
import 'package:tabs_lab/src/features/home/daily_score_circle.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_header.dart';
import 'package:tabs_lab/src/features/quicklog/history_screen.dart';
import 'package:tabs_lab/src/features/quicklog/quick_log_screen.dart';
import 'package:tabs_lab/src/theme/animations.dart';

import 'test_helpers.dart';

/// Video-lessons Wave A — acceptance tests for the SCORECARD-3 /
/// SCORECARD-9 clear wins:
/// - auth keyboard submit + the `_isLoading` entry guards (#5/#1),
/// - email blur validation (#7),
/// - credential autofill hints (SCORECARD-9 #15-adjacent),
/// - 48dp hit boxes for "Forgot Password?" and onboarding "Skip"
///   (#2 / #13 combined pass),
/// - tabular figures on numeric readouts (SCORECARD-9 #16),
/// - History delete Undo toast (SCORECARD-9 #5).

class _FakeAuthApi extends AuthApiClient {
  int loginCalls = 0;
  int registerCalls = 0;
  Completer<LoginResult>? loginGate;

  @override
  Future<LoginResult> login({
    required String email,
    required String password,
  }) async {
    loginCalls++;
    final gate = loginGate;
    if (gate != null) return gate.future;
    return const LoginFailure(LoginFailureKind.server, 'nope');
  }

  @override
  Future<LoginResult> register({
    required String email,
    required String password,
    required bool ageConfirmed,
  }) async {
    registerCalls++;
    return const LoginFailure(LoginFailureKind.server, 'nope');
  }

  @override
  Future<ForgotPasswordResult> forgotPassword({
    required String email,
  }) async =>
      const ForgotPasswordSuccess();
}

Future<void> _pumpLogin(
  WidgetTester tester,
  _FakeAuthApi api, {
  bool registerMode = false,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: LoginScreen(
      initialRegisterMode: registerMode,
      authApi: api,
      sessionStore: FakeSessionStore(),
    ),
  ));
  await tester.pump();
}

void main() {
  setUp(() => TabsBackend.debugResetSharedCaches());

  group('auth keyboard submit (SCORECARD-3 #5 + #1 guards)', () {
    testWidgets('email field: action is next, Enter moves focus to '
        'the password field', (tester) async {
      final api = _FakeAuthApi();
      await _pumpLogin(tester, api);
      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(2));
      final emailField = tester.widget<TextField>(fields.at(0));
      final passwordField = tester.widget<TextField>(fields.at(1));
      expect(emailField.textInputAction, TextInputAction.next);
      expect(passwordField.textInputAction, TextInputAction.done);

      await tester.enterText(fields.at(0), 'person@tabs.app');
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pump();
      expect(passwordField.focusNode!.hasFocus, isTrue);
      expect(api.loginCalls, 0);
    });

    testWidgets('password Enter submits login; a second Enter while '
        'in flight cannot double-fire (entry guard)', (tester) async {
      final api = _FakeAuthApi()..loginGate = Completer<LoginResult>();
      await _pumpLogin(tester, api);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'person@tabs.app');
      await tester.enterText(fields.at(1), 'secret');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(api.loginCalls, 1);
      // Second keyboard submit while the first is still in flight.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(api.loginCalls, 1);

      api.loginGate!.complete(
        const LoginFailure(LoginFailureKind.server, 'nope'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('login_error')), findsOneWidget);
    });

    testWidgets('register mode: password Enter submits register',
        (tester) async {
      final api = _FakeAuthApi();
      await _pumpLogin(tester, api, registerMode: true);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'new@tabs.app');
      await tester.enterText(fields.at(1), 'secret');
      await tester.tap(find.text('I confirm I am 13 or older.'));
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(api.registerCalls, 1);
      expect(api.loginCalls, 0);
    });
  });

  group('email blur validation (SCORECARD-3 #7)', () {
    testWidgets('malformed email is flagged on blur, cleared by a '
        'later well-formed blur; empty blur flags nothing',
        (tester) async {
      final api = _FakeAuthApi();
      await _pumpLogin(tester, api);
      final fields = find.byType(TextField);

      // Empty blur: no complaint.
      await tester.tap(fields.at(0));
      await tester.tap(fields.at(1));
      await tester.pump();
      expect(find.byKey(const ValueKey('login_error')), findsNothing);

      // Malformed email, then leave the field.
      await tester.enterText(fields.at(0), 'not-an-email');
      await tester.tap(fields.at(1));
      await tester.pump();
      final error = find.byKey(const ValueKey('login_error'));
      expect(error, findsOneWidget);
      expect(
        tester.widget<Text>(error).data,
        'Please enter a valid email address.',
      );

      // Fix the address and leave the field again: the blur error
      // clears (submit-time checks remain the backstop).
      await tester.enterText(fields.at(0), 'person@tabs.app');
      await tester.tap(fields.at(1));
      await tester.pump();
      expect(find.byKey(const ValueKey('login_error')), findsNothing);
    });
  });

  group('autofill hints (SCORECARD-9 #15-adjacent)', () {
    testWidgets('login mode: email + password hints', (tester) async {
      final api = _FakeAuthApi();
      await _pumpLogin(tester, api);
      final fields = find.byType(TextField);
      expect(
        tester.widget<TextField>(fields.at(0)).autofillHints,
        contains(AutofillHints.email),
      );
      expect(
        tester.widget<TextField>(fields.at(1)).autofillHints,
        contains(AutofillHints.password),
      );
    });

    testWidgets('register mode: newPassword hint', (tester) async {
      final api = _FakeAuthApi();
      await _pumpLogin(tester, api, registerMode: true);
      final fields = find.byType(TextField);
      expect(
        tester.widget<TextField>(fields.at(1)).autofillHints,
        contains(AutofillHints.newPassword),
      );
    });
  });

  group('48dp hit boxes (SCORECARD-3 #2 / SCORECARD-9 #13)', () {
    testWidgets('"Forgot Password?" hit height >= 48dp, glyph '
        'unchanged at 13sp', (tester) async {
      final api = _FakeAuthApi();
      await _pumpLogin(tester, api);
      final button = find.widgetWithText(TextButton, 'Forgot Password?');
      expect(button, findsOneWidget);
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      final text = tester.widget<Text>(find.text('Forgot Password?'));
      expect(text.style!.fontSize, 13);
    });

    testWidgets('onboarding "Skip" hit box >= 48x48dp and a tap at '
        'its edge still fires onSkip', (tester) async {
      var skipped = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: OnboardingHeader(onSkip: () => skipped++),
        ),
      ));
      await tester.pump();
      final button = find.widgetWithText(TextButton, 'Skip');
      expect(button, findsOneWidget);
      final size = tester.getSize(button);
      expect(size.height, greaterThanOrEqualTo(48));
      expect(size.width, greaterThanOrEqualTo(48));
      final rect = tester.getRect(button);
      await tester.tapAt(Offset(rect.center.dx, rect.top + 1));
      await tester.pump();
      expect(skipped, 1);
    });
  });

  group('tabular figures (SCORECARD-9 #16)', () {
    testWidgets('CountUp renders tabular figures and preserves the '
        'caller style', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: CountUp(
            value: 42,
            animate: false,
            style: TextStyle(fontSize: 20),
          ),
        ),
      ));
      await tester.pump();
      final text = tester.widget<Text>(find.text('42'));
      expect(
        text.style!.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
      expect(text.style!.fontSize, 20);
    });

    testWidgets('CountUp with no caller style still renders tabular',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: CountUp(value: 7, animate: false)),
      ));
      await tester.pump();
      final text = tester.widget<Text>(find.text('7'));
      expect(
        text.style!.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
    });

    testWidgets('vitals strip values render tabular', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: VitalsStrip(animateCountUps: false)),
      ));
      await tester.pump();
      final texts = tester.widgetList<Text>(find.byType(Text)).toList();
      expect(texts, isNotEmpty);
      for (final t in texts) {
        expect(
          t.style?.fontFeatures,
          contains(const FontFeature.tabularFigures()),
          reason: 'vitals text "${t.data}"',
        );
      }
    });

    testWidgets('Daily Score face number renders tabular',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: DailyScoreFace(score: 78, size: 100, showInnerLabel: true),
        ),
      ));
      await tester.pump();
      final text = tester.widget<Text>(find.text('78'));
      expect(
        text.style!.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
    });

    testWidgets('gem pill balance renders tabular', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: HomeGemPill(gemBalance: 1234)),
      ));
      await tester.pump();
      final text = tester.widget<Text>(
        find.byKey(const Key('homeGemPillCount')),
      );
      expect(
        text.style!.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
    });
  });

  group('Quick Log keyboard submit (SCORECARD-3 #5)', () {
    setUp(() {
      LogEntryOutbox.instance.debugReset();
      LogEntryOutbox.instance.debugSetStore(
        read: (key) async => null,
        write: (key, value) async {},
        delete: (key) async {},
      );
      QuickLogCache.instance.debugReset();
      QuickLogCache.instance.debugSetStore(
        read: (key) async => null,
        write: (key, value) async {},
        delete: (key) async {},
      );
      HomeDataCache.instance.debugReset();
      HomeDataCache.instance.debugSetStore(
        read: (key) async => null,
        write: (key, value) async {},
        delete: (key) async {},
      );
      WidgetSync.debugSetBridge(
        save: (key, value) async {},
        update: () async {},
      );
    });

    testWidgets('details field: Enter saves the typed entry',
        (tester) async {
      const cat = QuickLogCategory(
        id: 3,
        name: 'Symptoms',
        icon: 'circle',
        colorHex: '#4ECDC4',
        isDefault: true,
        sortOrder: 0,
      );
      final store = FakeSessionStore()..token = 'wave-a-token';
      final client = MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
            jsonEncode({
              'entries': <dynamic>[],
              'categories': [cat.toSyncJson()],
              'profile': <String, dynamic>{},
              'isUnlimited': true,
              'isAdmin': false,
            }),
            200,
          );
        }
        if (request.url.path == '/api/sync/entries') {
          return http.Response('{"ok":true}', 200);
        }
        return http.Response('not found', 404);
      });
      await tester.pumpWidget(MaterialApp(
        home: QuickLogScreen(
          backend: TabsBackend(client: client, sessionStore: store),
        ),
      ));
      await tester.pumpAndSettle();

      final details = find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.decoration?.hintText ==
                'Add optional details about these symptoms…',
      );
      expect(details, findsOneWidget);
      final field = tester.widget<TextField>(details);
      expect(field.textInputAction, TextInputAction.done);
      expect(field.onSubmitted, isNotNull);

      await tester.enterText(details, 'feeling rough');
      await tester.pump();
      // Typed text shows the Add suffix (not the mic, not a spinner).
      expect(find.byIcon(Icons.add), findsWidgets);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.textContaining('Entry logged'), findsOneWidget);
    });
  });

  group('History delete Undo (SCORECARD-9 #5)', () {
    testWidgets(
        'delete needs no confirm dialog; Undo restores the entry at '
        'its index and re-posts it to the server', (tester) async {
      final server = _HistoryServer([
        _historyEntry(42, 'newest entry'),
        _historyEntry(7, 'oldest entry'),
      ]);
      await tester.pumpWidget(MaterialApp(
        home: HistoryScreen(
          backend: server.backend(),
          outbox: server.freshOutbox(),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('newest entry'), findsOneWidget);
      expect(find.text('oldest entry'), findsOneWidget);

      // Delete the newest entry via its card delete button — the
      // path that used to demand a "This cannot be undone"
      // confirmation dialog.
      await tester.tap(find.byTooltip('Delete entry').first);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('This cannot be undone.'), findsNothing);
      expect(find.text('newest entry'), findsNothing);
      expect(find.text('oldest entry'), findsOneWidget);
      expect(server.deletedIds, [42]);
      // The toast offers Undo.
      expect(find.text('Entry removed'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      // Restored at its original (top) position, and re-created on
      // the server through the entries upsert with its original id.
      expect(find.text('newest entry'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('newest entry')).dy,
        lessThan(tester.getTopLeft(find.text('oldest entry')).dy),
      );
      expect(server.upsertedIds, contains(42));
      expect(server.entries.map((e) => e['id']), contains(42));
    });

    testWidgets(
        'Undo with a failing outbox store surfaces the failure and '
        'does not restore the entry as Synced (Vera Condition 1)',
        (tester) async {
      final server = _HistoryServer([
        _historyEntry(42, 'newest entry'),
        _historyEntry(7, 'oldest entry'),
      ]);
      await tester.pumpWidget(MaterialApp(
        home: HistoryScreen(
          backend: server.backend(),
          outbox: server.failingOutbox(),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('newest entry'), findsOneWidget);
      expect(find.text('oldest entry'), findsOneWidget);

      // Delete succeeds server-side; the entry is gone.
      await tester.tap(find.byTooltip('Delete entry').first);
      await tester.pumpAndSettle();
      expect(find.text('newest entry'), findsNothing);
      expect(server.deletedIds, [42]);
      expect(find.text('Undo'), findsOneWidget);

      // Undo: the outbox write fails, so stageForBackend returns
      // false. The failure must be surfaced and the entry must NOT
      // come back — before the fix it reappeared with a Synced
      // badge despite having no server row and no outbox record.
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(
        find.text("Couldn't undo that delete — try again."),
        findsOneWidget,
      );
      expect(find.text('newest entry'), findsNothing);
      expect(find.text('oldest entry'), findsOneWidget);
      // The only Synced badge on screen is the oldest entry's:
      // the deleted entry is not shown as restored/Synced.
      expect(find.text('Synced'), findsOneWidget);
      // And nothing was re-created on the server.
      expect(server.upsertedIds, isNot(contains(42)));
      expect(server.entries.map((e) => e['id']), isNot(contains(42)));
    });
  });
}

Map<String, dynamic> _historyEntry(int id, String body) => {
      'id': id,
      'categoryId': 7,
      'body': body,
      'chips': '["General"]',
      'manualText': '',
      'timestamp':
          DateTime(2026, 11, 12, 12, id).millisecondsSinceEpoch,
    };

const _historyCategories = <Map<String, dynamic>>[
  {
    'id': 7,
    'name': 'General',
    'icon': 'circle',
    'colorHex': '#CCCCCC',
    'isDefault': true,
    'sortOrder': 0,
  },
];

/// Stateful fake server: DELETE removes the row, the entries POST
/// (the outbox upsert) re-creates it — exactly the contract the Undo
/// path relies on.
class _HistoryServer {
  final List<Map<String, dynamic>> entries;
  final List<int> deletedIds = [];
  final List<int> upsertedIds = [];

  _HistoryServer(this.entries);

  TabsBackend backend() {
    final store = FakeSessionStore()..token = 'wave-a-token';
    final client = MockClient((request) async {
      if (request.url.path == '/api/sync/pull') {
        return http.Response(
          jsonEncode({
            'entries': entries,
            'categories': _historyCategories,
            'profile': <String, dynamic>{},
            'isUnlimited': true,
            'isAdmin': false,
          }),
          200,
        );
      }
      if (request.url.path.startsWith('/api/sync/entries/') &&
          request.method == 'DELETE') {
        final id = int.parse(request.url.pathSegments.last);
        deletedIds.add(id);
        entries.removeWhere((e) => e['id'] == id);
        return http.Response('{"ok":true}', 200);
      }
      if (request.url.path == '/api/sync/entries' &&
          request.method == 'POST') {
        final decoded = jsonDecode(request.body) as Map<String, dynamic>;
        for (final raw in (decoded['entries'] as List)) {
          final entry = (raw as Map).cast<String, dynamic>();
          upsertedIds.add(entry['id'] as int);
          entries.removeWhere((e) => e['id'] == entry['id']);
          entries.add(entry);
        }
        return http.Response('{"ok":true}', 200);
      }
      return http.Response('not found', 404);
    });
    return TabsBackend(client: client, sessionStore: store);
  }

  LogEntryOutbox freshOutbox() {
    final disk = <String, String>{};
    final outbox = LogEntryOutbox.instance;
    outbox.debugReset();
    outbox.debugSetStore(
      read: (key) async => disk[key],
      write: (key, value) async => disk[key] = value,
      delete: (key) async => disk.remove(key),
    );
    return outbox;
  }

  /// Vera Condition 1: an outbox whose disk load succeeds (empty
  /// disk) but whose every WRITE fails, so stage/restore persist
  /// fails and returns false — the C-01 failure mode.
  LogEntryOutbox failingOutbox() {
    final outbox = LogEntryOutbox.instance;
    outbox.debugReset();
    outbox.debugSetStore(
      read: (key) async => null,
      write: (key, value) async {
        throw StateError('failing outbox store: write failed');
      },
      delete: (key) async {},
    );
    return outbox;
  }
}
