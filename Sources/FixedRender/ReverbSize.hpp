#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include "include/FixedRender.h"
#include "EffectCatalog.hpp"

namespace fixedrender {

struct ReverbSizeBinding {
    uint32_t parameter = 0;
    float lower = 0, baseline = 0, upper = 0;

    static bool admit(uint32_t parameter, bool seconds, bool readable, bool writable,
                      float minimum, float maximum, float current, ReverbSizeBinding &out) noexcept {
        const auto *effect = effectContract(FR_REVERB);
        const auto *knob = effect ? knobContract(*effect, FR_ROOM_SIZE) : nullptr;
        const TargetContract *target = nullptr;
        if (knob) for (uint32_t i = 0; i < knob->targetCount; ++i)
            if (knob->targets[i].id == parameter) target = &knob->targets[i];
        if (!target || !seconds || !readable || !writable ||
            !std::isfinite(minimum) || !std::isfinite(maximum) || !std::isfinite(current)) return false;
        const float lower = target->lower, upper = target->upper;
        if (minimum > lower || maximum < upper || current < lower || current > upper) return false;
        out = {parameter, lower, current, upper};
        return true;
    }

    float seconds(float coordinate) const noexcept {
        if (coordinate == 0.5f) return baseline;
        if (coordinate < 0.5f) return std::lerp(lower, baseline, coordinate * 2);
        return std::lerp(baseline, upper, (coordinate - 0.5f) * 2);
    }
};

struct ParameterRamp {
    float current = 0, target = 0;
    uint32_t remaining = 0;

    void retarget(float value, uint32_t frames) noexcept {
        if (value == target) return;
        target = value;
        remaining = frames;
    }
    bool advance(uint32_t frames) noexcept {
        if (!remaining) return false;
        const auto step = std::min(frames, remaining);
        current += (target - current) * float(step) / float(remaining);
        remaining -= step;
        if (!remaining) current = target;
        return true;
    }
};

}
