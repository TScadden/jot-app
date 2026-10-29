import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:tabs_lab/src/data/tabs_backend.dart';

/// Round 65 — Digital Knowledge Extraction (native parity).
///
/// Native spec (trace: ~/workspace/audit-r65/native-trace.md):
/// - Documents are `KnowledgeDocument` rows (id, name, mimeType,
///   filePath, createdAt, extractedText) in Room; the server holds
///   metadata + file bytes in `knowledge_documents` and syncs them
///   through POST/GET/DELETE `/api/sync/documents…` in the DTO shape
///   `{id, name, mimeType, fileData, createdAt}`.
/// - Extraction is a SERVER call: `POST /api/ai/process-document`
///   `{mimeType, base64Data}` → `{result}` (Gemini transcription).
///   There is no on-device parser in native despite the Settings
///   card's "On-device" badge (that badge is copy, kept verbatim).
/// - extractedText lives ONLY on-device in native (Room). The
///   Flutter equivalent is [KnowledgeExtractionStore]: an
///   account-bound flutter_secure_storage blob (the
///   CoachMemoryStore pattern), holding id → extracted text plus an
///   explicit failed marker. Native leaves a failed extraction
///   silently stuck at "Extracting…" forever; the Lab deliberately
///   does NOT mirror the silence (LESSONS.md) — a failure is a
///   visible state with a retry.
///
/// Write disciplines (R48/R57, non-negotiable): every mutation in
/// [KnowledgeDocumentService] fresh-pulls first and ABORTS when the
/// pull fails; the documents POST is an upsert of the rows sent
/// (the restored handler never deletes rows it is not sent), so an
/// add pushes ONLY the new row — spliced against the pulled set for
/// id-collision safety — and is then VERIFIED two ways: the
/// response's `{synced: n}` must account for the batch, and a
/// verification pull must contain the id. A delete is verified by a
/// re-pull that no longer contains the id. Nothing is ever reported
/// saved on an unverified write.

/// One document's server metadata (the pull's `documents` rows and
/// the local Room row's synced fields).
class KnowledgeDocumentMeta {
  final String id;
  final String name;
  final String mimeType;
  final int createdAt; // epoch ms

  const KnowledgeDocumentMeta({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.createdAt,
  });

  /// Tolerant parse of one pull `documents` row (server BIGINTs can
  /// arrive as JSON strings, same tolerance as SettingsProfileData).
  static KnowledgeDocumentMeta? fromPullRow(dynamic raw) {
    if (raw is! Map) return null;
    final id = '${raw['id'] ?? ''}';
    if (id.isEmpty) return null;
    final tsRaw = raw['createdAt'];
    final ts = tsRaw is num
        ? tsRaw.toInt()
        : (tsRaw is String ? int.tryParse(tsRaw) ?? 0 : 0);
    return KnowledgeDocumentMeta(
      id: id,
      name: '${raw['name'] ?? ''}',
      mimeType: '${raw['mimeType'] ?? ''}',
      createdAt: ts,
    );
  }

  /// Pull rows → documents, newest first (native DAO order:
  /// `ORDER BY createdAt DESC`).
  static List<KnowledgeDocumentMeta> listFromPull(
      Map<String, dynamic>? body) {
    final raw = body?['documents'];
    if (raw is! List) return const [];
    final docs = <KnowledgeDocumentMeta>[];
    for (final r in raw) {
      final d = fromPullRow(r);
      if (d != null) docs.add(d);
    }
    docs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return docs;
  }

  /// Native DocumentTile type label: PDF / Text / subtype uppercased.
  String get typeLabel {
    if (mimeType == 'application/pdf') return 'PDF';
    if (mimeType == 'text/plain') return 'Text';
    final sub = mimeType.contains('/')
        ? mimeType.substring(mimeType.indexOf('/') + 1)
        : mimeType;
    return sub.toUpperCase();
  }

  @override
  bool operator ==(Object other) =>
      other is KnowledgeDocumentMeta &&
      other.id == id &&
      other.name == name &&
      other.mimeType == mimeType &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(id, name, mimeType, createdAt);
}

/// A UUID v4 string — the same generator the coach uses (native
/// `UUID.randomUUID()` for document ids).
String newKnowledgeUuid() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String hex(int i) => b[i].toRadixString(16).padLeft(2, '0');
  return '${hex(0)}${hex(1)}${hex(2)}${hex(3)}-${hex(4)}${hex(5)}-'
      '${hex(6)}${hex(7)}-${hex(8)}${hex(9)}-${hex(10)}${hex(11)}'
      '${hex(12)}${hex(13)}${hex(14)}${hex(15)}';
}

/// The visible extraction state of one document.
enum KnowledgeExtractionState {
  /// Cached extracted text exists (native's "• AI read").
  ready,

  /// No cached text and no recorded failure yet (native's
  /// "• Extracting…"): either never attempted or an attempt is in
  /// flight.
  pending,

  /// An extraction attempt completed with a failure. Honest Lab
  /// state; native has no equivalent (it stays at pending forever).
  failed,

  /// Docfix (Oct 2026) — extraction ran SUCCESSFULLY but Gemini
  /// found no readable text in the file. Distinct from [failed]:
  /// nothing went wrong, so there is no error copy and no error
  /// code, and auto-backfill never retries it (the result will not
  /// change); a manual retry from the viewer is still possible.
  empty,
}

/// Device-local extracted-text cache, account-bound.
///
/// The blob carries its owner's session email; a load for a
/// different account returns empty and wipes the blob instead of
/// leaking another account's extracted medical text. Logout /
/// account deletion clear it via [clear] (wired in AccountActions
/// like the other account-bound caches).
class KnowledgeExtractionStore {
  static const String storageKey = 'knowledge_extracted_v1';

  Future<String?> Function(String key) _read =
      (key) => const FlutterSecureStorage().read(key: key);
  Future<void> Function(String key, String value) _write =
      (key, value) =>
          const FlutterSecureStorage().write(key: key, value: value);
  Future<void> Function(String key) _delete =
      (key) => const FlutterSecureStorage().delete(key: key);

  KnowledgeExtractionStore();

  /// Shared instance (the CoachMemoryStore pattern): Settings and
  /// the coach read the same in-memory mirror.
  static final KnowledgeExtractionStore instance =
      KnowledgeExtractionStore._internal();
  KnowledgeExtractionStore._internal();

  KnowledgeExtractionStore._(this._read, this._write, this._delete);

  @visibleForTesting
  void debugSetStore({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
    Future<void> Function(String key)? delete,
  }) {
    _read = read;
    _write = write;
    if (delete != null) _delete = delete;
    _generation++;
    _loaded = false;
    _owner = null;
    _texts = {};
    _failed = {};
    _empty = {};
  }

  @visibleForTesting
  factory KnowledgeExtractionStore.withStorage({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
    required Future<void> Function(String key) delete,
  }) =>
      KnowledgeExtractionStore._(read, write, delete);

  String? _owner;
  Map<String, String> _texts = {};
  Set<String> _failed = {};
  Set<String> _empty = {};
  bool _loaded = false;

  // TAKEOVER Phase 4 fix (Vera BLOCK, sibling of CoachMemoryStore):
  // generation guard — [invalidateMirror] bumps it, and a [load]
  // that observes a different generation after its disk await
  // discards the (pre-external-write) blob it read instead of
  // repopulating the mirror with stale texts.
  int _generation = 0;

  /// Mirror-only invalidation for an EXTERNAL write to the disk
  /// blob (the migration import writes `knowledge_extracted_v1`
  /// straight to secure storage): a mirror warmed earlier in the
  /// session would otherwise keep serving the pre-import texts,
  /// and the next [_persist] (saveText / markFailed / remove …)
  /// writes the WHOLE mirror, silently overwriting the imported
  /// blob. This resets ONLY the in-memory state — the disk key is
  /// neither deleted nor altered — and the next [load] re-reads
  /// the (imported) blob. [_owner] clearing also disarms
  /// [_persist] until a fresh load re-stamps it, so no persist can
  /// land from the stale mirror in between. Never throws.
  void invalidateMirror() {
    _generation++;
    _texts = {};
    _failed = {};
    _empty = {};
    _owner = null;
    _loaded = false;
  }

  static String? _normEmail(String? email) {
    final e = email?.trim().toLowerCase();
    return (e == null || e.isEmpty) ? null : e;
  }

  /// Loads (once) the cache for [email]. A foreign owner's blob is
  /// wiped, never returned.
  Future<void> load(String? email) async {
    final owner = _normEmail(email);
    if (_loaded && _owner == owner) return;
    final generationAtStart = _generation;
    _texts = {};
    _failed = {};
    _empty = {};
    _owner = owner;
    _loaded = true;
    if (owner == null) return;
    try {
      final raw = await _read(storageKey);
      // An external write landed while the read was in flight
      // (invalidateMirror bumped the generation): the blob just
      // read predates it. Drop the mirror back to unloaded so the
      // next load re-reads the current disk state, and mutate
      // nothing — in particular, never run the owner-wipe below
      // against a blob that may be the freshly imported one.
      if (generationAtStart != _generation) {
        _texts = {};
        _failed = {};
        _empty = {};
        _owner = null;
        _loaded = false;
        return;
      }
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      if (_normEmail(decoded['owner'] as String?) != owner) {
        // Another account's extracted text: wipe, never surface.
        try {
          await _delete(storageKey);
        } catch (_) {}
        return;
      }
      final texts = decoded['texts'];
      if (texts is Map) {
        for (final e in texts.entries) {
          final v = e.value;
          if (v is String && v.trim().isNotEmpty) {
            _texts['${e.key}'] = v;
          }
        }
      }
      final failed = decoded['failed'];
      if (failed is List) {
        for (final f in failed) {
          final id = '$f';
          if (id.isNotEmpty && !_texts.containsKey(id)) _failed.add(id);
        }
      }
      // Docfix: the 'empty' set (absent in pre-fix blobs — those
      // load with no empty docs, and a stale 'failed' from a
      // really-empty result clears on the next successful retry,
      // which is the migration path; nothing is bulk-rewritten).
      final empty = decoded['empty'];
      if (empty is List) {
        for (final f in empty) {
          final id = '$f';
          if (id.isNotEmpty && !_texts.containsKey(id)) {
            _failed.remove(id);
            _empty.add(id);
          }
        }
      }
    } catch (_) {
      // Unreadable blob: behave as an empty cache (extractions will
      // backfill from the server file data).
      _texts = {};
      _failed = {};
      _empty = {};
    }
  }

  Future<void> _persist() async {
    if (_owner == null) return;
    try {
      await _write(
        storageKey,
        jsonEncode({
          'owner': _owner,
          'texts': _texts,
          'failed': _failed.toList(),
          'empty': _empty.toList(),
        }),
      );
    } catch (_) {
      // A storage failure must not crash the caller; the in-memory
      // mirror still serves this session.
    }
  }

  String? textFor(String id) => _texts[id];

  KnowledgeExtractionState stateFor(String id) {
    final t = _texts[id];
    if (t != null && t.trim().isNotEmpty) {
      return KnowledgeExtractionState.ready;
    }
    if (_empty.contains(id)) return KnowledgeExtractionState.empty;
    if (_failed.contains(id)) return KnowledgeExtractionState.failed;
    return KnowledgeExtractionState.pending;
  }

  /// Records a successful extraction (native
  /// `updateExtractedText`). Blank text is NOT a success: the
  /// server's empty result means no readable content, and native's
  /// FileViewer shows that as its own blank state — mirrored here
  /// by storing the blank as ready-with-empty so the viewer can
  /// say "No readable content was found in this file." Callers use
  /// [saveEmptyExtraction] for that case explicitly.
  Future<void> saveText(String id, String text) async {
    if (text.trim().isEmpty) return saveEmptyExtraction(id);
    _texts[id] = text;
    _failed.remove(id);
    _empty.remove(id);
    await _persist();
  }

  /// Docfix (Oct 2026) — the extraction ran SUCCESSFULLY and
  /// returned nothing readable. This is its own terminal state
  /// ([KnowledgeExtractionState.empty]), NOT a failure: no error
  /// copy, no error code, and auto-backfill never retries it. It
  /// replaces any stale failed marker for the doc (a pre-fix
  /// 'failed' that was really an empty result migrates here on the
  /// next successful re-extract). Manual retry from the viewer can
  /// still re-run it via the service's backfill force path.
  Future<void> saveEmptyExtraction(String id) async {
    _texts.remove(id);
    _failed.remove(id);
    _empty.add(id);
    await _persist();
  }

  Future<void> markFailed(String id) async {
    if (_texts.containsKey(id)) return; // never demote a ready doc
    _empty.remove(id);
    _failed.add(id);
    await _persist();
  }

  /// A user edit of the extracted text (native FileViewer edit →
  /// DAO updateExtractedText; local only, never synced).
  Future<void> saveEditedText(String id, String text) async {
    _texts[id] = text;
    _failed.remove(id);
    _empty.remove(id);
    await _persist();
  }

  Future<void> remove(String id) async {
    _texts.remove(id);
    _failed.remove(id);
    _empty.remove(id);
    await _persist();
  }

  /// Synchronous, owner-gated mirror read for the coach SEND path,
  /// which must never await disk IO (the CoachMemoryStore contract:
  /// a wedged storage channel would hang the chat). Returns '' when
  /// the mirror is not loaded for [email] or belongs to another
  /// account — a foreign account's text can never be injected. The
  /// mirror is warmed by the coach History screen's load and by
  /// [load] calls in Settings.
  String joinedCachedTextsFor(
      String? email, List<KnowledgeDocumentMeta> docs) {
    final owner = _normEmail(email);
    if (!_loaded || owner == null || _owner != owner) return '';
    return joinedExtractedTexts(docs);
  }

  /// Joined extracted texts for the coach context, in the order of
  /// [docs] (newest first, as passed), blank/failed docs skipped —
  /// the shape of native's report path (`knowledgeDocuments
  /// .joinToString("\n\n")`).
  String joinedExtractedTexts(List<KnowledgeDocumentMeta> docs) {
    final parts = <String>[];
    for (final d in docs) {
      final t = _texts[d.id];
      if (t != null && t.trim().isNotEmpty) parts.add(t.trim());
    }
    return parts.join('\n\n');
  }

  Future<void> clear() async {
    _texts = {};
    _failed = {};
    _empty = {};
    _owner = null;
    _loaded = false;
    try {
      await _delete(storageKey);
    } catch (_) {}
  }

  /// Drops the cache when the signed-in account differs from the
  /// blob's owner (main.dart's login/register hook, the
  /// CoachMemoryStore pattern). [load] enforces the same rule, so
  /// this is the eager path, not the only guard.
  Future<void> clearIfOwnerMismatch(String? email) async {
    final owner = _normEmail(email);
    if (owner == null) return;
    if (_loaded && _owner == owner) return;
    try {
      final raw = await _read(storageKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic> &&
          _normEmail(decoded['owner'] as String?) == owner) {
        return;
      }
    } catch (_) {
      return;
    }
    await clear();
  }
}

/// Failure from the document picker channel. [code] is the Kotlin
/// side's stable error code (`IN_FLIGHT`, `LAUNCH_FAILED`,
/// `READ_FAILED`, `TOO_LARGE`, `UNAVAILABLE`).
class KnowledgePickException implements Exception {
  final String code;
  final String? message;
  const KnowledgePickException(this.code, [this.message]);
  @override
  String toString() => 'KnowledgePickException($code)';
}

/// A file chosen through the picker bridge.
class PickedKnowledgeFile {
  final String name;
  final String mimeType;
  final String base64Data;
  const PickedKnowledgeFile({
    required this.name,
    required this.mimeType,
    required this.base64Data,
  });
}

/// Round 65 — picks ONE document through the Android Storage Access
/// Framework (the Flutter host's MainActivity registers a second
/// GetContent launcher on the existing file_picker channel,
/// mirroring native SettingsScreen's `GetContent` `"*/*"`), and
/// returns its display name, MIME type, and base64 bytes — the exact
/// triple native `ingestFile` derives from the Uri
/// (SettingsViewModel.kt:688). The Round 48 CSV picker cannot serve
/// here: it returns decoded text only, so PDFs/images would be
/// destroyed before extraction.
///
/// Returns null when the user cancels. Throws
/// [KnowledgePickException] on any failure — never silent.
class KnowledgeDocumentPicker {
  static const String channelName =
      'com.notel.notel.playground.flutter/file_picker';

  final MethodChannel _channel;

  KnowledgeDocumentPicker({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  Future<PickedKnowledgeFile?> pickDocument() async {
    try {
      final res =
          await _channel.invokeMapMethod<String, dynamic>('pickDocumentFile');
      if (res == null) return null;
      final name = '${res['name'] ?? ''}';
      final mime = '${res['mimeType'] ?? ''}';
      final b64 = '${res['base64Data'] ?? ''}';
      if (name.isEmpty || b64.isEmpty) {
        throw const KnowledgePickException(
            'READ_FAILED', "Couldn't read this file. Please try a different file.");
      }
      return PickedKnowledgeFile(
        name: name,
        mimeType: mime.isEmpty ? 'application/pdf' : mime,
        base64Data: b64,
      );
    } on PlatformException catch (e) {
      throw KnowledgePickException(e.code, e.message);
    } on MissingPluginException {
      throw const KnowledgePickException(
          'UNAVAILABLE', "Couldn't open the file picker.");
    }
  }
}

/// A documents write/read failure with a stable code for the UI.
class KnowledgeSyncException implements Exception {
  final String code;
  const KnowledgeSyncException(this.code);
  @override
  String toString() => 'KnowledgeSyncException($code)';
}

/// Orchestrates document sync + extraction against the backend,
/// under the write disciplines documented at the top of this file.
class KnowledgeDocumentService {
  final TabsBackend backend;
  final KnowledgeExtractionStore store;

  KnowledgeDocumentService({required this.backend, required this.store});

  /// Fresh pull → parsed documents. Invalidates the backend's TTL
  /// cache first so the read is genuinely fresh (the R62 pattern).
  /// Throws [KnowledgeSyncException] (`PULL_FAILED`) on any failure
  /// — callers abort writes on it, never splice against stale data.
  Future<List<KnowledgeDocumentMeta>> freshDocuments() async {
    backend.invalidateSyncPull();
    final body = await backend.fetchSyncPull();
    if (body == null) throw const KnowledgeSyncException('PULL_FAILED');
    return KnowledgeDocumentMeta.listFromPull(body);
  }

  /// Adds one document (native ingest order):
  /// 1. fresh pull — abort when it fails;
  /// 2. splice: the new id is generated fresh and checked against
  ///    the pulled set (regenerated on a collision);
  /// 3. push ONLY the new row (the POST upserts sent rows; it is
  ///    not a whole-set replace, so other rows need no fileData —
  ///    which the pull does not carry anyway);
  /// 4. verify: `syncDocumentsDetailed` already requires the
  ///    server's `{synced: n}` to account for the batch (R57
  ///    pattern, in TabsBackend), and a verification pull must
  ///    contain the id — or, when the server deduplicated the
  ///    import, the canonical id it reported (whose metadata is
  ///    then returned instead of the phantom new row's).
  /// Returns the stored document's metadata.
  Future<KnowledgeDocumentMeta> addDocument({
    required String name,
    required String mimeType,
    required String base64Data,
    int? createdAt,
    String Function()? idGenerator,
  }) async {
    final existing = await freshDocuments();
    final existingIds = existing.map((d) => d.id).toSet();
    var id = (idGenerator ?? newKnowledgeUuid)();
    var guard = 0;
    while (existingIds.contains(id) && guard++ < 5) {
      id = (idGenerator ?? newKnowledgeUuid)();
    }
    if (existingIds.contains(id)) {
      throw const KnowledgeSyncException('ID_COLLISION');
    }
    final doc = KnowledgeDocumentMeta(
      id: id,
      name: name,
      mimeType: mimeType,
      createdAt: createdAt ?? DateTime.now().millisecondsSinceEpoch,
    );
    final deduplicated = await backend.syncDocumentsDetailed([
      {
        'id': doc.id,
        'name': doc.name,
        'mimeType': doc.mimeType,
        'fileData': base64Data,
        'createdAt': doc.createdAt,
      },
    ]);
    if (deduplicated == null) {
      throw const KnowledgeSyncException('SAVE_UNVERIFIED');
    }
    final after = await freshDocuments();
    // Docfix — import dedupe adoption: when the server reports
    // this import was byte-identical to an existing document, it
    // stored nothing new and named the canonical id. Verify the
    // pull holds the canonical row and adopt ITS metadata — the
    // freshly generated id is a phantom that must never surface
    // as a duplicate tile or a second extraction cache entry.
    final canonicalId = deduplicated[doc.id];
    if (canonicalId != null) {
      for (final d in after) {
        if (d.id == canonicalId) return d;
      }
      throw const KnowledgeSyncException('SAVE_UNVERIFIED');
    }
    if (!after.any((d) => d.id == doc.id)) {
      throw const KnowledgeSyncException('SAVE_UNVERIFIED');
    }
    return doc;
  }

  /// Deletes one document (native order is local-first; here the
  /// server IS the store, so: fresh pull → DELETE → verify by
  /// re-pull). A doc already absent from the fresh pull is a
  /// successful no-op (the DELETE route is idempotent too).
  Future<void> deleteDocument(String id) async {
    final existing = await freshDocuments();
    if (existing.any((d) => d.id == id)) {
      final ok = await backend.deleteDocument(id);
      if (!ok) throw const KnowledgeSyncException('DELETE_FAILED');
    }
    final after = await freshDocuments();
    if (after.any((d) => d.id == id)) {
      throw const KnowledgeSyncException('DELETE_UNVERIFIED');
    }
    await store.remove(id);
  }

  /// Clear-all: fresh pull, delete every listed doc, verify the
  /// re-pull holds none of them.
  Future<void> clearAllDocuments() async {
    final existing = await freshDocuments();
    for (final d in existing) {
      final ok = await backend.deleteDocument(d.id);
      if (!ok) throw const KnowledgeSyncException('DELETE_FAILED');
    }
    final after = await freshDocuments();
    final remaining = after.where((d) => existing.any((e) => e.id == d.id));
    if (remaining.isNotEmpty) {
      throw const KnowledgeSyncException('DELETE_UNVERIFIED');
    }
    for (final d in existing) {
      await store.remove(d.id);
    }
  }

  /// Runs extraction for one document whose file bytes are in hand
  /// (a fresh pick or a coach-approved file). Records the honest
  /// outcome in the store: ready on non-blank text, empty on a
  /// successful call with no readable text, failed when the call
  /// itself failed. Returns the resulting state.
  Future<KnowledgeExtractionState> extractFromBytes(
      KnowledgeDocumentMeta doc, String base64Data) async {
    final text = await backend.processDocument(doc.mimeType, base64Data);
    if (text != null && text.trim().isNotEmpty) {
      await store.saveText(doc.id, text);
      return KnowledgeExtractionState.ready;
    }
    if (text != null) {
      // The call SUCCEEDED but Gemini found nothing readable —
      // the docfix 'empty' state, distinct from a failure.
      await store.saveEmptyExtraction(doc.id);
      return KnowledgeExtractionState.empty;
    }
    await store.markFailed(doc.id);
    return KnowledgeExtractionState.failed;
  }

  /// Native backfill (`backfillDocumentExtractions` +
  /// `extractAndCacheDocumentText`): for a doc with no cached text,
  /// fetch its file bytes from the server (the restore path,
  /// GET /api/sync/documents/{id}) and extract them. No-op when the
  /// doc is already ready.
  /// [force] is the viewer's MANUAL retry: it re-runs extraction
  /// even for an 'empty' doc. Without it (the automatic backfill),
  /// 'empty' is terminal — a successful empty result never changes
  /// on its own, so auto-retrying it would burn a Gemini call on
  /// every Settings open forever.
  Future<KnowledgeExtractionState> backfill(KnowledgeDocumentMeta doc,
      {bool force = false}) async {
    final current = store.stateFor(doc.id);
    if (current == KnowledgeExtractionState.ready) {
      return KnowledgeExtractionState.ready;
    }
    if (current == KnowledgeExtractionState.empty && !force) {
      return KnowledgeExtractionState.empty;
    }
    final b64 = await backend.fetchDocumentData(doc.id);
    if (b64 == null || b64.isEmpty) {
      await store.markFailed(doc.id);
      return KnowledgeExtractionState.failed;
    }
    return extractFromBytes(doc, b64);
  }
}
