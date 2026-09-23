//
//  SpliceKitLiveCamSegmentation.m
//  Person / subject segmentation for LiveCam backgrounds (Vision), producing the
//  mask the renderer composites with.
//

#import "SpliceKitLiveCam+Private.h"

@interface SpliceKitLiveCamSegmentationEngine ()
@property (nonatomic, strong) VNSequenceRequestHandler *requestHandler;
@property (nonatomic, strong) VNRequest *primaryRequest;
@property (nonatomic, strong) VNGeneratePersonSegmentationRequest *fallbackRequest;
@property (nonatomic, assign) CVPixelBufferRef latestMaskBuffer;
@property (nonatomic, assign, readwrite) BOOL supported;
@property (nonatomic, assign, readwrite) BOOL usingSubjectLift;
@property (nonatomic, copy, readwrite) NSString *lastError;
@property (nonatomic, assign) NSUInteger frameCounter;
@property (nonatomic, assign, readwrite) NSUInteger maskGeneration;
@end

@implementation SpliceKitLiveCamSegmentationEngine

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _quality = SpliceKitLiveCamSegmentationQualityBalanced;
    _requestHandler = [[VNSequenceRequestHandler alloc] init];

    // Subject Lift gives a much tighter, edge-aware matte than person segmentation
    // and works on objects, not just people — prefer it whenever the OS supports it.
    if (@available(macOS 14.0, *)) {
        _primaryRequest = [[VNGenerateForegroundInstanceMaskRequest alloc] init];
        _supported = YES;
        _usingSubjectLift = YES;
    } else if (@available(macOS 12.0, *)) {
        _fallbackRequest = [[VNGeneratePersonSegmentationRequest alloc] init];
        _fallbackRequest.qualityLevel = VNGeneratePersonSegmentationRequestQualityLevelAccurate;
        _fallbackRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8;
        _primaryRequest = _fallbackRequest;
        _supported = YES;
        _usingSubjectLift = NO;
    } else {
        _supported = NO;
        _lastError = @"Green Screen requires macOS 12 or newer.";
    }

    return self;
}

- (void)dealloc {
    if (_latestMaskBuffer) {
        CVPixelBufferRelease(_latestMaskBuffer);
        _latestMaskBuffer = nil;
    }
}

- (void)reset {
    self.frameCounter = 0;
    self.lastError = @"";
    if (self.latestMaskBuffer) {
        CVPixelBufferRelease(self.latestMaskBuffer);
        self.latestMaskBuffer = nil;
    }
    self.maskGeneration = 0;
}

- (void)setQuality:(SpliceKitLiveCamSegmentationQuality)quality {
    if (_quality == quality) return;
    _quality = quality;
    if (self.fallbackRequest) {
        switch (quality) {
            case SpliceKitLiveCamSegmentationQualityFast:
                self.fallbackRequest.qualityLevel = VNGeneratePersonSegmentationRequestQualityLevelFast;
                break;
            case SpliceKitLiveCamSegmentationQualityBalanced:
                self.fallbackRequest.qualityLevel = VNGeneratePersonSegmentationRequestQualityLevelBalanced;
                break;
            case SpliceKitLiveCamSegmentationQualityAccurate:
                self.fallbackRequest.qualityLevel = VNGeneratePersonSegmentationRequestQualityLevelAccurate;
                break;
        }
    }
}

// Quality presets pick the inference downsample factor. Vision dominates frame cost,
// so running on a smaller image and upscaling the mask is the dominant perf lever.
- (CGFloat)inferenceDownsampleFactor {
    switch (self.quality) {
        case SpliceKitLiveCamSegmentationQualityFast:     return 0.40;
        case SpliceKitLiveCamSegmentationQualityBalanced: return 0.60;
        case SpliceKitLiveCamSegmentationQualityAccurate: return 1.0;
    }
    return 0.6;
}

// Match inference cadence to the requested quality tier. The compositor still
// runs at camera frame rate and reuses the last materialized matte between
// Vision updates, so Fast saves substantial neural-engine/GPU work without
// making preview or recording cadence uneven.
- (NSUInteger)inferenceFrameInterval {
    switch (self.quality) {
        case SpliceKitLiveCamSegmentationQualityFast:     return 3;
        case SpliceKitLiveCamSegmentationQualityBalanced: return 2;
        case SpliceKitLiveCamSegmentationQualityAccurate: return 1;
    }
    return 2;
}

- (CIImage *)maskImageForSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!self.supported || !sampleBuffer || !self.primaryRequest) return nil;

    self.frameCounter += 1;
    NSUInteger inferenceInterval = [self inferenceFrameInterval];
    BOOL shouldAnalyze = (self.frameCounter <= 2) || (self.frameCounter % inferenceInterval == 0);
    if (shouldAnalyze) {
        CVPixelBufferRef maskBuffer = [self runInferenceForSampleBuffer:sampleBuffer];
        if (maskBuffer) {
            if (self.latestMaskBuffer) {
                CVPixelBufferRelease(self.latestMaskBuffer);
            }
            self.latestMaskBuffer = maskBuffer; // ownership transferred from runInference
            self.maskGeneration += 1;
            self.lastError = @"";
        }
    }

    if (!self.latestMaskBuffer) return nil;

    CIImage *mask = [CIImage imageWithCVPixelBuffer:self.latestMaskBuffer];
    if (!mask) return nil;
    CGRect extent = CGRectMake(0,
                               0,
                               CVPixelBufferGetWidth(self.latestMaskBuffer),
                               CVPixelBufferGetHeight(self.latestMaskBuffer));
    return [mask imageByCroppingToRect:extent];
}

// Returns a retained CVPixelBufferRef the caller owns, or NULL on failure.
- (CVPixelBufferRef)runInferenceForSampleBuffer:(CMSampleBufferRef)sampleBuffer CF_RETURNS_RETAINED {
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) return NULL;

    if (self.usingSubjectLift) {
        if (@available(macOS 14.0, *)) {
            return [self runSubjectLiftForImageBuffer:imageBuffer
                                       presentationTime:CMSampleBufferGetPresentationTimeStamp(sampleBuffer)];
        }
    }

    NSError *error = nil;
    BOOL ok = [self.requestHandler performRequests:@[self.primaryRequest]
                                  onCMSampleBuffer:sampleBuffer
                                             error:&error];
    if (!ok || error) {
        self.lastError = error.localizedDescription ?: @"Vision could not generate a person mask.";
        return NULL;
    }
    VNPixelBufferObservation *observation = (VNPixelBufferObservation *)self.primaryRequest.results.firstObject;
    CVPixelBufferRef result = observation.pixelBuffer;
    if (result) CVPixelBufferRetain(result);
    return result;
}

- (CVPixelBufferRef)runSubjectLiftForImageBuffer:(CVImageBufferRef)imageBuffer
                                presentationTime:(CMTime)pts CF_RETURNS_RETAINED API_AVAILABLE(macos(14.0)) {
    if (!imageBuffer) return NULL;

    // Run inference on a downsampled CIImage to cut Vision cost. The returned
    // CGImage is then upscaled by the renderer's joint-bilateral kernel using
    // the full-res guide image, so the mask edge stays sharp at output res.
    CIImage *full = [CIImage imageWithCVPixelBuffer:imageBuffer];
    if (!full) return NULL;
    CGFloat factor = [self inferenceDownsampleFactor];
    CIImage *scaled = full;
    if (factor < 0.999) {
        scaled = [full imageByApplyingFilter:@"CILanczosScaleTransform"
                         withInputParameters:@{kCIInputScaleKey: @(factor),
                                                kCIInputAspectRatioKey: @1.0}];
    }

    NSDictionary *handlerOptions = @{};
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCIImage:scaled
                                                                            options:handlerOptions];
    NSError *error = nil;
    VNGenerateForegroundInstanceMaskRequest *request = (VNGenerateForegroundInstanceMaskRequest *)self.primaryRequest;
    if (![handler performRequests:@[request] error:&error]) {
        self.lastError = error.localizedDescription ?: @"Subject Lift could not generate a mask.";
        return NULL;
    }

    VNInstanceMaskObservation *observation = (VNInstanceMaskObservation *)request.results.firstObject;
    if (!observation) {
        // No subject in frame — return a zero mask at the full source size so the
        // composite cleanly shows the background instead of falling back to the previous frame.
        return [self emptyMaskMatchingImageBuffer:imageBuffer];
    }

    NSError *maskError = nil;
    CVPixelBufferRef maskBuffer = [observation generateScaledMaskForImageForInstances:observation.allInstances
                                                                     fromRequestHandler:handler
                                                                                  error:&maskError];
    if (!maskBuffer || maskError) {
        self.lastError = maskError.localizedDescription ?: @"Subject Lift mask generation failed.";
        return NULL;
    }
    // generateScaledMaskForImageForInstances: returns a retained buffer.
    return maskBuffer;
}

- (CVPixelBufferRef)emptyMaskMatchingImageBuffer:(CVImageBufferRef)imageBuffer CF_RETURNS_RETAINED {
    size_t w = CVPixelBufferGetWidth(imageBuffer);
    size_t h = CVPixelBufferGetHeight(imageBuffer);
    CVPixelBufferRef out = NULL;
    NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    CVReturn rc = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                      kCVPixelFormatType_OneComponent8,
                                      (__bridge CFDictionaryRef)attrs, &out);
    if (rc != kCVReturnSuccess || !out) return NULL;
    CVPixelBufferLockBaseAddress(out, 0);
    void *base = CVPixelBufferGetBaseAddress(out);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(out);
    memset(base, 0, bytesPerRow * h);
    CVPixelBufferUnlockBaseAddress(out, 0);
    return out;
}

@end
