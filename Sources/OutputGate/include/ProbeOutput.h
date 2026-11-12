#ifndef TNF_PROBE_OUTPUT_H
#define TNF_PROBE_OUTPUT_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct OGProbeMeter OGProbeMeter;
typedef struct OGProbeSnapshot {
    uint64_t epoch, callbacks, frames, samples, nonzero_samples, invalid_samples;
    uint64_t invalid_buffers, dropped_callbacks, first_host_time, last_host_time;
    double sample_rate, sum_squares, peak;
    uint32_t channels, complete;
} OGProbeSnapshot;
OGProbeMeter *og_probe_create(uint64_t epoch, double sample_rate, uint32_t channels);
void og_probe_record(OGProbeMeter *, const float *const *planes, uint32_t channels,
                     uint32_t frames, double sample_rate, uint64_t host_time);
void og_probe_retain_observer(OGProbeMeter *);
void og_probe_release_observer(OGProbeMeter *);
void og_probe_close(OGProbeMeter *);
uint32_t og_probe_quiescent(const OGProbeMeter *);
void og_probe_snapshot(const OGProbeMeter *, OGProbeSnapshot *);
void og_probe_destroy(OGProbeMeter *);
#ifdef __cplusplus
}
#endif
#endif
