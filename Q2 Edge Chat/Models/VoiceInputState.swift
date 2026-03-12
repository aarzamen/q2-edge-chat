//
//  VoiceInputState.swift
//  Q2 Edge Chat
//
//  Voice input state machine for speech-to-text functionality.
//

import Foundation

/// Represents the current state of the voice input system
enum VoiceInputState: Equatable {
    /// Ready to start recording
    case idle

    /// Microphone active, VAD listening for speech
    case listening

    /// Speech detected, ASR processing audio
    case transcribing

    /// Finishing transcription, getting final result
    case finalizing

    /// An error occurred
    case error(String)

    /// Whether the microphone is currently active
    var isRecording: Bool {
        switch self {
        case .listening, .transcribing:
            return true
        case .idle, .finalizing, .error:
            return false
        }
    }

    /// Human-readable status message
    var statusMessage: String {
        switch self {
        case .idle:
            return "Tap to speak"
        case .listening:
            return "Listening..."
        case .transcribing:
            return "Transcribing..."
        case .finalizing:
            return "Processing..."
        case .error(let message):
            return message
        }
    }

    // Equatable conformance for error case
    static func == (lhs: VoiceInputState, rhs: VoiceInputState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.listening, .listening),
             (.transcribing, .transcribing),
             (.finalizing, .finalizing):
            return true
        case (.error(let lhsMsg), .error(let rhsMsg)):
            return lhsMsg == rhsMsg
        default:
            return false
        }
    }
}

/// Represents an update from the transcription system
struct TranscriptionUpdate: Equatable {
    /// The transcribed text (may be partial)
    let text: String

    /// Whether this text is confirmed (stable) or still being refined
    let isConfirmed: Bool

    /// Confidence score (0.0 - 1.0)
    let confidence: Float

    /// Timestamp of this update
    let timestamp: Date

    init(text: String, isConfirmed: Bool, confidence: Float, timestamp: Date = Date()) {
        self.text = text
        self.isConfirmed = isConfirmed
        self.confidence = confidence
        self.timestamp = timestamp
    }
}

/// Voice input configuration
struct VoiceInputConfig {
    /// VAD speech detection threshold (0.0 - 1.0)
    /// Lower = more sensitive, higher = less false positives
    var vadThreshold: Float = 0.75

    /// Minimum speech duration to trigger transcription (seconds)
    var minSpeechDuration: TimeInterval = 0.25

    /// Silence duration to end speech segment (seconds)
    var minSilenceDuration: TimeInterval = 0.5

    /// Maximum speech segment duration (seconds)
    var maxSpeechDuration: TimeInterval = 30.0

    /// Auto-stop after this duration of silence (seconds)
    /// Set to nil to disable auto-stop
    var autoStopSilenceDuration: TimeInterval? = 2.0

    static let `default` = VoiceInputConfig()

    /// Configuration optimized for medical conversations
    static let medical = VoiceInputConfig(
        vadThreshold: 0.7,
        minSpeechDuration: 0.2,
        minSilenceDuration: 0.8,
        maxSpeechDuration: 60.0,
        autoStopSilenceDuration: 3.0
    )
}
