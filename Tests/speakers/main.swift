// Speaker clustering check: embeds labeled 16 kHz mono WAV clips (in the given order) and clusters them online.
// build: xcrun swiftc -O -target arm64-apple-macosx26.0 -o build/speakers Tests/speakers/main.swift \
//          Sources/Shared/{Speakers,Common,Translator}.swift
// usage: build/speakers <label>=<file.wav> ...     (labels are the ground-truth speakers)
import AVFoundation

func read16k(_ path: String) -> [Float] {
    let f = try! AVAudioFile(forReading: URL(fileURLWithPath: path))
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    precondition(f.processingFormat.sampleRate == 16_000 && f.processingFormat.channelCount == 1, "need 16 kHz mono")
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f.length))!
    try! f.read(into: buf)
    return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
}

let clips = CommandLine.arguments.dropFirst().map { a -> (label: String, audio: [Float]) in
    let p = a.split(separator: "=", maxSplits: 1); return (String(p[0]), read16k(String(p[1])))
}
let embedder = try await SpeakerEmbedder.load { print($0) }
let t0 = Date()
let embs = clips.map { try! embedder.embed($0.audio) }
let audioSec = clips.reduce(0) { $0 + Double($1.audio.count) / 16_000 }
let t1 = Date(); for c in clips { _ = try! embedder.embed(c.audio) }
print(String(format: "warm: %.1f ms per clip", Date().timeIntervalSince(t1) * 1000 / Double(clips.count)))
print(String(format: "embedded %d clips (%.1fs audio) in %.0f ms", clips.count, audioSec, Date().timeIntervalSince(t0) * 1000))

var same: [Float] = [], diff: [Float] = []
for i in embs.indices { for j in embs.indices where j > i {
    let c = SpeakerClusterer.cosine(embs[i], embs[j])
    if clips[i].label == clips[j].label { same.append(c) } else { diff.append(c) }
} }
func stats(_ v: [Float]) -> String { String(format: "min %.2f  mean %.2f  max %.2f", v.min() ?? 0, v.reduce(0, +) / Float(max(v.count, 1)), v.max() ?? 0) }
print("same speaker cosine:", stats(same))
print("diff speaker cosine:", stats(diff))

for th: Float in [0.6, 0.65, 0.7, 0.75, 0.8] {
    var cl = SpeakerClusterer(threshold: th)
    var map: [Int: [String]] = [:]
    var line = ""
    for (i, c) in clips.enumerated() {
        let r = cl.assign(embs[i], duration: Double(c.audio.count) / 16_000)
        line += "\(c.label)→\(r.speaker.map { String($0 + 1) } ?? "?") "
        if let s = r.speaker { map[s, default: []].append(c.label) }
    }
    // Purity: share of clips whose cluster's majority label is their own label.
    let pure = map.values.reduce(0) { acc, ls in acc + (Dictionary(grouping: ls, by: { $0 }).values.map(\.count).max() ?? 0) }
    print(String(format: "th=%.1f clusters=%d purity=%d/%d | %@", th, map.count, pure, clips.count, line))
}
