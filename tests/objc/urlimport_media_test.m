//
//  urlimport_media_test.m
//  Offline checks for the WebM / MKV remux helpers in
//  Sources/Media/URLImport/SpliceKitURLImportMedia.m, built and run by
//  tests/test_urlimport_media.py (no Final Cut Pro needed).
//
//  urlimport_media_test check        run the assertions; exit 1 on any failure
//  urlimport_media_test args <fps>   print "<timescale> <frameTicks>" and then the
//                                    timestamp-rewrite ffmpeg arguments, one per
//                                    line, so the Python test can run them on a
//                                    real WebM with the ffmpeg SpliceKit uses
//

#import <Foundation/Foundation.h>
#import "SpliceKitURLImport+Private.h"

// The four symbols SpliceKitURLImportMedia.m takes from the rest of the dylib.
// Only the string helpers matter here; ffprobe is never run.
NSString *SpliceKitURLImportTrimmedString(id value) {
    if (![value isKindOfClass:[NSString class]]) return @"";
    return [(NSString *)value stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

NSString *SpliceKitURLImportStringFromData(NSData *data) {
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

NSString *SpliceKitURLImportFFprobePath(void) { return nil; }

SpliceKitProcessOutcome SpliceKit_runProcess(NSString *path, NSArray<NSString *> *arguments,
                                             NSString *directory, SpliceKitProcessOptions options,
                                             NSTimeInterval timeout, int *statusOut,
                                             NSData **stdoutOut, NSData **stderrOut,
                                             NSError **errorOut) {
    return SpliceKitProcessLaunchFailed;
}

static int sFailures = 0;

static void expect(BOOL condition, NSString *what) {
    if (!condition) {
        sFailures++;
        fprintf(stderr, "FAIL: %s\n", what.UTF8String);
    }
}

static void expectTiming(double fps, int timescale, int frameTicks) {
    int ts = 0, ticks = 0;
    BOOL ok = SpliceKitURLImportCanonicalFrameTimingForRate(fps, &ts, &ticks);
    expect(ok && ts == timescale && ticks == frameTicks,
           [NSString stringWithFormat:@"%.4f fps -> %d/%d, got %d/%d (ok=%d)",
            fps, timescale, frameTicks, ts, ticks, ok]);
}

static void checkFrameTiming(void) {
    // Each rate maps to itself, not to the first rate within tolerance:
    // 30 and 29.97 are 0.03 apart, and 30 used to come out as 29.97.
    expectTiming(24000.0 / 1001.0, 24000, 1001);
    expectTiming(24.0, 24000, 1000);
    expectTiming(25.0, 25000, 1000);
    expectTiming(30000.0 / 1001.0, 30000, 1001);
    expectTiming(30.0, 30000, 1000);
    expectTiming(50.0, 50000, 1000);
    expectTiming(60000.0 / 1001.0, 60000, 1001);
    expectTiming(60.0, 60000, 1000);
    // Matroska stores milliseconds, so a probed rate is a little off.
    expectTiming(29.98, 30000, 1001);
    expectTiming(29.99, 30000, 1000);
    expectTiming(23.98, 24000, 1001);
    // A rate that is no standard one keeps its own value in milliseconds.
    expectTiming(15.0, 15000, 1000);
    expectTiming(120.0, 120000, 1000);

    int ts = 0, ticks = 0;
    expect(!SpliceKitURLImportCanonicalFrameTimingForRate(0, &ts, &ticks), @"0 fps is refused");
    expect(!SpliceKitURLImportCanonicalFrameTimingForRate(-30, &ts, &ticks), @"negative fps is refused");
    expect(!SpliceKitURLImportCanonicalFrameTimingForRate(NAN, &ts, &ticks), @"NaN fps is refused");
}

static void checkRewriteArguments(void) {
    NSArray<NSString *> *args = SpliceKitURLImportTimestampRewriteArguments(30000, 1000);
    expect(args.count == 4, @"rewrite arguments are -time_base:v X -bsf:v Y");
    if (args.count == 4) {
        // The time base has to come before the filter, and match it: that is the
        // ffmpeg 9 fix (without it N*1000 came out as N seconds).
        expect([args[0] isEqualToString:@"-time_base:v"], @"first argument is -time_base:v");
        expect([args[1] isEqualToString:@"1/30000"], @"stream time base is 1/timescale");
        expect([args[2] isEqualToString:@"-bsf:v"], @"third argument is -bsf:v");
        expect([args[3] hasPrefix:@"setts=time_base=1/30000:"], @"setts writes 1/timescale");
        expect([args[3] containsString:@"dts=N*1000"], @"frame N decodes at N * frameTicks");
        expect([args[3] containsString:@"duration=1000"], @"every frame lasts frameTicks");
    }
    expect(SpliceKitURLImportTimestampRewriteArguments(0, 1000).count == 0, @"no arguments for timescale 0");
    expect(SpliceKitURLImportTimestampRewriteArguments(30000, 0).count == 0, @"no arguments for 0 ticks");
}

static void checkDurationCheck(void) {
    NSString *(*mismatch)(NSDictionary *, NSDictionary *) = SpliceKitURLImportRemuxDurationMismatch;
    expect(mismatch(@{@"duration": @"3.000"}, @{@"duration": @"3.003"}) == nil,
           @"a remux 3 ms longer is fine");
    expect(mismatch(@{@"duration": @"120.0"}, @{@"duration": @"124.0"}) == nil,
           @"5% of a long clip is fine");
    expect(mismatch(@{@"duration": @"3.000"}, @{@"duration": @"90.090"}) != nil,
           @"the ffmpeg 9 bug (30x too long) is caught");
    expect(mismatch(@{@"duration": @"120.0"}, @{@"duration": @"130.0"}) != nil,
           @"8% too long is caught");
    expect(mismatch(@{@"duration": @"0.2"}, @{@"duration": @"0.6"}) == nil,
           @"a very short clip gets half a second of slack");
    expect(mismatch(@{@"duration": @"600.0"}, @{@"duration": @"540.0"}) == nil,
           @"shorter is fine: a subtitle track that runs on past the picture is not copied");
    expect(mismatch(@{}, @{@"duration": @"3"}) == nil, @"no source duration: nothing to compare");
    expect(mismatch(@{@"duration": @"3"}, @{}) == nil, @"no output duration: nothing to compare");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc >= 3 && strcmp(argv[1], "args") == 0) {
            int ts = 0, ticks = 0;
            if (!SpliceKitURLImportCanonicalFrameTimingForRate(atof(argv[2]), &ts, &ticks)) return 2;
            printf("%d %d\n", ts, ticks);
            for (NSString *arg in SpliceKitURLImportTimestampRewriteArguments(ts, ticks)) {
                printf("%s\n", arg.UTF8String);
            }
            return 0;
        }
        if (argc >= 2 && strcmp(argv[1], "check") == 0) {
            checkFrameTiming();
            checkRewriteArguments();
            checkDurationCheck();
            if (sFailures == 0) printf("ok\n");
            return sFailures == 0 ? 0 : 1;
        }
        fprintf(stderr, "usage: %s check | args <fps>\n", argv[0]);
        return 2;
    }
}
