#pragma once
#include "EffectCatalog.hpp"
#include <algorithm>
#include <cmath>

namespace fixedrender {

inline bool admitNativeTarget(const KnobContract &knob, const TargetContract &target,
                              double sampleRate, uint32_t unit, bool readable, bool writable,
                              float minimum, float maximum) noexcept {
    if (!std::isfinite(minimum) || !std::isfinite(maximum) || minimum > maximum || unit >= 32 ||
        !(target.units & (1u << unit)) || (target.readable && !readable) || (target.writable && !writable)) return false;
    const float upper = knob.conversion == Conversion::SampleRateCutoff ?
        float(std::min(double(target.upper), sampleRate * 0.49)) : target.upper;
    return minimum <= target.lower && maximum >= upper;
}

}
