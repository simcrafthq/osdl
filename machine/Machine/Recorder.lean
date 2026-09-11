import Machine.Types
/-!
# Output recording

Time-weighted summaries, timeseries, and final values use ordered accumulation,
warmup seeding from pre-activation values, a 200 000-sample percentile cap,
and a finite-statistics-only finalization filter.

Everything the recorder consumes is trace-visible (store writes via the
`state.changed` stream, the warmup boundary, and sample instants), so the
results JSON is conceptually a pure fold over the trace; operationally it
runs inside the kernel because `metric.updated` emissions are themselves
trace events.
-/

namespace Machine

inductive OutputKind where
  | summary (stats : List String)
  /-- `interval = none` records on change. -/
  | timeseries (interval : Option Float)
  | final

structure OutputCfg where
  path : String
  name : String
  kind : OutputKind

instance : Inhabited OutputKind := ⟨.final⟩
instance : Inhabited OutputCfg := ⟨{ path := "", name := "", kind := .final }⟩

private def sampleCap : Nat := 200000

structure SummaryAcc where
  last : Option Float := none
  lastT : Float := 0.0
  t0 : Float := 0.0
  wsum : Float := 0.0
  w2sum : Float := 0.0
  min : Float := 0.0
  max : Float := 0.0
  count : Nat := 0
  sum : Float := 0.0
  samples : Array Float := #[]

namespace SummaryAcc

def observe (a : SummaryAcc) (t v : Float) : SummaryAcc :=
  let a := match a.last with
    | some lv =>
      let dt := t - a.lastT
      { a with wsum := a.wsum + lv * dt, w2sum := a.w2sum + lv * lv * dt }
    | none => a
  { a with
    last := some v
    lastT := t
    min := Min.min a.min v
    max := Max.max a.max v
    count := a.count + 1
    sum := a.sum + v
    samples := if a.samples.size < sampleCap then a.samples.push v else a.samples }

def reset (t : Float) (current : Option Float) : SummaryAcc :=
  let a : SummaryAcc := { t0 := t, lastT := t, min := 1.0 / 0.0, max := -(1.0 / 0.0) }
  match current with
  | some v => a.observe t v
  | none => a

def percentile (a : SummaryAcc) (q : Float) : Option Float :=
  if a.samples.isEmpty then none
  else
    let s := a.samples.qsort totalLt
    let idx := ((q / 100.0) * Float.ofNat (s.size - 1)).round.toUInt64.toNat
    some s[Nat.min idx (s.size - 1)]!

/-- Parse the `q` of a `p{q}` percentile stat: digits with an optional
fraction (the engine accepts any `f64` here; percentile names in practice
are decimal). -/
private def parseQ (s : String) : Option Float :=
  let cs := s.toList
  if cs.isEmpty || !cs.all (fun c => c.isDigit || c == '.') then none
  else if cs.count '.' > 1 then none
  else
    let (intDs, rest) := (cs.takeWhile Char.isDigit, cs.dropWhile Char.isDigit)
    let fracDs := match rest with
      | '.' :: f => f
      | _ => []
    let mantissa := (intDs ++ fracDs).foldl (fun n c => n * 10 + (c.toNat - '0'.toNat)) 0
    some (Float.ofScientific mantissa true fracDs.length)

def stat (a : SummaryAcc) (name : String) (tEnd : Float) : Option Float :=
  let total := tEnd - a.t0
  let (wsum, w2sum) := match a.last with
    | some lv =>
      let dt := tEnd - a.lastT
      (a.wsum + lv * dt, a.w2sum + lv * lv * dt)
    | none => (a.wsum, a.w2sum)
  let mean := if total > 0.0 then wsum / total else a.last.getD (0.0 / 0.0)
  match name with
  | "mean" => some mean
  | "std" =>
    let var := if total > 0.0 then Max.max (w2sum / total - mean * mean) 0.0 else 0.0
    some var.sqrt
  | "min" => some a.min
  | "max" => some a.max
  | "count" => some (Float.ofNat a.count)
  | "sum" => some a.sum
  | "last" => a.last
  | "median" => a.percentile 50.0
  | p =>
    if p.startsWith "p" then
      (parseQ (p.drop 1).toString).bind a.percentile
    else none

end SummaryAcc

inductive Recording where
  | summary (path name : String) (statistics : List String) (state : SummaryAcc)
  | timeseries (path name : String) (interval : Option Float)
      (times values : Array Float)
  | final (path name : String) (value : Option Float)

structure Recorder where
  entries : Array Recording
  active : Bool := false
  /-- Latest value seen per tracked path before activation (warmup). -/
  pre : List (String × Float) := []

namespace Recorder

def new (outputs : List OutputCfg) : Recorder :=
  { entries := outputs.toArray.map fun cfg =>
      match cfg.kind with
      | .summary statistics => .summary cfg.path cfg.name statistics {}
      | .timeseries interval => .timeseries cfg.path cfg.name interval #[] #[]
      | .final => .final cfg.path cfg.name none }

/-- Outputs that need interval sampling: `(index, interval)`. -/
def intervalOutputs (r : Recorder) : List (Nat × Float) :=
  r.entries.toList.zipIdx.filterMap fun (entry, i) =>
    match entry with
    | .timeseries _ _ (some iv) _ _ => some (i, iv)
    | _ => none

/-- Start recording (at `t = warmup`), seeding summaries with current values. -/
def activate (r : Recorder) (t : Float) (readState : String → Option Float) : Recorder :=
  let entries := r.entries.map fun entry =>
    match entry with
    | .summary path name statistics _ =>
      let current := (readState path).orElse fun _ => r.pre.lookup path
      .summary path name statistics (SummaryAcc.reset t current)
    | .timeseries path name interval times values =>
      let current := (readState path).orElse fun _ => r.pre.lookup path
      match interval, current with
      | none, some v => .timeseries path name interval (times.push t) (values.push v)
      | _, _ => .timeseries path name interval times values
    | .final path name _ =>
      let current := (readState path).orElse fun _ => r.pre.lookup path
      .final path name current
  { r with entries, active := true }

/-- A store value changed. Returns `metric.updated` emissions `(name, value)`. -/
def onChange (r : Recorder) (path : String) (v t : Float) :
    Recorder × List (String × Float) :=
  let tracked := r.entries.any fun entry =>
    match entry with
    | .summary entryPath _ _ _
    | .timeseries entryPath _ _ _ _
    | .final entryPath _ _ => entryPath == path
  if !tracked then (r, [])
  else if !r.active then
    ({ r with pre := (path, v) :: (r.pre.filter (·.1 != path)) }, [])
  else
    let (entries, out) := r.entries.foldl (init := (#[], [])) fun (entries, out) entry =>
      match entry with
      | .summary entryPath name statistics state =>
        if entryPath == path then
          (entries.push (.summary entryPath name statistics (state.observe t v)),
           out ++ [(name, v)])
        else (entries.push entry, out)
      | .timeseries entryPath name interval times values =>
        if entryPath == path && interval.isNone then
          (entries.push (.timeseries entryPath name interval (times.push t) (values.push v)),
           out ++ [(name, v)])
        else (entries.push entry, out)
      | .final entryPath name _ =>
        if entryPath == path then
          (entries.push (.final entryPath name (some v)), out)
        else (entries.push entry, out)
    ({ r with entries }, out)

/-- Interval sample for output `idx`: emissions and the reschedule interval. -/
def sample (r : Recorder) (idx : Nat) (readState : String → Option Float) (t : Float) :
    Recorder × List (String × Float) × Option Float :=
  match r.entries[idx]? with
  | some (.timeseries path name (some iv) times values) =>
    match readState path with
    | some v =>
      let entry := .timeseries path name (some iv) (times.push t) (values.push v)
      ({ r with entries := r.entries.set! idx entry }, [(name, v)], some iv)
    | none => (r, [], some iv)
  | _ => (r, [], none)

/-- The output name, recorder kind, and recorder result for the results JSON. -/
private def finalizedEntry (entry : Recording) (tEnd : Float) : String × String × JsonValue :=
  match entry with
  | .summary _ name statistics state =>
    let requested := statistics ++ (["last", "count"].filter (!statistics.contains ·))
    let m := requested.filterMap fun s =>
      match state.stat s tEnd with
      | some v => if v.isFinite then some (s, JsonValue.float v) else none
      | none => none
    (name, "summary", .obj [("stats", .obj m)])
  | .timeseries _ name _ times values =>
    (name, "timeseries", .obj
      [ ("times", .arr (times.toList.map .float))
      , ("values", .arr (values.toList.map .float)) ])
  | .final _ name value =>
    (name, "final", .obj
      [ ("value", match value with | some x => .float x | none => .null) ])

/-- The outputs object for the results JSON, grouped by declared output name. -/
def finalize (r : Recorder) (tEnd : Float) : JsonValue :=
  let grouped := r.entries.toList.foldl (init := []) fun groups entry =>
    let (name, kind, result) := finalizedEntry entry tEnd
    if groups.any (fun group => group.1 == name) then
      groups.map fun group =>
        if group.1 == name then (group.1, group.2 ++ [(kind, result)]) else group
    else groups ++ [(name, [(kind, result)])]
  .obj <| grouped.map fun group =>
    (group.1, .obj group.2)

end Recorder

end Machine
