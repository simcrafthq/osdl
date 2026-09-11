import Machine.Rng
/-!
# Pinned distribution samplers

These algorithms turn uniform bits into variates. Per-distribution golden
vectors check their binary64 results. Draw counts are part of the contract:
every sampler consumes a defined number of `Pcg64Mcg.next` draws per sample,
and rejection loops consume a defined number per iteration.

Two layers share one set of formulas: the pure `…OfU` functions map already-
drawn uniforms to variates. Component behaviors apply them to
`ComponentProgram.randomUInt64` draws. The `Pcg64Mcg`-state samplers draw and
apply the same formulas. Callers validate parameter domains; samplers assume
the documented domains hold.
-/

namespace Machine.Samplers

/-- 2⁻⁵³, the scale mapping 53 random bits onto `[0,1)`. -/
def twoNeg53 : Float := 1.0 / 9007199254740992.0

/-- 2π as the nearest binary64 (`0x401921FB54442D18`). -/
def twoPi : Float := 6.283185307179586

/-- The uniform primitive: top 53 bits of one draw, scaled to `[0,1)`. -/
def u01Bits (bits : UInt64) : Float :=
  (bits >>> 11).toFloat * twoNeg53

/-- Uniform on `[a, b]`: `a + (b-a)·u`. Requires `a ≤ b`. -/
def uniformOfU (a b u : Float) : Float :=
  a + (b - a) * u

/-- Exponential by inverse CDF: `-ln(1-u)/rate`. Requires `rate > 0`. -/
def expOfU (rate u : Float) : Float :=
  -Float.log (1.0 - u) / rate

/-- Samples a standard normal with the Box-Muller cosine branch.

`sqrt(-2·ln(1-u1)) · cos(2π·u2)`. No second variate is cached, so the draw
count per sample stays fixed at two. -/
def stdNormalOfU (u1 u2 : Float) : Float :=
  Float.sqrt (-2.0 * Float.log (1.0 - u1)) * Float.cos (twoPi * u2)

/-- Normal: `mean + std·z`. Requires `std ≥ 0`. -/
def normalOfU (mean std u1 u2 : Float) : Float :=
  mean + std * stdNormalOfU u1 u2

/-- Triangular by inverse CDF. Requires `min ≤ mode ≤ max`, `min < max`. -/
def triangularOfU (min mode max u : Float) : Float :=
  let fc := (mode - min) / (max - min)
  if u < fc then
    min + Float.sqrt ((max - min) * (mode - min) * u)
  else
    max - Float.sqrt ((max - min) * (max - mode) * (1.0 - u))

/-- Weibull by inverse CDF: `scale · (-ln(1-u))^(1/shape)`. Requires
`shape > 0`, `scale > 0`. -/
def weibullOfU (shape scale u : Float) : Float :=
  scale * Float.pow (-Float.log (1.0 - u)) (1.0 / shape)

/-- Bernoulli: `u < p`. -/
def bernoulliOfU (p u : Float) : Float :=
  if u < p then 1.0 else 0.0

/-- Geometric (failures before the first success) by inverse CDF:
`floor(ln(1-u)/ln(1-p))`. Requires `0 < p < 1` (callers return 0 for
`p = 1` without drawing). -/
def geometricOfU (p u : Float) : Float :=
  Float.floor (Float.log (1.0 - u) / Float.log (1.0 - p))

/-! ## Pcg64Mcg-state samplers -/

/-- One `u01` draw. -/
def u01 (g : Pcg64Mcg) : Float × Pcg64Mcg :=
  let (bits, g) := g.next
  (u01Bits bits, g)

/-- One uniform index in `0..k` (one draw): `min(floor(u·k), k-1)`.
Requires `k > 0`. -/
def pick (k : Nat) (g : Pcg64Mcg) : Nat × Pcg64Mcg :=
  let (u, g) := u01 g
  -- The min guard closes the rounding corner where u·k rounds up to k.
  (min (u * Float.ofNat k).toUInt64.toNat (k - 1), g)

def uniform (a b : Float) (g : Pcg64Mcg) : Float × Pcg64Mcg :=
  let (u, g) := u01 g
  (uniformOfU a b u, g)

def exponential (rate : Float) (g : Pcg64Mcg) : Float × Pcg64Mcg :=
  let (u, g) := u01 g
  (expOfU rate u, g)

def standardNormal (g : Pcg64Mcg) : Float × Pcg64Mcg :=
  let (u1, g) := u01 g
  let (u2, g) := u01 g
  (stdNormalOfU u1 u2, g)

def normal (mean std : Float) (g : Pcg64Mcg) : Float × Pcg64Mcg :=
  let (u1, g) := u01 g
  let (u2, g) := u01 g
  (normalOfU mean std u1 u2, g)

def lognormal (mu sigma : Float) (g : Pcg64Mcg) : Float × Pcg64Mcg :=
  let (z, g) := normal mu sigma g
  (Float.exp z, g)

def triangular (min mode max : Float) (g : Pcg64Mcg) : Float × Pcg64Mcg :=
  let (u, g) := u01 g
  (triangularOfU min mode max u, g)

def weibull (shape scale : Float) (g : Pcg64Mcg) : Float × Pcg64Mcg :=
  let (u, g) := u01 g
  (weibullOfU shape scale u, g)

def bernoulli (p : Float) (g : Pcg64Mcg) : Float × Pcg64Mcg :=
  let (u, g) := u01 g
  (bernoulliOfU p u, g)

def geometric (p : Float) (g : Pcg64Mcg) : Float × Pcg64Mcg :=
  if p ≥ 1.0 then (0.0, g)
  else
    let (u, g) := u01 g
    (geometricOfU p u, g)

/-- Limits rejection and loop samplers to 10,000 iterations.
Exhaustion returns the sampler-specific iteration-bound error. -/
def samplerFuel : Nat := 10000

/-- Samples a unit-scale gamma value with `shape ≥ 1` using Marsaglia-Tsang. -/
def gammaGe1 (shape : Float) : Nat → Pcg64Mcg → Except String (Float × Pcg64Mcg)
  | 0, _ => .error "gamma sampler exhausted its iteration bound"
  | fuel + 1, g =>
    let d := shape - 1.0 / 3.0
    let c := 1.0 / (3.0 * Float.sqrt d)
    let (z, g) := standardNormal g
    let v := (1.0 + c * z) * (1.0 + c * z) * (1.0 + c * z)
    if v ≤ 0.0 then gammaGe1 shape fuel g
    else
      let (u, g) := u01 g
      if u < 1.0 - 0.0331 * z * z * z * z then .ok (d * v, g)
      else if Float.log u < 0.5 * z * z + d * (1.0 - v + Float.log v) then .ok (d * v, g)
      else gammaGe1 shape fuel g

/-- Samples a gamma value using the Marsaglia-Tsang method.

`shape < 1` boosts with one extra draw:
`gamma(k) = gamma(k+1) · U^(1/k)`, `U ∈ (0,1]`. Requires `shape > 0`,
`scale > 0`. -/
def gamma (shape scale : Float) (g : Pcg64Mcg) : Except String (Float × Pcg64Mcg) :=
  if shape < 1.0 then do
    let (gv, g) ← gammaGe1 (shape + 1.0) samplerFuel g
    let (u, g) := u01 g
    .ok (scale * gv * Float.pow (1.0 - u) (1.0 / shape), g)
  else do
    let (gv, g) ← gammaGe1 shape samplerFuel g
    .ok (scale * gv, g)

/-- Beta as a gamma ratio: `x/(x+y)`, `x ~ gamma(alpha,1)` drawn first.
Requires `alpha > 0`, `beta > 0`. -/
def beta (alpha b : Float) (g : Pcg64Mcg) : Except String (Float × Pcg64Mcg) := do
  let (x, g) ← gamma alpha 1.0 g
  let (y, g) ← gamma b 1.0 g
  .ok (x / (x + y), g)

/-- Knuth: multiply uniforms until the product drops below `exp(-rate)`
(one draw per iteration). -/
def poissonKnuth (rate : Float) (g : Pcg64Mcg) : Except String (Float × Pcg64Mcg) :=
  go (Float.exp (-rate)) samplerFuel 1.0 0 g
where
  go : Float → Nat → Float → Nat → Pcg64Mcg → Except String (Float × Pcg64Mcg)
    | _, 0, _, _, _ => .error "poisson sampler exhausted its iteration bound"
    | l, fuel + 1, p, k, g =>
      let (u, g) := u01 g
      let p := p * u
      if p ≤ l then .ok (Float.ofNat k, g)
      else go l fuel p (k + 1) g

/-- Poisson by Knuth's method, split additively for large rates
(`poisson(a+b) = poisson(a) + poisson(b)` in distribution) so `exp(-rate)`
never underflows. Requires `rate > 0`. -/
def poisson (rate : Float) (g : Pcg64Mcg) : Except String (Float × Pcg64Mcg) :=
  go (chunks rate) rate 0.0 g
where
  chunk : Float := 500.0
  /-- Number of full 500-chunks, as loop fuel. -/
  chunks (rate : Float) : Nat :=
    if rate > chunk then (rate / chunk).toUInt64.toNat + 1 else 0
  go : Nat → Float → Float → Pcg64Mcg → Except String (Float × Pcg64Mcg)
    | 0, remaining, n, g => do
      let (k, g) ← poissonKnuth remaining g
      .ok (n + k, g)
    | fuel + 1, remaining, n, g =>
      if remaining > chunk then do
        let (k, g) ← poissonKnuth chunk g
        go fuel (remaining - chunk) (n + k) g
      else do
        let (k, g) ← poissonKnuth remaining g
        .ok (n + k, g)

/-- Binomial by direct summation: exactly `n` Bernoulli draws. Requires
`0 ≤ p ≤ 1`. -/
def binomial (n : Nat) (p : Float) (g : Pcg64Mcg) : Float × Pcg64Mcg :=
  go n 0.0 g
where
  go : Nat → Float → Pcg64Mcg → Float × Pcg64Mcg
    | 0, count, g => (count, g)
    | k + 1, count, g =>
      let (u, g) := u01 g
      go k (if u < p then count + 1.0 else count) g

end Machine.Samplers
