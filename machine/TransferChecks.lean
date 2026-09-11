import Conformance
import TraceQueries
/-!
# Transfer custody checks

Machine-side checks for the escrow transfer protocol: accepted delivery
order, blocked escrow with a single sender notification, readiness
redelivery order, pre-acceptance cancellation, and structured entity
identity through custody. Usage: `lake exe transfercheck`; exits nonzero on
any failure.
-/

open Machine
open Machine.TraceQueries

private structure CheckState where
  failures : Nat := 0

private def check (state : CheckState) (name : String) (ok : Bool) : IO CheckState := do
  if ok then
    pure state
  else do
    IO.eprintln s!"transfer check failed: {name}"
    pure { state with failures := state.failures + 1 }

private def reportFor (configuration : RunConfiguration) : IO RunReport := do
  match Machine.runReport configuration with
  | .ok report => pure report
  | .error error => throw (IO.userError s!"preparation failed: {error.message}")

/-- The identity fields of an entity as a payload object. `created` uses the
exact bit pattern so equality is bitwise, not printed-decimal. -/
private def identityJson (entity : Entity) : JsonValue :=
  .obj [ ("entityId", .str entity.name)
       , ("uid", .nat entity.uid.toNat)
       , ("entityType", .str entity.entityType)
       , ("agent", match entity.agent with
           | some agent => .nat agent.toNat
           | none => .null)
       , ("created", .str (toString entity.created.toBits)) ]

/-- A sender that sends one entity at start, records its identity, and
records outcomes. -/
private def oneShotSender : RuntimeComponent := RuntimeComponent.pack (σ := Unit)
  { start := fun s => do
      let e ← ComponentProgram.createEntity "probe"
      ComponentProgram.emitEvent "check.sent" (identityJson e)
      let _ ← ComponentProgram.sendUnique "out" e
      pure s
    handle := fun s event =>
      match event with
      | .sendResult _ .delivered => do
        ComponentProgram.emitEvent "check.delivered" .null
        pure s
      | .sendResult _ .blocked => do
        ComponentProgram.emitEvent "check.blocked" .null
        pure s
      | _ => pure s }
  ()

/-- A receiver that accepts immediately and echoes the entity identity. -/
private def acceptingReceiver : RuntimeComponent := RuntimeComponent.pack (σ := Unit)
  { start := fun s => pure s
    receive := fun s entity _ => do
      ComponentProgram.emitEvent "check.received" (identityJson entity)
      pure (s, .accept) }
  ()

/-- A receiver that blocks until its timer, then reports readiness and echoes
the entity identity on acceptance. -/
private def gatedReceiver (gate : Time) : RuntimeComponent :=
  RuntimeComponent.pack (σ := Bool)
    { start := fun _ => do
        let _ ← ComponentProgram.scheduleAfter gate
        pure true
      receive := fun busy entity _ =>
        if busy then pure (busy, .block)
        else do
          ComponentProgram.emitEvent "check.received" (identityJson entity)
          pure (busy, .accept)
      handle := fun _ event =>
        match event with
        | .timerFired _ => do
          ComponentProgram.reportReady "in"
          pure false
        | _ => pure false }
    true

/-- A sender that cancels its transfer as soon as it blocks. -/
private def cancellingSender : RuntimeComponent := RuntimeComponent.pack (σ := Unit)
  { start := fun s => do
      let e ← ComponentProgram.createEntity "probe"
      let _ ← ComponentProgram.sendUnique "out" e
      pure s
    handle := fun s event =>
      match event with
      | .sendResult transfer .blocked => do
        ComponentProgram.cancelTransfer transfer
        ComponentProgram.emitEvent "check.cancelled" .null
        pure s
      | .sendResult _ .delivered =>
        ComponentProgram.failRun "cancelled transfer must not deliver"
      | _ => pure s }
  ()

private def pair (sender receiver : RuntimeComponent) : RunConfiguration :=
  { modelName := "transfercheck"
    componentIds := #["snd", "rcv"]
    components := #[sender, receiver]
    connections := #[⟨(0, "out"), (1, "in")⟩]
    duration := 10.0
    seed := 5 }

/-- Whether the sent identity survives custody: exactly one `check.sent` and
one `check.received`, with equal identity payloads, and the `entity.moved`
envelope names the same entity. -/
private def identityPreserved (trace : Array JsonValue) : Bool :=
  match eventsOfType trace "check.sent", eventsOfType trace "check.received" with
  | [sent], [received] =>
    sent.render == received.render &&
      ((eventsOfType trace "entity.moved").head?.bind (stringField · "entityId")
        == stringField sent "entityId")
  | _, _ => false

def main : IO UInt32 := do
  let mut state : CheckState := {}

  -- Accepted delivery: receive on the destination, then `entity.moved`, then
  -- the sender's Delivered result, each exactly once, identity intact.
  let report ← reportFor (pair oneShotSender acceptingReceiver)
  state ← check state "accepted delivery follows receive, moved, delivered"
    (eventTypeOrder report.trace ["check.received", "entity.moved", "check.delivered"]
      == ["check.received", "entity.moved", "check.delivered"])
  state ← check state "accepted delivery preserves entity identity"
    (identityPreserved report.trace)
  state ← check state "accepted delivery run completes"
    (match report.status with
     | .completed _ => true
     | _ => false)

  -- Blocked escrow: Blocked notifies once, before anything else; after
  -- readiness the redelivery is received, moved, and reported Delivered,
  -- each exactly once, with the escrowed entity's identity intact.
  let report ← reportFor (pair oneShotSender (gatedReceiver 1.0))
  state ← check state "blocked then redelivered follows blocked, receive, moved, delivered"
    (eventTypeOrder report.trace
      ["check.blocked", "check.received", "entity.moved", "check.delivered"]
      == ["check.blocked", "check.received", "entity.moved", "check.delivered"])
  state ← check state "redelivery preserves entity identity through escrow"
    (identityPreserved report.trace)
  state ← check state "redelivery run completes"
    (match report.status with
     | .completed _ => true
     | _ => false)

  -- Pre-acceptance cancellation: no movement, no delivery.
  let report ← reportFor (pair cancellingSender (gatedReceiver 1.0))
  state ← check state "cancelled transfer is recorded"
    (countEvents report.trace "check.cancelled" == 1)
  state ← check state "cancelled transfer never moves"
    (countEvents report.trace "entity.moved" == 0)
  state ← check state "cancelled transfer never delivers"
    (countEvents report.trace "check.delivered" == 0)
  state ← check state "cancellation run completes"
    (match report.status with
     | .completed _ => true
     | _ => false)

  if state.failures == 0 then
    IO.println "transfer checks: ok"
    pure 0
  else
    IO.eprintln s!"transfer checks: {state.failures} failed"
    pure 1
