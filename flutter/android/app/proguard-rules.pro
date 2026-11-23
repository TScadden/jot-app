# Round 52 — widget R8 keep rules (insurance).
#
# The manifest names the vitals widget receiver by class, and the
# home_widget bridge resolves its provider/plugin classes by name
# at runtime. R8 currently keeps them (verified in the shipped
# R50/R52 dex), but a future toolchain change must not be able to
# silently rename/merge a manifest-facing class away — a renamed
# receiver is exactly the R51 regression class (launcher falls back
# to its restore/"Fix" placeholder when the bound component
# disappears). Keep these names verbatim; Lab-appropriate and
# deliberately minimal.
-keep class com.notel.notel.playground.flutter.VitalsWidgetProvider { *; }
# Size-fix package (Nov 19, 2026): the streak provider shipped
# Nov 18 without a keep line here; it is manifest-facing exactly
# like the vitals provider, and its onAppWidgetOptionsChanged
# override (the size-bucket re-render) must survive R8 verbatim.
-keep class com.notel.notel.playground.flutter.StreakWidgetProvider { *; }
-keep class es.antonborri.home_widget.HomeWidgetProvider { *; }
-keep class es.antonborri.home_widget.HomeWidgetPlugin { *; }
# Med Scan package (Nov 23, 2026): google_mlkit_text_recognition declares
# the non-Latin script artifacts (chinese/devanagari/japanese/korean) as
# compileOnly — the plugin references their options classes but they are
# not bundled, and the app uses the Latin recognizer only. Without these
# rules R8 fails the release build with missing-class errors.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
