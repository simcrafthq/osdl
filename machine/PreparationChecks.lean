import Conformance
/-!
# Prepared-run checks

Checks validation order, normalization, stable override ordering, prepared
connection lookups, and focused valid configurations. Usage:
`lake exe preparationcheck`.
-/

open Machine

private def baseConfiguration : RunConfiguration where
  modelName := "preparation"
  componentIds := #[]
  components := #[]
  connections := #[]
  duration := 10.0
  seed := 1

private def component : RuntimeComponent := default

private def allStatistics : List String :=
  [ "mean", "std", "min", "max", "median", "p5", "p25", "p75"
  , "p90", "p95", "p99", "count", "sum", "last" ]

private def output (path name : String) (kind : OutputKind) : OutputCfg :=
  { path, name, kind }

private def round (start : Float) (interval : Option Float) : RoundConfiguration :=
  { roundId := "round", participants := #[], start, interval }

private def errorIs (expected : String) (configuration : RunConfiguration) : Bool :=
  match prepareRun configuration with
  | .error error => error.message == expected
  | .ok _ => false

private def prepares (configuration : RunConfiguration) : Bool :=
  match prepareRun configuration with
  | .ok _ => true
  | .error _ => false

private def normalizedNullMetadata : Bool :=
  match prepareRun baseConfiguration with
  | .ok prepared =>
    prepared.runMetadata.render == "{}" &&
      prepared.configuration.runMetadata.render == "{}"
  | .error _ => false

private def preservesObjectMetadata : Bool :=
  let metadata := JsonValue.obj [("replication", .nat 2), ("label", .str "x")]
  match prepareRun { baseConfiguration with runMetadata := metadata } with
  | .ok prepared =>
    prepared.runMetadata.render == metadata.render &&
      prepared.configuration.runMetadata.render == metadata.render
  | .error _ => false

private def boundaryConfiguration : RunConfiguration :=
  { baseConfiguration with
    componentIds := #["a", "b", "c"]
    components := #[component, component, component]
    connections := #[⟨(0, "alpha"), (2, "in")⟩]
    parameters := [("rate", 1.0)]
    overrides := [(0, "rate", 2.0)]
    runMetadata := .obj [("case", .str "boundary")]
    outputs :=
      [ output "a.value" "series" (.timeseries (some 1.0))
      , output "a.value" "summary" (.summary allStatistics) ]
    warmup := 10.0
    rounds := #[round 0.0 (some 1.0), round 10.0 none] }

private def stableOverrides : Bool :=
  let configuration :=
    { baseConfiguration with
      parameters := [("first", 0.0), ("second", 0.0), ("third", 0.0)]
      overrides := [(2, "first", 1.0), (1, "second", 2.0), (1, "third", 3.0)] }
  match prepareRun configuration with
  | .ok prepared =>
    prepared.configuration.overrides ==
      [(1, "second", 2.0), (1, "third", 3.0), (2, "first", 1.0)]
  | .error _ => false

private def connectionConfiguration : RunConfiguration :=
  { baseConfiguration with
    componentIds := #["a", "b", "c"]
    components := #[component, component, component]
    connections :=
      #[ ⟨(0, "x"), (2, "in")⟩
       , ⟨(1, "out"), (0, "y")⟩
       , ⟨(0, "x"), (0, "y")⟩
       , ⟨(0, "z"), (0, "other")⟩ ] }

private def preparedConnectionOrder : Bool :=
  match prepareRun connectionConfiguration with
  | .error _ => false
  | .ok prepared =>
    prepared.outgoing.size == 3 && prepared.incoming.size == 3 &&
      (prepared.outgoing[0]!).map (·.index) == [0, 2, 3] &&
      (prepared.outgoing[1]!).map (·.index) == [1] &&
      (prepared.outgoing[2]!).map (·.index) == [] &&
      prepared.incoming[0]! == [1, 2, 3] &&
      prepared.incoming[1]! == [] && prepared.incoming[2]! == [0]

private def stateConnectionPortFilter : Bool :=
  match prepareRun connectionConfiguration with
  | .error _ => false
  | .ok prepared =>
    let state := MachineState.fromPreparedRun prepared
    let outgoing := (state.outgoingConnectionsOf 0 "x").map (·.index)
    outgoing == [0, 2] && state.incomingConnectionsOf 0 "y" == [1, 2]

private def preparedOverrideAppliesWithoutLookup : Bool :=
  match prepareRun baseConfiguration with
  | .error _ => false
  | .ok prepared =>
    let configuration :=
      { prepared.configuration with overrides := [(0, "late", 9.0)] }
    let state := MachineState.fromPreparedRun { prepared with configuration }
    match applyDueOverrides state with
    | .error _ => false
    | .ok state =>
      state.parameterOverrides.lookup "late" == some 9.0 &&
        state.pendingOverrides.isEmpty

private def errorChecks : List (String × Bool) :=
  [ ("component alignment", errorIs
      "component IDs and components differ in length"
      { baseConfiguration with componentIds := #["a"] })
  , ("zero duration", errorIs
      "duration must be finite and greater than zero"
      { baseConfiguration with duration := 0.0 })
  , ("negative duration", errorIs
      "duration must be finite and greater than zero"
      { baseConfiguration with duration := -1.0 })
  , ("infinite duration", errorIs
      "duration must be finite and greater than zero"
      { baseConfiguration with duration := 1.0 / 0.0 })
  , ("NaN duration", errorIs
      "duration must be finite and greater than zero"
      { baseConfiguration with duration := 0.0 / 0.0 })
  , ("warmup above duration", errorIs
      "warmup must be between zero and duration"
      { baseConfiguration with warmup := 11.0 })
  , ("negative warmup", errorIs
      "warmup must be between zero and duration"
      { baseConfiguration with warmup := -1.0 })
  , ("infinite warmup", errorIs
      "warmup must be between zero and duration"
      { baseConfiguration with warmup := 1.0 / 0.0 })
  , ("NaN warmup", errorIs
      "warmup must be between zero and duration"
      { baseConfiguration with warmup := 0.0 / 0.0 })
  , ("duplicate component ID", errorIs
      "duplicate component ID \"a\""
      { baseConfiguration with
        componentIds := #["a", "a"]
        components := #[component, component] })
  , ("connection source", errorIs
      "connection 0 source component index 2 is out of range"
      { baseConfiguration with
        componentIds := #["a"]
        components := #[component]
        connections := #[⟨(2, "out"), (0, "in")⟩] })
  , ("connection target", errorIs
      "connection 0 target component index 2 is out of range"
      { baseConfiguration with
        componentIds := #["a"]
        components := #[component]
        connections := #[⟨(0, "out"), (2, "in")⟩] })
  , ("unknown override parameter", errorIs
      "unknown parameter override \"missing\""
      { baseConfiguration with overrides := [(0, "missing", 1.0)] })
  , ("empty output path", errorIs
      "output 0 path must not be empty"
      { baseConfiguration with outputs := [output "" "result" .final] })
  , ("empty output name", errorIs
      "output 0 name must not be empty"
      { baseConfiguration with outputs := [output "a.value" "" .final] })
  , ("zero output interval", errorIs
      "output 0 timeseries interval must be finite and greater than zero"
      { baseConfiguration with
        outputs := [output "a.value" "series" (.timeseries (some 0.0))] })
  , ("negative output interval", errorIs
      "output 0 timeseries interval must be finite and greater than zero"
      { baseConfiguration with
        outputs := [output "a.value" "series" (.timeseries (some (-1.0)))] })
  , ("infinite output interval", errorIs
      "output 0 timeseries interval must be finite and greater than zero"
      { baseConfiguration with
        outputs := [output "a.value" "series" (.timeseries (some (1.0 / 0.0)))] })
  , ("NaN output interval", errorIs
      "output 0 timeseries interval must be finite and greater than zero"
      { baseConfiguration with
        outputs := [output "a.value" "series" (.timeseries (some (0.0 / 0.0)))] })
  , ("unknown summary statistic", errorIs
      "output 0 summary statistic \"average\" is unknown"
      { baseConfiguration with
        outputs := [output "a.value" "summary" (.summary ["mean", "average"])] })
  , ("negative round start", errorIs
      "round 0 start must be finite and between zero and duration"
      { baseConfiguration with rounds := #[round (-1.0) none] })
  , ("round start above duration", errorIs
      "round 0 start must be finite and between zero and duration"
      { baseConfiguration with rounds := #[round 11.0 none] })
  , ("infinite round start", errorIs
      "round 0 start must be finite and between zero and duration"
      { baseConfiguration with rounds := #[round (1.0 / 0.0) none] })
  , ("NaN round start", errorIs
      "round 0 start must be finite and between zero and duration"
      { baseConfiguration with rounds := #[round (0.0 / 0.0) none] })
  , ("zero round interval", errorIs
      "round 0 interval must be finite and greater than zero"
      { baseConfiguration with rounds := #[round 0.0 (some 0.0)] })
  , ("negative round interval", errorIs
      "round 0 interval must be finite and greater than zero"
      { baseConfiguration with rounds := #[round 0.0 (some (-1.0))] })
  , ("infinite round interval", errorIs
      "round 0 interval must be finite and greater than zero"
      { baseConfiguration with rounds := #[round 0.0 (some (1.0 / 0.0))] })
  , ("NaN round interval", errorIs
      "round 0 interval must be finite and greater than zero"
      { baseConfiguration with rounds := #[round 0.0 (some (0.0 / 0.0))] })
  , ("invalid run metadata", errorIs
      "run metadata must be an object or null"
      { baseConfiguration with runMetadata := .str "invalid" }) ]

private def orderingChecks : List (String × Bool) :=
  [ ("alignment before duration", errorIs
      "component IDs and components differ in length"
      { baseConfiguration with componentIds := #["a"], duration := 0.0 })
  , ("duration before warmup", errorIs
      "duration must be finite and greater than zero"
      { baseConfiguration with duration := 0.0, warmup := -1.0 })
  , ("warmup before duplicate IDs", errorIs
      "warmup must be between zero and duration"
      { baseConfiguration with
        componentIds := #["a", "a"]
        components := #[component, component]
        warmup := -1.0 })
  , ("duplicate IDs before connections", errorIs
      "duplicate component ID \"a\""
      { baseConfiguration with
        componentIds := #["a", "a"]
        components := #[component, component]
        connections := #[⟨(2, "out"), (0, "in")⟩] })
  , ("connection source before target", errorIs
      "connection 0 source component index 2 is out of range"
      { baseConfiguration with
        componentIds := #["a"]
        components := #[component]
        connections := #[⟨(2, "out"), (2, "in")⟩] })
  , ("earlier connection before later", errorIs
      "connection 0 target component index 2 is out of range"
      { baseConfiguration with
        componentIds := #["a"]
        components := #[component]
        connections := #[⟨(0, "out"), (2, "in")⟩, ⟨(2, "out"), (0, "in")⟩] })
  , ("connections before overrides", errorIs
      "connection 0 source component index 2 is out of range"
      { baseConfiguration with
        componentIds := #["a"]
        components := #[component]
        connections := #[⟨(2, "out"), (0, "in")⟩]
        overrides := [(0, "missing", 1.0)] })
  , ("earlier override before later", errorIs
      "unknown parameter override \"first\""
      { baseConfiguration with
        overrides := [(0, "first", 1.0), (0, "second", 2.0)] })
  , ("overrides before outputs", errorIs
      "unknown parameter override \"missing\""
      { baseConfiguration with
        overrides := [(0, "missing", 1.0)]
        outputs := [output "" "" (.timeseries (some 0.0))] })
  , ("output path before name and kind", errorIs
      "output 0 path must not be empty"
      { baseConfiguration with
        outputs := [output "" "" (.timeseries (some 0.0))] })
  , ("output name before kind", errorIs
      "output 0 name must not be empty"
      { baseConfiguration with
        outputs := [output "a.value" "" (.timeseries (some 0.0))] })
  , ("earlier output before later", errorIs
      "output 0 name must not be empty"
      { baseConfiguration with
        outputs := [output "a.value" "" .final, output "" "later" .final] })
  , ("outputs before rounds", errorIs
      "output 0 path must not be empty"
      { baseConfiguration with
        outputs := [output "" "result" .final]
        rounds := #[round (-1.0) none] })
  , ("round start before interval", errorIs
      "round 0 start must be finite and between zero and duration"
      { baseConfiguration with rounds := #[round (-1.0) (some 0.0)] })
  , ("earlier round before later", errorIs
      "round 0 interval must be finite and greater than zero"
      { baseConfiguration with
        rounds := #[round 0.0 (some 0.0), round (-1.0) none] })
  , ("rounds before metadata", errorIs
      "round 0 start must be finite and between zero and duration"
      { baseConfiguration with
        rounds := #[round (-1.0) none]
        runMetadata := .str "invalid" }) ]

private def positiveChecks : List (String × Bool) :=
  [ ("null metadata normalization", normalizedNullMetadata)
  , ("object metadata preservation", preservesObjectMetadata)
  , ("valid boundaries", prepares boundaryConfiguration)
  , ("stable override order", stableOverrides)
  , ("prepared connection order", preparedConnectionOrder)
  , ("state connection port filter", stateConnectionPortFilter)
  , ("prepared override application", preparedOverrideAppliesWithoutLookup) ]

def main : IO UInt32 := do
  let checks := errorChecks ++ orderingChecks ++ positiveChecks
  let failures := checks.filter (fun (_, passed) => !passed)
  for (name, _) in failures do
    IO.eprintln s!"preparation check failed: {name}"
  if failures.isEmpty then
    IO.println "preparation checks pass"
    return 0
  IO.eprintln s!"preparation checks: {checks.length} checked, {failures.length} failed"
  return 1
