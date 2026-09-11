import Conformance.Case
import Conformance.CoreCases
import Conformance.DesCases
import Conformance.RoundCases
/-!
# Conformance cases

Paired Lean configurations for envelope-by-envelope trace comparison with a
conforming implementation. The case record type lives in `Conformance.Case`; the cases live
in one module per catalogue module: `Conformance.CoreCases`,
`Conformance.DesCases`, and `Conformance.RoundCases`. `all` concatenates the
per-module lists in catalogue order.
-/

namespace Machine.ConformanceCases

/-- The conformance cases served by the Lean reference machine. -/
def all : List ConformanceCase :=
  core ++ des ++ rounds

end Machine.ConformanceCases
