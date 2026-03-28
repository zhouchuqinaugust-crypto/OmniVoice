@preconcurrency import AVFoundation
import Foundation

public enum AudioRecorderError: LocalizedError {
    case microphonePermissionDenied
    case alreadyRecording
    case notRecording
    case recorderSetupFailed
    case recordingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission was denied."
        case .alreadyRecording:
            return "Recording is already in progress."
        case .notRecording:
            return "No active recording is in progress."
        case .recorderSetupFailed:
            return "Failed to initialize local audio recording."
        case .recordingFailed(let reason):
            return "Failed to capture microphone audio: \(reason)"
        }
    }
}

@MainActor
public final class AudioRecorder: NSObject {
    public private(set) var isRecording = false
    public var levelObserver: (@Sendable (Float) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var currentFileURL: URL?
    private var recordingProcessor: RecordingProcessor?

    public override init() {
        super.init()
    }

    public func startRecording() async throws -> URL {
        guard !isRecording else {
            throw AudioRecorderError.alreadyRecording
        }

        let status = await PermissionManager.requestMicrophonePermission()
        guard status == "authorized" else {
            throw AudioRecorderError.microphonePermissionDenied
        }

        let fileURL = makeRecordingURL()
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let processor = try RecordingProcessor(outputURL: fileURL, levelHandler: levelObserver)
        let tapBlock = makeRecordingTapBlock(processor: processor)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: nil, block: tapBlock)

        engine.prepare()

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            processor.cancel()
            throw AudioRecorderError.recordingFailed(error.localizedDescription)
        }

        self.audioEngine = engine
        self.recordingProcessor = processor
        self.currentFileURL = fileURL
        self.isRecording = true
        return fileURL
    }

    public func stopRecording() throws -> URL {
        guard isRecording,
              let audioEngine,
              let recordingProcessor,
              let currentFileURL else {
            throw AudioRecorderError.notRecording
        }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        try recordingProcessor.finish()

        self.audioEngine = nil
        self.recordingProcessor = nil
        self.currentFileURL = nil
        self.isRecording = false
        try? RecordingDiagnostics.persistArtifacts(for: currentFileURL)
        return currentFileURL
    }

    public func cancelRecording() throws {
        guard isRecording,
              let audioEngine,
              let recordingProcessor,
              let currentFileURL else {
            throw AudioRecorderError.notRecording
        }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        recordingProcessor.cancel()

        self.audioEngine = nil
        self.recordingProcessor = nil
        self.currentFileURL = nil
        self.isRecording = false
        try? FileManager.default.removeItem(at: currentFileURL)
    }

    private func makeRecordingURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
        let filename = "omnivoice-recording-\(UUID().uuidString).wav"
        return directory.appendingPathComponent(filename)
    }
}

private func makeRecordingTapBlock(processor: RecordingProcessor) -> AVAudioNodeTapBlock {
    { buffer, _ in
        processor.append(buffer)
    }
}

private final class RecordingProcessor: @unchecked Sendable {
    private static let targetSampleRate: Double = 16_000
    private static let targetChannelCount: AVAudioChannelCount = 1

    private let queue = DispatchQueue(label: "com.chuqinzhou.omnivoice.recording-writer")
    private let outputURL: URL
    private let targetFormat: AVAudioFormat
    private let wavWriter: PCM16WAVWriter
    private let levelHandler: (@Sendable (Float) -> Void)?

    private var converter: AVAudioConverter?
    private var storedError: Error?

    init(
        outputURL: URL,
        levelHandler: (@Sendable (Float) -> Void)? = nil
    ) throws {
        self.outputURL = outputURL
        self.levelHandler = levelHandler
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: Self.targetChannelCount,
            interleaved: false
        ) else {
            throw AudioRecorderError.recorderSetupFailed
        }

        self.targetFormat = targetFormat
        self.wavWriter = try PCM16WAVWriter(
            outputURL: outputURL,
            sampleRate: Int(Self.targetSampleRate),
            channelCount: Int(Self.targetChannelCount)
        )
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard storedError == nil else {
            return
        }

        guard let bufferCopy = Self.makeBufferCopy(from: buffer) else {
            storedError = AudioRecorderError.recordingFailed("Unable to copy an audio buffer from the microphone.")
            return
        }

        queue.async { [weak self] in
            self?.process(bufferCopy)
        }
    }

    func finish() throws {
        try queue.sync {
            if let error = storedError {
                throw error
            }
            try flushConverter()
            try wavWriter.finalize()
        }
    }

    func cancel() {
        queue.sync {
            wavWriter.cancel()
            storedError = nil
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard storedError == nil else {
            return
        }

        do {
            if converter == nil {
                guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
                    throw AudioRecorderError.recordingFailed(
                        "Could not convert microphone input from \(buffer.format.settings) to 16 kHz mono."
                    )
                }
                converter.primeMethod = .none
                converter.downmix = false
                self.converter = converter
            }

            guard let converter else {
                throw AudioRecorderError.recorderSetupFailed
            }

            if let strongestChannel = Self.strongestChannelSignal(for: buffer) {
                converter.channelMap = [NSNumber(value: strongestChannel.index)]
                levelHandler?(Self.visualizationLevel(rms: strongestChannel.rms, peak: strongestChannel.peak))
            }

            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let targetCapacity = AVAudioFrameCount(max(1, Int(Double(buffer.frameLength) * ratio) + 512))
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: targetCapacity
            ) else {
                throw AudioRecorderError.recordingFailed("Unable to allocate a converted audio buffer.")
            }

            var pendingBuffer: AVAudioPCMBuffer? = buffer
            var conversionError: NSError?
            let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
                if let sourceBuffer = pendingBuffer {
                    outStatus.pointee = .haveData
                    pendingBuffer = nil
                    return sourceBuffer
                }

                outStatus.pointee = .noDataNow
                return nil
            }

            if let conversionError {
                throw conversionError
            }

            switch status {
            case .haveData, .inputRanDry, .endOfStream:
                try wavWriter.append(buffer: convertedBuffer)
            case .error:
                throw AudioRecorderError.recordingFailed("Audio conversion failed while capturing microphone input.")
            @unknown default:
                throw AudioRecorderError.recordingFailed("Audio conversion returned an unknown status.")
            }
        } catch {
            storedError = error
        }
    }

    private func flushConverter() throws {
        guard let converter else {
            return
        }

        while true {
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: 2_048
            ) else {
                throw AudioRecorderError.recordingFailed("Unable to allocate a flush audio buffer.")
            }

            var conversionError: NSError?
            let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }

            if let conversionError {
                throw conversionError
            }

            switch status {
            case .haveData, .inputRanDry:
                try wavWriter.append(buffer: convertedBuffer)
                if convertedBuffer.frameLength == 0 {
                    return
                }
            case .endOfStream:
                try wavWriter.append(buffer: convertedBuffer)
                return
            case .error:
                throw AudioRecorderError.recordingFailed("Audio conversion failed while finalizing microphone audio.")
            @unknown default:
                throw AudioRecorderError.recordingFailed("Audio conversion returned an unknown flush status.")
            }
        }
    }

    private static func makeBufferCopy(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }

        copy.frameLength = buffer.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)

        guard sourceBuffers.count == destinationBuffers.count else {
            return nil
        }

        for index in 0..<sourceBuffers.count {
            let source = sourceBuffers[index]
            var destination = destinationBuffers[index]
            guard let sourceData = source.mData,
                  let destinationData = destination.mData else {
                return nil
            }

            destination.mDataByteSize = source.mDataByteSize
            memcpy(destinationData, sourceData, Int(source.mDataByteSize))
            destinationBuffers[index] = destination
        }

        return copy
    }

    private static func strongestChannelSignal(
        for buffer: AVAudioPCMBuffer
    ) -> (index: Int, rms: Double, peak: Double)? {
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 0, frameCount > 0 else {
            return nil
        }

        var strongestIndex = 0
        var strongestEnergy: Double = -1
        var strongestPeak: Double = 0
        let stride = Int(buffer.stride)

        if let floatData = buffer.floatChannelData {
            for channelIndex in 0..<channelCount {
                let channel = floatData[channelIndex]
                var energy: Double = 0
                var peak: Double = 0
                for frameIndex in 0..<frameCount {
                    let sample = Double(channel[frameIndex * stride])
                    energy += sample * sample
                    peak = max(peak, abs(sample))
                }
                if energy > strongestEnergy {
                    strongestEnergy = energy
                    strongestIndex = channelIndex
                    strongestPeak = peak
                }
            }
            let rms = sqrt(strongestEnergy / Double(frameCount))
            return (strongestIndex, rms, strongestPeak)
        }

        if let int16Data = buffer.int16ChannelData {
            for channelIndex in 0..<channelCount {
                let channel = int16Data[channelIndex]
                var energy: Double = 0
                var peak: Double = 0
                for frameIndex in 0..<frameCount {
                    let sample = Double(channel[frameIndex * stride]) / Double(Int16.max)
                    energy += sample * sample
                    peak = max(peak, abs(sample))
                }
                if energy > strongestEnergy {
                    strongestEnergy = energy
                    strongestIndex = channelIndex
                    strongestPeak = peak
                }
            }
            let rms = sqrt(strongestEnergy / Double(frameCount))
            return (strongestIndex, rms, strongestPeak)
        }

        if let int32Data = buffer.int32ChannelData {
            for channelIndex in 0..<channelCount {
                let channel = int32Data[channelIndex]
                var energy: Double = 0
                var peak: Double = 0
                for frameIndex in 0..<frameCount {
                    let sample = Double(channel[frameIndex * stride]) / Double(Int32.max)
                    energy += sample * sample
                    peak = max(peak, abs(sample))
                }
                if energy > strongestEnergy {
                    strongestEnergy = energy
                    strongestIndex = channelIndex
                    strongestPeak = peak
                }
            }
            let rms = sqrt(strongestEnergy / Double(frameCount))
            return (strongestIndex, rms, strongestPeak)
        }

        return nil
    }

    private static func visualizationLevel(rms: Double, peak: Double) -> Float {
        let signal = max(rms, peak * 0.45)
        let floor = 0.000_02
        let decibels = 20.0 * log10(max(signal, floor))
        let normalized = max(0.0, min(1.0, (decibels + 52.0) / 46.0))
        return Float(pow(normalized, 0.85))
    }
}

private final class PCM16WAVWriter {
    private let outputURL: URL
    private let fileHandle: FileHandle
    private let sampleRate: Int
    private let channelCount: Int

    private var dataByteCount: UInt32 = 0
    private var isFinalized = false

    init(outputURL: URL, sampleRate: Int, channelCount: Int) throws {
        self.outputURL = outputURL
        self.sampleRate = sampleRate
        self.channelCount = channelCount

        try? FileManager.default.removeItem(at: outputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        self.fileHandle = try FileHandle(forWritingTo: outputURL)
        try fileHandle.write(contentsOf: Data(count: 44))
    }

    func append(buffer: AVAudioPCMBuffer) throws {
        guard !isFinalized else {
            return
        }

        guard buffer.frameLength > 0,
              let channelData = buffer.floatChannelData else {
            return
        }

        let frameCount = Int(buffer.frameLength)
        var samples = [Int16](repeating: 0, count: frameCount)
        let source = channelData[0]

        for index in 0..<frameCount {
            let clamped = max(-1.0, min(1.0, source[index]))
            samples[index] = Int16((clamped * Float(Int16.max)).rounded()).littleEndian
        }

        let data = samples.withUnsafeBytes { Data($0) }
        try fileHandle.write(contentsOf: data)
        dataByteCount += UInt32(data.count)
    }

    func finalize() throws {
        guard !isFinalized else {
            return
        }

        try fileHandle.seek(toOffset: 0)
        try fileHandle.write(contentsOf: makeHeader(dataByteCount: dataByteCount))
        try fileHandle.close()
        isFinalized = true
    }

    func cancel() {
        try? fileHandle.close()
        try? FileManager.default.removeItem(at: outputURL)
        isFinalized = true
    }

    private func makeHeader(dataByteCount: UInt32) -> Data {
        let byteRate = UInt32(sampleRate * channelCount * 2)
        let blockAlign = UInt16(channelCount * 2)
        let riffChunkSize = UInt32(36) + dataByteCount

        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        appendInteger(riffChunkSize, to: &header)
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        appendInteger(UInt32(16), to: &header)
        appendInteger(UInt16(1), to: &header)
        appendInteger(UInt16(channelCount), to: &header)
        appendInteger(UInt32(sampleRate), to: &header)
        appendInteger(byteRate, to: &header)
        appendInteger(blockAlign, to: &header)
        appendInteger(UInt16(16), to: &header)
        header.append("data".data(using: .ascii)!)
        appendInteger(dataByteCount, to: &header)
        return header
    }

    private func appendInteger<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}

private enum RecordingDiagnostics {
    private static let preservedAudioURL = URL(fileURLWithPath: "/tmp/omnivoice-last-recording.wav")
    private static let preservedMetadataURL = URL(fileURLWithPath: "/tmp/omnivoice-last-recording.json")

    static func persistArtifacts(for recordedFileURL: URL) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: preservedAudioURL)
        try? fileManager.removeItem(at: preservedMetadataURL)
        try fileManager.copyItem(at: recordedFileURL, to: preservedAudioURL)

        let metadata = try buildMetadata(for: preservedAudioURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: preservedMetadataURL)
    }

    private static func buildMetadata(for audioURL: URL) throws -> RecordingDiagnosticMetadata {
        let audioFile = try AVAudioFile(forReading: audioURL)
        let processingFormat = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCount) else {
            return RecordingDiagnosticMetadata(
                path: audioURL.path,
                sampleRate: processingFormat.sampleRate,
                channelCount: Int(processingFormat.channelCount),
                frameCount: Int(audioFile.length),
                durationSeconds: 0,
                peakAmplitude: 0,
                rmsAmplitude: 0
            )
        }

        try audioFile.read(into: buffer)
        let stats = amplitudeStats(for: buffer)

        return RecordingDiagnosticMetadata(
            path: audioURL.path,
            sampleRate: processingFormat.sampleRate,
            channelCount: Int(processingFormat.channelCount),
            frameCount: Int(buffer.frameLength),
            durationSeconds: processingFormat.sampleRate > 0
                ? Double(buffer.frameLength) / processingFormat.sampleRate
                : 0,
            peakAmplitude: stats.peak,
            rmsAmplitude: stats.rms
        )
    }

    private static func amplitudeStats(for buffer: AVAudioPCMBuffer) -> (peak: Float, rms: Float) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            return (0, 0)
        }

        var peak: Float = 0
        var squareSum: Double = 0
        var sampleCount = 0

        if let floatData = buffer.floatChannelData {
            for channelIndex in 0..<Int(buffer.format.channelCount) {
                let channel = floatData[channelIndex]
                for frameIndex in 0..<frameCount {
                    let sample = channel[frameIndex]
                    peak = max(peak, abs(sample))
                    squareSum += Double(sample * sample)
                    sampleCount += 1
                }
            }
        } else if let int16Data = buffer.int16ChannelData {
            for channelIndex in 0..<Int(buffer.format.channelCount) {
                let channel = int16Data[channelIndex]
                for frameIndex in 0..<frameCount {
                    let sample = Float(channel[frameIndex]) / Float(Int16.max)
                    peak = max(peak, abs(sample))
                    squareSum += Double(sample * sample)
                    sampleCount += 1
                }
            }
        }

        guard sampleCount > 0 else {
            return (0, 0)
        }

        let rms = sqrt(squareSum / Double(sampleCount))
        return (peak, Float(rms))
    }
}

private struct RecordingDiagnosticMetadata: Codable {
    let path: String
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int
    let durationSeconds: Double
    let peakAmplitude: Float
    let rmsAmplitude: Float
}
