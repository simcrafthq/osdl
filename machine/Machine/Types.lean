import Machine.Time
import Lean.Data.Json
/-!
# Wire-level records

Entities, connections, typed identifiers, run statuses, structured
diagnostics, and the JSON values the trace is made of. `JsonValue`
is a minimal JSON tree whose renderer emits floats as exact decimals
(`floatToDecimal` below), so the trace round-trips bit-for-bit through any
correctly-rounded parser.
-/

namespace Machine

/--
Exact decimal rendering of a finite float.

Decomposes the bit pattern into sign, mantissa `m`, and binary exponent `e`
(value = ±m·2^e) and renders the exact decimal digits via `Nat` arithmetic:
for `e ≥ 0` the value is the integer `m·2^e`; for `e < 0` it is `m·5^(-e)`
shifted `-e` decimal places. Trailing zeros of the fraction are trimmed
(value-preserving). A finite binary64 always has a finite decimal expansion,
and an exact expansion parses back to the identical bit pattern in any
correctly-rounded reader, so traces compare bit-for-bit without a shortest-
representation algorithm. Callers guarantee finiteness.
-/
def floatToDecimal (f : Float) : String :=
  let b := f.toBits
  let sign := b >>> 63 == 1
  let expBits := ((b >>> 52) &&& 0x7ff).toNat
  let frac := (b &&& 0xfffffffffffff).toNat
  let s := if sign then "-" else ""
  if expBits == 0x7ff then
    -- Never reached from the machine: calendar time is finite by construction
    -- and payload floats are guarded at emission.
    if frac == 0 then s ++ "1e999" else "null"
  else
    let m : Nat := if expBits == 0 then frac else frac + (1 <<< 52)
    let e : Int := if expBits == 0 then -1074 else (expBits : Int) - 1075
    if m == 0 then
      s ++ "0.0"
    else if e ≥ 0 then
      s ++ toString (m * 2 ^ e.toNat) ++ ".0"
    else
      let k := (-e).toNat
      let digits := (toString (m * 5 ^ k)).toList
      let digits :=
        if digits.length ≤ k then List.replicate (k + 1 - digits.length) '0' ++ digits
        else digits
      let intPart := digits.take (digits.length - k)
      let fracPart := (digits.drop (digits.length - k)).reverse.dropWhile (· == '0') |>.reverse
      let fracPart := if fracPart.isEmpty then ['0'] else fracPart
      s ++ String.ofList intPart ++ "." ++ String.ofList fracPart

/-- Format simulation time, rendering an integral value without a fraction. -/
def displayTime (time : Time) : String :=
  if time == time.floor then toString time.toUInt64 else floatToDecimal time

/-- A minimal JSON value for envelopes and payloads. -/
inductive JsonValue where
  | null
  | bool (b : Bool)
  | nat (n : Nat)
  | int (i : Int)
  | float (f : Float)
  | str (s : String)
  | arr (xs : List JsonValue)
  | obj (fields : List (String × JsonValue))
deriving Inhabited

namespace JsonValue

partial def render : JsonValue → String
  | .null => "null"
  | .bool b => if b then "true" else "false"
  | .nat n => toString n
  | .int i => toString i
  | .float f => floatToDecimal f
  | .str s => Lean.Json.renderString s
  | .arr xs => "[" ++ String.intercalate "," (xs.map render) ++ "]"
  | .obj fields => "{" ++ String.intercalate "," (fields.map fun (key, value) =>
      Lean.Json.renderString key ++ ":" ++ value.render) ++ "}"

end JsonValue

/-- A typed scalar observable state value. Absence is an absent observation,
never a published null. -/
inductive StateValue where
  | number (value : Float)
  | integer (value : Int)
  | boolean (value : Bool)
  | string (value : String)
deriving Inhabited

namespace StateValue

/-- Numeric coercion for expressions and recorded outputs: integers widen,
booleans coerce to `1`/`0`, strings do not coerce. -/
def asFloat : StateValue → Option Float
  | .number value => some value
  | .integer value => some (Float.ofInt value)
  | .boolean value => some (if value then 1.0 else 0.0)
  | .string _ => none

def toJson : StateValue → JsonValue
  | .number value => .float value
  | .integer value => .int value
  | .boolean value => .bool value
  | .string value => .str value

/-- Change detection for store writes. Numbers compare under IEEE `==`, so a
NaN write always changes and `-0.0 → 0.0` does not. A kind change always
changes. -/
def unchanged : StateValue → StateValue → Bool
  | .number left, .number right => left == right
  | .integer left, .integer right => left == right
  | .boolean left, .boolean right => left == right
  | .string left, .string right => left == right
  | _, _ => false

end StateValue

/-- An entity flowing through connections. `name` is `"{entityType}#{uid}"`. -/
structure Entity where
  uid : UInt64
  entityType : String
  agent : Option UInt32
  created : Time
deriving Inhabited

def Entity.name (entity : Entity) : String :=
  s!"{entity.entityType}#{entity.uid}"

/-- A connection joins `src = (component index, out port)` to `dst = (component index, in port)`. -/
structure Connection where
  src : Nat × String
  dst : Nat × String
deriving Inhabited

/-- A prepared route handle for one connection leaving an output port. Issued
by the machine; component behavior does not inspect the index. -/
structure Route where
  /-- Interpreter-owned connection index. -/
  index : Nat
deriving Inhabited, BEq

/-- A component-scoped timer identifier returned by `scheduleAfter` and
`scheduleAt`. -/
structure TimerId where
  value : UInt64
deriving Inhabited, BEq

/-- One admitted external input: an immutable run-owned snapshot. The
admission ordinal is the record's index in the transcript; the calendar entry
that dispatches the record carries the ordinal and the admission time.
Rejected input never becomes a record. -/
structure ExternalInputRecord where
  componentIndex : Nat
  port : String
  payload : JsonValue
deriving Inhabited

/-- Why a run completed normally. -/
inductive CompletionReason where
  | endTime
  | condition
  | requested
  | quiescent
deriving BEq

def CompletionReason.render : CompletionReason → String
  | .endTime => "endTime"
  | .condition => "condition"
  | .requested => "requested"
  | .quiescent => "quiescent"

/-- Why a run was aborted by the host or by implementation policy. -/
inductive AbortReason where
  | budgetExceeded
  | cancelled
deriving BEq

def AbortReason.render : AbortReason → String
  | .budgetExceeded => "budgetExceeded"
  | .cancelled => "cancelled"

/-- The stable code classifying a diagnostic. -/
inductive DiagnosticCode where
  /-- A kernel operation violated a runtime contract. -/
  | kernelRuntime
  /-- A component reaction or portable component operation failed. -/
  | componentFailure
  /-- Expression evaluation failed. -/
  | expressionError
deriving BEq, Inhabited

/-- The wire string of a diagnostic code. -/
def DiagnosticCode.render : DiagnosticCode → String
  | .kernelRuntime => "kernel.runtime"
  | .componentFailure => "component.failure"
  | .expressionError => "expression.error"

/-- A structured diagnostic with a stable code. -/
structure Diagnostic where
  code : DiagnosticCode
  message : String
  /-- Component id when the diagnostic is attributed to a component. -/
  source : Option String := none
  /-- The component runtime operation name (`start`, `handle`, `receive`,
  `finish`) when the diagnostic arose inside a reaction. -/
  operation : Option String := none
  time : Time := 0.0

namespace Diagnostic

def toJson (diagnostic : Diagnostic) : JsonValue :=
  .obj <| [("code", JsonValue.str diagnostic.code.render), ("message", .str diagnostic.message)]
    ++ (match diagnostic.source with
        | some source => [("source", JsonValue.str source)]
        | none => [])
    ++ (match diagnostic.operation with
        | some operation => [("operation", JsonValue.str operation)]
        | none => [])
    ++ [("time", .float diagnostic.time)]

/-- A kernel operation violated a runtime contract. -/
def runtime (message : String) : Diagnostic :=
  { code := .kernelRuntime, message }

/-- A component reaction or portable component operation failed. -/
def component (message : String) : Diagnostic :=
  { code := .componentFailure, message }

/-- Expression evaluation failure. -/
def expr (message : String) : Diagnostic :=
  { code := .expressionError, message }

end Diagnostic

/-- The status of one terminal run. -/
inductive RunStatus where
  | completed (reason : CompletionReason)
  | failed (diagnostic : Diagnostic)
  | aborted (reason : AbortReason)

def RunStatus.render : RunStatus → String
  | .completed _ => "completed"
  | .failed _ => "failed"
  | .aborted _ => "aborted"

end Machine
