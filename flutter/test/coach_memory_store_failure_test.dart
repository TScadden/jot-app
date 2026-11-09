import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/coach_memory_store.dart';

/// Pass-2 audit regressions — CoachMemoryStore:
/// - C-05a: a storage READ throw must not be conflated with
///   "loaded, empty". The store must not mark disk loaded, must
///   never persist over the unread blob, and must retry the read
///   on the next load so pre-existing facts survive alongside
///   facts recorded during the outage.
/// - C-09: a storage WRITE throw must not be reported as success.
///   The unsaved snapshot is tracked and the next load/mutation
///   retries persisting the FULL snapshot, so the fact survives a
///   cold start after the retry.
///
/// All assertions are behavioral (disk bytes + cold-start reads)
/// so they run against the pre-fix store unchanged and fail there.
class FakeDisk {
  final Map<String, String> mem = {};
  bool throwOnRead = false;
  bool throwOnWrite = false;

  CoachMemoryStore store() => CoachMemoryStore.withStorage(
    read: (k) async {
      if (throwOnRead) throw StateError('read boom');
      return mem[k];
    },
    write: (k, v) async {
      if (throwOnWrite) throw StateError('write boom');
      mem[k] = v;
    },
    delete: (k) async => mem.remove(k),
  );

  String blobFor(String owner, List<String> texts) => jsonEncode({
    'ownerEmail': owner,
    'facts': [
      for (var i = 0; i < texts.length; i++)
        {'text': texts[i], 'createdAt': i + 1, 'source': 'coach'},
    ],
  });

  List<String> diskTexts() {
    final raw = mem[CoachMemoryStore.storageKey];
    if (raw == null) return const [];
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return [for (final f in decoded['facts'] as List) '${(f as Map)['text']}'];
  }
}

/// Lets recordFact's unawaited load/persist chain settle.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  group('C-05a — read throw is not "loaded, empty"', () {
    test('addFact during a read outage never overwrites the blob; '
        'after recovery the old and new facts persist together', () async {
      final disk = FakeDisk();
      final original = disk.blobFor('a@x.com', [
        'Existing fact one',
        'Existing fact two',
      ]);
      disk.mem[CoachMemoryStore.storageKey] = original;
      disk.throwOnRead = true;
      final store = disk.store();

      final during = await store.addFact(
        text: 'New fact',
        source: 'coach',
        email: 'a@x.com',
      );
      expect(during.map((f) => f.text), contains('New fact'));
      // The unread blob must be byte-identical: nothing persisted
      // over disk state the store never successfully read.
      expect(disk.mem[CoachMemoryStore.storageKey], original);

      disk.throwOnRead = false;
      final recovered = await store.load('a@x.com');
      expect(
        recovered.map((f) => f.text),
        containsAll(['Existing fact one', 'Existing fact two', 'New fact']),
      );
      // The recovery load retries the pending persist, so a cold
      // start over the same disk sees all three facts.
      expect(
        disk.diskTexts(),
        containsAll(['Existing fact one', 'Existing fact two', 'New fact']),
      );
      final cold = await disk.store().load('a@x.com');
      expect(
        cold.map((f) => f.text),
        containsAll(['Existing fact one', 'Existing fact two', 'New fact']),
      );
    });

    test('recordFact during a read outage never overwrites the '
        'blob; after recovery both facts persist', () async {
      final disk = FakeDisk();
      final original = disk.blobFor('a@x.com', ['Existing fact']);
      disk.mem[CoachMemoryStore.storageKey] = original;
      disk.throwOnRead = true;
      final store = disk.store();

      store.recordFact(
        text: 'Recorded fact',
        source: 'coach',
        email: 'a@x.com',
      );
      await settle();
      expect(disk.mem[CoachMemoryStore.storageKey], original);

      disk.throwOnRead = false;
      final recovered = await store.load('a@x.com');
      await settle();
      expect(
        recovered.map((f) => f.text),
        containsAll(['Existing fact', 'Recorded fact']),
      );
      final cold = await disk.store().load('a@x.com');
      expect(
        cold.map((f) => f.text),
        containsAll(['Existing fact', 'Recorded fact']),
      );
    });

    test('a plain load during a read outage does not latch: the '
        'next load re-reads disk', () async {
      final disk = FakeDisk();
      disk.mem[CoachMemoryStore.storageKey] = disk.blobFor('a@x.com', [
        'Disk fact',
      ]);
      disk.throwOnRead = true;
      final store = disk.store();

      expect(await store.load('a@x.com'), isEmpty);
      disk.throwOnRead = false;
      // Pre-fix the failed load marked the store loaded, so this
      // returned the empty mirror forever.
      expect((await store.load('a@x.com')).map((f) => f.text), ['Disk fact']);
    });
  });

  group('C-09 — write throw is not success', () {
    test('addFact whose write throws is retried by the next load '
        'and survives a cold start', () async {
      final disk = FakeDisk();
      final store = disk.store();
      disk.throwOnWrite = true;
      final facts = await store.addFact(
        text: 'Unsaved fact',
        source: 'coach',
        email: 'a@x.com',
      );
      expect(facts.map((f) => f.text), ['Unsaved fact']);
      // The write never landed.
      expect(disk.mem.containsKey(CoachMemoryStore.storageKey), isFalse);

      disk.throwOnWrite = false;
      // The next load retries persisting the full snapshot.
      await store.load('a@x.com');
      expect(disk.diskTexts(), ['Unsaved fact']);
      final cold = await disk.store().load('a@x.com');
      expect(cold.map((f) => f.text), ['Unsaved fact']);
    });

    test('recordFact whose write throws is retried by the next '
        'load and survives a cold start', () async {
      final disk = FakeDisk();
      final store = disk.store();
      disk.throwOnWrite = true;
      store.recordFact(text: 'Session fact', source: 'coach', email: 'a@x.com');
      await settle();
      expect(disk.mem.containsKey(CoachMemoryStore.storageKey), isFalse);

      disk.throwOnWrite = false;
      await store.load('a@x.com');
      await settle();
      expect(disk.diskTexts(), ['Session fact']);
      final cold = await disk.store().load('a@x.com');
      expect(cold.map((f) => f.text), ['Session fact']);
    });

    test('deleteAt whose write throws is retried by the next '
        'load; the deletion survives a cold start', () async {
      final disk = FakeDisk();
      final store = disk.store();
      await store.addFact(text: 'one', source: 's', email: 'a@x.com');
      await store.addFact(text: 'two', source: 's', email: 'a@x.com');
      expect(disk.diskTexts(), ['two', 'one']);

      disk.throwOnWrite = true;
      final after = await store.deleteAt(0, 'a@x.com');
      expect(after.map((f) => f.text), ['one']);
      // Disk still holds both: the deletion never landed.
      expect(disk.diskTexts(), ['two', 'one']);

      disk.throwOnWrite = false;
      await store.load('a@x.com');
      expect(disk.diskTexts(), ['one']);
      final cold = await disk.store().load('a@x.com');
      expect(cold.map((f) => f.text), ['one']);
    });

    test('a later successful mutation persists the whole snapshot, '
        'including a fact whose original write failed', () async {
      final disk = FakeDisk();
      final store = disk.store();
      disk.throwOnWrite = true;
      await store.addFact(text: 'First fact', source: 's', email: 'a@x.com');
      disk.throwOnWrite = false;
      await store.addFact(text: 'Second fact', source: 's', email: 'a@x.com');
      expect(disk.diskTexts(), ['Second fact', 'First fact']);
      final cold = await disk.store().load('a@x.com');
      expect(cold.map((f) => f.text), ['Second fact', 'First fact']);
    });
  });
}
