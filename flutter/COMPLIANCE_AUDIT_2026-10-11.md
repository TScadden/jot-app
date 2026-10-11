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
