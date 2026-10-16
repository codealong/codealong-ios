// Writes the app's sounds (Codealong/Sounds), made here from sine waves so they're ours to ship:
// the Mac's are macOS's own Pop and Tink, which an iPhone doesn't have. Like them, a pop when a
// session needs you, two quick rising bubbles in the same low register as Pop, and a lighter
// tink when a turn ends, one short struck note. Run it again after changing one:
//
//   swift scripts/make-sounds.swift
import AVFoundation
import Foundation

let rate = 44_100.0

/// A bubble's pop at `at` seconds: a sine that rises from `from` to `to` hertz over its first 30
/// ms, as a bubble's pitch does as it bursts, and dies away in a tenth of a second.
func pop(_ out: inout [Double], at: Double, from: Double, to: Double, loud: Double) {
    let start = Int(at * rate)
    var phase = 0.0
    for i in 0..<Int(0.1 * rate) where start + i < out.count {
        let t = Double(i) / rate
        let f = from * pow(to / from, min(t / 0.03, 1))
        phase += 2 * .pi * f / rate
        let envelope = (1 - exp(-t / 0.0008)) * exp(-t / 0.016)
        out[start + i] += loud * envelope * (sin(phase) + 0.12 * sin(2 * phase))
    }
}

/// A small bell struck once: its note, and a partial at 2.76 times it, as a bar's, that fades
/// faster.
func tink(_ out: inout [Double], note: Double, loud: Double) {
    for i in out.indices {
        let t = Double(i) / rate
        let attack = 1 - exp(-t / 0.001)
        let body = exp(-t / 0.028) * sin(2 * .pi * note * t)
        let shimmer = 0.25 * exp(-t / 0.01) * sin(2 * .pi * note * 2.76 * t)
        out[i] += loud * attack * (body + shimmer)
    }
}

/// Writes samples as a 16-bit mono CAF, at `peak` of full scale, faded out over its last 10 ms so
/// it ends without a click.
func write(_ samples: [Double], peak: Double, to path: String) throws {
    let top = samples.map(abs).max() ?? 1
    let fade = Int(0.01 * rate)
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: url)
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = buffer.frameCapacity
    for (i, s) in samples.enumerated() {
        let tail = min(1, Double(samples.count - 1 - i) / Double(fade))
        buffer.floatChannelData![0][i] = Float(s / top * peak * tail)
    }
    try file.write(from: buffer)
}

let folder = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Codealong/Sounds").path
try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

var needsYou = [Double](repeating: 0, count: Int(0.2 * rate))
pop(&needsYou, at: 0, from: 520, to: 900, loud: 1)
pop(&needsYou, at: 0.075, from: 560, to: 980, loud: 0.6)
try write(needsYou, peak: 0.7, to: "\(folder)/needs-you.caf")

var yourTurn = [Double](repeating: 0, count: Int(0.18 * rate))
tink(&yourTurn, note: 1175, loud: 1)
try write(yourTurn, peak: 0.5, to: "\(folder)/your-turn.caf")
