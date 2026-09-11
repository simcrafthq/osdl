import Conformance
/-!
Checks for the conformance catalogue metadata. Usage: `lake exe cataloguecheck`.
-/

open Machine

private def requiredCoreIds : List String :=
  [ "timers", "timercancel", "pipeline", "backpressure", "cancelxfer"
  , "quiesce", "msgvalue", "valuescope", "paramoverride"
  , "paramoverridecascade", "rngpair", "stopper", "threshold", "exprerr"
  , "errsend", "componenterr" ]

private def requiredDesIds : List String :=
  [ "despipe", "desroute", "desstats", "desexp", "despri", "descond"
  , "desweight", "desmodes" ]

private def requiredRoundIds : List String :=
  ["roundtick", "rounderr"]

/-- Per-module case lists paired with their required IDs and module value.
`ConformanceCases.all` concatenates these lists, so pinning each list to its
required IDs in order pins the catalogue as a whole: no duplicate, missing,
or extra ID survives, and every case carries its list's module. -/
private def moduleLists : List (String × String × List String × List ConformanceCase) :=
  [ ("core", "core@0.1.0", requiredCoreIds, ConformanceCases.core)
  , ("des", "des@0.1.0", requiredDesIds, ConformanceCases.des)
  , ("rounds", "reference-machine@0.1.0", requiredRoundIds, ConformanceCases.rounds) ]

private def cataloguePreparationFailures
    (cases : List ConformanceCase) : List (String × String) :=
  cases.filterMap fun case =>
    match prepareRun case.configuration with
    | .ok _ => none
    | .error error => some (case.id, error.message)

private def machineBehaviors (cases : List ConformanceCase) : List String :=
  cases.filterMap fun case =>
    match case.input with
    | .machine behavior => some behavior
    | .osdl _ => none

private def machineBehaviorCountFailures (cases : List ConformanceCase) : List String :=
  let behaviors := machineBehaviors cases
  (cases.filterMap fun case =>
    match case.input with
    | .machine behavior =>
      if behaviors.count behavior == 1 then none else some behavior
    | .osdl _ => none).eraseDups

private def machineBehaviorIdFailures
    (cases : List ConformanceCase) : List (String × String) :=
  cases.filterMap fun case =>
    match case.input with
    | .machine behavior => if case.id == behavior then none else some (case.id, behavior)
    | .osdl _ => none

def main : IO UInt32 := do
  let cases := ConformanceCases.all
  let preparationFailures := cataloguePreparationFailures cases
  let behaviorCountFailures := machineBehaviorCountFailures cases
  let behaviorIdFailures := machineBehaviorIdFailures cases
  let emptyPurposeIds := cases.filter (·.purpose.isEmpty) |>.map (·.id)
  let mut failures := 0
  if !emptyPurposeIds.isEmpty then
    IO.eprintln s!"empty catalogue purposes: {emptyPurposeIds}"
    failures := failures + 1
  for (listName, moduleValue, required, listCases) in moduleLists do
    if listCases.map (·.id) != required then
      IO.eprintln s!"case list {listName} does not carry its required IDs in order"
      IO.eprintln s!"  required: {required}"
      IO.eprintln s!"  found:    {listCases.map (·.id)}"
      failures := failures + 1
    let strayIds := listCases.filter (·.module != moduleValue) |>.map (·.id)
    if !strayIds.isEmpty then
      IO.eprintln s!"case list {listName} has cases outside module {moduleValue}: {strayIds}"
      failures := failures + 1
  for (id, message) in preparationFailures do
    IO.eprintln s!"catalogue configuration {id} failed preparation: {message}"
    failures := failures + 1
  if !behaviorCountFailures.isEmpty then
    IO.eprintln s!"machine behaviors without exactly one catalogue entry: {behaviorCountFailures}"
    failures := failures + 1
  for (id, behavior) in behaviorIdFailures do
    IO.eprintln s!"machine catalogue ID {id} does not match behavior {behavior}"
    failures := failures + 1
  if failures == 0 then
    IO.println "catalogue checks pass"
    return 0
  return 1
