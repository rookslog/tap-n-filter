import AVFoundation
import AudioToolbox

enum FinalMixLimiter {
  static func make() throws -> AVAudioUnitEffect {
    let limiter = AVAudioUnitEffect(
      audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0,
        componentFlagsMask: 0))
    for (id, value) in [
      (kLimiterParam_AttackTime, Float(0.001)), (kLimiterParam_DecayTime, Float(0.05)),
      (kLimiterParam_PreGain, Float(0)),
    ] {
      let result = AudioUnitSetParameter(limiter.audioUnit, id, kAudioUnitScope_Global, 0, value, 0)
      guard result == noErr else { throw OutputError.nativeParameter(result) }
    }
    return limiter
  }
}
