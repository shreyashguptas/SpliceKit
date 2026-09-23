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
#import "SpliceKitLiveCam+Private.h"

NSString * const SpliceKitLiveCamVisibilityDidChangeNotification =
    @"SpliceKitLiveCamVisibilityDidChangeNotification";

NSString * const kLiveCamVideoDeviceKey = @"SpliceKitLiveCam.VideoDevice";
NSString * const kLiveCamAudioDeviceKey = @"SpliceKitLiveCam.AudioDevice";
NSString * const kLiveCamNoMicrophoneIdentifier = @"__splicekit_livecam_no_microphone__";
NSString * const kLiveCamResolutionKey = @"SpliceKitLiveCam.Resolution";
NSString * const kLiveCamFrameRateKey = @"SpliceKitLiveCam.FrameRate";
NSString * const kLiveCamQualityKey = @"SpliceKitLiveCam.Quality";
static NSString * const kLiveCamPresetKey = @"SpliceKitLiveCam.Preset";
NSString * const kLiveCamMirrorKey = @"SpliceKitLiveCam.Mirror";
NSString * const kLiveCamMuteKey = @"SpliceKitLiveCam.Mute";
NSString * const kLiveCamDestinationKey = @"SpliceKitLiveCam.Destination";
NSString * const kLiveCamPlacementKey = @"SpliceKitLiveCam.Placement";
static NSString * const kLiveCamClipNameKey = @"SpliceKitLiveCam.ClipName";
NSString * const kLiveCamEventNameKey = @"SpliceKitLiveCam.EventName";
static NSString * const kLiveCamIntensityKey = @"SpliceKitLiveCam.Intensity";
static NSString * const kLiveCamExposureKey = @"SpliceKitLiveCam.Exposure";
static NSString * const kLiveCamContrastKey = @"SpliceKitLiveCam.Contrast";
static NSString * const kLiveCamSaturationKey = @"SpliceKitLiveCam.Saturation";
static NSString * const kLiveCamTemperatureKey = @"SpliceKitLiveCam.Temperature";
static NSString * const kLiveCamSharpnessKey = @"SpliceKitLiveCam.Sharpness";
static NSString * const kLiveCamGlowKey = @"SpliceKitLiveCam.Glow";
NSString * const kLiveCamTimestampOverlayKey = @"SpliceKitLiveCam.TimestampOverlay";
NSString * const kLiveCamBackgroundModeKey = @"SpliceKitLiveCam.BackgroundMode";
NSString * const kLiveCamBackgroundColorKey = @"SpliceKitLiveCam.BackgroundColor";
NSString * const kLiveCamBackgroundEdgeSoftnessKey = @"SpliceKitLiveCam.BackgroundEdgeSoftness";
NSString * const kLiveCamBackgroundRefinementKey = @"SpliceKitLiveCam.BackgroundRefinement";
NSString * const kLiveCamBackgroundChokeKey = @"SpliceKitLiveCam.BackgroundChoke";
NSString * const kLiveCamBackgroundSpillKey = @"SpliceKitLiveCam.BackgroundSpill";
NSString * const kLiveCamBackgroundWrapKey = @"SpliceKitLiveCam.BackgroundWrap";
NSString * const kLiveCamBackgroundQualityKey = @"SpliceKitLiveCam.BackgroundQuality";
static NSString * const kLiveCamAdvancedVisibleKey = @"SpliceKitLiveCam.AdvancedVisible";

@implementation SpliceKitLiveCamPreset

+ (instancetype)presetWithIdentifier:(NSString *)identifier
                                name:(NSString *)name
                            category:(NSString *)category
                             summary:(NSString *)summary
                             premium:(BOOL)premium {
    SpliceKitLiveCamPreset *preset = [[self alloc] init];
    preset.identifier = identifier ?: @"clean";
    preset.name = name ?: @"Clean";
    preset.category = category ?: @"Clean";
    preset.summary = summary ?: @"";
    preset.premium = premium;
    return preset;
}

@end

@implementation SpliceKitLiveCamAdjustmentState

- (id)copyWithZone:(NSZone *)zone {
    SpliceKitLiveCamAdjustmentState *copy = [[[self class] allocWithZone:zone] init];
    copy.intensity = self.intensity;
    copy.exposure = self.exposure;
    copy.contrast = self.contrast;
    copy.saturation = self.saturation;
    copy.temperature = self.temperature;
    copy.sharpness = self.sharpness;
    copy.glow = self.glow;
    return copy;
}

@end

NSString *SpliceKitLiveCamString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

// Resident memory footprint of the current process in MB. Used by perf logging
// to surface mask-chain accumulation (which isn't heap-allocated itself but
// keeps CIContext intermediates + Metal textures resident).
double SpliceKitLiveCamResidentMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    if (kr != KERN_SUCCESS) return -1.0;
    return (double)info.phys_footprint / (1024.0 * 1024.0);
}

NSString *SpliceKitLiveCamTrimmedString(id value) {
    return [SpliceKitLiveCamString(value)
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

NSString *SpliceKitLiveCamSanitizeFilename(NSString *input) {
    NSString *trimmed = SpliceKitLiveCamTrimmedString(input);
    if (trimmed.length == 0) return @"LiveCam";

    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/:\\?%*|\"<>"];
    NSArray<NSString *> *parts = [trimmed componentsSeparatedByCharactersInSet:bad];
    NSString *joined = [[parts componentsJoinedByString:@"-"]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    while ([joined containsString:@"  "]) {
        joined = [joined stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    while ([joined containsString:@"--"]) {
        joined = [joined stringByReplacingOccurrencesOfString:@"--" withString:@"-"];
    }

    return joined.length > 0 ? joined : @"LiveCam";
}

NSString *SpliceKitLiveCamEscapeXML(NSString *input) {
    NSString *text = SpliceKitLiveCamString(input);
    text = [text stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    text = [text stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
    text = [text stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    text = [text stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
    text = [text stringByReplacingOccurrencesOfString:@"'" withString:@"&apos;"];
    return text;
}

BOOL SpliceKitLiveCamPresetSupportsTimestampOverlay(NSString *identifier) {
    return [identifier isEqualToString:@"securityCam"] ||
           [identifier isEqualToString:@"oldCamcorder"] ||
           [identifier isEqualToString:@"badVideoCall"];
}

BOOL SpliceKitLiveCamTimestampOverlayEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id stored = [defaults objectForKey:kLiveCamTimestampOverlayKey];
    if (!stored) return YES;
    return [defaults boolForKey:kLiveCamTimestampOverlayKey];
}

static NSString *SpliceKitLiveCamEnsureDirectory(NSString *path) {
    if (path.length == 0) return @"";
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return path;
}

NSString *SpliceKitLiveCamOutputDirectory(void) {
    return SpliceKitLiveCamEnsureDirectory([NSHomeDirectory()
        stringByAppendingPathComponent:@"Movies/SpliceKit/LiveCam"]);
}

NSString *SpliceKitLiveCamTemporaryDirectory(void) {
    return SpliceKitLiveCamEnsureDirectory([NSHomeDirectory()
        stringByAppendingPathComponent:@"Library/Application Support/SpliceKit/LiveCam/Temp"]);
}

NSString *SpliceKitLiveCamTimestampForFilename(NSDate *date) {
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"yyyyMMdd_HHmmss";
    });
    return [formatter stringFromDate:date ?: [NSDate date]] ?: @"00000000_000000";
}

NSString *SpliceKitLiveCamUniquePath(NSString *directory,
                                            NSString *baseName,
                                            NSString *extension) {
    NSString *safeBase = SpliceKitLiveCamSanitizeFilename(baseName);
    NSString *safeExt = extension.length > 0 ? extension : @"mov";
    NSString *candidate = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.%@", safeBase, safeExt]];
    NSInteger suffix = 1;
    while ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
        candidate = [directory stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@-%ld.%@", safeBase, (long)suffix, safeExt]];
        suffix++;
    }
    return candidate;
}

CGSize SpliceKitLiveCamResolutionForKey(NSString *key) {
    NSString *resolution = key.length > 0 ? key : @"1280x720";
    NSArray<NSString *> *parts = [resolution componentsSeparatedByString:@"x"];
    if (parts.count == 2) {
        CGFloat width = (CGFloat)[parts[0] integerValue];
        CGFloat height = (CGFloat)[parts[1] integerValue];
        if (width > 0 && height > 0) {
            return CGSizeMake(width, height);
        }
    }
    return CGSizeMake(1280, 720);
}

NSString *SpliceKitLiveCamResolutionKeyForDimensions(CGFloat width, CGFloat height) {
    if (width <= 0.0 || height <= 0.0) return @"";
    return [NSString stringWithFormat:@"%ldx%ld", (long)lrint(width), (long)lrint(height)];
}

NSString *SpliceKitLiveCamResolutionTitleForKey(NSString *key) {
    CGSize size = SpliceKitLiveCamResolutionForKey(key);
    if (fabs(size.width - 3840.0) < 1.0 && fabs(size.height - 2160.0) < 1.0) {
        return @"3840x2160 (4K)";
    }
    if (fabs(size.width - 2560.0) < 1.0 && fabs(size.height - 1440.0) < 1.0) {
        return @"2560x1440 (1440p)";
    }
    if (fabs(size.width - 1920.0) < 1.0 && fabs(size.height - 1080.0) < 1.0) {
        return @"1920x1080 (1080p)";
    }
    if (fabs(size.width - 1280.0) < 1.0 && fabs(size.height - 720.0) < 1.0) {
        return @"1280x720 (720p)";
    }
    return [NSString stringWithFormat:@"%ldx%ld", (long)lrint(size.width), (long)lrint(size.height)];
}

AVCaptureSessionPreset SpliceKitLiveCamSessionPresetForResolution(CGSize size) {
    if (fabs(size.width - 3840.0) < 1.0 && fabs(size.height - 2160.0) < 1.0) {
        return AVCaptureSessionPreset3840x2160;
    }
    if (fabs(size.width - 1920.0) < 1.0 && fabs(size.height - 1080.0) < 1.0) {
        return AVCaptureSessionPreset1920x1080;
    }
    if (fabs(size.width - 1280.0) < 1.0 && fabs(size.height - 720.0) < 1.0) {
        return AVCaptureSessionPreset1280x720;
    }
    return AVCaptureSessionPresetHigh;
}

NSString *SpliceKitLiveCamFrameDurationString(double fps) {
    if (fps <= 0.0) return @"100/2400s";
    int timescale = 2400;
    int value = MAX(1, (int)lrint((double)timescale / fps));
    return [NSString stringWithFormat:@"%d/%ds", value, timescale];
}

@implementation SpliceKitLiveCamPanel

+ (instancetype)sharedPanel {
    static SpliceKitLiveCamPanel *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _renderer = [[SpliceKitLiveCamRenderer alloc] init];
    _segmentationEngine = [[SpliceKitLiveCamSegmentationEngine alloc] init];
    _adjustments = [[SpliceKitLiveCamAdjustmentState alloc] init];
    _sessionQueue = dispatch_queue_create("com.splicekit.livecam.session", DISPATCH_QUEUE_SERIAL);
    _videoQueue = dispatch_queue_create("com.splicekit.livecam.video", DISPATCH_QUEUE_SERIAL);
    // USB audio callbacks have hard real-time-ish deadlines. Keep them ahead of
    // the much heavier Core Image / 4K encode work so memory pressure or a busy
    // video frame cannot starve the microphone callback and turn an otherwise
    // valid Shure buffer into an audible discontinuity.
    dispatch_queue_attr_t audioQueueAttributes =
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                 QOS_CLASS_USER_INTERACTIVE,
                                                 0);
    _audioQueue = dispatch_queue_create("com.splicekit.livecam.audio", audioQueueAttributes);
    _expectedNextAudioPTS = kCMTimeInvalid;
    _presets = @[
        [SpliceKitLiveCamPreset presetWithIdentifier:@"clean" name:@"Clean" category:@"Clean" summary:@"Natural camera image with no stylized treatment." premium:NO],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"faceCamPunch" name:@"Face-Cam Punch" category:@"Clean" summary:@"Tightens the framing for quick commentary pickups." premium:NO],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"vhs" name:@"VHS" category:@"Retro" summary:@"Soft tape blur, color drift, and low-fi scanlines." premium:YES],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"crt" name:@"CRT" category:@"Retro" summary:@"Curved glass, scanlines, bloom, and phosphor contrast." premium:YES],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"oldCamcorder" name:@"Old Camcorder" category:@"Retro" summary:@"Timestamped tape-era color and handheld camcorder texture." premium:YES],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"securityCam" name:@"Security Cam" category:@"Retro" summary:@"Green monochrome surveillance look with timestamp overlay." premium:YES],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"webcamFry" name:@"Webcam Fry" category:@"Glitch" summary:@"Harsh sharpening, ugly compression, and clipped digital contrast." premium:YES],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"rgbSplit" name:@"RGB Split" category:@"Glitch" summary:@"Chromatic channel drift for streamer-style aberration." premium:YES],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"glitchJitter" name:@"Glitch Jitter" category:@"Glitch" summary:@"Unstable signal jitter with blocky horizontal disruption." premium:YES],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"badVideoCall" name:@"Bad Video Call" category:@"Glitch" summary:@"Blocky low-bitrate video-call ugliness with digital instability." premium:YES],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"thermalFalseColor" name:@"Thermal False Color" category:@"Stylized" summary:@"Maps luminance into a bold hot-cold thermal palette." premium:YES],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"comicPoster" name:@"Comic / Poster" category:@"Stylized" summary:@"Bold contour edges and reduced posterized color." premium:NO],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"dreamGlow" name:@"Dream Glow" category:@"Stylized" summary:@"Bloom-heavy soft halation with a tinted haze." premium:NO],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"neonStream" name:@"Neon Stream" category:@"Stylized" summary:@"Punchy saturation, edge glow, and high-energy chroma." premium:YES],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"liquidWarp" name:@"Liquid Warp" category:@"Distortion" summary:@"Organic moving distortion that bends the live frame." premium:YES],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"slitScanTrail" name:@"Slit-Scan Trail" category:@"Distortion" summary:@"Temporal smearing for motion-trail time distortion." premium:YES],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"fisheyeBulge" name:@"Fisheye / Bulge" category:@"Distortion" summary:@"Comedic bulge-lens warp with rounded vignette." premium:YES],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"mirrorSplit" name:@"Mirror Split" category:@"Distortion" summary:@"Mirrors and duplicates the frame for performance-style symmetry." premium:NO],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"kaleidoscope" name:@"Kaleidoscope" category:@"Distortion" summary:@"Rotational symmetry that turns motion into geometric pattern." premium:NO],
    ];
    _presetCategories = @[@"Clean", @"Retro", @"Glitch", @"Stylized", @"Distortion"];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(deviceAvailabilityChanged:)
                                                 name:AVCaptureDeviceWasConnectedNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(deviceAvailabilityChanged:)
                                                 name:AVCaptureDeviceWasDisconnectedNotification
                                               object:nil];

    [self loadDefaults];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)isVisible {
    return self.panel && self.panel.isVisible;
}

- (NSDictionary *)statusSnapshot {
    NSString *presetName = @"Clean";
    for (SpliceKitLiveCamPreset *preset in self.presets) {
        if ([preset.identifier isEqualToString:[self selectedPresetIdentifier]]) {
            presetName = preset.name;
            break;
        }
    }
    return @{
        @"visible": @(self.isVisible),
        @"recording": @(self.recordingActive),
        @"finalizing": @(self.finalizingRecording),
        @"panelFrame": self.panel ? NSStringFromRect(self.panel.frame) : @"",
        @"contentSize": self.panel ? NSStringFromSize(self.panel.contentView.bounds.size) : @"",
        @"layoutBackgroundSize": self.panel ? NSStringFromSize(self.panel.contentView.subviews.firstObject.bounds.size) : @"",
        @"layoutContentHostSize": self.mainColumn ? NSStringFromSize(self.mainColumn.superview.bounds.size) : @"",
        @"layoutMainColumnSize": self.mainColumn ? NSStringFromSize(self.mainColumn.bounds.size) : @"",
        @"preset": presetName,
        @"lookCategory": [self selectedPreset].category ?: @"",
        @"destination": @([self selectedDestination]),
        @"timelinePlacement": @([self selectedTimelinePlacement]),
        @"clipName": self.clipNameField.stringValue ?: @"",
        @"eventName": self.eventNameField.stringValue ?: @"",
        @"camera": self.cameraPopup.selectedItem.title ?: @"",
        @"microphone": self.microphonePopup.selectedItem.title ?: @"",
        @"resolution": self.resolutionPopup.selectedItem.title ?: @"",
        @"frameRate": self.frameRatePopup.selectedItem.title ?: @"",
        @"quality": self.qualityPopup.selectedItem.title ?: @"",
        @"backgroundMode": @([self selectedBackgroundMode]),
        @"backgroundModeName": [self selectedBackgroundModeName] ?: @"None",
        @"timestampOverlay": @(SpliceKitLiveCamPresetSupportsTimestampOverlay([self selectedPresetIdentifier]) &&
                              [self selectedTimestampOverlayEnabled]),
        @"systemBlurSupported": @(self.systemBlurSupported),
        @"systemBlurActive": @(self.systemBlurActive),
        @"centerStageActive": @(self.centerStageActive),
        @"outputPath": self.finalRecordingURL.path ?: @"",
        @"droppedVideoFrames": @(self.droppedVideoFrames),
        @"droppedAudioFrames": @(self.droppedAudioFrames),
        @"sourceAudioDiscontinuities": @(self.sourceAudioDiscontinuities),
        @"sourceAudioGapFrames": @(self.sourceAudioGapFrames),
        @"audioSampleRate": @(self.capturedAudioSampleRate),
        @"audioChannels": @(self.capturedAudioChannels),
        @"audioLevelDB": @(self.audioMeter.rmsDB),
        @"audioPeakDB": @(self.audioMeter.peakDB),
        @"audioMeterBuffersReceived": @(self.audioMeterBuffersReceived),
        @"audioMeterDecodedSamples": @(self.audioMeterDecodedSamples),
        @"audioMeterLastError": @(self.audioMeterLastError),
    };
}

- (void)loadDefaults {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    self.adjustments.intensity = [defaults objectForKey:kLiveCamIntensityKey] ? [defaults doubleForKey:kLiveCamIntensityKey] : 0.8;
    self.adjustments.exposure = [defaults objectForKey:kLiveCamExposureKey] ? [defaults doubleForKey:kLiveCamExposureKey] : 0.0;
    self.adjustments.contrast = [defaults objectForKey:kLiveCamContrastKey] ? [defaults doubleForKey:kLiveCamContrastKey] : 1.0;
    self.adjustments.saturation = [defaults objectForKey:kLiveCamSaturationKey] ? [defaults doubleForKey:kLiveCamSaturationKey] : 1.0;
    self.adjustments.temperature = [defaults objectForKey:kLiveCamTemperatureKey] ? [defaults doubleForKey:kLiveCamTemperatureKey] : 0.0;
    self.adjustments.sharpness = [defaults objectForKey:kLiveCamSharpnessKey] ? [defaults doubleForKey:kLiveCamSharpnessKey] : 0.0;
    self.adjustments.glow = [defaults objectForKey:kLiveCamGlowKey] ? [defaults doubleForKey:kLiveCamGlowKey] : 0.0;
    self.advancedVisible = [defaults boolForKey:kLiveCamAdvancedVisibleKey];
}

- (NSString *)selectedPresetIdentifier {
    NSString *preset = [[NSUserDefaults standardUserDefaults] stringForKey:kLiveCamPresetKey];
    return preset.length > 0 ? preset : @"clean";
}

- (void)storeSelectedPresetIdentifier:(NSString *)identifier {
    NSString *resolved = identifier.length > 0 ? identifier : @"clean";
    [[NSUserDefaults standardUserDefaults] setObject:resolved forKey:kLiveCamPresetKey];
}

- (SpliceKitLiveCamPreset *)selectedPreset {
    NSString *identifier = [self selectedPresetIdentifier];
    for (SpliceKitLiveCamPreset *preset in self.presets) {
        if ([preset.identifier isEqualToString:identifier]) return preset;
    }
    return self.presets.firstObject;
}

- (BOOL)selectedTimestampOverlayEnabled {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id stored = [defaults objectForKey:kLiveCamTimestampOverlayKey];
    if (!stored) return YES;
    return [defaults boolForKey:kLiveCamTimestampOverlayKey];
}

- (BOOL)currentTimestampOverlayEnabled {
    if (self.timestampOverlayCheckbox) {
        return self.timestampOverlayCheckbox.state == NSControlStateValueOn;
    }
    return [self selectedTimestampOverlayEnabled];
}

- (SpliceKitLiveCamDestination)selectedDestination {
    return self.destinationControl.selectedSegment == 1
        ? SpliceKitLiveCamDestinationTimeline
        : SpliceKitLiveCamDestinationLibrary;
}

- (SpliceKitLiveCamTimelinePlacement)selectedTimelinePlacement {
    switch (self.timelinePlacementPopup.indexOfSelectedItem) {
        case 1: return SpliceKitLiveCamTimelinePlacementInsertAtPlayhead;
        case 2: return SpliceKitLiveCamTimelinePlacementConnectedAbove;
        default: return SpliceKitLiveCamTimelinePlacementAppend;
    }
}

- (SpliceKitLiveCamBackgroundMode)selectedBackgroundMode {
    switch (self.backgroundModePopup.indexOfSelectedItem) {
        case 1: return SpliceKitLiveCamBackgroundModeSystemBlur;
        case 2: return SpliceKitLiveCamBackgroundModeGreenScreen;
        default: return SpliceKitLiveCamBackgroundModeNone;
    }
}

- (NSString *)selectedBackgroundModeName {
    switch ([self selectedBackgroundMode]) {
        case SpliceKitLiveCamBackgroundModeSystemBlur: return @"Blur";
        case SpliceKitLiveCamBackgroundModeGreenScreen: return @"Green Screen";
        default: return @"None";
    }
}

- (void)persistDefaults {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (self.cameraPopup.selectedItem.representedObject) {
        [defaults setObject:self.cameraPopup.selectedItem.representedObject forKey:kLiveCamVideoDeviceKey];
    }
    if (self.microphonePopup.selectedItem.representedObject) {
        [defaults setObject:self.microphonePopup.selectedItem.representedObject forKey:kLiveCamAudioDeviceKey];
    }
    [defaults setObject:self.resolutionPopup.selectedItem.representedObject ?: @"1280x720" forKey:kLiveCamResolutionKey];
    [defaults setObject:self.frameRatePopup.selectedItem.representedObject ?: @30 forKey:kLiveCamFrameRateKey];
    [defaults setObject:self.qualityPopup.selectedItem.representedObject ?: @"balanced" forKey:kLiveCamQualityKey];
    [defaults setObject:[self selectedPresetIdentifier] forKey:kLiveCamPresetKey];
    [defaults setInteger:self.backgroundModePopup.indexOfSelectedItem forKey:kLiveCamBackgroundModeKey];
    [defaults setObject:self.backgroundColorPopup.selectedItem.representedObject ?: @"green" forKey:kLiveCamBackgroundColorKey];
    [defaults setDouble:self.backgroundEdgeSlider.doubleValue forKey:kLiveCamBackgroundEdgeSoftnessKey];
    [defaults setDouble:self.backgroundRefinementSlider.doubleValue forKey:kLiveCamBackgroundRefinementKey];
    [defaults setDouble:self.backgroundChokeSlider.doubleValue forKey:kLiveCamBackgroundChokeKey];
    [defaults setDouble:self.backgroundSpillSlider.doubleValue forKey:kLiveCamBackgroundSpillKey];
    [defaults setDouble:self.backgroundWrapSlider.doubleValue forKey:kLiveCamBackgroundWrapKey];
    [defaults setObject:self.backgroundQualityPopup.selectedItem.representedObject ?: @"balanced" forKey:kLiveCamBackgroundQualityKey];
    [defaults setBool:(self.mirrorCheckbox.state == NSControlStateValueOn) forKey:kLiveCamMirrorKey];
    [defaults setBool:(self.muteCheckbox.state == NSControlStateValueOn) forKey:kLiveCamMuteKey];
    [defaults setInteger:self.destinationControl.selectedSegment forKey:kLiveCamDestinationKey];
    [defaults setInteger:self.timelinePlacementPopup.indexOfSelectedItem forKey:kLiveCamPlacementKey];
    [defaults setObject:self.eventNameField.stringValue ?: @"" forKey:kLiveCamEventNameKey];
    [defaults setBool:self.advancedVisible forKey:kLiveCamAdvancedVisibleKey];
    [defaults setDouble:self.intensitySlider.doubleValue forKey:kLiveCamIntensityKey];
    [defaults setDouble:self.exposureSlider.doubleValue forKey:kLiveCamExposureKey];
    [defaults setDouble:self.contrastSlider.doubleValue forKey:kLiveCamContrastKey];
    [defaults setDouble:self.saturationSlider.doubleValue forKey:kLiveCamSaturationKey];
    [defaults setDouble:self.temperatureSlider.doubleValue forKey:kLiveCamTemperatureKey];
    [defaults setDouble:self.sharpnessSlider.doubleValue forKey:kLiveCamSharpnessKey];
    [defaults setDouble:self.glowSlider.doubleValue forKey:kLiveCamGlowKey];
    [defaults setBool:[self currentTimestampOverlayEnabled] forKey:kLiveCamTimestampOverlayKey];
}

- (void)showPanel {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self showPanel]; });
        return;
    }

    [self setupPanelIfNeeded];
    self.advancedVisible = NO;
    [self refreshAdvancedUI];
    [self refreshNameHint];
    NSRect desiredFrame = [self preferredLiveCamFrame];
    [self.panel setFrame:desiredFrame display:NO];
    [self.panel makeKeyAndOrderFront:nil];
    [self postVisibilityChange];
    [self reloadDevices];
    [self refreshBackgroundUI];
    [self requestPermissionsAndStartPreviewIfPossible];
}

- (NSRect)preferredLiveCamFrame {
    NSRect screenFrame = [[NSScreen mainScreen] visibleFrame];
    return NSMakeRect(NSMidX(screenFrame) - 390.0,
                      NSMidY(screenFrame) - 410.0,
                      780.0,
                      820.0);
}

- (void)hidePanel {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self hidePanel]; });
        return;
    }
    [self.panel orderOut:nil];
    [self postVisibilityChange];
    [self stopPreviewSession];
}

- (void)drawInMTKView:(MTKView *)view {
    if (!view.currentDrawable) return;

    CIImage *image = nil;
    @synchronized (self) {
        image = self.latestPreviewImage;
    }
    if (!image) return;

    CGSize drawableSize = view.drawableSize;
    if (drawableSize.width <= 0 || drawableSize.height <= 0) return;

    CIImage *fitted = [self.renderer imageFittedForCanvas:image
                                               canvasSize:drawableSize
                                                     fill:NO];

    id<MTLCommandBuffer> commandBuffer = [self.renderer.commandQueue commandBuffer];
    if (!commandBuffer) return;

    [self.renderer.ciContext render:fitted
                       toMTLTexture:view.currentDrawable.texture
                      commandBuffer:commandBuffer
                             bounds:CGRectMake(0, 0, drawableSize.width, drawableSize.height)
                         colorSpace:self.renderer.colorSpace];
    [commandBuffer presentDrawable:view.currentDrawable];
    [commandBuffer commit];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
}

- (void)windowWillClose:(NSNotification *)notification {
    if (self.recordingActive) {
        [self stopClicked:nil];
    } else {
        [self hidePanel];
    }
}

@end

NSDictionary *SpliceKit_handleLiveCamShow(NSDictionary *params) {
    __block NSDictionary *status = nil;
    SpliceKit_executeOnMainThread(^{
        [[SpliceKitLiveCamPanel sharedPanel] showPanel];
        status = [[SpliceKitLiveCamPanel sharedPanel] statusSnapshot];
    });
    return status ?: @{@"status": @"ok"};
}

NSDictionary *SpliceKit_handleLiveCamHide(NSDictionary *params) {
    __block NSDictionary *status = nil;
    SpliceKit_executeOnMainThread(^{
        [[SpliceKitLiveCamPanel sharedPanel] hidePanel];
        status = [[SpliceKitLiveCamPanel sharedPanel] statusSnapshot];
    });
    return status ?: @{@"status": @"ok"};
}

NSDictionary *SpliceKit_handleLiveCamStatus(NSDictionary *params) {
    __block NSDictionary *status = nil;
    SpliceKit_executeOnMainThread(^{
        status = [[SpliceKitLiveCamPanel sharedPanel] statusSnapshot];
    });
    return status ?: @{@"visible": @NO, @"recording": @NO};
}
