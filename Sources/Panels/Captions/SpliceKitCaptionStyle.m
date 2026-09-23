//
//  SpliceKitCaptionStyle.m
//  Caption styles and segments: SpliceKitCaptionStyle (the built-in presets and
//  dictionary round-trip), SpliceKitCaptionSegment, and the colour / word dictionary helpers.
//

#import "SpliceKitCaptionPanel+Private.h"

#pragma mark - NSColor RGBA Helpers

NSString *SpliceKitCaption_colorToFCPXML(NSColor *color) {
    if (!color) return @"1 1 1 1";
    NSColor *rgb = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!rgb) rgb = color;
    return [NSString stringWithFormat:@"%.3f %.3f %.3f %.3f",
            rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent];
}

static NSColor *SpliceKitCaption_colorFromString(NSString *str) {
    if (!str || str.length == 0) return [NSColor whiteColor];
    NSArray *parts = [str componentsSeparatedByString:@" "];
    if (parts.count < 3) return [NSColor whiteColor];
    CGFloat r = [parts[0] doubleValue];
    CGFloat g = [parts[1] doubleValue];
    CGFloat b = [parts[2] doubleValue];
    CGFloat a = parts.count >= 4 ? [parts[3] doubleValue] : 1.0;
    return [NSColor colorWithRed:r green:g blue:b alpha:a];
}

NSDictionary *SpliceKitCaption_transcriptWordToDictionary(SpliceKitTranscriptWord *word) {
    if (!word) return @{};
    return @{
        @"index": @(word.wordIndex),
        @"text": word.text ?: @"",
        @"startTime": @(word.startTime),
        @"duration": @(word.duration),
        @"endTime": @(word.endTime),
        @"confidence": @(word.confidence),
        @"speaker": word.speaker ?: @"Unknown",
        @"clipHandle": word.clipHandle ?: @"",
        @"clipTimelineStart": @(word.clipTimelineStart),
        @"sourceMediaOffset": @(word.sourceMediaOffset),
        @"sourceMediaTime": @(word.sourceMediaTime),
        @"sourceMediaPath": word.sourceMediaPath ?: @"",
    };
}

SpliceKitTranscriptWord *SpliceKitCaption_transcriptWordFromDictionary(NSDictionary *dict) {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    SpliceKitTranscriptWord *word = [[SpliceKitTranscriptWord alloc] init];
    word.text = dict[@"text"] ?: @"";
    word.startTime = [dict[@"startTime"] doubleValue];
    word.duration = [dict[@"duration"] doubleValue];
    word.endTime = [dict[@"endTime"] doubleValue];
    if (word.endTime <= word.startTime) word.endTime = word.startTime + word.duration;
    word.confidence = [dict[@"confidence"] doubleValue];
    word.wordIndex = [dict[@"index"] unsignedIntegerValue];
    word.speaker = dict[@"speaker"] ?: @"Unknown";
    word.clipHandle = dict[@"clipHandle"];
    word.clipTimelineStart = [dict[@"clipTimelineStart"] doubleValue];
    word.sourceMediaOffset = [dict[@"sourceMediaOffset"] doubleValue];
    word.sourceMediaTime = [dict[@"sourceMediaTime"] doubleValue];
    word.sourceMediaPath = dict[@"sourceMediaPath"];
    return word;
}

#pragma mark - SpliceKitCaptionStyle

@implementation SpliceKitCaptionStyle

- (instancetype)init {
    self = [super init];
    if (self) {
        _name = @"Custom";
        _presetID = @"custom";
        _font = @"Helvetica Neue";
        _fontSize = 60;
        _fontFace = @"Bold";
        _textColor = [NSColor whiteColor];
        _highlightColor = [NSColor colorWithRed:1 green:0.85 blue:0 alpha:1];
        _outlineColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:1];
        _outlineWidth = 2.0;
        _shadowColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:0.8];
        _shadowBlurRadius = 4.0;
        _shadowOffsetX = 0;
        _shadowOffsetY = 0;
        _backgroundColor = nil;
        _backgroundPadding = 0;
        _position = SpliceKitCaptionPositionBottom;
        _customYOffset = 0;
        _animation = SpliceKitCaptionAnimationFade;
        _animationDuration = 0.2;
        _allCaps = YES;
        _wordByWordHighlight = YES;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    SpliceKitCaptionStyle *copy = [[SpliceKitCaptionStyle alloc] init];
    copy.name = self.name;
    copy.presetID = self.presetID;
    copy.font = self.font;
    copy.fontSize = self.fontSize;
    copy.fontFace = self.fontFace;
    copy.textColor = self.textColor;
    copy.highlightColor = self.highlightColor;
    copy.outlineColor = self.outlineColor;
    copy.outlineWidth = self.outlineWidth;
    copy.shadowColor = self.shadowColor;
    copy.shadowBlurRadius = self.shadowBlurRadius;
    copy.shadowOffsetX = self.shadowOffsetX;
    copy.shadowOffsetY = self.shadowOffsetY;
    copy.backgroundColor = self.backgroundColor;
    copy.backgroundPadding = self.backgroundPadding;
    copy.position = self.position;
    copy.customYOffset = self.customYOffset;
    copy.animation = self.animation;
    copy.animationDuration = self.animationDuration;
    copy.allCaps = self.allCaps;
    copy.wordByWordHighlight = self.wordByWordHighlight;
    return copy;
}

static NSString *SpliceKitCaption_positionName(SpliceKitCaptionPosition p) {
    switch (p) {
        case SpliceKitCaptionPositionBottom: return @"bottom";
        case SpliceKitCaptionPositionCenter: return @"center";
        case SpliceKitCaptionPositionTop: return @"top";
        case SpliceKitCaptionPositionCustom: return @"custom";
    }
    return @"bottom";
}

static SpliceKitCaptionPosition SpliceKitCaption_positionFromName(NSString *name) {
    if ([name isEqualToString:@"center"]) return SpliceKitCaptionPositionCenter;
    if ([name isEqualToString:@"top"]) return SpliceKitCaptionPositionTop;
    if ([name isEqualToString:@"custom"]) return SpliceKitCaptionPositionCustom;
    return SpliceKitCaptionPositionBottom;
}

static NSString *SpliceKitCaption_animationName(SpliceKitCaptionAnimation a) {
    switch (a) {
        case SpliceKitCaptionAnimationNone: return @"none";
        case SpliceKitCaptionAnimationFade: return @"fade";
        case SpliceKitCaptionAnimationPop: return @"pop";
        case SpliceKitCaptionAnimationSlideUp: return @"slide_up";
        case SpliceKitCaptionAnimationTypewriter: return @"typewriter";
        case SpliceKitCaptionAnimationBounce: return @"bounce";
    }
    return @"none";
}

static SpliceKitCaptionAnimation SpliceKitCaption_animationFromName(NSString *name) {
    if ([name isEqualToString:@"fade"]) return SpliceKitCaptionAnimationFade;
    if ([name isEqualToString:@"pop"]) return SpliceKitCaptionAnimationPop;
    if ([name isEqualToString:@"slide_up"]) return SpliceKitCaptionAnimationSlideUp;
    if ([name isEqualToString:@"typewriter"]) return SpliceKitCaptionAnimationTypewriter;
    if ([name isEqualToString:@"bounce"]) return SpliceKitCaptionAnimationBounce;
    return SpliceKitCaptionAnimationNone;
}

- (NSDictionary *)toDictionary {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"name"] = self.name ?: @"Custom";
    d[@"presetID"] = self.presetID ?: @"custom";
    d[@"font"] = self.font ?: @"Helvetica Neue";
    d[@"fontSize"] = @(self.fontSize);
    d[@"fontFace"] = self.fontFace ?: @"Bold";
    d[@"textColor"] = SpliceKitCaption_colorToFCPXML(self.textColor);
    d[@"highlightColor"] = self.highlightColor ? SpliceKitCaption_colorToFCPXML(self.highlightColor) : [NSNull null];
    d[@"outlineColor"] = SpliceKitCaption_colorToFCPXML(self.outlineColor);
    d[@"outlineWidth"] = @(self.outlineWidth);
    d[@"shadowColor"] = SpliceKitCaption_colorToFCPXML(self.shadowColor);
    d[@"shadowBlurRadius"] = @(self.shadowBlurRadius);
    d[@"shadowOffsetX"] = @(self.shadowOffsetX);
    d[@"shadowOffsetY"] = @(self.shadowOffsetY);
    d[@"backgroundColor"] = self.backgroundColor ? SpliceKitCaption_colorToFCPXML(self.backgroundColor) : [NSNull null];
    d[@"backgroundPadding"] = @(self.backgroundPadding);
    d[@"position"] = SpliceKitCaption_positionName(self.position);
    d[@"customYOffset"] = @(self.customYOffset);
    d[@"animation"] = SpliceKitCaption_animationName(self.animation);
    d[@"animationDuration"] = @(self.animationDuration);
    d[@"allCaps"] = @(self.allCaps);
    d[@"wordByWordHighlight"] = @(self.wordByWordHighlight);
    return d;
}

+ (instancetype)fromDictionary:(NSDictionary *)dict {
    SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
    if (dict[@"name"]) s.name = dict[@"name"];
    if (dict[@"presetID"]) s.presetID = dict[@"presetID"];
    if (dict[@"font"]) s.font = dict[@"font"];
    if (dict[@"fontSize"]) s.fontSize = [dict[@"fontSize"] doubleValue];
    if (dict[@"fontFace"]) s.fontFace = dict[@"fontFace"];
    if (dict[@"textColor"]) s.textColor = SpliceKitCaption_colorFromString(dict[@"textColor"]);
    if (dict[@"highlightColor"] && dict[@"highlightColor"] != [NSNull null])
        s.highlightColor = SpliceKitCaption_colorFromString(dict[@"highlightColor"]);
    if (dict[@"outlineColor"]) s.outlineColor = SpliceKitCaption_colorFromString(dict[@"outlineColor"]);
    if (dict[@"outlineWidth"]) s.outlineWidth = [dict[@"outlineWidth"] doubleValue];
    if (dict[@"shadowColor"]) s.shadowColor = SpliceKitCaption_colorFromString(dict[@"shadowColor"]);
    if (dict[@"shadowBlurRadius"]) s.shadowBlurRadius = [dict[@"shadowBlurRadius"] doubleValue];
    if (dict[@"shadowOffsetX"]) s.shadowOffsetX = [dict[@"shadowOffsetX"] doubleValue];
    if (dict[@"shadowOffsetY"]) s.shadowOffsetY = [dict[@"shadowOffsetY"] doubleValue];
    if (dict[@"backgroundColor"] && dict[@"backgroundColor"] != [NSNull null])
        s.backgroundColor = SpliceKitCaption_colorFromString(dict[@"backgroundColor"]);
    if (dict[@"backgroundPadding"]) s.backgroundPadding = [dict[@"backgroundPadding"] doubleValue];
    if (dict[@"position"]) s.position = SpliceKitCaption_positionFromName(dict[@"position"]);
    if (dict[@"customYOffset"]) s.customYOffset = [dict[@"customYOffset"] doubleValue];
    if (dict[@"animation"]) s.animation = SpliceKitCaption_animationFromName(dict[@"animation"]);
    if (dict[@"animationDuration"]) s.animationDuration = [dict[@"animationDuration"] doubleValue];
    if (dict[@"allCaps"]) s.allCaps = [dict[@"allCaps"] boolValue];
    if (dict[@"wordByWordHighlight"]) s.wordByWordHighlight = [dict[@"wordByWordHighlight"] boolValue];
    return s;
}

+ (NSArray<SpliceKitCaptionStyle *> *)builtInPresets {
    static NSArray *presets = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray *list = [NSMutableArray array];

        // 1. Bold Pop — high energy YouTube/TikTok style
        {
            SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
            s.presetID = @"bold_pop"; s.name = @"Bold Pop";
            s.font = @"Futura-Bold"; s.fontSize = 72; s.fontFace = @"Bold";
            s.textColor = [NSColor whiteColor];
            s.highlightColor = [NSColor colorWithRed:1 green:0.85 blue:0 alpha:1];
            s.outlineColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:1]; s.outlineWidth = 3.0;
            s.shadowColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:0.8]; s.shadowBlurRadius = 4;
            s.position = SpliceKitCaptionPositionBottom;
            s.animation = SpliceKitCaptionAnimationPop; s.animationDuration = 0.2;
            s.allCaps = YES; s.wordByWordHighlight = YES;
            [list addObject:s];
        }

        // 2. Neon Glow
        {
            SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
            s.presetID = @"neon_glow"; s.name = @"Neon Glow";
            s.font = @"Avenir-Heavy"; s.fontSize = 68; s.fontFace = @"Heavy";
            s.textColor = [NSColor colorWithRed:0 green:1 blue:1 alpha:1];
            s.highlightColor = [NSColor colorWithRed:1 green:0 blue:1 alpha:1];
            s.outlineColor = nil; s.outlineWidth = 0;
            s.shadowColor = [NSColor colorWithRed:0 green:0.8 blue:1 alpha:0.9]; s.shadowBlurRadius = 15;
            s.position = SpliceKitCaptionPositionBottom;
            s.animation = SpliceKitCaptionAnimationFade; s.animationDuration = 0.25;
            s.allCaps = NO; s.wordByWordHighlight = YES;
            [list addObject:s];
        }

        // 3. Clean Minimal
        {
            SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
            s.presetID = @"clean_minimal"; s.name = @"Clean Minimal";
            s.font = @"HelveticaNeue-Bold"; s.fontSize = 60; s.fontFace = @"Bold";
            s.textColor = [NSColor whiteColor];
            s.highlightColor = [NSColor colorWithRed:0.4 green:0.7 blue:1 alpha:1];
            s.outlineColor = nil; s.outlineWidth = 0;
            s.shadowColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:0.5]; s.shadowBlurRadius = 3;
            s.position = SpliceKitCaptionPositionBottom;
            s.animation = SpliceKitCaptionAnimationFade; s.animationDuration = 0.2;
            s.allCaps = NO; s.wordByWordHighlight = YES;
            [list addObject:s];
        }

        // 4. Handwritten
        {
            SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
            s.presetID = @"handwritten"; s.name = @"Handwritten";
            s.font = @"Bradley Hand"; s.fontSize = 64; s.fontFace = @"Bold";
            s.textColor = [NSColor colorWithRed:0.95 green:0.95 blue:0.9 alpha:1];
            s.highlightColor = [NSColor colorWithRed:1 green:0.6 blue:0.2 alpha:1];
            s.outlineColor = nil; s.outlineWidth = 0;
            s.shadowColor = [NSColor colorWithRed:0.3 green:0.2 blue:0.1 alpha:0.6]; s.shadowBlurRadius = 4;
            s.position = SpliceKitCaptionPositionBottom;
            s.animation = SpliceKitCaptionAnimationNone; s.animationDuration = 0;
            s.allCaps = NO; s.wordByWordHighlight = YES;
            [list addObject:s];
        }

        // 5. Gradient Fire
        {
            SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
            s.presetID = @"gradient_fire"; s.name = @"Gradient Fire";
            s.font = @"HelveticaNeue-Bold"; s.fontSize = 70; s.fontFace = @"Bold";
            s.textColor = [NSColor colorWithRed:1 green:0.6 blue:0.1 alpha:1];
            s.highlightColor = [NSColor colorWithRed:1 green:0.2 blue:0.1 alpha:1];
            s.outlineColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:1]; s.outlineWidth = 2;
            s.shadowColor = [NSColor colorWithRed:0.5 green:0.1 blue:0 alpha:0.8]; s.shadowBlurRadius = 6;
            s.position = SpliceKitCaptionPositionBottom;
            s.animation = SpliceKitCaptionAnimationPop; s.animationDuration = 0.2;
            s.allCaps = YES; s.wordByWordHighlight = YES;
            [list addObject:s];
        }

        // 6. Outline Bold — classic meme style
        {
            SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
            s.presetID = @"outline_bold"; s.name = @"Outline Bold";
            s.font = @"Impact"; s.fontSize = 76; s.fontFace = @"Regular";
            s.textColor = [NSColor whiteColor];
            s.highlightColor = [NSColor colorWithRed:1 green:1 blue:0 alpha:1];
            s.outlineColor = [NSColor blackColor]; s.outlineWidth = 4;
            s.shadowColor = nil; s.shadowBlurRadius = 0;
            s.position = SpliceKitCaptionPositionBottom;
            s.animation = SpliceKitCaptionAnimationNone; s.animationDuration = 0;
            s.allCaps = YES; s.wordByWordHighlight = YES;
            [list addObject:s];
        }

        // 7. Shadow Deep
        {
            SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
            s.presetID = @"shadow_deep"; s.name = @"Shadow Deep";
            s.font = @"Futura-Bold"; s.fontSize = 68; s.fontFace = @"Bold";
            s.textColor = [NSColor whiteColor];
            s.highlightColor = [NSColor colorWithRed:0.2 green:1 blue:0.4 alpha:1];
            s.outlineColor = nil; s.outlineWidth = 0;
            s.shadowColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:1]; s.shadowBlurRadius = 8;
            s.shadowOffsetX = 4; s.shadowOffsetY = 4;
            s.position = SpliceKitCaptionPositionBottom;
            s.animation = SpliceKitCaptionAnimationFade; s.animationDuration = 0.25;
            s.allCaps = NO; s.wordByWordHighlight = YES;
            [list addObject:s];
        }

        // 8. Karaoke — gray base, white highlight
        {
            SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
            s.presetID = @"karaoke"; s.name = @"Karaoke";
            s.font = @"GillSans-Bold"; s.fontSize = 66; s.fontFace = @"Bold";
            s.textColor = [NSColor colorWithRed:0.5 green:0.5 blue:0.5 alpha:1];
            s.highlightColor = [NSColor whiteColor];
            s.outlineColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:1]; s.outlineWidth = 2;
            s.shadowColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:0.6]; s.shadowBlurRadius = 4;
            s.position = SpliceKitCaptionPositionCenter;
            s.animation = SpliceKitCaptionAnimationNone; s.animationDuration = 0;
            s.allCaps = NO; s.wordByWordHighlight = YES;
            [list addObject:s];
        }

        // 9. Typewriter — terminal/code aesthetic
        {
            SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
            s.presetID = @"typewriter"; s.name = @"Typewriter";
            s.font = @"Courier-Bold"; s.fontSize = 54; s.fontFace = @"Bold";
            s.textColor = [NSColor colorWithRed:0.2 green:1 blue:0.2 alpha:1];
            s.highlightColor = [NSColor whiteColor];
            s.outlineColor = nil; s.outlineWidth = 0;
            s.shadowColor = nil; s.shadowBlurRadius = 0;
            s.backgroundColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:0.7];
            s.backgroundPadding = 6;
            s.position = SpliceKitCaptionPositionBottom;
            s.animation = SpliceKitCaptionAnimationTypewriter; s.animationDuration = 0;
            s.allCaps = NO; s.wordByWordHighlight = YES;
            [list addObject:s];
        }

        // 10. Bounce Fun
        {
            SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
            s.presetID = @"bounce_fun"; s.name = @"Bounce Fun";
            s.font = @"AvenirNext-Heavy"; s.fontSize = 72; s.fontFace = @"Heavy";
            s.textColor = [NSColor whiteColor];
            s.highlightColor = [NSColor colorWithRed:1 green:0.4 blue:0.7 alpha:1];
            s.outlineColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:1]; s.outlineWidth = 2;
            s.shadowColor = nil; s.shadowBlurRadius = 0;
            s.position = SpliceKitCaptionPositionBottom;
            s.animation = SpliceKitCaptionAnimationBounce; s.animationDuration = 0.3;
            s.allCaps = YES; s.wordByWordHighlight = YES;
            [list addObject:s];
        }

        // 11. Subtitle Pro — traditional, no word highlight
        {
            SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
            s.presetID = @"subtitle_pro"; s.name = @"Subtitle Pro";
            s.font = @"HelveticaNeue-Medium"; s.fontSize = 48; s.fontFace = @"Medium";
            s.textColor = [NSColor whiteColor];
            s.highlightColor = nil;
            s.outlineColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:1]; s.outlineWidth = 1.5;
            s.shadowColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:0.6]; s.shadowBlurRadius = 2;
            s.position = SpliceKitCaptionPositionBottom;
            s.animation = SpliceKitCaptionAnimationFade; s.animationDuration = 0.15;
            s.allCaps = NO; s.wordByWordHighlight = NO;
            [list addObject:s];
        }

        // 12. Social Bold — TikTok/Reels centered
        {
            SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
            s.presetID = @"social_bold"; s.name = @"Social Bold";
            s.font = @"HelveticaNeue-Bold"; s.fontSize = 80; s.fontFace = @"Bold";
            s.textColor = [NSColor whiteColor];
            s.highlightColor = [NSColor colorWithRed:1 green:0.9 blue:0 alpha:1];
            s.outlineColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:1]; s.outlineWidth = 3;
            s.shadowColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:0.9]; s.shadowBlurRadius = 5;
            s.position = SpliceKitCaptionPositionCenter;
            s.animation = SpliceKitCaptionAnimationPop; s.animationDuration = 0.2;
            s.allCaps = YES; s.wordByWordHighlight = YES;
            [list addObject:s];
        }

        // 13. Social Reels — optimized for 9:16 vertical short-form
        {
            SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
            s.presetID = @"social_reels"; s.name = @"Social Reels";
            s.font = @"HelveticaNeue-Bold"; s.fontSize = 100; s.fontFace = @"Bold";
            s.textColor = [NSColor whiteColor];
            s.highlightColor = [NSColor colorWithRed:1 green:0.9 blue:0 alpha:1];
            s.outlineColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:1]; s.outlineWidth = 4.0;
            s.shadowColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:0.9]; s.shadowBlurRadius = 6;
            s.backgroundColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:0.6];
            s.backgroundPadding = 8;
            s.position = SpliceKitCaptionPositionCenter;
            s.animation = SpliceKitCaptionAnimationPop; s.animationDuration = 0.15;
            s.allCaps = YES; s.wordByWordHighlight = YES;
            [list addObject:s];
        }

        presets = [list copy];
    });
    return presets;
}

+ (instancetype)presetWithID:(NSString *)presetID {
    for (SpliceKitCaptionStyle *s in [self builtInPresets]) {
        if ([s.presetID isEqualToString:presetID]) return [s copy];
    }
    return nil;
}

@end

#pragma mark - SpliceKitCaptionSegment

@implementation SpliceKitCaptionSegment

- (NSDictionary *)toDictionary {
    NSMutableArray *wordDicts = [NSMutableArray array];
    for (SpliceKitTranscriptWord *w in self.words) {
        [wordDicts addObject:@{
            @"text": w.text ?: @"",
            @"startTime": @(w.startTime),
            @"endTime": @(w.endTime),
            @"duration": @(w.duration),
        }];
    }
    return @{
        @"index": @(self.segmentIndex),
        @"text": self.text ?: @"",
        @"startTime": @(self.startTime),
        @"endTime": @(self.endTime),
        @"duration": @(self.duration),
        @"wordCount": @(self.words.count),
        @"words": wordDicts,
    };
}

@end
