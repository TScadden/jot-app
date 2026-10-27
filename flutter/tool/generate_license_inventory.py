#!/usr/bin/env python3
"""Generate the per-release open-source license inventory (F-11).

Reads flutter/pubspec.lock (direct + transitive, hosted + path + SDK),
looks up each hosted package's LICENSE file in the local pub cache,
classifies it by its leading text, and writes a Markdown inventory.

Regenerate each release (see OSS_LICENSES.md):
    flutter pub get
    python3 tool/generate_license_inventory.py \
        --output <dated-inventory-file>.md

The output is a release artifact: archive it with the AAB for that
release. It is NOT checked in as a living file, because it must match
the exact pubspec.lock that produced the shipped binary.
"""
import argparse
import os
import re
import sys
from datetime import date
from pathlib import Path


def parse_lock(lock_path: Path):
    packages = []
    current = None
    for line in lock_path.read_text().splitlines():
        m = re.match(r"^  ([A-Za-z0-9_]+):\s*$", line)
        if m:
            current = {"name": m.group(1)}
            packages.append(current)
            continue
        if current is None:
            continue
        m = re.match(r'^\s+dependency:\s+"?([^"\n]+)"?\s*$', line)
        if m:
            current["dependency"] = m.group(1).strip()
        m = re.match(r'^\s+source:\s+(\S+)\s*$', line)
        if m:
            current["source"] = m.group(1)
        m = re.match(r'^\s+version:\s+"?([^"\n]+)"?\s*$', line)
        if m:
            current["version"] = m.group(1)
    return packages


def classify(text: str) -> str:
    head = text[:4000]
    if "Apache License" in head and "Version 2.0" in head:
        return "Apache-2.0"
    if "MIT License" in head or "Permission is hereby granted, free of charge" in head:
        return "MIT"
    if "Redistribution and use in source and binary forms" in head:
        if head.count("Redistribution and use") >= 1 and "Neither the name" in head:
            return "BSD-3-Clause"
        return "BSD-2-Clause/BSD-3-Clause (see LICENSE)"
    if "SIL OPEN FONT LICENSE" in head or "Open Font License" in head:
        return "OFL-1.1"
    if "GNU GENERAL PUBLIC LICENSE" in head:
        return "GPL (see LICENSE)"
    if "Mozilla Public License" in head:
        return "MPL-2.0"
    return "See LICENSE file"


def find_license(pub_cache: Path, name: str, version: str):
    pkg_dir = pub_cache / "hosted" / "pub.dev" / f"{name}-{version}"
    if not pkg_dir.is_dir():
        return None, None
    for candidate in sorted(pkg_dir.iterdir()):
        if candidate.name.upper().startswith("LICENSE"):
            try:
                return candidate.name, candidate.read_text(errors="replace")
            except OSError:
                return candidate.name, None
    return None, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lock", default=str(Path(__file__).resolve().parent.parent / "pubspec.lock"))
    ap.add_argument("--output", required=True)
    ap.add_argument("--release", default="")
    args = ap.parse_args()

    lock_path = Path(args.lock)
    packages = parse_lock(lock_path)
    pub_cache = Path(os.environ.get("PUB_CACHE", Path.home() / ".pub-cache"))

    rows = []
    missing = []
    for pkg in packages:
        name, version = pkg["name"], pkg.get("version", "?")
        dep = pkg.get("dependency", "?")
        source = pkg.get("source", "?")
        lic_name, lic_text = (None, None)
        if source == "hosted":
            lic_name, lic_text = find_license(pub_cache, name, version)
        if source in ("sdk",):
            lic = "BSD-3-Clause (Flutter/Dart SDK)"
        elif source == "path":
            lic = "First-party / local plugin (this repository)"
        elif lic_text:
            lic = classify(lic_text)
        else:
            lic = "NOT FOUND in pub cache"
            missing.append(f"{name} {version}")
        rows.append((name, version, dep, source, lic, lic_name or ""))

    out = []
    out.append("# Tabs — Open-Source License Inventory")
    out.append("")
    out.append(f"Generated: {date.today().isoformat()}")
    if args.release:
        out.append(f"Release: {args.release}")
    out.append("Base: release/vc100105 lineage, flutter/pubspec.lock as resolved at generation time.")
    out.append("")
    out.append("This inventory covers every package in pubspec.lock: direct, "
               "transitive, dev, SDK, and local path packages. License "
               "classification is from each package's LICENSE file in the "
               "pub cache at generation time. The in-app surface "
               "(Settings → Open Source Licenses, showLicensePage) renders "
               "the full license texts from Flutter's LicenseRegistry for "
               "the packages actually bundled in the shipped binary.")
    out.append("")
    out.append("| Package | Version | Dependency | Source | License | License file |")
    out.append("|---|---|---|---|---|---|")
    for r in rows:
        out.append(f"| {r[0]} | {r[1]} | {r[2]} | {r[3]} | {r[4]} | {r[5]} |")
    out.append("")
    out.append(f"Total packages: {len(rows)}")
    if missing:
        out.append("")
        out.append("License files not found in the local pub cache "
                   "(run `flutter pub get` and regenerate):")
        for m in missing:
            out.append(f"- {m}")
    out.append("")
    Path(args.output).write_text("\n".join(out))
    print(f"Wrote {args.output} with {len(rows)} packages; missing: {len(missing)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
