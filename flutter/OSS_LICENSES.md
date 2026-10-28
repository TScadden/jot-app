# Open-source licenses (F-11)

## In-app surface

Settings → footer → **Open Source Licenses** opens Flutter's
`showLicensePage` (applicationName "Tabs", version "1.0"), which
renders every license registered in `LicenseRegistry` by the
bundled packages. This satisfies the in-app notice duty from the
legal-exposure register Q82. Widget coverage:
`test/oss_licenses_test.dart` proves the entry opens the page and
lists registry contents.

## Per-release inventory — how to regenerate

Run once per release, against the exact `pubspec.lock` that builds
the shipped AAB, and archive the output with that release's ship
notes (dated filename, under the launch goal's `files/` folder):

```sh
cd flutter
flutter pub get
python3 tool/generate_license_inventory.py \
  --release "VC <versionCode> / <date>" \
  --output ~/workspace/goals/launch-tabs-on-the-play-store/files/license-inventory-YYYY-MM-DD-vcNNNNN.md
```

The script parses `pubspec.lock` (direct + transitive + dev + SDK
+ local path packages), reads each hosted package's `LICENSE`
file from the local pub cache, and classifies it (MIT / BSD /
Apache-2.0 / OFL-1.1 / other). If any license file is reported
missing, run `flutter pub get` on a machine with a warm cache and
regenerate — do not ship an inventory with missing entries.

First inventory generated under this note: see the launch goal's
`files/` folder for the 2026-10-27 inventory.
