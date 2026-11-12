#include "PlaybackDSP.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <limits>

// Deterministic fake FR only. Real pd_render still owns readiness, blend and safety.
struct FRRenderer { FRConfig config; FRToken token{}; float gain=1; };
struct FRPrepared {};
static float fakeGain=0.25f;
static bool fakeError=false;
extern "C" FRResult fr_create(const FRConfig *c,FRRenderer **out){*out=new FRRenderer{*c,{},fakeGain};return FR_OK;}
extern "C" FRResult fr_set_desired(FRRenderer *r,const FRProgram *,const FRFrame *f){r->token=f->token;return FR_OK;}
extern "C" FRResult fr_prepare(const FRConfig *,const FRProgram *,const FRFrame *,FRPrepared **,int32_t *){return FR_PREPARATION_FAILED;}
extern "C" FRResult fr_publish(FRRenderer *,FRPrepared **,int32_t *){return FR_PREPARATION_FAILED;}
extern "C" void fr_prepared_dispose(FRPrepared *){}
extern "C" uint32_t fr_collect(FRRenderer *){return 0;}
extern "C" void fr_stats(const FRRenderer *,FRStats *s){*s={};}
extern "C" void fr_destroy(FRRenderer *r){delete r;}
extern "C" FRResult fr_render(FRRenderer *r,const FRInput *in,FROutput *out,uint32_t frames,FRRenderReport *report){
  *report={};report->audible=r->token;report->frame_intent=r->token.intent;
  for(unsigned c=0;c<r->config.channels;++c)for(unsigned i=0;i<frames;++i)out->planes[c][i]=fakeError?0:in->planes[c][i]*r->gain;
  return fakeError?FR_RENDER_ERROR:FR_OK;
}
static unsigned failures=0,checks=0;
static void expect(bool value,const char *message){++checks;if(!value){++failures;printf("FAIL %s\n",message);}}
struct Fixture {
  PDEntry *entry=nullptr;
  FRFrame frame{};
  float input[2][1024]{},output[2][1024]{};
  PDRenderReport report{};
  Fixture(float gain){
    fakeGain=gain;fakeError=false;FRConfig c{};c.abi_version=FR_ABI_VERSION;c.channels=2;c.maximum_frames=1024;c.sample_rate=48000;c.peak_ceiling=.9f;c.limiter_release_seconds=.05f;
    expect(pd_create(&c,&entry)==FR_OK,"PD create");frame.token={1,1,1,1,1};FRProgram p{};pd_set_desired(entry,&p,&frame);
    setInput(.2f);
  }
  ~Fixture(){pd_destroy(entry);}
  void setInput(float value){std::fill_n(input[0],1024,value);std::fill_n(input[1],1024,-value);}
  FRResult render(){FRInput in{{input[0],input[1]},2,1024};FROutput out{{output[0],output[1]},2,1024};return pd_render(entry,&in,&out,1024,&report);}
  void warm(){for(int i=0;i<25;++i)render();}
  void identity(){FRProgram p{};pd_set_desired(entry,&p,&frame);}
};
int main(){
 for(float gain:{.25f,1.f,2.f,0.f}){
  Fixture f(gain);pd_request_original(f.entry,1);f.render();expect(!f.report.compare_ready&&!f.report.compare_active,"positive input readiness gate not bypassed");
  f.warm();f.render();
  printf("gain=%g input=%g held=%g original_gain=%g mix=%g ready=%u\n",gain,f.input[0][1023],f.output[0][1023],f.report.original_gain,f.report.original_mix,f.report.compare_ready);
  expect(std::abs(f.output[0][1023]-.2f)<1e-6f&&std::abs(f.output[1][1023]+.2f)<1e-6f,"AUD-01 settled original must equal unity dry,not processed RMS");
  expect(f.report.original_gain==1&&f.report.original_mix==1,"unity dry gain metadata and fully held mix");
  pd_request_original(f.entry,0);f.render();f.render();expect(f.report.original_mix==0&&std::abs(f.output[0][1023]-.2f*gain)<1e-6f,"release returns to processed signal");
  pd_request_original(f.entry,1);f.render();expect(std::abs(f.output[0][0]-.2f*gain)<.001f,"hold transition starts with bounded20ms slew");
  f.frame.token.source_epoch++;f.identity();f.render();expect(!f.report.compare_ready&&f.report.original_mix==0,"new source re-primes readiness even during hold");
  f.warm();expect(f.report.compare_ready&&std::abs(f.output[0][1023]-.2f)<1e-6f,"new source held comparison recovers");
  f.frame.token.format_epoch++;f.identity();f.render();expect(!f.report.compare_ready&&f.report.measured_frames==1024,"new format resets measured readiness");
  pd_request_original(f.entry,0);f.warm();expect(f.report.original_mix==0,"cancellation during priming does not later enable hold");
 }
 {Fixture f(.25f);f.setInput(0);for(int i=0;i<30;++i)f.render();expect(!f.report.compare_ready&&f.report.measured_frames==0,"silence does not falsely prime readiness");f.setInput(.2f);f.warm();expect(f.report.compare_ready,"fresh positive input primes readiness");
  pd_request_original(f.entry,1);f.render();f.render();f.setInput(2);f.render();expect(f.report.limited_samples>0,"unity dry still uses per-chain clipping protection");
  expect(std::all_of(&f.output[0][0],&f.output[0][1024],[](float x){return std::isfinite(x)&&std::abs(x)<=.9f;}),"all peak output stays finite and below ceiling");
  f.setInput(std::numeric_limits<float>::quiet_NaN());f.render();expect(f.report.invalid_samples>0&&std::isfinite(f.output[0][1023]),"nonfinite dry/processed handling retained");
  fakeError=true;expect(f.render()==FR_RENDER_ERROR&&!f.report.compare_ready&&!f.report.compare_active,"renderer failure refuses comparison status");fakeError=false;
 }
 printf("%s %u actual-PD checks,%u failures; deterministic fake FR only,no engine/audio/acoustic claim\n",failures?"FAIL":"PASS",checks,failures);return failures?1:0;
}
