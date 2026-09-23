#include "MKVCommon.h"

#include <cstdarg>
#include <cstring>
#include <memory>

#include <AudioToolbox/AudioToolbox.h>

#include "libwebm/mkvparser/mkvparser.h"
#include "libwebm/mkvparser/mkvreader.h"

namespace SpliceKitMKV {

static NSString *LogFilePath()
{
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SpliceKit"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return [dir stringByAppendingPathComponent:@"splicekit-mkv.log"];
}

void Log(NSString *component, NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"[%@] [%@] %@\n",
                      [NSDate date], component, body];
    NSLog(@"[SpliceKitMKV] [%@] %@", component, body);

    @try {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:LogFilePath()];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:LogFilePath()
                                                    contents:nil
                                                  attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:LogFilePath()];
        }
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *) {
        // best-effort only
    }
}

NSString *CopyNSString(CFStringRef value)
{
    if (!value) return nil;
    return [NSString stringWithString:(__bridge NSString *)value];
}

CFStringRef CopyStandardizedPathFromByteSource(MTPluginByteSourceRef byteSource)
{
    if (!byteSource) return nullptr;
    CFStringRef raw = MTPluginByteSourceCopyFileName(byteSource);
    if (!raw) return nullptr;
    NSString *path = [(__bridge NSString *)raw stringByStandardizingPath];
    CFRelease(raw);
    return path ? (CFStringRef)CFBridgingRetain(path) : nullptr;
}

// ---- Codec-type helpers --------------------------------------------------

static OSType VideoCodecTypeForCodecId(const std::string &id)
{
    if (id == "V_VP9") return kCMVideoCodecType_VP9;
    if (id == "V_VP8") return 'vp08';
    if (id == "V_AV1") return 'av01';
    if (id == "V_MPEG4/ISO/AVC") return kCMVideoCodecType_H264;
    if (id == "V_MPEGH/ISO/HEVC") return kCMVideoCodecType_HEVC;
    return 0;
}

static UInt32 AudioFormatIDForCodecId(const std::string &id)
{
    if (id == "A_AAC") return kAudioFormatMPEG4AAC;
    if (id == "A_OPUS") return kAudioFormatOpus;
    if (id == "A_VORBIS") return 'Vorb';
    if (id == "A_MPEG/L3") return kAudioFormatMPEGLayer3;
    if (id == "A_MPEG/L2") return kAudioFormatMPEGLayer2;
    if (id == "A_PCM/INT/LIT") return kAudioFormatLinearPCM;
    if (id == "A_PCM/INT/BIG") return kAudioFormatLinearPCM;
    if (id == "A_PCM/FLOAT/IEEE") return kAudioFormatLinearPCM;
    if (id == "A_AC3") return kAudioFormatAC3;
    return 0;
}

// ---- Format description builders ----------------------------------------

CMVideoFormatDescriptionRef CreateVideoFormatDescription(CFAllocatorRef allocator,
                                                          const TrackInfo &track,
                                                          const std::vector<uint8_t> &codecPrivate)
{
    OSType codecType = VideoCodecTypeForCodecId(track.codecId);
    if (codecType == 0) {
        Log(@"fmt", @"unsupported video codec id %s", track.codecId.c_str());
        return nullptr;
    }

    NSMutableDictionary *extensions = [NSMutableDictionary dictionary];

    // Attach the codec-private blob (if any) as the atoms extension.
    // VP9 stores a vpcC-style blob in MKV's CodecPrivate for some muxers;
    // many VP9 MKV files omit it entirely, relying on stream superframes.
    if (!codecPrivate.empty()) {
        NSData *cpData = [NSData dataWithBytes:codecPrivate.data()
                                         length:codecPrivate.size()];
        NSString *atomKey = nil;
        switch (codecType) {
            case kCMVideoCodecType_VP9: atomKey = @"vpcC"; break;
            case 'vp08':                atomKey = @"vpcC"; break;
            case 'av01':                atomKey = @"av1C"; break;
            case kCMVideoCodecType_H264: atomKey = @"avcC"; break;
            case kCMVideoCodecType_HEVC: atomKey = @"hvcC"; break;
            default: break;
        }
        if (atomKey) {
            extensions[(__bridge NSString *)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] =
                @{ atomKey: cpData };
        }
    }

    if (track.nominalFrameRate > 0.0f) {
        extensions[@"NominalFrameRate"] = @(track.nominalFrameRate);
    }

    CMVideoFormatDescriptionRef fd = nullptr;
    OSStatus st = CMVideoFormatDescriptionCreate(
        allocator ?: kCFAllocatorDefault,
        codecType,
        (int32_t)track.width,
        (int32_t)track.height,
        (__bridge CFDictionaryRef)extensions,
        &fd);
    if (st != noErr) {
        Log(@"fmt", @"CMVideoFormatDescriptionCreate failed %d for %s", (int)st, track.codecId.c_str());
        return nullptr;
    }
    return fd;
}

CMAudioFormatDescriptionRef CreateAudioFormatDescription(CFAllocatorRef allocator,
                                                          const TrackInfo &track,
                                                          const std::vector<uint8_t> &codecPrivate)
{
    UInt32 formatID = AudioFormatIDForCodecId(track.codecId);
    if (formatID == 0) {
        Log(@"fmt", @"unsupported audio codec id %s", track.codecId.c_str());
        return nullptr;
    }

    AudioStreamBasicDescription asbd = {};
    asbd.mSampleRate = (Float64)track.sampleRate;
    asbd.mFormatID = formatID;
    asbd.mChannelsPerFrame = track.channelCount;

    UInt32 bitDepth = track.bitDepth ? track.bitDepth : 16;

    if (formatID == kAudioFormatLinearPCM) {
        asbd.mBitsPerChannel = bitDepth;
        asbd.mFramesPerPacket = 1;
        asbd.mBytesPerFrame = (bitDepth / 8) * track.channelCount;
        asbd.mBytesPerPacket = asbd.mBytesPerFrame;
        asbd.mFormatFlags = kLinearPCMFormatFlagIsPacked;
        if (track.codecId == "A_PCM/FLOAT/IEEE") {
            asbd.mFormatFlags |= kLinearPCMFormatFlagIsFloat;
        } else {
            asbd.mFormatFlags |= kLinearPCMFormatFlagIsSignedInteger;
        }
        if (track.codecId == "A_PCM/INT/BIG") {
            asbd.mFormatFlags |= kLinearPCMFormatFlagIsBigEndian;
        }
    } else if (formatID == kAudioFormatMPEG4AAC) {
        asbd.mFramesPerPacket = 1024; // standard AAC-LC
    } else if (formatID == kAudioFormatOpus) {
        asbd.mFramesPerPacket = 960;  // 20ms @ 48k; Opus supports variable
    } else {
        asbd.mFramesPerPacket = 0; // unknown
    }

    CMAudioFormatDescriptionRef fd = nullptr;
    const void *magicCookie = codecPrivate.empty() ? nullptr : codecPrivate.data();
    size_t cookieSize = codecPrivate.size();

    OSStatus st = CMAudioFormatDescriptionCreate(
        allocator ?: kCFAllocatorDefault,
        &asbd,
        0, nullptr,
        cookieSize, magicCookie,
        nullptr,
        &fd);
    if (st != noErr) {
        Log(@"fmt", @"CMAudioFormatDescriptionCreate failed %d for %s", (int)st, track.codecId.c_str());
        return nullptr;
    }
    return fd;
}

// ---- File scan -----------------------------------------------------------

OSStatus ScanFile(CFStringRef filePathRef, FileData &outData, std::string &errorOut)
{
    if (!filePathRef) { errorOut = "null path"; return kMTPluginFormatReaderError_ParsingFailure; }
    NSString *pathNS = (__bridge NSString *)filePathRef;
    const char *pathCStr = pathNS.fileSystemRepresentation;
    if (!pathCStr) { errorOut = "could not get fsrep"; return kMTPluginFormatReaderError_ParsingFailure; }

    outData.path = pathCStr;

    mkvparser::MkvReader reader;
    if (reader.Open(pathCStr) < 0) {
        errorOut = std::string("MkvReader.Open failed on ") + pathCStr;
        return kMTPluginFormatReaderError_ParsingFailure;
    }
    long long total = 0, available = 0;
    reader.Length(&total, &available);
    outData.fileLength = total;

    long long pos = 0;
    mkvparser::EBMLHeader header;
    long long ret = header.Parse(&reader, pos);
    if (ret < 0) {
        errorOut = "EBMLHeader.Parse failed";
        return kMTPluginFormatReaderError_ParsingFailure;
    }
    const char *docType = header.m_docType;
    if (docType && strcmp(docType, "matroska") != 0 && strcmp(docType, "webm") != 0) {
        errorOut = std::string("unsupported EBML docType: ") + (docType ? docType : "(null)");
        return kMTPluginFormatReaderError_ParsingFailure;
    }

    mkvparser::Segment *segmentPtr = nullptr;
    ret = mkvparser::Segment::CreateInstance(&reader, pos, segmentPtr);
    if (ret < 0 || !segmentPtr) {
        errorOut = "Segment::CreateInstance failed";
        return kMTPluginFormatReaderError_ParsingFailure;
    }
    std::unique_ptr<mkvparser::Segment> segment(segmentPtr);

    ret = segment->Load();
    if (ret < 0) {
        errorOut = "Segment::Load failed";
        return kMTPluginFormatReaderError_ParsingFailure;
    }

    const mkvparser::SegmentInfo *segInfo = segment->GetInfo();
    if (!segInfo) {
        errorOut = "no SegmentInfo";
        return kMTPluginFormatReaderError_ParsingFailure;
    }
    long long durationNs = segInfo->GetDuration();
    long long timecodeScale = segInfo->GetTimeCodeScale(); // ns per tick

    outData.duration = CMTimeMake(durationNs, 1000000000);

    const mkvparser::Tracks *mkvTracks = segment->GetTracks();
    if (!mkvTracks) {
        errorOut = "no Tracks element";
        return kMTPluginFormatReaderError_ParsingFailure;
    }

    // Map MKV track number -> index into outData.tracks
    std::vector<std::pair<uint64_t, std::vector<uint8_t>>> codecPrivates; // track-num aligned
    std::vector<int> trackIndexByNumber(256, -1);

    uint32_t persistentID = 1;
    for (unsigned long i = 0; i < mkvTracks->GetTracksCount(); ++i) {
        const mkvparser::Track *mt = mkvTracks->GetTrackByIndex(i);
        if (!mt) continue;
        long typeID = mt->GetType();
        const char *codecIdCStr = mt->GetCodecId();
        if (!codecIdCStr) continue;
        std::string codecId(codecIdCStr);

        TrackInfo info = {};
        info.trackNumber = (uint64_t)mt->GetNumber();
        info.persistentID = persistentID++;
        info.codecId = codecId;

        size_t cpSize = 0;
        const unsigned char *cp = mt->GetCodecPrivate(cpSize);
        std::vector<uint8_t> codecPrivate;
        if (cp && cpSize > 0) codecPrivate.assign(cp, cp + cpSize);

        if (typeID == 1) { // video
            const mkvparser::VideoTrack *vt = static_cast<const mkvparser::VideoTrack *>(mt);
            info.mediaType = kCMMediaType_Video;
            info.width = (uint32_t)vt->GetWidth();
            info.height = (uint32_t)vt->GetHeight();
            double fr = vt->GetFrameRate();
            if (fr <= 0.0) {
                unsigned long long defaultDuration = vt->GetDefaultDuration(); // ns per frame
                if (defaultDuration > 0) {
                    fr = 1e9 / (double)defaultDuration;
                }
            }
            info.nominalFrameRate = (float)(fr > 0.0 ? fr : 0.0);

            CMVideoFormatDescriptionRef vfd = CreateVideoFormatDescription(kCFAllocatorDefault, info, codecPrivate);
            if (!vfd) {
                Log(@"scan", @"skipping video track %llu (codec %s — format desc create failed)",
                    info.trackNumber, info.codecId.c_str());
                continue;
            }
            info.formatDescription = (CMFormatDescriptionRef)vfd;
            info.codecFourCC = CMFormatDescriptionGetMediaSubType(vfd);
        } else if (typeID == 2) { // audio
            const mkvparser::AudioTrack *at = static_cast<const mkvparser::AudioTrack *>(mt);
            info.mediaType = kCMMediaType_Audio;
            info.sampleRate = (uint32_t)at->GetSamplingRate();
            info.channelCount = (uint32_t)at->GetChannels();
            info.bitDepth = (uint32_t)at->GetBitDepth();
            if (info.bitDepth == 0) info.bitDepth = 16;

            CMAudioFormatDescriptionRef afd = CreateAudioFormatDescription(kCFAllocatorDefault, info, codecPrivate);
            if (!afd) {
                Log(@"scan", @"skipping audio track %llu (codec %s — format desc create failed)",
                    info.trackNumber, info.codecId.c_str());
                continue;
            }
            info.formatDescription = (CMFormatDescriptionRef)afd;
            info.codecFourCC = CMFormatDescriptionGetMediaSubType(afd);
        } else {
            // Subtitles, metadata, etc. — skip for now.
            continue;
        }

        outData.tracks.push_back(info);
        if (info.trackNumber < trackIndexByNumber.size()) {
            trackIndexByNumber[info.trackNumber] = (int)outData.tracks.size() - 1;
        }
    }

    if (outData.tracks.empty()) {
        errorOut = "no supported tracks found";
        return kMTPluginFormatReaderError_ParsingFailure;
    }

    // Walk all clusters and gather blocks for each track.
    const mkvparser::Cluster *cluster = segment->GetFirst();
    while (cluster && !cluster->EOS()) {
        long long clusterTime = cluster->GetTime();
        const mkvparser::BlockEntry *blockEntry = nullptr;
        long lr = cluster->GetFirst(blockEntry);
        while (lr == 0 && blockEntry && !blockEntry->EOS()) {
            const mkvparser::Block *block = blockEntry->GetBlock();
            if (!block) break;
            long long trackNum = block->GetTrackNumber();
            int idx = (trackNum >= 0 && trackNum < (long long)trackIndexByNumber.size())
                        ? trackIndexByNumber[trackNum] : -1;
            if (idx >= 0) {
                TrackInfo &track = outData.tracks[idx];
                long long blockTimeNs = block->GetTime(cluster); // absolute ns
                bool keyframe = block->IsKey();
                int frameCount = block->GetFrameCount();
                for (int j = 0; j < frameCount; ++j) {
                    const mkvparser::Block::Frame &frame = block->GetFrame(j);
                    BlockEntry entry = {};
                    entry.trackNumber = track.trackNumber;
                    entry.presentationTimeNs = blockTimeNs;
                    entry.durationNs = 0; // filled in by post-pass below
                    entry.fileOffset = (int64_t)frame.pos;
                    entry.frameSize = (int32_t)frame.len;
                    entry.keyframe = keyframe;
                    track.blocks.push_back(entry);
                }
            }
            lr = cluster->GetNext(blockEntry, blockEntry);
        }
        cluster = segment->GetNext(cluster);
    }

    // Post-pass: compute per-block duration from next-block PTS. Last block
    // gets the track's DefaultDuration if set, or the track's nominal cadence.
    for (auto &track : outData.tracks) {
        // Find the MKV DefaultDuration for this track.
        unsigned long long defaultNs = 0;
        for (unsigned long i = 0; i < mkvTracks->GetTracksCount(); ++i) {
            const mkvparser::Track *mt = mkvTracks->GetTrackByIndex(i);
            if (mt && (uint64_t)mt->GetNumber() == track.trackNumber) {
                defaultNs = mt->GetDefaultDuration();
                break;
            }
        }
        if (track.blocks.empty()) continue;
        for (size_t i = 0; i + 1 < track.blocks.size(); ++i) {
            int64_t d = track.blocks[i + 1].presentationTimeNs - track.blocks[i].presentationTimeNs;
            track.blocks[i].durationNs = d > 0 ? d : (int64_t)defaultNs;
        }
        // Last block: use default, or fall back to previous block's duration.
        int64_t lastDur = (int64_t)defaultNs;
        if (lastDur <= 0 && track.blocks.size() >= 2) {
            lastDur = track.blocks[track.blocks.size() - 2].durationNs;
        }
        if (lastDur <= 0) {
            if (track.mediaType == kCMMediaType_Video) {
                double fr = track.nominalFrameRate > 0.0f ? track.nominalFrameRate : 24.0;
                lastDur = (int64_t)(1e9 / fr);
            } else if (track.sampleRate > 0) {
                lastDur = (int64_t)(1e9 * 1024.0 / (double)track.sampleRate);
            } else {
                lastDur = 0;
            }
        }
        track.blocks.back().durationNs = lastDur;
    }

    Log(@"scan", @"scanned %s — %zu tracks, duration=%lld ns",
        pathCStr, outData.tracks.size(), durationNs);
    for (const auto &t : outData.tracks) {
        Log(@"scan", @"  track#%llu pid=%u type=%c codec=%s frames=%zu (%dx%d @ %.2f fps / %u Hz %u ch)",
            t.trackNumber, t.persistentID,
            (t.mediaType == kCMMediaType_Video) ? 'V' : 'A',
            t.codecId.c_str(), t.blocks.size(),
            (int)t.width, (int)t.height, t.nominalFrameRate,
            t.sampleRate, t.channelCount);
    }

    (void)timecodeScale; // currently unused (libwebm already converts to ns)

    return noErr;
}

} // namespace SpliceKitMKV
