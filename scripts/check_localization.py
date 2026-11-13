#!/usr/bin/env python3
"""Fails if a UI string extracted by the compiler has no zh-Hans translation.

    scripts/check_localization.py <derived-data-dir> [Debug|Release]

Reads the *.stringsdata files the Swift compiler writes for each target (SWIFT_EMIT_LOC_STRINGS)
and checks every key of the "Localizable" table against that target's String Catalog.
"""
import glob, json, os, sys

dd = sys.argv[1]
config = sys.argv[2] if len(sys.argv) > 2 else "Debug"
TARGETS = {  # target build dir → its String Catalog
    "Flowbeat": "Flowbeat/Localizable.xcstrings",
    "FlowbeatWidgets": "FlowbeatWidgets/Localizable.xcstrings",
}
fail = 0
for target, catalog_path in TARGETS.items():
    build = os.path.join(dd, "Build/Intermediates.noindex/Flowbeat.build", f"{config}-watchsimulator", f"{target}.build")
    files = glob.glob(os.path.join(build, "**", "*.stringsdata"), recursive=True)
    if not files:
        print(f"FAIL {target}: no .stringsdata under {build} (build the Flowbeat scheme first)")
        fail = 1
        continue
    keys = set()
    for f in files:
        for e in json.load(open(f)).get("tables", {}).get("Localizable", []):
            keys.add(e["key"])
    strings = json.load(open(catalog_path))["strings"]
    def ok(k):
        v = strings.get(k)
        if v is None:
            return False
        if v.get("shouldTranslate") is False:
            return True
        return "zh-Hans" in v.get("localizations", {})
    missing = sorted(k for k in keys if not ok(k))
    print(f"{target}: {len(keys)} strings, {len(missing)} without zh-Hans")
    for k in missing:
        print("   missing:", repr(k))
    fail |= bool(missing)
sys.exit(fail)
