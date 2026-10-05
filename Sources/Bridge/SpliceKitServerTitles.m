//
//  SpliceKitServerTitles.m
//  Titles and generators (titles.*): list what is installed, add one at an exact time,
//  length and lane, and read or change its text and its published parameters — the
//  settings Final Cut Pro's Title / Generator inspector shows. Every change is one
//  undo step.
//
//  How a title is built (FCP 12.3):
//    clip   FFAnchoredGeneratorComponent (a connected clip; anchoredLane is its lane)
//    clip.effect  FFMotionEffect, the Motion template instance
//      publishedChannels   the inspector's parameters: CHChannelEnum (pop-up menu),
//                          CHChannelBool (checkbox), CHChannelColorNoAlpha (color),
//                          CHChannel2D/3D (point), CHChannelDouble and its subclasses
//                          CHChannelPercent (stored 0-1) and CHChannelAngle (radians)
//      textFieldCount / textForField: / setText:forField:   the text fields, as
//                          attributed strings carrying font, size, color and alignment
//
//  Undo. A published parameter is changed inside -[clip actionBegin:...] with the
//  channel's operationBegin/operationEnd: FCP records it like an inspector edit and
//  its undo restores the value. Text is different: setText:forField: updates the live
//  Motion text layout, saveDirtyTextToEffectValues writes the effect's stored values
//  (which FCP's undo does restore), but FCP does not rebuild the live layout from them
//  on undo. So a text change also registers its own undo step in the same group that
//  puts the previous text back, and its redo re-applies the new one. Writing a text
//  channel's string directly (CHChannelText setString:) is never done here: it leaves
//  the layout inconsistent and the next textForField: spins forever (seen live).
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"
#import "SpliceKitTime.h"
#import <AppKit/AppKit.h>

#pragma mark - Small helpers

static id SKT_send(id target, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    if (!target || ![target respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

static BOOL SKT_isKind(id obj, const char *className) {
    Class cls = objc_getClass(className);
    return obj && cls && [obj isKindOfClass:cls];
}

// Value time for parameters. Published parameters of a title are not keyframed in
// the templates FCP ships; a keyframed one is reported and left alone (see below).
static CMTime SKT_paramTime(void) {
    return SpliceKit_timeFromSeconds(0, 600);
}

// CMTimeMake without linking CoreMedia (see SpliceKitTime.h).
static CMTime SKT_time(int64_t value, int32_t timescale) {
    CMTime t = {value, timescale, kCMTimeFlags_Valid, 0};
    return t;
}

static NSString *SKT_hexFromRGB(double r, double g, double b) {
    int (^clamp)(double) = ^int(double v) {
        long n = lround(MAX(0.0, MIN(1.0, v)) * 255.0);
        return (int)n;
    };
    return [NSString stringWithFormat:@"#%02X%02X%02X", clamp(r), clamp(g), clamp(b)];
}

// "#RRGGBB", "RRGGBB", or [r, g, b] with components 0-1.
static BOOL SKT_parseColor(id value, double *r, double *g, double *b) {
    if ([value isKindOfClass:[NSArray class]] && [(NSArray *)value count] >= 3) {
        NSArray *a = value;
        for (NSUInteger i = 0; i < 3; i++) {
            if (![a[i] respondsToSelector:@selector(doubleValue)]) return NO;
        }
        *r = [a[0] doubleValue]; *g = [a[1] doubleValue]; *b = [a[2] doubleValue];
        return (*r >= 0 && *r <= 1 && *g >= 0 && *g <= 1 && *b >= 0 && *b <= 1);
    }
    if (![value isKindOfClass:[NSString class]]) return NO;
    NSString *hex = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if ([hex hasPrefix:@"#"]) hex = [hex substringFromIndex:1];
    if (hex.length != 6) return NO;
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hex];
    if (![scanner scanHexInt:&rgb] || !scanner.isAtEnd) return NO;
    *r = ((rgb >> 16) & 0xFF) / 255.0;
    *g = ((rgb >> 8) & 0xFF) / 255.0;
    *b = (rgb & 0xFF) / 255.0;
    return YES;
}

#pragma mark - Catalog (titles.list)

// "title" / "generator" for FCP's effect type, nil for anything else.
static NSString *SKT_kindForEffectType(NSString *type) {
    if ([type isEqualToString:@"effect.video.title"]) return @"title";
    if ([type isEqualToString:@"effect.video.generator"]) return @"generator";
    return nil;
}

// The theme is the folder between the category and the template in the effect ID:
// ".../Titles.localized/Lower Thirds.localized/Kinetic.localized/Bug.localized/Bug.moti"
// is category "Lower Thirds", theme "Kinetic". Fifteen titles are called "Bug"; the
// theme is what tells them apart, as in FCP's browser.
static NSString *SKT_themeForEffectID(NSString *effectID) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *component in effectID.pathComponents) {
        NSString *c = component;
        if ([c hasSuffix:@".localized"]) c = [c substringToIndex:c.length - @".localized".length];
        [parts addObject:c];
    }
    NSUInteger root = NSNotFound;
    for (NSUInteger i = 0; i < parts.count; i++) {
        if ([parts[i] isEqualToString:@"Titles"] || [parts[i] isEqualToString:@"Generators"]) root = i;
    }
    if (root == NSNotFound || parts.count < root + 4) return @"";
    // parts: ... Titles, <category>, <theme...>, <template folder>, <template file>
    NSRange themes = NSMakeRange(root + 2, parts.count - root - 4);
    if (themes.length == 0) return @"";
    return [[parts subarrayWithRange:themes] componentsJoinedByString:@" / "];
}

static NSDictionary *SKT_describeEffect(Class ffEffect, NSString *effectID) {
    id typeObj = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, @selector(effectTypeForEffectID:), effectID);
    NSString *kind = [typeObj isKindOfClass:[NSString class]] ? SKT_kindForEffectType(typeObj) : nil;
    if (!kind) return nil;
    id nameObj = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, @selector(displayNameForEffectID:), effectID);
    id catObj = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, @selector(categoryForEffectID:), effectID);
    return @{
        @"name": [nameObj isKindOfClass:[NSString class]] ? nameObj : effectID,
        @"kind": kind,
        @"category": [catObj isKindOfClass:[NSString class]] ? catObj : @"",
        @"theme": SKT_themeForEffectID(effectID),
        @"effectID": effectID,
    };
}

static NSArray<NSDictionary *> *SKT_catalog(NSString *kindFilter) {
    Class ffEffect = objc_getClass("FFEffect");
    if (!ffEffect) return @[];
    id allIDs = ((id (*)(id, SEL))objc_msgSend)((id)ffEffect, @selector(userVisibleEffectIDs));
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *effectID in allIDs) {
        @autoreleasepool {
            if (![effectID isKindOfClass:[NSString class]]) continue;
            NSDictionary *d = SKT_describeEffect(ffEffect, effectID);
            if (!d) continue;
            if (kindFilter.length > 0 && ![d[@"kind"] isEqualToString:kindFilter]) continue;
            [out addObject:d];
        }
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        for (NSString *key in @[@"kind", @"category", @"theme", @"name"]) {
            NSComparisonResult r = [a[key] localizedCaseInsensitiveCompare:b[key]];
            if (r != NSOrderedSame) return r;
        }
        return [a[@"effectID"] compare:b[@"effectID"]];
    }];
    return out;
}

static NSString *SKT_kindParam(NSDictionary *params, NSString **error) {
    NSString *kind = [params[@"kind"] isKindOfClass:[NSString class]] ? [params[@"kind"] lowercaseString] : @"";
    if (kind.length == 0 || [kind isEqualToString:@"all"]) return @"";
    if ([kind isEqualToString:@"title"] || [kind isEqualToString:@"generator"]) return kind;
    if (error) *error = @"kind must be \"title\", \"generator\" or \"all\"";
    return nil;
}

static BOOL SKT_matches(NSString *haystack, NSString *needle) {
    if (needle.length == 0) return YES;
    if ([haystack rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    NSString *n = SpliceKit_normalizedEffectName(needle);
    return n.length > 0 && [SpliceKit_normalizedEffectName(haystack) containsString:n];
}

NSDictionary *SpliceKit_handleTitlesList(NSDictionary *params) {
    NSString *error = nil;
    NSString *kind = SKT_kindParam(params, &error);
    if (!kind) return @{@"error": error};
    NSString *filter = [params[@"filter"] isKindOfClass:[NSString class]] ? params[@"filter"] : @"";
    NSString *category = [params[@"category"] isKindOfClass:[NSString class]] ? params[@"category"] : @"";
    NSString *theme = [params[@"theme"] isKindOfClass:[NSString class]] ? params[@"theme"] : @"";

    __block NSArray *catalog = nil;
    SpliceKit_executeOnMainThread(^{ catalog = SKT_catalog(kind); });

    NSCountedSet *names = [NSCountedSet set];
    for (NSDictionary *d in catalog) [names addObject:[d[@"name"] lowercaseString]];

    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *d in catalog) {
        if (!SKT_matches(d[@"category"], category) || !SKT_matches(d[@"theme"], theme)) continue;
        if (filter.length > 0 && !SKT_matches(d[@"name"], filter) && !SKT_matches(d[@"category"], filter) &&
            !SKT_matches(d[@"theme"], filter)) continue;
        NSMutableDictionary *row = [d mutableCopy];
        // Several templates share a name ("Bug", "Left"): say so, so a caller picks by ID.
        row[@"nameIsShared"] = @((BOOL)([names countForObject:[d[@"name"] lowercaseString]] > 1));
        [items addObject:row];
    }
    return @{@"items": items, @"count": @(items.count)};
}

// effectID, or name narrowed by kind / category / theme. A name several templates share
// is refused with the candidates instead of picking one, which is what the old
// insert_title did ("Left" could be any of fourteen lower thirds).
static NSDictionary *SKT_resolveTemplate(NSDictionary *params) {
    NSString *error = nil;
    NSString *kind = SKT_kindParam(params, &error);
    if (!kind) return @{@"error": error};
    NSString *effectID = [params[@"effectID"] isKindOfClass:[NSString class]] ? params[@"effectID"] : @"";
    NSString *name = [params[@"name"] isKindOfClass:[NSString class]] ? params[@"name"] : @"";
    NSString *category = [params[@"category"] isKindOfClass:[NSString class]] ? params[@"category"] : @"";
    NSString *theme = [params[@"theme"] isKindOfClass:[NSString class]] ? params[@"theme"] : @"";

    Class ffEffect = objc_getClass("FFEffect");
    if (!ffEffect) return @{@"error": @"FFEffect class not found"};
    if (effectID.length > 0) {
        NSDictionary *d = SKT_describeEffect(ffEffect, effectID);
        if (!d) return @{@"error": [NSString stringWithFormat:
            @"%@ is not an installed title or generator. list_titles() shows what is.", effectID]};
        if (kind.length > 0 && ![d[@"kind"] isEqualToString:kind]) {
            return @{@"error": [NSString stringWithFormat:@"%@ is a %@, not a %@", d[@"name"], d[@"kind"], kind]};
        }
        return @{@"template": d};
    }
    if (name.length == 0) return @{@"error": @"effectID or name is required (see list_titles())"};

    NSArray *catalog = SKT_catalog(kind);
    NSMutableArray *scoped = [NSMutableArray array];
    for (NSDictionary *d in catalog) {
        if (SKT_matches(d[@"category"], category) && SKT_matches(d[@"theme"], theme)) [scoped addObject:d];
    }
    NSString *wanted = SpliceKit_normalizedEffectName(name);
    NSMutableArray *exact = [NSMutableArray array];
    NSMutableArray *partial = [NSMutableArray array];
    for (NSDictionary *d in scoped) {
        NSString *n = SpliceKit_normalizedEffectName(d[@"name"]);
        if ([n isEqualToString:wanted]) [exact addObject:d];
        else if (wanted.length > 0 && [n containsString:wanted]) [partial addObject:d];
    }
    NSArray *candidates = exact.count > 0 ? exact : partial;
    if (candidates.count == 1) return @{@"template": candidates.firstObject};
    if (candidates.count == 0) {
        return @{@"error": [NSString stringWithFormat:@"No installed %@ is called '%@'%@. list_titles(filter=...) shows what is.",
                            kind.length ? kind : @"title or generator", name,
                            (category.length || theme.length) ? @" in that category / theme" : @""]};
    }
    NSMutableArray *options = [NSMutableArray array];
    for (NSDictionary *d in [candidates subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)12, candidates.count))]) {
        [options addObject:@{@"name": d[@"name"], @"category": d[@"category"], @"theme": d[@"theme"],
                             @"kind": d[@"kind"], @"effectID": d[@"effectID"]}];
    }
    return @{@"error": [NSString stringWithFormat:
                @"%lu templates match '%@'. Pass effect_id, or narrow with category= / theme=.",
                (unsigned long)candidates.count, name],
             @"candidates": options};
}

#pragma mark - Clip and effect access

static id SKT_effectForClip(id clip) {
    id effect = SKT_send(clip, @"effect");
    if (effect && [effect respondsToSelector:NSSelectorFromString(@"publishedChannels")]) return effect;
    return nil;
}

// A title or generator on the timeline, by handle.
static id SKT_clipForHandle(NSString *handle, NSString **error) {
    if (handle.length == 0) {
        if (error) *error = @"handle is required (a title or generator's handle from get_timeline_clips())";
        return nil;
    }
    id clip = SpliceKit_resolveHandle(handle);
    if (!clip) {
        if (error) *error = [NSString stringWithFormat:@"Handle %@ not found. Re-read handles with get_timeline_clips().", handle];
        return nil;
    }
    if (!SKT_isKind(clip, "FFAnchoredGeneratorComponent") || !SKT_effectForClip(clip)) {
        if (error) *error = [NSString stringWithFormat:@"%@ is a %@, not a title or generator.",
                             handle, NSStringFromClass([clip class])];
        return nil;
    }
    return clip;
}

static NSString *SKT_effectIDForClip(id clip) {
    id effect = SKT_send(clip, @"effect");
    id eid = SKT_send(effect, @"effectID");
    return [eid isKindOfClass:[NSString class]] ? eid : @"";
}

#pragma mark - Published parameters

// The inspector's kinds, from the channel's class. Subclasses come before their parents
// (a percent is a double, a color a folder).
static NSString *SKT_paramKind(id channel) {
    if (SKT_isKind(channel, "CHChannelEnum")) return @"menu";
    if (SKT_isKind(channel, "CHChannelBool")) return @"checkbox";
    if (SKT_isKind(channel, "CHChannelColorNoAlpha")) return @"color";
    if (SKT_isKind(channel, "CHChannel3D") || SKT_isKind(channel, "CHChannel2D")) return @"point";
    if (SKT_isKind(channel, "CHChannelPercent")) return @"percent";
    if (SKT_isKind(channel, "CHChannelAngle")) return @"angle";
    if (SKT_isKind(channel, "CHChannelDouble")) return @"number";
    return @"unsupported";
}

static NSString *SKT_channelName(id channel) {
    id name = SKT_send(channel, @"name");
    NSString *s = [name isKindOfClass:[NSString class]] ? name : @"";
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

static NSArray *SKT_publishedChannels(id effect) {
    id channels = SKT_send(effect, @"publishedChannels");
    return [channels isKindOfClass:[NSArray class]] ? channels : @[];
}

// Keys are the inspector labels; a label that repeats gets " (2)", " (3)" after it.
static NSArray<NSDictionary *> *SKT_keyedChannels(id effect) {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *seen = [NSMutableDictionary dictionary];
    for (id channel in SKT_publishedChannels(effect)) {
        NSString *name = SKT_channelName(channel);
        if (name.length == 0) name = @"Parameter";
        NSInteger n = seen[name.lowercaseString].integerValue + 1;
        seen[name.lowercaseString] = @(n);
        NSString *key = n > 1 ? [NSString stringWithFormat:@"%@ (%ld)", name, (long)n] : name;
        [out addObject:@{@"key": key, @"name": name, @"channel": channel}];
    }
    return out;
}

static double SKT_doubleValue(id channel) {
    SEL sel = NSSelectorFromString(@"curveDoubleValueAtTime:");
    if (![channel respondsToSelector:sel]) return 0;
    return ((double (*)(id, SEL, CMTime))objc_msgSend)(channel, sel, SKT_paramTime());
}

static NSInteger SKT_keyframeCount(id channel) {
    SEL sel = NSSelectorFromString(@"keyframeCount");
    if (![channel respondsToSelector:sel]) return 0;
    @try { return ((NSInteger (*)(id, SEL))objc_msgSend)(channel, sel); } @catch (__unused NSException *e) {}
    return 0;
}

static NSArray<NSString *> *SKT_menuOptions(id channel) {
    NSMutableArray *out = [NSMutableArray array];
    SEL countSel = NSSelectorFromString(@"stringCount");
    SEL atSel = NSSelectorFromString(@"stringAtIndex:");
    if (![channel respondsToSelector:countSel] || ![channel respondsToSelector:atSel]) return out;
    NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(channel, countSel);
    for (NSUInteger i = 0; i < count; i++) {
        id s = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(channel, atSel, i);
        [out addObject:[s isKindOfClass:[NSString class]] ? s : @""];
    }
    return out;
}

static NSArray<id> *SKT_pointAxes(id channel) {
    NSMutableArray *axes = [NSMutableArray array];
    for (NSString *sel in @[@"xChannel", @"yChannel", @"zChannel"]) {
        id axis = SKT_send(channel, sel);
        if (axis) [axes addObject:axis];
    }
    return axes;
}

// Value in the inspector's units: percent 0-100, angle in degrees, a color as #RRGGBB,
// a point as [x, y(, z)], a menu as its option text.
static id SKT_paramValue(id channel, NSString *kind) {
    if ([kind isEqualToString:@"menu"]) {
        id s = SKT_send(channel, @"stringValue");
        return [s isKindOfClass:[NSString class]] ? s : @"";
    }
    if ([kind isEqualToString:@"checkbox"]) {
        SEL sel = NSSelectorFromString(@"curveBoolValueAtTime:");
        return @(((BOOL (*)(id, SEL, CMTime))objc_msgSend)(channel, sel, SKT_paramTime()));
    }
    if ([kind isEqualToString:@"color"]) {
        double r = 0, g = 0, b = 0;
        SEL sel = NSSelectorFromString(@"getColorAtTime:curveRed:curveGreen:curveBlue:");
        if (![channel respondsToSelector:sel]) return [NSNull null];
        ((void (*)(id, SEL, CMTime, double *, double *, double *))objc_msgSend)(channel, sel, SKT_paramTime(), &r, &g, &b);
        return SKT_hexFromRGB(r, g, b);
    }
    if ([kind isEqualToString:@"point"]) {
        NSMutableArray *v = [NSMutableArray array];
        for (id axis in SKT_pointAxes(channel)) [v addObject:@(SKT_doubleValue(axis))];
        return v;
    }
    double v = SKT_doubleValue(channel);
    if ([kind isEqualToString:@"percent"]) return @(v * 100.0);
    if ([kind isEqualToString:@"angle"]) return @(v * 180.0 / M_PI);
    if ([kind isEqualToString:@"number"]) return @(v);
    return [NSNull null];
}

static NSDictionary *SKT_describeParam(NSDictionary *keyed) {
    id channel = keyed[@"channel"];
    NSString *kind = SKT_paramKind(channel);
    NSMutableDictionary *d = [@{@"key": keyed[@"key"], @"kind": kind} mutableCopy];
    if ([kind isEqualToString:@"unsupported"]) {
        d[@"channelClass"] = NSStringFromClass([channel class]);
        return d;
    }
    d[@"value"] = SKT_paramValue(channel, kind) ?: [NSNull null];
    if ([kind isEqualToString:@"menu"]) d[@"options"] = SKT_menuOptions(channel);
    if ([kind isEqualToString:@"number"] || [kind isEqualToString:@"percent"]) {
        double scale = [kind isEqualToString:@"percent"] ? 100.0 : 1.0;
        SEL minSel = NSSelectorFromString(@"minUIDoubleValue"), maxSel = NSSelectorFromString(@"maxUIDoubleValue");
        if ([channel respondsToSelector:minSel] && [channel respondsToSelector:maxSel]) {
            double lo = ((double (*)(id, SEL))objc_msgSend)(channel, minSel);
            double hi = ((double (*)(id, SEL))objc_msgSend)(channel, maxSel);
            // FLT_MAX means "no slider limit"; leave it out rather than print 3.4e38.
            if (fabs(lo) < 1e30) d[@"min"] = @(lo * scale);
            if (fabs(hi) < 1e30) d[@"max"] = @(hi * scale);
        }
    }
    NSInteger keyframes = [kind isEqualToString:@"point"] || [kind isEqualToString:@"color"]
        ? 0 : SKT_keyframeCount(channel);
    if (keyframes > 0) d[@"keyframes"] = @(keyframes);
    return d;
}

// Checks one requested value and returns a block that applies it, or an error. Nothing
// is changed until every requested value has been checked.
typedef void (^SKTApply)(void);

static SKTApply SKT_prepareParam(id channel, NSString *kind, NSString *key, id value, NSString **error) {
    CMTime t = SKT_paramTime();
    if ([kind isEqualToString:@"unsupported"]) {
        *error = [NSString stringWithFormat:@"'%@' is a %@ parameter, which SpliceKit cannot set", key,
                  NSStringFromClass([channel class])];
        return nil;
    }
    if (![kind isEqualToString:@"color"] && ![kind isEqualToString:@"point"] && SKT_keyframeCount(channel) > 0) {
        *error = [NSString stringWithFormat:@"'%@' is keyframed in this title; setting one value would "
                  "overwrite its animation, so SpliceKit leaves it alone", key];
        return nil;
    }
    if ([kind isEqualToString:@"menu"]) {
        NSArray<NSString *> *options = SKT_menuOptions(channel);
        NSInteger index = -1;
        if ([value isKindOfClass:[NSString class]]) {
            for (NSUInteger i = 0; i < options.count; i++) {
                if ([options[i] caseInsensitiveCompare:value] == NSOrderedSame) { index = (NSInteger)i; break; }
            }
        } else if ([value isKindOfClass:[NSNumber class]]) {
            index = [value integerValue];
        }
        if (index < 0 || index >= (NSInteger)options.count) {
            *error = [NSString stringWithFormat:@"'%@' has no option %@. Options: %@", key, value,
                      [options componentsJoinedByString:@", "]];
            return nil;
        }
        SEL mapSel = NSSelectorFromString(@"intValueForIndex:");
        int intValue = [channel respondsToSelector:mapSel]
            ? ((int (*)(id, SEL, int))objc_msgSend)(channel, mapSel, (int)index) : (int)index;
        return ^{
            ((void (*)(id, SEL, int, CMTime, unsigned int))objc_msgSend)(
                channel, NSSelectorFromString(@"setCurveIntValue:atTime:options:"), intValue, t, 0);
        };
    }
    if ([kind isEqualToString:@"checkbox"]) {
        if (![value isKindOfClass:[NSNumber class]]) {
            *error = [NSString stringWithFormat:@"'%@' is a checkbox: pass true or false", key];
            return nil;
        }
        BOOL on = [value boolValue];
        return ^{
            ((void (*)(id, SEL, BOOL, CMTime, unsigned int))objc_msgSend)(
                channel, NSSelectorFromString(@"setCurveBoolValue:atTime:options:"), on, t, 0);
        };
    }
    if ([kind isEqualToString:@"color"]) {
        double r, g, b;
        if (!SKT_parseColor(value, &r, &g, &b)) {
            *error = [NSString stringWithFormat:@"'%@' is a color: pass \"#RRGGBB\" or [r, g, b] with 0-1 components", key];
            return nil;
        }
        return ^{
            ((void (*)(id, SEL, CMTime, double, double, double, unsigned int))objc_msgSend)(
                channel, NSSelectorFromString(@"setColorAtTime:curveRed:curveGreen:curveBlue:options:"), t, r, g, b, 0);
        };
    }
    if ([kind isEqualToString:@"point"]) {
        NSArray *axes = SKT_pointAxes(channel);
        NSArray *values = [value isKindOfClass:[NSArray class]] ? value : nil;
        if (values.count < 2 || values.count > axes.count) {
            *error = [NSString stringWithFormat:@"'%@' is a point: pass [x, y]%@", key, axes.count > 2 ? @" or [x, y, z]" : @""];
            return nil;
        }
        for (id v in values) {
            if (![v isKindOfClass:[NSNumber class]]) {
                *error = [NSString stringWithFormat:@"'%@' is a point: every coordinate must be a number", key];
                return nil;
            }
        }
        return ^{
            for (NSUInteger i = 0; i < values.count; i++) {
                SpliceKit_setChannelValueAtTimeWithOptions(axes[i], [values[i] doubleValue], t, 0);
            }
        };
    }
    if (![value isKindOfClass:[NSNumber class]]) {
        *error = [NSString stringWithFormat:@"'%@' is a number: pass a number", key];
        return nil;
    }
    double v = [value doubleValue];
    if ([kind isEqualToString:@"percent"]) v /= 100.0;
    if ([kind isEqualToString:@"angle"]) v = v * M_PI / 180.0;
    SEL minSel = NSSelectorFromString(@"minUIDoubleValue"), maxSel = NSSelectorFromString(@"maxUIDoubleValue");
    if ([channel respondsToSelector:minSel] && [channel respondsToSelector:maxSel]) {
        double lo = ((double (*)(id, SEL))objc_msgSend)(channel, minSel);
        double hi = ((double (*)(id, SEL))objc_msgSend)(channel, maxSel);
        if (fabs(lo) < 1e30 && fabs(hi) < 1e30 && (v < lo - 1e-9 || v > hi + 1e-9)) {
            double scale = [kind isEqualToString:@"percent"] ? 100.0 : 1.0;
            *error = [NSString stringWithFormat:@"'%@' must be between %g and %g", key, lo * scale, hi * scale];
            return nil;
        }
    }
    return ^{ SpliceKit_setChannelValueAtTimeWithOptions(channel, v, t, 0); };
}

#pragma mark - Text fields

static NSString *SKT_alignmentName(NSTextAlignment a) {
    switch (a) {
        case NSTextAlignmentLeft: return @"left";
        case NSTextAlignmentCenter: return @"center";
        case NSTextAlignmentRight: return @"right";
        case NSTextAlignmentJustified: return @"justified";
        default: return @"natural";
    }
}

static NSUInteger SKT_textFieldCount(id effect) {
    SEL sel = NSSelectorFromString(@"textFieldCount");
    if (![effect respondsToSelector:sel]) return 0;
    return ((NSUInteger (*)(id, SEL))objc_msgSend)(effect, sel);
}

static NSAttributedString *SKT_textForField(id effect, NSUInteger field) {
    SEL sel = NSSelectorFromString(@"textForField:");
    if (![effect respondsToSelector:sel]) return nil;
    id t = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(effect, sel, field);
    if ([t isKindOfClass:[NSAttributedString class]]) return t;
    if ([t isKindOfClass:[NSString class]]) return [[NSAttributedString alloc] initWithString:t];
    return nil;
}

static NSDictionary *SKT_describeTextField(NSAttributedString *text, NSUInteger index) {
    NSMutableDictionary *d = [@{@"index": @(index), @"text": text.string ?: @""} mutableCopy];
    if (text.length == 0) return d;
    NSDictionary *attrs = [text attributesAtIndex:0 effectiveRange:NULL];
    NSFont *font = attrs[NSFontAttributeName];
    if (font) {
        d[@"font"] = font.familyName ?: @"";
        d[@"fontName"] = font.fontName ?: @"";
        d[@"size"] = @(font.pointSize);
        NSFontTraitMask traits = [[NSFontManager sharedFontManager] traitsOfFont:font];
        d[@"bold"] = @((BOOL)((traits & NSBoldFontMask) != 0));
        d[@"italic"] = @((BOOL)((traits & NSItalicFontMask) != 0));
    }
    NSColor *color = [attrs[NSForegroundColorAttributeName] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (color) d[@"color"] = SKT_hexFromRGB(color.redComponent, color.greenComponent, color.blueComponent);
    NSParagraphStyle *para = attrs[NSParagraphStyleAttributeName];
    if (para) d[@"alignment"] = SKT_alignmentName(para.alignment);
    return d;
}

// The field's current attributed text with the requested changes: new words keep the
// first run's attributes (the template's look); font, size, bold, italic, color and
// alignment then apply to the whole field.
static NSAttributedString *SKT_restyleText(NSAttributedString *current, NSDictionary *change, NSString **error) {
    NSDictionary *base = current.length > 0 ? [current attributesAtIndex:0 effectiveRange:NULL] : @{};
    NSMutableAttributedString *out = nil;
    if ([change[@"text"] isKindOfClass:[NSString class]]) {
        out = [[NSMutableAttributedString alloc] initWithString:change[@"text"] attributes:base];
    } else {
        out = [current mutableCopy] ?: [[NSMutableAttributedString alloc] init];
    }
    if (out.length == 0) return out;
    NSRange all = NSMakeRange(0, out.length);
    NSFontManager *fm = [NSFontManager sharedFontManager];

    id fontName = change[@"font"], size = change[@"size"], bold = change[@"bold"], italic = change[@"italic"];
    if (fontName || size || bold || italic) {
        if (fontName && ![fontName isKindOfClass:[NSString class]]) { *error = @"font must be a font family or PostScript name"; return nil; }
        if (size && (![size isKindOfClass:[NSNumber class]] || [size doubleValue] <= 0 || [size doubleValue] > 2000)) {
            *error = @"size must be a point size between 0 and 2000"; return nil;
        }
        __block NSString *fontError = nil;
        [out enumerateAttribute:NSFontAttributeName inRange:all options:0 usingBlock:^(NSFont *font, NSRange range, BOOL *stop) {
            NSFont *f = font ?: [NSFont systemFontOfSize:[size doubleValue] ?: 60];
            if (fontName) {
                NSFont *named = [NSFont fontWithName:fontName size:f.pointSize];
                NSFont *family = named ? nil : [fm convertFont:f toFamily:fontName];
                if (named) f = named;
                else if (family && [family.familyName caseInsensitiveCompare:fontName] == NSOrderedSame) f = family;
                else { fontError = [NSString stringWithFormat:@"No font called '%@' is installed", fontName]; *stop = YES; return; }
            }
            if (size) f = [fm convertFont:f toSize:[size doubleValue]];
            if (bold) f = [bold boolValue] ? [fm convertFont:f toHaveTrait:NSBoldFontMask] : [fm convertFont:f toNotHaveTrait:NSBoldFontMask];
            if (italic) f = [italic boolValue] ? [fm convertFont:f toHaveTrait:NSItalicFontMask] : [fm convertFont:f toNotHaveTrait:NSItalicFontMask];
            [out addAttribute:NSFontAttributeName value:f range:range];
        }];
        if (fontError) { *error = fontError; return nil; }
    }
    if (change[@"color"]) {
        double r, g, b;
        if (!SKT_parseColor(change[@"color"], &r, &g, &b)) { *error = @"color must be \"#RRGGBB\" or [r, g, b] with 0-1 components"; return nil; }
        [out addAttribute:NSForegroundColorAttributeName
                    value:[NSColor colorWithSRGBRed:r green:g blue:b alpha:1.0] range:all];
    }
    if (change[@"alignment"]) {
        NSDictionary *names = @{@"left": @(NSTextAlignmentLeft), @"center": @(NSTextAlignmentCenter),
                                @"right": @(NSTextAlignmentRight), @"justified": @(NSTextAlignmentJustified)};
        NSNumber *a = [change[@"alignment"] isKindOfClass:[NSString class]] ? names[[change[@"alignment"] lowercaseString]] : nil;
        if (!a) { *error = @"alignment must be left, center, right or justified"; return nil; }
        [out enumerateAttribute:NSParagraphStyleAttributeName inRange:all options:0 usingBlock:^(NSParagraphStyle *p, NSRange range, BOOL *stop) {
            NSMutableParagraphStyle *m = [(p ?: NSParagraphStyle.defaultParagraphStyle) mutableCopy];
            m.alignment = (NSTextAlignment)a.integerValue;
            [out addAttribute:NSParagraphStyleAttributeName value:m range:range];
        }];
    }
    return out;
}

// FCP's own text setter, after its own normalization (the caption panel does the same).
// Updates the live Motion layout and asks the effect to redraw.
static void SKT_setLiveText(id effect, NSUInteger field, NSAttributedString *text) {
    NSAttributedString *apply = text;
    SEL normalizeSel = NSSelectorFromString(@"_newAttributedString:forField:");
    if ([effect respondsToSelector:normalizeSel]) {
        @try {
            id n = ((id (*)(id, SEL, id, NSUInteger))objc_msgSend)(effect, normalizeSel, [text mutableCopy], field);
            if ([n isKindOfClass:[NSAttributedString class]] && [(NSAttributedString *)n length] > 0) apply = n;
        } @catch (__unused NSException *e) {}
    }
    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(effect, NSSelectorFromString(@"setText:forField:"), apply, field);
    SEL changedSel = NSSelectorFromString(@"_channelsChanged");
    if ([effect respondsToSelector:changedSel]) ((void (*)(id, SEL))objc_msgSend)(effect, changedSel);
}

static void SKT_saveText(id effect) {
    SEL saveSel = NSSelectorFromString(@"saveDirtyTextToEffectValues");
    if ([effect respondsToSelector:saveSel]) ((void (*)(id, SEL))objc_msgSend)(effect, saveSel);
}

// The undo half of a text change: puts `restore` back in the live layout, and registers
// the opposite change as its redo (NSUndoManager turns a registration made while undoing
// into a redo, and the other way round), so undo / redo / undo keep working.
static void SKT_registerTextRestore(NSUndoManager *um, id effect,
                                    NSDictionary<NSNumber *, NSAttributedString *> *restore,
                                    NSDictionary<NSNumber *, NSAttributedString *> *other) {
    if (!um || restore.count == 0) return;
    [um registerUndoWithTarget:effect handler:^(id target) {
        for (NSNumber *field in restore) SKT_setLiveText(target, field.unsignedIntegerValue, restore[field]);
        SKT_registerTextRestore(um, target, other, restore);
    }];
}

#pragma mark - Parsing a change request

// text (field 0), text_fields ([{index?, text?, font?, size?, bold?, italic?, color?,
// alignment?}] in field order, or keyed by index) and the style keys at the top level,
// which apply to field 0 when text_fields is not given.
static NSDictionary<NSNumber *, NSDictionary *> *SKT_textChanges(NSDictionary *params, NSUInteger fieldCount, NSString **error) {
    NSMutableDictionary<NSNumber *, NSDictionary *> *changes = [NSMutableDictionary dictionary];
    NSArray *styleKeys = @[@"text", @"font", @"size", @"bold", @"italic", @"color", @"alignment"];
    id fields = params[@"textFields"];
    if (fields && ![fields isKindOfClass:[NSNull class]]) {
        if (![fields isKindOfClass:[NSArray class]]) { *error = @"text_fields must be a list"; return nil; }
        NSUInteger position = 0;
        for (id entry in (NSArray *)fields) {
            NSDictionary *change = [entry isKindOfClass:[NSString class]] ? @{@"text": entry} : entry;
            if (![change isKindOfClass:[NSDictionary class]]) { *error = @"each text_fields entry is a string or an object"; return nil; }
            NSUInteger index = [change[@"index"] respondsToSelector:@selector(unsignedIntegerValue)]
                ? [change[@"index"] unsignedIntegerValue] : position;
            position++;
            NSMutableDictionary *c = [NSMutableDictionary dictionary];
            for (NSString *k in styleKeys) if (change[k] && ![change[k] isKindOfClass:[NSNull class]]) c[k] = change[k];
            if (c.count) changes[@(index)] = c;
        }
    }
    NSMutableDictionary *top = [NSMutableDictionary dictionary];
    for (NSString *k in styleKeys) if (params[k] && ![params[k] isKindOfClass:[NSNull class]]) top[k] = params[k];
    if (top.count) {
        if (changes.count) { *error = @"use either text / font / size / ... (field 0) or text_fields, not both"; return nil; }
        changes[@0] = top;
    }
    for (NSNumber *index in changes) {
        if (index.unsignedIntegerValue >= fieldCount) {
            *error = fieldCount == 0
                ? @"this title or generator has no text fields"
                : [NSString stringWithFormat:@"text field %@ does not exist (this template has %lu: 0-%lu)",
                   index, (unsigned long)fieldCount, (unsigned long)fieldCount - 1];
            return nil;
        }
    }
    return changes;
}

// Validates every requested change against `effect` and returns what to apply:
// paramApply (blocks), textNew / textOld (attributed strings by field), and a summary.
static NSDictionary *SKT_planChanges(id effect, NSDictionary *params, NSString **error) {
    NSMutableArray *paramApply = [NSMutableArray array];
    NSMutableArray *paramSummary = [NSMutableArray array];
    id requested = params[@"parameters"];
    if (requested && ![requested isKindOfClass:[NSNull class]]) {
        if (![requested isKindOfClass:[NSDictionary class]]) { *error = @"parameters must be an object of {name: value}"; return nil; }
        NSArray *keyed = SKT_keyedChannels(effect);
        for (NSString *key in (NSDictionary *)requested) {
            NSDictionary *match = nil;
            for (NSDictionary *k in keyed) {
                if ([k[@"key"] caseInsensitiveCompare:key] == NSOrderedSame) { match = k; break; }
            }
            if (!match) {
                NSMutableArray *names = [NSMutableArray array];
                for (NSDictionary *k in keyed) [names addObject:k[@"key"]];
                *error = [NSString stringWithFormat:@"No parameter '%@'. This template has: %@", key,
                          names.count ? [names componentsJoinedByString:@", "] : @"(none)"];
                return nil;
            }
            NSString *kind = SKT_paramKind(match[@"channel"]);
            SKTApply apply = SKT_prepareParam(match[@"channel"], kind, match[@"key"], requested[key], error);
            if (!apply) return nil;
            [paramApply addObject:@{@"channel": match[@"channel"], @"apply": [apply copy]}];
            [paramSummary addObject:@{@"key": match[@"key"], @"kind": kind,
                                      @"before": SKT_paramValue(match[@"channel"], kind) ?: [NSNull null],
                                      @"requested": requested[key]}];
        }
    }

    NSUInteger fieldCount = SKT_textFieldCount(effect);
    NSDictionary *textChanges = SKT_textChanges(params, fieldCount, error);
    if (!textChanges) return nil;
    NSMutableDictionary *textNew = [NSMutableDictionary dictionary];
    NSMutableDictionary *textOld = [NSMutableDictionary dictionary];
    NSMutableArray *textSummary = [NSMutableArray array];
    for (NSNumber *field in [textChanges.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSAttributedString *current = SKT_textForField(effect, field.unsignedIntegerValue) ?: [[NSAttributedString alloc] init];
        NSAttributedString *restyled = SKT_restyleText(current, textChanges[field], error);
        if (!restyled) return nil;
        textOld[field] = [current copy];
        textNew[field] = restyled;
        [textSummary addObject:@{@"before": SKT_describeTextField(current, field.unsignedIntegerValue),
                                 @"after": SKT_describeTextField(restyled, field.unsignedIntegerValue)}];
    }
    if (paramApply.count == 0 && textNew.count == 0) {
        *error = @"Nothing to change: pass text, text_fields, a style key (font, size, bold, italic, color, alignment) or parameters";
        return nil;
    }
    return @{@"paramApply": paramApply, @"paramSummary": paramSummary,
             @"textNew": textNew, @"textOld": textOld, @"textSummary": textSummary};
}

// Applies a plan. Published parameters go through the channel's operation bracket
// (FCP's inspector path); text goes through FCP's text setter and is saved into the
// effect's stored values. `um` registers the text restore; nil when the clip is not on a
// timeline yet (a new title: undoing the add removes it whole).
static void SKT_applyPlan(id effect, NSDictionary *plan, NSUndoManager *um) {
    for (NSDictionary *p in plan[@"paramApply"]) {
        id channel = p[@"channel"];
        SEL beginSel = NSSelectorFromString(@"operationBegin"), endSel = NSSelectorFromString(@"operationEnd");
        if ([channel respondsToSelector:beginSel]) ((void (*)(id, SEL))objc_msgSend)(channel, beginSel);
        ((SKTApply)p[@"apply"])();
        if ([channel respondsToSelector:endSel]) ((void (*)(id, SEL))objc_msgSend)(channel, endSel);
    }
    NSDictionary *textNew = plan[@"textNew"];
    if (textNew.count) {
        for (NSNumber *field in textNew) SKT_setLiveText(effect, field.unsignedIntegerValue, textNew[field]);
        SKT_saveText(effect);
        SKT_registerTextRestore(um, effect, plan[@"textOld"], textNew);
    }
}

#pragma mark - Reading a title (titles.getParameters)

static NSDictionary *SKT_describeClip(id clip, BOOL includeParameters) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    id effect = SKT_effectForClip(clip);
    id name = SKT_send(clip, @"displayName");
    d[@"name"] = [name isKindOfClass:[NSString class]] ? name : @"";
    NSString *effectID = SKT_effectIDForClip(clip);
    d[@"effectID"] = effectID;
    Class ffEffect = objc_getClass("FFEffect");
    NSDictionary *template = (ffEffect && effectID.length) ? SKT_describeEffect(ffEffect, effectID) : nil;
    if (template) {
        d[@"kind"] = template[@"kind"];
        d[@"template"] = template[@"name"];
        d[@"category"] = template[@"category"];
        d[@"theme"] = template[@"theme"];
    }
    if ([clip respondsToSelector:@selector(anchoredLane)]) {
        d[@"lane"] = @(((long long (*)(id, SEL))objc_msgSend)(clip, @selector(anchoredLane)));
    }
    if (includeParameters) {
        NSMutableArray *fields = [NSMutableArray array];
        NSUInteger count = SKT_textFieldCount(effect);
        for (NSUInteger i = 0; i < count; i++) {
            NSAttributedString *t = SKT_textForField(effect, i);
            if (t) [fields addObject:SKT_describeTextField(t, i)];
        }
        d[@"textFields"] = fields;
        NSMutableArray *parameters = [NSMutableArray array];
        for (NSDictionary *keyed in SKT_keyedChannels(effect)) [parameters addObject:SKT_describeParam(keyed)];
        d[@"parameters"] = parameters;
    }
    return d;
}

// Start and end on the timeline, as get_timeline_clips reports them.
static void SKT_addTimelinePlacement(NSMutableDictionary *d, id clip) {
    id timeline = SpliceKit_getActiveTimelineModule();
    id sequence = SKT_send(timeline, @"sequence");
    id primary = SKT_send(sequence, @"primaryObject");
    SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");
    if (!primary || ![primary respondsToSelector:erSel]) return;
    @try {
        CMTimeRange range = ((CMTimeRange (*)(id, SEL, id))STRET_MSG)(primary, erSel, clip);
        double start = SpliceKit_secondsFromTime(range.start);
        double duration = SpliceKit_secondsFromTime(range.duration);
        if (duration > 0) {
            d[@"start"] = @(start);
            d[@"end"] = @(start + duration);
            d[@"duration"] = @(duration);
        }
    } @catch (__unused NSException *e) {}
}

NSDictionary *SpliceKit_handleTitlesGetParameters(NSDictionary *params) {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            NSString *error = nil;
            id clip = SKT_clipForHandle(params[@"handle"], &error);
            if (!clip) { result = @{@"error": error}; return; }
            NSMutableDictionary *d = [SKT_describeClip(clip, YES) mutableCopy];
            d[@"handle"] = params[@"handle"];
            SKT_addTimelinePlacement(d, clip);
            result = d;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Reading the title failed"};
}

#pragma mark - Changing a title (titles.setParameters)

NSDictionary *SpliceKit_handleTitlesSetParameters(NSDictionary *params) {
    BOOL dryRun = [params[@"dryRun"] boolValue];
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            NSString *error = nil;
            id clip = SKT_clipForHandle(params[@"handle"], &error);
            if (!clip) { result = @{@"error": error}; return; }
            id effect = SKT_effectForClip(clip);
            NSDictionary *plan = SKT_planChanges(effect, params, &error);
            if (!plan) { result = @{@"error": error}; return; }

            NSMutableDictionary *out = [@{@"handle": params[@"handle"],
                                          @"parameters": plan[@"paramSummary"],
                                          @"textFields": plan[@"textSummary"]} mutableCopy];
            if (dryRun) {
                out[@"status"] = @"dry_run";
                result = out;
                return;
            }

            NSString *actionName = plan[@"textNew"] && [plan[@"textNew"] count] && ![plan[@"paramApply"] count]
                ? @"Set Title Text" : @"Edit Title";
            if ([params[@"undoName"] isKindOfClass:[NSString class]] && [params[@"undoName"] length]) {
                actionName = params[@"undoName"];
            }
            SEL beginSel = NSSelectorFromString(@"actionBegin:animationHint:deferUpdates:");
            SEL endSel = NSSelectorFromString(@"actionEnd:save:error:");
            ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(clip, beginSel, actionName, nil, YES);
            @try {
                SKT_applyPlan(effect, plan, (NSUndoManager *)SpliceKit_getUndoManager());
            } @finally {
                NSError *endError = nil;
                ((BOOL (*)(id, SEL, id, BOOL, NSError **))objc_msgSend)(clip, endSel, actionName, YES, &endError);
                if (endError) SpliceKit_log(@"[Titles] actionEnd \"%@\": %@", actionName, endError.localizedDescription);
            }

            // Read back what FCP now holds.
            NSMutableArray *params2 = [NSMutableArray array];
            for (NSDictionary *p in plan[@"paramSummary"]) {
                NSMutableDictionary *m = [p mutableCopy];
                for (NSDictionary *keyed in SKT_keyedChannels(effect)) {
                    if ([keyed[@"key"] isEqualToString:p[@"key"]]) {
                        m[@"after"] = SKT_paramValue(keyed[@"channel"], p[@"kind"]) ?: [NSNull null];
                        break;
                    }
                }
                [params2 addObject:m];
            }
            out[@"parameters"] = params2;
            NSMutableArray *fields = [NSMutableArray array];
            for (NSNumber *field in [[plan[@"textNew"] allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
                NSAttributedString *now = SKT_textForField(effect, field.unsignedIntegerValue);
                [fields addObject:SKT_describeTextField(now ?: [[NSAttributedString alloc] init], field.unsignedIntegerValue)];
            }
            out[@"textFields"] = fields;
            out[@"status"] = @"ok";
            out[@"undoName"] = actionName;
            result = out;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Changing the title failed"};
}

#pragma mark - Adding a title (titles.add)

// Lanes of the connected clips that overlap [start, end), from each spine item's
// anchored items (positions via the spine's effectiveRangeOfObject:, as the timeline
// read does).
static NSIndexSet *SKT_lanesUsedBetween(id primary, double start, double end) {
    NSMutableIndexSet *used = [NSMutableIndexSet indexSet];
    NSArray *spine = SpliceKit_mixerArrayFromContainer(SKT_send(primary, @"containedItems"));
    SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");
    for (id item in spine) {
        for (id anchored in SpliceKit_mixerArrayFromContainer(SKT_send(item, @"anchoredItems"))) {
            if (SpliceKit_isMarkerLikeItem(anchored) || ![anchored respondsToSelector:@selector(anchoredLane)]) continue;
            long long lane = ((long long (*)(id, SEL))objc_msgSend)(anchored, @selector(anchoredLane));
            if (lane <= 0) continue;
            @try {
                CMTimeRange r = ((CMTimeRange (*)(id, SEL, id))STRET_MSG)(primary, erSel, anchored);
                double s = SpliceKit_secondsFromTime(r.start);
                double e = s + SpliceKit_secondsFromTime(r.duration);
                if (s < end - 1e-6 && e > start + 1e-6) [used addIndex:(NSUInteger)lane];
            } @catch (__unused NSException *ex) {}
        }
    }
    return used;
}

static double SKT_playheadSeconds(id timeline) {
    for (NSString *selName in @[@"currentSequenceTime", @"playheadTime"]) {
        SEL sel = NSSelectorFromString(selName);
        if ([timeline respondsToSelector:sel]) {
            CMTime t = ((CMTime (*)(id, SEL))STRET_MSG)(timeline, sel);
            if (t.timescale > 0) return SpliceKit_secondsFromTime(t);
        }
    }
    return 0;
}

NSDictionary *SpliceKit_handleTitlesAdd(NSDictionary *params) {
    BOOL dryRun = [params[@"dryRun"] boolValue];
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            NSDictionary *resolved = SKT_resolveTemplate(params);
            if (resolved[@"error"]) { result = resolved; return; }
            NSDictionary *template = resolved[@"template"];

            id timeline = SpliceKit_getActiveTimelineModule();
            id sequence = SKT_send(timeline, @"sequence");
            id primary = SKT_send(sequence, @"primaryObject");
            if (!sequence || !primary) { result = @{@"error": @"No project is open: open_project() first"}; return; }

            CMTime frame = SpliceKit_sequenceFrameDuration(sequence);
            if (frame.timescale <= 0 || frame.value <= 0) frame = SKT_time(1, 30);
            double frameSeconds = SpliceKit_secondsFromTime(frame);
            int32_t timescale = frame.timescale;

            // Times snap to the project's frames, like an edit in FCP.
            double at = [params[@"atSeconds"] respondsToSelector:@selector(doubleValue)]
                ? [params[@"atSeconds"] doubleValue] : SKT_playheadSeconds(timeline);
            double duration = [params[@"durationSeconds"] respondsToSelector:@selector(doubleValue)]
                ? [params[@"durationSeconds"] doubleValue] : 10.0;
            if (duration <= 0) { result = @{@"error": @"duration_seconds must be more than 0"}; return; }
            int64_t atFrames = llround(at / frameSeconds);
            int64_t durFrames = MAX((int64_t)1, llround(duration / frameSeconds));
            CMTime atTime = SKT_time(atFrames * frame.value, timescale);
            CMTime durTime = SKT_time(durFrames * frame.value, timescale);
            double atSnapped = SpliceKit_secondsFromTime(atTime);
            double endSnapped = atSnapped + SpliceKit_secondsFromTime(durTime);

            SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");
            NSArray *spine = SpliceKit_mixerArrayFromContainer(SKT_send(primary, @"containedItems"));
            double spineStart = 0, spineEnd = 0;
            if (spine.count && [primary respondsToSelector:erSel]) {
                CMTimeRange first = ((CMTimeRange (*)(id, SEL, id))STRET_MSG)(primary, erSel, spine.firstObject);
                CMTimeRange last = ((CMTimeRange (*)(id, SEL, id))STRET_MSG)(primary, erSel, spine.lastObject);
                spineStart = SpliceKit_secondsFromTime(first.start);
                spineEnd = SpliceKit_secondsFromTime(last.start) + SpliceKit_secondsFromTime(last.duration);
            }
            if (!spine.count || atSnapped < spineStart - 1e-6 || atSnapped >= spineEnd - 1e-6) {
                result = @{@"error": [NSString stringWithFormat:
                    @"at_seconds %.3f is outside the primary storyline (%.3f-%.3f s): a connected title needs a clip "
                     "or gap under its start", atSnapped, spineStart, spineEnd]};
                return;
            }

            // Lane: a number (above the primary storyline is 1, 2, ...; below is -1, ...), or
            // "auto" / nothing for the lowest free lane above, which is where FCP's Connect
            // puts a title. A lane already holding a clip in that time range is refused
            // rather than letting FCP push other clips around.
            NSIndexSet *used = SKT_lanesUsedBetween(primary, atSnapped, endSnapped);
            long long lane = 0;
            id laneParam = params[@"lane"];
            if ([laneParam isKindOfClass:[NSNumber class]]) {
                lane = [laneParam longLongValue];
                if (lane == 0) { result = @{@"error": @"lane 0 is the primary storyline; a title goes on lane 1 or above (or -1 and below)"}; return; }
                if (lane > 0 && [used containsIndex:(NSUInteger)lane]) {
                    result = @{@"error": [NSString stringWithFormat:
                        @"Lane %lld already has a clip between %.3f and %.3f s. Pick another lane or leave lane out "
                         "for the first free one.", lane, atSnapped, endSnapped]};
                    return;
                }
            } else if (laneParam && ![laneParam isKindOfClass:[NSNull class]] &&
                       !([laneParam isKindOfClass:[NSString class]] && [[laneParam lowercaseString] isEqualToString:@"auto"])) {
                result = @{@"error": @"lane must be a number or \"auto\""};
                return;
            }
            if (lane == 0) {
                lane = 1;
                while ([used containsIndex:(NSUInteger)lane]) lane++;
            }

            // Build the title off the timeline, at its final length, with its effect loaded
            // so its text fields and parameters exist; then style it; then connect it.
            Class genClass = objc_getClass("FFAnchoredGeneratorComponent");
            SEL initSel = NSSelectorFromString(@"initWithEffectID:loadEffectInForeground:duration:sampleDuration:");
            if (!genClass || ![genClass instancesRespondToSelector:initSel]) {
                result = @{@"error": @"This Final Cut Pro build has no FFAnchoredGeneratorComponent initializer SpliceKit knows"};
                return;
            }
            id gen = ((id (*)(id, SEL, id, BOOL, CMTime, CMTime))objc_msgSend)(
                [genClass alloc], initSel, template[@"effectID"], YES, durTime, frame);
            id effect = SKT_effectForClip(gen);
            if (!gen || !effect) { result = @{@"error": [NSString stringWithFormat:@"Final Cut Pro could not load %@", template[@"name"]]}; return; }

            NSDictionary *plan = nil;
            BOOL wantsChanges = NO;
            for (NSString *k in @[@"text", @"textFields", @"font", @"size", @"bold", @"italic", @"color", @"alignment", @"parameters"]) {
                if (params[k] && ![params[k] isKindOfClass:[NSNull class]]) wantsChanges = YES;
            }
            if (wantsChanges) {
                NSString *error = nil;
                plan = SKT_planChanges(effect, params, &error);
                if (!plan) { result = @{@"error": error}; return; }
            }

            NSMutableDictionary *out = [@{@"template": template, @"lane": @(lane),
                                          @"start": @(atSnapped), @"end": @(endSnapped),
                                          @"duration": @(endSnapped - atSnapped)} mutableCopy];
            if (plan) {
                out[@"parameters"] = plan[@"paramSummary"];
                out[@"textFields"] = plan[@"textSummary"];
            }
            if (dryRun) { out[@"status"] = @"dry_run"; result = out; return; }

            if (plan) SKT_applyPlan(effect, plan, nil);

            NSString *actionName = [NSString stringWithFormat:@"Add %@", [template[@"kind"] isEqualToString:@"generator"] ? @"Generator" : @"Title"];
            BOOL opened = SpliceKit_internalBeginEditGroupIfNeeded(sequence, actionName);
            NSError *anchorError = nil;
            BOOL ok = NO;
            // The point of the title that lands at atTime is its first frame. A generator's
            // own clock starts one hour in (its clippedRange starts at 3600 s), not at 0:
            // anchoring local time 0 put a title meant for 3 s at 3603 s. A title already
            // on a timeline reports the same point as its localAnchorTime.
            CMTime firstFrame = SKT_time(0, timescale);
            for (NSString *rangeSel in @[@"clippedRange", @"timeRange"]) {
                SEL sel = NSSelectorFromString(rangeSel);
                if (![gen respondsToSelector:sel]) continue;
                CMTimeRange r = ((CMTimeRange (*)(id, SEL))STRET_MSG)(gen, sel);
                if (r.start.timescale > 0) { firstFrame = r.start; break; }
            }
            @try {
                SEL anchorSel = NSSelectorFromString(@"actionAnchorItem:withAnchorInLocalTime:atTime:inContainer:inContainerAnchorLane:error:");
                ok = ((BOOL (*)(id, SEL, id, CMTime, CMTime, id, long long, NSError **))objc_msgSend)(
                    sequence, anchorSel, gen, firstFrame, atTime, primary, lane, &anchorError);
            } @finally {
                SpliceKit_internalEndEditGroupIfOpened(sequence, timeline, actionName, opened);
            }
            if (!ok) {
                result = @{@"error": [NSString stringWithFormat:@"Final Cut Pro did not connect the %@: %@",
                                      template[@"kind"], anchorError.localizedDescription ?: @"no reason given"]};
                return;
            }

            // Read back where it landed.
            NSMutableDictionary *landed = [NSMutableDictionary dictionary];
            SKT_addTimelinePlacement(landed, gen);
            long long landedLane = ((long long (*)(id, SEL))objc_msgSend)(gen, @selector(anchoredLane));
            out[@"handle"] = SpliceKit_storeHandle(gen);
            out[@"lane"] = @(landedLane);
            if (landed[@"start"]) {
                out[@"start"] = landed[@"start"];
                out[@"end"] = landed[@"end"];
                out[@"duration"] = landed[@"duration"];
            }
            BOOL placed = landed[@"start"] && fabs([landed[@"start"] doubleValue] - atSnapped) < frameSeconds / 2 &&
                          fabs([landed[@"duration"] doubleValue] - (endSnapped - atSnapped)) < frameSeconds / 2 &&
                          landedLane == lane;
            out[@"verified"] = @(placed);
            if (plan) {
                NSMutableArray *fields = [NSMutableArray array];
                for (NSNumber *field in [[plan[@"textNew"] allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
                    NSAttributedString *now = SKT_textForField(effect, field.unsignedIntegerValue);
                    [fields addObject:SKT_describeTextField(now ?: [[NSAttributedString alloc] init], field.unsignedIntegerValue)];
                }
                out[@"textFields"] = fields;
            }
            out[@"status"] = @"ok";
            out[@"undoName"] = actionName;
            result = out;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Adding the title failed"};
}
