# Q2 Edge Chat - Development Guide

## Project Overview

Q2 Edge Chat is a privacy-focused, on-device LLM chat application for iOS. Runs entirely offline using GGUF quantized models via SwiftLlama. Includes real-time voice input via FluidAudio (VAD + batch ASR).

**Target Platform**: iOS 17.0+ (iPhone, iPad — arm64 only)
**Architecture**: MVVM + Service Layer (actors + @MainActor)
**Key Dependencies**: SwiftLlama (LLM inference), FluidAudio (speech-to-text)

---

## Architecture

### Layer Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Views (SwiftUI)                          │
│  ChatView, MessagesView, ModelBrowserView, FrontPageView    │
│  VoiceInputButton, MessageRow, ModelPickerView              │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│              ViewModels (@MainActor)                        │
│  ChatViewModel - text/voice input, model selection          │
│  BrowseModelsViewModel - search, download, local import     │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│                 Services                                    │
│  ChatManager (@MainActor) - session CRUD, engine caching,   │
│    debounced saves, performance metrics                     │
│  ModelManager (actor) - HuggingFace API, file management    │
│  DownloadService (NSObject) - background URLSession         │
│  ManifestStore (actor) - model registry, GGUF validation    │
│  LlamaEngine (class) - model loading + generation           │
│  VoiceInputManager (actor) - VAD + ASR pipeline             │
│  AudioCaptureService (actor) - microphone capture           │
│  AudioSessionManager (singleton) - AVAudioSession           │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│                    Models (Data)                            │
│  ChatSession, ModelSettings, Message (with perf metrics),   │
│  ManifestEntry, HFModel, ModelDetail, StaffPickModel,       │
│  VoiceInputState, DiscoveredFile                            │
└─────────────────────────────────────────────────────────────┘
```

### File Structure

```
Q2 Edge Chat/
├── Q2_Edge_ChatApp.swift           # App entry point
├── Models/
│   ├── ChatSession.swift           # ChatSession + ModelSettings
│   ├── Message.swift               # Message with performance metrics
│   └── VoiceInputState.swift       # Voice recording state machine
├── Services/
│   ├── ChatManager.swift           # Session management, engine caching, LLM orchestration
│   ├── LlamaEngine.swift           # SwiftLlama wrapper + auto prompt-type detection
│   ├── ModelManager.swift          # HuggingFace API, DownloadService, StaffPickModel
│   ├── ModelManifest.swift         # ManifestStore actor, GGUF validation, local import
│   └── Audio/
│       ├── AudioSessionManager.swift    # AVAudioSession configuration
│       ├── AudioCaptureService.swift    # Microphone capture (16kHz mono)
│       └── VoiceInputManager.swift      # VAD + batch ASR pipeline
├── ViewModels/
│   ├── ChatViewModel.swift         # Chat input + voice state management
│   └── BrowseModelsViewModel.swift # Model browser, search, download, import
└── Views/
    ├── ChatView.swift              # Main chat interface
    ├── MessagesView.swift          # Message list with auto-scroll
    ├── FrontPageView.swift         # Landing / model selection
    ├── ModelBrowserView.swift      # Staff picks, search, download, local import
    ├── ModelPickerView.swift       # Model selector for sessions
    ├── ModelSettingsView.swift     # Temperature, tokens, system prompt
    ├── ChatListView.swift          # Session sidebar
    ├── ChatWorkspaceView.swift     # Chat + sidebar layout
    ├── ContentView.swift           # Navigation container
    ├── DynamicTextEditor.swift     # Auto-growing text input
    ├── ExportChatView.swift        # Chat export
    ├── MarkdownText.swift          # Markdown rendering
    └── Components/
        ├── MessageRow.swift        # Message bubble with performance overlay
        └── VoiceInputButton.swift  # Microphone button with state animations
```

---

## Key Components

### ChatManager

`@MainActor final class` — central orchestrator for sessions and inference.

- **Engine caching**: Up to 3 `LlamaEngine` instances, LRU eviction
- **Debounced saves**: Token streaming batches saves (2s debounce), immediate save on message send/delete
- **Performance metrics**: Tracks time-to-first-token, tokens/sec, total tokens per assistant message
- **Session sanitization**: Removes stale model IDs when manifest changes
- **Model preloading**: Background engine load on model selection
- Uses **message ID for lookups** — not instance comparison (struct mutation safe)

### LlamaEngine

Wraps `SwiftLlama` with comprehensive validation and auto prompt-type detection.

**Supported prompt formats** (auto-detected from filename):

| Model Family | Prompt Type |
|-------------|-------------|
| Llama 3.x | `.llama3` |
| Llama 2 | `.llama` |
| Qwen, SmolLM, StableLM, TinyLlama | `.chatML` |
| Phi | `.phi` |
| Gemma | `.gemma` |
| Mistral | `.mistral` |
| Default fallback | `.chatML` |

**Error types**: `modelNotFound`, `modelNotReadable`, `invalidModelFormat`, `modelTooSmall`, `modelLoadFailed`, `modelTooLargeForMemory`, `validationFailed`, `generationError`

### ModelManager + DownloadService

`ModelManager` (actor) — HuggingFace API client:
- `fetchModels`, `searchModels`, `fetchModelInfo`, `fetchModelREADME`
- `fetchModelDetail` → returns `ModelDetail` with per-quantization file mapping
- `parseQuantization` — regex extraction of Q4_K_M/Q8_0/IQ3_XS etc.
- `finalizeDownload` — moves temp file to `Library/Models/{sanitizedModelID}/`

`DownloadService` (NSObject, singleton) — background downloads:
- Uses `URLSessionConfiguration.background` for OS-managed downloads
- Uses `taskDescription` for model ID tracking (survives app relaunch)
- Persists filename to `UserDefaults` (temp file has no original name)
- Publishes via `downloadComplete` / `downloadError` subjects

### ManifestStore

Actor — persistent model registry at `ApplicationSupport/models.json`.

- **Path migration**: Handles container path changes (re-installs, simulator moves)
- **GGUF validation**: Magic bytes check (`0x46554747`), minimum size (1MB)
- **Local import**: From Documents folder scan or document picker (security-scoped URLs)
- **File copy with progress**: 1MB chunk copy with progress callback
- **Cleanup**: `validateAndCleanup()` removes entries with missing files

### BrowseModelsViewModel

`@MainActor class` — manages the model browser UI flow.

- **Staff picks**: Curated list of recommended models (`StaffPickModel.staffPicks`)
- **HuggingFace search**: Debounced (300ms) live search
- **Quantization selection**: Defaults to Q4_K_M → Q4_* → first available
- **Download flow**: Delegates to `DownloadService`, handles completion via publisher
- **Local import**: Discovers unimported `.gguf` files in Documents, imports via document picker

### ChatViewModel

`@MainActor final class` — manages chat input and voice state.

- Forwards `ChatManager.isModelLoading` to trigger loading UI
- Voice input via `VoiceInputManager` with `transcriptionUpdated` / `transcriptionCompleted` subscriptions
- Model selection with background preload

---

## Coding Standards

### Swift Concurrency

1. **Actors for shared state**: `ManifestStore`, `ModelManager`, `VoiceInputManager`, `AudioCaptureService`
2. **@MainActor for UI-bound**: `ChatManager`, `ChatViewModel`, `BrowseModelsViewModel`
3. **Never use `@unchecked Sendable`** — fix concurrency issues properly
4. **`Task.detached` for CPU work**: Model loading, file copy

### Error Handling

- Typed errors with `LocalizedError` conformance (`LlamaEngineError`, `GGUFValidationError`, `ModelManagerError`)
- Surface to UI via `@Published var errorMessage: String?`

### State Management

- Combine `PassthroughSubject` for cross-component events (manifest changes, download completion, voice transcription)
- Enums for finite state machines (`VoiceInputState`, `Speaker`)
- Debounced search via `$searchText.debounce(for: .milliseconds(300))`

### Performance

- **Debounced saves** — 2s debounce during token streaming, immediate on important state changes
- **Message ID lookups** — use `$0.id == assistantID`, never instance comparison
- **Engine caching** — LRU with max 3 engines
- **Background downloads** — OS-managed URLSession

---

## Voice Input Architecture

### Audio Pipeline

```
Microphone (Hardware)
    ↓ AVAudioEngine tap (4096 samples @ hardware rate)
    ↓ AVAudioConverter (resample to 16kHz mono Float32)
    ↓
AudioCaptureService.audioChunkPublisher
    ↓
VoiceInputManager
    ├── VadManager.processStreamingChunk() → speech detection
    └── Accumulate samples → AsrManager (Batch) → final text
    ↓
ChatViewModel.inputText
```

### State Machine

```
IDLE → [Mic Tap] → LISTENING (VAD) → [speechStart] → TRANSCRIBING (Recording)
  ↑                                                          │
  └────────────── [Stop / Auto-stop 2s silence] → FINALIZING (Batch ASR) → IDLE
```

### FluidAudio API

- **ASR**: `AsrModels.downloadAndLoad(version: .v3)` → `AsrManager.transcribe(samples)` (batch only, no streaming)
- **VAD**: `VadManager.processStreamingChunk()` — streaming, must preserve `vadState` across chunks
- No partial/streaming transcription — text appears all at once after stop

---

## Model Settings

```swift
struct ModelSettings: Codable {
    var temperature: Float = 0.7
    var maxTokens: Int32 = 120
    var topP: Float = 0.9
    var topK: Int32 = 40
    var repeatPenalty: Float = 1.1
    var systemPrompt: String = ""
}
```

---

## Dependencies

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/AugustDev/SwiftLlama.git", branch: "main"),
    .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9"),
]
```

### Build Requirements

- **Architectures**: arm64 only (x86_64 excluded — FluidAudio requires Apple Neural Engine)
- **Deployment Target**: iOS 17.0+
- **Info.plist**: `NSMicrophoneUsageDescription` required

### Persistence

- Sessions: `ApplicationSupport/chats.json`
- Model manifest: `ApplicationSupport/models.json`
- Model files: `Library/Models/{sanitizedModelID}/`

---

## Common Issues

| Issue | Fix |
|-------|-----|
| Model not loading | Check `Library/Models/` path. ManifestStore handles container migration but file must exist |
| Audio capture fails on simulator | Simulator has no microphone — test voice on physical device |
| Download completes but model not selectable | `DownloadService` must move temp file → `ModelManager.finalizeDownload` → `ManifestStore.add` chain |
| Engine memory pressure | ASR ~500MB + LLM 2-4GB. Max 3 cached engines. Monitor Xcode Memory Graph |
| "Model not found" after re-install | Container paths change. `ManifestEntry.init(from:)` attempts path migration via `/Library/` extraction |
| Wrong prompt format | `ModelPromptType.detect(from:)` — check filename contains model family keyword |
