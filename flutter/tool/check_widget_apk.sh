#!/usr/bin/env bash
# Round 52 — widget artifact gate.
#
# Fails (exit 1) if the built APK is not a widget superset:
#   1. the compiled AndroidManifest.xml declares the
#      VitalsWidgetProvider appwidget receiver;
#   2. the provider class name survives in the artifact (dex);
#   3. the home_widget bridge's SharedPreferences name
#      ("HomeWidgetPreferences") survives (dex);
#   4. the four widget value view IDs survive (resources/dex):
#      widget_heart_rate, widget_streak, widget_logs, widget_sleep.
#
# Items 2–4 double as the R8 tripwire: a toolchain change that
# renames/merges the manifest-facing classes or strips the widget
# resources fails HERE, at build time, instead of on the launcher
# (the R51 incident: a widgetless build deleted the bound
# component and Pixel Launcher fell back to its "Fix" placeholder).
#
# Usage: check_widget_apk.sh <path-to-apk>
# aapt2 is located via $AAPT2, PATH, $ANDROID_HOME/$ANDROID_SDK_ROOT,
# ~/workspace/.android-sdk, or $HOME/Android/Sdk.
set -u

APK="${1:-}"
if [ -z "$APK" ] || [ ! -f "$APK" ]; then
  echo "FAIL: APK not found: '$APK'" >&2
  exit 1
fi

find_aapt2() {
  if [ -n "${AAPT2:-}" ] && [ -x "$AAPT2" ]; then echo "$AAPT2"; return; fi
  if command -v aapt2 >/dev/null 2>&1; then command -v aapt2; return; fi
  local root bt
  for root in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
              "$HOME/workspace/.android-sdk" "$HOME/Android/Sdk" \
              "/opt/android-sdk"; do
    [ -n "$root" ] || continue
    for bt in "$root"/build-tools/*/aapt2; do
      [ -x "$bt" ] && { echo "$bt"; return; }
    done
  done
  echo ""
}

AAPT2_BIN="$(find_aapt2)"
if [ -z "$AAPT2_BIN" ]; then
  echo "FAIL: aapt2 not found (set AAPT2 or ANDROID_HOME)" >&2
  exit 1
fi

fail=0

# ── 1. Compiled manifest carries the receiver ────────────────────
MANIFEST_DUMP="$("$AAPT2_BIN" dump xmltree "$APK" --file AndroidManifest.xml 2>/dev/null)"
if ! printf '%s' "$MANIFEST_DUMP" | grep -q 'VitalsWidgetProvider'; then
  echo "FAIL: compiled manifest lacks the VitalsWidgetProvider receiver" >&2
  fail=1
else
  echo "OK: compiled manifest declares VitalsWidgetProvider receiver"
fi
if ! printf '%s' "$MANIFEST_DUMP" | grep -q 'android.appwidget.action.APPWIDGET_UPDATE'; then
  echo "FAIL: compiled manifest lacks the APPWIDGET_UPDATE intent-filter" >&2
  fail=1
else
  echo "OK: APPWIDGET_UPDATE intent-filter present"
fi

# ── 2–4. Dex/resources string survival (R8 tripwire) ─────────────
# Scan every entry of the APK (dex files, resources.arsc, binary
# XML) for the required strings.
if ! APK="$APK" python3 - <<'PYEOF'
import os, sys, zipfile

required = [
    b"com/notel/notel/playground/flutter/VitalsWidgetProvider",
    b"HomeWidgetPreferences",
    b"widget_heart_rate",
    b"widget_streak",
    b"widget_logs",
    b"widget_sleep",
]
found = {r: False for r in required}
with zipfile.ZipFile(os.environ["APK"]) as zf:
    for name in zf.namelist():
        if not (name.endswith(".dex") or name == "resources.arsc"
                or name.endswith(".xml")):
            continue
        data = zf.read(name)
        for r in required:
            if not found[r] and r in data:
                found[r] = True
missing = [r.decode() for r, ok in found.items() if not ok]
for r, ok in found.items():
    print(("OK: artifact contains " if ok else "MISSING: ") + r.decode())
sys.exit(1 if missing else 0)
PYEOF
then
  echo "FAIL: dex/resources check failed (see MISSING lines above)" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "WIDGET GATE: FAILED for $APK" >&2
  exit 1
fi
echo "WIDGET GATE: PASSED for $APK"
