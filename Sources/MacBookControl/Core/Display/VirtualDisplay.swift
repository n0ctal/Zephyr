import CoreGraphics
import Foundation
import ObjectiveC.runtime

/// A display macOS believes in that no cable leads to.
///
/// BetterDisplay's headline feature, and long assumed here to need a driver.
/// It does not: CoreGraphics carries `CGVirtualDisplay` and its three
/// companions, private and headerless but present — verified on this machine
/// by creating one, watching the online display count go from two to three
/// with a real display ID, and watching it go back when the object was let go.
///
/// That last part is the whole safety story. A virtual display is *added*, so
/// the machine cannot be left with no screen — the failure this application
/// once caused by removing one. It exists while Zephyr holds the object and
/// vanishes when Zephyr quits, which is a promise the interface makes rather
/// than a surprise.
///
/// Every class and selector is looked up at runtime and every lookup can fail,
/// because all of it is private: on a macOS that moves it, the feature reports
/// itself unavailable instead of crashing.
final class VirtualDisplay {
    struct Specification: Codable, Equatable, Identifiable {
        var id = UUID()
        var name: String
        var width: Int
        var height: Int
        var refreshRate: Double
        /// Doubles the backing resolution so text is drawn the way it is on a
        /// Retina panel. The display still measures width by height.
        var hiDPI: Bool

        static let presets: [(String, Int, Int)] = [
            ("1280 × 720", 1280, 720),
            ("1920 × 1080", 1920, 1080),
            ("2560 × 1440", 2560, 1440),
            ("3840 × 2160", 3840, 2160),
        ]
    }

    /// Whether this macOS still has the classes.
    static var isAvailable: Bool {
        NSClassFromString("CGVirtualDisplay") != nil
            && NSClassFromString("CGVirtualDisplayDescriptor") != nil
            && NSClassFromString("CGVirtualDisplaySettings") != nil
            && NSClassFromString("CGVirtualDisplayMode") != nil
    }

    let specification: Specification
    /// The display lives exactly as long as this reference. Letting it go is
    /// how the display is removed; there is no "close" call.
    ///
    /// "Exactly as long" has a caveat worth knowing before it is debugged: the
    /// framework returns these autoreleased, so the screen disappears when the
    /// pool drains rather than the instant the reference is cleared. Inside an
    /// application that is the next turn of the run loop and invisible. In a
    /// command-line probe with no pool it never happens at all, which reads
    /// exactly like a display that cannot be removed.
    private let display: NSObject
    private let queue: DispatchQueue

    private(set) var displayID: CGDirectDisplayID?

    init?(_ specification: Specification) {
        guard Self.isAvailable,
              let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor"),
              let displayClass = NSClassFromString("CGVirtualDisplay"),
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings"),
              let modeClass = NSClassFromString("CGVirtualDisplayMode"),
              let descriptor = Self.make(descriptorClass) as? NSObject,
              let settings = Self.make(settingsClass) as? NSObject
        else { return nil }

        self.specification = specification
        let queue = DispatchQueue(label: "com.n0ctal.zephyr.virtualdisplay")
        self.queue = queue

        descriptor.setValue(specification.name, forKey: "name")
        descriptor.setValue(specification.width, forKey: "maxPixelsWide")
        descriptor.setValue(specification.height, forKey: "maxPixelsHigh")
        // A plausible physical size, so macOS computes a sane pixel density
        // rather than treating the panel as microscopic.
        descriptor.setValue(NSValue(size: NSSize(width: 600, height: 340)),
                            forKey: "sizeInMillimeters")
        descriptor.setValue(0x5A45, forKey: "productID")   // "ZE"
        descriptor.setValue(0x5048, forKey: "vendorID")    // "PH"
        descriptor.setValue(1, forKey: "serialNum")
        // Without a queue the framework has nowhere to call back and the
        // display never finishes coming up.
        descriptor.setValue(queue, forKey: "queue")

        guard let mode = Self.makeMode(modeClass,
                                       width: UInt32(specification.width),
                                       height: UInt32(specification.height),
                                       refreshRate: specification.refreshRate)
        else { return nil }
        settings.setValue([mode], forKey: "modes")
        settings.setValue(specification.hiDPI, forKey: "hiDPI")

        // `initWithDescriptor:` hands back an object it has already retained;
        // taking it retained gives that reference to ARC, so letting this
        // object go is what removes the display. Taking it unretained would
        // leak the reference and the display would outlive its own settings.
        guard let raw = Self.allocate(displayClass),
              let created = raw.perform(NSSelectorFromString("initWithDescriptor:"),
                                        with: descriptor)?
                .takeRetainedValue() as? NSObject,
              created.perform(NSSelectorFromString("applySettings:"), with: settings) != nil
        else { return nil }

        self.display = created
        self.displayID = created.value(forKey: "displayID") as? CGDirectDisplayID
    }

    // MARK: The runtime dance

    /// Swift hides `+alloc`, and these classes have no Swift initialiser.
    private static func allocate(_ cls: AnyClass) -> AnyObject? {
        typealias Alloc = @convention(c) (AnyClass, Selector) -> AnyObject?
        let selector = NSSelectorFromString("alloc")
        guard let imp = class_getMethodImplementation(object_getClass(cls), selector)
        else { return nil }
        return unsafeBitCast(imp, to: Alloc.self)(cls, selector)
    }

    private static func make(_ cls: AnyClass) -> AnyObject? {
        allocate(cls)?.perform(NSSelectorFromString("init"))?.takeRetainedValue()
    }

    /// `initWithWidth:height:refreshRate:` takes scalars, and `perform` can
    /// only pass objects — so the implementation is called through a typed
    /// function pointer.
    private static func makeMode(_ cls: AnyClass, width: UInt32, height: UInt32,
                                 refreshRate: Double) -> AnyObject? {
        typealias ModeInit = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double)
            -> AnyObject?
        let selector = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard let raw = allocate(cls),
              let imp = class_getMethodImplementation(cls, selector) else { return nil }
        return unsafeBitCast(imp, to: ModeInit.self)(raw, selector, width, height, refreshRate)
    }
}
