import Machine.GoldenVectors
/-!
Generates the committed golden vectors from the shared fixed cases.

Usage: `lake exe genvectors`.
-/

open Machine

private def sampleHeaderIndex : Nat := 329

def generate : IO UInt32 := do
  if cases.length != 348 then
    IO.eprintln s!"expected 348 golden-vector cases, found {cases.length}"
    return 1

  IO.println "# Golden vectors for the Lean reference machine (Machine/Time.lean, Machine/Rng.lean)."
  IO.println "# Regenerate: cd machine && lake exe genvectors > vectors/golden.txt"
  IO.println "# cmp <bitsA> <bitsB> <lt|eq|gt>   -- binary64 bit patterns, IEEE 754 totalOrder"
  IO.println "# stream <seed> <label> <d1> <d2> <d3> <d4> -- first four next_u64 of stream(seed, label)"

  for vectorCase in cases.take sampleHeaderIndex do
    IO.println (renderLine vectorCase)

  IO.println "# sample <dist> <seed> <p1bits> [<p2bits> [<p3bits>]] : <8 sample bits>"
  IO.println "# pick <seed> <k> <8 indices>"
  for vectorCase in cases.drop sampleHeaderIndex do
    IO.println (renderLine vectorCase)

  return 0

def main : IO UInt32 :=
  generate
