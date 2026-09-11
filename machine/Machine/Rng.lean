/-!
# Randomness

The kernel's per-component RNG streams are specified exactly.
FNV-1a labeling derives a stream seed from `(run seed, component id)`, and
PCG64-MCG with the MCG-XSL-RR 128/64 output function produces the draws. The
Lean reference machine derives every draw from the run seed alone. Adding a
component never perturbs another component's draws because each component uses
its own labeled stream.
-/

namespace Machine

/--
FNV-1a over a list of byte parts, with a `0xff`-separator fold after each
part to avoid concatenation collisions.
-/
def fnv1a (parts : List ByteArray) : UInt64 :=
  parts.foldl
    (fun h part =>
      let h := part.foldl (fun h b => (h ^^^ UInt64.ofNat b.toNat) * 0x100000001b3) h
      (h ^^^ 0xff) * 0x100000001b3)
    0xcbf29ce484222325

/-- Little-endian bytes of a `UInt64`. -/
def u64LeBytes (x : UInt64) : ByteArray :=
  ByteArray.mk <| (List.range 8).toArray.map fun i =>
    (x >>> (UInt64.ofNat (8 * i))).toUInt8

/-- PCG64-MCG: a 128-bit multiplicative congruential state. Invariant: odd, < 2^128. -/
structure Pcg64Mcg where
  state : Nat
deriving Repr

namespace Pcg64Mcg

def mask128 : Nat := (1 <<< 128) - 1
def mask64 : Nat := (1 <<< 64) - 1

/-- The PCG 128-bit MCG multiplier. -/
def mult : Nat := 0x2360ed051fc65da44385df649fccf645

/-- Create a PCG64-MCG state and force it odd. -/
def new (s : Nat) : Pcg64Mcg := ⟨(s ||| 1) &&& mask128⟩

instance : Inhabited Pcg64Mcg := ⟨new 0⟩

def rotr64 (x r : UInt64) : UInt64 :=
  let r := r &&& 63
  if r == 0 then x else (x >>> r) ||| (x <<< (64 - r))

/--
Advance the MCG and apply the XSL-RR output function: xor the state's high
and low halves, rotate right by the state's top six bits.
-/
def next (g : Pcg64Mcg) : UInt64 × Pcg64Mcg :=
  let s := (g.state * mult) &&& mask128
  let rot := UInt64.ofNat (s >>> 122)
  let xsl := UInt64.ofNat ((s >>> 64) &&& mask64) ^^^ UInt64.ofNat (s &&& mask64)
  (rotr64 xsl rot, ⟨s⟩)

end Pcg64Mcg

/-- Derive a labeled PCG64-MCG stream from the seed's little-endian bytes and
the label's UTF-8 bytes. -/
def stream (seed : UInt64) (label : String) : Pcg64Mcg :=
  Pcg64Mcg.new ((fnv1a [u64LeBytes seed, label.toUTF8]).toNat ||| 1)

end Machine
