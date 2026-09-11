import Machine.PreparedRun
import Machine.Rng
/-!
# Machine state

One run's complete state: components, connections, the calendar, the clock,
the observable-state store with dirty tracking, the transfer custody table,
per-component RNG streams and identifier counters, the external-input
transcript, counters, and the trace. The trace is machine state, not a side
effect of observation. Every run mints its event envelopes unconditionally.

Static run input is validated and normalized by `prepareRun` before machine
state exists; `fromPreparedRun` constructs a fresh run instance from the
prepared data.

Store writes become pending changes only when the value changes
(`StateValue.unchanged`: numbers compare under IEEE `==`, so a NaN write
always changes and `-0.0 → 0.0` does not; a kind change always changes).
Calendar entries use `(totalCmp time, seq)` order, and `seq` increments on
every insertion. Event envelope sequence values are independent of calendar
sequence values.
-/

namespace Machine

/-- Calendar targets. -/
inductive CalendarTarget where
  | timer (componentIndex : Nat) (timerId : TimerId)
  /-- First delivery attempt of transfer `(senderIndex, transferId)`. -/
  | deliver (senderIndex : Nat) (transferId : TransferId)
  /-- Redeliver the oldest blocked transfer destined to `(componentIndex, port)`
  after that receiver reported readiness. Provisional retry rule. -/
  | redeliver (componentIndex : Nat) (port : String)
  /-- Deliver a message payload through connection `connectionIndex`. -/
  | message (connectionIndex : Nat) (payload : JsonValue)
  /-- Deliver a changed input value through connection `connectionIndex`. -/
  | valueInput (connectionIndex : Nat) (value : StateValue)
  /-- Dispatch admitted external input `ordinal`. -/
  | external (ordinal : Nat)
  /-- Interval sample for output `outputIndex` (recorder). -/
  | sample (outputIndex : Nat)
  /-- The warmup boundary: recorder activation. -/
  | warmup
  /-- Dispatch resolution round `roundIndex`. -/
  | round (roundIndex : Nat)

/-- A calendar entry, totally ordered by `(totalCmp time, seq)`. -/
structure CalendarEntry where
  time : Time
  seq : UInt64
  target : CalendarTarget

def CalendarEntry.lt (left right : CalendarEntry) : Bool :=
  match totalCmp left.time right.time with
  | .lt => true
  | .gt => false
  | .eq => left.seq < right.seq

/-- The static half is the `PreparedRun`; everything else evolves per step. -/
structure MachineState : Type 1 where
  prepared : PreparedRun
  /-- Overlay written by applied overrides; read ahead of configured parameters. -/
  parameterOverrides : EvaluationScope := []
  /-- Overrides not yet applied, ordered by (afterSeq, insertion order). -/
  pendingOverrides : List (UInt64 × String × Float) := []
  components : Array RuntimeComponent
  calendar : List CalendarEntry
  calendarSequence : UInt64
  time : Time
  store : List (String × StateValue)
  dirty : Array (String × StateValue)
  pending : Array (String × String × JsonValue)
  randomStreams : Array Pcg64Mcg
  /-- Per-component counters for component-scoped timer identifiers. -/
  timerCounters : Array UInt64
  /-- Per-component counters for component-scoped transfer identifiers. -/
  transferCounters : Array UInt64
  /-- The kernel custody table, in transfer allocation order. -/
  transfers : Array TransferRecord
  /-- Immutable transcript of admitted external inputs, in admission order. -/
  externalTranscript : Array ExternalInputRecord
  entityCounter : UInt64
  eventSequence : UInt64
  trace : Array JsonValue
  stopRequested : Bool
  progressBucket : UInt64
  recorder : Recorder
  rounds : Array Round

namespace MachineState

/-! Static-configuration accessors, so call sites read as machine state. -/

def componentIds (state : MachineState) : Array String := state.prepared.componentIds
def connections (state : MachineState) : Array Connection := state.prepared.connections
def duration (state : MachineState) : Time := state.prepared.configuration.duration
def runMetadata (state : MachineState) : JsonValue := state.prepared.runMetadata
def parameters (state : MachineState) : EvaluationScope :=
  state.parameterOverrides ++ state.prepared.configuration.parameters
def stopWhen (state : MachineState) : Option Machine.Expr := state.prepared.configuration.stopWhen
def emitStateEvents (state : MachineState) : Bool := state.prepared.configuration.emitStateEvents
def externalPorts (state : MachineState) : List (Nat × String) :=
  state.prepared.configuration.externalPorts

/-- Construct initial machine state with one labeled random stream per component. -/
def fromPreparedRun (prepared : PreparedRun) : MachineState where
  prepared
  pendingOverrides := prepared.configuration.overrides
  components := prepared.components
  calendar := []
  calendarSequence := 0
  time := 0.0
  store := []
  dirty := #[]
  pending := #[]
  randomStreams := prepared.componentIds.map (stream prepared.configuration.seed ·)
  timerCounters := prepared.componentIds.map fun _ => 0
  transferCounters := prepared.componentIds.map fun _ => 0
  transfers := #[]
  externalTranscript := #[]
  entityCounter := 0
  eventSequence := 0
  trace := #[]
  stopRequested := false
  progressBucket := 0
  recorder := Recorder.new prepared.configuration.outputs
  rounds := prepared.configuration.rounds.map
    (Round.fromConfiguration prepared.configuration.seed)

/-- Read published state as its typed value. -/
def observeState (state : MachineState) (path : String) : Option StateValue :=
  state.store.lookup path

/-- Read published state coerced to a number. Integers widen, booleans coerce
to `1`/`0`, strings and absent state read as `none`. -/
def readState (state : MachineState) (path : String) : Option Float :=
  (state.store.lookup path).bind StateValue.asFloat

/-- Write store state and mark the path pending only when the value changes. -/
def setState (state : MachineState) (path : String) (value : StateValue) : MachineState :=
  let prev := state.store.lookup path
  let store :=
    if prev.isSome then state.store.map fun (k, x) => if k == path then (k, value) else (k, x)
    else (path, value) :: state.store
  let changed := match prev with
    | some p => !(p.unchanged value)
    | none => true
  { state with store, dirty := if changed then state.dirty.push (path, value) else state.dirty }

/-- Write numeric store state (ledger commits and driver publication). -/
def setNumberState (state : MachineState) (path : String) (value : Float) : MachineState :=
  state.setState path (.number value)

/-- Push a calendar entry at `time` and allocate the next calendar sequence. -/
def scheduleAt (state : MachineState) (time : Time) (target : CalendarTarget) : MachineState :=
  let sequence := state.calendarSequence + 1
  { state with
    calendarSequence := sequence
    calendar := ⟨time, sequence, target⟩ :: state.calendar }

/-- Remove and return the least calendar entry under `(totalCmp time, seq)`.
One pass carrying (least so far, everything else); the leftover order is
irrelevant because ordering is imposed here, at pop. -/
def popNextCalendarEntry (state : MachineState) : Option (CalendarEntry × MachineState) :=
  match state.calendar with
  | [] => none
  | e :: es =>
    let (best, rest) := es.foldl (init := (e, ([] : List CalendarEntry)))
      fun (best, rest) x =>
        if CalendarEntry.lt x best then (x, best :: rest) else (best, x :: rest)
    some (best, { state with calendar := rest })

/-- The least calendar entry time under `(totalCmp time, seq)`, without
removal. The whole calendar is in scope, including entries past the run's end
time. -/
def peekNextCalendarTime (state : MachineState) : Option Time :=
  match state.calendar with
  | [] => none
  | e :: es =>
    let best := es.foldl (init := e) fun best x =>
      if CalendarEntry.lt x best then x else best
    some best.time

/-- Whether `time` lies past the run's end time. This is the run-boundary
rule: dispatch never reaches such a time, because the run completes at the
end time first. -/
def pastEndTime (state : MachineState) (time : Time) : Bool :=
  time > state.duration

/-- The pending calendar entry for timer `(componentIndex, timerId)`, if any. -/
def pendingTimerEntry (state : MachineState) (componentIndex : Nat) (timerId : TimerId) :
    Option CalendarEntry :=
  state.calendar.find? fun entry =>
    match entry.target with
    | .timer entryComponent entryTimer =>
      entryComponent == componentIndex && entryTimer == timerId
    | _ => false

/-- Remove every calendar entry whose target satisfies `targetMatches`. -/
def removeCalendarEntries (state : MachineState) (targetMatches : CalendarTarget → Bool) :
    MachineState :=
  { state with calendar := state.calendar.filter fun entry => !targetMatches entry.target }

/-- Remove the pending calendar entry for timer `(componentIndex, timerId)`. -/
def removeTimerEntry (state : MachineState) (componentIndex : Nat) (timerId : TimerId) :
    MachineState :=
  state.removeCalendarEntries fun
    | .timer entryComponent entryTimer =>
      entryComponent == componentIndex && entryTimer == timerId
    | _ => false

/-- Remove the pending delivery entry for transfer `(senderIndex, transferId)`. -/
def removeDeliverEntry (state : MachineState) (senderIndex : Nat) (transferId : TransferId) :
    MachineState :=
  state.removeCalendarEntries fun
    | .deliver entrySender entryTransfer =>
      entrySender == senderIndex && entryTransfer == transferId
    | _ => false

/-- The custody-table index of transfer `(senderIndex, transferId)`, if any. -/
def transferIndex (state : MachineState) (senderIndex : Nat) (transferId : TransferId) :
    Option Nat :=
  state.transfers.findIdx? fun record =>
    record.sender == senderIndex && record.id == transferId

/-- The custody-table index of the oldest blocked transfer destined to
`(componentIndex, port)`, if any. Table order is allocation order, so the
scan is oldest first. -/
def oldestBlockedTransferTo (state : MachineState) (componentIndex : Nat) (port : String) :
    Option Nat :=
  state.transfers.findIdx? fun record =>
    record.status == .blocked &&
      (state.connections[record.connectionIndex]!).dst == (componentIndex, port)

/-- Append an envelope to the trace with the next event sequence. -/
def appendEventEnvelope (state : MachineState) (source eventType : String)
    (payload : JsonValue) : MachineState :=
  let sequence := state.eventSequence + 1
  let envelope := JsonValue.obj
    [ ("v", .str "0.1"), ("seq", .nat sequence.toNat), ("time", .float state.time)
    , ("type", .str eventType), ("source", .str source), ("run", state.runMetadata)
    , ("payload", payload) ]
  { state with eventSequence := sequence, trace := state.trace.push envelope }

/-- Post-dispatch flush: per store dirty write (in write order), recorder
`metric.updated` emissions first, then `state.changed`; after all dirty
writes, component-emitted events in emission order. Only numerically
coercible values reach the recorder. -/
def flushPendingChanges (state : MachineState) : MachineState :=
  let dirty := state.dirty
  let pending := state.pending
  let state := { state with dirty := #[], pending := #[] }
  let state := dirty.foldl (init := state) fun state (path, value) =>
    let source := (path.splitOn ".").headD "kernel"
    let state : MachineState := match value.asFloat with
      | some numeric =>
        let (recorder, metrics) := state.recorder.onChange path numeric state.time
        let state := { state with recorder }
        metrics.foldl (init := state) fun (state : MachineState) (name, metricValue) =>
          state.appendEventEnvelope source "metric.updated"
            (.obj [("name", .str name), ("value", .float metricValue)])
      | none => state
    if state.emitStateEvents then
      state.appendEventEnvelope source "state.changed"
        (.obj [("path", .str path), ("value", value.toJson)])
    else state
  pending.foldl (init := state) fun state (source, eventType, payload) =>
    state.appendEventEnvelope source eventType payload

/-- Prepared routes leaving `(componentIndex, port)`, in connection order. -/
def outgoingConnectionsOf (state : MachineState) (componentIndex : Nat)
    (port : String) : List Route :=
  (state.prepared.outgoing[componentIndex]!).filter fun route =>
    (state.connections[route.index]!).src == (componentIndex, port)

/-- Connection indices arriving at `(componentIndex, port)`, in connection order. -/
def incomingConnectionsOf (state : MachineState) (componentIndex : Nat)
    (port : String) : List Nat :=
  (state.prepared.incoming[componentIndex]!).filter fun connectionIndex =>
    (state.connections[connectionIndex]!).dst == (componentIndex, port)

end MachineState

end Machine
