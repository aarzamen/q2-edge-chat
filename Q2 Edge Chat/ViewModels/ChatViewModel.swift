//
//  ChatViewModel.swift
//  Q2 Edge Chat
//
//  ViewModel for chat input handling including text and voice input.
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class ChatViewModel: ObservableObject {
    // MARK: - Published Properties

    /// Current text input (either typed or transcribed)
    @Published var inputText = ""

    /// Whether an LLM response is being generated
    @Published var isLoading = false

    /// Error message to display to user
    @Published var errorMessage: String?

    // MARK: - Voice Input State

    /// Current state of voice input
    @Published var voiceState: VoiceInputState = .idle

    /// Partial transcription text (unconfirmed, still being processed)
    @Published var partialTranscription = ""

    /// Whether voice input is currently active
    var isRecording: Bool {
        voiceState.isRecording
    }
    
    /// Whether the model is currently loading into memory
    var isModelLoading: Bool {
        manager.isModelLoading
    }

    // MARK: - Private Properties

    private let manager: ChatManager
    private var sessionBinding: Binding<ChatSession>

    /// Voice input manager (lazy initialization)
    private var voiceManager: VoiceInputManager?
    private var voiceSubscriptions = Set<AnyCancellable>()

    // MARK: - Session Access

    var session: ChatSession {
        get { sessionBinding.wrappedValue }
        set { sessionBinding.wrappedValue = newValue }
    }
    
    // MARK: - Model Selection
    
    func selectModel(_ id: String) {
        guard session.modelID != id else { return }
        session.modelID = id
        Task {
            await manager.preloadModel(id: id)
        }
    }

    // MARK: - Initialization

    init(manager: ChatManager, session: Binding<ChatSession>) {
        self.manager = manager
        self.sessionBinding = session
        
        // Forward manager changes to view model to trigger UI updates
        manager.$isModelLoading
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &voiceSubscriptions) // Reusing existing bag
    }

    // MARK: - Voice Input Methods

    /// Initialize voice input (call once, e.g., on appear)
    func setupVoiceInput() async {
        guard voiceManager == nil else { return }

        let manager = VoiceInputManager()
        self.voiceManager = manager

        // Subscribe to transcription updates (for future streaming support)
        manager.transcriptionUpdates
            .receive(on: RunLoop.main)
            .sink { [weak self] update in
                self?.handleTranscriptionUpdate(update)
            }
            .store(in: &voiceSubscriptions)

        // Subscribe to state changes
        manager.stateChanges
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in
                self?.voiceState = newState
            }
            .store(in: &voiceSubscriptions)

        // Subscribe to transcription completion (handles auto-stop)
        manager.transcriptionCompleted
            .receive(on: RunLoop.main)
            .sink { [weak self] transcription in
                self?.handleTranscriptionCompleted(transcription)
            }
            .store(in: &voiceSubscriptions)

        // Pre-initialize models in background
        Task.detached(priority: .background) {
            try? await manager.initialize()
        }
    }

    /// Toggle voice recording on/off
    func toggleVoiceRecording() async {
        guard let voiceManager = voiceManager else {
            errorMessage = "Voice input not initialized"
            return
        }

        clearError()

        if isRecording {
            // Stop recording - transcription will be handled via transcriptionCompleted publisher
            do {
                _ = try await voiceManager.stopListening()
                partialTranscription = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            // Start recording
            do {
                partialTranscription = ""
                try await voiceManager.startListening()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Cancel voice recording without saving
    func cancelVoiceRecording() async {
        guard let voiceManager = voiceManager else { return }
        await voiceManager.cancel()
        partialTranscription = ""
    }

    // MARK: - Text Input Methods

    /// Send the current input as a message
    func send() async {
        // Stop voice recording if active
        if isRecording {
            await cancelVoiceRecording()
        }

        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        // Validate session still exists
        guard manager.sessions.contains(where: { $0.id == session.id }) else {
            errorMessage = "Chat session no longer exists"
            return
        }

        let originalInput = inputText
        inputText = ""
        partialTranscription = ""
        isLoading = true
        errorMessage = nil

        do {
            try await manager.send(prompt, in: session.id)
        } catch {
            inputText = originalInput

            if let llamaError = error as? LlamaEngineError {
                errorMessage = "Model Error: \(llamaError.localizedDescription)"
            } else {
                errorMessage = "Failed to send message: \(error.localizedDescription)"
            }
        }

        isLoading = false
    }

    /// Clear the current error message
    func clearError() {
        errorMessage = nil
    }

    // MARK: - Private Methods

    private func handleTranscriptionUpdate(_ update: TranscriptionUpdate) {
        if update.isConfirmed {
            // Confirmed text - append to input
            if inputText.isEmpty {
                inputText = update.text
            } else {
                inputText += " " + update.text
            }
            partialTranscription = ""
        } else {
            // Partial text - show as preview
            partialTranscription = update.text
        }
    }

    private func handleTranscriptionCompleted(_ transcription: String) {
        guard !transcription.isEmpty else { return }

        // Append transcribed text to input
        let trimmed = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        if inputText.isEmpty {
            inputText = trimmed
        } else {
            inputText += " " + trimmed
        }
        partialTranscription = ""
    }
}
