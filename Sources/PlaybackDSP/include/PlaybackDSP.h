#ifndef PLAYBACK_DSP_H
#define PLAYBACK_DSP_H
#include <FixedRender.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct PDEntry PDEntry;
typedef struct PDRenderReport {
    FRRenderReport renderer;
    uint32_t original_requested, compare_ready, compare_active, reserved;
    float original_gain, original_mix;
    uint64_t measured_frames, limited_samples, invalid_samples;
} PDRenderReport;
typedef struct PDStats {
    FRStats renderer;
    uint64_t callbacks, errors, measured_frames, limited_samples, invalid_samples;
    FRToken adopted;
    uint64_t frame_intent;
    uint32_t compare_ready, original_requested;
    float original_gain, original_mix;
    int32_t last_result, native_status;
} PDStats;
typedef FRResult (*PDRenderFunction)(void *, const FRInput *, FROutput *, uint32_t, PDRenderReport *);
typedef struct PDCallback { void *context; PDRenderFunction render; } PDCallback;

FRResult pd_create(const FRConfig *, PDEntry **);
FRResult pd_set_desired(PDEntry *, const FRProgram *, const FRFrame *);
FRResult pd_prepare(const FRConfig *, const FRProgram *, const FRFrame *, FRPrepared **, int32_t *);
FRResult pd_publish(PDEntry *, FRPrepared **, int32_t *);
void pd_prepared_dispose(FRPrepared *);
uint32_t pd_collect(PDEntry *);
void pd_request_original(PDEntry *, uint32_t);
PDCallback pd_callback(PDEntry *);
FRResult pd_render(PDEntry *, const FRInput *, FROutput *, uint32_t, PDRenderReport *);
void pd_stats(const PDEntry *, PDStats *);
void pd_destroy(PDEntry *);

FRResult pd_program_part(FRProgram *, uint32_t index, uint64_t key, uint32_t kind, uint32_t preset);
FRResult pd_frame_value(FRFrame *, uint32_t index, uint64_t key, uint32_t parameter, float value);
FRResult pd_input_plane(FRInput *, uint32_t channel, const float *);
FRResult pd_output_plane(FROutput *, uint32_t channel, float *);
#ifdef __cplusplus
}
#endif
#endif
