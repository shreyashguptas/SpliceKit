// Checks SpliceKitTranscript_placeWords (Sources/Panels/Transcript/SpliceKitTranscriptPlacement.m):
// where each transcribed word plays on the timeline after cuts, moves, blades, a clip used
// twice and a clip removed. Built and run by tests/test_transcript_placement.py.
// Prints one line per failed check and exits 1 when any failed.

#import <Foundation/Foundation.h>
#import "SpliceKitTranscriptPlacement.h"

static int failures = 0;
static const double kFrame = 1.0 / 30.0;

static void check(BOOL ok, NSString *what) {
    if (!ok) {
        failures++;
        printf("FAIL: %s\n", what.UTF8String);
    }
}

static BOOL near(double a, double b) { return fabs(a - b) < 1e-6; }

static NSDictionary *W(NSString *path, double source, double duration) {
    return @{@"path": path, @"sourceMediaTime": @(source), @"duration": @(duration)};
}

static NSDictionary *C(NSString *path, double trim, double duration, double at) {
    return @{@"path": path, @"trimStart": @(trim), @"duration": @(duration), @"timelineStart": @(at)};
}

// "word@start+duration" for each placement, in order: easy to compare and to print.
static NSString *describe(NSArray<NSDictionary *> *placements) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSDictionary *p in placements) {
        [parts addObject:[NSString stringWithFormat:@"%@@%.4f+%.4f", p[@"word"],
                          [p[@"startTime"] doubleValue], [p[@"duration"] doubleValue]]];
    }
    return [parts componentsJoinedByString:@" "];
}

static void expect(NSString *name, NSArray *words, NSArray *clips, NSString *expected) {
    NSString *got = describe(SpliceKitTranscript_placeWords(words, clips, kFrame));
    check([got isEqualToString:expected],
          [NSString stringWithFormat:@"%@\n  expected: %@\n  got:      %@", name, expected, got]);
}

int main(void) {
    @autoreleasepool {
        // Three words in a.mov (0.0-0.4, 0.4-0.5, 0.5-0.9) and one in b.mov.
        NSArray *words = @[W(@"a.mov", 0.0, 0.4), W(@"a.mov", 0.4, 0.1), W(@"a.mov", 0.5, 0.4),
                           W(@"b.mov", 0.2, 0.3)];

        expect(@"unedited timeline: every word at its own time",
               words, @[C(@"a.mov", 0, 1.0, 0), C(@"b.mov", 0, 1.0, 1.0)],
               @"0@0.0000+0.4000 1@0.4000+0.1000 2@0.5000+0.4000 3@1.2000+0.3000");

        // Word 1 deleted with both cuts rounded to frames: the first piece ends at 0.4333
        // (a 33 ms sliver of word 1 is left there) and the second starts at source 0.5.
        expect(@"deleted word with a sliver left: gone, not kept",
               words, @[C(@"a.mov", 0, 0.43333333, 0), C(@"a.mov", 0.5, 0.5, 0.43333333), C(@"b.mov", 0, 1.0, 0.93333333)],
               @"0@0.0000+0.4000 2@0.4333+0.4000 3@1.1333+0.3000");

        // The cut after word 1 rounded to a frame past the start of word 2 (piece starts at
        // source 0.5333): word 2 is still there, from the start of its piece. The old resync
        // lost it (its start was before every piece).
        expect(@"next word's start a frame before its piece: kept, from the piece's start",
               words, @[C(@"a.mov", 0, 0.4, 0), C(@"a.mov", 0.53333333, 0.46666667, 0.4)],
               @"0@0.0000+0.4000 2@0.4000+0.3667");

        // A blade (nothing removed) in the middle of word 2 at source 0.6: one word, at its
        // own time and full length, on the piece that plays most of it.
        expect(@"blade inside a word: the word once, whole",
               words, @[C(@"a.mov", 0, 0.6, 0), C(@"a.mov", 0.6, 0.4, 0.6)],
               @"0@0.0000+0.4000 1@0.4000+0.1000 2@0.5000+0.4000");

        // Word 2 reaches past the end of its piece (source 0.75), and the next piece is other
        // media: the word stops at the edge, so deleting it never takes the next piece's frames.
        expect(@"word cut short by its piece's end",
               words, @[C(@"a.mov", 0, 0.75, 0), C(@"b.mov", 0, 1.0, 0.75)],
               @"0@0.0000+0.4000 1@0.4000+0.1000 2@0.5000+0.2500 3@0.9500+0.3000");

        // Delete Silences cut the pause folded into the tail of a long word (0.0-0.66, spoken
        // part about 0.24): the word stays, as long as the part still played.
        expect(@"pause cut from a long word's tail: the word stays, shorter",
               @[W(@"a.mov", 0.0, 0.66), W(@"a.mov", 0.66, 0.3)],
               @[C(@"a.mov", 0, 0.24, 0), C(@"a.mov", 0.66, 0.34, 0.24)],
               @"0@0.0000+0.2400 1@0.2400+0.3000");

        // A two-frame word deleted, the cut before it rounded down a frame: gone.
        expect(@"short word deleted with a frame of it left: gone",
               @[W(@"a.mov", 0.0, 0.5), W(@"a.mov", 0.5, 0.0667), W(@"a.mov", 0.5667, 0.3)],
               @[C(@"a.mov", 0, 0.5333, 0), C(@"a.mov", 0.5667, 0.4333, 0.5333)],
               @"0@0.0000+0.5000 2@0.5333+0.3000");

        expect(@"pieces moved: words in the new order",
               words, @[C(@"a.mov", 0.5, 0.5, 0), C(@"a.mov", 0, 0.5, 0.5)],
               @"2@0.0000+0.4000 0@0.5000+0.4000 1@0.9000+0.1000");

        expect(@"clip used twice: its words twice",
               @[W(@"b.mov", 0.2, 0.3)], @[C(@"b.mov", 0, 1.0, 0), C(@"b.mov", 0, 1.0, 5.0)],
               @"0@0.2000+0.3000 0@5.2000+0.3000");

        expect(@"clip removed: its words on no clip",
               words, @[C(@"a.mov", 0, 1.0, 0)],
               @"0@0.0000+0.4000 1@0.4000+0.1000 2@0.5000+0.4000");

        expect(@"everything removed: no words",
               words, @[], @"");

        // A clip played at a conformed rate (1.001 timeline seconds per source second).
        NSMutableDictionary *conformed = [C(@"b.mov", 0, 1.001, 2.0) mutableCopy];
        conformed[@"rateFactor"] = @1.001;
        expect(@"rate factor applied",
               @[W(@"b.mov", 0.5, 0.2)], @[conformed], @"0@2.5005+0.2000");

        expect(@"a word with no media path matches a clip of any file",
               @[W(@"", 0.3, 0.2)], @[C(@"z.mov", 0, 1.0, 4.0)], @"0@4.3000+0.2000");

        // Same media under a connected clip and the primary storyline at different places:
        // a word is placed on each, sorted by time.
        expect(@"same media on two lanes: both places, by time",
               @[W(@"a.mov", 0.1, 0.2)], @[C(@"a.mov", 0, 1.0, 3.0), C(@"a.mov", 0, 1.0, 1.0)],
               @"0@1.1000+0.2000 0@3.1000+0.2000");
    }
    if (failures == 0) printf("all placement checks passed\n");
    return failures == 0 ? 0 : 1;
}
