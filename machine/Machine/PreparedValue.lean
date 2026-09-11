import Machine.Expr
import Machine.Samplers
/-!
# Prepared values

Prepared numeric values are the common evaluation and sampling interface.
References resolve through a local scope, model parameters, and published
state, in that order. Sampling uses the caller's deterministic random stream.
-/

namespace Machine

/-- Numeric names supplied by a local evaluation scope or model parameters. -/
abbrev EvaluationScope := List (String × Float)

/-- A checked numeric value ready for repeated evaluation or sampling. -/
inductive PreparedValue where
  | number (value : Float)
  | parameter (name : String)
  | expression (expression : Machine.Expr)
  | constant (value : PreparedValue)
  | uniform (min max : PreparedValue)
  | exponential (rate : PreparedValue)
  | normal (mean std : PreparedValue)
  | lognormal (mu sigma : PreparedValue)
  | triangular (min mode max : PreparedValue)
  | weibull (shape scale : PreparedValue)
  | gamma (shape scale : PreparedValue)
  | beta (alpha beta : PreparedValue)
  | poisson (rate : PreparedValue)
  | binomial (n p : PreparedValue)
  | bernoulli (p : PreparedValue)
  | geometric (p : PreparedValue)
  | discrete (values : List (Float × PreparedValue))
  | empirical (samples : List Float)

namespace EvaluationScope

/-- Resolve a path through local names, model parameters, then published state. -/
def resolve (localScope parameters : EvaluationScope) (state : String → Option Float)
    (path : List String) : Option Float :=
  let key := String.intercalate "." path
  match localScope.lookup key with
  | some value => some value
  | none =>
    match path with
    | [name] =>
      match parameters.lookup name with
      | some value => some value
      | none => state key
    | _ => state key

end EvaluationScope

namespace PreparedValue

private def unresolved (path : List String) : String :=
  s!"unresolved reference \"{String.intercalate "." path}\""

/-- Evaluate a deterministic prepared value without consuming random state. -/
def evaluate (value : PreparedValue) (resolve : List String → Option Float)
    (time : Time) : Except String Float :=
  match value with
  | .number numericValue => .ok numericValue
  | .parameter name =>
    match resolve [name] with
    | some numericValue => .ok numericValue
    | none => .error (unresolved [name])
  | .expression expressionValue => expressionValue.eval { resolve, time }
  | _ => .error "a distribution is not allowed in this deterministic position"

private def finite (distribution parameter : String) (value : Float) : Except String Float :=
  if value.isFinite then .ok value
  else .error s!"{distribution} {parameter} must be finite"

private def positive (distribution parameter : String) (value : Float) : Except String Float := do
  let value ← finite distribution parameter value
  if value > 0.0 then .ok value
  else .error s!"{distribution} {parameter} must be > 0"

private def probability (distribution : String) (value : Float) : Except String Float := do
  let value ← finite distribution "p" value
  if value ≥ 0.0 && value ≤ 1.0 then .ok value
  else .error s!"{distribution} p must be between 0 and 1"

private def weightedPick : List (Float × Float) → Float → Float → Float
  | [], _, fallback => fallback
  | (value, weight) :: remaining, draw, fallback =>
    if draw < weight then value
    else weightedPick remaining (draw - weight) fallback

/-- Evaluate or sample a prepared value with one deterministic random stream. -/
def sample (value : PreparedValue) (resolve : List String → Option Float)
    (time : Time) (randomStream : Pcg64Mcg) : Except String (Float × Pcg64Mcg) := do
  match value with
  | .number _ | .parameter _ | .expression _ =>
    .ok (← value.evaluate resolve time, randomStream)
  | .constant inner =>
    .ok (← finite "constant" "value" (← inner.evaluate resolve time), randomStream)
  | .uniform minValue maxValue =>
    let minValue ← finite "uniform" "min" (← minValue.evaluate resolve time)
    let maxValue ← finite "uniform" "max" (← maxValue.evaluate resolve time)
    if minValue > maxValue then .error "uniform min must be <= max"
    else .ok (Samplers.uniform minValue maxValue randomStream)
  | .exponential rate =>
    let rate ← positive "exponential" "rate" (← rate.evaluate resolve time)
    .ok (Samplers.exponential rate randomStream)
  | .normal mean std =>
    let mean ← finite "normal" "mean" (← mean.evaluate resolve time)
    let std ← finite "normal" "std" (← std.evaluate resolve time)
    if std < 0.0 then .error "normal std must be >= 0"
    else .ok (Samplers.normal mean std randomStream)
  | .lognormal mu sigma =>
    let mu ← finite "lognormal" "mu" (← mu.evaluate resolve time)
    let sigma ← finite "lognormal" "sigma" (← sigma.evaluate resolve time)
    if sigma < 0.0 then .error "lognormal sigma must be >= 0"
    else .ok (Samplers.lognormal mu sigma randomStream)
  | .triangular minValue mode maxValue =>
    let minValue ← finite "triangular" "min" (← minValue.evaluate resolve time)
    let mode ← finite "triangular" "mode" (← mode.evaluate resolve time)
    let maxValue ← finite "triangular" "max" (← maxValue.evaluate resolve time)
    if minValue > mode || mode > maxValue || minValue == maxValue then
      .error "triangular requires min <= mode <= max and min < max"
    else .ok (Samplers.triangular minValue mode maxValue randomStream)
  | .weibull shape scale =>
    let shape ← positive "weibull" "shape" (← shape.evaluate resolve time)
    let scale ← positive "weibull" "scale" (← scale.evaluate resolve time)
    .ok (Samplers.weibull shape scale randomStream)
  | .gamma shape scale =>
    let shape ← positive "gamma" "shape" (← shape.evaluate resolve time)
    let scale ← positive "gamma" "scale" (← scale.evaluate resolve time)
    Samplers.gamma shape scale randomStream
  | .beta alpha betaValue =>
    let alpha ← positive "beta" "alpha" (← alpha.evaluate resolve time)
    let betaValue ← positive "beta" "beta" (← betaValue.evaluate resolve time)
    Samplers.beta alpha betaValue randomStream
  | .poisson rate =>
    let rate ← positive "poisson" "rate" (← rate.evaluate resolve time)
    Samplers.poisson rate randomStream
  | .binomial n p =>
    let n ← finite "binomial" "n" (← n.evaluate resolve time)
    let p ← probability "binomial" (← p.evaluate resolve time)
    if n < 0.0 || n.floor != n then .error "binomial n must be a nonnegative integer"
    else .ok (Samplers.binomial n.toUInt64.toNat p randomStream)
  | .bernoulli p =>
    let p ← probability "bernoulli" (← p.evaluate resolve time)
    .ok (Samplers.bernoulli p randomStream)
  | .geometric p =>
    let p ← probability "geometric" (← p.evaluate resolve time)
    if p == 0.0 then .error "geometric p must be > 0"
    else .ok (Samplers.geometric p randomStream)
  | .discrete values =>
    if values.isEmpty then .error "discrete requires at least one value"
    else
      let weighted ← values.mapM fun (sampleValue, weightValue) => do
        let weight ← finite "discrete" "weight" (← weightValue.evaluate resolve time)
        if weight < 0.0 then .error "discrete weights must be >= 0"
        else .ok (sampleValue, weight)
      let total := weighted.foldl (fun total (_, weight) => total + weight) 0.0
      if !total.isFinite || total ≤ 0.0 then .error "discrete weight total must be finite and > 0"
      else
        let (draw, randomStream) := Samplers.uniform 0.0 total randomStream
        let fallback := weighted.getLast!.fst
        .ok (weightedPick weighted draw fallback, randomStream)
  | .empirical samples =>
    if samples.isEmpty then .error "empirical requires at least one sample"
    else
      let (index, randomStream) := Samplers.pick samples.length randomStream
      .ok (samples[index]!, randomStream)

end PreparedValue

end Machine
