# Zephyr

A single menu-bar app for **Intel** MacBooks that combines the everyday jobs of
**Macs Fan Control**, **gfxCardStatus**, and **Turbo Boost Switcher**:

- 🌡️ **Sensor monitoring** — live temperatures from every SMC sensor, hottest shown in the menu bar.
- 🌀 **Fan control** — per-fan automatic / manual targets, held reliably by a control loop.
- 🎛️ **GPU switching** — force integrated-only, discrete-only, or automatic on dual-GPU machines.
- ⚡ **Turbo Boost** — enable / disable Intel Turbo Boost (cooler & quieter when off).
- 🐢 **Throttling monitor** — the firmware's own CPU speed cap, the number that explains why a cool-looking machine feels slow.
- 🔋 **Charge ceiling** — stop charging at 80 % (or wherever you like) to slow battery wear, the way AlDente does.

Native Swift + AppKit. No Xcode required to build, no third-party dependencies.

## Supported machines

- **Intel Macs only** (`x86_64`). Apple Silicon is out of scope by design.
- **macOS 11 (Big Sur) → macOS 26.** Fan control auto-detects the mechanism:
  the legacy `FS!` force bitmask on pre-T2 Macs, and the per-fan `F{i}Md`
  mode key on T2 Macs (2018+).
- GPU switching applies to dual-GPU models (e.g. MacBook Pro with Intel + AMD).
- The charge ceiling needs the SMC key `BCLM`, present on most Intel laptops.
  Machines without it simply do not show the section.

## Privilege model — three different tiers

| Feature | Access needed | How |
|---|---|---|
| Read temps / fan RPM / active GPU | none | in-process IOKit + Metal |
| Write fan speed, switch GPU (`pmset gpuswitch`) | **root** | privileged LaunchDaemon over XPC |
| Read the CPU speed cap / thermal pressure | none | in-process IOKit |
| Set the charge ceiling (SMC `BCLM`) | **root** | same privileged LaunchDaemon |
| Enable/disable Turbo Boost (MSR `0x1A0`) | **ring-0** | bundled **kernel extension** (needs SIP disabled) |

Fan and GPU control use the same **sanctioned privileged-helper pattern** as
Macs Fan Control — a small **LaunchDaemon** (`--helper-daemon`) the app talks to
over XPC. No kernel extension, no reduced security.

Turbo Boost is different: toggling it means writing a CPU **MSR**, which is only
possible from the kernel. So it ships as a tiny kext that the helper loads /
unloads. Writing MSRs has no sanctioned userspace API, so this **requires SIP to
be disabled** (see below). If you don't disable SIP, the other two features work
fully and the Turbo Boost section simply stays hidden.

> Undervolting (Volta / VoltageShift) is intentionally **not** included: same
> kext requirement, and on 2019+ Macs the undervolt MSR is locked by Apple's
> Plundervolt (CVE-2019-11157) firmware mitigation anyway. On those machines it
> is not a matter of effort — the mailbox the tools write to no longer answers.

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
| **Cooling** | Macs Fan Control, Hot | Fans on a temperature curve or a fixed speed, plus how far the firmware has capped the CPU and for how long this session |
| **Power** | Turbo Boost Switcher, VoltageShift | Turbo Boost off, the Intel package power limit, live wattage |
| **Graphics** | gSwitch | Pins the integrated or discrete GPU — and *holds* the choice, re-asserting when macOS hands the other one out |
| **Battery** | AlDente | Charge ceiling enforced by the SMC, plus wear, cycles and where the watts are going |
| **Display** | BetterDisplay | Brightness, dimming past the panel's own minimum, and the resolutions the Displays pane hides |
| **Keyboard** | Karabiner-Elements | Key-for-key swaps written below the window server, so they hold on the login screen |
| **Pointer** | LinearMouse | Separate scroll directions for mouse and trackpad, fixed distance per notch, no pointer acceleration |
| **Awake** | Amphetamine | Holds the Mac awake, optionally with the display off or through a closed lid |
| **Profiles** | — | Rules that set several of the above at once when the circumstances call for it |

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
and gets you the same practical result: cooler, quieter, less throttling.

**Karabiner's conditional rules.** Layers, chords and hold-versus-tap need to
watch the event stream, and macOS shuts event taps out of password fields and
the login window. A Caps Lock that had become Escape would stop being Escape at
exactly the moment it is least expected. Plain swaps go through the HID layer,
where they hold everywhere.

**DDC/CI for external monitors.** Written blind it fails silently, and there was
no external display to test against.

## Build

```sh
# Build the .app bundle (ad-hoc signed, no Xcode):
./build.sh                 # -> Zephyr.app

# Build the Turbo Boost kext (optional, only if you want that feature):
./kext/build-kext.sh       # -> kext/DisableTurboBoost.kext
```

## Install & run

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

The same binary exposes diagnostic flags:

| Flag | Description |
|------|-------------|
| `--dump-smc` | Dump all temperature and fan SMC keys |
| `--test-fans [--write]` | Read fans; `--write` runs a manual/auto round-trip (needs root) |
| `--test-gpu` | Show GPU detection and current policy |
| `--test-helper` | Exercise fan control through the installed helper (no sudo) |
| `--helper-daemon` | Run as the privileged daemon (used by launchd) |

## Architecture

```
Zephyr.app  (user)                  LaunchDaemon (root)
┌────────────────────────────┐   XPC    ┌───────────────────────────┐
│ AppController (NSStatusItem)│ ───────▶ │ HelperService              │
│ SensorReader   (read temps) │         │  • SMC fan writes + loop   │
│ FanController  (read RPM)   │         │  • pmset gpuswitch         │
│ GPUController  (detect/read)│         │  • kmutil load/unload kext │──▶ DisableTurboBoost.kext
│ TurboBoost     (read state) │         │  • SMC charge ceiling      │──▶ DisableTurboBoost.kext
│ ThermalMonitor (speed cap)  │         └───────────────────────────┘     (MSR 0x1A0, ring-0)
│ BatteryReader  (charge)     │
│ HelperClient   (XPC proxy)  │
└────────────────────────────┘
        unprivileged                          (same binary, --helper-daemon)
```

Reads happen in-process and unprivileged; only the few root operations cross the
XPC boundary, and only Turbo Boost touches the kernel.

## License

MIT.
