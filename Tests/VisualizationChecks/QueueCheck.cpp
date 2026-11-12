#include "Visualization.h"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <thread>
#include <atomic>
#include <algorithm>
#include <initializer_list>
#ifdef OGV_IDENTITY_EXHAUSTION_CHECK
#include "../../Sources/OutputGate/Visualization.cpp"
#endif
static void record(OGV *v,const float *const *b,const float *const *a,uint32_t n,OGVMeta *m,double sample,uint32_t valid) {
    ogv_record(v,b,a,n,m,sample,valid);m->first_frame+=n;
}
int main(){
    float before[4096],after[4096];for(int i=0;i<4096;++i){before[i]=.25f;after[i]=.125f;}
    const float *b[]={before,before},*a[]={after,after};
    unsigned cases=0;
    for(double rate:{8000.,44100.,48000.,96000.,192000.})for(unsigned quantum:{1u,128u,256u,4096u}) {
        OGV *v=ogv_create(rate,2);assert(v);ogv_request(v,1);OGVMeta m{};
        m.channels=2;m.rate=rate;m.assignment=1;m.source=1;m.format=1;m.topology=1;m.intent=1;
        OGVWindow out{};uint64_t frame=0;unsigned reads=0;
        for(int step=0;step<int(rate/quantum*2);++step){m.last_host_time=frame;record(v,b,a,quantum,&m,double(frame),1);frame+=quantum;
            if(step%std::max(1,int(rate/quantum/20))==0 && ogv_latest(v,&out)){assert(out.meta.frames==ogv_window_frames(v));assert(out.meta.request==1);assert(ogv_before(&out,0)[0]==.25f);++reads;}}
        assert(reads>0);ogv_request(v,0);assert(ogv_scrub_disabled(v));ogv_destroy(v);++cases;
    }
    OGV *v=ogv_create(48000,1);ogv_request(v,3);OGVMeta m{};m.channels=1;m.rate=48000;m.assignment=m.source=m.format=1;
    auto count=ogv_window_frames(v);OGVWindow w{};
    record(v,b,a,count/2,&m,0,1);assert(!ogv_latest(v,&w));
    ogv_gap(v,1);record(v,b,a,count/2,&m,count/2,1);assert(!ogv_latest(v,&w));
    record(v,b,a,count/2,&m,count,1);assert(ogv_latest(v,&w));assert(w.meta.event>0);
    before[0]=NAN;record(v,b,a,count,&m,0,0);assert(ogv_reason(v)==2);assert(!ogv_latest(v,&w));before[0]=0;
    for(int i=0;i<20;++i)record(v,b,a,count,&m,0,0);
    assert(ogv_latest(v,&w));record(v,b,a,count,&m,0,0);assert(ogv_latest(v,&w));assert(w.meta.dropped>0);
    ogv_request(v,0);assert(ogv_scrub_disabled(v));ogv_request(v,4);record(v,b,a,count,&m,0,0);assert(ogv_latest(v,&w)&&w.meta.request==4);
    ogv_request(v,0);assert(ogv_scrub_disabled(v));ogv_request(v,6);
    for(unsigned offset=0;offset<count;offset+=128){m.intent=offset+1;m.frame_intent=offset+1;m.compare_active=offset>=count/2;m.original_requested=m.compare_active;m.original_mix=m.compare_active?.5f:0;
        record(v,b,a,128,&m,double(offset),1);}
    assert(ogv_latest(v,&w)&&w.meta.intent_changed&&w.meta.compare_changed);
    record(v,b,a,count/2,&m,0,0);++m.topology;record(v,b,a,count/2,&m,0,0);assert(!ogv_latest(v,&w));
    record(v,b,a,count/2,&m,0,0);assert(ogv_latest(v,&w)&&w.meta.topology==m.topology);
    ogv_request(v,0);assert(ogv_scrub_disabled(v));ogv_request(v,7);
    record(v,b,a,count/2,&m,0,0);ogv_request(v,8);record(v,b,a,count/2,&m,0,0);assert(!ogv_latest(v,&w));
    record(v,b,a,count/2,&m,0,0);assert(ogv_latest(v,&w)&&w.meta.request==8);
    for(unsigned reason:{1u,2u}) {
      ogv_request(v,0);assert(ogv_scrub_disabled(v));ogv_request(v,10+reason);
      record(v,b,a,count/2,&m,1e12,1);ogv_gap(v,reason);
      record(v,b,a,count/2,&m,-1e12,1);assert(!ogv_latest(v,&w));
      record(v,b,a,count/2,&m,42,1);assert(ogv_latest(v,&w));
    }
    ogv_request(v,0);assert(ogv_scrub_disabled(v));ogv_request(v,20);
    record(v,b,a,count/2,&m,0,0);record(v,b,a,5000,&m,0,0);record(v,b,a,count/2,&m,0,0);assert(!ogv_latest(v,&w));
    record(v,b,a,count/2,&m,0,0);assert(ogv_latest(v,&w));
    const float check=before[1];assert(check==.25f&&after[1]==.125f);
    ogv_request(v,0);assert(ogv_scrub_disabled(v));ogv_destroy(v);
    for(unsigned field:{0u,1u,2u})for(unsigned reason:{1u,2u}) {
      v=ogv_create(48000,1);ogv_request(v,21);m={};m.channels=1;m.rate=48000;
      m.assignment=m.source=m.format=m.topology=1;m.identity_generation=UINT64_MAX;
      count=ogv_window_frames(v);record(v,b,a,count,&m,0,0);assert(ogv_latest(v,&w));
      const auto original=w.meta.identity_generation;assert(original&&original!=m.identity_generation);
      uint64_t *token=field==0?&m.topology:field==1?&m.source:&m.format;
      ++*token;record(v,b,a,count/2,&m,0,0);
      const auto changed=ogv_identity_generation(v);assert(changed>original);
      ogv_gap(v,reason);assert(ogv_reason(v)==reason&&ogv_identity_generation(v)==changed);
      --*token;record(v,b,a,count/2,&m,0,0);
      const auto returned=ogv_identity_generation(v);assert(returned>changed);
      ogv_gap(v,reason);assert(ogv_identity_generation(v)==returned);
      assert(!ogv_latest(v,&w));record(v,b,a,count,&m,0,0);assert(ogv_latest(v,&w));
      assert(w.meta.identity_generation==returned&&w.meta.identity_generation!=original);
      const auto stable=ogv_identity_generation(v);++m.intent;m.compare_active=1;
      record(v,b,a,count,&m,0,0);assert(ogv_latest(v,&w)&&w.meta.identity_generation==stable);
      ogv_request(v,0);assert(ogv_scrub_disabled(v));assert(ogv_identity_generation(v)==stable);
      ogv_request(v,22);record(v,b,a,count,&m,0,0);assert(ogv_latest(v,&w));
      assert(w.meta.identity_generation>stable);
      ogv_request(v,0);assert(ogv_scrub_disabled(v));ogv_destroy(v);
    }
#ifdef OGV_IDENTITY_EXHAUSTION_CHECK
    v=ogv_create(48000,1);ogv_request(v,23);m={};m.channels=1;m.rate=48000;
    m.assignment=m.source=m.format=1;count=ogv_window_frames(v);
    record(v,b,a,count,&m,0,0);assert(ogv_latest(v,&w));
    v->identityGeneration.store(UINT64_MAX-1);
    ++m.topology;record(v,b,a,count,&m,0,0);assert(ogv_latest(v,&w));
    assert(w.meta.identity_generation==UINT64_MAX);
    ++m.topology;record(v,b,a,count,&m,0,0);
    assert(!ogv_identity_generation(v)&&!ogv_requested(v)&&!ogv_latest(v,&w));
    ogv_gap(v,1);ogv_request(v,24);record(v,b,a,count,&m,0,0);
    assert(!ogv_identity_generation(v)&&!ogv_requested(v)&&!ogv_latest(v,&w));
    assert(ogv_scrub_disabled(v));ogv_request(v,25);assert(!ogv_requested(v));ogv_destroy(v);
    puts("PASS checked identity exhaustion at UINT64_MAX; sticky zero refuses record/reopen/scrub revival; test-only direct storage seam, no production override");
#endif
    v=ogv_create(48000,2);ogv_request(v,5);m.channels=2;
    std::atomic<bool> done{false};
    std::thread writer([&]{for(int i=0;i<20000;++i)record(v,b,a,128,&m,double(i)*128,1);done=true;});
    std::thread reader([&]{OGVWindow local{};while(!done.load())if(ogv_latest(v,&local)){assert(local.meta.request==5);assert(ogv_after(&local,1)[1]==.125f);}});
    writer.join();reader.join();ogv_request(v,0);assert(ogv_scrub_disabled(v));ogv_destroy(v);
    assert(!ogv_create(0,1)&&!ogv_create(48000,3));
    printf("PASS %u cadence/rate cases + gap/invalid/full/reopen/input-preservation/concurrent ownership/S12-F01 intent+compare continuity/source resets; persistent topology/source/format A-B-A barriers, caller stamp ignored; storage=%llu bytes\n",cases,(unsigned long long)ogv_storage_bytes());
}
