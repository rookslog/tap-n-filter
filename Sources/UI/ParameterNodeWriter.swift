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
        let successful: () -> ParameterSuccessfulPresentation? = { handle?.successfulPresentation }
        let latestStarted: () -> UInt64? = { handle?.latestStartedOperationOrder }
        // Preserve the pending-first short circuit: do not read native state
        // just to seed fallback while accepted input already supplies display.
        let initialPending = pending()
        let initialActual = initialPending == nil ? target.parameterValue(parameter.identifier) : nil
        let initial = initialPending ?? initialActual ?? successful()?.value ?? parameter.defaultValue
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
            applicationSessionID: handle?.sessionID,
            initialActual: initialActual,
            successfulPresentation: successful,
            latestStartedOperationOrder: latestStarted
        )
        handle?.setApplicationResultHandler { [weak editor] result in editor?.receiveApplicationResult(result) }
        return editor
    }
}
