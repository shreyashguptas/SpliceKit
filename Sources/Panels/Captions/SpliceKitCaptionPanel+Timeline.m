//
//  SpliceKitCaptionPanel+Timeline.m
//  Putting the captions on the timeline as runtime titles: building FCP generator
//  objects and their attributed text / channels (word highlighting included), finding
//  existing caption storylines, and adding the caption storyline as connected titles.
//

#import "SpliceKitCaptionPanel+Private.h"

@implementation SpliceKitCaptionPanel (Timeline)

NSString *SpliceKitCaption_durRational(double seconds, int fdNum, int fdDen) {
    if (seconds <= 0) return @"0s";
    long long frames = (long long)round(seconds * fdDen / fdNum);
    if (frames <= 0) frames = 1;
    return [NSString stringWithFormat:@"%lld/%ds", frames * fdNum, fdDen];
}

static NSString *SpliceKitCaption_previewText(NSString *text, NSUInteger maxLength) {
    NSString *safe = text ?: @"";
    safe = [[safe stringByReplacingOccurrencesOfString:@"\n" withString:@" "]
        stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    if (safe.length <= maxLength) return safe;
    return [[safe substringToIndex:maxLength] stringByAppendingString:@"..."];
}

static NSString *SpliceKitCaption_formatCMTime(CMTime time) {
    if (time.timescale <= 0) return @"invalid";
    return [NSString stringWithFormat:@"%lld/%ds (%.4fs)",
            time.value, time.timescale, SpliceKit_secondsFromTime(time)];
}

static NSString *SpliceKitCaption_describeObject(id obj) {
    if (!obj) return @"(nil)";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:[NSString stringWithFormat:@"%@ %p",
                      NSStringFromClass([obj class]) ?: @"(unknown)",
                      obj]];

    @try {
        SEL displayNameSel = NSSelectorFromString(@"displayName");
        if ([obj respondsToSelector:displayNameSel]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(obj, displayNameSel);
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                [parts addObject:[NSString stringWithFormat:@"displayName=\"%@\"",
                                  SpliceKitCaption_previewText(value, 80)]];
            }
        }
    } @catch (NSException *e) {}

    @try {
        SEL nameSel = NSSelectorFromString(@"name");
        if ([obj respondsToSelector:nameSel]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(obj, nameSel);
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                [parts addObject:[NSString stringWithFormat:@"name=\"%@\"",
                                  SpliceKitCaption_previewText(value, 80)]];
            }
        }
    } @catch (NSException *e) {}

    return [parts componentsJoinedByString:@" "];
}

static void SpliceKitCaption_writeDataDebugFile(NSData *data, NSString *path, NSString *label) {
    if (!data || !path) return;
    NSError *writeError = nil;
    BOOL ok = [data writeToFile:path options:NSDataWritingAtomic error:&writeError];
    if (ok) {
        SpliceKit_log(@"[Captions][Debug] Wrote %@ (%lu bytes) to %@",
                      label, (unsigned long)data.length, path);
    } else {
        SpliceKit_log(@"[Captions][Debug] Failed to write %@ to %@: %@",
                      label, path, writeError.localizedDescription ?: @"unknown error");
    }
}

static void SpliceKitCaption_writeJSONDebugFile(id object, NSString *path, NSString *label) {
    if (!object || !path) return;
    if (![NSJSONSerialization isValidJSONObject:object]) {
        SpliceKit_log(@"[Captions][Debug] %@ JSON object invalid for %@", label, path);
        return;
    }
    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:object
                                                       options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                         error:&jsonError];
    if (!jsonData) {
        SpliceKit_log(@"[Captions][Debug] Failed to encode %@ JSON: %@",
                      label, jsonError.localizedDescription ?: @"unknown error");
        return;
    }
    SpliceKitCaption_writeDataDebugFile(jsonData, path, label);
}

static long long SpliceKitCaption_frameCountForSeconds(double seconds, int fdNum, int fdDen, BOOL allowZero) {
    int safeFdNum = MAX(fdNum, 1);
    int safeFdDen = MAX(fdDen, 1);
    long long frames = (long long)llround(seconds * safeFdDen / safeFdNum);
    if (!allowZero && seconds > 0 && frames <= 0) frames = 1;
    if (frames < 0) frames = 0;
    return frames;
}

static CMTime SpliceKitCaption_makeFrameAlignedCMTime(long long frames, int fdNum, int fdDen) {
    CMTime time;
    time.value = frames * MAX(fdNum, 1);
    time.timescale = MAX(fdDen, 1);
    time.flags = 1;
    time.epoch = 0;
    return time;
}

static id SpliceKitCaption_newGapComponent(CMTime duration, CMTime sampleDuration) {
    Class gapClass = objc_getClass("FFAnchoredGapGeneratorComponent");
    if (!gapClass) return nil;
    SEL gapSel = NSSelectorFromString(@"newGap:ofSampleDuration:");
    if (![gapClass respondsToSelector:gapSel]) return nil;
    return ((id (*)(id, SEL, CMTime, CMTime))objc_msgSend)(
        gapClass, gapSel, duration, sampleDuration);
}

static id SpliceKitCaption_findFirstChannelNode(id root, Class targetClass, NSString *targetName) {
    if (!root || !targetClass) return nil;

    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    SEL childSel = NSSelectorFromString(@"children");
    SEL nameSel = NSSelectorFromString(@"name");

    while (stack.count > 0) {
        id node = stack.lastObject;
        [stack removeLastObject];

        if ([node isKindOfClass:targetClass]) {
            if (!targetName) return node;
            @try {
                if ([node respondsToSelector:nameSel]) {
                    id name = ((id (*)(id, SEL))objc_msgSend)(node, nameSel);
                    if ([name isKindOfClass:[NSString class]] &&
                        [(NSString *)name isEqualToString:targetName]) {
                        return node;
                    }
                }
            } @catch (NSException *e) {}
        }

        @try {
            if ([node respondsToSelector:childSel]) {
                NSArray *children = ((id (*)(id, SEL))objc_msgSend)(node, childSel);
                if ([children isKindOfClass:[NSArray class]] && children.count > 0) {
                    [stack addObjectsFromArray:children];
                }
            }
        } @catch (NSException *e) {}
    }

    return nil;
}

static NSString *SpliceKitCaption_colorDebugString(NSColor *color) {
    if (![color isKindOfClass:[NSColor class]]) return @"(nil)";
    NSColor *rgb = [color colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
    if (!rgb) return color.description ?: @"(unconvertible)";
    return [NSString stringWithFormat:@"rgba(%.3f,%.3f,%.3f,%.3f)",
            rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent];
}

static NSString *SpliceKitCaption_fontDebugString(NSFont *font) {
    if (![font isKindOfClass:[NSFont class]]) return @"(nil)";
    return [NSString stringWithFormat:@"%@ %.1f",
            font.fontName ?: font.familyName ?: @"(unknown)", font.pointSize];
}

static NSUInteger SpliceKitCaption_attributedStringRunCount(NSAttributedString *attr) {
    if (![attr isKindOfClass:[NSAttributedString class]] || attr.length == 0) return 0;
    __block NSUInteger runCount = 0;
    [attr enumerateAttributesInRange:NSMakeRange(0, attr.length)
                             options:0
                          usingBlock:^(__unused NSDictionary<NSAttributedStringKey, id> *attrs,
                                       __unused NSRange range,
                                       __unused BOOL *stop) {
        runCount += 1;
    }];
    return runCount;
}

static NSString *SpliceKitCaption_attributedStringSummary(NSAttributedString *attr) {
    if (![attr isKindOfClass:[NSAttributedString class]] || attr.length == 0) return @"runs=0";

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    __block NSUInteger runIndex = 0;
    [attr enumerateAttributesInRange:NSMakeRange(0, attr.length)
                             options:0
                          usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs,
                                       NSRange range,
                                       BOOL *stop) {
        if (runIndex >= 6) {
            [parts addObject:@"..."];
            *stop = YES;
            return;
        }
        NSString *snippet = [[attr.string substringWithRange:range]
            stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
        if (snippet.length > 18) snippet = [[snippet substringToIndex:18] stringByAppendingString:@"..."];
        NSFont *font = attrs[NSFontAttributeName];
        NSColor *color = attrs[NSForegroundColorAttributeName];
        NSNumber *strokeWidth = attrs[NSStrokeWidthAttributeName];
        NSNumber *kern = attrs[NSKernAttributeName];
        [parts addObject:[NSString stringWithFormat:@"[%lu]{%@} font=%@ color=%@ stroke=%@ kern=%@ keys=%lu",
                          (unsigned long)range.location,
                          snippet ?: @"",
                          SpliceKitCaption_fontDebugString(font),
                          SpliceKitCaption_colorDebugString(color),
                          strokeWidth ?: @"(nil)",
                          kern ?: @"(nil)",
                          (unsigned long)attrs.count]];
        runIndex += 1;
    }];

    return [NSString stringWithFormat:@"runs=%lu %@",
            (unsigned long)SpliceKitCaption_attributedStringRunCount(attr),
            [parts componentsJoinedByString:@" | "]];
}

static id SpliceKitCaption_directTextChannelForEffect(id effect) {
    if (!effect) return nil;

    id textChannel = nil;
    SEL channelSel = NSSelectorFromString(@"channelForField:");
    if ([effect respondsToSelector:channelSel]) {
        @try {
            textChannel = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(effect, channelSel, 0);
        } @catch (__unused NSException *e) {}
    }

    Class textClass = objc_getClass("CHChannelText");
    if (textClass && [textChannel isKindOfClass:textClass]) {
        return textChannel;
    }

    SEL folderSel = NSSelectorFromString(@"channelFolder");
    if (![effect respondsToSelector:folderSel]) return nil;
    id channelFolder = ((id (*)(id, SEL))objc_msgSend)(effect, folderSel);
    if (!channelFolder) return nil;

    textChannel = SpliceKitCaption_findFirstChannelNode(channelFolder, textClass, @"Text");
    if (!textChannel) {
        textChannel = SpliceKitCaption_findFirstChannelNode(channelFolder, textClass, nil);
    }
    return textChannel;
}

BOOL SpliceKitCaption_usesWordHighlightRuntimeStyle(SpliceKitCaptionStyle *style) {
    return (style &&
            style.wordByWordHighlight &&
            [style.highlightColor isKindOfClass:[NSColor class]]);
}

static NSAttributedString *SpliceKitCaption_makeGeneratorAttributedString(NSString *text,
                                                                         SpliceKitCaptionStyle *style) {
    NSString *safeText = text ?: @"";
    NSColor *textColor = style.textColor ?: [NSColor whiteColor];
    NSString *fontName = style.font ?: @"Helvetica-Bold";
    CGFloat fontSize = style.fontSize > 0 ? style.fontSize : 72.0;
    NSFont *font = [NSFont fontWithName:fontName size:fontSize];
    if (!font) font = [NSFont boldSystemFontOfSize:fontSize];

    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = NSTextAlignmentCenter;
    paragraph.lineBreakMode = NSLineBreakByWordWrapping;

    NSDictionary *attrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: textColor,
        NSParagraphStyleAttributeName: paragraph,
    };
    return [[NSAttributedString alloc] initWithString:safeText attributes:attrs];
}

static NSMutableDictionary<NSAttributedStringKey, id> *SpliceKitCaption_generatorTextAttributes(SpliceKitCaptionStyle *style,
                                                                                                 NSColor *fillColor) {
    NSString *fontName = style.font ?: @"Helvetica-Bold";
    CGFloat fontSize = style.fontSize > 0 ? style.fontSize : 72.0;
    NSFont *font = [NSFont fontWithName:fontName size:fontSize];
    if (!font) font = [NSFont boldSystemFontOfSize:fontSize];

    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = NSTextAlignmentCenter;
    paragraph.lineBreakMode = NSLineBreakByWordWrapping;

    NSMutableDictionary<NSAttributedStringKey, id> *attrs = [@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: fillColor ?: [NSColor whiteColor],
        NSParagraphStyleAttributeName: paragraph,
        NSLigatureAttributeName: @0,
    } mutableCopy];

    if (SpliceKitCaption_usesWordHighlightRuntimeStyle(style)) {
        // Match the older word-progress generator more closely so runtime titles
        // keep the tighter, heavier-looking tracking the user expects.
        attrs[NSKernAttributeName] = @(-3.2);
    }

    if (style.outlineColor && style.outlineWidth > 0) {
        attrs[NSStrokeColorAttributeName] = style.outlineColor;
        // Negative width renders fill + stroke, which is what the preview and FCPXML path use.
        attrs[NSStrokeWidthAttributeName] = @(-style.outlineWidth);
    }

    if (style.shadowColor && style.shadowBlurRadius > 0) {
        NSShadow *shadow = [[NSShadow alloc] init];
        shadow.shadowColor = style.shadowColor;
        if (SpliceKitCaption_usesWordHighlightRuntimeStyle(style)) {
            shadow.shadowBlurRadius = 2.43;
            shadow.shadowOffset = NSMakeSize(3.54, -3.54);
        } else {
            shadow.shadowBlurRadius = style.shadowBlurRadius;
            shadow.shadowOffset = NSMakeSize(style.shadowOffsetX, -style.shadowOffsetY);
        }
        attrs[NSShadowAttributeName] = shadow;
    }

    return attrs;
}

NSAttributedString *SpliceKitCaption_makeHighlightedGeneratorAttributedStringFromWords(NSArray<NSString *> *displayWords,
                                                                                              NSUInteger activeWordIndex,
                                                                                              SpliceKitCaptionStyle *style) {
    if (![displayWords isKindOfClass:[NSArray class]] || displayWords.count == 0) {
        return SpliceKitCaption_makeGeneratorAttributedString(@"", style);
    }

    NSColor *baseColor = style.textColor ?: [NSColor whiteColor];
    NSColor *highlightColor = style.highlightColor ?: [NSColor yellowColor];

    NSDictionary *baseAttrs = SpliceKitCaption_generatorTextAttributes(style, baseColor);
    NSDictionary *highlightAttrs = SpliceKitCaption_generatorTextAttributes(style, highlightColor);

    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];
    for (NSUInteger i = 0; i < displayWords.count; i++) {
        NSString *wordText = [displayWords[i] isKindOfClass:[NSString class]] ? displayWords[i] : @"";
        if (i > 0) {
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:baseAttrs]];
        }
        NSDictionary *attrs = (i == activeWordIndex) ? highlightAttrs : baseAttrs;
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:wordText attributes:attrs]];
    }
    return result;
}

static NSAttributedString *SpliceKitCaption_effectFieldAttributedTextTemplate(id effect) {
    if (!effect) return nil;

    SEL getTextSel = NSSelectorFromString(@"textForField:");
    if (![effect respondsToSelector:getTextSel]) return nil;

    @try {
        id readBack = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(effect, getTextSel, 0);
        if ([readBack isKindOfClass:[NSAttributedString class]] &&
            [(NSAttributedString *)readBack length] > 0) {
            return readBack;
        }
    } @catch (__unused NSException *e) {}

    return nil;
}

static NSAttributedString *SpliceKitCaption_channelAttributedTextTemplate(id textChannel) {
    if (!textChannel) return nil;

    SEL attrSel = NSSelectorFromString(@"attributedString");
    if ([textChannel respondsToSelector:attrSel]) {
        @try {
            id attr = ((id (*)(id, SEL))objc_msgSend)(textChannel, attrSel);
            if ([attr isKindOfClass:[NSAttributedString class]] &&
                [(NSAttributedString *)attr length] > 0) {
                return attr;
            }
        } @catch (__unused NSException *e) {}
    }

    return nil;
}

static NSAttributedString *SpliceKitCaption_mergeAttributedTextWithTemplate(NSAttributedString *desired,
                                                                            NSAttributedString *template) {
    if (![desired isKindOfClass:[NSAttributedString class]] || desired.length == 0) return desired;
    if (![template isKindOfClass:[NSAttributedString class]] || template.length == 0) return desired;

    NSDictionary<NSAttributedStringKey, id> *templateAttrs =
        [template attributesAtIndex:0 effectiveRange:NULL];
    if (templateAttrs.count == 0) return desired;

    NSMutableAttributedString *merged = [[NSMutableAttributedString alloc] initWithString:desired.string];
    [desired enumerateAttributesInRange:NSMakeRange(0, desired.length)
                                options:0
                             usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs,
                                          NSRange range,
                                          __unused BOOL *stop) {
        NSMutableDictionary<NSAttributedStringKey, id> *runAttrs = [templateAttrs mutableCopy];
        if (attrs.count > 0) {
            [runAttrs addEntriesFromDictionary:attrs];
        }
        [merged setAttributes:runAttrs range:range];
    }];
    return merged;
}

static BOOL SpliceKitCaption_setGeneratorAttributedTextWithOptions(id generator,
                                                                   NSAttributedString *attr,
                                                                   BOOL saveDirty,
                                                                   BOOL allowChannelFallback) {
    if (!attr) return NO;
    SEL effectSel = NSSelectorFromString(@"effect");
    if (![generator respondsToSelector:effectSel]) return NO;
    id effect = ((id (*)(id, SEL))objc_msgSend)(generator, effectSel);
    if (!effect) return NO;

    SEL setTextSel = NSSelectorFromString(@"setText:forField:");
    SEL getTextSel = NSSelectorFromString(@"textForField:");
    SEL saveSel = NSSelectorFromString(@"saveDirtyTextToEffectValues");
    SEL normalizeSel = NSSelectorFromString(@"_newAttributedString:forField:");
    SEL wantsXMLSel = NSSelectorFromString(@"wantsXMLStyledText");
    SEL syncXMLSel = NSSelectorFromString(@"syncChannelStateForXMLExport");

    BOOL wantsXMLStyledText = NO;
    if ([effect respondsToSelector:wantsXMLSel]) {
        @try {
            wantsXMLStyledText = ((BOOL (*)(id, SEL))objc_msgSend)(effect, wantsXMLSel);
        } @catch (__unused NSException *e) {}
    }

    NSAttributedString *templateAttr = SpliceKitCaption_effectFieldAttributedTextTemplate(effect);
    if (templateAttr && SpliceKitCaption_attributedStringRunCount(templateAttr) > 0) {
        SpliceKit_log(@"[Captions][RuntimeTitle] Live effect template summary: %@",
                      SpliceKitCaption_attributedStringSummary(templateAttr));
    }
    NSAttributedString *mergedAttr = SpliceKitCaption_mergeAttributedTextWithTemplate(attr, templateAttr);

    if ([effect respondsToSelector:setTextSel]) {
        @try {
            NSAttributedString *attrToApply = mergedAttr ?: attr;
            NSUInteger inputRunCount = SpliceKitCaption_attributedStringRunCount(attrToApply);
            if (inputRunCount > 1) {
                SpliceKit_log(@"[Captions][RuntimeTitle] Applying attributed text summary: %@",
                              SpliceKitCaption_attributedStringSummary(attrToApply));
            }
            if ([effect respondsToSelector:normalizeSel]) {
                @try {
                    NSMutableAttributedString *mutableInput = [attrToApply mutableCopy];
                    id normalized = ((id (*)(id, SEL, id, NSUInteger))objc_msgSend)(effect, normalizeSel, mutableInput, 0);
                    if ([normalized isKindOfClass:[NSAttributedString class]] &&
                        [(NSAttributedString *)normalized length] > 0) {
                        attrToApply = normalized;
                        SpliceKit_log(@"[Captions][RuntimeTitle] _newAttributedString:forField: normalized attributed text=\"%@\"",
                                      SpliceKitCaption_previewText(attrToApply.string, 80));
                        NSUInteger normalizedRunCount = SpliceKitCaption_attributedStringRunCount(attrToApply);
                        if (normalizedRunCount > 1) {
                            SpliceKit_log(@"[Captions][RuntimeTitle] Normalized attributed text summary: %@",
                                          SpliceKitCaption_attributedStringSummary(attrToApply));
                        }
                    }
                } @catch (NSException *e) {
                    SpliceKit_log(@"[Captions][RuntimeTitle] _newAttributedString:forField: failed on %@: %@",
                                  SpliceKitCaption_describeObject(effect), e.reason);
                }
            }

            ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(effect, setTextSel, attrToApply, 0);

            NSString *readBackText = nil;
            if ([effect respondsToSelector:getTextSel]) {
                id readBack = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(effect, getTextSel, 0);
                if ([readBack isKindOfClass:[NSAttributedString class]]) {
                    readBackText = [(NSAttributedString *)readBack string];
                    NSUInteger readBackRunCount = SpliceKitCaption_attributedStringRunCount(readBack);
                    if (readBackRunCount > 1) {
                        SpliceKit_log(@"[Captions][RuntimeTitle] Read-back attributed text summary: %@",
                                      SpliceKitCaption_attributedStringSummary(readBack));
                    }
                } else if ([readBack isKindOfClass:[NSString class]]) {
                    readBackText = readBack;
                } else {
                    readBackText = [readBack description];
                }
            }
            SpliceKit_log(@"[Captions][RuntimeTitle] FFMotionEffect setText:forField: text=\"%@\" readBack=\"%@\"",
                          SpliceKitCaption_previewText(attrToApply.string, 80),
                          SpliceKitCaption_previewText(readBackText, 80));

            if (wantsXMLStyledText && [effect respondsToSelector:syncXMLSel]) {
                ((void (*)(id, SEL))objc_msgSend)(effect, syncXMLSel);
                SpliceKit_log(@"[Captions][RuntimeTitle] syncChannelStateForXMLExport completed after attributed text update");
            }

            if (saveDirty && [effect respondsToSelector:saveSel]) {
                ((void (*)(id, SEL))objc_msgSend)(effect, saveSel);
                SpliceKit_log(@"[Captions][RuntimeTitle] saveDirtyTextToEffectValues completed after attributed text update");
            }
            SpliceKitCaption_notifyEffectChannelChanged(effect, nil, NO);
            SpliceKitCaption_scheduleEffectTextRefreshPulses(effect, NO);
            return YES;
        } @catch (NSException *e) {
            SpliceKit_log(@"[Captions][RuntimeTitle] setText:forField: failed on %@: %@",
                          SpliceKitCaption_describeObject(effect), e.reason);
        }
    }

    id textChannel = allowChannelFallback ? SpliceKitCaption_directTextChannelForEffect(effect) : nil;
    SEL setAttrSel = NSSelectorFromString(@"setAttributedString:");
    SEL strSel = NSSelectorFromString(@"string");
    if (textChannel && [textChannel respondsToSelector:setAttrSel]) {
        @try {
            NSAttributedString *channelTemplateAttr = SpliceKitCaption_channelAttributedTextTemplate(textChannel);
            NSAttributedString *channelAttr = SpliceKitCaption_mergeAttributedTextWithTemplate(
                mergedAttr ?: attr, channelTemplateAttr);
            NSUInteger inputRunCount = SpliceKitCaption_attributedStringRunCount(channelAttr);
            if (inputRunCount > 1) {
                SpliceKit_log(@"[Captions][RuntimeTitle] Applying CHChannelText attributed summary: %@",
                              SpliceKitCaption_attributedStringSummary(channelAttr));
            }
            ((void (*)(id, SEL, id))objc_msgSend)(textChannel, setAttrSel, channelAttr);

            id readBack = nil;
            if ([textChannel respondsToSelector:strSel]) {
                readBack = ((id (*)(id, SEL))objc_msgSend)(textChannel, strSel);
            }
            SpliceKit_log(@"[Captions][RuntimeTitle] CHChannelText %@ setAttributedString text=\"%@\" readBack=\"%@\"",
                          SpliceKitCaption_describeObject(textChannel),
                          SpliceKitCaption_previewText(channelAttr.string, 80),
                          SpliceKitCaption_previewText([readBack description], 80));

            if (wantsXMLStyledText && [effect respondsToSelector:syncXMLSel]) {
                ((void (*)(id, SEL))objc_msgSend)(effect, syncXMLSel);
                SpliceKit_log(@"[Captions][RuntimeTitle] syncChannelStateForXMLExport completed after CHChannelText update");
            }

            if (saveDirty && [effect respondsToSelector:saveSel]) {
                ((void (*)(id, SEL))objc_msgSend)(effect, saveSel);
                SpliceKit_log(@"[Captions][RuntimeTitle] saveDirtyTextToEffectValues completed after CHChannelText update");
            }
            if ([effect respondsToSelector:getTextSel]) {
                id effectReadBack = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(effect, getTextSel, 0);
                if ([effectReadBack isKindOfClass:[NSAttributedString class]]) {
                    SpliceKit_log(@"[Captions][RuntimeTitle] Effect read-back after CHChannelText update: %@",
                                  SpliceKitCaption_attributedStringSummary(effectReadBack));
                } else if (effectReadBack) {
                    SpliceKit_log(@"[Captions][RuntimeTitle] Effect read-back after CHChannelText update: %@",
                                  SpliceKitCaption_previewText([effectReadBack description], 120));
                }
            }
            SpliceKitCaption_notifyEffectChannelChanged(effect, textChannel, NO);
            SpliceKitCaption_scheduleEffectTextRefreshPulses(effect, NO);
            return YES;
        } @catch (NSException *e) {
            SpliceKit_log(@"[Captions][RuntimeTitle] CHChannelText setAttributedString failed on %@: %@",
                          SpliceKitCaption_describeObject(textChannel), e.reason);
        }
    }

    return NO;
}

static BOOL SpliceKitCaption_setGeneratorAttributedText(id generator,
                                                        NSAttributedString *attr) {
    return SpliceKitCaption_setGeneratorAttributedTextWithOptions(generator, attr, YES, YES);
}

BOOL SpliceKitCaption_setGeneratorAttributedTextForPersistedRepair(id generator,
                                                                          NSAttributedString *attr) {
    // Relaunch repair must commit the effect-level text field state or the viewer
    // can continue rendering the template placeholder even when read-back looks correct.
    // Keep the low-level channel fallback disabled here to avoid the launch crash.
    return SpliceKitCaption_setGeneratorAttributedTextWithOptions(generator, attr, YES, NO);
}

static void SpliceKitCaption_notifyEffectChannelChanged(id effect,
                                                        id channel,
                                                        BOOL rebuildAllTextFromCurrentStringState) {
    if (!effect) return;

    SEL changedSel = NSSelectorFromString(@"channelParameterChanged:");
    SEL rebuildSel = NSSelectorFromString(@"_rebuildAllTextFromCurrentStringChannelState");
    SEL channelsChangedSel = NSSelectorFromString(@"_channelsChanged");
    SEL userInfoSel = NSSelectorFromString(@"userInfo");

    @try {
        if (channel && [effect respondsToSelector:changedSel] && [channel respondsToSelector:userInfoSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(effect, changedSel, channel);
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[Captions][RuntimeTitle] channelParameterChanged failed on %@: %@",
                      SpliceKitCaption_describeObject(effect), e.reason);
    }

    @try {
        if (rebuildAllTextFromCurrentStringState && [effect respondsToSelector:rebuildSel]) {
            ((void (*)(id, SEL))objc_msgSend)(effect, rebuildSel);
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[Captions][RuntimeTitle] _rebuildAllTextFromCurrentStringChannelState failed on %@: %@",
                      SpliceKitCaption_describeObject(effect), e.reason);
    }

    @try {
        if ([effect respondsToSelector:channelsChangedSel]) {
            ((void (*)(id, SEL))objc_msgSend)(effect, channelsChangedSel);
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[Captions][RuntimeTitle] _channelsChanged failed on %@: %@",
                      SpliceKitCaption_describeObject(effect), e.reason);
    }
}

static void SpliceKitCaption_scheduleEffectTextRefreshPulses(id effect,
                                                             BOOL rebuildAllTextFromCurrentStringState) {
    if (!effect) return;
    NSArray<NSNumber *> *delays = @[ @0.2, @0.75, @1.5 ];
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SpliceKitCaption_notifyEffectChannelChanged(effect, nil, rebuildAllTextFromCurrentStringState);
        });
    }
}

static BOOL SpliceKitCaption_setGeneratorChannelText(id generator,
                                                     NSString *text,
                                                     SpliceKitCaptionStyle *style) {
    NSAttributedString *attr = SpliceKitCaption_makeGeneratorAttributedString(text, style);
    return SpliceKitCaption_setGeneratorAttributedText(generator, attr);
}

BOOL SpliceKitCaption_setGeneratorTextFields(id generator,
                                                    NSArray<NSString *> *fields,
                                                    BOOL notifyChange) {
    SpliceKit_log(@"[Captions][RuntimeTitle] Configuring generator text fields: generator=%@ fields=%@",
                  SpliceKitCaption_describeObject(generator), fields ?: @[]);
    if (!generator) {
        SpliceKit_log(@"[Captions] runtime title text setup skipped: generator missing");
        return NO;
    }
    SEL effectSel = NSSelectorFromString(@"effect");
    if (![generator respondsToSelector:effectSel]) {
        SpliceKit_log(@"[Captions] runtime title generator has no effect selector");
        return NO;
    }
    id effect = ((id (*)(id, SEL))objc_msgSend)(generator, effectSel);
    if (!effect) {
        SpliceKit_log(@"[Captions] runtime title generator effect is nil");
        return NO;
    }
    SpliceKit_log(@"[Captions][RuntimeTitle] effect=%@", SpliceKitCaption_describeObject(effect));

    SEL countSel = NSSelectorFromString(@"textFieldCount");
    SEL setTextSel = NSSelectorFromString(@"setTextString:forField:");
    SEL getTextSel = NSSelectorFromString(@"stringForField:");
    if (![effect respondsToSelector:countSel] || ![effect respondsToSelector:setTextSel]) {
        SpliceKit_log(@"[Captions] runtime title effect text selectors missing on %@",
                      NSStringFromClass([effect class]));
        return NO;
    }

    NSUInteger fieldCount = ((NSUInteger (*)(id, SEL))objc_msgSend)(effect, countSel);
    SpliceKit_log(@"[Captions][RuntimeTitle] textFieldCount=%lu stringForField=%@ saveDirtyTextToEffectValues=%@",
                  (unsigned long)fieldCount,
                  [effect respondsToSelector:getTextSel] ? @"YES" : @"NO",
                  [effect respondsToSelector:NSSelectorFromString(@"saveDirtyTextToEffectValues")] ? @"YES" : @"NO");
    if (fieldCount == 0) {
        SpliceKit_log(@"[Captions] runtime title effect reports zero text fields during generator creation; deferring CHChannelText update until post-paste");
        return NO;
    }

    NSUInteger applied = 0;
    for (NSUInteger i = 0; i < fieldCount; i++) {
        NSString *value = (i < fields.count) ? fields[i] : @"";
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(effect, setTextSel, value ?: @"", i);
        if ([effect respondsToSelector:getTextSel]) {
            id readBack = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(effect, getTextSel, i);
            SpliceKit_log(@"[Captions][RuntimeTitle] field[%lu] set=\"%@\" readBack=\"%@\"",
                          (unsigned long)i,
                          SpliceKitCaption_previewText(value, 80),
                          SpliceKitCaption_previewText([readBack description], 80));
        } else {
            SpliceKit_log(@"[Captions][RuntimeTitle] field[%lu] set=\"%@\"",
                          (unsigned long)i,
                          SpliceKitCaption_previewText(value, 80));
        }
        applied++;
    }

    SEL saveSel = NSSelectorFromString(@"saveDirtyTextToEffectValues");
    if ([effect respondsToSelector:saveSel]) {
        ((void (*)(id, SEL))objc_msgSend)(effect, saveSel);
        SpliceKit_log(@"[Captions][RuntimeTitle] saveDirtyTextToEffectValues completed");
    }

    if (notifyChange) {
        // Do not resolve CHChannel wrappers here. During relaunch the effect can
        // expose text fields before ProChannel has wired the OZChannel wrappers.
        SpliceKitCaption_notifyEffectChannelChanged(effect, nil, YES);
        SpliceKitCaption_scheduleEffectTextRefreshPulses(effect, YES);
    }

    return (applied > 0);
}

static id SpliceKitCaption_newRuntimeCaptionGenerator(NSString *text,
                                                      SpliceKitCaptionStyle *style,
                                                      int fdNum,
                                                      int fdDen,
                                                      long long durationFrames) {
    Class genClass = objc_getClass("FFAnchoredGeneratorComponent");
    if (!genClass) {
        SpliceKit_log(@"[Captions][RuntimeTitle] FFAnchoredGeneratorComponent class missing");
        return nil;
    }

    SEL createSel = NSSelectorFromString(@"newGeneratorForEffectIDContainingSubstring:duration:sampleDuration:");
    if (![genClass respondsToSelector:createSel]) {
        SpliceKit_log(@"[Captions][RuntimeTitle] Generator create selector missing on %@",
                      NSStringFromClass(genClass));
        return nil;
    }

    CMTime sampleDuration = SpliceKitCaption_makeFrameAlignedCMTime(1, fdNum, fdDen);
    CMTime duration = SpliceKitCaption_makeFrameAlignedCMTime(MAX(durationFrames, 1), fdNum, fdDen);
    SpliceKit_log(@"[Captions][RuntimeTitle] Requesting generator template=\"%@\" text=\"%@\" durationFrames=%lld duration=%@ sample=%@",
                  kSpliceKitRuntimeCaptionTemplateMatch,
                  SpliceKitCaption_previewText(text, 100),
                  durationFrames,
                  SpliceKitCaption_formatCMTime(duration),
                  SpliceKitCaption_formatCMTime(sampleDuration));
    id generator = nil;
    @try {
        generator = ((id (*)(id, SEL, id, CMTime, CMTime))objc_msgSend)(
            genClass, createSel, kSpliceKitRuntimeCaptionTemplateMatch, duration, sampleDuration);
    } @catch (NSException *e) {
        SpliceKit_log(@"[Captions][RuntimeTitle] Generator creation threw: %@\n%@",
                      e.reason, [[e callStackSymbols] componentsJoinedByString:@"\n"]);
        return nil;
    }
    SpliceKit_log(@"[Captions][RuntimeTitle] Generator result=%@", SpliceKitCaption_describeObject(generator));
    if (!generator) return nil;

    NSArray<NSString *> *fields = @[text ?: @""];
    BOOL shouldSkipInitialTextSetup = (style.wordByWordHighlight && style.highlightColor != nil);
    if (shouldSkipInitialTextSetup) {
        SpliceKit_log(@"[Captions][RuntimeTitle] Skipping initial plain text setup for word-highlight generator=%@",
                      SpliceKitCaption_describeObject(generator));
    } else if (!SpliceKitCaption_setGeneratorTextFields(generator, fields, YES)) {
        SpliceKit_log(@"[Captions] Continuing with runtime title generator despite text setup failure");
    }
    return generator;
}

static id SpliceKitCaption_primaryObjectForSequence(id sequence) {
    if (!sequence) return nil;
    SEL primarySel = NSSelectorFromString(@"primaryObject");
    if (![sequence respondsToSelector:primarySel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(sequence, primarySel);
}

static NSUInteger SpliceKitCaption_removeExistingCaptionStorylines(id sequence, NSString *storylineName) {
    id primary = SpliceKitCaption_primaryObjectForSequence(sequence);
    if (!primary) return 0;

    SEL itemsSel = NSSelectorFromString(@"containedItems");
    NSArray *items = [primary respondsToSelector:itemsSel]
        ? ((id (*)(id, SEL))objc_msgSend)(primary, itemsSel)
        : nil;
    if (![items isKindOfClass:[NSArray class]] || items.count == 0) return 0;

    NSUInteger removed = 0;
    SEL anchoredSel = NSSelectorFromString(@"anchoredItems");
    SEL displayNameSel = NSSelectorFromString(@"displayName");
    SEL removeAnchoredItemsSel = NSSelectorFromString(@"removeAnchoredItemsObject:");
    SEL removeAnchoredSel = NSSelectorFromString(@"removeAnchoredObject:");

    for (id item in items) {
        if (![item respondsToSelector:anchoredSel]) continue;
        id anchoredRaw = ((id (*)(id, SEL))objc_msgSend)(item, anchoredSel);
        NSArray *anchored = nil;
        if ([anchoredRaw isKindOfClass:[NSSet class]]) {
            anchored = [(NSSet *)anchoredRaw allObjects];
        } else if ([anchoredRaw isKindOfClass:[NSArray class]]) {
            anchored = anchoredRaw;
        }
        if (anchored.count == 0) continue;

        for (id anchoredObject in anchored) {
            NSString *className = NSStringFromClass([anchoredObject class]) ?: @"";
            if (![className containsString:@"Collection"]) continue;

            NSString *displayName = nil;
            @try {
                if ([anchoredObject respondsToSelector:displayNameSel]) {
                    id name = ((id (*)(id, SEL))objc_msgSend)(anchoredObject, displayNameSel);
                    if ([name isKindOfClass:[NSString class]]) displayName = name;
                }
            } @catch (NSException *e) {}

            if (storylineName.length > 0 && ![displayName isEqualToString:storylineName]) continue;

            if ([item respondsToSelector:removeAnchoredItemsSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(item, removeAnchoredItemsSel, anchoredObject);
                removed++;
            } else if ([item respondsToSelector:removeAnchoredSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(item, removeAnchoredSel, anchoredObject);
                removed++;
            }
        }
    }

    return removed;
}

static BOOL SpliceKitCaption_isGeneratorTitleObject(id obj);

static BOOL SpliceKitCaption_storylineNameMatches(NSString *displayName) {
    if (displayName.length == 0) return NO;
    return [displayName isEqualToString:kSpliceKitCaptionStorylineName] ||
           [displayName isEqualToString:SpliceKitLegacyCaptionStorylineName()];
}

static BOOL SpliceKitCaption_effectiveRangeForObject(id primary,
                                                     id object,
                                                     double *startOut,
                                                     double *endOut) {
    if (startOut) *startOut = 0.0;
    if (endOut) *endOut = 0.0;
    if (!primary || !object) return NO;

    SEL rangeSel = NSSelectorFromString(@"effectiveRangeOfObject:");
    if (![primary respondsToSelector:rangeSel]) return NO;

    @try {
        CMTimeRange range =
            ((CMTimeRange (*)(id, SEL, id))STRET_MSG)(primary, rangeSel, object);
        if (range.start.timescale <= 0 || range.duration.timescale <= 0) return NO;
        double start = (double)range.start.value / (double)range.start.timescale;
        double duration = (double)range.duration.value / (double)range.duration.timescale;
        if (startOut) *startOut = start;
        if (endOut) *endOut = start + duration;
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

NSArray *SpliceKitCaption_collectTitlesForPersistedStorylines(id sequence) {
    id primary = SpliceKitCaption_primaryObjectForSequence(sequence);
    if (!primary) return @[];

    SEL itemsSel = NSSelectorFromString(@"containedItems");
    NSArray *items = [primary respondsToSelector:itemsSel]
        ? ((id (*)(id, SEL))objc_msgSend)(primary, itemsSel)
        : nil;
    if (![items isKindOfClass:[NSArray class]] || items.count == 0) return @[];

    SEL anchoredSel = NSSelectorFromString(@"anchoredItems");
    SEL displayNameSel = NSSelectorFromString(@"displayName");
    SEL containedSel = NSSelectorFromString(@"containedItems");
    NSMutableSet *seenTitles = [NSMutableSet set];
    NSMutableArray *titles = [NSMutableArray array];

    for (id item in items) {
        if (![item respondsToSelector:anchoredSel]) continue;
        id anchoredRaw = ((id (*)(id, SEL))objc_msgSend)(item, anchoredSel);
        NSArray *anchored = nil;
        if ([anchoredRaw isKindOfClass:[NSSet class]]) {
            anchored = [(NSSet *)anchoredRaw allObjects];
        } else if ([anchoredRaw isKindOfClass:[NSArray class]]) {
            anchored = anchoredRaw;
        }
        if (anchored.count == 0) continue;

        for (id anchoredObject in anchored) {
            NSString *displayName = nil;
            @try {
                if ([anchoredObject respondsToSelector:displayNameSel]) {
                    id name = ((id (*)(id, SEL))objc_msgSend)(anchoredObject, displayNameSel);
                    if ([name isKindOfClass:[NSString class]]) displayName = name;
                }
            } @catch (NSException *e) {}
            if (!SpliceKitCaption_storylineNameMatches(displayName)) continue;

            if ([anchoredObject respondsToSelector:containedSel]) {
                NSArray *contained = ((id (*)(id, SEL))objc_msgSend)(anchoredObject, containedSel);
                if (![contained isKindOfClass:[NSArray class]]) continue;
                for (id sub in contained) {
                    if (SpliceKitCaption_isGeneratorTitleObject(sub) &&
                        ![seenTitles containsObject:sub]) {
                        [seenTitles addObject:sub];
                        [titles addObject:sub];
                    }
                }
            } else if (SpliceKitCaption_isGeneratorTitleObject(anchoredObject) &&
                       ![seenTitles containsObject:anchoredObject]) {
                [seenTitles addObject:anchoredObject];
                [titles addObject:anchoredObject];
            }
        }
    }

    if (titles.count > 1) {
        [titles sortUsingComparator:^NSComparisonResult(id a, id b) {
            double aStart = 0.0, aEnd = 0.0, bStart = 0.0, bEnd = 0.0;
            BOOL hasARange = SpliceKitCaption_effectiveRangeForObject(primary, a, &aStart, &aEnd);
            BOOL hasBRange = SpliceKitCaption_effectiveRangeForObject(primary, b, &bStart, &bEnd);
            if (hasARange && hasBRange) {
                if (aStart < bStart) return NSOrderedAscending;
                if (aStart > bStart) return NSOrderedDescending;
                if (aEnd < bEnd) return NSOrderedAscending;
                if (aEnd > bEnd) return NSOrderedDescending;
            } else if (hasARange) {
                return NSOrderedAscending;
            } else if (hasBRange) {
                return NSOrderedDescending;
            }
            uintptr_t aPtr = (uintptr_t)(__bridge void *)a;
            uintptr_t bPtr = (uintptr_t)(__bridge void *)b;
            if (aPtr < bPtr) return NSOrderedAscending;
            if (aPtr > bPtr) return NSOrderedDescending;
            return NSOrderedSame;
        }];
    }

    return titles;
}

static BOOL SpliceKitCaption_isGeneratorTitleObject(id obj) {
    if (!obj) return NO;
    NSString *className = NSStringFromClass([obj class]) ?: @"";
    if ([className containsString:@"Gap"]) return NO;
    if ([className containsString:@"Generator"]) return YES;
    SEL effectSel = NSSelectorFromString(@"effect");
    if ([obj respondsToSelector:effectSel]) {
        id effect = ((id (*)(id, SEL))objc_msgSend)(obj, effectSel);
        return (effect != nil);
    }
    return NO;
}

static BOOL SpliceKitCaption_setChannelDouble(id channel, double value) {
    if (!channel) return NO;
    @try {
        CMTime t = {0, 0, 17, 0}; // kCMTimeIndefinite
        SEL setSel = NSSelectorFromString(@"setCurveDoubleValue:atTime:options:");
        if ([channel respondsToSelector:setSel]) {
            ((void (*)(id, SEL, double, CMTime, unsigned int))objc_msgSend)(
                channel, setSel, value, t, 0);
            return YES;
        }
    } @catch (NSException *e) {
    }
    return NO;
}

static id SpliceKitCaption_subChannel(id parentChannel, NSString *axis) {
    if (!parentChannel) return nil;
    NSString *selectorName = [NSString stringWithFormat:@"%@Channel", axis];
    SEL selector = NSSelectorFromString(selectorName);
    if (![parentChannel respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(parentChannel, selector);
}

BOOL SpliceKitCaption_applyGeneratorPositionYOffset(id titleObject, CGFloat yOffset) {
    if (!titleObject) return NO;

    @try {
        SEL effectSel = NSSelectorFromString(@"effect");
        id effect = [titleObject respondsToSelector:effectSel]
            ? ((id (*)(id, SEL))objc_msgSend)(titleObject, effectSel)
            : nil;
        id channelFolder = effect ? ((id (*)(id, SEL))objc_msgSend)(effect, NSSelectorFromString(@"channelFolder")) : nil;
        if (!channelFolder) return NO;

        Class pos3DClass = objc_getClass("CHChannelPosition3D");
        NSMutableArray *stack = [NSMutableArray arrayWithObject:channelFolder];
        while (stack.count > 0) {
            id node = stack.lastObject;
            [stack removeLastObject];
            if (pos3DClass && [node isKindOfClass:pos3DClass]) {
                NSString *name = ((id (*)(id, SEL))objc_msgSend)(node, NSSelectorFromString(@"name"));
                if ([name isEqualToString:@"Position"]) {
                    id parent = [node respondsToSelector:NSSelectorFromString(@"parent")]
                        ? ((id (*)(id, SEL))objc_msgSend)(node, NSSelectorFromString(@"parent")) : nil;
                    NSString *parentName = parent
                        ? ((id (*)(id, SEL))objc_msgSend)(parent, NSSelectorFromString(@"name")) : nil;
                    if ([parentName isEqualToString:@"Transform"]) {
                        id yChannel = SpliceKitCaption_subChannel(node, @"y");
                        return yChannel ? SpliceKitCaption_setChannelDouble(yChannel, yOffset) : NO;
                    }
                }
            }

            SEL childSel = NSSelectorFromString(@"children");
            if ([node respondsToSelector:childSel]) {
                NSArray *children = ((id (*)(id, SEL))objc_msgSend)(node, childSel);
                if ([children isKindOfClass:[NSArray class]]) {
                    [stack addObjectsFromArray:children];
                }
            }
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[Captions] Failed to restore generator position: %@", e.reason);
    }

    return NO;
}

// Legacy-style import: generate FCPXML with all captions as connected titles
// inside a single gap (lane 1), import via FFXMLTranslationTask, then copy/paste
// the entire connected storyline onto the user's timeline in one shot.

NSString *const kCaptionImportProjectPrefix = @"SpliceKit Caption Import";

// Enumerate all sequences in the active library. Must be called on main thread.
NSArray *SpliceKitCaption_allSequences(void) {
    id activeLibs = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("FFLibraryDocument"), NSSelectorFromString(@"copyActiveLibraries"));
    if (!activeLibs || [(NSArray *)activeLibs count] == 0) return @[];
    id library = [(NSArray *)activeLibs objectAtIndex:0];
    id seqSet = ((id (*)(id, SEL))objc_msgSend)(library,
        NSSelectorFromString(@"_deepLoadedSequences"));
    return ((id (*)(id, SEL))objc_msgSend)(seqSet, NSSelectorFromString(@"allObjects")) ?: @[];
}

id SpliceKitCaption_findSequenceByPrefix(NSString *prefix) {
    for (id seq in SpliceKitCaption_allSequences()) {
        NSString *seqName = ((id (*)(id, SEL))objc_msgSend)(seq,
            NSSelectorFromString(@"displayName"));
        if ([seqName hasPrefix:prefix]) return seq;
    }
    return nil;
}

id SpliceKitCaption_currentSequence(void) {
    id tm = SpliceKit_getActiveTimelineModule();
    if (!tm) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(tm, NSSelectorFromString(@"sequence"));
}

BOOL SpliceKitCaption_deleteSequence(id sequence) {
    return SpliceKit_deleteSequenceLibraryItem(sequence);
}

BOOL SpliceKitCaption_pollMainThread(BOOL (^condition)(void), double timeoutSec, double intervalSec) {
    double elapsed = 0;
    while (elapsed < timeoutSec) {
        __block BOOL result = NO;
        SpliceKit_executeOnMainThread(^{ result = condition(); });
        if (result) return YES;
        [NSThread sleepForTimeInterval:intervalSec];
        elapsed += intervalSec;
    }
    return NO;
}

- (NSDictionary *)addCaptionTitlesDirectlyToTimeline {
    // Native pasteboard insertion modeled on the earlier caption workflow:
    // build a real FFAnchoredCollection storyline containing generator and gap
    // components, archive it to proFFPasteboardUTI, then pasteAnchored: it.

    SpliceKitCaptionStyle *s = self.style;
    int fdN = self.fdNum, fdD = self.fdDen;

    // Verify a timeline is open
    __block BOOL hasTimeline = NO;
    SpliceKit_executeOnMainThread(^{
        hasTimeline = (SpliceKit_getActiveTimelineModule() != nil);
    });
    if (!hasTimeline) {
        return @{@"error": @"No active timeline — open a project first"};
    }

    __block NSData *nativePasteboardData = nil;
    __block NSData *nativeArchiveData = nil;
    __block NSDictionary *outerPasteboard = nil;
    __block NSString *buildError = nil;
    __block NSString *buildStage = @"init";
    __block int titleCount = 0;
    NSString *nativePath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        @"splicekit_captions_native_container.plist"];
    NSString *archivePath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        @"splicekit_captions_native_container.archive"];
    NSString *xmlDebugPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        @"splicekit_captions_native_container.xml"];
    NSString *debugPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        @"splicekit_captions_native_debug.json"];
    NSMutableArray<NSMutableDictionary *> *segmentDebug = [NSMutableArray array];
    NSMutableArray<NSString *> *warnings = [NSMutableArray array];
    NSMutableDictionary *debugInfo = [@{
        @"mode": @"nativeStorylinePasteboard",
        @"templateMatch": kSpliceKitRuntimeCaptionTemplateMatch,
        @"timeline": @{
            @"frameDuration": [NSString stringWithFormat:@"%d/%d", fdN, fdD],
            @"frameRate": @(self.frameRate),
            @"width": @(self.videoWidth),
            @"height": @(self.videoHeight),
        },
        @"paths": @{
            @"nativePasteboardPath": nativePath,
            @"nativeArchivePath": archivePath,
            @"nativeXMLPath": xmlDebugPath,
            @"debugJSONPath": debugPath,
        },
        @"segmentCount": @(self.mutableSegments.count),
        @"segments": segmentDebug,
    } mutableCopy];
    NSArray<NSDictionary *> *runtimeEntries = [self runtimeEntriesForStyle:s];
    debugInfo[@"expectedTextCount"] = @(runtimeEntries.count);
    debugInfo[@"runtimeEntryCount"] = @(runtimeEntries.count);
    debugInfo[@"runtimeMode"] = (s.wordByWordHighlight && s.highlightColor != nil) ? @"wordHighlight" : @"segment";

    SpliceKit_log(@"[Captions][Native] Starting storyline build for %lu runtime entries from %lu grouped segments using %@",
                  (unsigned long)runtimeEntries.count,
                  (unsigned long)self.mutableSegments.count,
                  kSpliceKitRuntimeCaptionTemplateMatch);

    SpliceKit_executeOnMainThread(^{
        @try {
            buildStage = @"resolveCollectionClass";
            Class collectionClass = objc_getClass("FFAnchoredCollection");
            if (!collectionClass) {
                buildError = @"FFAnchoredCollection class not found";
                return;
            }
            SpliceKit_log(@"[Captions][Native] Using collection class %@", NSStringFromClass(collectionClass));

            buildStage = @"createStoryline";
            id storyline = ((id (*)(id, SEL, id))objc_msgSend)(
                ((id (*)(id, SEL))objc_msgSend)(collectionClass, @selector(alloc)),
                NSSelectorFromString(@"initWithDisplayName:"),
                kSpliceKitCaptionStorylineName);
            if (!storyline) {
                buildError = @"Failed to create anchored collection";
                return;
            }
            SpliceKit_log(@"[Captions][Native] Storyline created: %@", SpliceKitCaption_describeObject(storyline));

            SEL setIsSpineSel = NSSelectorFromString(@"setIsSpine:");
            if ([storyline respondsToSelector:setIsSpineSel]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(storyline, setIsSpineSel, YES);
                SpliceKit_log(@"[Captions][Native] setIsSpine:YES");
            }
            SEL setContentCreatedSel = NSSelectorFromString(@"setContentCreated:");
            if ([storyline respondsToSelector:setContentCreatedSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(storyline, setContentCreatedSel, [NSDate date]);
                SpliceKit_log(@"[Captions][Native] setContentCreated");
            }
            SEL setAngleIDSel = NSSelectorFromString(@"setAngleID:");
            if ([storyline respondsToSelector:setAngleIDSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(storyline, setAngleIDSel, @"");
                SpliceKit_log(@"[Captions][Native] setAngleID:\"\"");
            }
            SEL setUnclippedStartSel = NSSelectorFromString(@"setUnclippedStart:");
            if ([storyline respondsToSelector:setUnclippedStartSel]) {
                CMTime zero = SpliceKitCaption_makeFrameAlignedCMTime(0, fdN, fdD);
                ((void (*)(id, SEL, CMTime))objc_msgSend)(storyline, setUnclippedStartSel, zero);
                SpliceKit_log(@"[Captions][Native] setUnclippedStart:%@", SpliceKitCaption_formatCMTime(zero));
            }

            SEL addContainedSel = NSSelectorFromString(@"addObjectToContainedItems:");
            if (![storyline respondsToSelector:addContainedSel]) {
                buildError = @"Anchored collection cannot accept contained items";
                return;
            }
            SpliceKit_log(@"[Captions][Native] Storyline responds to addObjectToContainedItems:");

            long long cursorFrames = 0;
            for (NSDictionary *entry in runtimeEntries) {
                NSUInteger segIndex = [entry[@"segmentIndex"] unsignedIntegerValue];
                SpliceKitCaptionSegment *seg = (segIndex < self.mutableSegments.count) ? self.mutableSegments[segIndex] : nil;
                NSNumber *activeWordIndex = entry[@"activeWordIndex"];
                NSString *trimmed = entry[@"text"];
                double entryStart = [entry[@"startTime"] doubleValue];
                double entryEnd = [entry[@"endTime"] doubleValue];
                double entryDuration = [entry[@"duration"] doubleValue];
                NSMutableDictionary *segInfo = [@{
                    @"segmentIndex": seg ? @(seg.segmentIndex) : @(segIndex),
                    @"startTime": @(entryStart),
                    @"endTime": @(entryEnd),
                    @"duration": @(entryDuration),
                    @"textPreview": SpliceKitCaption_previewText(trimmed, 120),
                    @"mode": entry[@"mode"] ?: @"segment",
                } mutableCopy];
                if ([activeWordIndex isKindOfClass:[NSNumber class]]) {
                    segInfo[@"activeWordIndex"] = activeWordIndex;
                }
                [segmentDebug addObject:segInfo];
                if (trimmed.length == 0) {
                    segInfo[@"status"] = @"skippedEmpty";
                    SpliceKit_log(@"[Captions][Native] Runtime entry for segment %lu skipped: empty text",
                                  (unsigned long)(seg ? seg.segmentIndex : segIndex));
                    continue;
                }

                double frameDuration = (double)MAX(fdN, 1) / (double)MAX(fdD, 1);
                double resolvedEnd = entryEnd;
                if (!isfinite(resolvedEnd) || resolvedEnd <= entryStart) {
                    double fallbackDuration = (isfinite(entryDuration) && entryDuration > 0) ? entryDuration : frameDuration;
                    resolvedEnd = entryStart + fallbackDuration;
                }

                long long startFrames = SpliceKitCaption_frameCountForSeconds(entryStart, fdN, fdD, YES);
                long long endFrames = SpliceKitCaption_frameCountForSeconds(resolvedEnd, fdN, fdD, NO);
                if (endFrames <= startFrames) {
                    endFrames = startFrames + 1;
                }
                if (startFrames < cursorFrames) {
                    long long unclampedStartFrames = startFrames;
                    startFrames = cursorFrames;
                    if (endFrames <= startFrames) {
                        endFrames = startFrames + 1;
                    }
                    segInfo[@"unclampedStartFrames"] = @(unclampedStartFrames);
                }

                long long durationFrames = MAX(endFrames - startFrames, 1);
                double rawDuration = resolvedEnd - entryStart;
                long long gapFrames = MAX(startFrames - cursorFrames, 0);
                segInfo[@"startFrames"] = @(startFrames);
                segInfo[@"endFrames"] = @(endFrames);
                segInfo[@"durationFrames"] = @(durationFrames);
                segInfo[@"gapFrames"] = @(gapFrames);
                segInfo[@"cursorFramesBefore"] = @(cursorFrames);
                segInfo[@"status"] = @"building";
                SpliceKit_log(@"[Captions][Native] Runtime entry segment=%lu word=%@ start=%.3f end=%.3f rawDur=%.3f startFrames=%lld endFrames=%lld gapFrames=%lld durationFrames=%lld text=\"%@\"",
                              (unsigned long)(seg ? seg.segmentIndex : segIndex),
                              [activeWordIndex isKindOfClass:[NSNumber class]] ? [activeWordIndex stringValue] : @"-",
                              entryStart, entryEnd, rawDuration,
                              startFrames, endFrames, gapFrames, durationFrames,
                              SpliceKitCaption_previewText(trimmed, 100));

                if (startFrames > cursorFrames) {
                    buildStage = [NSString stringWithFormat:@"createGap(segment=%lu)", (unsigned long)(seg ? seg.segmentIndex : segIndex)];
                    id gap = SpliceKitCaption_newGapComponent(
                        SpliceKitCaption_makeFrameAlignedCMTime(startFrames - cursorFrames, fdN, fdD),
                        SpliceKitCaption_makeFrameAlignedCMTime(1, fdN, fdD));
                    if (!gap) {
                        segInfo[@"status"] = @"gapCreateFailed";
                        buildError = @"Failed to create gap component";
                        return;
                    }
                    segInfo[@"gapClass"] = NSStringFromClass([gap class]) ?: @"unknown";
                    SpliceKit_log(@"[Captions][Native] Runtime entry segment=%lu gap=%@ duration=%@",
                                  (unsigned long)(seg ? seg.segmentIndex : segIndex),
                                  SpliceKitCaption_describeObject(gap),
                                  SpliceKitCaption_formatCMTime(
                                      SpliceKitCaption_makeFrameAlignedCMTime(startFrames - cursorFrames, fdN, fdD)));
                    ((void (*)(id, SEL, id))objc_msgSend)(storyline, addContainedSel, gap);
                }

                buildStage = [NSString stringWithFormat:@"createGenerator(segment=%lu)", (unsigned long)(seg ? seg.segmentIndex : segIndex)];
                id generator = SpliceKitCaption_newRuntimeCaptionGenerator(trimmed, s, fdN, fdD, durationFrames);
                if (!generator) {
                    segInfo[@"status"] = @"generatorCreateFailed";
                    buildError = [NSString stringWithFormat:@"Failed to create runtime title generator for segment %lu",
                                  (unsigned long)(seg ? seg.segmentIndex : segIndex)];
                    return;
                }
                segInfo[@"generatorClass"] = NSStringFromClass([generator class]) ?: @"unknown";
                segInfo[@"generator"] = SpliceKitCaption_describeObject(generator);
                SpliceKit_log(@"[Captions][Native] Runtime entry segment=%lu generator=%@",
                              (unsigned long)(seg ? seg.segmentIndex : segIndex),
                              SpliceKitCaption_describeObject(generator));

                ((void (*)(id, SEL, id))objc_msgSend)(storyline, addContainedSel, generator);
                cursorFrames = startFrames + durationFrames;
                segInfo[@"cursorFramesAfter"] = @(cursorFrames);
                segInfo[@"status"] = @"added";
                titleCount++;
            }

            if (titleCount == 0) {
                buildStage = @"validateTitleCount";
                buildError = @"No non-empty caption segments to insert";
                return;
            }

            buildStage = @"archiveStoryline";
            NSDictionary *archiveRoot = @{@"objects": @[storyline]};
            NSError *archiveError = nil;
            nativeArchiveData = [NSKeyedArchiver archivedDataWithRootObject:archiveRoot
                                                      requiringSecureCoding:NO
                                                                      error:&archiveError];
            if (!nativeArchiveData) {
                buildError = archiveError.localizedDescription ?: @"Failed to archive storyline payload";
                return;
            }
            SpliceKit_log(@"[Captions][Native] Archived storyline payload (%lu bytes)",
                          (unsigned long)nativeArchiveData.length);

            buildStage = @"buildPasteboardPlist";
            outerPasteboard = @{
                @"ffpasteboardcopiedtypes": @{@"pb_anchoredObject": @{@"count": @1}},
                @"ffpasteboardobject": nativeArchiveData,
                @"kffmodelobjectIDs": @[],
            };
            NSError *plistError = nil;
            nativePasteboardData = [NSPropertyListSerialization dataWithPropertyList:outerPasteboard
                                                                              format:NSPropertyListBinaryFormat_v1_0
                                                                             options:0
                                                                               error:&plistError];
            if (!nativePasteboardData) {
                buildError = plistError.localizedDescription ?: @"Failed to serialize native pasteboard payload";
                return;
            }
            SpliceKit_log(@"[Captions][Native] Serialized pasteboard plist (%lu bytes)",
                          (unsigned long)nativePasteboardData.length);
        } @catch (NSException *e) {
            buildError = [NSString stringWithFormat:@"Native caption build failed at %@: %@",
                          buildStage, e.reason];
            SpliceKit_log(@"[Captions][Native] Exception during %@: %@\n%@",
                          buildStage, e.reason, [[e callStackSymbols] componentsJoinedByString:@"\n"]);
        }
    });

    debugInfo[@"buildStage"] = buildStage ?: @"unknown";
    debugInfo[@"titleCount"] = @(titleCount);
    if (buildError) debugInfo[@"buildError"] = buildError;
    if (warnings.count > 0) debugInfo[@"warnings"] = warnings;
    if (nativeArchiveData) debugInfo[@"nativeArchiveBytes"] = @(nativeArchiveData.length);
    if (nativePasteboardData) debugInfo[@"nativePasteboardBytes"] = @(nativePasteboardData.length);

    if (nativeArchiveData) {
        SpliceKitCaption_writeDataDebugFile(nativeArchiveData, archivePath, @"native archive");
    }
    if (outerPasteboard) {
        NSError *xmlError = nil;
        NSData *xmlData = [NSPropertyListSerialization dataWithPropertyList:outerPasteboard
                                                                     format:NSPropertyListXMLFormat_v1_0
                                                                    options:0
                                                                      error:&xmlError];
        if (xmlData) {
            SpliceKitCaption_writeDataDebugFile(xmlData, xmlDebugPath, @"native pasteboard XML");
        } else {
            NSString *warning = [NSString stringWithFormat:@"Failed to write XML debug plist: %@",
                                 xmlError.localizedDescription ?: @"unknown error"];
            [warnings addObject:warning];
            SpliceKit_log(@"[Captions][Debug] %@", warning);
        }
    }
    SpliceKitCaption_writeJSONDebugFile(debugInfo, debugPath, @"native caption debug JSON");

    if (!nativePasteboardData) {
        return @{
            @"error": buildError ?: @"Could not build native caption storyline",
            @"debugPath": debugPath,
            @"nativeArchivePath": archivePath,
            @"nativePasteboardPath": nativePath,
            @"nativeXMLPath": xmlDebugPath,
        };
    }

    SpliceKitCaption_writeDataDebugFile(nativePasteboardData, nativePath, @"native pasteboard binary plist");

    __block BOOL pasteHandled = NO;
    __block NSString *pasteTarget = nil;
    __block NSArray *pasteboardTypes = nil;
    __block NSUInteger removedExistingCaptionCollections = 0;

    SpliceKit_executeOnMainThread(^{
        id sequence = SpliceKitCaption_currentSequence();
        if (!sequence) return;
        removedExistingCaptionCollections += SpliceKitCaption_removeExistingCaptionStorylines(
            sequence, SpliceKitLegacyCaptionStorylineName());
        removedExistingCaptionCollections += SpliceKitCaption_removeExistingCaptionStorylines(
            sequence, kSpliceKitCaptionStorylineName);
        if (removedExistingCaptionCollections > 0) {
            SpliceKit_log(@"[Captions][Native] Removed %lu existing caption storyline(s) before paste",
                          (unsigned long)removedExistingCaptionCollections);
        }
    });
    debugInfo[@"removedExistingCaptionCollections"] = @(removedExistingCaptionCollections);

    // Write native pasteboard data, seek to start, then paste as a connected storyline.
    SpliceKit_executeOnMainThread(^{
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setData:nativePasteboardData forType:@"com.apple.flexo.proFFPasteboardUTI"];
        pasteboardTypes = pb.types ?: @[];
        id target = [[NSApplication sharedApplication]
            targetForAction:NSSelectorFromString(@"pasteAnchored:") to:nil from:nil];
        pasteTarget = SpliceKitCaption_describeObject(target);
        SpliceKit_log(@"[Captions] Wrote %lu bytes native storyline payload to pasteboard",
                      (unsigned long)nativePasteboardData.length);
        SpliceKit_log(@"[Captions][Native] pasteboard types=%@ targetForPasteAnchored=%@",
                      pasteboardTypes, pasteTarget ?: @"(nil)");

        id tm = SpliceKit_getActiveTimelineModule();
        if (tm) {
            CMTime zeroTime = SpliceKitCaption_makeFrameAlignedCMTime(0, fdN, fdD);
            SEL setSel = NSSelectorFromString(@"setPlayheadTime:");
            if ([tm respondsToSelector:setSel]) {
                ((void (*)(id, SEL, CMTime))objc_msgSend)(tm, setSel, zeroTime);
                SpliceKit_log(@"[Captions][Native] Set playhead time to %@", SpliceKitCaption_formatCMTime(zeroTime));
            }
        }
        [[NSApplication sharedApplication] sendAction:NSSelectorFromString(@"deselectAll:")
                                                   to:nil from:nil];
    });

    [NSThread sleepForTimeInterval:0.2];

    SpliceKit_executeOnMainThread(^{
        pasteHandled = [[NSApplication sharedApplication]
            sendAction:NSSelectorFromString(@"pasteAnchored:")
                    to:nil from:nil];
    });

    [NSThread sleepForTimeInterval:0.6];

    SpliceKit_log(@"[Captions] Paste as connected: %@", pasteHandled ? @"YES" : @"NO");
    if (!pasteHandled) {
        SpliceKit_log(@"[Captions][Native] pasteAnchored returned NO. Pasteboard types at paste time=%@ target=%@",
                      pasteboardTypes ?: @[], pasteTarget ?: @"(nil)");
    }

    [NSThread sleepForTimeInterval:0.3];
    __block int verifiedTitleCount = 0;
    __block int positionAppliedCount = 0;
    __block NSString *verifiedText = nil;
    __block double verifiedFontSize = 0;
    __block NSString *verifiedFontFamily = nil;
    __block NSUInteger primaryItemCount = 0;
    __block NSUInteger anchoredContainerCount = 0;
    __block NSUInteger textAppliedCount = 0;
    __block NSUInteger textSegmentCursor = 0;
    CGFloat yOffset = [self yOffsetForStyle:s];
    BOOL needsPosition = (s.position != SpliceKitCaptionPositionCenter || s.customYOffset != 0);

    if (pasteHandled) {
        SpliceKit_executeOnMainThread(^{
            @try {
                id tm = SpliceKit_getActiveTimelineModule();
                if (!tm) return;
                id seq = ((id (*)(id, SEL))objc_msgSend)(tm, NSSelectorFromString(@"sequence"));
                if (!seq) return;
                id primary = ((id (*)(id, SEL))objc_msgSend)(seq, NSSelectorFromString(@"primaryObject"));
                if (!primary) return;
                NSArray *items = ((id (*)(id, SEL))objc_msgSend)(primary, NSSelectorFromString(@"containedItems"));
                if (![items isKindOfClass:[NSArray class]]) return;
                primaryItemCount = items.count;
                SpliceKit_log(@"[Captions][Native] Post-paste primary containedItems=%lu",
                              (unsigned long)items.count);

                for (id item in items) {
                    SEL anchoredSel = NSSelectorFromString(@"anchoredItems");
                    if (![item respondsToSelector:anchoredSel]) continue;
                    id anchoredRaw = ((id (*)(id, SEL))objc_msgSend)(item, anchoredSel);
                    NSArray *anchored = nil;
                    if ([anchoredRaw isKindOfClass:[NSSet class]])
                        anchored = [(NSSet *)anchoredRaw allObjects];
                    else if ([anchoredRaw isKindOfClass:[NSArray class]])
                        anchored = anchoredRaw;
                    if (!anchored || anchored.count == 0) continue;
                    anchoredContainerCount += anchored.count;
                    SpliceKit_log(@"[Captions][Native] Item %@ has %lu anchored items",
                                  SpliceKitCaption_describeObject(item),
                                  (unsigned long)anchored.count);

                    for (id conn in anchored) {
                        // Connected item may be a storyline (FFAnchoredCollection)
                        // containing titles, or an individual title. Collect all
                        // titles to process.
                        NSMutableArray *titlesToProcess = [NSMutableArray array];
                        SEL containedSel = NSSelectorFromString(@"containedItems");
                        if ([conn respondsToSelector:containedSel]) {
                            NSArray *contained = ((id (*)(id, SEL))objc_msgSend)(conn, containedSel);
                            if ([contained isKindOfClass:[NSArray class]]) {
                                SpliceKit_log(@"[Captions][Native] Connected container %@ contains %lu items",
                                              SpliceKitCaption_describeObject(conn),
                                              (unsigned long)contained.count);
                                for (id sub in contained) {
                                    if (SpliceKitCaption_isGeneratorTitleObject(sub)) {
                                        [titlesToProcess addObject:sub];
                                    }
                                }
                            }
                        }
                        // If no contained items (or not a collection), only process
                        // standalone generator titles. Skip unrelated anchored media.
                        if (titlesToProcess.count == 0 && SpliceKitCaption_isGeneratorTitleObject(conn)) {
                            [titlesToProcess addObject:conn];
                        }

                        for (id title in titlesToProcess) {
                            verifiedTitleCount++;
                            NSDictionary *entry = (textSegmentCursor < runtimeEntries.count)
                                ? runtimeEntries[textSegmentCursor]
                                : nil;
                            NSString *expectedText = entry[@"text"];
                            NSNumber *activeWordIndex = entry[@"activeWordIndex"];
                            NSArray *displayWords = [entry[@"words"] isKindOfClass:[NSArray class]] ? entry[@"words"] : nil;
                            textSegmentCursor++;

                            // Reload Motion template
                            @try {
                                SEL effectSel = NSSelectorFromString(@"effect");
                                if ([title respondsToSelector:effectSel]) {
                                    id eff = ((id (*)(id, SEL))objc_msgSend)(title, effectSel);
                                    SEL reloadSel = NSSelectorFromString(@"reloadMicaDocument");
                                    if (eff && [eff respondsToSelector:reloadSel]) {
                                        ((void (*)(id, SEL))objc_msgSend)(eff, reloadSel);
                                    }
                                }
                            } @catch (NSException *e) {}

                            if (expectedText.length > 0) {
                                @try {
                                    BOOL didApplyText = NO;
                                    if ([activeWordIndex isKindOfClass:[NSNumber class]] && displayWords.count > 0) {
	                                        NSAttributedString *highlighted =
	                                            SpliceKitCaption_makeHighlightedGeneratorAttributedStringFromWords(
	                                                displayWords, [activeWordIndex unsignedIntegerValue], s);
                                        didApplyText = SpliceKitCaption_setGeneratorAttributedText(title, highlighted);
                                    } else {
                                        didApplyText = SpliceKitCaption_setGeneratorChannelText(title, expectedText, s);
                                    }
                                    if (didApplyText) {
                                        textAppliedCount++;
                                    }
                                } @catch (NSException *e) {
                                    SpliceKit_log(@"[Captions][Native] Failed to apply text to %@: %@",
                                                  SpliceKitCaption_describeObject(title), e.reason);
                                }
                            }

                            // Set position via Motion template channel hierarchy
                            if (needsPosition) {
                                if (SpliceKitCaption_applyGeneratorPositionYOffset(title, yOffset)) {
                                    positionAppliedCount++;
                                }
                            }

                            // Verify first title only
                            if (verifiedText) continue;
                            @try {
                                SEL effectSel = NSSelectorFromString(@"effect");
                                id genEffect = [title respondsToSelector:effectSel]
                                    ? ((id (*)(id, SEL))objc_msgSend)(title, effectSel) : nil;
                                id cf = genEffect ? ((id (*)(id, SEL))objc_msgSend)(genEffect,
                                    NSSelectorFromString(@"channelFolder")) : nil;
                                if (!cf) continue;
                                Class chTextClass = objc_getClass("CHChannelText");
                                NSMutableArray *stack = [NSMutableArray arrayWithObject:cf];
                                while (stack.count > 0 && !verifiedText) {
                                    id node = stack.lastObject;
                                    [stack removeLastObject];
                                    if (chTextClass && [node isKindOfClass:chTextClass]) {
                                        SEL strSel = NSSelectorFromString(@"string");
                                        if ([node respondsToSelector:strSel]) {
                                            id str = ((id (*)(id, SEL))objc_msgSend)(node, strSel);
                                            if (str) verifiedText = [str description];
                                        }
                                        SEL asSel = NSSelectorFromString(@"attributedString");
                                        if ([node respondsToSelector:asSel]) {
                                            NSAttributedString *attrStr = ((id (*)(id, SEL))objc_msgSend)(node, asSel);
                                            if (attrStr && attrStr.length > 0) {
                                                NSDictionary *attrs = [attrStr attributesAtIndex:0 effectiveRange:NULL];
                                                NSFont *font = attrs[NSFontAttributeName];
                                                if (font) {
                                                    verifiedFontSize = font.pointSize;
                                                    verifiedFontFamily = font.familyName;
                                                }
                                            }
                                        }
                                    }
                                    SEL childSel = NSSelectorFromString(@"children");
                                    if ([node respondsToSelector:childSel]) {
                                        NSArray *ch = ((id (*)(id, SEL))objc_msgSend)(node, childSel);
                                        if ([ch isKindOfClass:[NSArray class]])
                                            [stack addObjectsFromArray:ch];
                                    }
                                }
                            } @catch (NSException *e) {}
                        }
                    }
                }
            } @catch (NSException *e) {
                SpliceKit_log(@"[Captions] Post-process exception: %@\n%@",
                              e.reason, [[e callStackSymbols] componentsJoinedByString:@"\n"]);
            }
        });
    }

    SpliceKit_log(@"[Captions] Verified: %d connected titles, text='%@', fontSize=%.1f, position=%d",
                  verifiedTitleCount, verifiedText ?: @"(none)", verifiedFontSize, positionAppliedCount);
    debugInfo[@"pasteHandled"] = @(pasteHandled);
    debugInfo[@"pasteTarget"] = pasteTarget ?: @"(nil)";
    if (pasteboardTypes) debugInfo[@"pasteboardTypes"] = pasteboardTypes;
    debugInfo[@"postPastePrimaryItemCount"] = @(primaryItemCount);
    debugInfo[@"postPasteAnchoredContainerCount"] = @(anchoredContainerCount);
    debugInfo[@"removedExistingCaptionCollections"] = @(removedExistingCaptionCollections);
    debugInfo[@"verifiedTitleCount"] = @(verifiedTitleCount);
    debugInfo[@"textAppliedCount"] = @(textAppliedCount);
    debugInfo[@"positionAppliedCount"] = @(positionAppliedCount);
    if (verifiedText) {
        debugInfo[@"verification"] = @{
            @"text": verifiedText,
            @"fontSize": @(verifiedFontSize),
            @"fontFamily": verifiedFontFamily ?: @"unknown",
        };
    }
    if (verifiedTitleCount == 0 && pasteHandled) {
        NSString *warning = @"pasteAnchored returned YES but verification found zero connected titles";
        [warnings addObject:warning];
        SpliceKit_log(@"[Captions][Native] %@", warning);
    }
    if (warnings.count > 0) debugInfo[@"warnings"] = warnings;
    SpliceKitCaption_writeJSONDebugFile(debugInfo, debugPath, @"native caption debug JSON");

    NSMutableDictionary *result = [@{
        @"status": pasteHandled ? @"ok" : @"error",
        @"insertedCount": @(titleCount),
        @"pasteHandled": @(pasteHandled),
        @"message": [NSString stringWithFormat:@"Added %d captions to timeline", titleCount],
        @"importMethod": @"nativeStorylinePasteboard",
        @"nativePasteboardPath": nativePath,
        @"nativeArchivePath": archivePath,
        @"nativeXMLPath": xmlDebugPath,
        @"debugPath": debugPath,
    } mutableCopy];

    if (!pasteHandled) {
        result[@"error"] = @"pasteAsConnected was not handled — captions may not be on timeline";
    }
    if (warnings.count > 0) {
        result[@"warnings"] = [warnings copy];
    }
    if (removedExistingCaptionCollections > 0) {
        result[@"removedExistingCaptionCollections"] = @(removedExistingCaptionCollections);
    }
    if (textAppliedCount > 0) {
        result[@"textAppliedCount"] = @(textAppliedCount);
    }
    if (needsPosition && positionAppliedCount > 0) {
        result[@"positionApplied"] = @(positionAppliedCount);
        result[@"positionY"] = @(yOffset);
    }
    if (verifiedText) {
        result[@"verification"] = @{
            @"text": verifiedText,
            @"fontSize": @(verifiedFontSize),
            @"fontFamily": verifiedFontFamily ?: @"unknown",
            @"connectedTitleCount": @(verifiedTitleCount),
        };
    }

    return result;
}

@end
