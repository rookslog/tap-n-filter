#pragma once

#include "include/FixedRender.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <type_traits>

namespace fixedrender {

constexpr uint32_t MaxParameters = 7;

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
    return a.key == b.key && a.kind == b.kind && a.preset == b.preset;
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

inline uint32_t parameters(uint32_t kind, uint32_t *ids) {
    switch (kind) {
        case FR_DEVICE_EQ: ids[0] = FR_HP_HZ; ids[1] = FR_LP_HZ; return 2;
        case FR_DEVICE_COLOUR: ids[0] = FR_WET_PERCENT; ids[1] = FR_PREGAIN_DB; return 2;
        case FR_PLACE_EQ: ids[0] = FR_LP_HZ; return 1;
        case FR_REVERB: ids[0] = FR_WET_PERCENT; return 1;
        case FR_SIZED_REVERB: ids[0] = FR_WET_PERCENT; ids[1] = FR_ROOM_SIZE; return 2;
        case FR_DYNAMICS:
            ids[0] = FR_THRESHOLD_DB; ids[1] = FR_HEADROOM_DB;
            ids[2] = FR_EXPANSION_RATIO; ids[3] = FR_EXPANSION_THRESHOLD_DB;
            ids[4] = FR_ATTACK_SECONDS; ids[5] = FR_RELEASE_SECONDS;
            ids[6] = FR_MAKEUP_DB; return 7;
        case FR_GAIN: ids[0] = FR_GAIN_DB; return 1;
        default: return 0;
    }
}

inline bool valueBounds(uint32_t id, double sampleRate, float &low, float &high) {
    switch (id) {
        case FR_HP_HZ: case FR_LP_HZ:
            low = 20; high = float(std::min(20000.0, sampleRate * 0.49)); break;
        case FR_WET_PERCENT: low = 0; high = 100; break;
        case FR_PREGAIN_DB: low = -80; high = 20; break;
        case FR_THRESHOLD_DB: low = -40; high = 20; break;
        case FR_HEADROOM_DB: low = 0.1f; high = 40; break;
        case FR_EXPANSION_RATIO: low = 1; high = 50; break;
        case FR_EXPANSION_THRESHOLD_DB: low = -120; high = 0; break;
        case FR_ATTACK_SECONDS: low = 0.001f; high = 0.2f; break;
        case FR_RELEASE_SECONDS: low = 0.01f; high = 3; break;
        case FR_MAKEUP_DB: low = -40; high = 40; break;
        case FR_GAIN_DB: low = -96; high = 6; break;
        case FR_ROOM_SIZE: low = 0; high = 1; break;
        default: return false;
    }
    return true;
}

inline bool validValue(uint32_t id, float v, double sampleRate) {
    float low = 0, high = 0;
    return valueBounds(id, sampleRate, low, high) && range(v, low, high);
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
        state.count = parameters(part.kind, state.ids);
        if (!state.count) return FR_INVALID_PROGRAM;
        bool presetOK = (part.kind == FR_REVERB || part.kind == FR_SIZED_REVERB) ? part.preset >= 1 && part.preset <= 3 :
                        part.kind == FR_DEVICE_COLOUR ? part.preset >= 1 && part.preset <= 2 :
                        part.preset == 0;
        if (!presetOK) return FR_INVALID_PROGRAM;
        expected += state.count;
        for (uint32_t j = 0; j < state.count; ++j) {
            uint32_t matches = 0;
            for (uint32_t k = 0; k < f.count; ++k) {
                const auto &v = f.values[k];
                if (v.key != part.key || v.parameter != state.ids[j]) continue;
                if (!validValue(v.parameter, v.value, c.sample_rate)) return FR_INVALID_FRAME;
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
