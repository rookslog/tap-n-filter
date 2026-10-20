import AppKit
import Foundation
import SwiftUI
import UI

/// Native source-backed rendering. Does not use ImageRenderer or a redrawn panel.
@MainActor
enum NativePanelRenderer {
    enum Theme: String, CaseIterable {
        case light, dark
        var shade: Double { self == .light ? 1 : 0.12 }
        var colorScheme: ColorScheme { self == .light ? .light : .dark }
        var appearanceName: NSAppearance.Name { self == .light ? .aqua : .darkAqua }
        var background: Color { Color(red: shade, green: shade, blue: shade) }
    }

    static func render(
        fixture: EvidenceFixture, theme: Theme, directory: URL
    ) async throws -> EvidenceManifest.Image {
        try await fixture.waitForState()
        let root = ControlPanelView()
            .environmentObject(fixture.model)
            .environment(\.colorScheme, theme.colorScheme)
            .background(theme.background)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: theme.appearanceName)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let width = hosting.widthAnchor.constraint(equalToConstant: 380)
        width.isActive = true
        let identity = String(describing: ObjectIdentifier(hosting))
        // The 1pt initial window is NOT the render height. Raw fittingSize must
        // pass the floor/cap checks before this same host is sized for capture.
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 380, height: 1),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.appearance = hosting.appearance
        window.isOpaque = true
        window.backgroundColor = NSColor(
            srgbRed: theme.shade, green: theme.shade, blue: theme.shade, alpha: 1
        )
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil) // Offscreen only; never activate or make key.
        defer {
            window.orderOut(nil)
            width.isActive = false
            window.contentView = nil
            window.close()
        }

        let measured = try await fittingHeight(of: hosting, fixture: fixture)
        let height = Int(ceil(measured))
        window.setContentSize(NSSize(width: 380, height: CGFloat(height)))
        hosting.setFrameSize(NSSize(width: 380, height: CGFloat(height)))
        // Let native children materialize in the same host after final sizing.
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        try fixture.validate()
        guard abs(hosting.fittingSize.height - measured) <= 1 else {
            throw EvidenceError.invalid("Fitting height changed after measured sizing")
        }
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw EvidenceError.invalid("Could not allocate native cache bitmap")
        }
        hosting.displayIfNeeded()
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let cached = bitmap.cgImage,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let backgroundColor = CGColor(
                colorSpace: colorSpace, components: [theme.shade, theme.shade, theme.shade, 1]
              ),
              let context = CGContext(
                data: nil, width: 380, height: height, bitsPerComponent: 8, bytesPerRow: 380 * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            throw EvidenceError.invalid("Native cache or sRGB normalization failed")
        }
        // Transparent text/control caches can look absent over a black preview.
        // Explicit opaque presentation preserves the native pixels and records
        // the theme background; no synthetic replacement controls are drawn.
        context.setFillColor(backgroundColor)
        let bounds = CGRect(x: 0, y: 0, width: 380, height: CGFloat(height))
        context.fill(bounds)
        context.draw(cached, in: bounds)
        guard let normalized = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: normalized).representation(using: .png, properties: [:]),
              !png.isEmpty else {
            throw EvidenceError.invalid("Could not encode opaque PNG")
        }
        let observed = try fixture.observation()
        let renderedIdentity = String(describing: ObjectIdentifier(hosting))
        guard renderedIdentity == identity else { throw EvidenceError.invalid("Host identity changed") }
        let file = "control-panel-\(fixture.state.rawValue)-\(theme.rawValue).png"
        try png.write(to: directory.appendingPathComponent(file), options: .atomic)
        return EvidenceManifest.Image(
            file: file, state: fixture.state.rawValue, theme: theme.rawValue,
            widthPoints: 380, fittingHeightPoints: Double(measured),
            pixelWidth: normalized.width, pixelHeight: normalized.height,
            preparedViewIdentity: identity, renderedViewIdentity: renderedIdentity, observed: observed,
            backgroundRGB: [theme.shade, theme.shade, theme.shade]
        )
    }

    private static func fittingHeight<V: View>(
        of hosting: NSHostingView<V>, fixture: EvidenceFixture
    ) async throws -> CGFloat {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        var previous: CGFloat?
        var stableSamples = 0
        repeat {
            try await Task.sleep(for: .milliseconds(50))
            hosting.layoutSubtreeIfNeeded()
            try fixture.validate()
            let measured = hosting.fittingSize
            let cap: CGFloat = fixture.model.showSettings ? 900 : 700
            guard measured.width.isFinite, abs(measured.width - 380) <= 1,
                  measured.height.isFinite, measured.height >= 420, measured.height <= cap else {
                throw EvidenceError.invalid("Raw fitting size outside 380pt/floor/cap contract: \(measured)")
            }
            stableSamples = previous.map { abs($0 - measured.height) < 0.1 } == true ? stableSamples + 1 : 0
            previous = measured.height
            if stableSamples >= 2 { return measured.height }
        } while clock.now < deadline
        throw EvidenceError.invalid("Native fitting height did not stabilize within two seconds")
    }
}
