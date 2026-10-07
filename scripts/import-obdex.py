#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml"]
# ///
"""Generate the bundled generic trouble-code catalog from an OBDex checkout."""

import json
import subprocess
import sys
from pathlib import Path

import yaml

COMMIT = "bc58b0eb7273226a1aabae98e956b70b8362bda1"
REPOSITORY = "https://github.com/foerbsnavi/OBDex"
OUTPUT = Path(__file__).resolve().parent.parent / "Sources/SpiaKit/Catalog/dtc-generic.json"
FILES = ("B0", "C0", "P0", "P2", "P3", "U0", "U3")
LIKELIHOOD = {"high": 0, "medium": 1, "low": 2}


def text(value: object, field: str, code: str) -> str:
    if not isinstance(value, dict) or not isinstance(value.get("en"), str) or not value["en"].strip():
        raise SystemExit(f"{code}: malformed {field}.en")
    return value["en"]


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: uv run scripts/import-obdex.py <OBDex checkout>")
    checkout = Path(sys.argv[1]).resolve()
    actual = subprocess.run(
        ["git", "-C", str(checkout), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    if actual != COMMIT:
        raise SystemExit(f"expected OBDex commit {COMMIT}, got {actual}")

    entries = []
    for family in FILES:
        path = checkout / "data" / "generic" / f"{family}xxx_enriched.yaml"
        if not path.is_file():
            raise SystemExit(f"missing {path}")
        values = yaml.safe_load(path.read_text())
        if not isinstance(values, list):
            raise SystemExit(f"{path}: expected a list")
        for item in values:
            if not isinstance(item, dict) or not isinstance(item.get("code"), str):
                raise SystemExit(f"{path}: malformed entry")
            code = item["code"]
            if not code or not isinstance(item.get("title"), dict) or not isinstance(item.get("description"), dict):
                raise SystemExit(f"{code}: malformed entry")
            causes = item.get("common_causes")
            if not isinstance(causes, list):
                raise SystemExit(f"{code}: malformed common_causes")
            ordered = sorted(enumerate(causes), key=lambda pair: (LIKELIHOOD.get(pair[1].get("likelihood"), 99), pair[0]))
            labels = []
            for _, cause in ordered[:3]:
                if not isinstance(cause, dict) or cause.get("likelihood") not in LIKELIHOOD:
                    raise SystemExit(f"{code}: malformed cause")
                labels.append(text(cause.get("label"), "cause label", code))
            entries.append({
                "code": code,
                "title": text(item["title"], "title", code),
                "description": text(item["description"], "description", code),
                "causes": labels,
            })
    entries.sort(key=lambda item: item["code"])
    if len({item["code"] for item in entries}) != len(entries):
        raise SystemExit("duplicate code")
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps({
        "source": {"repository": REPOSITORY, "commit": COMMIT, "license": "CC0-1.0"},
        "codes": entries,
    }, indent=2, ensure_ascii=False) + "\n")
    print(f"wrote {len(entries)} entries to {OUTPUT} ({OUTPUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
