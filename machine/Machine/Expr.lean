import Machine.Types
/-!
# The expression language

Parser and total evaluator for the OSDL expression language. The grammar
defines precedence from logical disjunction down to primary expressions.
Identifiers admit `-`, so `a-b` is one identifier while `a - b` is a
subtraction. The constants `true`, `false`, `pi`, and `e` are substituted at
parse time. Chained comparisons become adjacent short-circuit conjunctions.
`if` evaluates only its selected branch. Division or modulo by zero and
non-finite results from `pow`, `sqrt`, `exp`, `ln`, `log10`, `min`, or `max`
produce errors.

The parser and evaluator recurse on explicit fuel. Evaluation permits 512
nested expression steps before reporting `expression nesting too deep`.
-/

namespace Machine

namespace Expr

inductive UnOp where
  | neg
  | not

inductive BOp where
  | add | sub | mul | div | mod | pow
  | lt | le | gt | ge | eq | ne
  | land | lor

inductive Ast where
  | num (v : Float)
  | ref (path : List String)
  | unary (op : UnOp) (e : Ast)
  | binary (op : BOp) (l r : Ast)
  | call (name : String) (args : List Ast)

instance : Inhabited Ast := ⟨.num 0.0⟩

/-! ## Lexer -/

inductive Tok where
  | num (v : Float)
  | ident (s : String)
  | punct (s : String)
deriving BEq, Repr

private def isIdentStart (c : Char) : Bool :=
  c.isAlpha || c == '_'

/-- Continue an identifier with an alphanumeric character, `_`, or `-`. -/
private def isIdentCont (c : Char) : Bool :=
  c.isAlphanum || c == '_' || c == '-'

private def digitsToNat (ds : List Char) : Nat :=
  ds.foldl (fun n c => n * 10 + (c.toNat - '0'.toNat)) 0

/-- Lex digits with an optional fraction and signed exponent into binary64. -/
private def lexNumber (cs : List Char) : Except String (Float × List Char) := do
  let (intDs, cs) := List.span Char.isDigit cs
  let (fracDs, cs) :=
    match cs with
    | '.' :: c :: rest =>
      if c.isDigit then
        let (ds, r) := List.span Char.isDigit (c :: rest)
        (ds, r)
      else ([], '.' :: c :: rest)
    | other => ([], other)
  let (expVal, cs) ← do
    match cs with
    | e :: rest =>
      if e == 'e' || e == 'E' then
        let (sign, rest') :=
          match rest with
          | '-' :: r => (-1, r)
          | '+' :: r => (1, r)
          | r => (1, r)
        let (eds, r) := List.span Char.isDigit rest'
        if eds.isEmpty then throw "malformed exponent"
        else pure ((sign * (digitsToNat eds : Int) : Int), r)
      else pure ((0 : Int), e :: rest)
    | [] => pure ((0 : Int), [])
  let mantissa := digitsToNat (intDs ++ fracDs)
  let decExp : Int := (fracDs.length : Int) - expVal
  let v :=
    if decExp ≥ 0 then Float.ofScientific mantissa true decExp.toNat
    else Float.ofScientific mantissa false (-decExp).toNat
  pure (v, cs)

private def lex' (fuel : Nat) (cs : List Char) (acc : List Tok) : Except String (List Tok) :=
  match fuel with
  | 0 => throw "expression too long"
  | fuel + 1 =>
    match cs with
    | [] => pure acc.reverse
    | c :: rest =>
      if c == ' ' || c == '\t' || c == '\n' || c == '\r' then
        lex' fuel rest acc
      else if c.isDigit then
        match lexNumber (c :: rest) with
        | .error e => throw e
        | .ok (v, cs') => lex' fuel cs' (.num v :: acc)
      else if isIdentStart c then
        let (tk, cs') := List.span isIdentCont rest
        lex' fuel cs' (.ident (String.ofList (c :: tk)) :: acc)
      else
        match c :: rest with
        | '<' :: '=' :: cs' => lex' fuel cs' (.punct "<=" :: acc)
        | '>' :: '=' :: cs' => lex' fuel cs' (.punct ">=" :: acc)
        | '=' :: '=' :: cs' => lex' fuel cs' (.punct "==" :: acc)
        | '!' :: '=' :: cs' => lex' fuel cs' (.punct "!=" :: acc)
        | '&' :: '&' :: cs' => lex' fuel cs' (.punct "&&" :: acc)
        | '|' :: '|' :: cs' => lex' fuel cs' (.punct "||" :: acc)
        | c' :: cs' =>
          if "+-*/%^<>!(),.".toList.contains c' then
            lex' fuel cs' (.punct (String.singleton c') :: acc)
          else throw s!"unexpected character {String.singleton c'}"
        | [] => pure acc.reverse

private def lex (src : String) : Except String (List Tok) :=
  lex' (src.length * 2 + 8) src.toList []

/-! ## Parser -/

/-- Resolve the four constants substituted during parsing. -/
private def constantValue : String → Option Float
  | "true" => some 1.0
  | "false" => some 0.0
  | "pi" => some 3.141592653589793
  | "e" => some 2.718281828459045
  | _ => none

private def eatPunct (s : String) : List Tok → Option (List Tok)
  | .punct p :: rest => if p == s then some rest else none
  | _ => none

/-- Consume `.` `ident` continuations of a reference path. -/
private def refPath : Nat → List String → List Tok → List String × List Tok
  | 0, acc, ts => (acc.reverse, ts)
  | fuel + 1, acc, ts =>
    match ts with
    | .punct "." :: .ident seg :: rest => refPath fuel (seg :: acc) rest
    | _ => (acc.reverse, ts)

mutual

private def parseOr (fuel : Nat) (ts : List Tok) : Except String (Ast × List Tok) :=
  match fuel with
  | 0 => throw "expression nesting too deep"
  | fuel + 1 => do
    let (l, ts) ← parseAnd fuel ts
    parseOrLoop fuel l ts

private def parseOrLoop (fuel : Nat) (l : Ast) (ts : List Tok) : Except String (Ast × List Tok) :=
  match fuel with
  | 0 => throw "expression nesting too deep"
  | fuel + 1 =>
    match eatPunct "||" ts with
    | some ts => do
      let (r, ts) ← parseAnd fuel ts
      parseOrLoop fuel (.binary .lor l r) ts
    | none => pure (l, ts)

private def parseAnd (fuel : Nat) (ts : List Tok) : Except String (Ast × List Tok) :=
  match fuel with
  | 0 => throw "expression nesting too deep"
  | fuel + 1 => do
    let (l, ts) ← parseCmp fuel ts
    parseAndLoop fuel l ts

private def parseAndLoop (fuel : Nat) (l : Ast) (ts : List Tok) : Except String (Ast × List Tok) :=
  match fuel with
  | 0 => throw "expression nesting too deep"
  | fuel + 1 =>
    match eatPunct "&&" ts with
    | some ts => do
      let (r, ts) ← parseCmp fuel ts
      parseAndLoop fuel (.binary .land l r) ts
    | none => pure (l, ts)

/-- Parse comparison chains such that `a < b < c` becomes
`(a < b) && (b < c)`. -/
private def parseCmp (fuel : Nat) (ts : List Tok) : Except String (Ast × List Tok) :=
  match fuel with
  | 0 => throw "expression nesting too deep"
  | fuel + 1 => do
    let (first, ts) ← parseAdd fuel ts
    parseCmpLoop fuel none first ts

private def parseCmpLoop (fuel : Nat) (out : Option Ast) (prev : Ast) (ts : List Tok) : Except String (Ast × List Tok) :=
  match fuel with
  | 0 => throw "expression nesting too deep"
  | fuel + 1 =>
    let tryOp : Option (BOp × List Tok) :=
      match ts with
      | .punct "<=" :: r => some (.le, r)
      | .punct ">=" :: r => some (.ge, r)
      | .punct "==" :: r => some (.eq, r)
      | .punct "!=" :: r => some (.ne, r)
      | .punct "<" :: r => some (.lt, r)
      | .punct ">" :: r => some (.gt, r)
      | _ => none
    match tryOp with
    | some (op, ts) => do
      let (next, ts) ← parseAdd fuel ts
      let cmp := Ast.binary op prev next
      let out := some (match out with
        | some l => Ast.binary .land l cmp
        | none => cmp)
      parseCmpLoop fuel out next ts
    | none => pure (out.getD prev, ts)

private def parseAdd (fuel : Nat) (ts : List Tok) : Except String (Ast × List Tok) :=
  match fuel with
  | 0 => throw "expression nesting too deep"
  | fuel + 1 => do
    let (l, ts) ← parseMul fuel ts
    parseAddLoop fuel l ts

private def parseAddLoop (fuel : Nat) (l : Ast) (ts : List Tok) : Except String (Ast × List Tok) :=
  match fuel with
  | 0 => throw "expression nesting too deep"
  | fuel + 1 =>
    match ts with
    | .punct "+" :: r => do
      let (rhs, ts) ← parseMul fuel r
      parseAddLoop fuel (.binary .add l rhs) ts
    | .punct "-" :: r => do
      let (rhs, ts) ← parseMul fuel r
      parseAddLoop fuel (.binary .sub l rhs) ts
    | _ => pure (l, ts)

private def parseMul (fuel : Nat) (ts : List Tok) : Except String (Ast × List Tok) :=
  match fuel with
  | 0 => throw "expression nesting too deep"
  | fuel + 1 => do
    let (l, ts) ← parseUnary fuel ts
    parseMulLoop fuel l ts

private def parseMulLoop (fuel : Nat) (l : Ast) (ts : List Tok) : Except String (Ast × List Tok) :=
  match fuel with
  | 0 => throw "expression nesting too deep"
  | fuel + 1 =>
    match ts with
    | .punct "*" :: r => do
      let (rhs, ts) ← parseUnary fuel r
      parseMulLoop fuel (.binary .mul l rhs) ts
    | .punct "/" :: r => do
      let (rhs, ts) ← parseUnary fuel r
      parseMulLoop fuel (.binary .div l rhs) ts
    | .punct "%" :: r => do
      let (rhs, ts) ← parseUnary fuel r
      parseMulLoop fuel (.binary .mod l rhs) ts
    | _ => pure (l, ts)

private def parseUnary (fuel : Nat) (ts : List Tok) : Except String (Ast × List Tok) :=
  match fuel with
  | 0 => throw "expression nesting too deep"
  | fuel + 1 =>
    match ts with
    | .punct "-" :: r => do
      let (e, ts) ← parsePower fuel r
      pure (.unary .neg e, ts)
    | .punct "!" :: r => do
      let (e, ts) ← parsePower fuel r
      pure (.unary .not e, ts)
    | _ => parsePower fuel ts

private def parsePower (fuel : Nat) (ts : List Tok) : Except String (Ast × List Tok) :=
  match fuel with
  | 0 => throw "expression nesting too deep"
  | fuel + 1 => do
    let (base, ts) ← parsePrimary fuel ts
    match eatPunct "^" ts with
    | some r => do
      let (ex, ts) ← parseUnary fuel r
      pure (.binary .pow base ex, ts)
    | none => pure (base, ts)

private def parseArgs (fuel : Nat) (name : String) (acc : List Ast) (ts : List Tok) :
    Except String (List Ast × List Tok) :=
  match fuel with
  | 0 => throw "expression nesting too deep"
  | fuel + 1 => do
    let (a, ts) ← parseOr fuel ts
    match ts with
    | .punct "," :: r => parseArgs fuel name (a :: acc) r
    | .punct ")" :: r => pure ((a :: acc).reverse, r)
    | _ => throw s!"malformed arguments to {name}()"

private def parsePrimary (fuel : Nat) (ts : List Tok) : Except String (Ast × List Tok) :=
  match fuel with
  | 0 => throw "expression nesting too deep"
  | fuel + 1 =>
    match ts with
    | .num v :: r => pure (.num v, r)
    | .punct "(" :: r => do
      let (e, ts) ← parseOr fuel r
      match eatPunct ")" ts with
      | some ts => pure (e, ts)
      | none => throw "expected closing parenthesis"
    | .ident name :: .punct "(" :: r =>
      -- function call: a single identifier followed by `(`
      (match eatPunct ")" r with
      | some ts => pure (.call name [], ts)
      | none => do
        let (as_, ts) ← parseArgs fuel name [] r
        pure (.call name as_, ts))
    | .ident first :: r =>
      let (segs, ts) := refPath fuel [first] r
      match segs, constantValue first with
      | [_], some v => pure (.num v, ts)
      | _, _ => pure (.ref segs, ts)
    | t :: _ => throw s!"unexpected token {reprStr t}"
    | [] => throw "unexpected end of expression"

end

/-! ## Exact IEEE fmod

Lean core has no `Float.mod`; `fmod`'s result is always exactly
representable, so it is computed with exact integer arithmetic on the
operands' mantissas (aligned to a common binary exponent), then converted
back losslessly via `scaleB`.
-/

private def nan : Float := (0.0 : Float) / 0.0

/-- `(sign, mantissa, exponent)` with value `±mantissa · 2^exponent`, exact. -/
private def decomp (f : Float) : Bool × Nat × Int :=
  let b := f.toBits
  let sign := b >>> 63 == 1
  let expBits := ((b >>> 52) &&& 0x7ff).toNat
  let frac := (b &&& 0xfffffffffffff).toNat
  if expBits == 0 then (sign, frac, -1074)
  else (sign, frac + (1 <<< 52), (expBits : Int) - 1075)

private def trailingZeros : Nat → Nat
  | 0 => 0
  | n + 1 =>
    if (n + 1) % 2 == 1 then 0
    else 1 + trailingZeros ((n + 1) / 2)

def fmod (a b : Float) : Float :=
  if a.isNaN || b.isNaN || a.isInf then nan
  else if b.isInf then a
  else if a == 0.0 then a
  else
    let (sa, ma, ea) := decomp a
    let (_, mb, eb) := decomp b
    let e := min ea eb
    let A := ma <<< (ea - e).toNat
    let B := mb <<< (eb - e).toNat
    let r := A % B
    if r == 0 then if sa then -(0.0 : Float) else 0.0
    else
      let t := trailingZeros r
      let mag := (Float.ofNat (r >>> t)).scaleB (e + t)
      if sa then -mag else mag

/-! ## Evaluator -/

/-- Values available while evaluating references and `time()`. -/
structure Ctx where
  resolve : List String → Option Float
  time : Float

private def truthy (x : Float) : Bool := x != 0.0

private def boolF (b : Bool) : Float := if b then 1.0 else 0.0

private def finiteOr (v : Float) (what : String) : Except String Float :=
  if v.isFinite then pure v else throw s!"{what} is undefined here"

/-- Return each built-in function's minimum arity and variadic flag. -/
private def builtinArity : String → Option (Nat × Bool)
  | "abs" | "floor" | "ceil" | "round" | "sqrt" | "exp" | "ln" | "log10"
  | "sin" | "cos" | "tan" => some (1, false)
  | "pow" => some (2, false)
  | "if" => some (3, false)
  | "time" => some (0, false)
  | "min" | "max" => some (1, true)
  | _ => none

private def arityDescribe : Nat × Bool → String
  | (0, false) => "no arguments"
  | (1, false) => "1 argument"
  | (n, false) => s!"{n} arguments"
  | (1, true) => "at least 1 argument"
  | (n, true) => s!"at least {n} arguments"

private def arityAccepts : Nat × Bool → Nat → Bool
  | (n, false), got => got == n
  | (n, true), got => got ≥ n

private def evalAst (ctx : Ctx) : Nat → Ast → Except String Float
  | 0, _ => throw "expression nesting too deep"
  | fuel + 1, ast =>
    match ast with
    | .num v => pure v
    | .ref path =>
      match ctx.resolve path with
      | some v => pure v
      | none => throw s!"unresolved reference \"{String.intercalate "." path}\""
    | .unary op e => do
      let v ← evalAst ctx fuel e
      match op with
      | .neg => pure (-v)
      | .not => pure (if truthy v then 0.0 else 1.0)
    | .binary .land l r => do
      -- Leave the right side unevaluated when the left side is false.
      let a ← evalAst ctx fuel l
      if !truthy a then pure 0.0
      else do
        let b ← evalAst ctx fuel r
        pure (boolF (truthy b))
    | .binary .lor l r => do
      let a ← evalAst ctx fuel l
      if truthy a then pure 1.0
      else do
        let b ← evalAst ctx fuel r
        pure (boolF (truthy b))
    | .binary op l r => do
      let a ← evalAst ctx fuel l
      let b ← evalAst ctx fuel r
      match op with
      | .add => pure (a + b)
      | .sub => pure (a - b)
      | .mul => pure (a * b)
      | .div => if b == 0.0 then throw "division by zero" else pure (a / b)
      | .mod => if b == 0.0 then throw "modulo by zero" else pure (fmod a b)
      | .pow => finiteOr (a.pow b) "pow"
      | .lt => pure (boolF (a < b))
      | .le => pure (boolF (a ≤ b))
      | .gt => pure (boolF (a > b))
      | .ge => pure (boolF (a ≥ b))
      | .eq => pure (boolF (a == b))
      | .ne => pure (boolF (a != b))
      | .land | .lor => throw "unreachable"
    | .call name args => do
      match builtinArity name with
      | none => throw s!"unknown function \"{name}\""
      | some arity =>
        if !arityAccepts arity args.length then
          throw s!"{name}() takes {arityDescribe arity}"
        else if name == "if" then do
          -- Evaluate only the selected branch.
          let c ← evalAst ctx fuel args[0]!
          evalAst ctx fuel (if truthy c then args[1]! else args[2]!)
        else if name == "time" then
          pure ctx.time
        else do
          let vs ← args.mapM (evalAst ctx fuel)
          match name, vs with
          | "abs", [x] => pure x.abs
          | "floor", [x] => pure x.floor
          | "ceil", [x] => pure x.ceil
          | "round", [x] => pure x.round
          | "sqrt", [x] => finiteOr x.sqrt "sqrt"
          | "exp", [x] => finiteOr x.exp "exp"
          | "ln", [x] => finiteOr x.log "ln"
          | "log10", [x] => finiteOr x.log10 "log10"
          | "sin", [x] => pure x.sin
          | "cos", [x] => pure x.cos
          | "tan", [x] => pure x.tan
          | "pow", [x, y] => finiteOr (x.pow y) "pow"
          | "min", xs => do
            for x in xs do _ ← finiteOr x "min"
            pure (xs.foldl min (1.0 / 0.0))
          | "max", xs => do
            for x in xs do _ ← finiteOr x "max"
            pure (xs.foldl max (-(1.0 / 0.0)))
          | _, _ => throw s!"unknown function \"{name}\""

end Expr

/-- A parsed expression. -/
structure Expr where
  src : String
  ast : Expr.Ast

namespace Expr

instance : Inhabited Machine.Expr := ⟨{ src := "", ast := .num 0.0 }⟩

def parse (src : String) : Except String Expr := do
  let toks ← lex src
  let (ast, rest) ← parseOr (toks.length * 2 + 16) toks
  if rest.isEmpty then pure { src, ast }
  else throw s!"unexpected trailing tokens in {src}"

/-- Parse a known-valid expression while authoring a conformance case. -/
def parse! (src : String) : Expr :=
  match parse src with
  | .ok e => e
  | .error msg => panic! s!"Expr.parse! {src}: {msg}"

/-- Evaluate with a 512-step nesting limit and format failures as
`{message} in "{source}"`. -/
def eval (e : Expr) (ctx : Ctx) : Except String Float :=
  match evalAst ctx 513 e.ast with
  | .ok v => .ok v
  | .error msg => .error s!"{msg} in \"{e.src}\""

end Expr

end Machine
