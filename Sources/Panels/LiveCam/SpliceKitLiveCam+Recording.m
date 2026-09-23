//
//  SpliceKitLiveCam+Recording.m
//  Recording: asset-writer settings, start / stop, appending frames and audio,
//  and finishing the file before ingest.
//

#import "SpliceKitLiveCam+Private.h"

@implementation SpliceKitLiveCamPanel (Recording)

- (NSString *)recordingBaseName {
    NSString *baseName = SpliceKitLiveCamTrimmedString(self.clipNameField.stringValue);
    if (baseName.length == 0) baseName = @"LiveCam";
    NSString *timestamp = SpliceKitLiveCamTimestampForFilename([NSDate date]);
    return [NSString stringWithFormat:@"%@_%@", SpliceKitLiveCamSanitizeFilename(baseName), timestamp];
}

- (double)selectedBitRate {
    NSString *quality = SpliceKitLiveCamString(self.qualityPopup.selectedItem.representedObject);
    if ([quality isEqualToString:@"fast"]) return 6.0 * 1000.0 * 1000.0;
    if ([quality isEqualToString:@"high"]) return 20.0 * 1000.0 * 1000.0;
    return 12.0 * 1000.0 * 1000.0;
}

- (NSDictionary<NSString *, id> *)audioWriterSettingsForCurrentSession {
    // Apple's recommendation is derived from the configured capture session,
    // so it retains a mono USB microphone as mono and uses its actual sample
    // rate. The previous fixed 48 kHz/stereo dictionary made AVAssetWriter
    // perform an undocumented real-time mono-to-stereo conversion for the
    // Shure MVX2U, which is both unnecessary and vulnerable to crackle when
    // the 4K video path is under pressure.
    NSDictionary<NSString *, id> *recommended =
        [self.audioOutput recommendedAudioSettingsForAssetWriterWithOutputFileType:AVFileTypeQuickTimeMovie];
    NSNumber *recommendedRate = recommended[AVSampleRateKey];
    NSNumber *recommendedChannels = recommended[AVNumberOfChannelsKey];
    if (recommended.count > 0 && recommendedRate.doubleValue > 0.0 &&
        recommendedChannels.unsignedIntegerValue > 0) {
        return recommended;
    }

    // The recommendation should be available once the session is running, but
    // retain a format-aware fallback for devices/drivers that do not provide
    // one. Read the active audio ASBD instead of assuming every microphone is
    // stereo.
    double sampleRate = 48000.0;
    NSUInteger channelCount = 1;
    AVCaptureDevice *audioDevice = self.audioInput.device;
    CMFormatDescriptionRef formatDescription = audioDevice.activeFormat.formatDescription;
    if (formatDescription &&
        CMFormatDescriptionGetMediaType(formatDescription) == kCMMediaType_Audio) {
        const AudioStreamBasicDescription *asbd =
            CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription);
        if (asbd) {
            if (asbd->mSampleRate > 0.0) sampleRate = asbd->mSampleRate;
            if (asbd->mChannelsPerFrame > 0) {
                channelCount = MIN((NSUInteger)2, (NSUInteger)asbd->mChannelsPerFrame);
            }
        }
    }

    return @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVNumberOfChannelsKey: @(channelCount),
        AVSampleRateKey: @(sampleRate),
        AVEncoderBitRateKey: @(channelCount == 1 ? 96000 : 160000),
        AVEncoderAudioQualityKey: @(AVAudioQualityHigh),
    };
}

- (void)resetAudioDiagnosticsForRecording {
    dispatch_sync(self.audioQueue, ^{
        self.expectedNextAudioPTS = kCMTimeInvalid;
        self.sourceAudioDiscontinuities = 0;
        self.sourceAudioGapFrames = 0;
    });
}

- (void)prepareWriterForCurrentSettings {
    NSString *baseName = [self recordingBaseName];
    NSString *tempPath = SpliceKitLiveCamUniquePath(SpliceKitLiveCamTemporaryDirectory(), [baseName stringByAppendingString:@".partial"], @"mov");
    NSString *finalPath = SpliceKitLiveCamUniquePath(SpliceKitLiveCamOutputDirectory(), baseName, @"mov");

    [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];

    self.temporaryRecordingURL = [NSURL fileURLWithPath:tempPath];
    self.finalRecordingURL = [NSURL fileURLWithPath:finalPath];
    self.recordingCanvasSize = SpliceKitLiveCamResolutionForKey(SpliceKitLiveCamString(self.resolutionPopup.selectedItem.representedObject));

    NSError *writerError = nil;
    self.assetWriter = [AVAssetWriter assetWriterWithURL:self.temporaryRecordingURL
                                                fileType:AVFileTypeQuickTimeMovie
                                                   error:&writerError];
    if (!self.assetWriter || writerError) {
        SpliceKit_log(@"[LiveCamRecord] Writer creation failed: %@", writerError.localizedDescription);
        self.assetWriter = nil;
        return;
    }

    // ProRes 4444 is the only QuickTime codec FCP imports with alpha out of the box,
    // so transparent recordings have to switch off H.264 — bit rate / profile keys
    // are H.264-only and would be rejected by the ProRes encoder.
    BOOL transparentRecording = [self selectedBackgroundMode] == SpliceKitLiveCamBackgroundModeGreenScreen
        && [[self selectedBackgroundColorKey] isEqualToString:@"transparent"];
    self.recordingIsTransparent = transparentRecording;
    NSDictionary *videoSettings;
    if (transparentRecording) {
        // Without kVTCompressionPropertyKey_AlphaChannelMode the ProRes encoder
        // reserves the alpha plane in the file (yuva444p12le) but writes 1.0 into
        // every pixel, ignoring the source buffer's A channel.
        videoSettings = @{
            AVVideoCodecKey: AVVideoCodecTypeAppleProRes4444,
            AVVideoWidthKey: @((NSInteger)self.recordingCanvasSize.width),
            AVVideoHeightKey: @((NSInteger)self.recordingCanvasSize.height),
            AVVideoCompressionPropertiesKey: @{
                (id)kVTCompressionPropertyKey_AlphaChannelMode: (id)kVTAlphaChannelMode_PremultipliedAlpha,
            },
        };
    } else {
        videoSettings = @{
            AVVideoCodecKey: AVVideoCodecTypeH264,
            AVVideoWidthKey: @((NSInteger)self.recordingCanvasSize.width),
            AVVideoHeightKey: @((NSInteger)self.recordingCanvasSize.height),
            AVVideoCompressionPropertiesKey: @{
                AVVideoAverageBitRateKey: @([self selectedBitRate]),
                AVVideoMaxKeyFrameIntervalKey: @30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            }
        };
    }
    self.videoWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    self.videoWriterInput.expectsMediaDataInRealTime = YES;
    self.videoWriterInput.transform = CGAffineTransformIdentity;

    NSDictionary *pixelBufferAttributes = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferWidthKey: @((NSInteger)self.recordingCanvasSize.width),
        (NSString *)kCVPixelBufferHeightKey: @((NSInteger)self.recordingCanvasSize.height),
        (NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    self.pixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:self.videoWriterInput
                                   sourcePixelBufferAttributes:pixelBufferAttributes];

    if ([self.assetWriter canAddInput:self.videoWriterInput]) {
        [self.assetWriter addInput:self.videoWriterInput];
    }

    if (self.microphoneAuthorized &&
        self.muteCheckbox.state != NSControlStateValueOn &&
        self.audioInput != nil) {
        NSDictionary<NSString *, id> *audioSettings = [self audioWriterSettingsForCurrentSession];
        self.audioWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
        self.audioWriterInput.expectsMediaDataInRealTime = YES;
        if ([self.assetWriter canAddInput:self.audioWriterInput]) {
            [self.assetWriter addInput:self.audioWriterInput];
            SpliceKit_log(@"[LiveCamAudio] writer format rate=%.0fHz channels=%lu codec=%@ bitrate=%@",
                          [audioSettings[AVSampleRateKey] doubleValue],
                          (unsigned long)[audioSettings[AVNumberOfChannelsKey] unsignedIntegerValue],
                          audioSettings[AVFormatIDKey] ?: @"",
                          audioSettings[AVEncoderBitRateKey] ?: @"");
        } else {
            self.audioWriterInput = nil;
        }
    } else {
        self.audioWriterInput = nil;
    }

    self.writerStartTime = kCMTimeInvalid;
    self.writerDidStart = NO;
    self.droppedVideoFrames = 0;
    self.droppedAudioFrames = 0;
    [self resetAudioDiagnosticsForRecording];

    SpliceKit_log(@"[LiveCamRecord] Writer prepared path=%@ final=%@ quality=%@ canvas=%.0fx%.0f",
                  self.temporaryRecordingURL.path,
                  self.finalRecordingURL.path,
                  self.qualityPopup.titleOfSelectedItem ?: @"",
                  self.recordingCanvasSize.width,
                  self.recordingCanvasSize.height);
}

- (void)startElapsedTimer {
    [self.elapsedTimer invalidate];
    self.elapsedTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                         target:self
                                                       selector:@selector(updateElapsedTime)
                                                       userInfo:nil
                                                        repeats:YES];
}

- (void)updateElapsedTime {
    if (!self.recordingStartDate) {
        self.elapsedLabel.stringValue = @"00:00:00";
        return;
    }
    NSInteger total = (NSInteger)round([[NSDate date] timeIntervalSinceDate:self.recordingStartDate]);
    NSInteger hours = total / 3600;
    NSInteger minutes = (total / 60) % 60;
    NSInteger seconds = total % 60;
    self.elapsedLabel.stringValue = [NSString stringWithFormat:@"%02ld:%02ld:%02ld",
                                     (long)hours, (long)minutes, (long)seconds];
}

- (void)recordClicked:(id)sender {
    if (self.recordingActive || self.finalizingRecording) return;
    if (!self.cameraAuthorized) {
        [self updateStatus:@"LiveCam needs camera permission before it can record."];
        return;
    }
    if (!self.session || !self.session.isRunning) {
        [self updateStatus:@"The camera session is not running yet. Wait for preview, then record."];
        return;
    }

    self.recordingDestination = [self selectedDestination];
    self.recordingPlacement = [self selectedTimelinePlacement];
    self.recordingSequenceIdentity = nil;
    self.recordingEventName = SpliceKitLiveCamTrimmedString(self.eventNameField.stringValue);
    self.recordingClipName = [self recordingBaseName];

    if (self.recordingDestination == SpliceKitLiveCamDestinationTimeline) {
        NSDictionary *identity = SpliceKitLiveCamCurrentTimelineIdentity();
        if (identity.count == 0) {
            SpliceKit_log(@"[LiveCamTimeline] No active timeline at record start; LiveCam will fall back to Library.");
            self.recordingDestination = SpliceKitLiveCamDestinationLibrary;
        } else {
            self.recordingSequenceIdentity = identity;
        }
    }

    [self prepareWriterForCurrentSettings];
    if (!self.assetWriter) {
        [self updateStatus:@"LiveCam could not create a writer for this recording."];
        return;
    }

    self.recordingActive = YES;
    self.finalizingRecording = NO;
    self.recordingStartDate = [NSDate date];
    [self startElapsedTimer];
    [self updateElapsedTime];
    [self updateStatus:[NSString stringWithFormat:@"Recording %@. Stop to finalize, import, and %@.",
                        self.recordingClipName,
                        self.recordingDestination == SpliceKitLiveCamDestinationTimeline ? @"place it on the timeline" : @"import it into the Library"]];
    [self updateSessionLabel:[NSString stringWithFormat:@"REC • %@ • %@",
                              self.resolutionPopup.titleOfSelectedItem ?: @"",
                              self.frameRatePopup.titleOfSelectedItem ?: @""]];
    [self updateControlsForState];

    SpliceKit_log(@"[LiveCamRecord] start clip=%@ camera=%@ mic=%@ preset=%@ destination=%@ placement=%ld",
                  self.recordingClipName,
                  self.cameraPopup.selectedItem.title ?: @"",
                  self.microphonePopup.selectedItem.title ?: @"",
                  [self selectedPreset].name ?: @"Clean",
                  self.recordingDestination == SpliceKitLiveCamDestinationTimeline ? @"timeline" : @"library",
                  (long)self.recordingPlacement);
}

- (void)finishWriterAndIngest {
    if (!self.assetWriter) {
        self.finalizingRecording = NO;
        [self updateControlsForState];
        return;
    }

    AVAssetWriter *writer = self.assetWriter;
    AVAssetWriterInput *videoInput = self.videoWriterInput;
    AVAssetWriterInput *audioInput = self.audioWriterInput;
    NSURL *tempURL = self.temporaryRecordingURL;
    NSURL *finalURL = self.finalRecordingURL;

    self.assetWriter = nil;
    self.videoWriterInput = nil;
    self.audioWriterInput = nil;
    self.pixelBufferAdaptor = nil;

    if (!self.writerDidStart) {
        [writer cancelWriting];
        [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.finalizingRecording = NO;
            self.elapsedLabel.stringValue = @"00:00:00";
            [self updateStatus:@"LiveCam stopped before any frames were written, so nothing was imported."];
            [self updateControlsForState];
        });
        return;
    }

    [videoInput markAsFinished];
    [audioInput markAsFinished];

    [writer finishWritingWithCompletionHandler:^{
        if (writer.status != AVAssetWriterStatusCompleted) {
            SpliceKit_log(@"[LiveCamRecord] finishWriting failed: %@", writer.error.localizedDescription);
            [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.finalizingRecording = NO;
                self.elapsedLabel.stringValue = @"00:00:00";
                [self updateStatus:[NSString stringWithFormat:@"Finalizing failed: %@",
                                    writer.error.localizedDescription ?: @"Unknown error"]];
                [self updateControlsForState];
            });
            return;
        }

        [[NSFileManager defaultManager] removeItemAtURL:finalURL error:nil];
        NSError *moveError = nil;
        if (![[NSFileManager defaultManager] moveItemAtURL:tempURL toURL:finalURL error:&moveError]) {
            SpliceKit_log(@"[LiveCamRecord] Failed to move final clip: %@", moveError.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.finalizingRecording = NO;
                [self updateStatus:[NSString stringWithFormat:@"Finalized, but could not move the clip: %@",
                                    moveError.localizedDescription ?: @"Unknown error"]];
                [self updateControlsForState];
            });
            return;
        }

        SpliceKit_log(@"[LiveCamRecord] finalized output=%@ droppedVideo=%lu droppedAudio=%lu sourceAudioDiscontinuities=%lu sourceAudioGapFrames=%lu audio=%.0fHz/%luch",
                      finalURL.path,
                      (unsigned long)self.droppedVideoFrames,
                      (unsigned long)self.droppedAudioFrames,
                      (unsigned long)self.sourceAudioDiscontinuities,
                      (unsigned long)self.sourceAudioGapFrames,
                      self.capturedAudioSampleRate,
                      (unsigned long)self.capturedAudioChannels);

        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateStatus:@"Finalizing complete. Importing into Final Cut Pro…"];
            [self updateSessionLabel:@"Importing…"];
        });

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSDictionary *result = [self ingestFinalizedRecordingAtURL:finalURL];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.finalizingRecording = NO;
                self.elapsedLabel.stringValue = @"00:00:00";
                [self updateStatus:SpliceKitLiveCamString(result[@"message"]).length > 0
                    ? result[@"message"]
                    : @"LiveCam finished."];
                NSString *readyCamera = [self.cameraPopup.titleOfSelectedItem ?: @"" stringByReplacingOccurrencesOfString:@" Camera" withString:@""];
                [self updateSessionLabel:[NSString stringWithFormat:@"Ready • %@ • %@",
                                          readyCamera.length > 0 ? readyCamera : (self.cameraPopup.titleOfSelectedItem ?: @""),
                                          self.microphonePopup.titleOfSelectedItem ?: @"No Microphone"]];
                [self updateControlsForState];
            });
        });
    }];
}

- (void)stopClicked:(id)sender {
    if (!self.recordingActive && !self.finalizingRecording) return;
    self.recordingActive = NO;
    self.finalizingRecording = YES;
    [self.elapsedTimer invalidate];
    self.elapsedTimer = nil;
    [self updateStatus:@"Stopping capture and finalizing the LiveCam clip…"];
    [self updateControlsForState];
    [self finishWriterAndIngest];
}

- (void)appendVideoFrame:(CIImage *)image atTime:(CMTime)presentationTime {
    if (!self.recordingActive || !self.assetWriter || !self.videoWriterInput || !self.pixelBufferAdaptor) return;
    if (!self.writerDidStart) {
        if (![self.assetWriter startWriting]) {
            SpliceKit_log(@"[LiveCamRecord] startWriting failed: %@", self.assetWriter.error.localizedDescription);
            self.droppedVideoFrames++;
            return;
        }
        [self.assetWriter startSessionAtSourceTime:presentationTime];
        self.writerDidStart = YES;
        self.writerStartTime = presentationTime;
        SpliceKit_log(@"[LiveCamRecord] session started at %.3fs", CMTimeGetSeconds(presentationTime));
    }

    if (!self.videoWriterInput.readyForMoreMediaData) {
        self.droppedVideoFrames++;
        return;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn createStatus = CVPixelBufferPoolCreatePixelBuffer(NULL,
                                                               self.pixelBufferAdaptor.pixelBufferPool,
                                                               &pixelBuffer);
    if (createStatus != kCVReturnSuccess || !pixelBuffer) {
        self.droppedVideoFrames++;
        return;
    }

    BOOL transparent = self.recordingIsTransparent;
    CIImage *fitted = [self.renderer imageFittedForCanvas:image
                                               canvasSize:self.recordingCanvasSize
                                                     fill:NO
                                            preserveAlpha:transparent];
    if (transparent) {
        // -[CIContext render:toCVPixelBuffer:bounds:colorSpace:] treats the destination
        // as opaque per Apple's docs and overwrites alpha to 1.0. CIRenderDestination
        // with alphaMode = Premultiplied is the only path that preserves source alpha.
        CIRenderDestination *dest = [[CIRenderDestination alloc] initWithPixelBuffer:pixelBuffer];
        dest.alphaMode = CIRenderDestinationAlphaPremultiplied;
        if (self.renderer.colorSpace) {
            dest.colorSpace = self.renderer.colorSpace;
        }
        NSError *renderErr = nil;
        CIRenderTask *task = [self.renderer.ciContext startTaskToRender:fitted
                                                          toDestination:dest
                                                                  error:&renderErr];
        if (task) {
            [task waitUntilCompletedAndReturnError:&renderErr];
        }
        if (renderErr) {
            SpliceKit_log(@"[LiveCamRecord] alpha render failed: %@", renderErr.localizedDescription);
        }
    } else {
        [self.renderer.ciContext render:fitted
                        toCVPixelBuffer:pixelBuffer
                                 bounds:CGRectMake(0, 0, self.recordingCanvasSize.width, self.recordingCanvasSize.height)
                             colorSpace:self.renderer.colorSpace];
    }

    if (![self.pixelBufferAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:presentationTime]) {
        self.droppedVideoFrames++;
    }
    CVPixelBufferRelease(pixelBuffer);
}

- (void)appendAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!self.recordingActive || !self.audioWriterInput || !self.writerDidStart) return;
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if (CMTIME_IS_VALID(self.writerStartTime) && CMTIME_COMPARE_INLINE(pts, <, self.writerStartTime)) {
        return;
    }
    if (!self.audioWriterInput.readyForMoreMediaData) {
        self.droppedAudioFrames++;
        return;
    }
    if (![self.audioWriterInput appendSampleBuffer:sampleBuffer]) {
        self.droppedAudioFrames++;
    }
}

@end
