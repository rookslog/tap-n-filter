import Foundation

#if canImport(SoundModel)
    @testable import SoundModel
#endif

struct PositionCases: Sendable {
    func test_positions_reject_nonfinite_and_out_of_range_input() throws {
        for value in [-Double.infinity, -0.01, 1.01, Double.infinity, Double.nan] {
            try requireThrows(try Position(value))
        }
        for value in [0.0, 0.42, 1.0] {
            try requireEqual(try Position(value).value, value)
        }
    }

    func test_decoding_cannot_bypass_position_validation() throws {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan"
        )
        for text in ["-0.01", "1.01", "\"inf\"", "\"-inf\"", "\"nan\""] {
            try requireThrows(try decoder.decode(Position.self, from: Data(text.utf8)))
        }
        let position = try Position(0.37)
        try requireEqual(try decoder.decode(Position.self, from: JSONEncoder().encode(position)), position)
    }

    func test_choices_of_any_size_use_positions_and_permanent_option_ids() throws {
        for count in [2, 3, 5, 17] {
            let options = (0..<count).map { _ in OptionID() }
            let choice = try Choice(options: options)
            for (index, option) in options.enumerated() {
                let position = try choice.position(of: option)
                try requireEqual(position.value, Double(index) / Double(count - 1))
                try requireEqual(choice.option(at: position), option)
            }
            try requireEqual(choice.option(at: .start), options.first)
            try requireEqual(choice.option(at: .end), options.last)
            try requireEqual(
                try JSONDecoder().decode(Choice.self, from: JSONEncoder().encode(choice)), choice)
        }
    }

    func test_invalid_choices_are_rejected_on_construction_and_decode() throws {
        let id = OptionID()
        for options in [[OptionID](), [id], [id, id]] {
            try requireThrows(try Choice(options: options))
            let bytes = try JSONEncoder().encode(options)
            try requireThrows(try JSONDecoder().decode(Choice.self, from: bytes))
        }
        try requireThrows(try Choice(options: [OptionID(), OptionID()]).position(of: OptionID()))
    }
}
