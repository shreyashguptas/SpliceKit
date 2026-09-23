//
//  SpliceKitLiveCam+Capture.m
//  Capture: device lists and permissions, formats and frame rates, the preview
//  session, the sample-buffer callbacks, audio metering and the Metal preview.
//

#import "SpliceKitLiveCam+Private.h"

@implementation SpliceKitLiveCamPanel (Capture)

- (void)reloadDevices {
    NSString *currentResolution = SpliceKitLiveCamString(self.resolutionPopup.selectedItem.representedObject);
    NSNumber *currentFPS = self.frameRatePopup.selectedItem.representedObject;

    AVCaptureDeviceDiscoverySession *videoSession =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[
            AVCaptureDeviceTypeBuiltInWideAngleCamera,
            AVCaptureDeviceTypeExternal,
        ]
                                                               mediaType:AVMediaTypeVideo
                                                                position:AVCaptureDevicePositionUnspecified];
    AVCaptureDeviceDiscoverySession *audioSession =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[
            AVCaptureDeviceTypeMicrophone,
            AVCaptureDeviceTypeExternal,
        ]
                                                               mediaType:AVMediaTypeAudio
                                                                position:AVCaptureDevicePositionUnspecified];
    self.videoDevices = videoSession.devices ?: @[];
    self.audioDevices = audioSession.devices ?: @[];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *savedVideo = [defaults stringForKey:kLiveCamVideoDeviceKey];
    id savedAudioObject = [defaults objectForKey:kLiveCamAudioDeviceKey];
    NSString *savedAudio = [savedAudioObject isKindOfClass:[NSString class]] ? (NSString *)savedAudioObject : nil;
    NSString *defaultAudioID = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio].uniqueID ?: @"";

    [self.cameraPopup removeAllItems];
    NSInteger preferredVideoIndex = -1;
    for (AVCaptureDevice *device in self.videoDevices) {
        [self.cameraPopup addItemWithTitle:device.localizedName ?: @"Camera"];
        self.cameraPopup.lastItem.representedObject = device.uniqueID ?: @"";
        if (savedVideo.length > 0 && [device.uniqueID isEqualToString:savedVideo]) {
            preferredVideoIndex = self.cameraPopup.numberOfItems - 1;
        }
    }
    if (self.cameraPopup.numberOfItems > 0) {
        [self.cameraPopup selectItemAtIndex:(preferredVideoIndex >= 0 ? preferredVideoIndex : 0)];
    }

    [self.microphonePopup removeAllItems];
    NSInteger preferredAudioIndex = -1;
    NSInteger noMicIndex = -1;
    for (AVCaptureDevice *device in self.audioDevices) {
        [self.microphonePopup addItemWithTitle:device.localizedName ?: @"Microphone"];
        self.microphonePopup.lastItem.representedObject = device.uniqueID ?: @"";
        if ([savedAudio isEqualToString:kLiveCamNoMicrophoneIdentifier]) {
            continue;
        }
        if (savedAudio.length > 0 && [device.uniqueID isEqualToString:savedAudio]) {
            preferredAudioIndex = self.microphonePopup.numberOfItems - 1;
        } else if (preferredAudioIndex < 0 && defaultAudioID.length > 0 &&
                   [device.uniqueID isEqualToString:defaultAudioID]) {
            preferredAudioIndex = self.microphonePopup.numberOfItems - 1;
        }
    }
    [self.microphonePopup addItemWithTitle:@"No Microphone"];
    self.microphonePopup.lastItem.representedObject = kLiveCamNoMicrophoneIdentifier;
    noMicIndex = self.microphonePopup.numberOfItems - 1;

    if ([savedAudio isEqualToString:kLiveCamNoMicrophoneIdentifier]) {
        preferredAudioIndex = noMicIndex;
    } else if (preferredAudioIndex < 0) {
        preferredAudioIndex = (self.audioDevices.count > 0) ? 0 : noMicIndex;
    }
    [self.microphonePopup selectItemAtIndex:preferredAudioIndex];

    [self refreshResolutionOptionsPreservingSelection:currentResolution frameRate:currentFPS];
    [self persistDefaults];
}

- (void)deviceAvailabilityChanged:(NSNotification *)note {
    SpliceKit_log(@"[LiveCamCapture] Device availability changed: %@", note.name);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self reloadDevices];
        if (self.isVisible && !self.finalizingRecording) {
            [self reconfigurePreviewSession];
        }
    });
}

- (void)requestPermissionsAndStartPreviewIfPossible {
    AVAuthorizationStatus videoStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    AVAuthorizationStatus audioStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];

    dispatch_group_t group = dispatch_group_create();
    __block BOOL videoGranted = (videoStatus == AVAuthorizationStatusAuthorized);
    __block BOOL audioGranted = (audioStatus == AVAuthorizationStatusAuthorized);

    if (videoStatus == AVAuthorizationStatusNotDetermined) {
        dispatch_group_enter(group);
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            videoGranted = granted;
            dispatch_group_leave(group);
        }];
    }
    if (audioStatus == AVAuthorizationStatusNotDetermined) {
        dispatch_group_enter(group);
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
            audioGranted = granted;
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        self.cameraAuthorized = videoGranted || videoStatus == AVAuthorizationStatusAuthorized;
        self.microphoneAuthorized = audioGranted || audioStatus == AVAuthorizationStatusAuthorized;
        if (!self.cameraAuthorized) {
            AVAuthorizationStatus currentVideoStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
            BOOL needsSystemSettings = (currentVideoStatus == AVAuthorizationStatusDenied ||
                                         currentVideoStatus == AVAuthorizationStatusRestricted);
            self.permissionButton.title = needsSystemSettings ? @"Open System Settings…" : @"Allow Camera…";
            self.permissionButton.hidden = NO;
            NSString *detail = needsSystemSettings
                ? @"Camera permission is off. Click Open System Settings… to turn on camera access for Final Cut Pro."
                : @"Camera permission is required for LiveCam. Click Allow Camera… to grant access.";
            [self updateStatus:detail];
            [self updateSessionLabel:@"Camera permission denied"];
            [self updateControlsForState];
            return;
        }
        self.permissionButton.hidden = YES;

        if (!self.microphoneAuthorized) {
            [self updateStatus:@"Microphone access is off, so LiveCam will preview video only until microphone permission is granted."];
        }

        [self reconfigurePreviewSession];
    });
}

- (void)permissionButtonClicked:(id)sender {
    AVAuthorizationStatus videoStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (videoStatus == AVAuthorizationStatusNotDetermined) {
        [self requestPermissionsAndStartPreviewIfPossible];
        return;
    }
    NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

- (AVCaptureDevice *)selectedVideoDevice {
    NSString *identifier = SpliceKitLiveCamString(self.cameraPopup.selectedItem.representedObject);
    for (AVCaptureDevice *device in self.videoDevices) {
        if ([device.uniqueID isEqualToString:identifier]) return device;
    }
    return self.videoDevices.firstObject;
}

- (AVCaptureDevice *)selectedAudioDevice {
    NSString *identifier = SpliceKitLiveCamString(self.microphonePopup.selectedItem.representedObject);
    if (identifier.length == 0 || [identifier isEqualToString:kLiveCamNoMicrophoneIdentifier]) return nil;
    for (AVCaptureDevice *device in self.audioDevices) {
        if ([device.uniqueID isEqualToString:identifier]) return device;
    }
    return nil;
}

- (NSArray<NSNumber *> *)frameRatesForFormat:(AVCaptureDeviceFormat *)format {
    NSMutableOrderedSet<NSNumber *> *rates = [NSMutableOrderedSet orderedSet];
    NSArray<NSNumber *> *preferredRates = @[@24, @25, @30, @50, @60];

    for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
        double minRate = range.minFrameRate;
        double maxRate = range.maxFrameRate;

        for (NSNumber *candidate in preferredRates) {
            double fps = candidate.doubleValue;
            if (fps + 0.001 >= minRate && fps - 0.001 <= maxRate) {
                [rates addObject:@((NSInteger)lrint(fps))];
            }
        }

        NSInteger roundedMax = (NSInteger)lrint(maxRate);
        if (roundedMax > 0 && roundedMax <= 120 &&
            roundedMax + 0.001 >= minRate && roundedMax - 0.001 <= maxRate) {
            [rates addObject:@(roundedMax)];
        }
    }

    NSArray<NSNumber *> *sorted = [[rates array] sortedArrayUsingComparator:^NSComparisonResult(NSNumber *lhs, NSNumber *rhs) {
        return [lhs compare:rhs];
    }];
    return sorted.count > 0 ? sorted : @[@30];
}

- (void)refreshFrameRateOptionsPreservingSelection:(NSNumber *)preferredFPS {
    NSString *selectedResolutionKey = SpliceKitLiveCamString(self.resolutionPopup.selectedItem.representedObject);
    NSArray<NSNumber *> *availableRates = self.availableFrameRatesByResolution[selectedResolutionKey];
    if (availableRates.count == 0) {
        availableRates = @[@24, @30, @60];
    }

    NSNumber *fallbackPreferredFPS = preferredFPS ?: self.frameRatePopup.selectedItem.representedObject;
    [self.frameRatePopup removeAllItems];
    for (NSNumber *fps in availableRates) {
        [self.frameRatePopup addItemWithTitle:[NSString stringWithFormat:@"%@ fps", fps]];
        self.frameRatePopup.lastItem.representedObject = fps;
    }

    NSInteger preferredIndex = [self.frameRatePopup indexOfItemWithRepresentedObject:fallbackPreferredFPS];
    if (preferredIndex < 0) {
        preferredIndex = [self.frameRatePopup indexOfItemWithRepresentedObject:@30];
    }
    [self.frameRatePopup selectItemAtIndex:(preferredIndex >= 0 ? preferredIndex : 0)];
}

- (void)refreshResolutionOptionsPreservingSelection:(NSString *)preferredResolution
                                          frameRate:(NSNumber *)preferredFPS {
    AVCaptureDevice *device = [self selectedVideoDevice];
    NSMutableDictionary<NSString *, NSMutableOrderedSet<NSNumber *> *> *mutableRates = [NSMutableDictionary dictionary];

    for (AVCaptureDeviceFormat *format in device.formats) {
        CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
        if (dimensions.width <= 0 || dimensions.height <= 0) continue;

        NSString *resolutionKey = SpliceKitLiveCamResolutionKeyForDimensions(dimensions.width, dimensions.height);
        if (resolutionKey.length == 0) continue;

        NSMutableOrderedSet<NSNumber *> *bucket = mutableRates[resolutionKey];
        if (!bucket) {
            bucket = [NSMutableOrderedSet orderedSet];
            mutableRates[resolutionKey] = bucket;
        }
        for (NSNumber *fps in [self frameRatesForFormat:format]) {
            [bucket addObject:fps];
        }
    }

    if (mutableRates.count == 0) {
        mutableRates[@"1280x720"] = [NSMutableOrderedSet orderedSetWithArray:@[@24, @30, @60]];
    }

    NSArray<NSString *> *sortedResolutionKeys = [[mutableRates allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *lhs, NSString *rhs) {
        CGSize lhsSize = SpliceKitLiveCamResolutionForKey(lhs);
        CGSize rhsSize = SpliceKitLiveCamResolutionForKey(rhs);
        double lhsArea = lhsSize.width * lhsSize.height;
        double rhsArea = rhsSize.width * rhsSize.height;
        if (lhsArea > rhsArea) return NSOrderedAscending;
        if (lhsArea < rhsArea) return NSOrderedDescending;
        if (lhsSize.width > rhsSize.width) return NSOrderedAscending;
        if (lhsSize.width < rhsSize.width) return NSOrderedDescending;
        return [lhs compare:rhs];
    }];

    NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *finalRates = [NSMutableDictionary dictionary];
    for (NSString *resolutionKey in sortedResolutionKeys) {
        NSArray<NSNumber *> *sortedRates = [[mutableRates[resolutionKey] array] sortedArrayUsingComparator:^NSComparisonResult(NSNumber *lhs, NSNumber *rhs) {
            return [lhs compare:rhs];
        }];
        finalRates[resolutionKey] = sortedRates.count > 0 ? sortedRates : @[@30];
    }

    self.availableResolutionKeys = sortedResolutionKeys;
    self.availableFrameRatesByResolution = finalRates;

    NSString *resolvedPreference = preferredResolution.length > 0 ? preferredResolution : [[NSUserDefaults standardUserDefaults] stringForKey:kLiveCamResolutionKey];
    [self.resolutionPopup removeAllItems];
    for (NSString *resolutionKey in self.availableResolutionKeys) {
        [self.resolutionPopup addItemWithTitle:SpliceKitLiveCamResolutionTitleForKey(resolutionKey)];
        self.resolutionPopup.lastItem.representedObject = resolutionKey;
    }

    NSInteger preferredIndex = [self.resolutionPopup indexOfItemWithRepresentedObject:resolvedPreference];
    if (preferredIndex < 0) {
        preferredIndex = [self.resolutionPopup indexOfItemWithRepresentedObject:@"1920x1080"];
    }
    if (preferredIndex < 0) {
        preferredIndex = [self.resolutionPopup indexOfItemWithRepresentedObject:@"1280x720"];
    }
    [self.resolutionPopup selectItemAtIndex:(preferredIndex >= 0 ? preferredIndex : 0)];
    [self refreshFrameRateOptionsPreservingSelection:preferredFPS];
}

- (void)configureVideoDevice:(AVCaptureDevice *)device
                  resolution:(CGSize)resolution
                   frameRate:(double)fps {
    if (!device) return;

    NSError *error = nil;
    if (![device lockForConfiguration:&error]) {
        SpliceKit_log(@"[LiveCamCapture] Could not lock %@ for configuration: %@",
                      device.localizedName, error.localizedDescription);
        return;
    }

    AVCaptureDeviceFormat *bestFormat = nil;
    double bestScore = DBL_MAX;

    for (AVCaptureDeviceFormat *format in device.formats) {
        CMFormatDescriptionRef description = format.formatDescription;
        CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(description);

        BOOL fpsSupported = (fps <= 0.0);
        for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
            if (fps <= 0.0 || (range.minFrameRate <= fps && range.maxFrameRate >= fps)) {
                fpsSupported = YES;
                break;
            }
        }
        if (!fpsSupported) continue;

        double widthDelta = fabs((double)dimensions.width - resolution.width);
        double heightDelta = fabs((double)dimensions.height - resolution.height);
        double score = widthDelta + heightDelta;
        if (score < bestScore) {
            bestScore = score;
            bestFormat = format;
        }
    }

    if (bestFormat) {
        device.activeFormat = bestFormat;
        if (fps > 0.0) {
            CMTime frameDuration = CMTimeMake(1000, (int32_t)lrint(fps * 1000.0));
            device.activeVideoMinFrameDuration = frameDuration;
            device.activeVideoMaxFrameDuration = frameDuration;
        }
        CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(bestFormat.formatDescription);
        SpliceKit_log(@"[LiveCamCapture] %@ active format %dx%d @ %.0f fps",
                      device.localizedName ?: @"Camera",
                      dimensions.width,
                      dimensions.height,
                      fps);
    } else {
        SpliceKit_log(@"[LiveCamCapture] No exact format match for %@ %.0fx%.0f @ %.0f fps",
                      device.localizedName ?: @"Camera",
                      resolution.width,
                      resolution.height,
                      fps);
    }

    [device unlockForConfiguration];
}

- (void)reconfigurePreviewSession {
    if (!self.cameraAuthorized) return;

    AVCaptureDevice *videoDevice = [self selectedVideoDevice];
    AVCaptureDevice *audioDevice = self.microphoneAuthorized ? [self selectedAudioDevice] : nil;
    CGSize targetResolution = SpliceKitLiveCamResolutionForKey(SpliceKitLiveCamString(self.resolutionPopup.selectedItem.representedObject));
    double frameRate = [self.frameRatePopup.selectedItem.representedObject doubleValue] ?: 30.0;

    [self updateSessionLabel:@"Configuring capture…"];
    [self updateStatus:@"Opening camera preview…"];

    dispatch_async(self.sessionQueue, ^{
        if (self.session.isRunning) {
            [self.session stopRunning];
        }

        AVCaptureSession *session = [[AVCaptureSession alloc] init];
        // Use an exact macOS capture preset where one exists. The old generic
        // "High" preset made a selected 720p preview arrive as 1920x1080 and
        // forced 2.25x as many pixels through every effect.
        AVCaptureSessionPreset requestedPreset =
            SpliceKitLiveCamSessionPresetForResolution(targetResolution);
        if ([session canSetSessionPreset:requestedPreset]) {
            session.sessionPreset = requestedPreset;
        } else if ([session canSetSessionPreset:AVCaptureSessionPresetHigh]) {
            session.sessionPreset = AVCaptureSessionPresetHigh;
        }

        NSError *inputError = nil;
        AVCaptureDeviceInput *videoInput = videoDevice
            ? [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&inputError]
            : nil;
        if (videoInput && [session canAddInput:videoInput]) {
            [session addInput:videoInput];
            self.videoInput = videoInput;
        }

        if (videoDevice) {
            [self configureVideoDevice:videoDevice resolution:targetResolution frameRate:frameRate];
        }

        AVCaptureDeviceInput *audioInput = nil;
        if (audioDevice) {
            NSError *audioError = nil;
            audioInput = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice error:&audioError];
            if (audioInput && [session canAddInput:audioInput]) {
                [session addInput:audioInput];
                self.audioInput = audioInput;
            } else if (audioError) {
                SpliceKit_log(@"[LiveCamCapture] Audio input error: %@", audioError.localizedDescription);
            }
        } else {
            self.audioInput = nil;
        }

        AVCaptureVideoDataOutput *videoOutput = [[AVCaptureVideoDataOutput alloc] init];
        videoOutput.alwaysDiscardsLateVideoFrames = YES;
        videoOutput.videoSettings = @{
            (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (NSString *)kCVPixelBufferWidthKey: @((NSInteger)lrint(targetResolution.width)),
            (NSString *)kCVPixelBufferHeightKey: @((NSInteger)lrint(targetResolution.height)),
        };
        [videoOutput setSampleBufferDelegate:self queue:self.videoQueue];
        if ([session canAddOutput:videoOutput]) {
            [session addOutput:videoOutput];
            self.videoOutput = videoOutput;
        }

        AVCaptureAudioDataOutput *audioOutput = [[AVCaptureAudioDataOutput alloc] init];
        // Preserve the hardware's native rate and channel layout. In
        // particular, the MVX2U is a 48 kHz mono source; forcing a stereo
        // capture format here adds an unnecessary real-time conversion before
        // the writer has even seen the source format.
        audioOutput.audioSettings = nil;
        [audioOutput setSampleBufferDelegate:self queue:self.audioQueue];
        if (audioDevice && [session canAddOutput:audioOutput]) {
            [session addOutput:audioOutput];
            self.audioOutput = audioOutput;
        } else {
            self.audioOutput = nil;
        }

        AVCaptureConnection *videoConnection = [videoOutput connectionWithMediaType:AVMediaTypeVideo];
        if (videoConnection.isVideoMirroringSupported) {
            videoConnection.automaticallyAdjustsVideoMirroring = NO;
            videoConnection.videoMirrored = NO;
        }

        self.session = session;
        dispatch_sync(self.videoQueue, ^{
            self.latestPreviewImage = nil;
            [self.segmentationEngine reset];
            [self.renderer resetMaskHistory];
        });

        if (self.isVisible) {
            [session startRunning];
        }

        NSString *cameraName = videoDevice.localizedName ?: @"No Camera";
        NSString *micName = audioDevice.localizedName ?: @"No Microphone";
        NSString *statusCopy = audioDevice
            ? @"What you see is what gets recorded."
            : @"Video only. No microphone selected.";
        NSString *compactCameraName = [cameraName stringByReplacingOccurrencesOfString:@" Camera" withString:@""];
        NSString *compactResolution = SpliceKitLiveCamString(self.resolutionPopup.selectedItem.representedObject);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshBackgroundUI];
            [self updateSessionLabel:[NSString stringWithFormat:@"%@ • %@ • %@ • %@",
                                      compactCameraName.length > 0 ? compactCameraName : cameraName,
                                      micName,
                                      compactResolution.length > 0 ? compactResolution : (self.resolutionPopup.titleOfSelectedItem ?: @""),
                                      self.frameRatePopup.titleOfSelectedItem ?: @""]];
            [self updateStatus:statusCopy];
            [self updateControlsForState];
            [self persistDefaults];
        });
    });
}

- (void)stopPreviewSession {
    dispatch_async(self.sessionQueue, ^{
        if (self.session.isRunning) {
            [self.session stopRunning];
        }
        dispatch_sync(self.videoQueue, ^{
            self.latestPreviewImage = nil;
            [self.segmentationEngine reset];
            [self.renderer resetMaskHistory];
        });
        dispatch_async(dispatch_get_main_queue(), ^{
            self.smoothedAudioLevel = 0.0;
            [self.audioMeter reset];
        });
    });
}

- (void)trackAudioFormatAndContinuityFromSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
    const AudioStreamBasicDescription *asbd =
        CMAudioFormatDescriptionGetStreamBasicDescription(format);
    if (!asbd) return;

    double sampleRate = asbd->mSampleRate;
    NSUInteger channels = asbd->mChannelsPerFrame;
    BOOL formatChanged = !self.audioFormatLogged ||
        fabs(self.capturedAudioSampleRate - sampleRate) > 0.5 ||
        self.capturedAudioChannels != channels;
    self.capturedAudioSampleRate = sampleRate;
    self.capturedAudioChannels = channels;
    if (formatChanged) {
        self.audioFormatLogged = YES;
        SpliceKit_log(@"[LiveCamAudio] source format rate=%.0fHz channels=%lu format=0x%08x flags=0x%08x bits=%u bytesPerFrame=%u",
                      sampleRate,
                      (unsigned long)channels,
                      (unsigned int)asbd->mFormatID,
                      (unsigned int)asbd->mFormatFlags,
                      (unsigned int)asbd->mBitsPerChannel,
                      (unsigned int)asbd->mBytesPerFrame);
    }

    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMItemCount sampleCount = CMSampleBufferGetNumSamples(sampleBuffer);
    if (!CMTIME_IS_VALID(pts) || sampleRate <= 0.0 || sampleCount <= 0) {
        self.expectedNextAudioPTS = kCMTimeInvalid;
        return;
    }

    if (self.recordingActive && CMTIME_IS_VALID(self.expectedNextAudioPTS)) {
        double gapSeconds = CMTimeGetSeconds(CMTimeSubtract(pts, self.expectedNextAudioPTS));
        // Host-time conversion can introduce sub-millisecond rounding. A gap
        // beyond 2 ms is large enough to be audible and indicates a capture
        // discontinuity, even when AVAssetWriter itself reports zero drops.
        if (isfinite(gapSeconds) && fabs(gapSeconds) > 0.002) {
            self.sourceAudioDiscontinuities += 1;
            self.sourceAudioGapFrames += (NSUInteger)llround(fabs(gapSeconds) * sampleRate);
            NSUInteger eventCount = self.sourceAudioDiscontinuities;
            if (eventCount <= 8 || eventCount % 25 == 0) {
                SpliceKit_log(@"[LiveCamAudio] source discontinuity #%lu gap=%+.3fms near %.3fs",
                              (unsigned long)eventCount,
                              gapSeconds * 1000.0,
                              CMTimeGetSeconds(pts));
            }
        }
    }

    CMTime bufferDuration = CMTimeMakeWithSeconds((double)sampleCount / sampleRate, 1000000000);
    self.expectedNextAudioPTS = CMTimeAdd(pts, bufferDuration);
}

- (void)handleAudioMeterFromSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    self.audioMeterBuffersReceived += 1;

    // Metering is intentionally capped at 20 Hz. Do this before inspecting or
    // copying the PCM payload so the audio callback stays lightweight even for
    // high-rate/multichannel devices.
    NSTimeInterval now = CACurrentMediaTime();
    if (now - self.lastAudioMeterDispatchTime < 0.05) return;
    self.lastAudioMeterDispatchTime = now;

    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
    const AudioStreamBasicDescription *asbd =
        CMAudioFormatDescriptionGetStreamBasicDescription(format);
    if (!asbd) return;

    // Ask Core Media for the exact AudioBufferList size first. AVCapture can
    // return more buffers than the old fixed stack-sized estimate (especially
    // for non-interleaved and aggregate devices), in which case the previous
    // code returned kCMSampleBufferError_ArrayTooSmall and silently left the
    // UI frozen. The first call is a size query and does not copy audio.
    size_t bufferListSize = 0;
    OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        &bufferListSize,
        NULL,
        0,
        NULL,
        NULL,
        0,
        NULL);
    if (status != noErr || bufferListSize < sizeof(AudioBufferList)) {
        self.audioMeterLastError = status != noErr ? status : kCMSampleBufferError_ArrayTooSmall;
        return;
    }

    AudioBufferList *audioBufferList = calloc(1, bufferListSize);
    if (!audioBufferList) return;

    CMBlockBufferRef blockBuffer = NULL;
    status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        NULL,
        audioBufferList,
        bufferListSize,
        NULL,
        NULL,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        &blockBuffer);

    if (status != noErr) {
        self.audioMeterLastError = status;
        free(audioBufferList);
        if (blockBuffer) CFRelease(blockBuffer);
        return;
    }

    double total = 0.0;
    double peak = 0.0;
    NSUInteger count = 0;
    for (UInt32 i = 0; i < audioBufferList->mNumberBuffers; i++) {
        AudioBuffer buffer = audioBufferList->mBuffers[i];
        if (!buffer.mData || buffer.mDataByteSize == 0) continue;

        BOOL isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
        BOOL isSignedInteger = (asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
        if (isFloat && asbd->mBitsPerChannel == 32) {
            const float *samples = (const float *)buffer.mData;
            NSUInteger sampleCount = buffer.mDataByteSize / sizeof(float);
            for (NSUInteger s = 0; s < sampleCount; s++) {
                double value = samples[s];
                total += value * value;
                peak = MAX(peak, fabs(value));
            }
            count += sampleCount;
        } else if (isFloat && asbd->mBitsPerChannel == 64) {
            const double *samples = (const double *)buffer.mData;
            NSUInteger sampleCount = buffer.mDataByteSize / sizeof(double);
            for (NSUInteger s = 0; s < sampleCount; s++) {
                double value = samples[s];
                total += value * value;
                peak = MAX(peak, fabs(value));
            }
            count += sampleCount;
        } else if (isSignedInteger && asbd->mBitsPerChannel == 16) {
            const int16_t *samples = (const int16_t *)buffer.mData;
            NSUInteger sampleCount = buffer.mDataByteSize / sizeof(int16_t);
            for (NSUInteger s = 0; s < sampleCount; s++) {
                double normalized = (double)samples[s] / 32768.0;
                total += normalized * normalized;
                peak = MAX(peak, fabs(normalized));
            }
            count += sampleCount;
        } else if (isSignedInteger && asbd->mBitsPerChannel == 24) {
            BOOL nonInterleaved =
                (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
            BOOL bigEndian =
                (asbd->mFormatFlags & kAudioFormatFlagIsBigEndian) != 0;
            BOOL alignedHigh =
                (asbd->mFormatFlags & kAudioFormatFlagIsAlignedHigh) != 0;
            UInt32 bytesPerSample = nonInterleaved
                ? asbd->mBytesPerFrame
                : (asbd->mChannelsPerFrame > 0
                    ? asbd->mBytesPerFrame / asbd->mChannelsPerFrame
                    : 0);

            if (bytesPerSample == 4) {
                const int32_t *samples = (const int32_t *)buffer.mData;
                NSUInteger sampleCount = buffer.mDataByteSize / sizeof(int32_t);
                for (NSUInteger s = 0; s < sampleCount; s++) {
                    int32_t value = samples[s];
                    if (bigEndian) value = (int32_t)CFSwapInt32BigToHost((uint32_t)value);
                    if (!alignedHigh) value = (int32_t)((uint32_t)value << 8);
                    double normalized = (double)value / 2147483648.0;
                    total += normalized * normalized;
                    peak = MAX(peak, fabs(normalized));
                }
                count += sampleCount;
            } else if (bytesPerSample == 3) {
                const uint8_t *bytes = (const uint8_t *)buffer.mData;
                NSUInteger sampleCount = buffer.mDataByteSize / 3;
                for (NSUInteger s = 0; s < sampleCount; s++) {
                    const uint8_t *sample = bytes + s * 3;
                    int32_t value = bigEndian
                        ? ((int32_t)sample[0] << 16) | ((int32_t)sample[1] << 8) | sample[2]
                        : ((int32_t)sample[2] << 16) | ((int32_t)sample[1] << 8) | sample[0];
                    if (value & 0x00800000) value |= (int32_t)0xff000000;
                    double normalized = (double)value / 8388608.0;
                    total += normalized * normalized;
                    peak = MAX(peak, fabs(normalized));
                }
                count += sampleCount;
            }
        } else if (isSignedInteger && asbd->mBitsPerChannel == 32) {
            const int32_t *samples = (const int32_t *)buffer.mData;
            NSUInteger sampleCount = buffer.mDataByteSize / sizeof(int32_t);
            for (NSUInteger s = 0; s < sampleCount; s++) {
                double normalized = (double)samples[s] / 2147483648.0;
                total += normalized * normalized;
                peak = MAX(peak, fabs(normalized));
            }
            count += sampleCount;
        }
    }

    if (blockBuffer) CFRelease(blockBuffer);
    free(audioBufferList);

    self.audioMeterDecodedSamples = count;
    if (count == 0) {
        self.audioMeterLastError = kCMSampleBufferError_InvalidMediaFormat;
        return;
    }
    self.audioMeterLastError = noErr;

    double rms = sqrt(total / (double)count);
    self.smoothedAudioLevel = (self.smoothedAudioLevel * 0.82) + (rms * 0.18);
    double rmsDB = self.smoothedAudioLevel > 0.000001
        ? 20.0 * log10(self.smoothedAudioLevel)
        : -60.0;
    double peakDB = peak > 0.000001 ? 20.0 * log10(peak) : -60.0;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.audioMeter updateWithRMSDB:rmsDB peakDB:peakDB];
    });
}

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
    if (output == self.videoOutput) {
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (!imageBuffer) return;

        uint64_t frameStartTicks = mach_absolute_time();

        CIImage *source = [CIImage imageWithCVPixelBuffer:imageBuffer];
        if (!source) return;

        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        NSTimeInterval seconds = CMTimeGetSeconds(pts);
        SpliceKitLiveCamAdjustmentState *adjustments = [self.adjustments copy];
        SpliceKitLiveCamPreset *preset = [self selectedPreset];
        SpliceKitLiveCamBackgroundMode backgroundMode = [self selectedBackgroundMode];
        BOOL mirrored = (self.mirrorCheckbox.state == NSControlStateValueOn);
        CIImage *maskImage = nil;
        CIColor *backgroundColor = nil;
        SpliceKitLiveCamMaskParams *maskParams = nil;

        BOOL transparentBg = NO;
        if (backgroundMode == SpliceKitLiveCamBackgroundModeGreenScreen && self.segmentationEngine.supported) {
            maskImage = [self.segmentationEngine maskImageForSampleBuffer:sampleBuffer];
            NSString *colorKey = [self selectedBackgroundColorKey];
            transparentBg = [colorKey isEqualToString:@"transparent"];
            backgroundColor = transparentBg ? nil : SpliceKitLiveCamBackgroundCIColor(colorKey);
            maskParams = [[SpliceKitLiveCamMaskParams alloc] init];
            maskParams.edgeSoftness = self.backgroundEdgeSlider.doubleValue;
            maskParams.refinement = self.backgroundRefinementSlider.doubleValue;
            maskParams.choke = self.backgroundChokeSlider.doubleValue;
            maskParams.spill = self.backgroundSpillSlider.doubleValue;
            maskParams.wrap = self.backgroundWrapSlider.doubleValue;
            maskParams.temporalSmoothing = 0.45;
            maskParams.transparentBackground = transparentBg;
            maskParams.sourceGeneration = self.segmentationEngine.maskGeneration;
        }

        CIImage *rendered = [self.renderer renderedImageFromImage:source
                                                           preset:preset
                                                             time:seconds
                                                      adjustments:adjustments
                                                         maskImage:maskImage
                                                       maskParams:maskParams
                                                   backgroundColor:backgroundColor
                                                         mirrored:mirrored
                                                        recording:self.recordingActive
                                                       canvasSize:source.extent.size];
        // Preview composites alpha over a checkerboard so the user can see the cut.
        // The recording path keeps the untouched alpha-bearing frame.
        CIImage *previewImage = transparentBg
            ? [self.renderer imageByCompositingOverPreviewCheckerboard:rendered]
            : rendered;
        @synchronized (self) {
            self.latestPreviewImage = previewImage;
        }
        if (!self.previewDrawPending) {
            self.previewDrawPending = YES;
            dispatch_async(dispatch_get_main_queue(), ^{
                self.previewDrawPending = NO;
                [self.previewView draw];
            });
        }

        if (self.recordingActive) {
            [self appendVideoFrame:rendered atTime:pts];
        }

        // Perf instrumentation: accumulate per-frame render time and log a
        // summary every ~2 seconds with the number of masks materialized into
        // bounded history buffers and process RSS. CIImage.description is not
        // a reliable graph-depth metric on current Core Image releases.
        static mach_timebase_info_data_t timebase = {0, 0};
        if (timebase.denom == 0) mach_timebase_info(&timebase);
        double frameMs = ((mach_absolute_time() - frameStartTicks) * timebase.numer / (double)timebase.denom) / 1.0e6;
        self.perfFrameCount += 1;
        self.perfFrameMsSum += frameMs;
        if (frameMs > self.perfFrameMsMax) self.perfFrameMsMax = frameMs;
        NSTimeInterval now = CACurrentMediaTime();
        if (self.perfLastLogTime == 0) self.perfLastLogTime = now;
        if (now - self.perfLastLogTime >= 2.0 && self.perfFrameCount > 0) {
            double avgMs = self.perfFrameMsSum / self.perfFrameCount;
            double rssMB = SpliceKitLiveCamResidentMB();
            SpliceKit_log(@"[LiveCamPerf] frames=%lu avg=%.1fms max=%.1fms materializedMasks=%lu rss=%.1fMB input=%.0fx%.0f bg=%ld refinement=%.2f choke=%.2f edge=%.2f spill=%.2f wrap=%.2f",
                          (unsigned long)self.perfFrameCount,
                          avgMs,
                          self.perfFrameMsMax,
                          (unsigned long)self.renderer.maskHistoryFrames,
                          rssMB,
                          CGRectGetWidth(source.extent),
                          CGRectGetHeight(source.extent),
                          (long)backgroundMode,
                          self.backgroundRefinementSlider.doubleValue,
                          self.backgroundChokeSlider.doubleValue,
                          self.backgroundEdgeSlider.doubleValue,
                          self.backgroundSpillSlider.doubleValue,
                          self.backgroundWrapSlider.doubleValue);
            self.perfFrameCount = 0;
            self.perfFrameMsSum = 0;
            self.perfFrameMsMax = 0;
            self.perfLastLogTime = now;
        }
    } else if (output == self.audioOutput) {
        [self trackAudioFormatAndContinuityFromSampleBuffer:sampleBuffer];
        [self handleAudioMeterFromSampleBuffer:sampleBuffer];
        if (self.muteCheckbox.state != NSControlStateValueOn) {
            [self appendAudioSampleBuffer:sampleBuffer];
        }
    }
    }
}

@end
