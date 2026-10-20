import AVFoundation
import AppKit
import ApplicationServices
import Capture
import Combine
import Effects
import Foundation
import Graph
import SwiftUI
import UI
import ViewModel

// MARK: Accessibility tree dump utility
//
// Phase 3 produces `test-artifacts/phase-3-accessibility-tree.json` as the
// programmatic accessibility audit's evidence. The same walk lives in
// `Tests/AccessibilityTreeTests/AccessibilityTreeTests.swift` (via XCTest),
// and a CI run with full Xcode regenerates the artifact from the test side.
//
// This executable exists because the SwiftPM-only build environment used
// during phase development does not ship XCTest (only Command Line Tools is
// installed, not full Xcode). Without XCTest the test target cannot run, and
// the artifact would never land in the repo. Running this executable produces
// the same JSON via the same NSHostingView walk, and ADR-011 documents the
// SwiftPM/XCUI workaround in detail.

@MainActor
func runDump() {
    // UserDefaults(suiteName:) returns nil only for invalid names; "tnf.a11y.dump"
    // is a valid identifier. The guard satisfies the no-force-unwrap rule from
    // docs/governance/coding-standards.md and gives a clear error path if the
    // SDK ever changes the validity rules.
    guard let defaults = UserDefaults(suiteName: "tnf.a11y.dump") else {
        FileHandle.standardError.write(Data("Failed: could not create UserDefaults suite tnf.a11y.dump\n".utf8))
        exit(1)
    }
    defaults.removePersistentDomain(forName: "tnf.a11y.dump")
    let capture = StubCaptureController()
    let model = AppViewModel(
        capture: capture,
        engine: AVAudioEngine(),
        registry: EffectNodeRegistry(),
        defaults: defaults
    )
    while !model.graph.nodes.isEmpty {
        model.removeEffect(at: 0)
    }
    model.addEffect(of: "tnf.eq")
    model.addEffect(of: "tnf.reverb")

    let root = ControlPanelView().environmentObject(model)
    let hosting = NSHostingView(rootView: root)
    // Match the real panel size (ControlPanelView + docs/specs/ui.md) so the
    // regenerated accessibility tree reflects the dimensions users actually
    // get. Kept in sync with the snapshot helper's render size.
    // (Codex PR #11 review.)
    hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 700)

    // The accessibility tree only populates when the view is hosted inside a
    // real NSWindow that has been ordered front. We park a borderless,
    // off-screen window for the duration of the dump and run the runloop
    // briefly so SwiftUI's accessibility wiring catches up.
    let window = NSWindow(
        contentRect: hosting.frame,
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.contentView = hosting
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000)) // off-screen
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    // Expand the first effect so the parameter controls render in the dump.
    if let first = model.graph.nodes.first {
        model.expandedEffectID = first.id
    }
    hosting.layoutSubtreeIfNeeded()
    // SwiftUI's layout + accessibility wiring is async; spin the runloop
    // generously so child labels populate before we walk the tree.
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))

    // Walk the in-process accessibility tree via NSView's KVC-style API.
    //
    // We deliberately do NOT use the public AXUIElement API (the one VoiceOver
    // and Accessibility Inspector use) because it requires the Process Trust
    // privilege the host process does not have when run as a CLI. AXUIElement
    // returns an empty tree in that case. The KVC API surfaces SwiftUI's
    // synthesized accessibility shadow tree in-process without permissions.
    //
    // The trade-off: SwiftUI's `.accessibilityLabel(_:)` modifier does not
    // always populate AXDescription on the in-process tree (it lands in
    // various places depending on the underlying control). The KVC tree may
    // omit controls; compare it with the same-view PNG rather than assuming
    // completeness. The manual VoiceOver pass and a CI XCTest run
    // (with full Xcode + AXUIElement permission) are the authoritative
    // checks. See ADR-011 for the broader rationale.
    hosting.layoutSubtreeIfNeeded()
    hosting.displayIfNeeded()
    let tree = AccessibilityNode.dump(from: hosting)

    // Capture the very same expanded-EQ hosting view while its offscreen
    // window is still ordered. Compare this image to the KVC tree; successful
    // encoding alone does not establish that controls are visible or exposed.
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds),
          bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else {
        FileHandle.standardError.write(Data("Failed: no bitmap for hosted accessibility PNG\n".utf8))
        exit(1)
    }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]), !png.isEmpty else {
        FileHandle.standardError.write(Data("Failed: hosted accessibility PNG is missing or empty\n".utf8))
        exit(1)
    }
    window.orderOut(nil)

    // Wrap the tree with a small metadata header so the verification subagent
    // can read the env caveats without cross-referencing the ADR. Counts of
    // interactive elements (sliders, popups, buttons) give the auditor a
    // quick structural sanity check.
    //
    // The committed artifact is deterministic: only stable fields land in
    // `phase-3-accessibility-tree.json`. The volatile metadata (timestamp,
    // host macOS version) goes to a sidecar `phase-3-accessibility-diagnostics.json`
    // that is gitignored, so regenerating the tree on a different host or
    // at a different time doesn't churn the committed file when nothing about
    // the accessibility tree itself has changed.
    let dump = DumpDocument(
        environment: DumpDocument.Environment(
            hostingMode: "in-process NSHostingView (no AXUIElement permission)",
            adrReference: "docs/decisions/ADR-011-no-xcui-in-spm.md"
        ),
        counts: tree.interactiveCounts(),
        tree: tree
    )
    let diagnostics = DiagnosticsDocument(
        generatedAt: ISO8601DateFormatter().string(from: Date()),
        macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        pngFilename: "phase-3-accessibility-panel.png",
        viewWidthPoints: Double(hosting.bounds.width),
        viewHeightPoints: Double(hosting.bounds.height),
        imagePixelWidth: bitmap.pixelsWide,
        imagePixelHeight: bitmap.pixelsHigh,
        captureMethod: "Same NSHostingView, AppKit cacheDisplay(in:to:)",
        treeLimitation: "KVC may omit controls; compare the hosted PNG and tree. VoiceOver remains manual."
    )
    let outURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("test-artifacts/phase-3-accessibility-tree.json")
    let diagnosticsURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("test-artifacts/phase-3-accessibility-diagnostics.json")
    let imageURL = outURL.deletingLastPathComponent().appendingPathComponent(diagnostics.pngFilename)
    try? FileManager.default.createDirectory(
        at: outURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        let data = try encoder.encode(dump)
        try data.write(to: outURL)
        FileHandle.standardOutput.write(Data("Wrote \(outURL.path)\n".utf8))
        try png.write(to: imageURL)
        FileHandle.standardOutput.write(Data("Wrote \(imageURL.path)\n".utf8))
        let diagnosticsData = try encoder.encode(diagnostics)
        try diagnosticsData.write(to: diagnosticsURL)
        FileHandle.standardOutput.write(Data("Wrote \(diagnosticsURL.path)\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("Failed: \(error)\n".utf8))
        exit(1)
    }
}

struct DumpDocument: Codable {
    struct Environment: Codable {
        let hostingMode: String
        let adrReference: String
    }
    struct Counts: Codable {
        let totalNodes: Int
        let interactiveElements: Int
        let sliders: Int
        let buttons: Int
        let popUpButtons: Int
        let nodesWithLabel: Int
        let nodesWithValue: Int
    }
    let environment: Environment
    let counts: Counts
    let tree: AccessibilityNode
}

/// Sidecar that captures volatile diagnostic metadata (timestamp, host
/// macOS version) so the committed tree artifact stays deterministic.
/// This file is gitignored; it's only useful when triaging a specific
/// run that the CI/dev environment produced.
struct DiagnosticsDocument: Codable {
    let generatedAt: String
    let macOSVersion: String
    let pngFilename: String
    let viewWidthPoints: Double
    let viewHeightPoints: Double
    let imagePixelWidth: Int
    let imagePixelHeight: Int
    let captureMethod: String
    let treeLimitation: String
}

struct AccessibilityNode: Codable {
    let role: String?
    let label: String?
    let value: String?
    let help: String?
    let identifier: String?
    let children: [AccessibilityNode]

    func interactiveCounts() -> DumpDocument.Counts {
        var total = 0
        var interactive = 0
        var sliders = 0
        var buttons = 0
        var popups = 0
        var withLabel = 0
        var withValue = 0
        var stack: [AccessibilityNode] = [self]
        while let node = stack.popLast() {
            total += 1
            stack.append(contentsOf: node.children)
            switch node.role {
            case "AXButton", "AXMenuButton", "AXCheckBox", "AXRadioButton":
                interactive += 1
                buttons += 1
            case "AXSlider":
                interactive += 1
                sliders += 1
            case "AXPopUpButton":
                interactive += 1
                popups += 1
            case "AXSwitch", "AXTextField", "AXIncrementor", "AXStepper":
                interactive += 1
            default:
                break
            }
            if let l = node.label, !l.isEmpty { withLabel += 1 }
            if let v = node.value, !v.isEmpty { withValue += 1 }
        }
        return DumpDocument.Counts(
            totalNodes: total,
            interactiveElements: interactive,
            sliders: sliders,
            buttons: buttons,
            popUpButtons: popups,
            nodesWithLabel: withLabel,
            nodesWithValue: withValue
        )
    }

    static func dump(from element: Any, depth: Int = 0) -> AccessibilityNode {
        // KVC-style accessibility readers reflect SwiftUI's synthesized
        // accessibility shadow tree more completely than the modern instance
        // methods on NSView do — the instance methods only surface what the
        // top-level NSHostingView itself implements, whereas
        // `accessibilityAttributeValue:` and `AXChildren` traverse through to
        // the SwiftUI-synthesized children. We use KVC throughout.
        let role = readString(element, attribute: "AXRole")
        let label = readString(element, attribute: "AXDescription")
            ?? readString(element, attribute: "AXTitle")
            ?? readString(element, attribute: "AXLabel")
            ?? readTitleUIElementString(element)
        let value = readString(element, attribute: "AXValue")
        let help = readString(element, attribute: "AXHelp")
        let identifier = readString(element, attribute: "AXIdentifier")
        let rawChildren: [Any]
        if depth < 12, let arr = readValue(element, attribute: "AXChildren") as? [Any] {
            rawChildren = arr
        } else {
            rawChildren = []
        }
        let children = rawChildren.map { child in
            AccessibilityNode.dump(from: child, depth: depth + 1)
        }
        return AccessibilityNode(
            role: role,
            label: label,
            value: value,
            help: help,
            identifier: identifier,
            children: children
        )
    }

    private static func readString(_ element: Any, attribute: String) -> String? {
        let raw = readValue(element, attribute: attribute)
        if let str = raw as? String, !str.isEmpty { return str }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    private static func readValue(_ element: Any, attribute: String) -> Any? {
        let selector = NSSelectorFromString("accessibilityAttributeValue:")
        guard let obj = element as? NSObject, obj.responds(to: selector) else { return nil }
        return obj.perform(selector, with: attribute)?.takeUnretainedValue()
    }

    /// Some SwiftUI controls expose their label through `AXTitleUIElement`,
    /// which points at a sibling `AXStaticText` whose AXValue carries the
    /// text. Follow the pointer and return the sibling's value when present.
    private static func readTitleUIElementString(_ element: Any) -> String? {
        guard let titleElement = readValue(element, attribute: "AXTitleUIElement") else {
            return nil
        }
        return readString(titleElement, attribute: "AXValue")
            ?? readString(titleElement, attribute: "AXTitle")
            ?? readString(titleElement, attribute: "AXDescription")
    }

    // MARK: AXUIElement walker

    /// Walk an `AXUIElement` (the AXUIElement API used by VoiceOver and the
    /// Accessibility Inspector) recursively. This surface surfaces SwiftUI's
    /// fully-synthesized accessibility tree.
    static func dump(axElement element: AXUIElement, depth: Int = 0) -> AccessibilityNode {
        let role = readAXString(element, attribute: kAXRoleAttribute as CFString)
        let label = readAXString(element, attribute: kAXDescriptionAttribute as CFString)
            ?? readAXString(element, attribute: kAXTitleAttribute as CFString)
            ?? readAXString(element, attribute: "AXLabel" as CFString)
        let value = readAXString(element, attribute: kAXValueAttribute as CFString)
        let help = readAXString(element, attribute: kAXHelpAttribute as CFString)
        let identifier = readAXString(element, attribute: kAXIdentifierAttribute as CFString)

        let rawChildren: [AXUIElement]
        if depth < 16, let arr = readAXChildren(element) {
            rawChildren = arr
        } else {
            rawChildren = []
        }
        let children = rawChildren.map { child in
            AccessibilityNode.dump(axElement: child, depth: depth + 1)
        }
        return AccessibilityNode(
            role: role,
            label: label,
            value: value,
            help: help,
            identifier: identifier,
            children: children
        )
    }

    private static func readAXString(_ element: AXUIElement, attribute: CFString) -> String? {
        var raw: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &raw)
        guard result == .success, let raw else { return nil }
        if let s = raw as? String, !s.isEmpty { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return String(describing: raw)
    }

    private static func readAXChildren(_ element: AXUIElement) -> [AXUIElement]? {
        var raw: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw)
        guard result == .success, let raw else { return nil }
        return raw as? [AXUIElement]
    }
}

final class StubCaptureController: CaptureControllerProtocol, @unchecked Sendable {
    private let subject = CurrentValueSubject<CaptureState, Never>(.idle)
    var state: CaptureState { subject.value }
    var statePublisher: AnyPublisher<CaptureState, Never> { subject.eraseToAnyPublisher() }
    var captureSourceNode: AVAudioSourceNode? { nil }
    func availableSources() throws -> [CaptureSource] { [] }
    func start(source: CaptureSource, into engine: AVAudioEngine) throws {}
    func stop() throws {}
}

// AppKit needs an NSApplication instance up before any window is created.
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)

// Drive the dump from the main runloop and block until it finishes. The
// previous "spin for 1.5 s and exit" approach truncated the dump on slower
// CI / GUI sessions, where window creation + AX-tree population can easily
// exceed that budget and the JSON file would be empty or partial. Use a
// semaphore signaled by `runDump()` so we exit immediately on completion
// and only time out as a last resort.
let dumpSemaphore = DispatchSemaphore(value: 0)
DispatchQueue.main.async {
    runDump()
    dumpSemaphore.signal()
}
// Spin the runloop until the dump signals — RunLoop must run for the
// dispatch-async block to fire, but DispatchSemaphore.wait blocks the
// thread, so we cannot just call wait() here. The until-loop idiom keeps
// the runloop alive in 50 ms slices.
let dumpDeadline = Date(timeIntervalSinceNow: 30.0)
while dumpSemaphore.wait(timeout: .now()) == .timedOut {
    if Date() >= dumpDeadline {
        FileHandle.standardError.write(Data("Failed: dump did not complete within 30s\n".utf8))
        exit(1)
    }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
}

