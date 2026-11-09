import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/common_conditions.dart';
import 'package:tabs_lab/src/features/tools/research_screen.dart';

/// The bundled Research library, end to end.
///
/// Regression coverage for the production bug this package fixed:
/// `loadResearchEntries` enumerated assets by reading
/// `AssetManifest.json`, but built app bundles ship only
/// `AssetManifest.bin`, so on device the library loaded empty and
/// every condition rendered "Nothing here yet" — while the widget
/// tests passed, because their fake bundles served a synthetic JSON
/// manifest. The first test below loads through the REAL rootBundle
/// so the production path itself is exercised.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Every condition name the Research screen can show content for:
  /// the original 15 plus the expansion batches (tags are the exact
  /// `commonConditions` strings; dual-tagged conditions list every
  /// catalog string their entries carry).
  const coveredConditions = <String>[
    'POTS (Postural Orthostatic Tachycardia Syndrome)',
    'Mast Cell Activation Syndrome (MCAS)',
    'Ehlers-Danlos Syndrome (EDS - Hypermobile)',
    'Scoliosis',
    'Hypermobility Spectrum Disorder (HSD)',
    'Dysautonomia',
    'Orthostatic Hypotension',
    'Vasovagal Syncope',
    'Chronic Fatigue Syndrome (ME/CFS)',
    'Fibromyalgia',
    'Chronic Migraine',
    'Gastroparesis',
    'Long COVID (Post-Acute Sequelae of SARS-CoV-2)',
    'Neuropathy (Peripheral / Small Fiber)',
    "Raynaud's Phenomenon",
    // Expansion batch 1 (autoimmune + endocrine/metabolic).
    'Lupus (Systemic Lupus Erythematosus / SLE)',
    'Rheumatoid Arthritis (RA)',
    'Arthritis (Rheumatoid / RA)',
    'Multiple Sclerosis (MS - RRMS / PPMS)',
    "Sjögren's Syndrome",
    "Hashimoto's Thyroiditis",
    "Graves' Disease",
    'Celiac Disease',
    "Crohn's Disease",
    'Ulcerative Colitis',
    'Psoriatic Arthritis',
    'Ankylosing Spondylitis',
    'Psoriasis (Plaque / Guttate)',
    'Diabetes (Type 1)',
    'Diabetes (Type 2)',
    'Hypothyroidism',
    'Hyperthyroidism',
    'PCOS (Polycystic Ovary Syndrome)',
    'Endometriosis',
    'Anemia (Iron Deficiency)',
    'High Cholesterol (Hyperlipidemia)',
    // Expansion batch 2 (cardiovascular + neuro/psych).
    'Hypertension (High Blood Pressure)',
    'Atrial Fibrillation (AFib)',
    'Heart Failure',
    'Depression (Major Depressive Disorder / MDD)',
    'Major Depressive Disorder',
    'Generalized Anxiety Disorder (GAD)',
    'ADHD (Attention-Deficit/Hyperactivity Disorder)',
    'PTSD (Post-Traumatic Stress Disorder)',
    'Bipolar I Disorder',
    'Bipolar II Disorder',
    'OCD (Obsessive-Compulsive Disorder)',
    'Insomnia',
    'Epilepsy / Seizure Disorder',
    "Parkinson's Disease",
    'Restless Legs Syndrome (RLS)',
    'Narcolepsy',
    'Essential Tremor',
    'Trigeminal Neuralgia',
    "Ménière's Disease",
    'Intracranial Hypertension (IIH)',
    'Chiari Malformation',
  ];

  test('real rootBundle loads the full library (production path)',
      () async {
    final entries = await loadResearchEntries(rootBundle);
    expect(entries.length, 163,
        reason: 'the bundled library should load every entry file');
    for (final condition in coveredConditions) {
      expect(entriesForCondition(entries, condition), isNotEmpty,
          reason: 'no entries tagged for $condition');
    }
  });

  test('bundled entry files are complete, cited, and catalog-tagged',
      () {
    final files = Directory('assets/research')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList();
    expect(files.length, 163);

    final ids = <String>{};
    final covered = <String>{};
    for (final file in files) {
      final entry = jsonDecode(file.readAsStringSync())
          as Map<String, dynamic>;
      final id = '${entry['id'] ?? ''}';
      expect(id, isNotEmpty, reason: '${file.path} has no id');
      expect(ids.add(id), isTrue, reason: 'duplicate entry id $id');
      expect(id, file.uri.pathSegments.last.replaceAll('.json', ''),
          reason: 'entry id should match its file name');

      for (final field in ['title', 'summary', 'detail', 'sourceName']) {
        expect('${entry[field] ?? ''}'.trim(), isNotEmpty,
            reason: '$id has an empty $field');
      }
      final takeaways = entry['takeaways'];
      expect(takeaways, isA<List>(), reason: '$id takeaways not a list');
      expect(takeaways, isNotEmpty, reason: '$id has no takeaways');

      // Every entry cites an https web source (Juno condition C1:
      // no insecure source links in the library).
      final url = '${entry['sourceUrl'] ?? ''}';
      expect(url, startsWith('https://'),
          reason: '$id sourceUrl should be https: $url');

      // Juno's standing rule: every detail closes with the explicit
      // not-endorsing disclaimer (the existing library places it in
      // the final block, before or after the talk-to-your-doctor
      // line, so assert it is present in the closing text).
      final detail = '${entry['detail']}'.trim();
      final closing =
          detail.length > 400 ? detail.substring(detail.length - 400) : detail;
      expect(closing,
          contains('Tabs is not endorsing or verifying this material.'),
          reason: '$id detail is missing the disclaimer tail');

      final tags = (entry['conditionTags'] as List).cast<String>();
      expect(tags, isNotEmpty, reason: '$id has no condition tags');
      for (final tag in tags) {
        expect(commonConditions, contains(tag),
            reason: '$id tag "$tag" is not a catalog condition name');
        covered.add(tag);
      }
    }
    for (final condition in coveredConditions) {
      expect(covered, contains(condition),
          reason: 'no bundled entry covers $condition');
    }
  });
}
