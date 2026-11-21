import Foundation

struct BigSpace: BuiltinSound {
    let kind = BuiltinBlock.bigSpace
    let root: RootUseID
    let definition: BlockDefinition
    let presentation: [ListeningControl]

    init() throws {
        var recipe = BuiltinRecipe(namespace: 3)
        try recipe.part(32, type: "placeEQ", values: ["lowPassHz": 11_000])
        try recipe.part(33, type: "reverb", values: ["roomPreset": 4, "roomSize": 0.5, "wetPercent": 32])
        try recipe.part(34, type: "gain", values: ["gainDb": -1])
        try recipe.choice(16, title: "Space", options: [(64, "Hall"), (65, "Church")])
        try recipe.volume(gain: 34)
        try recipe.slider(20, title: "Where you stand", ends: ("Front", "Back"), parent: 16, option: 64)
        try recipe.slider(21, title: "Where you stand", ends: ("Front", "Back"), parent: 16, option: 65)
        try recipe.map(16, part: 32, parameter: "lowPassHz", values: [11_000, 9_000])
        try recipe.map(16, part: 33, parameter: "roomPreset", values: [4, 5])
        try recipe.map(16, part: 33, parameter: "wetPercent", values: [32, 42])
        try recipe.map(16, part: 34, parameter: "gainDb", values: [-1, -1.5])
        try recipe.map(20, part: 32, parameter: "lowPassHz", values: [16_000, 11_000, 7_000], reference: 11_000)
        try recipe.map(20, part: 33, parameter: "wetPercent", values: [15, 32, 55], reference: 32)
        try recipe.map(20, part: 34, parameter: "gainDb", values: [0, -1, -2.5], reference: -1)
        try recipe.map(21, part: 32, parameter: "lowPassHz", values: [14_000, 9_000, 5_500], reference: 9_000)
        try recipe.map(21, part: 33, parameter: "wetPercent", values: [22, 42, 68], reference: 42)
        try recipe.map(21, part: 34, parameter: "gainDb", values: [0, -1.5, -3], reference: -1.5)
        root = recipe.id(3)
        definition = recipe.definition("Big space")
        presentation = recipe.presentation
    }
    func nativeValue(type: String, parameter: ParameterKey, position: Position) throws -> Double {
        try BuiltinRecipe.domain(type, parameter.rawValue).value(position)
    }
}
