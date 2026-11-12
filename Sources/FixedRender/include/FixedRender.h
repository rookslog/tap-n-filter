#ifndef FIXED_RENDER_H
#define FIXED_RENDER_H

#include <stdint.h>
#include "AudioEngineSDKCompatibility.h"

#ifdef __cplusplus
extern "C" {
#endif

enum { FR_MAX_PARTS = 16, FR_MAX_VALUES = 128, FR_MAX_CHANNELS = 2,
       FR_MAX_FRAMES = 4096, FR_RETIRE_CAPACITY = 4, FR_ABI_VERSION = 1 };

typedef enum FRResult {
    FR_OK = 0, FR_INVALID_ARGUMENT, FR_INVALID_FORMAT, FR_INVALID_PROGRAM,
    FR_INVALID_FRAME, FR_STALE_TOKEN, FR_NATIVE_CONTRACT, FR_PREPARATION_FAILED,
    FR_BACKPRESSURE, FR_BUFFER_ERROR, FR_RENDER_ERROR, FR_OUT_OF_MEMORY
} FRResult;

typedef enum FRPartKind {
    FR_DEVICE_EQ = 1, FR_DEVICE_COLOUR = 2, FR_PLACE_EQ = 3,
    FR_REVERB = 4, FR_DYNAMICS = 5, FR_GAIN = 6, FR_SIZED_REVERB = 7
} FRPartKind;

typedef enum FRParameter {
    FR_HP_HZ = 1, FR_LP_HZ = 2, FR_WET_PERCENT = 3, FR_PREGAIN_DB = 4,
    FR_THRESHOLD_DB = 5, FR_HEADROOM_DB = 6, FR_EXPANSION_RATIO = 7,
    FR_EXPANSION_THRESHOLD_DB = 8, FR_ATTACK_SECONDS = 9,
    FR_RELEASE_SECONDS = 10, FR_MAKEUP_DB = 11, FR_GAIN_DB = 12, FR_ROOM_SIZE = 13
} FRParameter;

typedef enum FRCurve { FR_LINEAR = 0, FR_EQUAL_POWER = 1 } FRCurve;

typedef struct FRToken {
    uint64_t assignment, source_epoch, format_epoch, topology, intent;
} FRToken;

typedef struct FRConfig {
    uint32_t abi_version, channels, maximum_frames, transition_frames;
    double sample_rate;
    uint32_t smoothing_frames, parameter_quantum, transition_curve, reserved;
    float peak_ceiling, limiter_release_seconds;
} FRConfig;

typedef struct FRPart {
    uint64_t key;
    uint32_t kind, preset;
} FRPart;

typedef struct FRProgram {
    uint32_t count, reserved;
    FRPart parts[FR_MAX_PARTS];
} FRProgram;

typedef struct FRValue {
    uint64_t key;
    uint32_t parameter;
    float value;
} FRValue;

typedef struct FRFrame {
    FRToken token;
    uint32_t count, reserved;
    FRValue values[FR_MAX_VALUES];
} FRFrame;

typedef struct FRInput {
    const float *planes[FR_MAX_CHANNELS];
    uint32_t channels, capacity_frames;
} FRInput;

typedef struct FROutput {
    float *planes[FR_MAX_CHANNELS];
    uint32_t channels, capacity_frames;
} FROutput;

typedef struct FRRenderReport {
    FRToken audible;
    uint64_t frame_intent;
    uint32_t adopted, transitioning, limited_samples, invalid_samples;
    int32_t native_status;
    uint32_t reserved;
} FRRenderReport;

typedef struct FRStats {
    uint64_t callbacks, adoptions, stale_banks, adoption_backpressure;
    uint64_t native_errors, limited_samples, invalid_samples;
    uint64_t banks_created, banks_disposed, disposal_on_render;
    uint64_t pending_coalesced, frames_consumed;
} FRStats;

typedef struct FRRenderer FRRenderer;
typedef struct FRPrepared FRPrepared;

/* Full units and token rules are in INTERFACE.md. All pointer storage belongs to
   the caller. Create/prepare output handles must initially be null. One control
   publisher owns every renderer call except fr_render. Preparation owns only its
   independent copied inputs and unpublished output. */
FRResult fr_validate(const FRConfig *config, const FRProgram *program,
                     const FRFrame *frame);
FRResult fr_create(const FRConfig *config, FRRenderer **out_renderer);
FRResult fr_set_desired(FRRenderer *renderer, const FRProgram *program,
                       const FRFrame *frame);
FRResult fr_prepare(const FRConfig *config, const FRProgram *program,
                    const FRFrame *initial, FRPrepared **out_bank,
                    int32_t *native_status);
/* Success transfers the bank and clears *bank. Refusal leaves caller ownership. */
FRResult fr_publish(FRRenderer *renderer, FRPrepared **bank,
                    int32_t *native_status);
void fr_prepared_dispose(FRPrepared *bank);
uint32_t fr_collect(FRRenderer *renderer);
/* One serial native render consumer. Buffers are planar, nonoverlapping, and
   valid for the call. Native failure clears that bank's contribution. Queue
   pressure retains the audible bank and increments adoption_backpressure. */
FRResult fr_render(FRRenderer *renderer, const FRInput *input,
                   FROutput *output, uint32_t frames, FRRenderReport *report);
void fr_stats(const FRRenderer *renderer, FRStats *stats);
/* Only after the render consumer and preparation handoff are quiescent. */
void fr_destroy(FRRenderer *renderer);

#ifdef __cplusplus
}
#endif
#endif
