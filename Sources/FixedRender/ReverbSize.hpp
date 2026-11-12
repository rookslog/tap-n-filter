#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>

namespace fixedrender {

struct ReverbSizeBinding {
    uint32_t parameter = 0;
    float lower = 0, baseline = 0, upper = 0;

    static bool admit(uint32_t parameter, bool seconds, bool readable, bool writable,
                      float minimum, float maximum, float current, ReverbSizeBinding &out) noexcept {
        if ((parameter != 2 && parameter != 3) || !seconds || !readable || !writable ||
            !std::isfinite(minimum) || !std::isfinite(maximum) || !std::isfinite(current)) return false;
        const float lower = parameter == 2 ? 0.0001f : 0.005f;
        const float upper = parameter == 2 ? 0.05f : 0.15f;
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
