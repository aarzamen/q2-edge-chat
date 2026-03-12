//
//  VoiceInputManager.swift
//  Q2 Edge Chat
//
//  Orchestrates voice input using VAD and ASR from FluidAudio.
//  Uses streaming VAD for speech detection and batch ASR for transcription.
//

import Foundation
import Combine
import AVFoundation
import FluidAudio

/// Actor that manages the complete voice input pipeline
/// Coordinates audio capture, VAD, and ASR for speech-to-text
actor VoiceInputManager {

    // MARK: - State

    /// Current state of the voice input system
    private(set) var state: VoiceInputState = .idle

    /// Configuration for voice input behavior
    private let config: VoiceInputConfig

    // MARK: - Components

    private let audioCapture = AudioCaptureService()
    private var audioSubscription: AnyCancellable?
    private var interruptionSubscription: AnyCancellable?

    // FluidAudio components
    private var asrModels: AsrModels?
    private var asrManager: AsrManager?
    private var vadManager: VadManager?
    private var vadState: VadStreamState?

    /// Whether models have been loaded
    private var isInitialized = false

    // MARK: - Audio Accumulation

    /// Accumulated audio samples during recording
    private var accumulatedSamples: [Float] = []

    /// Time when silence started (for auto-stop)
    private var silenceStartTime: Date?

    /// Time when speech was first detected
    private var speechStartTime: Date?

    /// Whether we've detected speech in this recording session
    private var hasDetectedSpeech = false

    // MARK: - Publishers

    /// Publishes transcription updates (partial and confirmed text)
    nonisolated let transcriptionUpdates = PassthroughSubject<TranscriptionUpdate, Never>()

    /// Publishes state changes
    nonisolated let stateChanges = PassthroughSubject<VoiceInputState, Never>()

    /// Publishes final transcription result (especially useful for auto-stop)
    nonisolated let transcriptionCompleted = PassthroughSubject<String, Never>()

    // MARK: - Initialization

    init(config: VoiceInputConfig = .default) {
        self.config = config
    }

    // MARK: - Public Methods

    /// Initialize FluidAudio models (call once before first use)
    /// This downloads models if needed (~500MB) and may take several seconds
    func initialize() async throws {
        guard !isInitialized else { return }

        // Load ASR models (v3 for multilingual, v2 for English-only)
        asrModels = try await AsrModels.downloadAndLoad(version: .v3)

        // Initialize ASR manager
        if let models = asrModels {
            asrManager = AsrManager(config: .default)
            try await asrManager?.initialize(models: models)
        }

        // Initialize VAD manager with config
        let vadConfig = VadConfig(defaultThreshold: config.vadThreshold)
        vadManager = try await VadManager(config: vadConfig)

        // Create initial VAD state
        vadState = await vadManager?.makeStreamState()

        isInitialized = true
    }

    /// Start listening for voice input
    /// Returns immediately; use stateChanges to monitor progress
    func startListening() async throws {
        guard state == .idle else { return }

        // Check microphone permission
        if !AudioSessionManager.shared.hasMicrophonePermission {
            let granted = await AudioSessionManager.shared.requestMicrophonePermission()
            guard granted else {
                throw VoiceInputError.microphoneAccessDenied
            }
        }

        // Initialize if needed
        if !isInitialized {
            try await initialize()
        }

        // Reset state for new recording
        accumulatedSamples = []
        silenceStartTime = nil
        speechStartTime = nil
        hasDetectedSpeech = false

        // Reset VAD state for new session
        vadState = await vadManager?.makeStreamState()

        // Configure audio session
        try AudioSessionManager.shared.configureForSpeechRecognition()

        // Start audio capture
        try await audioCapture.startCapture()

        // Subscribe to audio chunks
        audioSubscription = audioCapture.audioChunkPublisher
            .sink { [weak self] chunk in
                guard let self = self else { return }
                Task {
                    await self.processAudioChunk(chunk)
                }
            }

        // Subscribe to interruptions
        interruptionSubscription = AudioSessionManager.shared.interruptionPublisher
            .sink { [weak self] event in
                guard let self = self else { return }
                Task {
                    await self.handleInterruption(event)
                }
            }

        // Update state
        updateState(.listening)
    }

    /// Stop listening and return final transcription
    @discardableResult
    func stopListening() async throws -> String {
        guard state.isRecording else { return "" }

        updateState(.finalizing)

        // Stop audio capture
        audioSubscription?.cancel()
        audioSubscription = nil
        await audioCapture.stopCapture()

        // Transcribe accumulated audio
        var finalText = ""

        if !accumulatedSamples.isEmpty && hasDetectedSpeech {
            do {
                if let asr = asrManager {
                    let result = try await asr.transcribe(accumulatedSamples, source: .microphone)
                    finalText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {
                updateState(.error("Transcription failed: \(error.localizedDescription)"))
                throw VoiceInputError.asrFailed(error.localizedDescription)
            }
        }

        // Clear accumulated samples
        accumulatedSamples = []

        // Deactivate audio session
        try? AudioSessionManager.shared.deactivate()

        // Publish the transcription result
        if !finalText.isEmpty {
            transcriptionCompleted.send(finalText)
        }

        // Update state
        updateState(.idle)

        return finalText
    }

    /// Cancel voice input without returning result
    func cancel() async {
        audioSubscription?.cancel()
        audioSubscription = nil
        await audioCapture.stopCapture()

        accumulatedSamples = []
        silenceStartTime = nil
        speechStartTime = nil
        hasDetectedSpeech = false

        try? AudioSessionManager.shared.deactivate()
        updateState(.idle)
    }

    // MARK: - Audio Processing

    private func processAudioChunk(_ chunk: [Float]) async {
        guard let vadManager = vadManager,
              let currentVadState = vadState else { return }

        // Always accumulate samples while recording
        accumulatedSamples.append(contentsOf: chunk)

        // Create segmentation config from our config
        var segmentConfig = VadSegmentationConfig.default
        segmentConfig.minSpeechDuration = config.minSpeechDuration
        segmentConfig.minSilenceDuration = config.minSilenceDuration
        segmentConfig.maxSpeechDuration = config.maxSpeechDuration

        do {
            // Process VAD
            let vadResult = try await vadManager.processStreamingChunk(
                chunk,
                state: currentVadState,
                config: segmentConfig,
                returnSeconds: true,
                timeResolution: 2
            )

            // CRITICAL: Update VAD state for next chunk
            vadState = vadResult.state

            // Handle speech events
            if let event = vadResult.event {
                switch event.kind {
                case .speechStart:
                    if state == .listening {
                        updateState(.transcribing)
                    }
                    hasDetectedSpeech = true
                    speechStartTime = Date()
                    silenceStartTime = nil

                case .speechEnd:
                    silenceStartTime = Date()
                }
            }

            // Update state based on probability if no event
            if vadResult.probability > config.vadThreshold {
                if state == .listening {
                    updateState(.transcribing)
                    hasDetectedSpeech = true
                    speechStartTime = speechStartTime ?? Date()
                }
                silenceStartTime = nil
            } else if state == .transcribing {
                // Low probability - start silence timer if not already started
                if silenceStartTime == nil {
                    silenceStartTime = Date()
                }
            }

            // Check for auto-stop after silence
            if let autoStop = config.autoStopSilenceDuration,
               let silenceStart = silenceStartTime,
               Date().timeIntervalSince(silenceStart) > autoStop,
               hasDetectedSpeech {
                // Auto-stop and transcribe
                Task {
                    try? await stopListening()
                }
            }

            // Check for max speech duration
            if let speechStart = speechStartTime,
               Date().timeIntervalSince(speechStart) > config.maxSpeechDuration {
                Task {
                    try? await stopListening()
                }
            }

        } catch {
            updateState(.error(error.localizedDescription))
        }
    }

    // MARK: - Interruption Handling

    private func handleInterruption(_ event: AudioSessionManager.InterruptionEvent) async {
        switch event {
        case .began:
            // Pause recording on interruption
            if state.isRecording {
                await audioCapture.stopCapture()
                audioSubscription?.cancel()
            }

        case .ended(let shouldResume):
            // Resume if we were recording and system says it's safe
            if shouldResume && (state == .listening || state == .transcribing) {
                try? await audioCapture.startCapture()

                audioSubscription = audioCapture.audioChunkPublisher
                    .sink { [weak self] chunk in
                        guard let self = self else { return }
                        Task {
                            await self.processAudioChunk(chunk)
                        }
                    }
            }
        }
    }

    // MARK: - State Management

    private func updateState(_ newState: VoiceInputState) {
        state = newState
        stateChanges.send(newState)
    }
}

// MARK: - Errors

enum VoiceInputError: LocalizedError {
    case microphoneAccessDenied
    case modelNotLoaded
    case alreadyRecording
    case notRecording
    case asrFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneAccessDenied:
            return "Microphone access is required for voice input. Please enable it in Settings."
        case .modelNotLoaded:
            return "Speech recognition models are not loaded. Please try again."
        case .alreadyRecording:
            return "Voice recording is already in progress."
        case .notRecording:
            return "No voice recording in progress."
        case .asrFailed(let message):
            return "Speech recognition failed: \(message)"
        }
    }
}
