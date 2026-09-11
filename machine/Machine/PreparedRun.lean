import Machine.ComponentBehavior
import Machine.Expr
import Machine.Recorder
import Machine.ResolutionRound
/-!
# Prepared runs

Preparation validates and normalizes static run input before machine state
exists. It also builds component-local connection index lists in document
order.
-/

namespace Machine

/-- Inputs required to construct one reference machine run. -/
structure RunConfiguration : Type 1 where
  modelName : String
  componentIds : Array String
  components : Array RuntimeComponent
  connections : Array Connection
  duration : Time
  seed : UInt64
  /-- Resolved numeric model parameters available to prepared values. -/
  parameters : EvaluationScope := []
  overrides : List (UInt64 × String × Float) := []
  runMetadata : JsonValue := .null
  /-- The experiment `stopWhen` expression, checked after every event;
  a nonzero value stops the run, an evaluation error aborts it. -/
  stopWhen : Option Machine.Expr := none
  emitStateEvents : Bool := true
  /-- Recorded outputs (summaries, timeseries, finals). -/
  outputs : List OutputCfg := []
  /-- Warmup boundary; outputs record from here (excluded from results). -/
  warmup : Float := 0.0
  /-- Resolution round configurations. -/
  rounds : Array RoundConfiguration := #[]
  /-- Validated external input ports as `(componentIndex, port)`. External
  input is admitted only through these. -/
  externalPorts : List (Nat × String) := []

instance : Inhabited RunConfiguration :=
  ⟨{ modelName := "", componentIds := #[], components := #[], connections := #[]
     duration := 1.0, seed := 0 }⟩

/-- A configuration error detected before machine state exists. -/
inductive PreparationError where
  | invalidConfiguration (message : String)

def PreparationError.message : PreparationError → String
  | .invalidConfiguration message => message

/-- Validated static data and component-local connection lookups for one run. -/
structure PreparedRun : Type 1 where
  configuration : RunConfiguration
  componentIds : Array String
  components : Array RuntimeComponent
  connections : Array Connection
  outgoing : Array (List Route)
  incoming : Array (List Nat)
  runMetadata : JsonValue

instance : Inhabited PreparedRun :=
  ⟨{ configuration := default, componentIds := #[], components := #[]
     connections := #[], outgoing := #[], incoming := #[], runMetadata := .null }⟩

private def invalid (message : String) : Except PreparationError α :=
  .error (.invalidConfiguration message)

private abbrev ValidationResult := ULift.{1} Unit

private def validateComponentIds :
    List String → List String → Except PreparationError ValidationResult
  | [], _ => .ok ⟨()⟩
  | componentId :: remaining, seen =>
    if seen.contains componentId then
      invalid s!"duplicate component ID \"{componentId}\""
    else
      validateComponentIds remaining (componentId :: seen)

private def validateConnections (componentCount : Nat) :
    Nat → List Connection → Except PreparationError ValidationResult
  | _, [] => .ok ⟨()⟩
  | index, connection :: remaining => do
    if connection.src.fst ≥ componentCount then
      invalid s!"connection {index} source component index {connection.src.fst} is out of range"
    if connection.dst.fst ≥ componentCount then
      invalid s!"connection {index} target component index {connection.dst.fst} is out of range"
    validateConnections componentCount (index + 1) remaining

private def validateExternalPorts (componentCount : Nat) :
    List (Nat × String) → Except PreparationError ValidationResult
  | [] => .ok ⟨()⟩
  | (componentIndex, port) :: remaining => do
    if componentIndex ≥ componentCount then
      invalid s!"external port \"{port}\" component index {componentIndex} is out of range"
    validateExternalPorts componentCount remaining

private def validateOverrides (parameters : EvaluationScope) :
    List (UInt64 × String × Float) → Except PreparationError ValidationResult
  | [] => .ok ⟨()⟩
  | (_, name, _) :: remaining => do
    if (parameters.lookup name).isNone then
      invalid s!"unknown parameter override \"{name}\""
    validateOverrides parameters remaining

private def validSummaryStatistics : List String :=
  [ "mean", "std", "min", "max", "median", "p5", "p25", "p75"
  , "p90", "p95", "p99", "count", "sum", "last" ]

private def validateSummaryStatistics (outputIndex : Nat) :
    List String → Except PreparationError ValidationResult
  | [] => .ok ⟨()⟩
  | statistic :: remaining => do
    if !validSummaryStatistics.contains statistic then
      invalid s!"output {outputIndex} summary statistic \"{statistic}\" is unknown"
    validateSummaryStatistics outputIndex remaining

private def validateOutputKind (outputIndex : Nat) :
    OutputKind → Except PreparationError ValidationResult
  | .timeseries (some interval) =>
    if !interval.isFinite || interval ≤ 0.0 then
      invalid s!"output {outputIndex} timeseries interval must be finite and greater than zero"
    else .ok ⟨()⟩
  | .summary statistics => validateSummaryStatistics outputIndex statistics
  | _ => .ok ⟨()⟩

private def validateOutputs : Nat → List OutputCfg → Except PreparationError ValidationResult
  | _, [] => .ok ⟨()⟩
  | index, output :: remaining => do
    if output.path.isEmpty then
      invalid s!"output {index} path must not be empty"
    if output.name.isEmpty then
      invalid s!"output {index} name must not be empty"
    let _ ← validateOutputKind index output.kind
    validateOutputs (index + 1) remaining

private def validateRoundInterval (roundIndex : Nat) :
    Option Time → Except PreparationError ValidationResult
  | some interval =>
    if !interval.isFinite || interval ≤ 0.0 then
      invalid s!"round {roundIndex} interval must be finite and greater than zero"
    else .ok ⟨()⟩
  | none => .ok ⟨()⟩

private def validateRounds (duration : Time) :
    Nat → List RoundConfiguration → Except PreparationError ValidationResult
  | _, [] => .ok ⟨()⟩
  | index, round :: remaining => do
    if !round.start.isFinite || round.start < 0.0 || round.start > duration then
      invalid s!"round {index} start must be finite and between zero and duration"
    let _ ← validateRoundInterval index round.interval
    validateRounds duration (index + 1) remaining

private def normalizeRunMetadata :
    JsonValue → Except PreparationError (ULift.{1} JsonValue)
  | .null => .ok ⟨.obj []⟩
  | metadata@(.obj _) => .ok ⟨metadata⟩
  | _ => invalid "run metadata must be an object or null"

private def connectionLookups (componentCount : Nat) (connections : Array Connection) :
    Array (List Route) × Array (List Nat) :=
  connections.toList.zipIdx.foldl
    (init := (Array.replicate componentCount ([] : List Route),
      Array.replicate componentCount ([] : List Nat)))
    fun (outgoing, incoming) (connection, index) =>
      let sourceConnections := outgoing[connection.src.fst]!
      let targetConnections := incoming[connection.dst.fst]!
      (outgoing.set! connection.src.fst (sourceConnections ++ [⟨index⟩]),
       incoming.set! connection.dst.fst (targetConnections ++ [index]))

/-- Validate and normalize a raw run configuration. -/
def prepareRun (configuration : RunConfiguration) : Except PreparationError PreparedRun := do
  if configuration.componentIds.size != configuration.components.size then
    invalid "component IDs and components differ in length"
  if !configuration.duration.isFinite || configuration.duration ≤ 0.0 then
    invalid "duration must be finite and greater than zero"
  if !configuration.warmup.isFinite || configuration.warmup < 0.0 ||
      configuration.warmup > configuration.duration then
    invalid "warmup must be between zero and duration"
  let _ ← validateComponentIds configuration.componentIds.toList []
  let _ ← validateConnections configuration.components.size 0 configuration.connections.toList
  let _ ← validateExternalPorts configuration.components.size configuration.externalPorts
  let _ ← validateOverrides configuration.parameters configuration.overrides
  let _ ← validateOutputs 0 configuration.outputs
  let _ ← validateRounds configuration.duration 0 configuration.rounds.toList
  let runMetadata := (← normalizeRunMetadata configuration.runMetadata).down
  let overrides := configuration.overrides.mergeSort fun left right => left.1 ≤ right.1
  let configuration := { configuration with overrides, runMetadata }
  let (outgoing, incoming) :=
    connectionLookups configuration.components.size configuration.connections
  pure
    { configuration
      componentIds := configuration.componentIds
      components := configuration.components
      connections := configuration.connections
      outgoing
      incoming
      runMetadata }

end Machine
