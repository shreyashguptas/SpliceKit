//
//  SpliceKitLiveCamEffects.m
//  LiveCam rendering: the Metal kernels, Core Image filter helpers and
//  SpliceKitLiveCamRenderer (looks, adjustments, mask refinement and history, overlays).
//

#import "SpliceKitLiveCam+Private.h"

static NSString * const kSpliceKitLiveCamMetalSource =
@"#include <CoreImage/CoreImage.h>\n"
@"using namespace metal;\n"
@"extern \"C\" { namespace coreimage {\n"
@"[[ stitchable ]] float2 vhsWarp(coreimage::destination dest, float time, float amount) {\n"
@"    float2 c = dest.coord();\n"
@"    float wobble = sin(c.y * 0.028 + time * 6.0) * amount * 18.0;\n"
@"    float jitter = sin(c.y * 0.19 + time * 31.0) * amount * 3.5;\n"
@"    return float2(c.x + wobble + jitter, c.y);\n"
@"}\n"
@"[[ stitchable ]] float2 liquidWarp(coreimage::destination dest, float time, float amount) {\n"
@"    float2 c = dest.coord();\n"
@"    float x = sin(c.y * 0.032 + time * 1.8) * amount * 28.0;\n"
@"    float y = cos(c.x * 0.024 + time * 1.3) * amount * 20.0;\n"
@"    return float2(c.x + x, c.y + y);\n"
@"}\n"
@"[[ stitchable ]] half4 rgbSplit(coreimage::sampler_h image, float dx, float dy) {\n"
@"    float2 c = image.coord();\n"
@"    half4 base = image.sample(c);\n"
@"    half4 red = image.sample(c + float2(dx, dy));\n"
@"    half4 blue = image.sample(c - float2(dx, dy));\n"
@"    return half4(red.r, base.g, blue.b, base.a);\n"
@"}\n"
@"[[ stitchable ]] half4 glitch(coreimage::sampler_h image, float time, float amount) {\n"
@"    float2 c = image.coord();\n"
@"    float band = floor(c.y / 18.0);\n"
@"    float shift = sin(band * 12.7 + time * 24.0) * amount * 36.0;\n"
@"    half4 color = image.sample(c + float2(shift, 0.0));\n"
@"    float swap = fract(band * 0.071 + time * 0.9);\n"
@"    if (swap > 0.84) {\n"
@"        color.rgb = color.bgr;\n"
@"    }\n"
@"    return color;\n"
@"}\n"
@"[[ stitchable ]] half4 thermal(coreimage::sampler_h image) {\n"
@"    float2 c = image.coord();\n"
@"    half4 color = image.sample(c);\n"
@"    half luma = dot(color.rgb, half3(0.299h, 0.587h, 0.114h));\n"
@"    half3 cold = half3(0.04h, 0.10h, 0.50h);\n"
@"    half3 mid = half3(1.0h, 0.48h, 0.02h);\n"
@"    half3 hot = half3(1.0h, 0.96h, 0.62h);\n"
@"    half3 palette = mix(cold, mid, smoothstep(0.12h, 0.58h, luma));\n"
@"    palette = mix(palette, hot, smoothstep(0.56h, 1.0h, luma));\n"
@"    return half4(palette, color.a);\n"
@"}\n"
@"[[ stitchable ]] half4 scanline(coreimage::sampler_h image, float strength, float time) {\n"
@"    float2 c = image.coord();\n"
@"    half4 color = image.sample(c);\n"
@"    float line = 0.62 + 0.38 * sin(c.y * 3.14159 + time * 3.0);\n"
@"    float flicker = 0.96 + 0.04 * sin(time * 21.0);\n"
@"    color.rgb *= half3(mix(1.0, line * flicker, strength));\n"
@"    return color;\n"
@"}\n"
@"[[ stitchable ]] float2 bulgeWarp(coreimage::destination dest, float amount, float width, float height) {\n"
@"    float2 c = dest.coord();\n"
@"    float2 center = float2(width * 0.5, height * 0.5);\n"
@"    float2 delta = c - center;\n"
@"    float radius = length(delta) / max(width, height);\n"
@"    float pull = 1.0 - amount * smoothstep(0.0, 0.8, radius);\n"
@"    return center + delta * pull;\n"
@"}\n"
@"// Signed morphological op: positive = erode (shrink mask, kills halo);\n"
@"// negative = dilate (grow mask). Output is mixed with original by amount magnitude.\n"
@"[[ stitchable ]] half4 maskChoke(coreimage::sampler_h mask, float amount) {\n"
@"    float2 c = mask.coord();\n"
@"    float radius = abs(amount) * 6.0;\n"
@"    half center = mask.sample(c).r;\n"
@"    half acc = center;\n"
@"    for (int i = 0; i < 8; i++) {\n"
@"        float a = float(i) * 0.7853981633974483;\n"
@"        float2 o = float2(cos(a), sin(a)) * radius;\n"
@"        half s = mask.sample(c + o).r;\n"
@"        acc = (amount >= 0.0) ? min(acc, s) : max(acc, s);\n"
@"    }\n"
@"    return half4(acc, acc, acc, 1.0h);\n"
@"}\n"
@"// Spill suppression: at partial-alpha edge pixels, desaturate toward luma. Removes\n"
@"// color cast (e.g. green/blue room light bleeding into hair) so the comp reads clean.\n"
@"[[ stitchable ]] half4 spillSuppress(coreimage::sampler_h image, coreimage::sampler_h mask, float amount) {\n"
@"    half4 c = image.sample(image.coord());\n"
@"    half a = mask.sample(mask.coord()).r;\n"
@"    half edgeWeight = clamp(4.0h * a * (1.0h - a), 0.0h, 1.0h);\n"
@"    half luma = dot(c.rgb, half3(0.2126h, 0.7152h, 0.0722h));\n"
@"    half3 desat = mix(c.rgb, half3(luma), half(amount) * edgeWeight);\n"
@"    return half4(desat, c.a);\n"
@"}\n"
@"// Light wrap: bleed background color into the subject edge so the composite picks\n"
@"// up ambient color from the new background. Sells the cut on solid-color keys.\n"
@"[[ stitchable ]] half4 lightWrap(coreimage::sampler_h image, coreimage::sampler_h mask, coreimage::sampler_h background, float amount) {\n"
@"    half4 c = image.sample(image.coord());\n"
@"    half4 b = background.sample(background.coord());\n"
@"    half a = mask.sample(mask.coord()).r;\n"
@"    half wrapBand = smoothstep(0.55h, 0.95h, a) * (1.0h - smoothstep(0.95h, 1.0h, a));\n"
@"    half3 wrapped = c.rgb + b.rgb * wrapBand * half(amount);\n"
@"    return half4(min(wrapped, half3(1.0h)), c.a);\n"
@"}\n"
@"// Temporal EMA: blend previous and current mask. Kills per-frame Vision flicker.\n"
@"[[ stitchable ]] half4 maskTemporalBlend(coreimage::sampler_h current, coreimage::sampler_h previous, float factor) {\n"
@"    half a = mix(current.sample(current.coord()).r, previous.sample(previous.coord()).r, half(factor));\n"
@"    return half4(a, a, a, 1.0h);\n"
@"}\n"
@"} }\n";

static CIImage *SpliceKitLiveCamApplyFilter(CIImage *image,
                                            NSString *filterName,
                                            NSDictionary<NSString *, id> *parameters) {
    CIFilter *filter = [CIFilter filterWithName:filterName];
    if (!filter) return image;
    [filter setDefaults];
    if (image) {
        [filter setValue:image forKey:kCIInputImageKey];
    }
    [parameters enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        if (value) [filter setValue:value forKey:key];
    }];
    CIImage *result = filter.outputImage;
    return result ?: image;
}

static CIImage *SpliceKitLiveCamSolidColorImage(CIColor *color, CGRect rect) {
    return [[[CIImage imageWithColor:color ?: [CIColor colorWithRed:0 green:0 blue:0 alpha:1]]
        imageByCroppingToRect:rect] imageByCroppingToRect:rect];
}

CIColor *SpliceKitLiveCamBackgroundCIColor(NSString *key) {
    NSString *backgroundKey = key.length > 0 ? key : @"green";
    if ([backgroundKey isEqualToString:@"blue"]) {
        return [CIColor colorWithRed:0.04 green:0.22 blue:0.82 alpha:1.0];
    }
    return [CIColor colorWithRed:0.03 green:0.78 blue:0.20 alpha:1.0];
}

@implementation SpliceKitLiveCamMaskParams
@end

@implementation SpliceKitLiveCamRenderer

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    _metalDevice = MTLCreateSystemDefaultDevice();
    if (_metalDevice) {
        _commandQueue = [_metalDevice newCommandQueue];
    }
    if (_commandQueue) {
        _ciContext = [CIContext contextWithMTLCommandQueue:_commandQueue options:@{
            kCIContextWorkingColorSpace: (__bridge id)_colorSpace,
            kCIContextOutputColorSpace: (__bridge id)_colorSpace,
            // Every camera frame has different inputs. Retaining Core Image's
            // transient intermediates only grows memory and cannot produce a
            // useful cache hit for this streaming workload.
            kCIContextCacheIntermediates: @NO,
        }];
        SpliceKit_log(@"[LiveCamEffects] Metal-backed CIContext ready on %@", _metalDevice.name ?: @"<unnamed>");
    } else {
        _ciContext = [CIContext contextWithOptions:@{
            kCIContextWorkingColorSpace: (__bridge id)_colorSpace,
            kCIContextOutputColorSpace: (__bridge id)_colorSpace,
            kCIContextCacheIntermediates: @NO,
        }];
        SpliceKit_log(@"[LiveCamEffects] Falling back to CPU/GL Core Image context");
    }

    _kernels = [NSMutableDictionary dictionary];
    _overlayCache = [NSMutableDictionary dictionary];
    _trailFrames = [NSMutableArray array];
    [self compileMetalKernelsIfPossible];
    return self;
}

- (void)dealloc {
    if (_maskHistoryPool) {
        CVPixelBufferPoolRelease(_maskHistoryPool);
        _maskHistoryPool = NULL;
    }
    if (_colorSpace) {
        CGColorSpaceRelease(_colorSpace);
        _colorSpace = nil;
    }
}

- (void)compileMetalKernelsIfPossible {
    if (@available(macOS 12.0, *)) {
        NSError *error = nil;
        NSArray<CIKernel *> *kernels = [CIKernel kernelsWithMetalString:kSpliceKitLiveCamMetalSource error:&error];
        if (kernels.count == 0 || error) {
            SpliceKit_log(@"[LiveCamEffects] Metal kernels unavailable: %@", error.localizedDescription ?: @"unknown error");
            return;
        }
        for (CIKernel *kernel in kernels) {
            if (kernel.name.length > 0) {
                self.kernels[kernel.name] = kernel;
            }
        }
        SpliceKit_log(@"[LiveCamEffects] Loaded Metal kernels: %@", [self.kernels.allKeys componentsJoinedByString:@", "]);
    }
}

- (CIImage *)applyWarpKernelNamed:(NSString *)name
                          toImage:(CIImage *)image
                        arguments:(NSArray<id> *)arguments {
    CIWarpKernel *kernel = (CIWarpKernel *)self.kernels[name];
    if (![kernel isKindOfClass:[CIWarpKernel class]]) return image;

    CGRect extent = image.extent;
    return [kernel applyWithExtent:extent
                       roiCallback:^CGRect(int index, CGRect destRect) {
                           return CGRectInset(destRect, -80.0, -80.0);
                       }
                        inputImage:image
                         arguments:arguments] ?: image;
}

- (CIImage *)applyColorKernelNamed:(NSString *)name
                           toImage:(CIImage *)image
                         arguments:(NSArray<id> *)arguments {
    // Despite the "Color" name, the method also handles general CIKernels so
    // stitchable Metal shaders that sample neighbor pixels (rgbSplit, glitch,
    // scanline, maskChoke) are not silently skipped.
    CIKernel *kernel = self.kernels[name];
    if (!kernel) return image;
    CIImage *result = nil;
    if ([kernel isKindOfClass:[CIColorKernel class]]) {
        result = [(CIColorKernel *)kernel applyWithExtent:image.extent arguments:arguments];
    } else {
        result = [kernel applyWithExtent:image.extent
                             roiCallback:^CGRect(int index, CGRect destRect) {
                                 return CGRectInset(destRect, -12.0, -12.0);
                             }
                               arguments:arguments];
    }
    return result ?: image;
}

- (CIImage *)noiseImageForExtent:(CGRect)extent alpha:(CGFloat)alpha monochrome:(BOOL)monochrome {
    CIImage *noise = [CIFilter filterWithName:@"CIRandomGenerator"].outputImage;
    if (!noise) return nil;
    noise = [noise imageByCroppingToRect:extent];
    if (monochrome) {
        noise = SpliceKitLiveCamApplyFilter(noise, @"CIColorControls", @{
            kCIInputSaturationKey: @0.0,
            kCIInputContrastKey: @1.35,
        });
    }
    noise = SpliceKitLiveCamApplyFilter(noise, @"CIColorMatrix", @{
        @"inputRVector": [CIVector vectorWithX:1 Y:0 Z:0 W:0],
        @"inputGVector": [CIVector vectorWithX:0 Y:1 Z:0 W:0],
        @"inputBVector": [CIVector vectorWithX:0 Y:0 Z:1 W:0],
        @"inputAVector": [CIVector vectorWithX:0 Y:0 Z:0 W:alpha],
    });
    return noise;
}

- (CIImage *)overlayImageForKey:(NSString *)cacheKey
                           size:(CGSize)size
                      drawBlock:(void (^)(void))drawBlock {
    if (cacheKey.length == 0 || size.width <= 0 || size.height <= 0) return nil;
    CIImage *cached = self.overlayCache[cacheKey];
    if (cached) return cached;

    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(size.width, size.height)];
    [image lockFocus];
    [[NSColor clearColor] setFill];
    NSRectFill(NSMakeRect(0, 0, size.width, size.height));
    if (drawBlock) drawBlock();
    [image unlockFocus];

    CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cgImage) return nil;

    CIImage *ciImage = [[CIImage alloc] initWithCGImage:cgImage];
    if (ciImage) {
        self.overlayCache[cacheKey] = ciImage;
    }
    return ciImage;
}

- (CIImage *)timestampOverlayForExtent:(CGRect)extent
                             timestamp:(NSString *)timestamp
                                  tint:(NSColor *)tint
                                prefix:(NSString *)prefix {
    NSString *text = prefix.length > 0
        ? [NSString stringWithFormat:@"%@ %@", prefix, timestamp ?: @""]
        : (timestamp ?: @"");
    NSString *cacheKey = [NSString stringWithFormat:@"stamp|%@|%.0fx%.0f|%@",
                          text,
                          extent.size.width,
                          extent.size.height,
                          tint.description ?: @""];
    CIImage *overlay = [self overlayImageForKey:cacheKey size:extent.size drawBlock:^{
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:14 weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName: tint ?: [NSColor colorWithWhite:1 alpha:0.95],
            NSStrokeColorAttributeName: [NSColor colorWithWhite:0 alpha:0.4],
            NSStrokeWidthAttributeName: @-1.5,
        };
        [text drawAtPoint:NSMakePoint(18, 18) withAttributes:attrs];
    }];
    if (!overlay) return nil;
    return [overlay imageByCroppingToRect:extent];
}

- (CIImage *)recordingOverlayForExtent:(CGRect)extent timestamp:(NSString *)timestamp {
    NSString *cacheKey = [NSString stringWithFormat:@"rec|%@|%.0fx%.0f",
                          timestamp ?: @"", extent.size.width, extent.size.height];
    CIImage *overlay = [self overlayImageForKey:cacheKey size:extent.size drawBlock:^{
        NSColor *red = [NSColor colorWithRed:0.98 green:0.21 blue:0.23 alpha:0.95];
        [red setFill];
        NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(18, extent.size.height - 30, 12, 12)];
        [dot fill];

        NSDictionary *recAttrs = @{
            NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightBold],
            NSForegroundColorAttributeName: red,
        };
        [@"REC" drawAtPoint:NSMakePoint(36, extent.size.height - 33) withAttributes:recAttrs];

        if (timestamp.length > 0) {
            NSDictionary *timeAttrs = @{
                NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium],
                NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.92],
                NSStrokeColorAttributeName: [NSColor colorWithWhite:0 alpha:0.35],
                NSStrokeWidthAttributeName: @-1.2,
            };
            [timestamp drawAtPoint:NSMakePoint(extent.size.width - 140, extent.size.height - 33)
                     withAttributes:timeAttrs];
        }
    }];
    if (!overlay) return nil;
    return [overlay imageByCroppingToRect:extent];
}

- (CIImage *)imageFittedForCanvas:(CIImage *)image
                       canvasSize:(CGSize)canvasSize
                             fill:(BOOL)fill {
    return [self imageFittedForCanvas:image canvasSize:canvasSize fill:fill preserveAlpha:NO];
}

- (CIImage *)imageFittedForCanvas:(CIImage *)image
                       canvasSize:(CGSize)canvasSize
                             fill:(BOOL)fill
                    preserveAlpha:(BOOL)preserveAlpha {
    if (!image || canvasSize.width <= 0 || canvasSize.height <= 0) return image;
    CGRect extent = image.extent;
    if (extent.size.width <= 0 || extent.size.height <= 0) return image;

    CGFloat scaleX = canvasSize.width / extent.size.width;
    CGFloat scaleY = canvasSize.height / extent.size.height;
    CGFloat scale = fill ? MAX(scaleX, scaleY) : MIN(scaleX, scaleY);
    if (!isfinite(scale) || scale <= 0.0) scale = 1.0;

    CIImage *scaled = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGRect scaledExtent = scaled.extent;
    CGFloat tx = (canvasSize.width - scaledExtent.size.width) * 0.5 - scaledExtent.origin.x;
    CGFloat ty = (canvasSize.height - scaledExtent.size.height) * 0.5 - scaledExtent.origin.y;
    scaled = [scaled imageByApplyingTransform:CGAffineTransformMakeTranslation(tx, ty)];

    CGRect canvasRect = CGRectMake(0, 0, canvasSize.width, canvasSize.height);
    if (preserveAlpha) {
        return [scaled imageByCroppingToRect:canvasRect];
    }
    CIImage *background = SpliceKitLiveCamSolidColorImage([CIColor colorWithRed:0 green:0 blue:0 alpha:1], canvasRect);
    return [[scaled imageByCompositingOverImage:background] imageByCroppingToRect:canvasRect];
}

- (CIImage *)composeSplitImage:(CIImage *)image mirrored:(BOOL)mirrored {
    CGRect extent = image.extent;
    CGFloat halfWidth = CGRectGetWidth(extent) * 0.5;
    CGRect leftRect = CGRectMake(CGRectGetMinX(extent), CGRectGetMinY(extent), halfWidth, CGRectGetHeight(extent));
    CIImage *left = [image imageByCroppingToRect:leftRect];
    CGAffineTransform transform = CGAffineTransformMake(-1, 0, 0, 1, CGRectGetWidth(extent), 0);
    CIImage *mirroredHalf = [left imageByApplyingTransform:transform];
    CIImage *background = SpliceKitLiveCamSolidColorImage([CIColor colorWithRed:0 green:0 blue:0 alpha:1], extent);
    background = [mirroredHalf imageByCompositingOverImage:background];
    background = [left imageByCompositingOverImage:background];
    return mirrored ? background : [background imageByCroppingToRect:extent];
}

- (CIImage *)composeSlitScanForImage:(CIImage *)image {
    CGRect extent = image.extent;
    if (CGRectIsEmpty(extent)) return image;

    [self.trailFrames insertObject:image atIndex:0];
    while (self.trailFrames.count > 10) {
        [self.trailFrames removeLastObject];
    }
    if (self.trailFrames.count < 2) return image;

    NSInteger slices = MIN((NSInteger)self.trailFrames.count, 8);
    CGFloat sliceWidth = CGRectGetWidth(extent) / (CGFloat)slices;
    CIImage *background = SpliceKitLiveCamSolidColorImage([CIColor colorWithRed:0 green:0 blue:0 alpha:1], extent);

    for (NSInteger idx = 0; idx < slices; idx++) {
        CIImage *frame = self.trailFrames[MIN(idx, (NSInteger)self.trailFrames.count - 1)];
        CGRect sliceRect = CGRectMake(CGRectGetMinX(extent) + sliceWidth * idx,
                                      CGRectGetMinY(extent),
                                      idx == slices - 1 ? CGRectGetWidth(extent) - sliceWidth * idx : sliceWidth,
                                      CGRectGetHeight(extent));
        CIImage *slice = [[frame imageByCroppingToRect:sliceRect] imageByCroppingToRect:sliceRect];
        background = [slice imageByCompositingOverImage:background];
    }
    return background;
}

- (void)resetMaskHistory {
    if (self.maskHistoryFrames > 0) {
        SpliceKit_log(@"[LiveCamPerf] resetMaskHistory: released materialized history after %lu masks",
                      (unsigned long)self.maskHistoryFrames);
    }
    self.previousMaskForBlend = nil;
    self.previousMaskSourceGeneration = 0;
    self.previousMaskConfigurationValid = NO;
    self.maskHistoryFrames = 0;
    if (self.maskHistoryPool) {
        CVPixelBufferPoolFlush(self.maskHistoryPool, kCVPixelBufferPoolFlushExcessBuffers);
    }
}

// CIImage is a lazy recipe, not a pixel snapshot. Keeping a filtered CIImage as
// feedback for the next frame creates mask[n] -> mask[n-1] -> ... forever. Core
// Image recursively walks that graph during recording and eventually exhausts
// the 544 KB capture-queue stack. Materialize each completed mask into a bounded
// pool-backed pixel buffer so feedback always has constant graph depth.
- (CIImage *)materializedMaskForHistory:(CIImage *)mask extent:(CGRect)extent {
    if (!mask || CGRectIsEmpty(extent) || !self.ciContext) return nil;

    size_t width = (size_t)MAX(1.0, ceil(CGRectGetWidth(extent)));
    size_t height = (size_t)MAX(1.0, ceil(CGRectGetHeight(extent)));
    if (!self.maskHistoryPool || self.maskHistoryWidth != width || self.maskHistoryHeight != height) {
        if (self.maskHistoryPool) {
            CVPixelBufferPoolRelease(self.maskHistoryPool);
            self.maskHistoryPool = NULL;
        }

        NSDictionary *poolAttributes = @{
            (id)kCVPixelBufferPoolMinimumBufferCountKey: @3,
        };
        NSDictionary *bufferAttributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_OneComponent8),
            (id)kCVPixelBufferWidthKey: @(width),
            (id)kCVPixelBufferHeightKey: @(height),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        };
        CVReturn poolStatus = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                                       (__bridge CFDictionaryRef)poolAttributes,
                                                       (__bridge CFDictionaryRef)bufferAttributes,
                                                       &_maskHistoryPool);
        if (poolStatus != kCVReturnSuccess || !self.maskHistoryPool) {
            SpliceKit_log(@"[LiveCamPerf] mask history pool creation failed (%d) for %zux%zu",
                          (int)poolStatus, width, height);
            self.maskHistoryWidth = 0;
            self.maskHistoryHeight = 0;
            return nil;
        }
        self.maskHistoryWidth = width;
        self.maskHistoryHeight = height;
        SpliceKit_log(@"[LiveCamPerf] materialized mask history ready at %zux%zu", width, height);
    }

    CVPixelBufferRef historyBuffer = NULL;
    NSDictionary *allocationLimit = @{
        (id)kCVPixelBufferPoolAllocationThresholdKey: @8,
    };
    CVReturn bufferStatus = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
        kCFAllocatorDefault,
        self.maskHistoryPool,
        (__bridge CFDictionaryRef)allocationLimit,
        &historyBuffer);
    if (bufferStatus != kCVReturnSuccess || !historyBuffer) {
        SpliceKit_log(@"[LiveCamPerf] mask history buffer unavailable (%d); using current-frame mask without feedback",
                      (int)bufferStatus);
        return nil;
    }

    CGRect targetExtent = CGRectMake(0, 0, width, height);
    CIImage *normalized = mask;
    if (fabs(CGRectGetMinX(extent)) > 0.001 || fabs(CGRectGetMinY(extent)) > 0.001) {
        normalized = [mask imageByApplyingTransform:CGAffineTransformMakeTranslation(-CGRectGetMinX(extent),
                                                                                     -CGRectGetMinY(extent))];
    }
    normalized = [normalized imageByCroppingToRect:targetExtent];
    [self.ciContext render:normalized
           toCVPixelBuffer:historyBuffer
                    bounds:targetExtent
                colorSpace:nil];

    CIImage *materialized = [CIImage imageWithCVPixelBuffer:historyBuffer
                                                   options:@{ kCIImageColorSpace: [NSNull null] }];
    CVPixelBufferRelease(historyBuffer);
    if (!materialized) return nil;

    materialized = [materialized imageByCroppingToRect:targetExtent];
    if (fabs(CGRectGetMinX(extent)) > 0.001 || fabs(CGRectGetMinY(extent)) > 0.001) {
        materialized = [materialized imageByApplyingTransform:CGAffineTransformMakeTranslation(CGRectGetMinX(extent),
                                                                                                CGRectGetMinY(extent))];
    }
    return [materialized imageByCroppingToRect:extent];
}

// Checkerboard composited under transparent preview only — never written to disk.
// The recording path receives the original alpha-bearing image untouched.
- (CIImage *)previewCheckerboardForExtent:(CGRect)extent {
    CIFilter *checker = [CIFilter filterWithName:@"CICheckerboardGenerator"];
    [checker setValue:[CIVector vectorWithX:0 Y:0] forKey:kCIInputCenterKey];
    [checker setValue:[CIColor colorWithRed:0.18 green:0.18 blue:0.20 alpha:1.0] forKey:@"inputColor0"];
    [checker setValue:[CIColor colorWithRed:0.10 green:0.10 blue:0.12 alpha:1.0] forKey:@"inputColor1"];
    [checker setValue:@(MAX(8.0, MIN(extent.size.width, extent.size.height) / 36.0)) forKey:kCIInputWidthKey];
    [checker setValue:@(0.0) forKey:@"inputSharpness"];
    CIImage *board = checker.outputImage;
    if (!board) return nil;
    return [board imageByCroppingToRect:extent];
}

- (CIImage *)imageByCompositingOverPreviewCheckerboard:(CIImage *)alphaImage {
    if (!alphaImage) return nil;
    CGRect extent = alphaImage.extent;
    CIImage *board = [self previewCheckerboardForExtent:extent];
    if (!board) return alphaImage;
    return [[alphaImage imageByCompositingOverImage:board] imageByCroppingToRect:extent];
}

- (CIImage *)applyColorKernelNamed:(NSString *)name
                          toExtent:(CGRect)extent
                         arguments:(NSArray<id> *)arguments {
    CIKernel *kernel = self.kernels[name];
    if (!kernel) return nil;
    if ([kernel isKindOfClass:[CIColorKernel class]]) {
        return [(CIColorKernel *)kernel applyWithExtent:extent arguments:arguments];
    }
    return [kernel applyWithExtent:extent
                       roiCallback:^CGRect(int index, CGRect destRect) {
                           return CGRectInset(destRect, -16.0, -16.0);
                       }
                         arguments:arguments];
}

- (CIImage *)refinedMaskFor:(CIImage *)rawMask
                      guide:(CIImage *)guideImage
                 background:(CIImage *)backgroundImage
                     params:(SpliceKitLiveCamMaskParams *)params
                     extent:(CGRect)extent {
    BOOL sameSource = self.previousMaskForBlend &&
        self.previousMaskConfigurationValid &&
        params.sourceGeneration == self.previousMaskSourceGeneration &&
        fabs(params.edgeSoftness - self.previousMaskEdgeSoftness) < 0.0001 &&
        fabs(params.refinement - self.previousMaskRefinement) < 0.0001 &&
        fabs(params.choke - self.previousMaskChoke) < 0.0001 &&
        fabs(params.temporalSmoothing - self.previousMaskTemporalSmoothing) < 0.0001 &&
        self.maskHistoryWidth == (size_t)MAX(1.0, ceil(CGRectGetWidth(extent))) &&
        self.maskHistoryHeight == (size_t)MAX(1.0, ceil(CGRectGetHeight(extent)));
    if (sameSource) {
        // Vision intentionally updates every other capture frame. Reuse the
        // already-materialized matte on the intervening frame instead of
        // repeating morphology, blur, temporal blend, and a GPU render.
        return self.previousMaskForBlend;
    }

    CIImage *mask = [self imageFittedForCanvas:rawMask canvasSize:extent.size fill:YES];
    mask = [mask imageByCroppingToRect:extent];

    // Signed morphology on the mask: positive dilates (grows the cutout so more
    // of the subject is kept), negative erodes (shrinks it so edge halo goes
    // away). Matches FCP's own Background Remover "Contour" parameter semantics
    // and uses Apple's Metal-backed CIMorphology filters.
    if (fabs(params.refinement) > 0.02) {
        CGFloat radius = fabs(params.refinement) * 8.0;
        NSString *filterName = (params.refinement > 0) ? @"CIMorphologyMaximum" : @"CIMorphologyMinimum";
        CIImage *shaped = SpliceKitLiveCamApplyFilter(mask, filterName, @{
            kCIInputRadiusKey: @(radius),
        });
        if (shaped) mask = [shaped imageByCroppingToRect:extent];
    }

    // Choke before feathering so the gaussian softens the *new* boundary.
    if (fabs(params.choke) > 0.01) {
        CIImage *choked = [self applyColorKernelNamed:@"maskChoke"
                                             toExtent:extent
                                            arguments:@[mask, @(params.choke)]];
        if (choked) mask = [choked imageByCroppingToRect:extent];
    }

    // Temporal EMA against the previously composited mask. Killer for live video.
    if (params.temporalSmoothing > 0.01 && self.previousMaskForBlend) {
        CIImage *prev = [self imageFittedForCanvas:self.previousMaskForBlend
                                        canvasSize:extent.size
                                              fill:YES];
        prev = [prev imageByCroppingToRect:extent];
        CIImage *blended = [self applyColorKernelNamed:@"maskTemporalBlend"
                                              toExtent:extent
                                             arguments:@[mask, prev, @(params.temporalSmoothing)]];
        if (blended) mask = [blended imageByCroppingToRect:extent];
    }

    if (params.edgeSoftness > 0.01) {
        mask = SpliceKitLiveCamApplyFilter(mask, @"CIGaussianBlur", @{
            kCIInputRadiusKey: @(params.edgeSoftness * 6.0),
        });
        mask = [mask imageByCroppingToRect:extent];
    }

    CIImage *materialized = [self materializedMaskForHistory:mask extent:extent];
    if (materialized) {
        self.previousMaskForBlend = materialized;
        self.previousMaskSourceGeneration = params.sourceGeneration;
        self.previousMaskEdgeSoftness = params.edgeSoftness;
        self.previousMaskRefinement = params.refinement;
        self.previousMaskChoke = params.choke;
        self.previousMaskTemporalSmoothing = params.temporalSmoothing;
        self.previousMaskConfigurationValid = YES;
        self.maskHistoryFrames += 1;
        return materialized;
    }

    // Allocation/render failure must degrade to a single-frame mask. Never
    // retain the lazy result, or the recursive graph and crash return.
    self.previousMaskForBlend = nil;
    self.previousMaskConfigurationValid = NO;
    return mask;
}

- (CIImage *)renderedImageFromImage:(CIImage *)image
                             preset:(SpliceKitLiveCamPreset *)preset
                               time:(NSTimeInterval)time
                        adjustments:(SpliceKitLiveCamAdjustmentState *)adjustments
                          maskImage:(CIImage *)maskImage
                         maskParams:(SpliceKitLiveCamMaskParams *)maskParams
                    backgroundColor:(CIColor *)backgroundColor
                           mirrored:(BOOL)mirrored
                          recording:(BOOL)recording
                         canvasSize:(CGSize)canvasSize {
    if (!image) return nil;
    CGRect originalExtent = image.extent;
    NSString *identifier = preset.identifier ?: @"clean";
    CGFloat intensity = MAX(0.0, adjustments.intensity);

    if (mirrored) {
        CGFloat tx = CGRectGetMinX(originalExtent) + CGRectGetMaxX(originalExtent);
        CGAffineTransform mirrorTransform = CGAffineTransformMake(-1, 0, 0, 1, tx, 0);
        image = [[image imageByApplyingTransform:mirrorTransform] imageByCroppingToRect:originalExtent];
    }

    if (maskImage) {
        BOOL transparent = maskParams.transparentBackground;
        CIImage *background = SpliceKitLiveCamSolidColorImage(transparent
                                                              ? [CIColor colorWithRed:0 green:0 blue:0 alpha:0]
                                                              : (backgroundColor ?: SpliceKitLiveCamBackgroundCIColor(@"green")),
                                                              originalExtent);
        CIImage *mask = [self refinedMaskFor:maskImage
                                       guide:image
                                  background:background
                                      params:maskParams
                                      extent:originalExtent];

        if (maskParams.spill > 0.01) {
            CIImage *suppressed = [self applyColorKernelNamed:@"spillSuppress"
                                                     toExtent:originalExtent
                                                    arguments:@[image, mask, @(maskParams.spill)]];
            if (suppressed) image = [suppressed imageByCroppingToRect:originalExtent];
        }

        // Light wrap only makes sense when compositing onto a real background;
        // it would just dim the alpha edge in transparent mode.
        if (!transparent && maskParams.wrap > 0.01) {
            CIImage *wrapped = [self applyColorKernelNamed:@"lightWrap"
                                                  toExtent:originalExtent
                                                 arguments:@[image, mask, background, @(maskParams.wrap)]];
            if (wrapped) image = [wrapped imageByCroppingToRect:originalExtent];
        }

        image = SpliceKitLiveCamApplyFilter(image, @"CIBlendWithMask", @{
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: mask,
        });
        image = [image imageByCroppingToRect:originalExtent];
    } else {
        // No mask this frame — drop history so the next composite starts clean.
        [self resetMaskHistory];
    }

    if (fabs(adjustments.exposure) > 0.001) {
        image = SpliceKitLiveCamApplyFilter(image, @"CIExposureAdjust", @{
            kCIInputEVKey: @(adjustments.exposure * 1.6),
        });
    }
    image = SpliceKitLiveCamApplyFilter(image, @"CIColorControls", @{
        kCIInputContrastKey: @(MAX(0.2, adjustments.contrast)),
        kCIInputSaturationKey: @(MAX(0.0, adjustments.saturation)),
    });
    if (fabs(adjustments.temperature) > 0.01) {
        CIVector *neutral = [CIVector vectorWithX:6500 Y:0];
        CIVector *target = [CIVector vectorWithX:(6500.0 + adjustments.temperature * 2400.0) Y:0];
        image = SpliceKitLiveCamApplyFilter(image, @"CITemperatureAndTint", @{
            @"inputNeutral": neutral,
            @"inputTargetNeutral": target,
        });
    }
    if (adjustments.sharpness > 0.01) {
        image = SpliceKitLiveCamApplyFilter(image, @"CISharpenLuminance", @{
            kCIInputSharpnessKey: @(adjustments.sharpness * 1.8),
        });
    }
    if (adjustments.glow > 0.01) {
        image = SpliceKitLiveCamApplyFilter(image, @"CIBloom", @{
            kCIInputRadiusKey: @(6.0 + adjustments.glow * 12.0),
            kCIInputIntensityKey: @(0.15 + adjustments.glow * 0.55),
        });
    }

    if ([identifier isEqualToString:@"vhs"]) {
        image = SpliceKitLiveCamApplyFilter(image, @"CIGaussianBlur", @{ kCIInputRadiusKey: @(0.8 + intensity * 1.3) });
        image = [self applyWarpKernelNamed:@"vhsWarp" toImage:image arguments:@[@(time), @(0.18 + intensity * 0.28)]];
        image = [self applyColorKernelNamed:@"rgbSplit" toImage:image arguments:@[image, @(0.7 + intensity * 2.2), @(0.15)]];
        CIImage *noise = [self noiseImageForExtent:image.extent alpha:(0.05 + intensity * 0.08) monochrome:NO];
        if (noise) image = [noise imageByCompositingOverImage:image];
        image = [self applyColorKernelNamed:@"scanline" toImage:image arguments:@[image, @(0.22 + intensity * 0.25), @(time)]];
        image = SpliceKitLiveCamApplyFilter(image, @"CIColorControls", @{
            kCIInputContrastKey: @(0.92),
            kCIInputSaturationKey: @(0.82),
        });
    } else if ([identifier isEqualToString:@"webcamFry"]) {
        image = SpliceKitLiveCamApplyFilter(image, @"CISharpenLuminance", @{ kCIInputSharpnessKey: @(1.2 + intensity * 1.6) });
        image = SpliceKitLiveCamApplyFilter(image, @"CIColorControls", @{
            kCIInputContrastKey: @(1.28 + intensity * 0.55),
            kCIInputSaturationKey: @(1.05 + intensity * 0.35),
        });
        image = SpliceKitLiveCamApplyFilter(image, @"CIHighlightShadowAdjust", @{
            @"inputHighlightAmount": @(0.0),
            @"inputShadowAmount": @(0.35),
        });
        image = SpliceKitLiveCamApplyFilter(image, @"CIColorPosterize", @{ @"inputLevels": @(18.0 - intensity * 7.0) });
    } else if ([identifier isEqualToString:@"crt"]) {
        image = [self applyWarpKernelNamed:@"bulgeWarp" toImage:image arguments:@[@(0.14 + intensity * 0.16), @(CGRectGetWidth(image.extent)), @(CGRectGetHeight(image.extent))]];
        image = [self applyColorKernelNamed:@"scanline" toImage:image arguments:@[image, @(0.42 + intensity * 0.3), @(time)]];
        image = [self applyColorKernelNamed:@"rgbSplit" toImage:image arguments:@[image, @(0.8 + intensity * 1.8), @(0.2)]];
        image = SpliceKitLiveCamApplyFilter(image, @"CIBloom", @{
            kCIInputRadiusKey: @(8.0),
            kCIInputIntensityKey: @(0.18 + intensity * 0.28),
        });
        image = SpliceKitLiveCamApplyFilter(image, @"CIVignette", @{
            kCIInputIntensityKey: @(0.52),
            kCIInputRadiusKey: @(1.45),
        });
    } else if ([identifier isEqualToString:@"securityCam"]) {
        image = SpliceKitLiveCamApplyFilter(image, @"CIPhotoEffectMono", @{});
        image = SpliceKitLiveCamApplyFilter(image, @"CIFalseColor", @{
            @"inputColor0": [CIColor colorWithRed:0.05 green:0.11 blue:0.05 alpha:1],
            @"inputColor1": [CIColor colorWithRed:0.52 green:1.00 blue:0.62 alpha:1],
        });
        image = SpliceKitLiveCamApplyFilter(image, @"CIColorControls", @{
            kCIInputContrastKey: @(1.35),
            kCIInputSaturationKey: @(0.6),
        });
        CIImage *noise = [self noiseImageForExtent:image.extent alpha:(0.08 + intensity * 0.08) monochrome:YES];
        if (noise) image = [noise imageByCompositingOverImage:image];
    } else if ([identifier isEqualToString:@"thermalFalseColor"]) {
        image = SpliceKitLiveCamApplyFilter(image, @"CIColorControls", @{
            kCIInputSaturationKey: @0.0,
            kCIInputContrastKey: @(1.25),
        });
        image = [self applyColorKernelNamed:@"thermal" toImage:image arguments:@[image]];
        image = SpliceKitLiveCamApplyFilter(image, @"CISharpenLuminance", @{ kCIInputSharpnessKey: @(0.7) });
    } else if ([identifier isEqualToString:@"comicPoster"]) {
        image = SpliceKitLiveCamApplyFilter(image, @"CIComicEffect", @{});
        image = SpliceKitLiveCamApplyFilter(image, @"CIColorPosterize", @{ @"inputLevels": @(6.0 + intensity * 3.0) });
    } else if ([identifier isEqualToString:@"dreamGlow"]) {
        image = SpliceKitLiveCamApplyFilter(image, @"CIBloom", @{
            kCIInputRadiusKey: @(15.0 + intensity * 12.0),
            kCIInputIntensityKey: @(0.4 + intensity * 0.5),
        });
        image = SpliceKitLiveCamApplyFilter(image, @"CIColorControls", @{
            kCIInputContrastKey: @(0.86),
            kCIInputSaturationKey: @(0.92),
        });
        image = SpliceKitLiveCamApplyFilter(image, @"CITemperatureAndTint", @{
            @"inputNeutral": [CIVector vectorWithX:6500 Y:0],
            @"inputTargetNeutral": [CIVector vectorWithX:7800 Y:0],
        });
    } else if ([identifier isEqualToString:@"mirrorSplit"]) {
        image = [self composeSplitImage:image mirrored:mirrored];
    } else if ([identifier isEqualToString:@"kaleidoscope"]) {
        image = SpliceKitLiveCamApplyFilter(image, @"CIKaleidoscope", @{
            kCIInputCenterKey: [CIVector vectorWithX:CGRectGetMidX(image.extent) Y:CGRectGetMidY(image.extent)],
            @"inputCount": @(6.0 + round(intensity * 2.0)),
            kCIInputAngleKey: @(time * 0.18),
        });
    } else if ([identifier isEqualToString:@"rgbSplit"]) {
        image = [self applyColorKernelNamed:@"rgbSplit" toImage:image arguments:@[image, @(1.0 + intensity * 5.0), @(0.3 + intensity * 1.4)]];
    } else if ([identifier isEqualToString:@"glitchJitter"]) {
        image = [self applyColorKernelNamed:@"glitch" toImage:image arguments:@[image, @(time), @(0.28 + intensity * 0.45)]];
        image = [self applyColorKernelNamed:@"rgbSplit" toImage:image arguments:@[image, @(0.6 + intensity * 2.5), @(0.0)]];
    } else if ([identifier isEqualToString:@"oldCamcorder"]) {
        image = SpliceKitLiveCamApplyFilter(image, @"CIColorControls", @{
            kCIInputContrastKey: @(1.02),
            kCIInputSaturationKey: @(0.82),
        });
        image = SpliceKitLiveCamApplyFilter(image, @"CITemperatureAndTint", @{
            @"inputNeutral": [CIVector vectorWithX:6500 Y:0],
            @"inputTargetNeutral": [CIVector vectorWithX:5200 Y:0],
        });
        image = [self applyWarpKernelNamed:@"vhsWarp" toImage:image arguments:@[@(time), @(0.08 + intensity * 0.12)]];
        image = [self applyColorKernelNamed:@"scanline" toImage:image arguments:@[image, @(0.12), @(time)]];
    } else if ([identifier isEqualToString:@"badVideoCall"]) {
        image = SpliceKitLiveCamApplyFilter(image, @"CIPixellate", @{ kCIInputScaleKey: @(5.0 + intensity * 10.0) });
        image = SpliceKitLiveCamApplyFilter(image, @"CIColorControls", @{
            kCIInputContrastKey: @(1.2 + intensity * 0.25),
            kCIInputSaturationKey: @(0.74),
        });
        image = [self applyColorKernelNamed:@"glitch" toImage:image arguments:@[image, @(time), @(0.16 + intensity * 0.25)]];
    } else if ([identifier isEqualToString:@"liquidWarp"]) {
        image = [self applyWarpKernelNamed:@"liquidWarp" toImage:image arguments:@[@(time), @(0.12 + intensity * 0.4)]];
    } else if ([identifier isEqualToString:@"slitScanTrail"]) {
        image = [self composeSlitScanForImage:image];
    } else if ([identifier isEqualToString:@"fisheyeBulge"]) {
        image = [self applyWarpKernelNamed:@"bulgeWarp" toImage:image arguments:@[@(0.2 + intensity * 0.24), @(CGRectGetWidth(image.extent)), @(CGRectGetHeight(image.extent))]];
        image = SpliceKitLiveCamApplyFilter(image, @"CIVignette", @{
            kCIInputIntensityKey: @(0.24),
            kCIInputRadiusKey: @(1.6),
        });
    } else if ([identifier isEqualToString:@"neonStream"]) {
        CIImage *edges = SpliceKitLiveCamApplyFilter(image, @"CIEdges", @{ kCIInputIntensityKey: @(8.0 + intensity * 6.0) });
        edges = SpliceKitLiveCamApplyFilter(edges, @"CIColorInvert", @{});
        edges = SpliceKitLiveCamApplyFilter(edges, @"CIColorControls", @{
            kCIInputSaturationKey: @(1.8),
            kCIInputContrastKey: @(1.25),
        });
        image = [edges imageByCompositingOverImage:image];
        image = SpliceKitLiveCamApplyFilter(image, @"CIBloom", @{
            kCIInputRadiusKey: @(10.0),
            kCIInputIntensityKey: @(0.22 + intensity * 0.25),
        });
    } else if ([identifier isEqualToString:@"faceCamPunch"]) {
        CGRect extent = image.extent;
        CGFloat scale = 1.07 + intensity * 0.13;
        CIImage *scaled = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
        CGRect scaledExtent = scaled.extent;
        CGFloat tx = CGRectGetMidX(extent) - CGRectGetMidX(scaledExtent);
        CGFloat ty = CGRectGetMidY(extent) - CGRectGetMidY(scaledExtent);
        image = [[scaled imageByApplyingTransform:CGAffineTransformMakeTranslation(tx, ty)] imageByCroppingToRect:extent];
        image = SpliceKitLiveCamApplyFilter(image, @"CIVignette", @{
            kCIInputIntensityKey: @(0.22 + intensity * 0.18),
            kCIInputRadiusKey: @(1.2),
        });
    }

    NSString *timestamp = nil;
    if (SpliceKitLiveCamTimestampOverlayEnabled() &&
        SpliceKitLiveCamPresetSupportsTimestampOverlay(identifier)) {
        timestamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                   dateStyle:NSDateFormatterShortStyle
                                                   timeStyle:NSDateFormatterMediumStyle];
        NSColor *tint = [identifier isEqualToString:@"securityCam"]
            ? [NSColor colorWithRed:0.80 green:1.00 blue:0.84 alpha:0.95]
            : [NSColor colorWithRed:1.00 green:0.93 blue:0.82 alpha:0.95];
        NSString *prefix = [identifier isEqualToString:@"badVideoCall"] ? @"NET UNSTABLE" : @"";
        CIImage *overlay = [self timestampOverlayForExtent:image.extent timestamp:timestamp tint:tint prefix:prefix];
        if (overlay) image = [overlay imageByCompositingOverImage:image];
    }

    if (recording) {
        NSString *clock = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                         dateStyle:NSDateFormatterNoStyle
                                                         timeStyle:NSDateFormatterMediumStyle];
        CIImage *recOverlay = [self recordingOverlayForExtent:image.extent timestamp:clock];
        if (recOverlay) image = [recOverlay imageByCompositingOverImage:image];
    }

    // Keep alpha intact for transparent-background mode. The preview path adds
    // its checkerboard later, and the recording path needs the untouched alpha
    // frame for ProRes 4444 output.
    BOOL preserveOutputAlpha = (maskParams != nil && maskParams.transparentBackground);
    return [self imageFittedForCanvas:[image imageByCroppingToRect:image.extent]
                           canvasSize:canvasSize
                                 fill:NO
                        preserveAlpha:preserveOutputAlpha];
}

@end
