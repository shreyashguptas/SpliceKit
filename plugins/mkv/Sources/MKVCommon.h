#pragma once

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <Foundation/Foundation.h>
#include <cstdint>
#include <string>
#include <vector>

#include "Private/MediaToolboxSPI.h"

namespace SpliceKitMKV {

// MKV timecode scale is in nanoseconds per tick by default (1,000,000 = ms).
// For FCP we use a fixed 1,000,000,000 Hz (nanosecond) timescale internally —
// but it truncates to int32_t so we downscale to microseconds when building
// CMSampleTimingInfo to stay within int32 limits.
constexpr int32_t kPresentationTimescale = 1000000; // microseconds

struct BlockEntry {
    uint64_t trackNumber;
    int64_t presentationTimeNs;  // absolute PTS in nanoseconds
    int64_t durationNs;          // duration in nanoseconds (0 if unknown)
    int64_t fileOffset;          // absolute byte offset in file
    int32_t frameSize;           // size of this frame's data in bytes
    bool keyframe;
};

struct TrackInfo {
    uint64_t trackNumber;        // MKV native track number
    uint32_t persistentID;       // 1-based, 1 = first track
    CMMediaType mediaType;       // kCMMediaType_Video / kCMMediaType_Audio
    CMFormatDescriptionRef formatDescription; // retained
    std::vector<BlockEntry> blocks; // in decode order
    // Video-specific
    uint32_t width;
    uint32_t height;
    float nominalFrameRate;      // 0 if unknown
    // Audio-specific
    uint32_t sampleRate;
    uint32_t channelCount;
    uint32_t bitDepth;
    // Codec
    uint32_t codecFourCC;        // 'vp09', 'aac ', etc. used for logging
    std::string codecId;         // e.g. "V_VP9", "A_AAC"
};

struct FileData {
    std::string path;
    int64_t fileLength;
    CMTime duration;
    std::vector<TrackInfo> tracks;
};

void Log(NSString *component, NSString *format, ...);
CFStringRef CopyStandardizedPathFromByteSource(MTPluginByteSourceRef byteSource);
NSString *CopyNSString(CFStringRef value);

// Scans the file (via libwebm) and fills outData. Returns noErr on success.
// On failure, outData is left partially populated but the caller should not use it.
OSStatus ScanFile(CFStringRef filePath, FileData &outData, std::string &errorOut);

// Build a CMVideoFormatDescription for a VP9 / AV1 / H264 track.
CMVideoFormatDescriptionRef CreateVideoFormatDescription(CFAllocatorRef allocator,
                                                          const TrackInfo &track,
                                                          const std::vector<uint8_t> &codecPrivate);

// Build a CMAudioFormatDescription for an AAC / Opus / Vorbis / PCM track.
CMAudioFormatDescriptionRef CreateAudioFormatDescription(CFAllocatorRef allocator,
                                                          const TrackInfo &track,
                                                          const std::vector<uint8_t> &codecPrivate);

} // namespace SpliceKitMKV
