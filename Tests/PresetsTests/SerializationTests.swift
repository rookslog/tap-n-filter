import XCTest

final class SerializationTests: XCTestCase {
    func test_effectState_roundtrip_preserves_identity_parameters_and_metadata() throws {
        try SerializationCases.effectStateRoundTrip()
    }

    func test_preset_roundtrip_preserves_ordered_chain_and_all_state() throws {
        try SerializationCases.chainRoundTrip()
    }

    func test_serialization_contract_detects_lost_parameters() throws {
        try SerializationCases.lostParametersAreDetected()
    }
}
