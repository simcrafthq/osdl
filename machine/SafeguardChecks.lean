import Machine
import TraceQueries
/-!
# Execution safeguard checks

The dispatch budget is implementation policy, not Core semantics. Exhausting
it aborts the run with `Aborted(BudgetExceeded)` and a terminal `sim.aborted`
frame; it is never a semantic failure and never a normal completion.
-/

open Machine

private def busyComponent : RuntimeComponent := RuntimeComponent.pack (σ := Unit)
  { start := fun s => do
      let _ ← ComponentProgram.scheduleAfter 1.0
      pure s
    handle := fun s event => do
      match event with
      | .timerFired _ =>
        let _ ← ComponentProgram.scheduleAfter 1.0
        pure s
      | _ => pure s }
  ()

private def busyConfiguration : RunConfiguration where
  modelName := "safeguard"
  componentIds := #["c0"]
  components := #[busyComponent]
  connections := #[]
  duration := 1.0e12
  seed := 1

def main : IO UInt32 := do
  let report ← match Machine.runReport busyConfiguration (budget := 5) with
    | .ok report => pure report
    | .error error =>
      IO.eprintln s!"safeguard configuration failed preparation: {error.message}"
      return 1
  match report.status with
  | .aborted .budgetExceeded =>
    match report.trace.back? with
    | some frame =>
      if Machine.TraceQueries.hasType frame "sim.aborted" then
        IO.println "dispatch-budget safeguard: ok"
        pure 0
      else
        IO.eprintln "dispatch-budget abort did not terminate the trace with sim.aborted"
        pure 1
    | none =>
      IO.eprintln "dispatch-budget abort produced an empty trace"
      pure 1
  | _ =>
    IO.eprintln "dispatch-budget exhaustion did not abort with BudgetExceeded"
    pure 1
