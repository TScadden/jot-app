import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/uuid_v4.dart';

/// C-01 regression tests — LogEntryOutbox load-failure conflation
/// (pass-2 audit, verdict v-outbox: HOLDS, both sub-claims).
///
/// Pre-fix, `_doLoad` treated a throwing storage read identically
/// to a missing blob: it marked the outbox loaded-and-empty, so
/// the next stage/allocate persisted over the disk blob from
/// empty memory — staged unconfirmed Quick Log entries were
/// permanently lost and their ids became reusable. Separately,
/// `clearIfOwnerMismatch` (and retain/cancel/restore) loaded
/// WITHOUT an owner, so an unowned blob was adopted instead of
/// hitting the F3 quarantine, and then wiped.
///
/// The fix mirrors PR #44 (health_history_store) and PR #49
/// (medication_change_event_outbox): a read THROW leaves the
/// outbox unloaded and retryable; only a missing/empty or
/// provably-corrupt blob counts as empty; persist is gated until
/// a load succeeds; owner enforcement never acts on an unloaded
/// queue; and the owner-bound entry points thread the owner so
/// the F3 quarantine runs as designed.
const _owner = 'founder@example.com';

QuickLogEntry _entry({String id = '42', String body = 'Brain fog all morning'}) {
  return QuickLogEntry(
    id: id,
    categoryId: '3',
    body: body,
    chips: '["Symptoms"]',
    manualText: '',
    timestamp: DateTime(2026, 10, 12, 9, 30).millisecondsSinceEpoch,
  );
}

/// Disk fake whose READ can be made to throw (a transient
/// secure-storage failure) while the blob underneath stays valid.
class _FakeDisk {
  final Map<String, String> values = {};
  bool throwOnRead = false;

  Future<String?> read(String key) async {
    if (throwOnRead) {
      throw StateError('transient storage read failure');
    }
    return values[key];
  }

  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  late _FakeDisk disk;
  late LogEntryOutbox outbox;

  setUp(() {
    disk = _FakeDisk();
    outbox = LogEntryOutbox.instance;
    outbox.debugReset();
    outbox.debugSetStore(
      read: disk.read,
      write: disk.write,
      delete: disk.delete,
    );
  });

  tearDown(() {
    LogEntryOutbox.instance.debugReset();
  });

  test('(a) C-01 regression: a throwing disk read on load does NOT '
      'overwrite staged-on-disk entries — stage/allocate fail '
      'without persisting, and the load retries and recovers when '
      'the throw stops', () async {
    // Stage an entry durably for the owner.
    expect(
      await outbox.stage(
        _entry(id: '42'),
        serverKnown: false,
        ownerEmail: _owner,
      ),
      isTrue,
    );
    final blobBefore = disk.values[LogEntryOutbox.storageKey];
    expect(blobBefore, isNotNull);

    // Process restart over the same disk, but now the storage
    // READ throws (transient failure). Pre-fix, _doLoad treated
    // the throw exactly like an empty disk: loaded=true with
    // empty records and high-water 0.
    outbox.debugReset();
    disk.throwOnRead = true;

    // A stage attempt must fail honestly and must NOT persist
    // over the blob.
    expect(
      await outbox.stage(
        _entry(id: '77', body: 'New entry during outage'),
        serverKnown: false,
        ownerEmail: _owner,
      ),
      isFalse,
    );
    expect(disk.values[LogEntryOutbox.storageKey], blobBefore);

    // An allocate attempt must NOT hand out an id while the
    // outbox state is unloaded — the C-01 load gate still stands
    // under GAP-18 (it binds the owner, not the id space).
    await expectLater(
      outbox.allocateEntryId(ownerEmail: _owner),
      throwsStateError,
    );
    expect(disk.values[LogEntryOutbox.storageKey], blobBefore);
    expect(outbox.isLoaded, isFalse);

    // The read recovers: the load RETRIES (it was never marked
    // loaded) and the staged entry is back.
    disk.throwOnRead = false;
    await outbox.load(ownerEmail: _owner);
    expect(outbox.isLoaded, isTrue);
    expect(outbox.records.single.entry.id, '42');

    // GAP-18: the next allocated id is a fresh random v4 UUID —
    // it cannot collide with the recovered entry (or any other
    // device's entries) by construction.
    final allocated = await outbox.allocateEntryId(ownerEmail: _owner);
    expect(isUuidV4(allocated), isTrue);
    expect(allocated, isNot('42'));

    // And staging works again, keeping BOTH records on disk.
    expect(
      await outbox.stage(
        _entry(id: allocated, body: 'Post-recovery entry'),
        serverKnown: false,
        ownerEmail: _owner,
      ),
      isTrue,
    );
    final blob = jsonDecode(
      disk.values[LogEntryOutbox.storageKey]!,
    ) as Map<String, dynamic>;
    expect((blob['records'] as List), hasLength(2));
  });

  test('(b) C-01 regression: clearIfOwnerMismatch with an unowned '
      'on-disk blob and a bound email hits the F3 quarantine '
      'instead of adopt-and-wipe', () async {
    // An unowned blob (owner stamp lost) holding one valid record.
    disk.values[LogEntryOutbox.storageKey] = jsonEncode({
      'ownerEmail': null,
      'nextIdHighWater': 301,
      'records': [
        LogEntryOutboxRecord(
          entry: _entry(id: '301'),
          serverKnown: false,
        ).toJson(),
      ],
    });

    // Pre-fix this loaded ownerless, adopted the record into
    // memory, then cleared it and DELETED the blob (dropped=true,
    // quarantine empty, disk gone).
    final dropped = await outbox.clearIfOwnerMismatch(_owner);
    expect(dropped, isFalse);
    // Nothing adopted into the account…
    expect(outbox.records, isEmpty);
    // …nothing deleted either: the record is quarantined per F3…
    expect(outbox.quarantinedRecordCount, 1);
    expect(disk.values.containsKey(LogEntryOutbox.storageKey), isTrue);

    // …and a later persist re-embeds the quarantined record under
    // the now-known owner.
    expect(
      await outbox.stage(
        _entry(id: '302'),
        serverKnown: false,
        ownerEmail: _owner,
      ),
      isTrue,
    );
    final blob = jsonDecode(
      disk.values[LogEntryOutbox.storageKey]!,
    ) as Map<String, dynamic>;
    expect(blob['records'], hasLength(1));
    expect(blob['quarantinedRecords'], hasLength(1));
  });

  test('(c) C-01 regression: an unbound warm followed by '
      'clearIfOwnerMismatch routes the unowned queue into the F3 '
      'quarantine instead of wiping it', () async {
    disk.values[LogEntryOutbox.storageKey] = jsonEncode({
      'ownerEmail': null,
      'nextIdHighWater': 401,
      'records': [
        LogEntryOutboxRecord(
          entry: _entry(id: '401'),
          serverKnown: false,
        ).toJson(),
      ],
    });

    // The main.dart session-read-failure ordering: warm UNBOUND
    // first (the ownerless load adopts the records with no owner
    // stamp), then the login hook runs clearIfOwnerMismatch.
    await outbox.load();
    expect(outbox.records.single.entry.id, 401);

    // Pre-fix, the loaded-owner enforcement wiped the adopted
    // records and deleted the blob. Now the unowned populated
    // queue is quarantined (F3 semantics): not adopted, not
    // deleted, preserved for the next persist.
    final dropped = await outbox.clearIfOwnerMismatch(_owner);
    expect(dropped, isFalse);
    expect(outbox.records, isEmpty);
    expect(outbox.quarantinedRecordCount, 1);
    expect(disk.values.containsKey(LogEntryOutbox.storageKey), isTrue);
  });

  test('(d) C-01 semantics pin: a corrupt disk blob is the one read '
      'outcome besides missing/empty that counts as empty', () async {
    disk.values[LogEntryOutbox.storageKey] = 'this is not json {';
    await outbox.load(ownerEmail: _owner);
    expect(outbox.isLoaded, isTrue);
    expect(outbox.records, isEmpty);
    // And the outbox is fully usable afterwards.
    expect(
      await outbox.stage(
        _entry(id: '55'),
        serverKnown: false,
        ownerEmail: _owner,
      ),
      isTrue,
    );
    final blob = jsonDecode(
      disk.values[LogEntryOutbox.storageKey]!,
    ) as Map<String, dynamic>;
    expect((blob['records'] as List), hasLength(1));
  });
}
