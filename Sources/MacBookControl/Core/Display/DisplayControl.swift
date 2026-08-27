import AppKit
import CoreGraphics
import Foundation

/// Brightness and resolution, including the parts macOS hides.
///
/// Three separate mechanisms, because they answer to different owners:
///
/// - Hardware brightness goes through `DisplayServices`, the same private
///   framework the brightness keys drive. Resolved at runtime — no headers.
/// - Below the panel's own minimum there is nothing left to dim, so going
///   darker means scaling the colour transfer table instead. That is public
///   API, and CoreGraphics restores it by itself when the process that set it
///   exits — so a crash cannot leave the screen black.
/// - Resolutions come from `CGDisplayCopyAllDisplayModes` asked for the
///   duplicate low-resolution modes as well: 65 modes without that flag on
///   this machine, 210 with it. The extra ones are the HiDPI variants the
///   Displays pane declines to show.
final class DisplayControl {
    struct Screen: Identifiable {
        let id: CGDirectDisplayID
        let name: String
        let isBuiltIn: Bool
        let width: Int
        let height: Int
        let pixelWidth: Int
        let brightness: Float?
        /// False for a panel that is attached but switched off.
        var isOn = true
    }

    /// What the monitor calls itself, which is what the Displays pane shows.
    ///
    /// An external display was listed as "Display 2028535915" — the number
    /// CoreGraphics happens to have given it this session — while every other
    /// application on the machine called it AG274FG8R4+. The name is on the
    /// screen object; it just has to be asked for.
    static func name(of id: CGDirectDisplayID, builtIn: Bool) -> String {
        if let localised = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == id
        })?.localizedName, !localised.isEmpty {
            return localised
        }
        // A display that has just been plugged in can be active before its
        // screen object exists, and a number is better than nothing.
        return builtIn ? "Built-in display" : "Display \(id)"
    }

    struct Mode: Identifiable, Hashable {
        let width: Int
        let height: Int
        let pixelWidth: Int
        let refreshHz: Int
        var isHiDPI: Bool { pixelWidth > width }
        var id: String { "\(width)x\(height)@\(refreshHz)\(isHiDPI ? "r" : "")" }
        var label: String {
            let scale = isHiDPI ? " HiDPI" : ""
            let rate = refreshHz > 0 ? " · \(refreshHz) Hz" : ""
            return "\(width) × \(height)\(scale)\(rate)"
        }
    }

    private typealias GetBrightnessC = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessC = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeC = @convention(c) (CGDirectDisplayID) -> Bool

    private let getBrightness: GetBrightnessC?
    private let setBrightness: SetBrightnessC?
    private let canChange: CanChangeC?

    /// Displays currently dimmed below hardware minimum, so the gamma table
    /// can be put back for exactly those and no others.
    private var dimmed: Set<CGDirectDisplayID> = []

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        getBrightness = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
            .map { unsafeBitCast($0, to: GetBrightnessC.self) }
        setBrightness = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
            .map { unsafeBitCast($0, to: SetBrightnessC.self) }
        canChange = handle.flatMap { dlsym($0, "DisplayServicesCanChangeBrightness") }
            .map { unsafeBitCast($0, to: CanChangeC.self) }
    }

    var isAvailable: Bool { getBrightness != nil && setBrightness != nil }

    // MARK: Screens

    /// Every display attached, whether or not it is switched on.
    ///
    /// The online list rather than the active one: a panel that has been
    /// switched off is still connected, and listing only the active ones meant
    /// the row carrying the switch vanished the moment it was used — leaving
    /// no way to switch it back on and making the control look broken.
    func screens() -> [Screen] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        let active = Set(activeDisplayIDs())

        return ids.map { id in
            let mode = CGDisplayCopyDisplayMode(id)
            let builtIn = CGDisplayIsBuiltin(id) != 0
            return Screen(
                id: id,
                name: Self.name(of: id, builtIn: builtIn),
                isBuiltIn: builtIn,
                width: mode?.width ?? 0,
                height: mode?.height ?? 0,
                pixelWidth: mode?.pixelWidth ?? 0,
                brightness: brightness(of: id),
                isOn: active.contains(id)
            )
        }
    }

    // MARK: Brightness

    func brightness(of display: CGDirectDisplayID) -> Float? {
        guard let getBrightness = getBrightness else { return nil }
        var value: Float = 0
        guard getBrightness(display, &value) == 0 else { return nil }
        return value
    }

    func canChangeBrightness(of display: CGDirectDisplayID) -> Bool {
        canChange?(display) ?? false
    }

    @discardableResult
    func setBrightness(_ value: Float, on display: CGDirectDisplayID) -> Bool {
        guard let setBrightness = setBrightness else { return false }
        return setBrightness(display, max(0, min(1, value))) == 0
    }

    // MARK: Dimming past the hardware floor

    /// `level` of 1 is untouched, 0 is black. Scales the transfer table rather
    /// than the backlight, so it works after the panel has nothing left to give.
    func setExtraDimming(_ level: Double, on display: CGDirectDisplayID) {
        let clamped = CGGammaValue(max(0.1, min(1, level)))
        if clamped >= 1 {
            clearDimming(on: display)
            return
        }
        CGSetDisplayTransferByFormula(display,
                                      0, clamped, 1,
                                      0, clamped, 1,
                                      0, clamped, 1)
        dimmed.insert(display)
    }

    func clearDimming(on display: CGDirectDisplayID) {
        guard dimmed.remove(display) != nil else { return }
        CGDisplayRestoreColorSyncSettings()
    }

    func clearAllDimming() {
        guard !dimmed.isEmpty else { return }
        dimmed.removeAll()
        CGDisplayRestoreColorSyncSettings()
    }

    // MARK: Modes

    /// Every mode, hidden ones included, with the duplicates collapsed.
    ///
    /// The raw list repeats each size once per refresh rate — eight entries of
    /// 1536×960 in a row on this machine — which is unusable in a menu. One
    /// entry per size and scaling, keeping the fastest refresh.
    func modes(for display: CGDirectDisplayID) -> [Mode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        let raw = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
        var best: [String: Mode] = [:]
        for mode in raw {
            let candidate = Mode(width: mode.width, height: mode.height,
                                 pixelWidth: mode.pixelWidth, refreshHz: Int(mode.refreshRate))
            let key = "\(candidate.width)x\(candidate.height)x\(candidate.pixelWidth)"
            if let existing = best[key], existing.refreshHz >= candidate.refreshHz { continue }
            best[key] = candidate
        }
        return best.values.sorted {
            ($0.width, $0.pixelWidth) > ($1.width, $1.pixelWidth)
        }
    }

    func currentMode(for display: CGDirectDisplayID) -> Mode? {
        guard let mode = CGDisplayCopyDisplayMode(display) else { return nil }
        return Mode(width: mode.width, height: mode.height,
                    pixelWidth: mode.pixelWidth, refreshHz: Int(mode.refreshRate))
    }

    /// The mode in force before the last change, so it can be put back.
    private var modeBeforeChange: [CGDirectDisplayID: CGDisplayMode] = [:]
    private var revertTimer: Timer?

    /// True while a change is waiting to be confirmed.
    private(set) var awaitingConfirmation: CGDirectDisplayID?
    /// Set while a rotation is waiting to be confirmed, so the revert puts
    /// back an orientation rather than a resolution.
    private var rotationBeforeChange: (display: CGDirectDisplayID, rotation: Rotation)?
    /// Set while a switched-off panel is waiting to be confirmed.
    private var disabledDisplay: CGDirectDisplayID?
    /// Where the windows were before a screen was switched off.
    private var arrangementBeforeChange: [WindowArrangement.Placement] = []
    /// How bright each switched-off panel was, so it comes back as it went.
    private var brightnessBeforeDisable: [CGDirectDisplayID: Float?] = [:]

    /// Switches resolution inside a configuration transaction, so the change
    /// lands in one step rather than as a sequence the window server has to
    /// animate through.
    ///
    /// The old mode is kept and put back automatically unless `confirm()` is
    /// called within `revertAfter` seconds. A display can be told to use a mode
    /// it cannot actually show — the panel goes black, and the button that
    /// would undo it is on the screen that just went dark. macOS guards its own
    /// Displays pane this way for the same reason, and a utility that changes
    /// resolutions without the guard is strictly more dangerous than the system
    /// tool it replaces.
    @discardableResult
    func apply(_ target: Mode, to display: CGDirectDisplayID, revertAfter: TimeInterval = 15) -> Bool {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let raw = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode],
              let match = raw.first(where: {
                  $0.width == target.width && $0.height == target.height
                      && $0.pixelWidth == target.pixelWidth && Int($0.refreshRate) == target.refreshHz
              })
        else { return false }

        let previous = CGDisplayCopyDisplayMode(display)

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(config, display, match, nil)
        // Only for this login session: a resolution that turns out to be
        // unreadable should not survive a restart, which is the one way back.
        let ok = CGCompleteDisplayConfiguration(config, CGConfigureOption.forSession) == .success
        guard ok else { return false }

        if let previous = previous, revertAfter > 0 {
            modeBeforeChange[display] = previous
            awaitingConfirmation = display
            revertTimer?.invalidate()
            let timer = Timer.scheduledTimer(withTimeInterval: revertAfter, repeats: false) { [weak self] _ in
                self?.revert(display)
            }
            RunLoop.main.add(timer, forMode: .common)
            revertTimer = timer
        }
        return true
    }

    /// Keeps the new mode. Called when the user confirms they can still see.
    func confirm() {
        revertTimer?.invalidate()
        revertTimer = nil
        awaitingConfirmation = nil
        modeBeforeChange.removeAll()
        rotationBeforeChange = nil
        disabledDisplay = nil
    }

    /// Puts the previous mode back.
    func revert(_ display: CGDirectDisplayID) {
        revertTimer?.invalidate()
        revertTimer = nil
        awaitingConfirmation = nil

        // A panel switched off comes back first: everything else assumes
        // there is something to draw on.
        if disabledDisplay == display {
            disabledDisplay = nil
            setEnabled(true, of: display, revertAfter: 0)
            return
        }

        // A rotation waiting to be confirmed is put back the way it was
        // applied, not through a display configuration.
        if let rotation = rotationBeforeChange, rotation.display == display {
            rotationBeforeChange = nil
            setRotation(rotation.rotation, of: display, revertAfter: 0)
            return
        }

        guard let previous = modeBeforeChange.removeValue(forKey: display) else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayWithDisplayMode(config, display, previous, nil)
        _ = CGCompleteDisplayConfiguration(config, CGConfigureOption.forSession)
    }

    // MARK: Displays coming and going

    /// Called whenever a display is attached, removed or reconfigured.
    var onConfigurationChange: (() -> Void)?

    /// Starts watching. Polling for this was wrong in two ways: it noticed a
    /// display leaving up to five seconds late, and five seconds is long
    /// enough to be stranded.
    func startWatchingConfiguration() {
        guard !isWatching else { return }
        isWatching = true
        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, userInfo in
            guard let userInfo = userInfo else { return }
            let control = Unmanaged<DisplayControl>.fromOpaque(userInfo).takeUnretainedValue()
            // Only the settled state matters; the "begin" phase fires before
            // anything has actually changed.
            guard flags.contains(.setModeFlag) || flags.contains(.addFlag)
                    || flags.contains(.removeFlag) || flags.contains(.disabledFlag)
                    || flags.contains(.enabledFlag) else { return }
            DispatchQueue.main.async { control.handleConfigurationChange() }
        }, context)
    }

    private var isWatching = false

    private func handleConfigurationChange() {
        // A display left while a resolution change on another one was still
        // waiting to be confirmed: nobody is going to click anything now, so
        // put it back rather than leaving a mode nobody agreed to.
        if let pending = awaitingConfirmation, !activeDisplayIDs().contains(pending) {
            revert(pending)
        }
        rescueIfHeadless()
        onConfigurationChange?()
    }

    /// Puts a screen back when the machine has none left.
    ///
    /// This is the failure people report of other display utilities: the
    /// built-in panel is switched off while an external one is attached, the
    /// external is then unplugged, and there is now nowhere to draw the window
    /// that would switch the built-in back on. The usual way out is a restart.
    ///
    /// `CGRestorePermanentDisplayConfiguration` asks the window server for the
    /// arrangement the system considers permanent, which on a laptop always
    /// includes the built-in panel. It is a public call and does nothing at
    /// all while any display is active, so the cost of being wrong here is
    /// zero — which matters, because this cannot be proven without a second
    /// monitor to unplug and there is none to test against.
    ///
    /// The delay is not politeness. Switching a mode passes through a moment
    /// with no active display, and restoring in the middle of that would fight
    /// the change that is already happening.
    private func rescueIfHeadless() {
        guard activeDisplayIDs().isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, self.activeDisplayIDs().isEmpty else { return }
            CGRestorePermanentDisplayConfiguration()
            // And the light back on. A panel switched off here was darkened
            // as well as disconnected, and a restored arrangement on a black
            // screen is the same problem wearing a different hat.
            for display in self.brightnessBeforeDisable.keys {
                self.setBrightness(self.brightnessBeforeDisable[display].flatMap { $0 } ?? 1,
                                   on: display)
            }
            self.brightnessBeforeDisable.removeAll()
        }
    }

    private func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids
    }

    // MARK: Switching a panel off

    /// Turns a display off or back on.
    ///
    /// This is the control that makes other utilities dangerous, and the
    /// reason the guard exists before the call rather than after it: switch
    /// the built-in panel off with an external attached, unplug the external,
    /// and there is nowhere left to draw the window that would switch the
    /// built-in back on. Three things stand between a person and that:
    ///
    /// - it refuses outright when this is the last display standing;
    /// - the switch stays in the list, so the way back is where the way out
    ///   was;
    /// - the change is for this session only, so a restart undoes it even if
    ///   everything else has failed — which is precisely the escape the
    ///   reported failure did not have.
    ///
    /// There is deliberately no timer putting it back. A resolution or a
    /// rotation can leave a panel that cannot be read, so those revert unless
    /// confirmed; a screen switched off while another one is lit cannot strand
    /// anybody, and a screen that turns itself back on after fifteen seconds
    /// is not a screen that has been switched off.
    ///
    /// And separately from all three, the watcher further down notices a
    /// machine with no active display at all and asks for the permanent
    /// arrangement back.
    @discardableResult
    func setEnabled(_ enabled: Bool, of display: CGDirectDisplayID,
                    revertAfter: TimeInterval = 0) -> Bool {
        guard enabled || canSafelyDisable(display) else { return false }
        guard let configure = Self.configureDisplayEnabled else { return false }

        if !enabled {
            // Taken before the screen goes: macOS herds every window onto
            // whatever is left and puts none of them back afterwards.
            arrangementBeforeChange = WindowArrangement.capture()
            // And the backlight goes out first. Switching a display off
            // removes it from the arrangement but leaves the panel lit — a
            // laptop shut this way glows black at you, which is not what
            // anybody means by off. Brightness has to be written while the
            // display is still active, so the order matters.
            brightnessBeforeDisable[display] = brightness(of: display)
            setBrightness(0, on: display)
        }

        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success,
              let configuration = configuration else { return false }
        _ = configure(configuration, display, enabled)
        guard CGCompleteDisplayConfiguration(configuration, .forSession) == .success else {
            return false
        }

        if enabled, let previous = brightnessBeforeDisable.removeValue(forKey: display) {
            // Back on, then lit: the same order in reverse.
            setBrightness(previous ?? 1, on: display)
        }

        if enabled, !arrangementBeforeChange.isEmpty {
            // A moment for the window server to finish rearranging, or the
            // windows are put back and then moved again.
            let arrangement = arrangementBeforeChange
            arrangementBeforeChange = []
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                WindowArrangement.restore(arrangement)
            }
        }

        guard !enabled, revertAfter > 0 else { return true }
        disabledDisplay = display
        awaitingConfirmation = display
        revertTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: revertAfter, repeats: false) { [weak self] _ in
            self?.revert(display)
        }
        RunLoop.main.add(timer, forMode: .common)
        revertTimer = timer
        return true
    }

    /// Puts back every panel this session switched off. Called when the
    /// feature is switched off and when the app quits.
    func restoreDisabledDisplays() {
        for display in brightnessBeforeDisable.keys {
            setEnabled(true, of: display)
        }
    }

    func isEnabled(_ display: CGDirectDisplayID) -> Bool {
        activeDisplayIDs().contains(display)
    }

    /// There is no published call for this. Looked up by name rather than
    /// linked against, so that a system which no longer offers it leaves the
    /// control unavailable instead of refusing to launch.
    private static let configureDisplayEnabled: (@convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> Int32)? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGSConfigureDisplayEnabled") else {
            return nil
        }
        return unsafeBitCast(symbol, to: (@convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> Int32).self)
    }()

    /// True when the machine has a call for this at all.
    static var canSwitchDisplaysOff: Bool { configureDisplayEnabled != nil }

    // MARK: Rotation

    /// The four orientations a panel can be driven at.
    enum Rotation: Int, CaseIterable, Identifiable {
        case standard = 0, ninety = 1, oneEighty = 2, twoSeventy = 3
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .standard: return "Standard"
            case .ninety: return "90°"
            case .oneEighty: return "180°"
            case .twoSeventy: return "270°"
            }
        }
    }

    func rotation(of display: CGDirectDisplayID) -> Rotation {
        // CoreGraphics answers in degrees; the framebuffer wants an index.
        switch Int(CGDisplayRotation(display).rounded()) {
        case 90: return .ninety
        case 180: return .oneEighty
        case 270: return .twoSeventy
        default: return .standard
        }
    }

    /// Rotates a panel, and puts it back by itself unless confirmed.
    ///
    /// There is no public call for this: the window server takes it as a probe
    /// on the framebuffer with the orientation packed into the option bits,
    /// which is what every tool that offers rotation does. The guard matters
    /// more here than for a resolution — a screen turned on its side is still
    /// readable, but a screen turned upside down with the mouse moving the
    /// wrong way is not something to be stuck with.
    @discardableResult
    func setRotation(_ rotation: Rotation, of display: CGDirectDisplayID,
                     revertAfter: TimeInterval = 15) -> Bool {
        guard let framebuffer = framebuffer(for: display) else { return false }
        defer { IOObjectRelease(framebuffer) }

        let previous = self.rotation(of: display)
        // kIOFBSetTransform, with the orientation in the high half.
        let options = IOOptionBits(0x00000400 | (rotation.rawValue << 16))
        guard IOServiceRequestProbe(framebuffer, options) == KERN_SUCCESS else { return false }

        guard rotation != previous, revertAfter > 0 else { return true }
        rotationBeforeChange = (display, previous)
        awaitingConfirmation = display
        revertTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: revertAfter, repeats: false) { [weak self] _ in
            self?.revert(display)
        }
        RunLoop.main.add(timer, forMode: .common)
        revertTimer = timer
        return true
    }

    /// The framebuffer driving a display, matched on the identifiers both
    /// sides publish — the vendor, the model and the serial from the monitor's
    /// own EDID. Matching on names would collide the moment somebody attaches
    /// two identical monitors.
    private func framebuffer(for display: CGDirectDisplayID) -> io_service_t? {
        let vendor = CGDisplayVendorNumber(display)
        let model = CGDisplayModelNumber(display)
        let serial = CGDisplaySerialNumber(display)

        var found: io_service_t?
        Registry.forEachService(matching: "IOFramebuffer") { framebuffer in
            guard found == nil else { return }
            Registry.forEachChild(of: framebuffer) { child in
                guard found == nil,
                      let info = IODisplayCreateInfoDictionary(child, IOOptionBits(0))?
                        .takeRetainedValue() as? [String: Any],
                      (info[kDisplayVendorID as String] as? UInt32) == vendor,
                      (info[kDisplayProductID as String] as? UInt32) == model
                else { return }
                // The serial is absent on some panels; when both sides have
                // one it must agree, and when they do not the vendor and
                // model are as far as anyone can go.
                if let theirs = info[kDisplaySerialNumber as String] as? UInt32,
                   serial != 0, theirs != serial { return }
                IOObjectRetain(framebuffer)
                found = framebuffer
            }
        }
        return found
    }

    // MARK: Mirroring

    /// Which display this one is mirroring, if any.
    func mirrorSource(of display: CGDirectDisplayID) -> CGDirectDisplayID? {
        let source = CGDisplayMirrorsDisplay(display)
        return source == kCGNullDirectDisplay ? nil : source
    }

    /// Mirrors `display` onto `source`, or stops mirroring when `source` is
    /// nil.
    ///
    /// Public CoreGraphics all the way, and reversible in one call — which is
    /// why it needs no confirm-or-revert dance the way a resolution does:
    /// nothing here can leave a panel showing a mode it cannot display.
    @discardableResult
    func setMirroring(of display: CGDirectDisplayID, to source: CGDirectDisplayID?) -> Bool {
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success,
              let configuration = configuration else { return false }
        CGConfigureDisplayMirrorOfDisplay(configuration, display,
                                          source ?? kCGNullDirectDisplay)
        return CGCompleteDisplayConfiguration(configuration, .permanently) == .success
    }

    /// Whether turning this display off would leave the machine with none.
    ///
    /// This is the rule that prevents the failure people report of other
    /// display utilities: switch the built-in panel off while an external one
    /// is attached, unplug the external, and there is now nowhere to draw the
    /// window that would switch the built-in back on. The only way out is a
    /// restart. Zephyr has no such switch yet — and when it gets one, it goes
    /// through here, and the watcher above re-enables the panel the moment the
    /// external display leaves.
    func canSafelyDisable(_ display: CGDirectDisplayID) -> Bool {
        activeDisplayIDs().filter { $0 != display }.isEmpty == false
    }

    deinit { clearAllDimming() }
}
