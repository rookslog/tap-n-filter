#ifndef AUDIO_ENGINE_SDK_COMPATIBILITY_H
#define AUDIO_ENGINE_SDK_COMPATIBILITY_H

#ifdef __OBJC__
#include <Availability.h>
#if __MAC_OS_X_VERSION_MAX_ALLOWED < 270000
#import <AVFAudio/AVFAudio.h>

// Older SDKs need the declaration; runtime availability still gates the call.
NS_ASSUME_NONNULL_BEGIN
@interface AVAudioEngine (TNFSDK27Connection)
- (BOOL)connect:(AVAudioNode *)node1 to:(AVAudioNode *)node2 fromBus:(AVAudioNodeBus)bus1 toBus:(AVAudioNodeBus)bus2 format:(AVAudioFormat * __nullable)format error:(NSError**)error NS_SWIFT_NAME(connectNode(_:to:fromBus:toBus:format:)) API_AVAILABLE(macos(27.0), ios(27.0), watchos(27.0), tvos(27.0));
@end
NS_ASSUME_NONNULL_END
#endif
#endif

#endif
