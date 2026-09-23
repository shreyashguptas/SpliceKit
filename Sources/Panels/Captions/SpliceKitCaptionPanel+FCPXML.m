//
//  SpliceKitCaptionPanel+FCPXML.m
//  Caption FCPXML: timeline properties, per-segment title XML (plain and
//  word-progress), and the document header / footer.
//

#import "SpliceKitCaptionPanel+Private.h"

@implementation SpliceKitCaptionPanel (FCPXML)

#pragma mark - FCPXML Generation

- (void)detectTimelineProperties {
    // Detect frame rate and resolution from the active timeline
    id timelineModule = SpliceKit_getActiveTimelineModule();
    if (!timelineModule) {
        SpliceKit_log(@"[Captions] detectTimelineProperties: no active timeline module");
        return;
    }

    SEL seqSel = NSSelectorFromString(@"sequence");
    id sequence = ((id (*)(id, SEL))objc_msgSend)(timelineModule, seqSel);
    if (!sequence) {
        SpliceKit_log(@"[Captions] detectTimelineProperties: no sequence");
        return;
    }

    // Frame duration (a CMTime, returned in memory on x86_64: see STRET_MSG)
    SEL fdSel = NSSelectorFromString(@"sequenceFrameDuration");
    if ([timelineModule respondsToSelector:fdSel]) {
        @try {
            CMTime fd = ((CMTime (*)(id, SEL))STRET_MSG)(timelineModule, fdSel);
            SpliceKit_log(@"[Captions] Frame duration: %lld/%d", fd.value, fd.timescale);
            if (fd.timescale > 0 && fd.value > 0) {
                self.fdNum = (int)fd.value;
                self.fdDen = fd.timescale;
                self.frameRate = (double)fd.timescale / fd.value;
            }
        } @catch (NSException *e) {
            SpliceKit_log(@"[Captions] Exception getting frame duration: %@", e.reason);
        }
    }

    // Resolution — NSSize is 16 bytes (2 x double), fits in registers on ARM64
    SEL resSel = NSSelectorFromString(@"renderSize");
    if ([sequence respondsToSelector:resSel]) {
        @try {
#if defined(__arm64__)
            NSSize size = ((NSSize (*)(id, SEL))objc_msgSend)(sequence, resSel);
#else
            NSSize size;
            ((void (*)(NSSize *, id, SEL))objc_msgSend_stret)(&size, sequence, resSel);
#endif
            SpliceKit_log(@"[Captions] Render size: %.0f x %.0f", size.width, size.height);
            if (size.width > 0 && size.height > 0) {
                self.videoWidth = (int)size.width;
                self.videoHeight = (int)size.height;
            }
        } @catch (NSException *e) {
            SpliceKit_log(@"[Captions] Exception getting render size: %@", e.reason);
        }
    }

    SpliceKit_log(@"[Captions] Timeline: %dx%d @ %.2f fps (fd=%d/%d)",
                  self.videoWidth, self.videoHeight, self.frameRate, self.fdNum, self.fdDen);
}

- (NSString *)textStyleXMLWithID:(NSString *)tsID color:(NSColor *)color isHighlight:(BOOL)highlight {
    SpliceKitCaptionStyle *s = self.style;
    NSMutableString *xml = [NSMutableString string];
    [xml appendFormat:@"<text-style-def id=\"%@\"><text-style", tsID];

    // FCPXML requires font FAMILY names (e.g. "Futura"), not PostScript names ("Futura-Bold").
    // Using PostScript names causes FCP to fall back to Helvetica 6.0 defaults.
    // Resolve the family name from NSFont.
    NSString *fontName = s.font ?: @"Helvetica";
    NSFont *resolvedFont = [NSFont fontWithName:fontName size:s.fontSize];
    NSString *familyName = resolvedFont ? resolvedFont.familyName : fontName;
    // Strip any face suffix that might remain (e.g. "Futura-Bold" → "Futura")
    if ([familyName containsString:@"-"]) {
        familyName = [familyName componentsSeparatedByString:@"-"].firstObject;
    }

    [xml appendFormat:@" font=\"%@\"", SpliceKit_escapeXMLWithApostrophe(familyName)];
    [xml appendFormat:@" fontSize=\"%.0f\"", s.fontSize];
    [xml appendFormat:@" fontColor=\"%@\"", SpliceKitCaption_colorToFCPXML(color)];
    [xml appendString:@" alignment=\"center\""];
    [xml appendString:@"/></text-style-def>"];
    return xml;
}

// Content Position Y for the FCPXML <param> element (Motion template coordinate space).
// This is different from yOffsetForPosition which uses FFCutawayEffects transform space.
// The legacy template uses height * 0.7 for bottom position in this coordinate space.
- (CGFloat)contentPositionYForFCPXML {
    switch (self.style.position) {
        case SpliceKitCaptionPositionBottom: return -(self.videoHeight * 0.7);
        case SpliceKitCaptionPositionCenter: return 0;
        case SpliceKitCaptionPositionTop: return (self.videoHeight * 0.7);
        case SpliceKitCaptionPositionCustom: return self.style.customYOffset * 2.0;
    }
    return -(self.videoHeight * 0.7);
}

// Returns FCPXML <param> string for Content Position, or empty string for center.
- (NSString *)contentPositionParamXML {
    CGFloat y = [self contentPositionYForFCPXML];
    if (fabs(y) < 1.0) return @""; // center — no param needed
    return [NSString stringWithFormat:
        @"<param name=\"Content Position\" key=\"9999/10003/1/100/101\" value=\"0 %.0f\"/>\n", y];
}

#pragma mark - Word-Progress Caption Generation

// Compute Custom Speed keyframe XML for a segment's words.
// Progress = (i+1)/N, capped at 0.999. Hold keyframes during inter-word gaps.
- (NSString *)wordProgressKeyframesForSegment:(SpliceKitCaptionSegment *)seg {
    NSUInteger N = seg.words.count;
    if (N == 0) return @"";
    int fdN = self.fdNum, fdD = self.fdDen;
    NSMutableString *kf = [NSMutableString string];
    [kf appendString:@"<keyframeAnimation>\n"];

    // Initial keyframe at segment start
    [kf appendFormat:@"                                            "
        @"<keyframe time=\"%@\" value=\"0\" curve=\"linear\"/>\n",
        SpliceKitCaption_durRational(seg.startTime, fdN, fdD)];

    for (NSUInteger i = 0; i < N; i++) {
        SpliceKitTranscriptWord *w = seg.words[i];
        double progress = (i == N - 1) ? 0.999
            : MIN(floor((double)(i + 1) / (double)N * 1000.0) / 1000.0, 0.999);

        // Jump to this word's progress at word start
        [kf appendFormat:@"                                            "
            @"<keyframe time=\"%@\" value=\"%.3f\" curve=\"linear\"/>\n",
            SpliceKitCaption_durRational(w.startTime, fdN, fdD), progress];

        // Hold during silence gap before next word
        if (i < N - 1 && seg.words[i + 1].startTime - w.endTime > 0.01) {
            [kf appendFormat:@"                                            "
                @"<keyframe time=\"%@\" value=\"%.3f\" curve=\"linear\"/>\n",
                SpliceKitCaption_durRational(w.endTime, fdN, fdD), progress];
        }
    }
    [kf appendString:@"                                        </keyframeAnimation>"];
    return kf;
}

// Build a base64 JSON blob with per-word timing data for the legacy re-edit payload.
- (NSString *)wordProgressBase64ForSegment:(SpliceKitCaptionSegment *)seg {
    SpliceKitCaptionStyle *s = self.style;
    NSUInteger N = seg.words.count;
    if (N == 0) return @"";
    int fdN = self.fdNum, fdD = self.fdDen;

    NSMutableArray *wordDicts = [NSMutableArray arrayWithCapacity:N];
    for (NSUInteger i = 0; i < N; i++) {
        SpliceKitTranscriptWord *w = seg.words[i];
        double pct = (i == N - 1) ? 0.999
            : MIN(floor((double)(i + 1) / (double)N * 1000.0) / 1000.0, 0.999);
        [wordDicts addObject:@{
            @"Text": w.text ?: @"",
            @"StartTime": SpliceKitCaption_durRational(w.startTime, fdN, fdD),
            @"EndTime": SpliceKitCaption_durRational(w.endTime, fdN, fdD),
            @"RawStartTime": [NSString stringWithFormat:@"%d/100s", (int)round(w.startTime * 100)],
            @"RawEndTime": [NSString stringWithFormat:@"%d/100s", (int)round(w.endTime * 100)],
            @"Percent": [NSString stringWithFormat:@"%.6f", pct],
            @"Data": @{@"DashedWord": @"0", @"LastWordInSentence": @"0"},
        }];
    }

    NSString *fontName = s.font ?: @"Helvetica";
    NSFont *f = [NSFont fontWithName:fontName size:s.fontSize];
    NSString *family = f ? f.familyName : fontName;
    if ([family containsString:@"-"]) family = [family componentsSeparatedByString:@"-"].firstObject;

    NSDictionary *blob = @{
        @"Version": @1, @"Type": @"1", @"Language": @"english",
        @"StartTime": SpliceKitCaption_durRational(seg.startTime, fdN, fdD),
        @"Words": wordDicts,
        @"Style": @{
            @"TextSize": @((int)s.fontSize), @"FontFamily": family,
            @"FontName": fontName, @"FontFace": s.fontFace ?: @"Regular",
            @"FillColor": SpliceKitCaption_colorToFCPXML(s.textColor),
            @"StrokeColor": s.outlineColor ? SpliceKitCaption_colorToFCPXML(s.outlineColor) : @"",
            @"WordByWord": @YES, @"TemplateName": @"Basic Title",
            @"PositionY": @(-35), @"LineCount": @1, @"TextWidth": @0.6,
            @"Uppercase": @(s.allCaps), @"Lowercase": @NO,
            @"AnimationIn": @YES, @"AnimationOut": @YES, @"HidePunctuation": @NO,
        },
        @"Id": [NSString stringWithFormat:@"%.0f.%u",
                [[NSDate date] timeIntervalSince1970] * 1000, arc4random() % 1000],
    };

    NSData *json = [NSJSONSerialization dataWithJSONObject:blob
                                                  options:NSJSONWritingSortedKeys | NSJSONWritingPrettyPrinted
                                                    error:nil];
    return json ? [json base64EncodedStringWithOptions:0] : @"";
}

// Generate one <title> XML element with word-progress params.
// Only emits the 3 params used by the legacy word-progress title format
// (Position, Opacity, Custom Speed).
// All other behavior params (Animate=Word, highlight colors, etc.) are template defaults.
- (NSString *)wordProgressTitleXMLForSegment:(SpliceKitCaptionSegment *)seg
                                   tsCounter:(int *)tsCounter
                                      indent:(NSString *)indent
                                        lane:(NSString *)lane {
    SpliceKitCaptionStyle *s = self.style;
    int fdN = self.fdNum, fdD = self.fdDen;
    double segDur = MAX(seg.duration, 0.1);
    NSString *text = s.allCaps ? [seg.text uppercaseString] : seg.text;
    NSString *offsetStr = SpliceKitCaption_durRational(seg.startTime, fdN, fdD);
    NSString *durStr = SpliceKitCaption_durRational(segDur, fdN, fdD);

    // Position Y from the legacy moti height mapping (motiHeight * posY / 100)
    CGFloat posY = -756;  // default lower-third position matching the legacy template
    if (self.style.position == SpliceKitCaptionPositionCenter) posY = 0;
    else if (self.style.position == SpliceKitCaptionPositionTop) posY = 756;
    else if (self.style.position == SpliceKitCaptionPositionCustom) posY = self.style.customYOffset;

    // Resolve font
    NSString *fontName = s.font ?: @"Helvetica";
    NSFont *resolvedFont = [NSFont fontWithName:fontName size:s.fontSize];
    NSString *familyName = resolvedFont ? resolvedFont.familyName : fontName;
    if ([familyName containsString:@"-"]) familyName = [familyName componentsSeparatedByString:@"-"].firstObject;
    NSString *fontFace = s.fontFace ?: @"Regular";
    NSString *fontColorStr = SpliceKitCaption_colorToFCPXML(s.textColor);

    // Highlight color for strokeColor (template uses it for the glow effect)
    NSColor *hilite = s.highlightColor ?: [NSColor yellowColor];
    NSString *hiliteStr = SpliceKitCaption_colorToFCPXML(hilite);

    // Text style IDs
    int base = (*tsCounter);
    NSString *tsVis = [NSString stringWithFormat:@"ts%d", base];
    NSString *tsPunct = [NSString stringWithFormat:@"ts%d", base + 1];
    NSString *tsHidden = [NSString stringWithFormat:@"ts%d", base + 2];
    *tsCounter = base + 3;

    // Split trailing punctuation
    NSString *mainText = text, *punctText = @"";
    if (text.length > 1) {
        unichar last = [text characterAtIndex:text.length - 1];
        if (last == '.' || last == ',' || last == '!' || last == '?' || last == ';' || last == ':') {
            mainText = [text substringToIndex:text.length - 1];
            punctText = [text substringFromIndex:text.length - 1];
        }
    }

    // Keyframes and blob
    NSString *kfXML = [self wordProgressKeyframesForSegment:seg];
    NSString *b64 = [self wordProgressBase64ForSegment:seg];

    // Fade-out times
    double fadeStart = MAX(seg.endTime - kWP_FadeOutDuration, seg.startTime);
    NSString *fadeStartStr = SpliceKitCaption_durRational(fadeStart, fdN, fdD);
    NSString *fadeEndStr = SpliceKitCaption_durRational(seg.endTime, fdN, fdD);

    NSMutableString *xml = [NSMutableString string];
    NSString *laneAttr = lane ? [NSString stringWithFormat:@" lane=\"%@\"", lane] : @"";

    // <title> — use start="3600s" (FCP standard for Motion titles)
    [xml appendFormat:@"%@<title ref=\"r2\"%@ offset=\"%@\" name=\"%@\" duration=\"%@\" start=\"3600s\">\n",
        indent, laneAttr, offsetStr, SpliceKit_escapeXMLWithApostrophe(text), durStr];

    // Param 1: Content Position (in Motion template coordinate space)
    [xml appendFormat:@"%@    <param name=\"Content Position\" key=\"%@\" value=\"0 %.0f\"/>\n",
        indent, kWP_ContentPositionKey, posY];

    // Param 2: Content Opacity (fade-out at end)
    [xml appendFormat:@"%@    <param name=\"Content Opacity\" key=\"%@\">\n", indent, kWP_ContentOpacityKey];
    [xml appendFormat:@"%@        <keyframeAnimation>\n", indent];
    [xml appendFormat:@"%@            <keyframe time=\"%@\" value=\"1\" curve=\"linear\"/>\n", indent, fadeStartStr];
    [xml appendFormat:@"%@            <keyframe time=\"%@\" value=\"0\" curve=\"linear\"/>\n", indent, fadeEndStr];
    [xml appendFormat:@"%@        </keyframeAnimation>\n", indent];
    [xml appendFormat:@"%@    </param>\n", indent];

    // Param 3: Custom Speed (word-progress keyframes)
    [xml appendFormat:@"%@    <param name=\"Custom Speed\" key=\"%@\">\n", indent, kWP_CustomSpeedKey];
    [xml appendFormat:@"%@        %@\n", indent, kfXML];
    [xml appendFormat:@"%@    </param>\n", indent];

    // Visible text
    [xml appendFormat:@"%@    <text>\n", indent];
    [xml appendFormat:@"%@        <text-style ref=\"%@\">%@</text-style>\n",
        indent, tsVis, SpliceKit_escapeXMLWithApostrophe(mainText)];
    if (punctText.length > 0) {
        [xml appendFormat:@"%@        <text-style ref=\"%@\">%@</text-style>\n",
            indent, tsPunct, SpliceKit_escapeXMLWithApostrophe(punctText)];
    }
    [xml appendFormat:@"%@    </text>\n", indent];

    // Hidden text (base64 JSON blob for re-editing)
    if (b64.length > 0) {
        [xml appendFormat:@"%@    <text>\n", indent];
        [xml appendFormat:@"%@        <text-style ref=\"%@\">%@</text-style>\n", indent, tsHidden, b64];
        [xml appendFormat:@"%@    </text>\n", indent];
    }

    // Text style definitions
    [xml appendFormat:@"%@    <text-style-def id=\"%@\">\n", indent, tsVis];
    [xml appendFormat:@"%@        <text-style font=\"%@\" fontSize=\"%.0f\" fontFace=\"%@\" "
        @"fontColor=\"%@\" strokeColor=\"%@\" strokeWidth=\"0\" "
        @"shadowColor=\"0 0 0 0.1947\" kerning=\"-3.2\" alignment=\"center\">\n",
        indent, SpliceKit_escapeXMLWithApostrophe(familyName), s.fontSize, fontFace, fontColorStr, hiliteStr];
    [xml appendFormat:@"%@            <param name=\"MotionSimpleValues\" key=\"MotionTextStyle:SimpleValues\">\n", indent];
    [xml appendFormat:@"%@                <param name=\"motionTextTracking\" key=\"tracking\" value=\"-3.2\"/>\n", indent];
    [xml appendFormat:@"%@            </param>\n", indent];
    [xml appendFormat:@"%@        </text-style>\n", indent];
    [xml appendFormat:@"%@    </text-style-def>\n", indent];
    if (punctText.length > 0) {
        [xml appendFormat:@"%@    <text-style-def id=\"%@\">\n", indent, tsPunct];
        [xml appendFormat:@"%@        <text-style font=\"%@\" fontSize=\"%.0f\" fontFace=\"%@\" "
            @"fontColor=\"%@\" strokeColor=\"%@\" strokeWidth=\"0\" "
            @"shadowColor=\"0 0 0 0.1947\" alignment=\"center\"/>\n",
            indent, SpliceKit_escapeXMLWithApostrophe(familyName), s.fontSize, fontFace, fontColorStr, hiliteStr];
        [xml appendFormat:@"%@    </text-style-def>\n", indent];
    }
    if (b64.length > 0) {
        [xml appendFormat:@"%@    <text-style-def id=\"%@\">\n", indent, tsHidden];
        [xml appendFormat:@"%@        <text-style font=\"Saira\" fontSize=\"6\" fontFace=\"Regular\" "
            @"fontColor=\"0.946308 0.946308 1 1\" alignment=\"center\"/>\n", indent];
        [xml appendFormat:@"%@    </text-style-def>\n", indent];
    }

    [xml appendFormat:@"%@</title>\n", indent];
    return xml;
}

// Generate a single segment-level title with an explicit offset in the spine.
// This avoids spacer gaps and produces the same kind of compact connected
// storyline structure that FCP serializes for dragged/pasted title storylines.
- (NSString *)segmentTitleXMLForSegment:(SpliceKitCaptionSegment *)seg
                              tsCounter:(int *)tsCounter
                                 indent:(NSString *)indent
                                   lane:(NSString *)lane {
    SpliceKitCaptionStyle *s = self.style;
    int fdN = self.fdNum, fdD = self.fdDen;
    double segDur = MAX(seg.duration, 0.1);
    NSString *text = s.allCaps ? [seg.text uppercaseString] : seg.text;
    NSString *offsetStr = SpliceKitCaption_durRational(seg.startTime, fdN, fdD);
    NSString *durStr = SpliceKitCaption_durRational(segDur, fdN, fdD);
    NSString *tsID = [NSString stringWithFormat:@"ts%d", (*tsCounter)++];
    NSString *tsDef = [self textStyleXMLWithID:tsID color:s.textColor isHighlight:NO];
    NSString *laneAttr = lane ? [NSString stringWithFormat:@" lane=\"%@\"", lane] : @"";

    NSMutableString *xml = [NSMutableString string];
    [xml appendFormat:@"%@<title ref=\"r2\"%@ offset=\"%@\" name=\"Cap%03lu\" duration=\"%@\" start=\"3600s\">\n",
        indent, laneAttr, offsetStr, (unsigned long)seg.segmentIndex + 1, durStr];
    NSString *posParam = [self contentPositionParamXML];
    if (posParam.length > 0) [xml appendFormat:@"%@    %@", indent, posParam];
    [xml appendFormat:@"%@    <text><text-style ref=\"%@\">%@</text-style></text>\n",
        indent, tsID, SpliceKit_escapeXMLWithApostrophe(text)];
    [xml appendFormat:@"%@    %@\n", indent, tsDef];
    [xml appendFormat:@"%@</title>\n", indent];
    return xml;
}

#pragma mark - FCPXML Builder Helpers

// Build the FCPXML document skeleton (resources + opening tags).
// Returns the gap anchor's duration string for use in closing tags.
- (NSMutableString *)buildFCPXMLHeader:(NSString *)projectName
                          totalDuration:(double)totalDuration
                              titleCount:(int *)outTitleCount
                              tsCounter:(int *)outTsCounter {
    int fdN = self.fdNum, fdD = self.fdDen;
    NSString *fmtId = @"r1";

    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
    [xml appendString:@"<!DOCTYPE fcpxml>\n\n"];
    [xml appendString:@"<fcpxml version=\"1.11\">\n"];
    // Drag-compatible FCPXML: <spine> at root level, no library/event/project wrapper.
    // This format is accepted by FCP's proFFPasteboardUTI drag handler and
    // anchorWithPasteboard:, inserting directly as a connected storyline.
    [xml appendString:@"    <resources>\n"];
    [xml appendFormat:@"        <format id=\"%@\" name=\"FFVideoFormat%dx%dp%d\" "
        @"frameDuration=\"%d/%ds\" width=\"%d\" height=\"%d\"/>\n",
        fmtId, self.videoWidth, self.videoHeight, (int)round(self.frameRate),
        fdN, fdD, self.videoWidth, self.videoHeight];
    // Use FCP's built-in Basic Title — available on all installations.
    [xml appendString:@"        <effect id=\"r2\" name=\"Basic Title\" "
        @"uid=\".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti\"/>\n"];
    [xml appendString:@"    </resources>\n"];
    [xml appendString:@"    <spine>\n"];

    *outTitleCount = 0;
    *outTsCounter = 1;
    return xml;
}

- (void)appendFCPXMLFooter:(NSMutableString *)xml {
    // Close spine + fcpxml (drag format — no library/event/project wrapper)
    [xml appendString:@"    </spine>\n"];
    [xml appendString:@"</fcpxml>\n"];
}

// Build word-level FCPXML using the legacy word-progress approach:
// one title per segment with Custom Speed keyframes for word-by-word animation.
// Saved to /tmp for manual import / debugging.
- (NSString *)buildWordLevelFCPXML {
    int fdN = self.fdNum, fdD = self.fdDen;

    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
    [xml appendString:@"<!DOCTYPE fcpxml>\n\n"];
    [xml appendString:@"<fcpxml version=\"1.14\">\n"];
    [xml appendString:@"    <resources>\n"];
    [xml appendFormat:@"        <format id=\"r1\" name=\"FFVideoFormat%dx%dp%d\" "
        @"frameDuration=\"%d/%ds\" width=\"%d\" height=\"%d\"/>\n",
        self.videoWidth, self.videoHeight, (int)round(self.frameRate),
        fdN, fdD, self.videoWidth, self.videoHeight];
    [xml appendString:@"        <effect id=\"r2\" name=\"Basic Title\" "
        @"uid=\".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti\"/>\n"];
    [xml appendString:@"    </resources>\n"];
    [xml appendString:@"    <spine>\n"];

    int tsCounter = 1, titleCount = 0;
    for (SpliceKitCaptionSegment *seg in self.mutableSegments) {
        [xml appendString:[self wordProgressTitleXMLForSegment:seg
                                                    tsCounter:&tsCounter
                                                       indent:@"        "
                                                         lane:nil]];
        titleCount++;
    }

    [xml appendString:@"    </spine>\n"];
    [xml appendString:@"</fcpxml>\n"];

    SpliceKit_log(@"[Captions] Built word-progress FCPXML: %d titles, %lu bytes",
                  titleCount, (unsigned long)xml.length);
    return xml;
}

@end
