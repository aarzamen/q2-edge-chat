//
//  VoiceInputButton.swift
//  Q2 Edge Chat
//
//  A circular button for voice input with state-based animations.
//  Shows different appearances based on recording state.
//

import SwiftUI

struct VoiceInputButton: View {
    /// Current voice input state
    @Binding var state: VoiceInputState

    /// Called when button is tapped
    let onTap: () -> Void

    /// Animation state
    @State private var isPulsing = false
    @State private var waveScale: CGFloat = 1.0

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Background circle
                Circle()
                    .fill(backgroundColor)
                    .frame(width: 44, height: 44)

                // Pulsing ring for listening state
                if state == .listening {
                    Circle()
                        .stroke(Color.accentColor.opacity(0.4), lineWidth: 2)
                        .frame(width: 44, height: 44)
                        .scaleEffect(isPulsing ? 1.6 : 1.0)
                        .opacity(isPulsing ? 0 : 0.8)
                }

                // Waveform rings for transcribing state
                if state == .transcribing {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .stroke(Color.white.opacity(0.3), lineWidth: 1.5)
                            .frame(width: 44, height: 44)
                            .scaleEffect(waveScale + CGFloat(index) * 0.15)
                            .opacity(1.0 - Double(index) * 0.3)
                    }
                }

                // Icon
                if state != .finalizing {
                    Image(systemName: iconName)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(iconColor)
                }

                // Progress indicator for finalizing
                if state == .finalizing {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
                }
            }
        }
        .buttonStyle(VoiceButtonStyle())
        .disabled(state == .finalizing)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .onChange(of: state) { _, newState in
            updateAnimations(for: newState)
        }
        .onAppear {
            updateAnimations(for: state)
        }
    }

    // MARK: - Appearance

    private var backgroundColor: Color {
        switch state {
        case .idle:
            return .accentColor
        case .listening:
            return .accentColor
        case .transcribing:
            return .red
        case .finalizing:
            return .gray
        case .error:
            return .red.opacity(0.8)
        }
    }

    private var iconName: String {
        switch state {
        case .idle:
            return "mic.fill"
        case .listening:
            return "mic.fill"
        case .transcribing:
            return "waveform"
        case .finalizing:
            return "ellipsis"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch state {
        case .idle, .listening, .transcribing, .finalizing:
            return .white
        case .error:
            return .white
        }
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        switch state {
        case .idle:
            return "Voice input"
        case .listening:
            return "Listening for speech"
        case .transcribing:
            return "Transcribing speech"
        case .finalizing:
            return "Processing transcription"
        case .error(let message):
            return "Error: \(message)"
        }
    }

    private var accessibilityHint: String {
        switch state {
        case .idle:
            return "Double tap to start voice recording"
        case .listening, .transcribing:
            return "Double tap to stop recording"
        case .finalizing:
            return "Please wait"
        case .error:
            return "Double tap to try again"
        }
    }

    // MARK: - Animations

    private func updateAnimations(for newState: VoiceInputState) {
        switch newState {
        case .listening:
            startPulsingAnimation()
        case .transcribing:
            stopPulsingAnimation()
            startWaveAnimation()
        default:
            stopAllAnimations()
        }
    }

    private func startPulsingAnimation() {
        isPulsing = false
        withAnimation(.easeOut(duration: 1.0).repeatForever(autoreverses: false)) {
            isPulsing = true
        }
    }

    private func startWaveAnimation() {
        waveScale = 1.0
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            waveScale = 1.3
        }
    }

    private func stopPulsingAnimation() {
        withAnimation(.linear(duration: 0.1)) {
            isPulsing = false
        }
    }

    private func stopAllAnimations() {
        withAnimation(.linear(duration: 0.1)) {
            isPulsing = false
            waveScale = 1.0
        }
    }
}

// MARK: - Button Style

struct VoiceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Preview

#Preview("Idle State") {
    VoiceInputButton(state: .constant(.idle)) {
        print("Tapped")
    }
    .padding()
}

#Preview("Listening State") {
    VoiceInputButton(state: .constant(.listening)) {
        print("Tapped")
    }
    .padding()
}

#Preview("Transcribing State") {
    VoiceInputButton(state: .constant(.transcribing)) {
        print("Tapped")
    }
    .padding()
}

#Preview("All States") {
    VStack(spacing: 20) {
        HStack(spacing: 20) {
            VoiceInputButton(state: .constant(.idle)) {}
            VoiceInputButton(state: .constant(.listening)) {}
            VoiceInputButton(state: .constant(.transcribing)) {}
        }
        HStack(spacing: 20) {
            VoiceInputButton(state: .constant(.finalizing)) {}
            VoiceInputButton(state: .constant(.error("Mic denied"))) {}
        }
    }
    .padding()
}
