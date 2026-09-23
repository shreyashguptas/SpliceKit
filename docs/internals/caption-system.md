# SpliceKit Caption System — Complete Technical Internals

> This describes the architecture of the social-captions panel. It was written when the
> panel was one file; the code is now split into categories under
> `Sources/Panels/Captions/` (see [File Manifest](#17-file-manifest)), so code excerpts may
> differ in detail from the current source, and line numbers have been replaced with the
> file that holds each function.

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Data Flow: End-to-End Pipeline](#2-data-flow-end-to-end-pipeline)
3. [Data Models](#3-data-models)
   - [SpliceKitCaptionStyle](#31-splicekitcaptionstyle)
   - [SpliceKitCaptionSegment](#32-splicekitcaptionsegment)
   - [SpliceKitTranscriptWord (shared)](#33-splicekittranscriptword-shared)
4. [Transcription Engine Integration](#4-transcription-engine-integration)
5. [Word Segmentation Algorithm](#5-word-segmentation-algorithm)
6. [FCPXML Generation — The Core Engine](#6-fcpxml-generation--the-core-engine)
   - [Timeline Property Detection](#61-timeline-property-detection)
   - [Rational Time Conversion](#62-rational-time-conversion)
   - [FCPXML Document Structure](#63-fcpxml-document-structure)
   - [Word-by-Word Highlight Mode](#64-word-by-word-highlight-mode)
   - [Non-Highlight Mode](#65-non-highlight-mode)
   - [Text Style XML Generation](#66-text-style-xml-generation)
   - [Position Calculation](#67-position-calculation)
7. [The Dedicated Caption Lane — Lane 1 System](#7-the-dedicated-caption-lane--lane-1-system)
   - [How FCPXML Lanes Work](#71-how-fcpxml-lanes-work)
   - [The Gap Anchor Pattern](#72-the-gap-anchor-pattern)
   - [Title Clips as Connected Items](#73-title-clips-as-connected-items)
   - [Why Lane 1 Specifically](#74-why-lane-1-specifically)
8. [Import Mechanism — NSOpenPanel Swizzling](#8-import-mechanism--nsopenpanel-swizzling)
9. [Style Preset System](#9-style-preset-system)
10. [UI Architecture — The Floating Panel](#10-ui-architecture--the-floating-panel)
11. [RPC Server Integration](#11-rpc-server-integration)
12. [MCP Tool Definitions](#12-mcp-tool-definitions)
13. [Export Formats](#13-export-formats)
14. [Reusing This System for Another Caption Engine](#14-reusing-this-system-for-another-caption-engine)
    - [Integration Points](#141-integration-points)
    - [Minimal Implementation: Injecting Words](#142-minimal-implementation-injecting-words)
    - [Custom Style: Extending the Preset System](#143-custom-style-extending-the-preset-system)
    - [Alternative Import Strategies](#144-alternative-import-strategies)
    - [Building a New Panel That Reuses the FCPXML Generator](#145-building-a-new-panel-that-reuses-the-fcpxml-generator)
    - [Using the Lane System for Non-Caption Overlays](#146-using-the-lane-system-for-non-caption-overlays)
15. [Thread Safety & Concurrency](#15-thread-safety--concurrency)
16. [Color Conversion Utilities](#16-color-conversion-utilities)
17. [File Manifest](#17-file-manifest)

---

## 1. Architecture Overview

The SpliceKit caption system generates social-media-style, word-by-word highlighted
caption titles and imports them into Final Cut Pro's timeline. It is built as an
in-process ObjC panel injected into FCP's address space.

**Core design philosophy:** Captions are not FCP's built-in subtitle/caption objects
(`FFAnchoredCaption`). Instead, they are **Basic Title generator clips** — full
FCPXML `<title>` elements with styled text, positioned on **lane 1** (a connected
storyline above the primary storyline). This gives complete control over typography,
colors, outlines, shadows, and word-by-word highlight animations that FCP's native
caption system doesn't support.

**Key components:**

```
┌─────────────────────────────────────────────────────────────┐
│  MCP Server (Python)                                        │
│  mcp/splicekit_mcp/tools/captions.py — tool definitions     │
│  open_captions(), generate_captions(), set_caption_style()  │
│         │  JSON-RPC over TCP :9876                          │
├─────────┼───────────────────────────────────────────────────┤
│  RPC Server (ObjC)                                          │
│  SpliceKitServerCaptions.m — captions.* handlers            │
│  SpliceKit_handleCaptionsGenerate(), etc.                   │
│         │  Direct ObjC calls                                │
├─────────┼───────────────────────────────────────────────────┤
│  Caption Panel (ObjC)                                       │
│  SpliceKitCaptionPanel.h/m                                  │
│  ┌──────────────────────────────────────────────┐           │
│  │ Style System        │ Segmentation Engine    │           │
│  │ 12 presets           │ 4 grouping modes       │           │
│  │ Custom overrides     │ Silence-gap detection   │           │
│  ├──────────────────────┼────────────────────────┤           │
│  │ FCPXML Generator     │ Import Engine           │           │
│  │ Title elements       │ NSOpenPanel swizzle     │           │
│  │ Text style defs      │ importCaptions: action  │           │
│  │ Lane 1 placement     │ SRT file intermediary   │           │
│  └──────────────────────┴────────────────────────┘           │
│         │  Notification delegate                             │
├─────────┼───────────────────────────────────────────────────┤
│  Transcript Panel (ObjC)                                    │
│  SpliceKitTranscriptPanel.h/m                               │
│  Parakeet/Apple Speech/FCP Native engines                   │
│  Word-level timing extraction                                │
└─────────────────────────────────────────────────────────────┘
```

**Files involved:**

| File | Role |
|------|------|
| `Sources/Panels/Captions/SpliceKitCaptionPanel.h` | Interface, enums, model classes |
| `Sources/Panels/Captions/SpliceKitCaptionPanel.m` and its `+FCPXML`, `+Timeline`, `+Transcription`, `+UI`, `+Persistence` categories | Panel implementation |
| `Sources/Panels/Captions/SpliceKitCaptionStyle.m` | Style and segment models, built-in presets, color helpers |
| `Sources/Panels/Transcript/SpliceKitTranscriptPanel.h` | Transcript word model, engine enum |
| `Sources/Panels/Transcript/SpliceKitTranscriptPanel.m` | Transcription engine, word extraction |
| `Sources/Bridge/SpliceKitServerCaptions.m` | `captions.*` RPC handlers (rows in `Sources/Bridge/SpliceKitRPCTable.def`) |
| `mcp/splicekit_mcp/tools/captions.py` | MCP tool definitions |

---

## 2. Data Flow: End-to-End Pipeline

```
User calls generate_captions(style="bold_pop")
    │
    ▼
MCP tools/captions.py: generate_captions() ──────────────────────
    │  bridge.call("captions.generate", style="bold_pop", ...)
    ▼
SpliceKitServerCaptions.m: SpliceKit_handleCaptionsGenerate()
    │  1. Resolve preset → SpliceKitCaptionStyle object
    │  2. Merge parameter overrides via dictionary round-trip
    │  3. [panel setStyle:style]
    │  4. dispatch_async(global queue) → [panel generateCaptions]
    ▼
SpliceKitCaptionPanel.m: generateCaptions()
    │
    │  Step 1: Validate words exist (from prior transcription)
    │  Step 2: [self regroupSegments] — organize words into segments
    │  Step 3: [self detectTimelineProperties] — frame rate, resolution
    │  Step 4: Build FCPXML document:
    │     │
    │     │  For each segment:
    │     │    ┌─ Word-by-word highlight mode? ──────────────────────┐
    │     │    │ YES: One <title> per word, full segment text shown  │
    │     │    │      Active word gets highlightColor, others normal │
    │     │    │ NO:  One <title> per segment, uniform text color    │
    │     │    └────────────────────────────────────────────────────┘
    │     │    Each <title>:
    │     │      - ref="r2" (Basic Title effect)
    │     │      - lane="1" (connected storyline, above primary)
    │     │      - offset, duration in rational frames
    │     │      - <text> with <text-style> refs
    │     │      - <text-style-def> for normal + highlight colors
    │     │      - <adjust-transform position="0 Y"/>
    │     │
    │  Step 5: Write FCPXML to /tmp/splicekit_captions.fcpxml
    │  Step 6: [self exportSRT:srtPath] — SRT for import
    │  Step 7: Swizzle NSOpenPanel (URLs, URL, runModal)
    │  Step 8: Send "importCaptions:" through responder chain
    │  Step 9: FCP imports SRT → captions on timeline
    │  Step 10: Clear swizzle URL after 1 second
    │
    ▼
Result: { titleCount, segmentCount, fcpxmlPath, srtPath, message }
```

---

## 3. Data Models

### 3.1 SpliceKitCaptionStyle

Declared in `SpliceKitCaptionPanel.h`. The style model captures every visual
property of the caption text.

```objc
@interface SpliceKitCaptionStyle : NSObject <NSCopying>

// Identity
@property (nonatomic, copy) NSString *name;              // "Bold Pop"
@property (nonatomic, copy) NSString *presetID;          // "bold_pop"

// Typography
@property (nonatomic, copy) NSString *font;              // "Futura-Bold"
@property (nonatomic) CGFloat fontSize;                   // 60-80 typical
@property (nonatomic, copy) NSString *fontFace;           // "Bold", "Regular"

// Text colors (NSColor objects, converted to "R G B A" for FCPXML)
@property (nonatomic, copy) NSColor *textColor;           // default white
@property (nonatomic, copy) NSColor *highlightColor;      // active word (nil = no highlight)

// Outline/stroke
@property (nonatomic, copy) NSColor *outlineColor;
@property (nonatomic) CGFloat outlineWidth;               // 0-5

// Drop shadow
@property (nonatomic, copy) NSColor *shadowColor;
@property (nonatomic) CGFloat shadowBlurRadius;           // 0-20
@property (nonatomic) CGFloat shadowOffsetX;
@property (nonatomic) CGFloat shadowOffsetY;

// Background (pseudo via stroke)
@property (nonatomic, copy) NSColor *backgroundColor;     // nil = no background
@property (nonatomic) CGFloat backgroundPadding;          // stroke width for bg effect

// Position & Animation
@property (nonatomic) SpliceKitCaptionPosition position;  // bottom/center/top/custom
@property (nonatomic) CGFloat customYOffset;              // for custom position
@property (nonatomic) SpliceKitCaptionAnimation animation;
@property (nonatomic) CGFloat animationDuration;          // seconds (0.15-0.5)

// Formatting
@property (nonatomic) BOOL allCaps;                       // force uppercase
@property (nonatomic) BOOL wordByWordHighlight;           // karaoke mode

// Serialization
- (NSDictionary *)toDictionary;
+ (instancetype)fromDictionary:(NSDictionary *)dict;

// Presets
+ (NSArray<SpliceKitCaptionStyle *> *)builtInPresets;
+ (instancetype)presetWithID:(NSString *)presetID;

@end
```

**Default values** (from `init` in `SpliceKitCaptionStyle.m`):

| Property | Default |
|----------|---------|
| font | "Helvetica Neue" |
| fontSize | 60 |
| fontFace | "Bold" |
| textColor | white (1 1 1 1) |
| highlightColor | yellow (1 0.85 0 1) |
| outlineColor | black (0 0 0 1) |
| outlineWidth | 2.0 |
| shadowColor | black @ 80% (0 0 0 0.8) |
| shadowBlurRadius | 4.0 |
| position | Bottom |
| animation | Fade |
| animationDuration | 0.2 |
| allCaps | YES |
| wordByWordHighlight | YES |

### 3.2 SpliceKitCaptionSegment

Declared in `SpliceKitCaptionPanel.h`. A segment is a group of words that
will be shown together on screen at the same time (the "current line" of the caption).

```objc
@interface SpliceKitCaptionSegment : NSObject
@property (nonatomic, strong) NSArray<SpliceKitTranscriptWord *> *words;
@property (nonatomic) double startTime;          // first word's startTime
@property (nonatomic) double endTime;            // last word's endTime
@property (nonatomic) double duration;           // endTime - startTime
@property (nonatomic, copy) NSString *text;      // all words joined with spaces
@property (nonatomic) NSUInteger segmentIndex;   // 0-based index
- (NSDictionary *)toDictionary;
@end
```

The `toDictionary` serialization (in `SpliceKitCaptionStyle.m`) includes nested word objects:

```json
{
    "index": 0,
    "text": "THE QUICK BROWN",
    "startTime": 1.5,
    "endTime": 2.8,
    "duration": 1.3,
    "wordCount": 3,
    "words": [
        {"text": "THE", "startTime": 1.5, "endTime": 1.8, "duration": 0.3},
        {"text": "QUICK", "startTime": 1.85, "endTime": 2.2, "duration": 0.35},
        {"text": "BROWN", "startTime": 2.25, "endTime": 2.8, "duration": 0.55}
    ]
}
```

### 3.3 SpliceKitTranscriptWord (shared)

Defined in `SpliceKitTranscriptPanel.h`. This model is shared between the transcript
and caption systems — it's the common data currency.

```objc
@interface SpliceKitTranscriptWord : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic) double startTime;        // seconds from timeline start
@property (nonatomic) double duration;
@property (nonatomic) double endTime;          // computed: startTime + duration
@property (nonatomic) double confidence;       // 0.0-1.0 from ASR engine
@property (nonatomic) NSUInteger wordIndex;    // position in full transcript
@property (nonatomic) NSRange textRange;       // range in joined fullText

// Source tracking
@property (nonatomic, copy) NSString *clipHandle;
@property (nonatomic) double clipTimelineStart;
@property (nonatomic) double sourceMediaOffset;
@property (nonatomic, copy) NSString *sourceMediaPath;

// Speaker diarization
@property (nonatomic, copy) NSString *speaker;
@end
```

**This is the key integration point.** Any system that can produce an array of
`SpliceKitTranscriptWord` objects (or dictionaries with `text`, `startTime`,
`duration`) can feed into the caption generator.

---

## 4. Transcription Engine Integration

The caption panel does NOT transcribe audio itself. It delegates to
`SpliceKitTranscriptPanel` and reuses its word timing data.

**Code path** (`SpliceKitCaptionPanel.m`, `-transcribeTimeline`):

```objc
- (void)transcribeTimeline {
    self.status = SpliceKitCaptionStatusTranscribing;
    // ... update UI ...

    SpliceKitTranscriptPanel *tp = [SpliceKitTranscriptPanel sharedPanel];

    // Optimization: if transcript panel already has words, reuse them
    if (tp.status == SpliceKitTranscriptStatusReady && tp.words.count > 0) {
        [self importWordsFromTranscriptPanel];
        return;
    }

    // Register for completion notification
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(transcriptDidComplete:)
        name:@"SpliceKitTranscriptDidComplete"
        object:nil];

    // Force Parakeet for best word-level timing
    tp.engine = SpliceKitTranscriptEngineParakeet;
    [tp transcribeTimeline];
}
```

When transcription completes, `transcriptDidComplete:` fires and calls
`importWordsFromTranscriptPanel`:

```objc
- (void)importWordsFromTranscriptPanel {
    SpliceKitTranscriptPanel *tp = [SpliceKitTranscriptPanel sharedPanel];
    @synchronized (self.mutableWords) {
        [self.mutableWords removeAllObjects];
        [self.mutableWords addObjectsFromArray:tp.words ?: @[]];
    }
    self.status = SpliceKitCaptionStatusReady;
    [self regroupSegments];
    // ... update UI ...
}
```

**Alternative: Manual word injection** (bypass transcription entirely):

```objc
- (void)setWordsManually:(NSArray<NSDictionary *> *)wordDicts {
    @synchronized (self.mutableWords) {
        [self.mutableWords removeAllObjects];
        for (NSUInteger i = 0; i < wordDicts.count; i++) {
            NSDictionary *d = wordDicts[i];
            SpliceKitTranscriptWord *w = [[SpliceKitTranscriptWord alloc] init];
            w.text = d[@"text"] ?: @"";
            w.startTime = [d[@"startTime"] doubleValue];
            w.duration = [d[@"duration"] doubleValue];
            w.endTime = w.startTime + w.duration;
            w.confidence = 1.0;
            w.wordIndex = i;
            [self.mutableWords addObject:w];
        }
    }
    self.status = SpliceKitCaptionStatusReady;
    [self regroupSegments];
}
```

This is accessible via the MCP `set_caption_words()` tool and the JSON-RPC
`captions.setWords` method. It's the entry point for external transcription services.

---

## 5. Word Segmentation Algorithm

Defined in `SpliceKitCaptionPanel.m` (`-regroupSegments`). Segmentation groups words into
display chunks — each segment becomes one "line" of captions on screen.

### Grouping Modes

```objc
typedef NS_ENUM(NSInteger, SpliceKitCaptionGrouping) {
    SpliceKitCaptionGroupingByWordCount = 0,   // max N words per segment (default 5)
    SpliceKitCaptionGroupingBySentence,        // break on .!?; punctuation (max 8 fallback)
    SpliceKitCaptionGroupingByTime,            // max N seconds per segment (default 3.0)
    SpliceKitCaptionGroupingByCharCount,       // max N chars per segment (default 40)
};
```

### Algorithm (pseudocode)

```
function regroupSegments():
    segments = []
    group = []
    segIdx = 0

    for each word in words:
        shouldBreak = false

        // RULE 1: Force break on large silence gaps (> 1.0 second)
        if group is not empty:
            gap = word.startTime - group.last.endTime
            if gap > 1.0:
                shouldBreak = true

        // RULE 2: Check grouping mode
        if not shouldBreak and group is not empty:
            switch groupingMode:
                case ByWordCount:
                    shouldBreak = (group.count >= maxWordsPerSegment)   // default 5

                case BySentence:
                    lastWord = group.last.text
                    shouldBreak = lastWord ends with "." or "!" or "?" or ";"
                    if not shouldBreak:
                        shouldBreak = (group.count >= 8)               // hard limit

                case ByTime:
                    groupStart = group.first.startTime
                    shouldBreak = (word.endTime - groupStart) > maxSecondsPerSegment  // default 3.0

                case ByCharCount:
                    totalChars = sum of (w.text.length + 1) for w in group
                    shouldBreak = (totalChars + word.text.length > maxCharsPerSegment) // default 40

        if shouldBreak and group is not empty:
            segments.append(createSegment(group, segIdx++))
            group = []

        group.append(word)

    // Flush remaining words
    if group is not empty:
        segments.append(createSegment(group, segIdx))

    return segments
```

### Segment creation

```objc
- (SpliceKitCaptionSegment *)segmentFromWords:(NSArray *)words index:(NSUInteger)idx {
    SpliceKitCaptionSegment *seg = [[SpliceKitCaptionSegment alloc] init];
    seg.words = [words copy];
    seg.startTime = words.firstObject.startTime;
    seg.endTime = words.lastObject.endTime;
    seg.duration = seg.endTime - seg.startTime;
    seg.text = [[words valueForKey:@"text"] componentsJoinedByString:@" "];
    seg.segmentIndex = idx;
    return seg;
}
```

---

## 6. FCPXML Generation — The Core Engine

This is the heart of the caption system. The entry point is `-generateCaptions` in `SpliceKitCaptionPanel.m`; the XML builders live in `SpliceKitCaptionPanel+FCPXML.m`.

### 6.1 Timeline Property Detection

Before generating FCPXML, the system introspects the active timeline to match
its frame rate and resolution. See `-detectTimelineProperties` in `SpliceKitCaptionPanel+FCPXML.m`.

```objc
- (void)detectTimelineProperties {
    id timelineModule = SpliceKit_getActiveTimelineModule();
    id sequence = objc_msgSend(timelineModule, @selector(sequence));

    // Frame duration — CMTime struct (24 bytes on ARM64)
    // Returns something like {value=100, timescale=2400} for 24fps
    typedef struct { int64_t value; int32_t timescale; uint32_t flags; int64_t epoch; } CMTimeStruct;
    CMTimeStruct fd = objc_msgSend(timelineModule, @selector(sequenceFrameDuration));
    self.fdNum = (int)fd.value;       // numerator (e.g., 100)
    self.fdDen = fd.timescale;         // denominator (e.g., 2400)
    self.frameRate = (double)fd.timescale / fd.value;  // e.g., 24.0

    // Resolution — NSSize from sequence
    NSSize size = objc_msgSend(sequence, @selector(renderSize));
    self.videoWidth = (int)size.width;    // e.g., 1920
    self.videoHeight = (int)size.height;  // e.g., 1080
}
```

**Default fallback values** (used when detection fails):
- Frame duration: 100/2400 → 24fps
- Resolution: 1920x1080

**Why this matters:** FCPXML uses rational time (e.g., `3600/2400s`), and positions
are in pixels relative to the video frame center. Wrong values would cause captions
to be misaligned or timed incorrectly.

### 6.2 Rational Time Conversion

FCPXML uses rational fractions for all timing, not floating-point seconds.
The conversion function (`SpliceKitCaption_durRational`, now in `SpliceKitCaptionPanel+Timeline.m`):

```objc
static NSString *SpliceKitCaption_durRational(double seconds, int fdNum, int fdDen) {
    if (seconds <= 0) return @"0s";
    long long frames = (long long)round(seconds * fdDen / fdNum);
    if (frames <= 0) frames = 1;
    return [NSString stringWithFormat:@"%lld/%ds", frames * fdNum, fdDen];
}
```

**Example conversions** at 24fps (fdNum=100, fdDen=2400):

| Seconds | Frames | FCPXML |
|---------|--------|--------|
| 0.042 | 1 | `100/2400s` |
| 0.5 | 12 | `1200/2400s` |
| 1.0 | 24 | `2400/2400s` |
| 1.5 | 36 | `3600/2400s` |
| 3.0 | 72 | `7200/2400s` |

### 6.3 FCPXML Document Structure

The generated FCPXML follows this structure:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE fcpxml>

<fcpxml version="1.11">
    <resources>
        <!-- Video format matching the active timeline -->
        <format id="r1" name="FFVideoFormat1920x1080p24"
                frameDuration="100/2400s" width="1920" height="1080"/>

        <!-- FCP's built-in Basic Title motion template -->
        <effect id="r2" name="Basic Title"
                uid=".../Titles.localized/Bumper:Opener.localized/
                     Basic Title.localized/Basic Title.moti"/>
    </resources>

    <library>
        <event name="Captions">
            <project name="Social Captions">
                <sequence format="r1" duration="72000/2400s"
                          tcStart="0s" tcFormat="NDF"
                          audioLayout="stereo" audioRate="48k">
                    <spine>
                        <!--
                          The gap is the "anchor" for all caption titles.
                          Its duration spans the entire timeline.
                          All <title> elements are placed inside this gap
                          as connected clips on lane 1.
                        -->
                        <gap name="CaptionAnchor" offset="0s"
                             duration="72000/2400s" start="0s">

                            <!-- Title clips here (see sections below) -->

                        </gap>
                    </spine>
                </sequence>
            </project>
        </event>
    </library>
</fcpxml>
```

**Key points:**
- `format id="r1"` matches the active timeline's exact frame rate and resolution
- `effect id="r2"` references FCP's Basic Title, which supports styled `<text>` content
- The entire spine is a single `<gap>` that serves as the anchor
- All titles sit inside the gap with `lane="1"` — this is the "dedicated caption lane"

### 6.4 Word-by-Word Highlight Mode

When `style.wordByWordHighlight == YES && style.highlightColor != nil && segment.words.count > 1`:

**For each segment, one `<title>` is generated per word.** Each title shows the
complete segment text, but only the "active" word is highlighted — the others
use the normal text color.

This creates a **karaoke effect**: as playback progresses through the segment,
successive title clips overlap such that the highlighted word sweeps left to right.

**Code**:

```objc
// Word-by-word mode: one title per word
for (NSUInteger wi = 0; wi < seg.words.count; wi++) {
    SpliceKitTranscriptWord *activeWord = seg.words[wi];
    double wordStart = activeWord.startTime;
    double wordDur = activeWord.duration;

    // Extend last word to segment end to avoid gaps
    if (wi == seg.words.count - 1) {
        wordDur = seg.endTime - wordStart;
    }
    if (wordDur <= 0) wordDur = 0.1;

    // Build mixed text: all words shown, active word highlighted
    NSMutableString *textXML = [NSMutableString string];
    [textXML appendString:@"<text>"];
    for (NSUInteger j = 0; j < seg.words.count; j++) {
        NSString *wordText = seg.words[j].text;
        if (s.allCaps) wordText = [wordText uppercaseString];
        NSString *suffix = (j < seg.words.count - 1) ? @" " : @"";
        // Active word gets highlight ref, others get normal ref
        NSString *ref = (j == wi) ? highlightTSID : normalTSID;
        [textXML appendFormat:@"<text-style ref=\"%@\">%@%@</text-style>",
            ref, escapeXML(wordText), suffix];
    }
    [textXML appendString:@"</text>"];
}
```

**Example output** for segment "THE QUICK BROWN" with word index 1 (QUICK) active:

```xml
<title ref="r2" lane="1" name="Cap001_w2" offset="1200/2400s"
       duration="800/2400s" start="3600s">
    <text>
        <text-style ref="ts1_n">THE </text-style>
        <text-style ref="ts1_h">QUICK </text-style>
        <text-style ref="ts1_n">BROWN</text-style>
    </text>
    <text-style-def id="ts1_n">
        <text-style font="Futura-Bold" fontSize="72" fontColor="1.000 1.000 1.000 1.000"
                    strokeColor="0.000 0.000 0.000 1.000" strokeWidth="3.0"
                    shadowColor="0.000 0.000 0.000 0.800" shadowOffset="0.0 0.0"
                    shadowBlurRadius="4.0" alignment="center"/>
    </text-style-def>
    <text-style-def id="ts1_h">
        <text-style font="Futura-Bold" fontSize="72" fontColor="1.000 0.850 0.000 1.000"
                    bold="1" strokeColor="0.000 0.000 0.000 1.000" strokeWidth="3.0"
                    shadowColor="0.000 0.000 0.000 0.800" shadowOffset="0.0 0.0"
                    shadowBlurRadius="4.0" alignment="center"/>
    </text-style-def>
    <adjust-transform position="0 -346"/>
</title>
```

**How the karaoke effect works visually:**

```
Timeline:  ─────────────────────────────────────────────►

Segment:   THE QUICK BROWN
           ├─word1─┤├─word2──┤├──word3──┤

Title 1:   [THE] QUICK BROWN
           ├─────────┤

Title 2:   THE [QUICK] BROWN
                ├──────────┤

Title 3:   THE QUICK [BROWN]
                      ├───────────┤    (extended to segment end)

Playback:  At any given time, exactly one title is visible,
           and its active word [in brackets] has the highlight color.
```

The last word's title duration is explicitly extended to `seg.endTime - wordStart`
to prevent gaps at the segment boundary.

### 6.5 Non-Highlight Mode

When `wordByWordHighlight == NO` or `highlightColor == nil` or the segment has
only one word:

**One `<title>` per segment**, uniform text color.

```objc
// Non-highlight mode: one title per segment
NSString *text = s.allCaps ? [seg.text uppercaseString] : seg.text;
NSString *offStr = SpliceKitCaption_durRational(seg.startTime, fdN, fdD);
NSString *durStr = SpliceKitCaption_durRational(seg.duration, fdN, fdD);

[xml appendFormat:@"<title ref=\"%@\" lane=\"1\" name=\"Cap%03lu\" "
    @"offset=\"%@\" duration=\"%@\" start=\"3600s\">\n",
    titleEffectId, seg.segmentIndex + 1, offStr, durStr];
[xml appendFormat:@"<text><text-style ref=\"%@\">%@</text-style></text>\n",
    tsID, escapeXML(text)];
[xml appendFormat:@"%@\n", tsDef];
[xml appendFormat:@"<adjust-transform position=\"0 %.0f\"/>\n", yOffset];
[xml appendString:@"</title>\n"];
```

### 6.6 Text Style XML Generation

The `textStyleXMLWithID:color:isHighlight:` method (in `SpliceKitCaptionPanel+FCPXML.m`) builds the
`<text-style-def>` element that defines font, color, outline, and shadow properties.

```objc
- (NSString *)textStyleXMLWithID:(NSString *)tsID
                           color:(NSColor *)color
                     isHighlight:(BOOL)highlight {
    SpliceKitCaptionStyle *s = self.style;
    NSMutableString *xml = [NSMutableString string];

    [xml appendFormat:@"<text-style-def id=\"%@\"><text-style", tsID];
    [xml appendFormat:@" font=\"%@\"", escapeXML(s.font)];
    [xml appendFormat:@" fontSize=\"%.0f\"", s.fontSize];
    if (s.fontFace)
        [xml appendFormat:@" fontFace=\"%@\"", escapeXML(s.fontFace)];
    [xml appendFormat:@" fontColor=\"%@\"", colorToFCPXML(color)];

    // Highlight words get bold="1" for extra visual weight
    if (highlight)
        [xml appendString:@" bold=\"1\""];

    // Outline (stroke)
    if (s.outlineColor && s.outlineWidth > 0) {
        [xml appendFormat:@" strokeColor=\"%@\"", colorToFCPXML(s.outlineColor)];
        [xml appendFormat:@" strokeWidth=\"%.1f\"", s.outlineWidth];
    }

    // Shadow
    if (s.shadowColor && s.shadowBlurRadius > 0) {
        [xml appendFormat:@" shadowColor=\"%@\"", colorToFCPXML(s.shadowColor)];
        [xml appendFormat:@" shadowOffset=\"%.1f %.1f\"", s.shadowOffsetX, s.shadowOffsetY];
        [xml appendFormat:@" shadowBlurRadius=\"%.1f\"", s.shadowBlurRadius];
    }

    [xml appendString:@" alignment=\"center\""];
    [xml appendString:@"/></text-style-def>"];
    return xml;
}
```

**FCPXML text-style attributes mapping:**

| Style Property | FCPXML Attribute | Example |
|---------------|-----------------|---------|
| font | `font` | `"Futura-Bold"` |
| fontSize | `fontSize` | `"72"` |
| fontFace | `fontFace` | `"Bold"` |
| textColor/highlightColor | `fontColor` | `"1.000 0.850 0.000 1.000"` |
| (highlight only) | `bold` | `"1"` |
| outlineColor | `strokeColor` | `"0.000 0.000 0.000 1.000"` |
| outlineWidth | `strokeWidth` | `"3.0"` |
| shadowColor | `shadowColor` | `"0.000 0.000 0.000 0.800"` |
| shadowOffset | `shadowOffset` | `"0.0 0.0"` |
| shadowBlurRadius | `shadowBlurRadius` | `"4.0"` |
| (always) | `alignment` | `"center"` |

### 6.7 Position Calculation

Captions are vertically positioned using `<adjust-transform position="X Y"/>`
on each title. X is always 0 (horizontally centered). Y is calculated as a
percentage of video height:

```objc
- (CGFloat)yOffsetForPosition {
    switch (self.style.position) {
        case SpliceKitCaptionPositionBottom:
            return -(self.videoHeight * 0.32);   // -345.6 for 1080p
        case SpliceKitCaptionPositionCenter:
            return 0;
        case SpliceKitCaptionPositionTop:
            return (self.videoHeight * 0.32);    // +345.6 for 1080p
        case SpliceKitCaptionPositionCustom:
            return self.style.customYOffset;
    }
    return -(self.videoHeight * 0.32);
}
```

**Position values for common resolutions:**

| Resolution | Bottom Y | Center Y | Top Y |
|-----------|----------|----------|-------|
| 1920x1080 | -345.6 | 0 | +345.6 |
| 3840x2160 (4K) | -691.2 | 0 | +691.2 |
| 1280x720 | -230.4 | 0 | +230.4 |

The coordinate system origin is the center of the frame. Negative Y moves down,
positive Y moves up.

---

## 7. The Dedicated Caption Lane — Lane 1 System

This is the most important architectural concept for reuse. The caption system
uses FCPXML's **lane** attribute to create a connected storyline dedicated to captions.

### 7.1 How FCPXML Lanes Work

In FCPXML, the `<spine>` is the primary storyline — sequential clips on lane 0
(the default). Any item inside a spine element (like `<gap>` or `<clip>`) can
have **connected items** placed on numbered lanes:

```
Lane 2:  ┌──────┐                    ┌──────┐
         │Title │                    │Title │
Lane 1:  │──────│──┌──────┐──────────│──────│──────
         │      │  │Title │          │      │
Lane 0:  ├══════╪══╪══════╪══════════╪══════╪══════  ← Primary storyline
(spine)  │ Gap  │  │ Clip │          │ Clip │
         └──────┘  └──────┘          └──────┘

Lane -1: Connected clips BELOW the primary storyline
```

- **Lane 0** (implicit): Items in the `<spine>` itself
- **Lane 1+**: Connected items ABOVE the primary storyline
- **Lane -1 and below**: Connected items below

Connected items are **magnetically anchored** to their parent spine item. When
the parent moves, all connected items on all lanes move with it.

### 7.2 The Gap Anchor Pattern

The caption system uses a specific pattern: a single gap clip in the spine
serves as the anchor for ALL caption titles.

```xml
<spine>
    <gap name="CaptionAnchor" offset="0s" duration="72000/2400s" start="0s">
        <!-- ALL title clips are children of this gap -->
        <title lane="1" offset="..."  duration="..." />
        <title lane="1" offset="..."  duration="..." />
        <title lane="1" offset="..."  duration="..." />
        <!-- ... hundreds of titles ... -->
    </gap>
</spine>
```

**Why a gap?** The `<gap>` is a transparent, silent placeholder that FCP treats
as empty timeline space. By making it span the entire timeline duration, it
provides a single anchor point for all connected caption titles. This is simpler
and more reliable than anchoring titles to individual video clips (which would
require finding the right parent clip for each caption's time range).

**Why not anchor to video clips?** If captions were anchored to individual video
clips, they would need to be distributed across multiple parent clips. If the
editor later reorders clips, the captions would move with them — which might or
might not be desired. The gap anchor pattern keeps all captions independent of
the video edit.

### 7.3 Title Clips as Connected Items

Each `<title>` element represents a single caption display moment:

```xml
<title ref="r2"         ← references the Basic Title effect (resource r2)
       lane="1"         ← places this on lane 1 (above primary storyline)
       name="Cap001_w2" ← human-readable name (segment 1, word 2)
       offset="1200/2400s"   ← timeline position (0.5 seconds)
       duration="800/2400s"  ← how long it's visible (0.33 seconds)
       start="3600s">        ← internal start (always 3600s for Basic Title)

    <text>
        <text-style ref="ts1_n">THE </text-style>
        <text-style ref="ts1_h">QUICK </text-style>   ← highlighted word
        <text-style ref="ts1_n">BROWN</text-style>
    </text>

    <text-style-def id="ts1_n">...</text-style-def>   ← normal color
    <text-style-def id="ts1_h">...</text-style-def>   ← highlight color

    <adjust-transform position="0 -346"/>              ← Y position
</title>
```

**The `start="3600s"` attribute:** This is not the timeline position — that's
`offset`. The `start` attribute is the internal media start time for the Basic
Title generator. FCP's Basic Title always uses `3600s` (1 hour) as its internal
origin. This is hardcoded and must be exactly this value.

### 7.4 Why Lane 1 Specifically

Lane 1 is the first lane above the primary storyline. This means:

1. **Captions render on top of video** — they composite above all lane 0 content
2. **They don't interfere with the primary edit** — moving or deleting primary
   clips doesn't break captions (they're anchored to the gap, not to clips)
3. **Lane 1 is visible in FCP's timeline** — users can see, select, and
   manually adjust caption clips just like any other connected clip
4. **Multiple caption systems can coexist** — a second system could use lane 2,
   and both would render independently

If a different system needs to place items BELOW the video (e.g., a background
graphic), it would use lane -1 instead.

---

## 8. Import Mechanism — NSOpenPanel Swizzling

> **Historical.** The NSOpenPanel swizzle and SRT import described in this section are no
> longer in the code. Captions now reach the timeline as FCPXML through the `pasteAnchored:` /
> `paste:` swizzle (see [fcpxml-paste.md](fcpxml-paste.md)). The section is kept because it
> records why FCP's `importCaptions:` route was hard to drive programmatically.

The caption FCPXML is generated but **not directly imported via pasteboard**.
Instead, the system uses a clever SRT-based import strategy with method swizzling
to automate the user interaction.

### Why SRT instead of FCPXML?

FCP's `importCaptions:` responder action expects an SRT file selected via
NSOpenPanel. There is no direct ObjC API to programmatically import captions.
Rather than reverse-engineering FCP's internal import pipeline, SpliceKit
generates an SRT file and tricks FCP into thinking the user selected it.

### The Swizzling Strategy

**Three methods are swizzled** on `NSOpenPanel`:

```objc
// Static variable holds the URL we want FCP to "select"
static NSURL *sAutoSelectURL = nil;
sAutoSelectURL = [NSURL fileURLWithPath:srtPath];

// 1. Swizzle -[NSOpenPanel URLs] → return our SRT file
Method urlsM = class_getInstanceMethod([NSOpenPanel class], @selector(URLs));
sOrigURLs = method_getImplementation(urlsM);
IMP newURLs = imp_implementationWithBlock(^NSArray *(NSOpenPanel *panel) {
    if (sAutoSelectURL) return @[sAutoSelectURL];
    return ((NSArray *(*)(id, SEL))sOrigURLs)(panel, @selector(URLs));
});
method_setImplementation(urlsM, newURLs);

// 2. Swizzle -[NSOpenPanel URL] → return our SRT file
Method urlM = class_getInstanceMethod([NSOpenPanel class], @selector(URL));
IMP origURL = method_getImplementation(urlM);
IMP newURL = imp_implementationWithBlock(^NSURL *(NSOpenPanel *panel) {
    if (sAutoSelectURL) return sAutoSelectURL;
    return ((NSURL *(*)(id, SEL))origURL)(panel, @selector(URL));
});
method_setImplementation(urlM, newURL);

// 3. Swizzle -[NSOpenPanel runModal] → return OK without showing dialog
Method m = class_getInstanceMethod([NSOpenPanel class], @selector(runModal));
sOrigRunModal2 = method_getImplementation(m);
IMP newImpl = imp_implementationWithBlock(^NSModalResponse(NSOpenPanel *panel) {
    if (sAutoSelectURL) return NSModalResponseOK;
    return ((NSModalResponse (*)(id, SEL))sOrigRunModal2)(panel, @selector(runModal));
});
method_setImplementation(m, newImpl);
```

### Triggering the Import

After swizzling, the import is triggered via the responder chain:

```objc
SEL importSel = NSSelectorFromString(@"importCaptions:");
id app = [NSApplication sharedApplication];
BOOL sent = objc_msgSend(app, @selector(sendAction:to:from:),
                          importSel, nil, nil);
```

This calls FCP's built-in "File > Import > Captions..." handler, which:
1. Creates an NSOpenPanel to ask the user to select a file
2. Our swizzled `runModal` returns `NSModalResponseOK` immediately (no dialog shown)
3. FCP reads the file URLs from the panel — our swizzled `URLs` returns the SRT
4. FCP processes the SRT and adds captions to the timeline

### Cleanup

The `sAutoSelectURL` is cleared after a 1-second delay to restore normal
NSOpenPanel behavior:

```objc
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
               dispatch_get_main_queue(), ^{
    sAutoSelectURL = nil;
});
```

The method implementations remain swizzled permanently, but they fall through
to the original implementations when `sAutoSelectURL` is nil — so normal
NSOpenPanel usage is unaffected.

---

## 9. Style Preset System

12 built-in presets are defined as static objects in `SpliceKitCaptionStyle.m` (`+builtInPresets`).
They're created once via `dispatch_once` and cached.

| # | ID | Name | Font | Size | Text Color | Highlight Color | Outline | Shadow | Position | Animation |
|---|-----|------|------|------|-----------|----------------|---------|--------|----------|-----------|
| 1 | `bold_pop` | Bold Pop | Futura-Bold | 72 | White | Yellow (1 .85 0) | Black 3px | Black 4px blur | Bottom | Pop 0.2s |
| 2 | `neon_glow` | Neon Glow | Avenir-Heavy | 68 | Cyan (0 1 1) | Magenta (1 0 1) | None | Blue 15px blur | Bottom | Fade 0.25s |
| 3 | `clean_minimal` | Clean Minimal | HelveticaNeue-Bold | 60 | White | Light Blue (.4 .7 1) | None | Black 3px blur | Bottom | Fade 0.2s |
| 4 | `handwritten` | Handwritten | Bradley Hand | 64 | Cream (.95 .95 .9) | Orange (1 .6 .2) | None | Brown 4px blur | Bottom | None |
| 5 | `gradient_fire` | Gradient Fire | HelveticaNeue-Bold | 70 | Orange (1 .6 .1) | Red (1 .2 .1) | Black 2px | Orange 6px blur | Bottom | Pop 0.2s |
| 6 | `outline_bold` | Outline Bold | Impact | 76 | White | Yellow (1 1 0) | Black 4px | None | Bottom | None |
| 7 | `shadow_deep` | Shadow Deep | Futura-Bold | 68 | White | Green (.2 1 .4) | None | Black 8px blur, offset 4,4 | Bottom | Fade 0.25s |
| 8 | `karaoke` | Karaoke | GillSans-Bold | 66 | Gray (.5 .5 .5) | White | Black 2px | Black 4px blur | Center | None |
| 9 | `typewriter` | Typewriter | Courier-Bold | 54 | Green (.2 1 .2) | White | None | None | Bottom | Typewriter |
| 10 | `bounce_fun` | Bounce Fun | AvenirNext-Heavy | 72 | White | Magenta (1 .4 .7) | Black 2px | None | Bottom | Bounce 0.3s |
| 11 | `subtitle_pro` | Subtitle Pro | HelveticaNeue-Medium | 48 | White | None (no highlight) | Black 1.5px | Black 2px blur | Bottom | Fade 0.15s |
| 12 | `social_bold` | Social Bold | HelveticaNeue-Bold | 80 | White | Yellow (1 .9 0) | Black 3px | Black 5px blur | Center | Pop 0.2s |

**Preset loading:**

```objc
+ (instancetype)presetWithID:(NSString *)presetID {
    for (SpliceKitCaptionStyle *s in [self builtInPresets]) {
        if ([s.presetID isEqualToString:presetID]) return [s copy];
    }
    return nil;  // nil = unknown preset
}
```

**Style merging** (used by `handleCaptionsSetStyle` and `handleCaptionsGenerate`):
Presets can be used as a base with individual parameter overrides:

```objc
SpliceKitCaptionStyle *style = [SpliceKitCaptionStyle presetWithID:@"bold_pop"];
NSMutableDictionary *merged = [[style toDictionary] mutableCopy];
for (NSString *key in params) {
    merged[key] = params[key];  // override individual properties
}
style = [SpliceKitCaptionStyle fromDictionary:merged];
```

---

## 10. UI Architecture — The Floating Panel

The caption panel is an `NSPanel` (utility floating window) injected into FCP's
process. Defined in `SpliceKitCaptionPanel+UI.m`.

**Window properties:**

```objc
NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(100, 150, 480, 680)
                                            styleMask:NSWindowStyleMaskTitled |
                                                      NSWindowStyleMaskClosable |
                                                      NSWindowStyleMaskResizable |
                                                      NSWindowStyleMaskUtilityWindow
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
panel.title = @"Social Captions";
panel.floatingPanel = YES;              // always on top of FCP
panel.becomesKeyOnlyIfNeeded = NO;      // can receive keyboard input
panel.hidesOnDeactivate = NO;           // stays visible when FCP loses focus
panel.level = NSFloatingWindowLevel;    // floating above normal windows
panel.minSize = NSMakeSize(400, 500);
panel.releasedWhenClosed = NO;          // singleton reuse
panel.appearance = NSAppearanceNameDarkAqua;  // dark mode to match FCP
```

**UI layout (top to bottom):**

```
┌─────────────────────────────────────────────┐
│ Social Captions                        [×]  │
├─────────────────────────────────────────────┤
│ Style    [Bold Pop        ▼]                │
├─────────────────────────────────────────────┤
│ ┌─────────────────────────────────────────┐ │
│ │                                         │ │
│ │     The QUICK brown fox                 │ │  ← Live preview (140px)
│ │                                         │ │
│ └─────────────────────────────────────────┘ │
├─────────────────────────────────────────────┤
│ Font     [Futura                   ▼]       │
│ Size     [────────●────────] [72]           │
│ Colors   [■]Text [■]Highlight [■]Outline    │
│          [■]Shadow                          │
│ Outline W [────●───────────]                │
│ Shadow Bl [───────●────────]                │
│ Position [Bottom         ▼]                 │
│ Animation [Pop           ▼]                 │
│ ☑ ALL CAPS   ☑ Word-by-word highlight       │
├╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┤
│ Grouping [By Words ▼] [5] max per group     │
├╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┤
│ [Transcribe] [Generate Captions] [SRT][TXT] │
├─────────────────────────────────────────────┤
│ ○ Ready — 245 words, 49 segments            │  ← Status bar (fixed)
└─────────────────────────────────────────────┘
```

**Live preview** (`-updatePreview`): The preview area renders attributed text
with the current style applied, showing "The QUICK brown fox" with the second
word highlighted. It updates in real-time as style properties change.

**UI actions**: Each control has a simple action method that
updates the style model and refreshes the preview:

```objc
- (void)presetChanged:(id)sender {
    NSArray *presets = [SpliceKitCaptionStyle builtInPresets];
    self.style = [presets[self.presetPopup.indexOfSelectedItem] copy];
    [self syncUIFromStyle];
}

- (void)fontChanged:(id)sender {
    self.style.font = self.fontPopup.titleOfSelectedItem;
    [self updatePreview];
}

- (void)colorChanged:(id)sender {
    self.style.textColor = self.textColorWell.color;
    self.style.highlightColor = self.highlightColorWell.color;
    // ... etc
    [self updatePreview];
}
```

---

## 11. RPC Server Integration

The `captions.*` methods are rows in `Sources/Bridge/SpliceKitRPCTable.def`, which builds the
dispatch table; the handlers are in `Sources/Bridge/SpliceKitServerCaptions.m`. Before the table
existed the dispatch was an if/else chain like this:

```objc
else if ([method isEqualToString:@"captions.open"])
    result = SpliceKit_handleCaptionsOpen(params);
else if ([method isEqualToString:@"captions.close"])
    result = SpliceKit_handleCaptionsClose(params);
else if ([method isEqualToString:@"captions.getState"])
    result = SpliceKit_handleCaptionsGetState(params);
else if ([method isEqualToString:@"captions.getStyles"])
    result = SpliceKit_handleCaptionsGetStyles(params);
else if ([method isEqualToString:@"captions.setStyle"])
    result = SpliceKit_handleCaptionsSetStyle(params);
else if ([method isEqualToString:@"captions.setGrouping"])
    result = SpliceKit_handleCaptionsSetGrouping(params);
else if ([method isEqualToString:@"captions.generate"])
    result = SpliceKit_handleCaptionsGenerate(params);
else if ([method isEqualToString:@"captions.exportSRT"])
    result = SpliceKit_handleCaptionsExportSRT(params);
else if ([method isEqualToString:@"captions.exportTXT"])
    result = SpliceKit_handleCaptionsExportTXT(params);
else if ([method isEqualToString:@"captions.setWords"])
    result = SpliceKit_handleCaptionsSetWords(params);
```

### Handler details

**`captions.open`**: Opens the panel on the main thread (with
a 0.5s delay for FCP UI readiness), applies an optional preset, and starts
transcription if no words are loaded yet (or always, with `forceRetranscribe`). It
transcribes the timeline only and refuses `fileURL` with an error: caption words carry
timeline times and their clips, which a bare file does not have.

**`captions.generate`**: The most complex handler. Supports
"one-shot" usage where style + grouping + generation happen in a single call:

```objc
static NSDictionary *SpliceKit_handleCaptionsGenerate(NSDictionary *params) {
    SpliceKitCaptionPanel *panel = [SpliceKitCaptionPanel sharedPanel];

    // One-shot: apply style if provided
    if (params[@"style"] || params[@"presetID"]) {
        NSString *pid = params[@"style"] ?: params[@"presetID"];
        SpliceKitCaptionStyle *style = [SpliceKitCaptionStyle presetWithID:pid];
        if (style) {
            // Merge overrides via serialization round-trip
            NSMutableDictionary *merged = [[style toDictionary] mutableCopy];
            for (NSString *key in params) {
                if (![key isEqualToString:@"style"] && ...) {
                    merged[key] = params[key];
                }
            }
            style = [SpliceKitCaptionStyle fromDictionary:merged];
            [panel setStyle:style];
        }
    }
    if (params[@"maxWords"]) {
        panel.maxWordsPerSegment = [params[@"maxWords"] unsignedIntegerValue];
        [panel regroupSegments];
    }

    // Run on background thread to avoid blocking RPC response
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *genResult = [panel generateCaptions];
    });

    return @{@"status": @"ok", @"message": @"Caption generation started..."};
}
```

**`captions.setStyle`**: Supports preset-as-base with parameter
overrides — the dictionary merge pattern.

**`captions.setWords`**: Direct word injection from external sources:

```objc
static NSDictionary *SpliceKit_handleCaptionsSetWords(NSDictionary *params) {
    NSArray *wordDicts = params[@"words"];
    if (!wordDicts || ![wordDicts isKindOfClass:[NSArray class]])
        return @{@"error": @"words array required"};
    [[SpliceKitCaptionPanel sharedPanel] setWordsManually:wordDicts];
    return @{@"status": @"ok", @"wordCount": @(wordDicts.count)};
}
```

---

## 12. MCP Tool Definitions

The MCP tools in `mcp/splicekit_mcp/tools/captions.py` provide the external API.
Each tool maps to a `captions.*` JSON-RPC call.

| MCP Tool | RPC Method | Purpose |
|----------|-----------|---------|
| `open_captions(style, force_retranscribe)` | `captions.open` | Open panel, transcribe the timeline (`fileURL` is refused) |
| `close_captions()` | `captions.close` | Close the panel |
| `get_caption_state()` | `captions.getState` | Status, words, segments, style |
| `get_caption_styles()` | `captions.getStyles` | List all 12 presets |
| `set_caption_style(preset_id, font, ...)` | `captions.setStyle` | Configure style |
| `set_caption_grouping(mode, max_words, ...)` | `captions.setGrouping` | Configure segmentation |
| `generate_captions(style, position, ...)` | `captions.generate` | Generate + import |
| `export_captions_srt(path)` | `captions.exportSRT` | Export SRT file |
| `export_captions_txt(path)` | `captions.exportTXT` | Export plain text |
| `set_caption_words(words)` | `captions.setWords` | Inject external words |

### Example MCP usage flow

```python
# 1. Open panel and transcribe
open_captions(style="bold_pop")

# 2. Wait for transcription
get_caption_state()  # poll until status="ready"

# 3. Adjust style
set_caption_style(preset_id="neon_glow", font_size=80, position="center")

# 4. Adjust grouping
set_caption_grouping(mode="words", max_words=3)

# 5. Generate and import
generate_captions()

# 6. Export
export_captions_srt(path="/tmp/my_captions.srt")
```

### One-shot usage

```python
# Set words manually (bypass transcription)
set_caption_words(words='[
    {"text": "Hello", "startTime": 0.0, "duration": 0.5},
    {"text": "world", "startTime": 0.6, "duration": 0.4}
]')

# Generate in one call with all parameters
generate_captions(style="social_bold", position="center",
                  word_highlight=True, max_words=4, all_caps=True)
```

---

## 13. Export Formats

### SRT Export

Standard SubRip subtitle format:

```
1
00:00:01,500 --> 00:00:02,800
THE QUICK BROWN

2
00:00:02,900 --> 00:00:04,100
FOX JUMPS OVER

3
00:00:04,200 --> 00:00:05,500
THE LAZY DOG
```

**Timestamp format:** `HH:MM:SS,mmm` (hours, minutes, seconds, milliseconds)

```objc
- (NSString *)srtTimestamp:(double)seconds {
    int h = (int)(seconds / 3600);
    int m = (int)(fmod(seconds, 3600) / 60);
    int s = (int)fmod(seconds, 60);
    int ms = (int)((seconds - floor(seconds)) * 1000);
    return [NSString stringWithFormat:@"%02d:%02d:%02d,%03d", h, m, s, ms];
}
```

Empty segments (whitespace-only text after trimming) are skipped.

### TXT Export

One line per segment, no timecodes:

```
THE QUICK BROWN
FOX JUMPS OVER
THE LAZY DOG
```

Both formats respect the `allCaps` style setting.

---

## 14. Reusing This System for Another Caption Engine

The caption system is designed with clear separation of concerns. Here's how
another caption system could reuse different parts.

### 14.1 Integration Points

```
┌───────────────────────────────────────────────────────┐
│                    YOUR SYSTEM                         │
│                                                       │
│  ┌─────────────┐    ┌──────────────┐    ┌──────────┐ │
│  │ Your        │───>│ Word Array   │───>│ FCPXML   │ │
│  │ Transcriber │    │ Interface    │    │ Generator│ │
│  │ (Whisper,   │    │              │    │          │ │
│  │  Rev.ai,    │    │ [text,       │    │ Reusable │ │
│  │  Deepgram)  │    │  startTime,  │    │ as-is    │ │
│  │             │    │  duration]   │    │          │ │
│  └─────────────┘    └──────────────┘    └──────────┘ │
│         ↓                   ↓                  ↓     │
│    REPLACEABLE        INTEGRATION          REUSABLE   │
│                         POINT                         │
└───────────────────────────────────────────────────────┘
```

### 14.2 Minimal Implementation: Injecting Words

The simplest way to use the caption system with a different transcription
engine is via `set_caption_words`:

```python
import json, subprocess

# 1. Run your own transcription engine
result = your_whisper_transcribe("/path/to/audio.wav")

# 2. Format as word array
words = []
for word in result.words:
    words.append({
        "text": word.text,
        "startTime": word.start_time,  # seconds (float)
        "duration": word.end_time - word.start_time
    })

# 3. Inject into SpliceKit's caption system
set_caption_words(words=json.dumps(words))

# 4. Generate captions using existing style system
generate_captions(style="bold_pop")
```

**What you provide:** Just an array of `{text, startTime, duration}` dictionaries.

**What you get:** Full FCPXML generation, styling, segmentation, lane placement,
and FCP import — all handled by the existing system.

### 14.3 Custom Style: Extending the Preset System

To add new presets, modify `builtInPresets` in `SpliceKitCaptionStyle.m`:

```objc
// 13. Your Custom Style
{
    SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
    s.presetID = @"my_custom_style";
    s.name = @"My Custom Style";
    s.font = @"SF Pro Display";
    s.fontSize = 64;
    s.fontFace = @"Bold";
    s.textColor = [NSColor colorWithRed:0.9 green:0.9 blue:0.9 alpha:1];
    s.highlightColor = [NSColor colorWithRed:0 green:0.8 blue:0.4 alpha:1];
    s.outlineColor = nil;
    s.outlineWidth = 0;
    s.shadowColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:0.6];
    s.shadowBlurRadius = 6;
    s.position = SpliceKitCaptionPositionBottom;
    s.animation = SpliceKitCaptionAnimationFade;
    s.animationDuration = 0.15;
    s.allCaps = NO;
    s.wordByWordHighlight = YES;
    [list addObject:s];
}
```

Or use `set_caption_style` with custom parameters at runtime (no code change):

```python
set_caption_style(
    font="SF Pro Display",
    font_size=64,
    text_color="0.9 0.9 0.9 1",
    highlight_color="0 0.8 0.4 1",
    outline_width=0,
    position="bottom",
    animation="fade",
    word_highlight=True,
    all_caps=False
)
```

### 14.4 Alternative Import Strategies

The current system uses NSOpenPanel swizzling + SRT import. Alternative
strategies that could be implemented:

#### A. Pasteboard FCPXML Import

SpliceKit already has a pasteboard import handler in `Sources/Bridge/SpliceKitServerFCPXML.m`
(`SpliceKit_handlePasteboardImportXML`), and the `pasteAnchored:` / `paste:` swizzle there converts
FCPXML on the pasteboard to FCP's native format (see [fcpxml-paste.md](fcpxml-paste.md)).
Instead of the SRT swizzle, you could import the FCPXML directly:

```objc
// Write FCPXML to pasteboard with FCP's custom type
NSPasteboard *pb = [NSPasteboard generalPasteboard];
[pb declareTypes:@[@"IXXMLPasteboardType"] owner:nil];
[pb setString:fcpxmlString forType:@"IXXMLPasteboardType"];

// Trigger paste
SEL pasteSel = NSSelectorFromString(@"paste:");
[NSApp sendAction:pasteSel to:nil from:nil];
```

This would import the FCPXML titles directly into the current timeline position,
preserving all styling information (which the SRT import loses).

#### B. Direct FFAnchoredCaption Creation

For native FCP captions (not styled titles), you could create `FFAnchoredCaption`
objects directly:

```objc
// Find the class
Class captionClass = NSClassFromString(@"FFAnchoredCaption");
// Create and configure...
```

This would use FCP's built-in caption system but loses the rich styling.

#### C. File-Based FCPXML Import

```objc
// Write FCPXML to file, then import via File > Import > XML
[fcpxml writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
NSURL *url = [NSURL fileURLWithPath:path];

// Use FCP's XML import action
SEL importSel = NSSelectorFromString(@"importXML:");
// ... swizzle and trigger
```

### 14.5 Building a New Panel That Reuses the FCPXML Generator

To build a completely new caption UI that reuses the generation engine:

```objc
@interface MyCaptionSystem : NSObject

- (void)generateFromWords:(NSArray<NSDictionary *> *)wordDicts
                 withStyle:(SpliceKitCaptionStyle *)style {

    // 1. Inject words into the shared caption panel
    SpliceKitCaptionPanel *panel = [SpliceKitCaptionPanel sharedPanel];
    [panel setWordsManually:wordDicts];

    // 2. Set your style
    [panel setStyle:style];

    // 3. Configure segmentation
    panel.groupingMode = SpliceKitCaptionGroupingByWordCount;
    panel.maxWordsPerSegment = 4;
    [panel regroupSegments];

    // 4. Generate — this builds FCPXML and imports to timeline
    NSDictionary *result = [panel generateCaptions];
    // result contains titleCount, segmentCount, fcpxmlPath, srtPath
}

@end
```

### 14.6 Using the Lane System for Non-Caption Overlays

The lane 1 pattern can be adapted for any connected storyline content:

**Lower thirds:**

```xml
<title ref="r2" lane="1" name="LowerThird_001"
       offset="2400/2400s" duration="12000/2400s" start="3600s">
    <text>
        <text-style ref="ts1">JOHN SMITH</text-style>
        <text-style ref="ts2">Senior Engineer</text-style>
    </text>
    <adjust-transform position="0 -400"/>
</title>
```

**Watermarks (use a different lane to avoid conflicts):**

```xml
<title ref="r2" lane="2" name="Watermark"
       offset="0s" duration="72000/2400s" start="3600s">
    <text>
        <text-style ref="ts1">DRAFT</text-style>
    </text>
    <adjust-transform position="500 400"/>  <!-- top-right corner -->
</title>
```

**Progress indicators, chapter titles, score overlays** — anything that
needs to be time-positioned above the primary video can use the same
gap-anchor + lane N + title element pattern.

---

## 15. Thread Safety & Concurrency

The caption system uses several threading strategies:

**Mutable arrays** (`mutableWords`, `mutableSegments`): Protected by
`@synchronized(self.mutableWords)` when reading or writing.

**UI updates**: Always dispatched to main thread via `dispatch_async(dispatch_get_main_queue(), ...)`.

**FCPXML generation** (`generateCaptions`): Called from a background thread
(QOS_CLASS_USER_INITIATED) by the RPC handler. The method itself is thread-safe
because it copies the word/segment arrays and style before building XML.

**NSOpenPanel swizzling**: Must happen on the main thread. The `generateCaptions`
method uses `dispatch_sync(dispatch_get_main_queue(), ...)` for this critical section.

**Timeline property detection**: Uses `objc_msgSend` to call FCP's ObjC methods.
These must be called from any thread but the returned values are copied to
instance variables immediately.

---

## 16. Color Conversion Utilities

Two helper functions handle conversion between NSColor and FCPXML's
`"R G B A"` space-separated float format:

```objc
// NSColor → FCPXML string (e.g., "1.000 0.850 0.000 1.000")
static NSString *SpliceKitCaption_colorToFCPXML(NSColor *color) {
    if (!color) return @"1 1 1 1";
    NSColor *rgb = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!rgb) rgb = color;
    return [NSString stringWithFormat:@"%.3f %.3f %.3f %.3f",
            rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent];
}

// FCPXML string → NSColor
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
```

**Important:** Colors are converted to sRGB color space before extraction. This
ensures consistent results regardless of the user's display profile or the
NSColor's original color space.

Text content is XML-escaped with the shared `SpliceKit_escapeXMLWithApostrophe()`
(declared in `Sources/Core/SpliceKitStrings.h`), which escapes `&`, `<`, `>`, `"` and `'`.
The caption panel used to carry its own copy (`SpliceKitCaption_escapeXML`); the
`escapeXML(...)` calls in the excerpts above are that function.

---

## 17. File Manifest

| File | Content |
|------|---------|
| `Sources/Panels/Captions/SpliceKitCaptionPanel.h` | Interface, enums, SpliceKitCaptionStyle, SpliceKitCaptionSegment, SpliceKitCaptionPanel |
| `Sources/Panels/Captions/SpliceKitCaptionPanel+Private.h` | Private interface shared by the categories |
| `Sources/Panels/Captions/SpliceKitCaptionPanel.m` | Panel core: init, word import, segmentation, `-generateCaptions`, export, state |
| `Sources/Panels/Captions/SpliceKitCaptionPanel+FCPXML.m` | Timeline property detection, text-style and title XML builders |
| `Sources/Panels/Captions/SpliceKitCaptionPanel+Timeline.m` | Placing captions on the timeline, rational time helpers |
| `Sources/Panels/Captions/SpliceKitCaptionPanel+Transcription.m` | Transcription hand-off to the transcript panel |
| `Sources/Panels/Captions/SpliceKitCaptionPanel+UI.m` | Floating panel, controls, live preview |
| `Sources/Panels/Captions/SpliceKitCaptionPanel+Persistence.m` | Saved drafts and settings |
| `Sources/Panels/Captions/SpliceKitCaptionStyle.m` | Style and segment models, built-in presets, color conversion |
| `Sources/Panels/Transcript/SpliceKitTranscriptPanel.h` | SpliceKitTranscriptWord model, engine enum, panel interface |
| `Sources/Panels/Transcript/SpliceKitTranscriptPanel.m` | Transcription engines, word extraction, silence detection |
| `Sources/Bridge/SpliceKitServerCaptions.m` | RPC handlers for the `captions.*` namespace |
| `Sources/Bridge/SpliceKitRPCTable.def` | The `captions.*` rows of the RPC dispatch table |
| `Sources/Core/SpliceKitStrings.h` | `SpliceKit_escapeXMLWithApostrophe()` |
| `mcp/splicekit_mcp/tools/captions.py` | MCP tool definitions for the external API |

### Where the key functions live

| Function | File |
|----------|------|
| `SpliceKitCaption_colorToFCPXML()` — NSColor → FCPXML string | `SpliceKitCaptionStyle.m` |
| `SpliceKitCaption_colorFromString()` — FCPXML string → NSColor | `SpliceKitCaptionStyle.m` |
| `SpliceKitCaptionStyle -init` — default style values | `SpliceKitCaptionStyle.m` |
| `+builtInPresets`, `+presetWithID:` — style presets | `SpliceKitCaptionStyle.m` |
| `SpliceKitCaptionSegment -toDictionary` | `SpliceKitCaptionStyle.m` |
| `SpliceKitCaptionPanel -init` — defaults (24fps, 1920x1080) | `SpliceKitCaptionPanel.m` |
| `-setupPanelIfNeeded`, `-buildUI:`, `-syncUIFromStyle`, `-updatePreview` | `SpliceKitCaptionPanel+UI.m` |
| `-transcribeTimeline` — delegate to transcript panel | `SpliceKitCaptionPanel.m` |
| `-setWordsManually:` — external word injection | `SpliceKitCaptionPanel.m` |
| `-regroupSegments` — segmentation algorithm | `SpliceKitCaptionPanel.m` |
| `-detectTimelineProperties` — frame rate + resolution | `SpliceKitCaptionPanel+FCPXML.m` |
| `SpliceKitCaption_durRational()` — seconds → rational time | `SpliceKitCaptionPanel+Timeline.m` |
| `-textStyleXMLWithID:color:isHighlight:` — text-style-def | `SpliceKitCaptionPanel+FCPXML.m` |
| **`-generateCaptions`** — FCPXML build + paste | `SpliceKitCaptionPanel.m` |
| `-exportSRT:`, `-exportTXT:`, `-srtTimestamp:` | `SpliceKitCaptionPanel.m` |
| `-getState` — current panel state as dictionary | `SpliceKitCaptionPanel.m` |
