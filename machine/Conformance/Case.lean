import Machine
/-!
# Conformance case shape

The catalogue record type and the shared run metadata used by every
conformance case module.
-/

namespace Machine

/-- The input artifact a conformance case runs from. -/
inductive ConformanceInput where
  | osdl (path : String)
  | machine (behavior : String)

/-- One catalogue entry: identity, purpose, module, input, and the paired
Lean configuration. -/
structure ConformanceCase : Type 1 where
  id : String
  purpose : String
  module : String
  input : ConformanceInput
  configuration : RunConfiguration

end Machine

namespace Machine.ConformanceCases

/-- The run metadata attached to every conformance case configuration. -/
def conformanceCaseMetadata : JsonValue :=
  .obj [("experiment", .str "workload"), ("replication", .nat 1), ("scenario", .nat 0)]

end Machine.ConformanceCases
