# Changelog

Assembled from the history: each entry lists the commits whose tree carried
that version number. Up to 1.9.43 and again from 1.9.50 the bump is a commit
of its own named `Release X`, which is why some entries carry one; in between
the bump travelled inside the change it released.

## Unreleased

- Profiles: a rule can ask whether the CPU is busy, not only whether it is hot.
  Heat lags the work by a minute, and naming an application only covers the
  ones you thought of — "on mains, docked, and running something heavy" is
  what the tab is for and could not be said until now.
- Cooling: the thermal ceiling that releases a pinned fan is only consulted
  when a fan is actually pinned. A curve raises the fan by itself, so the
  reading was bought and thrown away twice a second — and on a machine with no
  usable CPU sensor key that reading is a sweep of every sensor there is.
- The daemon's control loop lets the system choose the exact moment inside a
  fiftieth of a second, so its wake-ups can be shared.
- A comment described a setting that had been folded into another one and said
  the opposite of what the code now does: that all fans follow one sensor.
  They follow their own.
- "Held back for" counted the time it expected to pass rather than the time
  that did. Every reading credited a whole poll interval, including the
  readings taken out of turn when the window opens — twenty-one of those
  inside one second reported forty-two seconds of throttling. A sample is now
  credited with the time since the last one, capped at the interval so that
  the first reading after a night asleep does not claim the night.
- Fixed a data race that has been in the shipped app: opening the settings
  window reads the hardware on the main thread while a tick may already be
  reading it on the telemetry queue. The readers are not stateless — the load
  and network figures each hold the previous sample to subtract from — so what
  is at stake is a corrupted array rather than a stale number. Both paths now
  read on the one queue. `--test-telemetry-race`, run under the thread
  sanitizer, reported it five times in four seconds before and none after.
- The throttle reading asks the system for its dictionary once instead of
  once per field. Three fields meant three trips to configd on every tick,
  each opening a session of its own first: 0.4 ms became 0.1.
- Every SMC read and every SMC write used to ask the chip how big the key is
  and what type it holds, first, as a round trip of its own. The SMC builds
  that table when the machine boots and it does not change, so it is now asked
  once per key. A sweep of the sensors fell from 32 ms to 16, a read of both
  fans from 7 ms to 3, and the daemon's control loop and everything else with
  it.
- The battery no longer opens a connection to the SMC of its own on every
  reading and closes it again. It shares the one the rest of telemetry already
  holds, which is what that type's own note says everything does. The reading
  went from 1.8 ms to 1.0 — it was the most expensive thing in a tick, above
  the sensors.
- Cooling: the root daemon's control loop stopped doing the same work twice.
  It read each fan, then `setManual` read it again, then asked the SMC what
  byte layout the target key wants — every half-second, for as long as a fan
  was under our control. It also wrote a target the fan was already holding.
  At about 0.8 ms per SMC round trip on this machine that was roughly 19 ms of
  every tick; the steady state is now about a third of that.
- Sensors: a sensor that is asleep when the app starts is no longer lost for
  the rest of the session. The list of keys was filtered by plausibility once,
  so a discrete GPU that happened to be parked at launch could never be read
  again; believability is now decided on each refresh instead.
- `--dump-smc` lists the sensors that are asleep or out of range instead of
  hiding them, which is what you need when a temperature you expected is
  missing.
- Cooling: the GPU temperature is looked up through a preference list the way
  the CPU's already was. One key each way meant a dash on any machine that
  spells the discrete sensor differently.
- Sensors: TC1C through TC8C and TCMX are named rather than shown as
  themselves. The other unnamed keys are left alone — a wrong label reads
  worse than a raw one.
- Five repeating timers now carry a tolerance, so the system can line their
  wake-ups up with whatever else is waking.
- The disk image carries a note about the first-launch refusal, and the README
  has an install path for someone who downloaded it rather than built it.
- Eight releases that shipped without a changelog entry have one.

## 1.9.57 — 2026-08-28
- Build the release image with a script rather than by hand (`9176004`)

## 1.9.56 — 2026-08-28
- Display: screens with no cable behind them (`7e6b595`)

## 1.9.55 — 2026-08-28
- Pointer: tell the mice apart (`ffcb008`)

## 1.9.54 — 2026-08-28
- Cooling: read the clock the CPU is actually running at (`4c1d805`)

## 1.9.53 — 2026-08-28
- Cooling: show the temperature of the GPU that is doing the work (`9e89580`)

## 1.9.52 — 2026-08-28
- Cooling: fixed fan speeds in revolutions; Display: a poll rate for each screen (`647b1b4`)

## 1.9.51 — 2026-08-28
- Split Power into two tabs — Turbo Boost and Power limit (`9874cc0`)

## 1.9.50 — 2026-08-28
- Bring the repository up to what the application became (`7e860d4`)

## 1.9.49 — 2026-08-28
- Display: font smoothing, which Big Sur stopped showing (`35895ff`)

## 1.9.48 — 2026-08-28
- Display: stop offering squares a screen cannot occupy (`15f6d74`)

## 1.9.47 — 2026-08-28
- Icon: the name, drawn (`ba12fac`)
- Write down the install path that actually gets used (`29621bc`)
- Probe: record every field, rather than the ones I guessed (`cc3a41e`)

## 1.9.46 — 2026-08-28
- Pointer: give the wheel the glide the trackpad already has (`a6ad419`)

## 1.9.45 — 2026-08-28
- Pointer: scroll speed, and rules that follow the application (`b10ff64`)

## 1.9.44 — 2026-08-28
- Keyboard: rules that can notice a modifier (`4455ea3`)

## 1.9.43 — 2026-08-28
- Version bump only.

## 1.9.42 — 2026-08-28
- A sensor per fan, and a flow that moves (`2ceaa34`)
- What is actually costing something (`0a829b6`)

## 1.9.41 — 2026-08-28
- Hold the charger off while the cell is hot, and colour a temperature that matters (`23df092`)

## 1.9.40 — 2026-08-28
- Take out the control that left a Mac with no picture (`f71f9fc`)

## 1.9.39 — 2026-08-28
- A second pair of eyes for the one case nobody can rehearse (`e29da7b`)

## 1.9.38 — 2026-08-28
- Twelve in a row, and twelve standing up (`980ffa5`)

## 1.9.37 — 2026-08-28
- Size the grid by the screens attached, not by the machine I happened to test on (`f7821bc`)

## 1.9.36 — 2026-08-28
- The grid grows and shrinks around what is on it (`bce02b2`)

## 1.9.35 — 2026-08-28
- Arrange the screens on a grid instead of dragging rectangles until they touch (`797c623`)

## 1.9.34 — 2026-08-28
- A screen that is off should be dark, and should stay off (`8a663d4`)

## 1.9.33 — 2026-08-28
- Switching a screen off: make it stay off, and put the windows back after (`81fed04`)

## 1.9.32 — 2026-08-28
- Call a display what the display calls itself (`6a367b8`)
- Take the rest of the display and graphics tools, not just their headlines (`0297bd9`)

## 1.9.31 — 2026-08-27
- Diagnostics: the drive's own health, what is holding sleep off, and what starts by itself (`36af3b9`)
- Five corrections from review (`05f571c`)
- Stop reading everything for a window nobody can see (`bbcbc64`)
- Battery temperature, a third time, checked against something this time (`e309695`)
- Polled reads once when it needs to, and announces only real changes (`4a29e59`)
- One place for the registry moves, and stop re-learning constants (`a97b852`)
- Each part says what it costs, instead of telemetry guessing for all of them (`1aa00fb`)
- Poll what a tab shows while that tab is open, and one heading for all of them (`e3485ee`)
- Assertion names written out, like their neighbour already does (`c27ed57`)

## 1.9.30 — 2026-08-27
- Square the power-flow diagram in the terminal theme (`332d725`)

## 1.9.29 — 2026-08-27
- Take 50 points back off the window (`1795f27`)

## 1.9.28 — 2026-08-27
- The one size is 960 × 520, and a remembered frame no longer overrides it (`378f749`)

## 1.9.27 — 2026-08-27
- One window size, and a scrollbar only where there is something to scroll (`94f1e6a`)

## 1.9.26 — 2026-08-27
- The name signs off at the foot of Settings instead of arguing with the title (`2fc6453`)

## 1.9.25 — 2026-08-27
- No scrollbars, no resize handle: the window is the size of what is in it (`3c85a1c`)

## 1.9.24 — 2026-08-27
- Put the section's name on the same line as the window's (`c75c932`)

## 1.9.23 — 2026-08-27
- Two items in the menu, Profiles under Settings, and the band of nothing goes (`a848354`)

## 1.9.22 — 2026-08-27
- THR ends in the speed being allowed, not a dash (`c87edce`)

## 1.9.21 — 2026-08-27
- Fix the drop-down menus, which had become a column of "[" (`517a3cd`)

## 1.9.20 — 2026-08-27
- The heading is the switch, and the readings absorb what was only ever a readout (`0a2a722`)

## 1.9.19 — 2026-08-27
- Lower the window buttons, stop the sidebar sliding, and a way to look at both (`f96fafc`)

## 1.9.18 — 2026-08-27
- Alignment, Darkness, and a sidebar that stops sliding about (`2e11c42`)

## 1.9.17 — 2026-08-27
- Both fans at once, in percent (`77e6f47`)

## 1.9.16 — 2026-08-27
- Terminal controls, so the theme is one thing rather than two (`03850a3`)

## 1.9.15 — 2026-08-27
- Terminal means terminal: one face everywhere, and no grey strip above it (`75c6fb3`)

## 1.9.14 — 2026-08-27
- A choice of window layout, network speed, a curve sensor, and one display at a time (`66e7253`)

## 1.9.13 — 2026-08-26
- Fill the battery pill properly, and stop labelling a unit with itself (`fb53391`)

## 1.9.12 — 2026-08-26
- Size the battery digits from the pill, and pin the pill to one width (`8a79e21`)

## 1.9.11 — 2026-08-26
- Actually add the appearance picker, which was never there (`3690d6d`)
- Fix captions vanishing all at once, and make the watts field say something (`07cba60`)

## 1.9.10 — 2026-08-26
- Keep two invented directions, and let the shipping window speak for itself (`6154cbe`)

## 1.9.9 — 2026-08-26
- Add a whole-application design sheet prompt (`8caf877`)
- Add a light/system/dark choice, and thin the slider marks to sixteen (`b756525`)
- Caption each menu-bar field on its own, and stop the percent sign paying rent (`7a96b91`)

## 1.9.8 — 2026-08-26
- Add design prompts for the 2.0 look (`3b5bba6`)
- Add sidebar layout prompts and a consolidation proposal (`b32de30`)
- Add the real Cooling content for design renders (`a8690e1`)
- Rewrite the three surviving directions with the sidebar enforced (`52adfeb`)
- Build the 2.0 look as a working prototype instead of arguing with a generator (`379f3bb`)
- Add the status block prototype and a prompt for its variations (`1e399ea`)
- Never let a display change strand the machine, and show the whole reading (`77a6430`)

## 1.9.7 — 2026-08-26
- Put the power limit back after a wake, now that it is proven to work (`6837c5c`)

## 1.9.6 — 2026-08-26
- Say when the helper is refusing us, instead of going quiet (`c7a4e44`)

## 1.9.5 — 2026-08-26
- Say where the Allow button is when macOS refuses to load the extension (`2ff4fe7`)
- Stop the Power tab dying on a CPU that reports no power range (`e644089`)

## 1.9.4 — 2026-08-26
- Version bump only.

## 1.9.3 — 2026-08-26
- Draw the whole status item, and stop deleting a kext that only needed a restart (`0bf543b`)

## 1.9.2 — 2026-08-26
- Hang the load bars from the top, and tell people how to enable the power limit (`841af80`)

## 1.9.1 — 2026-08-26
- Draw the battery the way iOS 27 does, and stop the Menu Bar tab hiding the tabs (`dcc1296`)

## 1.9.0 — 2026-08-26
- Fix the sign on battery power, stop one menu-bar drawing eating the other (`b854f88`)

## 1.8.0 — 2026-08-26
- Give every mouse and keyboard settings of its own (`6e987ee`)

## 1.7.2 — 2026-08-26
- Let the menu bar show what you actually want to watch (`6fe57f0`)

## 1.7.1 — 2026-08-26
- Add regression checks that read the shipped code, and make the build run them (`fb8f219`)

## 1.7.0 — 2026-08-25
- Stop the settings window taking seventeen seconds to appear (`fe7ba17`)

## 1.6.1 — 2026-08-25
- Fix the power kext refusing to load, and take the write off the open sysctl (`e2b8f3e`)
- Let the values in a profile actually be changed (`acbbbb0`)

## 1.6.0 — 2026-08-25
- Version bump only.

## 1.5.0 — 2026-08-25
- Add rules that set several things at once, displays, and the power limit (`3d49900`)

## 1.4.0 — 2026-08-25
- Swap keys below the window server, and share one HID client between features (`ccb7a97`)

## 1.3.0 — 2026-08-25
- Move every function behind its own switch, in a window built for nine of them (`361ded5`)
- Give the mouse and the trackpad separate answers about scrolling (`4fd06a3`)

## 1.2.0 — 2026-08-25
- Report power draw, wear and what the throttling monitor has seen (`a04b59e`)

## 1.1.0 — 2026-08-25
- Add a throttling monitor and a battery charge ceiling (`4db01a6`)
- Document the throttling monitor and the charge ceiling (`c116b36`)

## 1.0.0 — 2026-08-19
- Zephyr — menu-bar fan, GPU & Turbo Boost control for Intel Macs (`a869adc`)
- XPC auth: resolve client via audit token, not PID (`4a17905`)
- Bundle the helper installer inside the app (`cd568ad`)
- Fix the paths that fail open instead of restoring firmware control (`75d85f3`)
- Re-apply the Turbo disable after wake (`2c020ab`)
