import Machine.Time
import Machine.Rng
import Machine.Samplers
/-!
# Golden vectors

Shared golden-vector cases, parsing, rendering, and evaluation.
-/

namespace Machine

/-- One comparison, stream, sampler, or pick golden-vector case. -/
inductive GoldenVectorCase where
  | compare (leftBits rightBits : UInt64) (expected : Ordering)
  | stream (seed : UInt64) (label : String) (expected : List UInt64)
  | sample (distribution : String) (seed : UInt64)
      (parameters expected : List UInt64)
  | pick (seed : UInt64) (bound : Nat) (expected : List Nat)
deriving BEq, Repr

abbrev VectorSampler := Pcg64Mcg → Except String (Float × Pcg64Mcg)

/-- Render an ordering token. -/
def ordName : Ordering → String
  | .lt => "lt"
  | .eq => "eq"
  | .gt => "gt"

/-- Parse an ordering token. -/
def parseOrdering : String → Except String Ordering
  | "lt" => .ok .lt
  | "eq" => .ok .eq
  | "gt" => .ok .gt
  | _ => .error "invalid ordering"

/-- Return the first `n` draws from a stream. -/
def drawN : Nat → Pcg64Mcg → List UInt64
  | 0, _ => []
  | n + 1, generator =>
    let (value, nextGenerator) := generator.next
    value :: drawN n nextGenerator

/-- Return `n` values from a state sampler. -/
def sampleN (sampler : VectorSampler) : Nat → Pcg64Mcg → Except String (List Float)
  | 0, _ => .ok []
  | n + 1, generator => do
    let (value, nextGenerator) ← sampler generator
    let rest ← sampleN sampler n nextGenerator
    .ok (value :: rest)

private def samplerTable : List (String × (List Float → Option VectorSampler)) :=
  [ ("uniform", fun parameters => match parameters with
      | [a, b] => some fun generator => .ok (Samplers.uniform a b generator)
      | _ => none)
  , ("exponential", fun parameters => match parameters with
      | [rate] => some fun generator => .ok (Samplers.exponential rate generator)
      | _ => none)
  , ("normal", fun parameters => match parameters with
      | [mean, deviation] => some fun generator => .ok (Samplers.normal mean deviation generator)
      | _ => none)
  , ("lognormal", fun parameters => match parameters with
      | [mean, deviation] => some fun generator => .ok (Samplers.lognormal mean deviation generator)
      | _ => none)
  , ("triangular", fun parameters => match parameters with
      | [minimum, mode, maximum] => some fun generator =>
          .ok (Samplers.triangular minimum mode maximum generator)
      | _ => none)
  , ("weibull", fun parameters => match parameters with
      | [shape, scale] => some fun generator => .ok (Samplers.weibull shape scale generator)
      | _ => none)
  , ("bernoulli", fun parameters => match parameters with
      | [probability] => some fun generator => .ok (Samplers.bernoulli probability generator)
      | _ => none)
  , ("geometric", fun parameters => match parameters with
      | [probability] => some fun generator => .ok (Samplers.geometric probability generator)
      | _ => none)
  , ("gamma", fun parameters => match parameters with
      | [shape, scale] => some (Samplers.gamma shape scale)
      | _ => none)
  , ("beta", fun parameters => match parameters with
      | [alpha, beta] => some (Samplers.beta alpha beta)
      | _ => none)
  , ("poisson", fun parameters => match parameters with
      | [rate] => some (Samplers.poisson rate)
      | _ => none)
  , ("binomial", fun parameters => match parameters with
      | [trials, probability] => some fun generator =>
          .ok (Samplers.binomial trials.toUInt64.toNat probability generator)
      | _ => none) ]

/-- Select a fixed golden-vector sampler by name and parameters. -/
def samplerFor (distribution : String) (parameters : List Float) : Option VectorSampler :=
  (samplerTable.find? fun entry => entry.1 == distribution).bind fun entry =>
    entry.2 parameters

/-- Return `n` fixed-width random picks. -/
def pickN : Nat → Nat → Pcg64Mcg → List Nat
  | 0, _, _ => []
  | n + 1, bound, generator =>
    let (value, nextGenerator) := Samplers.pick bound generator
    value :: pickN n bound nextGenerator

private def maximumUInt64 : Nat := 18446744073709551615

private def parseUInt64Field (token message : String) : Except String UInt64 := do
  match token.toNat? with
  | some value =>
    if value ≤ maximumUInt64 then .ok (UInt64.ofNat value) else .error message
  | none => .error message

private def parseNatField (token message : String) : Except String Nat :=
  match token.toNat? with
  | some value => .ok value
  | none => .error message

private def parseUInt64Fields (tokens : List String) (message : String) : Except String (List UInt64) :=
  tokens.mapM fun token => parseUInt64Field token message

private def parseNatFields (tokens : List String) (message : String) : Except String (List Nat) :=
  tokens.mapM fun token => parseNatField token message

/-- Parse one data line without comment or blank-line handling. -/
def parseLine (line : String) : Except String GoldenVectorCase := do
  let words := (line.splitOn " ").filter (· ≠ "")
  match words with
  | "cmp" :: left :: right :: ordering :: [] =>
    let leftBits ← parseUInt64Field left "invalid left bits"
    let rightBits ← parseUInt64Field right "invalid right bits"
    let expected ← parseOrdering ordering
    .ok (.compare leftBits rightBits expected)
  | "cmp" :: _ => .error "invalid comparison vector"
  | "stream" :: seed :: label :: draws =>
    let parsedSeed ← parseUInt64Field seed "invalid seed"
    let expected ← parseUInt64Fields draws "invalid stream draw"
    .ok (.stream parsedSeed label expected)
  | "stream" :: _ => .error "invalid stream vector"
  | "sample" :: distribution :: seed :: rest =>
    let parsedSeed ← parseUInt64Field seed "invalid seed"
    match rest.splitOn ":" with
    | [parameterTokens, expectedTokens] =>
      let parameters ← parseUInt64Fields parameterTokens "invalid parameter bits"
      let expected ← parseUInt64Fields expectedTokens "invalid sample bits"
      .ok (.sample distribution parsedSeed parameters expected)
    | _ => .error "invalid sample delimiter"
  | "sample" :: _ => .error "invalid sample vector"
  | "pick" :: seed :: bound :: indices =>
    let parsedSeed ← parseUInt64Field seed "invalid seed"
    let parsedBound ← parseNatField bound "invalid pick bound"
    let expected ← parseNatFields indices "invalid pick index"
    .ok (.pick parsedSeed parsedBound expected)
  | "pick" :: _ => .error "invalid pick vector"
  | _ => .error "unknown vector kind"

private def renderWords (words : List String) : String :=
  String.intercalate " " words

private def renderUInt64s (values : List UInt64) : List String :=
  values.map fun value => toString value.toNat

/-- Render one golden-vector data line. -/
def renderLine : GoldenVectorCase → String
  | .compare leftBits rightBits expected =>
    renderWords ["cmp", toString leftBits.toNat, toString rightBits.toNat, ordName expected]
  | .stream seed label expected =>
    renderWords (["stream", toString seed.toNat, label] ++ renderUInt64s expected)
  | .sample distribution seed parameters expected =>
    renderWords (["sample", distribution, toString seed.toNat] ++
      renderUInt64s parameters ++ [":"] ++ renderUInt64s expected)
  | .pick seed bound expected =>
    renderWords (["pick", toString seed.toNat, toString bound] ++ expected.map toString)

/-- Evaluate one golden-vector case. -/
def evaluate : GoldenVectorCase → Except String Bool
  | .compare leftBits rightBits expected =>
    .ok (totalCmp (Float.ofBits leftBits) (Float.ofBits rightBits) == expected)
  | .stream seed label expected =>
    .ok (drawN expected.length (stream seed label) == expected)
  | .sample distribution seed parameterBits expected => do
    let parameters := parameterBits.map (Float.ofBits ·)
    let sampler ← match samplerFor distribution parameters with
      | some sampler => .ok sampler
      | none => .error "unsupported sampler"
    let samples ← sampleN sampler expected.length (stream seed "s")
    .ok (samples.map (·.toBits) == expected)
  | .pick seed bound expected =>
    .ok (pickN expected.length bound (stream seed "s") == expected)

private def valueBits : List UInt64 :=
  [ 0
  , 9223372036854775808
  , 4607182418800017408
  , 4607182418800017409
  , 13830554455654793216
  , 13830554455654793217
  , 4503599627370496
  , 1
  , 4503599627370495
  , 9218868437227405311
  , 18442240474082181119
  , 118622047889322841
  , 9341994084744098649
  , 9094988921128908188
  , 4591870180066957722
  , 4602678819172646912
  , 9218868437227405312
  , 18442240474082181120 ]

private def comparisonCases : List GoldenVectorCase :=
  valueBits.flatMap fun leftBits => valueBits.map fun rightBits =>
    .compare leftBits rightBits
      (totalCmp (Float.ofBits leftBits) (Float.ofBits rightBits))

private def streamInputs : List (UInt64 × String) :=
  [ (0, "a")
  , (42, "t0")
  , (20260702, "b")
  , (18446744073709551615, "a-very-long-component-identifier-with-dashes_and_underscores.0")
  , (7, "src") ]

private def streamCases : List GoldenVectorCase :=
  streamInputs.map fun (seed, label) => .stream seed label (drawN 4 (stream seed label))

private def sampleInputs : List (String × UInt64 × List Float) :=
  [ ("uniform", 1, [2.0, 5.0])
  , ("uniform", 2, [-1.0, 1.0])
  , ("exponential", 3, [0.9])
  , ("exponential", 4, [2.0])
  , ("normal", 5, [0.0, 1.0])
  , ("normal", 6, [3.0, 0.5])
  , ("lognormal", 7, [0.0, 0.25])
  , ("triangular", 8, [0.0, 1.0, 4.0])
  , ("weibull", 9, [1.5, 2.0])
  , ("bernoulli", 10, [0.3])
  , ("geometric", 11, [0.25])
  , ("gamma", 12, [0.5, 2.0])
  , ("gamma", 13, [2.5, 1.5])
  , ("beta", 14, [2.0, 3.0])
  , ("poisson", 15, [4.0])
  , ("poisson", 16, [1200.0])
  , ("binomial", 17, [20.0, 0.3]) ]

private def makeSampleCase (input : String × UInt64 × List Float) : Option GoldenVectorCase := do
  let (distribution, seed, parameters) := input
  let sampler ← samplerFor distribution parameters
  match sampleN sampler 8 (stream seed "s") with
  | .ok samples =>
    some (.sample distribution seed (parameters.map (·.toBits)) (samples.map (·.toBits)))
  | .error _ => none

private def sampleCases : List GoldenVectorCase :=
  sampleInputs.filterMap makeSampleCase

private def pickInputs : List (UInt64 × Nat) := [(21, 3), (22, 7)]

private def pickCases : List GoldenVectorCase :=
  pickInputs.map fun (seed, bound) => .pick seed bound (pickN 8 bound (stream seed "s"))

/-- The 348 fixed cases in committed generation order. -/
def cases : List GoldenVectorCase :=
  comparisonCases ++ streamCases ++ sampleCases ++ pickCases

end Machine
