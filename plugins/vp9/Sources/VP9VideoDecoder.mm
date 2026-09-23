// SpliceKit VP9 proxy decoder.
//
// Registered via the on-disk bundle + PCMediaPlugInsRegisterVideoCodecBundleInProcess
// path that Flexo's CoreMediaMovieReader_Query::decoderIsAvailable probe
// consults. Each decodeFrame forwards through a child VTDecompressionSession
// pinned to Apple's supplemental system VP9 decoder (activated by
// VTRegisterSupplementalVideoDecoderIfAvailable on host bootstrap). Result:
// FCP sees vp09 as a first-class codec and every frame decodes in hardware
// on M3+ Apple Silicon — no re-encode, no container swap, no libvpx.

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <VideoToolbox/VTDecompressionProperties.h>

#include "Private/CMBaseObjectSPI.h"
#include "Private/VTVideoDecoderSPI.h"

#include <mutex>
#include <new>
#include <unistd.h>
#include <vector>

namespace {

static NSString *kVP9LogFile = @"/tmp/splicekit-vp9.log";

static void VP9Log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void VP9Log(NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ [vp9-decoder] %@\n", [NSDate date], msg];
    FILE *f = fopen([kVP9LogFile UTF8String], "a");
    if (f) { fputs([line UTF8String], f); fclose(f); }
    NSLog(@"[SK-VP9-decoder] %@", msg);
}

__attribute__((constructor))
static void VP9BundleDidLoad() {
    VP9Log(@"bundle loaded pid=%d", getpid());
}

#if defined(__x86_64__)
constexpr size_t kCMBasePadSize = 4;
#else
constexpr size_t kCMBasePadSize = 0;
#endif

struct AlignedBaseClass {
    uint8_t pad[kCMBasePadSize];
    CMBaseClass baseClass;
};

struct VP9Decoder {
    CFAllocatorRef allocator { nullptr };
    VTVideoDecoderSession ourSession { nullptr };
    CMVideoFormatDescriptionRef formatDescription { nullptr };
    VTDecompressionSessionRef childSession { nullptr };
    CFMutableDictionaryRef supportedProperties { nullptr };
    CFMutableDictionaryRef decoderProperties { nullptr };
    CFArrayRef supportedPixelFormats { nullptr };
    std::mutex decodeMutex;

    explicit VP9Decoder(CFAllocatorRef inAllocator)
        : allocator((CFAllocatorRef)CFRetain(inAllocator ?: kCFAllocatorDefault))
    {
        supportedProperties = CFDictionaryCreateMutable(
            allocator, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (supportedProperties) {
            CFDictionaryRef placeholder = CFDictionaryCreate(
                allocator, nullptr, nullptr, 0,
                &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            if (placeholder) {
                CFDictionaryAddValue(supportedProperties,
                    kVTDecompressionPropertyKey_SupportedPixelFormatsOrderedByQuality, placeholder);
                CFDictionaryAddValue(supportedProperties,
                    kVTDecompressionPropertyKey_SupportedPixelFormatsOrderedByPerformance, placeholder);
                CFDictionaryAddValue(supportedProperties,
                    kVTDecompressionPropertyKey_PixelFormatsWithReducedResolutionSupport, placeholder);
                CFDictionaryAddValue(supportedProperties,
                    kVTDecompressionPropertyKey_ContentHasInterframeDependencies, placeholder);
                CFDictionaryAddValue(supportedProperties,
                    kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, placeholder);
                CFRelease(placeholder);
            }
        }
    }

    ~VP9Decoder() {
        closeRuntime();
        if (decoderProperties) CFRelease(decoderProperties);
        if (supportedProperties) CFRelease(supportedProperties);
        if (allocator) CFRelease(allocator);
    }

    void closeRuntime() {
        if (childSession) {
            VTDecompressionSessionInvalidate(childSession);
            CFRelease(childSession);
            childSession = nullptr;
        }
        if (supportedPixelFormats) {
            CFRelease(supportedPixelFormats);
            supportedPixelFormats = nullptr;
        }
        if (formatDescription) { CFRelease(formatDescription); formatDescription = nullptr; }
        ourSession = nullptr;
    }
};

template<typename T> static T *Storage(CMBaseObjectRef object) {
    return static_cast<T *>(CMBaseObjectGetDerivedStorage(object));
}
static VP9Decoder *DecoderFromRef(VTVideoDecoderRef d) {
    return Storage<VP9Decoder>(reinterpret_cast<CMBaseObjectRef>(d));
}

static CFStringRef CopyDebugDescription(CMBaseObjectRef) {
    return CFSTR("SpliceKit VP9 proxy decoder");
}

static OSStatus Invalidate(CMBaseObjectRef o) {
    VP9Decoder *d = Storage<VP9Decoder>(o);
    if (!d) return paramErr;
    d->closeRuntime();
    return noErr;
}

static void Finalize(CMBaseObjectRef o) { Storage<VP9Decoder>(o)->~VP9Decoder(); }

static CFArrayRef CopyPixelFormatArray(CFAllocatorRef allocator, CFTypeRef pixelFormatsValue) {
    if (!pixelFormatsValue) return nullptr;
    if (CFGetTypeID(pixelFormatsValue) == CFArrayGetTypeID()) {
        return CFArrayCreateCopy(allocator ?: kCFAllocatorDefault,
                                 reinterpret_cast<CFArrayRef>(pixelFormatsValue));
    }
    if (CFGetTypeID(pixelFormatsValue) == CFNumberGetTypeID()) {
        const void *values[] = { pixelFormatsValue };
        return CFArrayCreate(allocator ?: kCFAllocatorDefault, values, 1, &kCFTypeArrayCallBacks);
    }
    return nullptr;
}

static void RefreshSupportedPixelFormats(VP9Decoder *self_) {
    if (!self_) return;
    if (self_->supportedPixelFormats) {
        CFRelease(self_->supportedPixelFormats);
        self_->supportedPixelFormats = nullptr;
    }
    if (!self_->ourSession) return;

    CFDictionaryRef attrs = VTDecoderSessionGetDestinationPixelBufferAttributes(self_->ourSession);
    if (!attrs) return;

    CFTypeRef pixelFormatsValue = CFDictionaryGetValue(attrs, kCVPixelBufferPixelFormatTypeKey);
    self_->supportedPixelFormats = CopyPixelFormatArray(self_->allocator, pixelFormatsValue);
}

static void MergeDecoderProperties(VP9Decoder *self_, CFDictionaryRef properties) {
    if (!self_ || !properties) return;
    if (!self_->decoderProperties) {
        self_->decoderProperties = CFDictionaryCreateMutableCopy(self_->allocator, 0, properties);
        return;
    }

    CFIndex count = CFDictionaryGetCount(properties);
    if (count <= 0) return;

    std::vector<const void *> keys((size_t)count);
    std::vector<const void *> values((size_t)count);
    CFDictionaryGetKeysAndValues(properties, keys.data(), values.data());
    for (CFIndex idx = 0; idx < count; ++idx) {
        CFDictionarySetValue(self_->decoderProperties, keys[(size_t)idx], values[(size_t)idx]);
    }
}

static void ApplyDecoderPropertiesToChildSession(VP9Decoder *self_) {
    if (!self_ || !self_->childSession || !self_->decoderProperties) return;
    OSStatus st = VTSessionSetProperties(self_->childSession, self_->decoderProperties);
    if (st != noErr) {
        VP9Log(@"VTSessionSetProperties(child) failed st=%d", (int)st);
    }
}

static OSStatus CopyProperty(CMBaseObjectRef object, CFStringRef key, CFAllocatorRef allocator, void *out) {
    if (!key || !out) return paramErr;
    VP9Decoder *self_ = object ? Storage<VP9Decoder>(object) : nullptr;
    if (CFEqual(key, kVTDecompressionPropertyKey_SupportedPixelFormatsOrderedByQuality) ||
        CFEqual(key, kVTDecompressionPropertyKey_SupportedPixelFormatsOrderedByPerformance) ||
        CFEqual(key, kVTDecompressionPropertyKey_PixelFormatsWithReducedResolutionSupport)) {
        if (!self_ || !self_->supportedPixelFormats) return kCMBaseObjectError_ValueNotAvailable;
        *reinterpret_cast<CFArrayRef *>(out) = CFArrayCreateCopy(allocator ?: self_->allocator,
                                                                 self_->supportedPixelFormats);
        return *reinterpret_cast<CFArrayRef *>(out) ? noErr : kCMBaseObjectError_ValueNotAvailable;
    }
    if (CFEqual(key, kVTDecompressionPropertyKey_ContentHasInterframeDependencies)) {
        *reinterpret_cast<CFBooleanRef *>(out) = kCFBooleanTrue;
        return noErr;
    }
    if (CFEqual(key, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder)) {
        *reinterpret_cast<CFBooleanRef *>(out) = kCFBooleanTrue;
        return noErr;
    }
    return kCMBaseObjectError_ValueNotAvailable;
}

static const AlignedBaseClass kBaseClass = {
    {},
    {
        kCMBaseObject_ClassVersion_1,
        sizeof(VP9Decoder),
        nullptr, Invalidate, Finalize, CopyDebugDescription, CopyProperty,
        nullptr, nullptr, nullptr,
    }
};

// Child-session output: forward the decoded pixel buffer up to our caller.
static void ChildOutputCallback(void *decompressionOutputRefCon,
                                 void *sourceFrameRefCon,
                                 OSStatus status,
                                 VTDecodeInfoFlags infoFlags,
                                 CVImageBufferRef imageBuffer,
                                 CMTime /*pts*/, CMTime /*dur*/) {
    VP9Decoder *self_ = (VP9Decoder *)decompressionOutputRefCon;
    VTVideoDecoderFrame frame = (VTVideoDecoderFrame)sourceFrameRefCon;
    if (!self_ || !self_->ourSession) return;
    VTDecoderSessionEmitDecodedFrame(self_->ourSession, frame, status, infoFlags, imageBuffer);
}

// Build a decoder specification that steers VT away from picking *us* for the
// child session — we want Apple's system decoder, not infinite recursion.
// The EnableHardware key alone doesn't exclude us (we claim HW in copyProperty).
// Safest differentiator: target Apple's DecoderID by string.
static CFDictionaryRef CopyChildDecoderSpec(CFAllocatorRef alloc) {
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(alloc ?: kCFAllocatorDefault,
        0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!d) return nullptr;
    // Two keys VT understands for steering by DecoderID. The first is public.
    CFDictionarySetValue(d, CFSTR("CodecName"), CFSTR("Apple Video Decoder - VP9 family"));
    CFDictionarySetValue(d, CFSTR("DecoderID"), CFSTR("com.apple.videotoolbox.videodecoder.avd.vp9"));
    return d;
}

static OSStatus CreateChildSession(VP9Decoder *self_, CMVideoFormatDescriptionRef fd) {
    if (self_->childSession) {
        VTDecompressionSessionInvalidate(self_->childSession);
        CFRelease(self_->childSession);
        self_->childSession = nullptr;
    }
    RefreshSupportedPixelFormats(self_);
    VTDecompressionOutputCallbackRecord cb = { ChildOutputCallback, self_ };
    CFDictionaryRef spec = CopyChildDecoderSpec(self_->allocator);
    CFDictionaryRef imageBufferAttrs = self_->ourSession
        ? VTDecoderSessionGetDestinationPixelBufferAttributes(self_->ourSession)
        : nullptr;
    OSStatus st = VTDecompressionSessionCreate(self_->allocator, fd, spec, imageBufferAttrs, &cb,
                                               &self_->childSession);
    if (spec) CFRelease(spec);
    if (st != noErr) {
        VP9Log(@"spec'd child session create failed st=%d, retrying without spec", (int)st);
        st = VTDecompressionSessionCreate(self_->allocator, fd, NULL, imageBufferAttrs, &cb,
                                          &self_->childSession);
    }
    if (st != noErr && imageBufferAttrs) {
        VP9Log(@"child session create with host attrs failed st=%d, retrying without host attrs", (int)st);
        st = VTDecompressionSessionCreate(self_->allocator, fd, NULL, NULL, &cb, &self_->childSession);
    }
    if (st == noErr) {
        ApplyDecoderPropertiesToChildSession(self_);
    }
    VP9Log(@"CreateChildSession st=%d sess=%p", (int)st, self_->childSession);
    return st;
}

static OSStatus StartSession(VTVideoDecoderRef ref, VTVideoDecoderSession session,
                              CMVideoFormatDescriptionRef fd) {
    VP9Decoder *self_ = DecoderFromRef(ref);
    if (!self_ || !session || !fd) return paramErr;
    std::lock_guard<std::mutex> lock(self_->decodeMutex);
    self_->ourSession = session;
    if (self_->formatDescription) CFRelease(self_->formatDescription);
    self_->formatDescription = (CMVideoFormatDescriptionRef)CFRetain(fd);
    return CreateChildSession(self_, fd);
}

static OSStatus DecodeFrame(VTVideoDecoderRef ref, VTVideoDecoderFrame frame,
                             CMSampleBufferRef sb, VTDecodeFrameFlags flags,
                             VTDecodeInfoFlags *infoFlagsOut) {
    VP9Decoder *self_ = DecoderFromRef(ref);
    if (!self_ || !sb) return paramErr;
    std::lock_guard<std::mutex> lock(self_->decodeMutex);
    if (infoFlagsOut) *infoFlagsOut = 0;
    if (!self_->childSession) return kVTVideoDecoderNotAvailableNowErr;
    VTDecodeFrameFlags childFlags = flags;
    if (flags & kVTDecodeFrame_1xRealTimePlayback) {
        // The host is already pacing playback. Do not let the nested child
        // decoder introduce a second queue or indefinite temporal delay.
        childFlags &= ~kVTDecodeFrame_EnableAsynchronousDecompression;
        childFlags &= ~kVTDecodeFrame_EnableTemporalProcessing;
    }
    return VTDecompressionSessionDecodeFrame(self_->childSession, sb, childFlags, (void *)frame,
                                             infoFlagsOut);
}

static OSStatus CopySupportedPropertyDictionary(VTVideoDecoderRef ref, CFDictionaryRef *out) {
    VP9Decoder *self_ = DecoderFromRef(ref);
    if (!self_ || !out || !self_->supportedProperties) return paramErr;
    *out = CFDictionaryCreateCopy(self_->allocator, self_->supportedProperties);
    return *out ? noErr : kCMBaseObjectError_ValueNotAvailable;
}

static OSStatus SetDecoderProperties(VTVideoDecoderRef ref, CFDictionaryRef properties) {
    VP9Decoder *self_ = DecoderFromRef(ref);
    if (!self_) return paramErr;
    std::lock_guard<std::mutex> lock(self_->decodeMutex);
    MergeDecoderProperties(self_, properties);
    ApplyDecoderPropertiesToChildSession(self_);
    return noErr;
}

static OSStatus CopySerializableProperties(VTVideoDecoderRef, CFDictionaryRef *out) {
    if (!out) return paramErr;
    *out = CFDictionaryCreate(kCFAllocatorDefault, nullptr, nullptr, 0,
                              &kCFTypeDictionaryKeyCallBacks,
                              &kCFTypeDictionaryValueCallBacks);
    return *out ? noErr : kCMBaseObjectError_ValueNotAvailable;
}

static Boolean CanAcceptFormatDescription(VTVideoDecoderRef, CMVideoFormatDescriptionRef fd) {
    if (!fd) return false;
    FourCharCode sub = CMFormatDescriptionGetMediaSubType(fd);
    return sub == 'vp09' || sub == 'vp08';
}

static OSStatus FinishDelayedFrames(VTVideoDecoderRef ref) {
    VP9Decoder *self_ = DecoderFromRef(ref);
    if (!self_) return paramErr;
    std::lock_guard<std::mutex> lock(self_->decodeMutex);
    if (self_->childSession) return VTDecompressionSessionWaitForAsynchronousFrames(self_->childSession);
    return noErr;
}

static const VTVideoDecoderClass kDecoderClass = {
    kVTVideoDecoder_ClassVersion_1,
    StartSession, DecodeFrame,
    CopySupportedPropertyDictionary, SetDecoderProperties, CopySerializableProperties,
    CanAcceptFormatDescription, FinishDelayedFrames,
    nullptr, nullptr, nullptr,
};

static const VTVideoDecoderVTable kDecoderVTable = {
    { nullptr, &kBaseClass.baseClass },
    &kDecoderClass,
};

} // namespace

extern "C" __attribute__((visibility("default")))
OSStatus SpliceKitVP9Decoder_CreateInstance(FourCharCode /*codec*/,
                                             CFAllocatorRef allocator,
                                             VTVideoDecoderRef *decoderOut) {
    if (!decoderOut) return paramErr;
    VP9Log(@"factory createInstance");
    VTVideoDecoderRef decoder = nullptr;
    OSStatus status = CMDerivedObjectCreate(
        allocator ?: kCFAllocatorDefault,
        &kDecoderVTable.base,
        VTVideoDecoderGetClassID(),
        reinterpret_cast<CMBaseObjectRef *>(&decoder));
    if (status != noErr || !decoder) return status ? status : kVTAllocationFailedErr;
    new (Storage<VP9Decoder>(reinterpret_cast<CMBaseObjectRef>(decoder))) VP9Decoder(allocator);
    *decoderOut = decoder;
    return noErr;
}
