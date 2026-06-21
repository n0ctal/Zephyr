# Zephyr

A single menu-bar app for **Intel** MacBooks that combines the everyday jobs of
**Macs Fan Control**, **gfxCardStatus**, and **Turbo Boost Switcher**:

- 🌡️ **Sensor monitoring** — live temperatures from every SMC sensor, hottest shown in the menu bar.
- 🌀 **Fan control** — per-fan automatic / manual targets, held reliably by a control loop.
- 🎛️ **GPU switching** — force integrated-only, discrete-only, or automatic on dual-GPU machines.
- ⚡ **Turbo Boost** — enable / disable Intel Turbo Boost (cooler & quieter when off).

Native Swift + AppKit. No Xcode required to build, no third-party dependencies.

## Supported machines

- **Intel Macs only** (`x86_64`). Apple Silicon is out of scope by design.
- **macOS 11 (Big Sur) → macOS 26.** Fan control auto-detects the mechanism:
  the legacy `FS!` force bitmask on pre-T2 Macs, and the per-fan `F{i}Md`
  mode key on T2 Macs (2018+).
- GPU switching applies to dual-GPU models (e.g. MacBook Pro with Intel + AMD).

## Privilege model — three different tiers

| Feature | Access needed | How |
|---|---|---|
| Read temps / fan RPM / active GPU | none | in-process IOKit + Metal |
| Write fan speed, switch GPU (`pmset gpuswitch`) | **root** | privileged LaunchDaemon over XPC |
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
> Plundervolt (CVE-2019-11157) firmware mitigation anyway.

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
│ TurboBoost     (read state) │         └───────────────────────────┘     (MSR 0x1A0, ring-0)
│ HelperClient   (XPC proxy)  │
└────────────────────────────┘
        unprivileged                          (same binary, --helper-daemon)
```

Reads happen in-process and unprivileged; only the few root operations cross the
XPC boundary, and only Turbo Boost touches the kernel.

## License

MIT.
