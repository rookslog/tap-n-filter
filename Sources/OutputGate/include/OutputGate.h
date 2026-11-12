#ifndef TNF_OUTPUT_GATE_H
#define TNF_OUTPUT_GATE_H
#include <stdint.h>
#include "ProbeOutput.h"
#include "Visualization.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct OGEntry OGEntry;
typedef struct OGStats {
    uint64_t callbacks, requested_frames, captured_frames, underruns, errors;
    int32_t last_error;
    uint32_t active, disabled;
} OGStats;
OGEntry *og_create(void);
uint32_t og_enter(OGEntry *);
void og_leave(OGEntry *);
void og_disable(OGEntry *);
uint32_t og_is_quiescent(const OGEntry *);
void og_record(OGEntry *, uint32_t requested, uint32_t captured, int32_t error);
void og_stats(const OGEntry *, OGStats *);
void og_destroy(OGEntry *);
#ifdef __cplusplus
}
#endif
#endif
