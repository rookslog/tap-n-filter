import AVFoundation
import Capture
import Combine
import Effects
import Foundation
import Graph
import Presets
@testable import ViewModel
import XCTest

/// Existing-API witnesses for a future, noncandidate diagnostic. Missing
/// modified receipts are intentional assertions, not an observed runtime red.
@MainActor
final class DirtyComparisonReceiptTests: XCTestCase {
    func test_clean_finite_baseline_and_no_op_snapshot_once_in_graph_order_without_receipt() throws {
        try withFixture { fixture in
            assertReceipt(probe(fixture, modified: false), count: 0)
            try fixture.nodes[1].setParameter("gain", value: -6)
            assertReceipt(probe(fixture, modified: false), count: 0)
        }
    }

    func test_output_gain_change_snapshots_every_node_once_and_emits_one_receipt_with_known_bits() throws {
        try withFixture { fixture in
            fixture.model.graph.outputGain = 0.5
            let entries = probe(fixture, modified: true)
            assertReceipt(entries, count: 1, bits: [Float(0.5), Float(0.75)])
            assertTokens(entries, expected: [
                "gain.c": "3f000000", "gain.b": "3f400000", "gain.eq": "0",
                "n0.mix.c": "3f200000", "n0.mix.b": "3f200000", "n0.mix.eq": "1",
            ])
        }
    }

    func test_node_mix_change_with_unchanged_output_gain_emits_one_receipt_with_known_bits() throws {
        try withFixture { fixture in
            fixture.nodes[0].wetDryMix = 0.25
            let entries = probe(fixture, modified: true)
            assertReceipt(entries, count: 1, bits: [Float(0.25), Float(0.625)])
            assertTokens(entries, expected: [
                "gain.c": "3f400000", "gain.b": "3f400000", "gain.eq": "1",
                "n0.mix.c": "3e800000", "n0.mix.b": "3f200000", "n0.mix.eq": "0",
            ])
        }
    }

    func test_modified_calls_have_increasing_ordinals_across_a_clean_revert() throws {
        try withFixture { fixture in
            fixture.model.graph.outputGain = 0.5
            let first = probe(fixture, modified: true)
            assertReceipt(first, count: 1)
            fixture.model.graph.outputGain = 0.75
            assertReceipt(probe(fixture, modified: false), count: 0)
            fixture.model.graph.outputGain = 0.5
            let second = probe(fixture, modified: true)
            assertReceipt(second, count: 1)
            // Nonthrowing receipt checks above still run when the source has
            // no marker. No required initial ordinal and no extra dirty read.
            if let earlier = first.first.flatMap({ ordinal($0.message) }),
               let later = second.first.flatMap({ ordinal($0.message) }) {
                XCTAssertGreaterThan(later, earlier, "Per-instance call ordinal must increase")
            }
            XCTAssertEqual(markers(fixture.model).count, 2, "Two modified calls, no clean receipt")
        }
    }

    func test_private_strings_UUIDs_and_unknown_numeric_values_never_enter_any_marker() throws {
        try withFixture { fixture in
            let node = fixture.nodes[0]
            node.snapshotType = "receipt-private-type"
            node.id = UUID()
            fixture.model.graph.outputGain = 0.5
            let entries = probe(fixture, modified: true)
            assertReceipt(entries, count: 1, bits: [Float(0.5), Float(0.75)])
            // Cardinality above prevents an empty stream from passing privacy.
            // Inspect only source/marker entries, never print full messages.
            let forbidden = [
                fixture.input.name, fixture.url.absoluteString, fixture.url.path,
                fixture.directory.absoluteString, node.snapshotType,
                "receipt-private-display", "receipt-private-key", "receipt-private-number",
                "receipt-private-parameter", "receipt-private-string",
                "https://receipt-private.invalid/private", "tnf.reverb", "tnf.gain", "tnf.eq",
                "hp.frequency", "hp.Q", "lp.frequency", "lp.Q", "largeHall",
                "9876.54321", String(format: "%016llx", Double(9876.54321).bitPattern),
                "321.125", String(format: "%08x", Float(321.125).bitPattern),
                node.id.uuidString,
            ] + fixture.input.nodes.map { $0.id.uuidString }
            assertCompactUUIDPrivacy(markers(fixture.model), ids: [node.id] + fixture.input.nodes.map { $0.id })
            for entry in markers(fixture.model) {
                for sentinel in forbidden {
                    XCTAssertFalse(entry.message.lowercased().contains(sentinel.lowercased()),
                                   "Diagnostic leaked a synthetic private-field sentinel")
                }
            }
        }
    }

    func test_unknown_key_value_name_identity_and_membership_edits_remain_meaningful() throws {
        try withFixture { fixture in
            let node = fixture.nodes[1]
            let original = fixture.input.nodes[1]
            let edits: [() -> Void] = [
                { node.values["receipt-private-added-key"] = 42.125 },
                { node.extras["receipt-private-string"] = .string("receipt-private-replacement") },
                { node.displayName = "receipt-private-renamed" },
                { node.id = UUID() },
            ]
            var controlIndex = 0
            for edit in edits {
                edit()
                let changed = probe(fixture, modified: true)
                assertReceipt(changed, count: 1)
                assertCompactUUIDPrivacy(changed, ids: [node.id, original.id])
                assertControlTransition(changed, index: controlIndex)
                controlIndex += 1
                for entry in changed {
                    for sentinel in ["receipt-private-added-key", "receipt-private-string",
                                     "receipt-private-replacement", "receipt-private-renamed",
                                     "42.125", String(format: "%08x", Float(42.125).bitPattern),
                                     node.id.uuidString, original.id.uuidString] {
                        XCTAssertFalse(entry.message.lowercased().contains(sentinel.lowercased()),
                                       "Control receipt leaked a synthetic private-field sentinel")
                    }
                }
                try node.restore(from: original)
                assertReceipt(probe(fixture, modified: false), count: 0)
            }
            try fixture.model.graph.remove(at: 2)
            // Check the same measured removal entries without a second getter.
            assertReceipt(probe(fixture, modified: true), count: 1)
            try fixture.model.graph.add(fixture.nodes[2])
            assertReceipt(probe(fixture, modified: false), count: 0)
        }
    }

    func test_24_node_overflow_retains_true_counts_bounded_slots_and_private_counter_state() throws {
        try withFixture { fixture in
            var added: [ReceiptValueNode] = []
            defer {
                for node in added {
                    XCTAssertEqual(node.attachmentAttempts, 0)
                    XCTAssertNil(node.inputBus.engine)
                    XCTAssertNil(node.outputBus.engine)
                }
            }
            // Membership edits and ownership assignment precede the measured
            // getter. Even slots omitted from the receipt must snapshot once.
            for slot in 3..<24 {
                let node = ReceiptOverflowNode()
                node.snapshotType = ReceiptOverflowNode.typeIdentifier
                node.slot = slot
                node.order = fixture.order
                node.displayName = "receipt-private-overflow-display-\(slot)"
                node.values = ["receipt-private-overflow-key-\(slot)": 654.125]
                node.extras = [
                    "receipt-private-overflow-extra-\(slot)":
                        .string("https://receipt-private.invalid/overflow/\(slot)"),
                    "receipt-private-overflow-number-\(slot)": .double(7654.321),
                ]
                added.append(node)
                try fixture.model.graph.add(node)
            }
            XCTAssertEqual(fixture.model.graph.nodes.count, 24)
            let entries = probe(fixture, modified: true)
            assertReceipt(entries, count: 1)
            assertTokens(entries, expected: [
                "nodes.c": "24", "nodes.b": "3", "overflow": "1",
                "gain.c": "3f400000", "gain.b": "3f400000", "gain.eq": "1",
                "n0.mix.c": "3f200000", "n0.mix.b": "3f200000", "n0.mix.eq": "1",
            ])
            let forbidden = [
                "receipt-private", fixture.input.name, fixture.url.absoluteString,
                fixture.url.path, "654.125", "7654.321",
                String(format: "%08x", Float(654.125).bitPattern),
                String(format: "%016llx", Double(7654.321).bitPattern),
            ] + (fixture.nodes + added).map { $0.id.uuidString }
            assertCompactUUIDPrivacy(markers(fixture.model), ids: (fixture.nodes + added).map { $0.id })
            assertFixtureSlots(entries)
            for slot in 3..<16 {
                assertSlot(entries, slot: slot, expected: [
                    "f": "0001", "kc": "0", "kb": "0", "pc": "1", "pb": "0",
                    "xc": "2", "xb": "0", "kpc": "00", "kpb": "00",
                    "mix.c": "3f800000", "mix.b": "00000000", "mix.eq": "0",
                ])
            }
            for entry in markers(fixture.model) {
                for sentinel in forbidden {
                    XCTAssertFalse(entry.message.lowercased().contains(sentinel.lowercased()),
                                   "Overflow receipt leaked a synthetic private-field sentinel")
                }
            }
        }
    }

    /// Capture immediately around exactly ONE explicit getter. Setup and model
    /// mutations may snapshot outside this window. Assert Bool/count/order
    /// before any receipt assertion; counters do not prove helper short-circuiting.
    private func probe(
        _ fixture: ReceiptFixture, modified: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) -> [DebugLogEntry] {
        let active = fixture.model.graph.nodes.compactMap { $0 as? ReceiptValueNode }
        XCTAssertEqual(active.count, fixture.model.graph.nodes.count, file: file, line: line)
        let expectedOrder = active.map { $0.slot }
        let previousIDs = Set(markers(fixture.model).map { $0.id })
        let orderStart = fixture.order.slots.count
        let before = active.map { $0.snapshotCount }
        let parameterBefore = active.map { $0.parameterValueReadCount }
        let actual = fixture.model.isPresetModified
        let after = active.map { $0.snapshotCount }
        let parameterAfter = active.map { $0.parameterValueReadCount }
        let order = Array(fixture.order.slots.dropFirst(orderStart))
        XCTAssertEqual(actual, modified, "Existing Bool contract", file: file, line: line)
        XCTAssertEqual(zip(after, before).map { $0.0 - $0.1 }, Array(repeating: 1, count: active.count),
                       "Exactly one snapshot per active node", file: file, line: line)
        XCTAssertEqual(order, expectedOrder, "Graph snapshot order", file: file, line: line)
        XCTAssertEqual(zip(parameterAfter, parameterBefore).map { $0.0 - $0.1 },
                       Array(repeating: 0, count: active.count),
                       "No direct parameterValue reads in getter window", file: file, line: line)
        assertBounds(Array(markers(fixture.model).filter { !previousIDs.contains($0.id) }),
                     currentNodes: active.count, baselineNodes: fixture.input.nodes.count,
                     file: file, line: line)
        if active.count == 2 {
            let removed = Array(markers(fixture.model).filter { !previousIDs.contains($0.id) })
            assertFixtureSlots(removed, slots: 0..<2)
            assertSlot(removed, slot: 2, expected: [
                "f": "0002", "kc": "0", "kb": "2", "pc": "0", "pb": "5",
                "xc": "0", "xb": "0", "kpc": "00", "kpb": "0f",
                "mix.c": "00000000", "mix.b": "3f800000", "mix.eq": "0",
                "v0b": "42a00000", "v1b": "3f800000", "v2b": "44480000", "v3b": "3fc00000",
            ])
        }
        return Array(markers(fixture.model).filter { !previousIDs.contains($0.id) }.reversed())
    }

    private func markers(_ model: AppViewModel) -> [DebugLogEntry] {
        model.debugLog.entries.filter {
            $0.source == "AppViewModel" && $0.message.hasPrefix("[TNF-DIRTY61]")
        }
    }

    private func ordinal(_ message: String) -> UInt64? {
        let tokens = message.split(separator: " ")
        guard tokens.count >= 4, tokens[0] == "[TNF-DIRTY61]", tokens[1] == "schema=1",
              tokens[2].hasPrefix("call="), tokens[3] == "modified=1" else { return nil }
        let digits = tokens[2].dropFirst(5)
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let value = UInt64(digits), value > 0 else { return nil }
        return value
    }

    private func assertReceipt(
        _ entries: [DebugLogEntry], count: Int, bits: [Float] = [],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(entries.count, count, "Receipt cardinality (missing on uninstrumented source)",
                       file: file, line: line)
        for entry in entries {
            XCTAssertTrue(ordinal(entry.message) != nil, "Fixed prefix/schema/modified/positive ordinal",
                          file: file, line: line)
            // Historical lexical check retained below; strictReceipt in
            // assertBounds now additionally enforces the settled closed schema.
            // Only numeric coded payloads; field labels/layout beyond the
            // settled prefix are deliberately not invented here. Sentinels
            // separately reject unknown keys and numeric extras. No raw dump.
            let grammar = #"^\[TNF-DIRTY61\] schema=1 call=[0-9]+ modified=1(?: [A-Za-z][A-Za-z0-9_.\[\]-]*=[0-9a-f]+)*$"#
            XCTAssertTrue(entry.message.range(of: grammar, options: .regularExpression) != nil,
                          "Fixed numeric receipt grammar", file: file, line: line)
            for value in bits {
                let hex = String(format: "%08x", value.bitPattern)
                let token = "(?<![A-Za-z0-9])" + hex + "(?![A-Za-z0-9])"
                XCTAssertTrue(entry.message.range(of: token, options: .regularExpression) != nil,
                              "Expected known Float bits missing", file: file, line: line)
            }
        }
    }

    /// Root-settled private diagnostic metadata, not graph field enumeration.
    /// Never include payloads or keys in assertion diagnostics.
    private func payloadTokens(
        _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) -> [String: String] {
        var result: [String: String] = [:]
        for token in message.split(separator: " ").dropFirst() {
            let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                XCTFail("Malformed diagnostic token", file: file, line: line)
                continue
            }
            let previous = result.updateValue(String(parts[1]), forKey: String(parts[0]))
            XCTAssertTrue(previous == nil, "Duplicate diagnostic token", file: file, line: line)
        }
        return result
    }

    private func assertTokens(
        _ entries: [DebugLogEntry], expected: [String: String],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for entry in entries {
            let tokens = payloadTokens(entry.message, file: file, line: line)
            for (key, value) in expected {
                // Bool assertion avoids echoing a potentially private actual
                // value while demanding exact key/side/width/case association.
                XCTAssertTrue(tokens[key] == value, "Fixed coded token association mismatch",
                              file: file, line: line)
            }
        }
    }

    private func assertBounds(
        _ entries: [DebugLogEntry], currentNodes: Int, baselineNodes: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for entry in entries {
            XCTAssertTrue(strictReceipt(entry.message), "Closed receipt schema", file: file, line: line)
            XCTAssertLessThanOrEqual(entry.message.utf8.count, 8192, "Receipt UTF8 byte bound",
                                     file: file, line: line)
            assertTokens([entry], expected: [
                "nodes.c": String(currentNodes), "nodes.b": String(baselineNodes),
                "overflow": max(currentNodes, baselineNodes) > 16 ? "1" : "0",
            ], file: file, line: line)
            let tokens = payloadTokens(entry.message, file: file, line: line)
            var slots = Set<Int>()
            for key in tokens.keys {
                guard key.first == "n", let digit = key.dropFirst().first,
                      digit >= "0", digit <= "9" else { continue }
                let parts = key.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[1].isEmpty,
                      let slot = Int(parts[0].dropFirst()), (0..<16).contains(slot),
                      parts[0] == Substring("n\(slot)") else {
                    XCTFail("Diagnostic node slot outside canonical n0 through n15", file: file, line: line)
                    continue
                }
                slots.insert(slot)
            }
            XCTAssertLessThanOrEqual(slots.count, 16, "At most sixteen diagnostic node slots",
                                     file: file, line: line)
            XCTAssertEqual(slots, Set(0..<min(max(currentNodes, baselineNodes), 16)),
                           "Every retained occurrence is required", file: file, line: line)
        }
    }

    /// Syntax/schema only: consumes tokens, never graph state or private field keys.
    /// Correspondence truth is tested separately with fixed fixture literals.
    private func strictReceipt(_ message: String) -> Bool {
        guard message.utf8.count <= 8192 else { return false }
        let words = message.components(separatedBy: " ")
        guard words.count >= 4, words[0] == "[TNF-DIRTY61]",
              words[1] == "schema=1", words[3] == "modified=1" else { return false }
        var fields: [String: String] = [:]
        for word in words.dropFirst() {
            let pair = word.components(separatedBy: "=")
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty,
                  fields.updateValue(pair[1], forKey: pair[0]) == nil else { return false }
        }
        func decimal(_ key: String) -> Int? {
            guard let raw = fields[key], let value = Int(raw), value >= 0,
                  String(value) == raw else { return nil }
            return value
        }
        func hex(_ key: String, width: Int) -> UInt64? {
            guard let raw = fields[key], raw.count == width,
                  raw.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
                return nil
            }
            return UInt64(raw, radix: 16)
        }
        func flag(_ key: String) -> Bool {
            fields[key] == "0" || fields[key] == "1"
        }
        guard let rawCall = fields["call"], let call = UInt64(rawCall), call > 0,
              String(call) == rawCall, words[2] == "call=\(rawCall)",
              hex("gain.c", width: 8) != nil, hex("gain.b", width: 8) != nil, flag("gain.eq"),
              let current = decimal("nodes.c"), let baseline = decimal("nodes.b"),
              fields["overflow"] == (max(current, baseline) > 16 ? "1" : "0") else { return false }
        var allowed: Set<String> = [
            "schema", "call", "modified", "gain.c", "gain.b", "gain.eq", "nodes.c", "nodes.b", "overflow",
        ]
        let suffixes = ["f", "kc", "kb", "mix.c", "mix.b", "mix.eq", "pc", "pb", "xc", "xb", "kpc", "kpb"]
        for slot in 0..<min(max(current, baseline), 16) {
            let prefix = "n\(slot)."
            for suffix in suffixes { allowed.insert(prefix + suffix) }
            guard let bits = hex(prefix + "f", width: 4), bits <= 0x0fff,
                  let kc = decimal(prefix + "kc"), kc <= 3,
                  let kb = decimal(prefix + "kb"), kb <= 3,
                  hex(prefix + "mix.c", width: 8) != nil,
                  hex(prefix + "mix.b", width: 8) != nil, flag(prefix + "mix.eq") else { return false }
            let currentExists = slot < current
            let baselineExists = slot < baseline
            guard (bits & 1 != 0) == currentExists,
                  (bits & 2 != 0) == baselineExists else { return false }
            if !currentExists || !baselineExists {
                // All correspondence/equality bits need two present sides.
                guard bits & 0x0f9c == 0, fields[prefix + "mix.eq"] == "0" else { return false }
            }
            for (side, kind, exists, parameterKey, extraKey, maskKey, bypassBit) in [
                ("c", kc, currentExists, "pc", "xc", "kpc", UInt64(0x20)),
                ("b", kb, baselineExists, "pb", "xb", "kpb", UInt64(0x40)),
            ] {
                guard let parameters = decimal(prefix + parameterKey),
                      let extras = decimal(prefix + extraKey),
                      let mask = hex(prefix + maskKey, width: 2) else { return false }
                let maximum: UInt64 = kind == 1 ? 1 : (kind == 2 ? 15 : 0)
                guard mask <= maximum, mask.nonzeroBitCount <= parameters else { return false }
                if !exists {
                    guard kind == 0, parameters == 0, extras == 0, mask == 0,
                          fields[prefix + "mix." + side] == "00000000",
                          bits & bypassBit == 0 else { return false }
                }
                if kind == 1 || kind == 2 {
                    for index in 0..<(kind == 1 ? 1 : 4) {
                        let key = prefix + "v\(index)" + side
                        allowed.insert(key)
                        guard hex(key, width: 8) != nil else { return false }
                        if mask & (UInt64(1) << index) == 0 && fields[key] != "00000000" { return false }
                    }
                } else if kind == 3 {
                    let key = prefix + "r" + side
                    allowed.insert(key)
                    guard let preset = decimal(key), preset <= 13 else { return false }
                }
            }
        }
        return Set(fields.keys) == allowed
    }

    private func assertCompactUUIDPrivacy(_ entries: [DebugLogEntry], ids: [UUID]) {
        for entry in entries {
            for id in ids {
                let compact = id.uuidString.replacingOccurrences(of: "-", with: "")
                for spelling in [compact.lowercased(), compact.uppercased()] {
                    XCTAssertFalse(entry.message.contains(spelling), "Compact UUID must remain private")
                }
            }
        }
    }

    private func assertSlot(_ entries: [DebugLogEntry], slot: Int, expected: [String: String]) {
        // Keys come only from fixed schema suffixes and finite test slot indices.
        assertTokens(entries, expected: Dictionary(uniqueKeysWithValues: expected.map {
            ("n\(slot)." + $0.key, $0.value)
        }))
    }

    /// Literal finite input expectations, not a snapshot comparator/classifier.
    private func fixtureSlot(_ slot: Int) -> [String: String] {
        switch slot {
        case 0:
            return ["f": "0f9f", "kc": "3", "kb": "3", "pc": "0", "pb": "0",
                    "xc": "4", "xb": "4", "kpc": "00", "kpb": "00", "rc": "8", "rb": "8",
                    "mix.c": "3f200000", "mix.b": "3f200000", "mix.eq": "1"]
        case 1:
            return ["f": "0f9f", "kc": "1", "kb": "1", "pc": "1", "pb": "1",
                    "xc": "1", "xb": "1", "kpc": "01", "kpb": "01",
                    "v0c": "c0c00000", "v0b": "c0c00000",
                    "mix.c": "3f800000", "mix.b": "3f800000", "mix.eq": "1"]
        case 2:
            return ["f": "0f9f", "kc": "2", "kb": "2", "pc": "5", "pb": "5",
                    "xc": "0", "xb": "0", "kpc": "0f", "kpb": "0f",
                    "v0c": "42a00000", "v0b": "42a00000", "v1c": "3f800000", "v1b": "3f800000",
                    "v2c": "44480000", "v2b": "44480000", "v3c": "3fc00000", "v3b": "3fc00000",
                    "mix.c": "3f800000", "mix.b": "3f800000", "mix.eq": "1"]
        default:
            preconditionFailure("Finite fixture slot only")
        }
    }

    private func assertFixtureSlots(_ entries: [DebugLogEntry], slots: Range<Int> = 0..<3) {
        for slot in slots { assertSlot(entries, slot: slot, expected: fixtureSlot(slot)) }
    }

    private func assertControlTransition(_ entries: [DebugLogEntry], index: Int) {
        // Added parameter clears key-set/value bits8/9; same-key extra clears11;
        // rename clears4; changed identity clears2. Counts are input literals.
        let transitions: [[String: String]] = [
            ["f": "0c9f", "pc": "2"], ["f": "079f"], ["f": "0f8f"], ["f": "0f9b"],
        ]
        var expected = fixtureSlot(1)
        expected.merge(transitions[index]) { _, changed in changed }
        assertSlot(entries, slot: 1, expected: expected)
        assertSlot(entries, slot: 0, expected: fixtureSlot(0))
        assertSlot(entries, slot: 2, expected: fixtureSlot(2))
    }

    func test_distinct_type_bypass_gain_EQ_and_reverb_fields_and_clean_restorations() throws {
        try withFixture { fixture in
            // Each control has a distinct promised field; no native constructors.
            let controls: [(Int, () -> Void, [String: String])] = [
                (1, { fixture.nodes[1].snapshotType = "receipt-private-type" },
                 ["f": "0f97", "kc": "0", "kpc": "00"]),
                (1, { fixture.nodes[1].bypass = true }, ["f": "0f3f"]),
                (1, { fixture.nodes[1].values["gain"] = -3 }, ["f": "0d9f", "v0c": "c0400000"]),
                (1, { fixture.nodes[1].values.removeValue(forKey: "gain") },
                 ["f": "0c9f", "pc": "0", "kpc": "00", "v0c": "00000000"]),
                (2, { fixture.nodes[2].values["hp.Q"] = 2 }, ["f": "0d9f", "v1c": "40000000"]),
                (2, { fixture.nodes[2].values.removeValue(forKey: "lp.Q") },
                 ["f": "0c9f", "pc": "4", "kpc": "07", "v3c": "00000000"]),
                (0, { fixture.nodes[0].extras["preset"] = .string("smallRoom") },
                 ["f": "079f", "rc": "1"]),
                (0, { fixture.nodes[0].extras["preset"] = .int(8) }, ["f": "079f", "rc": "0"]),
            ]
            for (slot, edit, overrides) in controls {
                edit()
                let changed = probe(fixture, modified: true)
                assertReceipt(changed, count: 1)
                var expected = fixtureSlot(slot)
                expected.merge(overrides) { _, changed in changed }
                if slot == 1 && overrides["kc"] == "0" { expected.removeValue(forKey: "v0c") }
                assertSlot(changed, slot: slot, expected: expected)
                for other in 0..<3 where other != slot {
                    assertSlot(changed, slot: other, expected: fixtureSlot(other))
                }
                assertCompactUUIDPrivacy(changed, ids: fixture.nodes.map { $0.id })
                try fixture.nodes[slot].restore(from: fixture.input.nodes[slot])
                assertReceipt(probe(fixture, modified: false), count: 0)
            }
        }
    }

    func test_strict_schema_rejects_fixed_privacy_and_incomplete_field_counterexamples() {
        // Fixed schema examples only, not a proposed formatter or graph encoding.
        let head = "[TNF-DIRTY61] schema=1 call=1 modified=1 gain.c=3f000000 gain.b=3f400000 gain.eq=0"
        let empty = head + " nodes.c=0 nodes.b=0 overflow=0"
        let slot = " n0.f=0f9f n0.kc=1 n0.kb=1 n0.mix.c=3f800000 n0.mix.b=3f800000 n0.mix.eq=1"
            + " n0.pc=1 n0.pb=1 n0.xc=0 n0.xb=0 n0.kpc=01 n0.kpb=01 n0.v0c=c0c00000 n0.v0b=c0c00000"
        let valid = head + " nodes.c=1 nodes.b=1 overflow=0" + slot
        XCTAssertTrue(strictReceipt(empty))
        XCTAssertTrue(strictReceipt(valid))
        let eq = head + " nodes.c=0 nodes.b=1 overflow=0"
            + " n0.f=0002 n0.kc=0 n0.kb=2 n0.mix.c=00000000 n0.mix.b=3f800000 n0.mix.eq=0"
            + " n0.pc=0 n0.pb=4 n0.xc=0 n0.xb=0 n0.kpc=00 n0.kpb=0f"
            + " n0.v0b=42a00000 n0.v1b=3f800000 n0.v2b=44480000 n0.v3b=3fc00000"
        XCTAssertTrue(strictReceipt(eq))
        let reverb = head + " nodes.c=1 nodes.b=0 overflow=0"
            + " n0.f=0001 n0.kc=3 n0.kb=0 n0.mix.c=3f800000 n0.mix.b=00000000 n0.mix.eq=0"
            + " n0.pc=0 n0.pb=0 n0.xc=1 n0.xb=0 n0.kpc=00 n0.kpb=00 n0.rc=13"
        XCTAssertTrue(strictReceipt(reverb))
        let invalid = [
            valid + " u=0123456789abcdef0123456789abcdef",
            valid + " u=0123456789ABCDEF0123456789ABCDEF",
            valid + " x72656365697074=70726976617465",
            valid + " n0.receipt-private-key=01",
            valid + " n0.rc=8", valid + " gain.c=3f000000",
            head + " nodes.c=1 nodes.b=1 overflow=0", // omitted occurrence
            valid.replacingOccurrences(of: " n0.pb=1", with: ""),
            valid.replacingOccurrences(of: " n0.v0b=c0c00000", with: ""),
            valid.replacingOccurrences(of: "n0.f=0f9f", with: "n0.f=1f9f"),
            valid.replacingOccurrences(of: "n0.f=0f9f", with: "n0.f=f9f"),
            valid.replacingOccurrences(of: "n0.kpc=01", with: "n0.kpc=02"),
            valid.replacingOccurrences(of: "n0.v0c=c0c00000", with: "n0.v0c=C0C00000"),
            valid.replacingOccurrences(of: "call=1", with: "call=01"),
            valid.replacingOccurrences(of: "call=1", with: "call=18446744073709551616"),
            valid.replacingOccurrences(of: "nodes.c=1", with: "nodes.c=01"),
            valid.replacingOccurrences(of: "nodes.c=1", with: "nodes.c=999999999999999999999"),
            valid.replacingOccurrences(of: "gain.eq=0", with: "gain.eq=2"),
            valid.replacingOccurrences(of: "overflow=0", with: "overflow=1"),
            valid.replacingOccurrences(of: "n0.kc=1", with: "n0.kc=4"),
            valid.replacingOccurrences(of: "gain.c=3f000000", with: "gain.c=3f00000"),
            valid.replacingOccurrences(of: "n0.kpc=01", with: "n0.kpc=00"), // nonzero missing value
            eq.replacingOccurrences(of: "n0.f=0002", with: "n0.f=0006"),
            eq.replacingOccurrences(of: "n0.pc=0", with: "n0.pc=1"),
            reverb.replacingOccurrences(of: "n0.rc=13", with: "n0.rc=14"),
            reverb.replacingOccurrences(of: "n0.kpc=00", with: "n0.kpc=01"),
            valid + " ", valid.replacingOccurrences(of: " gain.c", with: "  gain.c"),
        ]
        for message in invalid {
            XCTAssertFalse(strictReceipt(message), "Fixed malformed schema witness must be rejected")
        }
    }

    private func withFixture(_ body: (ReceiptFixture) throws -> Void) throws {
        let suite = "DirtyComparisonReceiptTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Isolated receipt fixture cleanup failed") }
        }
        let input = GraphPreset(name: "receipt-private-preset", outputGain: 0.75, nodes: [
            EffectState(typeIdentifier: "tnf.reverb", id: UUID(), displayName: "receipt-private-display",
                        bypass: false, wetDryMix: 0.625, parameters: [:],
                        extras: ["preset": .string("largeHall"),
                                 "receipt-private-key": .string("https://receipt-private.invalid/private"),
                                 "receipt-private-string": .string("receipt-private-string"),
                                 "receipt-private-number": .double(9876.54321)]),
            EffectState(typeIdentifier: "tnf.gain", id: UUID(), displayName: "receipt-private-display",
                        bypass: false, wetDryMix: 1, parameters: ["gain": -6],
                        extras: ["receipt-private-string": .string("receipt-private-string")]),
            EffectState(typeIdentifier: "tnf.eq", id: UUID(), displayName: "receipt-private-display",
                        bypass: false, wetDryMix: 1,
                        parameters: ["hp.frequency": 80, "hp.Q": 1, "lp.frequency": 800, "lp.Q": 1.5,
                                     "receipt-private-parameter": 321.125], extras: [:]),
        ])
        // Complete finite session exists BEFORE AppViewModel initialization.
        defaults.set(try JSONEncoder().encode(input), forKey: AppViewModelDefaultsKey.graph)
        let registry = EffectNodeRegistry()
        registry.register(ReceiptReverbNode.self)
        registry.register(ReceiptGainNode.self)
        registry.register(ReceiptEqNode.self)
        let capture = ReceiptCapture()
        let engine = AVAudioEngine()
        let model = AppViewModel(capture: capture, engine: engine, registry: registry, defaults: defaults)
        let sessionNodes = model.graph.nodes.compactMap { $0 as? ReceiptValueNode }
        XCTAssertEqual(sessionNodes.count, 3)
        XCTAssertEqual(model.presetOrigin, .session)
        XCTAssertEqual(model.graph.snapshot().nodes, input.nodes)
        let url = directory.appendingPathComponent(input.name).appendingPathExtension("tnf")
        try PresetStore.save(input, to: url)
        model.loadPreset(from: url)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.presetName, input.name)
        XCTAssertEqual(model.presetFileURL, url)
        XCTAssertEqual(model.presetOrigin, .file)
        XCTAssertTrue(model.graph.lastLoadWarnings.isEmpty)
        XCTAssertEqual(model.graph.snapshot().nodes, input.nodes)
        let nodes = try model.graph.nodes.map { try XCTUnwrap($0 as? ReceiptValueNode) }
        XCTAssertEqual(nodes.count, 3)
        guard nodes.count == 3 else { return XCTFail("Incomplete pure-value fixture") }
        let order = ReceiptOrder()
        for (slot, node) in nodes.enumerated() { node.slot = slot; node.order = order }
        defer {
            XCTAssertEqual(capture.starts, 0)
            XCTAssertNil(capture.captureSourceNode)
            XCTAssertFalse(engine.isRunning)
            XCTAssertFalse(model.graph.isAttached)
            for node in sessionNodes + nodes {
                XCTAssertEqual(node.attachmentAttempts, 0)
                XCTAssertNil(node.inputBus.engine)
                XCTAssertNil(node.outputBus.engine)
            }
        }
        try body(ReceiptFixture(model: model, nodes: nodes, order: order,
                                input: input, directory: directory, url: url))
    }
}

@MainActor
private struct ReceiptFixture {
    let model: AppViewModel
    let nodes: [ReceiptValueNode]
    let order: ReceiptOrder
    let input: GraphPreset
    let directory: URL
    let url: URL
}

private final class ReceiptOrder { var slots: [Int] = [] }

/// Pure finite value storage. No native EQ/Reverb/Gain object or classifier.
/// Mixers only satisfy protocol buses; attaching visibly fails closed.
private class ReceiptValueNode: DefaultConstructibleEffectNode {
    class var typeIdentifier: String { "tnf.reverb" }
    var id = UUID()
    var displayName = "receipt-private-display"
    var bypass = false
    var wetDryMix: Float = 1
    let inputBus = AVAudioMixerNode()
    let outputBus = AVAudioMixerNode()
    var parameters: [EffectParameter] { [] }
    var values: [String: Float] = [:]
    var extras: [String: AnyCodableValue] = [:]
    var snapshotType = "tnf.reverb"
    var slot = 0
    var order: ReceiptOrder?
    private(set) var snapshotCount = 0
    private(set) var parameterValueReadCount = 0
    private(set) var attachmentAttempts = 0

    required init() {}
    required convenience init(from decoder: Decoder) throws {
        self.init()
        try restore(from: EffectState(from: decoder))
    }

    func restore(from state: EffectState) throws {
        id = state.id
        displayName = state.displayName
        bypass = state.bypass
        wetDryMix = state.wetDryMix
        snapshotType = state.typeIdentifier
        values = state.parameters
        extras = state.extras
    }

    func snapshot() -> EffectState {
        snapshotCount += 1
        order?.slots.append(slot)
        return EffectState(typeIdentifier: snapshotType, id: id, displayName: displayName,
                           bypass: bypass, wetDryMix: wetDryMix, parameters: values, extras: extras)
    }

    func setParameter(_ identifier: String, value: Float) throws {
        guard let parameter = parameters.first(where: { $0.identifier == identifier }) else {
            throw EffectParameterError.unknownParameter(identifier: identifier)
        }
        guard value.isFinite, parameter.range.contains(value) else {
            throw EffectParameterError.valueOutOfRange(identifier: identifier, value: value, range: parameter.range)
        }
        values[identifier] = value
    }

    func parameterValue(_ identifier: String) -> Float? {
        parameterValueReadCount += 1
        return values[identifier]
    }
    func attach(to engine: AVAudioEngine) throws {
        attachmentAttempts += 1
        XCTFail("Receipt pure-value fake must never attach")
        throw ReceiptFixtureError.audioLifecycle
    }
    func detach() {}
}

private final class ReceiptReverbNode: ReceiptValueNode {}
private final class ReceiptOverflowNode: ReceiptValueNode {
    override class var typeIdentifier: String { "receipt-private-overflow-type" }
}
private final class ReceiptGainNode: ReceiptValueNode {
    override class var typeIdentifier: String { "tnf.gain" }
    override var parameters: [EffectParameter] { GainNode.parameterCatalog }
}
private final class ReceiptEqNode: ReceiptValueNode {
    override class var typeIdentifier: String { "tnf.eq" }
    override var parameters: [EffectParameter] { EQNode.parameterCatalog }
}

/// Private fail-closed mock: never creates/attaches a source node, even on misuse.
private final class ReceiptCapture: CaptureControllerProtocol, @unchecked Sendable {
    private let subject = CurrentValueSubject<CaptureState, Never>(.idle)
    private(set) var starts = 0
    var state: CaptureState { subject.value }
    var statePublisher: AnyPublisher<CaptureState, Never> { subject.eraseToAnyPublisher() }
    var captureSourceNode: AVAudioSourceNode? { nil }
    func availableSources() throws -> [CaptureSource] { [] }
    func start(source: CaptureSource, into engine: AVAudioEngine) throws {
        starts += 1
        XCTFail("Receipt tests must never start capture")
        throw ReceiptFixtureError.audioLifecycle
    }
    func stop() throws {}
}

private enum ReceiptFixtureError: Error { case audioLifecycle }
