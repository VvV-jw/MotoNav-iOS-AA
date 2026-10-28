#!/usr/bin/env python3
"""Compile the real UI/Bridge intent methods with disposable service adapters."""
from pathlib import Path
import hashlib
import json
import sys

ROOT = Path(__file__).resolve().parents[3]
OUTPUT = Path(sys.argv[1])
OUTPUT.mkdir(parents=True, exist_ok=True)


def extract(relative, signature):
    source = (ROOT / relative).read_text(encoding="utf-8")
    start = source.index(signature)
    brace = source.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    actual = source[start:end]
    proofs.append({"source": relative, "signature": signature,
                   "sha256": hashlib.sha256(actual.encode()).hexdigest()})
    # Only visibility changes: the method body is production code, not a replica.
    return actual.removeprefix("private ")


proofs = []
saved = extract("ios/MotoNav/ContentView.swift", "private func useSavedJourney(_ journey: SavedJourney)")
restore = extract("ios/MotoNav/ContentView.swift", "private func restoreRoute(_ checkpoint: NavigationRecoveryCheckpoint)")
vehicle = extract("ios/MotoNav/NaviBridge.swift", "func applyVehicleAndReplan() -> Bool")
generated = "import Foundation\nextension NativeHomeIntentHarness {\n" + saved + "\n" + restore + "\n}\n"
generated += "extension NativeVehicleIntentHarness {\n" + vehicle + "\n}\n"
(OUTPUT / "ProductionNativeIntent.swift").write_text(generated, encoding="utf-8")
(OUTPUT / "production-intent-extraction.json").write_text(json.dumps(proofs, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print("Extracted actual ContentView saved/recovery and NaviBridge vehicle actions for replay.")
