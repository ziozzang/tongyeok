import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// Delivers raw PCM buffers (any format) from some audio source.
protocol AudioSource: AnyObject {
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) async throws
    func stop() async
}

enum InputKind: String, CaseIterable, Identifiable {
    case microphone = "마이크"
    case systemAudio = "시스템 소리"
    var id: String { rawValue }
}

// MARK: - Microphone (AVAudioEngine)

final class MicrophoneSource: AudioSource {
    private let engine = AVAudioEngine()

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw AppError.permission("마이크 권한이 거부되었습니다. 시스템 설정 > 개인정보 보호 > 마이크에서 허용하세요.") }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw AppError.audio("입력 장치를 찾을 수 없습니다.") }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            onBuffer(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

// MARK: - Audio file (testing / offline)

final class FileSource: AudioSource {
    let url: URL
    let speed: Double          // 1.0 = real time
    private var task: Task<Void, Never>?
    var onFinished: (() -> Void)?

    init(url: URL, speed: Double = 1.0) { self.url = url; self.speed = speed }

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        task = Task.detached { [speed, weak self] in
            let chunk: AVAudioFrameCount = 1024
            while file.framePosition < file.length, !Task.isCancelled {
                guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
                do { try file.read(into: buf, frameCount: chunk) } catch { break }
                onBuffer(buf)
                try? await Task.sleep(for: .seconds(Double(buf.frameLength) / format.sampleRate / speed))
            }
            self?.onFinished?()
        }
    }

    func stop() async { task?.cancel(); await task?.value }
}

// MARK: - System audio (ScreenCaptureKit)

final class SystemAudioSource: NSObject, AudioSource, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private let queue = DispatchQueue(label: "stttrans.systemaudio")

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        self.onBuffer = onBuffer
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw AppError.permission("화면 및 시스템 오디오 녹음 권한이 필요합니다. 시스템 설정 > 개인정보 보호 > 화면 및 시스템 오디오 녹음에서 허용 후 앱을 재시작하세요.")
        }
        guard let display = content.displays.first else { throw AppError.audio("디스플레이를 찾을 수 없습니다.") }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // Video is mandatory for SCStream; keep it as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let pcm = sampleBuffer.toPCMBuffer() else { return }
        onBuffer?(pcm)
    }
}

