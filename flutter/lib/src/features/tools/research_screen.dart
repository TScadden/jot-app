import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Medical disclaimer — always visible at the top (native ResearchScreen.kt,
/// verbatim copy).
const String researchDisclaimer =
    'For educational purposes only. This is not medical advice. '
    'Talk to your doctor before trying anything here.';

/// One document from the sync-pull `documents` array — the backend's
/// `KnowledgeDocumentDtoModel` (`{id, name, mimeType, fileData?, createdAt}`).
class ResearchDocument {
  final String id;
  final String name;
  final String mimeType;
  final String? fileData; // base64; nullable
  final int createdAt; // epoch ms

  const ResearchDocument({
    required this.id,
    required this.name,
    required this.mimeType,
    this.fileData,
    required this.createdAt,
  });

  /// Tolerant parse; throws [FormatException] on a malformed row and the
  /// caller skips it.
  factory ResearchDocument.fromJson(Map<String, dynamic> map) {
    final id = map['id']?.toString() ?? '';
    final name = map['name']?.toString() ?? '';
    if (id.isEmpty || name.isEmpty) {
      throw const FormatException('Research document needs id and name');
    }
    final created = map['createdAt'];
    return ResearchDocument(
      id: id,
      name: name,
      mimeType: map['mimeType']?.toString() ?? '',
      fileData: map['fileData']?.toString(),
      createdAt: created is num
          ? created.toInt()
          : int.tryParse(created?.toString() ?? '') ?? 0,
    );
  }
}

/// Parse the sync-pull `documents` array; skips malformed rows, never throws.
List<ResearchDocument> parseResearchDocuments(dynamic raw) {
  if (raw is! List) return const [];
  final out = <ResearchDocument>[];
  for (final item in raw) {
    if (item is Map<String, dynamic>) {
      try {
        out.add(ResearchDocument.fromJson(item));
      } catch (_) {
        // Skip malformed rows — never fail the whole library.
      }
    }
  }
  return out;
}

/// Best-effort text preview of a document's content.
///
/// Only attempts to decode when the MIME type looks textual; binary files
/// (PDFs, images) return null so the UI says so honestly instead of
/// showing garbage. Never throws.
String? researchPreview(ResearchDocument doc, {int maxChars = 1500}) {
  final data = doc.fileData;
  if (data == null || data.isEmpty) return null;
  final mime = doc.mimeType.toLowerCase();
  final looksText = mime.startsWith('text/') ||
      mime.contains('json') ||
      mime.contains('xml') ||
      mime.contains('markdown');
  if (!looksText) return null;
  try {
    final bytes = base64Decode(data.trim());
    final text = utf8.decode(bytes, allowMalformed: true).trim();
    if (text.isEmpty) return null;
    return text.length > maxChars ? '${text.substring(0, maxChars)}…' : text;
  } catch (_) {
    return null;
  }
}

/// "Oct 11, 2026" — small local formatter (no intl dep allowed).
String formatResearchDate(int timeEpochMs) {
  if (timeEpochMs <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(timeEpochMs);
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  return '${months[d.month - 1]} ${d.day}, ${d.year}';
}

/// Round 18, Team D — Research tool screen.
///
/// Ports the spirit of `ResearchScreen.kt`: the pinned medical disclaimer and
/// a research library whose entries expand to show content. The data layer
/// differs per the round brief — documents come from the sync-pull
/// `documents` array (backend `KnowledgeDocumentDtoModel`) and the user's
/// conditions from `profile.conditions` provide a context line.
class ResearchToolScreen extends StatefulWidget {
  final VoidCallback? onBack;
  final TabsBackend? backend;

  const ResearchToolScreen({super.key, this.onBack, this.backend});

  @override
  State<ResearchToolScreen> createState() => _ResearchToolScreenState();
}

class _ResearchToolScreenState extends State<ResearchToolScreen> {
  TabsBackend get _backend => widget.backend ?? TabsBackend();

  bool _loading = true;
  List<ResearchDocument> _documents = const [];
  List<String> _conditions = const [];
  String? _error;
  String? _expandedId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final body = await _backend.fetchSyncPull();
      final docs = parseResearchDocuments(body?['documents']);
      final profile = body?['profile'];
      final conditions = profile is Map<String, dynamic>
          ? TabsBackend.decodeProfileList(profile['conditions'])
              .map((c) => c['name']?.toString() ?? '')
              .where((n) => n.isNotEmpty)
              .toList()
          : <String>[];
      if (!mounted) return;
      setState(() {
        _documents = docs;
        _conditions = conditions;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load your data. We could not pull your latest '
            'entries. Check your connection and try again.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back,
              color: NotelColors.textPrimary, semanticLabel: 'Back'),
          onPressed: widget.onBack ?? () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Research',
          style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary),
        ),
      ),
      body: Column(
        children: [
          _disclaimerBanner(),
          if (_conditions.isNotEmpty) _conditionsLine(),
          const SizedBox(height: 14),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _disclaimerBanner() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: NotelColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: NotelColors.warning.withValues(alpha: 0.4)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber, size: 20, color: NotelColors.warning),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              researchDisclaimer,
              style: TextStyle(
                  fontSize: 13,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                  color: NotelColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _conditionsLine() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'Personalized for: ${_conditions.join(', ')}',
          style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: NotelColors.textSecondary),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: NotelColors.primary));
    }
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [_errorBanner(_error!)],
      );
    }
    if (_documents.isEmpty) {
      return ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: NotelColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: NotelColors.divider),
            ),
            child: const Column(
              children: [
                Icon(Icons.science,
                    size: 40, color: NotelColors.textSecondary),
                SizedBox(height: 12),
                Text('Nothing here yet',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: NotelColors.textPrimary)),
                SizedBox(height: 6),
                Text(
                  'The research library is empty. New documents will appear here when they are added.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: NotelColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      itemCount: _documents.length,
      separatorBuilder: (_, _) => const SizedBox(height: 14),
      itemBuilder: (context, i) => _documentCard(_documents[i]),
    );
  }

  Widget _errorBanner(String text) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: NotelColors.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: NotelColors.error.withValues(alpha: 0.4)),
      ),
      child: Text(text,
          style:
              const TextStyle(fontSize: 13, color: NotelColors.textPrimary)),
    );
  }

  Widget _documentCard(ResearchDocument doc) {
    final expanded = _expandedId == doc.id;
    final preview = researchPreview(doc);
    final dateStr = formatResearchDate(doc.createdAt);
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () =>
          setState(() => _expandedId = expanded ? null : doc.id),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: NotelColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: NotelColors.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.menu_book,
                    size: 20, color: NotelColors.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    doc.name,
                    style: const TextStyle(
                        fontSize: 15,
                        height: 1.3,
                        fontWeight: FontWeight.bold,
                        color: NotelColors.textPrimary),
                  ),
                ),
                Icon(
                    expanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                    color: NotelColors.textSecondary),
              ],
            ),
            if (dateStr.isNotEmpty || doc.mimeType.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                [if (doc.mimeType.isNotEmpty) doc.mimeType, if (dateStr.isNotEmpty) dateStr]
                    .join(' · '),
                style: const TextStyle(
                    fontSize: 12, color: NotelColors.textSecondary),
              ),
            ],
            if (expanded) ...[
              const SizedBox(height: 12),
              const Divider(color: NotelColors.divider),
              const SizedBox(height: 12),
              if (preview != null)
                Text(preview,
                    style: const TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: NotelColors.textPrimary))
              else
                const Text(
                  'Preview is not available for this file type. '
                  'Open the main Tabs app to view the full document.',
                  style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: NotelColors.textSecondary),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
