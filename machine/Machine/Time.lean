/-!
# Simulation time

`Time := Float` uses IEEE 754 binary64. The calendar orders entries by IEEE
totalOrder then insertion sequence. Non-finite values never enter the calendar
because the `schedule` operation rejects them.
-/

namespace Machine

abbrev Time := Float

/-- Map a float's bits to a key whose unsigned order is IEEE totalOrder.

Domain caveat: Lean canonicalizes every NaN (sign and payload) to the quiet-
NaN bit pattern, so NaN orderings are unobservable here. This is sound for
the machine: calendar entries are finite by construction (strict `schedule`),
so `total_cmp`'s NaN branches are unreachable in machine and engine alike;
`totalCmp` defines the ordering on non-NaN values, verified by the golden
vectors. -/
def totalKey (f : Float) : UInt64 :=
  let b := f.toBits
  if b >>> 63 == 1 then ~~~b else b ^^^ ((1 : UInt64) <<< 63)

/-- IEEE totalOrder comparison, Rust's `f64::total_cmp` (non-NaN domain). -/
def totalCmp (a b : Float) : Ordering :=
  compare (totalKey a) (totalKey b)

def totalLt (a b : Float) : Bool :=
  totalKey a < totalKey b

end Machine
