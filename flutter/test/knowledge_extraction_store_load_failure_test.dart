import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/knowledge_documents.dart';

/// C-05b regression — KnowledgeExtractionStore load-conflation wipe.
///
/// Verdict: ~/workspace/pass2-audit/verdicts/v-stores.md (C-05,
/// knowledge half — HOLDS). A storage READ throw during [load] was
/// indistinguishable from an empty cache: load marked itself loaded
/// with empty maps, never re-read, and the next mutation's whole-blob
/// persist wiped every cached extraction and every local-only user
/// text edit. The fix mirrors the PR #44 pattern in
/// health_history_store.dart: a read throw leaves the store unloaded
/// (owner cleared) so the next load retries, and _persist is gated
/// on a load having succeeded.
void main() {
  const owner = 'a@example.com';
  const key = KnowledgeExtractionStore.storageKey;

  // A pre-existing on-disk blob: two cached extractions (one of them
  // a local-only user edit), one failed marker, one empty marker.
  String preExistingBlob() => jsonEncode({
    'owner': owner,
    'texts': {'d1': 'private labs', 'd2': 'user edited note'},
    'failed': ['d3'],
    'empty': ['d4'],
  });

  KnowledgeExtractionStore storeOver(
    Map<String, String> disk, {
    required bool Function() readsFail,
  }) => KnowledgeExtractionStore.withStorage(
    read: (k) async {
      if (readsFail()) throw Exception('secure storage boom');
      return disk[k];
    },
    write: (k, v) async => disk[k] = v,
    delete: (k) async => disk.remove(k),
  );

  group('C-05b failed load', () {
    test('(a) read throws on load → a mutation does NOT overwrite '
        'knowledge_extracted_v1 (blob byte-identical)', () async {
      final disk = <String, String>{key: preExistingBlob()};
      final before = disk[key];
      var fail = true;
      final store = storeOver(disk, readsFail: () => fail);

      await store.load(owner);
      await store.saveText('d9', 'new extraction');
      await store.saveEditedText('d10', 'new user edit');
      await store.markFailed('d11');

      // The whole point: the on-disk blob survived untouched.
      expect(disk[key], before);
      // In-memory session behavior stays sane: the new mutations
      // are visible to this session even though nothing persisted.
      expect(store.textFor('d9'), 'new extraction');
      expect(store.textFor('d10'), 'new user edit');
      expect(store.stateFor('d11'), KnowledgeExtractionState.failed);
    });

    test('(b) after reads recover, previously stored extractions/edits '
        'are intact and the new mutation persists alongside them', () async {
      final disk = <String, String>{key: preExistingBlob()};
      final before = disk[key];
      var fail = true;
      final store = storeOver(disk, readsFail: () => fail);

      await store.load(owner);
      await store.saveText('d9', 'new extraction');
      expect(disk[key], before); // still not wiped

      // Storage recovers: the next load must RETRY the disk read
      // (pre-fix it early-returned forever on the conflated flag).
      fail = false;
      await store.load(owner);
      expect(store.textFor('d1'), 'private labs');
      expect(store.textFor('d2'), 'user edited note');
      expect(store.stateFor('d3'), KnowledgeExtractionState.failed);
      expect(store.stateFor('d4'), KnowledgeExtractionState.empty);

      // A mutation now persists ALONGSIDE the recovered data.
      await store.saveText('d9', 'new extraction');
      final decoded = jsonDecode(disk[key]!) as Map<String, dynamic>;
      expect(decoded['owner'], owner);
      final texts = (decoded['texts'] as Map).cast<String, dynamic>();
      expect(texts['d1'], 'private labs');
      expect(texts['d2'], 'user edited note');
      expect(texts['d9'], 'new extraction');
      expect(decoded['failed'], contains('d3'));
      expect(decoded['empty'], contains('d4'));
    });

    test(
      'characterization (PR #44 split): a CORRUPT blob is not a '
      'read throw — it loads as an empty cache and persists re-arm',
      () async {
        final disk = <String, String>{key: 'this is not json'};
        final store = storeOver(disk, readsFail: () => false);

        await store.load(owner);
        expect(store.textFor('d1'), isNull);
        await store.saveText('d9', 'fresh extraction');

        final decoded = jsonDecode(disk[key]!) as Map<String, dynamic>;
        expect((decoded['texts'] as Map)['d9'], 'fresh extraction');
      },
    );
  });
}
