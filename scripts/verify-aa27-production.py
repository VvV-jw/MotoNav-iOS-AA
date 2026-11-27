#!/usr/bin/env python3
"""Prove that the AA27 regression driver fix changes no compiled app input."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PACKAGE_COMMIT = "7a8aebff01b6aa033c224f2f940d10ed3f383d71"
ALLOWED_CHANGED_PATHS = {
    ".github/workflows/ios-aa.yml",
    "ios/tests/diagnostics-aa8/run.sh",
    "scripts/validate-ios-project.py",
    "scripts/verify-aa27-production.py",
}


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT)


def tree(commit):
    entries = {}
    for record in git("ls-tree", "-rz", "--full-tree", commit).split(b"\0"):
        if not record:
            continue
        metadata, raw_path = record.split(b"\t", 1)
        mode, kind, identity = metadata.decode("ascii").split()
        path = raw_path.decode("utf-8")
        if path not in ALLOWED_CHANGED_PATHS:
            assert kind == "blob", f"Unexpected non-file tracked input: {path}"
            entries[path] = (mode, identity)
    return entries


def canonical_sha(value):
    data = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    actual = git("rev-parse", "HEAD").decode().strip()
    assert not git("status", "--porcelain").strip(), "Verification requires a committed clean checkout"
    changed = git("diff", "--name-only", PACKAGE_COMMIT, actual).decode().splitlines()
    assert set(changed) == ALLOWED_CHANGED_PATHS, changed
    old_workflow = git("show", PACKAGE_COMMIT + ":.github/workflows/ios-aa.yml").decode().replace("\r\n", "\n")
    new_workflow = git("show", actual + ":.github/workflows/ios-aa.yml").decode().replace("\r\n", "\n")
    original_job = old_workflow.split("jobs:\n", 1)[1].rstrip()
    retained_job = new_workflow.split("jobs:\n", 1)[1].split("  swift-regressions:\n", 1)[0]
    retained_job = retained_job.replace("    if: ${{ !inputs.regression_only }}\n", "", 1).rstrip()
    assert retained_job == original_job, "The original dependency/build/UIKit job definition changed"
    before, after = tree(PACKAGE_COMMIT), tree(actual)
    assert before == after, "A tracked input outside the four explicit test infrastructure paths changed"
    files = []
    reader = subprocess.Popen(["git", "cat-file", "--batch"], cwd=ROOT,
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        for path, (mode, identity) in sorted(after.items()):
            reader.stdin.write((identity + "\n").encode("ascii"))
            reader.stdin.flush()
            header = reader.stdout.readline().decode("ascii").strip().split()
            assert len(header) == 3 and header[0] == identity and header[1] == "blob"
            size = int(header[2])
            data = reader.stdout.read(size)
            assert len(data) == size and reader.stdout.read(1) == b"\n"
            files.append({"path": path, "mode": mode, "bytes": size,
                          "sha256": hashlib.sha256(data).hexdigest()})
    finally:
        reader.stdin.close()
        reader.wait(timeout=20)
    assert reader.returncode == 0
    production = [item for item in files if
                  (item["path"].startswith("ios/") and not item["path"].startswith(("ios/tests/", "ios/previews/"))) or
                  item["path"] in {"BUILD_NUMBER", "RELEASE_VERSION", ".gitattributes", ".gitignore",
                                   "scripts/build-ios-ipa.sh",
                                   "scripts/test-text-images.sh"}]
    assert any(item["path"] == "ios/Podfile.lock" for item in production)
    assert any(item["path"] == "ios/MotoNav.xcodeproj/project.pbxproj" for item in production)
    report = {
        "passed": True, "packageSourceCommit": PACKAGE_COMMIT, "regressionSourceCommit": actual,
        "changedPaths": changed, "allowedChangedPaths": sorted(ALLOWED_CHANGED_PATHS),
        "originalBuildJobDefinitionUnchanged": True,
        "originalBuildJobSHA256": hashlib.sha256(original_job.encode("utf-8")).hexdigest(),
        "allOtherTrackedFilesByteIdentical": True, "unchangedTrackedFiles": files,
        "unchangedTrackedTreeSHA256": canonical_sha(files),
        "productionScope": "All tracked iOS app/share sources, resources, dependencies, workspace/project/scheme and configuration, excluding tests/previews; root version files, attributes, ignores, IPA builder and UIKit text test driver. The workflow adds only a separate regression job; the original build job steps are compared separately.",
        "productionFiles": production, "productionTreeSHA256": canonical_sha(production),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"passed": True, "unchangedTrackedFiles": len(files),
                      "productionFiles": len(production),
                      "productionTreeSHA256": report["productionTreeSHA256"],
                      "packageSourceCommit": PACKAGE_COMMIT, "regressionSourceCommit": actual}))


if __name__ == "__main__":
    main()
