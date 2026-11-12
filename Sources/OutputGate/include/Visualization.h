#ifndef TNF_VISUALIZATION_H
#define TNF_VISUALIZATION_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
enum { OGV_MAX_FRAMES=4096, OGV_SLOTS=8, OGV_MAX_CHANNELS=2 };
typedef struct OGV OGV;
typedef struct OGVMeta {
    uint64_t request, sequence, assignment, source, format, topology, intent, frame_intent;
    uint64_t first_frame, last_host_time, dropped, event, identity_generation;
    double rate;
    uint32_t channels, frames, clock_basis, compare_active, original_requested, transitioning, intent_changed, compare_changed;
    float original_mix, original_gain;
} OGVMeta;
typedef struct OGVWindow { OGVMeta meta; float before[2][4096], after[2][4096]; } OGVWindow;
OGV *ogv_create(double rate, uint32_t channels);
void ogv_request(OGV *, uint64_t epoch);
uint64_t ogv_requested(const OGV *);
void ogv_record(OGV *, const float *const *before, const float *const *after,
                uint32_t frames, const OGVMeta *, double sample_time, uint32_t sample_time_valid);
void ogv_gap(OGV *, uint32_t reason);
uint32_t ogv_latest(OGV *, OGVWindow *);
uint64_t ogv_event(const OGV *);
uint64_t ogv_identity_generation(const OGV *);
uint32_t ogv_reason(const OGV *);
uint32_t ogv_scrub_disabled(OGV *);
void ogv_destroy(OGV *);
const float *ogv_before(const OGVWindow *, uint32_t channel);
const float *ogv_after(const OGVWindow *, uint32_t channel);
uint64_t ogv_storage_bytes(void);
uint32_t ogv_window_frames(const OGV *);
#ifdef __cplusplus
}
#endif
#endif
