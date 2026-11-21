#include "include/EngineCatalogCore.h"
#include "../../Sources/FixedRender/Core.hpp"
#include "../../Sources/FixedRender/NativeContract.hpp"
#include "../../Sources/FixedRender/ReverbSize.hpp"
#include <limits>
using namespace fixedrender;
#define CHECK(condition) do { if (!(condition)) return __LINE__; } while (false)
extern "C" int engine_catalog_contract_check() {
    FRConfig config{FR_ABI_VERSION, 2, 512, 960, 48000, 480, 16, FR_LINEAR, 0, .95f, .08f};
    FRProgram program{}; program.count = 1;
    program.parts[0] = {1, FR_REVERB, 2, FR_PARAMETER_BIT(FR_WET_PERCENT), 0};
    FRFrame frame{}; frame.token = {1,1,1,1,1}; frame.count = 1;
    frame.values[0] = {1, FR_WET_PERCENT, 25};
    Snapshot wet, sized;
    CHECK(decode(config, program, frame, wet) == FR_OK);
    program.parts[0].parameter_mask |= FR_PARAMETER_BIT(FR_ROOM_SIZE);
    CHECK(decode(config, program, frame, sized) == FR_INVALID_FRAME);
    frame.values[frame.count++] = {1, FR_ROOM_SIZE, .5f};
    CHECK(decode(config, program, frame, sized) == FR_OK);
    CHECK(!sameSchedule(wet, sized));
    for (uint32_t preset : {1u,2u,3u,4u,5u}) {
        program.parts[0].preset = preset;
        CHECK(decode(config, program, frame, sized) == FR_OK);
    }
    program.parts[0].preset = 6; CHECK(decode(config, program, frame, sized) == FR_INVALID_PROGRAM);
    program.parts[0].preset = 2;
    program.parts[0].kind = FR_RESERVED_KIND_7; CHECK(decode(config, program, frame, sized) == FR_INVALID_PROGRAM);
    program.parts[0].kind = FR_REVERB;
    program.parts[0].parameter_mask = FR_PARAMETER_BIT(FR_ROOM_SIZE); CHECK(decode(config, program, frame, sized) == FR_INVALID_PROGRAM);
    program.parts[0].parameter_mask |= FR_PARAMETER_BIT(FR_WET_PERCENT) | (1u << 31); CHECK(decode(config, program, frame, sized) == FR_INVALID_PROGRAM);
    program.parts[0].parameter_mask &= ~(1u << 31);
    program.parts[0].reserved = 1; CHECK(decode(config, program, frame, sized) == FR_INVALID_PROGRAM);
    program.parts[0].reserved = 0;
    frame.values[1].value = std::numeric_limits<float>::quiet_NaN(); CHECK(decode(config, program, frame, sized) == FR_INVALID_FRAME);
    frame.values[1].value = .5f;
    frame.values[2] = frame.values[1]; ++frame.count; CHECK(decode(config, program, frame, sized) == FR_INVALID_FRAME);
    --frame.count;
    uint32_t contracts = 0;
    for (const auto &effect : EffectContracts) for (uint32_t k = 0; k < effect.knobCount; ++k) {
        const auto &knob = effect.knobs[k];
        for (uint32_t t = 0; t < knob.targetCount; ++t) {
            const auto &target = knob.targets[t];
            uint32_t unit = 0; while (!(target.units & (1u << unit))) ++unit;
            CHECK(admitNativeTarget(knob, target, 48000, unit, true, true, target.lower, target.upper));
            CHECK(!admitNativeTarget(knob, target, 48000, 31, true, true, target.lower, target.upper));
            CHECK(!admitNativeTarget(knob, target, 48000, unit, true, false, target.lower, target.upper));
            CHECK(!admitNativeTarget(knob, target, 48000, unit, true, true, std::nextafter(target.lower, target.upper), target.upper));
            CHECK(!admitNativeTarget(knob, target, 48000, unit, true, true, target.lower, std::nextafter(target.upper, target.lower)));
            CHECK(!admitNativeTarget(knob, target, 48000, unit, true, true, std::numeric_limits<float>::quiet_NaN(), target.upper));
            if (!target.readable) CHECK(admitNativeTarget(knob, target, 48000, unit, false, true, target.lower, target.upper));
            if (target.readable) CHECK(!admitNativeTarget(knob, target, 48000, unit, false, true, target.lower, target.upper));
            ++contracts;
        }
    }
    CHECK(contracts == 16);
    const auto *reverb = effectContract(FR_REVERB), *colour = effectContract(FR_DEVICE_COLOUR);
    CHECK(knobContract(*reverb, FR_WET_PERCENT)->targets[0].id == 0);
    CHECK(knobContract(*colour, FR_WET_PERCENT)->targets[0].id == 15);
    CHECK(knobContract(*reverb, FR_ROOM_SIZE)->optional);
    CHECK(!(reverb->requiredMask & FR_PARAMETER_BIT(FR_ROOM_SIZE)));
    const auto &size = *knobContract(*reverb, FR_ROOM_SIZE);
    for (uint32_t i = 0; i < size.targetCount; ++i) {
        const auto &target = size.targets[i];
        ReverbSizeBinding binding;
        const float baseline = std::lerp(target.lower, target.upper, .37f);
        CHECK(ReverbSizeBinding::admit(target.id, true, true, true, target.lower, target.upper, baseline, binding));
        CHECK(binding.seconds(.5f) == baseline);
        CHECK(binding.seconds(0) == target.lower && binding.seconds(1) == target.upper);
    }
    return 0;
}

// Refusals the spec names that the contract check above does not exercise.
extern "C" int engine_catalog_abi_refusal_check() {
    FRConfig config{FR_ABI_VERSION, 2, 512, 960, 48000, 480, 16, FR_LINEAR, 0, .95f, .08f};
    FRProgram program{}; program.count = 1;
    program.parts[0] = {1, FR_REVERB, 2, FR_PARAMETER_BIT(FR_WET_PERCENT), 0};
    FRFrame frame{}; frame.token = {1,1,1,1,1}; frame.count = 1;
    frame.values[0] = {1, FR_WET_PERCENT, 25};
    Snapshot out;
    CHECK(decode(config, program, frame, out) == FR_OK);
    program.parts[0].parameter_mask |= 1u;                       // bit 0 is invalid
    CHECK(decode(config, program, frame, out) == FR_INVALID_PROGRAM);
    program.parts[0].parameter_mask = FR_PARAMETER_BIT(FR_WET_PERCENT) | FR_PARAMETER_BIT(FR_GAIN_DB); // known id, not this effect's
    CHECK(decode(config, program, frame, out) == FR_INVALID_PROGRAM);
    program.parts[0].parameter_mask = FR_PARAMETER_BIT(FR_WET_PERCENT);
    frame.values[frame.count++] = {1, FR_ROOM_SIZE, .5f};        // value for an inactive optional knob
    CHECK(decode(config, program, frame, out) == FR_INVALID_FRAME);
    frame.values[1] = {1, 31, .5f};                              // unknown parameter id
    CHECK(decode(config, program, frame, out) == FR_INVALID_FRAME);
    frame.values[1] = {2, FR_WET_PERCENT, 25};                   // value for an unknown part key
    CHECK(decode(config, program, frame, out) == FR_INVALID_FRAME);
    frame.count = 1;
    program.parts[0] = {1, FR_GAIN, 0, FR_PARAMETER_BIT(FR_GAIN_DB), 0};
    frame.values[0] = {1, FR_GAIN_DB, -6};
    CHECK(decode(config, program, frame, out) == FR_OK);
    program.parts[0].preset = 1;                                 // effect with no presets takes preset 0 only
    CHECK(decode(config, program, frame, out) == FR_INVALID_PROGRAM);
    program.parts[0].preset = 0;
    program.parts[0].parameter_mask = 0;                         // required knob absent
    CHECK(decode(config, program, frame, out) == FR_INVALID_PROGRAM);
    program.parts[0].parameter_mask = FR_PARAMETER_BIT(FR_GAIN_DB);
    frame.values[0].value = 7;                                   // above the catalog's gain range
    CHECK(decode(config, program, frame, out) != FR_OK);
    frame.values[0].value = -6;
    config.abi_version = 1;                                      // ABI 1 values refuse
    CHECK(decode(config, program, frame, out) != FR_OK);
    return 0;
}

extern "C" int engine_catalog_native_row(uint32_t index, EngineCatalogNativeRow *row) {
    uint32_t n = 0;
    for (const auto &effect : EffectContracts) for (uint32_t k = 0; k < effect.knobCount; ++k) {
        const auto &knob = effect.knobs[k];
        for (uint32_t t = 0; t < knob.targetCount; ++t, ++n) {
            if (n != index) continue;
            const auto &target = knob.targets[t];
            *row = {effect.kind, knob.id, knob.optional ? 1u : 0u, static_cast<uint32_t>(knob.conversion), target.id, target.scope,
                    target.element, target.units, target.readable ? 1u : 0u, target.writable ? 1u : 0u,
                    knob.lower, knob.upper, target.lower, target.upper};
            return 1;
        }
    }
    return 0;
}

extern "C" int engine_catalog_effect_row(uint32_t index, EngineCatalogEffectRow *row) {
    if (index >= sizeof(EffectContracts) / sizeof(EffectContracts[0])) return 0;
    const auto &effect = EffectContracts[index];
    *row = {effect.kind, effect.componentType, effect.componentSubtype, effect.manufacturer, effect.requiredMask, effect.allowedMask, effect.presetCount, {}};
    for (uint32_t i = 0; i < effect.presetCount && i < 8; ++i) row->presets[i] = effect.presets[i];
    return 1;
}
