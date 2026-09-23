//
//  SpliceKitTime.m
//  See SpliceKitTime.h.
//

#import "SpliceKitTime.h"

double SpliceKit_secondsFromTime(CMTime t) {
    if (t.timescale <= 0) return 0.0;
    return (double)t.value / (double)t.timescale;
}

CMTime SpliceKit_timeFromSeconds(double seconds, int32_t timescale) {
    int32_t ts = timescale > 0 ? timescale : 600;
    CMTime t = {(int64_t)round(seconds * ts), ts, 1, 0};
    return t;
}

CMTime SpliceKit_sequenceFrameDuration(id sequence) {
    CMTime fd = {0, 0, 0, 0};
    SEL fdSel = NSSelectorFromString(@"frameDuration");
    if (sequence && [sequence respondsToSelector:fdSel]) {
        fd = ((CMTime (*)(id, SEL))STRET_MSG)(sequence, fdSel);
    }
    return fd;
}
