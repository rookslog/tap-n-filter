import Foundation
import EffectCatalog

struct LibraryParameterDescriptor: Sendable {
    let key: ParameterKey
    let domain: ParameterDomain
    let seed: Double
    let unit: String
    let discrete: Bool
    let nativeLower: Double
    var specification: LibraryValueSpecification {
        let lower: Double, upper: Double, scale: LibraryValueScale
        switch domain {
        case .linear(let a, let b): lower = a; upper = b; scale = .linear
        case .logarithmic(let a, let b): lower = a; upper = b; scale = .logarithmic
        }
        return LibraryValueSpecification(lower: lower, upper: upper,
            minimumInput: max(lower, nativeLower),
            scale: scale, discrete: discrete)
    }
    func position(_ value: Double) throws -> Position {
        try Position(specification.normalized(value))
    }
}
struct LibraryPartDescriptor: Sendable {
    let type: String
    let parameters: [LibraryParameterDescriptor]
    func seed() throws -> SoundPart {
        SoundPart(id: PartID(), type: type, settings: try parameters.map {
            ParameterSetting(key: $0.key, position: try $0.position($0.seed))
        })
    }
}
extension EffectProfileParameter {
    var domain: ParameterDomain { logarithmic ? .logarithmic(lower, upper) : .linear(lower, upper) }
}

extension LibraryProfiles {
    static let authoringKinds = EffectCatalog.effects.map(\.type)
    func descriptor(_ profile: String, type: String, includingOptional: Bool = false) throws -> LibraryPartDescriptor {
        _ = try recipe(profile)
        let legacySize = type == "sizedReverb" && profile == Self.quickMenu
        guard let effect = EffectCatalog.effect(legacySize ? "reverb" : type) else { throw LibraryError.unsupportedEdit }
        let domainName = legacySize ? "quickMenu.v1" : (profile == Self.expandedReverb || Self.newSoundProfiles.contains(profile)) ? "unified.v1" :
            profile == Self.filters ? "filters.v1" : "everyday.v1"
        guard var parameters = effect.profiles[domainName] ?? effect.profiles["everyday.v1"] else { throw LibraryError.unsupportedEdit }
        if includingOptional && !legacySize, let extra = effect.profiles["quickMenu.v1"] {
            parameters += extra.filter { item in !parameters.contains { $0.key == item.key } }
        }
        if !includingOptional && !legacySize {
            let optional = Set(effect.parameters.filter(\.optional).map(\.key))
            parameters.removeAll { optional.contains($0.key) }
        }
        return LibraryPartDescriptor(type: type, parameters: try parameters.map { parameter in
            LibraryParameterDescriptor(key: try ParameterKey(parameter.key), domain: parameter.domain,
                seed: parameter.seed, unit: effect.parameters.first { $0.key == parameter.key }?.unit ?? "",
                discrete: parameter.discrete, nativeLower: effect.parameters.first { $0.key == parameter.key }?.lower ?? parameter.lower)
        })
    }
    func authoredCatalog(_ profile: String) throws -> [PartDescriptor] {
        var result = try Self.authoringKinds.map { type in
            let descriptor = try descriptor(profile, type: type)
            let effect = EffectCatalog.effect(type)!
            return PartDescriptor(type: type, parameters: descriptor.parameters.map(\.key),
                optionalParameters: try effect.parameters.filter(\.optional).map { try ParameterKey($0.key) })
        }
        if profile == Self.quickMenu {
            let alias = try descriptor(profile, type: "sizedReverb")
            result.append(PartDescriptor(type: alias.type, parameters: alias.parameters.map(\.key)))
        }
        return result
    }
}
