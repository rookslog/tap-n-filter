#!/usr/bin/env python3
"""Generate compile-time effect contracts. No build-time dependencies or runtime parser."""
import argparse
import json
import math
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
CONVERSIONS = {"identity": "Identity", "sampleRateCutoff": "SampleRateCutoff", "presetRelativeSize": "PresetRelativeSize"}
STRATEGIES = {"equalizer": "Equalizer", "distortion": "Distortion", "reverb": "Reverb", "effect": "Effect", "gain": "Gain"}
PRESETS = {
    "distortion": {"AVAudioUnitDistortionPresetSpeechRadioTower", "AVAudioUnitDistortionPresetSpeechGoldenPi"},
    "reverb": {"AVAudioUnitReverbPresetSmallRoom", "AVAudioUnitReverbPresetMediumRoom", "AVAudioUnitReverbPresetLargeRoom", "AVAudioUnitReverbPresetLargeHall", "AVAudioUnitReverbPresetCathedral"},
}
UNITS = {"Hz": {8}, "dB": {13}, "%": {3, 16}, "s": {4}, "": {7}}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unique(values, message):
    require(len(set(values)) == len(values), message)


def bounds(value):
    require(isinstance(value, list) and len(value) == 2 and all(type(x) in (int, float) and math.isfinite(x) for x in value) and value[0] < value[1], "nonfinite or inverted range")


def validate(data):
    require(data["schema"] == 1 and data["revision"] >= 1, "unsupported catalog schema/revision")
    require(1 <= data["maxParameters"] <= 7 and 1 <= data["maxBindings"] <= 7, "fixed capacity exceeds ABI")
    ps, effects = data["parameters"], data["effects"]
    for key in ("id", "key", "symbol"):
        unique([p[key] for p in ps], "duplicate parameter " + key)
    by_key = {p["key"]: p for p in ps}
    for p in ps:
        bounds(p["range"])
        require(0 < p["id"] < 32 and p["conversion"] in CONVERSIONS and p["smoothing"] == "configurationFrames", "unsupported parameter contract")
    for key in ("id", "type", "symbol"):
        unique([e[key] for e in effects], "duplicate effect " + key)
    for e in effects:
        require({"everyday.v1", "filters.v1"} <= set(e["profiles"]), "missing historical profiles")
        require(type(e["id"]) is int and 0 < e["id"] <= 0xffffffff and e["id"] not in data["reservedKinds"] and e["strategy"] in STRATEGIES, "reserved effect or unknown factory")
        require(all(len(e["component"][x]) == 4 for x in ("type", "subtype", "manufacturer")), "invalid component identity")
        unique([k["parameter"] for k in e["knobs"]], "duplicate knob")
        unique([p["id"] for p in e["presets"]], "duplicate preset")
        require(bool(e["presetKey"]) == bool(e["presets"]), "missing preset targets")
        require(all(p["native"] in PRESETS.get(e["strategy"], set()) and p["id"] > 0 for p in e["presets"]), "preset is not in named native allowlist")
        require(len(e["knobs"]) <= data["maxParameters"] and sum(len(k["targets"]) for k in e["knobs"]) <= data["maxBindings"], "expanded binding capacity")
        unique([t["id"] for k in e["knobs"] for t in k["targets"]], "duplicate effect native target")
        for k in e["knobs"]:
            p = by_key[k["parameter"]]
            require(type(k["optional"]) is bool and 1 <= len(k["targets"]) <= 2, "missing knob targets/presence")
            for t in k["targets"]:
                bounds(t["range"])
                require(type(t["id"]) is int and 0 <= t["id"] <= 0xffffffff, "invalid native ID")
                require(t["scope"] == 0 and t["element"] == 0 and t["writable"] and type(t["readable"]) is bool, "unsupported target scope/flags")
                require(set(t["units"]) and set(t["units"]) <= ({4} if p["conversion"] == "presetRelativeSize" else UNITS[p["unit"]]), "incompatible native unit")
                if p["conversion"] != "presetRelativeSize":
                    require(t["range"] == p["range"], "identity target range differs from logical range")
                else:
                    require(t["id"] in (2, 3) and t["units"] == [4] and t["readable"], "invalid preset-relative target")
            unique([t["id"] for t in k["targets"]], "duplicate native target")
        for profile in e["profiles"].values():
            unique([p["key"] for p in profile], "duplicate profile key")
            allowed = {k["parameter"] for k in e["knobs"]} | {e["presetKey"]}
            required = {k["parameter"] for k in e["knobs"] if not k["optional"]} | ({e["presetKey"]} if e["presetKey"] else set())
            require(required <= {p["key"] for p in profile} <= allowed, "profile key contract")
            for p in profile:
                bounds(p["range"])
                require(math.isfinite(p["seed"]) and p["range"][0] <= p["seed"] <= p["range"][1], "out-of-bounds default")
                require(p["scale"] in ("linear", "logarithmic") and (p["scale"] != "logarithmic" or p["range"][0] > 0), "invalid profile scale")
                if p["key"] in by_key:
                    logical = by_key[p["key"]]["range"]
                    require(logical[0] <= p["seed"] <= logical[1], "default outside admitted logical range")
                if p["key"] == e["presetKey"]:
                    ids = {v["id"] for v in e["presets"]}
                    require(all(i in ids for i in range(int(p["range"][0]), int(p["range"][1]) + 1)), "profile has missing preset targets")
    return by_key


def f(value):
    return repr(float(value)) + "f"


def mask(parameters, by_key):
    return sum(1 << by_key[k["parameter"]]["id"] for k in parameters)


def generate(data):
    by_key = validate(data)
    banner = "// Generated by tools/generate-effect-catalog.py. Edit Config/EffectCatalog.json.\n"
    public = banner + "#ifndef FR_EFFECT_CATALOG_H\n#define FR_EFFECT_CATALOG_H\n"
    public += "enum { FR_CATALOG_REVISION = %d };\n" % data["revision"]
    public += "typedef enum FRPartKind {\n" + ",\n".join("    %s = %d" % (e["symbol"], e["id"]) for e in data["effects"]) + ",\n    FR_RESERVED_KIND_7 = 7\n} FRPartKind;\n"
    public += "typedef enum FRParameter {\n" + ",\n".join("    %s = %d" % (p["symbol"], p["id"]) for p in data["parameters"]) + "\n} FRParameter;\n"
    public += "#define FR_PARAMETER_BIT(id) (UINT32_C(1) << (id))\n#endif\n"
    cpp = banner + "#pragma once\n#include <cstdint>\nnamespace fixedrender {\n"
    cpp += "enum class Conversion { Identity, SampleRateCutoff, PresetRelativeSize };\nenum class Factory { Equalizer, Distortion, Reverb, Effect, Gain };\n"
    cpp += "struct TargetContract { uint32_t id, scope, element, units; float lower, upper; bool readable, writable; };\n"
    cpp += "struct KnobContract { uint32_t id; float lower, upper; Conversion conversion; bool optional; uint32_t targetCount; TargetContract targets[2]; };\n"
    cpp += "struct EffectContract { uint32_t kind; Factory factory; uint32_t componentType, componentSubtype, manufacturer, requiredMask, allowedMask, knobCount, presetCount, bandCount; uint32_t bands[2], presets[5]; KnobContract knobs[7]; };\n"
    cpp += "constexpr uint32_t MaxParameters = %d, MaxBindings = %d;\n" % (data["maxParameters"], data["maxBindings"])
    cpp += "inline constexpr EffectContract EffectContracts[] = {\n"
    for e in data["effects"]:
        fourcc = lambda s: str(int.from_bytes(s.encode("ascii"), "big")) + "u"
        component = [fourcc(e["component"][k]) for k in ("type", "subtype", "manufacturer")]
        cpp += "    {%d, Factory::%s, %s, %du, %du, %d, %d, %d, {%s}, {%s}, {\n" % (e["id"], STRATEGIES[e["strategy"]], ", ".join(component), mask([k for k in e["knobs"] if not k["optional"]], by_key), mask(e["knobs"], by_key), len(e["knobs"]), len(e["presets"]), len(e["bands"]), ", ".join(str({"bypass": 0, "highPass": 1, "lowPass": 2}[band]) for band in e["bands"]), ", ".join(str(p["id"]) for p in e["presets"]))
        for k in e["knobs"]:
            p = by_key[k["parameter"]]
            targets = []
            for t in k["targets"]:
                targets.append("{%d, %d, %d, %du, %s, %s, %s, true}" % (t["id"], t["scope"], t["element"], sum(1 << u for u in t["units"]), f(t["range"][0]), f(t["range"][1]), str(t["readable"]).lower()))
            cpp += "        {%d, %s, %s, Conversion::%s, %s, %d, {%s}},\n" % (p["id"], f(p["range"][0]), f(p["range"][1]), CONVERSIONS[p["conversion"]], str(k["optional"]).lower(), len(targets), ", ".join(targets))
        cpp += "    }},\n"
    cpp += "};\ninline const EffectContract *effectContract(uint32_t kind) { for (const auto &e : EffectContracts) if (e.kind == kind) return &e; return nullptr; }\ninline const KnobContract *knobContract(const EffectContract &effect, uint32_t id) { for (uint32_t i = 0; i < effect.knobCount; ++i) if (effect.knobs[i].id == id) return &effect.knobs[i]; return nullptr; }\n}\n"
    native = banner + "#pragma once\nnamespace fixedrender {\ninline int64_t nativePreset(uint32_t kind, uint32_t preset) {\n    switch (kind) {\n"
    for e in data["effects"]:
        if e["presets"]:
            native += "        case %d: switch (preset) {\n" % e["id"]
            for p in e["presets"]:
                native += "            case %d: return %s;\n" % (p["id"], p["native"])
            native += "            default: return -1;\n        }\n"
    native += "        default: return -1;\n    }\n}\n}\n"
    swift = banner + '''import Foundation

public struct EffectParameter: Sendable {
    public let key: String
    public let id: UInt32
    public let lower: Double
    public let upper: Double
    public let optional: Bool
    public let cutoff: Bool
    public let unit: String
}
public struct EffectProfileParameter: Sendable {
    public let key: String
    public let lower: Double
    public let upper: Double
    public let seed: Double
    public let logarithmic: Bool
    public let discrete: Bool
}
public struct EffectDefinition: Sendable {
    public let type: String
    public let kind: UInt32
    public let parameters: [EffectParameter]
    public let presetKey: String?
    public let presets: Set<UInt32>
    public let profiles: [String: [EffectProfileParameter]]
}
public enum EffectCatalog {
'''
    distortion = next(e for e in data["effects"] if e["strategy"] == "distortion")
    saved_enum = "public enum SavedDistortionPreset: Double {\n"
    for preset in distortion["presets"]:
        name = preset["native"].removeprefix("AVAudioUnitDistortionPreset")
        saved_enum += "    case " + name[0].lower() + name[1:] + " = " + str(preset["id"]) + "\n"
    saved_enum += "}\n"
    swift = swift.replace("public enum EffectCatalog {\n", saved_enum + "public enum EffectCatalog {\n")
    swift += "    public static let revision = %d\n    public static let effects: [EffectDefinition] = [\n" % data["revision"]
    for e in data["effects"]:
        swift += '        EffectDefinition(type: "%s", kind: %d, parameters: [\n' % (e["type"], e["id"])
        for k in e["knobs"]:
            p = by_key[k["parameter"]]
            swift += '            EffectParameter(key: "%s", id: %d, lower: %s, upper: %s, optional: %s, cutoff: %s, unit: "%s"),\n' % (p["key"], p["id"], *p["range"], str(k["optional"]).lower(), str(p["conversion"] == "sampleRateCutoff").lower(), p["unit"])
        swift += '        ], presetKey: %s, presets: [%s], profiles: [\n' % (json.dumps(e["presetKey"]) if e["presetKey"] else "nil", ", ".join(str(p["id"]) for p in e["presets"]))
        for name, ps in e["profiles"].items():
            swift += '            "%s": [\n' % name
            for p in ps:
                swift += '                EffectProfileParameter(key: "%s", lower: %s, upper: %s, seed: %s, logarithmic: %s, discrete: %s),\n' % (p["key"], *p["range"], p["seed"], str(p["scale"] == "logarithmic").lower(), str(p["discrete"]).lower())
            swift += "            ],\n"
        swift += "        ]),\n"
    swift += '''    ]
    public static func effect(_ type: String) -> EffectDefinition? {
        effects.first { $0.type == type }
    }
}
'''
    return {"Sources/FixedRender/include/EffectCatalog.h": public, "Sources/FixedRender/EffectCatalog.hpp": cpp, "Sources/FixedRender/EffectCatalogNative.hpp": native, "Sources/EffectCatalog/EffectCatalog.swift": swift}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--catalog", type=Path, default=ROOT / "Config/EffectCatalog.json")
    args = parser.parse_args()
    try:
        outputs = generate(json.loads(args.catalog.read_text()))
        stale = []
        for path, content in outputs.items():
            target = ROOT / path
            if args.check:
                if not target.exists() or target.read_bytes() != content.encode():
                    stale.append(path)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(content)
        require(not stale, "stale generated output: " + ", ".join(stale))
        print("PASS effect catalog" + (" drift check" if args.check else " generation"))
        return 0
    except (ValueError, KeyError, TypeError, OSError) as error:
        print("effect catalog: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
