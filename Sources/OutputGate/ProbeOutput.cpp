#include "ProbeOutput.h"
#include <atomic>
#include <algorithm>
#include <cassert>
#include <cmath>
#include <new>
struct OGProbeMeter {
    const uint64_t epoch;
    const double rate;
    const uint32_t channels;
    std::atomic<bool> closed{false}, writing{false};
    std::atomic<uint32_t> active{0}, observers{0};
    std::atomic<uint64_t> callbacks{0}, frames{0}, samples{0}, nonzero{0}, invalid{0};
    std::atomic<uint64_t> badBuffers{0}, dropped{0}, first{0}, last{0};
    std::atomic<double> squares{0}, peak{0};
    OGProbeMeter(uint64_t e, double r, uint32_t c): epoch(e),rate(r),channels(c) {}
};
static_assert(std::atomic<bool>::is_always_lock_free);
static_assert(std::atomic<uint32_t>::is_always_lock_free);
static_assert(std::atomic<uint64_t>::is_always_lock_free);
static_assert(std::atomic<double>::is_always_lock_free);
extern "C" OGProbeMeter *og_probe_create(uint64_t e, double r, uint32_t c) {
    if (!e || !std::isfinite(r) || r <= 0 || !c || c > 8) return nullptr;
    return new(std::nothrow) OGProbeMeter(e,r,c);
}
extern "C" void og_probe_record(OGProbeMeter *m, const float *const *p, uint32_t c,
                                  uint32_t n, double r, uint64_t time) {
    m->active.fetch_add(1);
    if (m->closed.load()) { m->active.fetch_sub(1); return; }
    bool expected = false;
    if (!m->writing.compare_exchange_strong(expected, true)) {
        m->dropped.fetch_add(1); m->active.fetch_sub(1); return;
    }
    m->callbacks.fetch_add(1);
    bool valid = p && c == m->channels && r == m->rate && n && n <= 16384;
    if (valid) for (uint32_t ch=0; ch<c; ++ch) valid = valid && p[ch];
    if (!valid) m->badBuffers.fetch_add(1);
    else {
        double squares=0, peak=0; uint64_t invalid=0, nonzero=0;
        for (uint32_t ch=0; ch<c; ++ch) for (uint32_t i=0; i<n; ++i) {
            const double value = p[ch][i];
            if (!std::isfinite(value)) { ++invalid; continue; }
            squares += value*value; peak=std::max(peak,std::abs(value));
            nonzero += value != 0;
        }
        if (!m->frames.load()) m->first.store(time);
        m->last.store(time); m->frames.fetch_add(n); m->samples.fetch_add(uint64_t(n)*c);
        m->nonzero.fetch_add(nonzero); m->invalid.fetch_add(invalid);
        m->squares.store(m->squares.load()+squares);
        m->peak.store(std::max(m->peak.load(),peak));
    }
    m->writing.store(false); m->active.fetch_sub(1);
}
extern "C" void og_probe_retain_observer(OGProbeMeter *m) {
    assert(!m->closed.load()); m->observers.fetch_add(1);
}
extern "C" void og_probe_release_observer(OGProbeMeter *m) {
    const auto previous = m->observers.fetch_sub(1); assert(previous > 0);
}
extern "C" void og_probe_close(OGProbeMeter *m) { m->closed.store(true); }
extern "C" uint32_t og_probe_quiescent(const OGProbeMeter *m) {
    return m->closed.load() && m->active.load()==0 && m->observers.load()==0;
}
extern "C" void og_probe_snapshot(const OGProbeMeter *m, OGProbeSnapshot *s) {
    *s = {m->epoch,m->callbacks.load(),m->frames.load(),m->samples.load(),m->nonzero.load(),
        m->invalid.load(),m->badBuffers.load(),m->dropped.load(),m->first.load(),m->last.load(),
        m->rate,m->squares.load(),m->peak.load(),m->channels,og_probe_quiescent(m)};
}
extern "C" void og_probe_destroy(OGProbeMeter *m) {
    if (!m) return;
    assert(og_probe_quiescent(m)); delete m;
}
