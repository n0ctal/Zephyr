#!/bin/bash
#
# Every preference a feature reads when it is built, it must be able to read
# again.
#
# The settings window runs in its own process and writes the user's choices
# straight to preferences. The copies in the menu-bar process never hear about
# it, so `reloadFromPreferences()` exists to re-read them — and the failure
# mode is silent: add a property to `init`, forget it here, and that setting
# simply stops taking effect after the window is closed. Nothing crashes and
# no test fails, because the code is correct in every other way.
#
# So the two lists are compared as text. Crude, and it catches exactly the
# mistake that is otherwise invisible.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import glob, os, re, sys

# Preferences a feature reads at launch that are not "what the user chose":
# there is nothing to re-read, and re-reading would be wrong.
NOT_THE_USERS_CHOICE = {
    # Whether a key mapping is still written to the hardware from a run that
    # was killed. Read once, to clean up; reloading it would undo a live one.
    "KeyboardFeature.swift": {"keyboardMappingApplied"},
}

problems = []
for path in sorted(glob.glob("Sources/MacBookControl/Features/*Feature.swift")):
    source = open(path, encoding="utf-8").read()
    name = os.path.basename(path)

    def preferences_in(block):
        return set(re.findall(r"Preferences\.([A-Za-z]+)", block))

    # What init reads. Features assign either `self.x = Preferences.y` or
    # `x = Preferences.y`; both are inside `init`, which ends at the first
    # line that closes it at one level of indentation.
    init = re.search(r"\n    init\(.*?\n    \}\n", source, re.S)
    reload = re.search(r"\n    override func reloadFromPreferences\(\).*?\n    \}\n", source, re.S)

    # Every preference init touches, however it is spelled. The first version
    # of this looked for `x = Preferences.y` and missed
    # `self.mode = GPUMode(rawValue: Preferences.gpuMode)`, which is exactly
    # the kind of thing it exists to catch — a check with a blind spot is
    # worse than no check, because it is believed.
    read_at_init = preferences_in(init.group(0)) if init else set()
    # featureEnabled is the base class's business, reconciled separately.
    read_at_init.discard("featureEnabled")
    read_at_init -= NOT_THE_USERS_CHOICE.get(name, set())

    reloaded = preferences_in(reload.group(0)) if reload else set()

    missing = read_at_init - reloaded
    if missing:
        problems.append("%s: read when built but never re-read: %s"
                        % (name, ", ".join(sorted(missing))))
    extra = reloaded - read_at_init
    if extra:
        problems.append("%s: re-read but not read when built: %s"
                        % (name, ", ".join(sorted(extra))))

if problems:
    print("reload does not mirror init:")
    for p in problems:
        print("  " + p)
    sys.exit(1)
print("reload mirrors init in every feature")
PY
