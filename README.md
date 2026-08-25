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

## What the two newer sections are for

**Throttling monitor.** When the package runs hot, or the charger cannot supply
what the CPU wants, the firmware caps clock speed. Nothing in macOS surfaces
this: every sensor still reads survivable and the machine merely feels slow.
`IOPMCopyCPUPowerStatus` reports that cap — the same number `pmset -g therm`
prints — so the menu shows it next to the thermal pressure and the number of
cores the scheduler is still allowed to use. 100 % means nothing is being held
back. This is read-only; Zephyr never changes the cap.

**Charge ceiling.** Keeping a lithium cell at 100 % is what ages it fastest,
and a laptop that lives on a desk does exactly that. The SMC accepts a ceiling
in `BCLM`, so the daemon can hold charging at 80 % — the same mechanism the
dedicated tools use. Two details are worth knowing:

- The firmware clears the key across sleep and power loss, so Zephyr writes it
  again on wake, next to the Turbo Boost bit.
- A ceiling **below** the current charge does not discharge anything. The
  machine simply stops charging and waits for normal use to bring it down,
  which looks like a fault until you know it is deliberate. The menu says so.

Turning the toggle off restores unlimited charging immediately.

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
