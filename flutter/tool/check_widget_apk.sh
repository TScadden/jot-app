#!/usr/bin/env bash
# Round 52 — widget artifact gate. Round 56 additions marked [R56].
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
# [R56] 0. Source-side RemoteViews-safety check (runs BEFORE the
#   artifact checks when a res tree is found, and standalone via
#   --source-only): every layout referenced from a widget info XML
#   (res/xml/*appwidget-provider*: initialLayout + previewLayout,
#   plus any <include>d layouts, transitively) must contain
#     - NO bare <View> element: android.view.View is NOT in
#       RemoteViews' supported view set, and a layout containing
#       one can fail inflation atomically in the LAUNCHER process
#       (the provider's try/catch cannot catch it), leaving only
#       the widget background visible — the R50–R55 black bar.
#     - NO reference to a vector drawable: any @drawable/* the
#       layout resolves to must not be a <vector> / carry
#       android:pathData. Widget icons ship as PNG rasters.
#   XML comments are stripped before scanning, so documenting the
#   rule inside a layout never false-positives.
#
# [R56] 5. Dex DEFINED-CLASS check: the dex must define BOTH
#   com.notel.notel.playground.flutter.VitalsWidgetProvider AND
#   es.antonborri.home_widget.HomeWidgetPlugin as actual classes.
#   Checks 2–4 only grep class-name STRINGS anywhere in the APK —
#   R50 passed them while its dex defined no HomeWidgetPlugin at
#   all (the name survived as a stray string). This check uses
#   `apkanalyzer dex packages --defined-only` when available and
#   falls back to `dexdump` Class-descriptor lines, both of which
#   list class DEFINITIONS, never stray strings.
#
# Usage:
#   check_widget_apk.sh <path-to-apk> [--res-dir <res-dir>]
#   check_widget_apk.sh --source-only [<res-dir>]
# With an APK, the source check runs automatically when the res
# tree is found (script-relative ../android/app/src/main/res, or
# --res-dir); --skip-source disables it explicitly.
# aapt2 is located via $AAPT2, PATH, $ANDROID_HOME/$ANDROID_SDK_ROOT,
# ~/workspace/.android-sdk, or $HOME/Android/Sdk. apkanalyzer and
# dexdump are located the same way ($APKANALYZER / $DEXDUMP, PATH,
# SDK cmdline-tools / build-tools). If `java` is not on PATH,
# $JAVA_HOME or a JDK under ~/workspace/.jdk is used for apkanalyzer.
set -u

# ── Argument parsing ─────────────────────────────────────────────
SOURCE_ONLY=0
SKIP_SOURCE=0
APK=""
RES_DIR_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --source-only) SOURCE_ONLY=1; shift ;;
    --skip-source) SKIP_SOURCE=1; shift ;;
    --res-dir) RES_DIR_ARG="${2:-}"; shift 2 ;;
    *) if [ -z "$APK" ]; then APK="$1"; else RES_DIR_ARG="$1"; fi; shift ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_RES_DIR="$SCRIPT_DIR/../android/app/src/main/res"

resolve_res_dir() {
  if [ -n "$RES_DIR_ARG" ]; then echo "$RES_DIR_ARG"; return; fi
  if [ "$SOURCE_ONLY" -eq 1 ] && [ -n "$APK" ]; then echo "$APK"; return; fi
  if [ -d "$DEFAULT_RES_DIR" ]; then echo "$DEFAULT_RES_DIR"; return; fi
  echo ""
}
RES_DIR="$(resolve_res_dir)"
# In --source-only mode the positional arg was the res dir.
if [ "$SOURCE_ONLY" -eq 1 ]; then APK=""; fi

fail=0

# ── [R56] 0. Source-side RemoteViews-safety check ───────────────
run_source_check() {
  local res="$1"
  if [ -z "$res" ] || [ ! -d "$res" ]; then
    echo "FAIL: source check: res dir not found: '$res'" >&2
    return 1
  fi
  RES_DIR="$res" python3 - <<'PYEOF'
import os, re, sys
from pathlib import Path

res = Path(os.environ["RES_DIR"])
errors = []

def strip_comments(text):
    return re.sub(r"<!--.*?-->", "", text, flags=re.S)

# Layouts referenced from any widget info XML (appwidget-provider).
info_files = sorted((res / "xml").glob("*.xml")) if (res / "xml").is_dir() else []
layout_names = []
for info in info_files:
    text = strip_comments(info.read_text(errors="replace"))
    if "<appwidget-provider" not in text:
        continue
    for attr in ("initialLayout", "previewLayout"):
        for m in re.finditer(attr + r'\s*=\s*"@layout/([A-Za-z0-9_]+)"', text):
            if m.group(1) not in layout_names:
                layout_names.append(m.group(1))
if not layout_names:
    print("FAIL: source check: no appwidget-provider layout references "
          f"found under {res}/xml")
    sys.exit(1)

def resolve_drawable(name):
    """Return the Path of a drawable resource (any density dir), or None."""
    for cand in sorted(res.glob(f"drawable*/{name}.*")):
        return cand
    return None

seen = []
queue = list(layout_names)
while queue:
    name = queue.pop(0)
    if name in seen:
        continue
    seen.append(name)
    path = res / "layout" / f"{name}.xml"
    if not path.is_file():
        errors.append(f"layout @{name} referenced by widget info XML is missing: {path}")
        continue
    text = strip_comments(path.read_text(errors="replace"))
    # (a) bare <View> element (not <ViewGroup>/<ViewFlipper>/...:
    #     the tag name must be exactly "View").
    if re.search(r"<View(?=[\s/>])", text):
        errors.append(f"{path}: contains a bare <View> element "
                      "(not RemoteViews-supported; fails launcher inflation)")
    else:
        print(f"OK: source: {name}.xml has no bare <View> element")
    # <include>d layouts are widget layouts too.
    for m in re.finditer(r'<include[^>]*layout\s*=\s*"@layout/([A-Za-z0-9_]+)"', text):
        if m.group(1) not in seen and m.group(1) not in queue:
            queue.append(m.group(1))
    # (b) no vector drawables reachable from this layout.
    vec_refs = []
    for m in re.finditer(r"@drawable/([A-Za-z0-9_]+)", text):
        dname = m.group(1)
        dpath = resolve_drawable(dname)
        if dpath is None:
            errors.append(f"{path}: @drawable/{dname} does not resolve under {res}/drawable*")
            continue
        if dpath.suffix == ".xml":
            dtext = strip_comments(dpath.read_text(errors="replace"))
            if "<vector" in dtext or "android:pathData" in dtext:
                vec_refs.append(dname)
    if vec_refs:
        errors.append(f"{path}: references vector drawable(s): "
                      + ", ".join(sorted(set(vec_refs)))
                      + " (widget layouts must use raster drawables)")
    else:
        print(f"OK: source: {name}.xml references no vector drawable")

for e in errors:
    print("FAIL: source: " + e)
sys.exit(1 if errors else 0)
PYEOF
}

if [ "$SOURCE_ONLY" -eq 1 ]; then
  if run_source_check "$RES_DIR"; then
    echo "WIDGET SOURCE GATE: PASSED for $RES_DIR"
    exit 0
  fi
  echo "WIDGET SOURCE GATE: FAILED for $RES_DIR" >&2
  exit 1
fi

if [ -z "$APK" ] || [ ! -f "$APK" ]; then
  echo "FAIL: APK not found: '$APK'" >&2
  exit 1
fi

if [ "$SKIP_SOURCE" -eq 0 ]; then
  if [ -n "$RES_DIR" ] && [ -d "$RES_DIR" ]; then
    if ! run_source_check "$RES_DIR"; then
      echo "FAIL: source-side RemoteViews-safety check failed" >&2
      fail=1
    fi
  else
    echo "WARN: no res dir found; source-side check skipped (use --res-dir)" >&2
  fi
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

# ── [R56] 5. Dex DEFINED-CLASS check ─────────────────────────────
# Both classes must be DEFINED in the dex, not merely named by a
# stray string somewhere in the artifact (the R50 false pass).
find_sdk_tool() { # $1=env override, $2=tool name, $3..=glob patterns
  local override="$1" tool="$2"; shift 2
  if [ -n "$override" ] && [ -x "$override" ]; then echo "$override"; return; fi
  if command -v "$tool" >/dev/null 2>&1; then command -v "$tool"; return; fi
  local root pat
  for root in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
              "$HOME/workspace/.android-sdk" "$HOME/Android/Sdk" \
              "/opt/android-sdk"; do
    [ -n "$root" ] || continue
    for pat in "$@"; do
      for f in "$root"/$pat; do
        [ -x "$f" ] && { echo "$f"; return; }
      done
    done
  done
  echo ""
}

ensure_java() {
  if command -v java >/dev/null 2>&1; then return 0; fi
  local jh
  for jh in "${JAVA_HOME:-}" "$HOME"/workspace/.jdk/*/ "$HOME"/.jdk/*/ \
            /usr/lib/jvm/*/; do
    if [ -n "$jh" ] && [ -x "${jh}bin/java" ]; then
      export JAVA_HOME="${jh%/}"
      export PATH="$JAVA_HOME/bin:$PATH"
      return 0
    fi
  done
  return 1
}

DEX_CLASSES_OK=0
APKANALYZER_BIN="$(find_sdk_tool "${APKANALYZER:-}" apkanalyzer \
  "cmdline-tools/latest/bin/apkanalyzer" "cmdline-tools/*/bin/apkanalyzer" \
  "tools/bin/apkanalyzer")"
if [ -n "$APKANALYZER_BIN" ] && ensure_java; then
  DEX_PKGS="$("$APKANALYZER_BIN" dex packages --defined-only "$APK" 2>/dev/null)"
  if [ -n "$DEX_PKGS" ]; then
    DEX_CLASSES_OK=1
    for cls in \
      "com.notel.notel.playground.flutter.VitalsWidgetProvider" \
      "es.antonborri.home_widget.HomeWidgetPlugin"; do
      if printf '%s\n' "$DEX_PKGS" | awk -v c="$cls" '$1=="C" && $NF==c {found=1} END {exit !found}'; then
        echo "OK: dex defines class $cls (apkanalyzer --defined-only)"
      else
        echo "FAIL: dex does not define class $cls (apkanalyzer --defined-only)" >&2
        fail=1
      fi
    done
  fi
fi
if [ "$DEX_CLASSES_OK" -eq 0 ]; then
  DEXDUMP_BIN="$(find_sdk_tool "${DEXDUMP:-}" dexdump \
    "build-tools/*/dexdump")"
  if [ -n "$DEXDUMP_BIN" ]; then
    DEX_TMP="$(mktemp -d)"
    APK="$APK" DEX_TMP="$DEX_TMP" python3 - <<'PYEOF'
import os, zipfile
with zipfile.ZipFile(os.environ["APK"]) as zf:
    for name in zf.namelist():
        if name.endswith(".dex"):
            zf.extract(name, os.environ["DEX_TMP"])
PYEOF
    DESCRIPTORS=""
    for dex in "$DEX_TMP"/*.dex; do
      [ -f "$dex" ] || continue
      DESCRIPTORS="$DESCRIPTORS
$("$DEXDUMP_BIN" -f "$dex" 2>/dev/null | grep 'Class descriptor')"
    done
    rm -rf "$DEX_TMP"
    if [ -n "$DESCRIPTORS" ]; then
      DEX_CLASSES_OK=1
      for desc in \
        "Lcom/notel/notel/playground/flutter/VitalsWidgetProvider;" \
        "Les/antonborri/home_widget/HomeWidgetPlugin;"; do
        if printf '%s' "$DESCRIPTORS" | grep -qF "'$desc'"; then
          echo "OK: dex defines class $desc (dexdump Class descriptor)"
        else
          echo "FAIL: dex does not define class $desc (dexdump Class descriptor)" >&2
          fail=1
        fi
      done
    fi
  fi
fi
if [ "$DEX_CLASSES_OK" -eq 0 ]; then
  echo "FAIL: dex defined-class check could not run (no apkanalyzer or dexdump found)" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "WIDGET GATE: FAILED for $APK" >&2
  exit 1
fi
echo "WIDGET GATE: PASSED for $APK"
