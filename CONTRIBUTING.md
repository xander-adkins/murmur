# Contributing

Thanks for taking a look. Murmur is a small, focused tool; contributions that keep it that
way are the most welcome.

## Development setup

- macOS 26 or newer for the on-device `SpeechAnalyzer` engine (macOS 13–15 builds too, using the
  legacy `SFSpeechRecognizer` path).
- Xcode 26 or the matching Command Line Tools. The tests use swift-testing, which the toolchain
  ships; XCTest is not required.

```sh
swift build            # library + CLI
scripts/test.sh        # unit tests, no hardware needed (see Tests below for why not bare swift test)
./build.sh             # release build + Murmur.app
./install.sh           # build, copy to ~/Applications, launch
```

## Tests

- Pure logic gets a plain `@Suite struct`; these run in parallel.
- Anything that touches `Settings.environment` or `Settings.defaults` goes under the serialized
  `GlobalState` parent suite (see `SettingsTests.swift`) so suites cannot interleave.
- The push-to-talk flow is tested through `SpeechDictationController(engineFactory:isMicrophoneAuthorized:)`
  with `FakeEngine`; add flow cases there rather than reaching for hardware.
- Run tests with `scripts/test.sh`, not bare `swift test`. With the Command Line Tools toolchain,
  SwiftPM serves the swift-testing macros from an in-process plugin server that fails roughly half
  the time with "plugin for module 'TestingMacros' not found" on every `@Test`/`#expect`. The
  script passes the toolchain's out-of-process `swift-plugin-server` explicitly, which is reliable.
  Extra arguments pass through (`scripts/test.sh --filter DictationMachineTests`).

## Testing without a remote

The whole dictation pipeline can run from a simulated press, logging the transcript instead of
pasting it. Speak, or let the Mac speak:

```sh
MURMUR_PASSIVE=1 MURMUR_DRY_RUN=1 MURMUR_SIMULATE_PTT=6 .build/release/murmur &
sleep 5; say "Testing one two three"
```

Never test without `MURMUR_DRY_RUN=1` unless you want the transcript pasted and sent into whatever
window is focused.

## What goes where

See `docs/ARCHITECTURE.md`. The short version: decisions live in value types with tests
(`DictationMachine`, `GraphReusePolicy`, `TranscriptAssembler`, `RemoteButton`, `Settings`
resolution); the classes that touch IOKit, CoreAudio, Speech and AppKit execute those decisions
and log everything they do.

## Pull requests

- Keep the log lines. They are how users (and you) debug a silent failure on someone else's Mac.
- Anything that opens the microphone, posts keystrokes, or reads input devices must stay
  behind an explicit user action or a documented setting.
- No keystroke logging, ever. The log records the remote's buttons and your transcripts, nothing
  typed on the keyboard.
- Run `scripts/test.sh` and the simulated press before opening the PR.
