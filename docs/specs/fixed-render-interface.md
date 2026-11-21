# Fixed renderer ABI 2

The public ABI is declared in `Sources/FixedRender/include/FixedRender.h`. All callers rebuild together when the ABI version changes. ABI 2 is a structural change from ABI 1, not a claim of identical C struct bytes.

## Parameter presence

`FRPart.parameter_mask` declares every active logical parameter before frame admission or native preparation. Bit `id` represents logical parameter ID `id`. `FR_PARAMETER_BIT(id)` produces that bit. Bit 0 and all unknown bits are invalid. Required parameters must be present. Optional parameters are active only when their bit is set. `FRPart.reserved` must be zero.

Each active parameter has exactly one finite frame value for the same part key. Missing, duplicate, inactive, or unknown frame values refuse. Values are never inferred from an absent frame. Each program part's preset must occur in its generated effect contract, or be zero for an effect with no presets.

The mask participates in topology equality and the Swift mapper's topology signature. Changing parameter presence requires a new topology generation. Kind 7 is reserved and refuses. Legacy sized content lowers to kind 4 with both wet and room-size bits. Wet-only kind 4 carries only the wet bit.

`pd_program_part` now takes the mask explicitly. The mapper and all local callers use ABI 2. ABI 1 config values refuse rather than being interpreted under the new layout.

## Control and render ownership

One control publisher owns renderer calls other than `fr_render`. Input pointer storage remains caller-owned. A prepared bank remains caller-owned until `fr_publish` succeeds and clears its pointer. Refusal leaves the caller responsible for disposal. Preparation owns independent copied inputs and unpublished resources.

The render callback consumes fixed snapshots, prepared banks, resolved native IDs, and ramps. Capacity, source and format epochs, increasing intents, topology tokens, mailbox coalescing, retire-queue backpressure, transitions, and quiescent destruction retain their prior rules. No bank destruction occurs on the render callback. The control publisher drains retired banks with `fr_collect`.

Native preparation rejects an expanded target count above its fixed binding capacity. Optional size expands one logical value to two resolved native bindings without increasing logical frame capacity. All ramp lengths continue to use `FRConfig.smoothing_frames`.
