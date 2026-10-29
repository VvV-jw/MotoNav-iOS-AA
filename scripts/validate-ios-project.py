#!/usr/bin/env python3
"""Dependency-free static checks; does not claim to replace an Xcode build."""
from pathlib import Path
import json
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "ios/MotoNav.xcodeproj/project.pbxproj"


def parse_openstep(text):
    pattern = re.compile(r'\s+|//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+', re.S)
    tokens = []
    position = 0
    while position < len(text):
        match = pattern.match(text, position)
        assert match, f"Unrecognized PBX syntax at {position}"
        token = match.group()
        position = match.end()
        if token.isspace() or token.startswith(("//", "/*")):
            continue
        tokens.append(json.loads(token) if token.startswith('"') else token)
    at = 0

    def take(expected=None):
        nonlocal at
        assert at < len(tokens), "Unexpected end of PBX project"
        value = tokens[at]
        at += 1
        assert expected is None or value == expected, f"Expected {expected}, got {value}"
        return value

    def value():
        if tokens[at] == "{":
            take("{")
            result = {}
            while tokens[at] != "}":
                key = take()
                assert key not in result, f"Duplicate PBX dictionary key: {key}"
                take("=")
                result[key] = value()
                take(";")
            take("}")
            return result
        if tokens[at] == "(":
            take("(")
            result = []
            while tokens[at] != ")":
                result.append(value())
                if tokens[at] != ")":
                    take(",")
            take(")")
            return result
        return take()

    result = value()
    assert at == len(tokens), "Unparsed PBX trailing tokens"
    return result


def main():
    expected = (ROOT / "RELEASE_VERSION").read_text().strip()
    expected_build = (ROOT / "BUILD_NUMBER").read_text().strip()
    assert expected == "0.15.18" and expected_build == "18", "Unexpected isolated-port version"
    project = parse_openstep(PROJECT.read_text(encoding="utf-8"))
    objects = project["objects"]
    root = objects[project["rootObject"]]
    paths = {}

    def walk(identifier, parent, seen):
        assert identifier not in seen, "Cycle in PBX groups"
        obj = objects[identifier]
        source_tree = obj.get("sourceTree", "<group>")
        base = ROOT / "ios" if source_tree == "SOURCE_ROOT" else parent
        if source_tree not in ("<group>", "SOURCE_ROOT"):
            return
        path = base / obj.get("path", "")
        if obj["isa"] == "PBXGroup":
            for child in obj.get("children", []):
                walk(child, path, seen | {identifier})
        else:
            paths[identifier] = path.resolve()

    walk(root["mainGroup"], ROOT / "ios", set())
    compiled = {}
    target_count = 0
    for target_id in root["targets"]:
        target = objects[target_id]
        target_count += 1
        name = target["name"]
        assert name in ("MotoNav", "MotoNavShare"), f"Unexpected target: {name}"
        listed = []
        for phase_id in target["buildPhases"]:
            phase = objects[phase_id]
            if phase["isa"] != "PBXSourcesBuildPhase":
                continue
            for build_id in phase["files"]:
                reference = objects[build_id]["fileRef"]
                path = paths[reference]
                assert path.is_file(), f"Missing compiled source: {path}"
                listed.append(path)
        assert len(listed) == len(set(listed)), f"Duplicate Sources membership in {name}"
        on_disk = set((ROOT / "ios" / name).rglob("*.swift"))
        registered = {p for p in listed if p.suffix == ".swift"}
        assert registered == {p.resolve() for p in on_disk}, \
            f"Unregistered or stray Swift sources in {name}: {registered ^ {p.resolve() for p in on_disk}}"
        compiled[name] = len(registered)
        configurations = objects[target["buildConfigurationList"]]["buildConfigurations"]
        assert len(configurations) == 2, f"Expected Debug and Release for {name}"
        for config_id in configurations:
            settings = objects[config_id]["buildSettings"]
            assert settings["MARKETING_VERSION"] == expected, f"Marketing version mismatch in {name}"
            assert settings["CURRENT_PROJECT_VERSION"] == expected_build, f"Build number mismatch in {name}"
            assert settings.get("DEVELOPMENT_TEAM", "") == "", "Personal signing team is checked in"
            if name == "MotoNav":
                assert "-lz" in settings.get("OTHER_LDFLAGS", ""), "RasterTransport needs zlib linking"
        info = plistlib.loads((ROOT / "ios" / name / "Info.plist").read_bytes())
        assert info["CFBundleShortVersionString"] == "$(MARKETING_VERSION)"
        assert info["CFBundleVersion"] == "$(CURRENT_PROJECT_VERSION)"
    assert target_count == 2
    for source in ("GtaVectorCodec.swift", "MvtTile.swift", "GtaVectorMaps.swift",
                   "RasterTransport.swift", "MapStylePolicy.swift"):
        assert (ROOT / "ios/MotoNav" / source).is_file(), f"Missing new port source: {source}"
    for source in (ROOT / "ios/MotoNav").glob("*.swift"):
        text = source.read_text(encoding="utf-8")
        if "ObservableObject" in text or "@Published" in text:
            assert "import Combine" in text or "import SwiftUI" in text, \
                f"Observable state needs an explicit Combine/SwiftUI import: {source.name}"

    tests = (ROOT / "scripts/test-ios.sh").read_text(encoding="utf-8")
    swift_tests = list((ROOT / "ios/tests").rglob("main.swift"))
    for entry in swift_tests:
        relative = entry.relative_to(ROOT).as_posix()
        if entry.parent.name in ("gta-vector", "aa-raster", "quality-aa6", "preparation-recovery", "preparation-stress", "diagnostics-aa8", "ride-store-aa9", "journeys-aa10", "traffic-lights"):
            assert f"ios/tests/{entry.parent.name}/run.sh" in tests
            assert entry.with_name("run.sh").is_file()
        elif entry.parent.name == "parity-015":
            parser = (ROOT / "ios/tests/webmotor/check.py").read_text(encoding="utf-8")
            assert "tests/parity-015/main.swift" in parser and "ios/tests/webmotor/check.py" in tests
        else:
            assert relative in tests, f"Test suite omitted from CI: {relative}"
    assert "cruise-idle -Onone" in tests, "Legacy assert() checks must remain enabled"

    workflows = list((ROOT / ".github/workflows").glob("*.yml"))
    assert sorted(p.name for p in workflows) == ["ios-aa-pages.yml", "ios-aa.yml"], "Unexpected publishing workflow in isolated port"
    workflow = (ROOT / ".github/workflows/ios-aa.yml").read_text(encoding="utf-8")
    events = re.search(r"^on:\s*\n(.*?)(?=^\S)", workflow, re.M | re.S).group(1)
    assert events.strip() == """workflow_dispatch:
    inputs:
      capture_native_pages:
        description: 'Capture native UI tests and screenshots'
        type: boolean
        required: true
        default: true""", "Cloud build must be manual only; native captures default to enabled"
    assert workflow.count("if: ${{ inputs.capture_native_pages }}") == 4
    assert "contents: read" in workflow and "contents: write" not in workflow
    assert "runs-on: macos-15" in workflow and "persist-credentials: false" in workflow
    job_configuration = workflow.split("\n    steps:", 1)[0]
    assert "${{ runner." not in job_configuration, "Runner context is unavailable in job-level env"
    build_step = workflow.split("      - name: Build unsigned iPhone IPA\n", 1)[1].split("\n      - name:", 1)[0]
    assert "MOTONAV_DERIVED_DATA: ${{ runner.temp }}/MotoNav-aa-DerivedData" in build_step
    assert "pod _1.16.2_ install --deployment" in workflow
    assert "scripts/test-ios.sh" in workflow and "scripts/build-ios-ipa.sh" in workflow
    assert "upload-artifact@v4" in workflow
    assert ".build/tests/aa-raster/*.bin" in workflow and ".build/tests/gta-vector/*.bin" in workflow
    assert "include-hidden-files: true" in workflow, "Protocol samples live under the hidden .build directory"
    assert not any(s in workflow.lower() for s in ("gh release", "create-release", "firmware", "secrets."))
    lock = (ROOT / "ios/Podfile.lock").read_text(encoding="utf-8")
    assert "COCOAPODS: 1.16.2" in lock
    builder = (ROOT / "scripts/build-ios-ipa.sh").read_text(encoding="utf-8")
    assert "CODE_SIGNING_ALLOWED=NO" in builder and "CODE_SIGNING_REQUIRED=NO" in builder
    assert "DEVELOPMENT_TEAM=" in builder and "BUILD_NUMBER" in builder
    assert "verify_version \"$APP\"" in builder and '"$APP"/PlugIns/*.appex' in builder
    assert "embedded.mobileprovision" in builder and "_CodeSignature" in builder
    print(json.dumps({"staticValidation": "PASS", "version": expected, "build": expected_build,
                      "compiledSwiftSources": compiled, "swiftTestEntrypoints": len(swift_tests),
                      "workflow": "manual macos-15, read-only, unsigned IPA artifacts"}, ensure_ascii=False))


if __name__ == "__main__":
    main()
