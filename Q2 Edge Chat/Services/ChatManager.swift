//
//  ChatManager.swift
//  Q2 Edge Chat
//
//  Manages chat sessions and orchestrates LLM inference.
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class ChatManager: ObservableObject {
    // MARK: - Published Properties

    @Published var sessions: [ChatSession] = []
    @Published var activeID: UUID?
    @Published var isSidebarHidden = true
    @Published var isModelLoading = false // Added loading state

    // MARK: - Private Properties

    private var engines: [URL: LlamaEngine] = [:]
    private var engineLastUsed: [URL: Date] = [:]
    private let maxCachedEngines = 3
    private let manifest: ManifestStore
    private var bag = Set<AnyCancellable>()
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    /// Debounce timer for saving sessions
    private var saveDebounceTask: Task<Void, Never>?

    // MARK: - Initialization

    init() {
        self.manifest = ManifestStore.shared

        loadSessions()

        // Sanitize sessions on init to clear any stale model IDs
        Task { await self.sanitizeSessions() }

        manifest.didChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { await self?.sanitizeSessions() }
            }
            .store(in: &bag)
    }

    // MARK: - Session Management

    func newChat() {
        let chat = ChatSession.empty()
        sessions.insert(chat, at: 0)
        activeID = chat.id
        saveSessionsImmediately()
    }

    func delete(_ id: UUID) {
        // Cancel any active task for this session
        activeTasks[id]?.cancel()
        activeTasks.removeValue(forKey: id)

        sessions.removeAll { $0.id == id }
        if activeID == id { activeID = sessions.first?.id }
        saveSessionsImmediately()
    }

    var activeIndex: Int? {
        sessions.firstIndex { $0.id == activeID }
    }
    
    // MARK: - Engine Preloading
    
    func preloadModel(id: String) async {
        guard !id.isEmpty else { return }
        
        let manifestEntries = await manifest.all()
        guard let entry = manifestEntries.first(where: { $0.id == id }) else { return }
        
        do {
            // Trigger engine loading (ignoring return value)
            _ = try await engine(for: entry.localURL)
        } catch {
            print("Failed to preload model \(id): \(error.localizedDescription)")
        }
    }

    // MARK: - Message Sending

    func send(_ text: String, in id: UUID) async throws {
        // Cancel any existing task for this session
        activeTasks[id]?.cancel()

        // Clean up task when done
        defer { activeTasks.removeValue(forKey: id) }

        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }

        // Append user message
        sessions[idx].messages.append(.init(speaker: .user, text: text))

        // Create assistant message and capture its ID (not the instance)
        let assistant = Message(speaker: .assistant, text: "")
        let assistantID = assistant.id  // FIX: Use ID instead of instance for lookups
        sessions[idx].messages.append(assistant)
        saveSessionsImmediately()

        // Validate model is available
        let manifestEntries = await manifest.all()
        guard let entry = manifestEntries.first(where: { $0.id == sessions[idx].modelID }) else {
            sessions[idx].messages.append(
                .init(speaker: .assistant, text: "Selected model not downloaded.")
            )
            saveSessionsImmediately()
            return
        }

        // Performance tracking
        var startTime: Date?
        var firstTokenTime: Date?
        var tokenCount = 0

        do {
            // Await the engine (handling async load if needed)
            let engine = try await engine(for: entry.localURL)

            startTime = Date()

            try await engine.generate(prompt: text, settings: sessions[idx].modelSettings) { token in
                Task { @MainActor in
                    // FIX: Use message ID for lookup instead of instance comparison
                    guard idx < self.sessions.count,
                          self.sessions[idx].id == id,
                          let aiIndex = self.sessions[idx].messages.firstIndex(where: { $0.id == assistantID }) else {
                        print("Warning: Could not find assistant message for token update")
                        return
                    }

                    // Track first token
                    if firstTokenTime == nil, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        firstTokenTime = Date()
                    }

                    tokenCount += 1
                    self.sessions[idx].messages[aiIndex].text.append(token)

                    // FIX: Debounce saves instead of saving every token
                    self.debouncedSave()
                }
            }

            // Calculate and store metrics
            if let start = startTime, let firstToken = firstTokenTime, tokenCount > 0 {
                let timeToFirst = firstToken.timeIntervalSince(start)
                let totalTime = Date().timeIntervalSince(start)
                let tokensPerSec = totalTime > 0 ? Double(tokenCount) / totalTime : 0

                // FIX: Use ID-based lookup for final metrics update
                if let aiIndex = sessions[idx].messages.firstIndex(where: { $0.id == assistantID }) {
                    sessions[idx].messages[aiIndex].timeToFirstToken = timeToFirst
                    sessions[idx].messages[aiIndex].tokensPerSecond = tokensPerSec
                    sessions[idx].messages[aiIndex].totalTokens = tokenCount
                }
            }

        } catch is CancellationError {
            // Handle cancellation gracefully
            guard idx < sessions.count, sessions[idx].id == id else { return }
            if let aiIndex = sessions[idx].messages.firstIndex(where: { $0.id == assistantID }) {
                sessions[idx].messages[aiIndex].text.append(" [Cancelled]")
            }
        } catch {
            guard idx < sessions.count, sessions[idx].id == id else { return }
            sessions[idx].messages.append(.init(
                speaker: .assistant,
                text: "Error: \(error.localizedDescription)"
            ))

            throw error
        }

        // Final save (immediate, not debounced)
        saveSessionsImmediately()
    }

    // MARK: - Engine Management

    private func engine(for url: URL) async throws -> LlamaEngine {
        if let e = engines[url] {
            engineLastUsed[url] = Date()
            return e
        }

        // Clean up old engines if we're at capacity
        if engines.count >= maxCachedEngines {
            evictOldestEngine()
        }

        // Indicate loading state
        isModelLoading = true
        defer { isModelLoading = false }

        // Load in background to prevent UI freeze
        let engine = try await Task.detached(priority: .userInitiated) {
            try LlamaEngine(modelURL: url)
        }.value
        
        engines[url] = engine
        engineLastUsed[url] = Date()
        return engine
    }

    private func evictOldestEngine() {
        guard let oldestURL = engineLastUsed.min(by: { $0.value < $1.value })?.key else {
            return
        }

        engines.removeValue(forKey: oldestURL)
        engineLastUsed.removeValue(forKey: oldestURL)
    }

    func clearAllEngines() {
        engines.removeAll()
        engineLastUsed.removeAll()
    }

    // MARK: - Persistence

    private func sessionsFileURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appendingPathComponent("chats.json")
    }

    /// Debounced save - batches rapid updates (e.g., token streaming)
    private func debouncedSave() {
        saveDebounceTask?.cancel()
        saveDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self.saveSessionsImmediately()
        }
    }

    /// Immediate save - use for important state changes
    private func saveSessionsImmediately() {
        // Cancel any pending debounced save
        saveDebounceTask?.cancel()
        saveDebounceTask = nil

        do {
            let data = try JSONEncoder().encode(sessions)
            let url = try sessionsFileURL()
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to save sessions: \(error.localizedDescription)")
        }
    }

    /// Legacy method name for compatibility
    private func saveSessions() {
        saveSessionsImmediately()
    }

    private func loadSessions() {
        do {
            let url = try sessionsFileURL()
            let data = try Data(contentsOf: url)
            let saved = try JSONDecoder().decode([ChatSession].self, from: data)
            sessions = saved
            activeID = sessions.first?.id
        } catch {
            print("Failed to load sessions: \(error.localizedDescription)")
        }
    }

    private func sanitizeSessions() async {
        let validIDs = Set(await manifest.all().map(\.id))
        for i in sessions.indices where !validIDs.contains(sessions[i].modelID) {
            sessions[i].modelID = ""
        }
    }
}
