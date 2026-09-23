//
//  SpliceKitOTIO.m
//  OpenTimelineIO (.otio JSON) to FCPXML converter used by the OTIO import
//  menu item and the fcpxml.import bridge path.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitLua.h"
#import "SpliceKitPlugins.h"
#import "SpliceKitCommandPalette.h"
#import "SpliceKitDebugUI.h"
#import "SpliceKitLiveCam.h"
#import "SpliceKitURLImport.h"
#import "SpliceKitMKV.h"
#import "SpliceKitVP9.h"
#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <Security/Security.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <math.h>
#import <signal.h>
#import <execinfo.h>
#import <time.h>
#import <setjmp.h>
#import <pthread.h>
#import "SpliceKitMenus.h"
#import "SpliceKitStrings.h"

#pragma mark - OpenTimelineIO Native Conversion

// ---- OTIO → FCPXML helpers ----

/// A copy of parsed JSON with every null removed.
///
/// JSON null becomes NSNull, which is a real object: `ref[@"available_range"]` is
/// truthy and the very next `[... objectForKeyedSubscript:]` kills the converter with
/// "unrecognized selector sent to instance". OpenTimelineIO writes
/// "available_range": null on any media reference whose full extent is unknown, and
/// "color": null on every track, so a perfectly ordinary .otio file brought the whole
/// conversion down. Strip them once, at the door, rather than guarding thirty chained
/// subscripts.
static id otio_withoutNulls(id value) {
    if (!value || value == (id)kCFNull) return nil;
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *source = value;
        NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:source.count];
        for (id key in source) {
            id cleaned = otio_withoutNulls(source[key]);
            if (cleaned) out[key] = cleaned;
        }
        return out;
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSArray *source = value;
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:source.count];
        for (id item in source) {
            id cleaned = otio_withoutNulls(item);
            if (cleaned) [out addObject:cleaned];
        }
        return out;
    }
    return value;
}

static long long otio_gcd(long long a, long long b) {
    a = llabs(a); b = llabs(b);
    while (b) { long long t = b; b = a % b; a = t; }
    return a ?: 1;
}

/// Convert OTIO RationalTime dict {value, rate} to FCPXML time string (e.g. "385385/24000s").
/// Uses canonical SMPTE timebases to keep frame-exact alignment.
static NSString *otio_time(NSDictionary *rt) {
    if (!rt) return @"0s";
    double val = [rt[@"value"] doubleValue];
    double rate = [rt[@"rate"] doubleValue];
    if (rate <= 0 || val == 0) return @"0s";

    // Map known SMPTE rates to canonical numerator multiplier and denominator.
    // OTIO stores frame counts at the clip rate. FCPXML needs rational seconds
    // aligned to the sequence timebase so every time lands on a frame boundary.
    // For 23.976fps: value * 1001 / 24000 = exact seconds
    //
    // IMPORTANT: Do NOT GCD-simplify for known rates. FCP requires the canonical
    // denominator (e.g. 24000) — simplified fractions like 1001/800 (= 30030/24000)
    // cause "unexpected value" errors even though they're mathematically equal.
    long long frameVal = (long long)round(val);
    long long num, den;
    BOOL canonical = NO;

    if (fabs(rate - 24000.0/1001.0) < 0.01) {       // 23.976
        num = frameVal * 1001; den = 24000; canonical = YES;
    } else if (fabs(rate - 24.0) < 0.01) {
        num = frameVal * 100;  den = 2400;  canonical = YES;
    } else if (fabs(rate - 25.0) < 0.01) {
        num = frameVal * 100;  den = 2500;  canonical = YES;
    } else if (fabs(rate - 30000.0/1001.0) < 0.01) { // 29.97
        num = frameVal * 1001; den = 30000; canonical = YES;
    } else if (fabs(rate - 30.0) < 0.01) {
        num = frameVal * 100;  den = 3000;  canonical = YES;
    } else if (fabs(rate - 50.0) < 0.01) {
        num = frameVal * 100;  den = 5000;  canonical = YES;
    } else if (fabs(rate - 60000.0/1001.0) < 0.01) { // 59.94
        num = frameVal * 1001; den = 60000; canonical = YES;
    } else if (fabs(rate - 60.0) < 0.01) {
        num = frameVal * 100;  den = 6000;  canonical = YES;
    } else {
        // Unknown rate — GCD-simplify
        num = (long long)round(val * 1000.0);
        den = (long long)round(rate * 1000.0);
    }

    if (!canonical) {
        long long g = otio_gcd(num, den);
        num /= g; den /= g;
    }
    if (num == 0) return @"0s";
    if (den == 1) return [NSString stringWithFormat:@"%llds", num];
    return [NSString stringWithFormat:@"%lld/%llds", num, den];
}

/// Convert OTIO RationalTime to seconds.
static double otio_sec(NSDictionary *rt) {
    if (!rt) return 0;
    double val = [rt[@"value"] doubleValue];
    double rate = [rt[@"rate"] doubleValue];
    return (rate > 0) ? val / rate : 0;
}

/// Get the media reference from an OTIO Clip dict.
static NSDictionary *otio_mediaRef(NSDictionary *clip) {
    NSDictionary *refs = clip[@"media_references"];
    NSString *key = clip[@"active_media_reference_key"] ?: @"DEFAULT_MEDIA";
    NSDictionary *ref = refs[key];
    if (!ref) ref = clip[@"media_reference"];
    return ref;
}

/// Check if a media reference is a usable external file.
static BOOL otio_isExternal(NSDictionary *ref) {
    NSString *schema = ref[@"OTIO_SCHEMA"] ?: @"";
    return [schema hasPrefix:@"ExternalReference."] && ref[@"target_url"] != nil;
}

/// Normalize OTIO media references to valid FCPXML URLs.
/// Some producers write absolute POSIX paths into target_url even though FCPXML
/// expects URL strings. FCP can silently drop clips when these are not encoded.
static NSString *otio_mediaSrcURL(NSString *targetURL) {
    if (!targetURL || targetURL.length == 0) return @"";
    if ([targetURL containsString:@"://"]) return targetURL;
    if ([targetURL hasPrefix:@"/"]) {
        return [NSURL fileURLWithPath:targetURL].absoluteString;
    }
    return targetURL;
}

/// Compute clip source start relative to asset start=0.
/// Returns the in-point in seconds for the start= attribute.
static NSDictionary *otio_dict(id value);

static double otio_sourceStart(NSDictionary *clip) {
    NSDictionary *sr = otio_dict(clip[@"source_range"]);
    NSDictionary *ref = otio_mediaRef(clip);
    double srStart = otio_sec(sr[@"start_time"]);
    // When the media reference says where the file itself starts, the in-point is
    // written as it is: the <asset> carries that same start, and Final Cut Pro wants
    // the two to agree. Subtracting it to get a relative in-point, against an asset
    // pinned to start="0s", is what made FCP drop every clip on import.
    if (otio_dict(ref[@"available_range"])) return srStart;
    // No available_range → use 0 (safer than absolute Premiere timecodes)
    if (!otio_isExternal(ref)) return 0;
    return srStart;
}

/// Return FCPXML-specific metadata using either the modern upstream key ("fcpx")
/// or the older contrib adapter namespace ("fcpx_xml").
static NSDictionary *otio_fcpxMeta(NSDictionary *obj) {
    NSDictionary *metadata = [obj[@"metadata"] isKindOfClass:[NSDictionary class]] ? obj[@"metadata"] : @{};
    NSDictionary *fcpx = [metadata[@"fcpx"] isKindOfClass:[NSDictionary class]] ? metadata[@"fcpx"] : nil;
    if (fcpx) return fcpx;
    NSDictionary *fcpxXml = [metadata[@"fcpx_xml"] isKindOfClass:[NSDictionary class]] ? metadata[@"fcpx_xml"] : nil;
    return fcpxXml ?: @{};
}

static NSDictionary *otio_dict(id value) {
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

static NSArray *otio_array(id value) {
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

static NSString *otio_string(id value) {
    if (!value || value == (id)kCFNull) return nil;
    return [value isKindOfClass:[NSString class]] ? value : [value description];
}

/// Read values from both SpliceKit's older flat metadata and PR #7's
/// structured metadata shape, e.g. fcpx.asset.attrs.uid or fcpx.effect.resource.uid.
static id otio_fcpxNestedValue(NSDictionary *meta, NSString *section, NSString *key) {
    id flat = meta[key];
    if (flat) return flat;
    NSDictionary *sectionDict = otio_dict(meta[section]);
    id sectionValue = sectionDict[key];
    if (sectionValue) return sectionValue;
    NSDictionary *attrs = otio_dict(sectionDict[@"attrs"]);
    id attrValue = attrs[key];
    if (attrValue) return attrValue;
    NSDictionary *resource = otio_dict(sectionDict[@"resource"]);
    return resource[key];
}

static NSString *otio_fcpxAssetValue(NSDictionary *meta, NSString *key) {
    return otio_string(otio_fcpxNestedValue(meta, @"asset", key));
}

static NSArray *otio_fcpxAssetMediaReps(NSDictionary *meta) {
    NSArray *mediaReps = otio_array(meta[@"media_reps"]);
    if (mediaReps) return mediaReps;
    NSDictionary *asset = otio_dict(meta[@"asset"]);
    return otio_array(asset[@"media_reps"]) ?: @[];
}

static NSString *otio_fcpxEffectRef(NSDictionary *meta) {
    return otio_string(
        meta[@"ref"] ?:
        otio_dict(meta[@"attrs"])[@"ref"] ?:
        otio_dict(meta[@"resource"])[@"id"] ?:
        otio_fcpxNestedValue(meta, @"effect", @"ref")
    );
}

static NSString *otio_fcpxEffectUID(NSDictionary *meta) {
    return otio_string(
        meta[@"uid"] ?:
        otio_dict(meta[@"resource"])[@"uid"] ?:
        otio_fcpxNestedValue(meta, @"effect", @"uid")
    );
}

static NSString *otio_fcpxEffectName(NSDictionary *effect, NSDictionary *meta) {
    return otio_string(
        effect[@"effect_name"] ?:
        effect[@"name"] ?:
        meta[@"name"] ?:
        otio_dict(meta[@"resource"])[@"name"] ?:
        otio_fcpxNestedValue(meta, @"effect", @"name")
    ) ?: @"";
}

static NSString *otio_fcpxEffectElement(NSDictionary *meta) {
    return otio_string(meta[@"element"] ?: meta[@"type"] ?: otio_fcpxNestedValue(meta, @"effect", @"element"));
}

static id otio_fcpxEffectParams(NSDictionary *meta) {
    return meta[@"params"] ?: otio_fcpxNestedValue(meta, @"effect", @"params");
}

static void otio_appendParams(NSMutableString *xml, id params, NSString *indent) {
    if ([params isKindOfClass:[NSDictionary class]]) {
        for (NSString *pName in (NSDictionary *)params) {
            [xml appendFormat:@"%@<param name=\"%@\" value=\"%@\"/>",
                indent, SpliceKit_escapeXML(pName), SpliceKit_escapeXML([(NSDictionary *)params objectForKey:pName])];
        }
        return;
    }

    if (![params isKindOfClass:[NSArray class]]) return;
    for (NSDictionary *param in (NSArray *)params) {
        if (![param isKindOfClass:[NSDictionary class]]) continue;
        NSMutableString *attrs = [NSMutableString string];
        for (NSString *key in param) {
            id val = param[key];
            if (!val || val == (id)kCFNull) continue;
            [attrs appendFormat:@" %@=\"%@\"", key, SpliceKit_escapeXML(val)];
        }
        if (attrs.length > 0) {
            [xml appendFormat:@"%@<param%@/>", indent, attrs];
        }
    }
}

/// Return GeneratorReference parameters if present.
static NSDictionary *otio_generatorParams(NSDictionary *ref) {
    NSDictionary *params = [ref[@"parameters"] isKindOfClass:[NSDictionary class]] ? ref[@"parameters"] : nil;
    return params ?: @{};
}

/// Identify generator references that should roundtrip as FCP titles.
static BOOL otio_isTitleGenerator(NSDictionary *ref) {
    NSString *schema = ref[@"OTIO_SCHEMA"] ?: @"";
    if (![schema hasPrefix:@"GeneratorReference."]) return NO;

    NSString *kind = ref[@"generator_kind"] ?: @"";
    if ([kind isEqualToString:@"Title"] ||
        [kind isEqualToString:@"title"] ||
        [kind isEqualToString:@"fcpx.title"]) {
        return YES;
    }

    NSDictionary *params = otio_generatorParams(ref);
    return params[@"text_xml"] != nil || params[@"text_style_def_xml"] != nil;
}

// ---- Main converter ----

/// Extract text from Premiere-style GeneratorReference clips.
/// Premiere stores title text as base64-encoded AE binary blobs.
static NSString *otio_extractPremiereText(NSDictionary *clip) {
    NSArray *effects = clip[@"effects"] ?: @[];
    for (NSDictionary *effect in effects) {
        NSDictionary *ppro = effect[@"metadata"][@"PremierePro_OTIO"] ?: @{};
        if (![ppro[@"MatchName"] isEqualToString:@"AE.ADBE Text"]) continue;
        for (NSDictionary *param in ppro[@"Parameters"] ?: @[]) {
            if (![param[@"DisplayName"] isEqualToString:@"Source Text"]) continue;
            id val = param[@"StartValue"];
            if ([val isKindOfClass:[NSDictionary class]]) val = val[@"Value"];
            if (![val isKindOfClass:[NSString class]]) continue;
            NSData *decoded = [[NSData alloc] initWithBase64EncodedString:(NSString *)val options:0];
            if (!decoded || decoded.length == 0) continue;
            // Scan for ASCII text fragments — the longest meaningful one is the title text
            const uint8_t *bytes = decoded.bytes;
            NSUInteger len = decoded.length;
            NSMutableArray *fragments = [NSMutableArray array];
            NSUInteger i = 0;
            while (i < len) {
                if (bytes[i] >= 0x20 && bytes[i] < 0x7f) {
                    NSUInteger start = i;
                    while (i < len && bytes[i] >= 0x20 && bytes[i] < 0x7f) i++;
                    NSString *seg = [[NSString alloc] initWithBytes:bytes + start
                                                             length:i - start
                                                           encoding:NSASCIIStringEncoding];
                    if (seg && seg.length >= 2) {
                        // Filter out known font names and binary metadata
                        NSArray *skipPrefixes = @[@"Adobe", @"Myriad", @"Mini", @"Kozuka",
                                                  @"Source", @"Times", @"Arial", @"Helvet"];
                        BOOL skip = NO;
                        for (NSString *prefix in skipPrefixes) {
                            if ([seg hasPrefix:prefix]) { skip = YES; break; }
                        }
                        if (!skip) [fragments addObject:seg];
                    }
                } else {
                    i++;
                }
            }
            // Return the last meaningful fragment (Premiere puts text near the end)
            return fragments.lastObject;
        }
    }
    return nil;
}

/// Build a <title> FCPXML element string from an OTIO GeneratorReference clip.
/// titleEffectRef is the resource ID for the Basic Title effect (e.g. "r4").
static NSString *otio_buildTitleElement(NSDictionary *child, NSDictionary *ref,
                                        NSString *offsetStr, NSString *durationStr,
                                        int *tsCounter, NSString *titleEffectRef) {
    NSDictionary *genMeta = otio_fcpxMeta(ref);
    NSDictionary *params = otio_generatorParams(ref);
    NSString *clipName = SpliceKit_escapeXML(child[@"name"] ?: @"Title");

    // Get text content: FCPXML metadata > Premiere extraction > clip name
    NSString *text = genMeta[@"text"] ?: params[@"text"];
    if (!text || text.length == 0) {
        text = otio_extractPremiereText(child);
    }
    if (!text || text.length == 0) {
        text = child[@"name"] ?: @"Title";
    }

    NSMutableString *xml = [NSMutableString string];

    // Build text-style-def and text body
    NSArray *paramXml = [params[@"param_xml"] isKindOfClass:[NSArray class]] ? params[@"param_xml"] : nil;
    NSArray *rawTextXml = [params[@"text_xml"] isKindOfClass:[NSArray class]] ? params[@"text_xml"] : nil;
    NSArray *rawStyleDefs = [params[@"text_style_def_xml"] isKindOfClass:[NSArray class]] ? params[@"text_style_def_xml"] : nil;
    NSArray *textSegments = genMeta[@"text_segments"];
    NSArray *styleDefs = genMeta[@"text_style_defs"];

    NSString *tsId = [NSString stringWithFormat:@"ts%d", (*tsCounter)++];

    // Use round-tripped ref or fall back to Basic Title effect
    NSString *effectRef = genMeta[@"ref"] ?: titleEffectRef;
    [xml appendFormat:@"<title name=\"%@\" ref=\"%@\" offset=\"%@\" duration=\"%@\" start=\"3600s\"",
        clipName, effectRef, offsetStr, durationStr];

    // Add role if present
    NSString *role = genMeta[@"role"] ?: params[@"role"];
    if (role) [xml appendFormat:@" role=\"%@\"", SpliceKit_escapeXML(role)];
    [xml appendString:@">\n"];

    // Motion/title parameters must precede text blocks.
    if (paramXml && paramXml.count > 0) {
        for (NSString *raw in paramXml) {
            if (![raw isKindOfClass:[NSString class]] || raw.length == 0) continue;
            [xml appendFormat:@"                            %@\n", raw];
        }
    }

    // Text content
    if (rawTextXml && rawTextXml.count > 0) {
        for (NSString *raw in rawTextXml) {
            if (![raw isKindOfClass:[NSString class]] || raw.length == 0) continue;
            [xml appendFormat:@"                            %@\n", raw];
        }
    } else if (textSegments && [textSegments isKindOfClass:[NSArray class]] && textSegments.count > 0) {
        [xml appendString:@"                            <text>"];
        for (NSDictionary *seg in textSegments) {
            NSString *segRef = seg[@"ref"] ?: @"";
            NSString *segText = seg[@"text"] ?: @"";
            [xml appendFormat:@"<text-style ref=\"%@\">%@</text-style>",
                SpliceKit_escapeXML(segRef), SpliceKit_escapeXML(segText)];
        }
        [xml appendString:@"</text>\n"];
    } else {
        [xml appendFormat:@"                            <text><text-style ref=\"%@\">%@</text-style></text>\n",
            tsId, SpliceKit_escapeXML(text)];
    }

    // Text style definitions
    if (rawStyleDefs && rawStyleDefs.count > 0) {
        for (NSString *raw in rawStyleDefs) {
            if (![raw isKindOfClass:[NSString class]] || raw.length == 0) continue;
            [xml appendFormat:@"                            %@\n", raw];
        }
    } else if (styleDefs && [styleDefs isKindOfClass:[NSArray class]] && styleDefs.count > 0) {
        for (NSDictionary *sd in styleDefs) {
            NSString *sdId = sd[@"id"] ?: tsId;
            NSDictionary *attrs = sd[@"attrs"] ?: @{};
            NSMutableString *attrStr = [NSMutableString string];
            for (NSString *key in attrs) {
                [attrStr appendFormat:@" %@=\"%@\"", key, SpliceKit_escapeXML(attrs[key])];
            }
            [xml appendFormat:@"                            <text-style-def id=\"%@\">"
                @"<text-style%@/></text-style-def>\n", SpliceKit_escapeXML(sdId), attrStr];
        }
    } else {
        // Default style — matches FCP's own Basic Title output
        [xml appendFormat:@"                            <text-style-def id=\"%@\">"
            @"<text-style font=\"Helvetica\" fontSize=\"63\" fontFace=\"Regular\" fontColor=\"1 1 1 1\" alignment=\"center\"/>"
            @"</text-style-def>\n", tsId];
    }

    // Restore adjust-transform if present
    NSDictionary *adjTransform = genMeta[@"adjust_transform"];
    if (adjTransform && [adjTransform isKindOfClass:[NSDictionary class]]) {
        NSMutableString *attrStr = [NSMutableString string];
        for (NSString *key in adjTransform) {
            [attrStr appendFormat:@" %@=\"%@\"", key, SpliceKit_escapeXML(adjTransform[key])];
        }
        [xml appendFormat:@"                            <adjust-transform%@/>\n", attrStr];
    }

    [xml appendString:@"                        </title>"];
    return xml;
}

/// Parse a .otio JSON file and convert to FCPXML 1.14 string.
/// Handles multi-track, transitions, titles, markers, source trimming, connected clips.
/// The event an OTIO import should land in: the library's first event, so an import
/// does not sprinkle a new event across the library every time.
///
/// The converter used to name the event after the timeline, which meant every
/// import_otio call left an event behind — and once its project was removed, an empty
/// one. Final Cut Pro's own importer needs SOME <event name=...>, so this picks the one
/// already there.
static NSString *otio_defaultEventName(void) {
    @try {
        Class libDocClass = objc_getClass("FFLibraryDocument");
        if (!libDocClass) return nil;
        id libs = ((id (*)(id, SEL))objc_msgSend)((id)libDocClass,
            NSSelectorFromString(@"copyActiveLibraries"));
        if (![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) return nil;
        for (id lib in (NSArray *)libs) {
            SEL eventsSel = NSSelectorFromString(@"events");
            if (![lib respondsToSelector:eventsSel]) continue;
            id events = ((id (*)(id, SEL))objc_msgSend)(lib, eventsSel);
            if (![events isKindOfClass:[NSArray class]] || [(NSArray *)events count] == 0) continue;
            id event = [(NSArray *)events firstObject];
            if ([event respondsToSelector:@selector(displayName)]) {
                NSString *name = ((id (*)(id, SEL))objc_msgSend)(event, @selector(displayName));
                if (name.length > 0) return name;
            }
        }
    } @catch (NSException *e) {}
    return nil;
}

NSString *SpliceKit_otioToFCPXMLInEvent(NSString *otioPath, NSString *eventName) {
    NSData *data = [NSData dataWithContentsOfFile:otioPath];
    if (!data) { SpliceKit_log(@"[OTIO] Could not read: %@", otioPath); return nil; }

    NSError *jsonErr = nil;
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
    if (!root || jsonErr) { SpliceKit_log(@"[OTIO] JSON error: %@", jsonErr); return nil; }
    root = otio_withoutNulls(root);
    if (![root isKindOfClass:[NSDictionary class]]) {
        SpliceKit_log(@"[OTIO] Top level is not an object");
        return nil;
    }
    if (![root[@"OTIO_SCHEMA"] hasPrefix:@"Timeline."]) { SpliceKit_log(@"[OTIO] Not a Timeline"); return nil; }

    NSString *projectName = root[@"name"] ?: @"";
    if (![projectName isKindOfClass:[NSString class]] || projectName.length == 0) {
        projectName = otioPath.lastPathComponent.stringByDeletingPathExtension ?: @"Imported";
    }
    NSArray *tracks = root[@"tracks"][@"children"] ?: @[];

    // Resolution from metadata (Premiere stores it in PremierePro_OTIO)
    NSDictionary *stackMeta = root[@"tracks"][@"metadata"] ?: @{};
    NSDictionary *pMeta = stackMeta[@"PremierePro_OTIO"] ?: @{};
    int width = [pMeta[@"VideoResolution"][@"width"] intValue] ?: 1920;
    int height = [pMeta[@"VideoResolution"][@"height"] intValue] ?: 1080;

    // Separate video/audio tracks
    NSMutableArray *videoTracks = [NSMutableArray array];
    NSMutableArray *audioTracks = [NSMutableArray array];
    for (NSDictionary *t in tracks) {
        if ([t[@"kind"] isEqualToString:@"Audio"]) [audioTracks addObject:t];
        else [videoTracks addObject:t];
    }

    // Detect fps from first video clip
    double fps = 24.0;
    for (NSDictionary *t in videoTracks) {
        for (NSDictionary *c in t[@"children"] ?: @[]) {
            double r = [c[@"source_range"][@"duration"][@"rate"] doubleValue];
            if (r > 1) { fps = r; goto found; }
        }
    }
    found:;

    // FCP format name + frame duration
    NSString *fmtName, *frameDur;
    struct { double lo, hi; const char *name; const char *dur; } fmts[] = {
        {23.9, 24.0, "2398", "1001/24000s"}, {24.0, 24.1, "24", "100/2400s"},
        {24.9, 25.1, "25", "100/2500s"}, {29.9, 30.0, "2997", "1001/30000s"},
        {30.0, 30.1, "30", "100/3000s"}, {49.9, 50.1, "50", "100/5000s"},
        {59.9, 60.0, "5994", "1001/60000s"}, {60.0, 60.1, "60", "100/6000s"},
    };
    fmtName = [NSString stringWithFormat:@"FFVideoFormat%dp%d", height, (int)round(fps)];
    frameDur = [NSString stringWithFormat:@"100/%ds", (int)round(fps * 100)];
    for (int i = 0; i < 8; i++) {
        if (fps >= fmts[i].lo && fps < fmts[i].hi) {
            fmtName = [NSString stringWithFormat:@"FFVideoFormat%dp%s", height, fmts[i].name];
            frameDur = @(fmts[i].dur);
            break;
        }
    }

    // ---- Effect resources ----
    // Standard FCP effect IDs (stable across all installations).
    // r2 = Cross Dissolve, r3 = Audio Crossfade, r4 = Basic Title
    NSString *crossDissolveEffectId = @"r2";
    NSString *audioCrossfadeEffectId = @"r3";
    NSString *basicTitleEffectId = @"r4";

    // ---- Collect unique assets ----
    NSMutableDictionary *assets = [NSMutableDictionary dictionary]; // targetUrl → assetId
    NSMutableString *assetXml = [NSMutableString string];
    NSMutableDictionary *effectRefs = [NSMutableDictionary dictionary]; // effectRef → effectId
    NSMutableString *effectXml = [NSMutableString string];
    int resCounter = 5; // r1=format, r2=cross dissolve, r3=audio crossfade, r4=basic title

    for (NSDictionary *t in tracks) {
        for (NSDictionary *c in t[@"children"] ?: @[]) {
            if (![c[@"OTIO_SCHEMA"] hasPrefix:@"Clip."]) continue;
            NSDictionary *ref = otio_mediaRef(c);
            if (!otio_isExternal(ref)) continue;
            NSString *url = ref[@"target_url"];
            if (assets[url]) continue;

            NSString *aid = [NSString stringWithFormat:@"r%d", resCounter++];
            assets[url] = aid;

            // Duration and start from available_range (the whole media) when the file
            // says how long it is, otherwise from this clip's own range.
            NSDictionary *availableRange = otio_dict(ref[@"available_range"]);
            NSDictionary *durRT = availableRange ? availableRange[@"duration"]
                                                 : otio_dict(c[@"source_range"])[@"duration"];
            NSString *durStr = otio_time(durRT);

            // The media's own start timecode, NOT 0s.
            //
            // Final Cut Pro validates a clip's in-point against the asset's start, and
            // silently drops any clip that falls outside it — no error, the import
            // reports success and the spine comes back empty. Camera media here starts
            // at 1705373670/30000s (about 15 hours of timecode), so every clip written
            // with start="0s" against an asset pinned to start="0s" was thrown away:
            // a four-clip timeline imported as nothing but its one connected clip.
            NSString *assetStartStr = @"0s";
            if (availableRange && availableRange[@"start_time"]) {
                assetStartStr = otio_time(otio_dict(availableRange[@"start_time"]));
            }

            // hasVideo/hasAudio: check track kind
            NSString *kind = t[@"kind"] ?: @"Video";
            BOOL isVideo = [kind isEqualToString:@"Video"];

            // Preserve asset metadata from FCPXML round-trip (uid, audioChannels, etc.)
            NSDictionary *refMeta = otio_fcpxMeta(ref);
            NSMutableString *assetAttrs = [NSMutableString stringWithFormat:
                @"        <asset name=\"%@\" format=\"r1\" id=\"%@\" duration=\"%@\" start=\"%@\" hasVideo=\"%d\" hasAudio=\"1\"",
                SpliceKit_escapeXML(c[@"name"] ?: @"Clip"), aid, durStr, assetStartStr, isVideo ? 1 : 0];
            // Optional metadata attributes
            for (NSString *metaKey in @[@"uid", @"audioSources", @"audioChannels",
                                        @"audioRate", @"videoSources"]) {
                id val = otio_fcpxAssetValue(refMeta, metaKey);
                if (val) [assetAttrs appendFormat:@" %@=\"%@\"", metaKey, val];
            }
            [assetAttrs appendString:@">\n"];
            [assetXml appendString:assetAttrs];

            // Preserve media-rep attributes from FCPXML adapter PR #7 metadata.
            // Fall back to target_url when the OTIO came from another producer.
            NSString *uidVal = otio_fcpxAssetValue(refMeta, @"uid");
            NSString *srcURL = otio_mediaSrcURL(url);
            NSDictionary *mediaRep = nil;
            for (NSDictionary *rep in otio_fcpxAssetMediaReps(refMeta)) {
                if (![rep isKindOfClass:[NSDictionary class]]) continue;
                if (!mediaRep || [rep[@"kind"] isEqualToString:@"original-media"]) {
                    mediaRep = rep;
                }
                if ([rep[@"kind"] isEqualToString:@"original-media"]) break;
            }
            if (mediaRep) {
                NSMutableString *repAttrs = [NSMutableString string];
                NSMutableSet *seenRepKeys = [NSMutableSet set];
                for (NSString *key in mediaRep) {
                    id val = mediaRep[key];
                    if (!val || val == (id)kCFNull) continue;
                    [seenRepKeys addObject:key];
                    [repAttrs appendFormat:@" %@=\"%@\"", key, SpliceKit_escapeXML(val)];
                }
                if (![seenRepKeys containsObject:@"src"]) {
                    [repAttrs appendFormat:@" src=\"%@\"", SpliceKit_escapeXML(srcURL)];
                }
                if (uidVal.length > 0 && ![seenRepKeys containsObject:@"sig"]) {
                    [repAttrs appendFormat:@" sig=\"%@\"", SpliceKit_escapeXML(uidVal)];
                }
                [assetXml appendFormat:@"            <media-rep%@/>\n        </asset>\n", repAttrs];
            } else if (uidVal && uidVal.length > 0) {
                [assetXml appendFormat:
                    @"            <media-rep kind=\"original-media\" sig=\"%@\" src=\"%@\"/>\n"
                    @"        </asset>\n", SpliceKit_escapeXML(uidVal), SpliceKit_escapeXML(srcURL)];
            } else {
                [assetXml appendFormat:
                    @"            <media-rep kind=\"original-media\" src=\"%@\"/>\n"
                    @"        </asset>\n", SpliceKit_escapeXML(srcURL)];
            }

            // Collect effect resources from clip effects
            for (NSDictionary *eff in c[@"effects"] ?: @[]) {
                NSDictionary *fcpxMeta = otio_fcpxMeta(eff);
                NSString *eRef = otio_fcpxEffectRef(fcpxMeta);
                NSString *eName = otio_fcpxEffectName(eff, fcpxMeta);
                // Skip adjust-* (not effect resources) and empty refs
                if (!eRef || eRef.length == 0) continue;
                if ([eName hasPrefix:@"adjust-"]) continue;
                if (effectRefs[eRef]) continue;
                NSString *eid = [NSString stringWithFormat:@"r%d", resCounter++];
                effectRefs[eRef] = eid;
                NSString *uid = otio_fcpxEffectUID(fcpxMeta) ?: @"";
                if (uid.length > 0) {
                    [effectXml appendFormat:
                        @"        <effect id=\"%@\" name=\"%@\" uid=\"%@\"/>\n",
                        eid, SpliceKit_escapeXML(eName), SpliceKit_escapeXML(uid)];
                } else {
                    [effectXml appendFormat:
                        @"        <effect id=\"%@\" name=\"%@\"/>\n",
                        eid, SpliceKit_escapeXML(eName)];
                }
            }
        }
    }

    // ---- Build spine items array from primary video track ----
    // Accumulate frame counts (not seconds) to preserve frame-exact alignment.
    NSDictionary *primaryTrack = videoTracks.firstObject;
    NSMutableArray *spineItems = [NSMutableArray array];

    // Helper: build an offset RationalTime dict from accumulated frames
    // Uses the primary track's rate for all offsets so they align to the sequence timebase.
    double (^frameVal)(NSDictionary *) = ^double(NSDictionary *rt) {
        return rt ? [rt[@"value"] doubleValue] : 0;
    };
    double (^frameRate)(NSDictionary *) = ^double(NSDictionary *rt) {
        double r = rt ? [rt[@"rate"] doubleValue] : 0;
        return r > 0 ? r : fps;
    };

    double runFrames = 0; // accumulated offset in frames at primary track rate

    // Pre-scan: for each clip, determine how many frames are eaten by
    // adjacent transitions (in_offset from following transition, out_offset from preceding).
    NSArray *primaryChildren = primaryTrack[@"children"] ?: @[];
    NSInteger pCount = primaryChildren.count;

    for (NSInteger ci = 0; ci < pCount; ci++) {
        NSDictionary *child = primaryChildren[ci];
        NSString *schema = child[@"OTIO_SCHEMA"] ?: @"";
        NSDictionary *srDur = child[@"source_range"][@"duration"];
        double durFrames = frameVal(srDur);
        double rate = frameRate(srDur);
        double durSec = (rate > 0) ? durFrames / rate : 0;

        // All time strings use the clip's native RationalTime directly
        // (no seconds→frames round-trip). For offsets, build from accumulated frames.
        NSDictionary *offRT = @{@"value": @(runFrames), @"rate": @(rate)};

        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        item[@"timelineStartSec"] = @(runFrames / rate);
        item[@"timelineDurSec"] = @(durSec);
        item[@"rate"] = @(rate);
        item[@"childXml"] = [NSMutableString string];

        if ([schema hasPrefix:@"Transition."]) {
            NSDictionary *inRT = child[@"in_offset"];
            NSDictionary *outRT = child[@"out_offset"];
            double inFrames = frameVal(inRT);
            double outFrames = frameVal(outRT);
            double totalFrames = inFrames + outFrames;
            double tRate = frameRate(inRT);
            NSDictionary *durRT = @{@"value": @(totalFrames), @"rate": @(tRate)};
            NSDictionary *transOffRT = @{@"value": @(runFrames - inFrames), @"rate": @(tRate)};

            item[@"type"] = @"transition";
            if (inFrames == 0 && outFrames > 0) {
                // Fade-in from black (no effect reference needed)
                item[@"openTag"] = [NSString stringWithFormat:
                    @"<transition offset=\"%@\" duration=\"%@\">\n"
                    @"                        <filter-video ref=\"%@\" enabled=\"0\"/>\n"
                    @"                    </transition>",
                    otio_time(transOffRT), otio_time(durRT), crossDissolveEffectId];
            } else if (inFrames > 0 && outFrames == 0) {
                // Fade-out to black
                item[@"openTag"] = [NSString stringWithFormat:
                    @"<transition offset=\"%@\" duration=\"%@\">\n"
                    @"                        <filter-video ref=\"%@\" enabled=\"0\"/>\n"
                    @"                    </transition>",
                    otio_time(transOffRT), otio_time(durRT), crossDissolveEffectId];
            } else {
                // Cross dissolve — needs effect references
                item[@"openTag"] = [NSString stringWithFormat:
                    @"<transition name=\"Cross Dissolve\" offset=\"%@\" duration=\"%@\">\n"
                    @"                        <filter-video ref=\"%@\" name=\"Cross Dissolve\"/>\n"
                    @"                        <filter-audio ref=\"%@\" name=\"Audio Crossfade\"/>\n"
                    @"                    </transition>",
                    otio_time(transOffRT), otio_time(durRT),
                    crossDissolveEffectId, audioCrossfadeEffectId];
            }
            // Transitions overlap — do NOT advance runFrames
        } else if ([schema hasPrefix:@"Gap."]) {
            item[@"type"] = @"gap";
            item[@"sourceStartSec"] = @(3600.0);
            item[@"openTag"] = [NSString stringWithFormat:
                @"<gap name=\"Gap\" offset=\"%@\" duration=\"%@\" start=\"3600s\">",
                otio_time(offRT), otio_time(srDur)];
            runFrames += durFrames;
        } else if ([schema hasPrefix:@"Clip."]) {
            NSDictionary *ref = otio_mediaRef(child);
            NSString *refSchema = ref[@"OTIO_SCHEMA"] ?: @"";
            if (otio_isTitleGenerator(ref)) {
                // Title generator clip — build <title> element
                static int tsCounter = 1;
                NSString *titleXml = otio_buildTitleElement(child, ref,
                    otio_time(offRT), otio_time(srDur), &tsCounter, basicTitleEffectId);
                item[@"type"] = @"title";
                item[@"sourceStartSec"] = @(3600.0);
                item[@"openTag"] = titleXml;
                runFrames += durFrames;
                goto clipDone;
            } else if ([refSchema hasPrefix:@"GeneratorReference."]) {
                // Non-title generators do not map cleanly to FCPXML in this path.
                item[@"type"] = @"gap";
                item[@"sourceStartSec"] = @(3600.0);
                item[@"openTag"] = [NSString stringWithFormat:
                    @"<gap name=\"%@\" offset=\"%@\" duration=\"%@\" start=\"3600s\">",
                    SpliceKit_escapeXML(child[@"name"] ?: @"Gap"), otio_time(offRT), otio_time(srDur)];
            } else if (!otio_isExternal(ref)) {
                item[@"type"] = @"gap";
                item[@"sourceStartSec"] = @(3600.0);
                item[@"openTag"] = [NSString stringWithFormat:
                    @"<gap name=\"%@\" offset=\"%@\" duration=\"%@\" start=\"3600s\">",
                    SpliceKit_escapeXML(child[@"name"] ?: @"Gap"), otio_time(offRT), otio_time(srDur)];
            } else {
                NSString *aid = assets[ref[@"target_url"]] ?: @"r2";
                double srcStartSec = otio_sourceStart(child);
                double srcStartFrames = round(srcStartSec * rate);
                BOOL enabled = child[@"enabled"] == nil || [child[@"enabled"] boolValue];

                // Check for adjacent transitions that eat into this clip's duration.
                // A preceding transition's out_offset eats from this clip's start.
                // A following transition's in_offset eats from this clip's end.
                double eatFromStart = 0; // frames eaten from start by preceding transition
                double eatFromEnd = 0;   // frames eaten from end by following transition
                if (ci > 0) {
                    NSDictionary *prev = primaryChildren[ci - 1];
                    if ([prev[@"OTIO_SCHEMA"] hasPrefix:@"Transition."]) {
                        double outOff = frameVal(prev[@"out_offset"]);
                        if (outOff > 0 && frameVal(prev[@"in_offset"]) > 0) {
                            eatFromStart = outOff; // cross-dissolve eats from our start
                        }
                    }
                }
                if (ci + 1 < pCount) {
                    NSDictionary *next = primaryChildren[ci + 1];
                    if ([next[@"OTIO_SCHEMA"] hasPrefix:@"Transition."]) {
                        double inOff = frameVal(next[@"in_offset"]);
                        if (inOff > 0 && frameVal(next[@"out_offset"]) > 0) {
                            eatFromEnd = inOff; // cross-dissolve eats from our end
                        }
                    }
                }

                // Adjusted duration and source start for transition overlap
                double adjDurFrames = durFrames - eatFromStart - eatFromEnd;
                double adjSrcStartFrames = srcStartFrames + eatFromStart;
                NSDictionary *adjDurRT = @{@"value": @(adjDurFrames), @"rate": @(rate)};
                NSDictionary *adjSrcStartRT = @{@"value": @(adjSrcStartFrames), @"rate": @(rate)};

                // <asset-clip>, which is what Final Cut Pro's own export writes, not
                // <clip> with a nested <video>.
                //
                // A comment here used to claim <asset-clip> has a restricted DTD that
                // allows no markers, filters or connected clips. On FCP 12.3 that is not
                // so: its own export nests <adjust-transform> and anchored
                // <asset-clip lane="1"> inside one. What IS true is that FCP silently
                // drops a spine <clip><video>: a four-clip round trip imported as nothing
                // but its one connected clip, and the import still reported success.
                // Verified both ways against FCP 12.3 build 450152 before changing this.
                NSMutableString *tag = [NSMutableString stringWithFormat:
                    @"<asset-clip name=\"%@\" ref=\"%@\" offset=\"%@\" duration=\"%@\" start=\"%@\" format=\"r1\"",
                    SpliceKit_escapeXML(child[@"name"] ?: @"Clip"), aid,
                    otio_time(offRT), otio_time(adjDurRT), otio_time(adjSrcStartRT)];
                if (!enabled) [tag appendString:@" enabled=\"0\""];
                [tag appendString:@">"];

                item[@"type"] = @"clip";
                item[@"sourceStartSec"] = @(srcStartSec);
                item[@"assetUrl"] = ref[@"target_url"] ?: @"";
                item[@"openTag"] = tag;

                NSMutableString *cx = item[@"childXml"];

                // Ordering inside <asset-clip>:
                //   1. adjust-* elements (conform, transform, blend, etc.)
                //   2. adjust-volume, adjust-panner
                //   3. timeMap / frame-sampling
                //   4. filter-video / filter-audio
                //   5. markers, then connected clips/titles (added later by secondary track loop)

                // Phase 1: adjust-* elements (before timeMap/video)
                NSMutableString *filterXml = [NSMutableString string]; // filters go inside <video>
                NSMutableString *timeMapXml = [NSMutableString string];
                for (NSDictionary *eff in child[@"effects"] ?: @[]) {
                    NSDictionary *fcpxMeta = otio_fcpxMeta(eff);
                    NSString *eName = otio_fcpxEffectName(eff, fcpxMeta);
                    NSString *fcpxElement = otio_fcpxEffectElement(fcpxMeta);
                    NSString *eSchema = eff[@"OTIO_SCHEMA"] ?: @"";

                    if ([eName hasPrefix:@"adjust-"]) {
                        // Adjust elements go directly on <clip>
                        NSMutableString *attrStr = [NSMutableString string];
                        NSDictionary *attrs = otio_dict(fcpxMeta[@"attrs"]) ?: fcpxMeta;
                        for (NSString *key in attrs) {
                            if ([key isEqualToString:@"params"]) continue;
                            if ([key isEqualToString:@"element"]) continue;
                            if ([key isEqualToString:@"resource"]) continue;
                            id val = attrs[key];
                            if ([val isKindOfClass:[NSString class]]) {
                                [attrStr appendFormat:@" %@=\"%@\"", key, SpliceKit_escapeXML(val)];
                            }
                        }
                        [cx appendFormat:@"\n                        <%@%@", eName, attrStr];
                        id params = otio_fcpxEffectParams(fcpxMeta);
                        BOOL hasParams = ([params isKindOfClass:[NSDictionary class]] && [(NSDictionary *)params count] > 0) ||
                                         ([params isKindOfClass:[NSArray class]] && [(NSArray *)params count] > 0);
                        if (hasParams) {
                            [cx appendString:@">"];
                            otio_appendParams(cx, params, @"\n                            ");
                            [cx appendFormat:@"\n                        </%@>", eName];
                        } else {
                            [cx appendString:@"/>"];
                        }
                    } else if (fcpxMeta[@"time_map"]) {
                        id rawTimeMap = fcpxMeta[@"time_map"];
                        NSArray *rawEntries = [rawTimeMap isKindOfClass:[NSArray class]] ? rawTimeMap : nil;
                        if ([rawTimeMap isKindOfClass:[NSString class]]) rawEntries = @[rawTimeMap];
                        for (NSString *raw in rawEntries ?: @[]) {
                            if (![raw isKindOfClass:[NSString class]] || raw.length == 0) continue;
                            [timeMapXml appendFormat:@"\n                        %@", raw];
                        }
                    } else if ([eSchema hasPrefix:@"FreezeFrame."]) {
                        [timeMapXml appendFormat:
                            @"\n                        <timeMap>"
                            @"\n                            <timept time=\"0s\" value=\"0s\" interp=\"linear\"/>"
                            @"\n                            <timept time=\"%@\" value=\"0s\" interp=\"linear\"/>"
                            @"\n                        </timeMap>",
                            otio_time(adjDurRT)];
                    } else if ([eSchema hasPrefix:@"LinearTimeWarp."]) {
                        double timeScalar = [eff[@"time_scalar"] doubleValue];
                        if (timeScalar != 0.0 && timeScalar != 1.0) {
                            NSDictionary *mappedEndRT = @{
                                @"value": @(llround((double)adjDurFrames * fabs(timeScalar))),
                                @"rate": adjDurRT[@"rate"] ?: @1
                            };
                            NSString *startValue = timeScalar < 0.0 ? otio_time(mappedEndRT) : @"0s";
                            NSString *endValue = timeScalar < 0.0 ? @"0s" : otio_time(mappedEndRT);
                            [timeMapXml appendFormat:
                                @"\n                        <timeMap>"
                                @"\n                            <timept time=\"0s\" value=\"%@\" interp=\"linear\"/>"
                                @"\n                            <timept time=\"%@\" value=\"%@\" interp=\"linear\"/>"
                                @"\n                        </timeMap>",
                                startValue, otio_time(adjDurRT), endValue];
                        }
                    } else if ([fcpxElement isEqualToString:@"filter-audio"] ||
                               [fcpxMeta[@"type"] isEqualToString:@"audio"]) {
                        // filter-audio goes inside <video> — skip if no valid ref
                        NSString *eRef = otio_fcpxEffectRef(fcpxMeta) ?: @"";
                        if (eRef.length == 0) continue;
                        NSString *mappedRef = effectRefs[eRef] ?: eRef;
                        [filterXml appendFormat:
                            @"\n                            <filter-audio name=\"%@\" ref=\"%@\"/>",
                            SpliceKit_escapeXML(eName), mappedRef];
                    } else if (eName.length > 0) {
                        // filter-video goes inside <video> — skip if no valid ref
                        NSString *eRef = otio_fcpxEffectRef(fcpxMeta) ?: @"";
                        if (eRef.length == 0) continue;
                        NSString *mappedRef = effectRefs[eRef] ?: eRef;
                        [filterXml appendFormat:
                            @"\n                            <filter-video name=\"%@\" ref=\"%@\"",
                            SpliceKit_escapeXML(eName), mappedRef];
                        id params = otio_fcpxEffectParams(fcpxMeta);
                        BOOL hasParams = ([params isKindOfClass:[NSDictionary class]] && [(NSDictionary *)params count] > 0) ||
                                         ([params isKindOfClass:[NSArray class]] && [(NSArray *)params count] > 0);
                        if (hasParams) {
                            [filterXml appendString:@">"];
                            otio_appendParams(filterXml, params, @"\n                                ");
                            [filterXml appendString:@"\n                            </filter-video>"];
                        } else {
                            [filterXml appendString:@"/>"];
                        }
                    }
                }

                // Phase 2: retime metadata before <video>
                if (timeMapXml.length > 0) {
                    [cx appendString:timeMapXml];
                }

                // Phase 3: filters, which sit directly inside <asset-clip> — the media
                // reference is the asset-clip's own ref, so there is no <video> to nest
                // them in any more.
                if (filterXml.length > 0) {
                    [cx appendString:filterXml];
                }

                // Phase 4: Markers (after video, before connected clips)
                for (NSDictionary *m in child[@"markers"] ?: @[]) {
                    NSDictionary *fcpxMeta = otio_fcpxMeta(m);
                    NSString *markerType = fcpxMeta[@"marker_type"] ?: @"marker";
                    NSString *startStr = otio_time(m[@"marked_range"][@"start_time"]);
                    NSString *durStr = otio_time(m[@"marked_range"][@"duration"]);
                    NSString *name = SpliceKit_escapeXML(m[@"name"] ?: @"Marker");

                    if ([markerType isEqualToString:@"chapter-marker"]) {
                        NSString *posterOff = fcpxMeta[@"posterOffset"] ?: @"0s";
                        [cx appendFormat:
                            @"\n                        <chapter-marker start=\"%@\" duration=\"%@\" value=\"%@\" posterOffset=\"%@\"/>",
                            startStr, durStr, name, posterOff];
                    } else {
                        NSMutableString *attrs = [NSMutableString stringWithFormat:
                            @"start=\"%@\" duration=\"%@\" value=\"%@\"", startStr, durStr, name];
                        NSString *color = m[@"color"];
                        if ([color isEqualToString:@"RED"]) {
                            [attrs appendString:@" completed=\"0\""];
                        } else if ([color isEqualToString:@"GREEN"]) {
                            [attrs appendString:@" completed=\"1\""];
                        }
                        [cx appendFormat:@"\n                        <%@ %@/>", markerType, attrs];
                    }
                }
                // Phase 5: Connected clips/titles are added later by the secondary track loop

                // Advance by adjusted duration (transitions eat into clip edges)
                runFrames += adjDurFrames;
                goto clipDone;
            }
            runFrames += durFrames; // non-external clips (gaps)
            clipDone:;
        } else {
            // Unknown schema — treat as gap
            runFrames += durFrames;
        }
        [spineItems addObject:item];
    }

    // ---- Attach connected clips from secondary video tracks (lane 1, 2, ...) ----
    for (NSInteger ti = 1; ti < videoTracks.count; ti++) {
        NSDictionary *secTrack = videoTracks[ti];
        int lane = (int)ti;
        double secOff = 0; // in seconds

        for (NSDictionary *child in secTrack[@"children"] ?: @[]) {
            NSString *schema = child[@"OTIO_SCHEMA"] ?: @"";
            double durSec = otio_sec(child[@"source_range"][@"duration"]);
            double clipRate = [child[@"source_range"][@"duration"][@"rate"] doubleValue] ?: fps;

            if ([schema hasPrefix:@"Clip."]) {
                NSDictionary *ref = otio_mediaRef(child);
                NSString *refSchema = ref[@"OTIO_SCHEMA"] ?: @"";

                if (otio_isTitleGenerator(ref)) {
                    // Connected title clip — build <title> with lane attribute
                    for (NSMutableDictionary *si in spineItems) {
                        double siStart = [si[@"timelineStartSec"] doubleValue];
                        double siEnd = siStart + [si[@"timelineDurSec"] doubleValue];
                        if (secOff >= siStart - 0.001 && secOff < siEnd + 0.001) {
                            double relOffSec = [si[@"sourceStartSec"] doubleValue] + (secOff - siStart);
                            double relOffFrames = round(relOffSec * clipRate);
                            NSDictionary *offRT = @{@"value": @(relOffFrames), @"rate": @(clipRate)};
                            NSDictionary *durRT = child[@"source_range"][@"duration"];

                            static int connTsCounter = 100;
                            NSString *titleXml = otio_buildTitleElement(child, ref,
                                otio_time(offRT), otio_time(durRT), &connTsCounter, basicTitleEffectId);
                            // Inject lane attribute into the title opening tag
                            NSString *connTitle = [titleXml stringByReplacingOccurrencesOfString:@" start=\"3600s\""
                                withString:[NSString stringWithFormat:@" lane=\"%d\" start=\"3600s\"", lane]];
                            NSMutableString *cx = si[@"childXml"];
                            [cx appendFormat:@"\n                        %@", connTitle];
                            break;
                        }
                    }
                } else if ([refSchema hasPrefix:@"GeneratorReference."]) {
                    // Ignore non-title generators on secondary lanes for now.
                } else if (otio_isExternal(ref)) {
                    NSString *aid = assets[ref[@"target_url"]] ?: @"r2";
                    double srcStart = otio_sourceStart(child);

                    for (NSMutableDictionary *si in spineItems) {
                        double siStart = [si[@"timelineStartSec"] doubleValue];
                        double siEnd = siStart + [si[@"timelineDurSec"] doubleValue];
                        if (secOff >= siStart - 0.001 && secOff < siEnd + 0.001) {
                            double relOffSec = [si[@"sourceStartSec"] doubleValue] + (secOff - siStart);
                            double relOffFrames = round(relOffSec * clipRate);
                            NSDictionary *offRT = @{@"value": @(relOffFrames), @"rate": @(clipRate)};
                            NSDictionary *srcRT = @{@"value": @(round(srcStart * clipRate)), @"rate": @(clipRate)};

                            NSMutableString *cx = si[@"childXml"];
                            [cx appendFormat:
                                @"\n                        <asset-clip name=\"%@\" ref=\"%@\" lane=\"%d\""
                                @" offset=\"%@\" duration=\"%@\" format=\"r1\"",
                                SpliceKit_escapeXML(child[@"name"] ?: @"Clip"), aid, lane,
                                otio_time(offRT), otio_time(child[@"source_range"][@"duration"])];
                            if (srcStart > 0.001) {
                                [cx appendFormat:@" start=\"%@\"", otio_time(srcRT)];
                            }
                            [cx appendString:@"/>"];
                            break;
                        }
                    }
                }
            }
            if (![schema hasPrefix:@"Transition."]) secOff += durSec;
        }
    }

    // ---- Attach connected audio clips (lane -1, -2, ...) ----
    // Match audio to spine items by asset reference (same source media)
    // rather than by timeline position — transitions cause position drift
    // between video and audio tracks.
    for (NSInteger ai = 0; ai < audioTracks.count; ai++) {
        NSDictionary *aTrack = audioTracks[ai];
        int lane = -(int)(ai + 1);

        for (NSDictionary *child in aTrack[@"children"] ?: @[]) {
            NSString *schema = child[@"OTIO_SCHEMA"] ?: @"";
            if (![schema hasPrefix:@"Clip."]) continue;

            NSDictionary *ref = otio_mediaRef(child);
            if (!otio_isExternal(ref)) continue;

            NSString *audioUrl = ref[@"target_url"];
            NSString *aid = assets[audioUrl] ?: @"r2";
            double clipRate = [child[@"source_range"][@"duration"][@"rate"] doubleValue] ?: fps;

            // Find the spine item that uses the SAME asset (matched by URL)
            for (NSMutableDictionary *si in spineItems) {
                NSString *siAssetUrl = si[@"assetUrl"];
                if (!siAssetUrl || ![siAssetUrl isEqualToString:audioUrl]) continue;

                // Audio offset = same as the parent clip's source start
                double srcStartFrames = round([si[@"sourceStartSec"] doubleValue] * clipRate);
                NSDictionary *offRT = @{@"value": @(srcStartFrames), @"rate": @(clipRate)};

                NSMutableString *cx = si[@"childXml"];
                [cx appendFormat:
                    @"\n                        <audio ref=\"%@\" lane=\"%d\""
                    @" offset=\"%@\" duration=\"%@\" role=\"dialogue\"/>",
                    aid, lane, otio_time(offRT),
                    otio_time(child[@"source_range"][@"duration"])];
                break;
            }
        }
    }

    // ---- Assemble FCPXML ----
    // runFrames is total frames accumulated from the primary track
    double totalRate = fps;
    // Find the rate from the primary track's first clip for consistency
    for (NSDictionary *child in primaryTrack[@"children"] ?: @[]) {
        double r = [child[@"source_range"][@"duration"][@"rate"] doubleValue];
        if (r > 0) { totalRate = r; break; }
    }
    NSDictionary *seqDurRT = @{@"value": @(runFrames), @"rate": @(totalRate)};
    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE fcpxml>\n"];
    [xml appendFormat:@"<fcpxml version=\"1.14\">\n    <resources>\n"];
    [xml appendFormat:@"        <format id=\"r1\" frameDuration=\"%@\" width=\"%d\" height=\"%d\" name=\"%@\"/>\n",
        frameDur, width, height, fmtName];
    [xml appendFormat:@"        <effect id=\"%@\" name=\"Cross Dissolve\" uid=\"FxPlug:4731E73A-8DAC-4113-9A30-AE85B1761265\"/>\n", crossDissolveEffectId];
    [xml appendFormat:@"        <effect id=\"%@\" name=\"Audio Crossfade\" uid=\"FFAudioTransition\"/>\n", audioCrossfadeEffectId];
    [xml appendFormat:@"        <effect id=\"%@\" name=\"Basic Title\" uid=\".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti\"/>\n", basicTitleEffectId];
    [xml appendString:effectXml]; // clip effect resources
    [xml appendString:assetXml];
    [xml appendString:@"    </resources>\n"];
    NSString *targetEvent = eventName.length > 0 ? eventName
                                                : (otio_defaultEventName() ?: projectName);
    [xml appendFormat:@"    <event name=\"%@\">\n", SpliceKit_escapeXML(targetEvent)];

    // Asset-clip browser items (so clips appear in FCP's event browser)
    for (NSString *url in assets) {
        NSString *aid = assets[url];
        // Find the clip to get its name and duration
        for (NSDictionary *t in tracks) {
            for (NSDictionary *c in t[@"children"] ?: @[]) {
                NSDictionary *cRef = otio_mediaRef(c);
                if (cRef && [cRef[@"target_url"] isEqualToString:url]) {
                    NSDictionary *durRT = cRef[@"available_range"] ?
                        cRef[@"available_range"][@"duration"] : c[@"source_range"][@"duration"];
                    [xml appendFormat:
                        @"        <asset-clip name=\"%@\" ref=\"%@\" format=\"r1\" duration=\"%@\"/>\n",
                        SpliceKit_escapeXML(c[@"name"] ?: @"Clip"), aid, otio_time(durRT)];
                    goto nextAsset;
                }
            }
        }
        nextAsset:;
    }

    [xml appendFormat:@"        <project name=\"%@\">\n", SpliceKit_escapeXML(projectName)];
    [xml appendFormat:@"            <sequence format=\"r1\" duration=\"%@\" tcStart=\"0s\" tcFormat=\"NDF\">\n",
        otio_time(seqDurRT)];
    [xml appendString:@"                <spine>\n"];

    for (NSDictionary *si in spineItems) {
        NSString *type = si[@"type"];
        NSString *openTag = si[@"openTag"];
        NSString *childXml = si[@"childXml"];

        if ([type isEqualToString:@"transition"] || [type isEqualToString:@"title"]) {
            // Transitions and titles are self-contained elements (already have closing tags)
            [xml appendFormat:@"                    %@\n", openTag];
        } else {
            BOOL hasChildren = childXml.length > 0;
            if (hasChildren) {
                [xml appendFormat:@"                    %@%@\n", openTag, childXml];
                // Close tag: determine element name from opening tag
                NSString *closeTag = [openTag hasPrefix:@"<asset-clip"] ? @"</asset-clip>" :
                                     [openTag hasPrefix:@"<gap"] ? @"</gap>" : @"</clip>";
                [xml appendFormat:@"                    %@\n", closeTag];
            } else {
                // Self-close
                NSString *selfClose = [openTag stringByReplacingOccurrencesOfString:@">" withString:@"/>"
                    options:NSBackwardsSearch range:NSMakeRange(openTag.length - 1, 1)];
                [xml appendFormat:@"                    %@\n", selfClose];
            }
        }
    }

    [xml appendString:@"                </spine>\n"];
    [xml appendString:@"            </sequence>\n"];
    [xml appendString:@"        </project>\n"];
    [xml appendString:@"    </event>\n"];
    [xml appendString:@"</fcpxml>\n"];

    SpliceKit_log(@"[OTIO] Converted %@ → FCPXML (%lu bytes, %lu spine items, %lu assets)",
        otioPath.lastPathComponent, (unsigned long)xml.length,
        (unsigned long)spineItems.count, (unsigned long)assets.count);
    return xml;
}

NSString *SpliceKit_otioToFCPXML(NSString *otioPath) {
    return SpliceKit_otioToFCPXMLInEvent(otioPath, nil);
}
