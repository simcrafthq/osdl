import Conformance.Case
/-!
# Core conformance cases

Cases for module `core@0.1.0`: timers, entity transfer, message and value
ports, evaluation scopes, parameter overrides, random streams, stopping,
and terminal errors. Each fixture is followed by its catalogue record;
`core` lists the records in catalogue order.
-/

namespace Machine.ConformanceCases

open Machine

/-! ## timers -/

private def timerComp : RuntimeComponent := RuntimeComponent.pack (σ := Nat)
  { start := fun s => do
      let _ ← ComponentProgram.scheduleAfter 1.0
      let _ ← ComponentProgram.scheduleAfter 1.0   -- same time: insertion seq breaks the tie
      let _ ← ComponentProgram.scheduleAfter 2.5
      pure s
    handle := fun s event =>
      match event with
      | .timerFired timer => do
        let s := s + 1
        ComponentProgram.publishNumber "fired" (Float.ofNat s)
        ComponentProgram.publishNumber "lastTimer" (Float.ofNat timer.value.toNat)
        ComponentProgram.emitEvent "fixture.timerFired"
          (.obj [("timer", .nat timer.value.toNat), ("count", .nat s)])
        pure s
      | _ => pure s }
  0

def timers : RunConfiguration where
  modelName := "timers"
  componentIds := #["t0"]
  components := #[timerComp]
  connections := #[]
  duration := 10.0
  seed := 42
  runMetadata := conformanceCaseMetadata

def timersCase : ConformanceCase where
  id := "timers"
  purpose := "Checks timer ordering for equal and different event times."
  module := "core@0.1.0"
  input := .machine "timers"
  configuration := timers

/-! ## timercancel

Cancellation removes a pending timer; rescheduling gives the moved timer a
new insertion sequence, so an equal-time rescheduled timer dispatches after
timers inserted earlier at that time. Cancelling an already-fired timer is a
no-op. -/

private structure TcSt where
  fired : Nat := 0
  cancelTarget : Option TimerId := none

private def timerCancelComp : RuntimeComponent := RuntimeComponent.pack (σ := TcSt)
  { start := fun s => do
      let first ← ComponentProgram.scheduleAfter 1.0
      let toCancel ← ComponentProgram.scheduleAfter 2.0
      let toMove ← ComponentProgram.scheduleAfter 2.0
      let _last ← ComponentProgram.scheduleAfter 3.0
      -- Cancel one pending timer and move another to the same time as the
      -- last timer: the rescheduled entry gets a new insertion sequence and
      -- dispatches after it.
      ComponentProgram.cancelTimer toCancel
      let _ ← ComponentProgram.rescheduleTimer toMove 3.0
      -- Cancelling the first timer after it fires is a no-op (see handle).
      pure { s with fired := 0, cancelTarget := some first }
    handle := fun s event =>
      match event with
      | .timerFired timer => do
        let s := { s with fired := s.fired + 1 }
        ComponentProgram.publishNumber "fired" (Float.ofNat s.fired)
        ComponentProgram.publishNumber "lastTimer" (Float.ofNat timer.value.toNat)
        match s.cancelTarget with
        | some cancelled => do
          -- Idempotent: this timer already fired or was never pending.
          ComponentProgram.cancelTimer cancelled
          pure { s with cancelTarget := none }
        | none => pure s
      | _ => pure s }
  {}

def timercancel : RunConfiguration where
  modelName := "timercancel"
  componentIds := #["t0"]
  components := #[timerCancelComp]
  connections := #[]
  duration := 10.0
  seed := 42
  runMetadata := conformanceCaseMetadata

def timercancelCase : ConformanceCase where
  id := "timercancel"
  purpose := "Checks timer cancellation, rescheduling, and idempotent cancels."
  module := "core@0.1.0"
  input := .machine "timercancel"
  configuration := timercancel

/-! ## pipeline -/

private def pipeSrc (limit : Nat) : RuntimeComponent := RuntimeComponent.pack (σ := Nat)
  { start := fun _ => do
      let e ← ComponentProgram.createEntity "job"
      let _ ← ComponentProgram.sendUnique "out" e
      pure 1
    handle := fun s event =>
      match event with
      | .sendResult _ .delivered =>
        if s < limit then do
          let e ← ComponentProgram.createEntity "job"
          let _ ← ComponentProgram.sendUnique "out" e
          pure (s + 1)
        else pure s
      | .sendResult _ .blocked =>
        ComponentProgram.failRun "unexpected blocked transfer"
      | _ => pure s }
  0

private def pipeSnk : RuntimeComponent := RuntimeComponent.pack (σ := Nat)
  { start := fun s => pure s
    receive := fun s entity _ => do
      let s := s + 1
      ComponentProgram.publishNumber "count" (Float.ofNat s)
      ComponentProgram.disposeEntity entity
      pure (s, .accept) }
  0

def pipeline : RunConfiguration where
  modelName := "pipeline"
  componentIds := #["src", "snk"]
  components := #[pipeSrc 3, pipeSnk]
  connections := #[⟨(0, "out"), (1, "in")⟩]
  duration := 5.0
  seed := 7
  runMetadata := conformanceCaseMetadata

def pipelineCase : ConformanceCase where
  id := "pipeline"
  purpose := "Checks accepted entity delivery through a source and sink."
  module := "core@0.1.0"
  input := .machine "pipeline"
  configuration := pipeline

/-! ## backpressure

The sender learns `Blocked` once; the exact entity stays in kernel escrow.
When the receiver reports readiness, the kernel redelivers the oldest blocked
transfer and the sender sees `Delivered`. -/

private def bpSrc (limit : Nat) : RuntimeComponent := RuntimeComponent.pack (σ := Nat)
  { start := fun s => do
      let e ← ComponentProgram.createEntity "job"
      let _ ← ComponentProgram.sendUnique "out" e
      pure (s + 1)
    handle := fun s event =>
      match event with
      | .sendResult _ .delivered =>
        if s < limit then do
          let e ← ComponentProgram.createEntity "job"
          let _ ← ComponentProgram.sendUnique "out" e
          pure (s + 1)
        else pure s
      | .sendResult _ .blocked =>
        -- The entity waits in kernel escrow; nothing to do.
        pure s
      | _ => pure s }
  0

private def bpSnk : RuntimeComponent := RuntimeComponent.pack (σ := Bool × Nat)
  { start := fun (_, n) => do
      let _ ← ComponentProgram.scheduleAfter 1.0
      pure (true, n)
    receive := fun (busy, n) entity _ =>
      if busy then do
        ComponentProgram.emitEvent "fixture.blocked"
          (.obj [("entityId", .str entity.name), ("inputPort", .str "in")])
        pure ((busy, n), .block)
      else do
        ComponentProgram.publishNumber "count" (Float.ofNat (n + 1))
        pure ((busy, n + 1), .accept)
    handle := fun (_, n) event =>
      match event with
      | .timerFired _ => do
        ComponentProgram.emitEvent "fixture.ready" (.obj [("inputPort", .str "in")])
        ComponentProgram.reportReady "in"
        pure (false, n)
      | _ => pure (false, n) }
  (false, 0)

def backpressure : RunConfiguration where
  modelName := "backpressure"
  componentIds := #["src", "snk"]
  components := #[bpSrc 2, bpSnk]
  connections := #[⟨(0, "out"), (1, "in")⟩]
  duration := 5.0
  seed := 11
  runMetadata := conformanceCaseMetadata

def backpressureCase : ConformanceCase where
  id := "backpressure"
  purpose := "Checks escrow blocking, readiness, and kernel redelivery."
  module := "core@0.1.0"
  input := .machine "backpressure"
  configuration := backpressure

/-! ## cancelxfer

A transfer blocked in escrow is cancelled by the sender before acceptance:
the receiver's later readiness report finds no blocked transfer and the run
goes quiescent. -/

private def cxSrc : RuntimeComponent := RuntimeComponent.pack (σ := Unit)
  { start := fun s => do
      let e ← ComponentProgram.createEntity "job"
      let _ ← ComponentProgram.sendUnique "out" e
      pure s
    handle := fun s event =>
      match event with
      | .sendResult transfer .blocked => do
        ComponentProgram.cancelTransfer transfer
        ComponentProgram.publishNumber "cancelled" 1.0
        pure s
      | .sendResult _ .delivered =>
        ComponentProgram.failRun "cancelled transfer must not deliver"
      | _ => pure s }
  ()

private def cxSnk : RuntimeComponent := RuntimeComponent.pack (σ := Bool)
  { start := fun _ => do
      let _ ← ComponentProgram.scheduleAfter 1.0
      pure true
    receive := fun busy _ _ =>
      if busy then pure (busy, .block)
      else pure (busy, .accept)
    handle := fun _ event =>
      match event with
      | .timerFired _ => do
        ComponentProgram.reportReady "in"
        pure false
      | _ => pure false }
  false

def cancelxfer : RunConfiguration where
  modelName := "cancelxfer"
  componentIds := #["src", "snk"]
  components := #[cxSrc, cxSnk]
  connections := #[⟨(0, "out"), (1, "in")⟩]
  duration := 5.0
  seed := 11
  runMetadata := conformanceCaseMetadata

def cancelxferCase : ConformanceCase where
  id := "cancelxfer"
  purpose := "Checks pre-acceptance transfer cancellation."
  module := "core@0.1.0"
  input := .machine "cancelxfer"
  configuration := cancelxfer

/-! ## quiesce

An empty calendar before the end time completes the run with reason
`quiescent` at the last event time; it is distinct from `endTime`. -/

private def quiesceComp : RuntimeComponent := RuntimeComponent.pack (σ := Nat)
  { start := fun s => do
      let _ ← ComponentProgram.scheduleAfter 1.0
      pure s
    handle := fun s event =>
      match event with
      | .timerFired _ => do
        let s := s + 1
        ComponentProgram.publishNumber "fired" (Float.ofNat s)
        if s < 2 then
          let _ ← ComponentProgram.scheduleAfter 1.0
          pure s
        else pure s
      | _ => pure s
    finish := fun s reason => do
      ComponentProgram.publishNumber "sawQuiescent"
        (if reason == .quiescent then 1.0 else 0.0)
      pure s }
  0

def quiesce : RunConfiguration where
  modelName := "quiesce"
  componentIds := #["c0"]
  components := #[quiesceComp]
  connections := #[]
  duration := 10.0
  seed := 3
  runMetadata := conformanceCaseMetadata

def quiesceCase : ConformanceCase where
  id := "quiesce"
  purpose := "Checks empty-calendar completion distinct from the end time."
  module := "core@0.1.0"
  input := .machine "quiesce"
  configuration := quiesce

/-! ## msgvalue

Message ports deliver immutable payloads without custody; value ports
deliver typed scalar values as `InputValueChanged` events. -/

private def mvSender : RuntimeComponent := RuntimeComponent.pack (σ := Unit)
  { start := fun s => do
      let _ ← ComponentProgram.scheduleAfter 1.0
      pure s
    handle := fun s event =>
      match event with
      | .timerFired _ => do
        match (← ComponentProgram.routes "notify") with
        | [route] => ComponentProgram.sendMessage route (.obj [("topic", .str "greeting")])
        | _ => ComponentProgram.failRun "expected one notify route"
        ComponentProgram.setOutput "level" (.number 42.5)
        ComponentProgram.setOutput "label" (.string "steady")
        pure s
      | _ => pure s }
  ()

private def mvReceiver : RuntimeComponent := RuntimeComponent.pack (σ := Nat)
  { start := fun s => pure s
    handle := fun s event =>
      match event with
      | .messageReceived port _ => do
        let s := s + 1
        ComponentProgram.publishNumber "messages" (Float.ofNat s)
        ComponentProgram.emitEvent "mv.received" (.obj [("port", .str port)])
        pure s
      | .inputValueChanged _ value => do
        ComponentProgram.publishState "lastValue" value
        pure s
      | _ => pure s }
  0

def msgvalue : RunConfiguration where
  modelName := "msgvalue"
  componentIds := #["a", "b"]
  components := #[mvSender, mvReceiver]
  connections := #[ ⟨(0, "notify"), (1, "inbox")⟩
            , ⟨(0, "level"), (1, "levelIn")⟩
            , ⟨(0, "label"), (1, "labelIn")⟩ ]
  duration := 3.0
  seed := 13
  runMetadata := conformanceCaseMetadata

def msgvalueCase : ConformanceCase where
  id := "msgvalue"
  purpose := "Checks message-port and value-port delivery."
  module := "core@0.1.0"
  input := .machine "msgvalue"
  configuration := msgvalue

/-! ## valuescope -/

private def valueScopeComp : RuntimeComponent := RuntimeComponent.pack (σ := Unit)
  { start := fun s => do
      ComponentProgram.publishNumber "base" 3.0
      let componentId ← ComponentProgram.componentId
      let parameter ← ComponentProgram.evaluate (.parameter "offset")
      let evaluated ← ComponentProgram.evaluate
        (.expression (Expr.parse! "local + offset + v0.base"))
        [("local", 7.0), ("offset", 5.0)]
      let sampled ← ComponentProgram.sample
        (.uniform (.expression (Expr.parse! "local"))
          (.expression (Expr.parse! "local + 1")))
        [("local", 7.0)]
      ComponentProgram.publishNumber "parameter" parameter
      ComponentProgram.publishNumber "evaluated" evaluated
      ComponentProgram.publishNumber "sampled" sampled
      ComponentProgram.emitEvent "value.scope"
        (.obj [ ("componentId", .str componentId), ("parameter", .float parameter)
              , ("evaluated", .float evaluated), ("sampled", .float sampled) ])
      pure s }
  ()

def valuescope : RunConfiguration where
  modelName := "valuescope"
  componentIds := #["v0"]
  components := #[valueScopeComp]
  connections := #[]
  duration := 1.0
  seed := 17
  parameters := [("offset", 2.0)]
  runMetadata := conformanceCaseMetadata

def valuescopeCase : ConformanceCase where
  id := "valuescope"
  purpose := "Checks parameter, state, local expression, and sampling scopes."
  module := "core@0.1.0"
  input := .machine "valuescope"
  configuration := valuescope

/-! ## paramoverride -/

private def parameterOverrideComp : RuntimeComponent := RuntimeComponent.pack (σ := Unit)
  { start := fun s => do
      let _ ← ComponentProgram.scheduleAfter 1.0
      pure s
    handle := fun s event =>
      match event with
      | .timerFired _ => do
        let offset ← ComponentProgram.evaluate (.parameter "offset")
        let value := offset + 1.0
        ComponentProgram.publishNumber "value" value
        ComponentProgram.emitEvent "param.value" (.obj [("value", .float value)])
        let _ ← ComponentProgram.scheduleAfter 1.0
        pure s
      | _ => pure s }
  ()

/-- `afterSeq = 6` applies after the timer dispatch at time 3.0 and before
the timer dispatch at time 4.0. -/
def paramoverride : RunConfiguration where
  modelName := "paramoverride"
  componentIds := #["v0"]
  components := #[parameterOverrideComp]
  connections := #[]
  duration := 4.0
  seed := 17
  parameters := [("offset", 2.0)]
  overrides := [(6, "offset", 5.0)]
  runMetadata := conformanceCaseMetadata

def paramoverrideCase : ConformanceCase where
  id := "paramoverride"
  purpose := "Checks one run-time parameter override at a dispatch boundary."
  module := "core@0.1.0"
  input := .machine "paramoverride"
  configuration := paramoverride

/-! ## paramoverridecascade -/

/-- The dispatch boundary lands on sequence 7. Applying the first override
emits sequence 8, which makes the second override due at the same boundary. -/
def paramoverridecascade : RunConfiguration where
  modelName := "paramoverridecascade"
  componentIds := #["v0"]
  components := #[parameterOverrideComp]
  connections := #[]
  duration := 4.0
  seed := 17
  parameters := [("bonus", 2.0), ("offset", 2.0)]
  overrides := [(7, "offset", 5.0), (8, "bonus", 9.0)]
  runMetadata := conformanceCaseMetadata

def paramoverridecascadeCase : ConformanceCase where
  id := "paramoverridecascade"
  purpose := "Checks cascading parameter overrides at one dispatch boundary."
  module := "core@0.1.0"
  input := .machine "paramoverridecascade"
  configuration := paramoverridecascade

/-! ## rngpair -/

private def draw53 (x : UInt64) : Float :=
  -- top 53 bits: exactly representable in binary64
  Float.ofNat (x >>> 11).toNat

private def rngComp : RuntimeComponent := RuntimeComponent.pack (σ := Unit)
  { start := fun s => do
      let x1 ← ComponentProgram.randomBits
      let x2 ← ComponentProgram.randomBits
      let x3 ← ComponentProgram.randomBits
      let x4 ← ComponentProgram.randomBits
      ComponentProgram.publishNumber "d1" (draw53 x1)
      ComponentProgram.publishNumber "d2" (draw53 x2)
      ComponentProgram.publishNumber "d3" (draw53 x3)
      ComponentProgram.publishNumber "d4" (draw53 x4)
      ComponentProgram.emitEvent "machine.draws"
        (.obj [ ("draws", .arr [ .str (toString x1), .str (toString x2)
                               , .str (toString x3), .str (toString x4) ]) ])
      pure s }
  ()

def rngpair : RunConfiguration where
  modelName := "rngpair"
  componentIds := #["a", "b"]
  components := #[rngComp, rngComp]
  connections := #[]
  duration := 1.0
  seed := 20260702
  runMetadata := conformanceCaseMetadata

def rngpairCase : ConformanceCase where
  id := "rngpair"
  purpose := "Checks deterministic random streams for two components."
  module := "core@0.1.0"
  input := .machine "rngpair"
  configuration := rngpair

/-! ## stopper -/

private def stopComp : RuntimeComponent := RuntimeComponent.pack (σ := Unit)
  { start := fun s => do
      let _ ← ComponentProgram.scheduleAfter 3.0
      pure s
    handle := fun s event =>
      match event with
      | .timerFired _ => do
        ComponentProgram.stopRun
        pure s
      | _ => pure s }
  ()

def stopper : RunConfiguration where
  modelName := "stopper"
  componentIds := #["c0"]
  components := #[stopComp]
  connections := #[]
  duration := 10.0
  seed := 1
  runMetadata := conformanceCaseMetadata

def stopperCase : ConformanceCase where
  id := "stopper"
  purpose := "Checks a component-requested stop."
  module := "core@0.1.0"
  input := .machine "stopper"
  configuration := stopper

/-! ## threshold -/

private def countComp : RuntimeComponent := RuntimeComponent.pack (σ := Nat)
  { start := fun s => do
      let _ ← ComponentProgram.scheduleAfter 1.0
      pure s
    handle := fun s event =>
      match event with
      | .timerFired _ => do
        let s := s + 1
        ComponentProgram.publishNumber "count" (Float.ofNat s)
        let _ ← ComponentProgram.scheduleAfter 1.0
        pure s
      | _ => pure s
    finish := fun s _ => do
      ComponentProgram.publishNumber "done" 1.0
      pure s }
  0

def threshold : RunConfiguration where
  modelName := "threshold"
  componentIds := #["c0"]
  components := #[countComp]
  connections := #[]
  duration := 10.0
  seed := 3
  runMetadata := conformanceCaseMetadata
  stopWhen := some (Expr.parse! "c0.count >= 3")

def thresholdCase : ConformanceCase where
  id := "threshold"
  purpose := "Checks expression-based stopping after a state change."
  module := "core@0.1.0"
  input := .machine "threshold"
  configuration := threshold

/-! ## exprerr -/

private def zeroComp : RuntimeComponent := RuntimeComponent.pack (σ := Unit)
  { start := fun s => do
      ComponentProgram.publishNumber "zero" 0.0
      let _ ← ComponentProgram.scheduleAfter 1.0
      pure s }
  ()

def exprerr : RunConfiguration where
  modelName := "exprerr"
  componentIds := #["c0"]
  components := #[zeroComp]
  connections := #[]
  duration := 5.0
  seed := 13
  runMetadata := conformanceCaseMetadata
  stopWhen := some (Expr.parse! "1 / c0.zero")

def exprerrCase : ConformanceCase where
  id := "exprerr"
  purpose := "Checks expression failure during stop-condition evaluation."
  module := "core@0.1.0"
  input := .machine "exprerr"
  configuration := exprerr

/-! ## errsend -/

private def errComp : RuntimeComponent := RuntimeComponent.pack (σ := Unit)
  { start := fun s => do
      let e ← ComponentProgram.createEntity "job"
      let _ ← ComponentProgram.sendUnique "out" e   -- no route: component failure → sim.error
      pure s }
  () (componentType := "test.err")

def errsend : RunConfiguration where
  modelName := "errsend"
  componentIds := #["e0"]
  components := #[errComp]
  connections := #[]
  duration := 5.0
  seed := 9
  runMetadata := conformanceCaseMetadata

def errsendCase : ConformanceCase where
  id := "errsend"
  purpose := "Checks the terminal error for a send without a route."
  module := "core@0.1.0"
  input := .machine "errsend"
  configuration := errsend

/-! ## componenterr -/

private def componentErrorComp : RuntimeComponent :=
  RuntimeComponent.pack (σ := Unit)
    { start := fun _ => ComponentProgram.failRun "component failed" }
    () (componentType := "test.component_err")

def componenterr : RunConfiguration where
  modelName := "componenterr"
  componentIds := #["e0"]
  components := #[componentErrorComp]
  connections := #[]
  duration := 1.0
  seed := 19
  runMetadata := conformanceCaseMetadata

def componenterrCase : ConformanceCase where
  id := "componenterr"
  purpose := "Checks a component-raised terminal error."
  module := "core@0.1.0"
  input := .machine "componenterr"
  configuration := componenterr

/-- The core-module conformance cases in catalogue order. -/
def core : List ConformanceCase :=
  [ timersCase, timercancelCase, pipelineCase, backpressureCase, cancelxferCase
  , quiesceCase, msgvalueCase, valuescopeCase, paramoverrideCase
  , paramoverridecascadeCase, rngpairCase, stopperCase, thresholdCase
  , exprerrCase, errsendCase, componenterrCase ]

end Machine.ConformanceCases
