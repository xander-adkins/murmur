# Architecture

Murmur turns a paired Siri Remote into a push-to-talk button for terminal coding agents.
Hold Siri, talk, release: the transcript is pasted into the focused terminal and Return is pressed.

## Data flow

```
  Siri Remote                         Mac
 ┌───────────┐   Bluetooth LE HID   ┌───────────────────────────────────────────────────────────┐
 │  [Siri]   │ ───────────────────▶ │ HIDMonitor          usagePage 0x0C / usage 0x04           │
 │  hold…    │   press / release    │   └─▶ RemoteController.dispatchButton(.siri, isPressed)   │
 └───────────┘                      │           │                                               │
      remote mic: not reachable     │           ▼                                               │
      from macOS (Apple TV only)    │ SpeechDictationController                                 │
                                    │   press ──▶ take prewarmed AnalyzerEngine                  │
                                    │             (SpeechAnalyzer session already started,      │
                                    │              audio graph already built)                   │
                                    │             open mic ──────────────────┐                  │
                                    │                                        ▼                  │
 ┌───────────┐  Bluetooth HFP       │ AudioCapture (AVAudioEngine)                              │
 │  AirPods  │ ──── ~1 s wake ────▶ │   input tap ──▶ AudioFeeder (render thread) ──▶ converter │
 │  (mic at  │   unless kept warm   │                     to the analyzer's preferred format     │
 │   mouth)  │                      │                                        ▼                  │
 └───────────┘                      │ SpeechAnalyzer + SpeechTranscriber (on-device model)      │
   or MacBook mic (no wake delay)   │   volatile/final results ──▶ TranscriptAssembler          │
                                    │                                                           │
                                    │   release ──▶ stop mic, finalizeAndFinishThroughEndOfInput│
                                    │               wait for the results stream to end (≤5 s)   │
                                    │                                        │                  │
                                    │                                        ▼                  │
                                    │ DictationMachine.finish (pure)                            │
                                    │   Accessibility trusted? ─ no ─▶ clipboard only + warning │
                                    │   yes ─▶ .insert(text, via: paste|type, then: Return)     │
                                    │                                        ▼                  │
                                    │ TextInserter executes exactly that effect                 │
                                    │   clipboard ← transcript, Cmd-V, 300 ms, Return, restore  │
                                    │                                                           │
                                    │ MenuBarAppDelegate: waveform → red mic → bubble → check   │
                                    │ Menu while holding Siri ──▶ cancel take, nothing sent     │
                                    │ next AnalyzerEngine prewarmed for the next press          │
                                    └───────────────────────────────────────────────────────────┘
```

## Modules

| File | Role |
| --- | --- |
| `MurmurApp` | Process entry: menu bar app when launched from a bundle, CLI otherwise. |
| `RemoteController` | Owns the pieces below, starts/stops them, routes button events. |
| `HIDMonitor` / `RemoteIdentity` | Finds Siri Remote HID interfaces through IOHIDManager and decodes usages. |
| `RemoteButton` | The button enum everything else switches on, decoded from HID usages. |
| `DictationMachine` (+ `DictationFailure`, `DictationState`, `DictationEvent`, `DictationEffect`, `DictationContext`) | Pure push-to-talk state machine: `(phase, event) → (phase, [effect])`. Every transition has a test; an exhaustive walk pins the invariants. |
| `SpeechDictationController` | The shell around the machine: snapshots context, feeds events, executes effects (engines, clipboard, keystrokes). Owns engine choice and the prewarmed session. |
| `Permissions` | Record of permission checks and prompts; `.live` in the app, `.granted` in tests. |
| `GraphReusePolicy` / `InputSelection` | Pure: may a pre-built audio graph serve the next take? Compares the *resolved* device binding. |
| `AnalyzerEngine` (macOS 26+) | `SpeechAnalyzer`/`SpeechTranscriber` session with a single lifecycle value; on-device, no length limit. |
| `AudioFeeder` | The only object the audio render thread touches: format conversion and lock-guarded counters. |
| `LegacyRecognizerEngine` | `SFSpeechRecognizer` fallback for macOS 13–15 or unsupported locales. |
| `TranscriptAssembler` | Pure: merges volatile and final results into one string. |
| `AudioCapture` | One AVAudioEngine session per take; graph pre-built between takes; device selection. |
| `MicrophoneWarmer` | Optional silent input stream that keeps Bluetooth headsets in headset mode. Its state is a sum type, so "off" cancels a pending retry. |
| `AudioDeviceProbe` | CoreAudio input device listing and lookup. |
| `TextInserter` / `KeyEvents` | Execute an `insert` effect exactly as specified: paste or type, press Return, restore the clipboard. Reads no settings. |
| `TerminalControl` | Other buttons → keystrokes (Esc, Ctrl-C, Return, arrows). |
| `MenuBarAppDelegate` | Status item, toggles, microphone picker, launch at login. |
| `Settings` | Environment → UserDefaults → default. Injectable for tests. |
| `Support` | `OneShotCompletion` (release → exactly one transcript, or a timeout), small `Date`/`String` helpers. |
| `Logging` | `log(.topic, …)`: typed subsystem prefixes over one append-only file. |

## Timing

Measured on an M4 Pro with the mic kept warm: **~18 ms** from the HID event to audio flowing.
Without keep-warm the graph is still pre-built (~20 ms) but AirPods add roughly a second of their
own before delivering sound, which is a Bluetooth headset-mode switch nothing on the Mac can
shorten. The MacBook microphone has no such delay.

## Permissions

| Permission | Needed by | Failure mode without it |
| --- | --- | --- |
| Input Monitoring | `IOHIDDeviceOpen` on the remote | Remote found but no button events |
| Accessibility | `CGEvent.post` | Transcript transcribed, keystrokes silently dropped; the machine reports it and leaves the text on the clipboard |
| Microphone | `AVAudioEngine` | No audio |
| Speech Recognition | legacy engine only | Legacy engine refuses to start |

macOS ties these grants to the app's code-signing identity. An ad-hoc signature changes on every
build, so `scripts/make-signing-identity.sh` creates a self-signed certificate that `build.sh`
uses automatically; grants then survive rebuilds.

## Design notes

- **Everything logs.** `~/Library/Logs/Murmur.log` is the debugging surface: press, capture
  device and latency, every partial hypothesis, the final transcript, and what was done with it.
- **Engines are sessions.** One `AnalyzerEngine` per take; the next one is created and started
  while the current transcript is being delivered, so a press never waits for model setup.
- **Uncatchable failures are avoided, not caught.** CoreAudio raises Objective-C exceptions for a
  stale audio graph; `AudioCapture` invalidates the pre-built graph on configuration changes and
  checks the hardware format before starting.
- **Pure where it matters.** Button decoding, transcript assembly, settings resolution and the
  graph-reuse policy are value types with tests; the hardware-facing classes stay thin.
- **No dead ends kept.** The lab-phase Bluetooth scanning, direct-connect attempts, feature-report
  probing for the remote's microphone and the keystroke-logging event tap were removed once they
  had answered their questions (pair through macOS; the mic is not reachable). They live in git
  history, not in the build.
- **Decide in values, act in the shell.** `DictationMachine` never touches the world: it takes
  an event plus a `DictationContext` snapshot and returns the new phase and an ordered list of
  `DictationEffect`s. `SpeechDictationController` executes them. Tests assert exact effect lists
  for every transition (`DictationMachineTests`) and, separately, that the shell interprets them
  correctly against a `FakeEngine` (`DictationFlowTests`). `TranscriptionEngine` is the seam.

  ```
  event ──▶ DictationMachine.handle(event, context) ──▶ [effects] ──▶ shell.perform(effect)
              pure, Equatable, exhaustively switched          beginEngine / insert / report / …
  ```
- **Menus are data.** Each checkbox in the menu bar is a `SettingToggle` (title, read, write,
  enabled-when, after-change); one action handles all of them. The button-mapping submenu and the
  log line both render `TerminalControl.keyMapping`.
- **Threads own their state.** The audio render thread only ever sees an `AudioFeeder`, whose
  mutable fields it alone touches; counters cross to the main thread under a lock. Everything else
  runs on the main run loop, which is what makes the synchronous effect interpreter safe.
- **Nothing outlives `stop()`.** Start and stop bump a generation counter; async callbacks from a
  previous run are dropped, and effects that would create work (prewarm, warmer) check `isStarted`.
