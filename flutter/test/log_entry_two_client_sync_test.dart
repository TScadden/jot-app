import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/uuid_v4.dart';

/// GAP-18 proof (Nov 27, 2026) — the two-phones scenario from the
/// break-it audit (C-sync item 18), exercised at the outbox/sync
/// level:
///
/// Both clients pull the SAME server state (legacy max id 41),
/// go offline, and each logs a DIFFERENT new entry. Pre-GAP-18
/// both devices allocated local_id 42 (per-device maxId+1) and
/// the second sync silently overwrote the first device's entry.
/// Post-GAP-18 both allocate random v4 UUIDs, and after both
/// flush against the fake server — which implements the real
/// upsert rule, keyed on (user, local_id) with the
/// `updated_at >=` guard — BOTH entries are present, alongside
/// the untouched legacy row.
///
/// The two clients are two sequential incarnations of the
/// outbox singleton, each bound to its OWN fake disk (separate
/// device storage) and its own backend handle onto the one
/// shared fake server (same account).
const _owner = 'founder@example.com';

class _FakeDisk {
  final Map<String, String> values = {};

  Future<String?> read(String key) async => values[key];

  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  Future<void> delete(String key) async {
    values.remove(key);
  }
}

/// The server side of the proof: an in-memory row set keyed by
/// the wire local_id, applying the production upsert rule from
/// sync.js (insert, or replace when the incoming updated_at is
/// not older than the stored one).
class _FakeSyncServer {
  final Map<String, Map<String, dynamic>> rows = {};

  void seedLegacyRow() {
    rows['41'] = {
      'id': 41,
      'categoryId': 3,
      'body': 'Legacy entry from before the trip',
      'chips': '[]',
      'manualText': '',
      'timestamp': 1000000,
      'updatedAt': 1000000,
    };
  }

  void upsertEntries(List<Map<String, dynamic>> entries) {
    for (final e in entries) {
      final key = '${e['id']}';
      final existing = rows[key];
      if (existing == null ||
          (e['updatedAt'] as int) >= (existing['updatedAt'] as int)) {
        rows[key] = Map<String, dynamic>.of(e);
      }
    }
  }

  /// The pull both clients start from (and the final pull the
  /// assertions read): rows serialized the way the real pull
  /// serializes them — legacy ids as ints, UUID ids as strings.
  List<QuickLogEntry> pullEntries() {
    final out = rows.values.map(QuickLogEntry.fromJson).toList();
    out.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return out;
  }
}

class _ClientBackend extends TabsBackend {
  final _FakeSyncServer server;

  _ClientBackend(this.server);

  @override
  Future<String?> readEmail() async => _owner;

  @override
  Future<bool> postLogEntries(List<QuickLogEntry> entries) async {
    server.upsertEntries(entries.map((e) => e.toSyncJson()).toList());
    return true;
  }

  @override
  void invalidateSyncPull() {}
}

/// One device: its own disk, its own backend handle, the shared
/// server and the shared outbox singleton (reset + rebound per
/// device, exactly like two processes on two phones).
class _Device {
  final _FakeDisk disk = _FakeDisk();
  final _ClientBackend backend;

  _Device(_FakeSyncServer server) : backend = _ClientBackend(server);

  LogEntryOutbox get outbox => LogEntryOutbox.instance;

  Future<void> powerOn() async {
    outbox.debugReset();
    outbox.debugSetStore(
      read: disk.read,
      write: disk.write,
      delete: disk.delete,
    );
    await outbox.load(ownerEmail: _owner);
  }

  /// Logs a brand-new entry the way the screens do: allocate
  /// through the outbox, stage durably, return the entry.
  Future<QuickLogEntry> logOffline(String body, int timestamp) async {
    final id = await outbox.allocateEntryIdForBackend(backend: backend);
    final entry = QuickLogEntry(
      id: id,
      categoryId: '3',
      body: body,
      chips: '[]',
      manualText: '',
      timestamp: timestamp,
    );
    final staged =
        await outbox.stageForBackend(entry, backend: backend, serverKnown: false);
    expect(staged, isTrue, reason: 'stage must be durable before sync');
    return entry;
  }
}

void main() {
  test('GAP-18: two offline clients logging after the same pull '
      'both survive sync', () async {
    final server = _FakeSyncServer()..seedLegacyRow();
    final phoneA = _Device(server);
    final phoneB = _Device(server);

    // Both phones pull the same state: one legacy entry, id 41.
    for (final phone in [phoneA, phoneB]) {
      final pulled = server.pullEntries();
      expect(pulled, hasLength(1));
      expect(pulled.single.id, '41');
    }

    // Both go offline and log different entries.
    await phoneA.powerOn();
    final entryA = await phoneA.logOffline('Phone A: dizzy spell', 2000000);
    await phoneB.powerOn();
    final entryB = await phoneB.logOffline('Phone B: took meds', 3000000);

    // The GAP-18 identity contract: distinct random v4 UUIDs —
    // under the old scheme both of these were the integer 42.
    expect(entryA.id, isNot(entryB.id));
    expect(isUuidV4(entryA.id), isTrue, reason: entryA.id);
    expect(isUuidV4(entryB.id), isTrue, reason: entryB.id);

    // Both come back online and flush.
    await phoneA.powerOn();
    expect(await phoneA.outbox.flush(phoneA.backend), isTrue);
    await phoneB.powerOn();
    expect(await phoneB.outbox.flush(phoneB.backend), isTrue);

    // BOTH entries are on the server, plus the legacy row —
    // nothing overwritten, nothing lost.
    final after = server.pullEntries();
    expect(after, hasLength(3));
    final bodies = after.map((e) => e.body).toSet();
    expect(
      bodies,
      containsAll([
        'Legacy entry from before the trip',
        'Phone A: dizzy spell',
        'Phone B: took meds',
      ]),
    );
    final legacy = after.singleWhere((e) => e.id == '41');
    expect(legacy.body, 'Legacy entry from before the trip');
  });

  test('GAP-18: a legacy int-id entry still edits and syncs '
      'under its own id', () async {
    final server = _FakeSyncServer()..seedLegacyRow();
    final phone = _Device(server);
    await phone.powerOn();

    // Edit the pulled legacy entry (same id, new body) and push.
    final edited = QuickLogEntry(
      id: '41',
      categoryId: '3',
      body: 'Legacy entry, edited on the new build',
      chips: '[]',
      manualText: '',
      timestamp: 1000000,
    );
    await phone.outbox
        .stageForBackend(edited, backend: phone.backend, serverKnown: true);
    expect(await phone.outbox.flush(phone.backend), isTrue);

    final after = server.pullEntries();
    expect(after, hasLength(1));
    expect(after.single.id, '41');
    expect(after.single.body, 'Legacy entry, edited on the new build');
    // The wire form of a legacy id stays a JSON int, so the push
    // is byte-identical to a pre-GAP-18 build's push.
    expect(edited.toSyncJson()['id'], 41);
  });

  test('GAP-18: category pushes carry a real updatedAt and '
      'legacy category ids stay ints on the wire', () {
    const legacy = QuickLogCategory(
      id: '7',
      name: 'Symptoms',
      icon: 'circle',
      colorHex: '#CCCCCC',
      isDefault: true,
      sortOrder: 0,
      updatedAt: 123456789,
    );
    final json = legacy.toSyncJson();
    expect(json['id'], 7);
    expect(json['updatedAt'], 123456789);

    final fresh = QuickLogCategory(
      id: generateUuidV4(),
      name: 'Custom',
      icon: 'circle',
      colorHex: '#FF6B6B',
      isDefault: false,
      sortOrder: 9,
      updatedAt: 987654321,
    );
    final freshJson = fresh.toSyncJson();
    expect(freshJson['id'], fresh.id);
    expect(isUuidV4(freshJson['id'] as String), isTrue);
    expect(freshJson['updatedAt'], 987654321);

    // Pulls parse both id forms and the stamped updatedAt.
    final parsed = QuickLogCategory.fromJson({
      'id': fresh.id,
      'name': 'Custom',
      'updatedAt': 987654321,
    });
    expect(parsed.id, fresh.id);
    expect(parsed.updatedAt, 987654321);

    // The GAP-18 server's categories pull shape for a UUID
    // category: `id` is the legacy local_id (null) and the UUID
    // rides in `clientId` — the client must adopt the UUID or
    // the category loses its identity on the next pull.
    final pulledUuid = QuickLogCategory.fromJson({
      'id': null,
      'clientId': fresh.id,
      'name': 'Custom',
      'updatedAt': 987654321,
    });
    expect(pulledUuid.id, fresh.id);
    expect(pulledUuid.updatedAt, 987654321);
  });
}
