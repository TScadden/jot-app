import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/knowledge_documents.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';

import 'test_helpers.dart';

/// Docfix (Oct 2026) — knowledge-document extraction fix, app half:
/// service/backend level. (The Settings-surface widget tests live
/// in settings_docfix_knowledge_test.dart.)
///
/// The fake server below implements the FIXED server contract
/// (branch fix/knowledge-doc-extraction-server, see
/// ~/workspace/doc-extract-investigation/patch_server.py):
/// - POST /api/sync/documents strips whitespace from fileData at
///   the boundary, dedupes by content hash, and answers
///   `{synced}` or `{synced, deduplicated: {sentId: canonicalId}}`;
/// - GET /api/sync/documents/:id serves the stored bytes;
/// - POST /api/ai/process-document answers 200 `{result: text}`
///   (the server trims; an empty result is a SUCCESSFUL extraction
///   that found no readable text) and non-200 on failure. Like the
///   real Gemini upstream, it REJECTS whitespace-wrapped base64
///   with a 500, so the client-side strip is load-bearing here.
class FakeFixedDocServer {
  final List<Map<String, dynamic>> docs = []; // full rows incl. fileData
  bool processFails = false;
  String processResult = 'Extracted text from the document.';
  int processCalls = 0;
  String? lastProcessBase64;
  final List<String> paths = [];

  static String stripWs(String s) => s.replaceAll(RegExp(r'\s+'), '');

  MockClient get client => MockClient((request) async {
        paths.add('${request.method} ${request.url.path}');
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
              // Content dedupe against a DIFFERENT existing id.
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
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final b64 = body['base64Data'] as String;
            lastProcessBase64 = b64;
            // Gemini rejects whitespace-wrapped base64 outright.
            if (RegExp(r'\s').hasMatch(b64)) {
              return http.Response(
                  jsonEncode({'error': 'Document processing failed'}), 500);
            }
            return http.Response(
                jsonEncode({'result': processResult.trim()}), 200);
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

/// A real minimal one-page PDF whose content stream carries a text
/// layer ("Hello PDF layer") — the text-layer PDF fixture.
String textLayerPdfBase64() {
  final content = 'BT /F1 24 Tf 72 720 Td (Hello PDF layer) Tj ET';
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
        '/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
    '<< /Length ${content.length} >>\nstream\n$content\nendstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  final buf = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(buf.length);
    buf.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = buf.length;
  buf.write('xref\n0 ${objects.length + 1}\n');
  buf.write('0000000000 65535 f \n');
  for (final o in offsets) {
    buf.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  buf.write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
      'startxref\n$xref\n%%EOF');
  return base64Encode(utf8.encode(buf.toString()));
}

/// CRLF-wraps a clean base64 string at 76 columns, exactly like
/// android.util.Base64.DEFAULT (the native-era storage format).
String wrapBase64(String clean) {
  final buf = StringBuffer();
  for (var i = 0; i < clean.length; i += 76) {
    buf.write(
        clean.substring(i, i + 76 > clean.length ? clean.length : i + 76));
    buf.write('\r\n');
  }
  return buf.toString();
}

void main() {
  setUp(TabsBackend.debugResetSharedCaches);

  test('1a. import → extract → listed-with-content (plain text)', () async {
    final server = FakeFixedDocServer();
    final store = memStore({});
    await store.load('a@example.com');
    final service =
        KnowledgeDocumentService(backend: backendFor(server), store: store);
    final b64 = base64Encode(utf8.encode('Patient takes ivabradine 7.5 mg.'));
    final doc = await service.addDocument(
      name: 'note.txt',
      mimeType: 'text/plain',
      base64Data: b64,
      idGenerator: () => 'txt-1',
    );
    final state = await service.extractFromBytes(doc, b64);
    expect(state, KnowledgeExtractionState.ready);
    final listed = await service.freshDocuments();
    expect(listed.map((d) => d.id), ['txt-1']);
    expect(store.textFor('txt-1'), 'Extracted text from the document.');
    expect(store.stateFor('txt-1'), KnowledgeExtractionState.ready);
  });

  test('1b. import → extract → listed-with-content (text-layer PDF)',
      () async {
    final server = FakeFixedDocServer()..processResult = 'Hello PDF layer';
    final store = memStore({});
    await store.load('a@example.com');
    final service =
        KnowledgeDocumentService(backend: backendFor(server), store: store);
    final b64 = textLayerPdfBase64();
    // The fixture really is a PDF with a text layer.
    final decoded = utf8.decode(base64Decode(b64));
    expect(decoded, startsWith('%PDF-1.4'));
    expect(decoded, contains('(Hello PDF layer) Tj'));
    final doc = await service.addDocument(
      name: 'labs.pdf',
      mimeType: 'application/pdf',
      base64Data: b64,
      idGenerator: () => 'pdf-1',
    );
    final state = await service.extractFromBytes(doc, b64);
    expect(state, KnowledgeExtractionState.ready);
    expect(store.textFor('pdf-1'), 'Hello PDF layer');
    final listed = await service.freshDocuments();
    expect(listed.single.id, 'pdf-1');
  });

  test('2. duplicate import adopts the canonical document (one doc total)',
      () async {
    final server = FakeFixedDocServer();
    final store = memStore({});
    await store.load('a@example.com');
    final service =
        KnowledgeDocumentService(backend: backendFor(server), store: store);
    final b64 = base64Encode(utf8.encode('same bytes both times'));
    var n = 0;
    final first = await service.addDocument(
      name: 'orig.txt',
      mimeType: 'text/plain',
      base64Data: b64,
      idGenerator: () => 'import-${++n}',
    );
    expect(first.id, 'import-1');
    final second = await service.addDocument(
      name: 'orig copy.txt',
      mimeType: 'text/plain',
      base64Data: b64,
      idGenerator: () => 'import-${++n}',
    );
    // The second import returns the CANONICAL metadata, and the
    // server + pull hold exactly one document.
    expect(second.id, 'import-1');
    expect(second.name, 'orig.txt');
    expect(server.docs, hasLength(1));
    final listed = await service.freshDocuments();
    expect(listed, hasLength(1));
    expect(listed.single.id, 'import-1');
  });

  test('3. retry-after-fix: stale failed state clears to ready on success',
      () async {
    final server = FakeFixedDocServer();
    server.docs.add({
      'id': 'd-stale',
      'name': 'legacy.pdf',
      'mimeType': 'application/pdf',
      'fileData': 'bGVnYWN5',
      'createdAt': 7,
    });
    // A pre-fix blob: the doc sits in the old single 'failed'
    // state (no 'empty' key exists in this blob at all).
    final disk = <String, String>{
      KnowledgeExtractionStore.storageKey: jsonEncode({
        'owner': 'a@example.com',
        'texts': <String, String>{},
        'failed': ['d-stale'],
      }),
    };
    final store = memStore(disk);
    await store.load('a@example.com');
    expect(store.stateFor('d-stale'), KnowledgeExtractionState.failed);
    final service =
        KnowledgeDocumentService(backend: backendFor(server), store: store);
    const doc = KnowledgeDocumentMeta(
        id: 'd-stale', name: 'legacy.pdf', mimeType: 'application/pdf', createdAt: 7);
    final state = await service.backfill(doc, force: true);
    expect(state, KnowledgeExtractionState.ready);
    expect(store.stateFor('d-stale'), KnowledgeExtractionState.ready);
    expect(store.textFor('d-stale'), 'Extracted text from the document.');
    // The persisted blob no longer carries the stale failure.
    final blob = jsonDecode(disk[KnowledgeExtractionStore.storageKey]!)
        as Map<String, dynamic>;
    expect(blob['failed'], isNot(contains('d-stale')));
  });

  test('4a. genuinely-unreadable file lands in empty (service level)',
      () async {
    final server = FakeFixedDocServer()..processResult = '';
    final store = memStore({});
    await store.load('a@example.com');
    final service =
        KnowledgeDocumentService(backend: backendFor(server), store: store);
    // A scanned-image-only PDF: no readable text (fixture choice —
    // the fake Gemini returns an empty successful result for it).
    final b64 = textLayerPdfBase64();
    final doc = await service.addDocument(
      name: 'scan.pdf',
      mimeType: 'application/pdf',
      base64Data: b64,
      idGenerator: () => 'scan-1',
    );
    final state = await service.extractFromBytes(doc, b64);
    expect(state, KnowledgeExtractionState.empty);
    expect(store.stateFor('scan-1'), KnowledgeExtractionState.empty);
    expect(store.textFor('scan-1'), isNull);
    // Auto-backfill must NOT re-run an empty doc…
    final callsBefore = server.processCalls;
    expect(await service.backfill(doc), KnowledgeExtractionState.empty);
    expect(server.processCalls, callsBefore);
    // …but a manual (forced) retry re-runs it and can succeed.
    server.processResult = 'Now readable after all.';
    expect(await service.backfill(doc, force: true),
        KnowledgeExtractionState.ready);
    expect(store.textFor('scan-1'), 'Now readable after all.');
  });

  test('5. wrapped-base64 regression: CRLF-wrapped stored payload extracts',
      () async {
    final server = FakeFixedDocServer();
    final clean = base64Encode(utf8.encode('legacy native upload bytes'));
    final wrapped = wrapBase64(clean);
    expect(wrapped, contains('\r\n'));
    // Seed a LEGACY row: the server still holds the wrapped form.
    server.docs.add({
      'id': 'd-legacy',
      'name': 'native-era.pdf',
      'mimeType': 'application/pdf',
      'fileData': wrapped,
      'createdAt': 3,
    });
    final store = memStore({});
    await store.load('a@example.com');
    final service =
        KnowledgeDocumentService(backend: backendFor(server), store: store);
    const doc = KnowledgeDocumentMeta(
        id: 'd-legacy',
        name: 'native-era.pdf',
        mimeType: 'application/pdf',
        createdAt: 3);
    final state = await service.backfill(doc);
    expect(state, KnowledgeExtractionState.ready);
    // What reached process-document carried NO whitespace at all.
    expect(server.lastProcessBase64, clean);
    expect(server.lastProcessBase64, isNot(contains('\r')));
    expect(server.lastProcessBase64, isNot(contains('\n')));
  });

  test('backend: processDocument strips whitespace before sending', () async {
    final server = FakeFixedDocServer();
    final backend = backendFor(server);
    final wrapped = wrapBase64(base64Encode(utf8.encode('hi')));
    final text = await backend.processDocument('text/plain', wrapped);
    expect(text, 'Extracted text from the document.');
    expect(server.lastProcessBase64,
        TabsBackend.stripBase64Whitespace(wrapped));
  });

  test('backend: fetchDocumentData strips a wrapped stored payload', () async {
    final server = FakeFixedDocServer();
    final clean = base64Encode(utf8.encode('stored bytes'));
    server.docs.add({
      'id': 'd-w',
      'name': 'w.pdf',
      'mimeType': 'application/pdf',
      'fileData': wrapBase64(clean),
      'createdAt': 1,
    });
    final backend = backendFor(server);
    expect(await backend.fetchDocumentData('d-w'), clean);
  });
}
