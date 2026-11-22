#!/usr/bin/env python3
"""Generate FlowbeatDevTest.xcodeproj for real-device testing with a FREE (personal) Apple team.

    python3 scripts/make_devtest_project.py && xcodegen generate --spec project.devtest.yml

Why a separate project: a personal team that signs `com.xungirl.flowbeat*` registers those App IDs
under itself, and the paid team may then get "bundle identifier is not available" when it tries to
use them for the App Store. So the test build uses `com.xungirl.flowbeat.devtest*` instead, and drops
what a free team can't sign: iCloud/CloudKit, push, and App Groups. The app copes with all three
missing (local-only database; the widget snapshot falls back when the group container is nil).

Signing team: put your personal Team ID in Config/Signing.local.xcconfig (gitignored).
Outputs (both ignored by git via .git/info/exclude): project.devtest.yml, FlowbeatDevTest.xcodeproj.
Entitlement files go to build/devtest/ so the real ones in the repo are never overwritten.
"""
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = open(os.path.join(ROOT, "project.yml"), encoding="utf-8").read()

s = re.sub(r"^name: .*$", "name: FlowbeatDevTest", src, count=1, flags=re.M)
# every bundle id (iPhone app, watch app, widget) and the companion key that points at the iPhone app
s = re.sub(r"\bcom\.xungirl\.flowbeat\b(?!\.devtest)", "com.xungirl.flowbeat.devtest", s)
# keep the real entitlement files untouched
for name in ["Flowbeat/Flowbeat.entitlements", "FlowbeatWidgets/FlowbeatWidgets.entitlements",
             "FlowbeatPhone/FlowbeatPhone.entitlements"]:
    s = s.replace(f"path: {name}", f"path: build/devtest/{os.path.basename(name)}")
# capabilities a free team can't sign
s = re.sub(r"\n\s*com\.apple\.security\.application-groups: \[[^\]]*\]", "", s)
s = re.sub(r"\n\s*com\.apple\.developer\.icloud-container-identifiers: \[[^\]]*\]", "", s)
s = re.sub(r"\n\s*com\.apple\.developer\.icloud-services: \[[^\]]*\]", "", s)
s = re.sub(r"\n\s*aps-environment: \w+", "", s)
s = re.sub(r"(FLOWBEAT_CLOUDKIT_CONTAINER:) \S+", r'\1 ""', s)

for needle in ["application-groups", "icloud-", "aps-environment"]:
    assert needle not in s.split("schemes:")[0].replace("# ", "#"), f"{needle} still present"

os.makedirs(os.path.join(ROOT, "build/devtest"), exist_ok=True)
out = os.path.join(ROOT, "project.devtest.yml")
open(out, "w", encoding="utf-8").write(s)
print("wrote", os.path.relpath(out, ROOT))
