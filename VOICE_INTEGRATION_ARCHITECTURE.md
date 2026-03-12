# Voice Integration Architecture (As Implemented)
## Q2 Edge Chat → TCCC.ai Medical Scribe Foundation

**Target Device**: iPhone 17 Pro (12GB VRAM)
**Execution Mode**: Fully Offline / On-Device
**Language**: English Only (optimized) / Multilingual (supported)

---

## Executive Summary

This document describes the implemented architecture for voice capabilities in Q2 Edge Chat using the `FluidAudio` SDK. Due to API availability in the current version of FluidAudio, the implementation uses a **Hybrid Approach**:
1.  **Streaming VAD**: Real-time Voice Activity Detection (VAD) monitors microphone input to detect start/end of speech.
2.  **Batch ASR**: Audio is accumulated during the speech segment and transcribed in a single batch operation upon completion.

This architecture ensures high accuracy and efficient resource usage, although it trades off token-by-token "live" text appearance for higher stability.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Data Flow](#2-data-flow)
3. [Components](#3-components)
4. [State Machine](#4-state-machine)
5. [TCCC.ai Scalability](#5-tcccai-scalability)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    UI Layer (SwiftUI)                       │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ ChatView                                              │  │
│  │  ├── [🎤 Voice Button] (VoiceInputButton)            │  │
│  │  │    Shows: Idle → Pulse → Waveform → Spinner       │  │
│  │  └── DynamicTextEditor (Receives final text)         │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                            ↓ (State Binding)
┌─────────────────────────────────────────────────────────────┐
│                 ViewModel Layer (@MainActor)                │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ ChatViewModel                                         │  │
│  │  ├── Manages voiceState (.listening, .transcribing)   │  │
│  │  └── Handles final transcription injection            │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                            ↓ (Async/Await)
┌─────────────────────────────────────────────────────────────┐
│                 Service Layer (Actors)                      │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ VoiceInputManager (Actor)                             │  │
│  │  ├── AudioCaptureService (AVAudioEngine)              │  │
│  │  ├── VadManager (FluidAudio) - Streaming VAD          │  │
│  │  ├── AsrManager (FluidAudio) - Batch ASR              │  │
│  │  └── Accumulates [Float] samples                      │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Data Flow

### 2.1 Audio Pipeline
1.  **Microphone** captures audio at hardware rate.
2.  **AudioCaptureService** converts input to **16kHz Mono Float32**.
3.  **VoiceInputManager** receives chunks (buffers).
4.  **VAD Processing**:
    *   Each chunk is passed to `VadManager.processStreamingChunk()`.
    *   Speech events (`.speechStart`, `.speechEnd`) trigger state changes.
5.  **Accumulation**: All samples are appended to an in-memory buffer while recording.
6.  **Transcription** (Triggered by Stop/Silence):
    *   `AsrManager.transcribe(accumulatedSamples)` is called.
    *   Final text string is returned and passed to UI.

---

## 3. Components

### 3.1 VoiceInputManager
The central orchestrator.
- **Role**: Coordinates Audio, VAD, and ASR.
- **Key Method**: `processAudioChunk(_ chunk: [Float])`
    - Runs VAD.
    - Updates State (Listening -> Transcribing).
    - Checks Auto-stop timers.
- **Auto-Stop Logic**:
    - If `silenceDuration > 2.0s` AND `speechWasDetected`, stop and transcribe.

### 3.2 FluidAudio Integration

| Component | Usage |
|-----------|-------|
| `VadManager` | **Streaming**. Processes 256ms chunks. Detecting speech updates UI to "transcribing" (Red Waveform). |
| `AsrManager` | **Batch**. Processes entire buffer at once. High speed (~145x RTFx) means users wait <0.5s for result. |
| `AsrModels` | Uses `.v3` (Multilingual) or `.v2` (English). Downloaded on first use (~500MB). |

---

## 4. State Machine

The `VoiceInputState` enum drives the implementation:

```
        ┌─────────────┐
        │    IDLE     │  (Blue Button)
        └──────┬──────┘
               │ Tap
               ▼
        ┌─────────────┐
        │  LISTENING  │  (Pulsing Blue Ring)
        │ (VAD Active)│
        └──────┬──────┘
               │ Speech Detected
               ▼
        ┌─────────────┐
        │ TRANSCRIBING│  (Red Waveform)
        │ (Recording) │
        └──────┬──────┘
               │ Stop / Auto-stop
               ▼
        ┌─────────────┐
        │  FINALIZING │  (Spinner / No Icon)
        │ (Processing)│
        └──────┬──────┘
               │ Result Ready
               ▼
        ┌─────────────┐
        │    IDLE     │  (Text appears in input)
        └─────────────┘
```

---

## 5. TCCC.ai Scalability

This architecture serves as the foundation for the future Medical Scribe.

### 5.1 Speaker Diarization (Future)
Since we have the full audio buffer in `accumulatedSamples`, we can pass this same buffer to `DiarizerManager` before or parallel to ASR.
- **Goal**: Identify "Medic" vs "Patient".
- **Implementation**:
  ```swift
  // Future implementation in stopListening()
  async let transcription = asrManager.transcribe(samples)
  async let diarization = diarizerManager.performCompleteDiarization(samples)
  let (text, segments) = await (transcription, diarization)
  ```

### 5.2 Extended Recording
The current in-memory accumulation works well for chat commands (10-30s). For long-form TCCC encounters (30m+):
- **Change**: Switch from `[Float]` array to writing to a temporary `.wav` file on disk.
- **Benefit**: Reduces RAM usage.
- **FluidAudio**: Supports file-based processing `asrManager.transcribe(fileURL)`.
