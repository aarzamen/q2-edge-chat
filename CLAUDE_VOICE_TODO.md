# Voice Integration TODO for Claude Code Agent

## Status: COMPLETED

FluidAudio integration has been completed with architectural changes from the original plan.

---

## Important: API Changes from Original Plan

The original TODO assumed a `StreamingAsrManager` API that **does not exist** in FluidAudio. The actual FluidAudio API provides:

| Original TODO Assumed | Actual FluidAudio API |
|----------------------|----------------------|
| `StreamingAsrManager` | `AsrManager` (batch only) |
| `asr.start(models:, source:)` | `asrManager.transcribe(samples)` |
| `asr.transcriptionUpdates` AsyncStream | No streaming - batch returns final result |
| `asr.streamAudio(buffer)` | Not available |
| `asr.finish() -> String` | Not available (batch is immediate) |
| Real-time partial transcription | Only final transcription on stop |

**VAD streaming works as documented** - `VadManager.processStreamingChunk()` is correct.

---

## Completed Implementation

### Architecture: Batch ASR with Streaming VAD

```
Microphone → AudioCaptureService → VoiceInputManager → ChatViewModel → ChatView
               (16kHz mono)         (VAD + ASR)        (state binding)   (UI)

Flow:
1. User taps mic button
2. Audio capture starts, samples accumulate
3. VAD streaming detects speech start → state: .transcribing
4. VAD detects silence → start silence timer
5. After 2s silence (auto-stop) OR user taps button:
   - Stop audio capture
   - Batch transcribe accumulated samples
   - Publish result via transcriptionCompleted
   - Reset to idle state
```

### Files Modified

| File | Changes |
|------|---------|
| `project.pbxproj` | Added FluidAudio SPM dependency (correct URL: FluidInference/FluidAudio) |
| `VoiceInputManager.swift` | Complete rewrite for batch ASR + streaming VAD |
| `ChatViewModel.swift` | Added `transcriptionCompleted` subscription for auto-stop handling |

### Key Implementation Details

**VoiceInputManager.swift:**
- Uses `AsrModels.downloadAndLoad(version: .v3)` for multilingual support
- Uses `AsrManager` for batch transcription
- Uses `VadManager.processStreamingChunk()` for real-time speech detection
- Accumulates audio samples during recording
- Publishes result via `transcriptionCompleted` publisher
- Auto-stops after 2 seconds of silence (configurable)

**ChatViewModel.swift:**
- Subscribes to `transcriptionCompleted` publisher
- Handles both manual stop and auto-stop scenarios
- Appends transcription to input field

---

## UX Differences from Original Plan

| Original Plan | Actual Implementation |
|--------------|----------------------|
| Live transcription text while speaking | No live text - only final result |
| Partial results shown in overlay | Status only (listening → transcribing → finalizing) |
| Real-time word appearance | Text appears all at once after stop |

The visual feedback (button animations, state changes) still provides good UX:
- Blue pulsing = listening for speech
- Red waveform = speech detected, recording
- Gray spinner = processing transcription
- Text appears in input field when done

---

## Build Status

- **Compiles**: Yes, zero errors
- **Simulator**: iPhone 16 (iOS 18.3) - builds successfully
- **FluidAudio Version**: 0.7.9+

---

## Testing Checklist

### Basic Flow Test
- [ ] Run app on **physical device** (simulator has no microphone)
- [ ] Tap mic button → should see permission prompt (first time)
- [ ] Grant permission → button should pulse (listening state)
- [ ] Speak → button should show waveform (transcribing state)
- [ ] Stop speaking → auto-stop after 2s silence
- [ ] Text should appear in input field

### Edge Cases
- [ ] Deny mic permission → should show error state
- [ ] Phone call interruption → should pause gracefully
- [ ] Bluetooth headset → should route audio correctly
- [ ] Cancel button → should stop without sending
- [ ] Manual stop (tap while recording) → should transcribe immediately

---

## Configuration

### VoiceInputConfig Defaults
```swift
vadThreshold: 0.75        // Speech probability threshold
minSpeechDuration: 0.25   // Ignore brief sounds (250ms)
minSilenceDuration: 0.5   // Pause detection (500ms)
maxSpeechDuration: 30.0   // Force stop after 30s
autoStopSilenceDuration: 2.0  // Auto-send after 2s silence
```

### For Medical Scribe (TCCC.ai)
```swift
VoiceInputConfig.medical:
vadThreshold: 0.7         // More sensitive for quiet speech
minSilenceDuration: 0.8   // Longer pauses in medical dictation
maxSpeechDuration: 60.0   // Longer recordings
autoStopSilenceDuration: 3.0  // More patience before auto-stop
```

---

## FluidAudio API Reference (Actual)

### ASR (Batch)
```swift
// Load models (~500MB download on first use)
let asrModels = try await AsrModels.downloadAndLoad(version: .v3) // multilingual
// or .v2 for English-only

// Initialize manager
let asrManager = AsrManager(config: .default)
try await asrManager.initialize(models: asrModels)

// Transcribe (batch)
let result = try await asrManager.transcribe(samples, source: .microphone)
print(result.text)
```

### VAD (Streaming)
```swift
let vadManager = try await VadManager()
var vadState = await vadManager.makeStreamState()

// Process each audio chunk
let result = try await vadManager.processStreamingChunk(
    chunk,
    state: vadState,
    config: VadSegmentationConfig(...),
    returnSeconds: true,
    timeResolution: 2
)

// CRITICAL: Update state for next chunk
vadState = result.state

// Check speech events
if let event = result.event {
    switch event.kind {
    case .speechStart: // Speech began
    case .speechEnd:   // Speech ended
    }
}

// Check probability
if result.probability > threshold { /* speech detected */ }
```

---

## Future Improvements

1. **Model Download Progress**: Show progress UI during first-time model download (~500MB)
2. **Streaming ASR**: If FluidAudio adds streaming support in future, update implementation
3. **Speaker Diarization**: Add `DiarizerManager` for TCCC.ai medical scribe feature
4. **Error Recovery**: Add retry logic for transient ASR failures
