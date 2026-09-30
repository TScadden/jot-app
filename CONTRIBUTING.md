# Contributing to Tabs (jot-app)

How the Tabs build team ships code. Short on purpose.

## Branches

- `main` is the only release branch. **It is protected: no direct pushes,
  ever.** Every change lands through a pull request.
- `playground` is the long-lived experimental branch ("Tabs Lab"). Bold
  UI/UX and feature experiments go here so they never touch `main`. It
  builds as a *separate* installable app: applicationId
  `com.notel.notel.playground`, display name "Tabs Lab", tinted launcher
  icon, separate app data. Revertable by design.
- Feature work happens on short-lived branches off `main` (e.g.
  `mason/med-reminder-fix`). No gitflow, no `develop` branch.

## Pull requests

1. Open a PR from your feature branch against `main`. Keep it focused.
2. CI (`Play internal release` workflow) must be **green** before merge.
   It compiles, verifies the signed release AAB against the registered
   upload key, and archives the signed AAB + debug APK per run.
3. Review happens in the PR, in this order:
   - Mason codes the change.
   - Mira reviews anything visual (design lead pass).
   - Tess verifies it actually works (functional QA).
   - Vera signs off on the diff (security; mandatory for anything touching
     the manifest, permissions, or signing-adjacent config).
   - Juno signs off when the change touches health data, health claims,
     AI insights, privacy/terms, medical disclaimers, or store health
     declarations. Pure UI polish and non-user-facing bug fixes skip Juno.
4. Only Mason merges (squash or rebase; keep history readable).

Direct pushes to `main` are blocked by branch protection. The release
keystore and `PLAY_UPLOADS_LIVE` gating are never touched in PRs.

## What CI does and does not do

- Every push to `main` and every PR builds, verifies, and archives. **Pushes
  never upload to Play.** Play uploads happen only via a manual workflow
  dispatch, only on `main`, only when the founder has armed
  `PLAY_UPLOADS_LIVE`, and always to the internal track as a draft.
- Pushes to `playground` build the Tabs Lab debug APK only. No signed AAB,
  no Play upload path exists for that branch.

## Builds for the founder's phone

Debug APKs are delivered to the founder's phone only when he asks, over
Tailscale into `/DCIM/Tabs App debug files/`, deleting older APKs so only
the latest remains. This applies to Tabs Lab builds too. Never send an
APK unprompted.

## App identity

The customer-facing name is **Tabs**, never Jot or Notel. The Lab build is
called **Tabs Lab**. User-facing copy contains no dashes (em, en, or hyphen):
rewrite the sentence instead.
