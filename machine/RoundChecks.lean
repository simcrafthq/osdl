import Conformance
/-!
Machine-side checks for the resolution-round discipline run over the
`roundtick` conformance case's trace. They verify contention grants
(`min(requested, balance)` in participant order), all-or-nothing withdrawal,
snapshot isolation, one commit per round, and interval re-arming. Usage:
`lake exe roundcheck`; exits nonzero on any failure. External engine
conformance may separately compare an engine trace with this case.
-/

open Machine

def field (j : JsonValue) (k : String) : JsonValue :=
  match j with
  | .obj fs => (fs.lookup k).getD .null
  | _ => .null

/-- `(time, type, source, payload)` rows for events of interest. -/
def rows (trace : Array JsonValue) : List (String × String × String × JsonValue) :=
  trace.toList.filterMap fun e =>
    let ty := (field e "type").render
    if ty == "\"state.changed\"" || ty == "\"round.read\"" || ty == "\"round.harvest\""
        || ty == "\"round.noise\"" then
      some ((field e "time").render, (field e "type").render,
            (field e "source").render, field e "payload")
    else none

def expected : List (String × String × String × String) :=
  [ -- t=0: commits (sorted keys), then surviving emissions in proposal order.
    ("0.0", "\"state.changed\"", "\"field\"", "{\"path\":\"field.stock\",\"value\":2.0}")
  , ("0.0", "\"state.changed\"", "\"harvest-a\"", "{\"path\":\"harvest-a.stash\",\"value\":3.0}")
  , ("0.0", "\"state.changed\"", "\"harvest-b\"", "{\"path\":\"harvest-b.stash\",\"value\":4.0}")
  , ("0.0", "\"round.read\"", "\"reader\"", "{\"value\":null,\"bonus\":2.0,\"time\":0.0,\"balance\":5,\"random\":\"2074134861973389515\",\"sampled\":4.39570634356572753631553496234118938446044921875}")
  , ("0.0", "\"round.harvest\"", "\"harvest-a\"", "{\"granted\":3}")
  , ("0.0", "\"round.harvest\"", "\"harvest-b\"", "{\"granted\":4}")
    -- t=1: the frozen read sees the previous commit (2), not this round's
    -- rain; contention reduces the balance to zero.
  , ("1.0", "\"state.changed\"", "\"field\"", "{\"path\":\"field.stock\",\"value\":0.0}")
  , ("1.0", "\"state.changed\"", "\"harvest-a\"", "{\"path\":\"harvest-a.stash\",\"value\":6.0}")
  , ("1.0", "\"state.changed\"", "\"harvest-b\"", "{\"path\":\"harvest-b.stash\",\"value\":7.0}")
  , ("1.0", "\"round.read\"", "\"reader\"", "{\"value\":2.0,\"bonus\":2.0,\"time\":1.0,\"balance\":2,\"random\":\"14051751459229557887\",\"sampled\":4.13328036915508079118808382190763950347900390625}")
  , ("1.0", "\"round.harvest\"", "\"harvest-a\"", "{\"granted\":3}")
  , ("1.0", "\"round.harvest\"", "\"harvest-b\"", "{\"granted\":3}") ]

def main : IO UInt32 := do
  let trace ← match Machine.runTrace ConformanceCases.roundtick with
    | .ok trace => pure trace
    | .error error =>
      IO.eprintln s!"roundtick failed preparation: {error.message}"
      return 1
  let got := rows trace
  let want := expected.map fun (t, ty, src, p) => (t, ty, src, p)
  let gotR := got.map fun (t, ty, src, p) => (t, ty, src, p.render)
  let mut failures := 0
  if gotR.length != want.length then
    IO.eprintln s!"roundtick: expected {want.length} rows, got {gotR.length}"
    failures := failures + 1
  for (g, w) in gotR.zip want do
    if g != w then
      IO.eprintln s!"roundtick mismatch:\n  got  {g}\n  want {w}"
      failures := failures + 1
  -- The aborted participant's emission must not survive.
  if gotR.any (fun (_, ty, _, _) => ty == "\"round.noise\"") then
    IO.eprintln "roundtick: aborted participant's emission leaked"
    failures := failures + 1
  IO.println s!"round checks: {want.length} rows, {failures} failed"
  return if failures == 0 then 0 else 1
