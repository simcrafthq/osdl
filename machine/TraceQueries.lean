import Machine
/-!
# Trace queries

Structured helpers over trace envelopes for the check executables. Every
helper reads the envelope object fields (`type`, `payload`) instead of
searching rendered JSON text, so checks assert on event structure rather
than substrings.
-/

namespace Machine.TraceQueries

/-- The `type` field of a trace envelope, if present. -/
def envelopeType (envelope : JsonValue) : Option String :=
  match envelope with
  | .obj fields =>
    match fields.lookup "type" with
    | some (.str eventType) => some eventType
    | _ => none
  | _ => none

/-- Whether the envelope's `type` field equals `eventType`. -/
def hasType (envelope : JsonValue) (eventType : String) : Bool :=
  envelopeType envelope == some eventType

/-- The `payload` field of a trace envelope, if present. -/
def envelopePayload (envelope : JsonValue) : Option JsonValue :=
  match envelope with
  | .obj fields => fields.lookup "payload"
  | _ => none

/-- The payloads of the envelopes with the given event type, in trace order. -/
def eventsOfType (trace : Array JsonValue) (eventType : String) : List JsonValue :=
  trace.toList.filterMap fun envelope =>
    if hasType envelope eventType then envelopePayload envelope else none

/-- The number of envelopes with the given event type. -/
def countEvents (trace : Array JsonValue) (eventType : String) : Nat :=
  trace.foldl (init := 0) fun count envelope =>
    if hasType envelope eventType then count + 1 else count

/-- The subsequence of envelope types drawn from `types`, in trace order. -/
def eventTypeOrder (trace : Array JsonValue) (types : List String) : List String :=
  trace.toList.filterMap fun envelope =>
    match envelopeType envelope with
    | some eventType => if types.contains eventType then some eventType else none
    | none => none

/-- The index of the first envelope with the given event type, if any. -/
def firstIndexOfType? (trace : Array JsonValue) (eventType : String) : Option Nat :=
  trace.findIdx? (hasType · eventType)

/-- The named field of a payload object, if present. -/
def payloadField (payload : JsonValue) (name : String) : Option JsonValue :=
  match payload with
  | .obj fields => fields.lookup name
  | _ => none

/-- The named payload field as a string, if present. -/
def stringField (payload : JsonValue) (name : String) : Option String :=
  match payloadField payload name with
  | some (.str value) => some value
  | _ => none

end Machine.TraceQueries
