#!/usr/bin/env bash
# Round 52 — widget artifact gate. Round 58 — hardened (see 5–6).
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
# They are raw STRING survival checks only — a string can survive
# in a dex string pool while the class itself is gone, which is
# exactly how a widgetless build once passed this gate. The real
# class-presence check is item 5.
#
# Round 58 additions (the black-bar incident: the values layout
# carried two RemoteViews inflation hazards that no check caught):
#   5. REAL dex class presence: dexdump's parsed class
#      descriptors must contain BOTH
#      com.notel.notel.playground.flutter.VitalsWidgetProvider
#      and the home_widget plugin class
#      es.antonborri.home_widget.HomeWidgetPlugin. Descriptors
#      come from the dex class_defs table, not string search.
#   6. Compiled widget-layout RemoteViews safety: every element
#      in the three compiled widget layouts (vitals_widget,
#      vitals_widget_fallback, vitals_widget_signed_out) must be
#      in RemoteViews' supported view set (a bare <View> divider
#      fails inflation atomically in the launcher), and no
#      drawable referenced from a widget layout may resolve to a
#      vector drawable (a compiled <vector> XML — unsafe for
#      RemoteViews; widget icons ship as multi-density PNGs).
#
# Usage: check_widget_apk.sh <path-to-apk>
# aapt2/dexdump are located via $AAPT2/$DEXDUMP, PATH,
# $ANDROID_HOME/$ANDROID_SDK_ROOT, ~/workspace/.android-sdk, or
# $HOME/Android/Sdk.
set -u

APK="${1:-}"
if [ -z "$APK" ] || [ ! -f "$APK" ]; then
  echo "FAIL: APK not found: '$APK'" >&2
  exit 1
fi

find_build_tool() {
  # $1 = env override value, $2 = tool name
  if [ -n "${1:-}" ] && [ -x "$1" ]; then echo "$1"; return; fi
  if command -v "$2" >/dev/null 2>&1; then command -v "$2"; return; fi
  local root bt
  for root in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
              "$HOME/workspace/.android-sdk" "$HOME/Android/Sdk" \
              "/opt/android-sdk"; do
    [ -n "$root" ] || continue
    for bt in "$root"/build-tools/*/"$2"; do
      [ -x "$bt" ] && { echo "$bt"; return; }
    done
  done
  echo ""
}

AAPT2_BIN="$(find_build_tool "${AAPT2:-}" aapt2)"
if [ -z "$AAPT2_BIN" ]; then
  echo "FAIL: aapt2 not found (set AAPT2 or ANDROID_HOME)" >&2
  exit 1
fi
DEXDUMP_BIN="$(find_build_tool "${DEXDUMP:-}" dexdump)"
if [ -z "$DEXDUMP_BIN" ]; then
  echo "FAIL: dexdump not found (set DEXDUMP or ANDROID_HOME) —" >&2
  echo "      the Round 58 dex class-presence check cannot run" >&2
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
# XML) for the required strings. NOTE: string survival only —
# the authoritative class-presence check is section 5 below.
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
  echo "FAIL: dex/resources string check failed (see MISSING lines above)" >&2
  fail=1
fi

# ── 5. Dex class presence (dexdump class descriptors) ────────────
# Parse the class_defs of every classes*.dex with dexdump and
# require the exact class descriptors. Unlike section 2, a class
# whose name merely survives as a string (constant pool, debug
# info, another class's reference) does NOT pass: the class must
# be DEFINED in the dex.
DEX_TMP="$(mktemp -d)"
trap 'rm -rf "$DEX_TMP"' EXIT
if ! APK="$APK" DEX_TMP="$DEX_TMP" python3 - <<'PYEOF'
import os, sys, zipfile
with zipfile.ZipFile(os.environ["APK"]) as zf:
    dexes = [n for n in zf.namelist()
             if "/" not in n and n.startswith("classes")
             and n.endswith(".dex")]
    if not dexes:
        print("FAIL: APK contains no classes*.dex", file=sys.stderr)
        sys.exit(1)
    for n in dexes:
        with open(os.path.join(os.environ["DEX_TMP"], n), "wb") as fh:
            fh.write(zf.read(n))
print("dex files: " + ", ".join(dexes))
PYEOF
then
  fail=1
else
  DESCRIPTORS="$DEX_TMP/descriptors.txt"
  : > "$DESCRIPTORS"
  for dex in "$DEX_TMP"/classes*.dex; do
    "$DEXDUMP_BIN" "$dex" 2>/dev/null \
      | grep 'Class descriptor' >> "$DESCRIPTORS" || true
  done
  for desc in \
    "'Lcom/notel/notel/playground/flutter/VitalsWidgetProvider;'" \
    "'Les/antonborri/home_widget/HomeWidgetPlugin;'"; do
    if grep -Fq "$desc" "$DESCRIPTORS"; then
      echo "OK: dex defines class $desc"
    else
      echo "FAIL: dex does NOT define class $desc" >&2
      fail=1
    fi
  done
fi

# ── 6. Compiled widget layouts: RemoteViews safety ──────────────
# Resolve the three widget layouts and every drawable they
# reference through the APK's own resource table (release builds
# obfuscate res/ paths, so nothing is assumed), then inspect the
# COMPILED binary XML with aapt2:
#   - every element must be in RemoteViews' supported view set;
#   - no referenced drawable may be a vector (compiled <vector>).
if ! AAPT2="$AAPT2_BIN" APK="$APK" python3 - <<'PYEOF'
import os, re, subprocess, sys

aapt2, apk = os.environ["AAPT2"], os.environ["APK"]

def dump(*args):
    return subprocess.run([aapt2, "dump", *args, apk],
                          capture_output=True, text=True).stdout

# Resource table: id -> (type, name); (type, name) -> [(path, restype)]
res_by_id, files_by_key = {}, {}
current = None
for line in dump("resources").splitlines():
    m = re.match(r"\s*resource (0x[0-9a-fA-F]+) (\w+)/(\S+)", line)
    if m:
        current = (m.group(2), m.group(3))
        res_by_id[m.group(1).lower()] = current
        files_by_key.setdefault(current, [])
        continue
    m = re.match(r"\s*\(.*?\) \(file\) (\S+) type=(\S+)", line)
    if m and current:
        files_by_key[current].append((m.group(1), m.group(2)))

# RemoteViews' supported view classes (android.widget, exact set
# from the RemoteViews docs). Anything else — bare View, custom
# or androidx classes — cannot be inflated by the launcher.
SUPPORTED = {
    "AdapterViewFlipper", "AnalogClock", "Button", "Chronometer",
    "FrameLayout", "GridLayout", "GridView", "ImageButton",
    "ImageView", "LinearLayout", "ListView", "ProgressBar",
    "RelativeLayout", "StackView", "TextView", "ViewFlipper",
    "ViewStub",
}
FRAMEWORK_PREFIXES = ("android.widget.", "android.view.")

def elements_of(path):
    out = dump("xmltree", "--file", path)
    return re.findall(r"^\s*E:\s+(\S+)\s+\(line=", out, re.M)

def refs_of(path):
    out = dump("xmltree", "--file", path)
    return {r.lower() for r in re.findall(r"=@(0x[0-9a-fA-F]+)", out)}

fail = 0
LAYOUTS = ["vitals_widget", "vitals_widget_fallback",
           "vitals_widget_signed_out"]
for name in LAYOUTS:
    files = files_by_key.get(("layout", name))
    if not files:
        print(f"FAIL: widget layout missing from APK: layout/{name}")
        fail = 1
        continue
    path = files[0][0]
    bad = []
    for el in elements_of(path):
        simple = el.rsplit(".", 1)[-1]
        if simple not in SUPPORTED or (
                "." in el and not el.startswith(FRAMEWORK_PREFIXES)):
            bad.append(el)
    if bad:
        print(f"FAIL: layout/{name} uses non-RemoteViews views: "
              + ", ".join(sorted(set(bad))))
        fail = 1
    else:
        print(f"OK: layout/{name} elements all RemoteViews-supported")
    # Vector check on every drawable this layout references.
    vec_bad = 0
    for rid in sorted(refs_of(path)):
        key = res_by_id.get(rid)
        if not key or key[0] not in ("drawable", "mipmap"):
            continue
        for dpath, _t in files_by_key.get(key, []):
            if not dpath.endswith(".xml"):
                continue  # raster (png/webp/...) — safe
            els = elements_of(dpath)
            if any(e.rsplit(".", 1)[-1] in
                   ("vector", "animated-vector") for e in els):
                print(f"FAIL: layout/{name} references vector "
                      f"drawable {key[0]}/{key[1]} ({dpath})")
                vec_bad = 1
    if vec_bad:
        fail = 1
    else:
        print(f"OK: layout/{name} drawable references vector-free")

sys.exit(1 if fail else 0)
PYEOF
then
  echo "FAIL: compiled widget-layout RemoteViews check failed" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "WIDGET GATE: FAILED for $APK" >&2
  exit 1
fi
echo "WIDGET GATE: PASSED for $APK"
