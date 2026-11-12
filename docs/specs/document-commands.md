# Document command infrastructure, first slice

Historical first-slice snapshot, retained for implementation context. Its
unimplemented-boundary statements describe that slice, not the current source.
See [Quick Menu development](../quick-menu-development.md) for the current branch.

Status: internal root/assignment command model with a restart-data envelope,
not connected to the app or a released public file/API. Current unit/evidence and independent read scopes are tracked in the
lead's production-app plans/reports, not inferred from this spec's snapshot.

## Owner and state

`SoundDocument` is the sole actor for one in-memory document. All mutations go
through `perform`; neither UI nor agent adapters own another mutable copy.
Transactions contain no suspension points. Snapshot values are immutable copies,
not handles to mutable authoring objects or native processors.

An ordered library contains `BlockDefinition` values: stable DefinitionID,
immutable DefinitionVersionID/content, and a library name. An ordered root-use
list references those versions and stores `UseName.library/own(String)`, not
positions. A name equal to the library name can still be explicitly owned.
A rename never changes content or its version ID. There is
only one content version per definition in this slice; publishing/history of
library versions is not implemented.

**User decision, DECISIONS §3, 2026-10-28:** a top control's position is where
you are listening. Moving controls never marks a block changed here, offers
Update Library…, or enters publication. Each use and app keeps its positions.

`DocumentSnapshot.listening` is a separate root-keyed collection of
`UseListeningState.positions`. A move changes that state, never a definition or
RootSoundUse. Sparse missing positions evaluate from the definition's construction
seeds; the first explicit equal-seed record remains a listening-state record,
not an authored override. Choice moves retain canonical normalized positions.
The later recorded operator choice changes history: outside Edit, playing never
enters Undo; in Edit, control moves stay undoable. Neither
disk I/O nor a publish/changed-here API exists yet. A future publisher
must consume authored data rather than merge evaluated listening positions into it.

`PlaybackAssignment` binds a stable AssignmentID and ApplicationKey to a root.
ApplicationKey is a nonempty bundle identifier with no whitespace/control
characters, not a live PID/HAL object or a tab. Assignments have their own
`assignmentListening` collection. Two apps sharing a root do not share positions
with each other or its editor/listening context. `assign` requires an explicit
initial record; an empty record uses authored construction seeds. It never
copies another app's latest positions. There is one assignment per app in this
unit; duplicate app binding is refused rather than silently reassigned.

Assignment creation/removal, enabled state and assignment-control moves are
menu-only listening/session actions. They do not enter authored Undo/Redo or
clear redo. This is the lead's v0.1 integration choice, not a claim that the
operator settled a future assignment-editing history policy. No native start,
automatic process fallback or device authority follows from a model binding.

Global `isEnabled` is desired session state, separate from authored/history and
gesture snapshots. `setEnabled` never enters Undo or clears Redo. It remains
available during a gesture, so switching TNF off cannot be refused by a drag;
cancel and history cannot undo that switch. First construction is off. It is
not capture status or evidence of audible output.

The compiler resolves the exact definition/version reference, applies a root's
listening positions, and returns complete target data and the observed document
revision in one `DocumentEvaluation`. `evaluate(assignment:)` selects that app's
positions explicitly. Off assignments can still be evaluated; the runtime must
honor enabled state separately. Two uses/apps compile independently. This is
authoring/control-rate work, never a render-callback operation.

## Commands

| Operation | Effect |
|---|---|
| addDefinition | Validate content/catalog and name, then add one definition. IDs/version IDs must be unique. |
| instantiate | Create an inheriting root use referring to an existing definition/version. |
| moveControl | Required context is .listening (outside Edit, no undo entry/redo clearing) or .editing (undoable). Both set root listening positions without changing authored use/definition data. Choices store canonical positions; XY is one commit. |
| renameDefinition | Change the library name and all resolved inheriting use names in one undo step. |
| renameUse | Set an explicit own name, even if it equals the library name. |
| useLibraryName | Clear that flag; Undo restores it. |
| assign | Validate root, unique assignment/app and explicit initial positions; add one app listening context. |
| moveAssignmentControl | Listening-only, canonical normalized choice/atomic XY; complete evaluation without changing authored or root-listening data. |
| setAssignmentEnabled / unassign | Set the app's Off state without losing positions, or remove its binding and listening record together. No audio action. |
| setEnabled | Set global desired on/off, independently of editing history/gestures. No audio action. |
| undo / redo | Apply the last edit's recorded scope, not an old whole-document snapshot. Authored edits restore metadata/references; control edits restore only their addressed positions. |

Commands validate before committing a value copy. Invalid references, duplicate
IDs, wrong value shapes, invalid content and empty/whitespace-only names are
refused without changing content, revision or history. Names are not silently
trimmed. Exact no-ops preserve redo and do not advance the revision. The first
explicit equal-to-seed listening record changes document state, not authored
ownership. It is never a changed-here/publication signal; outside Edit it consumes
no history. In Edit the retained first record is undoable.
Choice normalization happens at command ingress; it does not change the authored
definition's baseline or implement option-count editing/remapping.

Every actual content change, including listening or changed cancellation, advances a
checked UInt64 document revision. This is not an authored-dirty or publishability
stamp. Undo never rewinds that number. `DocumentReceipt`
reports this model commit only; it does not create a playback intent, promise
audibility, or report that native state adopted a change. A history-only Undo/Redo
traversal can change canUndo/canRedo while its addressed data already equals the
recorded target; like End, that returns didChange false without a new content
revision. It still consumes the edit and enables the opposite traversal.

## Scoped history

Authored entries store before/after definitions and uses, with an archive only
for roots added/removed by that entry. Restoring a rename preserves the current
positions of surviving roots. Removing/reinstating a root through Undo/Redo
archives/restores its latest listening record rather than leaving an orphan or
resetting its controls. Assignment records/positions for a removed root are
archived too. Restore them only when the root returns and their app is still
unbound. A newer binding survives; the skipped archived binding is spent so a
later Undo/Redo cannot revive it after Take Off. A future deletion command must
follow the same no-orphan invariant.

An in-Edit control entry stores before/after patches for changed control IDs.
Undo applies a patch only if that control still holds the entry's after value;
Redo requires its before value. A different current played value survives. Keep
only applied patches in the opposite stack entry: skipped patches are spent and
cannot reappear later just because playing returned to a matching old value.
Partially applicable entries still restore untouched controls. This is stored-
value comparison, not per-control generation tracking; intervening changes that
return to exactly the same stored value are not distinguished. XY is one atomic
value. Playing itself changes neither stack, clears no redo and evicts no authored
entry. New authored or editing changes clear redo as usual.

The explicit ControlMoveContext is required for both UI and agent commands.
There is no ambiguous legacy/default mode. Wiring it to the actual editor mode
remains UI integration. Before UI/MCP integration, validate it against one shared
Edit-mode authority. Headless agents must enter that same edit context, not invent
.editing while outside Edit. Choosing .editing does not implement teaching/write
rules or grant authority for unrelated changes.

## Gestures

`beginGesture(id, context:)` and `endGesture(id)` delimit a gesture explicitly.
While active, moveControl commands require its ID **and context**. Global
setEnabled without a gesture ID is also allowed, outside the gesture's scope.
Mixed contexts are refused before content/history changes. Other
commands receive a typed refusal; they are not queued or retried automatically.
This is a provisional owner-serialization rule, not a new restriction on the
final interface's rename or multi-input behavior.

At End, only an editing gesture with a net change becomes one positional-patch
undo entry. A listening gesture never enters history or clears redo. End itself
changes no content, so its receipt's
didChange is false and revision unchanged. `cancelGesture(id)` restores starting
content as a new revision if necessary in either context, without consuming earlier undo/redo.
Empty/net-unchanged gestures add no history entry. Closed IDs cannot be reused;
missing/wrong IDs and nested gestures are refused. No clock-based merge exists.

Owner construction requires an explicit validated `UndoHistoryLimit(groups:)`:
positive counts only, no production default. Completed undo/redo entries together
retain at most that many groups after a transaction; oldest completed groups are
discarded when a new group exceeds the limit. A drag counts once, at End. Cancel
does not consume a group or remove prior redo. This is an entry-count limit, not
a byte budget: authored before/after arrays, lifecycle archives and positional
patches can be large. Current state,
an active gesture's starting content and closed gesture IDs are outside that count;
closed IDs remain unbounded. Resource policy, recovery/autosave and crash semantics
are still later work. This actor never writes a file or global store.

No editor-wide history depth was selected. Test capacities are fixtures. The
listening-only facade uses a 64-group internal cap; it exposes no authoring or
Undo commands. The editor composition must choose its policy before integration.

The future MCP contract must classify transient busy separately from wrong/reused
IDs, wake on gesture completion rather than poll, revalidate current revision and
bound/cancel any retry. Ambiguous transport completion must not be blindly replayed.
No agent transport or automatic retry policy is implemented in this actor slice.

## Internal saved-session data

`sessionData()` exports version 1 of SoundSessionArchive. It includes actual
definitions/content, exact root references and names, sparse root positions,
app assignments/enabled flags, global desired enabled state and independent app positions. UUIDs are stable;
arrays of named position records allow duplicate-ID rejection. It excludes
PIDs, HAL handles, buffers, runtime epochs, login/autolaunch, Undo/Redo and gesture
IDs. This is an internal restart envelope, not a released block exchange schema.

`restoreSession` refuses an active gesture, unsupported version, corrupt data,
duplicate IDs/apps, missing versions/roots, invalid names, unknown controls,
wrong control shapes, noncanonical choices and invalid catalog targets. All
validation precedes one replacement with a newer local revision. Failure changes
nothing. A successful changed import clears history; importing identical data
is a no-op and does not clear it. Restore performs no capture or file I/O.
An absent global enabled field in an earlier internal v1 archive defaults off.

## Everyday listening facade

`ListeningSession` exposes immutable control metadata, listening-only commands,
saved data, and one coherent snapshot of desired power, assignments, positions
and ordered complete native-domain parameters. The underlying SoundDocument
remains the transaction owner. Snapshot projection/evaluation does not suspend.
`putEveryday` checks and assigns in one owner turn; selecting an already-bound
app is a no-op retaining its assignment, enabled state and positions. It is not
a substitute for an atomic multi-block reassign command.

Everyday is an actual SoundBlock with stable definition/version/control/option/
part IDs and six ordered parts. Its catalog converts normalized targets into
native domains off the audio thread. Device and Place have independent EQs;
Softer's log-frequency delta multiplies any Place cutoff by 0.7 at Gentle,
and gain contributions add in dB. Reverb roomPreset is a prepared factory
choice, not continuous room size. AU headroom 20→5 dB is a starting proposal,
not the brief's 1.2→3.5 compression ratio. Native transfer/ears must tune it.
Initial positions are Here, Own speakers and As is. Rain is deferred, not shown
as a nonfunctional control. Neither nonpositive gain nor a limiter proves SL0.

The menu-only facade adopts the shipped non-user-authored built-in on restore,
not arbitrary valid authoring documents. The internal migration requires the
same stable block and root identity. It keeps names, assignments, power and
independent listening positions. Choices retain their selected OptionID across
reordering or extension, rather than retaining a number that now means another
option. A removed selected option or removed control drops that override and
uses the shipped default. Slider and XY values retain their positions. A true
face-kind change refuses restore. Old overrides must remain canonical and
well-shaped even when their controls are removed; migration must not hide
duplicates, unknown controls or corrupt values. The restored document validates
the shipped definition and all remaining references before replacement.
This is not the future editable-library confirmation or option-edit policy.
Restore creates no capture. Startup reconciliation and atomic disk persistence
belong to app integration. Compare is temporary runtime state, not saved content.

Atomic file writing, size/depth policy, autosave ordering, invalid-file recovery,
application startup and listening acceptance remain integration work. A memory
roundtrip is not a demonstrated app restart, nor a portable/public migration
promise. A future schema must handle its version explicitly.

## Acceptance and remaining boundaries

Run `python3 tools/check-sound-model.py`. The shared runner now awaits both
the original synchronous contracts and async actor scenarios; the actual XCTest
adapter invokes the same cases when XCTest is available. Portable execution is
not an XCTest pass on machines missing that framework.

The root-level contracts cover listening moves leaving authored use/definition
data unchanged, outside-Edit playing not evicting edits/clearing redo, scoped
restoration and root lifecycle, independent and newly instantiated uses, exact stored XY/coherent
evaluated targets, one-gesture undo, monotonic revisions, cancellation/redo,
own-name collisions, equal-value ownership, atomic refusal, creation undo and
32 concurrent metadata commands. They do not establish timing or audio quality.

Not implemented: linked nested uses, parameter/mapping local changes, nudges/off,
editing-mode write rules, teaching, authoring-time option edits/remapping, control-to-control
targets, per-option sets, structural drafts/A24, confirmed publication/rebase,
version history, duplicate/paste, deletion, agents' external transport, disk persistence
or native runtime/UI. Those remain the decided product work, not discarded scope.
The high model-01 findings still gate option editing and teaching. The known
neighbor-waypoint tangent kink needs listening acceptance when teaching exists.
