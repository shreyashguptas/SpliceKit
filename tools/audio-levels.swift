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
//  Samples are sliced as they stream out of the reader, so memory stays at one
//  slice plus one decoder buffer however long the range is.
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

struct AudioLevelsResult: Codable {
    let filePath: String
    let fileDuration: Double
    let audioTrackCount: Int
    let sampleRate: Double
    let channels: Int
    let channelsMode: String           // "mixdownMono" or "perChannel"
    let analysisRange: Range
    let sliceSeconds: Double
    let floorDb: Double
    let slices: Slices
    let perChannel: [ChannelSlices]?
    let stats: Stats

    struct Range: Codable { let start: Double; let end: Double }
    struct Slices: Codable {
        let start: Double                // file time of the first slice
        let count: Int
        let peakDb: [Double]             // per slice, max |sample| over all channels
        let rmsDb: [Double]              // per slice, RMS over all channels
        let clippedSliceIndices: [Int]   // slices whose peak reached -0.1 dBFS (at full scale; possible clipping); first 2000
    }
    struct ChannelSlices: Codable { let peakDb: [Double]; let rmsDb: [Double] }
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
          --per-channel        Also report the first audio track's channels (up to two) separately

        Output: JSON to stdout with peak and RMS levels in dBFS per slice.
        """)
        exit(0)
    default:
        if !arg.hasPrefix("-") { filePath = arg } else { fputs("Error: unknown option \(arg)\n", stderr); exit(1) }
    }
    i += 1
}

guard let path = filePath else {
    fputs("Error: usage: audio-levels <file> [--start sec] [--end sec] [--slice 0.05] [--per-channel]\n", stderr)
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

// The first track's natural format: sample rate and channel count.
var nativeRate: Double = 48000
var nativeChannels: Int = 1
if let fd = audioTracks[0].formatDescriptions.first, let desc = fd as? CMFormatDescription {
    if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
        if asbd.mSampleRate > 0 { nativeRate = asbd.mSampleRate }
        if asbd.mChannelsPerFrame > 0 { nativeChannels = Int(asbd.mChannelsPerFrame) }
    }
}

// MARK: - Streaming analysis

struct Analysis {
    let sampleRate: Double
    let channels: Int
    let mode: String
    let framesPerSlice: Int
    var framesTotal = 0
    var peakDb = [Double]()
    var rmsDb = [Double]()
    var channelPeak: [[Double]]
    var channelRms: [[Double]]
    var maxPeak: Float = 0
    var maxPeakSlice = 0
    var meanSquareSum: Double = 0
    var clipped = 0
    var clippedIndices = [Int]()

    init(sampleRate: Double, channels: Int, mode: String, framesPerSlice: Int, perChannel: Bool) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.mode = mode
        self.framesPerSlice = framesPerSlice
        let tracked = perChannel && channels > 1 ? channels : 0
        channelPeak = [[Double]](repeating: [], count: tracked)
        channelRms = [[Double]](repeating: [], count: tracked)
    }

    var sliceCount: Int { peakDb.count }

    /// One slice of `frames` interleaved frames starting at `base`.
    mutating func emit(_ base: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        var slicePeak: Float = 0
        var sliceMeanSquare: Double = 0
        for c in 0..<channels {
            let p = base + c
            var peak: Float = 0
            var ms: Float = 0
            // Strided over the interleaved buffer: channel c of every frame in the slice.
            vDSP_maxmgv(p, vDSP_Stride(channels), &peak, vDSP_Length(frames))
            vDSP_measqv(p, vDSP_Stride(channels), &ms, vDSP_Length(frames))
            if peak > slicePeak { slicePeak = peak }
            sliceMeanSquare += Double(ms)
            if !channelPeak.isEmpty {
                channelPeak[c].append(round1(db(peak)))
                channelRms[c].append(round1(db(sqrtf(ms))))
            }
        }
        sliceMeanSquare /= Double(channels)
        let s = peakDb.count
        peakDb.append(round1(db(slicePeak)))
        rmsDb.append(round1(db(Float(sliceMeanSquare.squareRoot()))))
        if slicePeak > maxPeak { maxPeak = slicePeak; maxPeakSlice = s }
        if slicePeak >= clipPeakLinear {
            clipped += 1
            if clippedIndices.count < 2000 { clippedIndices.append(s) }
        }
        meanSquareSum += sliceMeanSquare
        framesTotal += frames
    }
}

/// Read the range with one reader and slice it as it streams. `channels == 1` uses the mono
/// mixdown of every audio track (AVAssetReaderAudioMixOutput when there are several, else the
/// silence-detector's proven track-output path); `channels > 1` keeps the first track's own
/// channels.
func analyze(channels: Int, sampleRate: Double) -> Analysis? {
    let reader: AVAssetReader
    do { reader = try AVAssetReader(asset: asset) } catch {
        fputs("Error: creating AVAssetReader: \(error)\n", stderr)
        return nil
    }
    let timescale = Int32(max(1000, min(sampleRate, 192_000)))
    reader.timeRange = CMTimeRange(
        start: CMTimeMakeWithSeconds(rangeStart, preferredTimescale: timescale),
        end: CMTimeMakeWithSeconds(rangeEnd, preferredTimescale: timescale))

    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
    ]
    let output: AVAssetReaderOutput
    if channels == 1 && audioTracks.count > 1 {
        let mix = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: settings)
        mix.alwaysCopiesSampleData = false
        output = mix
    } else {
        let track = AVAssetReaderTrackOutput(track: audioTracks[0], outputSettings: settings)
        track.alwaysCopiesSampleData = false
        output = track
    }
    guard reader.canAdd(output) else {
        fputs("note: reader cannot add output (channels=\(channels) rate=\(sampleRate))\n", stderr)
        return nil
    }
    reader.add(output)
    guard reader.startReading() else {
        fputs("note: reader did not start (channels=\(channels) rate=\(sampleRate)): \(reader.error?.localizedDescription ?? "unknown")\n", stderr)
        return nil
    }

    let framesPerSlice = max(1, Int((sliceSeconds * sampleRate).rounded()))
    let sliceSamples = framesPerSlice * channels
    var analysis = Analysis(sampleRate: sampleRate, channels: channels,
                            mode: channels == 1 ? "mixdownMono" : "perChannel",
                            framesPerSlice: framesPerSlice, perChannel: perChannel)
    var carry = [Float]()
    carry.reserveCapacity(2 * sliceSamples + 65_536)

    while let sampleBuffer = output.copyNextSampleBuffer() {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        let floatCount = length / MemoryLayout<Float>.size
        guard floatCount > 0 else { continue }
        var dataPointer: UnsafeMutablePointer<Int8>?
        var lengthAtOffset = 0
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                                 totalLengthOut: nil, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let rawPtr = dataPointer else { continue }
        rawPtr.withMemoryRebound(to: Float.self, capacity: floatCount) { floatPtr in
            carry.append(contentsOf: UnsafeBufferPointer(start: floatPtr, count: floatCount))
        }
        // Emit every complete slice now held; keep the remainder for the next buffer.
        var consumed = 0
        carry.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            while carry.count - consumed >= sliceSamples {
                analysis.emit(base + consumed, frames: framesPerSlice)
                consumed += sliceSamples
            }
        }
        if consumed > 0 { carry.removeFirst(consumed) }
    }
    if reader.status == .failed {
        fputs("Error: reader failed: \(reader.error?.localizedDescription ?? "unknown")\n", stderr)
        return nil
    }
    // The last, partial slice.
    let remainingFrames = carry.count / channels
    if remainingFrames > 0 {
        carry.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress { analysis.emit(base, frames: remainingFrames) }
        }
    }
    return analysis
}

// Per-channel decoding first when asked (capped at two channels: a track output for more
// channels needs a channel layout the helper does not pass), else the mono mixdown.
var result: Analysis?
if perChannel && nativeChannels > 1 {
    result = analyze(channels: min(nativeChannels, 2), sampleRate: nativeRate)
    if result == nil { fputs("note: per-channel decode failed, using the mono mixdown\n", stderr) }
}
if result == nil { result = analyze(channels: 1, sampleRate: nativeRate) }
if result == nil && nativeRate != 44100 { result = analyze(channels: 1, sampleRate: 44100) }
guard let audio = result else {
    fputs("Error: could not decode the audio of \(path)\n", stderr)
    exit(4)
}

// MARK: - Output

let effectiveSlice = Double(audio.framesPerSlice) / audio.sampleRate
let sliceCount = audio.sliceCount
let meanRms = sliceCount > 0 ? Float((audio.meanSquareSum / Double(sliceCount)).squareRoot()) : 0
let out = AudioLevelsResult(
    filePath: path,
    fileDuration: fileDuration.isFinite ? round1(fileDuration * 1000) / 1000 : 0,
    audioTrackCount: audioTracks.count,
    sampleRate: audio.sampleRate,
    channels: audio.channels,
    channelsMode: audio.mode,
    analysisRange: .init(start: rangeStart, end: rangeStart + Double(audio.framesTotal) / audio.sampleRate),
    sliceSeconds: effectiveSlice,
    floorDb: floorDb,
    slices: .init(start: rangeStart, count: sliceCount, peakDb: audio.peakDb, rmsDb: audio.rmsDb,
                  clippedSliceIndices: audio.clippedIndices),
    perChannel: audio.channelPeak.isEmpty ? nil
        : (0..<audio.channels).map { .init(peakDb: audio.channelPeak[$0], rmsDb: audio.channelRms[$0]) },
    stats: .init(maxPeakDb: round1(db(audio.maxPeak)),
                 maxPeakAt: rangeStart + Double(audio.maxPeakSlice) * effectiveSlice,
                 meanRmsDb: round1(db(meanRms)),
                 clippedSlices: audio.clipped))

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
