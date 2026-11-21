import Foundation

struct Underwater: BuiltinSound {
    let kind = BuiltinBlock.underwater
    let root: RootUseID
    let definition: BlockDefinition
    let presentation: [ListeningControl]

    init() throws {
        var recipe = BuiltinRecipe(namespace: 5)
        try recipe.part(32, type: "placeEQ", values: ["lowPassHz": 1_100])
        try recipe.part(33, type: "reverb", values: ["roomPreset": 3, "roomSize": 0.5, "wetPercent": 12])
        try recipe.part(34, type: "gain", values: ["gainDb": 0])
        try recipe.slider(16, title: "Depth", ends: ("Surface", "Deep"))
        try recipe.volume(gain: 34)
        try recipe.map(16, part: 32, parameter: "lowPassHz", values: [20_000, 1_100, 280])
        try recipe.map(16, part: 33, parameter: "wetPercent", values: [0, 12, 25])
        try recipe.map(16, part: 34, parameter: "gainDb", values: [0, 0, 0])
        root = recipe.id(3)
        definition = recipe.definition("Underwater")
        presentation = recipe.presentation
    }
    func nativeValue(type: String, parameter: ParameterKey, position: Position) throws -> Double {
        try BuiltinRecipe.domain(type, parameter.rawValue).value(position)
    }
}
