#!/usr/bin/env swift
//
//  audio-levels.swift — Peak and RMS level of a media file's audio over time.
//
//  Decodes a time range of the file's audio with AVAssetReader (out of Final
//  Cut Pro's process: in-process AVFoundation audio decoding deadlocked, see
//  SpliceKitServer.m's beat detector note) and prints, per slice, the peak
//  sample level and the RMS level in dBFS. SpliceKit's bridge maps the slices
//  onto the timeline (timeline.getAudioLevels) so an MCP client can "see" the
//  audio of every clip.
//
//  The levels are those of the source media file as decoded: Final Cut Pro's
//  volume, fades, effects, retiming and the mix of all concurrent clips are not
//  applied. -100 dB is the floor reported for a slice with no sample above 1e-5.
//
//  Channels are pooled, never mixed: up to eight audio tracks are decoded, each
//  at its own channel count; the peak of a slice is the loudest sample in any
//  channel and its RMS is taken over all channels' samples (for a file with one
//  audio track, the figures ffmpeg's volumedetect reports for the same range;
//  with several tracks each is weighted by its channels). QA run 3 found the
//  earlier mono mixdown reading exactly 3 dB above the per-channel level on
//  dual-mono files, consistent with a power-preserving mixdown (two channels
//  carrying the same signal sum to +3 dB), so no sample of one channel is added
//  to another any more. The mixdown remains only as the fallback when no track
//  decodes at its own channel count, and is named as such (channelsMode
//  "mixdownMono").
//
//  Samples are sliced as they stream out of the reader, so memory stays at one
//  decoder buffer plus the per-slice figures (at most --max-slices of them per
//  track) however long the range is.
//
//  Usage: audio-levels <file> [--start sec] [--end sec] [--slice 0.05]
//                             [--max-slices 4000] [--per-channel]
//  Output: JSON to stdout (see AudioLevelsResult below). Failures exit non-zero
//  with a line starting "Error:" on stderr; a fallback taken along the way is a
//  "note:" line.
//

import AVFoundation
import Accelerate
import Foundation

// MARK: - Types

let floorDb: Double = -100.0          // the floor: no sample above 1e-5
let clipPeakLinear: Float = 0.98855   // -0.1 dBFS
let maxTracks = 8                     // audio tracks decoded and pooled, at most
let maxReportedChannels = 8           // channels of the first track reported separately, at most

struct AudioLevelsResult: Codable {
    let filePath: String
    let fileDuration: Double
    let audioTrackCount: Int
    let tracksDecoded: Int             // tracks pooled (all of them, capped at maxTracks; the mixdown counts them all)
    let sampleRate: Double
    let channels: Int                  // channels pooled over the decoded tracks (1 for the mixdown fallback)
    let channelsMode: String           // "pooled" (no channel mixed with another) or "mixdownMono" (the fallback)
    let videoFrameRate: Double?        // the first video track's average rate over the file (AVAssetTrack.nominalFrameRate)
    let videoFrameRateAverage: Double? // the same reading under its own name
    let videoFrameRateShortest: Double? // the rate the track's shortest frame duration corresponds to (1 / minFrameDuration)
    let analysisRange: Range
    let sliceSeconds: Double
    let floorDb: Double
    let slices: Slices
    let perChannel: [ChannelSlices]?   // the first track's channels, with --per-channel
    let stats: Stats

    struct Range: Codable { let start: Double; let end: Double }
    struct Slices: Codable {
        let start: Double                // file time of the first slice
        let count: Int
        let peakDb: [Double]             // per slice, the loudest sample in any channel
        let rmsDb: [Double]              // per slice, RMS over all channels' samples
        let clippedSliceIndices: [Int]   // slices whose peak reached -0.1 dBFS (at full scale; possible clipping); first 2000
    }
    struct ChannelSlices: Codable {
        let peakDb: [Double]
        let rmsDb: [Double]
        let maxPeakDb: Double
        let meanRmsDb: Double            // power mean of the channel's slice RMS values
        let clippedSlices: Int
    }
    struct Stats: Codable {
        let maxPeakDb: Double
        let maxPeakAt: Double            // file time of the loudest slice
        let meanRmsDb: Double            // power mean of the slice RMS values
        let clippedSlices: Int           // slices whose peak reached -0.1 dBFS (at full scale; possible clipping)
    }
}

func db(_ linear: Float) -> Double {
    guard linear > 1e-5 else { return floorDb }
    return max(floorDb, 20.0 * log10(Double(linear)))
}

func round1(_ x: Double) -> Double { (x * 10.0).rounded() / 10.0 }

// MARK: - Arguments

var filePath: String?
var startTime: Double?
var endTime: Double?
var sliceSeconds = 0.05
var maxSlices = 4000
var perChannel = false

let cliArgs = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < cliArgs.count {
    let arg = cliArgs[i]
    switch arg {
    case "--start":
        i += 1; if i < cliArgs.count { startTime = Double(cliArgs[i]) }
    case "--end":
        i += 1; if i < cliArgs.count { endTime = Double(cliArgs[i]) }
    case "--slice":
        i += 1; if i < cliArgs.count { sliceSeconds = Double(cliArgs[i]) ?? 0.05 }
    case "--max-slices":
        i += 1; if i < cliArgs.count { maxSlices = Int(cliArgs[i]) ?? 4000 }
    case "--per-channel":
        perChannel = true
    case "--help", "-h":
        print("""
        Usage: audio-levels <file> [options]

        Options:
          --start <sec>        Start of the analysed range in the file (default: 0)
          --end <sec>          End of the analysed range (default: end of file)
          --slice <sec>        Slice length; peak and RMS are reported per slice (default: 0.05)
          --max-slices <n>     Lengthen the slice so at most n slices are reported (default: 4000)
          --per-channel        Also report each channel of the first audio track separately
                               (when it has more than one; up to eight)

        Output: JSON to stdout with peak and RMS levels in dBFS per slice, pooled over the
        file's channels (peak: the loudest sample in any channel; RMS over all channels).
        """)
        exit(0)
    default:
        if !arg.hasPrefix("-") { filePath = arg } else { fputs("Error: unknown option \(arg)\n", stderr); exit(1) }
    }
    i += 1
}

guard let path = filePath else {
    fputs("Error: usage: audio-levels <file> [--start sec] [--end sec] [--slice 0.05] [--max-slices 4000] [--per-channel]\n", stderr)
    exit(1)
}
guard FileManager.default.fileExists(atPath: path) else {
    fputs("Error: file not found: \(path)\n", stderr)
    exit(1)
}
if !(sliceSeconds > 0.001) { sliceSeconds = 0.05 }
if maxSlices < 10 { maxSlices = 10 }

// MARK: - Asset

let asset = AVURLAsset(url: URL(fileURLWithPath: path))
let trackSemaphore = DispatchSemaphore(value: 0)
var audioTracks: [AVAssetTrack] = []
asset.loadTracks(withMediaType: .audio) { tracks, _ in
    audioTracks = tracks ?? []
    trackSemaphore.signal()
}
trackSemaphore.wait()

guard !audioTracks.isEmpty else {
    fputs("Error: no audio track found in \(path)\n", stderr)
    exit(2)
}

// The first video track's frame rate, for the bridge's frame-rate-conform reading (a media
// file whose frame rate differs from the project's is rate-conformed by FCP). Two readings,
// both reported as what they are: the average over the file (AVAssetTrack.nominalFrameRate,
// frame count over duration) and the rate the shortest frame duration in the track
// corresponds to (1 / minFrameDuration). They agree for a constant-frame-rate file with a
// fine timescale; QA run 4 found a variable-frame-rate screen recording (30 fps frames with
// drops, averaging 29.74 fps) that the average alone had presented as "nominally 29.740
// fps". Neither is a "nominal" rate: a 29.97 fps file in a 600-tick timescale alternates
// 20- and 21-tick frames, so its shortest frame reads 30.000. A shortest-frame rate above
// 240 fps (one glitch frame would give that) is not reported.
let videoSemaphore = DispatchSemaphore(value: 0)
var videoTracks: [AVAssetTrack] = []
asset.loadTracks(withMediaType: .video) { tracks, _ in
    videoTracks = tracks ?? []
    videoSemaphore.signal()
}
videoSemaphore.wait()
var videoFrameRateAverage: Double = 0
var videoFrameRateShortest: Double = 0
if let video = videoTracks.first {
    videoFrameRateAverage = Double(video.nominalFrameRate)
    let shortest = video.minFrameDuration
    if shortest.isValid && shortest.value > 0 && shortest.timescale > 0 {
        let rate = Double(shortest.timescale) / Double(shortest.value)
        if rate > 0 && rate <= 240 { videoFrameRateShortest = rate }
    }
}

let fileDuration = CMTimeGetSeconds(asset.duration)
let rangeStart = max(0.0, startTime ?? 0.0)
var rangeEnd = endTime ?? fileDuration
if fileDuration.isFinite && fileDuration > 0 { rangeEnd = min(rangeEnd, fileDuration) }
guard rangeEnd > rangeStart else {
    fputs("Error: empty range \(rangeStart)..\(rangeEnd) (file duration \(fileDuration))\n", stderr)
    exit(3)
}
let rangeDuration = rangeEnd - rangeStart
if rangeDuration / sliceSeconds > Double(maxSlices) {
    sliceSeconds = rangeDuration / Double(maxSlices)
}

// A track's natural format: sample rate and channel count. formatDescriptions is [Any]
// holding CMFormatDescription CF objects; Swift 6.4 rejects `as?` to a CF type
// ("conditional downcast ... will always succeed" is an error there), so the CF type ID
// is compared and the reference bit-cast.
func nativeFormat(of track: AVAssetTrack) -> (rate: Double, channels: Int) {
    var rate: Double = 0
    var channels = 0
    if let fd = track.formatDescriptions.first,
       CFGetTypeID(fd as CFTypeRef) == CMFormatDescriptionGetTypeID() {
        let desc = unsafeBitCast(fd as AnyObject, to: CMFormatDescription.self)
        if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
            if asbd.mSampleRate > 0 { rate = asbd.mSampleRate }
            if asbd.mChannelsPerFrame > 0 { channels = Int(asbd.mChannelsPerFrame) }
        }
    }
    return (rate, channels)
}

let firstFormat = nativeFormat(of: audioTracks[0])
let nativeRate: Double = firstFormat.rate > 0 ? firstFormat.rate : 48000
let rangeTimescale = Int32(max(1000, min(nativeRate, 192_000)))
let analysisTimeRange = CMTimeRange(
    start: CMTimeMakeWithSeconds(rangeStart, preferredTimescale: rangeTimescale),
    end: CMTimeMakeWithSeconds(rangeEnd, preferredTimescale: rangeTimescale))

// MARK: - Streaming analysis

/// Per-slice levels of one decoded stream, kept linear so streams can be pooled.
struct TrackLevels {
    let sampleRate: Double
    let channels: Int
    let framesPerSlice: Int
    var framesTotal = 0
    var slicePeak = [Float]()            // per slice, the loudest sample in any channel
    var sliceMeanSquare = [Double]()     // per slice, mean square over all channels' samples
    var channelPeak: [[Float]]           // per channel, only when asked
    var channelMeanSquare: [[Float]]

    init(sampleRate: Double, channels: Int, framesPerSlice: Int, keepChannels: Bool) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.framesPerSlice = framesPerSlice
        let tracked = keepChannels && channels > 1 ? min(channels, maxReportedChannels) : 0
        channelPeak = [[Float]](repeating: [], count: tracked)
        channelMeanSquare = [[Float]](repeating: [], count: tracked)
    }

    var sliceCount: Int { slicePeak.count }

    /// One slice of `frames` interleaved frames starting at `base`.
    mutating func emit(_ base: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        var peakAll: Float = 0
        var meanSquareAll: Double = 0
        for c in 0..<channels {
            let p = base + c
            var peak: Float = 0
            var ms: Float = 0
            // Strided over the interleaved buffer: channel c of every frame in the slice.
            vDSP_maxmgv(p, vDSP_Stride(channels), &peak, vDSP_Length(frames))
            vDSP_measqv(p, vDSP_Stride(channels), &ms, vDSP_Length(frames))
            if peak > peakAll { peakAll = peak }
            meanSquareAll += Double(ms)
            if c < channelPeak.count {
                channelPeak[c].append(peak)
                channelMeanSquare[c].append(ms)
            }
        }
        slicePeak.append(peakAll)
        sliceMeanSquare.append(meanSquareAll / Double(channels))
        framesTotal += frames
    }
}

/// Read `output` (already added to `reader`) and slice it as it streams. The channel
/// count is what the reader really delivers, read from the first sample buffer's format
/// description; `fallbackChannels` covers a buffer without one.
func decode(reader: AVAssetReader, output: AVAssetReaderOutput, sampleRate: Double,
            fallbackChannels: Int, keepChannels: Bool, label: String) -> TrackLevels? {
    guard reader.startReading() else {
        fputs("note: reader did not start (\(label)): \(reader.error?.localizedDescription ?? "unknown")\n", stderr)
        return nil
    }
    let framesPerSlice = max(1, Int((sliceSeconds * sampleRate).rounded()))
    var levels = TrackLevels(sampleRate: sampleRate, channels: max(1, fallbackChannels),
                             framesPerSlice: framesPerSlice, keepChannels: keepChannels)
    var formatChecked = false
    var carry = [Float]()
    carry.reserveCapacity(2 * framesPerSlice * levels.channels + 65_536)

    while let sampleBuffer = output.copyNextSampleBuffer() {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
        if !formatChecked {
            formatChecked = true
            if let fd = CMSampleBufferGetFormatDescription(sampleBuffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
               asbd.mChannelsPerFrame > 0, Int(asbd.mChannelsPerFrame) != levels.channels {
                // Nothing has been emitted yet: start over with the delivered channel count.
                levels = TrackLevels(sampleRate: sampleRate, channels: Int(asbd.mChannelsPerFrame),
                                     framesPerSlice: framesPerSlice, keepChannels: keepChannels)
            }
        }
        let sliceSamples = framesPerSlice * levels.channels
        let length = CMBlockBufferGetDataLength(blockBuffer)
        let floatCount = length / MemoryLayout<Float>.size
        guard floatCount > 0 else { continue }
        var dataPointer: UnsafeMutablePointer<Int8>?
        var lengthAtOffset = 0
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                                 totalLengthOut: nil, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let rawPtr = dataPointer else { continue }
        if lengthAtOffset >= length {
            rawPtr.withMemoryRebound(to: Float.self, capacity: floatCount) { floatPtr in
                carry.append(contentsOf: UnsafeBufferPointer(start: floatPtr, count: floatCount))
            }
        } else {
            // A block buffer held in several pieces (not seen from AVAssetReader, but the
            // pointer above is only valid for lengthAtOffset bytes): copy it out whole.
            var whole = [Float](repeating: 0, count: floatCount)
            let copied = whole.withUnsafeMutableBytes { raw -> OSStatus in
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: floatCount * MemoryLayout<Float>.size,
                                           destination: raw.baseAddress!)
            }
            guard copied == kCMBlockBufferNoErr else { continue }
            carry.append(contentsOf: whole)
        }
        // Emit every complete slice now held; keep the remainder for the next buffer.
        var consumed = 0
        carry.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            while carry.count - consumed >= sliceSamples {
                levels.emit(base + consumed, frames: framesPerSlice)
                consumed += sliceSamples
            }
        }
        if consumed > 0 { carry.removeFirst(consumed) }
    }
    if reader.status == .failed {
        fputs("note: reader failed (\(label)): \(reader.error?.localizedDescription ?? "unknown")\n", stderr)
        return nil
    }
    // The last, partial slice.
    let remainingFrames = carry.count / levels.channels
    if remainingFrames > 0 {
        carry.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress { levels.emit(base, frames: remainingFrames) }
        }
    }
    return levels
}

/// One decoded stream per audio track, each at the track's own channel count (no channel
/// key in the output settings, so nothing is mixed), all at the first track's sample rate
/// so the slices line up. At most `maxTracks` tracks.
func decodeTracks(keepChannels: Bool) -> [TrackLevels] {
    var out = [TrackLevels]()
    for (index, track) in audioTracks.prefix(maxTracks).enumerated() {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            fputs("note: creating AVAssetReader for track \(index + 1): \(error)\n", stderr)
            continue
        }
        reader.timeRange = analysisTimeRange
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: nativeRate,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            fputs("note: reader cannot add track \(index + 1)\n", stderr)
            continue
        }
        reader.add(output)
        let format = nativeFormat(of: track)
        if let levels = decode(reader: reader, output: output, sampleRate: nativeRate,
                               fallbackChannels: max(1, format.channels),
                               keepChannels: keepChannels && index == 0, label: "track \(index + 1)") {
            out.append(levels)
        } else {
            fputs("note: track \(index + 1) was not decoded\n", stderr)
        }
    }
    if audioTracks.count > maxTracks {
        fputs("note: \(audioTracks.count) audio tracks; only the first \(maxTracks) are pooled\n", stderr)
    }
    return out
}

/// The fallback: every audio track mixed down to one mono channel by AVFoundation
/// (AVAssetReaderAudioMixOutput when there are several tracks). A power-preserving
/// mixdown: two channels carrying the same signal read 3 dB above either channel alone.
func decodeMixdown(sampleRate: Double) -> TrackLevels? {
    let reader: AVAssetReader
    do { reader = try AVAssetReader(asset: asset) } catch {
        fputs("note: creating AVAssetReader for the mixdown: \(error)\n", stderr)
        return nil
    }
    reader.timeRange = analysisTimeRange
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
    ]
    let output: AVAssetReaderOutput
    if audioTracks.count > 1 {
        let mix = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: settings)
        mix.alwaysCopiesSampleData = false
        output = mix
    } else {
        let track = AVAssetReaderTrackOutput(track: audioTracks[0], outputSettings: settings)
        track.alwaysCopiesSampleData = false
        output = track
    }
    guard reader.canAdd(output) else {
        fputs("note: reader cannot add the mixdown output (rate=\(sampleRate))\n", stderr)
        return nil
    }
    reader.add(output)
    return decode(reader: reader, output: output, sampleRate: sampleRate, fallbackChannels: 1,
                  keepChannels: false, label: "mixdown \(sampleRate) Hz")
}

/// Slices pooled over the decoded streams: peak = the loudest sample in any channel of any
/// stream; mean square = over all channels' samples (each stream weighted by its channels).
/// A stream shorter than the others simply drops out of the later slices.
struct Pooled {
    let sampleRate: Double
    let framesPerSlice: Int
    let framesTotal: Int
    let channels: Int
    let peak: [Float]
    let meanSquare: [Double]
}

func pool(_ streams: [TrackLevels]) -> Pooled {
    let count = streams.map { $0.sliceCount }.max() ?? 0
    var peak = [Float](repeating: 0, count: count)
    var meanSquare = [Double](repeating: 0, count: count)
    for s in 0..<count {
        var weight = 0
        for stream in streams where s < stream.sliceCount {
            if stream.slicePeak[s] > peak[s] { peak[s] = stream.slicePeak[s] }
            meanSquare[s] += stream.sliceMeanSquare[s] * Double(stream.channels)
            weight += stream.channels
        }
        if weight > 0 { meanSquare[s] /= Double(weight) }
    }
    return Pooled(sampleRate: streams[0].sampleRate,
                  framesPerSlice: streams[0].framesPerSlice,
                  framesTotal: streams.map { $0.framesTotal }.max() ?? 0,
                  channels: streams.reduce(0) { $0 + $1.channels },
                  peak: peak, meanSquare: meanSquare)
}

var channelsMode = "pooled"
var streams = decodeTracks(keepChannels: perChannel)
var tracksDecoded = streams.count
if streams.isEmpty {
    fputs("note: no audio track decoded at its own channel count; using the mono mixdown\n", stderr)
    var mix = decodeMixdown(sampleRate: nativeRate)
    if mix == nil && nativeRate != 44100 { mix = decodeMixdown(sampleRate: 44100) }
    if let mixed = mix {
        streams = [mixed]
        channelsMode = "mixdownMono"
        tracksDecoded = audioTracks.count
    }
}
guard !streams.isEmpty else {
    fputs("Error: could not decode the audio of \(path)\n", stderr)
    exit(4)
}
let pooled = pool(streams)

// MARK: - Output

let sliceCount = pooled.peak.count
var maxPeak: Float = 0
var maxPeakSlice = 0
var clipped = 0
var clippedIndices = [Int]()
var meanSquareSum: Double = 0
for (s, p) in pooled.peak.enumerated() {
    if p > maxPeak { maxPeak = p; maxPeakSlice = s }
    if p >= clipPeakLinear {
        clipped += 1
        if clippedIndices.count < 2000 { clippedIndices.append(s) }
    }
    meanSquareSum += pooled.meanSquare[s]
}
let meanRms = sliceCount > 0 ? Float((meanSquareSum / Double(sliceCount)).squareRoot()) : 0
let effectiveSlice = Double(pooled.framesPerSlice) / pooled.sampleRate

var perChannelOut: [AudioLevelsResult.ChannelSlices]? = nil
if perChannel, let first = streams.first, !first.channelPeak.isEmpty {
    perChannelOut = (0..<first.channelPeak.count).map { (c: Int) -> AudioLevelsResult.ChannelSlices in
        let peaks = first.channelPeak[c]
        let meanSquares = first.channelMeanSquare[c]
        var channelMax: Float = 0
        var channelClipped = 0
        var channelSum: Double = 0
        for (s, p) in peaks.enumerated() {
            if p > channelMax { channelMax = p }
            if p >= clipPeakLinear { channelClipped += 1 }
            channelSum += Double(meanSquares[s])
        }
        let channelMean = peaks.isEmpty ? Float(0) : Float((channelSum / Double(peaks.count)).squareRoot())
        return AudioLevelsResult.ChannelSlices(
            peakDb: peaks.map { round1(db($0)) },
            rmsDb: meanSquares.map { round1(db(sqrtf($0))) },
            maxPeakDb: round1(db(channelMax)),
            meanRmsDb: round1(db(channelMean)),
            clippedSlices: channelClipped)
    }
}

let out = AudioLevelsResult(
    filePath: path,
    fileDuration: fileDuration.isFinite ? round1(fileDuration * 1000) / 1000 : 0,
    audioTrackCount: audioTracks.count,
    tracksDecoded: tracksDecoded,
    sampleRate: pooled.sampleRate,
    channels: pooled.channels,
    channelsMode: channelsMode,
    videoFrameRate: videoFrameRateAverage > 0 ? videoFrameRateAverage : nil,
    videoFrameRateAverage: videoFrameRateAverage > 0 ? videoFrameRateAverage : nil,
    videoFrameRateShortest: videoFrameRateShortest > 0 ? videoFrameRateShortest : nil,
    analysisRange: .init(start: rangeStart, end: rangeStart + Double(pooled.framesTotal) / pooled.sampleRate),
    sliceSeconds: effectiveSlice,
    floorDb: floorDb,
    slices: .init(start: rangeStart, count: sliceCount,
                  peakDb: pooled.peak.map { round1(db($0)) },
                  rmsDb: pooled.meanSquare.map { round1(db(Float($0.squareRoot()))) },
                  clippedSliceIndices: clippedIndices),
    perChannel: perChannelOut,
    stats: .init(maxPeakDb: round1(db(maxPeak)),
                 maxPeakAt: rangeStart + Double(maxPeakSlice) * effectiveSlice,
                 meanRmsDb: round1(db(meanRms)),
                 clippedSlices: clipped))

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
do {
    let data = try encoder.encode(out)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
} catch {
    fputs("Error: encoding JSON: \(error)\n", stderr)
    exit(1)
}
