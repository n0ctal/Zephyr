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

    func screens() -> [Screen] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        return ids.map { id in
            let mode = CGDisplayCopyDisplayMode(id)
            let builtIn = CGDisplayIsBuiltin(id) != 0
            return Screen(
                id: id,
                name: builtIn ? "Built-in display" : "Display \(id)",
                isBuiltIn: builtIn,
                width: mode?.width ?? 0,
                height: mode?.height ?? 0,
                pixelWidth: mode?.pixelWidth ?? 0,
                brightness: brightness(of: id)
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

    /// Switches resolution inside a configuration transaction, so the change
    /// lands in one step rather than as a sequence the window server has to
    /// animate through.
    @discardableResult
    func apply(_ target: Mode, to display: CGDirectDisplayID) -> Bool {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let raw = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode],
              let match = raw.first(where: {
                  $0.width == target.width && $0.height == target.height
                      && $0.pixelWidth == target.pixelWidth && Int($0.refreshRate) == target.refreshHz
              })
        else { return false }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(config, display, match, nil)
        // Only for this login session: a resolution that turns out to be
        // unreadable should not survive a restart, which is the one way back.
        return CGCompleteDisplayConfiguration(config, CGConfigureOption.forSession) == .success
    }

    deinit { clearAllDimming() }
}
