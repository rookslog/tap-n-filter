import AppKit
import SwiftUI

/// Momentary comparison with a local release handler and explicit interaction cancellation.
struct CompareButton: NSViewRepresentable {
    let available: Bool
    let comparing: Bool
    let cancelEpoch: UInt64
    let change: (Bool) -> Void
    var capsuleStyle = false

    func makeNSView(context: Context) -> HoldOriginalButton {
        let button = HoldOriginalButton()
        button.identifier = NSUserInterfaceItemIdentifier("compare")
        button.image = NSImage(systemSymbolName: "ear", accessibilityDescription: "Hold to hear original")
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.toolTip = "Hold to hear original"
        button.setAccessibilityLabel("Hold to hear original")
        return button
    }

    func updateNSView(_ button: HoldOriginalButton, context: Context) {
        if button.cancelEpoch != cancelEpoch { button.releasePress(); button.cancelEpoch = cancelEpoch }
        if !available { button.releasePress() }
        button.isEnabled = available
        if capsuleStyle {
            button.contentTintColor = comparing ? .white : available ? .labelColor : .secondaryLabelColor
        } else {
            button.contentTintColor = comparing ? .controlAccentColor : .secondaryLabelColor
        }
        button.change = change
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HoldOriginalButton, context: Context) -> CGSize? {
        capsuleStyle ? CGSize(width: 26, height: 26) : nil
    }
}

final class HoldOriginalButton: NSButton {
    private enum PressOrigin { case mouse, keyboard }
    var change: ((Bool) -> Void)?
    var cancelEpoch: UInt64 = 0
    private var origin: PressOrigin?
    private var releaseObservation: Timer?

    func releasePress() {
        releaseObservation?.invalidate()
        releaseObservation = nil
        guard origin != nil else { return }
        origin = nil
        isHighlighted = false
        change?(false)
    }

    private func beginPress(_ next: PressOrigin) {
        guard isEnabled, origin == nil else { return }
        origin = next
        isHighlighted = true
        change?(true)
        guard next == .mouse else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.observeMouseRelease()
            }
        }
        releaseObservation = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func observeMouseRelease() {
        guard origin == .mouse else { releaseObservation?.invalidate(); releaseObservation = nil; return }
        guard let window, window.isVisible else { releasePress(); return }
        let ear = window.convertToScreen(convert(bounds, to: nil))
        if NSEvent.pressedMouseButtons & 1 == 0 || !ear.contains(NSEvent.mouseLocation) { releasePress() }
    }

    override func mouseDown(with event: NSEvent) { beginPress(.mouse) }
    override func mouseUp(with event: NSEvent) { releasePress() }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, event.keyCode == 49 || event.keyCode == 36 else {
            super.keyDown(with: event)
            return
        }
        if !event.isARepeat { beginPress(.keyboard) }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { releasePress() }
        else { super.keyUp(with: event) }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { releasePress() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func resignFirstResponder() -> Bool {
        releasePress()
        return super.resignFirstResponder()
    }
}
