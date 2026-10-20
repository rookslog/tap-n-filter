import Effects
import ViewModel

/// UI write boundary shared by the slider and its integration tests. A preset
/// can replace a node with the same UUID before the old view is torn down.
@MainActor
struct ParameterNodeWriter {
    let node: any EffectNode
    let parameter: EffectParameter
    let viewModel: AppViewModel

    func makeEditor() -> ParameterValueEditor {
        let model = viewModel
        let target = node
        let handle = model.makeParameterEditHandle(node: target, parameterID: parameter.identifier)
        let pending: () -> Float? = { [weak model] in
            guard let model, let handle else { return nil }
            return model.pendingParameterValue(for: handle)
        }
        // Defaults seed presentation only. Native nil remains nil on results.
        let initial = pending() ?? target.parameterValue(parameter.identifier) ?? parameter.defaultValue
        let parameterID = parameter.identifier
        let editor = ParameterValueEditor(
            parameter: parameter, initialValue: initial,
            readValue: { [weak target] in pending() ?? target?.parameterValue(parameterID) },
            onDragAccepted: { [weak model] value, revision in
                guard let model, let handle else { return }
                model.acceptParameterValue(value, for: handle, intentRevision: revision)
            },
            onCommitIntent: { [weak model] value, revision in
                guard let model, let handle else { return }
                model.commitParameterValue(value, for: handle, intentRevision: revision)
            },
            finishAcceptedDrag: { [weak model] in
                guard let model, let handle else { return }
                model.finishParameterEditing(handle)
            },
            stopAcceptedEditing: { [weak model] in
                guard let model, let handle else { return }
                model.retireParameterEditHandle(handle)
            },
            pendingAcceptedValue: pending,
            applicationSessionID: handle?.sessionID
        )
        handle?.setApplicationResultHandler { [weak editor] result in editor?.receiveApplicationResult(result) }
        return editor
    }
}
