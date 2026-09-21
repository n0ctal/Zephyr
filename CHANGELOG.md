# Changelog

Assembled from the history: each entry lists the commits whose tree carried
that version number. Up to 1.9.43 and again from 1.9.50 the bump is a commit
of its own named `Release X`, which is why some entries carry one; in between
the bump travelled inside the change it released.

## Unreleased

- The settings window can tell the menu bar it changed something. Until now a
  choice made there reached the process that acts on it when the window closed
  and not before: dragging the scroll speed did nothing you could feel, and the
  graphics watchdog spent five seconds arguing with a mode the window had just
  set. The window announces every write it makes and the menu bar re-reads. It
  carries no payload — preferences are the message and this is only the knock,
  which is also why a knock that goes missing costs a late reading rather than
  a wrong one. Coalesced at a tenth of a second, because a slider writes on
  every frame, and held only while the window exists, because nothing else can
  send one.
- One rule now says which process may touch the machine, and four things that
  were quietly broken by not having it are fixed. What a process *holds*, it
  loses when it ends — an event tap, a power assertion, a gamma table, a
  virtual screen — and the settings window ends every time it is closed, so
  dimming chosen there vanished with it and "keep this Mac awake" lasted as
  long as somebody was looking at the switch. What a process *re-asserts*, it
  duplicates — the graphics watchdog, the battery's heat timer, the profile
  engine and the pointer's device watch all write on a timer, and two of each
  is two writers arguing over one setting. The window shows and edits; the menu
  bar owns.
- Dimming below the panel's minimum is remembered. It has to be, because the
  process that sets the gamma is no longer the one that is asked for it. Which
  means it now lasts until it is changed rather than until the session ends;
  switching the Display feature off still clears it, as it clears everything
  else of ours.
- Reloading a feature's settings applies what changed and only what changed. A
  fan speed chosen in the window never reached the fans, because the mode was
  loaded before the values it applies. And anything reloaded unchanged was
  applied again, which restarted a timed Awake from the beginning and
  re-asserted a profile nobody had touched.

- Known, and not yet decided: dimming a screen below its hardware minimum is
  lost when the settings window closes. It is done by writing a gamma table,
  and macOS restores the gamma when the process that set it exits — which the
  settings window now does. Nothing can put it back, because the level is only
  ever held in memory. Virtual screens and the sleep assertion recover on their
  own, because what they are made of *is* written down.

- The settings window runs in a process of its own. Opening one is permanent:
  SwiftUI, Metal, CoreML and Vision load when a window first draws and a dylib
  cannot be unloaded, so a menu-bar process that has ever shown the window
  carries about twelve megabytes and half a percent of a core for the rest of
  the session. Measured on the owner's machine, which is where the gap showed
  up — 0.5 % of a core and 20 MB against the 0.077 % and 7 MB reported from a
  process whose window had never been opened. "Options…" now launches the same
  binary with `--settings-window`, which builds everything except the status
  item and quits when the window closes. After: 0.067 % of a core, four
  threads and no rendering at all in the process that stays.
- The daemon returns the fans to the firmware when the *last* authorised
  connection drops, not when any one does. Two processes means the second one
  ends every time its window closes, and restoring on any drop would have
  handed back a manual fan hold the first one was still keeping. The guarantee
  is unchanged — fans held by a process that no longer exists is still an empty
  set — at the cost that an app which crashes with its settings window open
  keeps the hold until that window closes too.
- The settings window is released when it closes rather than kept for the next
  time. Worth about a sixth of the cost of having opened it; none of the
  memory, which belongs to the frameworks.
- The charge is read when IOKit says it moved. The battery node raises general
  interest on a strict sixty-second cycle — which is how often the gauge behind
  it is read at all — so asking once a second was fifty-nine questions with the
  same answer. A fifteen-second floor stays under it: a notification is a
  mechanism without memory, and a missed edge would otherwise leave a wrong
  number up for the rest of the session.

- Idle cost is down about three times again, and about fifteen times against
  1.9.57. A sample of the running app found its entire main-thread cost inside
  a drawing that was thrown away: the line was composed first and compared
  afterwards, so every tick that changed nothing still paid for an offscreen
  bitmap nobody saw. The line is now planned — values and signature, no
  pixels — and drawn only when the plan is new. 163 us a tick to 17.
- The battery is read at the size it is being looked at. One reading served
  everything, so a menu bar with a battery icon in it paid once a second for
  health, cycles, capacities, temperature, watts and the estimate of the time
  left, none of which is shown outside the window. The charge is four registry
  properties; the rest is ten more and two SMC round trips at about 350 us
  each. 0.76 ms a reading to 0.05.
- And the whole node is no longer serialised to get at them. Asking IOKit for
  an entry's properties hands back all fifty-one, nine of them nested
  structures — the IOReport legend, the telemetry blob, the adapter's details.
  Named fetches instead: 317 us to 110 for the full reading, 35 for the
  charge. The entry itself is kept rather than matched again every tick, and
  released if a reading ever comes back empty.
- The menu bar has lost its own timer. It kept one beside telemetry's, at the
  same rate, waking the machine a second time to redraw what the first wake-up
  had just read. A published reading is the only thing that can change the
  line, so the reading says when — still no faster than the rate set for the
  menu bar, since an open window makes telemetry run at the window's.
- The list of menu-bar fields is decoded once per stored value instead of on
  every tick. It is JSON in user defaults and was allocating a decoder twice a
  second for the life of the process. Keyed on the stored bytes, so it cannot
  go stale whoever writes it next.
- The shipped binary carries no local symbols: 4.5 MB to 2.1, and the bundle
  4.7 to 2.3. Nothing reads them at run time — Swift's metadata, which
  reflection and Codable need, lives elsewhere and is untouched — and the
  unstripped binary stays in the build directory for symbolicating a crash.

- The battery in the menu bar shows a bolt whenever the machine is on mains.
  Colour alone could not say it: green means a battery that is filling, and a
  Mac sitting at 100 % on the charger, or held at a charge limit, is not
  filling — so it looked exactly like one running on battery, which is the
  state this machine is in most of the time. Three states now read apart at a
  glance: no bolt is on battery, bolt and green is charging, bolt and plain is
  on mains and done. It sits inside the pill, to the right of the number, and
  is punched through it the way the digits are. The glyph is the system's own
  `bolt.fill`, which is the shape being compared against; drawing one by hand
  at five pixels across gave something recognisable only once you were told
  what it was. The
  room for it is counted into the pill whether or not it is drawn, so plugging
  the charger in does not drag the rest of the menu bar sideways.

- The menu bar is not redrawn when nothing in it has changed. It was rebuilt
  and handed to the status item twice a second for as long as the app runs,
  and giving `button.image` a fresh image marks the item dirty whether or not
  a pixel differs — while most ticks change nothing, a temperature that has
  not moved or a battery that steps once in several minutes. Each line now
  carries a signature of the values it was drawn from, and an unchanged one is
  left alone. Built from the values rather than the pixels: comparing the
  drawn bytes costs 0.29 ms, more than drawing them.
- The battery is one shape whether or not it shows a number. It was 37 points
  wide with the percentage and 23 without, which at one height reads as two
  different objects rather than one drawn two ways: the short one looks
  rounder and stubbier. The pill is sized for everything it can hold and what
  is absent leaves the middle emptier.
- The three drawing heights come from the menu bar instead of being written
  down as constants. 18 for the strip, 15 for the battery and 14 for the load
  graph were measured against a 22-point bar, and a taller one left them where
  they were. They now follow it, and give back exactly those numbers at 22.
- Text and glyphs are pulled to half-point boundaries. The menu bar draws at
  2×, so a coordinate landing between device pixels costs sharpness on things
  that are mostly small text.

## 1.10.0 — 2026-09-20

One branch of work rather than one change, which is the departure from
everything above it: 1.9.50 through 1.9.57 were a change each. This is fifty-five
commits, and a good half of them fix the other half — twelve rounds of review,
each finding something in what the last one had just written. Bumping per
commit would have produced fifty-five versions most of which corrected their
predecessor, so it is bumped once, here.

Grouped by what it touches rather than by the order the commits landed; the
history has the order.

**Temperature — which sensor is the processor's**

- The CPU temperature no longer changes by eighteen degrees depending on
  whether the settings window is open. Two preference lists disagreed about
  which sensor is the CPU's: the reader fetched TC0P, while the menu bar and
  the profile engine preferred TC0F. With the window shut only TC0P was ever
  read, so the preference could not be honoured — measured at one instant
  during a build, the app said 69 °C while TC0F read 87.2. There is one list
  now, and it is walked when it is asked rather than frozen at launch, so a
  Mac whose best sensor was asleep when the app started is no longer stuck
  with the second-best for the life of the process.
- TCMX is the first choice. It is the register holding the hottest core, and
  it behaves like one: across twelve samples from idle through a build it
  matched the hottest of the eight per-core sensors exactly ten times and read
  2.3 °C above it twice, never below, and it moved the moment the load arrived
  while TC0F was still catching up.
- TC0P is the last resort, and is labelled "CPU Proximity" rather than "CPU".
  It sits beside the package rather than on it and lags badly: 54 °C while the
  hottest core read 94, 69.4 against TC0F's 87.2 later in the same build.
- TCGC is out of the CPU list and TCXC is out of the graphics one. Each is a
  single sensor that was answering under two headings, which is how a Mac
  lacking the other keys came to show its graphics temperature as the
  processor's, and the other way round.
- A sensor that is asleep when the app starts is no longer lost for the rest
  of the session. The list of keys was filtered by plausibility once, so a
  discrete GPU parked at launch could never be read again; believability is
  decided on each refresh instead. On this machine that means fifty keys are
  read and forty-eight answer.
- The GPU temperature is looked up through a preference list the way the CPU's
  already was. One key each way meant a dash on any machine that spells the
  discrete sensor differently.
- TC1C through TC8C and TCMX are named rather than shown as themselves. The
  other unnamed keys are left alone — a wrong label reads worse than a raw one.

**Cooling**

- The thermal release — the ceiling that hands a pinned fan back to the
  firmware — never fired. It compared 90 °C against TC0P, which does not reach
  85 on this machine under any load: the die would have had to pass 120 °C,
  and the machine shuts down before that. It reads the processor now, and it
  has a band rather than a figure: the fan goes back at 95 °C and is not taken
  again until 85. With one threshold the firmware would cool the machine just
  past it, the hold would resume, and the fan would change hands every couple
  of seconds. While a fan is held back this way the daemon reports it as
  "auto", which is what it is.
- That release is only consulted when a fan is actually pinned — a curve
  raises the fan by itself — and only acts on a reading that really came from
  a processor sensor. Whether the machine has one is decided by one having
  answered, not by a name being in the key list, because that list deliberately
  keeps keys which read nothing: a Mac publishing a permanently zero stub
  would otherwise look equipped, produce no reading, be refused the fallback,
  and hold a pinned fan with no ceiling at all. Where there is genuinely no
  processor sensor it falls back to the hottest thing in the machine, because a
  ceiling measured elsewhere is worse than an exact one but better than none.
- The smart fan curve followed the same wrong sensor. A curve with no sensor
  chosen follows "the CPU", and its default range of 55–85 °C is written for a
  die temperature. At the instant the hottest core read 94 °C the curve was
  handed 54, which is below its own floor: the fan sat at 1836 rpm when the
  same curve fed the die reading would have called for 5616. Anyone who had
  picked a sensor by hand, or "the hottest sensor", was never affected.

**Correctness**

- Fixed a data race that has been in the shipped app: opening the settings
  window reads the hardware on the main thread while a tick may already be
  reading it on the telemetry queue. The readers are not stateless — the load
  and network figures each hold the previous sample to subtract from — so what
  is at stake is a corrupted array rather than a stale number. Both paths now
  read on the one queue. `--test-telemetry-race`, run under the thread
  sanitizer, reported it five times in four seconds before and none after.
- Readings are published in the order they were started. The blocking read
  waits for a tick already in flight, reads everything, and publishes at once
  — while the tick it waited for is still queued to publish its own, narrower
  result, which landed second and replaced a full sweep with a single sensor
  for one cycle, at the moment the window opened.
- That same out-of-turn read no longer blanks a field whose reader declined to
  answer. The ordinary tick has always left the last number in place; this
  path, reached every time the window opens, overwrote it with nothing.
- CPU load refuses to answer when two samples land too close together, and
  answers for gaps up to ninety seconds. A tenth of a second of scheduler
  ticks is mostly rounding — it came out as an idle machine or a pegged one
  for one refresh, exactly when somebody had just looked. The old twenty-second
  ceiling, meanwhile, silenced the load entirely for anyone polling slower than
  that, which the menu bar offers up to sixty. The network speed uses the same
  bounds.
- "Held back for" counts the time that passed rather than the time that was
  scheduled to. Every reading used to credit a whole poll interval, including
  the readings taken out of turn when the window opens — twenty-one of those
  inside one second reported forty-two seconds of throttling. A sample is now
  credited with the time since the last one, in fractions of a second, capped
  at the interval plus the slack the timers are allowed so that neither a late
  tick nor a night asleep is counted wrongly.
- Whether the Mac has a charge ceiling is worked out once rather than on every
  redraw, and remembered only when the SMC actually answered "no such key" —
  status 0x84, measured by reading a key that cannot exist. The question is
  asked from a view body, which SwiftUI re-runs on every published change, so
  the answer was being fetched by opening a connection to the SMC, reading a
  key and closing it again, twice a second: 0.68 ms each time. Remembering a
  failed call as an answer hid the Battery tab for the rest of the session.
- A fan that refuses to go back under firmware control now says so in the
  daemon's log. Every path that hands the hardware back swallowed the error —
  which is right, there is nothing useful to do about it on the way out — but
  it then wrote "fans returned to firmware control" whether they had or not.
  It is the one failure in that file that can leave a machine cooling to a
  setting with nothing left running that could change it.
- A window whose position or size could not be read is left alone rather than
  recorded as sitting at the origin with no size. The accessibility call's
  result was ignored and its output left at zero, so a window that declined to
  answer was remembered as 0×0 in the corner — and written back there when the
  display came home. The type is checked too: these answers come from other
  applications' processes, and a forced cast to a CoreFoundation type does not
  trap on the wrong thing, it returns something that answers nothing.
- Putting the windows back no longer puts two of them in the same place. A
  display switched off and on again restores the arrangement by matching each
  window to its title, and two windows of one application can share one — two
  Finder windows on the same folder, or two with no title at all. Each
  placement took the first window that matched, so both landed on the same
  one: it ended where the second placement said and the other never moved.
  Each window is now spoken for once, and every title is matched before any
  placement is allowed to fall back to the position it used to hold: resolving
  them one at a time let a placement whose window had closed take, by
  position, the very window a later one matched by name — which then fell back
  in its turn and moved a window that had never been ours.
- Stored numbers are bounded before they become fixed-width ones: a poll
  interval that becomes a timer's period, a power limit that becomes fifteen
  bits and then an MSR write, a pointer multiplier that becomes a HID
  property, and the five figures the profile editor reads out of a saved rule
  and hands to `Int(_:)` inside a view body. Swift's conversions trap rather than saturating, on a value that
  is not a number as much as on one out of range. None are reachable through
  the interface; all are reachable with `defaults write` or in a damaged
  preferences file. The power limit gains more than not crashing: its steps
  were masked to fifteen bits *after* conversion, so a slider left too high
  wrapped and wrote a small limit rather than a large one.

**What it costs the machine**

- Every SMC read and every SMC write used to ask the chip how big the key is
  and what type it holds, first, as a round trip of its own. That table is
  built when the machine boots and does not change, so it is asked once per
  key. A sweep of the sensors fell from 32 ms to 16, a read of both fans from
  7 ms to 3, and everything else with them.
- The battery no longer opens a connection to the SMC of its own on every
  reading and closes it again. It shares the one the rest of telemetry holds,
  which is what that type's own note says everything does: 1.8 ms to 1.0. It
  was the most expensive thing in a tick, above the sensors.
- The throttle reading asks the system for its dictionary once instead of once
  per field. Three fields meant three trips to configd on every tick, each
  opening a session of its own first: 0.4 ms became 0.1.
- The root daemon's control loop stopped doing the same work twice. It read
  each fan, then `setManual` read it again, then asked the SMC what byte
  layout the target key wants — every half-second, for as long as a fan was
  under our control — and then wrote a target the fan was already holding. At
  about 0.8 ms per round trip that was roughly 19 ms of every tick; the steady
  state is about a third of that.
- Six repeating timers carry a tolerance of a fifth of their period, so the
  system can line their wake-ups up with whatever else is waking. The menu
  bar's redraw was the last one without it, and being the most frequent and
  never stopping, it had been keeping the others' slack from buying anything.

**Profiles**

- A rule can ask whether the CPU is busy, not only whether it is hot. Heat
  lags the work by a minute, and naming an application only covers the ones
  you thought of — "on mains, docked, and running something heavy" is what the
  tab is for and could not be said until now.

**Probes and documentation**

- `--dump-smc` lists the sensors that are asleep or out of range instead of
  hiding them, which is what you need when a temperature you expected is
  missing.
- `--test-gpu` can fill in the line it has always had for the active card: it
  asked for that information without requesting it, so the line printed a dash
  on every machine. It also names the processes holding the discrete card,
  which the policy alone cannot tell you — on this Mac the policy reads
  "integrated only" while four processes hold a command queue on the other one.
- `--test-pointer` explains an empty device list instead of printing a bare
  zero. Nothing matching and nothing publishing a curve want different
  answers. On this machine the built-in trackpad matches, names its curve
  `HIDTrackpadAcceleration`, and the value behind that name is absent from the
  service, so the list comes back empty.
- `--test-profiles` reads everything, as if a window were open, and waits for
  two ticks: it claims to try every condition against the machine, and the one
  about CPU load had nothing to try itself against. It also names the sensor
  each temperature came from.
- `--test-telemetry-race` drives the two paths that read the hardware into
  each other, for use under the thread sanitizer.
- `scripts/verify-clean-build.sh` builds the committed state in a clone of its
  own and runs the whole release path through it — build, self-test, bundle,
  disk image, and the note inside the image. `.build` survives edits, so a
  tree that builds in the working copy can still be missing a file nobody
  added to git.
- The note inside the disk image said the helper is installed on first use. It
  is not: the offer lives in an "Install helper…" menu item and in a banner
  across the settings window. Its claim that there is no network code was also
  untrue — there are no connections of any kind, but the interface counters
  and the current Wi-Fi name are read locally, and it now says so.
- A comment described a setting that had been folded into another one and said
  the opposite of what the code does: that all fans follow one sensor. They
  follow their own.
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
