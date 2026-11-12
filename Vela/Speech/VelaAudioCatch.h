#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Catches Objective-C exceptions from AVAudioEngine. Swift cannot.
NSError * _Nullable VelaAudioEnginePrepare(AVAudioEngine *engine);
NSError * _Nullable VelaAudioEngineStart(AVAudioEngine *engine);
NSError * _Nullable VelaSetVoiceProcessing(AVAudioEngine *engine, BOOL enabled);
NSError * _Nullable VelaInstallInputTap(AVAudioEngine *engine, AVAudioFormat *format, void (^handler)(AVAudioPCMBuffer *buffer));

NS_ASSUME_NONNULL_END
