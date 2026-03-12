//
//  AudioCaptureService.swift
//  Q2 Edge Chat
//
//  Handles microphone audio capture using AVAudioEngine.
//  Outputs 16kHz mono Float32 audio chunks suitable for speech recognition.
//

import AVFoundation
import Combine

/// Actor that manages audio capture from the microphone
actor AudioCaptureService {

    // MARK: - Properties

    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?

    /// Target format for speech recognition
    private let targetSampleRate: Double = 16000
    private let targetChannels: AVAudioChannelCount = 1

    /// Buffer size: 4096 samples = 256ms at 16kHz (matches Silero VAD chunk size)
    private let bufferSize: AVAudioFrameCount = 4096

    /// Publisher for audio chunks (16kHz mono Float32)
    nonisolated let audioChunkPublisher = PassthroughSubject<[Float], Never>()

    /// Current capture state
    private(set) var isCapturing = false

    // MARK: - Public Methods

    /// Start capturing audio from the microphone
    /// Audio is automatically converted to 16kHz mono Float32
    func startCapture() throws {
        guard !isCapturing else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Get hardware format
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard hardwareFormat.sampleRate > 0 else {
            throw AudioCaptureError.invalidHardwareFormat
        }

        // Create target format: 16kHz, mono, Float32
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        ) else {
            throw AudioCaptureError.formatCreationFailed
        }

        // Create converter for sample rate conversion
        guard let audioConverter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw AudioCaptureError.converterCreationFailed
        }
        self.converter = audioConverter

        // Calculate buffer size for hardware sample rate
        let hardwareBufferSize = AVAudioFrameCount(
            Double(bufferSize) * hardwareFormat.sampleRate / targetSampleRate
        )

        // Install tap on input node with HARDWARE format (not target format)
        inputNode.installTap(onBus: 0, bufferSize: hardwareBufferSize, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Convert on audio thread then dispatch
            Task.detached(priority: .userInitiated) {
                await self.processAndPublish(buffer: buffer, converter: audioConverter, targetFormat: targetFormat)
            }
        }

        engine.prepare()
        try engine.start()

        self.audioEngine = engine
        self.isCapturing = true
    }

    /// Stop capturing audio
    func stopCapture() {
        guard isCapturing else { return }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()

        audioEngine = nil
        converter = nil
        isCapturing = false
    }

    // MARK: - Private Methods

    private func processAndPublish(buffer: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat) {
        // Calculate output frame count based on sample rate ratio
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        // Create output buffer
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCount
        ) else { return }

        // Convert
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil else {
            print("Audio conversion error: \(error?.localizedDescription ?? "unknown")")
            return
        }

        // Extract samples
        guard let channelData = outputBuffer.floatChannelData?[0] else { return }
        let frameCount = Int(outputBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))

        // Publish
        audioChunkPublisher.send(samples)
    }
}

// MARK: - Errors

enum AudioCaptureError: LocalizedError {
    case invalidHardwareFormat
    case formatCreationFailed
    case converterCreationFailed
    case engineStartFailed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidHardwareFormat:
            return "Invalid audio hardware format"
        case .formatCreationFailed:
            return "Failed to create target audio format"
        case .converterCreationFailed:
            return "Failed to create audio converter"
        case .engineStartFailed(let error):
            return "Failed to start audio engine: \(error.localizedDescription)"
        }
    }
}

// MARK: - Extensions

extension Array where Element == Float {
    /// Convert Float array to AVAudioPCMBuffer (16kHz mono)
    func toAudioBuffer() -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else { return nil }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(count)
        ) else { return nil }

        buffer.frameLength = AVAudioFrameCount(count)

        if let channelData = buffer.floatChannelData?[0] {
            for (index, sample) in self.enumerated() {
                channelData[index] = sample
            }
        }

        return buffer
    }
}
