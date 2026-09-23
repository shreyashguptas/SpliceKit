//
//  SpliceKitCommandPalette+Dictation.m
//  Live voice dictation into the palette search field (Speech framework).
//

#import "SpliceKitCommandPalette+Private.h"

@implementation SpliceKitCommandPalette (Dictation)

#pragma mark - Voice Dictation

- (void)toggleDictation:(id)sender {
    if (self.dictationActive) {
        [self stopDictation];
    } else {
        [self startDictation];
    }
}

- (void)requestDictationPermissions:(void (^)(BOOL, NSString *))completion {
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"Speech recognition permission is disabled for this Final Cut Pro build.");
            });
            return;
        }

        AVAuthorizationStatus micStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
        if (micStatus == AVAuthorizationStatusAuthorized) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(YES, nil); });
            return;
        }
        if (micStatus == AVAuthorizationStatusDenied || micStatus == AVAuthorizationStatusRestricted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"Microphone permission is disabled for this Final Cut Pro build.");
            });
            return;
        }

        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(granted, granted ? nil : @"Microphone permission is required for palette dictation.");
            });
        }];
    }];
}

- (void)startDictation {
    if (self.dictationActive) return;

    __weak typeof(self) weakSelf = self;
    [self requestDictationPermissions:^(BOOL granted, NSString *message) {
        if (!granted) {
            weakSelf.statusError = message;
            [weakSelf updateStatusLabel];
            return;
        }

        [weakSelf stopDictation];

        weakSelf.dictationRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale currentLocale]];
        if (!weakSelf.dictationRecognizer || !weakSelf.dictationRecognizer.isAvailable) {
            weakSelf.statusError = @"Apple speech dictation is unavailable right now.";
            [weakSelf updateStatusLabel];
            return;
        }

        weakSelf.dictationSeedQuery = [weakSelf.searchField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        weakSelf.dictationRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
        weakSelf.dictationRequest.shouldReportPartialResults = YES;
        weakSelf.dictationRequest.requiresOnDeviceRecognition = YES;
        weakSelf.dictationRequest.taskHint = SFSpeechRecognitionTaskHintDictation;
        SEL punctuationSel = NSSelectorFromString(@"setAddsPunctuation:");
        if ([weakSelf.dictationRequest respondsToSelector:punctuationSel]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(weakSelf.dictationRequest, punctuationSel, YES);
        }

        weakSelf.dictationAudioEngine = [[AVAudioEngine alloc] init];
        AVAudioInputNode *inputNode = weakSelf.dictationAudioEngine.inputNode;
        if (!inputNode) {
            weakSelf.statusError = @"No audio input device is available for dictation.";
            [weakSelf updateStatusLabel];
            return;
        }

        AVAudioFormat *format = [inputNode outputFormatForBus:0];
        [inputNode removeTapOnBus:0];
        [inputNode installTapOnBus:0
                        bufferSize:1024
                            format:format
                             block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
            [weakSelf.dictationRequest appendAudioPCMBuffer:buffer];
        }];

        NSError *startError = nil;
        [weakSelf.dictationAudioEngine prepare];
        if (![weakSelf.dictationAudioEngine startAndReturnError:&startError]) {
            [inputNode removeTapOnBus:0];
            weakSelf.statusError = startError.localizedDescription ?: @"Could not start audio engine for dictation.";
            [weakSelf updateStatusLabel];
            return;
        }

        weakSelf.dictationActive = YES;
        weakSelf.statusError = nil;
        [weakSelf updateStatusLabel];
        [weakSelf updateHeroStageAnimated:YES];
        [weakSelf.panel makeFirstResponder:weakSelf.searchField];

        weakSelf.dictationTask = [weakSelf.dictationRecognizer recognitionTaskWithRequest:weakSelf.dictationRequest
                                                                            resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (result) {
                    [weakSelf handleDictationText:result.bestTranscription.formattedString
                                            final:result.isFinal];
                }
                if (error) {
                    weakSelf.statusError = error.localizedDescription ?: @"Voice dictation stopped unexpectedly.";
                }
                if (error || result.isFinal) {
                    [weakSelf stopDictation];
                }
            });
        }];
    }];
}

- (void)handleDictationText:(NSString *)text final:(BOOL)isFinal {
    NSString *spoken = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *combined = spoken ?: @"";
    if (self.dictationSeedQuery.length > 0) {
        combined = spoken.length > 0
            ? [NSString stringWithFormat:@"%@ %@", self.dictationSeedQuery, spoken]
            : self.dictationSeedQuery;
    }

    self.searchField.stringValue = combined ?: @"";
    [self refreshSearchResultsForCurrentQuery];
    [self.panel makeFirstResponder:self.searchField];

    if (isFinal && combined.length > 0) {
        self.statusError = nil;
    }
}

- (void)stopDictation {
    if (self.dictationAudioEngine) {
        AVAudioInputNode *inputNode = self.dictationAudioEngine.inputNode;
        [inputNode removeTapOnBus:0];
        if (self.dictationAudioEngine.isRunning) {
            [self.dictationAudioEngine stop];
        }
    }

    [self.dictationRequest endAudio];
    [self.dictationTask cancel];
    self.dictationTask = nil;
    self.dictationRequest = nil;
    self.dictationRecognizer = nil;
    self.dictationAudioEngine = nil;
    self.dictationSeedQuery = nil;
    self.dictationActive = NO;
    [self updateStatusLabel];
    [self updateHeroStageAnimated:YES];
}

@end
