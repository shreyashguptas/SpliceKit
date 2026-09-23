//
//  SpliceKitLiveCamViews.m
//  Small LiveCam views: the flipped document view for the Advanced controls and
//  the dBFS audio input meter.
//

#import "SpliceKitLiveCam+Private.h"

// Flipped NSView used as the documentView for the Advanced controls scroll
// view so the clip view shows the top of the stack first (NSStackView is
// unflipped by default, which makes NSScrollView's initial bounds origin
// sit at the bottom-left of the content).

@implementation SpliceKitLiveCamFlippedView
- (BOOL)isFlipped { return YES; }
@end

// Compact broadcast-style input meter for the LiveCam audio card. The old
// NSLevelIndicator was only 12 points tall and mapped linear RMS to an
// arbitrary 0-100 range, so it was easy to miss and gave no useful headroom
// information. This view uses the standard dBFS scale, keeps a short peak hold,
// and makes clipping visible without taking over the compact four-card layout.

@implementation SpliceKitLiveCamAudioMeterView

static double SpliceKitLiveCamMeterClampedDB(double value) {
    if (!isfinite(value)) return -60.0;
    return MIN(0.0, MAX(-60.0, value));
}

static CGFloat SpliceKitLiveCamMeterPosition(double value) {
    return (CGFloat)((SpliceKitLiveCamMeterClampedDB(value) + 60.0) / 60.0);
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    _rmsDB = -60.0;
    _peakDB = -60.0;
    _heldPeakDB = -60.0;
    self.toolTip = @"Live microphone level in dBFS. Keep peaks out of the red to avoid clipping.";
    [self setAccessibilityElement:YES];
    [self setAccessibilityRole:NSAccessibilityLevelIndicatorRole];
    [self setAccessibilityLabel:@"Audio monitor"];
    return self;
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize(168.0, 46.0);
}

- (void)updateWithRMSDB:(double)rmsDB peakDB:(double)peakDB {
    self.rmsDB = SpliceKitLiveCamMeterClampedDB(rmsDB);
    self.peakDB = SpliceKitLiveCamMeterClampedDB(peakDB);

    NSTimeInterval now = CACurrentMediaTime();
    if (self.peakDB >= self.heldPeakDB) {
        self.heldPeakDB = self.peakDB;
        self.peakHoldUntil = now + 0.8;
    } else if (now > self.peakHoldUntil) {
        self.heldPeakDB = MAX(self.peakDB, self.heldPeakDB - 2.0);
    }
    if (self.peakDB >= -0.5) {
        self.clipHoldUntil = now + 1.5;
    }

    NSString *accessibilityValue = self.peakDB <= -59.5
        ? @"No signal"
        : [NSString stringWithFormat:@"Peak %.0f decibels full scale", self.peakDB];
    [self setAccessibilityValue:accessibilityValue];
    [self setNeedsDisplay:YES];
}

- (void)reset {
    self.rmsDB = -60.0;
    self.peakDB = -60.0;
    self.heldPeakDB = -60.0;
    self.peakHoldUntil = 0.0;
    self.clipHoldUntil = 0.0;
    [self setAccessibilityValue:@"No signal"];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    NSRect bounds = self.bounds;
    NSRect track = NSMakeRect(1.0, 14.0, MAX(1.0, NSWidth(bounds) - 2.0), 10.0);
    NSBezierPath *trackPath = [NSBezierPath bezierPathWithRoundedRect:track
                                                             xRadius:3.0
                                                             yRadius:3.0];
    [[NSColor colorWithWhite:0.04 alpha:0.88] setFill];
    [trackPath fill];

    NSArray<NSColor *> *zoneColors = @[
        [NSColor colorWithRed:0.20 green:0.82 blue:0.42 alpha:1.0],
        [NSColor colorWithRed:0.96 green:0.73 blue:0.18 alpha:1.0],
        [NSColor colorWithRed:0.96 green:0.25 blue:0.23 alpha:1.0],
    ];
    const double zoneStarts[] = { -60.0, -12.0, -3.0 };
    const double zoneEnds[] = { -12.0, -3.0, 0.0 };

    [NSGraphicsContext saveGraphicsState];
    [trackPath addClip];
    for (NSUInteger i = 0; i < 3; i++) {
        CGFloat startX = NSMinX(track) + NSWidth(track) * SpliceKitLiveCamMeterPosition(zoneStarts[i]);
        CGFloat endX = NSMinX(track) + NSWidth(track) * SpliceKitLiveCamMeterPosition(zoneEnds[i]);
        [[zoneColors[i] colorWithAlphaComponent:0.18] setFill];
        NSRectFill(NSMakeRect(startX, NSMinY(track), MAX(0.0, endX - startX), NSHeight(track)));
    }

    CGFloat activeWidth = NSWidth(track) * SpliceKitLiveCamMeterPosition(self.rmsDB);
    [[NSBezierPath bezierPathWithRect:NSMakeRect(NSMinX(track),
                                                 NSMinY(track),
                                                 activeWidth,
                                                 NSHeight(track))] addClip];
    for (NSUInteger i = 0; i < 3; i++) {
        CGFloat startX = NSMinX(track) + NSWidth(track) * SpliceKitLiveCamMeterPosition(zoneStarts[i]);
        CGFloat endX = NSMinX(track) + NSWidth(track) * SpliceKitLiveCamMeterPosition(zoneEnds[i]);
        [zoneColors[i] setFill];
        NSRectFill(NSMakeRect(startX, NSMinY(track), MAX(0.0, endX - startX), NSHeight(track)));
    }
    [NSGraphicsContext restoreGraphicsState];

    if (self.heldPeakDB > -59.5) {
        CGFloat peakX = NSMinX(track) + NSWidth(track) * SpliceKitLiveCamMeterPosition(self.heldPeakDB);
        NSBezierPath *peakLine = [NSBezierPath bezierPath];
        [peakLine moveToPoint:NSMakePoint(peakX, NSMinY(track) + 1.0)];
        [peakLine lineToPoint:NSMakePoint(peakX, NSMaxY(track) - 1.0)];
        peakLine.lineWidth = 1.5;
        [[NSColor colorWithWhite:1.0 alpha:0.95] setStroke];
        [peakLine stroke];
    }

    NSDictionary *headerAttributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:9.0 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
        NSKernAttributeName: @(0.8),
    };
    [@"MONITOR" drawAtPoint:NSMakePoint(1.0, 30.0) withAttributes:headerAttributes];

    BOOL clipping = CACurrentMediaTime() < self.clipHoldUntil;
    NSString *readout = clipping
        ? @"CLIP"
        : (self.peakDB <= -59.5
            ? @"−∞ dBFS"
            : [NSString stringWithFormat:@"%.0f dBFS", self.peakDB]);
    NSDictionary *readoutAttributes = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:9.0 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: clipping ? [NSColor systemRedColor] : [NSColor secondaryLabelColor],
    };
    NSSize readoutSize = [readout sizeWithAttributes:readoutAttributes];
    [readout drawAtPoint:NSMakePoint(MAX(1.0, NSMaxX(bounds) - readoutSize.width - 1.0), 30.0)
          withAttributes:readoutAttributes];

    NSDictionary *tickAttributes = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:7.5 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: [NSColor tertiaryLabelColor],
    };
    NSArray<NSNumber *> *ticks = @[@(-48), @(-24), @(-12), @(-6), @(0)];
    for (NSNumber *tick in ticks) {
        NSString *label = tick.stringValue;
        NSSize labelSize = [label sizeWithAttributes:tickAttributes];
        CGFloat centerX = NSMinX(track) + NSWidth(track) * SpliceKitLiveCamMeterPosition(tick.doubleValue);
        CGFloat labelX = MIN(NSMaxX(bounds) - labelSize.width,
                             MAX(NSMinX(bounds), centerX - labelSize.width * 0.5));
        [label drawAtPoint:NSMakePoint(labelX, 1.0) withAttributes:tickAttributes];
    }
}

@end
