#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioToolbox/AUAudioUnitImplementation.h>
#include <Block.h>
#include <new>
#if FR_TESTING
#include <pthread.h>
#endif
#include "Core.hpp"
#include "ReverbSize.hpp"

using namespace fixedrender;

namespace {

std::atomic<uint64_t> created{0}, disposed{0}, disposedOnRender{0};
#if FR_TESTING
thread_local bool insideRender = false;
void (*prepareHook)(void *) = nullptr;
void *prepareContext = nullptr;
void (*boundaryHook)(void *) = nullptr;
void *boundaryContext = nullptr;
bool failPreparation = false;
std::atomic<uint32_t> metadataSeen[8]{};
std::atomic<uint64_t> lastDisposalThread{0};
#endif

struct NativeFailure { FRResult result; OSStatus status; };

struct Binding {
    AudioUnit unit = nullptr;
    AudioUnitParameterID id = 0;
    AudioUnitScope scope = kAudioUnitScope_Global;
    AudioUnitElement element = 0;
    ParameterRamp ramp{};
    uint32_t source = 0;
    bool sized = false;
    ReverbSizeBinding size{};
    float nativeValue(float value) const noexcept { return sized ? size.seconds(value) : value; }
};

struct PartRuntime {
    uint32_t count = 0;
    Binding bindings[MaxParameters]{};
};

struct PlanarABL {
    UInt32 mNumberBuffers;
    AudioBuffer mBuffers[FR_MAX_CHANNELS];
};

void check(OSStatus status, FRResult result = FR_PREPARATION_FAILED) {
    if (status != noErr) throw NativeFailure{result, status};
}

AudioUnit unitFor(AVAudioNode *node) {
    AUAudioUnit *au = node.AUAudioUnit;
    if (![au isKindOfClass:[AUAudioUnitV2Bridge class]])
        throw NativeFailure{FR_NATIVE_CONTRACT, kAudioUnitErr_InvalidProperty};
    AudioUnit unit = ((AUAudioUnitV2Bridge *)au).audioUnit;
    if (!unit) throw NativeFailure{FR_NATIVE_CONTRACT, kAudioUnitErr_Uninitialized};
    return unit;
}

void connectNodes(AVAudioEngine *engine, AVAudioNode *from, AVAudioNode *to, AVAudioFormat *format) {
    if (@available(macOS 27.0, *)) {
        NSError *error = nil;
        if (![engine connect:from to:to fromBus:0 toBus:0 format:format error:&error]) {
            const auto status = error ? int32_t(error.code) : kAudioUnitErr_FailedInitialization;
            throw NativeFailure{status == kAudioUnitErr_FormatNotSupported ? FR_INVALID_FORMAT :
                                FR_PREPARATION_FAILED, status};
        }
    } else {
        [engine connect:from to:to fromBus:0 toBus:0 format:format];
    }
}

void configureBinding(Binding &b, uint32_t parameter, uint32_t band) {
    switch (parameter) {
        case FR_HP_HZ: case FR_LP_HZ: b.id = kAUNBandEQParam_Frequency + band; break;
        case FR_WET_PERCENT: b.id = kReverbParam_DryWetMix; break;
        case FR_PREGAIN_DB: b.id = kDistortionParam_SoftClipGain; break;
        case FR_THRESHOLD_DB: b.id = kDynamicsProcessorParam_Threshold; break;
        case FR_HEADROOM_DB: b.id = kDynamicsProcessorParam_HeadRoom; break;
        case FR_EXPANSION_RATIO: b.id = kDynamicsProcessorParam_ExpansionRatio; break;
        case FR_EXPANSION_THRESHOLD_DB: b.id = kDynamicsProcessorParam_ExpansionThreshold; break;
        case FR_ATTACK_SECONDS: b.id = kDynamicsProcessorParam_AttackTime; break;
        case FR_RELEASE_SECONDS: b.id = kDynamicsProcessorParam_ReleaseTime; break;
        case FR_MAKEUP_DB: b.id = kDynamicsProcessorParam_OverallGain; break;
        case FR_GAIN_DB:
            b.id = kAUNBandEQParam_GlobalGain;
            break;
    }
}

void checkBindingContract(const Binding &b, uint32_t kind, uint32_t parameter,
                          double sampleRate, bool recordMetadata) {
    AudioUnitParameterInfo info{};
    UInt32 bytes = sizeof(info);
    check(AudioUnitGetProperty(b.unit, kAudioUnitProperty_ParameterInfo,
          b.scope, b.id, &info, &bytes), FR_NATIVE_CONTRACT);
    if (info.flags & kAudioUnitParameterFlag_CFNameRelease) CFRelease(info.cfNameString);
    if (b.sized) {
        ReverbSizeBinding checked;
        if (!ReverbSizeBinding::admit(b.id, info.unit == kAudioUnitParameterUnit_Seconds,
            info.flags & kAudioUnitParameterFlag_IsReadable, info.flags & kAudioUnitParameterFlag_IsWritable,
            info.minValue, info.maxValue, b.size.baseline, checked))
            throw NativeFailure{FR_NATIVE_CONTRACT, kAudioUnitErr_InvalidParameterValue};
        return;
    }
    float low = 0, high = 0;
    if (!valueBounds(parameter, sampleRate, low, high) ||
        !(info.flags & kAudioUnitParameterFlag_IsWritable) ||
        !range(low, info.minValue, info.maxValue) ||
        !range(high, info.minValue, info.maxValue))
        throw NativeFailure{FR_NATIVE_CONTRACT, kAudioUnitErr_InvalidParameterValue};
    bool unitOK = false;
    switch (parameter) {
        case FR_HP_HZ: case FR_LP_HZ: unitOK = info.unit == kAudioUnitParameterUnit_Hertz; break;
        case FR_WET_PERCENT:
            unitOK = info.unit == kAudioUnitParameterUnit_Percent ||
                     ((kind == FR_REVERB || kind == FR_SIZED_REVERB) && info.unit == kAudioUnitParameterUnit_EqualPowerCrossfade);
            break;
        case FR_EXPANSION_RATIO: unitOK = info.unit == kAudioUnitParameterUnit_Rate; break;
        case FR_ATTACK_SECONDS: case FR_RELEASE_SECONDS:
            unitOK = info.unit == kAudioUnitParameterUnit_Seconds; break;
        case FR_GAIN_DB: unitOK = info.unit == kAudioUnitParameterUnit_Decibels; break;
        default: unitOK = info.unit == kAudioUnitParameterUnit_Decibels; break;
    }
    if (!unitOK) throw NativeFailure{FR_NATIVE_CONTRACT, kAudioUnitErr_InvalidParameterValue};
#if FR_TESTING
    if (recordMetadata) {
        const uint32_t bit = 1u << parameter;
        if (!(metadataSeen[kind].fetch_or(bit) & bit))
            std::printf("META kind=%u parameter=%u min=%.9g max=%.9g unit=%u flags=%u\n",
                        kind, parameter, info.minValue, info.maxValue,
                        unsigned(info.unit), unsigned(info.flags));
    }
#else
    (void)recordMetadata;
#endif
}

} // namespace

struct FRPrepared {
    FRConfig config{};
    Snapshot state{};
    uint64_t frameIntent = 0;
    PartRuntime parts[FR_MAX_PARTS]{};
    AVAudioEngine *engine = nil;
    AVAudioEngineManualRenderingBlock renderBlock = nil;
    float input[FR_MAX_CHANNELS][FR_MAX_FRAMES]{};
    float output[FR_MAX_CHANNELS][FR_MAX_FRAMES]{};
    PlanarABL abl{};
    uint32_t sourceFrames = 0;
    uint32_t sourceOffset = 0;
    uint32_t sourceBase = 0;
    int32_t forcedError = 0;
    uint32_t preparationStage = 0;

    FRPrepared() { created.fetch_add(1, std::memory_order_relaxed); }
    ~FRPrepared() {
#if FR_TESTING
        uint64_t thread = 0;
        pthread_threadid_np(nullptr, &thread);
        lastDisposalThread.store(thread, std::memory_order_relaxed);
        if (insideRender) disposedOnRender.fetch_add(1, std::memory_order_relaxed);
#endif
        if (engine) [engine stop];
        if (renderBlock) Block_release(renderBlock);
        [engine release];
        disposed.fetch_add(1, std::memory_order_relaxed);
    }

    OSStatus supply(BOOL *silent, uint32_t n, AudioBufferList *out) noexcept {
        if (!out || n > sourceFrames - std::min(sourceFrames, sourceOffset) ||
            out->mNumberBuffers != config.channels) return kAudio_ParamError;
        bool allZero = true;
        for (uint32_t c = 0; c < config.channels; ++c) {
            auto &b = out->mBuffers[c];
            if (!b.mData || b.mNumberChannels != 1 || b.mDataByteSize < n * sizeof(float))
                return kAudio_ParamError;
            std::memcpy(b.mData, input[c] + sourceBase + sourceOffset, n * sizeof(float));
            b.mDataByteSize = n * sizeof(float);
            for (uint32_t i = 0; i < n; ++i)
                allZero = allZero && input[c][sourceBase + sourceOffset + i] == 0;
        }
        sourceOffset += n;
        *silent = allZero;
        return noErr;
    }

    void build(const FRConfig &c, const Snapshot &s) {
        config = c;
        state = s;
        frameIntent = s.token.intent;
        preparationStage = 1;
        engine = [AVAudioEngine new];
        if (!engine) throw std::bad_alloc();
        AVAudioFormat *format = [[[AVAudioFormat alloc]
            initStandardFormatWithSampleRate:c.sample_rate channels:c.channels] autorelease];
        NSError *error = nil;
        preparationStage = 2;
        if (!format || ![engine enableManualRenderingMode:AVAudioEngineManualRenderingModeRealtime
                     format:format maximumFrameCount:c.maximum_frames error:&error])
            throw NativeFailure{FR_PREPARATION_FAILED, error ? int32_t(error.code) : kAudio_ParamError};
        FRPrepared *bank = this;
        preparationStage = 3;
        AVAudioSourceNode *source = [[[AVAudioSourceNode alloc] initWithFormat:format
            renderBlock:^OSStatus(BOOL *silent, const AudioTimeStamp *, AVAudioFrameCount n,
                                  AudioBufferList *buffers) {
                return bank->supply(silent, n, buffers);
            }] autorelease];
        [engine attachNode:source];
        AVAudioNode *last = source;
        for (uint32_t i = 0; i < s.count; ++i) {
            preparationStage = 100 + i;
            const auto &part = s.parts[i];
            AVAudioNode *node = nil;
            switch (part.spec.kind) {
                case FR_DEVICE_EQ: case FR_PLACE_EQ: {
                    auto *eq = [[[AVAudioUnitEQ alloc] initWithNumberOfBands:part.count] autorelease];
                    for (uint32_t j = 0; j < part.count; ++j) {
                        AVAudioUnitEQFilterParameters *band = eq.bands[j];
                        band.filterType = part.ids[j] == FR_HP_HZ ?
                            AVAudioUnitEQFilterTypeHighPass : AVAudioUnitEQFilterTypeLowPass;
                        band.frequency = part.values[j];
                        band.bypass = NO;
                    }
                    eq.globalGain = 0;
                    node = eq;
                    break;
                }
                case FR_DEVICE_COLOUR: {
                    auto *colour = [[[AVAudioUnitDistortion alloc] init] autorelease];
                    [colour loadFactoryPreset:part.spec.preset == 1 ?
                        AVAudioUnitDistortionPresetSpeechRadioTower : AVAudioUnitDistortionPresetSpeechGoldenPi];
                    node = colour;
                    break;
                }
                case FR_REVERB: case FR_SIZED_REVERB: {
                    auto *reverb = [[[AVAudioUnitReverb alloc] init] autorelease];
                    if (part.spec.kind == FR_SIZED_REVERB) {
                        switch (part.spec.preset) {
                            case 1: [reverb loadFactoryPreset:AVAudioUnitReverbPresetSmallRoom]; break;
                            case 2: [reverb loadFactoryPreset:AVAudioUnitReverbPresetMediumRoom]; break;
                            case 3: [reverb loadFactoryPreset:AVAudioUnitReverbPresetLargeRoom]; break;
                            default: throw NativeFailure{FR_NATIVE_CONTRACT, kAudioUnitErr_InvalidParameterValue};
                        }
                    } else { [reverb loadFactoryPreset:AVAudioUnitReverbPreset(part.spec.preset - 1)]; }
                    node = reverb;
                    break;
                }
                case FR_DYNAMICS: {
                    AudioComponentDescription description{kAudioUnitType_Effect,
                        kAudioUnitSubType_DynamicsProcessor, kAudioUnitManufacturer_Apple, 0, 0};
                    node = [[[AVAudioUnitEffect alloc] initWithAudioComponentDescription:description] autorelease];
                    break;
                }
                case FR_GAIN: {
                    auto *gain = [[[AVAudioUnitEQ alloc] initWithNumberOfBands:1] autorelease];
                    gain.bands[0].bypass = YES;
                    node = gain;
                    break;
                }
            }
            if (!node) throw NativeFailure{FR_PREPARATION_FAILED, kAudioUnitErr_FailedInitialization};
            [engine attachNode:node];
            connectNodes(engine, last, node, format);
            const auto unit = unitFor(node);
            preparationStage = 200 + i;
            auto &runtime = parts[i];
            if (part.spec.kind == FR_SIZED_REVERB) {
                AudioComponentDescription description{};
                check(AudioComponentGetDescription(AudioComponentInstanceGetComponent(unit), &description), FR_NATIVE_CONTRACT);
                if (description.componentType != kAudioUnitType_Effect ||
                    description.componentSubType != kAudioUnitSubType_MatrixReverb ||
                    description.componentManufacturer != kAudioUnitManufacturer_Apple)
                    throw NativeFailure{FR_NATIVE_CONTRACT, kAudioUnitErr_InvalidProperty};
            }
            for (uint32_t j = 0; j < part.count; ++j) {
                const uint32_t copies = part.ids[j] == FR_ROOM_SIZE ? 2 : 1;
                for (uint32_t copy = 0; copy < copies; ++copy) {
                    auto &b = runtime.bindings[runtime.count++];
                    b.unit = unit;
                    b.source = j;
                    if (part.ids[j] == FR_ROOM_SIZE) {
                        b.sized = true;
                        b.id = copy == 0 ? kReverbParam_SmallSize : kReverbParam_LargeSize;
                        float baseline = 0;
                        check(AudioUnitGetParameter(unit, b.id, b.scope, b.element, &baseline), FR_NATIVE_CONTRACT);
                        b.size.baseline = baseline;
                        checkBindingContract(b, part.spec.kind, part.ids[j], c.sample_rate, false);
                        AudioUnitParameterInfo info{};
                        UInt32 bytes = sizeof(info);
                        check(AudioUnitGetProperty(unit, kAudioUnitProperty_ParameterInfo, b.scope, b.id, &info, &bytes), FR_NATIVE_CONTRACT);
                        if (info.flags & kAudioUnitParameterFlag_CFNameRelease) CFRelease(info.cfNameString);
                        if (!ReverbSizeBinding::admit(b.id, info.unit == kAudioUnitParameterUnit_Seconds,
                            info.flags & kAudioUnitParameterFlag_IsReadable, info.flags & kAudioUnitParameterFlag_IsWritable,
                            info.minValue, info.maxValue, baseline, b.size))
                            throw NativeFailure{FR_NATIVE_CONTRACT, kAudioUnitErr_InvalidParameterValue};
                    } else {
                        configureBinding(b, part.ids[j], j);
                        if (part.spec.kind == FR_DEVICE_COLOUR && part.ids[j] == FR_WET_PERCENT)
                            b.id = kDistortionParam_FinalMix;
                        checkBindingContract(b, part.spec.kind, part.ids[j], c.sample_rate, false);
                    }
                    const float value = b.nativeValue(part.values[j]);
                    b.ramp.current = b.ramp.target = value;
                    if (!b.sized) check(AudioUnitSetParameter(unit, b.id, b.scope, b.element, value, 0));
                }
            }
            last = node;
        }
        AVAudioMixerNode *main = engine.mainMixerNode;
        preparationStage = 4;
        main.outputVolume = 1;
        connectNodes(engine, last, main, format);
#if FR_TESTING
        if (prepareHook) prepareHook(prepareContext);
        if (failPreparation) throw NativeFailure{FR_PREPARATION_FAILED, kAudioUnitErr_FailedInitialization};
#endif
        [engine prepare];
        preparationStage = 5;
        if (![engine startAndReturnError:&error])
            throw NativeFailure{FR_PREPARATION_FAILED, error ? int32_t(error.code) : kAudioUnitErr_FailedInitialization};
        for (uint32_t i = 0; i < state.count; ++i) {
            const auto &part = state.parts[i];
            for (uint32_t j = 0; j < parts[i].count; ++j) {
                auto &b = parts[i].bindings[j];
                if (b.sized) {
                    float baseline = 0;
                    check(AudioUnitGetParameter(b.unit, b.id, b.scope, b.element, &baseline), FR_NATIVE_CONTRACT);
                    b.size.baseline = baseline;
                    b.ramp.current = b.ramp.target = b.nativeValue(part.values[b.source]);
                }
                checkBindingContract(b, part.spec.kind, part.ids[b.source], c.sample_rate, true);
                check(AudioUnitSetParameter(b.unit, b.id, b.scope, b.element, b.ramp.current, 0));
            }
        }
        renderBlock = Block_copy(engine.manualRenderingBlock);
        preparationStage = 6;
        if (!renderBlock) throw NativeFailure{FR_PREPARATION_FAILED, kAudioUnitErr_Uninitialized};
        for (uint32_t i = 0; i < 2; ++i) check(run(c.maximum_frames));
    }

    void reconcile(const Snapshot &desired) noexcept {
        if (!sameIdentity(state.token, desired.token)) return;
        bool matched = state.count == 0 && desired.count == 0;
        for (uint32_t i = 0; i < state.count; ++i) {
            for (uint32_t j = 0; j < desired.count; ++j) {
                if (!samePart(state.parts[i].spec, desired.parts[j].spec)) continue;
                matched = true;
                auto &part = state.parts[i];
                bool changed = false;
                for (uint32_t k = 0; k < part.count; ++k) part.values[k] = desired.parts[j].values[k];
                for (uint32_t k = 0; k < parts[i].count; ++k) {
                    auto &b = parts[i].bindings[k];
                    const float target = b.nativeValue(desired.parts[j].values[b.source]);
                    if (target != b.ramp.target) changed = true;
                    b.ramp.retarget(target, config.smoothing_frames);
                }
                if (changed && part.spec.kind == FR_DEVICE_EQ)
                    for (uint32_t k = 0; k < part.count; ++k)
                        parts[i].bindings[k].ramp.remaining = config.smoothing_frames;
                break;
            }
        }
        if (matched) frameIntent = desired.token.intent;
        if (sameTopology(state.token, desired.token)) state.token.intent = desired.token.intent;
    }

    void applyInitial() {
        for (uint32_t i = 0; i < state.count; ++i) {
            for (uint32_t j = 0; j < parts[i].count; ++j) {
                auto &b = parts[i].bindings[j];
                b.ramp.current = b.ramp.target;
                b.ramp.remaining = 0;
                check(AudioUnitSetParameter(b.unit, b.id, b.scope, b.element, b.ramp.current, 0));
            }
        }
    }

    OSStatus advance(uint32_t n) noexcept {
        for (uint32_t i = 0; i < state.count; ++i) {
            for (uint32_t j = 0; j < parts[i].count; ++j) {
                auto &b = parts[i].bindings[j];
                if (!b.ramp.advance(n)) continue;
                const auto error = AudioUnitSetParameter(b.unit, b.id, b.scope, b.element, b.ramp.current, 0);
                if (error) return error;
            }
        }
        return noErr;
    }

    OSStatus run(uint32_t n) noexcept {
        for (uint32_t c = 0; c < config.channels; ++c) std::memset(output[c], 0, n * sizeof(float));
        if (forcedError) return forcedError;
        for (uint32_t offset = 0; offset < n;) {
            const auto count = std::min(config.parameter_quantum, n - offset);
            const auto setError = advance(count);
            if (setError) return clearOutput(n, setError);
            sourceFrames = count;
            sourceOffset = 0;
            sourceBase = offset;
            abl.mNumberBuffers = config.channels;
            for (uint32_t c = 0; c < config.channels; ++c)
                abl.mBuffers[c] = {1, count * UInt32(sizeof(float)), output[c] + offset};
            OSStatus error = noErr;
            const auto status = renderBlock(count, reinterpret_cast<AudioBufferList *>(&abl), &error);
            if (status != AVAudioEngineManualRenderingStatusSuccess)
                return clearOutput(n, error ? error : -81000 - int32_t(status));
            if (abl.mNumberBuffers != config.channels) return clearOutput(n, kAudio_ParamError);
            for (uint32_t c = 0; c < config.channels; ++c) {
                const auto &b = abl.mBuffers[c];
                if (!b.mData || b.mNumberChannels != 1 || b.mDataByteSize != count * sizeof(float))
                    return clearOutput(n, kAudio_ParamError);
                if (b.mData != output[c] + offset)
                    std::memmove(output[c] + offset, b.mData, count * sizeof(float));
            }
            offset += count;
        }
        return noErr;
    }

    OSStatus clearOutput(uint32_t n, OSStatus error) noexcept {
        for (uint32_t c = 0; c < config.channels; ++c) std::memset(output[c], 0, n * sizeof(float));
        return error;
    }
};

struct FRRenderer {
    FRConfig config;
    Snapshot latest{}, audibleDesired{};
    bool hasDesired = false, hasAudibleDesired = false;
    FrameMailbox frames;
    std::atomic<FRPrepared *> pending{nullptr};
    RetireQueue<FRPrepared *, FR_RETIRE_CAPACITY> retired;
    FRPrepared *current = nullptr, *fading = nullptr;
    uint32_t transitionAt = 0;
    float limiterGain = 1, limiterRelease = 0;
    std::atomic<uint64_t> callbacks{0}, adoptions{0}, stale{0}, backpressure{0};
    std::atomic<uint64_t> nativeErrors{0}, limited{0}, invalid{0}, coalesced{0}, consumed{0};

    explicit FRRenderer(const FRConfig &c) : config(c) {
        limiterRelease = std::exp(-1.0 / (c.sample_rate * c.limiter_release_seconds));
    }

    void retireIncompatible(FRPrepared *&bank) noexcept {
        if (bank && !sameIdentity(bank->state.token, audibleDesired.token) && retired.push(bank))
            bank = nullptr;
    }

    void boundary(FRRenderReport &report) noexcept {
        Snapshot received;
        if (frames.consume(received)) {
            if (!hasAudibleDesired || received.token.intent > audibleDesired.token.intent)
                audibleDesired = received;
            hasAudibleDesired = true;
            consumed.fetch_add(1, std::memory_order_relaxed);
        }
#if FR_TESTING
        if (boundaryHook) boundaryHook(boundaryContext);
#endif
        if (!hasAudibleDesired) return;
        retireIncompatible(fading);
        retireIncompatible(current);
        if (current) current->reconcile(audibleDesired);
        if (fading) fading->reconcile(audibleDesired);
        if (fading || (current && transitionAt < config.transition_frames) ||
            !pending.load(std::memory_order_acquire)) return;
        if (!retired.hasSpace()) {
            backpressure.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        auto *bank = pending.exchange(nullptr, std::memory_order_acq_rel);
        if (!bank) return;
        // The bank and frame mailboxes can be observed on opposite sides of a publish.
        if (bank->state.token.intent > audibleDesired.token.intent) {
            audibleDesired = bank->state;
            retireIncompatible(current);
        }
        if (!sameTopology(bank->state.token, audibleDesired.token) ||
            !sameSchedule(bank->state, audibleDesired)) {
            retired.push(bank);
            stale.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        bank->reconcile(audibleDesired);
        fading = current;
        current = bank;
        transitionAt = 0;
        adoptions.fetch_add(1, std::memory_order_relaxed);
        report.adopted = 1;
    }
};

extern "C" FRResult fr_validate(const FRConfig *c, const FRProgram *p, const FRFrame *f) {
    if (!c || !p || !f) return FR_INVALID_ARGUMENT;
    Snapshot decoded;
    return decode(*c, *p, *f, decoded);
}

extern "C" FRResult fr_create(const FRConfig *c, FRRenderer **out) {
    if (!c || !out || *out) return FR_INVALID_ARGUMENT;
    const auto result = validateConfig(*c);
    if (result != FR_OK) return result;
    *out = new (std::nothrow) FRRenderer(*c);
    return *out ? FR_OK : FR_OUT_OF_MEMORY;
}

extern "C" FRResult fr_set_desired(FRRenderer *r, const FRProgram *p, const FRFrame *f) {
    if (!r || !p || !f) return FR_INVALID_ARGUMENT;
    Snapshot next;
    const auto result = decode(r->config, *p, *f, next);
    if (result != FR_OK) return result;
    if (r->hasDesired) {
        const auto &old = r->latest.token;
        const auto &t = next.token;
        if (t.assignment != old.assignment || t.source_epoch < old.source_epoch ||
            t.format_epoch < old.format_epoch || t.topology < old.topology || t.intent <= old.intent)
            return FR_STALE_TOKEN;
        if (t.topology == old.topology &&
            (!sameIdentity(t, old) || !sameSchedule(next, r->latest))) return FR_STALE_TOKEN;
    }
    r->latest = next;
    r->hasDesired = true;
    r->frames.publish(next);
    return FR_OK;
}

extern "C" FRResult fr_prepare(const FRConfig *c, const FRProgram *p, const FRFrame *f,
                                FRPrepared **out, int32_t *nativeStatus) {
    if (nativeStatus) *nativeStatus = 0;
    if (!c || !p || !f || !out || *out) return FR_INVALID_ARGUMENT;
    Snapshot initial;
    auto result = decode(*c, *p, *f, initial);
    if (result != FR_OK) return result;
    @autoreleasepool {
        auto *bank = new (std::nothrow) FRPrepared;
        if (!bank) return FR_OUT_OF_MEMORY;
        @try {
            try {
                bank->build(*c, initial);
                *out = bank;
                return FR_OK;
            } catch (const NativeFailure &failure) {
                result = failure.result;
                if (nativeStatus) *nativeStatus = failure.status;
            } catch (const std::bad_alloc &) { result = FR_OUT_OF_MEMORY; }
        } @catch (NSException *exception) {
            result = FR_PREPARATION_FAILED;
            if (nativeStatus) *nativeStatus = kAudioUnitErr_FailedInitialization;
#if FR_TESTING
            std::fprintf(stderr, "preparation exception stage=%u %s: %s\n", bank->preparationStage,
                         exception.name.UTF8String, exception.reason.UTF8String);
#endif
        }
        delete bank;
    }
    return result;
}

extern "C" FRResult fr_publish(FRRenderer *r, FRPrepared **bank, int32_t *nativeStatus) {
    if (nativeStatus) *nativeStatus = 0;
    if (!r || !bank || !*bank) return FR_INVALID_ARGUMENT;
    auto *b = *bank;
    if (!sameConfig(r->config, b->config)) return FR_INVALID_FORMAT;
    if (!r->hasDesired || !sameTopology(r->latest.token, b->state.token) ||
        !sameSchedule(r->latest, b->state) || b->state.token.intent > r->latest.token.intent)
        return FR_STALE_TOKEN;
    try {
        b->reconcile(r->latest);
        b->applyInitial();
    } catch (const NativeFailure &failure) {
        if (nativeStatus) *nativeStatus = failure.status;
        return failure.result;
    }
    auto *superseded = r->pending.exchange(b, std::memory_order_acq_rel);
    *bank = nullptr;
    if (superseded) {
        r->coalesced.fetch_add(1, std::memory_order_relaxed);
        fr_prepared_dispose(superseded);
    }
    return FR_OK;
}

extern "C" void fr_prepared_dispose(FRPrepared *bank) {
    @autoreleasepool { delete bank; }
}

extern "C" uint32_t fr_collect(FRRenderer *r) {
    if (!r) return 0;
    uint32_t count = 0;
    for (; count < FR_RETIRE_CAPACITY; ++count) {
        auto *bank = r->retired.pop();
        if (!bank) break;
        fr_prepared_dispose(bank);
    }
    return count;
}

namespace {

void clearWritable(const FRRenderer *r, FROutput *output, uint32_t n) {
    if (!output) return;
    const auto channels = std::min(output->channels, uint32_t(FR_MAX_CHANNELS));
    const auto count = std::min({n, output->capacity_frames,
                                r ? r->config.maximum_frames : uint32_t(FR_MAX_FRAMES)});
    for (uint32_t c = 0; c < channels; ++c)
        if (output->planes[c]) std::memset(output->planes[c], 0, count * sizeof(float));
}

bool overlaps(const float *a, const float *b, uint32_t frames) {
    const auto aa = reinterpret_cast<uintptr_t>(a), bb = reinterpret_cast<uintptr_t>(b);
    const auto bytes = uintptr_t(frames) * sizeof(float);
    return aa <= bb ? bb - aa < bytes : aa - bb < bytes;
}

FRResult validateBuffers(const FRRenderer *r, const FRInput *in, const FROutput *out, uint32_t n) {
    if (!r || !in || !out) return FR_INVALID_ARGUMENT;
    if (n > r->config.maximum_frames || in->channels != r->config.channels ||
        out->channels != r->config.channels || in->capacity_frames < n || out->capacity_frames < n)
        return FR_BUFFER_ERROR;
    for (uint32_t c = 0; c < r->config.channels; ++c) {
        if (!in->planes[c] || !out->planes[c]) return FR_BUFFER_ERROR;
        for (uint32_t j = 0; j < r->config.channels; ++j)
            if (overlaps(in->planes[c], out->planes[j], n)) return FR_BUFFER_ERROR;
        for (uint32_t j = 0; j < c; ++j)
            if (overlaps(out->planes[c], out->planes[j], n)) return FR_BUFFER_ERROR;
    }
    return FR_OK;
}

} // namespace

extern "C" FRResult fr_render(FRRenderer *r, const FRInput *in, FROutput *out,
                               uint32_t n, FRRenderReport *callerReport) {
    FRRenderReport report{};
    if (callerReport) *callerReport = report;
    const auto result = validateBuffers(r, in, out, n);
    if (result != FR_OK) { clearWritable(r, out, n); return result; }
    if (!n) return FR_OK;
#if FR_TESTING
    insideRender = true;
#endif
    r->callbacks.fetch_add(1, std::memory_order_relaxed);
    r->boundary(report);
    auto *current = r->current;
    auto *old = r->fading;
    const bool active = current && sameIdentity(current->state.token, r->audibleDesired.token);
    const bool oldActive = old && sameIdentity(old->state.token, r->audibleDesired.token);
    for (uint32_t c = 0; c < r->config.channels; ++c) {
        for (uint32_t i = 0; i < n; ++i) {
            float value = in->planes[c][i];
            if (!std::isfinite(value)) { value = 0; ++report.invalid_samples; }
            if (active) current->input[c][i] = value;
            if (oldActive) old->input[c][i] = value;
        }
    }
    if (active) {
        report.audible = current->state.token;
        report.frame_intent = current->frameIntent;
        report.native_status = current->run(n);
    }
    if (oldActive) {
        const auto error = old->run(n);
        if (!report.native_status) report.native_status = error;
    }
    report.transitioning = active && r->transitionAt < r->config.transition_frames;
    for (uint32_t i = 0; i < n; ++i) {
        const float progress = std::min(1.0f, float(r->transitionAt + i + 1) /
                                                float(r->config.transition_frames));
        float newWeight = progress, oldWeight = 1 - progress;
        if (r->config.transition_curve == FR_EQUAL_POWER) {
            newWeight = std::sin(progress * float(M_PI_2));
            oldWeight = std::cos(progress * float(M_PI_2));
        }
        if (progress == 1) { newWeight = 1; oldWeight = 0; }
        float samples[FR_MAX_CHANNELS]{};
        float peak = 0;
        for (uint32_t c = 0; c < r->config.channels; ++c) {
            const float a = active ? current->output[c][i] : 0;
            const float b = oldActive ? old->output[c][i] : 0;
            float sample = a * newWeight + b * oldWeight;
            if (!std::isfinite(sample)) { sample = 0; ++report.invalid_samples; }
            samples[c] = sample;
            peak = std::max(peak, std::abs(sample));
        }
        const float required = peak > r->config.peak_ceiling ? r->config.peak_ceiling / peak : 1;
        if (required < r->limiterGain) r->limiterGain = required;
        else r->limiterGain = required + r->limiterRelease * (r->limiterGain - required);
        for (uint32_t c = 0; c < r->config.channels; ++c) {
            if (r->limiterGain < 1) ++report.limited_samples;
            out->planes[c][i] = std::clamp(samples[c] * r->limiterGain,
                                         -r->config.peak_ceiling, r->config.peak_ceiling);
        }
    }
    if (active) r->transitionAt = std::min(r->config.transition_frames, r->transitionAt + n);
    if (old && r->transitionAt >= r->config.transition_frames && r->retired.push(old)) r->fading = nullptr;
    if (report.native_status) r->nativeErrors.fetch_add(1, std::memory_order_relaxed);
    r->invalid.fetch_add(report.invalid_samples, std::memory_order_relaxed);
    r->limited.fetch_add(report.limited_samples, std::memory_order_relaxed);
    if (callerReport) *callerReport = report;
#if FR_TESTING
    insideRender = false;
#endif
    return report.native_status ? FR_RENDER_ERROR : FR_OK;
}

extern "C" void fr_stats(const FRRenderer *r, FRStats *stats) {
    if (!stats) return;
    *stats = {};
    if (!r) return;
    stats->callbacks = r->callbacks.load(std::memory_order_relaxed);
    stats->adoptions = r->adoptions.load(std::memory_order_relaxed);
    stats->stale_banks = r->stale.load(std::memory_order_relaxed);
    stats->adoption_backpressure = r->backpressure.load(std::memory_order_relaxed);
    stats->native_errors = r->nativeErrors.load(std::memory_order_relaxed);
    stats->limited_samples = r->limited.load(std::memory_order_relaxed);
    stats->invalid_samples = r->invalid.load(std::memory_order_relaxed);
    stats->pending_coalesced = r->coalesced.load(std::memory_order_relaxed);
    stats->frames_consumed = r->consumed.load(std::memory_order_relaxed);
    stats->banks_created = created.load(std::memory_order_relaxed);
    stats->banks_disposed = disposed.load(std::memory_order_relaxed);
    stats->disposal_on_render = disposedOnRender.load(std::memory_order_relaxed);
}

extern "C" void fr_destroy(FRRenderer *r) {
    if (!r) return;
    fr_prepared_dispose(r->pending.exchange(nullptr));
    fr_prepared_dispose(r->current);
    fr_prepared_dispose(r->fading);
    fr_collect(r);
    delete r;
}

#if FR_TESTING
extern "C" void fr_test_prepare_hook(void (*hook)(void *), void *context) {
    prepareHook = hook;
    prepareContext = context;
}
extern "C" void fr_test_boundary_hook(void (*hook)(void *), void *context) {
    boundaryHook = hook;
    boundaryContext = context;
}
extern "C" void fr_test_prepare_failure(uint32_t fail) { failPreparation = fail; }
extern "C" uint64_t fr_test_disposal_thread() { return lastDisposalThread.load(); }
extern "C" void fr_test_render_error(FRRenderer *r, int32_t error) {
    if (r->current) r->current->forcedError = error;
}
extern "C" float fr_test_target(FRRenderer *r, uint64_t key, uint32_t id, uint32_t old) {
    auto *bank = old ? r->fading : r->current;
    if (bank) for (uint32_t i = 0; i < bank->state.count; ++i)
        if (bank->state.parts[i].spec.key == key)
            for (uint32_t j = 0; j < bank->state.parts[i].count; ++j)
                if (bank->state.parts[i].ids[j] == id) return bank->state.parts[i].values[j];
    return NAN;
}
#endif
