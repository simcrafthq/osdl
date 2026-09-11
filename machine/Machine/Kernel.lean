import Machine.MachineState
/-!
# The kernel: interpreter and dispatch

The kernel is the interpreter of the operation signature.
`applyComponentOperation` gives each operation its semantics against the
machine state. `runComponentProgram` runs a component program. The dispatch
helpers run one entry point and `flushPendingChanges`. `stepOnce` dispatches
one calendar entry: one scheduled event dispatch plus its synchronous
reaction validation and command interpretation.

Deliver protocol: pop `deliver` → dispatch `receive` on the target (its
pending changes flush first) → on `accept`, mark the transfer `delivered`,
append `entity.moved`, then dispatch the sender's
`handle (sendResult Delivered)`; on `block`, keep the exact entity in kernel
escrow, mark the transfer `blocked`, and dispatch the sender's
`handle (sendResult Blocked)` with no entity value. A later `reportReady`
from the receiver schedules a `redeliver` entry; redelivery dispatches
`receive` again for the oldest blocked transfer to that port and notifies
the sender only when the outcome changes. After every event: due parameter
overrides, progress buckets, then `stopWhen`, then the component stop
request.

Run control (create, step, run, runThrough, external input, cancellation,
reports) lives in `Machine/RunControl.lean`.
-/

namespace Machine

/-- Result of a kernel step: the error side carries the state at failure so
the partial trace survives. -/
abbrev MachineResult (α : Type u) := Except (Diagnostic × MachineState) α

/-- A component failure attributed at the raise site to the component,
operation, and time it arose in. -/
private def componentFailure (componentIndex : Nat) (operationName : String)
    (state : MachineState) (message : String) : Diagnostic × MachineState :=
  let component := state.components[componentIndex]!
  ( { code := .componentFailure
      message :=
        s!"component \"{state.componentIds[componentIndex]!}\" ({component.componentType}) {operationName} at simulation time {displayTime state.time}: {message}"
      source := some state.componentIds[componentIndex]!
      operation := some operationName
      time := state.time }
  , state )

/-- Apply one component operation to the machine state. `operationName` is the
entry point being dispatched; component failures are attributed to it. -/
def applyComponentOperation (componentIndex : Nat) (operationName : String)
    (state : MachineState) : ComponentOperation α → MachineResult (α × MachineState)
  | .now => .ok (state.time, state)
  | .componentId => .ok (state.componentIds[componentIndex]!, state)
  | .routes port => .ok (state.outgoingConnectionsOf componentIndex port, state)
  | .scheduleAfter delay =>
    if !delay.isFinite || delay < 0.0 then
      .error (componentFailure componentIndex operationName state
        "scheduleAfter with non-finite or negative delay")
    else
      let time := state.time + delay
      if !time.isFinite then
        .error (componentFailure componentIndex operationName state
          "scheduled timer time is not finite")
      else
        let timerId : TimerId := ⟨state.timerCounters[componentIndex]! + 1⟩
        let state := { state with
          timerCounters := state.timerCounters.set! componentIndex timerId.value }
        .ok (timerId, state.scheduleAt time (.timer componentIndex timerId))
  | .scheduleAt time =>
    if !time.isFinite then
      .error (componentFailure componentIndex operationName state
        "scheduleAt with non-finite time")
    else if time < state.time then
      .error (componentFailure componentIndex operationName state
        "scheduleAt with a time in the past")
    else
      let timerId : TimerId := ⟨state.timerCounters[componentIndex]! + 1⟩
      let state := { state with
        timerCounters := state.timerCounters.set! componentIndex timerId.value }
      .ok (timerId, state.scheduleAt time (.timer componentIndex timerId))
  | .cancelTimer timer =>
    .ok ((), state.removeTimerEntry componentIndex timer)
  | .rescheduleTimer timer time =>
    if !time.isFinite then
      .error (componentFailure componentIndex operationName state
        "rescheduleTimer with non-finite time")
    else if time < state.time then
      .error (componentFailure componentIndex operationName state
        "rescheduleTimer with a time in the past")
    else if (state.pendingTimerEntry componentIndex timer).isNone then
      .error (componentFailure componentIndex operationName state
        "rescheduleTimer for a timer that is not pending")
    else
      let state := state.removeTimerEntry componentIndex timer
      .ok (timer, state.scheduleAt time (.timer componentIndex timer))
  | .send route entity =>
    match state.connections[route.index]? with
    | none => .error (.runtime "send through an unknown route", state)
    | some connection =>
      if connection.src.fst != componentIndex then
        .error (.runtime "send through a route owned by another component", state)
      else
        let transferId : TransferId := ⟨state.transferCounters[componentIndex]! + 1⟩
        let record : TransferRecord :=
          { sender := componentIndex, id := transferId
            connectionIndex := route.index, entity, status := .pending }
        let state := { state with
          transferCounters := state.transferCounters.set! componentIndex transferId.value
          transfers := state.transfers.push record }
        .ok (transferId, state.scheduleAt state.time (.deliver componentIndex transferId))
  | .cancelTransfer transfer =>
    match state.transferIndex componentIndex transfer with
    | none =>
      .error (componentFailure componentIndex operationName state
        "cancelTransfer for an unknown transfer")
    | some index =>
      let record := state.transfers[index]!
      match record.status with
      | .pending =>
        let state := state.removeDeliverEntry componentIndex transfer
        .ok ((), { state with
          transfers := state.transfers.set! index { record with status := .cancelled } })
      | .blocked =>
        .ok ((), { state with
          transfers := state.transfers.set! index { record with status := .cancelled } })
      | _ =>
        .error (componentFailure componentIndex operationName state
          "cancelTransfer for a transfer that is already terminal")
  | .reportReady port =>
    .ok ((), state.scheduleAt state.time (.redeliver componentIndex port))
  | .sendMessage route payload =>
    match state.connections[route.index]? with
    | none => .error (.runtime "sendMessage through an unknown route", state)
    | some connection =>
      if connection.src.fst != componentIndex then
        .error (.runtime "sendMessage through a route owned by another component", state)
      else
        .ok ((), state.scheduleAt state.time (.message route.index payload))
  | .setOutput port value =>
    let connections := state.outgoingConnectionsOf componentIndex port
    let state := connections.foldl (init := state) fun state route =>
      state.scheduleAt state.time (.valueInput route.index value)
    .ok ((), { state with
      pending := state.pending.push
        ( state.componentIds[componentIndex]!, "value.changed"
        , .obj [("port", .str port), ("value", value.toJson)] ) })
  | .publishState stateVariable value =>
    .ok ((), state.setState s!"{state.componentIds[componentIndex]!}.{stateVariable}" value)
  | .observe path => .ok (state.observeState path, state)
  | .evaluate value locals =>
    match value.evaluate
      (EvaluationScope.resolve locals state.parameters state.readState) state.time with
    | .ok value => .ok (value, state)
    | .error message => .error (componentFailure componentIndex operationName state message)
  | .sample value locals =>
    match value.sample
      (EvaluationScope.resolve locals state.parameters state.readState) state.time
      state.randomStreams[componentIndex]! with
    | .ok (value, randomStream) =>
      .ok (value, { state with
        randomStreams := state.randomStreams.set! componentIndex randomStream })
    | .error message => .error (componentFailure componentIndex operationName state message)
  | .emitEvent eventType payload =>
    .ok ((), { state with
      pending := state.pending.push
        (state.componentIds[componentIndex]!, eventType, payload) })
  | .createEntity entityType agent =>
    let counter := state.entityCounter + 1
    let entity : Entity := ⟨counter, entityType, agent, state.time⟩
    let payload := JsonValue.obj
      [ ("entityId", .str entity.name)
      , ("entityType", .str entityType)
      , ("at", .str state.componentIds[componentIndex]!) ]
    .ok (entity, { state with
      entityCounter := counter
      pending := state.pending.push
        (state.componentIds[componentIndex]!, "entity.created", payload) })
  | .disposeEntity entity =>
    let payload := JsonValue.obj
      [ ("entityId", .str entity.name)
      , ("at", .str state.componentIds[componentIndex]!) ]
    .ok ((), { state with
      pending := state.pending.push
        (state.componentIds[componentIndex]!, "entity.disposed", payload) })
  | .randomBits =>
    let (value, randomStream) := (state.randomStreams[componentIndex]!).next
    .ok (value, { state with
      randomStreams := state.randomStreams.set! componentIndex randomStream })
  | .stopRun => .ok ((), { state with stopRequested := true })
  | .failRun message => .error (componentFailure componentIndex operationName state message)

/-- Run a component program to completion. -/
def runComponentProgram (componentIndex : Nat) (operationName : String) :
    ComponentProgram α → MachineState → MachineResult (α × MachineState)
  | .pure value, state => .ok (value, state)
  | .bind operation continuation, state =>
    match applyComponentOperation componentIndex operationName state operation with
    | .error errorAndState => .error errorAndState
    | .ok (value, state) =>
      runComponentProgram componentIndex operationName (continuation value) state

/-- Run one entry point, store its new local state, and flush pending changes. -/
def dispatchComponentWithResult (componentIndex : Nat)
    (operationName : String)
    (entryPoint : (component : RuntimeComponent) →
      ComponentProgram (component.σ × α))
    (state : MachineState) : MachineResult (α × MachineState) := do
  let component := state.components[componentIndex]!
  let ((nextComponentState, result), state) ←
    runComponentProgram componentIndex operationName (entryPoint component) state
  let state := { state with
    components := state.components.set! componentIndex
      { component with state := nextComponentState } }
  pure (result, state.flushPendingChanges)

/-- Dispatch a state-only entry point on one component. -/
def dispatchComponent (componentIndex : Nat)
    (operationName : String)
    (entryPoint : (component : RuntimeComponent) → ComponentProgram component.σ)
    (state : MachineState) : MachineResult MachineState := do
  let (_, state) ← dispatchComponentWithResult componentIndex operationName
    (fun component => do
      let nextComponentState ← entryPoint component
      pure (nextComponentState, ())) state
  pure state

/-- Dispatch `receive`, returning its `ReceiveDecision`. -/
def dispatchReceive (componentIndex : Nat) (entity : Entity) (port : String)
    (state : MachineState) : MachineResult (ReceiveDecision × MachineState) :=
  dispatchComponentWithResult componentIndex
    "receive"
    (fun component => component.behavior.receive component.state entity port) state

/-- Dispatch `handle` with one runtime event. -/
def dispatchHandle (componentIndex : Nat) (event : RuntimeEvent)
    (state : MachineState) : MachineResult MachineState :=
  dispatchComponent componentIndex "handle"
    (fun component => component.behavior.handle component.state event) state

/-- Which delivery attempt of a transfer is being processed. The sender
learns `Blocked` only on the first attempt. -/
inductive DeliveryAttempt where
  | first
  | redelivery
deriving BEq

/-- Process one delivery attempt for the transfer at custody-table index
`transferTableIndex`. -/
def processEntityDelivery (transferTableIndex : Nat) (attempt : DeliveryAttempt)
    (state : MachineState) : MachineResult MachineState := do
  let record := state.transfers[transferTableIndex]!
  let connection := state.connections[record.connectionIndex]!
  let entityName := record.entity.name
  let (decision, state) ← dispatchReceive
    connection.dst.fst record.entity connection.dst.snd state
  match decision with
  | .accept =>
    let record := state.transfers[transferTableIndex]!
    let state := { state with
      transfers := state.transfers.set! transferTableIndex
        { record with status := .delivered } }
    let payload := JsonValue.obj
      [ ("entityId", .str entityName)
      , ("from", .str state.componentIds[connection.src.fst]!)
      , ("to", .str state.componentIds[connection.dst.fst]!) ]
    let state := state.appendEventEnvelope
      state.componentIds[connection.dst.fst]! "entity.moved" payload
    let state ← dispatchHandle connection.src.fst
      (.sendResult record.id .delivered) state
    -- Redelivery after acceptance continues to drain: the receiver stays
    -- ready until it blocks again.
    if attempt == .redelivery then
      match state.oldestBlockedTransferTo connection.dst.fst connection.dst.snd with
      | some _ =>
        pure (state.scheduleAt state.time (.redeliver connection.dst.fst connection.dst.snd))
      | none => pure state
    else
      pure state
  | .block =>
    let record := state.transfers[transferTableIndex]!
    let state := { state with
      transfers := state.transfers.set! transferTableIndex
        { record with status := .blocked } }
    if attempt == .first then
      dispatchHandle connection.src.fst (.sendResult record.id .blocked) state
    else
      pure state

/-- Dispatch one resolution round against the frozen state snapshot. -/
def processResolutionRound (roundIndex : Nat) (state : MachineState) :
    MachineResult MachineState := do
  let round := state.rounds[roundIndex]!
  let before := round.ledger
  match ResolutionRound.dispatch round state.readState state.time with
  | .error message =>
    .error ({ Diagnostic.component message with time := state.time }, state)
  | .ok (updatedRound, emissions) =>
    let state := { state with rounds := state.rounds.set! roundIndex updatedRound }
    let state := (Ledger.commits before updatedRound.ledger).foldl (init := state)
      fun state (path, balance) => state.setNumberState path (Float.ofNat balance)
    let state := emissions.foldl (init := state)
      fun state (source, eventType, payload) =>
        { state with pending := state.pending.push (source, eventType, payload) }
    let state := match updatedRound.interval with
      | some interval => state.scheduleAt (state.time + interval) (.round roundIndex)
      | none => state
    .ok state.flushPendingChanges

/-- Append progress events in 1% buckets. -/
def progress (state : MachineState) : MachineState :=
  let bucket := ((state.time / state.duration) * 100.0).toUInt64
  if bucket > state.progressBucket then
    let progressValue := state.time / state.duration
    let progressValue :=
      if progressValue < 0.0 then 0.0
      else if progressValue > 1.0 then 1.0
      else progressValue
    ({ state with progressBucket := bucket }).appendEventEnvelope
      "kernel" "sim.progress" (.obj [("progress", .float progressValue)])
  else state

/-- Applies the sorted prefix of overrides due at the current event sequence. -/
def applyDueOverrides (state : MachineState) : MachineResult MachineState :=
  go state.pendingOverrides state
where
  go : List (UInt64 × String × Float) → MachineState → MachineResult MachineState
    | [], state => .ok { state with pendingOverrides := [] }
    | entry :: pending, state =>
      let (afterSeq, name, value) := entry
      if afterSeq ≤ state.eventSequence then
        -- Preparation validates override names; application does not look
        -- them up again.
        let state := { state with
          parameterOverrides := (name, value) :: state.parameterOverrides }
        let state := state.appendEventEnvelope "kernel" "param.changed"
          (.obj [("name", .str name), ("value", .float value)])
        go pending state
      else
        .ok { state with pendingOverrides := entry :: pending }

/-- The disposition of one calendar-dispatch semantic unit. -/
inductive StepDisposition : Type 1 where
  /-- The run remains active. -/
  | active (state : MachineState)
  /-- The run completed normally. `finish` has not run yet. -/
  | completed (reason : CompletionReason) (state : MachineState)
  /-- The run failed with a semantic diagnostic. -/
  | failed (diagnostic : Diagnostic) (state : MachineState)

/-- Dispatch one calendar target against the current machine state. -/
private def dispatchCalendarTarget (target : CalendarTarget) (state : MachineState) :
    MachineResult MachineState :=
  match target with
  | .timer componentIndex timerId =>
    dispatchHandle componentIndex (.timerFired timerId) state
  | .deliver senderIndex transferId =>
    match state.transferIndex senderIndex transferId with
    | some index =>
      if (state.transfers[index]!).status == .pending then
        processEntityDelivery index .first state
      else .ok state
    | none =>
      .error ({ Diagnostic.runtime "delivery for an unknown transfer" with
        time := state.time }, state)
  | .redeliver componentIndex port =>
    match state.oldestBlockedTransferTo componentIndex port with
    | some index => processEntityDelivery index .redelivery state
    | none => .ok state
  | .message connectionIndex payload =>
    let connection := state.connections[connectionIndex]!
    let state := state.appendEventEnvelope
      state.componentIds[connection.src.fst]! "message.sent"
      (.obj [ ("from", .str state.componentIds[connection.src.fst]!)
            , ("to", .str state.componentIds[connection.dst.fst]!)
            , ("port", .str connection.dst.snd) ])
    dispatchHandle connection.dst.fst
      (.messageReceived connection.dst.snd payload) state
  | .valueInput connectionIndex value =>
    let connection := state.connections[connectionIndex]!
    dispatchHandle connection.dst.fst
      (.inputValueChanged connection.dst.snd value) state
  | .external ordinal =>
    match state.externalTranscript[ordinal]? with
    | some record =>
      dispatchHandle record.componentIndex
        (.externalInput record.port record.payload) state
    | none =>
      .error ({ Diagnostic.runtime "dispatch of an unknown external input" with
        time := state.time }, state)
  | .sample outputIndex =>
    let (recorder, emissions, interval) :=
      state.recorder.sample outputIndex state.readState state.time
    let state := { state with recorder }
    let state := emissions.foldl (init := state) fun state (name, value) =>
      state.appendEventEnvelope "kernel" "metric.updated"
        (.obj [("name", .str name), ("value", .float value)])
    .ok (match interval with
      | some interval =>
        state.scheduleAt (state.time + interval) (.sample outputIndex)
      | none => state)
  | .warmup =>
    .ok { state with
      recorder := state.recorder.activate state.time state.readState }
  | .round roundIndex => processResolutionRound roundIndex state

/-- Dispatch one calendar entry and its post-event checks: exactly one
calendar-dispatch semantic unit. -/
def stepOnce (state : MachineState) : StepDisposition :=
  match state.popNextCalendarEntry with
  | none => .completed .quiescent state
  | some (entry, popped) =>
    if state.pastEndTime entry.time then .completed .endTime state
    else
      let state := { popped with time := entry.time }
      let step := dispatchCalendarTarget entry.target state
      match step with
      | .error (diagnostic, state) => .failed diagnostic state
      | .ok state =>
        match applyDueOverrides state with
        | .error (diagnostic, state) => .failed diagnostic state
        | .ok state =>
          let state := progress state
          let stopHit : MachineResult Bool :=
            match state.stopWhen with
            | some expression =>
              match expression.eval {
                resolve := EvaluationScope.resolve [] state.parameters state.readState
                time := state.time
              } with
              | .ok value => .ok (value != 0.0)
              | .error message =>
                .error ({ Diagnostic.expr message with time := state.time }, state)
            | none => .ok false
          match stopHit with
          | .error (diagnostic, state) => .failed diagnostic state
          | .ok true => .completed .condition state
          | .ok false =>
            if state.stopRequested then .completed .requested state
            else .active state

/-- Start every component in slot order. Provisional startup rule pending the
startup-transaction prototype. -/
def startComponents (state : MachineState) : MachineResult MachineState :=
  (List.range state.components.size).foldlM (init := state) fun state componentIndex =>
    dispatchComponent componentIndex "start"
      (fun component => component.behavior.start component.state) state

/-- Finish every component in slot order with the completion reason. -/
def finishComponents (reason : CompletionReason) (state : MachineState) :
    MachineResult MachineState :=
  (List.range state.components.size).foldlM (init := state) fun state componentIndex =>
    dispatchComponent componentIndex "finish"
      (fun component => component.behavior.finish component.state reason) state

end Machine
