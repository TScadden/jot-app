import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:tabs_lab/src/data/medications.dart';

/// Med Scan (Nov 22, 2026, founder direction) — identify a
/// medication from a package barcode or a photo of its label so
/// it can be added to (or used to update) the user's medication
/// list.
///
/// PRIVACY SHAPE (binding, coordinator decision):
/// - The barcode path sends ONLY the scanned barcode digits to
///   public drug databases (openFDA, fallback RxNorm) — public
///   data, no key, nothing user-specific, nothing cached.
/// - The label-photo path runs OCR fully ON-DEVICE
///   (google_mlkit_text_recognition, see med_scan_screen.dart).
///   The image is never uploaded anywhere; this file's lookup
///   service is only ever called with barcode digit strings.
/// - NOTHING here saves anything. Identification produces a
///   [MedScanProposal]; the confirm sheet (med_scan_confirm_sheet)
///   always precedes a save, and saves route through the exact
///   manual add/edit document ops in medications_screen.dart.

/// Where an identification came from.
enum MedScanSource { barcode, labelPhoto }

/// A proposed medication identity from a scan. [name] is the
/// display name; [dose] is a dose string in the app's free-text
/// dose shape ("50 mg"); [form] is display-only metadata (the
/// medication model has no form field — it is shown on the
/// confirm sheet as lookup detail, never persisted).
class MedScanProposal {
  final String name;
  final String dose;
  final String? form;
  final MedScanSource source;

  const MedScanProposal({
    required this.name,
    this.dose = '',
    this.form,
    required this.source,
  });
}

// ── NDC normalization ────────────────────────────────────────────

/// One openFDA drug/ndc query: a field (`package_ndc` or
/// `product_ndc`) and the hyphenated value to search for.
class NdcQuery {
  final String field;
  final String value;

  const NdcQuery(this.field, this.value);

  @override
  bool operator ==(Object other) =>
      other is NdcQuery && other.field == field && other.value == value;

  @override
  int get hashCode => Object.hash(field, value);

  @override
  String toString() => '$field:"$value"';
}

/// The plausible NDC digit strings encoded by a scanned barcode
/// value, most likely first.
///
/// US drug package barcodes are usually UPC-A: GS1 prefix "3" +
/// the 10-digit NDC + a check digit (12 digits total). Scanners
/// may also return the bare 10-digit NDC, an 11-digit NDC
/// (5-4-2), an EAN-13 with a leading 0 before the UPC-A, or a
/// hyphenated NDC string from a Code 128. Every plausible digit
/// string is returned so the query builder can try them all.
List<String> ndcDigitCandidates(String rawValue) {
  final out = <String>[];
  void add(String s) {
    if (s.isNotEmpty && !out.contains(s)) out.add(s);
  }

  final trimmed = rawValue.trim();
  // A hyphenated NDC read directly (e.g. "00093-5510-01"): its
  // digits are the candidate, ahead of any UPC interpretation.
  final digits = trimmed.replaceAll(RegExp(r'\D'), '');
  if (trimmed.contains('-') && (digits.length == 10 || digits.length == 11)) {
    add(digits);
  }
  if (digits.length == 12 && digits.startsWith('3')) {
    // UPC-A: "3" + 10-digit NDC + check digit.
    add(digits.substring(1, 11));
  }
  if (digits.length == 13 && digits.startsWith('03')) {
    // EAN-13 wrapping a UPC-A: 0 + "3" + NDC + check digit.
    add(digits.substring(2, 12));
  }
  if (digits.length == 11 && digits.startsWith('3')) {
    // "3" + 10-digit NDC, check digit dropped by the scanner.
    add(digits.substring(1));
  }
  add(digits);
  return out;
}

/// Hyphenates [digits] per the segment lengths, e.g.
/// `_segment('1234567890', [5, 4, 1])` → `"12345-6789-0"`.
/// Returns null when the lengths don't sum to the digit count.
String? _segment(String digits, List<int> lengths) {
  if (lengths.fold<int>(0, (a, b) => a + b) != digits.length) return null;
  final parts = <String>[];
  var at = 0;
  for (final len in lengths) {
    parts.add(digits.substring(at, at + len));
    at += len;
  }
  return parts.join('-');
}

/// The ordered openFDA queries to try for a scanned barcode
/// value: for each candidate digit string, the three standard
/// 10-digit NDC segmentations (5-4-1 — the configuration the
/// FDA uses inside UPCs — then 4-4-2 and 5-3-2) as
/// `package_ndc`, then the matching `product_ndc` (labeler +
/// product segments); an 11-digit candidate contributes its
/// 5-4-2 package form and 5-4 product form. Duplicates removed,
/// order preserved, list capped so a pathological value cannot
/// fan out into dozens of requests.
List<NdcQuery> ndcQueriesForBarcode(String rawValue) {
  final out = <NdcQuery>[];
  void add(String field, String? value) {
    if (value == null) return;
    final q = NdcQuery(field, value);
    if (!out.contains(q)) out.add(q);
  }

  final candidates = ndcDigitCandidates(rawValue);
  const segmentations = [
    [5, 4, 1],
    [4, 4, 2],
    [5, 3, 2],
  ];
  for (final digits in candidates) {
    if (digits.length == 10) {
      for (final seg in segmentations) {
        add('package_ndc', _segment(digits, seg));
      }
    } else if (digits.length == 11) {
      add('package_ndc', _segment(digits, const [5, 4, 2]));
    }
  }
  for (final digits in candidates) {
    if (digits.length == 10) {
      for (final seg in segmentations) {
        // product_ndc = labeler + product segments only: the
        // first (seg[0] + seg[1]) digits, hyphenated.
        final head = digits.substring(0, seg[0] + seg[1]);
        add('product_ndc', _segment(head, [seg[0], seg[1]]));
      }
    } else if (digits.length == 11) {
      add('product_ndc', _segment(digits.substring(0, 9), const [5, 4]));
    }
  }
  return out.take(12).toList();
}

// ── Dose / strength text ─────────────────────────────────────────

/// A strength mention: number + unit, optionally per-volume
/// ("10 mg/mL"). Units are matched longest-first so "mcg" wins
/// over "mg"/"g" at the same position.
final RegExp _strengthPattern = RegExp(
  r'(\d+(?:\.\d+)?)\s*(mcg|µg|ug|mg|ml|g|%|units?|iu)\b(\s*/\s*(ml|g))?',
  caseSensitive: false,
);

/// Normalizes a raw strength string ("50 MG", "500 mcg",
/// "10 mg/mL") to the app's dose shape ("50 mg"). Returns null
/// when the string carries no recognizable strength.
String? normalizeDoseString(String raw) {
  final m = _strengthPattern.firstMatch(raw);
  if (m == null) return null;
  final number = m.group(1)!;
  var unit = m.group(2)!.toLowerCase();
  if (unit == 'ug' || unit == 'µg') unit = 'mcg';
  if (unit == 'unit') unit = 'units';
  if (unit == 'ml') unit = 'mL';
  final per = m.group(4);
  final suffix = per == null
      ? ''
      : '/${per.toLowerCase() == 'ml' ? 'mL' : per.toLowerCase()}';
  return '$number $unit$suffix';
}

/// Dosage-form words the parsers recognize, mapped to their
/// display (singular, title-case) form.
const Map<String, String> _formWords = {
  'tablet': 'Tablet',
  'tablets': 'Tablet',
  'capsule': 'Capsule',
  'capsules': 'Capsule',
  'caplet': 'Caplet',
  'caplets': 'Caplet',
  'solution': 'Solution',
  'suspension': 'Suspension',
  'cream': 'Cream',
  'ointment': 'Ointment',
  'drops': 'Drops',
  'spray': 'Spray',
  'patch': 'Patch',
  'syrup': 'Syrup',
  'injection': 'Injection',
  'powder': 'Powder',
};

/// The first dosage-form word in [text], display-shaped, or null.
String? formWordIn(String text) {
  for (final token in text.toLowerCase().split(RegExp(r'[^a-z]+'))) {
    final form = _formWords[token];
    if (form != null) return form;
  }
  return null;
}

/// Title-cases a ALL-CAPS or all-lowercase string for display;
/// a mixed-case string is returned trimmed, untouched. Short
/// all-caps tokens (ER, XL) keep their caps.
String displayCase(String raw) {
  final s = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (s.isEmpty) return s;
  final hasLetter = s.contains(RegExp(r'[A-Za-z]'));
  if (!hasLetter) return s;
  if (s != s.toUpperCase() && s != s.toLowerCase()) return s;
  return s
      .split(' ')
      .map((w) {
        // Digit-bearing tokens are drug codes, not words
        // ("BPC-157", "D3") — they keep their caps.
        if (w.contains(RegExp(r'\d'))) return w.toUpperCase();
        if (w.length <= 2 &&
            w == w.toUpperCase() &&
            w.contains(RegExp(r'[A-Z]'))) {
          return w;
        }
        if (w.isEmpty) return w;
        return w[0].toUpperCase() + w.substring(1).toLowerCase();
      })
      .join(' ');
}

// ── openFDA parsing ──────────────────────────────────────────────

/// Parses one openFDA drug/ndc response body into a proposal.
/// The generic name is preferred over the brand name: the
/// user's list is written in generic names ("Desvenlafaxine
/// Succinate ER"), so a generic-first proposal is what the
/// matcher can recognize as an update. Returns null on an
/// empty/malformed result set.
MedScanProposal? parseOpenFdaNdcResponse(Map<String, dynamic> json) {
  final results = json['results'];
  if (results is! List || results.isEmpty) return null;
  final first = results.first;
  if (first is! Map) return null;
  final generic = '${first['generic_name'] ?? ''}'.trim();
  final brand = '${first['brand_name'] ?? ''}'.trim();
  final rawName = generic.isNotEmpty ? generic : brand;
  if (rawName.isEmpty) return null;

  var dose = '';
  final ingredients = first['active_ingredients'];
  if (ingredients is List && ingredients.isNotEmpty) {
    final ing = ingredients.first;
    if (ing is Map) {
      dose = normalizeDoseString('${ing['strength'] ?? ''}') ?? '';
    }
  }
  String? form;
  final dosageForm = '${first['dosage_form'] ?? ''}'.trim();
  if (dosageForm.isNotEmpty) {
    form = displayCase(dosageForm.split(',').first.trim());
  }
  return MedScanProposal(
    name: displayCase(rawName),
    dose: dose,
    form: form,
    source: MedScanSource.barcode,
  );
}

// ── RxNorm fallback parsing ──────────────────────────────────────

/// Extracts the RxCUI from an RxNav `ndcstatus` response, or
/// null when the NDC is unknown there.
String? parseRxNormRxcui(Map<String, dynamic> json) {
  final status = json['ndcStatus'];
  if (status is! Map) return null;
  final rxcui = '${status['rxcui'] ?? ''}'.trim();
  if (rxcui.isEmpty || rxcui == '0') return null;
  return rxcui;
}

/// The parsed pieces of a drug display name (an RxNorm name or
/// a label line): candidate name, dose, and form — every field
/// nullable; the parser is deliberately conservative.
class DrugNameParts {
  final String? name;
  final String? dose;
  final String? form;

  const DrugNameParts({this.name, this.dose, this.form});
}

/// Parses a single drug display string — an RxNorm name like
/// "Desvenlafaxine 50 MG Extended Release Oral Tablet" or a
/// label line like "Ivabradine 7.5 mg" — into name/dose/form.
/// The name is the text before the strength, minus trailing
/// form/filler words; without a strength, the whole string
/// (minus a trailing form word) is the name candidate.
DrugNameParts parseDrugDisplayName(String raw) {
  final s = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (s.isEmpty) return const DrugNameParts();
  final form = formWordIn(s);
  final m = _strengthPattern.firstMatch(s);
  String namePart;
  String? dose;
  if (m != null) {
    dose = normalizeDoseString(m.group(0)!);
    namePart = s.substring(0, m.start).trim();
  } else {
    namePart = s;
  }
  // Strip trailing form words and route/filler words from the
  // name candidate ("Desvenlafaxine Oral" → "Desvenlafaxine"),
  // and a trailing bare number (the unit-less dose shape:
  // "BPC-157 0.05" → "BPC-157").
  final tokens = namePart.split(' ');
  while (tokens.isNotEmpty) {
    if (RegExp(r'^\d+(\.\d+)?$').hasMatch(tokens.last)) {
      tokens.removeLast();
      continue;
    }
    final last = tokens.last.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    if (_formWords.containsKey(last) ||
        last == 'oral' ||
        last == 'extended' ||
        last == 'release') {
      // "Extended Release" is a name suffix worth keeping (the
      // founder's entries carry "ER"); only a bare trailing form
      // word or "Oral" is dropped. Dropping stops at the first
      // real name token.
      if (last == 'extended' || last == 'release') break;
      tokens.removeLast();
    } else {
      break;
    }
  }
  final name = tokens.join(' ').trim();
  return DrugNameParts(
    name: name.isEmpty ? null : displayCase(name),
    dose: dose,
    form: form,
  );
}

// ── Label OCR parsing ────────────────────────────────────────────

/// Words that mark an OCR line as label furniture, not a drug
/// name: directions, pharmacy boilerplate, identifiers.
const List<String> _labelJunkWords = [
  'take',
  'qty',
  'quantity',
  'refill',
  'discard',
  'expires',
  'expired',
  'lot',
  'ndc',
  'pharmacy',
  'directions',
  'use by',
  'www',
  '.com',
  'patient',
  'prescriber',
  'doctor',
  'rx #',
  'rx#',
  'filled',
  'daw',
  'sig:',
  'warning',
  'keep out',
  'store at',
  'mfg',
  'manufactured',
  'as directed',
];

bool _isJunkLine(String line) {
  final lower = line.toLowerCase();
  for (final junk in _labelJunkWords) {
    if (lower.contains(junk)) return true;
  }
  // Mostly digits/punctuation (dates, phone numbers, counts).
  final letters = RegExp(r'[A-Za-z]').allMatches(line).length;
  if (letters < 3) return true;
  return false;
}

/// Whether [line] could be a drug name: letter-bearing, not
/// label furniture, at most 6 words.
bool _isNameShaped(String line) {
  final s = line.trim();
  if (s.length < 3 || _isJunkLine(s)) return false;
  if (s.split(RegExp(r'\s+')).length > 6) return false;
  return true;
}

/// Conservative parse of on-device OCR lines from a medication
/// label photo. Prefers the line carrying the strength (US
/// labels print "Name … 50 mg" together); otherwise the longest
/// name-shaped line. A bare decimal ("0.05" — the peptide dose
/// shape) counts as a dose when no unit strength exists.
/// Returns null when nothing usable was recognized.
DrugNameParts? parseMedicationLabelLines(List<String> rawLines) {
  final lines = [
    for (final l in rawLines)
      if (l.trim().isNotEmpty) l.trim(),
  ];
  if (lines.isEmpty) return null;

  String? dose;
  String? form;
  String? name;

  // The line the dose was found on — the name almost always
  // shares it, so it outranks the longest-line guess below.
  String? doseLine;

  // 1) The strength line: name before the strength.
  for (final line in lines) {
    final m = _strengthPattern.firstMatch(line);
    if (m != null) {
      dose = normalizeDoseString(m.group(0)!);
      doseLine = line;
      form = formWordIn(line);
      final before = line.substring(0, m.start).trim();
      if (_isNameShaped(before)) {
        name = parseDrugDisplayName(before).name ?? displayCase(before);
      }
      break;
    }
  }

  // 2) Bare-decimal dose fallback ("BPC-157 0.05").
  if (dose == null) {
    for (final line in lines) {
      final m = RegExp(r'\b\d+\.\d+\b').firstMatch(line);
      if (m != null && !_isJunkLine(line)) {
        dose = m.group(0);
        doseLine = line;
        break;
      }
    }
  }

  // 3) Name: the dose's own line first (its name parse strips
  // the dose back off), else the longest name-shaped line
  // (ties → earliest).
  if (name == null && doseLine != null) {
    name = parseDrugDisplayName(doseLine).name;
    form ??= formWordIn(doseLine);
  }
  if (name == null) {
    String? best;
    for (final line in lines) {
      if (_isNameShaped(line) && (best == null || line.length > best.length)) {
        best = line;
      }
    }
    if (best != null) {
      name = parseDrugDisplayName(best).name ?? displayCase(best);
      form ??= formWordIn(best);
    }
  }

  // Form words are distinctive enough to take from any line
  // ("Take 1 tablet…" still establishes the form) when the
  // name/dose lines carried none.
  if (form == null) {
    for (final line in lines) {
      form = formWordIn(line);
      if (form != null) break;
    }
  }

  if (name == null && dose == null) return null;
  return DrugNameParts(name: name, dose: dose, form: form);
}

// ── Name matching ────────────────────────────────────────────────

/// Salt/form/route words stripped before comparing names: the
/// same drug is written "Desvenlafaxine Succinate ER" on one
/// label and "Desvenlafaxine" on another.
const Set<String> _nameStopwords = {
  'succinate',
  'hydrochloride',
  'hcl',
  'hbr',
  'sodium',
  'potassium',
  'calcium',
  'sulfate',
  'sulphate',
  'phosphate',
  'mesylate',
  'maleate',
  'fumarate',
  'tartrate',
  'citrate',
  'acetate',
  'benzoate',
  'er',
  'xr',
  'sr',
  'cr',
  'xl',
  'la',
  'extended',
  'release',
  'delayed',
  'oral',
  'tablet',
  'tablets',
  'capsule',
  'capsules',
  'caplet',
  'caplets',
  'solution',
  'suspension',
  'cream',
  'ointment',
};

/// The normalized CORE of a medication name for matching:
/// lowercased, punctuation and strength tokens removed,
/// salt/form words removed, tokens sorted (word order on labels
/// varies). Two names match confidently iff their cores are
/// equal and non-empty.
String normalizeMedicationName(String raw) {
  var s = raw.toLowerCase();
  s = s.replaceAll(_strengthPattern, ' ');
  s = s.replaceAll(RegExp(r'[^a-z0-9 ]'), ' ');
  final tokens =
      s
          .split(RegExp(r'\s+'))
          .where(
            (t) =>
                t.isNotEmpty &&
                !_nameStopwords.contains(t) &&
                !RegExp(r'^\d+(\.\d+)?$').hasMatch(t),
          )
          .toList()
        ..sort();
  return tokens.join(' ');
}

/// Finds the ONE existing entry a scanned name confidently
/// matches (equal normalized cores). Prefers an active entry;
/// an archived-only match still resolves when it is unique.
/// Returns null on no match AND on ambiguity (multiple active
/// entries with the same core) — a guess here would aim an
/// update at the wrong row, so ambiguity falls back to an ADD
/// proposal the user confirms.
MedicationEntry? findConfidentMedicationMatch(
  String scannedName,
  List<MedicationEntry> entries,
) {
  final core = normalizeMedicationName(scannedName);
  if (core.isEmpty) return null;
  final matches = entries
      .where((e) => !e.isDeleted && normalizeMedicationName(e.name) == core)
      .toList();
  if (matches.isEmpty) return null;
  final active = matches.where((e) => !e.isArchived).toList();
  if (active.length == 1) return active.single;
  if (active.isEmpty && matches.length == 1) return matches.single;
  return null;
}

// ── Lookup service (barcode → public drug data) ─────────────────

/// Resolves a scanned barcode to a medication identity via
/// openFDA drug/ndc, falling back to RxNorm RxNav for name
/// normalization when openFDA misses. Public drug data only —
/// the requests carry barcode digits and nothing else; no API
/// key; nothing is cached. Every failure mode (404 no-result,
/// 429 rate limit, timeout, malformed body) resolves to null,
/// which the UI treats as "not identified" and routes to the
/// photo/manual paths.
class DrugLookupService {
  final http.Client _client;

  /// Overall cap on one barcode lookup (Juno follow-up F3):
  /// the per-request timeout alone lets a full candidate walk
  /// of slow answers spin for minutes, so the whole lookup is
  /// capped too — on expiry it resolves to null and the UI
  /// lands on the §5 not-identified message. Injectable so
  /// tests can use a short cap.
  final Duration overallTimeout;

  DrugLookupService({
    http.Client? client,
    this.overallTimeout = const Duration(seconds: 45),
  }) : _client = client ?? http.Client();

  static const Duration _timeout = Duration(seconds: 10);

  Future<MedScanProposal?> lookupBarcode(String rawValue) {
    return _lookupBarcode(rawValue)
        .timeout(overallTimeout, onTimeout: () => null);
  }

  Future<MedScanProposal?> _lookupBarcode(String rawValue) async {
    var transportFailures = 0;
    for (final query in ndcQueriesForBarcode(rawValue)) {
      try {
        final uri = Uri.https('api.fda.gov', '/drug/ndc.json', {
          'search': '${query.field}:"${query.value}"',
          'limit': '1',
        });
        final resp = await _client.get(uri).timeout(_timeout);
        if (resp.statusCode == 429) {
          // Rate-limited: stop — hammering further only deepens
          // the limit. The caller falls through to photo/manual.
          return null;
        }
        if (resp.statusCode != 200) continue; // 404 = no match
        final decoded = jsonDecode(resp.body);
        if (decoded is Map<String, dynamic>) {
          final proposal = parseOpenFdaNdcResponse(decoded);
          if (proposal != null) return proposal;
        }
      } on TimeoutException {
        transportFailures++;
      } catch (_) {
        transportFailures++;
      }
      if (transportFailures >= 3) break;
    }
    return _rxNormFallback(rawValue);
  }

  /// RxNorm fallback: NDC → RxCUI (ndcstatus) → the RxNorm
  /// name (properties), parsed into name/dose/form. Best
  /// effort; any failure resolves to null.
  Future<MedScanProposal?> _rxNormFallback(String rawValue) async {
    try {
      final tenDigit = ndcDigitCandidates(rawValue)
          .where((d) => d.length == 10)
          .firstOrNull;
      if (tenDigit == null) return null;
      final statusUri = Uri.https('rxnav.nlm.nih.gov', '/REST/ndcstatus.json', {
        'ndc': tenDigit,
      });
      final statusResp = await _client.get(statusUri).timeout(_timeout);
      if (statusResp.statusCode != 200) return null;
      final statusJson = jsonDecode(statusResp.body);
      if (statusJson is! Map<String, dynamic>) return null;
      final rxcui = parseRxNormRxcui(statusJson);
      if (rxcui == null) return null;
      final propsUri = Uri.https(
        'rxnav.nlm.nih.gov',
        '/REST/rxcui/$rxcui/properties.json',
      );
      final propsResp = await _client.get(propsUri).timeout(_timeout);
      if (propsResp.statusCode != 200) return null;
      final propsJson = jsonDecode(propsResp.body);
      if (propsJson is! Map<String, dynamic>) return null;
      final props = propsJson['properties'];
      if (props is! Map) return null;
      final rxName = '${props['name'] ?? ''}'.trim();
      if (rxName.isEmpty) return null;
      final parts = parseDrugDisplayName(rxName);
      if (parts.name == null) return null;
      return MedScanProposal(
        name: parts.name!,
        dose: parts.dose ?? '',
        form: parts.form,
        source: MedScanSource.barcode,
      );
    } catch (_) {
      return null;
    }
  }
}
