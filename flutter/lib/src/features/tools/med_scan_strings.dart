/// Med Scan — EVERY user-facing string for the scan-a-medication
/// flow, in ONE place (the medication_timeline_strings.dart
/// pattern).
///
/// STATUS: Juno's FINAL ruled set (Nov 22, 2026,
/// ~/workspace/build-med-scan/JUNO-COPY.md) — implemented
/// byte-exact, including punctuation and capitalisation. The
/// two templates take data values only (the existing entry's
/// saved name/dose). Disciplines: no prediction verbs, no
/// prevention claims, no medical advice, no unreceipted health
/// claims; scan results are always a proposal the user checks,
/// never a fact.
///
/// Follow-up ruling (Nov 23, 2026, JUNO-COPY.md): the
/// photo-mode action button draft is APPROVED as written (F1),
/// and the busy states are now ruled (F2) — the spinner is
/// always paired with its ruled text, never bare. One string
/// remains a Bram draft, flagged inline: the rationale
/// heading.
abstract final class MedScanStrings {
  /// §1 — the Medications screen entry button.
  static const String scanButtonLabel = 'Scan medication';

  /// §2 — scan screen title.
  static const String screenTitle = 'Scan medication';

  /// §2 — mode switch labels.
  static const String modeBarcode = 'Barcode';
  static const String modeLabelPhoto = 'Label photo';

  /// §2 — hint in barcode mode.
  static const String barcodeHint =
      'Line up the barcode on the package inside the frame.';

  /// §2 — hint in label-photo mode.
  static const String photoHint =
      'Take a clear photo of the label. Fill the frame with the label text and hold steady.';

  /// §6 — label-photo privacy line: scan screen footer in
  /// label-photo mode, and the confirm sheet footer when the
  /// proposal came from a label photo. RULED TRUE of the
  /// on-device OCR design; void if recognition ever moves to
  /// the cloud.
  static const String photoPrivacyNote =
      'Label photos are read on your phone and are not uploaded.';

  /// §6 — barcode lookup disclosure: scan screen footer in
  /// barcode mode, and the confirm sheet footer when the
  /// proposal came from a barcode. TRUE only while the lookup
  /// request carries the barcode/NDC value and nothing
  /// user-linked (Juno §6 condition; verified on the diff).
  static const String barcodeLookupNote =
      'Barcode lookups send only the barcode number to openFDA and RxNorm to find the medication name. No personal information is sent.';

  /// Follow-up ruling F1: Bram's draft APPROVED as written —
  /// the label-photo mode action button that opens the camera.
  static const String takePhotoButton = 'Take a photo of the label';

  /// Follow-up ruling F2 — busy text for the barcode lookup:
  /// shown beside/below the spinner for the state's entire
  /// duration and used as the spinner's semantics label. The
  /// trailing character is a single horizontal ellipsis
  /// (U+2026), never three full stops. No sub-lines.
  static const String busyBarcodeLookup = 'Looking up this barcode…';

  /// Follow-up ruling F2 — busy text for the on-device label
  /// read (OCR + parse). Same placement, semantics, and
  /// ellipsis rules as [busyBarcodeLookup].
  static const String busyReadingLabelPhoto = 'Reading the label photo…';

  /// §3 — camera rationale, shown in-app BEFORE the system
  /// permission prompt, on first use of Scan only.
  static const String rationaleBody =
      'To scan, Tabs needs camera access. The camera is used only to read a medication barcode or label on this phone.';

  /// §3 — rationale actions. Continue triggers the system
  /// prompt (via the camera starting); Not now dismisses with
  /// no prompt shown.
  static const String rationaleContinue = 'Continue';
  static const String rationaleNotNow = 'Not now';

  /// §3 — permission-denied message. Routes directly to manual
  /// add ([addManuallyButton]); [cancelButton] dismisses.
  static const String permissionDeniedBody =
      'Camera access is off, so scanning is not available. You can add the medication manually instead.';

  /// §3/§5 — shared action labels.
  static const String addManuallyButton = 'Add manually';
  static const String cancelButton = 'Cancel';

  /// §4 — confirm sheet title, ADD case.
  static const String confirmAddTitle = 'Check and save this medication';

  /// §4 — confirm sheet title, UPDATE case: the EXISTING
  /// entry's name and dose exactly as saved (not the scanned
  /// values), e.g. "Update Lisinopril 10 mg?". An entry with
  /// no saved dose renders name-only rather than a dangling
  /// blank.
  static String confirmUpdateTitle(String existingName, String existingDose) =>
      existingDose.isEmpty
      ? 'Update $existingName?'
      : 'Update $existingName $existingDose?';

  /// §4 — supporting line under the title, ADD case.
  static const String confirmAddIntro =
      'We filled in what the scan found. Check each field — you can edit anything.';

  /// §4 — supporting line under the title, UPDATE case.
  static const String confirmUpdateIntro =
      'This matches a medication you already saved. Saving will update that entry, not add a new one. Check each field — you can edit anything.';

  /// §4 — field labels.
  static const String nameLabel = 'Name';
  static const String doseLabel = 'Dose / strength';
  static const String formLabel = 'Form';
  static const String startDateLabel = 'Start date';

  /// §4 — nothing-saved line directly above Save, ADD case.
  static const String nothingSavedAdd =
      'Nothing is saved yet. Nothing is added until you tap Save.';

  /// §4 — nothing-saved line directly above Save, UPDATE case.
  static const String nothingSavedUpdate =
      'Nothing is changed yet. Your saved entry stays as it is until you tap Save.';

  /// §4 — buttons.
  static const String saveAddButton = 'Save medication';
  static const String saveUpdateButton = 'Save update';
  static const String addAsNewInsteadButton = 'Add as new instead';

  /// §5 — not-identified message. "could not identify" is
  /// deliberate (Juno's note): no blame wording, no "failed"
  /// claim. Actions: [addManuallyButton] (manual add prefilled
  /// with any text that was read) and [cancelButton] (back to
  /// the scan screen).
  static const String notIdentifiedMessage =
      'We could not identify this medication. Add it manually — any text we could read is already filled in.';
}
