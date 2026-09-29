# Diagnostics

Normal use needs none of this: pair the remote in System Settings and Murmur reads it over HID.
These switches exist for when button delivery misbehaves, and for mapping new buttons.

## Reading the log

```sh
tail -f ~/Library/Logs/Murmur.log
```

A healthy press looks like:

```text
[HID] input ... button=siri ... value=1
[Dictation] SpeechAnalyzer listening… (engine ready 0ms after press)
[Audio] graph reused in 0ms, mic opened in 1ms (24000Hz x1)
[Dictation] capturing from AirPods (default), on-device after 18ms
[Dictation] partial=hello
[HID] input ... button=siri ... value=0
[Dictation] released after 2.1s; finalizing
[Dictation] fed 2.0s of audio
[Dictation] finalized (results finished)
[Dictation] transcript=Hello.
[Insert] pasted 6 characters
[Insert] pressed Return
```

What each missing line means:

| Missing | Cause |
| --- | --- |
| No `[HID] input` at all | Remote not paired, asleep, or Input Monitoring not granted (`[HID] opened remote` lines are the tell). |
| `capturing from …` but empty `transcript=` | The mic heard nothing. On AirPods, takes shorter than ~2 s lose the first second to headset-mode wake-up; enable *Keep Microphone Warm*. |
| `transcript=` but no `[Insert]` | Accessibility not granted; the app leaves the text on the clipboard and says so in the menu bar. |
| `Accessibility permission missing` right after a rebuild | The grant was bound to an older signature. `tccutil reset Accessibility <bundle id>`, relaunch, grant again. Use `scripts/make-signing-identity.sh` so it stops happening. |

## Environment switches

```sh
MURMUR_PASSIVE=1        # list remote HID interfaces but do not open them
MURMUR_SEIZE=1          # open the remote exclusively instead of shared with the system
MURMUR_RAW_REPORTS=1    # log raw HID input reports (mapping new buttons, touch surface)
MURMUR_STDOUT=0         # log to the file only
```

A remote that pairs but sends no events is almost always a permission problem, not a Bluetooth one.
Direct GATT access to an unpaired Siri Remote is rejected before macOS bonds it, so there is no
app-level workaround for pairing; the Bluetooth settings pane is the only path.

## Testing without the remote

```sh
MURMUR_PASSIVE=1 MURMUR_DRY_RUN=1 MURMUR_SIMULATE_PTT=6 ./run.sh
```

simulates a six-second Siri press four seconds after launch and logs the transcript instead of
pasting it. Speak into the Mac, or `say "testing one two three"` from another terminal.
