#include "OutputGate.h"
#include <atomic>
#include <cassert>
#include <new>

struct OGEntry {
    std::atomic<uint32_t> active{0}, disabled{0};
    std::atomic<uint64_t> callbacks{0}, requested{0}, captured{0}, underruns{0}, errors{0};
    std::atomic<int32_t> lastError{0};
};
static_assert(std::atomic<uint32_t>::is_always_lock_free);
static_assert(std::atomic<uint64_t>::is_always_lock_free);

extern "C" OGEntry *og_create() { return new (std::nothrow) OGEntry; }
extern "C" uint32_t og_enter(OGEntry *e) {
    e->active.fetch_add(1);
    if (!e->disabled.load()) return 1;
    e->active.fetch_sub(1);
    return 0;
}
extern "C" void og_leave(OGEntry *e) { e->active.fetch_sub(1); }
extern "C" void og_disable(OGEntry *e) { e->disabled.store(1); }
extern "C" uint32_t og_is_quiescent(const OGEntry *e) {
    return e->disabled.load() && e->active.load() == 0;
}
extern "C" void og_record(OGEntry *e, uint32_t requested, uint32_t captured, int32_t error) {
    e->callbacks.fetch_add(1, std::memory_order_relaxed);
    e->requested.fetch_add(requested, std::memory_order_relaxed);
    e->captured.fetch_add(captured, std::memory_order_relaxed);
    if (captured < requested) e->underruns.fetch_add(1, std::memory_order_relaxed);
    if (error) e->errors.fetch_add(1, std::memory_order_relaxed);
    e->lastError.store(error, std::memory_order_relaxed);
}
extern "C" void og_stats(const OGEntry *e, OGStats *s) {
    *s = {e->callbacks.load(), e->requested.load(), e->captured.load(), e->underruns.load(),
          e->errors.load(), e->lastError.load(), e->active.load(), e->disabled.load()};
}
extern "C" void og_destroy(OGEntry *e) {
    if (!e) return;
    assert(og_is_quiescent(e));
    delete e;
}
