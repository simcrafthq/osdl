import Machine.GoldenVectors
/-!
# Golden-vector round-trip checks

Checks parsing, rendering, catalogue size, numeric failures, and evaluation.
Usage: `lake exe vectorroundtripcheck`.
-/

open Machine

private def parsesAs (line : String) (expected : GoldenVectorCase) : Bool :=
  match parseLine line with
  | .ok actual => actual == expected
  | .error _ => false

private def errorsAs (line expected : String) : Bool :=
  match parseLine line with
  | .ok _ => false
  | .error actual => actual == expected

private def rejects (line : String) : Bool :=
  match parseLine line with
  | .ok _ => false
  | .error _ => true

private def roundTrips (value : GoldenVectorCase) : Bool :=
  match parseLine (renderLine value) with
  | .ok parsed => parsed == value
  | .error _ => false

private def evaluates (value : GoldenVectorCase) : Bool :=
  match evaluate value with
  | .ok true => true
  | _ => false

private def validKindChecks : List (String × Bool) :=
  [ ("comparison line", parsesAs "cmp 0 0 eq" (.compare 0 0 .eq))
  , ("stream line", parsesAs "stream 0 a 1 2" (.stream 0 "a" [1, 2]))
  , ("sample line", parsesAs "sample uniform 1 0 4607182418800017408 : 1 2"
      (.sample "uniform" 1 [0, 4607182418800017408] [1, 2]))
  , ("pick line", parsesAs "pick 21 3 2 0" (.pick 21 3 [2, 0])) ]

private def malformedChecks : List (String × Bool) :=
  [ ("invalid seed", errorsAs "sample exponential nope : 1" "invalid seed")
  , ("invalid pick bound", errorsAs "pick 21 nope 0" "invalid pick bound")
  , ("unknown kind", errorsAs "unknown 1" "unknown vector kind")
  , ("left bits overflow", errorsAs "cmp 18446744073709551616 0 eq" "invalid left bits")
  , ("right bits overflow", errorsAs "cmp 0 18446744073709551616 eq" "invalid right bits")
  , ("ordering", errorsAs "cmp 0 0 equal" "invalid ordering")
  , ("parameter bits", errorsAs "sample uniform 1 nope : 1" "invalid parameter bits")
  , ("sample bits", errorsAs "sample uniform 1 0 : nope" "invalid sample bits")
  , ("stream draw", errorsAs "stream 1 label nope" "invalid stream draw")
  , ("pick index", errorsAs "pick 1 2 nope" "invalid pick index")
  , ("sample delimiter missing", rejects "sample uniform 1 0 1")
  , ("sample delimiter repeated", rejects "sample uniform 1 0 : 1 : 2") ]

private def caseCounts : Nat × Nat × Nat × Nat :=
  cases.foldl (fun (comparisons, streams, samples, picks) value =>
    match value with
    | .compare .. => (comparisons + 1, streams, samples, picks)
    | .stream .. => (comparisons, streams + 1, samples, picks)
    | .sample .. => (comparisons, streams, samples + 1, picks)
    | .pick .. => (comparisons, streams, samples, picks + 1)) (0, 0, 0, 0)

private def check (name : String) (condition : Bool) : IO Nat := do
  if condition then pure 0
  else
    IO.eprintln s!"vector round-trip check failed: {name}"
    pure 1

def main : IO UInt32 := do
  let checks := validKindChecks ++ malformedChecks
  let mut failures := 0
  for (name, condition) in checks do
    failures := failures + (← check name condition)
  failures := failures + (← check "catalogue counts" (caseCounts == (324, 5, 17, 2)))
  failures := failures + (← check "348 catalogue cases" (cases.length == 348))
  failures := failures + (← check "all catalogue cases round trip" (cases.all roundTrips))
  failures := failures + (← check "all catalogue cases evaluate" (cases.all evaluates))
  if failures == 0 then
    IO.println "vector round-trip checks pass"
    return 0
  return 1
