import Conformance
/-!
Run a named conformance case on the Lean reference machine and print its trace
as NDJSON envelopes.
Usage: `lake exe osdl-reference-machine <conformance-case> [--seed <seed>] [--results]`
or `lake exe osdl-reference-machine --catalog`.
-/

open Machine

private def withSeed (configuration : RunConfiguration) (seed : String) : Option RunConfiguration :=
  match seed.toNat? with
  | some value => some { configuration with seed := UInt64.ofNat value }
  | none => none

private def parseArguments : List String → Option (String × Option String × Bool)
  | [conformanceCaseName] => some (conformanceCaseName, none, false)
  | [conformanceCaseName, "--results"] => some (conformanceCaseName, none, true)
  | [conformanceCaseName, "--seed", seed] => some (conformanceCaseName, some seed, false)
  | [conformanceCaseName, "--seed", seed, "--results"] =>
    some (conformanceCaseName, some seed, true)
  | _ => none

private def emitConfiguration (configuration : RunConfiguration) (results : Bool) : IO Bool := do
  match Machine.runReport configuration with
  | .error error =>
    IO.eprintln error.message
    pure false
  | .ok report =>
    if results then
      IO.println report.results.render
    else
      for eventEnvelope in report.trace do
        IO.println eventEnvelope.render
    pure true

private def conformanceInputJson : ConformanceInput → JsonValue
  | .osdl path => .obj [("kind", .str "osdl"), ("path", .str path)]
  | .machine behavior => .obj [("kind", .str "machine"), ("behavior", .str behavior)]

private def conformanceCaseJson (case : ConformanceCase) : JsonValue :=
  .obj [ ("id", .str case.id)
       , ("purpose", .str case.purpose)
       , ("module", .str case.module)
       , ("input", conformanceInputJson case.input) ]

private def catalogueJson : JsonValue :=
  .arr (ConformanceCases.all.map conformanceCaseJson)

def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | ["--catalog"] =>
    IO.println catalogueJson.render
    return 0
  | _ =>
    match parseArguments arguments with
    | some (conformanceCaseName, seed, results) =>
      match ConformanceCases.all.find? (fun case => case.id == conformanceCaseName) with
      | none =>
        IO.eprintln s!"unknown conformance case: {conformanceCaseName}"
        if seed.isNone && !results then
          IO.eprintln s!"available: {ConformanceCases.all.map (·.id)}"
        return 1
      | some case =>
        match seed with
        | none =>
          return if ← emitConfiguration case.configuration results then 0 else 1
        | some seed =>
          match withSeed case.configuration seed with
          | some configuration =>
            return if ← emitConfiguration configuration results then 0 else 1
          | none =>
            IO.eprintln s!"invalid seed: {seed}"
            return 1
    | none =>
      IO.eprintln "usage: osdl-reference-machine <conformance-case> [--seed <seed>] [--results]"
      IO.eprintln "       osdl-reference-machine --catalog"
      IO.eprintln s!"available: {ConformanceCases.all.map (·.id)}"
      return 1
