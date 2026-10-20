import Combine
import Effects
import ViewModel

/// Retained SwiftUI state outlives individual appearances. Each appearance
/// after retirement needs a new editor/handle, never a revived terminal one.
@MainActor
final class ParameterEditorSession: ObservableObject {
    @Published private(set) var editor: ParameterValueEditor?

    private weak var viewModel: AppViewModel?
    private weak var node: (any EffectNode)?
    private let parameter: EffectParameter

    init(writer: ParameterNodeWriter) {
        viewModel = writer.viewModel
        node = writer.node
        parameter = writer.parameter
    }

    func appear() {
        guard editor == nil, let viewModel, let node,
              viewModel.graph.nodes.contains(where: { $0 === node }),
              node.parameters.contains(where: { $0.identifier == parameter.identifier }) else { return }
        // The default writer creates a handle for the current graph generation.
        // A same-UUID replacement is not this concrete target and cannot renew.
        editor = ParameterNodeWriter(node: node, parameter: parameter, viewModel: viewModel).makeEditor()
    }

    func disappear() {
        guard let editor else { return }
        editor.stop() // Flush accepted input once, retire, then discard numeric draft.
        self.editor = nil
    }
}
