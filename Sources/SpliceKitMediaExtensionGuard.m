//
//  SpliceKitMediaExtensionGuard.m
//  Wrap -[FFMediaExtensionManager copyDecoderInfo:] in @try/@catch so the
//  NSInvalidArgumentException that VTCopyVideoDecoderExtensionProperties raises
//  when an extension returns nil for a required property key doesn't take down FCP.
//  Only that one specific exception is swallowed; anything else re-raises so we
//  don't mask unrelated bugs.
//
//  Background: the crash this started from
//  ---------------------------------------
//  2026-04-21 14:31:13 — EXC_CRASH (SIGABRT) on com.apple.flexo.thumbnailMgr.flatten:
//
//    *** -[__NSDictionaryM __setObject:forKey:]: object cannot be nil
//        (key: <one of the kVTExtensionProperties_* constants>)
//
//      VTCopyVideoDecoderExtensionProperties + 556        (VideoToolbox)
//      -[FFMediaExtensionManager copyDecoderInfo:] + 252  (Flexo)
//      -[FFMediaExtensionManager copyCodecName:] + 16     (Flexo)
//      copyVideoCodecName + 616                           (Flexo)
//      FFAVFQTMediaReader::initFromReadableAVAsset()      (Flexo)
//      ... FFMCSwitcherVideoSource newSubRangeMD5InfoForSampleDuration:atTime:context:
//      FFThumbnailRequestManager _backgroundTask:onTask:  (Flexo)
//
//  VTCopyVideoDecoderExtensionProperties (macOS 15+ public API) builds a
//  CFDictionary containing six required CFStringRef/CFURLRef values:
//      kVTExtensionProperties_ExtensionIdentifierKey
//      kVTExtensionProperties_ExtensionNameKey
//      kVTExtensionProperties_ContainingBundleNameKey
//      kVTExtensionProperties_ExtensionURLKey
//      kVTExtensionProperties_ContainingBundleURLKey
//      kVTExtensionProperties_CodecNameKey
//  If any value resolves to nil — for example, an extension whose CodecInfo
//  array does not declare an entry for the FourCC the format description
//  carries — VT calls __setObject:forKey: with nil and __NSDictionaryM raises
//  NSInvalidArgumentException, which unwinds to FCP's uncaught handler and
//  abort()s the process.
//
//  Argument signature
//  ------------------
//  copyDecoderInfo: takes a FourCharCode (uint32 codec FourCC), NOT an
//  Objective-C object. Declaring the parameter as `id` would make ARC emit
//  objc_storeStrong on entry, which segfaults trying to dereference the
//  FourCC value as an object pointer. We saw this on the very first deploy of
//  this guard (2026-04-21 15:03:54): EXC_BAD_ACCESS inside
//  MEG_swizzledCopyDecoderInfo → objc_storeStrong. Using uintptr_t for the
//  parameter passes the register value through with no ARC retain. The 32-bit
//  FourCharCode lives in the low half of the 64-bit arg register on ARM64; the
//  original method reads it back as a uint32 and never notices the wider-than-needed type.

#import "SpliceKit.h"
#import <objc/runtime.h>
#import <objc/message.h>

static IMP sOrigCopyDecoderInfo = NULL;
static IMP sOrigCopyProcessorInfo = NULL;
static BOOL sMediaExtensionGuardInstalled = NO;

static NSString *MEG_fourCCString(uint32_t fourcc) {
    char chars[5] = {
        (char)((fourcc >> 24) & 0xFF),
        (char)((fourcc >> 16) & 0xFF),
        (char)((fourcc >> 8)  & 0xFF),
        (char)(fourcc         & 0xFF),
        0,
    };
    return [NSString stringWithUTF8String:chars];
}

static void MEG_logCatch(NSException *exception, uint32_t fourcc) {
    static NSUInteger sCatchCount = 0;
    static NSDate *sLastLog = nil;
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.splicekit.mediaextensionguard.log", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_async(q, ^{
        sCatchCount++;
        // First catch logs in full; thereafter, throttle to once per minute and
        // include the running count so the user knows it's still happening.
        NSDate *now = [NSDate date];
        if (sLastLog && [now timeIntervalSinceDate:sLastLog] < 60.0) return;
        sLastLog = now;
        SpliceKit_log(@"[MediaExtensionGuard] swallowed %@ from copyDecoderInfo: "
                       "for %@ (0x%08x) (count=%lu) reason=%@",
                       exception.name, MEG_fourCCString(fourcc), fourcc,
                       (unsigned long)sCatchCount,
                       exception.reason ?: @"(no reason)");
    });
}

// The exception we want to swallow has a very specific signature: it's an
// NSInvalidArgumentException raised by NSMutableDictionary when its setter is
// called with nil. Anything else is re-raised so we don't mask unrelated bugs
// (a real ObjC selector mismatch in copyDecoderInfo:, for example).
static BOOL MEG_isVTNilPropertyException(NSException *exception) {
    if (![exception.name isEqualToString:NSInvalidArgumentException]) return NO;
    NSString *reason = exception.reason ?: @"";
    return [reason containsString:@"__setObject:forKey:"]
        && [reason containsString:@"object cannot be nil"];
}

static id MEG_swizzledCopyDecoderInfo(id self, SEL _cmd, uintptr_t arg) {
    if (!sOrigCopyDecoderInfo) return nil;
    uint32_t fourcc = (uint32_t)arg;

    @try {
        return ((id (*)(id, SEL, uintptr_t))sOrigCopyDecoderInfo)(self, _cmd, arg);
    } @catch (NSException *exception) {
        if (MEG_isVTNilPropertyException(exception)) {
            MEG_logCatch(exception, fourcc);
            // Returning nil mirrors the kVTCouldNotFindExtensionErr path, which
            // copyCodecName: handles by falling back to the built-in codec
            // table. The thumbnail render proceeds without the extension's
            // codec name annotation.
            return nil;
        }
        @throw;
    }
}

static id MEG_swizzledCopyProcessorInfo(id self, SEL _cmd, uintptr_t arg) {
    if (!sOrigCopyProcessorInfo) return nil;
    uint32_t fourcc = (uint32_t)arg;

    @try {
        return ((id (*)(id, SEL, uintptr_t))sOrigCopyProcessorInfo)(self, _cmd, arg);
    } @catch (NSException *exception) {
        if (MEG_isVTNilPropertyException(exception)) {
            MEG_logCatch(exception, fourcc);
            return nil;
        }
        @throw;
    }
}

void SpliceKit_installMediaExtensionGuard(void) {
    if (sMediaExtensionGuardInstalled) return;

    Class cls = objc_getClass("FFMediaExtensionManager");
    if (!cls) {
        SpliceKit_log(@"[MediaExtensionGuard] FFMediaExtensionManager class not found; skipping");
        return;
    }

    SEL sel = @selector(copyDecoderInfo:);
    if (![cls instancesRespondToSelector:sel]) {
        SpliceKit_log(@"[MediaExtensionGuard] -[FFMediaExtensionManager copyDecoderInfo:] missing; skipping");
        return;
    }

    sOrigCopyDecoderInfo = SpliceKit_swizzleMethod(cls, sel, (IMP)MEG_swizzledCopyDecoderInfo);
    if (!sOrigCopyDecoderInfo) {
        SpliceKit_log(@"[MediaExtensionGuard] swizzle failed; FCP remains exposed to the VT nil-property crash");
        return;
    }

    if ([cls instancesRespondToSelector:@selector(copyProcessorInfo:)]) {
        sOrigCopyProcessorInfo = SpliceKit_swizzleMethod(
            cls, @selector(copyProcessorInfo:), (IMP)MEG_swizzledCopyProcessorInfo);
    }

    sMediaExtensionGuardInstalled = YES;
    SpliceKit_log(@"[MediaExtensionGuard] installed: copyDecoderInfo:%s copyProcessorInfo:%s",
                  sOrigCopyDecoderInfo ? "✓" : "✗",
                  sOrigCopyProcessorInfo ? "✓" : "✗");
}
