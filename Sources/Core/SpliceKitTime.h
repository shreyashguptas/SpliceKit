//
//  SpliceKitTime.h
//  CMTime plumbing shared by the bridge, the panels and the timeline features.
//
//  FCP's model objects return CMTime / CMTimeRange by value. We use CoreMedia's own
//  types (only the struct definitions: calling CMTime functions is what links
//  CoreMedia, and nothing here does) and read them through STRET_MSG.
//
//  Everything declared here is hidden: it never shows up in the dylib's exports.
//

#ifndef SpliceKitTime_h
#define SpliceKitTime_h

#import <Foundation/Foundation.h>
#import <CoreMedia/CMTime.h>
#import <CoreMedia/CMTimeRange.h>
#import <objc/message.h>

// objc_msgSend for a method that returns a struct, cast to the method's real type:
//   CMTime t = ((CMTime (*)(id, SEL))STRET_MSG)(obj, sel);
// On x86_64 a struct larger than 16 bytes (CMTime, CMTimeRange, CGRect) comes back in
// memory, which needs objc_msgSend_stret. arm64 has no such variant: every struct goes
// through plain objc_msgSend. We build universal, so handle both.
#if defined(__x86_64__)
#define STRET_MSG objc_msgSend_stret
#else
#define STRET_MSG objc_msgSend
#endif

#pragma GCC visibility push(hidden)

// value / timescale in seconds; 0 when the timescale is not positive (an invalid time).
double SpliceKit_secondsFromTime(CMTime t);

// seconds * timescale, rounded to the nearest tick; timescale <= 0 means 600.
// flags = valid, epoch = 0.
CMTime SpliceKit_timeFromSeconds(double seconds, int32_t timescale);

// -[sequence frameDuration]; a zeroed CMTime (timescale 0) when the sequence is nil or
// does not answer frameDuration.
CMTime SpliceKit_sequenceFrameDuration(id sequence);

#pragma GCC visibility pop

#endif /* SpliceKitTime_h */
