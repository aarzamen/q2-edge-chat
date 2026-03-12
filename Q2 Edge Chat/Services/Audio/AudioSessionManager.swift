//
//  AudioSessionManager.swift
//  Q2 Edge Chat
//
//  Manages AVAudioSession configuration and handles audio interruptions.
//

import AVFoundation
import Combine

/// Singleton manager for AVAudioSession configuration and event handling
final class AudioSessionManager {
    static let shared = AudioSessionManager()

    private let session = AVAudioSession.sharedInstance()
    private var cancellables = Set<AnyCancellable>()

    /// Published when audio is interrupted (phone call, alarm, Siri)
    let interruptionPublisher = PassthroughSubject<InterruptionEvent, Never>()

    /// Published when audio route changes (headphones, Bluetooth)
    let routeChangePublisher = PassthroughSubject<RouteChangeEvent, Never>()

    /// Current audio session state
    private(set) var isActive = false

    // MARK: - Event Types

    enum InterruptionEvent {
        case began
        case ended(shouldResume: Bool)
    }

    enum RouteChangeEvent {
        case newDeviceAvailable
        case oldDeviceUnavailable
        case categoryChanged
        case other(AVAudioSession.RouteChangeReason)
    }

    // MARK: - Initialization

    private init() {
        setupNotifications()
    }

    // MARK: - Configuration

    /// Configure audio session for speech recognition
    /// Uses .record category with .measurement mode for raw audio input
    func configureForSpeechRecognition() throws {
        try session.setCategory(
            .record,
            mode: .measurement,
            options: [.duckOthers, .allowBluetoothHFP]
        )

        // Request 16kHz sample rate (iOS may provide closest available)
        try session.setPreferredSampleRate(16000.0)

        // Low latency buffer: 16ms
        try session.setPreferredIOBufferDuration(0.016)

        try session.setActive(true)
        isActive = true
    }

    /// Configure audio session for playback and recording
    /// Use this for apps that need both voice input and audio output
    func configureForPlayAndRecord() throws {
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        )

        try session.setPreferredSampleRate(16000.0)
        try session.setPreferredIOBufferDuration(0.016)

        try session.setActive(true)
        isActive = true
    }

    /// Deactivate audio session and notify other apps
    func deactivate() throws {
        guard isActive else { return }

        try session.setActive(false, options: .notifyOthersOnDeactivation)
        isActive = false
    }

    // MARK: - Properties

    /// Current sample rate (may differ from requested)
    var currentSampleRate: Double {
        session.sampleRate
    }

    /// Current IO buffer duration
    var currentBufferDuration: TimeInterval {
        session.ioBufferDuration
    }

    /// Check if microphone permission is granted
    var hasMicrophonePermission: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// Request microphone permission
    func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    // MARK: - Notification Handling

    private func setupNotifications() {
        // Audio interruption notifications
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                self?.handleInterruption(notification)
            }
            .store(in: &cancellables)

        // Route change notifications
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] notification in
                self?.handleRouteChange(notification)
            }
            .store(in: &cancellables)
    }

    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            isActive = false
            interruptionPublisher.send(.began)

        case .ended:
            var shouldResume = false

            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                shouldResume = options.contains(.shouldResume)
            }

            if shouldResume {
                try? session.setActive(true)
                isActive = true
            }

            interruptionPublisher.send(.ended(shouldResume: shouldResume))

        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        let event: RouteChangeEvent

        switch reason {
        case .newDeviceAvailable:
            event = .newDeviceAvailable
        case .oldDeviceUnavailable:
            event = .oldDeviceUnavailable
        case .categoryChange:
            event = .categoryChanged
        default:
            event = .other(reason)
        }

        routeChangePublisher.send(event)
    }
}
