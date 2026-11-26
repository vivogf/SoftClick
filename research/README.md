# Research tools

These command line trials were used to find Soft Click's replacement click. They are not part of the app and
are not needed to use it. They were tested only on a MacBook Pro with Apple M5 on macOS 27.2.

```sh
make research          # builds build/soft-click
./build/soft-click --help
```

Quit Soft Click before running a trial: both need control of the stock haptics. `./build/soft-click status`
shows whether stock haptics are on, and `./build/soft-click restore` turns them back on after a crash.
The trial windows use Russian text.

## What we found

- macOS doesn't play the click inside the trackpad firmware. `WindowServer` asks the actuator for
  waveform **2** on press and waveform **1** on release, with a profile option that follows the click pressure
  setting (light, medium, firm = 1, 2, 4). A `ktrace` of the actuator calls showed this.
- Turning off the stock response and playing that same pair from an event tap felt the same as the stock
  click at strength 1.0 in a blind A/B test. Lower strengths feel softer, which is what the app does.
- Single replacement pulses (waveforms 3, 4 and 6) lost every blind comparison against the stock click.
- `ActuationStrength = 0` and changing the firmware press/release reports had no noticeable effect
  on this Mac.

## Compare the traced press/release pair

Run `./build/soft-click compare-pair`. Select A or B with `1` or `2`, then physically
press and release the built-in trackpad in the test area. One side uses the
real system click; the other plays ID 2 on press and ID 1 on release using
the selected click profile. Each round randomizes which side is stock.

First compare at amplitude scale 1.0. ↑ means they feel different and ends
the test; ↓ means they feel the same and unlocks the trial at scale 0.6.
In that trial vote ← A, → B, or ↓ for no preference. Only amplitude scale
changes between trials. To start directly in the 60% round without a
calibration vote, use `./build/soft-click compare-60`.
AppKit event timing and macOS's per-click adaptation
may still differ. The scale is a request, not a measured physical amplitude.
The test needs no sudo, does not write firmware reports, and restores stock
haptics on exit, timeout or Ctrl+C.

## Try the pair across apps

`./build/soft-click global-pair` plays the same press/release pair at scale **0.50**
for 30 seconds in the current login session. Try selecting text or dragging
a file with the built-in trackpad. It passively listens for left, right and
other mouse button presses and releases; it does not intercept, generate or
log input. External mouse clicks and tap-to-click also register, so use only
physical trackpad presses for the trial.

Run from Terminal without sudo. If the listener is unavailable, the program
leaves stock haptics on. macOS may require **Privacy & Security → Input
Monitoring** for Terminal. Stock feedback returns on timeout or Ctrl+C;
after a force quit use `./build/soft-click restore`.

## Native click trial

```sh
make research
./build/soft-click native-test 15 40
```

This changes only the strength bytes in the built-in trackpad's original
press and release reports, by about 40%. Use `20` or omit the last argument
for the original 20% reduction. It does
not turn off stock haptics, play another impulse, or flash firmware.
It is limited to the tested Mac model and macOS build. Try ordinary clicks
during the countdown and again after restoration. Ctrl+C ends the test early.

Run from this directory and don't run other haptic tests at the same time.
If the trial crashes or is force-killed, retain `native-click.backup` and
run `./build/soft-click restore-native` in the same directory. A normal exit
removes the backup after verifying both original reports byte for byte.

## Blind comparison

```sh
make research
./build/soft-click compare
```

In each of three rounds, use `1` / `2` to select A / B and press normally in
the indicated area. Switch and press again as often as you like. After sampling
both, use ← for A, → for B, or ↓ for no preference. One side is the real
stock click; the other uses a custom pulse (waveform 3, 4, or 6 at scale
0.35). The app shuffles the round order and assigns the stock side randomly.
It reveals the mapping after the last vote and prints it to the terminal.
The test lasts up to two minutes. Escape, closing the window, or leaving it
after it has focus ends the test and restores stock haptics.

## Single pulse demo

```sh
make research
./build/soft-click status
./build/soft-click demo 0.35 20
```

Try normal presses inside the window. `0.35` is a waveform scale,
not a measured percentage of the stock click. Try `0.20` or `0.50` to compare.
The demo lasts up to 30 seconds and restores stock haptics on exit or
Ctrl+C, Escape, or closing the window. Don't run several trials at once or
put the Mac to sleep mid-trial.
If the process crashes or is force-killed, use `./build/soft-click restore`.

The window demo needs no extra permissions. For a system-wide experiment,
run `./build/soft-click global 0.35 20` from Terminal. macOS may require Input
Monitoring permission for Terminal. You can also place a finger on the
trackpad and run `./build/soft-click probe 0.35` for a single pulse without a window
or click listener.

The demo can't distinguish physical trackpad presses from tap-to-click or
external mouse clicks. Each can trigger a pulse on the built-in trackpad.
Only the system-wide demo replaces right-click feedback. The haptic controls
use a private macOS framework and may stop working after an OS update.
