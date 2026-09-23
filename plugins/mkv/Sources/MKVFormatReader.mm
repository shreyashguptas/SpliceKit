#include "MKVCommon.h"

#include <CoreMedia/CMFormatDescription.h>
#include <CoreMedia/CMSampleBuffer.h>
#include <algorithm>
#include <cstring>
#include <unistd.h>

using namespace SpliceKitMKV;

namespace {

__attribute__((constructor))
static void MKVFormatReaderBundleDidLoad()
{
    Log(@"reader", @"bundle loaded pid=%d", getpid());
}

#if defined(__x86_64__)
constexpr size_t kCMBasePadSize = 4;
#else
constexpr size_t kCMBasePadSize = 0;
#endif

struct AlignedBaseClass {
    uint8_t pad[kCMBasePadSize];
    CMBaseClass baseClass;
};

struct MKVFormatReader;
struct MKVTrackReader;
struct MKVSampleCursor;

template<typename T>
static T *Storage(CMBaseObjectRef object)
{
    return static_cast<T *>(CMBaseObjectGetDerivedStorage(object));
}

static MKVFormatReader *ReaderFromRef(MTPluginFormatReaderRef r) {
    return Storage<MKVFormatReader>((CMBaseObjectRef)r);
}
static MKVTrackReader *TrackFromRef(MTPluginTrackReaderRef t) {
    return Storage<MKVTrackReader>((CMBaseObjectRef)t);
}
static MKVSampleCursor *CursorFromRef(MTPluginSampleCursorRef c) {
    return Storage<MKVSampleCursor>((CMBaseObjectRef)c);
}

// --------- Reader / Track / Cursor -----------------------------------------

struct MKVFormatReader {
    CFAllocatorRef allocator { nullptr };
    MTPluginByteSourceRef byteSource { nullptr };
    CFStringRef filePath { nullptr };
    FileData data;
    OSStatus status { noErr };

    MKVFormatReader(CFAllocatorRef inAllocator, MTPluginByteSourceRef source)
        : allocator((CFAllocatorRef)CFRetain(inAllocator ?: kCFAllocatorDefault))
        , byteSource((MTPluginByteSourceRef)CFRetain(source))
    {
        filePath = CopyStandardizedPathFromByteSource(source);
        if (!filePath) {
            status = kMTPluginFormatReaderError_ParsingFailure;
            Log(@"reader", @"could not get file path from byte source");
            return;
        }
        std::string err;
        status = ScanFile(filePath, data, err);
        if (status != noErr) {
            Log(@"reader", @"ScanFile failed for %@: %s", CopyNSString(filePath), err.c_str());
        }
    }

    ~MKVFormatReader()
    {
        for (auto &t : data.tracks) {
            if (t.formatDescription) {
                CFRelease(t.formatDescription);
                t.formatDescription = nullptr;
            }
        }
        if (filePath) CFRelease(filePath);
        if (byteSource) CFRelease(byteSource);
        if (allocator) CFRelease(allocator);
    }
};

struct MKVTrackReader {
    CFAllocatorRef allocator { nullptr };
    MTPluginFormatReaderRef owner { nullptr };
    size_t trackIndex { 0 }; // into reader->data.tracks

    MKVTrackReader(CFAllocatorRef inAllocator, MTPluginFormatReaderRef reader, size_t index)
        : allocator((CFAllocatorRef)CFRetain(inAllocator ?: kCFAllocatorDefault))
        , owner((MTPluginFormatReaderRef)CFRetain(reader))
        , trackIndex(index)
    {
    }

    ~MKVTrackReader()
    {
        if (owner) CFRelease(owner);
        if (allocator) CFRelease(allocator);
    }

    const TrackInfo &track() const {
        return ReaderFromRef(owner)->data.tracks[trackIndex];
    }
};

struct MKVSampleCursor {
    CFAllocatorRef allocator { nullptr };
    MTPluginTrackReaderRef track { nullptr };
    int64_t blockIndex { 0 }; // may be negative (before start) or >= blocks.size() (past end)

    MKVSampleCursor(CFAllocatorRef inAllocator, MTPluginTrackReaderRef trackRef, int64_t index)
        : allocator((CFAllocatorRef)CFRetain(inAllocator ?: kCFAllocatorDefault))
        , track((MTPluginTrackReaderRef)CFRetain(trackRef))
        , blockIndex(index)
    {
    }

    ~MKVSampleCursor()
    {
        if (track) CFRelease(track);
        if (allocator) CFRelease(allocator);
    }

    const TrackInfo &trackInfo() const { return TrackFromRef(track)->track(); }
    int64_t sampleCount() const { return (int64_t)trackInfo().blocks.size(); }
    bool valid() const { return blockIndex >= 0 && blockIndex < sampleCount(); }
};

// --------- MT callbacks: reader ------------------------------------------

static CFStringRef CopyReaderDebugDescription(CMBaseObjectRef) {
    return CFSTR("SpliceKit MKV format reader");
}

static void FinalizeReader(CMBaseObjectRef object) {
    Storage<MKVFormatReader>(object)->~MKVFormatReader();
}

static OSStatus ReaderCopyProperty(CMBaseObjectRef object, CFStringRef key,
                                    CFAllocatorRef allocator, void *valueOut)
{
    MKVFormatReader *reader = Storage<MKVFormatReader>(object);
    if (!reader || reader->status != noErr) {
        return reader ? reader->status : kMTPluginFormatReaderError_ParsingFailure;
    }
    if (CFEqual(key, kMTPluginFormatReaderProperty_Duration)) {
        CFDictionaryRef d = CMTimeCopyAsDictionary(reader->data.duration,
                                                    allocator ?: kCFAllocatorDefault);
        if (!d) return kCMBaseObjectError_ValueNotAvailable;
        *reinterpret_cast<CFDictionaryRef *>(valueOut) = d;
        return noErr;
    }
    return kCMBaseObjectError_ValueNotAvailable;
}

static const AlignedBaseClass kReaderBaseClass = {
    {},
    {
        kCMBaseObject_ClassVersion_1,
        sizeof(MKVFormatReader),
        nullptr, nullptr,
        FinalizeReader,
        CopyReaderDebugDescription,
        ReaderCopyProperty,
        nullptr, nullptr, nullptr,
    }
};

static OSStatus ReaderCopyTrackArray(MTPluginFormatReaderRef readerRef, CFArrayRef *trackArrayOut);

static const MTPluginFormatReaderClass kReaderClass = {
    kMTPluginFormatReader_ClassVersion_1,
    ReaderCopyTrackArray,
    nullptr,
};

static const MTPluginFormatReaderVTable kReaderVTable = {
    { nullptr, &kReaderBaseClass.baseClass },
    &kReaderClass,
};

// --------- MT callbacks: track --------------------------------------------

static CFStringRef CopyTrackDebugDescription(CMBaseObjectRef) {
    return CFSTR("SpliceKit MKV track reader");
}

static void FinalizeTrack(CMBaseObjectRef object) {
    Storage<MKVTrackReader>(object)->~MKVTrackReader();
}

static OSStatus TrackCopyProperty(CMBaseObjectRef object, CFStringRef key,
                                   CFAllocatorRef allocator, void *valueOut)
{
    MKVTrackReader *trackReader = Storage<MKVTrackReader>(object);
    if (!trackReader) return kCMBaseObjectError_ValueNotAvailable;
    const TrackInfo &track = trackReader->track();
    bool isAudio = (track.mediaType == kCMMediaType_Audio);

    if (CFEqual(key, kMTPluginTrackReaderProperty_Enabled)) {
        *reinterpret_cast<CFBooleanRef *>(valueOut) = kCFBooleanTrue;
        return noErr;
    }
    if (CFEqual(key, kMTPluginTrackReaderProperty_FormatDescriptionArray)) {
        const void *values[1] = { track.formatDescription };
        CFArrayRef arr = CFArrayCreate(allocator ?: trackReader->allocator,
                                       values, 1, &kCFTypeArrayCallBacks);
        *reinterpret_cast<CFArrayRef *>(valueOut) = arr;
        return arr ? noErr : kCMBaseObjectError_ValueNotAvailable;
    }
    if (CFEqual(key, kMTPluginTrackReaderProperty_Dimensions)) {
        if (isAudio) return kCMBaseObjectError_ValueNotAvailable;
        int32_t dims[2] = { (int32_t)track.width, (int32_t)track.height };
        CFDataRef d = CFDataCreate(allocator ?: trackReader->allocator,
                                    (const UInt8 *)dims, (CFIndex)sizeof(dims));
        *reinterpret_cast<CFDataRef *>(valueOut) = d;
        return d ? noErr : kCMBaseObjectError_ValueNotAvailable;
    }
    if (CFEqual(key, kMTPluginTrackReaderProperty_NominalFrameRate)) {
        if (isAudio || track.nominalFrameRate <= 0.0f) {
            return kCMBaseObjectError_ValueNotAvailable;
        }
        float r = track.nominalFrameRate;
        *reinterpret_cast<CFNumberRef *>(valueOut) = CFNumberCreate(
            allocator ?: trackReader->allocator, kCFNumberFloat32Type, &r);
        return noErr;
    }
    if (CFEqual(key, kMTPluginTrackReaderProperty_NaturalTimescale)) {
        int32_t ts = isAudio ? (int32_t)track.sampleRate : kPresentationTimescale;
        if (ts <= 0) ts = kPresentationTimescale;
        *reinterpret_cast<CFNumberRef *>(valueOut) = CFNumberCreate(
            allocator ?: trackReader->allocator, kCFNumberSInt32Type, &ts);
        return noErr;
    }
    if (CFEqual(key, kMTPluginTrackReaderProperty_UneditedDuration)) {
        CMTime d = ReaderFromRef(trackReader->owner)->data.duration;
        CFDictionaryRef dict = CMTimeCopyAsDictionary(d, allocator ?: trackReader->allocator);
        *reinterpret_cast<CFDictionaryRef *>(valueOut) = dict;
        return dict ? noErr : kCMBaseObjectError_ValueNotAvailable;
    }
    return kCMBaseObjectError_ValueNotAvailable;
}

static const AlignedBaseClass kTrackBaseClass = {
    {},
    {
        kCMBaseObject_ClassVersion_1,
        sizeof(MKVTrackReader),
        nullptr, nullptr,
        FinalizeTrack,
        CopyTrackDebugDescription,
        TrackCopyProperty,
        nullptr, nullptr, nullptr,
    }
};

static OSStatus TrackGetTrackInfo(MTPluginTrackReaderRef trackRef,
                                   MTPersistentTrackID *trackIDOut,
                                   CMMediaType *mediaTypeOut)
{
    MKVTrackReader *tr = TrackFromRef(trackRef);
    if (!tr) return paramErr;
    const TrackInfo &info = tr->track();
    if (trackIDOut) *trackIDOut = (MTPersistentTrackID)info.persistentID;
    if (mediaTypeOut) *mediaTypeOut = info.mediaType;
    return noErr;
}

static CMItemCount TrackGetTrackEditCount(MTPluginTrackReaderRef) {
    return 1;
}

static OSStatus TrackGetTrackEditWithIndex(MTPluginTrackReaderRef trackRef,
                                            CMItemCount editIndex,
                                            CMTimeMapping *mappingOut)
{
    if (editIndex != 0 || !mappingOut) return paramErr;
    MKVTrackReader *tr = TrackFromRef(trackRef);
    if (!tr) return paramErr;
    CMTime d = ReaderFromRef(tr->owner)->data.duration;
    CMTimeRange r = CMTimeRangeMake(kCMTimeZero, d);
    mappingOut->source = r;
    mappingOut->target = r;
    return noErr;
}

static OSStatus CreateCursorForIndex(MTPluginTrackReaderRef trackRef, int64_t index,
                                      MTPluginSampleCursorRef *cursorOut);

static OSStatus TrackCreateCursorAtFirst(MTPluginTrackReaderRef trackRef,
                                          MTPluginSampleCursorRef *out)
{
    return CreateCursorForIndex(trackRef, 0, out);
}

static OSStatus TrackCreateCursorAtLast(MTPluginTrackReaderRef trackRef,
                                         MTPluginSampleCursorRef *out)
{
    MKVTrackReader *tr = TrackFromRef(trackRef);
    if (!tr) return paramErr;
    int64_t count = (int64_t)tr->track().blocks.size();
    return CreateCursorForIndex(trackRef, std::max<int64_t>(0, count - 1), out);
}

static OSStatus TrackCreateCursorAtPresentationTime(MTPluginTrackReaderRef trackRef,
                                                     CMTime ts,
                                                     MTPluginSampleCursorRef *out)
{
    MKVTrackReader *tr = TrackFromRef(trackRef);
    if (!tr) return paramErr;
    const auto &blocks = tr->track().blocks;
    if (blocks.empty()) return CreateCursorForIndex(trackRef, 0, out);

    double seconds = CMTimeGetSeconds(ts);
    int64_t targetNs = (int64_t)(seconds * 1e9);

    // binary search for largest block whose PTS <= target (so we can decode from a keyframe)
    int64_t lo = 0, hi = (int64_t)blocks.size() - 1, best = 0;
    while (lo <= hi) {
        int64_t mid = (lo + hi) / 2;
        if (blocks[mid].presentationTimeNs <= targetNs) {
            best = mid;
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }
    // walk back to nearest preceding keyframe
    int64_t kfIdx = best;
    while (kfIdx > 0 && !blocks[kfIdx].keyframe) kfIdx--;
    return CreateCursorForIndex(trackRef, kfIdx, out);
}

static const MTPluginTrackReaderClass kTrackClass = {
    kMTPluginTrackReader_ClassVersion_1,
    TrackGetTrackInfo,
    TrackGetTrackEditCount,
    TrackGetTrackEditWithIndex,
    TrackCreateCursorAtPresentationTime,
    TrackCreateCursorAtFirst,
    TrackCreateCursorAtLast,
};

static const MTPluginTrackReaderVTable kTrackVTable = {
    { nullptr, &kTrackBaseClass.baseClass },
    &kTrackClass,
};

// --------- MT callbacks: cursor -------------------------------------------

static CFStringRef CopyCursorDebugDescription(CMBaseObjectRef) {
    return CFSTR("SpliceKit MKV sample cursor");
}

static void FinalizeCursor(CMBaseObjectRef object) {
    Storage<MKVSampleCursor>(object)->~MKVSampleCursor();
}

static const AlignedBaseClass kCursorBaseClass = {
    {},
    {
        kCMBaseObject_ClassVersion_1,
        sizeof(MKVSampleCursor),
        nullptr, nullptr,
        FinalizeCursor,
        CopyCursorDebugDescription,
        nullptr, nullptr, nullptr, nullptr,
    }
};

static OSStatus CursorCopy(MTPluginSampleCursorRef cursorRef,
                            MTPluginSampleCursorRef *outCursor);
static OSStatus CursorStepDecode(MTPluginSampleCursorRef c, int64_t steps, int64_t *taken);
static OSStatus CursorStepPresentation(MTPluginSampleCursorRef c, int64_t steps, int64_t *taken);
static OSStatus CursorStepByDecodeTime(MTPluginSampleCursorRef c, CMTime dt, Boolean *positionedOut);
static OSStatus CursorStepByPresentationTime(MTPluginSampleCursorRef c, CMTime dt, Boolean *positionedOut);
static CFComparisonResult CursorCompare(MTPluginSampleCursorRef a, MTPluginSampleCursorRef b);
static OSStatus CursorGetSampleTiming(MTPluginSampleCursorRef c, CMSampleTimingInfo *out);
static OSStatus CursorGetSyncInfo(MTPluginSampleCursorRef c, MTPluginSampleCursorSyncInfo *out);
static OSStatus CursorGetDependencyInfo(MTPluginSampleCursorRef c, MTPluginSampleCursorDependencyInfo *out);
static Boolean  CursorTestReorder(MTPluginSampleCursorRef a, MTPluginSampleCursorRef b, MTPluginSampleCursorReorderingBoundary);
static OSStatus CursorCopySampleLocation(MTPluginSampleCursorRef c,
                                           MTPluginSampleCursorStorageRange *range,
                                           MTPluginByteSourceRef *source);
static OSStatus CursorCopyChunkDetails(MTPluginSampleCursorRef c,
                                        MTPluginByteSourceRef *source,
                                        MTPluginSampleCursorStorageRange *range,
                                        MTPluginSampleCursorChunkInfo *chunk,
                                        CMItemCount *itemCount);
static OSStatus CursorCopyFormatDescription(MTPluginSampleCursorRef c, CMFormatDescriptionRef *out);
static OSStatus CursorCreateSampleBuffer(MTPluginSampleCursorRef c, MTPluginSampleCursorRef, CMSampleBufferRef *out);
static OSStatus CursorGetPlayableHorizon(MTPluginSampleCursorRef c, CMTime *horizon);

static const MTPluginSampleCursorClass kCursorClass = {
    kMTPluginSampleCursor_ClassVersion_3,
    CursorCopy,
    CursorStepDecode,
    CursorStepPresentation,
    CursorStepByDecodeTime,
    CursorStepByPresentationTime,
    CursorCompare,
    CursorGetSampleTiming,
    CursorGetSyncInfo,
    CursorGetDependencyInfo,
    CursorTestReorder,
    CursorCopySampleLocation,
    CursorCopyChunkDetails,
    CursorCopyFormatDescription,
    CursorCreateSampleBuffer,
    nullptr, nullptr, nullptr,
    CursorGetPlayableHorizon,
};

static const MTPluginSampleCursorVTable kCursorVTable = {
    { nullptr, &kCursorBaseClass.baseClass },
    &kCursorClass,
    nullptr,
};

static OSStatus CreateCursorForIndex(MTPluginTrackReaderRef trackRef, int64_t index,
                                      MTPluginSampleCursorRef *cursorOut)
{
    if (!trackRef || !cursorOut) return paramErr;
    MKVTrackReader *tr = TrackFromRef(trackRef);
    if (!tr) return paramErr;
    CMBaseObjectRef object = nullptr;
    OSStatus st = CMDerivedObjectCreate(tr->allocator,
                                         &kCursorVTable.base,
                                         MTPluginSampleCursorGetClassID(),
                                         &object);
    if (st != noErr || !object) {
        return st ? st : kMTPluginFormatReaderError_AllocationFailure;
    }
    new (Storage<MKVSampleCursor>(object)) MKVSampleCursor(tr->allocator, trackRef, index);
    *cursorOut = reinterpret_cast<MTPluginSampleCursorRef>(object);
    return noErr;
}

static OSStatus CursorCopy(MTPluginSampleCursorRef cursorRef, MTPluginSampleCursorRef *outCursor) {
    MKVSampleCursor *cursor = CursorFromRef(cursorRef);
    if (!cursor || !outCursor) return paramErr;
    return CreateCursorForIndex(cursor->track, cursor->blockIndex, outCursor);
}

static OSStatus CursorStepDecode(MTPluginSampleCursorRef cursorRef, int64_t steps, int64_t *takenOut) {
    MKVSampleCursor *cursor = CursorFromRef(cursorRef);
    if (!cursor) return paramErr;
    int64_t count = cursor->sampleCount();
    int64_t before = cursor->blockIndex;
    cursor->blockIndex = std::max<int64_t>(-1, std::min<int64_t>(count, before + steps));
    if (takenOut) *takenOut = cursor->blockIndex - before;
    return noErr;
}

static OSStatus CursorStepPresentation(MTPluginSampleCursorRef c, int64_t steps, int64_t *takenOut) {
    return CursorStepDecode(c, steps, takenOut);
}

static OSStatus CursorStepByDecodeTime(MTPluginSampleCursorRef cursorRef, CMTime dt, Boolean *positionedOut) {
    MKVSampleCursor *cursor = CursorFromRef(cursorRef);
    if (!cursor) return paramErr;
    const auto &blocks = cursor->trackInfo().blocks;
    if (blocks.empty()) {
        if (positionedOut) *positionedOut = false;
        return noErr;
    }
    int64_t idx = cursor->blockIndex;
    if (idx < 0) idx = 0;
    if (idx >= (int64_t)blocks.size()) idx = (int64_t)blocks.size() - 1;
    int64_t deltaNs = (int64_t)(CMTimeGetSeconds(dt) * 1e9);
    int64_t targetNs = blocks[idx].presentationTimeNs + deltaNs;

    int64_t lo = 0, hi = (int64_t)blocks.size() - 1, best = 0;
    while (lo <= hi) {
        int64_t mid = (lo + hi) / 2;
        if (blocks[mid].presentationTimeNs <= targetNs) { best = mid; lo = mid + 1; }
        else hi = mid - 1;
    }
    cursor->blockIndex = best;
    if (positionedOut) *positionedOut = true;
    return noErr;
}

static OSStatus CursorStepByPresentationTime(MTPluginSampleCursorRef c, CMTime dt, Boolean *positionedOut) {
    return CursorStepByDecodeTime(c, dt, positionedOut);
}

static CFComparisonResult CursorCompare(MTPluginSampleCursorRef a, MTPluginSampleCursorRef b) {
    MKVSampleCursor *ca = CursorFromRef(a);
    MKVSampleCursor *cb = CursorFromRef(b);
    if (!ca || !cb) return kCFCompareEqualTo;
    if (ca->blockIndex < cb->blockIndex) return kCFCompareLessThan;
    if (ca->blockIndex > cb->blockIndex) return kCFCompareGreaterThan;
    return kCFCompareEqualTo;
}

static CMTime PTSForBlock(const TrackInfo &track, const BlockEntry &blk) {
    if (track.mediaType == kCMMediaType_Audio) {
        // Express audio PTS in sample-rate timescale for best precision.
        int64_t samples = (int64_t)((double)blk.presentationTimeNs / 1e9 * (double)track.sampleRate);
        return CMTimeMake(samples, (int32_t)track.sampleRate);
    }
    // Microsecond timescale is safe for int32 for movies up to ~35 minutes; for
    // longer files use nanoseconds but lose precision. Most MKVs use <int32 us.
    int64_t us = blk.presentationTimeNs / 1000;
    return CMTimeMake(us, kPresentationTimescale);
}

static CMTime DurationForBlock(const TrackInfo &track, const BlockEntry &blk) {
    if (blk.durationNs > 0) {
        if (track.mediaType == kCMMediaType_Audio) {
            int64_t samples = (int64_t)((double)blk.durationNs / 1e9 * (double)track.sampleRate);
            return CMTimeMake(samples, (int32_t)track.sampleRate);
        }
        return CMTimeMake(blk.durationNs / 1000, kPresentationTimescale);
    }
    // Fall back to 1/framerate for video, 1024/rate for AAC.
    if (track.mediaType == kCMMediaType_Video) {
        float fr = track.nominalFrameRate > 0.0f ? track.nominalFrameRate : 24.0f;
        return CMTimeMake((int64_t)(1e6 / fr), kPresentationTimescale);
    }
    return CMTimeMake(1024, (int32_t)(track.sampleRate ? track.sampleRate : 48000));
}

static OSStatus CursorGetSampleTiming(MTPluginSampleCursorRef cursorRef, CMSampleTimingInfo *out) {
    MKVSampleCursor *cursor = CursorFromRef(cursorRef);
    if (!cursor || !out) return paramErr;
    if (!cursor->valid()) return kMTPluginSampleCursorError_NoSamples;
    const TrackInfo &track = cursor->trackInfo();
    const BlockEntry &blk = track.blocks[cursor->blockIndex];
    out->duration = DurationForBlock(track, blk);
    out->presentationTimeStamp = PTSForBlock(track, blk);
    out->decodeTimeStamp = out->presentationTimeStamp;
    return noErr;
}

static OSStatus CursorGetSyncInfo(MTPluginSampleCursorRef cursorRef, MTPluginSampleCursorSyncInfo *out) {
    MKVSampleCursor *cursor = CursorFromRef(cursorRef);
    if (!cursor || !out) return paramErr;
    if (!cursor->valid()) return kMTPluginSampleCursorError_NoSamples;
    const BlockEntry &blk = cursor->trackInfo().blocks[cursor->blockIndex];
    out->fullSync = blk.keyframe;
    out->partialSync = false;
    out->droppable = false;
    return noErr;
}

static OSStatus CursorGetDependencyInfo(MTPluginSampleCursorRef cursorRef, MTPluginSampleCursorDependencyInfo *out) {
    MKVSampleCursor *cursor = CursorFromRef(cursorRef);
    if (!cursor || !out) return paramErr;
    if (!cursor->valid()) return kMTPluginSampleCursorError_NoSamples;
    const BlockEntry &blk = cursor->trackInfo().blocks[cursor->blockIndex];
    memset(out, 0, sizeof(*out));
    // Keyframe: doesn't depend on others
    out->sampleIndicatesWhetherItDependsOnOthers = true;
    out->sampleDependsOnOthers = !blk.keyframe;
    return noErr;
}

static Boolean CursorTestReorder(MTPluginSampleCursorRef, MTPluginSampleCursorRef, MTPluginSampleCursorReorderingBoundary) {
    return false; // MKV delivered in decode order with no reorder needed for single-cursor stepping
}

static OSStatus CursorCopySampleLocation(MTPluginSampleCursorRef cursorRef,
                                           MTPluginSampleCursorStorageRange *range,
                                           MTPluginByteSourceRef *source)
{
    MKVSampleCursor *cursor = CursorFromRef(cursorRef);
    if (!cursor || !range || !source) return paramErr;
    if (!cursor->valid()) return kMTPluginSampleCursorError_NoSamples;
    MKVTrackReader *tr = TrackFromRef(cursor->track);
    MKVFormatReader *reader = ReaderFromRef(tr->owner);
    const BlockEntry &blk = cursor->trackInfo().blocks[cursor->blockIndex];
    range->offset = blk.fileOffset;
    range->length = blk.frameSize;
    *source = (MTPluginByteSourceRef)CFRetain(reader->byteSource);
    return noErr;
}

static OSStatus CursorCopyChunkDetails(MTPluginSampleCursorRef cursorRef,
                                        MTPluginByteSourceRef *source,
                                        MTPluginSampleCursorStorageRange *range,
                                        MTPluginSampleCursorChunkInfo *chunk,
                                        CMItemCount *itemCount)
{
    // Represent each MKV frame as its own "chunk" of 1 sample.
    MKVSampleCursor *cursor = CursorFromRef(cursorRef);
    if (!cursor) return paramErr;
    if (!cursor->valid()) return kMTPluginSampleCursorError_NoSamples;
    const BlockEntry &blk = cursor->trackInfo().blocks[cursor->blockIndex];
    MKVTrackReader *tr = TrackFromRef(cursor->track);
    MKVFormatReader *reader = ReaderFromRef(tr->owner);

    if (range) { range->offset = blk.fileOffset; range->length = blk.frameSize; }
    if (source) *source = (MTPluginByteSourceRef)CFRetain(reader->byteSource);
    if (chunk) {
        chunk->chunkSampleCount = 1;
        chunk->chunkHasUniformSampleSizes = true;
        chunk->chunkHasUniformSampleDurations = true;
        chunk->chunkHasUniformFormatDescriptions = true;
        memset(chunk->pad, 0, sizeof(chunk->pad));
    }
    if (itemCount) *itemCount = 1;
    return noErr;
}

static OSStatus CursorCopyFormatDescription(MTPluginSampleCursorRef cursorRef, CMFormatDescriptionRef *out) {
    MKVSampleCursor *cursor = CursorFromRef(cursorRef);
    if (!cursor || !out) return paramErr;
    const TrackInfo &track = cursor->trackInfo();
    *out = (CMFormatDescriptionRef)CFRetain(track.formatDescription);
    return noErr;
}

static OSStatus CursorCreateSampleBuffer(MTPluginSampleCursorRef cursorRef,
                                          MTPluginSampleCursorRef,
                                          CMSampleBufferRef *sampleBufferOut)
{
    MKVSampleCursor *cursor = CursorFromRef(cursorRef);
    if (!cursor || !sampleBufferOut) return paramErr;
    if (!cursor->valid()) return kMTPluginSampleCursorError_NoSamples;
    const TrackInfo &track = cursor->trackInfo();
    const BlockEntry &blk = track.blocks[cursor->blockIndex];
    MKVTrackReader *tr = TrackFromRef(cursor->track);
    MKVFormatReader *reader = ReaderFromRef(tr->owner);

    void *buffer = malloc((size_t)blk.frameSize);
    if (!buffer) return kMTPluginFormatReaderError_AllocationFailure;
    size_t read = 0;
    OSStatus st = MTPluginByteSourceRead(reader->byteSource,
                                          (size_t)blk.frameSize,
                                          blk.fileOffset,
                                          buffer,
                                          &read);
    if (st != noErr || read != (size_t)blk.frameSize) {
        free(buffer);
        Log(@"cursor", @"byte-source read failed st=%d got=%zu want=%d", (int)st, read, blk.frameSize);
        return st ? st : kMTPluginFormatReaderError_ParsingFailure;
    }

    CMBlockBufferRef blockBuffer = nullptr;
    st = CMBlockBufferCreateWithMemoryBlock(
        tr->allocator,
        buffer,
        (size_t)blk.frameSize,
        kCFAllocatorMalloc,
        nullptr, 0,
        (size_t)blk.frameSize,
        0,
        &blockBuffer);
    if (st != noErr || !blockBuffer) {
        free(buffer);
        return st ? st : kMTPluginFormatReaderError_AllocationFailure;
    }

    CMSampleTimingInfo timing = {};
    timing.duration = DurationForBlock(track, blk);
    timing.presentationTimeStamp = PTSForBlock(track, blk);
    timing.decodeTimeStamp = timing.presentationTimeStamp;
    size_t sampleSize = (size_t)blk.frameSize;

    st = CMSampleBufferCreateReady(
        tr->allocator,
        blockBuffer,
        track.formatDescription,
        1, 1, &timing,
        1, &sampleSize,
        sampleBufferOut);
    CFRelease(blockBuffer);
    return st;
}

static OSStatus CursorGetPlayableHorizon(MTPluginSampleCursorRef cursorRef, CMTime *horizon) {
    MKVSampleCursor *cursor = CursorFromRef(cursorRef);
    if (!cursor || !horizon) return paramErr;
    const TrackInfo &track = cursor->trackInfo();
    if (track.blocks.empty()) { *horizon = kCMTimeZero; return noErr; }
    int64_t lastNs = track.blocks.back().presentationTimeNs + std::max<int64_t>(track.blocks.back().durationNs, 0);
    int64_t currentNs = (cursor->blockIndex >= 0 && cursor->blockIndex < (int64_t)track.blocks.size())
        ? track.blocks[cursor->blockIndex].presentationTimeNs : 0;
    int64_t remainingNs = std::max<int64_t>(0, lastNs - currentNs);
    *horizon = CMTimeMake(remainingNs / 1000, kPresentationTimescale);
    return noErr;
}

// --------- Reader: CopyTrackArray entry point -----------------------------

static OSStatus ReaderCopyTrackArray(MTPluginFormatReaderRef readerRef, CFArrayRef *trackArrayOut) {
    MKVFormatReader *reader = ReaderFromRef(readerRef);
    if (!reader || !trackArrayOut) return paramErr;
    if (reader->status != noErr) return reader->status;

    NSMutableArray *trackArray = [NSMutableArray arrayWithCapacity:reader->data.tracks.size()];
    for (size_t i = 0; i < reader->data.tracks.size(); ++i) {
        CMBaseObjectRef trackObject = nullptr;
        OSStatus st = CMDerivedObjectCreate(
            reader->allocator,
            &kTrackVTable.base,
            MTPluginTrackReaderGetClassID(),
            &trackObject);
        if (st != noErr || !trackObject) {
            return st ? st : kMTPluginFormatReaderError_AllocationFailure;
        }
        new (Storage<MKVTrackReader>(trackObject)) MKVTrackReader(
            reader->allocator, readerRef, i);
        [trackArray addObject:(__bridge id)trackObject];
        CFRelease(trackObject); // array retains
    }
    *trackArrayOut = (CFArrayRef)CFBridgingRetain([trackArray copy]);
    return noErr;
}

} // namespace

extern "C" __attribute__((visibility("default")))
OSStatus MKVPluginFormatReader_CreateInstance(
    MTPluginByteSourceRef byteSource,
    CFAllocatorRef allocator,
    CFDictionaryRef,
    MTPluginFormatReaderRef *readerOut)
{
    if (!byteSource || !readerOut) return paramErr;

    CFStringRef dbgPath = CopyStandardizedPathFromByteSource(byteSource);
    Log(@"reader", @"factory createInstance path=%@", CopyNSString(dbgPath));
    if (dbgPath) CFRelease(dbgPath);

    CMBaseObjectRef object = nullptr;
    OSStatus st = CMDerivedObjectCreate(
        allocator ?: kCFAllocatorDefault,
        &kReaderVTable.base,
        MTPluginFormatReaderGetClassID(),
        &object);
    if (st != noErr || !object) {
        return st ? st : kMTPluginFormatReaderError_AllocationFailure;
    }

    new (Storage<MKVFormatReader>(object)) MKVFormatReader(allocator, byteSource);
    MKVFormatReader *reader = Storage<MKVFormatReader>(object);
    if (reader->status != noErr) {
        OSStatus parseStatus = reader->status;
        CFRelease(object);
        return parseStatus;
    }
    *readerOut = reinterpret_cast<MTPluginFormatReaderRef>(object);
    return noErr;
}
