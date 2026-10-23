@preconcurrency import CoreML
import Foundation

/// Voice-based speaker labeling: one CAM++ embedding per VAD utterance + online clustering.
/// Model: FunASR CAM++ (CoreML conversion `FluidInference/campplus-coreml`, ~17 MB, downloaded on first use).
/// Pipeline (same as FluidAudio's CampPlusEmbedder): 16 kHz waveform -> fbank [1,T,80] -> [1,192] -> L2 normalize.
final class SpeakerEmbedder: @unchecked Sendable {
    static let repo = "FluidInference/campplus-coreml"
    static let files = [
        "CamPlusPreprocessor.mlmodelc/analytics/coremldata.bin", "CamPlusPreprocessor.mlmodelc/coremldata.bin",
        "CamPlusPreprocessor.mlmodelc/model.mil", "CamPlusPreprocessor.mlmodelc/weights/weight.bin",
        "CamPlusPlus.mlmodelc/analytics/coremldata.bin", "CamPlusPlus.mlmodelc/coremldata.bin",
        "CamPlusPlus.mlmodelc/model.mil", "CamPlusPlus.mlmodelc/weights/weight.bin",
    ]
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tongyeok/Models/campplus-coreml", isDirectory: true)
    }

    private let preprocessor: MLModel
    private let model: MLModel

    private init(preprocessor: MLModel, model: MLModel) { self.preprocessor = preprocessor; self.model = model }

    static var isDownloaded: Bool {
        files.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    /// Downloads (once) and loads the two CoreML stages.
    static func load(status: (String) -> Void = { _ in }) async throws -> SpeakerEmbedder {
        let dir = directory
        if !isDownloaded {
            status("화자 모델 다운로드 중… (약 17MB, 최초 1회)")
            for f in files {
                let dest = dir.appendingPathComponent(f)
                if FileManager.default.fileExists(atPath: dest.path) { continue }
                let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(f)")!
                let (tmp, resp) = try await URLSession.shared.download(from: url)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    throw AppError.speech("화자 모델 다운로드 실패: \(f)")
                }
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
            }
        }
        // Dynamic time dimension -> ANE rejects it; the model is tiny, CPU/GPU is plenty.
        let cpu = MLModelConfiguration(); cpu.computeUnits = .cpuOnly
        let gpu = MLModelConfiguration(); gpu.computeUnits = .cpuAndGPU
        let pre = try MLModel(contentsOf: dir.appendingPathComponent("CamPlusPreprocessor.mlmodelc"), configuration: cpu)
        let model = try MLModel(contentsOf: dir.appendingPathComponent("CamPlusPlus.mlmodelc"), configuration: gpu)
        return SpeakerEmbedder(preprocessor: pre, model: model)
    }

    /// 16 kHz mono samples in [-1, 1] -> 192-d L2-normalized embedding.
    func embed(_ audio: [Float]) throws -> [Float] {
        let wav = try MLMultiArray(shape: [1, audio.count as NSNumber], dataType: .float32)
        let p = wav.dataPointer.assumingMemoryBound(to: Float32.self)
        for i in audio.indices { p[i] = audio[i] * 32_768 }   // kaldi fbank expects int16 range
        let feats = try preprocessor.prediction(
            from: MLDictionaryFeatureProvider(dictionary: ["waveform": MLFeatureValue(multiArray: wav)]))
        guard let fbank = feats.featureValue(for: "features")?.multiArrayValue else {
            throw AppError.speech("CAM++ preprocessor: no features")
        }
        let out = try model.prediction(
            from: MLDictionaryFeatureProvider(dictionary: ["feats": MLFeatureValue(multiArray: fbank)]))
        guard let e = out.featureValue(for: "embedding")?.multiArrayValue else { throw AppError.speech("CAM++: no embedding") }
        var v = (0..<e.count).map { e[$0].floatValue }
        let norm = max(sqrt(v.reduce(0) { $0 + $1 * $1 }), 1e-9)
        for i in v.indices { v[i] /= norm }
        return v
    }
}

/// Online speaker clustering over utterance embeddings (cosine vs. running centroids).
struct SpeakerClusterer {
    var threshold: Float = 0.7          // min cosine to join an existing speaker (same ≈0.8-0.9, different ≈0.45-0.65)
    var maxSpeakers = 8
    /// Shorter utterances carry too little voice to found a new speaker.
    var minNewSpeakerSec = 1.2
    private var centroids: [[Float]] = []   // un-normalized sums
    private var counts: [Int] = []

    init(threshold: Float = 0.7) { self.threshold = threshold }

    mutating func reset() { centroids = []; counts = [] }

    /// Speaker index (0-based), or nil when the utterance is too ambiguous to label.
    mutating func assign(_ e: [Float], duration: Double) -> (speaker: Int?, similarity: Float) {
        let sims = centroids.map { Self.cosine(Self.normalized($0), e) }
        let best = sims.indices.max { sims[$0] < sims[$1] }
        if let b = best, sims[b] >= threshold {
            add(e, to: b)
            return (b, sims[b])
        }
        if duration < minNewSpeakerSec {
            // Short ("네", "OK"): label with the closest speaker only if it's not far off; don't learn from it.
            if let b = best, sims[b] >= threshold - 0.15 { return (b, sims[b]) }
            return (nil, best.map { sims[$0] } ?? 0)
        }
        if centroids.count >= maxSpeakers, let b = best { add(e, to: b); return (b, sims[b]) }
        centroids.append(e); counts.append(1)
        return (centroids.count - 1, best.map { sims[$0] } ?? 0)
    }

    private mutating func add(_ e: [Float], to i: Int) {
        // Cap the weight so a speaker's centroid keeps adapting (mic distance, tone) during long sessions.
        let w = Float(min(counts[i], 20))
        let c = Self.normalized(centroids[i])
        centroids[i] = zip(c, e).map { $0 * w + $1 }
        counts[i] += 1
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let n = max(sqrt(v.reduce(0) { $0 + $1 * $1 }), 1e-9)
        return v.map { $0 / n }
    }
    static func cosine(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
}

/// Embedding + clustering off the audio thread, one utterance at a time.
actor Diarizer {
    private let embedder: SpeakerEmbedder
    private var clusterer: SpeakerClusterer

    init(embedder: SpeakerEmbedder, threshold: Float) {
        self.embedder = embedder
        clusterer = SpeakerClusterer(threshold: threshold)
    }

    func reset() { clusterer.reset() }
    func setThreshold(_ t: Float) { clusterer.threshold = t }

    func speaker(for audio: [Float]) -> Int? {
        let sec = Double(audio.count) / 16_000
        guard sec >= 0.5, let e = try? embedder.embed(audio) else { return nil }
        let r = clusterer.assign(e, duration: sec)
        dlog(String(format: "speaker %@ sim=%.2f dur=%.1fs", r.speaker.map { "\($0 + 1)" } ?? "?", r.similarity, sec))
        return r.speaker
    }
}
