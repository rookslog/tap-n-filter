// Reference model for two behaviours of the menu-bar audio app:
//   (A) live-value admission: which slider and choice changes are accepted while drags, saves,
//       editor reads, structural changes and playback changes overlap;
//   (B) lane life for one app: idle, starting, running, stopping, failed.
// The model states required outcomes in the abstract. It is not a design for the app and imports
// nothing from it, so a test target can compile it next to the real code and compare the two.
// Each rule cites the cell id of the event table it encodes (A-..., B-...).

import Foundation

// MARK: - Shared

/// Live values of one slider (S) and one choice (C). The model gives every move a unique value:
/// the 1-based index of the event that made it. 0 is the value before the sequence.
public struct Values: Hashable, CustomStringConvertible {
    public var slider: Int
    public var choice: Int
    public init(slider: Int = 0, choice: Int = 0) { self.slider = slider; self.choice = choice }
    public var description: String { "S=\(slider) C=\(choice)" }
}

// MARK: - (A) Live-value admission

public enum Gesture: Int, Hashable, CustomStringConvertible {
    case g1 = 1, g2 = 2
    public var description: String { "G\(rawValue)" }
}

/// Which displayed card a menu action carries.
public enum Card: Hashable, CustomStringConvertible {
    /// The card shown before the sequence began.
    case initial
    /// The card the menu shows at the moment of the action.
    case shown
    public var description: String { self == .initial ? "old" : "now" }
}

public enum AEvent: Hashable, CustomStringConvertible {
    /// The menu starts a drag with a fresh identity on slider S. Every menu drag has one (D-1).
    case begin(Gesture)
    /// A drag sample on S carrying the gesture identity and a card.
    case move(Gesture, Card)
    /// The pointer is released (ends the session's drag, if any).
    case end
    /// An anonymous choice click on C (no gesture identity).
    case click(Card)
    /// An anonymous slider step on S: a keyboard or accessibility step (D-1: drags never send these).
    case nudge(Card)
    /// The next persistence write parks until released.
    case holdWrite
    case releaseWrite
    /// The next persistence write is refused (A-S6).
    case refuseWrite
    /// Applying the next change that would be admitted fails (A-E1).
    case failApply
    /// An editor query or read starts. It is read-only.
    case readBegin
    /// The oldest or newest in-flight editor read finishes, successfully or not.
    case readEnd(oldest: Bool, ok: Bool)
    /// The only in-flight editor read finishes its operation and takes its completion read; the
    /// publication of that read is held (I6).
    case completionHeld
    /// The held completion tries to publish.
    case completionRelease
    /// Source or output format change (a real playback barrier).
    case playbackChange
    /// A structural command on any app (select, rename, create).
    case structural
    /// A lane finished starting or stopping and playback republished its state.
    case laneChange
    /// A menu refresh read lands and the menu shows its card.
    case refresh
    /// The menu opens (again).
    case menuOpen

    public var description: String {
        switch self {
        case .begin(let g): return "begin(\(g))"
        case .move(let g, let c): return "move(\(g),\(c))"
        case .end: return "end"
        case .click(let c): return "click(\(c))"
        case .nudge(let c): return "nudge(\(c))"
        case .holdWrite: return "holdWrite"
        case .releaseWrite: return "releaseWrite"
        case .refuseWrite: return "refuseWrite"
        case .failApply: return "failApply"
        case .readBegin: return "readBegin"
        case .readEnd(let oldest, let ok): return "readEnd(\(oldest ? "oldest" : "newest"),\(ok ? "ok" : "fail"))"
        case .playbackChange: return "playbackChange"
        case .structural: return "structural"
        case .laneChange: return "laneChange"
        case .refresh: return "refresh"
        case .menuOpen: return "menuOpen"
        case .completionHeld: return "completionHeld"
        case .completionRelease: return "completionRelease"
        }
    }
}

public enum AOutcome: Hashable, CustomStringConvertible {
    case none
    case admitted
    case superseded
    /// Would have been admitted, but applying it failed: nothing changed and the problem shows (A-E1).
    case failed
    /// What an editor read sees when it starts (every admitted change so far).
    case observed(Values)
    case published
    case discarded
    case failure(shown: Bool, retriggered: Bool)
    public var description: String {
        switch self {
        case .none: return "-"
        case .admitted: return "admitted"
        case .superseded: return "superseded"
        case .failed: return "failed"
        case .observed(let v): return "observed(\(v))"
        case .published: return "published"
        case .discarded: return "discarded"
        case .failure(let shown, let retriggered): return "failure(shown:\(shown),retriggered:\(retriggered))"
        }
    }
}

/// The three policy cells. `ratified` holds the chosen behaviour; the other
/// combinations stay enumerable so a later change of mind only changes expected outcomes.
public struct AdmissionPolicy: Hashable, CustomStringConvertible {
    /// A-LC: does a lane start/stop publication retire the drag in progress? Ratified: no.
    public var laneChangeRetiresDrag: Bool
    /// A-NR: is a keyboard slider step admitted while an editor read is in flight? Ratified: yes.
    public var sliderStepDuringRead: Bool
    /// A-CD: is a choice click admitted while the pointer holds a drag? Ratified: yes.
    public var clickDuringDrag: Bool
    public init(laneChangeRetiresDrag: Bool, sliderStepDuringRead: Bool, clickDuringDrag: Bool) {
        self.laneChangeRetiresDrag = laneChangeRetiresDrag
        self.sliderStepDuringRead = sliderStepDuringRead
        self.clickDuringDrag = clickDuringDrag
    }
    public static let ratified = AdmissionPolicy(laneChangeRetiresDrag: false, sliderStepDuringRead: true, clickDuringDrag: true)
    public static var all: [AdmissionPolicy] {
        var out: [AdmissionPolicy] = []
        for a in [false, true] { for b in [false, true] { for c in [false, true] {
            out.append(AdmissionPolicy(laneChangeRetiresDrag: a, sliderStepDuringRead: b, clickDuringDrag: c))
        } } }
        return out
    }
    public var description: String {
        "laneChangeRetiresDrag=\(laneChangeRetiresDrag) sliderStepDuringRead=\(sliderStepDuringRead) clickDuringDrag=\(clickDuringDrag)"
    }
}

/// Deliberately wrong behaviours. The self-test shows the invariants catch each one.
public enum AMutant: String, CaseIterable {
    case none
    /// A save in flight makes the shown card stale (clicks and fresh drags dropped during a held save).
    case saveStalesCards
    /// End retires the drag only at the next non-move event (the end-to-retired gap).
    case endRetiresLate
    /// An editor read retires the drag in progress.
    case readRetiresDrag
    /// Anonymous clicks are refused while an editor read is in flight.
    case readDropsClicks
    /// A real barrier leaves the drag admitted (admission restored after every barrier).
    case barrierKeepsDrag
    /// An older read's result takes effect after a newer one.
    case stalePublishes
    /// An older read's failure is shown after a newer success.
    case staleFailureShows
    /// A failed read schedules another read by itself.
    case failureRetriggers
    /// A click marks the session as dragging and nothing ends it.
    case clickStartsDrag
    /// A refused write shows nothing.
    case refusalSilent
    /// A refused write rolls the live values back to the last saved ones.
    case refusalLosesValues
    /// After a refused write, nothing saves again.
    case refusalStopsSaves
    /// A failed apply leaves the drag admitted.
    case failedApplyKeepsDrag
    /// A failed apply still changes the live value.
    case failedApplyAdmits
    /// A held completion publishes its card even after a newer refresh, barrier or menu open.
    case completionPublishesHeldCard
}

/// One completed persistence write: the step it completed at (settle steps are count + 1) and whether the port refused it.
public struct WriteRecord: Hashable { public let step: Int; public let refused: Bool }

public struct ASettled: Hashable, CustomStringConvertible {
    public var saved: Values
    public var live: Values
    public var shown: Values
    /// Attention state before settling, when no settle read has cleared it.
    public var attentionBefore: Bool
    public var delivered: [Int]
    public var settleReads: Int
    public var writes: [WriteRecord]
    public var lastWrite: WriteRecord? { writes.last }
    public var refusedWrites: Int { writes.filter(\.refused).count }
    public var saveProblems: Int
    public var applyProblems: Int
    public var description: String {
        "saved \(saved), live \(live), shown \(shown), attention \(attentionBefore), delivered \(delivered), settleReads \(settleReads), refused \(refusedWrites), saveProblems \(saveProblems), applyProblems \(applyProblems)"
    }
}

public struct AdmissionModel {
    struct Read { let order: Int; let gen: Int; let observed: Values }
    public let policy: AdmissionPolicy
    public let mutant: AMutant
    public private(set) var live = Values()
    public private(set) var saved = Values()
    public private(set) var shownValues = Values()
    public private(set) var attention = false
    public private(set) var delivered: [Int] = []
    public private(set) var gesturing = false
    var cardGen = 0          // advanced by real barriers only (A-SEM)
    var shownGen = 0         // generation of the card the menu shows
    var barriers = 0         // real barriers seen (used only to prune equivalent card variants)
    var active: Gesture?     // the drag whose moves are admitted
    var retireAfterEnd = false
    var begun: Set<Gesture> = []
    var debounce = false     // an unissued debounced save is waiting
    var armed = false
    var refuseArmed = false
    var failArmed = false
    var savesStopped = false // mutant only
    var parked: (values: Values, refused: Bool)?
    var queued = 0
    var writes: [WriteRecord] = []
    var saveProblems = 0
    var applyProblems = 0
    var reads: [Read] = []
    var heldCompletion: Read?
    var nextOrder = 1
    var lastEffective = 0    // newest read whose result took effect
    var autoReads = 0        // reads the editor will start by itself
    var step = 0

    public init(policy: AdmissionPolicy = .ratified, mutant: AMutant = .none) {
        self.policy = policy; self.mutant = mutant
    }

    public func isEnabled(_ e: AEvent) -> Bool {
        switch e {
        case .begin(let g): return !begun.contains(g) && (g == .g1 || begun.contains(.g1))
        case .move(let g, let card): return begun.contains(g) && (card == .shown || barriers > 0)
        case .click(let card), .nudge(let card): return card == .shown || barriers > 0
        case .end: return gesturing
        case .holdWrite: return !armed && parked == nil
        case .releaseWrite: return parked != nil
        case .refuseWrite: return !refuseArmed
        case .failApply: return !failArmed
        case .readBegin: return reads.count < 2 && heldCompletion == nil
        case .readEnd(let oldest, _): return heldCompletion == nil && !reads.isEmpty && (oldest || reads.count > 1)
        case .completionHeld: return heldCompletion == nil && reads.count == 1
        case .completionRelease: return heldCompletion != nil
        default: return true
        }
    }

    func cardIsCurrent(_ card: Card) -> Bool {
        (card == .initial ? 0 : shownGen) == cardGen
    }

    /// A-E1: the change would be admitted but applying it fails. Returns true when it failed.
    mutating func applyFails() -> Bool {
        guard failArmed else { return false }
        failArmed = false
        applyProblems += 1
        if gesturing && mutant != .failedApplyKeepsDrag {
            gesturing = false; active = nil; retireAfterEnd = false
            issueSave()
        }
        return true
    }

    public mutating func apply(_ e: AEvent) -> AOutcome {
        step += 1
        let value = step
        if retireAfterEnd {
            if case .move = e {} else { active = nil; retireAfterEnd = false }
        }
        switch e {
        case .begin(let g):
            // A-G1: a new drag retires any earlier one and cancels an unissued debounce.
            begun.insert(g); active = g; retireAfterEnd = false
            gesturing = true; debounce = false
            return .none
        case .move(let g, let card):
            // A-G2/A-G3: only the live drag, with a card no real barrier has replaced.
            guard active == g, cardIsCurrent(card) else { return .superseded }
            if applyFails() {
                if mutant == .failedApplyAdmits { admitSlider(value) }
                return .failed
            }
            admitSlider(value)
            return .admitted
        case .end:
            // A-G4: end retires the drag at once and issues one save of every admitted value.
            guard gesturing else { return .none }
            gesturing = false
            if mutant == .endRetiresLate { retireAfterEnd = true } else { active = nil }
            issueSave()
            return .none
        case .click(let card):
            // A-C1, A-C2, A-CD: saves and reads never refuse a click; a real barrier does until the menu shows a new card.
            guard cardIsCurrent(card) else { return .superseded }
            if gesturing && !policy.clickDuringDrag { return .superseded }
            if mutant == .readDropsClicks && !reads.isEmpty { return .superseded }
            if applyFails() { return .failed }
            live.choice = value
            if mutant == .clickStartsDrag { gesturing = true; debounce = false; return .admitted }
            if !gesturing { debounce = true }
            return .admitted
        case .nudge(let card):
            // A-N1..A-N3, A-NR: refused while the pointer holds a drag.
            guard !gesturing, cardIsCurrent(card) else { return .superseded }
            if !reads.isEmpty && !policy.sliderStepDuringRead { return .superseded }
            if applyFails() { return .failed }
            admitSlider(value)
            debounce = true
            return .admitted
        case .holdWrite:
            armed = true
            return .none
        case .releaseWrite:
            releaseWrites()
            return .none
        case .refuseWrite:
            refuseArmed = true
            return .none
        case .failApply:
            failArmed = true
            return .none
        case .readBegin:
            // A-R1: a read sees every admitted change and changes no admission.
            reads.append(Read(order: nextOrder, gen: cardGen, observed: live)); nextOrder += 1
            if mutant == .readRetiresDrag { active = nil }
            return .observed(live)
        case .readEnd(let oldest, let ok):
            let read = oldest ? reads.removeFirst() : reads.removeLast()
            return ok ? completeEditorRead(read) : finish(read, ok: false)
        case .completionHeld:
            // I6 (amended): the completion reads now; its publication waits.
            _ = reads.removeFirst()
            heldCompletion = Read(order: nextOrder, gen: cardGen, observed: live); nextOrder += 1
            return .none
        case .completionRelease:
            let held = heldCompletion!
            heldCompletion = nil
            if mutant == .completionPublishesHeldCard { return publish(held) }
            // A refresh or menu open since the completion's read (newer order), or a barrier (newer
            // structure), makes the held card older than what the menu should show: discarded.
            return finish(held, ok: true)
        case .playbackChange:
            realBarrier()
            return .none
        case .structural:
            // A-SEM with A-S5: a structural command is itself a document write,
            // so it carries the live, admitted values, held or refused like any write.
            realBarrier()
            issueSave()
            return .none
        case .laneChange:
            if policy.laneChangeRetiresDrag { realBarrier() }
            return .none
        case .refresh:
            let read = Read(order: nextOrder, gen: cardGen, observed: live); nextOrder += 1
            return finish(read, ok: true)
        case .menuOpen:
            // A-M1: opening the menu ends a drag the old menu never ended, saves it, and shows a fresh card.
            active = nil; retireAfterEnd = false
            if gesturing { gesturing = false; issueSave() }
            let read = Read(order: nextOrder, gen: cardGen, observed: live); nextOrder += 1
            return finish(read, ok: true)
        }
    }

    mutating func admitSlider(_ value: Int) {
        live.slider = value
        delivered.append(value)
    }

    mutating func realBarrier() {
        // A-SEM: flushes (the model's live value is always flushed), retires the drag, stales every shown card.
        cardGen += 1; barriers += 1
        if mutant != .barrierKeepsDrag { active = nil }
        retireAfterEnd = false
    }

    mutating func issueSave() {
        if mutant == .saveStalesCards { cardGen += 1 }
        if savesStopped { return }
        if parked != nil { queued += 1; return }
        executeSave()
    }

    mutating func executeSave() {
        // A-S5: a write carries the values live when it runs. A-S6: the port may refuse it.
        let refused = refuseArmed
        refuseArmed = false
        if armed { armed = false; parked = (live, refused) } else { complete(live, refused: refused) }
    }

    mutating func complete(_ values: Values, refused: Bool) {
        writes.append(WriteRecord(step: step, refused: refused))
        guard refused else { saved = values; return }
        // A-S6: the problem shows, the values stay live, and the next admitted change saves again.
        if mutant != .refusalSilent { saveProblems += 1 }
        if mutant == .refusalLosesValues { live = saved }
        if mutant == .refusalStopsSaves { savesStopped = true }
    }

    mutating func releaseWrites() {
        guard let p = parked else { return }
        parked = nil
        complete(p.values, refused: p.refused)
        while queued > 0 && parked == nil { queued -= 1; executeSave() }
    }

    /// I6: an editor completion may publish only a card read after the latest
    /// refresh, barrier or menu open before its publication. Here a successful completion takes a
    /// fresh read when it is the last read in flight; while another read is still in flight its
    /// result is coalesced into that one (A-R8) and nothing publishes.
    mutating func completeEditorRead(_ read: Read) -> AOutcome {
        if mutant == .stalePublishes { return publish(read) }
        guard reads.isEmpty else { return .discarded }
        let fresh = Read(order: nextOrder, gen: cardGen, observed: live); nextOrder += 1
        return finish(fresh, ok: true)
    }

    /// Shows a read's card regardless of what came after it (mutants only).
    mutating func publish(_ read: Read) -> AOutcome {
        lastEffective = read.order
        attention = false
        shownGen = read.gen
        if shownValues != read.observed { autoReads = 1 }
        shownValues = read.observed
        return .published
    }

    mutating func finish(_ read: Read, ok: Bool) -> AOutcome {
        // A-R2..A-R6: only the newest result takes effect; a success shows a card only for the current structure.
        let newest = read.order > lastEffective
        if ok {
            guard newest, read.gen == cardGen else { return .discarded }
            lastEffective = max(lastEffective, read.order)
            attention = false
            shownGen = read.gen
            if shownValues != read.observed { autoReads = 1 }
            shownValues = read.observed
            return .published
        }
        let shown = newest || mutant == .staleFailureShows
        if shown { lastEffective = max(lastEffective, read.order); attention = true }
        var retriggered = false
        if mutant == .failureRetriggers { autoReads += 1; retriggered = true }
        return .failure(shown: shown, retriggered: retriggered)
    }

    /// Lets everything finish. `flush` is the end-of-test flush (it saves even mid-drag);
    /// without it only saves the app issued by itself run. Injected failures still armed are disarmed.
    public mutating func settle(flush: Bool) -> ASettled {
        let attentionBefore = attention
        step += 1
        refuseArmed = false; failArmed = false
        if let held = heldCompletion { heldCompletion = nil; _ = finish(held, ok: true) }
        while !reads.isEmpty { _ = completeEditorRead(reads.removeFirst()) }
        armed = false
        releaseWrites()
        if flush { gesturing = false; active = nil; issueSave() }
        if debounce { debounce = false; issueSave() }
        releaseWrites()
        var settleReads = 0
        autoReads += 1   // the closing menu refresh
        while autoReads > 0 && settleReads < 8 {
            autoReads -= 1; settleReads += 1
            let read = Read(order: nextOrder, gen: cardGen, observed: live); nextOrder += 1
            _ = finish(read, ok: true)
        }
        return ASettled(saved: saved, live: live, shown: shownValues, attentionBefore: attentionBefore,
                        delivered: delivered, settleReads: settleReads, writes: writes,
                        saveProblems: saveProblems, applyProblems: applyProblems)
    }
}

/// Invariants for (A), restated from the event list alone (plus which reads published and which
/// writes the port refused, both observable on the real code).
public enum AdmissionInvariants {
    public static func violations(_ events: [AEvent], _ outcomes: [AOutcome], flush: ASettled, noFlush: ASettled,
                                  policy: AdmissionPolicy) -> [String] {
        var out: [String] = []
        var lastSlider = 0, lastChoice = 0, lastAdmittedStep = 0
        var admittedSlider: [Int] = [0]
        var liveDrag: Gesture?
        var holding = false
        var failArmed = false, failedApplies = 0
        var barrierSinceStart = false, barrierSinceShown = false
        var barrierCount = 0
        var inFlight: [(order: Int, barriers: Int)] = []
        var heldRead: (order: Int, barriers: Int)?
        var nextOrder = 1
        var lastEffective = 0
        var attention = false

        func current(_ card: Card) -> Bool { card == .initial ? !barrierSinceStart : !barrierSinceShown }
        func barrier() { barrierCount += 1; barrierSinceStart = true; barrierSinceShown = true; liveDrag = nil }
        func result(_ read: (order: Int, barriers: Int), ok: Bool, _ outcome: AOutcome, _ i: Int) {
            let newest = read.order > lastEffective
            if ok {
                let expect: AOutcome = newest && read.barriers == barrierCount ? .published : .discarded
                if outcome != expect { out.append("I6 read result at \(i + 1): expected \(expect), got \(outcome)") }
                if outcome == .published { lastEffective = read.order; attention = false; barrierSinceShown = false }
            } else {
                let expect = AOutcome.failure(shown: newest, retriggered: false)
                if outcome != expect { out.append("I7/I8 read failure at \(i + 1): expected \(expect), got \(outcome)") }
                if newest { lastEffective = read.order; attention = true }
            }
        }
        /// I2/I3/I10: the expected outcome of an action that passes or fails admission.
        func decide(_ admit: Bool, _ e: AEvent, _ o: AOutcome, _ step: Int) -> Bool {
            var expect: AOutcome = admit ? .admitted : .superseded
            if admit && failArmed {
                failArmed = false; failedApplies += 1; expect = .failed
                if holding { holding = false; liveDrag = nil }     // A-E1: the drag stops counting
            }
            if o != expect { out.append("I2/I3/I10 \(e) at \(step): expected \(expect), got \(o)") }
            if o == .admitted { lastAdmittedStep = step }
            return o == .admitted
        }

        for (i, e) in events.enumerated() {
            let step = i + 1, o = outcomes[i]
            switch e {
            case .begin(let g): liveDrag = g; holding = true
            case .move(let g, let card):
                if decide(liveDrag == g && current(card), e, o, step) { lastSlider = step; admittedSlider.append(step) }
            case .end: if holding { holding = false; liveDrag = nil }
            case .click(let card):
                if decide(current(card) && (!holding || policy.clickDuringDrag), e, o, step) { lastChoice = step }
            case .nudge(let card):
                let admit = !holding && current(card) && (inFlight.isEmpty || policy.sliderStepDuringRead)
                if decide(admit, e, o, step) { lastSlider = step; admittedSlider.append(step) }
            case .holdWrite, .releaseWrite, .refuseWrite: break
            case .failApply: failArmed = true
            case .readBegin:
                let expect = AOutcome.observed(Values(slider: lastSlider, choice: lastChoice))
                if o != expect { out.append("I5 read at \(step) saw \(o), expected \(expect)") }
                inFlight.append((nextOrder, barrierCount)); nextOrder += 1
            case .readEnd(let oldest, let ok):
                let read = oldest ? inFlight.removeFirst() : inFlight.removeLast()
                if ok {
                    // I6: an editor completion may publish only a card read after the
                    // latest refresh, barrier or menu open before its publication. A completion that
                    // publishes at once shows a card read now; one that publishes nothing is allowed.
                    if o == .published {
                        lastEffective = nextOrder; nextOrder += 1; attention = false; barrierSinceShown = false
                    } else if o != .discarded {
                        out.append("I6 read result at \(step): expected published or discarded, got \(o)")
                    }
                } else {
                    result(read, ok: false, o, i)
                }
            case .completionHeld:
                if o != .none { out.append("I6 held completion at \(step) gave \(o)") }
                _ = inFlight.removeFirst()
                heldRead = (nextOrder, barrierCount); nextOrder += 1
            case .completionRelease:
                let held = heldRead ?? (order: 0, barriers: -1)
                heldRead = nil
                let fresh = held.barriers == barrierCount && held.order > lastEffective
                if o == .published {
                    if !fresh { out.append("I6 completion at \(step) published a card read before a later refresh, barrier or menu open") }
                    lastEffective = held.order; attention = false; barrierSinceShown = false
                } else if o != .discarded {
                    out.append("I6 completion at \(step): expected published or discarded, got \(o)")
                }
            case .playbackChange, .structural: barrier()
            case .laneChange: if policy.laneChangeRetiresDrag { barrier() }
            case .refresh:
                result((nextOrder, barrierCount), ok: true, o, i); nextOrder += 1
            case .menuOpen:
                liveDrag = nil; holding = false
                result((nextOrder, barrierCount), ok: true, o, i); nextOrder += 1
            }
        }
        let expected = Values(slider: lastSlider, choice: lastChoice)
        // I1: the saved value is the last admitted move. Without the final flush this holds when no drag
        // is held, unless the latest write the port completed was refused after the last admitted change
        // (A-S6: nothing new to save yet).
        if flush.saved != expected { out.append("I1 saved \(flush.saved) after flush, expected \(expected)") }
        if flush.live != expected { out.append("I1 live \(flush.live), expected \(expected)") }
        let waitingAfterRefusal = noFlush.lastWrite.map { $0.refused && $0.step >= lastAdmittedStep } ?? false
        if !holding && !waitingAfterRefusal && noFlush.saved != expected {
            out.append("I1 saved \(noFlush.saved) without flush (no drag held), expected \(expected)")
        }
        // I9: every refused write shows the problem once.
        if noFlush.saveProblems != noFlush.refusedWrites {
            out.append("I9 \(noFlush.refusedWrites) refused writes, \(noFlush.saveProblems) problems shown")
        }
        // I10: every failed apply shows the problem once.
        if flush.applyProblems != failedApplies { out.append("I10 \(failedApplies) failed applies, \(flush.applyProblems) problems shown") }
        // I3: nothing silently dropped: after settling the menu shows the live value.
        if flush.shown != flush.live { out.append("I3 menu shows \(flush.shown), live is \(flush.live)") }
        // I4: playback only ever receives admitted values, in order, ending at the last one.
        var cursor = 0
        for value in flush.delivered {
            guard let index = admittedSlider[cursor...].firstIndex(of: value) else {
                out.append("I4 playback received \(value) out of admitted order \(admittedSlider)"); break
            }
            cursor = index
        }
        if (flush.delivered.last ?? 0) != lastSlider { out.append("I4 playback ends at \(flush.delivered.last ?? 0), expected \(lastSlider)") }
        // I7: attention shows exactly when the newest read result was a failure.
        if flush.attentionBefore != attention { out.append("I7 attention \(flush.attentionBefore), expected \(attention)") }
        // I8: an error never re-triggers itself; settling ends after at most two reads.
        if flush.settleReads > 2 { out.append("I8 settling took \(flush.settleReads) reads") }
        return out
    }
}

// MARK: - (B) Lane life for one app

public enum LaneState: String, Hashable { case idle, starting, running, stopping, failed }

public enum BEvent: Hashable, CustomStringConvertible {
    /// A full activation delivery with master power ON or OFF.
    case activation(on: Bool)
    /// A positions-only delivery that carries master power ON or OFF.
    case positions(on: Bool)
    /// A positions-only parameter change with power unchanged.
    case parameters
    /// The oldest outstanding start finishes (success or failure).
    case startCompletes(ok: Bool)
    case stopCompletes
    /// The source app quit or the output route changed under a starting or running lane.
    case sourceGone
    case retry
    public var description: String {
        switch self {
        case .activation(let on): return "activation(\(on ? "ON" : "OFF"))"
        case .positions(let on): return "positions(\(on ? "ON" : "OFF"))"
        case .parameters: return "parameters"
        case .startCompletes(let ok): return "startCompletes(\(ok ? "ok" : "fail"))"
        case .stopCompletes: return "stopCompletes"
        case .sourceGone: return "sourceGone"
        case .retry: return "retry"
        }
    }
    var power: Bool? {
        switch self { case .activation(let on), .positions(let on): return on; default: return nil }
    }
}

public struct BOutcome: Hashable, CustomStringConvertible {
    public var startIssued = false
    public var outputStarted = false
    public var stopIssued = false
    public var state: LaneState
    /// Whether the app's problem shows after the event.
    public var problem = false
    public var description: String {
        var parts: [String] = [state.rawValue]
        if startIssued { parts.append("start") }
        if outputStarted { parts.append("SOUND") }
        if stopIssued { parts.append("stop") }
        if problem { parts.append("problem") }
        return parts.joined(separator: "+")
    }
}

public enum BMutant: String, CaseIterable {
    case none
    /// Positions OFF stops running lanes only; a starting lane slips past and sounds.
    case positionsOffSkipsStarting
    /// A stop's completion resumes from the last activation's scope, ignoring a later positions OFF.
    case resumeFromStaleActivation
    /// A stop's completion never resumes, so an authorized restart is stranded.
    case restartStranded
    /// A positions-only parameter change stops a starting lane.
    case parametersStopStarting
    /// A failed start retries by itself.
    case failureAutoRetries
    /// An ON activation while starting issues a second start.
    case doubleStart
    /// An ON activation restarts a running lane.
    case activationRestartsRunning
    /// A cancelled start still starts output.
    case cancelledStartSounds
    /// A cancelled start's failure shows a problem.
    case cancelledFailureShows
}

public struct BSettled: Hashable, CustomStringConvertible {
    public var state: LaneState
    public var outputStarts: Int
    public var laneParameters: Int
    public var parameters: Int
    public var steps: Int
    public var problem: Bool
    public var description: String { "\(state.rawValue) starts=\(outputStarts) params=\(laneParameters)/\(parameters) steps=\(steps) problem=\(problem)" }
}

public struct LaneModel {
    public let mutant: BMutant
    public private(set) var state = LaneState.idle
    var powerOn = false            // latest power delivered by either path
    var onAuthorized = false       // an ON activation arrived after the latest OFF
    var parameters = 0, laneParameters = 0
    var pendingStarts: [Bool] = [] // outstanding start completions, oldest first; false = cancelled
    var stopPending = false
    var failurePending = false     // B-S9: the source went while starting; shown when the cancelled start returns
    public private(set) var outputStarts = 0
    public private(set) var problem = false

    public init(mutant: BMutant = .none) { self.mutant = mutant }

    public func isEnabled(_ e: BEvent) -> Bool {
        switch e {
        case .startCompletes: return !pendingStarts.isEmpty
        // B-T8/B-A8: the runtime serialises per assignment, so a stop completes only after the
        // start it cancelled has returned.
        case .stopCompletes: return stopPending && pendingStarts.isEmpty
        case .sourceGone: return state == .running || state == .starting
        case .retry: return state == .failed
        default: return true
        }
    }

    mutating func issueStart(_ out: inout BOutcome) {
        state = .starting; pendingStarts.append(true); out.startIssued = true
    }
    mutating func beginStop(_ out: inout BOutcome) {
        pendingStarts = pendingStarts.map { _ in false }
        state = .stopping; stopPending = true; out.stopIssued = true
    }

    public mutating func apply(_ e: BEvent) -> BOutcome {
        var out = BOutcome(state: state)
        switch e {
        case .activation(let on):
            powerOn = on
            if on {
                onAuthorized = true
                switch state {
                case .idle: issueStart(&out)                                          // B-I1
                case .starting: if mutant == .doubleStart { pendingStarts.append(true); out.startIssued = true } // B-S1
                case .running: if mutant == .activationRestartsRunning { beginStop(&out) } // B-R1
                case .stopping, .failed: break                                        // B-T1 (authorizes), B-A1, B-F1
                }
            } else {
                onAuthorized = false
                switch state {
                case .starting, .running: beginStop(&out)                             // B-S2, B-R2
                case .failed: state = .idle; problem = false                          // B-F2
                case .idle, .stopping: break
                }
            }
        case .positions(let on):
            powerOn = on                                                              // B-x3: positions never start a lane
            if !on {
                onAuthorized = false
                switch state {
                case .running: beginStop(&out)                                        // B-R4
                case .starting: if mutant != .positionsOffSkipsStarting { beginStop(&out) } // B-S4
                default: break
                }
            }
        case .parameters:
            parameters += 1
            switch state {
            case .running: laneParameters = parameters                                // B-R5
            case .starting: if mutant == .parametersStopStarting { beginStop(&out) }  // B-S5
            default: break
            }
        case .startCompletes(let ok):
            let live = pendingStarts.removeFirst()
            if live && ok {                                                           // B-S6
                state = .running; outputStarts += 1; out.outputStarted = true; laneParameters = parameters
            } else if live {                                                          // B-S7: shown once
                state = .failed; problem = true
                if mutant == .failureAutoRetries { issueStart(&out) }
            } else if ok && mutant == .cancelledStartSounds {
                outputStarts += 1; out.outputStarted = true
            } else if !ok && mutant == .cancelledFailureShows {                       // B-S7: cancelled, silent
                problem = true
            }
            if failurePending && pendingStarts.isEmpty {                              // B-S9: the cancelled start returned
                failurePending = false
                state = .failed; problem = true
            }
        case .stopCompletes:                                                          // B-T8, B-A8
            stopPending = false
            state = .idle
            let resume: Bool
            switch mutant {
            case .resumeFromStaleActivation: resume = lastActivationOn
            case .restartStranded: resume = false
            default: resume = powerOn && onAuthorized
            }
            if resume { issueStart(&out) }
        case .sourceGone:
            if state == .starting {                                                   // B-S9
                // The invalidation's stop waits for the start it cancels: stopping, with the failure recorded.
                pendingStarts = pendingStarts.map { _ in false }
                state = .stopping; failurePending = true; out.stopIssued = true
            } else {                                                                  // B-R9
                state = .failed; problem = true
            }
        case .retry:                                                                  // B-F10
            state = .idle; problem = false
            if powerOn && onAuthorized { issueStart(&out) }
        }
        if case .activation(let on) = e { lastActivationOn = on }
        out.state = state
        out.problem = problem
        return out
    }
    var lastActivationOn = false

    public mutating func settle() -> BSettled {
        var steps = 0
        while steps < 8 {
            if !pendingStarts.isEmpty { _ = apply(.startCompletes(ok: true)) }
            else if stopPending { _ = apply(.stopCompletes) }
            else { break }
            steps += 1
        }
        return BSettled(state: state, outputStarts: outputStarts, laneParameters: laneParameters,
                        parameters: parameters, steps: steps, problem: problem)
    }
}

/// Invariants for (B), restated from the event list and the reported start/stop/sound effects.
public enum LaneInvariants {
    public static func violations(_ events: [BEvent], _ outcomes: [BOutcome], settled: BSettled) -> [String] {
        var out: [String] = []
        var power = false, authorized = false
        var issued: [(index: Int, live: Bool)] = []  // outstanding starts in issue order
        var sounding = false
        var failed = false, failedPending = false
        for (i, e) in events.enumerated() {
            let o = outcomes[i], step = i + 1
            let before = i == 0 ? LaneState.idle : outcomes[i - 1].state
            if let on = e.power {
                power = on
                if !on { authorized = false; issued = issued.map { ($0.index, false) } }
                else if case .activation = e { authorized = true }
            }
            switch e {
            case .activation(let on):
                if !on { failed = false }
                if on {
                    // B-I1, B-S1, B-R1, B-T1, B-F1: ON starts a lane only from idle, and never restarts one.
                    let expectStart = before == .idle
                    if o.startIssued != expectStart || o.stopIssued {
                        out.append("B2/B8 ON activation at \(step) from \(before.rawValue) gave \(o)")
                    }
                }
            case .positions(let on):
                if o.startIssued { out.append("B3 positions at \(step) started a lane") }
                if on && o.stopIssued { out.append("B4 positions ON at \(step) stopped a lane") }
                if !on && (before == .starting || before == .running) && !o.stopIssued {
                    out.append("B1 positions OFF at \(step) left a \(before.rawValue) lane running")
                }
            case .parameters:
                if o.startIssued || o.stopIssued { out.append("B4 parameter change at \(step) gave \(o)") }
            case .startCompletes(let ok):
                let start = issued.isEmpty ? (index: -1, live: false) : issued.removeFirst()
                if o.outputStarted {
                    if !start.live || !power { out.append("B1 sound at \(step) after OFF (start issued at \(start.index + 1))") }
                    if sounding { out.append("B2 second sounding lane at \(step)") }
                    sounding = true
                }
                if !ok && start.live { failed = true }
                if failedPending && issued.isEmpty { failedPending = false; failed = true }   // B-S9
            case .stopCompletes:
                let expectRestart = power && authorized
                if o.startIssued != expectRestart {
                    out.append("B7 stop completion at \(step) \(o.startIssued ? "restarted" : "did not restart"), expected \(expectRestart ? "a restart" : "none")")
                }
            case .sourceGone:
                // B-R9 fails at once; B-S9 fails when the cancelled start returns.
                if before == .starting { failedPending = true } else { failed = true }
                sounding = false
                issued = issued.map { ($0.index, false) }
            case .retry:
                failed = false
            }
            if o.stopIssued { sounding = false }
            if o.startIssued {
                if failed { out.append("B6 start at \(step) while failed, without retry or OFF") }
                if issued.contains(where: { $0.live }) { out.append("B2 second live start at \(step)") }
                issued.append((i, true))
            }
            if o.outputStarted, !(e == .startCompletes(ok: true)) { out.append("B1 sound outside a start completion at \(step)") }
            // B9: the problem shows exactly while the lane has failed (a cancelled start's failure shows nothing).
            if o.problem != failed { out.append("B9 problem \(o.problem) at \(step), expected \(failed)") }
        }
        let expectState: LaneState = failed || failedPending ? .failed : (power && authorized ? .running : .idle)
        if settled.state != expectState { out.append("B2 settled \(settled.state.rawValue), expected \(expectState.rawValue)") }
        if settled.state == .running && settled.laneParameters != settled.parameters {
            out.append("B5 running lane has parameters \(settled.laneParameters) of \(settled.parameters)")
        }
        if settled.steps >= 8 { out.append("B6 settling did not finish") }
        return out
    }
}
