import Conformance
import TraceQueries
/-!
# Run-control checks

Machine-side checks for the structured run-control interface: step-to-run
equivalence, inclusive `runThrough` boundaries, the end-time clamp on
`nextEventTime`, deterministic external-input admission and rejection, and
host cancellation.
Usage: `lake exe runcontrolcheck`; exits nonzero on any failure.
-/

open Machine
open Machine.TraceQueries

private def renderTrace (trace : Array JsonValue) : List String :=
  trace.toList.map (·.render)

private structure CheckState where
  failures : Nat := 0

private def check (state : CheckState) (name : String) (ok : Bool) : IO CheckState := do
  if ok then
    pure state
  else do
    IO.eprintln s!"run-control check failed: {name}"
    pure { state with failures := state.failures + 1 }

/-- Step an active run to its terminal report one dispatch at a time. -/
private partial def stepToEnd : StepResult → RunReport
  | .terminal report => report
  | .active runInstance _ => stepToEnd (step runInstance)

/-- A component that publishes external payload observations. -/
private def externalComp : RuntimeComponent := RuntimeComponent.pack (σ := Nat)
  { start := fun s => do
      let _ ← ComponentProgram.scheduleAfter 1.0
      pure s
    handle := fun s event =>
      match event with
      | .timerFired _ => do
        ComponentProgram.publishNumber "ticks" 1.0
        -- Keep the calendar occupied so runThrough can stop while active.
        if s < 3 then
          let _ ← ComponentProgram.scheduleAfter 1.0
          pure s
        else pure s
      | .externalInput port _ => do
        let s := s + 1
        ComponentProgram.publishNumber "externals" (Float.ofNat s)
        ComponentProgram.emitEvent "external.seen" (.obj [("port", .str port)])
        pure s
      | _ => pure s }
  0

/-- A component whose timer reschedules past the run duration. -/
private def pastDurationComp : RuntimeComponent := RuntimeComponent.pack (σ := Unit)
  { start := fun s => do
      let _ ← ComponentProgram.scheduleAfter 1.0
      pure s
    handle := fun s event =>
      match event with
      | .timerFired _ => do
        let _ ← ComponentProgram.scheduleAfter 100.0
        pure s
      | _ => pure s }
  ()

private def prep! (configuration : RunConfiguration) : PreparedRun :=
  match prepareRun configuration with
  | .ok prepared => prepared
  | .error _ => panic! "check configuration failed preparation"

private def pastDurationConfiguration : RunConfiguration where
  modelName := "pastduration"
  componentIds := #["p0"]
  components := #[pastDurationComp]
  connections := #[]
  duration := 5.0
  seed := 3

private def externalConfiguration : RunConfiguration where
  modelName := "externalinput"
  componentIds := #["x0"]
  components := #[externalComp]
  connections := #[]
  duration := 5.0
  seed := 2
  externalPorts := [(0, "command")]

def main : IO UInt32 := do
  let mut state : CheckState := {}

  -- Step equivalence: stepping to the end equals run.
  let viaRun := runPreparedReport (prep! ConformanceCases.threshold)
  let viaStep := stepToEnd (createRunPrepared (prep! ConformanceCases.threshold))
  state ← check state "step equivalence: status"
    (viaRun.status.render == viaStep.status.render)
  state ← check state "step equivalence: trace"
    (renderTrace viaRun.trace == renderTrace viaStep.trace)
  state ← check state "step equivalence: results"
    (viaRun.results.render == viaStep.results.render)

  -- runThrough boundaries on the timers case (events at 1.0, 1.0, and 2.5).
  match createRunPrepared (prep! ConformanceCases.timers) with
  | .terminal _ => state ← check state "timers createRun is active" false
  | .active runInstance _ =>
    state ← check state "nextEventTime before any dispatch"
      (nextEventTime runInstance == some 1.0)
    match runThrough runInstance 1.0 with
    | .terminal _ => state ← check state "runThrough 1.0 stays active" false
    | .active runInstance progress =>
      state ← check state "runThrough 1.0 processes both equal-time events"
        (progress.time == 1.0 && progress.nextEventTime == some 2.5)
      match runThrough runInstance 2.4 with
      | .terminal _ => state ← check state "runThrough 2.4 stays active" false
      | .active runInstance progress =>
        state ← check state "runThrough 2.4 dispatches nothing"
          (progress.time == 1.0 && progress.nextEventTime == some 2.5)
        -- Inclusive advancement through the last event goes quiescent.
        match runThrough runInstance 2.5 with
        | .terminal report =>
          state ← check state "runThrough 2.5 completes quiescent"
            (match report.status with
             | .completed .quiescent => true
             | _ => false)
        | .active _ _ => state ← check state "runThrough 2.5 terminates" false

  -- nextEventTime clamps to the run's end time: the entry at 101.0 lies past
  -- the duration of 5.0, so an active run reads as having no next event and
  -- the next step completes at the end time.
  match createRunPrepared (prep! pastDurationConfiguration) with
  | .terminal _ => state ← check state "past-duration createRun is active" false
  | .active runInstance _ =>
    state ← check state "nextEventTime before the past-duration reschedule"
      (nextEventTime runInstance == some 1.0)
    match step runInstance with
    | .terminal _ => state ← check state "past-duration first step stays active" false
    | .active runInstance progress =>
      state ← check state "nextEventTime clamps a past-duration entry to none"
        (progress.time == 1.0 && progress.nextEventTime == none
          && nextEventTime runInstance == none)
      match step runInstance with
      | .active _ _ =>
        state ← check state "past-duration step after the clamp is terminal" false
      | .terminal report =>
        state ← check state "clamped next event completes at the end time"
          (match report.status with
           | .completed .endTime => report.finalTime == 5.0
           | _ => false)

  -- External input: admission, equal-time ordering after internal events,
  -- and rejection paths.
  match createRunPrepared (prep! externalConfiguration) with
  | .terminal _ => state ← check state "external createRun is active" false
  | .active runInstance _ =>
    state ← check state "reject non-finite time"
      (match injectExternal runInstance 0 "command" (1.0 / 0.0) .null with
       | .error .nonFiniteTime => true
       | _ => false)
    state ← check state "reject unknown external port"
      (match injectExternal runInstance 0 "mystery" 1.0 .null with
       | .error .unknownExternalPort => true
       | _ => false)
    match injectExternal runInstance 0 "command" 1.0 (.obj [("go", .bool true)]) with
    | .error _ =>
      state ← check state "admit external input at the timer time" false
    | .ok runInstance =>
      let report := run runInstance
      state ← check state "external run completes"
        (match report.status with
         | .completed _ => true
         | _ => false)
      -- The internal timer at 1.0 was scheduled first and dispatches first;
      -- the external input dispatches after it at the same time.
      let ticksIndex := report.trace.findIdx? fun envelope =>
        hasType envelope "state.changed" &&
          (envelopePayload envelope |>.bind (stringField · "path")) == some "x0.ticks"
      let externalIndex := firstIndexOfType? report.trace "external.seen"
      state ← check state "equal-time external input dispatches after the internal timer"
        (match ticksIndex, externalIndex with
         | some t, some e => t < e
         | _, _ => false)

  -- Rejection of past times after the clock advanced.
  match createRunPrepared (prep! externalConfiguration) with
  | .terminal _ => state ← check state "external createRun is active (past)" false
  | .active runInstance _ =>
    match runThrough runInstance 1.0 with
    | .terminal _ => state ← check state "advance to 1.0 stays active" false
    | .active runInstance _ =>
      state ← check state "reject external input in the past"
        (match injectExternal runInstance 0 "command" 0.5 .null with
         | .error .timeInPast => true
         | _ => false)

  -- Host cancellation between dispatch transactions.
  match createRunPrepared (prep! ConformanceCases.timers) with
  | .terminal _ => state ← check state "cancel createRun is active" false
  | .active runInstance _ =>
    let report := stepToEnd (step (cancel runInstance))
    state ← check state "cancellation aborts with Cancelled"
      (match report.status with
       | .aborted .cancelled => true
       | _ => false)
    state ← check state "cancellation trace terminates with sim.aborted"
      (match report.trace.back? with
       | some frame => hasType frame "sim.aborted"
       | none => false)

  if state.failures == 0 then
    IO.println "run-control checks: ok"
    pure 0
  else
    IO.eprintln s!"run-control checks: {state.failures} failed"
    pure 1
