import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/knowledge_documents.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';

import 'test_helpers.dart';

/// Docfix (Oct 2026) — Settings-surface widget tests for the
/// extraction FAILED vs EMPTY split (Juno copy ruling, verbatim).
/// Service-level coverage lives in docfix_knowledge_service_test.dart.
///
/// The fake server implements the FIXED server contract: import
/// strips whitespace + content-dedupes (answering a `deduplicated`
/// map), process-document answers 200 `{result}` (empty result =
/// successful extraction, no readable text) or non-200 on failure.
class FakeFixedDocServer {
  final List<Map<String, dynamic>> docs = []; // full rows incl. fileData
  bool processFails = false;
  int processCalls = 0;

  static String stripWs(String s) => s.replaceAll(RegExp(r'\s+'), '');

  MockClient get client => MockClient((request) async {
        switch (request.url.path) {
          case '/api/sync/pull':
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
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final batch = body['documents'] as List;
            final deduplicated = <String, String>{};
            var synced = 0;
            for (final raw in batch) {
              final doc = (raw as Map).cast<String, dynamic>();
              final clean = stripWs(doc['fileData'] as String);
              final dupe = docs.where((d) =>
                  d['id'] != doc['id'] &&
                  stripWs(d['fileData'] as String) == clean);
              if (dupe.isNotEmpty) {
                deduplicated[doc['id'] as String] = dupe.first['id'] as String;
                synced += 1;
                continue;
              }
              docs.removeWhere((d) => d['id'] == doc['id']);
              docs.add({...doc, 'fileData': clean});
              synced += 1;
            }
            return http.Response(
                jsonEncode({
                  'synced': synced,
                  if (deduplicated.isNotEmpty) 'deduplicated': deduplicated,
                }),
                200);
          case '/api/ai/process-document':
            processCalls += 1;
            if (processFails) {
              return http.Response(
                  jsonEncode({'error': 'Document processing failed'}), 502);
            }
            return http.Response(
                jsonEncode({'result': 'Extracted text from the document.'}),
                200);
        }
        if (request.url.path.startsWith('/api/sync/documents/')) {
          final id = Uri.decodeComponent(
              request.url.path.substring('/api/sync/documents/'.length));
          if (request.method == 'GET') {
            final matches = docs.where((d) => d['id'] == id).toList();
            if (matches.isEmpty) {
              return http.Response(
                  jsonEncode({'error': 'Document not found'}), 404);
            }
            final data = matches.first['fileData'];
            return http.Response(
                jsonEncode({'fileData': data, 'result': data}), 200);
          }
          if (request.method == 'DELETE') {
            docs.removeWhere((d) => d['id'] == id);
            return http.Response(jsonEncode({'deleted': true}), 200);
          }
        }
        return http.Response('{}', 404);
      });
}

TabsBackend backendFor(FakeFixedDocServer server) {
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

void main() {
  setUp(TabsBackend.debugResetSharedCaches);

  Future<void> pumpAi(WidgetTester tester, TabsBackend backend,
      {required KnowledgeExtractionStore store}) async {
    tester.view.physicalSize = const Size(1080, 3400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsScreen(
          backend: backend,
          settingsStore: settingsStore(),
          notificationService: FakeReminderNotificationService(),
          knowledgeStore: store,
          urlLauncher: (uri) async => true,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AI & Clinical Advocate'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('documents_toggle')));
    await tester.pumpAndSettle();
  }

  testWidgets('4b. EMPTY renders Juno strings verbatim, no error code',
      (tester) async {
    final server = FakeFixedDocServer();
    server.docs.add({
      'id': 'scan-1',
      'name': 'scan.pdf',
      'mimeType': 'application/pdf',
      'fileData': 'c2Nhbg==',
      'createdAt': 10,
    });
    final store = memStore({});
    await store.load('a@example.com');
    await store.saveEmptyExtraction('scan-1');
    await pumpAi(tester, backendFor(server), store: store);
    // Tile: the EMPTY subtitle, and NOT the failed one.
    expect(find.text('• No readable text found'), findsOneWidget);
    expect(find.text('• Extraction failed'), findsNothing);
    // Auto-backfill never called extraction for the empty doc.
    expect(server.processCalls, 0);
    // Viewer dialog.
    await tester.tap(find.byKey(const ValueKey('doc_tile_scan-1')));
    await tester.pumpAndSettle();
    expect(find.text('No readable text was found'), findsOneWidget);
    expect(
        find.text('Gemini read this file and found no readable text in it.'),
        findsOneWidget);
    expect(find.text('No content could be extracted'), findsNothing);
    // NO error-code suffix anywhere on the EMPTY surfaces.
    expect(find.textContaining('[EXTRACTION'), findsNothing);
    // Manual retry is offered.
    expect(find.text('Retry extraction'), findsOneWidget);
  });

  testWidgets('FAILED renders the changed Juno body, retry kept',
      (tester) async {
    final server = FakeFixedDocServer()..processFails = true;
    server.docs.add({
      'id': 'bad-1',
      'name': 'bad.pdf',
      'mimeType': 'application/pdf',
      'fileData': 'YmFk',
      'createdAt': 10,
    });
    final store = memStore({});
    await store.load('a@example.com');
    await store.markFailed('bad-1');
    await pumpAi(tester, backendFor(server), store: store);
    expect(find.text('• Extraction failed'), findsOneWidget);
    expect(find.text('• No readable text found'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('doc_tile_bad-1')));
    await tester.pumpAndSettle();
    expect(find.text('No content could be extracted'), findsOneWidget);
    expect(
        find.text(
            'Gemini could not complete extraction for this file. Try again.'),
        findsOneWidget);
    // The rejected old FAILED body is gone.
    expect(find.text('No readable content was found in this file.'),
        findsNothing);
    expect(find.text('Retry extraction'), findsOneWidget);
  });

  testWidgets('2b. re-import through the service yields ONE tile (canonical)',
      (tester) async {
    final server = FakeFixedDocServer();
    server.docs.add({
      'id': 'canon-1',
      'name': 'orig.txt',
      'mimeType': 'text/plain',
      'fileData': base64Encode(utf8.encode('duplicate me')),
      'createdAt': 5,
    });
    final store = memStore({});
    await store.load('a@example.com');
    final service =
        KnowledgeDocumentService(backend: backendFor(server), store: store);
    final adopted = await service.addDocument(
      name: 'orig copy.txt',
      mimeType: 'text/plain',
      base64Data: base64Encode(utf8.encode('duplicate me')),
      idGenerator: () => 'phantom-1',
    );
    expect(adopted.id, 'canon-1');
    await pumpAi(tester, backendFor(server), store: store);
    expect(find.text('Original Documents (1)'), findsOneWidget);
    expect(find.byKey(const ValueKey('doc_tile_canon-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('doc_tile_phantom-1')), findsNothing);
  });
}
