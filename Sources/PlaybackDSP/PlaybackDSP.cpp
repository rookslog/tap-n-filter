#include "include/PlaybackDSP.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <new>

static_assert(std::atomic<uint64_t>::is_always_lock_free);
static_assert(std::atomic<uint32_t>::is_always_lock_free);
static_assert(std::atomic<float>::is_always_lock_free);
static_assert(std::atomic<int32_t>::is_always_lock_free);

struct PDEntry {
    FRRenderer *renderer;
    const FRConfig config;
    const double slew, release;
    double mix = 0, safetyGain = 1;
    FRToken identity{};
    uint64_t measured = 0;
    bool ready = false;
    std::atomic<uint32_t> requested{0}, readyStat{0};
    std::atomic<uint64_t> callbacks{0}, errors{0}, measuredStat{0}, limited{0}, invalid{0};
    std::atomic<uint64_t> assignment{0}, source{0}, format{0}, topology{0}, intent{0}, frameIntent{0};
    std::atomic<float> mixStat{0};
    std::atomic<int32_t> resultStat{FR_OK}, nativeStat{0};

    PDEntry(FRRenderer *r, const FRConfig &c) : renderer(r), config(c),
        slew(1 / (c.sample_rate * 0.02)),
        release(std::exp(-1 / (c.sample_rate * c.limiter_release_seconds))) {}
};

namespace {
double toward(double current, double target, double step) {
    return current + std::clamp(target - current, -step, step);
}
FRResult callback(void *context, const FRInput *input, FROutput *output,
                  uint32_t frames, PDRenderReport *report) {
    return pd_render(static_cast<PDEntry *>(context), input, output, frames, report);
}
void record(PDEntry &e, FRResult result, const PDRenderReport &r) {
    e.callbacks.fetch_add(1, std::memory_order_relaxed);
    if (result != FR_OK) e.errors.fetch_add(1, std::memory_order_relaxed);
    e.measuredStat.store(e.measured, std::memory_order_relaxed);
    e.readyStat.store(r.compare_ready, std::memory_order_relaxed);
    e.mixStat.store(float(e.mix), std::memory_order_relaxed);
    e.limited.fetch_add(r.limited_samples, std::memory_order_relaxed);
    e.invalid.fetch_add(r.invalid_samples, std::memory_order_relaxed);
    const auto &t = r.renderer.audible;
    e.assignment.store(t.assignment, std::memory_order_relaxed);
    e.source.store(t.source_epoch, std::memory_order_relaxed);
    e.format.store(t.format_epoch, std::memory_order_relaxed);
    e.topology.store(t.topology, std::memory_order_relaxed);
    e.intent.store(t.intent, std::memory_order_relaxed);
    e.frameIntent.store(r.renderer.frame_intent, std::memory_order_relaxed);
    e.resultStat.store(result, std::memory_order_relaxed);
    e.nativeStat.store(r.renderer.native_status, std::memory_order_relaxed);
}
}

extern "C" FRResult pd_create(const FRConfig *config, PDEntry **out) {
    if (!config || !out || *out) return FR_INVALID_ARGUMENT;
    FRRenderer *renderer = nullptr;
    const auto result = fr_create(config, &renderer);
    if (result != FR_OK) return result;
    *out = new (std::nothrow) PDEntry(renderer, *config);
    if (!*out) { fr_destroy(renderer); return FR_OUT_OF_MEMORY; }
    return FR_OK;
}
extern "C" FRResult pd_set_desired(PDEntry *e, const FRProgram *p, const FRFrame *f) {
    return e ? fr_set_desired(e->renderer, p, f) : FR_INVALID_ARGUMENT;
}
extern "C" FRResult pd_prepare(const FRConfig *c, const FRProgram *p, const FRFrame *f,
                                FRPrepared **b, int32_t *s) { return fr_prepare(c, p, f, b, s); }
extern "C" FRResult pd_publish(PDEntry *e, FRPrepared **b, int32_t *s) {
    return e ? fr_publish(e->renderer, b, s) : FR_INVALID_ARGUMENT;
}
extern "C" void pd_prepared_dispose(FRPrepared *b) { fr_prepared_dispose(b); }
extern "C" uint32_t pd_collect(PDEntry *e) { return e ? fr_collect(e->renderer) : 0; }
extern "C" void pd_request_original(PDEntry *e, uint32_t requested) {
    if (e) e->requested.store(requested != 0, std::memory_order_relaxed);
}
extern "C" PDCallback pd_callback(PDEntry *e) { return {e, e ? callback : nullptr}; }
extern "C" void pd_destroy(PDEntry *e) {
    if (e) { fr_destroy(e->renderer); delete e; }
}

extern "C" FRResult pd_render(PDEntry *e, const FRInput *input, FROutput *output,
                               uint32_t frames, PDRenderReport *report) {
    PDRenderReport r{};
    if (!e) { if (report) *report = r; return FR_INVALID_ARGUMENT; }
    r.original_requested = e->requested.load(std::memory_order_relaxed);
    const auto result = fr_render(e->renderer, input, output, frames, &r.renderer);
    if (frames && result == FR_OK) {
        const auto &token = r.renderer.audible;
        if (token.assignment != e->identity.assignment || token.source_epoch != e->identity.source_epoch ||
            token.format_epoch != e->identity.format_epoch || !token.assignment) {
            e->measured = 0; e->ready = false; e->mix = 0;
            e->identity = token;
        }
        for (uint32_t frame = 0; frame < frames; ++frame) {
            double dry[FR_MAX_CHANNELS]{}, processed[FR_MAX_CHANNELS]{}, inputEnergy = 0;
            for (uint32_t channel = 0; channel < e->config.channels; ++channel) {
                const auto raw = input->planes[channel][frame];
                dry[channel] = std::isfinite(raw) ? raw : 0;
                if (!std::isfinite(raw)) ++r.invalid_samples;
                const auto value = output->planes[channel][frame];
                processed[channel] = std::isfinite(value) ? value : 0;
                if (!std::isfinite(value)) ++r.invalid_samples;
                inputEnergy += dry[channel] * dry[channel];
            }
            inputEnergy /= e->config.channels;
            if (token.assignment && inputEnergy > 1e-12 && e->measured < uint64_t(std::ceil(e->config.sample_rate * 0.4))) {
                ++e->measured;
            }
            e->ready = token.assignment && e->measured >= uint64_t(std::ceil(e->config.sample_rate * 0.4));
            e->mix = toward(e->mix, r.original_requested && e->ready ? 1 : 0, e->slew);
            double mixed[FR_MAX_CHANNELS]{}, peak = 0;
            for (uint32_t channel = 0; channel < e->config.channels; ++channel) {
                mixed[channel] = processed[channel] * (1 - e->mix) + dry[channel] * e->mix;
                peak = std::max(peak, std::abs(mixed[channel]));
            }
            const double needed = peak > e->config.peak_ceiling ? e->config.peak_ceiling / peak : 1;
            e->safetyGain = needed < e->safetyGain ? needed : 1 - (1 - e->safetyGain) * e->release;
            for (uint32_t channel = 0; channel < e->config.channels; ++channel) {
                const auto value = mixed[channel] * e->safetyGain;
                if (e->safetyGain < 0.999999) ++r.limited_samples;
                output->planes[channel][frame] = float(std::clamp(value, -double(e->config.peak_ceiling), double(e->config.peak_ceiling)));
            }
        }
    }
    r.compare_ready = result == FR_OK && e->ready;
    r.compare_active = result == FR_OK && frames && e->mix > 0;
    r.original_gain = 1;
    r.original_mix = float(e->mix);
    r.measured_frames = e->measured;
    record(*e, result, r);
    if (report) *report = r;
    return result;
}

extern "C" void pd_stats(const PDEntry *e, PDStats *s) {
    if (!s) return;
    *s = {};
    if (!e) return;
    fr_stats(e->renderer, &s->renderer);
    s->callbacks = e->callbacks.load(std::memory_order_relaxed);
    s->errors = e->errors.load(std::memory_order_relaxed);
    s->measured_frames = e->measuredStat.load(std::memory_order_relaxed);
    s->limited_samples = e->limited.load(std::memory_order_relaxed);
    s->invalid_samples = e->invalid.load(std::memory_order_relaxed);
    s->compare_ready = e->readyStat.load(std::memory_order_relaxed);
    s->original_requested = e->requested.load(std::memory_order_relaxed);
    s->original_gain = 1;
    s->original_mix = e->mixStat.load(std::memory_order_relaxed);
    s->adopted = {e->assignment.load(std::memory_order_relaxed), e->source.load(std::memory_order_relaxed),
                  e->format.load(std::memory_order_relaxed), e->topology.load(std::memory_order_relaxed),
                  e->intent.load(std::memory_order_relaxed)};
    s->frame_intent = e->frameIntent.load(std::memory_order_relaxed);
    s->last_result = e->resultStat.load(std::memory_order_relaxed);
    s->native_status = e->nativeStat.load(std::memory_order_relaxed);
}

extern "C" FRResult pd_program_part(FRProgram *p, uint32_t index, uint64_t key, uint32_t kind, uint32_t preset) {
    if (!p || index >= FR_MAX_PARTS) return FR_INVALID_ARGUMENT;
    p->parts[index] = {key, kind, preset};
    p->count = std::max(p->count, index + 1);
    return FR_OK;
}
extern "C" FRResult pd_frame_value(FRFrame *f, uint32_t index, uint64_t key, uint32_t parameter, float value) {
    if (!f || index >= FR_MAX_VALUES) return FR_INVALID_ARGUMENT;
    f->values[index] = {key, parameter, value};
    f->count = std::max(f->count, index + 1);
    return FR_OK;
}
extern "C" FRResult pd_input_plane(FRInput *p, uint32_t channel, const float *samples) {
    if (!p || channel >= FR_MAX_CHANNELS) return FR_INVALID_ARGUMENT;
    p->planes[channel] = samples; return FR_OK;
}
extern "C" FRResult pd_output_plane(FROutput *p, uint32_t channel, float *samples) {
    if (!p || channel >= FR_MAX_CHANNELS) return FR_INVALID_ARGUMENT;
    p->planes[channel] = samples; return FR_OK;
}
