import Machine.Time
import Machine.Rng
import Machine.Samplers
import Machine.GoldenVectors
import Machine.Types
import Machine.Transfer
import Machine.Expr
import Machine.PreparedValue
import Machine.ComponentOperation
import Machine.ComponentBehavior
import Machine.Recorder
import Machine.ResolutionRound
import Machine.PreparedRun
import Machine.MachineState
import Machine.Kernel
import Machine.RunControl
import Machine.Des
/-!
# The Lean reference machine

An executable model of OSDL runtime semantics: machine state, semantic
operations available to component behavior, and transitions. Within its stated
coverage, this machine defines runtime behavior.

The portable conformance cases and executable live in the separate
`Conformance` target. Reading order: `Time` → `Rng` → `Samplers` → `Types` →
`Transfer` → `Expr` → `PreparedValue` → `ComponentOperation` → `ComponentBehavior` →
`Recorder` → `ResolutionRound` → `PreparedRun` → `MachineState` → `Kernel` →
`RunControl`.
See `README.md` for the module map and coverage boundary.
-/
