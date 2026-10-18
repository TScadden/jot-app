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
-keep class es.antonborri.home_widget.HomeWidgetProvider { *; }
-keep class es.antonborri.home_widget.HomeWidgetPlugin { *; }
