import Foundation

extension SoundPart {
    var unifiedReverb: SoundPart {
        type == "sizedReverb" ? SoundPart(id: id, type: "reverb", settings: settings) : self
    }
}

extension SoundBlock {
    var inheritsReverbDomain: Bool {
        pieces.contains { piece in
            switch piece {
            case .part(let part): return part.type == "reverb"
            case .block(let use): return use.payload == nil && use.content.inheritsReverbDomain
            case .reference: return false
            }
        }
    }
    var needsVersion6: Bool {
        pieces.contains { piece in
            switch piece {
            case .part(let part):
                return part.type == "reverb" && part.settings.contains { $0.key.rawValue == "roomSize" }
            case .block(let use): return use.payload?.requiresSchema9 == true || use.content.needsVersion6
            case .reference: return false
            }
        }
    }
    var hasLegacySizedReverb: Bool {
        pieces.contains { piece in
            switch piece {
            case .part(let part): return part.type == "sizedReverb"
            case .block(let use): return use.content.hasLegacySizedReverb
            case .reference: return false
            }
        }
    }
    func unifyingAuthoredReverb() throws -> SoundBlock {
        var changed = replacing(pieces: try pieces.map { piece in
            switch piece {
            case .part(let part): return .part(part.unifiedReverb)
            case .block(let use):
                if let payload = use.payload, let original = use.original {
                    return .block(BlockUse(site: use.site, payload: try payload.authoredReverb(), original: original))
                }
                return .block(BlockUse(site: use.site, content: try use.content.unifyingAuthoredReverb()))
            case .reference: return piece
            }
        })
        if let bindings = changed.bindings {
            changed = changed.replacing(bindings: bindings.map { binding in
                var binding = binding
                binding.provenance.setting = binding.provenance.setting?.unifiedReverb
                return binding
            })
        }
        return changed
    }
}

extension LibraryPayload {
    var usesExpandedReverbDomain: Bool {
        profile == LibraryProfiles.expandedReverb && block.inheritsReverbDomain
    }
    var requiresSchema9: Bool { canonicalVersion == 6 || block.needsVersion6 || usesExpandedReverbDomain }

    func authoringVersion(for changed: SoundBlock) -> Int {
        if changed.needsVersion6 || (profile == LibraryProfiles.expandedReverb && changed.inheritsReverbDomain) { return 6 }
        let previous = max(3, min(5, canonicalVersion))
        if changed.needsVersion5 { return max(5, previous) }
        if changed.needsVersion4 { return max(4, previous) }
        return previous
    }

    func authoredReverb() throws -> LibraryPayload {
        guard block.hasLegacySizedReverb else { return self }
        return try replacing(block: block.unifyingAuthoredReverb())
    }
}
