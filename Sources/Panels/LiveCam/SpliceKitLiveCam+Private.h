//
//  SpliceKitLiveCam+Private.h
//  Private declarations shared by SpliceKitLiveCam.m and the files split out of it
//  (listed in SOURCES.txt right after it).
//  The functions and variables below were file-static before SpliceKitLiveCam.m
//  was split. They are declared hidden so they stay out of the dylib's exported symbols.
//

#ifndef SpliceKitLiveCam_Private_h
#define SpliceKitLiveCam_Private_h

// The imports SpliceKitLiveCam.m has always been compiled with.
#import "SpliceKitLiveCam.h"
#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Vision/Vision.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import "SpliceKitTime.h"
#import "SpliceKitStrings.h"

typedef NS_ENUM(NSInteger, SpliceKitLiveCamDestination) {
    SpliceKitLiveCamDestinationLibrary = 0,
    SpliceKitLiveCamDestinationTimeline = 1,
};

@interface SpliceKitLiveCamFlippedView : NSView
@end

@interface SpliceKitLiveCamAudioMeterView : NSView
@property (nonatomic, assign) double rmsDB;
@property (nonatomic, assign) double peakDB;
@property (nonatomic, assign) double heldPeakDB;
@property (nonatomic, assign) NSTimeInterval peakHoldUntil;
@property (nonatomic, assign) NSTimeInterval clipHoldUntil;
- (void)updateWithRMSDB:(double)rmsDB peakDB:(double)peakDB;
- (void)reset;
@end

typedef NS_ENUM(NSInteger, SpliceKitLiveCamTimelinePlacement) {
    SpliceKitLiveCamTimelinePlacementAppend = 0,
    SpliceKitLiveCamTimelinePlacementInsertAtPlayhead = 1,
    SpliceKitLiveCamTimelinePlacementConnectedAbove = 2,
};

typedef NS_ENUM(NSInteger, SpliceKitLiveCamBackgroundMode) {
    SpliceKitLiveCamBackgroundModeNone = 0,
    SpliceKitLiveCamBackgroundModeSystemBlur = 1,
    SpliceKitLiveCamBackgroundModeGreenScreen = 2,
};

@interface SpliceKitLiveCamPreset : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *category;
@property (nonatomic, copy) NSString *summary;
@property (nonatomic, assign) BOOL premium;
+ (instancetype)presetWithIdentifier:(NSString *)identifier
                                name:(NSString *)name
                            category:(NSString *)category
                             summary:(NSString *)summary
                             premium:(BOOL)premium;
@end

@interface SpliceKitLiveCamAdjustmentState : NSObject <NSCopying>
@property (nonatomic, assign) CGFloat intensity;
@property (nonatomic, assign) CGFloat exposure;
@property (nonatomic, assign) CGFloat contrast;
@property (nonatomic, assign) CGFloat saturation;
@property (nonatomic, assign) CGFloat temperature;
@property (nonatomic, assign) CGFloat sharpness;
@property (nonatomic, assign) CGFloat glow;
@end

typedef NS_ENUM(NSInteger, SpliceKitLiveCamSegmentationQuality) {
    SpliceKitLiveCamSegmentationQualityFast = 0,
    SpliceKitLiveCamSegmentationQualityBalanced = 1,
    SpliceKitLiveCamSegmentationQualityAccurate = 2,
};

@interface SpliceKitLiveCamSegmentationEngine : NSObject
@property (nonatomic, assign, readonly) BOOL supported;
@property (nonatomic, assign, readonly) BOOL usingSubjectLift;
@property (nonatomic, copy, readonly) NSString *lastError;
@property (nonatomic, assign, readonly) NSUInteger maskGeneration;
@property (nonatomic, assign) SpliceKitLiveCamSegmentationQuality quality;
- (CIImage *)maskImageForSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)reset;
@end

@interface SpliceKitLiveCamMaskParams : NSObject
@property (nonatomic, assign) CGFloat edgeSoftness;  // 0..1, gaussian feather radius scale
@property (nonatomic, assign) CGFloat refinement;    // 0..1, joint-bilateral edge refinement
@property (nonatomic, assign) CGFloat choke;         // -1..1, negative dilates / positive erodes
@property (nonatomic, assign) CGFloat spill;         // 0..1, edge desaturation strength
@property (nonatomic, assign) CGFloat wrap;          // 0..1, background light bleed into edge
@property (nonatomic, assign) CGFloat temporalSmoothing; // 0..1, EMA factor against previous mask
@property (nonatomic, assign) BOOL transparentBackground; // when YES, output premultiplied alpha
@property (nonatomic, assign) NSUInteger sourceGeneration;
@end

@interface SpliceKitLiveCamRenderer : NSObject
@property (nonatomic, strong, readonly) CIContext *ciContext;
@property (nonatomic, strong, readonly) id<MTLCommandQueue> commandQueue;
@property (nonatomic, assign, readonly) CGColorSpaceRef colorSpace;
- (CIImage *)renderedImageFromImage:(CIImage *)image
                             preset:(SpliceKitLiveCamPreset *)preset
                               time:(NSTimeInterval)time
                        adjustments:(SpliceKitLiveCamAdjustmentState *)adjustments
                          maskImage:(CIImage *)maskImage
                         maskParams:(SpliceKitLiveCamMaskParams *)maskParams
                    backgroundColor:(CIColor *)backgroundColor
                           mirrored:(BOOL)mirrored
                          recording:(BOOL)recording
                         canvasSize:(CGSize)canvasSize;
- (CIImage *)imageFittedForCanvas:(CIImage *)image
                       canvasSize:(CGSize)canvasSize
                             fill:(BOOL)fill;
- (CIImage *)imageFittedForCanvas:(CIImage *)image
                       canvasSize:(CGSize)canvasSize
                             fill:(BOOL)fill
                    preserveAlpha:(BOOL)preserveAlpha;
- (CIImage *)imageByCompositingOverPreviewCheckerboard:(CIImage *)alphaImage;
- (void)resetMaskHistory;
@property (nonatomic, strong, readonly) CIImage *previousMaskForBlend;
@end

@interface SpliceKitLiveCamRenderer ()
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, strong) id<MTLDevice> metalDevice;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, assign) CGColorSpaceRef colorSpace;
@property (nonatomic, strong) NSMutableDictionary<NSString *, CIKernel *> *kernels;
@property (nonatomic, strong) NSMutableDictionary<NSString *, CIImage *> *overlayCache;
@property (nonatomic, strong) NSMutableArray<CIImage *> *trailFrames;
@property (nonatomic, strong) CIImage *previousMaskForBlend;
@property (nonatomic, assign) CVPixelBufferPoolRef maskHistoryPool;
@property (nonatomic, assign) size_t maskHistoryWidth;
@property (nonatomic, assign) size_t maskHistoryHeight;
@property (nonatomic, assign) NSUInteger maskHistoryFrames;
@property (nonatomic, assign) NSUInteger previousMaskSourceGeneration;
@property (nonatomic, assign) CGFloat previousMaskEdgeSoftness;
@property (nonatomic, assign) CGFloat previousMaskRefinement;
@property (nonatomic, assign) CGFloat previousMaskChoke;
@property (nonatomic, assign) CGFloat previousMaskTemporalSmoothing;
@property (nonatomic, assign) BOOL previousMaskConfigurationValid;
@end

@interface SpliceKitLiveCamPanel () <AVCaptureVideoDataOutputSampleBufferDelegate,
                                     AVCaptureAudioDataOutputSampleBufferDelegate,
                                     MTKViewDelegate,
                                     NSWindowDelegate,
                                     NSTextFieldDelegate>
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) MTKView *previewView;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTextField *presetLabel;
@property (nonatomic, strong) NSTextField *elapsedLabel;
@property (nonatomic, strong) NSTextField *sessionLabel;
@property (nonatomic, strong) NSButton *permissionButton;
@property (nonatomic, strong) NSTextField *lookDescriptionLabel;
@property (nonatomic, strong) NSTextField *destinationHintLabel;
@property (nonatomic, strong) NSTextField *backgroundInfoLabel;
@property (nonatomic, strong) NSTextField *backgroundStatusLabel;
@property (nonatomic, strong) NSTextField *nameHintLabel;
@property (nonatomic, strong) SpliceKitLiveCamAudioMeterView *audioMeter;
@property (nonatomic, strong) NSPopUpButton *lookCategoryPopup;
@property (nonatomic, strong) NSPopUpButton *lookPresetPopup;
@property (nonatomic, strong) NSPopUpButton *backgroundModePopup;
@property (nonatomic, strong) NSPopUpButton *backgroundColorPopup;
@property (nonatomic, strong) NSPopUpButton *cameraPopup;
@property (nonatomic, strong) NSPopUpButton *microphonePopup;
@property (nonatomic, strong) NSPopUpButton *resolutionPopup;
@property (nonatomic, strong) NSPopUpButton *frameRatePopup;
@property (nonatomic, strong) NSPopUpButton *qualityPopup;
@property (nonatomic, strong) NSPopUpButton *timelinePlacementPopup;
@property (nonatomic, strong) NSSegmentedControl *destinationControl;
@property (nonatomic, strong) NSTextField *clipNameField;
@property (nonatomic, strong) NSTextField *eventNameField;
@property (nonatomic, strong) NSSlider *backgroundEdgeSlider;
@property (nonatomic, strong) NSSlider *backgroundRefinementSlider;
@property (nonatomic, strong) NSSlider *backgroundChokeSlider;
@property (nonatomic, strong) NSSlider *backgroundSpillSlider;
@property (nonatomic, strong) NSSlider *backgroundWrapSlider;
@property (nonatomic, strong) NSPopUpButton *backgroundQualityPopup;
@property (nonatomic, strong) NSSlider *intensitySlider;
@property (nonatomic, strong) NSSlider *exposureSlider;
@property (nonatomic, strong) NSSlider *contrastSlider;
@property (nonatomic, strong) NSSlider *saturationSlider;
@property (nonatomic, strong) NSSlider *temperatureSlider;
@property (nonatomic, strong) NSSlider *sharpnessSlider;
@property (nonatomic, strong) NSSlider *glowSlider;
@property (nonatomic, strong) NSButton *mirrorCheckbox;
@property (nonatomic, strong) NSButton *muteCheckbox;
@property (nonatomic, strong) NSButton *timestampOverlayCheckbox;
@property (nonatomic, strong) NSButton *openVideoEffectsButton;
@property (nonatomic, strong) NSButton *advancedToggleButton;
@property (nonatomic, strong) NSButton *recordButton;
@property (nonatomic, strong) NSButton *stopButton;
@property (nonatomic, strong) NSView *advancedContainer;
@property (nonatomic, strong) NSView *advancedSectionCard;
@property (nonatomic, strong) NSView *advancedKeyingGroup;
@property (nonatomic, strong) NSView *mainColumn;
@property (nonatomic, strong) NSView *timelinePlacementRow;
@property (nonatomic, strong) NSView *backgroundColorRow;
@property (nonatomic, strong) NSView *backgroundEdgeRow;
@property (nonatomic, strong) NSArray<AVCaptureDevice *> *videoDevices;
@property (nonatomic, strong) NSArray<AVCaptureDevice *> *audioDevices;
@property (nonatomic, strong) NSArray<SpliceKitLiveCamPreset *> *presets;
@property (nonatomic, strong) NSArray<NSString *> *presetCategories;
@property (nonatomic, strong) SpliceKitLiveCamRenderer *renderer;
@property (nonatomic, strong) SpliceKitLiveCamSegmentationEngine *segmentationEngine;
@property (nonatomic, strong) SpliceKitLiveCamAdjustmentState *adjustments;
@property (nonatomic, strong) dispatch_queue_t sessionQueue;
@property (nonatomic, strong) dispatch_queue_t videoQueue;
@property (nonatomic, strong) dispatch_queue_t audioQueue;
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureDeviceInput *videoInput;
@property (nonatomic, strong) AVCaptureDeviceInput *audioInput;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoOutput;
@property (nonatomic, strong) AVCaptureAudioDataOutput *audioOutput;
@property (nonatomic, strong) CIImage *latestPreviewImage;
@property (nonatomic, assign) BOOL previewDrawPending;
@property (nonatomic, assign) BOOL cameraAuthorized;
@property (nonatomic, assign) BOOL microphoneAuthorized;
@property (nonatomic, assign) BOOL recordingActive;
@property (nonatomic, assign) BOOL finalizingRecording;
@property (nonatomic, assign) BOOL writerDidStart;
@property (nonatomic, assign) CMTime writerStartTime;
@property (nonatomic, strong) AVAssetWriter *assetWriter;
@property (nonatomic, strong) AVAssetWriterInput *videoWriterInput;
@property (nonatomic, strong) AVAssetWriterInput *audioWriterInput;
@property (nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor *pixelBufferAdaptor;
@property (nonatomic, assign) CGSize recordingCanvasSize;
@property (nonatomic, assign) BOOL recordingIsTransparent;
@property (nonatomic, strong) NSURL *temporaryRecordingURL;
@property (nonatomic, strong) NSURL *finalRecordingURL;
@property (nonatomic, strong) NSDictionary *recordingSequenceIdentity;
@property (nonatomic, assign) SpliceKitLiveCamDestination recordingDestination;
@property (nonatomic, assign) SpliceKitLiveCamTimelinePlacement recordingPlacement;
@property (nonatomic, copy) NSString *recordingClipName;
@property (nonatomic, copy) NSString *recordingEventName;
@property (nonatomic, strong) NSTimer *elapsedTimer;
@property (nonatomic, strong) NSDate *recordingStartDate;
@property (nonatomic, assign) NSUInteger droppedVideoFrames;
@property (nonatomic, assign) NSUInteger droppedAudioFrames;
@property (atomic, assign) NSUInteger sourceAudioDiscontinuities;
@property (atomic, assign) NSUInteger sourceAudioGapFrames;
@property (atomic, assign) double capturedAudioSampleRate;
@property (atomic, assign) NSUInteger capturedAudioChannels;
@property (nonatomic, assign) CMTime expectedNextAudioPTS;
@property (nonatomic, assign) BOOL audioFormatLogged;
@property (nonatomic, assign) NSTimeInterval lastAudioMeterDispatchTime;
@property (atomic, assign) NSUInteger audioMeterBuffersReceived;
@property (atomic, assign) NSUInteger audioMeterDecodedSamples;
@property (atomic, assign) OSStatus audioMeterLastError;
@property (nonatomic, assign) NSUInteger perfFrameCount;
@property (nonatomic, assign) double perfFrameMsSum;
@property (nonatomic, assign) double perfFrameMsMax;
@property (nonatomic, assign) NSTimeInterval perfLastLogTime;
@property (nonatomic, assign) double smoothedAudioLevel;
@property (nonatomic, assign) BOOL systemBlurSupported;
@property (nonatomic, assign) BOOL systemBlurActive;
@property (nonatomic, assign) BOOL centerStageSupported;
@property (nonatomic, assign) BOOL centerStageActive;
@property (nonatomic, assign) BOOL studioLightActive;
@property (nonatomic, assign) BOOL advancedVisible;
@property (nonatomic, copy) NSArray<NSString *> *availableResolutionKeys;
@property (nonatomic, copy) NSDictionary<NSString *, NSArray<NSNumber *> *> *availableFrameRatesByResolution;
@end

#pragma GCC visibility push(hidden)

#pragma mark - Defined in SpliceKitLiveCam.m

extern NSString * const kLiveCamVideoDeviceKey;
extern NSString * const kLiveCamAudioDeviceKey;
extern NSString * const kLiveCamNoMicrophoneIdentifier;
extern NSString * const kLiveCamResolutionKey;
extern NSString * const kLiveCamFrameRateKey;
extern NSString * const kLiveCamQualityKey;
extern NSString * const kLiveCamMirrorKey;
extern NSString * const kLiveCamMuteKey;
extern NSString * const kLiveCamDestinationKey;
extern NSString * const kLiveCamPlacementKey;
extern NSString * const kLiveCamEventNameKey;
extern NSString * const kLiveCamTimestampOverlayKey;
extern NSString * const kLiveCamBackgroundModeKey;
extern NSString * const kLiveCamBackgroundColorKey;
extern NSString * const kLiveCamBackgroundEdgeSoftnessKey;
extern NSString * const kLiveCamBackgroundRefinementKey;
extern NSString * const kLiveCamBackgroundChokeKey;
extern NSString * const kLiveCamBackgroundSpillKey;
extern NSString * const kLiveCamBackgroundWrapKey;
extern NSString * const kLiveCamBackgroundQualityKey;
NSString *SpliceKitLiveCamString(id value);
double SpliceKitLiveCamResidentMB(void);
NSString *SpliceKitLiveCamTrimmedString(id value);
NSString *SpliceKitLiveCamSanitizeFilename(NSString *input);
BOOL SpliceKitLiveCamPresetSupportsTimestampOverlay(NSString *identifier);
BOOL SpliceKitLiveCamTimestampOverlayEnabled(void);
NSString *SpliceKitLiveCamOutputDirectory(void);
NSString *SpliceKitLiveCamTemporaryDirectory(void);
NSString *SpliceKitLiveCamTimestampForFilename(NSDate *date);
NSString *SpliceKitLiveCamUniquePath(NSString *directory,
                                     NSString *baseName,
                                     NSString *extension);
CGSize SpliceKitLiveCamResolutionForKey(NSString *key);
NSString *SpliceKitLiveCamResolutionKeyForDimensions(CGFloat width, CGFloat height);
NSString *SpliceKitLiveCamResolutionTitleForKey(NSString *key);
AVCaptureSessionPreset SpliceKitLiveCamSessionPresetForResolution(CGSize size);
NSString *SpliceKitLiveCamFrameDurationString(double fps);

#pragma mark - Defined in SpliceKitLiveCamEffects.m

CIColor *SpliceKitLiveCamBackgroundCIColor(NSString *key);

#pragma mark - Defined in SpliceKitLiveCam+Ingest.m

NSDictionary *SpliceKitLiveCamCurrentTimelineIdentity(void);

#pragma GCC visibility pop

// Implemented in SpliceKitLiveCam.m, called from another file.
@interface SpliceKitLiveCamPanel ()
- (NSString *)selectedPresetIdentifier;
- (void)storeSelectedPresetIdentifier:(NSString *)identifier;
- (SpliceKitLiveCamPreset *)selectedPreset;
- (BOOL)selectedTimestampOverlayEnabled;
- (SpliceKitLiveCamDestination)selectedDestination;
- (SpliceKitLiveCamTimelinePlacement)selectedTimelinePlacement;
- (SpliceKitLiveCamBackgroundMode)selectedBackgroundMode;
- (void)persistDefaults;
@end

// Implemented in SpliceKitLiveCam+Ingest.m, called from another file.
@interface SpliceKitLiveCamPanel (Ingest)
- (NSDictionary *)ingestFinalizedRecordingAtURL:(NSURL *)url;
@end

// Implemented in SpliceKitLiveCam+UI.m, called from another file.
@interface SpliceKitLiveCamPanel (UI)
- (void)setupPanelIfNeeded;
- (NSString *)selectedBackgroundColorKey;
- (void)refreshBackgroundUI;
- (void)refreshAdvancedUI;
- (void)refreshNameHint;
- (void)postVisibilityChange;
- (void)updateStatus:(NSString *)status;
- (void)updateSessionLabel:(NSString *)text;
- (void)updateControlsForState;
@end

// Implemented in SpliceKitLiveCam+Capture.m, called from another file.
@interface SpliceKitLiveCamPanel (Capture)
- (void)reloadDevices;
- (void)requestPermissionsAndStartPreviewIfPossible;
- (AVCaptureDevice *)selectedVideoDevice;
- (void)refreshFrameRateOptionsPreservingSelection:(NSNumber *)preferredFPS;
- (void)refreshResolutionOptionsPreservingSelection:(NSString *)preferredResolution
                                          frameRate:(NSNumber *)preferredFPS;
- (void)reconfigurePreviewSession;
- (void)stopPreviewSession;
@end

// Implemented in SpliceKitLiveCam+Recording.m, called from another file.
@interface SpliceKitLiveCamPanel (Recording)
- (void)stopClicked:(id)sender;
- (void)appendVideoFrame:(CIImage *)image atTime:(CMTime)presentationTime;
- (void)appendAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer;
@end

#endif /* SpliceKitLiveCam_Private_h */
