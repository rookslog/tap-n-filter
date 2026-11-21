#pragma once

#include "include/FixedRender.h"
#include "EffectCatalog.hpp"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <type_traits>

namespace fixedrender {

struct PartState {
    FRPart spec{};
    uint32_t count = 0;
    uint32_t ids[MaxParameters]{};
    float values[MaxParameters]{};
};

struct Snapshot {
    FRToken token{};
    uint32_t count = 0;
    PartState parts[FR_MAX_PARTS]{};
};

static_assert(std::is_trivially_copyable_v<Snapshot>);
static_assert(std::is_trivially_destructible_v<Snapshot>);
static_assert(sizeof(Snapshot) <= 4096);

inline bool sameIdentity(const FRToken &a, const FRToken &b) {
    return a.assignment == b.assignment && a.source_epoch == b.source_epoch &&
           a.format_epoch == b.format_epoch;
}

inline bool sameTopology(const FRToken &a, const FRToken &b) {
    return sameIdentity(a, b) && a.topology == b.topology;
}

inline bool samePart(const FRPart &a, const FRPart &b) {
    return a.key == b.key && a.kind == b.kind && a.preset == b.preset &&
           a.parameter_mask == b.parameter_mask;
}

inline bool sameSchedule(const Snapshot &a, const Snapshot &b) {
    if (a.count != b.count) return false;
    for (uint32_t i = 0; i < a.count; ++i)
        if (!samePart(a.parts[i].spec, b.parts[i].spec)) return false;
    return true;
}

inline bool range(float value, float low, float high) {
    return std::isfinite(value) && value >= low && value <= high;
}

inline FRResult validateConfig(const FRConfig &c) {
    if (c.abi_version != FR_ABI_VERSION || c.reserved ||
        c.transition_curve > FR_EQUAL_POWER || c.transition_frames < 1 ||
        c.transition_frames > 192000 || c.smoothing_frames < 1 ||
        c.smoothing_frames > 192000 || c.parameter_quantum < 1 ||
        c.parameter_quantum > 64 || !range(c.peak_ceiling, 0, 1) ||
        c.peak_ceiling == 0 || !range(c.limiter_release_seconds, 0.001f, 3))
        return FR_INVALID_ARGUMENT;
    if (!std::isfinite(c.sample_rate) || c.sample_rate < 8000 ||
        c.sample_rate > 192000 || c.channels < 1 || c.channels > 2 ||
        c.maximum_frames < 1 || c.maximum_frames > FR_MAX_FRAMES)
        return FR_INVALID_FORMAT;
    return FR_OK;
}

inline bool sameConfig(const FRConfig &a, const FRConfig &b) {
    return a.abi_version == b.abi_version && a.channels == b.channels &&
           a.maximum_frames == b.maximum_frames && a.sample_rate == b.sample_rate &&
           a.transition_frames == b.transition_frames &&
           a.smoothing_frames == b.smoothing_frames &&
           a.parameter_quantum == b.parameter_quantum &&
           a.transition_curve == b.transition_curve && a.peak_ceiling == b.peak_ceiling &&
           a.limiter_release_seconds == b.limiter_release_seconds;
}

inline uint32_t parameters(const FRPart &part, uint32_t *ids) {
    const auto *effect = effectContract(part.kind);
    if (!effect || part.reserved || (part.parameter_mask & effect->requiredMask) != effect->requiredMask ||
        (part.parameter_mask & ~effect->allowedMask)) return 0;
    uint32_t count = 0;
    for (uint32_t i = 0; i < effect->knobCount; ++i)
        if (part.parameter_mask & FR_PARAMETER_BIT(effect->knobs[i].id)) ids[count++] = effect->knobs[i].id;
    return count;
}

inline bool valueBounds(const KnobContract &knob, double sampleRate, float &low, float &high) {
    low = knob.lower;
    high = knob.conversion == Conversion::SampleRateCutoff ? float(std::min(double(knob.upper), sampleRate * 0.49)) : knob.upper;
    return true;
}

inline FRResult decode(const FRConfig &c, const FRProgram &p, const FRFrame &f,
                       Snapshot &out) {
    auto result = validateConfig(c);
    if (result != FR_OK) return result;
    const auto &t = f.token;
    if (!t.assignment || !t.source_epoch || !t.format_epoch || !t.topology || !t.intent)
        return FR_INVALID_FRAME;
    if (p.reserved || p.count > FR_MAX_PARTS) return FR_INVALID_PROGRAM;
    if (f.reserved || f.count > FR_MAX_VALUES) return FR_INVALID_FRAME;
    out = {};
    out.token = t;
    out.count = p.count;
    bool used[FR_MAX_VALUES]{};
    uint32_t expected = 0;
    for (uint32_t i = 0; i < p.count; ++i) {
        const FRPart &part = p.parts[i];
        if (!part.key) return FR_INVALID_PROGRAM;
        for (uint32_t j = 0; j < i; ++j)
            if (p.parts[j].key == part.key) return FR_INVALID_PROGRAM;
        auto &state = out.parts[i];
        state.spec = part;
        state.count = parameters(part, state.ids);
        if (!state.count) return FR_INVALID_PROGRAM;
        const auto &effect = *effectContract(part.kind);
        bool presetOK = !effect.presetCount && !part.preset;
        for (uint32_t j = 0; j < effect.presetCount; ++j) presetOK |= effect.presets[j] == part.preset;
        if (!presetOK) return FR_INVALID_PROGRAM;
        expected += state.count;
        for (uint32_t j = 0; j < state.count; ++j) {
            uint32_t matches = 0;
            for (uint32_t k = 0; k < f.count; ++k) {
                const auto &v = f.values[k];
                if (v.key != part.key || v.parameter != state.ids[j]) continue;
                float low = 0, high = 0;
                const auto *knob = knobContract(effect, v.parameter);
                if (!knob || !valueBounds(*knob, c.sample_rate, low, high) || !range(v.value, low, high)) return FR_INVALID_FRAME;
                state.values[j] = v.value;
                used[k] = true;
                ++matches;
            }
            if (matches != 1) return FR_INVALID_FRAME;
        }
    }
    if (expected != f.count) return FR_INVALID_FRAME;
    for (uint32_t k = 0; k < f.count; ++k)
        if (!used[k]) return FR_INVALID_FRAME;
    return FR_OK;
}

class FrameMailbox {
    Snapshot slots_[3]{};
    std::atomic<uint32_t> middle_{1};
    uint32_t back_ = 2;
    uint32_t front_ = 0;
    static constexpr uint32_t Dirty = 4;
public:
    void publish(const Snapshot &value) {
        slots_[back_] = value;
        back_ = middle_.exchange(back_ | Dirty, std::memory_order_acq_rel) & 3;
    }
    bool consume(Snapshot &value) {
        if (!(middle_.load(std::memory_order_acquire) & Dirty)) return false;
        front_ = middle_.exchange(front_, std::memory_order_acq_rel) & 3;
        value = slots_[front_];
        return true;
    }
};

template <typename T, uint32_t Capacity> class RetireQueue {
    T entries_[Capacity]{};
    std::atomic<uint64_t> write_{0}, read_{0};
public:
    bool hasSpace() const {
        return write_.load(std::memory_order_relaxed) -
               read_.load(std::memory_order_acquire) < Capacity;
    }
    bool push(T entry) {
        const auto w = write_.load(std::memory_order_relaxed);
        if (w - read_.load(std::memory_order_acquire) >= Capacity) return false;
        entries_[w % Capacity] = entry;
        write_.store(w + 1, std::memory_order_release);
        return true;
    }
    T pop() {
        const auto r = read_.load(std::memory_order_relaxed);
        if (r == write_.load(std::memory_order_acquire)) return {};
        const auto result = entries_[r % Capacity];
        read_.store(r + 1, std::memory_order_release);
        return result;
    }
};

static_assert(std::atomic<uint32_t>::is_always_lock_free);
static_assert(std::atomic<uint64_t>::is_always_lock_free);
static_assert(std::atomic<void *>::is_always_lock_free);

} // namespace fixedrender
