#include "OutputGate.h"
#include <atomic>
#include <cassert>
#include <cstdio>
#include <thread>

int main() {
    auto *gate = og_create(); assert(gate);
    assert(og_enter(gate));
    og_disable(gate);
    assert(!og_is_quiescent(gate));
    for (int i = 0; i < 10000; ++i) assert(!og_enter(gate));
    og_leave(gate);
    assert(og_is_quiescent(gate));
    og_destroy(gate);
    for (int repeat = 0; repeat < 100; ++repeat) {
        gate = og_create(); assert(gate);
        std::atomic<bool> started{false}, finish{false};
        std::thread consumer([&] {
            assert(og_enter(gate)); started.store(true);
            while (!finish.load()) std::this_thread::yield();
            og_record(gate, 512, 256, -1);
            og_leave(gate);
            for (int i = 0; i < 1000; ++i) assert(!og_enter(gate));
        });
        while (!started.load()) std::this_thread::yield();
        og_disable(gate);
        assert(!og_is_quiescent(gate));
        finish.store(true); consumer.join();
        assert(og_is_quiescent(gate));
        OGStats stats{}; og_stats(gate, &stats);
        assert(stats.callbacks == 1 && stats.captured_frames == 256 && stats.requested_frames == 512);
        assert(stats.underruns == 1 && stats.errors == 1 && stats.last_error == -1);
        og_destroy(gate);
    }
    std::puts("PASS output gate: disabled callbacks cannot reenter DSP, outstanding callback drains, 100 threaded ownership/telemetry traces");
}
