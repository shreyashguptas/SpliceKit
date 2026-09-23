//
//  SpliceKitServerClipInfo.m
//  SpliceKit - timeline.getClipInfo and timeline.captureClipFrame; also batch actions,
//  set range, batch export (with its share-panel / open-URL swizzles) and
//  timeline.getState, which sit in the same section.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

static NSString *SpliceKit_symlinkTarget(NSString *path);

#pragma mark - timeline.getClipInfo / timeline.captureClipFrame
//
// Per-clip picture and context for one clip, by handle.
//
// timeline.getClipInfo is READ-ONLY (never moves the playhead or the selection).
// It reports the Info inspector's fields for the clip -- name, notes, Video Roles /
// Audio Roles, the source media file and which media representation it is
// (original / optimized / proxy, the names FCP lists under Available Media
// Representations) -- plus what SpliceKit adds from the model: timeline
// placement, effects, title text, the markers placed within the clip, the words
// of SpliceKit's Text-Based Editor transcript inside it, and a frame decoded
// from the source media file (JPEG, base64). The frame is decoded with
// AVFoundation on the calling thread, never inside the main-thread block.
//
// timeline.captureClipFrame CHANGES STATE and restores it: it seeks the
// playhead to the frame time, lets the Viewer render, captures the Viewer
// (effects included) and seeks back.
//
// Source start point / media start (the same math the transcript panel and
// the stabilization code use):
//   sourceStart = clip.trimStartTime (else trimmedOffset)   -- the clip's start point in the source media
//   mediaOrigin = mediaComponent.unclippedRange.start        -- where the source media starts in FCP's
//                                                              model (normally its starting source timecode)
//   sourceTime  = sourceStart + (timelineTime - clipStart)
//   fileTime    = sourceTime - mediaOrigin                   -- seconds into the media file
//

static BOOL SpliceKit_clipInfoBoolParam(NSDictionary *params, NSString *key, BOOL defaultValue) {
    id value = params[key];
    if ([value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]]) {
        return [value boolValue];
    }
    return defaultValue;
}

// The media component that carries a clip's source media. A compound clip,
// connected storyline or multicam item is a collection: dig into containedItems
// for the first FF*MediaComponent (bounded depth), as the stabilization code does.
// outDepth: 0 when `item` is the media component itself, 1 for a direct child (an
// ordinary clip with video and audio: the FFAnchoredCollection holding its components),
// 2 or more when it sits inside a nested container (compound, multicam, synchronized).
static id SpliceKit_clipInfoMediaComponentAtDepth(id item, int depth, int *outDepth) {
    if (!item || depth > 4) return nil;
    NSString *cls = NSStringFromClass([item class]) ?: @"";
    if ([cls containsString:@"MediaComponent"]) { if (outDepth) *outDepth = depth; return item; }
    if (![item respondsToSelector:@selector(containedItems)]) return nil;
    NSArray *contained = nil;
    @try {
        contained = SpliceKit_mixerArrayFromContainer(
            ((id (*)(id, SEL))objc_msgSend)(item, @selector(containedItems)));
    } @catch (NSException *e) { contained = nil; }
    for (id child in contained) {
        NSString *childClass = NSStringFromClass([child class]) ?: @"";
        if ([childClass containsString:@"MediaComponent"]) { if (outDepth) *outDepth = depth + 1; return child; }
    }
    for (id child in contained) {
        id found = SpliceKit_clipInfoMediaComponentAtDepth(child, depth + 1, outDepth);
        if (found) return found;
    }
    return nil;
}

id SpliceKit_clipInfoMediaComponentWithDepth(id item, int *outDepth) {
    if (outDepth) *outDepth = -1;
    return SpliceKit_clipInfoMediaComponentAtDepth(item, 0, outDepth);
}

// FCP's names for a media representation (Info inspector > Available Media
// Representations): original, optimized, proxy. Inside a library bundle FCP keeps
// them in "<Event>/Original Media", "<Event>/Transcoded Media/High Quality Media"
// (optimized) and "<Event>/Transcoded Media/Proxy Media"; media left in place or
// in an external storage location is original media. Returns `fallback` when the
// path does not say.
static NSString *SpliceKit_clipInfoRepresentationForPath(NSString *path, NSString *fallback) {
    if (path.length == 0) return fallback;
    if ([path rangeOfString:@"/Transcoded Media/Proxy Media/"].location != NSNotFound) return @"proxy";
    if ([path rangeOfString:@"/Transcoded Media/High Quality Media/"].location != NSNotFound) return @"optimized";
    if ([path rangeOfString:@"/Original Media/"].location != NSNotFound) return @"original";
    return fallback;
}

// First NSURL in an array-like value (a media rep's fileURLs is an NSArray of NSURL).
static NSURL *SpliceKit_clipInfoFirstURL(id value) {
    NSArray *urls = SpliceKit_mixerArrayFromContainer(value);
    for (id url in urls) {
        if ([url isKindOfClass:[NSURL class]]) return (NSURL *)url;
    }
    return nil;
}

// Source media file for a clip, mirroring -[SpliceKitTranscriptPanel getMediaURLForClip:]
// (Sources/Panels/Transcript/SpliceKitTranscriptPanel.m, not exported in its header).
// *outRepresentation is the media representation in FCP's words:
//   "original"  -- media.originalMediaURL / media.originalMediaRep / clipRef.assets.originalMediaURL
//   "optimized" / "proxy" / "original" -- media.currentRep (whichever FCP is using), classified
//                  from the file's place in the library (see SpliceKit_clipInfoRepresentationForPath)
//   "unknown"   -- a fallback hit whose path does not say
// *outSource names the exact chain that produced the URL so a live run can tell which fired.
NSURL *SpliceKit_clipInfoMediaURL(id item, NSString **outRepresentation, NSString **outSource) {
    if (!item) return nil;
    NSURL *found = nil;
    NSString *representation = @"unknown";
    NSString *source = @"";

    // Chain 1: clip.media -> originalMediaURL | originalMediaRep.(fileURLs|URL) | currentRep.fileURLs
    @try {
        SEL mediaSel = NSSelectorFromString(@"media");
        id media = [item respondsToSelector:mediaSel]
            ? ((id (*)(id, SEL))objc_msgSend)(item, mediaSel) : nil;
        if (media) {
            SEL omSel = NSSelectorFromString(@"originalMediaURL");
            if ([media respondsToSelector:omSel]) {
                id url = ((id (*)(id, SEL))objc_msgSend)(media, omSel);
                if ([url isKindOfClass:[NSURL class]]) {
                    found = url; representation = @"original"; source = @"media.originalMediaURL";
                }
            }
            SEL omrSel = NSSelectorFromString(@"originalMediaRep");
            if (!found && [media respondsToSelector:omrSel]) {
                id rep = ((id (*)(id, SEL))objc_msgSend)(media, omrSel);
                SEL fuSel = NSSelectorFromString(@"fileURLs");
                if (rep && [rep respondsToSelector:fuSel]) {
                    found = SpliceKit_clipInfoFirstURL(((id (*)(id, SEL))objc_msgSend)(rep, fuSel));
                    if (found) { representation = @"original"; source = @"media.originalMediaRep.fileURLs"; }
                }
                SEL urlSel = NSSelectorFromString(@"URL");
                if (!found && rep && [rep respondsToSelector:urlSel]) {
                    id url = ((id (*)(id, SEL))objc_msgSend)(rep, urlSel);
                    if ([url isKindOfClass:[NSURL class]]) {
                        found = url; representation = @"original"; source = @"media.originalMediaRep.URL";
                    }
                }
            }
            SEL crSel = NSSelectorFromString(@"currentRep");
            if (!found && [media respondsToSelector:crSel]) {
                id rep = ((id (*)(id, SEL))objc_msgSend)(media, crSel);
                SEL fuSel = NSSelectorFromString(@"fileURLs");
                if (rep && [rep respondsToSelector:fuSel]) {
                    found = SpliceKit_clipInfoFirstURL(((id (*)(id, SEL))objc_msgSend)(rep, fuSel));
                    if (found) {
                        representation = SpliceKit_clipInfoRepresentationForPath(found.path, @"unknown");
                        source = @"media.currentRep.fileURLs";
                    }
                }
            }
        }
    } @catch (NSException *e) { found = nil; }

    // Chain 1b: FFAnchoredClip -> clipRef (FFClipRef) -> assets (NSSet/NSArray of FFAsset) -> originalMediaURL
    if (!found) {
        @try {
            SEL clipRefSel = NSSelectorFromString(@"clipRef");
            id clipRef = [item respondsToSelector:clipRefSel]
                ? ((id (*)(id, SEL))objc_msgSend)(item, clipRefSel) : nil;
            SEL assetsSel = NSSelectorFromString(@"assets");
            if (clipRef && [clipRef respondsToSelector:assetsSel]) {
                NSArray *assets = SpliceKit_mixerArrayFromContainer(
                    ((id (*)(id, SEL))objc_msgSend)(clipRef, assetsSel));
                SEL omSel = NSSelectorFromString(@"originalMediaURL");
                for (id asset in assets) {
                    if (![asset respondsToSelector:omSel]) continue;
                    id url = ((id (*)(id, SEL))objc_msgSend)(asset, omSel);
                    if ([url isKindOfClass:[NSURL class]]) {
                        found = url; representation = @"original"; source = @"clipRef.assets.originalMediaURL";
                        break;
                    }
                }
            }
        } @catch (NSException *e) { found = nil; }
    }

    // Chain 2: key paths, each in its own @try (KVC raises for unknown keys).
    if (!found) {
        NSArray<NSString *> *keyPaths = @[@"resolvedURL", @"originalMediaURL", @"URL",
                                          @"assetMediaReference.resolvedURL",
                                          @"media.originalMediaURL", @"originalMediaRep.URL"];
        for (NSString *keyPath in keyPaths) {
            @try {
                id url = [item valueForKeyPath:keyPath];
                if ([url isKindOfClass:[NSURL class]]) {
                    found = url;
                    representation = [keyPath containsString:@"originalMedia"]
                        ? @"original" : SpliceKit_clipInfoRepresentationForPath(((NSURL *)url).path, @"unknown");
                    source = [@"keyPath:" stringByAppendingString:keyPath];
                    break;
                }
            } @catch (NSException *e) {}
        }
    }

    if (found) {
        if (outRepresentation) *outRepresentation = representation;
        if (outSource) *outSource = source;
    }
    return found;
}

// Role display name via <identifierSelector> + -[FFLibrary findRoleWithUID:], the
// lookup SpliceKit_readClipRole does for audioRoleIdentifier; used here for
// videoRoleIdentifier (unverified selector, guarded).
static NSString *SpliceKit_clipInfoRoleName(id clip, NSString *identifierSelector) {
    if (!clip || identifierSelector.length == 0) return nil;
    @try {
        SEL idSel = NSSelectorFromString(identifierSelector);
        if (![clip respondsToSelector:idSel]) return nil;
        if (!SpliceKit_selectorReturnsObject(clip, idSel)) return nil;
        id roleUID = ((id (*)(id, SEL))objc_msgSend)(clip, idSel);
        if (![roleUID isKindOfClass:[NSString class]] || [(NSString *)roleUID length] == 0) return nil;

        // Same +0 treatment as every other copyActiveLibraries call site in
        // SpliceKit (SpliceKit_readClipRole included). By Cocoa naming the
        // method should return +1, which would make this a small leak per call,
        // but that has not been verified live and an over-release would crash
        // FCP, so the shipped pattern stays until a live run settles it.
        id libs = ((id (*)(Class, SEL))objc_msgSend)(
            objc_getClass("FFLibraryDocument"), NSSelectorFromString(@"copyActiveLibraries"));
        if (![libs isKindOfClass:[NSArray class]]) return nil;
        SEL findSel = NSSelectorFromString(@"findRoleWithUID:");
        for (id library in (NSArray *)libs) {
            if (![library respondsToSelector:findSel]) continue;
            id role = ((id (*)(id, SEL, id))objc_msgSend)(library, findSel, roleUID);
            if (!role || ![role respondsToSelector:@selector(displayName)]) continue;
            id name = ((id (*)(id, SEL))objc_msgSend)(role, @selector(displayName));
            if ([name isKindOfClass:[NSString class]] && [(NSString *)name length] > 0) {
                return (NSString *)name;
            }
        }
    } @catch (NSException *e) {}
    return nil;
}

// Text channels of a title / generator, for an arbitrary clip object (the
// selection-based inspector.getTitle walks the same chain): primary
// clip.effect -> channelFolder; fallback clip.effectStack -> visibleEffects ->
// each channelFolder. Returns the channel dicts SpliceKit_collectTitleText
// produces (text, fontName, fontFamily, fontSize, textColor, channelName,
// channelID, handle) or nil when the clip has no text channels.
static NSArray *SpliceKit_clipInfoTitleText(id clip) {
    if (!clip) return nil;
    NSMutableArray *channels = [NSMutableArray array];
    @try {
        SEL effectSel = NSSelectorFromString(@"effect");
        id genEffect = [clip respondsToSelector:effectSel]
            ? ((id (*)(id, SEL))objc_msgSend)(clip, effectSel) : nil;
        if (genEffect) {
            SEL cfSel = NSSelectorFromString(@"channelFolder");
            id cf = [genEffect respondsToSelector:cfSel]
                ? ((id (*)(id, SEL))objc_msgSend)(genEffect, cfSel) : nil;
            if (cf) SpliceKit_collectTitleText(cf, channels, 0);
        }
    } @catch (NSException *e) {}

    if (channels.count == 0) {
        @try {
            SEL esSel = @selector(effectStack);
            id effectStack = [clip respondsToSelector:esSel]
                ? ((id (*)(id, SEL))objc_msgSend)(clip, esSel) : nil;
            SEL veSel = NSSelectorFromString(@"visibleEffects");
            if (effectStack && [effectStack respondsToSelector:veSel]) {
                NSArray *effects = SpliceKit_mixerArrayFromContainer(
                    ((id (*)(id, SEL))objc_msgSend)(effectStack, veSel));
                SEL cfSel = NSSelectorFromString(@"channelFolder");
                for (id effect in effects) {
                    if (![effect respondsToSelector:cfSel]) continue;
                    id cf = ((id (*)(id, SEL))objc_msgSend)(effect, cfSel);
                    if (cf) SpliceKit_collectTitleText(cf, channels, 0);
                }
            }
        } @catch (NSException *e) {}
    }
    return channels.count > 0 ? channels : nil;
}

// Transcript words (SpliceKit's Text-Based Editor) whose [startTime, endTime) overlaps the
// clip's absolute timeline range [start, end). Word times are timeline seconds.
// Capped at 400 words (`truncated`). `matchedByHandle` counts the words whose
// clipHandle is this clip's handle (a consistency check, not a filter).
static NSDictionary *SpliceKit_clipInfoTranscriptWords(double start, double end, NSString *handle) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"available"] = @NO;
    out[@"status"] = @"idle";
    out[@"wordCount"] = @0;
    out[@"matchedByHandle"] = @0;
    out[@"words"] = @[];
    out[@"text"] = @"";
    out[@"truncated"] = @NO;
    @try {
        SpliceKitTranscriptPanel *panel = [SpliceKitTranscriptPanel sharedPanel];
        if (!panel) return out;
        // Load the cached transcript for the current sequence if it is not in
        // memory yet (and drop words that belong to another project). This is
        // the same call transcript.getState makes; it reads the per-sequence
        // state file but, unlike getState, allocates nothing per word.
        [panel ensurePersistedStateLoaded];
        switch (panel.status) {
            case SpliceKitTranscriptStatusIdle:         out[@"status"] = @"idle"; break;
            case SpliceKitTranscriptStatusTranscribing: out[@"status"] = @"transcribing"; break;
            case SpliceKitTranscriptStatusReady:        out[@"status"] = @"ready"; break;
            case SpliceKitTranscriptStatusError:        out[@"status"] = @"error"; break;
        }
        out[@"engine"] = (panel.engine == SpliceKitTranscriptEngineFCPNative) ? @"fcpNative" :
                         (panel.engine == SpliceKitTranscriptEngineParakeet) ? @"parakeet" : @"appleSpeech";

        NSArray<SpliceKitTranscriptWord *> *words = panel.words;
        out[@"timelineWordCount"] = @(words.count);
        if (words.count == 0) return out;
        out[@"available"] = @YES;

        NSMutableArray *rows = [NSMutableArray array];
        NSMutableArray<NSString *> *texts = [NSMutableArray array];
        NSMutableArray<NSString *> *speakers = [NSMutableArray array];
        NSInteger inClip = 0;
        NSInteger matched = 0;
        BOOL truncated = NO;
        for (SpliceKitTranscriptWord *word in words) {
            if (![word isKindOfClass:[SpliceKitTranscriptWord class]]) continue;
            double wordStart = word.startTime;
            double wordEnd = word.endTime;
            if (wordEnd <= wordStart) wordEnd = wordStart + MAX(0.0, word.duration);
            if (wordEnd <= start || wordStart >= end) continue;
            inClip++;
            if (handle.length > 0 && [word.clipHandle isEqualToString:handle]) matched++;
            if (rows.count >= 400) { truncated = YES; continue; }

            NSMutableDictionary *row = [NSMutableDictionary dictionary];
            row[@"text"] = word.text ?: @"";
            row[@"startTime"] = @(wordStart);
            row[@"endTime"] = @(wordEnd);
            row[@"confidence"] = @(word.confidence);
            row[@"wordIndex"] = @(word.wordIndex);
            if (word.speaker.length > 0) {
                row[@"speaker"] = word.speaker;
                if (![speakers containsObject:word.speaker]) [speakers addObject:word.speaker];
            }
            if (word.clipHandle.length > 0) row[@"clipHandle"] = word.clipHandle;
            [rows addObject:row];
            if (word.text.length > 0) [texts addObject:word.text];
        }
        out[@"wordCount"] = @(inClip);
        out[@"matchedByHandle"] = @(matched);
        out[@"words"] = rows;
        out[@"text"] = [texts componentsJoinedByString:@" "];
        out[@"speakers"] = speakers;
        out[@"truncated"] = @(truncated);
    } @catch (NSException *e) {
        out[@"error"] = [NSString stringWithFormat:@"Exception: %@", e.reason];
    }
    return out;
}

// JPEG (quality 0.75) from a CGImage, downscaled through a CGBitmapContext so
// that its longest side is at most maxSide (the same box AVAssetImageGenerator's
// square maximumSize enforces). Never consumes `image`; the caller releases it.
static NSData *SpliceKit_clipInfoJPEGFromCGImage(CGImageRef image, int maxSide, int *outWidth, int *outHeight) {
    if (!image) return nil;
    size_t srcWidth = CGImageGetWidth(image);
    size_t srcHeight = CGImageGetHeight(image);
    if (srcWidth == 0 || srcHeight == 0) return nil;

    CGImageRef scaled = NULL;
    CGImageRef source = image;
    size_t longest = MAX(srcWidth, srcHeight);
    if (maxSide > 0 && longest > (size_t)maxSide) {
        double scale = (double)maxSide / (double)longest;
        size_t dstWidth = (size_t)MAX(1LL, llround((double)srcWidth * scale));
        size_t dstHeight = (size_t)MAX(1LL, llround((double)srcHeight * scale));
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = colorSpace
            ? CGBitmapContextCreate(NULL, dstWidth, dstHeight, 8, 0, colorSpace,
                                    kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big)
            : NULL;
        if (ctx) {
            CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
            CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)dstWidth, (CGFloat)dstHeight), image);
            scaled = CGBitmapContextCreateImage(ctx);
            CGContextRelease(ctx);
        }
        if (colorSpace) CGColorSpaceRelease(colorSpace);
        if (scaled) source = scaled;
    }

    NSData *jpeg = nil;
    @try {
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:source];
        jpeg = [rep representationUsingType:NSBitmapImageFileTypeJPEG
                                 properties:@{NSImageCompressionFactor: @0.75}];
    } @catch (NSException *e) { jpeg = nil; }
    if (outWidth) *outWidth = (int)CGImageGetWidth(source);
    if (outHeight) *outHeight = (int)CGImageGetHeight(source);
    if (scaled) CGImageRelease(scaled);
    return jpeg;
}

// SpliceKit's classification of a timeline item (SpliceKit bookkeeping, spelled
// with FCP's words), from the class name: FFAnchoredGapGeneratorComponent -> gap
// clip, FFAnchoredTransition -> transition, FFAnchoredCaption -> caption,
// FFAnchoredGeneratorComponent -> generator (FCP's titles are generator components
// with a title effect; the caller upgrades a generator with text channels to
// "title"); then FCP's own flags: isConnectedStoryline -> connected storyline,
// isCompoundClip -> compound clip, isReferenceClip -> reference clip (a compound,
// multicam or synchronized clip), a multicam flag -> multicam clip; everything else
// (a media component, or the FFAnchoredCollection FCP wraps a clip with both video
// and audio in) by its video/audio flags.
NSString *SpliceKit_clipInfoKindForItem(id item, BOOL hasVideo, BOOL hasAudio) {
    NSString *cls = item ? (NSStringFromClass([item class]) ?: @"") : @"";
    if ([cls containsString:@"Gap"]) return @"gap clip";
    if ([cls containsString:@"Transition"]) return @"transition";
    if ([cls containsString:@"Caption"]) return @"caption";
    if ([cls containsString:@"Title"]) return @"title";
    if ([cls containsString:@"Generator"]) {
        NSArray<NSString *> *titleSelectors = @[@"isTitle", @"isTitleGenerator", @"isTitleClip"];
        for (NSString *selName in titleSelectors) {
            BOOL flag = NO;
            if (SpliceKit_tryReadBoolSelector(item, selName, &flag) && flag) return @"title";
        }
        return @"generator";
    }
    if (SpliceKit_boolForSelector(item, @"isConnectedStoryline")) return @"connected storyline";
    if (SpliceKit_itemIsMulticamClip(item)) return @"multicam clip";
    NSString *containerKind = SpliceKit_itemContainerKind(item);
    if (containerKind) return containerKind;
    // An FFAnchoredCollection that is none of those is an ordinary clip: FCP wraps a
    // clip that carries both video and audio in a collection of media components.
    if (hasVideo) return @"video clip";
    if (hasAudio) return @"audio clip";
    return @"clip";
}

// Frame time for a clip: the midpoint unless the caller asked for an absolute
// timeline time, which is clamped into [clipStart, clipEnd - 1 ms].
static double SpliceKit_clipInfoFrameTime(double clipStart, double clipEnd, BOOL haveRequested,
                                          double requested, BOOL *outClamped) {
    if (outClamped) *outClamped = NO;
    if (!haveRequested || !isfinite(requested)) return (clipStart + clipEnd) / 2.0;
    double lastInside = MAX(clipStart, clipEnd - 0.001);
    if (requested < clipStart) { if (outClamped) *outClamped = YES; return clipStart; }
    if (requested > lastInside) { if (outClamped) *outClamped = YES; return lastInside; }
    return requested;
}

// The clip's start point in its source media, in the media's own time (which starts at
// the media's timecode origin, see unclippedRange): read from the first of `targets`
// (the timeline item, then its media component) that answers clippedRange (its start;
// the reading the transcript panel's clip-to-file conversion is built on and that FCP
// 12.3's clips answer), then trimStartTime, then trimmedOffset. Returns NO when none
// answers; *outSelector names the reading, or "none". Without a source start there is
// nothing to subtract the origin from, so callers take the file start as 0 and say so
// -- subtracting the origin from a 0 that was never read is what placed every clip
// with a start timecode tens of thousands of seconds before its file (QA run 2).
static BOOL SpliceKit_readSourceStart(NSArray *targets, CMTime *outTime, NSString **outSelector) {
    if (outSelector) *outSelector = @"none";
    for (id target in targets) {
        CMTimeRange clipped = {{0, 0, 0, 0}, {0, 0, 0, 0}};
        if (SpliceKit_tryReadCMTimeRangeSelector(target, @"clippedRange", &clipped)) {
            if (outTime) *outTime = clipped.start;
            if (outSelector) *outSelector = @"clippedRange";
            return YES;
        }
    }
    for (NSString *name in @[@"trimStartTime", @"trimmedOffset"]) {
        for (id target in targets) {
            CMTime t = {0, 0, 0, 0};
            if (SpliceKit_tryReadCMTimeSelector(target, name, &t)) {
                if (outTime) *outTime = t;
                if (outSelector) *outSelector = name;
                return YES;
            }
        }
    }
    return NO;
}

// A source start read from the item (a collection's clippedRange) in the media file's
// own time. When FCP conforms a clip's frame rate (30 fps media in a 29.97 project) the
// collection's ranges are in conformed time and the media component's in file time:
// media starting at timecode 74435 s reads 74509.435 s on the collection, and
// subtracting the media origin from that put the clip 74 s into a 45 s file. The two
// unclipped ranges give the factor. *outFactor is timeline seconds per file second
// (1 when there is nothing to convert).
static double SpliceKit_sourceStartInMediaTime(NSArray *targets, double sourceStart, double *outFactor) {
    if (outFactor) *outFactor = 1.0;
    if (targets.count < 2) return sourceStart;
    CMTimeRange outer = {{0, 0, 0, 0}, {0, 0, 0, 0}}, inner = {{0, 0, 0, 0}, {0, 0, 0, 0}};
    if (!SpliceKit_tryReadCMTimeRangeSelector(targets.firstObject, @"unclippedRange", &outer) ||
        !SpliceKit_tryReadCMTimeRangeSelector(targets.lastObject, @"unclippedRange", &inner)) {
        return sourceStart;
    }
    double outerStart = SpliceKit_secondsFromTime(outer.start), outerDur = SpliceKit_secondsFromTime(outer.duration);
    double innerStart = SpliceKit_secondsFromTime(inner.start), innerDur = SpliceKit_secondsFromTime(inner.duration);
    if (!(outerDur > 0) || !(innerDur > 0)) return sourceStart;
    // FCP's automatic rate conform only joins close rates (23.98/24/25, 29.97/30); a
    // container of clips (compound, multicam) spans its own timeline, not a rate.
    if (SpliceKit_boolForSelector(targets.firstObject, @"isReferenceClip")) return sourceStart;
    double factor = outerDur / innerDur;
    if (!isfinite(factor) || factor < 0.95 || factor > 1.05) return sourceStart;
    if (fabs(factor - 1.0) <= 1e-5 && fabs(outerStart - innerStart) <= 0.001) return sourceStart;
    if (outFactor) *outFactor = factor;
    return innerStart + (sourceStart - outerStart) / factor;
}

// Source media of one timeline item for timeline.getAudioLevels (SpliceKitAudioLevels.m):
// the same media file, source start and media origin resolution getClipInfo reports,
// without the frame decode. Main thread only. `fileStart` is how many seconds into the
// media file the clip's first frame lies; add (timeline time - clip start) to it.
NSDictionary *SpliceKit_audioSourceForItem(id item) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if (!item) { out[@"error"] = @"nil item"; return out; }
    @try {
        NSString *cls = NSStringFromClass([item class]) ?: @"";
        BOOL hasAudio = SpliceKit_boolForSelector(item, @"hasAudio");
        BOOL hasVideo = SpliceKit_boolForSelector(item, @"hasVideo");
        out[@"class"] = cls;
        out[@"name"] = SpliceKit_displayNameForItem(item) ?: @"";
        out[@"hasAudio"] = @(hasAudio);
        out[@"hasVideo"] = @(hasVideo);
        out[@"kind"] = SpliceKit_clipInfoKindForItem(item, hasVideo, hasAudio) ?: @"";
        out[@"isCollection"] = @([cls containsString:@"Collection"]);

        int mediaDepth = -1;
        id mediaComp = SpliceKit_clipInfoMediaComponentWithDepth(item, &mediaDepth);
        out[@"mediaComponentDepth"] = @(mediaDepth);
        NSMutableArray *targets = [NSMutableArray arrayWithObject:item];
        if (mediaComp && mediaComp != item) [targets addObject:mediaComp];

        NSString *representation = nil, *urlSource = nil;
        NSURL *mediaURL = SpliceKit_clipInfoMediaURL(mediaComp ?: item, &representation, &urlSource);
        if (!mediaURL && mediaComp && mediaComp != item) {
            mediaURL = SpliceKit_clipInfoMediaURL(item, &representation, &urlSource);
        }

        CMTime sourceStart = {0, 0, 0, 0};
        NSString *sourceStartSelector = @"none";
        BOOL haveSourceStart = SpliceKit_readSourceStart(targets, &sourceStart, &sourceStartSelector);
        double sourceStartSeconds = haveSourceStart ? SpliceKit_secondsFromTime(sourceStart) : 0.0;
        double rateConform = 1.0;
        if (haveSourceStart && [sourceStartSelector isEqualToString:@"clippedRange"]) {
            sourceStartSeconds = SpliceKit_sourceStartInMediaTime(targets, sourceStartSeconds, &rateConform);
        }
        if (rateConform != 1.0) out[@"rateConformFactor"] = @(rateConform);
        CMTimeRange unclipped = {{0, 0, 0, 0}, {0, 0, 0, 0}};
        NSString *mediaOriginSelector = @"none";
        double mediaOriginSeconds = 0.0;
        for (id target in [[targets reverseObjectEnumerator] allObjects]) {
            if (SpliceKit_tryReadCMTimeRangeSelector(target, @"unclippedRange", &unclipped)) {
                mediaOriginSelector = @"unclippedRange";
                mediaOriginSeconds = SpliceKit_secondsFromTime(unclipped.start);
                break;
            }
        }
        out[@"sourceStart"] = @(sourceStartSeconds);
        out[@"sourceStartSelector"] = sourceStartSelector;
        out[@"sourceStartKnown"] = @(haveSourceStart);
        out[@"mediaOrigin"] = @(mediaOriginSeconds);
        out[@"mediaOriginSelector"] = mediaOriginSelector;
        out[@"fileStart"] = @(haveSourceStart ? (sourceStartSeconds - mediaOriginSeconds) : 0.0);

        if (mediaURL) {
            // No file-system access here: this runs on the main thread, and a stat on an
            // offline volume can block for seconds. The caller checks existence off main.
            NSString *path = mediaURL.path ?: (mediaURL.absoluteString ?: @"");
            out[@"path"] = path;
            out[@"fileName"] = mediaURL.lastPathComponent ?: @"";
            out[@"representation"] = representation ?: @"unknown";
            out[@"urlSource"] = urlSource ?: @"";
        }

        // Retiming changes the source-to-timeline mapping. Unverified selector names; only a
        // selector whose type encoding really returns BOOL is called (tryReadBoolSelector),
        // so a same-named method returning an object or a struct is never invoked.
        NSString *retimeSelector = nil;
        BOOL retimed = NO;
        for (NSString *name in @[@"isRetimed", @"hasRetiming", @"hasTimeMap", @"isSpeedChanged", @"hasSpeedChange"]) {
            for (id target in targets) {
                BOOL flag = NO;
                if (SpliceKit_tryReadBoolSelector(target, name, &flag)) {
                    retimeSelector = name;
                    retimed = flag;
                    break;
                }
            }
            if (retimeSelector) break;
        }
        out[@"retimed"] = retimeSelector ? (id)@(retimed) : (id)@"unknown";
        if (retimeSelector) out[@"retimeSelector"] = retimeSelector;
    } @catch (NSException *e) {
        out[@"error"] = e.reason ?: @"exception while resolving the source media";
    }
    return out;
}

// timeline.getClipInfo -- read-only clip information by handle.
//   params: handle (required), includeFrame (YES), frameTime (absolute timeline
//           seconds inside the clip; default midpoint), frameMaxWidth (640, 64..1920),
//           includeTranscript (YES), includeEffects (YES), includeMarkers (YES)
NSDictionary *SpliceKit_handleTimelineGetClipInfo(NSDictionary *params) {
    NSString *handle = [params[@"handle"] isKindOfClass:[NSString class]] ? params[@"handle"] : nil;
    if (handle.length == 0) {
        return @{@"error": @"handle parameter required (a clip handle from timeline.getDetailedState)"};
    }
    BOOL includeFrame = SpliceKit_clipInfoBoolParam(params, @"includeFrame", YES);
    BOOL includeTranscript = SpliceKit_clipInfoBoolParam(params, @"includeTranscript", YES);
    BOOL includeEffects = SpliceKit_clipInfoBoolParam(params, @"includeEffects", YES);
    BOOL includeMarkers = SpliceKit_clipInfoBoolParam(params, @"includeMarkers", YES);
    BOOL haveFrameTime = [params[@"frameTime"] isKindOfClass:[NSNumber class]];
    double frameTimeParam = haveFrameTime ? [params[@"frameTime"] doubleValue] : 0.0;
    int frameMaxWidth = [params[@"frameMaxWidth"] isKindOfClass:[NSNumber class]]
        ? [params[@"frameMaxWidth"] intValue] : 640;
    if (frameMaxWidth < 64) frameMaxWidth = 64;
    if (frameMaxWidth > 1920) frameMaxWidth = 1920;

    double startedAt = CFAbsoluteTimeGetCurrent();
    __block NSDictionary *result = nil;
    __block NSMutableDictionary *info = nil;
    __block NSURL *frameURL = nil;
    __block double clipStartSeconds = 0.0;
    __block double clipEndSeconds = 0.0;
    __block double sourceStartSeconds = 0.0;
    __block double mediaOriginSeconds = 0.0;
    __block BOOL sourceStartKnown = NO;
    __block BOOL haveRange = NO;
    __block BOOL sourceExists = NO;
    __block NSString *noSingleSourceFrameOut = nil;   // why no frame comes from a media file (set below)

    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) { result = @{@"error": @"No active timeline module"}; return; }

            id sequence = [timeline respondsToSelector:@selector(sequence)]
                ? ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence)) : nil;
            if (!sequence) { result = @{@"error": @"No sequence in timeline"}; return; }

            id primaryObj = [sequence respondsToSelector:@selector(primaryObject)]
                ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject)) : nil;
            if (!primaryObj) { result = @{@"error": @"Cannot access primary storyline"}; return; }

            CMTimeRange range = {{0, 0, 0, 0}, {0, 0, 0, 0}};
            NSString *resolveError = nil;
            id item = SpliceKit_handleResolveTimelineClip(handle, primaryObj, &range, &resolveError);
            if (!item) {
                if ([resolveError hasPrefix:@"markers are not clips"]) {
                    resolveError = @"a marker is not a clip (markers are placed within clips); use list_markers or the marker actions";
                }
                result = @{@"error": resolveError ?: @"clip is not in the active sequence", @"handle": handle};
                return;
            }
            // A nested connected clip whose absolute range the connected walk could
            // not compute still gets everything that does not need placement.
            haveRange = (range.start.timescale > 0 && range.duration.timescale > 0);

            // Built locally and published to `info` as the LAST statement, so a
            // 20 s watchdog timeout in SpliceKit_executeOnMainThread can never
            // hand the RPC thread a dictionary this thread is still filling.
            NSMutableDictionary *local = [NSMutableDictionary dictionary];
            local[@"handle"] = handle;
            local[@"class"] = NSStringFromClass([item class]) ?: @"";
            local[@"name"] = SpliceKit_displayNameForItem(item) ?: @"";
            BOOL hasVideo = SpliceKit_boolForSelector(item, @"hasVideo");
            BOOL hasAudio = SpliceKit_boolForSelector(item, @"hasAudio");
            local[@"hasVideo"] = @(hasVideo);
            local[@"hasAudio"] = @(hasAudio);
            local[@"lane"] = @(SpliceKit_laneForItem(item));

            // Placement on the timeline.
            double clipDuration = 0.0;
            if (haveRange) {
                clipStartSeconds = SpliceKit_secondsFromTime(range.start);
                clipDuration = SpliceKit_secondsFromTime(range.duration);
                clipEndSeconds = clipStartSeconds + clipDuration;
                local[@"startTime"] = SpliceKit_serializeCMTime(range.start);
                local[@"endTime"] = SpliceKit_serializeCMTime(SpliceKit_endTimeForRange(range));
                local[@"duration"] = SpliceKit_serializeCMTime(range.duration);
                local[@"timeline"] = @{@"start": @(clipStartSeconds), @"end": @(clipEndSeconds),
                                      @"duration": @(clipDuration)};
            } else {
                local[@"timelineRangeError"] = @"the clip's absolute timeline range could not be determined (nested connected clip); "
                                              @"start/end, transcript words and the frame need it; timeline.getDetailedState shows what is known";
            }

            // Primary storyline membership (pointer identity, as trimClip does).
            BOOL isSpineItem = NO;
            @try {
                id spineItems = [primaryObj respondsToSelector:@selector(containedItems)]
                    ? ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems)) : nil;
                for (id spineItem in SpliceKit_mixerArrayFromContainer(spineItems)) {
                    if (spineItem == item) { isSpineItem = YES; break; }
                }
            } @catch (NSException *e) {}
            local[@"onPrimaryStoryline"] = @(isSpineItem);

            BOOL enabledFlag = NO;
            if (SpliceKit_tryReadBoolSelector(item, @"isEnabled", &enabledFlag) ||
                SpliceKit_tryReadBoolSelector(item, @"enabled", &enabledFlag)) {
                local[@"enabled"] = @(enabledFlag);
            }

            // Selection membership (same query timeline.getDetailedState uses).
            NSMutableSet<NSString *> *selectedKeys =
                SpliceKit_handleSelectionPointerKeys(SpliceKit_handleSelectionCurrentItems(timeline));
            NSString *itemKey = SpliceKit_handlePointerKey(item);
            local[@"selected"] = (itemKey.length > 0 && [selectedKeys containsObject:itemKey]) ? @YES : @NO;

            // Roles (Info inspector: Video Role / Audio Role).
            NSMutableDictionary *roles = [NSMutableDictionary dictionary];
            NSString *audioRole = SpliceKit_readClipRole(item);
            if (audioRole.length > 0) roles[@"audio"] = audioRole;
            NSString *videoRole = SpliceKit_clipInfoRoleName(item, @"videoRoleIdentifier");
            if (videoRole.length > 0) roles[@"video"] = videoRole;
            local[@"roles"] = roles;

            // The object that carries the source media (the item itself for a
            // plain clip; the first media component inside a collection).
            int mediaDepth = -1;
            id mediaComp = SpliceKit_clipInfoMediaComponentWithDepth(item, &mediaDepth);
            NSMutableArray *probeTargets = [NSMutableArray arrayWithObject:item];
            if (mediaComp && mediaComp != item) [probeTargets addObject:mediaComp];
            if (mediaComp && mediaComp != item) {
                local[@"mediaComponentClass"] = NSStringFromClass([mediaComp class]) ?: @"";
                local[@"mediaComponentDepth"] = @(mediaDepth);
            }

            // A compound, multicam or synchronized clip on the timeline (FCP: reference
            // clip; isCompoundClip / isReferenceClip answer YES) has no single source
            // media file: its contents are clips of their own. QA run 3: the first file
            // found inside one was presented as the clip's source, the compound's own
            // range was read as the media origin, and the frame came from the wrong
            // footage. The same holds when the first media file sits two or more
            // containers down. No source file and no frame are reported for these;
            // timeline.captureClipFrame renders them from the Viewer.
            // The kind is decided once, by SpliceKit_clipInfoKindForItem (class-name kinds
            // first, then FCP's flags), so the container decision and the reported kind agree.
            NSString *kind = SpliceKit_clipInfoKindForItem(item, hasVideo, hasAudio);
            NSString *flagKind = SpliceKit_itemContainerKind(item);   // FCP's flags, as getDetailedState reports them
            if ([flagKind isEqualToString:@"compound clip"]) local[@"isCompound"] = @YES;
            if ([flagKind isEqualToString:@"reference clip"]) local[@"isReferenceClip"] = @YES;
            NSString *containerKind = ([kind isEqualToString:@"compound clip"] || [kind isEqualToString:@"reference clip"]
                                       || [kind isEqualToString:@"multicam clip"]) ? kind : nil;
            if (containerKind) local[@"containerKind"] = containerKind;
            NSString *noSingleSource = nil;
            if (containerKind) {
                noSingleSource = [NSString stringWithFormat:
                    @"no single source media file: this is a %@, whose contents are clips of their own, each with "
                    @"its own media file (Final Cut Pro opens it in its own timeline: select it and "
                    @"timeline_action(\"openClip\")); timeline.captureClipFrame renders it as the Viewer shows it",
                    containerKind];
            } else if (mediaDepth >= 2) {
                noSingleSource = [NSString stringWithFormat:
                    @"no single source media file: the first media file inside this clip was found %d levels down "
                    @"inside nested containers, and nothing says which part of this clip that file is; "
                    @"timeline.captureClipFrame renders it as the Viewer shows it",
                    mediaDepth];
            }
            // Nothing inside a container is read as the container's own (its first inner
            // clip's Notes included): only the item itself is probed from here on.
            if (noSingleSource && mediaComp && mediaComp != item) [probeTargets removeObject:mediaComp];
            if (containerKind) {
                noSingleSourceFrameOut = [NSString stringWithFormat:
                    @"no single source media file to decode a frame from: this is a %@ whose contents are clips "
                    @"of their own; timeline.captureClipFrame renders it as the Viewer shows it", containerKind];
            } else if (noSingleSource) {
                noSingleSourceFrameOut = [NSString stringWithFormat:
                    @"no single source media file to decode a frame from: the first media file inside this clip sits "
                    @"%d levels down inside nested containers; timeline.captureClipFrame renders it as the Viewer shows it",
                    mediaDepth];
            }

            // Notes (Info inspector: Notes). Unverified selectors, guarded.
            for (id target in probeTargets) {
                NSString *note = SpliceKit_tryReadStringSelector(target, @"note");
                if (note.length == 0) note = SpliceKit_tryReadStringSelector(target, @"notes");
                if (note.length > 0) { local[@"notes"] = note; break; }
            }

            // Source media file (not looked up for a container: see above).
            NSString *representation = nil;
            NSString *urlSource = nil;
            NSURL *mediaURL = nil;
            if (!noSingleSource) {
                mediaURL = SpliceKit_clipInfoMediaURL(mediaComp ?: item, &representation, &urlSource);
                if (!mediaURL && mediaComp && mediaComp != item) {
                    mediaURL = SpliceKit_clipInfoMediaURL(item, &representation, &urlSource);
                }
            }

            // Source start point (clippedRange.start, else trimStartTime, else trimmedOffset;
            // see SpliceKit_readSourceStart) and where the source media starts
            // (unclippedRange.start, media component first). Not read for a container:
            // its clippedRange / unclippedRange describe its own inner timeline.
            CMTime sourceStart = {0, 0, 0, 0};
            NSString *sourceStartSelector = @"none";
            BOOL haveSourceStart = noSingleSource ? NO
                : SpliceKit_readSourceStart(probeTargets, &sourceStart, &sourceStartSelector);
            sourceStartKnown = haveSourceStart;
            sourceStartSeconds = haveSourceStart ? SpliceKit_secondsFromTime(sourceStart) : 0.0;
            double rateConform = 1.0;
            if (haveSourceStart && [sourceStartSelector isEqualToString:@"clippedRange"]) {
                sourceStartSeconds = SpliceKit_sourceStartInMediaTime(probeTargets, sourceStartSeconds, &rateConform);
            }
            if (rateConform != 1.0) local[@"rateConformFactor"] = @(rateConform);
            CMTimeRange unclipped = {{0, 0, 0, 0}, {0, 0, 0, 0}};
            NSString *mediaOriginSelector = @"none";
            mediaOriginSeconds = 0.0;
            if (!noSingleSource) {
                for (id target in [[probeTargets reverseObjectEnumerator] allObjects]) {
                    if (SpliceKit_tryReadCMTimeRangeSelector(target, @"unclippedRange", &unclipped)) {
                        mediaOriginSelector = @"unclippedRange";
                        mediaOriginSeconds = SpliceKit_secondsFromTime(unclipped.start);
                        break;
                    }
                }
            }

            if (noSingleSource) {
                local[@"sourceMediaError"] = noSingleSource;
            } else if (mediaURL) {
                frameURL = mediaURL;
                NSString *path = mediaURL.path ?: (mediaURL.absoluteString ?: @"");
                BOOL exists = path.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:path];
                sourceExists = exists;
                // Without a source start there is nothing to subtract the origin from: the
                // file start is taken as 0 (right for a clip whose start is not trimmed).
                double fileStart = sourceStartKnown ? (sourceStartSeconds - mediaOriginSeconds) : 0.0;
                local[@"sourceMedia"] = @{
                    @"path": path,
                    // A library's "Original Media" entry is often a symlink to the real
                    // file (on a NAS, say). Following it with readlink only never touches
                    // the target volume, so an offline share cannot stall this.
                    @"resolvedPath": SpliceKit_symlinkTarget(path) ?: path,
                    @"isSymlink": @(SpliceKit_symlinkTarget(path) != nil),
                    @"fileName": mediaURL.lastPathComponent ?: @"",
                    @"exists": @(exists),
                    @"representation": representation ?: @"unknown",
                    @"urlSource": urlSource ?: @"",
                    @"sourceStart": @(sourceStartSeconds),
                    @"sourceStartSelector": sourceStartSelector,
                    @"sourceStartKnown": @(sourceStartKnown),
                    @"mediaOrigin": @(mediaOriginSeconds),
                    @"mediaOriginSelector": mediaOriginSelector,
                    @"fileStart": @(fileStart),
                    @"fileEnd": @(fileStart + clipDuration / rateConform),
                };
            } else {
                local[@"sourceMediaError"] = @"no source media file: this is a title, generator or gap clip (a clip whose media file is missing still reports its path with exists=false)";
            }

            // Effects (same reader as effects.getClipEffects; runs inline on the main thread).
            if (includeEffects) {
                NSDictionary *fx = SpliceKit_handleGetClipEffects(@{@"handle": handle});
                NSArray *effects = [fx[@"effects"] isKindOfClass:[NSArray class]] ? fx[@"effects"] : @[];
                local[@"effects"] = effects;
                local[@"effectCount"] = [fx[@"effectCount"] isKindOfClass:[NSNumber class]]
                    ? fx[@"effectCount"] : @(effects.count);
                if (fx[@"effectStackHandle"]) local[@"effectStackHandle"] = fx[@"effectStackHandle"];
                if (fx[@"error"]) local[@"effectsError"] = fx[@"error"];
            }

            // Title text (kind was decided above).
            NSArray *channels = SpliceKit_clipInfoTitleText(item);
            if (channels.count > 0) {
                NSMutableDictionary *title = [NSMutableDictionary dictionary];
                NSDictionary *first = channels.firstObject;
                for (NSString *key in @[@"text", @"fontName", @"fontFamily", @"fontSize", @"textColor"]) {
                    if (first[key]) title[key] = first[key];
                }
                title[@"channels"] = channels;
                title[@"channelCount"] = @(channels.count);
                local[@"title"] = title;
                if ([kind isEqualToString:@"generator"]) kind = @"title";
            }
            local[@"kind"] = kind;

            // Markers placed within this clip (anchored to it in the model).
            if (includeMarkers) {
                NSMutableArray *markers = [NSMutableArray array];
                @try {
                    SEL anchoredSel = NSSelectorFromString(@"anchoredItems");
                    if ([item respondsToSelector:anchoredSel]) {
                        NSArray *anchored = SpliceKit_mixerArrayFromContainer(
                            ((id (*)(id, SEL))objc_msgSend)(item, anchoredSel));
                        for (id child in anchored) {
                            if (!SpliceKit_isMarkerLikeItem(child)) continue;
                            [markers addObject:SpliceKit_describeMarker(child, primaryObj, handle,
                                                                        haveRange, clipStartSeconds)];
                        }
                    }
                } @catch (NSException *e) {}
                local[@"markers"] = markers;
                local[@"markerCount"] = @(markers.count);
            }

            // Transcript words inside the clip (SpliceKit's Text-Based Editor).
            if (includeTranscript && haveRange) {
                local[@"transcript"] = SpliceKit_clipInfoTranscriptWords(clipStartSeconds, clipEndSeconds, handle);
            } else if (includeTranscript) {
                local[@"transcript"] = @{@"available": @NO, @"status": @"unknown", @"wordCount": @0,
                                        @"matchedByHandle": @0, @"words": @[], @"text": @"", @"truncated": @NO,
                                        @"error": @"clip timeline range unknown; cannot select the words inside it"};
            }
            info = local;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason], @"handle": handle};
        }
    });
    if (result) return result;
    if (!info) return @{@"error": @"Failed to read clip info (main thread did not finish in time)", @"handle": handle};

    double mainThreadMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0;
    double frameMs = 0.0;

    // Frame from the source media file. AVFoundation work happens here, on the
    // calling thread, so decoding never blocks FCP's main thread (the
    // executeOnMainThread watchdog is 20 s). Any failure becomes `frameError`;
    // the rest of the clip information is returned regardless.
    if (includeFrame && !haveRange) {
        info[@"frameError"] = @"clip timeline range unknown; cannot map a timeline time to the source media file";
    } else if (includeFrame) {
        double frameStartedAt = CFAbsoluteTimeGetCurrent();
        BOOL clamped = NO;
        double timelineTime = SpliceKit_clipInfoFrameTime(clipStartSeconds, clipEndSeconds,
                                                          haveFrameTime, frameTimeParam, &clamped);
        double sourceTime = sourceStartSeconds + (timelineTime - clipStartSeconds);
        double fileTime = sourceStartKnown ? (sourceTime - mediaOriginSeconds) : (timelineTime - clipStartSeconds);
        NSMutableDictionary *request = [NSMutableDictionary dictionary];
        request[@"timelineTime"] = @(timelineTime);
        request[@"sourceTime"] = @(sourceTime);
        request[@"mediaOrigin"] = @(mediaOriginSeconds);
        request[@"sourceStartKnown"] = @(sourceStartKnown);
        request[@"fileTime"] = @(fileTime);
        if (clamped) request[@"frameTimeClamped"] = @YES;

        if (!frameURL) {
            info[@"frameError"] = noSingleSourceFrameOut
                ?: @"no source media file to read a frame from (title, generator or gap clip); use timeline.captureClipFrame for the Viewer";
            info[@"frameRequest"] = request;
        } else {
            NSString *frameError = nil;
            NSMutableDictionary *frame = [NSMutableDictionary dictionary];
            @try {
                // AVAsset never returns nil for a missing file; it just has no
                // tracks. Check the file first so a missing file is reported as
                // what FCP shows (Missing File), not as an audio-only clip.
                AVAsset *asset = sourceExists ? [AVAsset assetWithURL:frameURL] : nil;
                double assetDuration = 0.0;
                if (asset) {
                    CMTime d = asset.duration;
                    if ((d.flags & kCMTimeFlags_Valid) && d.timescale > 0) assetDuration = CMTimeGetSeconds(d);
                }
                if (assetDuration > 0.0) request[@"assetDuration"] = @(assetDuration);
                if (!sourceExists) {
                    frameError = [NSString stringWithFormat:@"the source media file is missing on disk (FCP: Missing File): %@",
                                  frameURL.path ?: frameURL.absoluteString ?: @""];
                } else if (!asset) {
                    frameError = @"AVAsset could not open the source media file";
                } else if ([asset tracksWithMediaType:AVMediaTypeVideo].count == 0) {
                    frameError = @"no video track could be read from the source media file (an audio-only clip, or a file AVFoundation cannot open)";
                } else {
                    if (assetDuration > 0.0) {
                        fileTime = MIN(MAX(fileTime, 0.0), MAX(0.0, assetDuration - 0.001));
                    } else if (fileTime < 0.0) {
                        fileTime = 0.0;
                    }
                    request[@"fileTime"] = @(fileTime);
                    AVAssetImageGenerator *gen = [[AVAssetImageGenerator alloc] initWithAsset:asset];
                    gen.appliesPreferredTrackTransform = YES;
                    gen.maximumSize = CGSizeMake(frameMaxWidth, frameMaxWidth);
                    gen.requestedTimeToleranceBefore = CMTimeMakeWithSeconds(0.25, 600);
                    gen.requestedTimeToleranceAfter = CMTimeMakeWithSeconds(0.25, 600);
                    NSError *imgErr = nil;
                    CMTime actual = kCMTimeInvalid;
                    CGImageRef img = [gen copyCGImageAtTime:CMTimeMakeWithSeconds(fileTime, 600)
                                                 actualTime:&actual error:&imgErr];
                    if (!img) {
                        frameError = [NSString stringWithFormat:@"copyCGImageAtTime failed at file time %.3fs: %@",
                                      fileTime, imgErr.localizedDescription ?: @"unknown error"];
                    } else {
                        int width = 0, height = 0;
                        NSData *jpeg = SpliceKit_clipInfoJPEGFromCGImage(img, frameMaxWidth, &width, &height);
                        CGImageRelease(img);
                        if (!jpeg) {
                            frameError = @"JPEG encoding of the decoded frame failed";
                        } else {
                            frame[@"format"] = @"jpeg";
                            frame[@"width"] = @(width);
                            frame[@"height"] = @(height);
                            frame[@"base64"] = [jpeg base64EncodedStringWithOptions:0];
                            frame[@"bytes"] = @(jpeg.length);
                            frame[@"timelineTime"] = @(timelineTime);
                            frame[@"sourceTime"] = @(sourceTime);
                            frame[@"mediaOrigin"] = @(mediaOriginSeconds);
                            frame[@"fileTime"] = @(fileTime);
                            if ((actual.flags & kCMTimeFlags_Valid) && actual.timescale > 0) {
                                frame[@"actualFileTime"] = @(CMTimeGetSeconds(actual));
                            }
                            frame[@"source"] = @"media file";
                            frame[@"maxWidth"] = @(frameMaxWidth);
                            if (clamped) frame[@"frameTimeClamped"] = @YES;
                        }
                    }
                }
            } @catch (NSException *e) {
                frameError = [NSString stringWithFormat:@"Exception: %@", e.reason];
            }
            if (frameError) {
                info[@"frameError"] = frameError;
                info[@"frameRequest"] = request;
            } else {
                info[@"frame"] = frame;
            }
        }
        frameMs = (CFAbsoluteTimeGetCurrent() - frameStartedAt) * 1000.0;
    }

    info[@"timings"] = @{@"mainThreadMs": @(mainThreadMs), @"frameMs": @(frameMs)};
    return info;
}

// timeline.captureClipFrame -- the clip as rendered in the Viewer (effects included).
// CHANGES STATE and restores it: moves the playhead to the frame time, lets FCP
// render (at most 0.35 s of run loop), captures the Viewer, then moves it back.
// During that render wait the main run loop is spinning, so a request from
// ANOTHER bridge client (Lua REPL, a second MCP process) can run while the
// playhead sits at the clip; and if FCP is playing, playback continues, so
// playheadAtCapture is reported for the caller to compare with timelineTime.
//   params: handle (required), frameTime (default midpoint), frameMaxWidth (960, 64..1920),
//           path (PNG; default /tmp/splicekit_clip_<handle>.png), restorePlayhead (YES)
// Where a symlink ultimately points (following up to 8 links with readlink only), or
// nil when path is not a symlink.
static NSString *SpliceKit_symlinkTarget(NSString *path) {
    if (path.length == 0) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *current = path;
    BOOL followed = NO;
    for (int hop = 0; hop < 8; hop++) {
        NSString *dest = [fm destinationOfSymbolicLinkAtPath:current error:nil];
        if (!dest) break;
        if (![dest isAbsolutePath]) {
            dest = [[current stringByDeletingLastPathComponent] stringByAppendingPathComponent:dest];
        }
        current = [dest stringByStandardizingPath];
        followed = YES;
    }
    return followed ? current : nil;
}

// A 64x36 grayscale thumbprint of a PNG on disk, for telling two Viewer captures
// apart. nil when the file cannot be read.
static NSData *SpliceKit_viewerThumbprint(NSString *pngPath) {
    NSData *png = [NSData dataWithContentsOfFile:pngPath];
    NSBitmapImageRep *rep = png.length ? [NSBitmapImageRep imageRepWithData:png] : nil;
    CGImageRef image = rep.CGImage;
    if (!image) return nil;
    const size_t w = 64, h = 36;
    NSMutableData *pixels = [NSMutableData dataWithLength:w * h];
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(pixels.mutableBytes, w, h, 8, w, gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    if (!ctx) return nil;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
    CGContextRelease(ctx);
    return pixels;
}

// Mean absolute difference of two thumbprints, 0-255; -1 when they cannot be compared.
static double SpliceKit_thumbprintDistance(NSData *a, NSData *b) {
    if (!a || !b || a.length != b.length || a.length == 0) return -1;
    const uint8_t *pa = a.bytes, *pb = b.bytes;
    double sum = 0;
    for (NSUInteger i = 0; i < a.length; i++) sum += abs((int)pa[i] - (int)pb[i]);
    return sum / a.length;
}

NSDictionary *SpliceKit_handleTimelineCaptureClipFrame(NSDictionary *params) {
    NSString *handle = [params[@"handle"] isKindOfClass:[NSString class]] ? params[@"handle"] : nil;
    if (handle.length == 0) {
        return @{@"error": @"handle parameter required (a clip handle from timeline.getDetailedState)"};
    }
    BOOL haveFrameTime = [params[@"frameTime"] isKindOfClass:[NSNumber class]];
    double frameTimeParam = haveFrameTime ? [params[@"frameTime"] doubleValue] : 0.0;
    int frameMaxWidth = [params[@"frameMaxWidth"] isKindOfClass:[NSNumber class]]
        ? [params[@"frameMaxWidth"] intValue] : 960;
    if (frameMaxWidth < 64) frameMaxWidth = 64;
    if (frameMaxWidth > 1920) frameMaxWidth = 1920;
    NSString *path = ([params[@"path"] isKindOfClass:[NSString class]] && [params[@"path"] length] > 0)
        ? params[@"path"] : [NSString stringWithFormat:@"/tmp/splicekit_clip_%@.png", handle];
    BOOL restorePlayhead = SpliceKit_clipInfoBoolParam(params, @"restorePlayhead", YES);

    __block NSDictionary *result = nil;
    __block NSMutableDictionary *out = nil;
    // The render wait below runs inside this block, so the main-thread wait has to
    // cover it: renderTimeout (capped at 15 s) plus the captures and seeks around it.
    // With the fixed 20 s wait, a 25 s renderTimeout always came back as a timeout.
    double renderTimeoutParam = [params[@"renderTimeout"] isKindOfClass:[NSNumber class]]
        ? MAX(0.35, MIN(15.0, [params[@"renderTimeout"] doubleValue])) : 5.0;
    SpliceKit_executeOnMainThreadWithTimeout(^{
        // Tracked outside the @try so an exception after the seek still puts the
        // playhead back and the error reply says where it was.
        BOOL movedPlayhead = NO;
        BOOL havePlayhead = NO;
        double playheadBefore = 0.0;
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) { result = @{@"error": @"No active timeline module"}; return; }

            id sequence = [timeline respondsToSelector:@selector(sequence)]
                ? ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence)) : nil;
            if (!sequence) { result = @{@"error": @"No sequence in timeline"}; return; }

            id primaryObj = [sequence respondsToSelector:@selector(primaryObject)]
                ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject)) : nil;
            if (!primaryObj) { result = @{@"error": @"Cannot access primary storyline"}; return; }

            CMTimeRange range = {{0, 0, 0, 0}, {0, 0, 0, 0}};
            NSString *resolveError = nil;
            id item = SpliceKit_handleResolveTimelineClip(handle, primaryObj, &range, &resolveError);
            if (!item) {
                if ([resolveError hasPrefix:@"markers are not clips"]) {
                    resolveError = @"a marker is not a clip (markers are placed within clips); use list_markers or the marker actions";
                }
                result = @{@"error": resolveError ?: @"clip is not in the active sequence", @"handle": handle};
                return;
            }
            if (range.start.timescale <= 0 || range.duration.timescale <= 0) {
                result = @{@"error": @"the clip's timeline range could not be determined (nested connected clip); seek there yourself and use viewer.capture",
                           @"handle": handle};
                return;
            }

            double clipStart = SpliceKit_secondsFromTime(range.start);
            double clipEnd = clipStart + SpliceKit_secondsFromTime(range.duration);
            BOOL clamped = NO;
            double timelineTime = SpliceKit_clipInfoFrameTime(clipStart, clipEnd, haveFrameTime,
                                                              frameTimeParam, &clamped);

            // Half a frame is the restore tolerance (setPlayheadTime: truncates to a frame unit).
            CMTime frameDuration = {100, 3000, 1, 0};
            CMTime fd = SpliceKit_sequenceFrameDuration(sequence);
            if (fd.timescale > 0 && fd.value > 0) frameDuration = fd;
            double halfFrame = MAX(0.001, SpliceKit_secondsFromTime(frameDuration)) / 2.0;

            // Built locally and published to `out` only at an exit, so a 20 s
            // watchdog timeout can never expose a dictionary still being filled.
            // A failed capture is reported with status "failed" + `failure`
            // (not `error`: the dispatcher collapses any `error` reply to
            // {code, message} and would drop the playhead diagnostics).
            NSMutableDictionary *local = [NSMutableDictionary dictionary];
            local[@"handle"] = handle;
            local[@"name"] = SpliceKit_displayNameForItem(item) ?: @"";
            local[@"class"] = NSStringFromClass([item class]) ?: @"";
            local[@"timelineTime"] = @(timelineTime);
            if (clamped) local[@"frameTimeClamped"] = @YES;
            local[@"path"] = path;
            local[@"restorePlayhead"] = @(restorePlayhead);

            NSDictionary *before = SpliceKit_handlePlaybackGetPosition(@{});
            havePlayhead = [before[@"seconds"] isKindOfClass:[NSNumber class]];
            playheadBefore = havePlayhead ? [before[@"seconds"] doubleValue] : 0.0;
            if (havePlayhead) local[@"playheadBefore"] = @(playheadBefore);

            // What the Viewer shows before the seek, to tell a fresh frame from the
            // old one. A fixed 0.35 s wait was too short for 60 fps / non-16:9 media
            // with a Fill conform: three captures in a row came back as the frame the
            // playhead had left, and nothing said so.
            BOOL sameFrame = havePlayhead && fabs(playheadBefore - timelineTime) < halfFrame;
            NSString *beforePath = [path stringByAppendingString:@".before.png"];
            NSData *beforePrint = nil;
            if (!sameFrame) {
                // The reference must be what the Viewer settles on at the current
                // playhead, not a frame it is still leaving: straight after a seek the
                // Viewer can still show the previous position, and taking that as the
                // reference made a correct capture of that same earlier frame read as
                // stale. Capture until two in a row match (at most ~1 s).
                NSData *previousPrint = nil;
                for (int attempt = 0; attempt < 6; attempt++) {
                    NSDictionary *beforeCapture = SpliceKit_handleCaptureViewer(@{@"path": beforePath});
                    if (!beforeCapture || beforeCapture[@"error"]) { beforePrint = nil; break; }
                    beforePrint = SpliceKit_viewerThumbprint(beforePath);
                    if (previousPrint) {
                        double d = SpliceKit_thumbprintDistance(beforePrint, previousPrint);
                        if (d >= 0 && d <= 1.0) break;
                    }
                    previousPrint = beforePrint;
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
                }
                [[NSFileManager defaultManager] removeItemAtPath:beforePath error:nil];
            }

            NSDictionary *seek = SpliceKit_handlePlaybackSeek(@{@"seconds": @(timelineTime)});
            if (!seek || seek[@"error"]) {
                local[@"status"] = @"failed";
                local[@"failure"] = [seek[@"error"] isKindOfClass:[NSString class]] ? seek[@"error"] : @"seek failed";
                local[@"playheadRestored"] = @YES;   // nothing moved
                out = local;
                return;
            }
            movedPlayhead = YES;
            // Let the Viewer render the new frame before the capture (shipped code
            // spins the run loop the same way after a model change), then keep
            // capturing until the image has moved off the pre-seek frame and holds
            // still across two captures, for up to renderTimeout seconds (default 5).
            double renderTimeout = renderTimeoutParam;
            NSDate *renderStart = [NSDate date];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.35]];

            NSDictionary *capture = SpliceKit_handleCaptureViewer(@{@"path": path});
            if (beforePrint && capture && !capture[@"error"]) {
                const double changedAt = 1.0;   // mean grey-level difference that counts as a new picture
                NSData *print = SpliceKit_viewerThumbprint(path);
                NSData *previous = nil;
                BOOL changed = SpliceKit_thumbprintDistance(print, beforePrint) > changedAt;
                BOOL settled = NO;
                while (-[renderStart timeIntervalSinceNow] < renderTimeout) {
                    if (changed && previous && SpliceKit_thumbprintDistance(print, previous) <= changedAt) {
                        settled = YES;
                        break;
                    }
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
                    NSDictionary *again = SpliceKit_handleCaptureViewer(@{@"path": path});
                    if (!again || again[@"error"]) break;
                    capture = again;
                    previous = print;
                    print = SpliceKit_viewerThumbprint(path);
                    if (!changed) changed = SpliceKit_thumbprintDistance(print, beforePrint) > changedAt;
                }
                local[@"renderWaitSeconds"] = @(round(-[renderStart timeIntervalSinceNow] * 100) / 100);
                if (!print) {
                    // An unreadable capture says nothing about the Viewer; no verdict.
                    local[@"staleCheck"] = @"skipped: the capture could not be read back for comparison";
                } else {
                    local[@"changedFromBefore"] = @(changed);
                }
                if (print && !changed) {
                    local[@"stale"] = @YES;
                    local[@"staleWarning"] = [NSString stringWithFormat:
                        @"the Viewer still showed the frame from before the seek (%.3fs) after %.1f s: this "
                        @"capture is probably stale, not the clip. Retry with a longer renderTimeout, or "
                        @"both frames really look alike.", playheadBefore, renderTimeout];
                } else if (!settled) {
                    local[@"renderStillChanging"] = @YES;
                }
            }
            NSDictionary *atCapture = SpliceKit_handlePlaybackGetPosition(@{});
            if ([atCapture[@"seconds"] isKindOfClass:[NSNumber class]]) {
                local[@"playheadAtCapture"] = atCapture[@"seconds"];
            }

            if (restorePlayhead && havePlayhead) {
                SpliceKit_handlePlaybackSeek(@{@"seconds": @(playheadBefore)});
                NSDictionary *after = SpliceKit_handlePlaybackGetPosition(@{});
                double playheadAfter = [after[@"seconds"] isKindOfClass:[NSNumber class]]
                    ? [after[@"seconds"] doubleValue] : playheadBefore;
                local[@"playheadAfter"] = @(playheadAfter);
                local[@"playheadRestored"] = (fabs(playheadAfter - playheadBefore) < halfFrame) ? @YES : @NO;
            } else {
                local[@"playheadRestored"] = @NO;
            }

            if (!capture || capture[@"error"]) {
                local[@"status"] = @"failed";
                local[@"failure"] = [capture[@"error"] isKindOfClass:[NSString class]]
                    ? capture[@"error"] : @"viewer capture failed";
                out = local;
                return;
            }
            NSMutableDictionary *captureInfo = [NSMutableDictionary dictionary];
            for (NSString *key in @[@"width", @"height", @"bytes", @"cropped", @"flat", @"flatColor", @"warning"]) {
                if (capture[key]) captureInfo[key] = capture[key];
            }
            local[@"capture"] = captureInfo;
            // A one-colour Viewer image is not a verified frame (QA run 4: screen locked).
            if ([capture[@"flat"] boolValue]) {
                local[@"flat"] = @YES;
                if (capture[@"warning"]) local[@"warning"] = capture[@"warning"];
            }
            local[@"status"] = @"ok";
            out = local;
        } @catch (NSException *e) {
            // Reported as status "failed" (see above) so the playhead diagnostics survive.
            NSMutableDictionary *err = [NSMutableDictionary dictionary];
            err[@"status"] = @"failed";
            err[@"failure"] = [NSString stringWithFormat:@"Exception: %@", e.reason];
            err[@"handle"] = handle;
            err[@"path"] = path;
            if (movedPlayhead) {
                BOOL restored = NO;
                if (havePlayhead) {
                    err[@"playheadBefore"] = @(playheadBefore);
                    if (restorePlayhead) {
                        @try {
                            SpliceKit_handlePlaybackSeek(@{@"seconds": @(playheadBefore)});
                            NSDictionary *after = SpliceKit_handlePlaybackGetPosition(@{});
                            if ([after[@"seconds"] isKindOfClass:[NSNumber class]]) {
                                double playheadAfter = [after[@"seconds"] doubleValue];
                                err[@"playheadAfter"] = @(playheadAfter);
                                restored = fabs(playheadAfter - playheadBefore) < 0.05;
                            }
                        } @catch (NSException *e2) {}
                    }
                }
                err[@"playheadRestored"] = restored ? @YES : @NO;
            } else {
                err[@"playheadRestored"] = @YES;   // nothing moved
            }
            out = err;
        }
    }, renderTimeoutParam + 15.0, YES);
    if (result) return result;
    if (!out) return @{@"error": @"Failed to capture clip frame (main thread did not finish in time)", @"handle": handle};
    if (![out[@"status"] isEqualToString:@"ok"]) return out;

    // Off the main thread: load the PNG the Viewer capture wrote, downscale, JPEG, base64.
    @try {
        NSData *png = [NSData dataWithContentsOfFile:path];
        NSBitmapImageRep *rep = (png.length > 0) ? [NSBitmapImageRep imageRepWithData:png] : nil;
        CGImageRef cgImage = rep ? rep.CGImage : NULL;   // owned by the rep; not released here
        if (!cgImage) {
            out[@"status"] = @"failed";
            out[@"failure"] = [NSString stringWithFormat:@"could not read the captured PNG at %@", path];
            return out;
        }
        int width = 0, height = 0;
        NSData *jpeg = SpliceKit_clipInfoJPEGFromCGImage(cgImage, frameMaxWidth, &width, &height);
        if (!jpeg) {
            out[@"status"] = @"failed";
            out[@"failure"] = @"JPEG encoding of the captured frame failed";
            return out;
        }
        out[@"frame"] = @{
            @"format": @"jpeg",
            @"width": @(width),
            @"height": @(height),
            @"base64": [jpeg base64EncodedStringWithOptions:0],
            @"bytes": @(jpeg.length),
            @"source": @"viewer",
            @"maxWidth": @(frameMaxWidth),
        };
    } @catch (NSException *e) {
        out[@"status"] = @"failed";
        out[@"failure"] = [NSString stringWithFormat:@"Exception: %@", e.reason];
    }
    return out;
}

// Batch timeline/playback actions executed server-side (no per-action round-trip)
NSDictionary *SpliceKit_handleBatchActions(NSDictionary *params) {
    NSArray *actions = params[@"actions"];
    if (!actions || ![actions isKindOfClass:[NSArray class]] || actions.count == 0) {
        return @{@"error": @"actions array required"};
    }

    NSString *paramName = params[@"name"];
    NSString *batchUndoName = ([paramName isKindOfClass:[NSString class]] && paramName.length > 0)
        ? paramName : @"Batch Actions";

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        id timeline = nil;
        id sequence = nil;
        BOOL openedUndoGroup = NO;
        @try {
            timeline = SpliceKit_getActiveTimelineModule();
            if (timeline) {
                sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
                openedUndoGroup = SpliceKit_internalBeginEditGroupIfNeeded(sequence, batchUndoName);
            }

            NSMutableArray *results = [NSMutableArray array];
            NSUInteger executed = 0;

            @try {
            for (NSDictionary *act in actions) {
                NSString *type = act[@"type"] ?: @"timeline";
                NSString *actionName = act[@"action"] ?: @"";
                NSInteger repeat = [act[@"repeat"] integerValue];
                if (repeat < 1) repeat = 1;

                if ([type isEqualToString:@"wait"]) {
                    double secs = [act[@"seconds"] doubleValue];
                    if (secs <= 0) secs = 0.5;
                    [NSThread sleepForTimeInterval:secs];
                    [results addObject:[NSString stringWithFormat:@"wait %.2fs", secs]];
                } else if ([type isEqualToString:@"playback"]) {
                    for (NSInteger i = 0; i < repeat; i++) {
                        SpliceKit_handlePlayback(@{@"action": actionName});
                    }
                    [results addObject:[NSString stringWithFormat:@"playback.%@%@",
                        actionName, repeat > 1 ? [NSString stringWithFormat:@" x%ld", (long)repeat] : @""]];
                } else if ([type isEqualToString:@"timeline"]) {
                    for (NSInteger i = 0; i < repeat; i++) {
                        SpliceKit_handleTimelineAction(@{@"action": actionName});
                    }
                    [results addObject:[NSString stringWithFormat:@"timeline.%@%@",
                        actionName, repeat > 1 ? [NSString stringWithFormat:@" x%ld", (long)repeat] : @""]];
                } else if ([type isEqualToString:@"seek"]) {
                    double secs = [act[@"seconds"] doubleValue];
                    SpliceKit_handlePlaybackSeek(@{@"seconds": @(secs)});
                    [results addObject:[NSString stringWithFormat:@"seek %.2fs", secs]];
                } else {
                    [results addObject:[NSString stringWithFormat:@"unknown type: %@", type]];
                    continue;
                }
                executed++;
            }
            } @finally {
                if (openedUndoGroup) {
                    SpliceKit_internalEndEditGroupIfOpened(sequence, timeline, batchUndoName, YES);
                }
            }

            result = @{
                @"status": @"ok",
                @"executed": @(executed),
                @"results": results,
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to execute batch actions"};
}

NSDictionary *SpliceKit_handleSetRange(NSDictionary *params) {
    NSNumber *startSec = params[@"startSeconds"];
    NSNumber *endSec = params[@"endSeconds"];
    if (!startSec || !endSec) {
        return @{@"error": @"startSeconds and endSeconds parameters required"};
    }

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) {
                result = @{@"error": @"No active timeline module"};
                return;
            }

            double startVal = [startSec doubleValue];
            double endVal = [endSec doubleValue];

            // Build CMTimes
            CMTime startTime = SpliceKit_buildCMTime(startVal, timeline);
            CMTime endTime = SpliceKit_buildCMTime(endVal, timeline);

            // Seek to start, mark in
            BOOL inOk = SpliceKit_seekAndMark(timeline, startTime, @"setRangeStart:");
            // Seek to end, mark out
            BOOL outOk = SpliceKit_seekAndMark(timeline, endTime, @"setRangeEnd:");

            if (!inOk || !outOk) {
                NSMutableString *detail = [NSMutableString stringWithFormat:
                    @"Failed to set timeline range %.3fs–%.3fs (mark in: %@, mark out: %@).",
                    startVal, endVal, inOk ? @"ok" : @"failed", outOk ? @"ok" : @"failed"];
                if (!inOk && !outOk &&
                    ![timeline respondsToSelector:NSSelectorFromString(@"setRangeStart:")] &&
                    ![timeline respondsToSelector:NSSelectorFromString(@"setRangeEnd:")]) {
                    [detail appendString:
                        @" FFAnchoredTimelineModule does not implement setRangeStart:/setRangeEnd:."];
                } else if (!inOk || !outOk) {
                    [detail appendString:
                        @" Range marks use setRangeStart:/setRangeEnd: on the timeline module; "
                        @"if playhead moved but marks did not stick, try bringing Final Cut Pro frontmost."];
                }
                result = @{
                    @"error": detail,
                    @"startSeconds": @(startVal),
                    @"endSeconds": @(endVal),
                    @"rangeStartSet": @(inOk),
                    @"rangeEndSet": @(outOk),
                };
                return;
            }

            result = @{
                @"status": @"ok",
                @"startSeconds": @(startVal),
                @"endSeconds": @(endVal),
                @"rangeStartSet": @(inOk),
                @"rangeEndSet": @(outOk),
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to set range"};
}

// Helper: collect exportable clips with their time ranges (no ARC-managed ObjC objects in the mix)
static NSArray *SpliceKit_collectExportableClips(id primaryObj, NSSet *selectedSet) {
    SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");
    if (![primaryObj respondsToSelector:erSel]) return nil;

    NSArray *allItems = ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems));
    if (![allItems isKindOfClass:[NSArray class]]) return nil;

    Class transitionClass = objc_getClass("FFAnchoredTransition");
    NSMutableArray *clips = [NSMutableArray array];

    for (id item in allItems) {
        if (transitionClass && [item isKindOfClass:transitionClass]) continue;
        NSString *className = NSStringFromClass([item class]);
        if ([className containsString:@"Gap"]) continue;
        if (selectedSet && ![selectedSet containsObject:item]) continue;

        @try {
            CMTimeRange range = ((CMTimeRange (*)(id, SEL, id))STRET_MSG)(
                primaryObj, erSel, item);
            NSString *name = @"Untitled";
            if ([item respondsToSelector:@selector(displayName)]) {
                id n = ((id (*)(id, SEL))objc_msgSend)(item, @selector(displayName));
                if (n) name = n;
            }
            CMTime endTime = SpliceKit_endTimeForRange(range);
            [clips addObject:@{
                @"name": name,
                @"startTime": SpliceKit_serializeCMTime(range.start),
                @"endTime": SpliceKit_serializeCMTime(endTime),
                @"startCMTime": [NSValue valueWithBytes:&range.start objCType:@encode(CMTime)],
                @"endCMTime": [NSValue valueWithBytes:&endTime objCType:@encode(CMTime)],
            }];
        } @catch (NSException *e) { /* skip */ }
    }
    return clips;
}

// --- Batch Export: swizzle approach ---
// We swizzle FFSequenceExporter's showSharePanelWithSources:... to skip the modal dialog
// and directly queue the export. The original method creates a share panel, runs it modally,
// then queues batches. Our replacement creates the panel silently, extracts batches, and queues.

static NSURL *sBatchExportFolderURL = nil;
static NSString *sBatchExportFileName = nil;
static BOOL sBatchExportActive = NO;
static IMP sOrigShowSharePanel = NULL;
static NSInteger sBatchExportPendingCount = 0; // tracks async exports still running
static CMTime sBatchExportClipStart;
static CMTime sBatchExportClipEnd;

// Swizzle NSWorkspace openURL: to suppress auto-open of exported files
static IMP sOrigOpenURL = NULL;
static BOOL SpliceKit_swizzled_openURL(id self, SEL _cmd, id url) {
    if (sBatchExportPendingCount > 0 && url && [url isKindOfClass:[NSURL class]]) {
        // Suppress opening files from the batch export folder
        NSString *path = [(NSURL *)url path];
        NSString *folderPath = [sBatchExportFolderURL path];
        if (folderPath && [path hasPrefix:folderPath]) {
            SpliceKit_log(@"[BatchExport] Suppressed auto-open: %@", path);
            sBatchExportPendingCount--;
            return YES; // pretend we opened it
        }
    }
    // Call original
    return sOrigOpenURL ? ((BOOL (*)(id, SEL, id))sOrigOpenURL)(self, _cmd, url) : NO;
}

// Also suppress activateFileViewerSelectingURLs: (Reveal in Finder)
static IMP sOrigRevealURLs = NULL;
static void SpliceKit_swizzled_revealURLs(id self, SEL _cmd, id urls) {
    if (sBatchExportPendingCount > 0 && urls) {
        SpliceKit_log(@"[BatchExport] Suppressed reveal in Finder");
        return;
    }
    if (sOrigRevealURLs) ((void (*)(id, SEL, id))sOrigRevealURLs)(self, _cmd, urls);
}

// Suppress openURL:configuration:completionHandler: (modern API)
static IMP sOrigOpenURLConfig = NULL;
static void SpliceKit_swizzled_openURLConfig(id self, SEL _cmd, id url, id config, id handler) {
    if (sBatchExportPendingCount > 0 && url && [url isKindOfClass:[NSURL class]]) {
        NSString *path = [(NSURL *)url path];
        NSString *folderPath = [sBatchExportFolderURL path];
        if (folderPath && [path hasPrefix:folderPath]) {
            SpliceKit_log(@"[BatchExport] Suppressed openURL:config: %@", path);
            sBatchExportPendingCount--;
            if (handler) ((void (^)(id, id))handler)(nil, nil);
            return;
        }
    }
    if (sOrigOpenURLConfig) ((void (*)(id, SEL, id, id, id))sOrigOpenURLConfig)(self, _cmd, url, config, handler);
}

// Suppress openURLs:withApplicationAtURL:configuration:completionHandler:
static IMP sOrigOpenURLs = NULL;
static void SpliceKit_swizzled_openURLs(id self, SEL _cmd, id urls, id appURL, id config, id handler) {
    if (sBatchExportPendingCount > 0 && urls) {
        SpliceKit_log(@"[BatchExport] Suppressed openURLs: batch");
        sBatchExportPendingCount--;
        if (handler) ((void (^)(id, id))handler)(nil, nil);
        return;
    }
    if (sOrigOpenURLs) ((void (*)(id, SEL, id, id, id, id))sOrigOpenURLs)(self, _cmd, urls, appURL, config, handler);
}

// Suppress openFile: (deprecated but still used)
static IMP sOrigOpenFile = NULL;
static BOOL SpliceKit_swizzled_openFile(id self, SEL _cmd, id path) {
    if (sBatchExportPendingCount > 0 && path) {
        NSString *folderPath = [sBatchExportFolderURL path];
        if (folderPath && [(NSString *)path hasPrefix:folderPath]) {
            sBatchExportPendingCount--;
            return YES;
        }
    }
    return sOrigOpenFile ? ((BOOL (*)(id, SEL, id))sOrigOpenFile)(self, _cmd, path) : NO;
}

// Replacement for -[FFSequenceExporter showSharePanelWithSources:destination:destinationURL:parentWindow:]
// Called after shareToDestination:parentWindow: has already converted sources to CK format
static void SpliceKit_swizzled_showSharePanel(id self, SEL _cmd, id sources, id dest, id destURL, id parentWindow) {
    if (!sBatchExportActive) {
        // Not in batch mode - call original
        if (sOrigShowSharePanel) {
            ((void (*)(id, SEL, id, id, id, id))sOrigShowSharePanel)(self, _cmd, sources, dest, destURL, parentWindow);
        }
        return;
    }

    SpliceKit_log(@"[BatchExport] Swizzled showSharePanel called with %@ sources, dest=%@",
        sources ? @([(NSArray *)sources count]) : @"nil", NSStringFromClass([dest class]));

    @try {
        // Determine panel class (consumer vs pro)
        BOOL isConsumer = ((BOOL (*)(id, SEL))objc_msgSend)(
            objc_getClass("Flexo"), NSSelectorFromString(@"isConsumerUI"));

        Class panelClass = isConsumer
            ? objc_getClass("FFConsumerSharePanel")
            : objc_getClass("FFSharePanel");
        if (!panelClass) panelClass = objc_getClass("FFBaseSharePanel");

        // Modify source to set clip-specific in/out range
        id firstSource = [(NSArray *)sources firstObject];
        id sourceToUse = firstSource;

        SEL mutableCopySel = @selector(mutableCopy);
        SEL setInOutSel = NSSelectorFromString(@"setInPoint:outPoint:");
        if (firstSource && [firstSource respondsToSelector:mutableCopySel] &&
            sBatchExportClipStart.flags == 1 && sBatchExportClipEnd.flags == 1) {
            // Create a mutable copy and set the clip's range as in/out points
            sourceToUse = ((id (*)(id, SEL))objc_msgSend)(firstSource, mutableCopySel);
            if (sourceToUse && [sourceToUse respondsToSelector:setInOutSel]) {
                // Convert our CMTime to NSValue objects that the source expects
                // The source's setInPoint:outPoint: takes CMTime-wrapping objects
                // Let's try creating PCTimeObject or similar
                SEL inPtSel = NSSelectorFromString(@"inPoint");
                id origIn = [firstSource respondsToSelector:inPtSel]
                    ? ((id (*)(id, SEL))objc_msgSend)(firstSource, inPtSel) : nil;
                SpliceKit_log(@"[BatchExport] Original inPoint: %@ (class: %@)",
                    origIn, origIn ? NSStringFromClass([origIn class]) : @"nil");

                // Try creating time objects from our CMTime values
                // PCTimeObject or similar wraps CMTime
                Class timeObjClass = objc_getClass("PCTimeObject");
                if (timeObjClass) {
                    SEL initWithTimeSel = NSSelectorFromString(@"timeObjectWithCMTime:");
                    if ([(id)timeObjClass respondsToSelector:initWithTimeSel]) {
                        id startObj = ((id (*)(id, SEL, CMTime))objc_msgSend)(
                            (id)timeObjClass, initWithTimeSel, sBatchExportClipStart);
                        id endObj = ((id (*)(id, SEL, CMTime))objc_msgSend)(
                            (id)timeObjClass, initWithTimeSel, sBatchExportClipEnd);
                        if (startObj && endObj) {
                            ((void (*)(id, SEL, id, id))objc_msgSend)(sourceToUse, setInOutSel, startObj, endObj);
                            SpliceKit_log(@"[BatchExport] Set in/out: %@ - %@", startObj, endObj);
                        }
                    }
                }
            }
        }

        // Create the panel silently (no runModal)
        id panel = nil;
        void *rawError = NULL;

        if (isConsumer) {
            SEL createSel = NSSelectorFromString(@"sharePanelWithSource:destination:error:");
            panel = ((id (*)(id, SEL, id, id, void **))objc_msgSend)(
                (id)panelClass, createSel, sourceToUse, dest, &rawError);
        } else {
            NSArray *modSources = @[sourceToUse];
            SEL createSel = NSSelectorFromString(@"sharePanelWithSources:destination:error:");
            panel = ((id (*)(id, SEL, id, id, void **))objc_msgSend)(
                (id)panelClass, createSel, modSources, dest, &rawError);
        }

        if (!panel) {
            id panelError = rawError ? (__bridge id)rawError : nil;
            SpliceKit_log(@"[BatchExport] Panel creation failed: %@",
                panelError ? ((id (*)(id, SEL))objc_msgSend)(panelError, @selector(localizedDescription)) : @"nil");
            return;
        }

        // Set destination URL to our batch export folder
        NSURL *outputFolderURL = sBatchExportFolderURL ?: (NSURL *)destURL;
        SEL setURLSel = NSSelectorFromString(@"setDestinationURL:");
        if ([panel respondsToSelector:setURLSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(panel, setURLSel, outputFolderURL);
        }

        // Set delegate (the exporter itself, needed for queuing)
        SEL setDelegateSel = NSSelectorFromString(@"setDelegate:");
        if ([panel respondsToSelector:setDelegateSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(panel, setDelegateSel, self);
        }

        // Get batches (created during panel init)
        NSArray *batches = ((id (*)(id, SEL))objc_msgSend)(panel, NSSelectorFromString(@"batches"));
        SpliceKit_log(@"[BatchExport] Panel created %lu batches", (unsigned long)(batches ? batches.count : 0));

        if (!batches || batches.count == 0) {
            SpliceKit_log(@"[BatchExport] No batches from panel");
            return;
        }

        // Set per-clip filename on targets if provided
        if (sBatchExportFileName && sBatchExportFolderURL) {
            NSURL *fileURL = [sBatchExportFolderURL URLByAppendingPathComponent:sBatchExportFileName];
            for (id batch in batches) {
                id jobs = ((id (*)(id, SEL))objc_msgSend)(batch, NSSelectorFromString(@"jobs"));
                if (!jobs || ![jobs isKindOfClass:[NSArray class]]) continue;
                for (id job in jobs) {
                    id targets = ((id (*)(id, SEL))objc_msgSend)(job, NSSelectorFromString(@"targets"));
                    if (!targets || ![targets isKindOfClass:[NSArray class]]) continue;
                    for (id target in targets) {
                        if ([target respondsToSelector:NSSelectorFromString(@"setDestinationURL:")]) {
                            ((void (*)(id, SEL, id))objc_msgSend)(target,
                                NSSelectorFromString(@"setDestinationURL:"), fileURL);
                        }
                    }
                }
            }
        }

        // Queue the export operations directly (no dialog!)
        SEL queueSel = NSSelectorFromString(@"queueShareOperationsForBatches:addToTheater:");
        if ([self respondsToSelector:queueSel]) {
            SpliceKit_log(@"[BatchExport] Queuing batches on %@", NSStringFromClass([self class]));
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(self, queueSel, batches, NO);
            SpliceKit_log(@"[BatchExport] Queued successfully!");
        } else {
            SpliceKit_log(@"[BatchExport] Exporter doesn't respond to queueShareOperationsForBatches:");
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[BatchExport] Exception in swizzled showSharePanel: %@", e.reason);
    }
}

NSDictionary *SpliceKit_handleBatchExport(NSDictionary *params) {
    NSString *scope = params[@"scope"] ?: @"all";
    NSString *folderPath = params[@"folder"];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) { result = @{@"error": @"No active timeline module"}; return; }

            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            if (!sequence) { result = @{@"error": @"No sequence in timeline"}; return; }

            id primaryObj = [sequence respondsToSelector:@selector(primaryObject)]
                ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject)) : nil;
            if (!primaryObj) { result = @{@"error": @"Cannot access primary storyline"}; return; }

            // `folder` is required over the bridge.
            //
            // This used to open an NSOpenPanel and call -runModal right here — inside the
            // bridge's own main-thread dispatch. That parks the main thread in a modal run
            // loop, so the bridge's 20-second watchdog gives up and abandons the work with
            // the panel still on screen and the export half-run. It is also the shape that
            // has crashed Final Cut Pro before: a modal run loop reached from a bridge call,
            // with an undo transaction open. And nothing could have answered the panel
            // anyway — a save/open panel cannot be confirmed over the bridge, only cancelled.
            if (folderPath.length == 0) {
                result = @{@"error": @"batch_export needs a `folder` to export into. The "
                                     @"folder picker can only be answered by a person at the "
                                     @"machine, and a save/open panel cannot be confirmed "
                                     @"over the bridge. Pass folder=\"/path/to/output\"."};
                return;
            }
            NSURL *folderURL = [NSURL fileURLWithPath:folderPath];
            if (!folderURL) { result = @{@"error": @"No folder selected"}; return; }
            [[NSFileManager defaultManager] createDirectoryAtURL:folderURL
                                     withIntermediateDirectories:YES attributes:nil error:nil];

            // Get selected set if needed
            NSSet *selectedSet = nil;
            if ([scope isEqualToString:@"selected"]) {
                SEL selSel = NSSelectorFromString(@"selectedItems:includeItemBeforePlayheadIfLast:");
                if ([timeline respondsToSelector:selSel]) {
                    id sel = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(timeline, selSel, NO, NO);
                    if ([sel isKindOfClass:[NSArray class]]) selectedSet = [NSSet setWithArray:sel];
                }
                if (!selectedSet || selectedSet.count == 0) {
                    result = @{@"error": @"No clips selected"}; return;
                }
            }

            // Get default share destination
            Class destClass = objc_getClass("FFShareDestination");
            id dest = destClass ? ((id (*)(id, SEL))objc_msgSend)((id)destClass,
                NSSelectorFromString(@"defaultUserDestination")) : nil;
            if (!dest) { result = @{@"error": @"No default share destination. Configure in File > Share > Add Destination."}; return; }

            // Collect clips
            NSArray *clips = SpliceKit_collectExportableClips(primaryObj, selectedSet);
            if (!clips || clips.count == 0) { result = @{@"error": @"No exportable clips"}; return; }

            // Install swizzle on FFSequenceExporter to bypass share dialog
            Class exporterClass = objc_getClass("FFSequenceExporter");
            SEL showPanelSel = NSSelectorFromString(@"showSharePanelWithSources:destination:destinationURL:parentWindow:");
            Method origMethod = exporterClass ? class_getInstanceMethod(exporterClass, showPanelSel) : NULL;

            if (!origMethod) {
                result = @{@"error": @"Cannot find showSharePanelWithSources: method on FFSequenceExporter"};
                return;
            }

            // Save original and install swizzle
            sOrigShowSharePanel = method_getImplementation(origMethod);
            method_setImplementation(origMethod, (IMP)SpliceKit_swizzled_showSharePanel);
            sBatchExportActive = YES;
            sBatchExportFolderURL = folderURL;
            sBatchExportPendingCount = clips.count;

            // Swizzle NSWorkspace methods to suppress auto-open of exported files
            Class wsClass = [NSWorkspace class];
            Method m;
            m = class_getInstanceMethod(wsClass, @selector(openURL:));
            if (m && !sOrigOpenURL) { sOrigOpenURL = method_getImplementation(m); method_setImplementation(m, (IMP)SpliceKit_swizzled_openURL); }

            m = class_getInstanceMethod(wsClass, @selector(activateFileViewerSelectingURLs:));
            if (m && !sOrigRevealURLs) { sOrigRevealURLs = method_getImplementation(m); method_setImplementation(m, (IMP)SpliceKit_swizzled_revealURLs); }

            m = class_getInstanceMethod(wsClass, NSSelectorFromString(@"openURL:configuration:completionHandler:"));
            if (m && !sOrigOpenURLConfig) { sOrigOpenURLConfig = method_getImplementation(m); method_setImplementation(m, (IMP)SpliceKit_swizzled_openURLConfig); }

            m = class_getInstanceMethod(wsClass, NSSelectorFromString(@"openURLs:withApplicationAtURL:configuration:completionHandler:"));
            if (m && !sOrigOpenURLs) { sOrigOpenURLs = method_getImplementation(m); method_setImplementation(m, (IMP)SpliceKit_swizzled_openURLs); }

            m = class_getInstanceMethod(wsClass, @selector(openFile:));
            if (m && !sOrigOpenFile) { sOrigOpenFile = method_getImplementation(m); method_setImplementation(m, (IMP)SpliceKit_swizzled_openFile); }

            // Set destination action to "Save only" (no auto-open)
            SEL actionSel = NSSelectorFromString(@"action");
            SEL setActionSel = NSSelectorFromString(@"setAction:");
            id origAction = nil;
            if ([dest respondsToSelector:actionSel]) {
                origAction = ((id (*)(id, SEL))objc_msgSend)(dest, actionSel);
            }
            if ([dest respondsToSelector:setActionSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(dest, setActionSel, nil); // nil = save only
            }

            // Get share helper
            id shareHelper = ((id (*)(id, SEL))objc_msgSend)(timeline, NSSelectorFromString(@"shareHelper"));
            SEL shareSel = NSSelectorFromString(@"_shareToDestination:isDefault:");

            NSMutableArray *exportResults = [NSMutableArray array];
            NSInteger exported = 0;

            // No undo group: mark in/out + share export are not timeline model edits; nothing meaningful registers on the undo stack.
            for (NSUInteger i = 0; i < clips.count; i++) {
                NSDictionary *clipInfo = clips[i];
                CMTime startCMTime, endCMTime;
                [clipInfo[@"startCMTime"] getValue:&startCMTime];
                [clipInfo[@"endCMTime"] getValue:&endCMTime];

                NSString *clipName = clipInfo[@"name"];
                NSString *safeName = [[clipName stringByReplacingOccurrencesOfString:@"/" withString:@"-"]
                                      stringByReplacingOccurrencesOfString:@":" withString:@"-"];
                // Use clip name directly; append index only if duplicate
                NSString *baseName = safeName;
                NSString *candidate = baseName;
                NSUInteger dupIdx = 2;
                while ([[NSFileManager defaultManager] fileExistsAtPath:
                        [[folderURL URLByAppendingPathComponent:
                          [candidate stringByAppendingPathExtension:@"mov"]] path]]) {
                    candidate = [NSString stringWithFormat:@"%@ %lu", baseName, (unsigned long)dupIdx++];
                }
                sBatchExportFileName = candidate;

                NSString *status = @"unknown";
                @try {
                    // Store clip range for the swizzled showSharePanel
                    sBatchExportClipStart = startCMTime;
                    sBatchExportClipEnd = endCMTime;

                    // Set in/out range using simulated I/O key presses
                    SpliceKit_seekAndMark(timeline, startCMTime, @"setRangeStart:");
                    SpliceKit_seekAndMark(timeline, endCMTime, @"setRangeEnd:");

                    // Trigger the normal share flow - our swizzle intercepts the dialog
                    if (shareHelper && [shareHelper respondsToSelector:shareSel]) {
                        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(shareHelper, shareSel, nil, YES);
                        status = @"queued";
                        exported++;
                    } else {
                        status = @"no share helper";
                    }
                } @catch (NSException *e) {
                    status = [NSString stringWithFormat:@"error: %@", e.reason];
                }

                // Let FCP process events between clips
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];

                [exportResults addObject:@{
                    @"name": clipName,
                    @"startTime": clipInfo[@"startTime"],
                    @"endTime": clipInfo[@"endTime"],
                    @"status": status,
                }];
            }

            // Restore showSharePanel swizzle
            if (origMethod && sOrigShowSharePanel) {
                method_setImplementation(origMethod, sOrigShowSharePanel);
            }
            sBatchExportActive = NO;
            sBatchExportFileName = nil;
            sBatchExportFolderURL = nil;
            sOrigShowSharePanel = NULL;

            // Restore original destination action
            if ([dest respondsToSelector:setActionSel] && origAction) {
                ((void (*)(id, SEL, id))objc_msgSend)(dest, setActionSel, origAction);
            }

            // Clear range
            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            ((BOOL (*)(id, SEL, SEL, id, id))objc_msgSend)(
                app, @selector(sendAction:to:from:),
                NSSelectorFromString(@"clearRange:"), nil, nil);

            result = @{
                @"status": @"ok",
                @"folder": [folderURL path] ?: @"",
                @"exported": @(exported),
                @"total": @(clips.count),
                @"clips": exportResults,
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to batch export"};
}

NSDictionary *SpliceKit_handleTimelineGetState(NSDictionary *params) {
    __block NSDictionary *result = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) {
                result = @{@"error": @"No active timeline module"};
                return;
            }

            NSMutableDictionary *state = [NSMutableDictionary dictionary];

            // Get sequence
            SEL seqSel = @selector(sequence);
            if ([timeline respondsToSelector:seqSel]) {
                id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel);
                if (sequence) {
                    state[@"sequence"] = [sequence description];
                    state[@"sequenceClass"] = NSStringFromClass([sequence class]);

                    // Get contained items count
                    SEL ciSel = @selector(containedItems);
                    if ([sequence respondsToSelector:ciSel]) {
                        id items = ((id (*)(id, SEL))objc_msgSend)(sequence, ciSel);
                        if ([items respondsToSelector:@selector(count)]) {
                            state[@"itemCount"] = @([(NSArray *)items count]);
                        }
                        // Describe each item
                        if ([items respondsToSelector:@selector(objectEnumerator)]) {
                            NSMutableArray *itemDescs = [NSMutableArray array];
                            for (id item in (NSArray *)items) {
                                NSMutableDictionary *desc = [NSMutableDictionary dictionary];
                                desc[@"class"] = NSStringFromClass([item class]);
                                desc[@"description"] = [item description];

                                // Try to get name
                                if ([item respondsToSelector:@selector(name)]) {
                                    id name = ((id (*)(id, SEL))objc_msgSend)(item, @selector(name));
                                    if (name) desc[@"name"] = name;
                                }
                                // Try to get mediaType
                                if ([item respondsToSelector:@selector(mediaType)]) {
                                    long long mt = ((long long (*)(id, SEL))objc_msgSend)(item, @selector(mediaType));
                                    desc[@"mediaType"] = @(mt);
                                }

                                [itemDescs addObject:desc];
                            }
                            state[@"items"] = itemDescs;
                        }
                    }

                    // Get hasContainedItems
                    if ([sequence respondsToSelector:@selector(hasContainedItems)]) {
                        BOOL has = ((BOOL (*)(id, SEL))objc_msgSend)(sequence, @selector(hasContainedItems));
                        state[@"hasItems"] = @(has);
                    }
                } else {
                    state[@"sequence"] = [NSNull null];
                }
            }

            // Get playhead time (CMTime struct - value/timescale/flags/epoch)
            SEL ptSel = @selector(playheadTime);
            if ([timeline respondsToSelector:ptSel]) {
                CMTime t = ((CMTime (*)(id, SEL))STRET_MSG)(timeline, ptSel);
                state[@"playheadTime"] = @{
                    @"value": @(t.value),
                    @"timescale": @(t.timescale),
                    @"seconds": (t.timescale > 0) ? @((double)t.value / t.timescale) : @(0)
                };
            }

            result = state;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result;
}
