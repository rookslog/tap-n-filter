import Foundation

struct OldRecording: BuiltinSound {
    let kind = BuiltinBlock.oldRecording
    let root: RootUseID
    let definition: BlockDefinition
    let presentation: [ListeningControl]

    init() throws {
        var recipe = BuiltinRecipe(namespace: 4)
        try recipe.part(32, type: "deviceEQ", values: ["highPassHz": 280, "lowPassHz": 3_200])
        try recipe.part(33, type: "deviceColour", values: ["factoryPreset": 1, "preGainDb": -6, "wetPercent": 12])
        try recipe.part(34, type: "dynamics", values: [:])
        try recipe.part(35, type: "gain", values: ["gainDb": 0])
        try recipe.choice(16, title: "Era", options: [(64, "Shellac"), (65, "Vinyl"), (66, "Tape")])
        try recipe.volume(gain: 35)
        try recipe.slider(20, title: "Wear", ends: ("New", "Worn"), parent: 16, option: 65)
        try recipe.slider(21, title: "Wear", ends: ("New", "Worn"), parent: 16, option: 66)
        try recipe.map(16, part: 32, parameter: "highPassHz", values: [280, 65, 50])
        try recipe.map(16, part: 32, parameter: "lowPassHz", values: [3_200, 8_000, 9_000])
        try recipe.map(16, part: 33, parameter: "wetPercent", values: [12, 4, 3])
        try recipe.map(16, part: 35, parameter: "gainDb", values: [0, 0, 0])
        try recipe.map(16, part: 34, parameter: "thresholdDb", values: [20, 20, -19])
        try recipe.map(16, part: 34, parameter: "headroomDb", values: [40, 40, 8])
        try recipe.map(16, part: 34, parameter: "attackSeconds", values: [0.001, 0.001, 0.01])
        try recipe.map(16, part: 34, parameter: "releaseSeconds", values: [0.18, 0.18, 0.15])
        try recipe.map(16, part: 34, parameter: "makeupDb", values: [0, 0, 2])
        try recipe.map(20, part: 32, parameter: "highPassHz", values: [40, 65, 110], reference: 65)
        try recipe.map(20, part: 32, parameter: "lowPassHz", values: [12_000, 8_000, 5_200], reference: 8_000)
        try recipe.map(20, part: 33, parameter: "wetPercent", values: [0, 4, 10], reference: 4)
        try recipe.map(21, part: 32, parameter: "highPassHz", values: [35, 50, 70], reference: 50)
        try recipe.map(21, part: 32, parameter: "lowPassHz", values: [13_500, 9_000, 5_800], reference: 9_000)
        try recipe.map(21, part: 33, parameter: "wetPercent", values: [0, 3, 8], reference: 3)
        try recipe.map(21, part: 34, parameter: "thresholdDb", values: [-14, -19, -24], reference: -19)
        try recipe.map(21, part: 34, parameter: "headroomDb", values: [12, 8, 5], reference: 8)
        root = recipe.id(3)
        definition = recipe.definition("Old recording")
        presentation = recipe.presentation
    }
    func nativeValue(type: String, parameter: ParameterKey, position: Position) throws -> Double {
        try BuiltinRecipe.domain(type, parameter.rawValue).value(position)
    }
}
