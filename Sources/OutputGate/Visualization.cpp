#include "Visualization.h"
#include <atomic>
#include <cmath>
#include <cstring>
#include <new>
#include <cassert>
static_assert(std::atomic<uint64_t>::is_always_lock_free);
static_assert(std::atomic<uint32_t>::is_always_lock_free);
struct OGV {
    const double rate; const uint32_t channels, window;
    std::atomic<uint64_t> request{0}, write{0}, read{0}, dropped{0}, event{0}, identityGeneration{1};
    std::atomic<uint32_t> writer{0}, reader{0}, reason{0};
    OGVWindow assembly{}, slots[OGV_SLOTS]{};
    uint32_t fill=0; uint64_t producerRequest=0, sequence=0, frame=0;

    OGV(double r,uint32_t c,uint32_t n):rate(r),channels(c),window(n) {}
};
static bool enter(std::atomic<uint32_t> &flag) { uint32_t zero=0;return flag.compare_exchange_strong(zero,1); }
static bool same(const OGVMeta &a,const OGVMeta &b) {
    return a.assignment==b.assignment && a.source==b.source && a.format==b.format &&
        a.topology==b.topology && a.clock_basis==b.clock_basis;
}
extern "C" OGV *ogv_create(double r,uint32_t c) {
    if (!std::isfinite(r)||r<8000||r>192000||c<1||c>2) return nullptr;
    uint32_t n=512;while(n<4096 && double(n)*1.5<r*.04)n*=2;
    return new(std::nothrow) OGV(r,c,n);
}
extern "C" void ogv_request(OGV *v,uint64_t epoch) { v->request.store(epoch);if(!v->identityGeneration.load())v->request.store(0); }
extern "C" uint64_t ogv_requested(const OGV *v) { return v->request.load(); }
extern "C" void ogv_gap(OGV *v,uint32_t reason) {
    if (!v->request.load()) return;
    v->reason.store(reason);v->event.fetch_add(1);
    // Only the serial render producer mutates assembly, including gaps.
    if (enter(v->writer)) {v->fill=0;v->writer.store(0);}
}
extern "C" void ogv_record(OGV *v,const float *const *b,const float *const *a,
    uint32_t n,const OGVMeta *m,double sample,uint32_t sampleValid) {
    const auto epoch=v->request.load();if(!epoch)return;
    if(!enter(v->writer))return;
    const auto leave=[&]{v->writer.store(0);};
    if(v->request.load()!=epoch){leave();return;}
    if(!v->identityGeneration.load()){v->request.store(0);leave();return;}
    const bool newRequest=v->producerRequest!=epoch;
    const bool identityChanged=!newRequest && m && !same(v->assembly.meta,*m);
    const bool discontinuity=!newRequest && m && m->first_frame!=v->frame;
    if(newRequest||identityChanged||discontinuity) v->fill=0;
    if(newRequest||identityChanged) {
        const auto generation=v->identityGeneration.load();
        if(!generation||generation==UINT64_MAX) {
            v->identityGeneration.store(0);v->reason.store(2);v->event.fetch_add(1);v->request.store(0);leave();return;
        }
        v->identityGeneration.store(generation+1);
    }
    if(identityChanged){v->reason.store(3);v->event.fetch_add(1);}
    if(discontinuity){v->reason.store(1);v->event.fetch_add(1);}
    if(newRequest){v->producerRequest=epoch;v->frame=0;}
    if(!m||!b||!a||!n||n>4096||m->channels!=v->channels||m->rate!=v->rate||
       !m->assignment||!m->source||!m->format) {
        v->fill=0;v->reason.store(2);v->event.fetch_add(1);leave();return;
    }
    bool valid=true;
    for(uint32_t c=0;c<v->channels;++c) {
        if(!b[c]||!a[c]){valid=false;break;}
        for(uint32_t f=0;f<n;++f)if(!std::isfinite(b[c][f])||!std::isfinite(a[c][f]))valid=false;
    }
    if(!valid){v->fill=0;v->reason.store(2);v->event.fetch_add(1);leave();return;}
    if(m->first_frame>UINT64_MAX-n){v->fill=0;v->reason.store(2);v->event.fetch_add(1);leave();return;}
    if(v->fill) {
        auto &meta=v->assembly.meta;
        if(meta.intent!=m->intent||meta.frame_intent!=m->frame_intent)meta.intent_changed=1;
        if(meta.compare_active!=m->compare_active||meta.original_requested!=m->original_requested||meta.original_mix!=m->original_mix)meta.compare_changed=1;
    }
    for(uint32_t f=0;f<n;++f) {
        if(!v->fill) {v->assembly.meta=*m;v->assembly.meta.first_frame=m->first_frame+f;}
        for(uint32_t c=0;c<v->channels;++c){v->assembly.before[c][v->fill]=b[c][f];v->assembly.after[c][v->fill]=a[c][f];}
        ++v->fill;
        v->assembly.meta.last_host_time=m->last_host_time;
        v->assembly.meta.intent=m->intent;v->assembly.meta.frame_intent=m->frame_intent;
        v->assembly.meta.compare_active=m->compare_active;v->assembly.meta.original_requested=m->original_requested;
        v->assembly.meta.transitioning|=m->transitioning;
        v->assembly.meta.original_mix=m->original_mix;v->assembly.meta.original_gain=m->original_gain;
        if(v->fill==v->window) {
            if(v->sequence==UINT64_MAX||v->write.load()==UINT64_MAX){v->fill=0;v->reason.store(2);v->event.fetch_add(1);v->request.store(0);leave();return;}
            auto &meta=v->assembly.meta;meta.request=epoch;meta.sequence=++v->sequence;
            meta.frames=v->window;meta.event=v->event.load();meta.dropped=v->dropped.load();
            meta.identity_generation=v->identityGeneration.load();
            const auto w=v->write.load(std::memory_order_relaxed),rd=v->read.load(std::memory_order_acquire);
            if(w-rd<OGV_SLOTS) {auto &slot=v->slots[w%OGV_SLOTS];slot.meta=meta;
                for(uint32_t c=0;c<v->channels;++c){std::memcpy(slot.before[c],v->assembly.before[c],v->window*sizeof(float));std::memcpy(slot.after[c],v->assembly.after[c],v->window*sizeof(float));}
                v->write.store(w+1,std::memory_order_release);}
            else v->dropped.fetch_add(1);
            v->fill=0;
        }
    }
    v->frame=m->first_frame+n;leave();
}
extern "C" uint32_t ogv_latest(OGV *v,OGVWindow *out) {
    if(!out||!enter(v->reader))return 0;
    const auto w=v->write.load(std::memory_order_acquire),rd=v->read.load(std::memory_order_relaxed);
    if(w==rd){v->reader.store(0);return 0;}
    *out=v->slots[(w-1)%OGV_SLOTS];v->read.store(w,std::memory_order_release);v->reader.store(0);return 1;
}
extern "C" uint64_t ogv_event(const OGV *v){return v->event.load();}
extern "C" uint64_t ogv_identity_generation(const OGV *v){return v->identityGeneration.load();}
extern "C" uint32_t ogv_reason(const OGV *v){return v->reason.load();}
extern "C" uint32_t ogv_scrub_disabled(OGV *v) {
    if(v->request.load()||!enter(v->writer))return 0;
    if(!enter(v->reader)){v->writer.store(0);return 0;}
    if(v->request.load()){v->reader.store(0);v->writer.store(0);return 0;}
    std::memset(&v->assembly,0,sizeof(v->assembly));std::memset(v->slots,0,sizeof(v->slots));
    v->fill=0;v->producerRequest=0;v->write.store(0);v->read.store(0);
    v->reader.store(0);v->writer.store(0);return 1;
}
extern "C" void ogv_destroy(OGV *v) {if(!v)return;assert(!v->request.load()&&!v->writer.load()&&!v->reader.load());delete v;}
extern "C" const float *ogv_before(const OGVWindow *w,uint32_t c){return c<2?w->before[c]:nullptr;}
extern "C" const float *ogv_after(const OGVWindow *w,uint32_t c){return c<2?w->after[c]:nullptr;}
extern "C" uint64_t ogv_storage_bytes(){return sizeof(OGV);}
extern "C" uint32_t ogv_window_frames(const OGV *v){return v->window;}
