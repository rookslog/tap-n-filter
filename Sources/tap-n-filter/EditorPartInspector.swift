import AppKit
import SoundModel
import SwiftUI

enum EditorSettingFormat {
    static func name(_ key: String) -> String {
        switch key {
        case "thresholdDb": return "Threshold"
        case "headroomDb": return "Headroom"
        case "expansionRatio": return "Expansion ratio"
        case "expansionThresholdDb": return "Expansion threshold"
        case "attackSeconds": return "Attack"
        case "releaseSeconds": return "Release"
        case "makeupDb": return "Makeup"
        default: return key
        }
    }
    static func factor(_ setting: LibraryEditSetting) -> Double { setting.unit == "s" ? 1000 : 1 }
    static func unit(_ setting: LibraryEditSetting) -> String { setting.unit == "s" ? "ms" : setting.unit }
    static func text(_ setting: LibraryEditSetting, precise: Bool = false) -> String {
        let value = setting.physicalValue * factor(setting)
        let digits = setting.parameter == "expansionRatio" ? 2 : (setting.parameter == "releaseSeconds" || setting.parameter == "expansionThresholdDb" ? 0 : 1)
        let number = precise ? String(value) : String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, value)
        return number + (setting.parameter == "expansionRatio" ? " : 1" : unit(setting).isEmpty ? "" : " " + unit(setting))
    }
    static func parse(_ text: String, setting: LibraryEditSetting) throws -> Double {
        var number = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "−", with: "-")
        let suffix = setting.parameter == "expansionRatio" ? ": 1" : unit(setting)
        if !suffix.isEmpty && number.hasSuffix(suffix) { number = String(number.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces) }
        guard let entered = Double(number), entered.isFinite else { throw LibraryError.unsupportedEdit }
        let physical = entered / factor(setting)
        _ = try setting.specification.normalized(physical)
        return physical
    }
    static func command(_ snapshot: LibraryEditSnapshot, part: UUID, key: String, physical: Double) throws -> LibraryEditCommand {
        guard let setting = snapshot.parts.first(where: { $0.id == part })?.settings.first(where: { $0.parameter == key }) else { throw LibraryError.unsupportedEdit }
        _ = try setting.specification.normalized(physical)
        return .setPhysical(part: part, parameter: key, value: physical)
    }
}

struct EditorSettingIdentity: Equatable {
    let handle: LibraryEditHandle
    let part: UUID
    let parameter: String
}
struct EditorSettingViewKey: Hashable {
    let handle: UUID
    let part: UUID
    let parameter: String
}

// A native instance can retire, never retarget. A new target gets a new keyed view.
struct EditorInteractionLifetime<Payload> {
    struct Ticket {
        let id: UUID
        let payload: Payload
    }
    private enum State { case idle, active(Ticket), retired }
    let identity: EditorSettingIdentity
    private var state = State.idle
    init(_ identity: EditorSettingIdentity) { self.identity = identity }
    var active: Ticket? { if case .active(let ticket) = state { return ticket }; return nil }
    var isRetired: Bool { if case .retired = state { return true }; return false }
    mutating func begin(_ payload: Payload) -> Ticket? {
        guard case .idle = state else { return nil }
        let ticket = Ticket(id: UUID(), payload: payload); state = .active(ticket); return ticket
    }
    func sample(_ id: UUID) -> Payload? { active.flatMap { $0.id == id ? $0.payload : nil } }
    mutating func finish(_ id: UUID) -> Ticket? {
        guard let ticket = active, ticket.id == id else { return nil }
        state = .idle; return ticket
    }
    mutating func update(_ identity: EditorSettingIdentity) -> Ticket? {
        guard identity != self.identity else { return nil }
        return retire()
    }
    mutating func retire() -> Ticket? {
        let ticket = active; state = .retired; return ticket
    }
}

enum EditorInspectorPolicy {
    static func allowsBypass(_ target: LibraryEditTarget, editing: Bool) -> Bool {
        if editing { return true }
        if case .use = target { return true }
        return false
    }
}

struct EditorPartInspector: View {
    let snapshot: LibraryEditSnapshot
    let selected: UUID
    let editing: Bool
    let blockTint: Color
    let send: (EditorPartEvent) -> Void
    private func emit(_ action: EditorPartAction) { send(EditorPartEvent(snapshot, action)) }
    var body: some View {
        Group {
            if let part = snapshot.parts.first(where: { $0.id == selected }), part.type == "dynamics" {
                VStack(spacing: 0) {
                    HStack(spacing: 9) {
                        Image(systemName: EditorPartPresentation.symbol(part.type))
                            .font(.system(size: 16)).foregroundStyle(Color.accentColor)
                            .frame(width: 26, height: 26)
                            .background(EditorPartPalette.tile, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                        Text(EditorPartPresentation.name(part.type)).font(.system(size: 14, weight: .semibold))
                        Spacer(minLength: 0)
                        if EditorInspectorPolicy.allowsBypass(snapshot.handle.target, editing: editing) {
                            Toggle("Evener", isOn: Binding(get: { !part.bypassed }, set: { emit(.command(.bypassPart(part.id, !$0))) }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(.accentColor)
                                .help("Bypass Evener")
                        } else { Color.clear.frame(width: 32, height: 19) }
                    }.frame(height: 32).padding(.bottom, 6)
                    ForEach(part.settings, id: \.parameter) { setting in
                        settingRow(part, setting)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(width: 320, height: 492, alignment: .top)
                .background(EditorPartPalette.inspector, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            }
        }
    }
    private func settingRow(_ part: LibraryEditPart, _ setting: LibraryEditSetting) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(setting.isChangedHere ? Color.accentColor : .clear).frame(width: 6, height: 6)
                    .help(setting.isChangedHere ? "Changed on this use" : "")
                Text(EditorSettingFormat.name(setting.parameter)).font(.system(size: 13)).fixedSize()
                HStack(spacing: 4) {
                    ForEach(setting.sourceControls, id: \.self) { id in
                        if let control = snapshot.controls.first(where: { $0.id == id }) {
                            Text(control.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                .foregroundStyle(blockTint).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(blockTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                                .help(control.title)
                        }
                    }
                }.layoutPriority(-1)
                Spacer(minLength: 0)
                EditorPhysicalField(identity: EditorSettingIdentity(handle: snapshot.handle, part: part.id, parameter: setting.parameter), setting: setting, enabled: editing, identifier: part.id.uuidString + ":" + setting.parameter) { text in
                    if let value = try? EditorSettingFormat.parse(text, setting: setting),
                       let command = try? EditorSettingFormat.command(snapshot, part: part.id, key: setting.parameter, physical: value) {
                        emit(.command(command))
                    }
                }.frame(width: 86, height: 22)
                if editing {
                    Button {
                        emit(.command(.showAtTop(part: part.id, parameter: setting.parameter, title: EditorSettingFormat.name(setting.parameter))))
                    } label: {
                        Image(systemName: setting.isShownAtTop ? "pin.fill" : "pin")
                            .font(.system(size: 11)).frame(width: 18, height: 18)
                            .foregroundStyle(setting.isShownAtTop ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain).help("Show at the Top")
                    .accessibilityLabel("Show " + EditorSettingFormat.name(setting.parameter) + " at the Top")
                } else { Color.clear.frame(width: 18, height: 18) }
            }.frame(height: 24)
            EditorFineSlider(identity: EditorSettingIdentity(handle: snapshot.handle, part: part.id, parameter: setting.parameter), setting: setting, enabled: editing, identifier: part.id.uuidString + ":" + setting.parameter) { phase in
                switch phase {
                case .begin(let id): emit(.begin(id))
                case .sample(let id, let physical):
                    if let command = try? EditorSettingFormat.command(snapshot, part: part.id, key: setting.parameter, physical: physical) {
                        if let id { emit(.sample(id, command)) } else { emit(.command(command)) }
                    }
                case .end(let id): emit(.end(id))
                case .cancel(let id): emit(.cancel(id))
                }
            }.frame(height: 18).padding(.leading, 12).padding(.trailing, 24)
        }
        .padding(.top, 4).frame(height: 52, alignment: .top)
        .overlay(alignment: .top) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.5) }
        .accessibilityElement(children: .contain)
        .id(EditorSettingViewKey(handle: snapshot.handle.id, part: part.id, parameter: setting.parameter))
    }
}

private struct EditorFieldCapture {
    let setting: LibraryEditSetting
    let commit: (String) -> Void
}
private struct EditorPhysicalField: NSViewRepresentable {
    let identity: EditorSettingIdentity
    let setting: LibraryEditSetting
    let enabled: Bool
    let identifier: String
    let commit: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false; field.isBezeled = true; field.bezelStyle = .roundedBezel
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.alignment = .right; field.delegate = context.coordinator
        field.setContentHuggingPriority(.required, for: .horizontal)
        return field
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        CGSize(width: 86, height: 22)
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        _ = coordinator.lifetime.update(identity)
        guard !coordinator.lifetime.isRetired else { coordinator.abort(field); field.isEnabled = false; return }
        coordinator.parent = self
        field.identifier = NSUserInterfaceItemIdentifier("field:" + identifier)
        field.isEnabled = enabled; field.setAccessibilityLabel(EditorSettingFormat.name(setting.parameter))
        if !enabled { coordinator.cancel(field) }
        if coordinator.lifetime.active == nil { field.stringValue = EditorSettingFormat.text(setting) }
    }
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        _ = coordinator.lifetime.retire(); coordinator.abort(field)
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: EditorPhysicalField
        var lifetime: EditorInteractionLifetime<EditorFieldCapture>
        init(_ parent: EditorPhysicalField) { self.parent = parent; lifetime = EditorInteractionLifetime(parent.identity) }
        func abort(_ field: NSTextField) {
            field.abortEditing(); field.stringValue = EditorSettingFormat.text(parent.setting)
        }
        func cancel(_ field: NSTextField) {
            if let ticket = lifetime.active { _ = lifetime.finish(ticket.id) }
            abort(field)
        }
        func controlTextDidBeginEditing(_ notification: Notification) {
            guard parent.enabled,
                  let ticket = lifetime.begin(EditorFieldCapture(setting: parent.setting, commit: parent.commit)) else { return }
            if let field = notification.object as? NSTextField, let editor = field.currentEditor() {
                editor.string = EditorSettingFormat.text(ticket.payload.setting, precise: true)
            }
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let current = lifetime.active, let ticket = lifetime.finish(current.id) else { return }
            ticket.payload.commit(field.stringValue)
            field.stringValue = EditorSettingFormat.text(parent.setting)
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)), let field = control as? NSTextField else { return false }
            cancel(field); return true
        }
    }
}

enum EditorSliderPhase {
    case begin(UUID), sample(UUID?, Double), end(UUID), cancel(UUID)
}
private struct EditorSliderCapture {
    let setting: LibraryEditSetting
    let start: Double
    let send: (EditorSliderPhase) -> Void
}
private struct EditorFineSlider: NSViewRepresentable {
    let identity: EditorSettingIdentity
    let setting: LibraryEditSetting
    let enabled: Bool
    let identifier: String
    let send: (EditorSliderPhase) -> Void
    func makeNSView(context: Context) -> EditorNativeSlider {
        let slider = EditorNativeSlider(identity)
        slider.isContinuous = true; slider.controlSize = .small
        slider.target = slider; slider.action = #selector(EditorNativeSlider.sample)
        return slider
    }
    func updateNSView(_ slider: EditorNativeSlider, context: Context) {
        if let old = slider.lifetime.update(identity) { old.payload.send(.cancel(old.id)) }
        guard !slider.lifetime.isRetired else { slider.isEnabled = false; return }
        slider.setting = setting; slider.send = send
        slider.identifier = NSUserInterfaceItemIdentifier("slider:" + identifier)
        slider.setAccessibilityLabel(EditorSettingFormat.name(setting.parameter))
        slider.minValue = (try? setting.specification.normalized(setting.specification.minimumInput)) ?? 0
        slider.maxValue = 1; slider.isEnabled = enabled
        if !enabled { slider.cancelActive() }
        if slider.lifetime.active == nil { slider.doubleValue = (try? setting.specification.normalized(setting.physicalValue)) ?? slider.minValue }
    }
    static func dismantleNSView(_ slider: EditorNativeSlider, coordinator: ()) {
        if let old = slider.lifetime.retire() { old.payload.send(.cancel(old.id)) }
    }
}
private final class EditorNativeSlider: NSSlider {
    var setting: LibraryEditSetting?
    var send: ((EditorSliderPhase) -> Void)?
    var lifetime: EditorInteractionLifetime<EditorSliderCapture>
    private var tracking: UUID?
    init(_ identity: EditorSettingIdentity) { lifetime = EditorInteractionLifetime(identity); super.init(frame: .zero) }
    required init?(coder: NSCoder) { return nil }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let setting, let send,
              let ticket = lifetime.begin(EditorSliderCapture(setting: setting, start: doubleValue, send: send)) else { return }
        tracking = ticket.id
        defer { tracking = nil }
        ticket.payload.send(.begin(ticket.id))
        super.mouseDown(with: event)
        if let ended = lifetime.finish(ticket.id) { ended.payload.send(.end(ended.id)) }
    }
    @objc func sample() {
        guard !lifetime.isRetired else { return }
        if let tracking {
            guard let payload = lifetime.sample(tracking) else { return }
            let p = NSEvent.modifierFlags.contains(.option) ? payload.start + (doubleValue - payload.start) / 10 : doubleValue
            if let physical = try? payload.setting.specification.physical(p) { payload.send(.sample(tracking, physical)) }
        } else if isEnabled, let setting, let physical = try? setting.specification.physical(doubleValue) {
            send?(.sample(nil, physical))
        }
    }
    func cancelActive() {
        guard let active = lifetime.active, let ticket = lifetime.finish(active.id) else { return }
        doubleValue = ticket.payload.start; ticket.payload.send(.cancel(ticket.id))
    }
    override func cancelOperation(_ sender: Any?) { cancelActive() }
}
