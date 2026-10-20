import Effects
import ViewModel

/// UI write boundary shared by the slider and its integration tests. A preset
/// can replace a node with the same UUID before the old view is torn down.
@MainActor
struct ParameterNodeWriter {
    let node: any EffectNode
    let parameter: EffectParameter
    let viewModel: AppViewModel

    func makeEditor(
        scheduleDrag: ((@escaping () -> Void) -> Void)? = nil
    ) -> ParameterValueEditor {
        // A default seeds presentation only; verification must preserve nil.
        let initialValue = readValue() ?? parameter.defaultValue
        if let scheduleDrag {
            return ParameterValueEditor(
                parameter: parameter, initialValue: initialValue, onCommit: write,
                readValue: readValue, scheduleDrag: scheduleDrag
            )
        }
        return ParameterValueEditor(
            parameter: parameter, initialValue: initialValue, onCommit: write, readValue: readValue
        )
    }

    private func write(_ value: Float) {
        guard let current = viewModel.graph.nodes.first(where: { $0.id == node.id }),
              ObjectIdentifier(current) == ObjectIdentifier(node) else { return }
        // Keep broad readback-observer notification; this is not a VM
        // observation refactor. Identity is checked at delivery, not creation.
        viewModel.objectWillChange.send()
        viewModel.updateParameter(nodeID: node.id, paramID: parameter.identifier, value: value)
    }

    private func readValue() -> Float? {
        node.parameterValue(parameter.identifier)
    }
}
