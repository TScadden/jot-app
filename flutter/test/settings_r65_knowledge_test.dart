import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/knowledge_documents.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';
import 'package:tabs_lab/src/features/tools/health_coach_screen.dart'
    show buildCoachHealthContext;

import 'test_helpers.dart';

/// Round 65 — Digital Knowledge Extraction.
///
/// The fake server below implements the REAL restored handler's
/// shapes (jot-server src/routes/sync.js documents routes + the
/// pull's documents field + src/routes/ai.js process-document):
/// - POST /api/sync/documents validates the batch and returns
///   `{synced: n}` counting the rows it now holds from the batch;
/// - GET /api/sync/pull returns document METADATA only;
/// - GET /api/sync/documents/:id returns `{fileData, result}`;
/// - DELETE /api/sync/documents/:id returns `{deleted: true}`;
/// - POST /api/ai/process-document returns `{result: text}`.
class FakeDocServer {
  final List<Map<String, dynamic>> docs = []; // full rows incl. fileData
  bool pullFails = false;
  bool postFails = false;
  int? syncedOverride;
  bool processFails = false;
  String processResult = 'Extracted: patient takes ivabradine.';
  final List<String> paths = [];

  MockClient get client => MockClient((request) async {
        paths.add('${request.method} ${request.url.path}');
        switch (request.url.path) {
          case '/api/sync/pull':
            if (pullFails) return http.Response('boom', 500);
            return http.Response(
                jsonEncode({
                  'isUnlimited': false,
                  'isAdmin': false,
                  'nickname': 'Tyson',
                  'tag': '1234',
                  'profile': {'knowledgeBase': ''},
                  'insights': const [],
                  'documents': [
                    for (final d in docs)
                      {
                        'id': d['id'],
                        'name': d['name'],
                        'mimeType': d['mimeType'],
                        'createdAt': d['createdAt'],
                      },
                  ],
                }),
                200);
          case '/api/sync/documents':
            if (postFails) return http.Response('boom', 500);
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final batch = body['documents'] as List;
            for (final raw in batch) {
              final doc = (raw as Map).cast<String, dynamic>();
              // Real handler validation: fileData must be a string.
              if (doc['fileData'] is! String) {
                return http.Response(
                    jsonEncode({'error': 'each document needs … string fileData'}),
                    400);
              }
              docs.removeWhere((d) => d['id'] == doc['id']);
              docs.add(doc);
            }
            return http.Response(
                jsonEncode({'synced': syncedOverride ?? batch.length}), 200);
          case '/api/ai/process-document':
            if (processFails) {
              return http.Response(jsonEncode({'error': 'Gemini down'}), 500);
            }
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body.keys, containsAll(['mimeType', 'base64Data']));
            return http.Response(jsonEncode({'result': processResult}), 200);
        }
        if (request.url.path.startsWith('/api/sync/documents/')) {
          final id = Uri.decodeComponent(
              request.url.path.substring('/api/sync/documents/'.length));
          if (request.method == 'GET') {
            final matches = docs.where((d) => d['id'] == id).toList();
            final doc = matches.isEmpty ? null : matches.first;
            if (doc == null) {
              return http.Response(
                  jsonEncode({'error': 'Document not found'}), 404);
            }
            return http.Response(
                jsonEncode(
                    {'fileData': doc['fileData'], 'result': doc['fileData']}),
                200);
          }
          if (request.method == 'DELETE') {
            docs.removeWhere((d) => d['id'] == id);
            return http.Response(jsonEncode({'deleted': true}), 200);
          }
        }
        return http.Response('{}', 404);
      });
}

TabsBackend backendFor(FakeDocServer server) {
  final store = FakeSessionStore()
    ..token = 'tok'
    ..email = 'a@example.com';
  return TabsBackend(client: server.client, sessionStore: store);
}

KnowledgeExtractionStore memStore(Map<String, String> disk) =>
    KnowledgeExtractionStore.withStorage(
      read: (k) async => disk[k],
      write: (k, v) async => disk[k] = v,
      delete: (k) async => disk.remove(k),
    );

SettingsStore settingsStore() => SettingsStore.withStorage(
      read: (k) async => null,
      write: (k, v) async {},
      delete: (k) async {},
    );

class FakePicker extends KnowledgeDocumentPicker {
  PickedKnowledgeFile? result;
  KnowledgePickException? error;
  @override
  Future<PickedKnowledgeFile?> pickDocument() async {
    if (error != null) throw error!;
    return result;
  }
}

void main() {
  group('KnowledgeDocumentMeta.listFromPull', () {
    test('parses metadata, tolerates string createdAt, sorts DESC', () {
      final docs = KnowledgeDocumentMeta.listFromPull({
        'documents': [
          {'id': 'a', 'name': 'old.pdf', 'mimeType': 'application/pdf', 'createdAt': 100},
          {'id': 'b', 'name': 'new.txt', 'mimeType': 'text/plain', 'createdAt': '200'},
          {'name': 'no-id', 'mimeType': 'text/plain', 'createdAt': 300},
        ],
      });
      expect(docs.map((d) => d.id), ['b', 'a']);
      expect(docs.first.typeLabel, 'Text');
      expect(docs.last.typeLabel, 'PDF');
    });
  });

  group('KnowledgeDocumentService write disciplines', () {
    test('add: fresh pull, push only the new row, verify synced + re-pull',
        () async {
      final server = FakeDocServer();
      server.docs.add({
        'id': 'existing',
        'name': 'old.pdf',
        'mimeType': 'application/pdf',
        'fileData': 'b2xk',
        'createdAt': 1,
      });
      final service = KnowledgeDocumentService(
          backend: backendFor(server), store: memStore({}));
      final doc = await service.addDocument(
        name: 'labs.pdf',
        mimeType: 'application/pdf',
        base64Data: 'bmV3',
        idGenerator: () => 'new-id',
      );
      expect(doc.id, 'new-id');
      // The existing doc was NOT re-pushed (upsert splice, not a
      // whole-set replace): exactly one POST with one row.
      final posts = server.paths.where((p) => p == 'POST /api/sync/documents');
      expect(posts, hasLength(1));
      expect(server.docs.map((d) => d['id']),
          containsAll(['existing', 'new-id']));
    });

    test('add: a failed fresh pull aborts the write (no POST)', () async {
      final server = FakeDocServer()..pullFails = true;
      final service = KnowledgeDocumentService(
          backend: backendFor(server), store: memStore({}));
      await expectLater(
        service.addDocument(
            name: 'x.pdf', mimeType: 'application/pdf', base64Data: 'eA=='),
        throwsA(isA<KnowledgeSyncException>()
            .having((e) => e.code, 'code', 'PULL_FAILED')),
      );
      expect(server.paths.where((p) => p.startsWith('POST')), isEmpty);
    });

    test('add: a partial synced count is NOT a save (R57 pattern)',
        () async {
      final server = FakeDocServer()..syncedOverride = 0;
      final service = KnowledgeDocumentService(
          backend: backendFor(server), store: memStore({}));
      await expectLater(
        service.addDocument(
            name: 'x.pdf', mimeType: 'application/pdf', base64Data: 'eA=='),
        throwsA(isA<KnowledgeSyncException>()
            .having((e) => e.code, 'code', 'SAVE_UNVERIFIED')),
      );
    });

    test('delete: verified by re-pull; clear-all empties the set',
        () async {
      final server = FakeDocServer();
      server.docs.addAll([
        {'id': 'd1', 'name': 'a', 'mimeType': 'text/plain', 'fileData': 'YQ==', 'createdAt': 2},
        {'id': 'd2', 'name': 'b', 'mimeType': 'text/plain', 'fileData': 'Yg==', 'createdAt': 1},
      ]);
      final disk = <String, String>{};
      final store = memStore(disk);
      await store.load('a@example.com');
      await store.saveText('d1', 'text one');
      final service =
          KnowledgeDocumentService(backend: backendFor(server), store: store);
      await service.deleteDocument('d1');
      expect(server.docs.map((d) => d['id']), ['d2']);
      expect(store.textFor('d1'), isNull);
      await service.clearAllDocuments();
      expect(server.docs, isEmpty);
    });

    test('extraction: success caches text; failure is a failed state, '
        'never a fake ready', () async {
      final server = FakeDocServer();
      final store = memStore({});
      await store.load('a@example.com');
      final service =
          KnowledgeDocumentService(backend: backendFor(server), store: store);
      const doc = KnowledgeDocumentMeta(
          id: 'd1', name: 'a.pdf', mimeType: 'application/pdf', createdAt: 1);
      expect(await service.extractFromBytes(doc, 'eA=='),
          KnowledgeExtractionState.ready);
      expect(store.textFor('d1'), contains('ivabradine'));

      server.processFails = true;
      const doc2 = KnowledgeDocumentMeta(
          id: 'd2', name: 'b.pdf', mimeType: 'application/pdf', createdAt: 2);
      expect(await service.extractFromBytes(doc2, 'eA=='),
          KnowledgeExtractionState.failed);
      expect(store.stateFor('d2'), KnowledgeExtractionState.failed);
      expect(store.textFor('d2'), isNull);
    });

    test('extraction: an empty result is failed, not ready-with-empty',
        () async {
      final server = FakeDocServer()..processResult = '  ';
      final store = memStore({});
      await store.load('a@example.com');
      final service =
          KnowledgeDocumentService(backend: backendFor(server), store: store);
      const doc = KnowledgeDocumentMeta(
          id: 'd1', name: 'a.pdf', mimeType: 'application/pdf', createdAt: 1);
      expect(await service.extractFromBytes(doc, 'eA=='),
          KnowledgeExtractionState.failed);
    });

    test('backfill: fetches file data then extracts (native restore path)',
        () async {
      final server = FakeDocServer();
      server.docs.add({
        'id': 'd9',
        'name': 'restored.pdf',
        'mimeType': 'application/pdf',
        'fileData': 'cmVzdG9yZWQ=',
        'createdAt': 5,
      });
      final store = memStore({});
      await store.load('a@example.com');
      final service =
          KnowledgeDocumentService(backend: backendFor(server), store: store);
      const doc = KnowledgeDocumentMeta(
          id: 'd9',
          name: 'restored.pdf',
          mimeType: 'application/pdf',
          createdAt: 5);
      expect(await service.backfill(doc), KnowledgeExtractionState.ready);
      expect(server.paths, contains('GET /api/sync/documents/d9'));
    });

    test('store: cached mirror is owner-gated for the coach send path',
        () async {
      final disk = <String, String>{};
      final store = memStore(disk);
      const doc = KnowledgeDocumentMeta(
          id: 'd1', name: 'a.pdf', mimeType: 'application/pdf', createdAt: 1);
      // Not loaded yet: the synchronous mirror reads empty.
      expect(store.joinedCachedTextsFor('a@example.com', [doc]), '');
      await store.load('a@example.com');
      await store.saveText('d1', 'cached labs');
      expect(store.joinedCachedTextsFor('a@example.com', [doc]),
          'cached labs');
      // A different account can never be handed the mirror.
      expect(store.joinedCachedTextsFor('b@example.com', [doc]), '');
      expect(store.joinedCachedTextsFor(null, [doc]), '');
    });

    test('store: a different account never sees cached extracted text',
        () async {
      final disk = <String, String>{};
      final a = memStore(disk);
      await a.load('a@example.com');
      await a.saveText('d1', 'private labs');
      final b = memStore(disk);
      await b.load('b@example.com');
      expect(b.textFor('d1'), isNull);
      expect(disk, isEmpty); // foreign blob wiped, not leaked
    });
  });

  group('coach context inclusion (R55 assembler)', () {
    test('documents ride as the last section; clinician updates stay first',
        () {
      final out = buildCoachHealthContext(
        profile: const {
          'professionalUpdates': 'From the Doctor: increase salt.',
        },
        knowledgeDocumentsText: 'DOC TEXT about standing tolerance.',
        now: DateTime(2026, 10, 16),
      );
      expect(out, startsWith('CLINICIAN UPDATES (highest priority):'));
      expect(out, contains('Knowledge documents (extracted):'));
      expect(out.indexOf('CLINICIAN UPDATES'),
          lessThan(out.indexOf('Knowledge documents')));
      expect(out.length, lessThanOrEqualTo(9000));
    });

    test('over budget: document chunks drop BEFORE log lines', () {
      final bigDoc = List.generate(40, (i) => 'chunk$i ${'x' * 400}').join('\n\n');
      final out = buildCoachHealthContext(
        profile: const {'professionalUpdates': 'clinician note'},
        entries: [
          {
            'id': 1,
            'categoryId': 1,
            'body': 'Felt dizzy standing',
            'chips': '',
            'manualText': '',
            'timestamp': DateTime(2026, 10, 16).millisecondsSinceEpoch,
          },
        ],
        categories: const [
          {'id': 1, 'name': 'Symptoms'},
        ],
        knowledgeDocumentsText: bigDoc,
        now: DateTime(2026, 10, 16),
      );
      expect(out.length, lessThanOrEqualTo(9000));
      expect(out, contains('clinician note'));
      expect(out, contains('Felt dizzy standing'));
    });
  });

  group('Settings FILE KNOWLEDGE BASE card', () {
    Future<void> pumpAi(WidgetTester tester, TabsBackend backend,
        {KnowledgeDocumentPicker? picker,
        KnowledgeExtractionStore? store}) async {
      tester.view.physicalSize = const Size(1080, 3400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SettingsScreen(
            backend: backend,
            settingsStore: settingsStore(),
            notificationService: FakeReminderNotificationService(),
            knowledgePicker: picker,
            knowledgeStore: store,
            urlLauncher: (uri) async => true,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AI & Clinical Advocate'));
      await tester.pumpAndSettle();
    }

    testWidgets('native copy, add buttons, and document tiles render',
        (tester) async {
      final server = FakeDocServer();
      server.docs.add({
        'id': 'd1',
        'name': 'labs.pdf',
        'mimeType': 'application/pdf',
        'fileData': 'eA==',
        'createdAt': 10,
      });
      final store = memStore({});
      await store.load('a@example.com');
      await store.saveText('d1', 'Extracted labs text.');
      await pumpAi(tester, backendFor(server), store: store);
      expect(find.text('Digital Knowledge Extraction'), findsOneWidget);
      expect(find.text('On-device'), findsOneWidget);
      expect(
          find.text(
              'Upload notes or PDFs to extract permanent knowledge (patterns, triggers, facts) that Gemini will remember.'),
          findsOneWidget);
      expect(find.text('Select Document / PDF'), findsOneWidget);
      expect(find.text('Add Text Note'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('documents_toggle')));
      await tester.pumpAndSettle();
      expect(find.text('Original Documents (1)'), findsOneWidget);
      expect(find.text('labs.pdf'), findsOneWidget);
      expect(find.text('PDF'), findsOneWidget);
      expect(find.text('• AI read'), findsOneWidget);
    });

    testWidgets('text note flow saves a text/plain doc and extracts it',
        (tester) async {
      final server = FakeDocServer();
      final store = memStore({});
      await pumpAi(tester, backendFor(server), store: store);
      await tester.tap(find.byKey(const ValueKey('add_text_note_button')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('note_body_field')), 'Standing triggers dizziness');
      await tester.pumpAndSettle(); // Process enables on the rebuild
      await tester.tap(find.byKey(const ValueKey('note_process_button')));
      await tester.pumpAndSettle();
      expect(server.docs, hasLength(1));
      expect(server.docs.single['name'], 'Text Note');
      expect(server.docs.single['mimeType'], 'text/plain');
      expect(utf8.decode(base64Decode(server.docs.single['fileData'] as String)),
          'Standing triggers dizziness');
      expect(store.textFor(server.docs.single['id'] as String),
          contains('ivabradine'));
    });

    testWidgets('picker failure surfaces a visible error with its code',
        (tester) async {
      final server = FakeDocServer();
      final picker = FakePicker()
        ..error = const KnowledgePickException('LAUNCH_FAILED', "Couldn't open the file picker.");
      await pumpAi(tester, backendFor(server),
          picker: picker, store: memStore({}));
      await tester
          .tap(find.byKey(const ValueKey('select_document_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('knowledge_process_error')),
          findsOneWidget);
      expect(find.textContaining('[LAUNCH_FAILED]'), findsOneWidget);
      expect(server.docs, isEmpty);
    });

    testWidgets('extraction failure: doc stays listed as failed, not ready',
        (tester) async {
      final server = FakeDocServer()..processFails = true;
      final picker = FakePicker()
        ..result = const PickedKnowledgeFile(
            name: 'scan.pdf',
            mimeType: 'application/pdf',
            base64Data: 'eA==');
      final store = memStore({});
      await pumpAi(tester, backendFor(server), picker: picker, store: store);
      await tester
          .tap(find.byKey(const ValueKey('select_document_button')));
      await tester.pumpAndSettle();
      expect(server.docs, hasLength(1)); // saved (native order)
      expect(find.textContaining('could not extract'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('documents_toggle')));
      await tester.pumpAndSettle();
      expect(find.text('• Extraction failed'), findsOneWidget);
      expect(find.text('• AI read'), findsNothing);
    });

    testWidgets('delete flow: confirm removes the doc server-side',
        (tester) async {
      final server = FakeDocServer();
      server.docs.add({
        'id': 'd1',
        'name': 'labs.pdf',
        'mimeType': 'application/pdf',
        'fileData': 'eA==',
        'createdAt': 10,
      });
      await pumpAi(tester, backendFor(server), store: memStore({}));
      await tester.tap(find.byKey(const ValueKey('documents_toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delete_doc_d1')));
      await tester.pumpAndSettle();
      expect(find.text('Trash File?'), findsOneWidget);
      await tester
          .tap(find.byKey(const ValueKey('confirm_delete_doc_d1')));
      await tester.pumpAndSettle();
      expect(server.docs, isEmpty);
      expect(find.text('labs.pdf'), findsNothing);
    });
  });
}
