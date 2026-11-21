#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
int engine_catalog_contract_check(void);
/// Presence-mask and preset refusals not covered by the contract check. 0 on pass, else a line number.
int engine_catalog_abi_refusal_check(void);
/// One flattened native target from the compiled C++ effect contracts, in table order.
typedef struct EngineCatalogNativeRow {
    uint32_t kind, parameter, optional, conversion, target, scope, element, units, readable, writable;
    float logicalLower, logicalUpper, lower, upper;
} EngineCatalogNativeRow;
/// Fills `row` and returns 1 while `index` is inside the table, otherwise returns 0.
int engine_catalog_native_row(uint32_t index, EngineCatalogNativeRow *row);
/// Compiled per-effect masks and presets, in table order. Returns 0 past the end.
typedef struct EngineCatalogEffectRow {
    uint32_t kind, componentType, componentSubtype, manufacturer, requiredMask, allowedMask, presetCount, presets[8];
} EngineCatalogEffectRow;
int engine_catalog_effect_row(uint32_t index, EngineCatalogEffectRow *row);
#ifdef __cplusplus
}
#endif
