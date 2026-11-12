import Foundation

struct MenuChoiceAction {
    private(set) var options: [MenuSoundOption] = []
    private var callback: ((MenuSoundOption) -> Void)?
    mutating func update(_ options: [MenuSoundOption], callback: @escaping (MenuSoundOption) -> Void) {
        self.options = options
        self.callback = callback
    }
    func activate(_ index: Int) {
        guard options.indices.contains(index) else { return }
        callback?(options[index])
    }
}

struct MenuChoiceConfiguration {
    struct Content: Equatable {
        let id: UUID
        let title: String
        let symbol: String?
    }
    struct Changes {
        let count: Bool
        let content: [Int]
        let order: Bool
        let hints: Set<UUID>
    }
    private(set) var content: [Content] = []
    private var hints: [UUID: String] = [:]

    mutating func update(_ options: [MenuSoundOption], hints: [UUID: String]) -> Changes {
        let symbols = options.allSatisfy { optionSymbol($0.id) != nil }
        let next = options.map { Content(id: $0.id, title: $0.title, symbol: symbols ? optionSymbol($0.id) : nil) }
        let changes = Changes(count: next.count != content.count,
            content: next.indices.filter { !content.indices.contains($0) || content[$0] != next[$0] },
            order: next.map(\.id) != content.map(\.id),
            hints: Set(next.filter { hints[$0.id] != self.hints[$0.id] }.map(\.id)))
        content = next
        self.hints = hints
        return changes
    }
}
