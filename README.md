# Zephyr

One menu-bar application for **Intel** Macs, in place of about ten separate
utilities. Nine tabs, each behind its own switch, plus a rule engine that can
drive them together — which is the only thing a single process can do that nine
utilities cannot.

| Instead of | Zephyr |
|---|---|
| Macs Fan Control | fan curves, fixed speeds, per-fan sensor choice, throttling |
| Turbo Boost Switcher | Turbo Boost, Intel package power limits, live wattage |
| gfxCardStatus / gSwitch | pins a GPU and holds it, names what is keeping the discrete card awake |
| AlDente | charge ceiling, pause-on-heat, wear, cycles, power flow |
| BetterDisplay | brightness past the panel's minimum, hidden resolutions, arrangement, rotation, mirroring, font smoothing |
| Karabiner-Elements | key swaps below the window server, plus rules that need a modifier held |
| LinearMouse / Mos | scroll direction and speed per device, per-application rules, smoothed wheel, button bindings |
| Amphetamine / KeepingYouAwake | holds the Mac awake, with the display off or the lid shut |
| Stats | temperatures, load, memory, disk, network and battery drawn into the menu bar |
| — | **Profiles**: rules that set several of the above when the circumstances call for it |

Native Swift and AppKit. No Xcode to build, no third-party dependencies, no
network access of any kind.

## Supported machines

- **Intel Macs only** (`x86_64`). Apple Silicon is out of scope: much of what
  this does is Intel-specific (MSRs, the Intel package power limit, the
  discrete-GPU mux), and there is no ARM hardware here to test the rest on.
- **macOS 11 (Big Sur) → macOS 26** is the declared range, chosen because it is
  the whole Intel span. **Verified on macOS 15.7.9, MacBookPro16,1** — that is
  the only machine this has run on, and the honest limit of the claim.
- Not a laptop-only application: an iMac or a Mac Pro is a better fit for parts
  of it than this laptop is. The display arrangement grid sizes itself to the
  screens attached, up to the twelve a Mac Pro can drive.
- Features that need hardware the machine does not have hide themselves rather
  than failing: no charge ceiling without the SMC key `BCLM`, no GPU tab on a
  single-GPU Mac, no Turbo Boost or power limits without the kexts.

## Privilege model — four different tiers

Most of what Zephyr does needs nothing at all. The table is worth reading
before installing anything, because it says exactly how much is being asked for
and why.

| What | Access | How |
|---|---|---|
| Temperatures, fan RPM, active GPU, throttling | none | in-process IOKit and Metal |
| SSD SMART, sleep assertions, wake and shutdown records, GPU clients | none | in-process IOKit |
| Brightness, resolutions, arrangement, rotation, mirroring, font smoothing | none | CoreGraphics and the user's own preferences |
| Key swaps (hidutil), pointer acceleration | none | in-process HID, per user |
| Scroll rewriting, modifier key rules, window capture and restore | **Accessibility** | an event tap and the accessibility API, granted in System Settings |
| Fan writes, GPU switching, charge ceiling | **root** | privileged LaunchDaemon over XPC |
| Turbo Boost (MSR `0x1A0`), package power limit (MSR `0x610`) | **ring 0** | two small kernel extensions, which need SIP disabled |

Fan, GPU and battery control use the sanctioned privileged-helper pattern — a
small **LaunchDaemon** the app talks to over XPC. The helper does not trust
whatever asks: `install-helper.sh` pins the calling application's code
signature, and the daemon rejects every client whose cdhash does not match. The
practical consequence is that replacing the app means re-running that script,
which the build reminds you of.

The kexts are the only part that reduces the machine's security, they are
entirely optional, and without them those two tabs simply do not appear.

> Undervolting (Volta / VoltageShift) is deliberately not included: same kext
> requirement, and on 2019 and later Macs the undervolt MSR is locked by
> Apple's Plundervolt (CVE-2019-11157) firmware mitigation anyway. There the
> mailbox those tools write to no longer answers, so it is not a question of
> effort.

## What each tab does

The menu bar stays at four items — Settings, the helper's state, Launch at
login, Quit — and everything else lives in one window, a tab per function, each
behind its own **Enable**.

The checkbox is a promise rather than a display preference: a function that is
off leaves the hardware exactly as it found it. Switching **Cooling** off hands
the fans back to the firmware; switching **Battery** off lifts the charge
ceiling. Anything less strands the machine in a state with nothing in the UI to
explain it, which is how a battery ends up capped at 80 % for a year because an
app was uninstalled.

| Tab | What it replaces | What it does |
|---|---|---|
| **Cooling** | Macs Fan Control, Hot | Fans on a temperature curve or a fixed percentage, the sensor each fan follows, and how far the firmware has capped the CPU this session |
| **Power** | Turbo Boost Switcher, VoltageShift | Turbo Boost off, the Intel package power limit, live wattage |
| **Graphics** | gfxCardStatus, gSwitch | Pins the integrated or discrete GPU and *holds* it, and names the processes keeping the discrete card awake |
| **Battery & Sleep** | AlDente | Charge ceiling enforced by the SMC, charging paused above a temperature, wear and cycles, where the watts are going, and what is holding the machine awake |
| **Display** | BetterDisplay | Brightness, dimming past the panel's own minimum, resolutions the Displays pane hides, the arrangement grid, rotation, mirroring, blanking a panel, virtual screens, and font smoothing |
| **Input** | Karabiner-Elements, LinearMouse, Mos | Key swaps and modifier rules; per-device scroll direction, speed and buttons; per-application scroll rules; a smoothed wheel |
| **Awake** | Amphetamine, KeepingYouAwake | Holds the Mac awake, optionally with the display off or through a closed lid |
| **Diagnostics** | DriveDx, smartmontools | SSD health from the NVMe SMART log, why the machine last woke, slept and shut down, and which processes are loading it |
| **Menu Bar** | Stats, iStat Menus | Chooses what the menu bar shows and in what order, drawn as one image so the order is actually obeyed |
| **Settings** | — | Helper state, launch at login, window appearance |
| **Profiles** | — | Rules that set several of the above at once when the circumstances call for it |

### Appearance

Three window layouts — **Classic** (tabs across the top), **Quiet** (a side
list) and **Terminal** (the same list, monospaced and drawn in brackets) — each
with a light and a dark face, plus **Darkness**, a true black for OLED and for
people who mean it. This is a real setting rather than a preview: the direction
the 2.0 redesign is going has to be usable before it is committed to.

### Why Profiles is the point

Nothing above is hard to find on its own. What no separate utility can do is
notice that the machine is on mains, docked to an external display, and running
something heavy — because none of them can see the others' business. A profile
says "when these hold, set those", and it is the only reason to have one process
instead of nine.

A profile is applied when it takes over, and not again until the circumstances
change. That matters: re-applying every tick would mean the app silently undoing
anything you changed by hand. When several profiles match, the first in the list
wins, so ordering is how "specific above general" gets expressed.

A profile can only drive functions you have already enabled. A rule may decide
*when* the Mac is held awake; it may not decide *whether* you allowed it to be.

### What is deliberately not here

**Undervolting.** The register is locked by the firmware's Plundervolt
mitigation (CVE-2019-11157) on every Mac built after 2018. The Power tab offers
the package power limit instead, which is a mechanism Intel intends to be used
and gets the same practical result: cooler, quieter, less throttling.

**Karabiner's layers, chords and hold-versus-tap.** Plain key swaps go through
hidutil, below the window server, so they hold on the login screen and inside
password fields. Anything that has to notice a modifier needs an event tap,
which is a different bargain: a tap rule applies to every keyboard, because an
event does not say which one produced it, and it stops the moment Zephyr does.
Both are offered, side by side, with that difference written in the interface —
because a Caps Lock that had become Escape and then quietly stopped being
Escape at the login window is worse than not having the rule.

**Switching a display off.** Removing a panel from the arrangement, and then
unplugging the external one, left this machine with no picture at all: the
reconfiguration callback, a timed watch, restoring the permanent arrangement
and re-enabling the panel by name all failed, and so did plugging the cable
back in. Only holding the power button worked. Once the window server has no
display it will not accept a configuration that would give it one, so no fourth
guard can help. The tab blanks the backlight instead, which leaves the screen
in the arrangement — dark, but present.

**DDC/CI for external monitors.** Not merely untested: probed and found
unreachable on this hardware. The framebuffer driving the external panel was
identified by its EDID, and every combination of transaction type and delay
failed; `IOAVServiceCreate` returns nil and no service class binds on Intel.
Writing it blind would produce a control that silently does nothing.

## Verifying it does what it says

The binary runs its own checks and the build refuses to package a bundle that
fails them:

```sh
./build.sh                 # runs --self-test before assembling Zephyr.app
```

The checks cover the parts where being wrong is invisible: fan curve
arithmetic, profile conditions, the scroll and key rewriting rules, the
arrangement grid, drive-health thresholds, menu-bar composition, and the
readout column widths.

## Build

```sh
# The .app bundle (ad-hoc signed, no Xcode — Command Line Tools are enough):
./build.sh                          # -> Zephyr.app

# The kexts, both optional and neither kept in the repository — a compiled
# kernel extension that has drifted from its source is the one binary on the
# machine nobody should load:
./kext/build-kext.sh                # -> kext/DisableTurboBoost.kext  (Turbo Boost)
./kext/build-kext.sh ZephyrPower    # -> kext/ZephyrPower.kext        (power limits)
```

`build.sh` copies whichever kexts it finds into the bundle, so building them is
the only thing that decides whether those features appear.

## Install & run

### From the disk image

Drag Zephyr onto Applications, then open it. macOS refuses the first launch
and says the developer cannot be verified: the application is signed ad-hoc,
because the certificate that removes that dialog costs 99 US dollars a year
and buys nothing else. Open System Settings, go to Privacy & Security, scroll
to the bottom and click "Open Anyway"; on macOS 14 and earlier, right-click
the app in Applications and choose Open instead. That is once.

Then install the helper, which is what makes the controls work rather than
only the readings:

```sh
sudo /Applications/Zephyr.app/Contents/Resources/scripts/install-helper.sh
```

### From a build

```sh
# 1. Install the privileged helper (one-time, asks for your password).
#    Also installs the kext if you built it.
sudo ./scripts/install-helper.sh

# 2. Launch the app:
open Zephyr.app
```

A temperature appears in the menu bar. Open the menu for sensors, fan presets,
GPU switching, and Turbo Boost. Without the helper the app still **monitors**
everything; control items are disabled until the helper is installed.

### Replacing a copy already in /Applications

```sh
osascript -e 'quit app "Zephyr"'; sleep 1
sudo rm -rf /Applications/Zephyr.app
sudo cp -R Zephyr.app /Applications/
sudo /Applications/Zephyr.app/Contents/Resources/scripts/install-helper.sh
open /Applications/Zephyr.app
```

Both the removal and the copy need `sudo`: an installed bundle is owned by
root, which is what keeps a process running as you from swapping the
application the privileged helper talks to. `open` deliberately does not —
nothing with a window should run as root.

The helper step is not optional. The app is ad-hoc signed, so every build has
a different code signature, and the helper only accepts the exact copy it was
installed against. Skip it and the app launches but every control is refused.

## Enabling Turbo Boost control (requires disabling SIP)

Writing the Turbo Boost MSR needs a kernel extension, which an unsigned/ad-hoc
build can only load with SIP off. This is a deliberate security trade-off — do
it only if you want the feature.

1. **Disable SIP** — reboot holding **⌘R** to enter Recovery, then:
   - *Utilities → Startup Security Utility* → **No Security**
   - *Utilities → Terminal* → `csrutil disable`
   - Reboot. Verify with `csrutil status` → *disabled*.
2. **Build & install** the kext: `./kext/build-kext.sh` then re-run
   `sudo ./scripts/install-helper.sh`.
3. **Approve the kext** — the first load prompts *"System Extension Blocked"*;
   approve it in *System Settings → Privacy & Security*, then reboot. After
   that the app toggles Turbo Boost freely.

## Enabling the power limit (also requires SIP disabled)

The Intel package power limit lives in MSR 0x610, which is ring 0. A small kext
publishes it over three sysctls:

```
sudo "/Applications/Zephyr.app/Contents/Resources/scripts/install-power-kext.sh"
```

It refuses to do anything if SIP is enabled, installs a boot-time loader so the
sysctls survive a reboot, and finishes by telling you whether the firmware has
**locked** the register. If it has, Zephyr can read the limits but not change
them — and neither can anything else. That is a hardware decision, not a
limitation of this app.

## Uninstall

```sh
sudo ./scripts/uninstall-helper.sh    # removes daemon + kext, restores fans
rm -rf Zephyr.app
# Re-enable SIP (if you disabled it): boot to Recovery, `csrutil enable`.
```

## CLI / debugging

The same binary carries its diagnostic flags. Nothing here is needed to use the
application; they exist because every hardware claim in it was checked on a
real machine before it was written.

| Flag | What it does |
|------|--------------|
| `--self-test` | Run the built-in checks (the build gate) |
| `--dump-smc` | Every temperature and fan SMC key |
| `--test-fans [--write]` | Read fans; `--write` runs a manual/auto round trip (root) |
| `--test-gpu` | GPU detection and the policy in force |
| `--test-power-limit [--write]` | Read MSR 0x610 through the kext; `--write` sets and restores |
| `--test-helper` | Exercise fan control through the installed helper |
| `--test-keyboard [--write]` | hidutil mappings, read back from the device |
| `--test-pointer [--write]` | Pointing devices, their identities and acceleration curves |
| `--test-scroll [--seconds=N]` | Record every field of real scroll events and compare devices |
| `--test-network` | Interface counters, wrap handling, tunnel detection |
| `--test-windows` | Capture and restore window positions through the accessibility API |
| `--test-virtual-display` | Create a screen with no cable, prove it appears, prove it goes away |
| `--test-diagnostics` | SSD SMART, sleep assertions, wake and shutdown records, GPU clients |
| `--test-profiles` | Evaluate every profile condition against the machine now |
| `--test-timing` | Where the milliseconds go: what the window touches, and what a tick costs |
| `--time-phases` | Startup phase timings — **launches the app** and stays running, unlike every other flag here |
| `--test-telemetry-race` | Drive the two paths that read the hardware into each other; build with `-Xswiftc -sanitize=thread` and let the sanitizer judge |
| `--measure-sections` | The height of each settings section, menu bar expanded |
| `--dump-window <path> [--dark\|--darkness]` | Render every layout offscreen to a contact sheet |
| `--dump-real-window <path> [--layout=…] [--open-settings=…] [--strip=N]` | Photograph the real window, frame and buttons included |
| `--dump-icons <path>` | Every menu-bar icon state as a contact sheet |
| `--preview-design`, `--dump-preview` | The design prototype, kept out of the shipping path |
| `--helper-daemon` | Run as the privileged daemon (launchd uses this) |

## Architecture

One executable in three roles: the menu-bar application, the root daemon when
launchd starts it with `--helper-daemon`, and a pile of diagnostic entry points.

```
Zephyr.app (you)                                  LaunchDaemon (root)
┌──────────────────────────────────┐   XPC   ┌──────────────────────────────┐
│ AppController — NSStatusItem     │ ──────▶ │ HelperService                │
│ FeatureRegistry — nine features  │         │  • SMC fan writes + curve    │
│ Telemetry — reads only what is   │         │  • SMC charge ceiling (BCLM) │
│   currently being shown          │         │  • pmset gpuswitch           │
│ Profiles — conditions → actions  │         │  • kmutil load/unload        │──▶ kexts
└──────────────────────────────────┘         └──────────────────────────────┘    (ring 0)
        unprivileged                              (same binary, --helper-daemon)
```

Everything that can be read without privilege is read in process — SMC sensors,
IOKit registries, NVMe SMART, power assertions, HID services. Only the handful
of operations that genuinely need root cross the XPC boundary, and only MSR
access reaches the kernel.

Two design rules run through the whole thing:

**A switch that is off means the hardware was handed back.** Turning a feature
off restores what it changed — fans to the firmware, the charge ceiling lifted,
the pointer curve returned, font smoothing put back. Anything less strands the
machine in a state with nothing in the interface to explain it, which is how a
battery ends up capped at 80 % for a year because an application was deleted.

**Nothing is read that nobody is looking at.** Telemetry asks the menu bar, the
open tab and the enabled profiles what they actually need, and reads that. With
the window shut and one sensor in the menu bar it reads one sensor rather than
forty-eight: 1.3 % CPU became 0.2 % when this was put in.

## Repository layout

```
Sources/MacBookControl/
  App/          telemetry, preferences, the feature registry
  Core/         one folder per subsystem: SMC, Power, GPU, Display, Pointer,
                HID, Storage, System — no SwiftUI below this line
  Features/     one file per tab: the model and its view together
  UI/           window layouts, palettes, shared controls, the menu-bar drawing
  SelfTest/     the checks the build gate runs, and the hardware probes
kext/           two kernel extensions and the script that builds them
scripts/        helper install/uninstall, the icon generator
```

## License

MIT.
