//
//  SpliceKitURLImportMedia.m
//  Media inspection helpers for URL import: codec and frame-timing checks, the
//  normalization-mode rules and the ffprobe JSON reader.
//

#import "SpliceKitURLImport+Private.h"

static FourCharCode SpliceKitURLImportTrackCodecType(AVAssetTrack *track) {
    if (!track) return 0;
    NSArray *formatDescriptions = track.formatDescriptions;
    id firstDescription = formatDescriptions.firstObject;
    if (!firstDescription) return 0;
    return CMFormatDescriptionGetMediaSubType((CMFormatDescriptionRef)firstDescription);
}

FourCharCode SpliceKitURLImportVideoCodecType(AVAssetTrack *videoTrack) {
    return SpliceKitURLImportTrackCodecType(videoTrack);
}

FourCharCode SpliceKitURLImportAudioCodecType(AVAssetTrack *audioTrack) {
    return SpliceKitURLImportTrackCodecType(audioTrack);
}

NSString *SpliceKitURLImportFourCCString(FourCharCode code) {
    if (code == 0) return @"";
    char chars[5] = {
        (char)((code >> 24) & 0xFF),
        (char)((code >> 16) & 0xFF),
        (char)((code >> 8) & 0xFF),
        (char)(code & 0xFF),
        0
    };
    return [NSString stringWithUTF8String:chars] ?: @"";
}

BOOL SpliceKitURLImportCanonicalFrameTimingForRate(double fps,
                                                          int *outTimescale,
                                                          int *outFrameTicks) {
    if (!(fps > 0.0) || !isfinite(fps)) return NO;

    struct {
        double fps;
        int timescale;
        int frameTicks;
    } knownRates[] = {
        { 24000.0 / 1001.0, 24000, 1001 },
        { 24.0,             24000, 1000 },
        { 25.0,             25000, 1000 },
        { 30000.0 / 1001.0, 30000, 1001 },
        { 30.0,             30000, 1000 },
        { 50.0,             50000, 1000 },
        { 60000.0 / 1001.0, 60000, 1001 },
        { 60.0,             60000, 1000 },
    };

    // The nearest known rate, not the first one within tolerance: 30 and 29.97
    // (and 24 and 23.976) are both within 0.05 of each other, and taking the
    // first turned a true 30 fps WebM into 29.97, 0.1% slow against its audio.
    size_t nearest = SIZE_MAX;
    double nearestDistance = 0.05;
    for (size_t i = 0; i < sizeof(knownRates) / sizeof(knownRates[0]); ++i) {
        double distance = fabs(fps - knownRates[i].fps);
        if (distance <= nearestDistance) {
            nearest = i;
            nearestDistance = distance;
        }
    }
    if (nearest != SIZE_MAX) {
        if (outTimescale) *outTimescale = knownRates[nearest].timescale;
        if (outFrameTicks) *outFrameTicks = knownRates[nearest].frameTicks;
        return YES;
    }

    int timescale = (int)lrint(fps * 1000.0);
    if (timescale <= 0) return NO;
    if (outTimescale) *outTimescale = timescale;
    if (outFrameTicks) *outFrameTicks = 1000;
    return YES;
}

BOOL SpliceKitURLImportCanonicalFrameTimingForTrack(AVAssetTrack *videoTrack,
                                                           int *outTimescale,
                                                           int *outFrameTicks) {
    if (!videoTrack) return NO;
    if (SpliceKitURLImportCanonicalFrameTimingForRate(videoTrack.nominalFrameRate,
                                                      outTimescale,
                                                      outFrameTicks)) {
        return YES;
    }

    CMTime minFrameDuration = videoTrack.minFrameDuration;
    if (CMTIME_IS_VALID(minFrameDuration) && !CMTIME_IS_INDEFINITE(minFrameDuration) &&
        minFrameDuration.value > 0 && minFrameDuration.timescale > 0) {
        double fps = (double)minFrameDuration.timescale / (double)minFrameDuration.value;
        return SpliceKitURLImportCanonicalFrameTimingForRate(fps, outTimescale, outFrameTicks);
    }
    return NO;
}

BOOL SpliceKitURLImportCMTimeMatchesRational(CMTime time, int value, int timescale) {
    if (!CMTIME_IS_VALID(time) || CMTIME_IS_INDEFINITE(time) ||
        time.value <= 0 || time.timescale <= 0 ||
        value <= 0 || timescale <= 0) {
        return NO;
    }
    return (int64_t)time.value * (int64_t)timescale == (int64_t)value * (int64_t)time.timescale;
}

BOOL SpliceKitURLImportNormalizationModeUsesStreamCopy(NSString *mode) {
    NSString *normalized = SpliceKitURLImportTrimmedString(mode);
    return [normalized isEqualToString:@"rewrite_timestamps"] ||
           [normalized isEqualToString:@"remux_copy"] ||
           [normalized isEqualToString:@"remux_copy_rewrite_timestamps"];
}

BOOL SpliceKitURLImportNormalizationModeNeedsTimestampRewrite(NSString *mode) {
    NSString *normalized = SpliceKitURLImportTrimmedString(mode);
    return [normalized isEqualToString:@"rewrite_timestamps"] ||
           [normalized isEqualToString:@"remux_copy_rewrite_timestamps"];
}

// The ffmpeg arguments that rewrite a VP9/VP8 stream's timestamps to constant frame
// rate: frame N at N * frameTicks / timescale seconds.
//   DTS = N * frameTicks -- packets arrive in decode (DTS) order, so the packet
//     index N is already the decode index.
//   PTS = DTS + round((src_pts - src_dts) in source frames) * frameTicks keeps
//     h264/hevc/av1 B-frame display order. `(PTS-DTS)*TB` is the offset in
//     seconds, times `timescale/frameTicks` (= fps) is the offset in frames,
//     round() snaps it to whole frames (cancelling the millisecond quantization
//     of Matroska timestamps), times `frameTicks` turns it back into ticks. For
//     VP9/VP8 the source PTS equals the DTS and the term is 0.
// `-time_base:v` puts the stream in 1/timescale before the setts filter runs, so
// the filter's input and output time bases are the same and `N * frameTicks`
// means ticks of 1/timescale on every ffmpeg. Without it, ffmpeg 9 evaluates the
// expressions in the source time base (Matroska's 1/1000) and then rescales:
// N*1000 became N seconds, a 30 fps clip played one frame per second in Final Cut.
NSArray<NSString *> *SpliceKitURLImportTimestampRewriteArguments(int timescale, int frameTicks) {
    if (timescale <= 0 || frameTicks <= 0) return @[];
    NSString *settsArg = [NSString stringWithFormat:
        @"setts=time_base=1/%d:dts=N*%d:pts=N*%d+round((PTS-DTS)*TB*%d/%d)*%d:duration=%d",
        timescale, frameTicks, frameTicks, timescale, frameTicks, frameTicks, frameTicks];
    return @[
        @"-time_base:v", [NSString stringWithFormat:@"1/%d", timescale],
        @"-bsf:v", settsArg,
    ];
}

// A stream-copy remux keeps every frame, so its output runs no longer than the source.
// nil when it does; otherwise why not, so a remux with broken timestamps (like the
// ffmpeg 9 one above, 30x too long) fails loudly instead of reaching Final Cut.
// Only too long counts: the source's duration is the whole file's (Matroska's segment
// duration), and the remux keeps just the first video and audio track, so an MKV whose
// subtitle or second audio track runs on past the picture remuxes shorter, correctly.
NSString *SpliceKitURLImportRemuxDurationMismatch(NSDictionary *sourceInfo, NSDictionary *outputInfo) {
    double source = SpliceKitURLImportParseFractionString(sourceInfo[@"duration"]);
    double output = SpliceKitURLImportParseFractionString(outputInfo[@"duration"]);
    if (!(source > 0.0) || !(output > 0.0)) return nil;
    double tolerance = MAX(0.5, source * 0.05);
    if (output <= source + tolerance) return nil;
    return [NSString stringWithFormat:
        @"The remuxed file runs %.3f s but the source runs %.3f s; its timestamps are wrong.",
        output, source];
}

NSString *SpliceKitURLImportOutputExtensionForNormalizationMode(NSString *mode) {
    NSString *normalized = SpliceKitURLImportTrimmedString(mode);
    if ([normalized isEqualToString:@"rewrite_timestamps"] ||
        [normalized isEqualToString:@"remux_copy"] ||
        [normalized isEqualToString:@"remux_copy_rewrite_timestamps"]) {
        return @"mp4";
    }
    return @"mov";
}

// Video codecs we can stream-copy from MKV/WebM into an MP4 container without
// re-encoding. AVFoundation and Final Cut play these natively (VP9/VP8 via the
// SpliceKit VP9 decoder bundle; h264/hevc/av1/mpeg4/prores via the system).
BOOL SpliceKitURLImportVideoCodecCanStreamCopyToMP4(NSString *codecName) {
    NSString *normalized = SpliceKitURLImportTrimmedString(codecName).lowercaseString;
    if (normalized.length == 0) return NO;
    return [normalized isEqualToString:@"vp9"] ||
           [normalized isEqualToString:@"vp8"] ||
           [normalized isEqualToString:@"h264"] ||
           [normalized isEqualToString:@"avc"] ||
           [normalized isEqualToString:@"avc1"] ||
           [normalized isEqualToString:@"hevc"] ||
           [normalized isEqualToString:@"h265"] ||
           [normalized isEqualToString:@"av1"] ||
           [normalized isEqualToString:@"mpeg4"] ||
           [normalized isEqualToString:@"mpeg2video"] ||
           [normalized isEqualToString:@"prores"];
}

// Audio codecs we can stream-copy into an MP4 container. Everything else is
// re-encoded to AAC 192k during the remux so the shadow MP4 is guaranteed to
// be playable in Final Cut.
BOOL SpliceKitURLImportAudioCodecCanStreamCopyToMP4(NSString *codecName) {
    NSString *normalized = SpliceKitURLImportTrimmedString(codecName).lowercaseString;
    if (normalized.length == 0) return NO;
    if ([normalized containsString:@"aac"]) return YES;
    return [normalized isEqualToString:@"mp3"] ||
           [normalized isEqualToString:@"ac3"] ||
           [normalized isEqualToString:@"eac3"] ||
           [normalized isEqualToString:@"alac"] ||
           [normalized isEqualToString:@"mp4a"] ||
           [normalized hasPrefix:@"pcm"];
}

// True when the video codec in an MKV/WebM benefits from CFR timestamp rewriting
// during stream-copy to MP4. Every codec we stream-copy suffers the same MKV
// millisecond-quantization problem — avg deltas of 42/41/42ms land as an ugly
// 1/16000 MP4 time_base instead of the canonical 1/24000 (or 1/30000, etc.).
// The setts bitstream filter rewrites packet PTS/DTS to a clean CFR grid using
// a B-frame-safe expression (see the ffmpeg command below), so we apply it to
// h264/hevc/av1 alongside VP9/VP8.
BOOL SpliceKitURLImportVideoCodecNeedsTimestampRewrite(NSString *codecName) {
    NSString *normalized = SpliceKitURLImportTrimmedString(codecName).lowercaseString;
    if (normalized.length == 0) return NO;
    return [normalized isEqualToString:@"vp9"] ||
           [normalized isEqualToString:@"vp8"] ||
           [normalized isEqualToString:@"h264"] ||
           [normalized isEqualToString:@"avc"] ||
           [normalized isEqualToString:@"avc1"] ||
           [normalized isEqualToString:@"hevc"] ||
           [normalized isEqualToString:@"h265"] ||
           [normalized isEqualToString:@"av1"] ||
           [normalized isEqualToString:@"mpeg4"] ||
           [normalized isEqualToString:@"mpeg2video"];
}

double SpliceKitURLImportParseFractionString(NSString *value) {
    NSString *trimmed = SpliceKitURLImportTrimmedString(value);
    if (trimmed.length == 0) return 0.0;

    NSRange slashRange = [trimmed rangeOfString:@"/"];
    if (slashRange.location != NSNotFound) {
        NSString *numeratorString = [trimmed substringToIndex:slashRange.location];
        NSString *denominatorString = [trimmed substringFromIndex:(slashRange.location + 1)];
        double numerator = numeratorString.doubleValue;
        double denominator = denominatorString.doubleValue;
        if (numerator > 0.0 && denominator > 0.0 && isfinite(numerator) && isfinite(denominator)) {
            return numerator / denominator;
        }
        return 0.0;
    }

    double scalar = trimmed.doubleValue;
    return (scalar > 0.0 && isfinite(scalar)) ? scalar : 0.0;
}

NSString *SpliceKitURLImportCMTimeStringFromSeconds(double seconds, NSString *fallback) {
    if (!(seconds >= 0.0) || !isfinite(seconds)) return fallback ?: @"2400/2400s";
    int32_t timescale = 1000;
    int64_t value = llround(seconds * (double)timescale);
    if (value < 0) value = 0;
    return [NSString stringWithFormat:@"%lld/%ds", value, timescale];
}

NSDictionary *SpliceKitURLImportFFprobeJSONForPath(NSString *path, NSString **outError) {
    NSString *ffprobe = SpliceKitURLImportFFprobePath();
    if (ffprobe.length == 0) {
        if (outError) {
            *outError = @"SpliceKit could not find ffprobe to inspect this Matroska/WebM source. Run `make url-import-tools` or put ffprobe in ~/Applications/SpliceKit/tools/.";
        }
        return nil;
    }

    NSArray *arguments = @[
        @"-v", @"error",
        @"-show_streams",
        @"-show_format",
        @"-print_format", @"json",
        path,
    ];

    int status = -1;
    NSData *data = nil;
    NSError *launchError = nil;
    if (SpliceKit_runProcess(ffprobe, arguments, nil, SpliceKitProcessMergeStderr, 0,
                             &status, &data, NULL, &launchError) != SpliceKitProcessExited) {
        if (outError) {
            *outError = launchError.localizedDescription ?: @"Could not launch ffprobe to inspect the source media.";
        }
        return nil;
    }

    NSString *output = SpliceKitURLImportTrimmedString(SpliceKitURLImportStringFromData(data));
    if (status != 0) {
        if (outError) {
            *outError = output.length > 0 ? output : @"ffprobe failed while inspecting the source media.";
        }
        return nil;
    }

    if (output.length == 0) {
        if (outError) *outError = @"ffprobe returned no metadata for the source media.";
        return nil;
    }

    NSData *jsonData = [output dataUsingEncoding:NSUTF8StringEncoding];
    NSError *jsonError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&jsonError];
    if (![object isKindOfClass:[NSDictionary class]]) {
        if (outError) {
            *outError = jsonError.localizedDescription ?: @"ffprobe returned malformed JSON.";
        }
        return nil;
    }
    return (NSDictionary *)object;
}
