//
//  ChatView.swift
//  Q2 Edge Chat
//
//  Main chat interface with text and voice input support.
//

import SwiftUI

struct ChatView: View {
    @ObservedObject var manager: ChatManager
    @Binding var session: ChatSession
    @StateObject private var vm: ChatViewModel
    @State private var showingSettings = false
    @State private var showingExport = false

    init(manager: ChatManager, session: Binding<ChatSession>) {
        self.manager = manager
        self._session = session
        self._vm = StateObject(wrappedValue: ChatViewModel(manager: manager, session: session))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            // Chat Messages Area
            MessagesView(messages: session.messages)
                .background(Color(.systemGroupedBackground))

            // Error Banner
            if let error = vm.errorMessage {
                errorBanner(message: error)
            }

            // Input Area
            inputArea
        }
        .navigationBarBackButtonHidden(true)
        .sheet(isPresented: $showingSettings) {
            ModelSettingsView(settings: $session.modelSettings)
        }
        .sheet(isPresented: $showingExport) {
            ExportChatView(session: session)
        }
        .task {
            // Initialize voice input when view appears
            await vm.setupVoiceInput()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    manager.isSidebarHidden.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .padding(25)

            Spacer()

            HStack(spacing: 8) {
                ModelPickerView(selection: Binding(
                    get: { session.modelID },
                    set: { vm.selectModel($0) }
                ))
                
                if vm.isModelLoading {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.opacity)
                }
            }

            Spacer()

            Menu {
                Button("Model Settings") {
                    showingSettings = true
                }
                Button("Clear Chat") {
                    session.messages.removeAll()
                }
                Button("Export Chat") {
                    showingExport = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .padding(25)
        }
    }

    // MARK: - Input Area

    private var inputArea: some View {
        VStack(spacing: 0) {
            Divider()

            // Voice status indicator
            if vm.isRecording {
                voiceStatusBar
            }

            HStack(alignment: .bottom, spacing: 8) {
                // Voice Input Button
                VoiceInputButton(state: $vm.voiceState) {
                    Task { await vm.toggleVoiceRecording() }
                }

                // Text Input with partial transcription overlay
                textInputField

                // Send Button
                sendButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
        }
    }

    private var voiceStatusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(vm.voiceState == .transcribing ? 1.0 : 0.5)

            Text(vm.voiceState.statusMessage)
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            // Cancel button when recording
            Button("Cancel") {
                Task { await vm.cancelVoiceRecording() }
            }
            .font(.caption)
            .foregroundColor(.red)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: vm.isRecording)
    }

    private var textInputField: some View {
        ZStack(alignment: .leading) {
            // Main text editor
            DynamicTextEditor(
                text: $vm.inputText,
                placeholder: vm.isRecording ? nil : "Type or speak...",
                maxHeight: 100
            )

            // Partial transcription overlay
            if !vm.partialTranscription.isEmpty {
                Text(vm.partialTranscription)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .italic()
                    .lineLimit(2)
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemGray6))
                .stroke(
                    vm.isRecording ? Color.red.opacity(0.5) : Color(.systemGray4),
                    lineWidth: vm.isRecording ? 2 : 0.5
                )
        )
        .animation(.easeInOut(duration: 0.2), value: vm.isRecording)
    }

    private var sendButton: some View {
        Button(action: {
            Task { await vm.send() }
        }) {
            Image(systemName: hasInput ? "arrow.up.circle.fill" : "arrow.up.circle")
                .font(.title2)
                .foregroundColor(hasInput ? .accentColor : .secondary)
        }
        .disabled(!hasInput || vm.isRecording)
        .animation(.easeInOut(duration: 0.1), value: hasInput)
    }

    private var hasInput: Bool {
        !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Error Banner

    private func errorBanner(message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)

            Text(message)
                .font(.caption)
                .foregroundColor(.primary)
                .lineLimit(2)

            Spacer()

            Button {
                vm.clearError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.1))
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: vm.errorMessage != nil)
    }
}

// MARK: - Preview

#Preview {
    let manager = ChatManager()
    let session = ChatSession.empty()

    return ChatView(manager: manager, session: .constant(session))
}
