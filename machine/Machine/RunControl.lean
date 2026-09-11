import Machine.Kernel
/-!
# Run control

The structured run-control interface over the kernel: `createRun` builds a
fresh run instance from an immutable `RunConfiguration`, `step` dispatches
exactly one calendar-dispatch semantic unit, `run` steps to a terminal
status, and `runThrough` processes every scheduled event at or before a
target time and stops before the first event after it.

Every terminal execution path returns one `RunReport` with status, final
time, recorded results, the complete available trace, and diagnostics.
Non-terminal `step` and `runThrough` calls return the live instance and an
`ActiveProgress` value.

The dispatch budget is implementation policy, not Core semantics: exhausting
it aborts the run with `BudgetExceeded`. A host cancellation request is
observed between dispatch transactions and aborts with `Cancelled`. Both
abort paths keep all report data gathered so far.
-/

namespace Machine

/-- The terminal report of one run. -/
structure RunReport : Type where
  status : RunStatus
  finalTime : Time
  /-- Recorded results; `JsonValue.null` unless the run completed. -/
  results : JsonValue
  trace : Array JsonValue
  diagnostics : List Diagnostic

instance : Inhabited RunStatus := ⟨.completed .endTime⟩

instance : Inhabited RunReport :=
  ⟨{ status := default, finalTime := 0.0, results := .null
     trace := #[], diagnostics := [] }⟩

/-- Non-terminal progress returned by `step` and `runThrough`. -/
structure ActiveProgress : Type where
  time : Time
  /-- The next event time a host observes, clamped to the run's end time.
  `none` covers both an empty calendar and a calendar whose least entry lies
  past the end time; in either case the next `step` is terminal. -/
  nextEventTime : Option Time

/-- One mutable run instance created from a prepared configuration. -/
structure RunInstance : Type 1 where
  state : MachineState
  /-- Remaining dispatch budget (implementation policy). -/
  fuel : Nat
  /-- Host cancellation request, observed between dispatch transactions. -/
  cancelRequested : Bool := false

/-- Default dispatch budget for one reference run. -/
def runBudget : Nat := 1000000

/-- The least calendar entry time, clamped to the run's end time. The clamp
is the host seam: an entry past the end time is never dispatched, so it is
not a next event a host can wait for. -/
private def clampedNextEventTime (state : MachineState) : Option Time :=
  match state.peekNextCalendarTime with
  | some time => if state.pastEndTime time then none else some time
  | none => none

private def progressOf (state : MachineState) : ActiveProgress :=
  { time := state.time, nextEventTime := clampedNextEventTime state }

/-- Terminal frames and report for a failed run. -/
def failedReport (diagnostic : Diagnostic) (state : MachineState) : RunReport :=
  let state := state.appendEventEnvelope "kernel" "sim.error" diagnostic.toJson
  { status := .failed diagnostic
    finalTime := state.time
    results := .null
    trace := state.trace
    diagnostics := [diagnostic] }

/-- Terminal frames and report for an aborted run. -/
def abortedReport (reason : AbortReason) (state : MachineState) : RunReport :=
  let state := state.appendEventEnvelope "kernel" "sim.aborted"
    (.obj [("reason", .str reason.render)])
  { status := .aborted reason
    finalTime := state.time
    results := .null
    trace := state.trace
    diagnostics := [] }

/-- Terminal frames and report for a normally completed run: end-time fixup,
`finish` in slot order with the completion reason, recorded results, and the
`sim.completed` frame. A `finish` failure fails the run. -/
def completedReport (reason : CompletionReason) (state : MachineState) : RunReport :=
  let state := {
    state with time := if reason == .endTime then state.duration else state.time }
  match finishComponents reason state with
  | .error (diagnostic, state) => failedReport diagnostic state
  | .ok state =>
    let results := state.recorder.finalize state.time
    let state := state.appendEventEnvelope "kernel" "sim.completed"
      (.obj [("reason", .str reason.render)])
    { status := .completed reason
      finalTime := state.time
      results
      trace := state.trace
      diagnostics := [] }

/-- The result of one run-control call. -/
inductive StepResult : Type 1 where
  | active (runInstance : RunInstance) (progress : ActiveProgress)
  | terminal (report : RunReport)

/-- Create a run instance from prepared input: `sim.started`, `start` in
slot order, due overrides, warmup, interval samples, and round scheduling. A
startup failure returns a terminal report. -/
def createRunPrepared (prepared : PreparedRun) (budget : Nat := runBudget) :
    StepResult :=
  let configuration := prepared.configuration
  let state := (MachineState.fromPreparedRun prepared).appendEventEnvelope
    "kernel" "sim.started"
    (.obj [ ("model", .str configuration.modelName)
          , ("duration", .float configuration.duration)
          , ("seed", .nat configuration.seed.toNat) ])
  let initialized : MachineResult MachineState := do
    let state ← startComponents state
    let state ← applyDueOverrides state
    let state :=
      if configuration.warmup > 0.0 then
        state.scheduleAt configuration.warmup .warmup
      else
        { state with recorder := state.recorder.activate 0.0 state.readState }
    let state := state.recorder.intervalOutputs.foldl (init := state)
      fun state (outputIndex, _) =>
        state.scheduleAt configuration.warmup (.sample outputIndex)
    let state := (List.range configuration.rounds.size).foldl (init := state)
      fun state roundIndex =>
        let round := configuration.rounds[roundIndex]!
        if round.interval.isSome then
          state.scheduleAt round.start (.round roundIndex)
        else state
    pure state
  match initialized with
  | .error (diagnostic, state) => .terminal (failedReport diagnostic state)
  | .ok state => .active { state, fuel := budget } (progressOf state)

/-- Dispatch exactly one calendar-dispatch semantic unit. Observes a pending
host cancellation and the dispatch budget before dispatching. -/
def step (runInstance : RunInstance) : StepResult :=
  if runInstance.cancelRequested then
    .terminal (abortedReport .cancelled runInstance.state)
  else
    match runInstance.fuel with
    | 0 => .terminal (abortedReport .budgetExceeded runInstance.state)
    | fuel + 1 =>
      match stepOnce runInstance.state with
      | .active state => .active { runInstance with state, fuel } (progressOf state)
      | .completed reason state => .terminal (completedReport reason state)
      | .failed diagnostic state => .terminal (failedReport diagnostic state)

/-- Step to a terminal status. Equivalent to repeated `step`. -/
def run (runInstance : RunInstance) : RunReport :=
  go (runInstance.fuel + 1) runInstance
where
  go : Nat → RunInstance → RunReport
    -- Unreachable: `step` aborts at fuel 0 first. The arm is the termination measure.
    | 0, runInstance => abortedReport .budgetExceeded runInstance.state
    | limit + 1, runInstance =>
      match step runInstance with
      | .terminal report => report
      | .active runInstance _ => go limit runInstance

/-- Process every scheduled event at or before `target` and stop before the
first event after it. Inclusive: equal-time events at `target` dispatch. The
kernel owns the run boundary: with no next event inside the run's end time,
`runThrough` hands the calendar to `step`, and `stepOnce` decides whether the
run completes at the end time or at quiescence. -/
def runThrough (runInstance : RunInstance) (target : Time) : StepResult :=
  go (runInstance.fuel + 1) runInstance
where
  go : Nat → RunInstance → StepResult
    -- Unreachable: `step` aborts at fuel 0 first. The arm is the termination measure.
    | 0, runInstance => .terminal (abortedReport .budgetExceeded runInstance.state)
    | limit + 1, runInstance =>
      match clampedNextEventTime runInstance.state with
      | some nextTime =>
        if nextTime ≤ target then
          match step runInstance with
          | .terminal report => .terminal report
          | .active runInstance _ => go limit runInstance
        else
          .active runInstance (progressOf runInstance.state)
      | none => step runInstance

/-- The next scheduled event time of an active run, clamped to the run's end
time. A calendar whose least entry lies past the end time reads as `none`,
the same value quiescence reads as: the run completes at the end time before
reaching that entry, so no host-visible event is still due. A host polling an
active run therefore learns from `none` that the next `step` is terminal, not
which completion reason it will carry. -/
def nextEventTime (runInstance : RunInstance) : Option Time :=
  clampedNextEventTime runInstance.state

/-- Reasons external input is rejected at admission. -/
inductive ExternalInputError where
  | nonFiniteTime
  | timeInPast
  | unknownExternalPort
deriving BEq

def ExternalInputError.message : ExternalInputError → String
  | .nonFiniteTime => "external input time is not finite"
  | .timeInPast => "external input time is in the past"
  | .unknownExternalPort => "external input port is not a validated external port"

/-- Admit one external input deterministically. Admission validates the time
and port, copies the payload into an immutable run-owned transcript record
with the next admission ordinal, and allocates its calendar position through
the same calendar sequence as internal events. Rejected input changes
nothing. -/
def injectExternal (runInstance : RunInstance) (componentIndex : Nat) (port : String)
    (time : Time) (payload : JsonValue) :
    Except ExternalInputError RunInstance :=
  if !time.isFinite then
    .error .nonFiniteTime
  else if time < runInstance.state.time then
    .error .timeInPast
  else if !runInstance.state.externalPorts.contains (componentIndex, port) then
    .error .unknownExternalPort
  else
    let state := runInstance.state
    let ordinal := state.externalTranscript.size
    let record : ExternalInputRecord := { componentIndex, port, payload }
    let state := { state with externalTranscript := state.externalTranscript.push record }
    .ok { runInstance with state := state.scheduleAt time (.external ordinal) }

/-- Request idempotent host cancellation. The request is observed between
dispatch transactions: the next `step` returns `Aborted(Cancelled)` with all
available report data. -/
def cancel (runInstance : RunInstance) : RunInstance :=
  { runInstance with cancelRequested := true }

/-- Run prepared input to its terminal report. -/
def runPreparedReport (prepared : PreparedRun) (budget : Nat := runBudget) : RunReport :=
  match createRunPrepared prepared budget with
  | .terminal report => report
  | .active runInstance _ => run runInstance

/-- Prepare a configuration and create a run instance. Preparation failures
are outside event traces. -/
def createRun (configuration : RunConfiguration) (budget : Nat := runBudget) :
    Except PreparationError StepResult :=
  (prepareRun configuration).map (createRunPrepared · budget)

/-- Prepare and run a configuration to its terminal report. -/
def runReport (configuration : RunConfiguration) (budget : Nat := runBudget) :
    Except PreparationError RunReport :=
  (prepareRun configuration).map (runPreparedReport · budget)

/-- Prepare and run a configuration to its complete trace and results JSON. -/
def runWithResults (configuration : RunConfiguration) :
    Except PreparationError (Array JsonValue × JsonValue) :=
  (runReport configuration).map fun report => (report.trace, report.results)

/-- Prepare and run a configuration to its complete trace. -/
def runTrace (configuration : RunConfiguration) :
    Except PreparationError (Array JsonValue) :=
  (runWithResults configuration).map (·.fst)

end Machine
