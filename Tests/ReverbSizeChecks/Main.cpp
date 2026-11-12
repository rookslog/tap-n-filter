#include "../../Sources/FixedRender/Core.hpp"
#include "../../Sources/FixedRender/ReverbSize.hpp"
#include <cassert>
#include <cstdio>
#include <limits>

using namespace fixedrender;

struct FakeNative {
    uint32_t writes = 0, ids[128]{};
    float values[128]{};
    void set(uint32_t id, float value) noexcept {
        assert(writes < 128);
        ids[writes] = id;
        values[writes++] = value;
    }
};

int main() {
    ReverbSizeBinding small, large;
    assert(ReverbSizeBinding::admit(2, true, true, true, 0.0001f, 0.05f, 0.019f, small));
    assert(ReverbSizeBinding::admit(3, true, true, true, 0.005f, 0.15f, 0.071f, large));
    assert(small.seconds(0.5f) == 0.019f && large.seconds(0.5f) == 0.071f);
    for (const auto &binding : {small, large}) {
        assert(binding.seconds(0) == binding.lower && binding.seconds(1) == binding.upper);
        float previous = binding.lower;
        for (uint32_t step = 0; step <= 1000; ++step) {
            const auto value = binding.seconds(float(step) / 1000);
            assert(std::isfinite(value) && value >= binding.lower && value <= binding.upper && value >= previous);
            previous = value;
        }
    }
    ReverbSizeBinding edge;
    assert(ReverbSizeBinding::admit(2, true, true, true, 0.0001f, 0.05f, 0.0010867919772863388f, edge));
    assert(edge.seconds(1) == edge.upper);
    for (uint32_t id : {2u, 3u}) {
        const float lower = id == 2 ? 0.0001f : 0.005f;
        const float upper = id == 2 ? 0.05f : 0.15f;
        for (uint32_t step = 0; step <= 4096; ++step) {
            const float baseline = std::lerp(lower, upper, float(step) / 4096);
            ReverbSizeBinding binding;
            assert(ReverbSizeBinding::admit(id, true, true, true, lower, upper, baseline, binding));
            assert(binding.seconds(0) == lower && binding.seconds(0.5f) == baseline && binding.seconds(1) == upper);
            for (uint32_t position = 0; position <= 32; ++position) {
                const float value = binding.seconds(float(position) / 32);
                assert(std::isfinite(value) && value >= lower && value <= upper);
            }
        }
    }
    ReverbSizeBinding unused;
    assert(!ReverbSizeBinding::admit(2, false, true, true, 0.0001f, 0.05f, 0.019f, unused));
    assert(!ReverbSizeBinding::admit(2, true, false, true, 0.0001f, 0.05f, 0.019f, unused));
    assert(!ReverbSizeBinding::admit(2, true, true, false, 0.0001f, 0.05f, 0.019f, unused));
    assert(!ReverbSizeBinding::admit(2, true, true, true, 0.001f, 0.05f, 0.019f, unused));
    assert(!ReverbSizeBinding::admit(3, true, true, true, 0.005f, 0.14f, 0.071f, unused));
    assert(!ReverbSizeBinding::admit(3, true, true, true, 0.005f, 0.15f, 0.16f, unused));
    assert(!ReverbSizeBinding::admit(3, true, true, true, 0.005f, 0.15f, std::numeric_limits<float>::quiet_NaN(), unused));
    assert(!ReverbSizeBinding::admit(4, true, true, true, 0.005f, 0.15f, 0.071f, unused));
    FakeNative native;
    ParameterRamp ramps[2]{{small.baseline, small.baseline, 0}, {large.baseline, large.baseline, 0}};
    ReverbSizeBinding bindings[2]{small, large};
    for (uint32_t i = 0; i < 2; ++i) ramps[i].retarget(bindings[i].seconds(1), 480);
    for (uint32_t frame = 0; frame < 480; frame += 16) {
        for (uint32_t i = 0; i < 2; ++i) {
            assert(ramps[i].advance(16));
            native.set(bindings[i].parameter, ramps[i].current);
            assert(ramps[i].current >= bindings[i].baseline && ramps[i].current <= bindings[i].upper);
        }
    }
    assert(native.writes == 60 && native.ids[0] == 2 && native.ids[1] == 3);
    assert(ramps[0].current == small.upper && ramps[1].current == large.upper);
    assert(!ramps[0].advance(16) && !ramps[1].advance(16));
    ramps[0].retarget(small.seconds(0.5f), 480);
    for (uint32_t frame = 0; frame < 480; frame += 16) ramps[0].advance(16);
    assert(ramps[0].current == small.baseline);
    FRConfig config{};
    config.abi_version = FR_ABI_VERSION; config.channels = 2; config.maximum_frames = 512;
    config.sample_rate = 48000; config.transition_frames = 960; config.smoothing_frames = 480;
    config.parameter_quantum = 16; config.peak_ceiling = 0.95f; config.limiter_release_seconds = 0.08f;
    FRProgram program{}; program.count = 1; program.parts[0] = {1, FR_SIZED_REVERB, 2};
    FRFrame frame{}; frame.token = {1, 1, 1, 1, 1}; frame.count = 2;
    frame.values[0] = {1, FR_WET_PERCENT, 8}; frame.values[1] = {1, FR_ROOM_SIZE, 0.5f};
    Snapshot initial, moved;
    assert(decode(config, program, frame, initial) == FR_OK);
    frame.values[1].value = 1;
    assert(decode(config, program, frame, moved) == FR_OK && sameSchedule(initial, moved));
    for (uint32_t preset : {0u, 4u, 5u, 9u}) {
        program.parts[0].preset = preset;
        assert(decode(config, program, frame, moved) == FR_INVALID_PROGRAM);
    }
    program.parts[0].preset = 2;
    frame.values[1].value = 1.01f;
    assert(decode(config, program, frame, moved) == FR_INVALID_FRAME);
    frame.values[1].value = 0.5f;
    frame.count = 1;
    assert(decode(config, program, frame, moved) == FR_INVALID_FRAME);
    program.parts[0].kind = FR_REVERB;
    assert(decode(config, program, frame, moved) == FR_OK);
    frame.count = 2;
    assert(decode(config, program, frame, moved) == FR_INVALID_FRAME);
    std::puts("PASS sized binding midpoint/ranges/units, fake seconds scheduling, Core contracts and legacy wet-only admission");
}
