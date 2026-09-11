import Machine.GoldenVectors
/-!
Golden-vector checker for comparison, stream, sampler, and pick cases.

Usage: `lake exe vectors [path]` (default `vectors/golden.txt`).
-/

open Machine

private def checkDataLine (line : String) : Except String Bool := do
  let vectorCase ← parseLine line
  evaluate vectorCase

def main (args : List String) : IO UInt32 := do
  let path := args.headD "vectors/golden.txt"
  let lines ← IO.FS.lines path
  let mut checked := 0
  let mut failures := 0
  let mut lineNumber := 0
  for line in lines do
    lineNumber := lineNumber + 1
    if !line.isEmpty && !line.startsWith "#" then
      checked := checked + 1
      match checkDataLine line with
      | .error message =>
        IO.eprintln s!"{path}:{lineNumber}: {message}: {line}"
        failures := failures + 1
      | .ok false =>
        IO.eprintln s!"{path}:{lineNumber}: vector mismatch: {line}"
        failures := failures + 1
      | .ok true => pure ()
  IO.println s!"golden vectors: {checked} checked, {failures} failed"
  return if failures == 0 then 0 else 1
