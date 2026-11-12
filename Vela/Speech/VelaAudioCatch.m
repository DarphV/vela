#import "VelaAudioCatch.h"

static NSError *VelaExceptionError(NSException *exception, NSString *fallback) {
    NSString *reason = exception.reason.length > 0 ? exception.reason : fallback;
    return [NSError errorWithDomain:@"de.barczewski.vela.audio"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: reason}];
}

NSError *VelaAudioEnginePrepare(AVAudioEngine *engine) {
    @try {
        [engine prepare];
        return nil;
    } @catch (NSException *exception) {
        return VelaExceptionError(exception, @"Audioengine konnte nicht vorbereitet werden");
    }
}

NSError *VelaAudioEngineStart(AVAudioEngine *engine) {
    @try {
        NSError *error = nil;
        if (![engine startAndReturnError:&error]) {
            return error ?: [NSError errorWithDomain:@"de.barczewski.vela.audio"
                                                code:2
                                            userInfo:@{NSLocalizedDescriptionKey: @"Audioengine konnte nicht starten"}];
        }
        return nil;
    } @catch (NSException *exception) {
        return VelaExceptionError(exception, @"Audioengine konnte nicht starten");
    }
}

NSError *VelaSetVoiceProcessing(AVAudioEngine *engine, BOOL enabled) {
    @try {
        NSError *error = nil;
        if (![engine.inputNode setVoiceProcessingEnabled:enabled error:&error]) {
            return error ?: [NSError errorWithDomain:@"de.barczewski.vela.audio"
                                                code:3
                                            userInfo:@{NSLocalizedDescriptionKey: @"Echounterdrückung nicht verfügbar"}];
        }
        return nil;
    } @catch (NSException *exception) {
        return VelaExceptionError(exception, @"Echounterdrückung nicht verfügbar");
    }
}

NSError *VelaInstallInputTap(AVAudioEngine *engine, AVAudioFormat *format, void (^handler)(AVAudioPCMBuffer *buffer)) {
    @try {
        [engine.inputNode installTapOnBus:0 bufferSize:1024 format:format block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
            (void)when;
            handler(buffer);
        }];
        return nil;
    } @catch (NSException *exception) {
        return VelaExceptionError(exception, @"Mikrofon konnte nicht verbunden werden");
    }
}
