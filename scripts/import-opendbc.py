#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "pycapnp", "pycryptodome", "tqdm"]
# ///
"""Generates Sources/SpiaKit/Catalog/modules-opendbc.json from a checkout of commaai/opendbc.

    git clone https://github.com/commaai/opendbc <dir>
    uv run scripts/import-opendbc.py <dir>

opendbc (MIT) records, for every car openpilot supports, the diagnostic address of each module
whose firmware it read on real cars (`FW_VERSIONS` in each make's fingerprints.py), and how it
asks them (`FW_QUERY_CONFIG` in values.py). The dependencies above are opendbc's own: the script
reads those objects through opendbc's code rather than re-parsing its Python.

Which modules an ordinary OBD-II adapter can reach, by the requests that read them (requests
marked `logging` only collect data, so they never produced a fingerprint and don't count):

    bus 1, OBD multiplexing   sent through the car's OBD port: openpilot's pandad sets the
                              panda's ELM327 safety parameter to 0, and the panda then routes its
                              second CAN controller to the OBD port (CAN_MODE_OBD_CAN2).
    bus 0                     sent on the car's own bus at the camera harness. Reachable from the
                              OBD port unless a gateway sits in between, so kept, and labelled so.
    anything else             harness-only buses (bus 1 without multiplexing, bus 2): left out.

A module's reply is its request plus the `rx_offset` of the requests that read it. When those
disagree (Chrysler reads ABS at both -0x280 and +8; Nissan reads everything at +8 and +0x20), the
legislated 7E0-7E7 answer at +8 and every other module at the make's own offset.

Left out for now, and counted: 29-bit addresses (Honda, some Chrysler) and ISO-TP extended
addressing (Toyota's sub-addressed modules), which Spia can't send yet.

Model names are matched against what NHTSA's vPIC decodes from a VIN, so the generator strips
what vPIC keeps out of the model (powertrain words, notes in parentheses) and maps the few names
vPIC spells differently. Output is sorted and stable: running it twice gives the same bytes.
"""

import ast
import importlib
import json
import re
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

OUTPUT = Path(__file__).resolve().parent.parent / "Sources/SpiaKit/Catalog/modules-opendbc.json"

# opendbc's ECU types, in the words the review sheet uses. A new type must be named here first.
LABELS = {
    "abs": "ABS",
    "adas": "Driver assistance",
    "combinationMeter": "Instrument cluster",
    "cornerRadar": "Corner radar",
    "dsu": "Driving support unit",
    "electricBrakeBooster": "Brake booster",
    "engine": "Engine",
    "eps": "Power steering",
    "fwdCamera": "Front camera",
    "fwdRadar": "Front radar",
    "gateway": "Gateway",
    "hud": "Head-up display",
    "hvac": "Climate control",
    "hybrid": "Hybrid system",
    "parkingAdas": "Parking assistance",
    "programmedFuelInjection": "Fuel injection",
    "shiftByWire": "Shift-by-wire",
    "srs": "Airbag",
    "transmission": "Transmission",
    "vsa": "Stability control",
}
SKIPPED_ECUS = {"debug", "unknown"}

# Words vPIC keeps out of the model (it decodes a Sonata Hybrid as a Sonata). Longest first.
POWERTRAIN_SUFFIXES = [
    "Sportback e-tron",
    "Plug-in Hybrid",
    "Electrified",
    "eHybrid",
    "Electric",
    "Hybrid",
    "Diesel",
    "EV",
]
# Names vPIC spells its own way, by make. Checked against vPIC's model lists on 2026-10-01.
VPIC_MODELS = {
    ("Mazda", "3"): "Mazda3",
    ("Mazda", "6"): "Mazda6",
    ("Toyota", "RAV4 Prime"): "RAV4 Prime (PHEV)",
    ("Toyota", "Prius Prime"): "Prius Prime (PHEV)",
    ("Toyota", "Corolla Hatchback"): "Corolla",
    ("Honda", "Civic Hatchback"): "Civic",
    ("Lexus", "GS F"): "GS",
}
ALIASES = {"Volkswagen": ["VW"]}


def vpic_model(make: str, model: str) -> str:
    model = re.sub(r"\s*\([^)]*\)", "", model).strip()
    for suffix in POWERTRAIN_SUFFIXES:
        if model.endswith(" " + suffix):
            model = model[: -len(suffix) - 1]
            break
    return VPIC_MODELS.get((make, model), model)


def year_runs(years: list[int]) -> list[tuple[int, int]]:
    runs: list[tuple[int, int]] = []
    for year in sorted(set(years)):
        if runs and year == runs[-1][1] + 1:
            runs[-1] = (runs[-1][0], year)
        else:
            runs.append((year, year))
    return runs


def fingerprint_lines(path: Path) -> dict[tuple[str, str, int, int | None], int]:
    """(platform, ecu, address, subaddress) -> the line of its key in fingerprints.py."""
    tree = ast.parse(path.read_text())
    lines = {}
    for node in tree.body:
        if not (isinstance(node, ast.Assign) and any(
                isinstance(t, ast.Name) and t.id == "FW_VERSIONS" for t in node.targets)):
            continue
        for platform, ecus in zip(node.value.keys, node.value.values):
            for key in ecus.keys:
                ecu, address, sub = key.elts
                lines[(platform.attr, ecu.attr, address.value, sub.value)] = key.lineno
    return lines


def route(requests, ecu) -> tuple[str, list[int]] | None:
    """How opendbc reads this ECU type, and the reply offsets it reads it at."""
    reading = [r for r in requests
               if not r.logging and (not r.whitelist_ecus or ecu in r.whitelist_ecus)]
    obd = [r.rx_offset for r in reading if r.bus == 1 and r.obd_multiplexing]
    harness = [r.rx_offset for r in reading if r.bus == 0]
    if obd:
        return "obd", sorted(set(obd))
    if harness:
        return "harness", sorted(set(harness))
    return None


def reply_offset(address: int, offsets: list[int]) -> int | None:
    if len(offsets) == 1:
        return offsets[0]
    if 0x7E0 <= address <= 0x7E7 and 0x8 in offsets:
        return 0x8
    own = [offset for offset in offsets if offset != 0x8]
    return own[0] if len(own) == 1 else None


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: uv run scripts/import-opendbc.py <opendbc checkout>")
    checkout = Path(sys.argv[1]).resolve()
    commit = subprocess.run(["git", "-C", str(checkout), "rev-parse", "HEAD"], check=True,
                            capture_output=True, text=True).stdout.strip()
    short = commit[:7]
    sys.path.insert(0, str(checkout))
    from opendbc.car.fw_query_definitions import ECU_NAME

    skipped: Counter[str] = Counter()
    # (make, platform name) -> platform; one per opendbc platform, model, and run of years.
    platforms: dict[str, dict[str, dict]] = defaultdict(dict)
    brands = sorted(p.parent.name for p in (checkout / "opendbc/car").glob("*/fingerprints.py"))
    for brand in brands:
        values = importlib.import_module(f"opendbc.car.{brand}.values")
        fingerprints = importlib.import_module(f"opendbc.car.{brand}.fingerprints")
        lines = fingerprint_lines(checkout / f"opendbc/car/{brand}/fingerprints.py")
        requests = values.FW_QUERY_CONFIG.requests
        for platform, ecus in fingerprints.FW_VERSIONS.items():
            modules = {}
            for ecu, address, sub in ecus:
                name = ECU_NAME[ecu]
                why = None
                if name in SKIPPED_ECUS:
                    why = f"{name} ECU"
                elif sub is not None:
                    why = "ISO-TP extended addressing"
                elif address > 0x7FF:
                    why = "29-bit"
                way = route(requests, ecu) if why is None else None
                if why is None and way is None:
                    why = "read only on harness buses"
                offset = reply_offset(address, way[1]) if way else None
                if why is None and offset is None:
                    why = "ambiguous reply offset"
                reply = address + offset if offset is not None else 0
                if why is None and not (0 < reply <= 0x7FF and reply != address
                                        and address != 0x7DF):
                    why = "reply outside 11-bit"
                if why is not None:
                    skipped[f"{brand}: {why}"] += 1
                    continue
                if name not in LABELS:
                    sys.exit(f"opendbc has a new ECU type, {name}: give it a label in LABELS")
                line = lines[(platform.name, name, address, sub)]
                asked = ("asked through the OBD port" if way[0] == "obd" else
                         "asked on the car's bus at the camera harness, so it may sit behind a "
                         "gateway from the OBD port")
                key = (address, reply)
                if key in modules:
                    skipped[f"{brand}: same address as another ECU type"] += 1
                    continue
                modules[key] = {
                    "label": LABELS[name], "bus": "hs",
                    "request": f"{address:03X}", "reply": f"{reply:03X}",
                    "provenance": "reference",
                    "source": f"opendbc {short}: {platform.name} {name}, "
                              f"opendbc/car/{brand}/fingerprints.py:{line}; {asked}",
                }
            if not modules:
                continue
            labels = Counter(m["label"] for m in modules.values())
            ordered = []
            for (address, reply), module in sorted(modules.items()):
                if labels[module["label"]] > 1:
                    module["label"] = f"{module['label']} ({module['request']})"
                ordered.append(module)
            years_by_model: dict[tuple[str, str], list[int]] = defaultdict(list)
            for docs in platform.config.car_docs:
                if docs.make == "comma":
                    continue
                years_by_model[(docs.make, vpic_model(docs.make, docs.model))] += [
                    int(year) for year in docs.year_list
                ]
            for (make, model), years in sorted(years_by_model.items()):
                if not years:
                    skipped[f"{brand}: model without years"] += 1
                    continue
                for first, last in year_runs(years):
                    span = f"{first}" if first == last else f"{first}-{last}"
                    name = f"{make} {model} {span} (opendbc {platform.name})"
                    platforms[make][name] = {
                        "name": name, "models": [model], "years": {"first": first, "last": last},
                        "source": f"opendbc {short}: {platform.name}, opendbc/car/{brand}/values.py",
                        "modules": ordered,
                    }

    makes = []
    for make in sorted(platforms, key=str.casefold):
        entries = sorted(platforms[make].values(),
                         key=lambda p: (p["models"][0].casefold(), p["years"]["first"], p["name"]))
        makes.append({"make": make, "aliases": ALIASES.get(make, []), "platforms": entries})

    write(makes, commit, short)
    modules = sum(len(p["modules"]) for m in makes for p in m["platforms"])
    print(f"opendbc {commit}: {len(makes)} makes, "
          f"{sum(len(m['platforms']) for m in makes)} platforms, {modules} modules", file=sys.stderr)
    for make in makes:
        addresses = sorted({m["request"] for p in make["platforms"] for m in p["modules"]})
        print(f"  {make['make']}: {len(make['platforms'])} platforms, addresses {addresses}",
              file=sys.stderr)
    for why, count in sorted(skipped.items()):
        print(f"  skipped {count}: {why}", file=sys.stderr)


def write(makes: list[dict], commit: str, short: str) -> None:
    """The same shape as modules.json, one module per line."""
    def line(value: dict) -> str:
        return json.dumps(value, ensure_ascii=False)

    out = ["{", '  "schemaVersion": 1,', f'  "catalogVersion": "opendbc-{short}",',
           f'  "generatedFrom": "https://github.com/commaai/opendbc/tree/{commit}",',
           '  "license": "MIT, Copyright (c) 2020 Comma.ai, Inc.; see NOTICE",',
           '  "makes": [']
    for i, make in enumerate(makes):
        out += ["    {", f'      "make": {line(make["make"])},',
                f'      "aliases": {line(make["aliases"])},', '      "platforms": [']
        for j, platform in enumerate(make["platforms"]):
            out += ["        {", f'          "name": {line(platform["name"])},',
                    f'          "models": {line(platform["models"])},',
                    f'          "years": {line(platform["years"])},',
                    f'          "source": {line(platform["source"])},', '          "modules": [']
            modules = platform["modules"]
            out += [f"            {line(m)}" + ("," if k < len(modules) - 1 else "")
                    for k, m in enumerate(modules)]
            out += ["          ]", "        }" + ("," if j < len(make["platforms"]) - 1 else "")]
        out += ["      ]", "    }" + ("," if i < len(makes) - 1 else "")]
    out += ["  ]", "}", ""]
    OUTPUT.write_text("\n".join(out))


if __name__ == "__main__":
    main()
