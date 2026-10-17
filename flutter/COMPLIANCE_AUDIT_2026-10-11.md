# Juno Compliance Audit — Flutter Rebuild

**Date:** October 11, 2026
**Auditor:** Juno (compliance)
**Branch:** `flutter-app`
**Scope:** everything under `jot-app/flutter/` (rounds 1–13 as committed, including round 13's health-data reads + streak work)
**Founder directive:** "Make sure we are compliant with laws while we rebuild. It's easier to do now than when the app is completely full."

**Method:** read every data-layer file (`auth_api`, `session_store`, `weather_api`, `location_service`, `health_connect_service`, `health_data`, `health_repository`, `tabs_backend`), the permission touchpoints (`home_screen` weather tap, `weather_sheet` rationale card, `connections_screen`), the login screen terms line, `AndroidManifest.xml`, `MainActivity.kt`, and `pubspec.yaml`; diffed permission/rationale ordering against the native app (`TodayScreen.kt`, `DataConnectionsScreen.kt`, `LoginScreen.kt`).

**Verdict:** the data layer is clean — no credential logging, no health-value logging, no fabricated readings, no background permissions. Three must-fix items below, all small while the app is small.

---

## 1. Data inventory (what the Flutter app collects, where it goes, how it's stored)

| Data | Collected when | Sent to | Stored | Logged |
|---|---|---|---|---|
| Email + password | Login form submit | `POST https://api.jottracker.com/api/auth/login` (HTTPS) | Password: never persisted, memory-only for the request | Never |
| Session token, refresh token, user ID, email | Login success | Bearer header to `api.jottracker.com` | `flutter_secure_storage` (Android Keystore-backed EncryptedSharedPreferences) | Never |
| IP-based location (city, lat/lon, country from ipinfo.io) | Home screen load (weather) | `https://ipinfo.io/json` → coords forwarded to `https://api.open-meteo.com/v1/forecast` (HTTPS) | Memory only, never persisted | Never |
| GPS coordinates | Weather-icon tap + system permission grant | `api.open-meteo.com` only (HTTPS) | Memory only, never persisted | Never |
| Health Connect reads (HR samples, sleep, calories, steps, resting HR, BP) | Home screen load, only when HC connected | Nowhere — on-device reads, used in-memory for vitals/snapshot | Round 16+: one encrypted JSON blob in `flutter_secure_storage` (`home_data_cache_v1`): today's vitals + streaks, stale-while-revalidate, date-bound (vitals apply only when fetched today; streaks ≤7 days). No network transmission. (Was "Not persisted" before round 16.) | Never |
| HC connection state (granted permission *names* + timestamp) | Permission grant | Nowhere | `flutter_secure_storage` | Never |
| Streak, log entries, habits, manual BP logs | Home screen load, only when logged in | `GET https://api.jottracker.com/api/sync/pull`, `/api/habits` (Bearer, HTTPS) | Memory only | Never |

No analytics, crash-reporting, or ad SDKs in `pubspec.yaml`. No `print`/`debugPrint`/`Log` calls anywhere in `lib/` or `MainActivity.kt`.

---

## 2. What passes

- **Auth security:** tokens in secure storage; password never persisted or logged; HTTPS hard-coded with no http fallback; generic error messages that don't leak transport details. Matches native.
- **Location privacy:** while-in-use only (`ACCESS_COARSE_LOCATION`/`ACCESS_FINE_LOCATION`); `ACCESS_BACKGROUND_LOCATION` never declared or requested; position used only for the Open-Meteo request; honest icon-only state on any failure. Matches native.
- **Health data:** no medical claims, diagnoses, or treatment advice anywhere in the UI. Vitals/snapshot render `--`/empty states on missing data; the biometric zero-exclusion rule and daytime-only HR (7am–10pm) are enforced in `health_data.dart` and covered by tests. Weather info sheets are general weather-education copy ported verbatim from the native app (no diagnoses, no prescriptions).
- **Health Connect scope:** the 14 record-type reads + HISTORY match the native manifest exactly; `READ_HEALTH_DATA_IN_BACKGROUND` is never declared or requested; the `health_permissions` meta-data, `ACTION_SHOW_PERMISSIONS_RATIONALE`, and `VIEW_PERMISSION_USAGE` intent-filters are present per round 12b.
- **Register/Google-login buttons:** UI-only, no-ops — no data sent.

---

## 3. MUST-FIX NOW

### MF-1 — Location: system permission fires before the in-app rationale (Play prominent-disclosure rule)
**File:** `lib/src/features/home/home_screen.dart` (`_onWeatherTap` → `_fetchGpsPositionForHeader`)
**Problem:** tapping the weather icon calls `location.requestPermission()` (the *system* dialog) immediately, before the weather sheet — and its in-app rationale card ("Use your location for weather?" / "Share location") — is ever shown. The native app does the opposite: tap only opens the sheet (`showWeatherSheet = true` in `TodayScreen.kt:147`); the system request fires solely from the rationale card's "Share location" button. Play requires the prominent in-app disclosure *before* the system request.
**Fix:** remove the `requestPermission()` call from the header-tap path. The tap opens the sheet; the sheet's existing `_onShareLocation` (rationale → "Share location" → system dialog → GPS load) becomes the sole permission-request path. Keep the silent IP fallback for denied/permanently-denied.

### MF-2 — Login terms line looks like links but does nothing
**File:** `lib/src/features/auth/login_screen.dart` (`_buildTermsLine`)
**Problem:** "Terms of Use" and "Privacy Policy" are styled as links but are plain `Text` in a `Wrap` — not tappable. The native screen opens `https://api.jottracker.com/terms.html` and `https://api.jottracker.com/privacy.html` (`LoginScreen.kt:687,702`). A user cannot currently reach the privacy policy from the app at all.
**Fix:** make both spans tappable (add `url_launcher`, or route through the existing platform channel) opening those two URLs, matching native.

### MF-3 — Health Connect: no in-app disclosure before the permission UI
**File:** `lib/src/features/connections/connections_screen.dart` (`_onConnectTap`)
**Problem:** tapping the "Android Health" row launches the Health Connect permission UI directly, with no in-app explanation of *what* health data Tabs reads (heart rate, sleep, steps, calories, blood pressure, etc.) and *why* (vitals strip, weekly snapshot). Google's Health Connect policy requires a prominent in-app disclosure before the request. (The native screen has the same gap — fix it here while the app is small rather than porting the gap.)
**Fix:** on tap, show an in-app dialog first — e.g. "Tabs reads your heart rate, sleep, steps, calories, and blood pressure from Health Connect to show your vitals and weekly snapshot. Your health data stays on your device and is never sold." — with "Continue" (→ `requestPermissions()`) and "Not now". Reuse the same dialog in the future onboarding connections step.

### MF-4 — Verify the hosted privacy policy covers the Flutter flows
**Not a code change; a verification step.** With MF-2 fixed, users can reach `https://api.jottracker.com/privacy.html`. Confirm that page discloses: (a) the 14 Health Connect data types + history read, (b) IP-based geolocation via ipinfo.io and weather via Open-Meteo, (c) GPS use for weather on explicit tap. If any are missing, update the hosted page (server repo) before the next phone build.

**Round 16 extension:** when the hosted policy is next updated, also note the on-device encrypted caching of home-screen health values (one `flutter_secure_storage` JSON blob: today's vitals + streaks, stale-while-revalidate, no network transmission). The policy's §1b currently describes health data as backend-stored only.

**Round 54 (Oct 13, 2026) — production ledger additions (Juno P1–P6):** Round 54 gave the Health Coach real Google Calendar access (CalendarContract bridge: upcoming-events context, approve-time permission gate with in-app disclosure, writable-calendar insert / exact-title delete). The following are required before production; none block Lab phone builds.

- **P1:** MF-4 addition required before production: replace/augment §1f with a new item reading exactly: "Calendar (Health Coach): If you connect Google Calendar and grant calendar permission, the Health Coach reads the titles and start times of your events for today and the next 14 days and transmits them to our backend and the Google Gemini API as context for your Coach conversations. The Coach may propose calendar events and deletions, and it adds or deletes an event only after you tap Approve on the proposal. Disconnecting Google Calendar in Settings > Connected Apps stops this access, and you can revoke calendar permission at any time in Android system settings."
- **P2:** Play Console — READ/WRITE_CALENDAR permissions declaration + Data Safety update (calendar/appointments data collected and shared with the AI processor; app functionality; not sold; not advertising). Founder/Console action.
- **P3:** At production, move/duplicate the A1 disclosure to the Connected Apps connect moment (approve-time-only disclosure is Lab-acceptable; a manual system-settings grant bypasses it).
- **P4:** At production, make the upcoming-events context permission-aware (currently a SecurityException yields "No events found." instead of native's "Calendar events are unavailable right now.").
- **P5:** Before production, revisit "your Google Calendar" wording in confirmations — insert target is the best writable DEVICE calendar (connected-email preferred), not necessarily Google.
- **P6:** Verify the backend does not separately retain/log the userContext payload beyond chat history (it now carries calendar titles).

**Round 65 (Oct 16, 2026) — production ledger additions (Juno P7–P10):** Round 65 restored Digital Knowledge Extraction at native parity: user documents sync to the Tabs server (`POST /api/sync/documents`, shape `{id, name, mimeType, fileData, createdAt}`), their bytes are sent to server-side Gemini for extraction (`POST /api/ai/process-document`), the extracted text is cached device-locally in an account-bound secure-storage store, and that extracted text now also joins the Health Coach's `userContext` (lowest-priority section of the 9,000-char R55 budget). Juno verdict for the Lab build: SIGN OFF — no Lab-blocking items; Flutter's disclosure copy is verbatim native, so it is not less disclosed than native for identical behaviour. The following are required before production; none block Lab phone builds.

- **P7:** MF-4 addition required before production: the hosted privacy policy must gain a Digital Knowledge Extraction item reading exactly: "Documents and Knowledge Extraction: When you add a document or text note in Settings > Digital Knowledge Extraction, the file is uploaded to and stored on our servers, and its contents are transmitted to the Google Gemini API, which extracts the text. The extracted text is stored on your device and is also sent to the Gemini API as context for your Health Coach conversations and reports. Opening Settings may automatically extract any document that does not yet have extracted text. You can delete a document at any time in Settings > Digital Knowledge Extraction; deletion removes it from our servers and removes its extracted text from your device. Extracted text already included in a past Coach conversation remains part of that conversation's history."
- **P8:** Play Console — Data Safety update for this flow: declare Files and docs (and health information contained in user documents) as collected, stored on the Tabs server, and shared with the AI processor (Google Gemini via the Tabs backend); purpose app functionality; not sold; not advertising. Founder/Console action.
- **P9:** Verify the backend does not separately retain/log (a) the `/api/ai/process-document` payloads (full document bytes), (b) the `/api/sync/documents` fileData at rest beyond the account's document store and its deletion path, and (c) the coach userContext payload beyond chat history (extends P6 — it now carries extracted document text, the most sensitive content yet to ride it). Also confirm server-side deletion of a document is honoured in backups/derived stores on the normal retention cycle.
- **P10:** Production copy correction (native copy, ported verbatim in R65, may not ship to production as-is): the Settings card badge "On-device" (settings_screen.dart, FILE KNOWLEDGE BASE card) is false for this flow — documents are stored on the server and extraction runs server-side in Gemini — and must be removed or replaced (e.g. "Gemini") before production. In the same pass, revisit the subtitle "extract permanent knowledge (patterns, triggers, facts) that Gemini will remember": extraction is a transcription, documents do not populate the Extracted Facts string, and documents are deletable (not permanent); the production subtitle must describe transcription + server storage + Coach use in those terms.

---

## 4. WATCH LIST (bake into upcoming rounds)

1. **Medical-disclaimer banners:** when AI/Coach/clinical-insight features arrive, add the native-style medical disclaimer banners (native has them on Coach and AI/Clinical Advocate screens). The current weather info sheets are general education copy — fine as-is — but any *personalized* health interpretation needs the disclaimer.
2. **Data Safety section (Play Console):** will need to declare location, Health Connect health data, and account data. Founder action in Play Console; prepare the answers now.
3. **Health-apps declaration (Play Console):** founder action, cannot be done by the team.
4. **Onboarding connections step:** must reuse `HealthConnectService` (already designed for it) and include the MF-3 disclosure dialog.
5. **Never add background access** (`ACCESS_BACKGROUND_LOCATION`, `READ_HEALTH_DATA_IN_BACKGROUND`) without a new Juno review and a Play-policy justification.
6. **Session restoration on cold launch:** keep tokens in secure storage, never log the token, handle 401/refresh explicitly.
7. **No new third-party SDKs** (analytics, crash reporting, ads, attribution) without a Juno disclosure review — `pubspec.yaml` is currently clean; keep it that way.
8. **Re-verify the biometric zero rule and daytime-only HR** in every future health-data round (already a team lesson; keep enforcing).
9. **Age gate:** login sends `ageConfirmed: false` (native behavior). When registration wires up, the age-confirmation flow needs a compliance review (COPPA / Play Families policy).
10. **Account/data deletion:** when the settings screen arrives, provide a user-facing path to delete account data (Play policy + GDPR/CCPA).

---

## 5. Sign-off

Juno: the data layer and permission scopes are compliant as built. The four must-fix items above are disclosure/ordering gaps, not data-handling violations — fix them while the app is small, per the founder's directive. No blockers on shipping phone builds once MF-1–MF-3 are in.

*Standing rule (added to `~/workspace/team/memory/LESSONS.md` with this audit): every Flutter round gets a Juno compliance check before delivery, not just health-data rounds.*
- **R66 (2026-10-16) — Progress Reports (Flutter Lab):** health data leaves the device only via the existing authenticated POST /api/ai/report, same payload classes as native including the dataAvailability anti-hallucination block; generated PDFs are stored in the app-private documents directory (divergence from native's Downloads copy — safer; delivery is share-sheet only, after the native share-confirmation dialog); MedicalDisclaimerBanner, the PDF closing disclaimer, and the "What's in this report" AI disclosure are verbatim native. Juno sign-off on file.
- **R67 (2026-10-16) — Spike Review PDF export (Flutter Lab):** no new data leaves the device; the PDF is generated on-device from Health Connect samples already loaded for the Heart screen, saved to the app-private documents directory (the R66 divergence from native's Downloads copy), and shared only when the user taps Share on the saved SnackBar. No new permissions, no new endpoints, no new third-party SDKs (`pdf`/`printing`/`path_provider` already landed in R66). The founder's zero rule is enforced before the summary statistics (a deliberate, documented divergence from native's unfiltered exporter). Juno sign-off on file.

---

## R70 Addendum (2026-10-17) — Historical Health Store, CSV Import, Sleep Need, Daily Score

**Auditor:** Juno (compliance) — mandatory wording + health-data pass, client side (the server side was signed separately, PR #7, conditions recorded there).
**Branch:** `r70-historystore`, head `2208c62`; R70 range reviewed as `4fe382c..2208c62` (WS1 store + HC capture, WS2 union migration, WS3 CSV import, Sleep Need, Daily Score engine + Home circle + history/day-detail screens).
**Method:** read `health_history_store.dart`, `health_history_sync.dart`, `health_history_queries.dart`, `metrics_csv_import.dart`, `sleep_need.dart`, `daily_score.dart`, `daily_score_vocabulary.dart`, `daily_score_circle.dart`, `daily_score_screen.dart`, the Sleep Need section of `sleep_screen.dart`, the Settings import row/flow, and the account-lifecycle wiring in `main.dart` + `account_actions.dart`; diffed the R70 range for manifest, pubspec, and backend changes (none).

**Verdict: SIGN OFF WITH CONDITIONS.** Conditions C1–C7 below are pre-delivery: the Lab APK does not ship until the fix pass lands and the C1 wiring is re-verified. If any of C1–C7 is unmet at delivery time, this verdict converts to BLOCK. C8 is a production gate, not a Lab gate.

### What passes

- **Store posture (in isolation):** one JSON blob (`health_history_store_v1`) in `flutter_secure_storage`, same as the sibling caches; merge-only writes (mergeRefresh for Health Connect captures, fill-gaps for imports, the stored date set never shrinks — the Sep 30, 2026 lesson); the founder zero rule enforced on the way in for both merge modes and on blob re-read (spike count 0 stays, it is real data); Daily Score fields are write-once via `persistScore` only, and `sanitized()` strips score fields from every incoming merge row so no capture or import can smuggle a score in. No logging of health values anywhere in the R70 files.
- **CSV import surface (WS3):** user-initiated only, through the pre-existing Round 48 SAF picker channel (`GetContent`, capped read, no storage permission). What enters the device: date, resting HR, sleep, deep sleep, spike count from a Tabs metrics export — nothing else parses (wrong header rejected, malformed rows skipped and counted, "No data"/empty/0 cells never fill). **No new transmission: imported data is merged into the on-device store and nowhere else.** The import row copy ("Fill in older days from a Tabs metrics export. Days already on this device are kept.") and the result dialog are accurate.
- **Client sync for daily biometrics is INERT — by absence.** The R70 range adds no endpoint, no URL, and no call: `tabs_backend.dart`, `AndroidManifest.xml`, and `pubspec.yaml` are untouched in the range, and no daily-biometrics upload wiring of any kind ships in this build, live or flag-disabled. There is nothing to accidentally enable before the server PR merges. The only network flows that read store data are the pre-existing, already-signed surfaces reading through the union helper within their existing windows: the R66 report collector (`POST /api/ai/report`, user-chosen report window) and the Health Coach context loader (its existing 7/28-day windows). New depth inside those windows is completeness, not a new destination or data class. Key Metrics CSV export likewise stays a user-initiated share of the same data classes, now at store depth for "All Time."
- **Permissions/disclosures:** no new permissions, no new SDKs, no new disclosures triggered. Captures run only behind already-connected Health Connect loads and the existing MF-3 disclosure flow.
- **Daily Score evidence discipline:** no citation of the Welltory medRxiv preprint (or any study) anywhere in `lib/` or `test/` — grep-verified. The one basis sentence in the "How this score works" card (see C4) references HRV/RMSSD being among the most-studied signals in physiology in Tabs' own words, with no citation and no claim that the score itself is validated. No diagnostic terms, no "stress"/"recovery" claims presented as fact, no vendor language or borrowed branding, no accuracy claims anywhere in the score or Sleep Need copy. Components are labeled as what they are (Sleep, HRV (RMSSD), Resting heart rate); every label pairs text with color, never color alone; the cold start shows a dash and no number, and no score is persisted from nothing.

### Wording rulings (Daily Score + Sleep Need) — KEEP unless listed in C2–C7

- **Bands — all KEEP:** "Great" (80+), "Good" (60–79, founder-seen), "Low" (40–59), "Very low" (<40). "Great" is ruled KEEP: a plain top-tier word in the same register as the founder-seen "Good," describing the score level against the user's own baseline; it carries no diagnostic, vendor, or accuracy claim, and the downward extension ("Low"/"Very low") was never disputed.
- **Direction chips — words KEEP:** "Above" / "Below" / "Normal" for HRV and resting HR. "Normal" here means exactly one thing after C2: within ±2% of the user's own baseline median. Founder-seen for resting HR. (One fill change for resting HR — see C3.)
- **Sleep chips — "Good" (≥80), "Low" (40–59), "Very low" (<40) KEEP** ("Good" is founder-seen for Sleep). The 60–79 tier changes — see C2.
- **Cold start — KEEP:** "Building" chip, "Building baseline" heading, semantics "Daily Score, building baseline," and the body "Your score appears once at least 7 earlier days exist for one part of the score: sleep, HRV, or resting heart rate. From then on, each day is scored once, against your own recent baseline." Accurate against the engine (≥7 baseline days per component, write-once).
- **Day detail — KEEP:** "Daily Score: {n} · {band}", "Same as the previous scored day ({date})", "Higher/Lower by {n} than the previous scored day ({date})" (trend vs the previous *scored* day — honest, not calendar-yesterday), the concept sleep line "{asleep} of {need} need", "{value} ms · your baseline {baseline} ms" / bpm equivalents, "Not counted" with its three honest reasons ("the need estimate needs 7 earlier nights" / "the baseline needs 7 earlier days"), the three "No … stored for this day/night" lines, "No score stored for this day.", and "Scored once from the data stored for this day. Later changes to earlier days do not change this score."
- **Disclaimer — KEEP** on the history screen (both states): the native MedicalDisclaimerBanner copy, verbatim. It is missing from day detail — see C7.
- **Sleep Need — KEEP:** title "Sleep Need"; subtitle "Your usual need, from your recent nights" (the required framing: a personal estimate from his own patterns); figures "Last night asleep" / "That night's need" / "Tonight's need"; "Recent shortfall: {x} across your last {n} recorded nights"; "This week's balance"; and the `sleep_need.dart` status descriptors "Above need" / "Near need" / "Below need" (±15-minute Near tolerance). Trend language only, no medical claims. One cold-state change — see C6.
- Out of scope, noted only: the pre-existing Sleep screen "Sleep Science" dialog and REM copy are native-parity text that predates R70 and were not part of this pass.

### Conditions

- **C1 (health data, mandatory) — the history store's account guard is built and unit-tested but never wired in production.** `HealthHistoryStore` implements the sibling contract (`bindToAccount` / `clearIfOwnerMismatch` / `warmFromDisk(currentEmail:)` / `clear()`), but no caller ever passes it an email: `bindToAccount` has no production caller, `warmFromDisk` is only ever called with no argument, and `persist()` therefore writes `ownerEmail: null` on every blob. The store is also absent from every lifecycle list its siblings are in — the pre-frame warm in `main.dart` (Home + QuickLog only), `_onLoginSuccess` / `_onRegisterSuccess` owner-mismatch enforcement, `_onSessionExpired`, and `AccountActions._clearDefaultCaches` (logout / account deletion). As shipped, a second account on the same device inherits the first account's entire all-time history and Daily Scores, and logout/account deletion leaves all of it on device — the exact failure the R19c/R29b/R35 pattern exists to prevent, now at all-time depth. **Fix (one fix pass, mirroring the siblings exactly):** add `HealthHistoryStore.instance.warmFromDisk(currentEmail: sessionEmail)` to the pre-frame warm; add `clearIfOwnerMismatch(email)` to `_onLoginSuccess` and `_onRegisterSuccess`; add `clear()` to `_onSessionExpired` and to `AccountActions._clearDefaultCaches`.
- **C2 (copy) — sleep chip 60–79 tier:** in `daily_score_vocabulary.dart` (`sleepChipForScore`), replace the label `'Normal'` with `'Fair'` (new chip: background `NotelColors.info`, foreground `NotelColors.background`). "Normal" at 60–79% of personal need met carries a normative-range implication this feature nowhere else makes, and it gave "Normal" a second, conflicting meaning on the same screen. After this change "Normal" means only "within ±2% of your own baseline."
- **C3 (copy/color) — resting-HR "Below" chip fill:** in `restingHrChipForDeviation`, the `'Below'` chip must not use the warning fill — below-baseline resting HR *raises* this component's score, so amber turns a descriptive direction word into a badness signal that contradicts the feature's own scoring. Replace with a direction-neutral chip identical in color to `'Above'`: label `'Below'`, background `NotelColors.info`, foreground `NotelColors.background`. Wording unchanged. (HRV "Below" keeps the warning fill — there the valence and the scoring agree.)
- **C4 (copy) — "How this score works" accuracy:** the baseline is the most recent 28 days *with data*, not the calendar 28 days. Replace the card body with exactly: "Each day is compared with your own recent baseline: the most recent 28 days with data before it. Sleep counts 40%, HRV 35%, and resting heart rate 25%, counting only the parts with at least 7 baseline days. HRV is measured as RMSSD, among the most-studied signals in physiology. A day is scored once and never changes." (Only the baseline clause changes; the RMSSD sentence is ruled KEEP as written — see evidence discipline above.)
- **C5 (copy) — chart heading:** in `daily_score_screen.dart`, replace `'Last 14 days'` with `'Last 14 scored days'` (the chart plots the last 14 *scored* days, which can span more than 14 calendar days; the current heading overstates the window).
- **C6 (copy) — Sleep Need cold state:** in `sleep_screen.dart`, replace "Still learning your pattern. Once a few more nights are recorded, your personal sleep need will show here." with exactly: "Still learning your pattern. Your personal sleep need will show here once at least 7 nights are recorded." (The threshold is 7 nights total; "a few more" understates it from a cold start and is inconsistent with the feature's own 7-day honesty elsewhere.)
- **C7 (copy) — day-detail disclaimer:** add the same disclaimer footer that ends the history screen to the end of the `DailyScoreDayScreen` list, exactly: "Tabs is not a medical device. It does not diagnose, treat, cure, or prevent any condition. AI insights are informational only. Consult a healthcare professional."
- **C8 (production gate, not a Lab gate; MF-4 ledger addition):** before production, the hosted privacy policy and Play Data Safety must describe (a) the all-time on-device historical health store in secure storage, including the Daily Score fields derived from it, (b) the CSV health-history import (device-local, fill-gaps, no transmission), and (c) Daily Score / Sleep Need as on-device derivations from the user's own Health Connect data. No hosted-page change is required for the founder's Lab build.

*Juno — R70 client pass, 2026-10-17. Juno sign-off with conditions C1–C7 (pre-delivery) + C8 (production) on file.*
