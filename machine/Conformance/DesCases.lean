import Conformance.Case
/-!
# DES conformance cases

Cases for module `des@0.1.0`: source, queue, server, delay, router, and
sink behaviors, queue disciplines, routing policies, recorders, and
exponential sampling. Each configuration is followed by its catalogue
record; `des` lists the records in catalogue order.
-/

namespace Machine.ConformanceCases

open Machine

/-! ## despipe -/

def despipe : RunConfiguration where
  modelName := "despipe"
  componentIds := #["src", "q", "srv", "snk"]
  components := #[ Des.source { interarrival := .lit 1.0, entityType := "src", limit := some 4 }
            , Des.queue { capacity := some 2 }
            , Des.server { serviceTime := .lit 1.5 }
            , Des.sink ]
  connections := #[ ⟨(0, "out"), (1, "in")⟩, ⟨(1, "out"), (2, "in")⟩, ⟨(2, "out"), (3, "in")⟩ ]
  duration := 12.0
  seed := 5
  runMetadata := conformanceCaseMetadata

def despipeCase : ConformanceCase where
  id := "despipe"
  purpose := "Checks DES source, queue, server, and sink flow."
  module := "des@0.1.0"
  input := .osdl "libraries/des/conformance/cases/pipeline.osdl.json"
  configuration := despipe

/-! ## desroute -/

def desroute : RunConfiguration where
  modelName := "desroute"
  componentIds := #["src", "rt", "q1", "q2", "s1", "s2"]
  components := #[ Des.source { interarrival := .lit 1.0, entityType := "src", limit := some 4 }
            , Des.router {
                policy := .shortestQueue
                targetLengthPaths := ["q1.length", "q2.length"] }
            , Des.queue {}, Des.queue {}
            , Des.sink, Des.sink ]
  connections := #[ ⟨(0, "out"), (1, "in")⟩
            , ⟨(1, "out"), (2, "in")⟩, ⟨(1, "out"), (3, "in")⟩
            , ⟨(2, "out"), (4, "in")⟩, ⟨(3, "out"), (5, "in")⟩ ]
  duration := 10.0
  seed := 6
  runMetadata := conformanceCaseMetadata

def desrouteCase : ConformanceCase where
  id := "desroute"
  purpose := "Checks shortest-queue routing between two queues."
  module := "des@0.1.0"
  input := .machine "desroute"
  configuration := desroute

/-! ## desstats -/

def desstats : RunConfiguration where
  modelName := "desstats"
  componentIds := #["src", "q", "srv", "snk"]
  components := #[ Des.source { interarrival := .lit 1.0, entityType := "src", limit := some 4 }
            , Des.queue { capacity := some 2 }
            , Des.server { serviceTime := .lit 1.5 }
            , Des.sink ]
  connections := #[ ⟨(0, "out"), (1, "in")⟩, ⟨(1, "out"), (2, "in")⟩, ⟨(2, "out"), (3, "in")⟩ ]
  duration := 12.0
  seed := 5
  runMetadata := conformanceCaseMetadata
  warmup := 2.0
  outputs :=
    [ { path := "q.length", name := "q.length",
        kind := .summary
          ["mean", "std", "min", "max", "median", "p5", "p25",
           "p75", "p90", "p95", "p99", "count", "sum", "last"] }
    , { path := "srv.busy", name := "busy", kind := .timeseries none }
    , { path := "srv.busy", name := "busy", kind := .summary ["mean"] }
    , { path := "q.length", name := "qlen2", kind := .timeseries (some 2.0) }
    , { path := "q.length", name := "qlen2", kind := .summary ["mean"] }
    , { path := "snk.count", name := "snk.count", kind := .final } ]

def desstatsCase : ConformanceCase where
  id := "desstats"
  purpose := "Checks DES recorders, warmup, and summary statistics."
  module := "des@0.1.0"
  input := .osdl "libraries/des/conformance/cases/recorders.osdl.json"
  configuration := desstats

/-! ## desexp -/

def desexp : RunConfiguration where
  modelName := "desexp"
  componentIds := #["src", "q", "srv", "rt", "s1", "s2"]
  components := #[ Des.source { interarrival := .exponential 0.9, entityType := "src", limit := some 6 }
            , Des.queue {}
            , Des.server { serviceTime := .exponential 1.25 }
            , Des.router { policy := .random }
            , Des.sink, Des.sink ]
  connections := #[ ⟨(0, "out"), (1, "in")⟩, ⟨(1, "out"), (2, "in")⟩, ⟨(2, "out"), (3, "in")⟩
            , ⟨(3, "out"), (4, "in")⟩, ⟨(3, "out"), (5, "in")⟩ ]
  duration := 20.0
  seed := 12
  runMetadata := conformanceCaseMetadata

def desexpCase : ConformanceCase where
  id := "desexp"
  purpose := "Checks exponential durations and random routing."
  module := "des@0.1.0"
  input := .machine "desexp"
  configuration := desexp

/-! ## despri: priority queue discipline

A busy server holds the queue head while later entities enter with larger
`time()` priorities. Higher priority leaves first; equal priorities preserve
insertion order because insertion only skips existing entries with equal
priority. -/

def despri : RunConfiguration where
  modelName := "despri"
  componentIds := #["src", "q", "srv", "snk"]
  components := #[ Des.source { interarrival := .lit 0.25, entityType := "src", limit := some 4 }
            , Des.queue { discipline := .priority (Expr.parse! "time()") }
            , Des.server { serviceTime := .lit 1.0 }
            , Des.sink ]
  connections := #[ ⟨(0, "out"), (1, "in")⟩, ⟨(1, "out"), (2, "in")⟩, ⟨(2, "out"), (3, "in")⟩ ]
  duration := 8.0
  seed := 21
  runMetadata := conformanceCaseMetadata

def despriCase : ConformanceCase where
  id := "despri"
  purpose := "Checks priority queue ordering and stable equal priorities."
  module := "des@0.1.0"
  input := .machine "despri"
  configuration := despri

/-! ## descond: conditional router policy

Conditions are evaluated in route order. The first true condition wins. If
none is true, the last route is used. -/

def descond : RunConfiguration where
  modelName := "descond"
  componentIds := #["src", "rt", "s1", "s2", "s3"]
  components := #[ Des.source { interarrival := .lit 1.0, entityType := "src", limit := some 4 }
            , Des.router { policy := .conditional [ Expr.parse! "time() < 2.5"
                                                   , Expr.parse! "0"
                                                   , Expr.parse! "time() < 3.5" ] }
            , Des.sink, Des.sink, Des.sink ]
  connections := #[ ⟨(0, "out"), (1, "in")⟩
            , ⟨(1, "out"), (2, "in")⟩
            , ⟨(1, "out"), (3, "in")⟩
            , ⟨(1, "out"), (4, "in")⟩ ]
  duration := 8.0
  seed := 22
  runMetadata := conformanceCaseMetadata

def descondCase : ConformanceCase where
  id := "descond"
  purpose := "Checks conditional routing and fallback selection."
  module := "des@0.1.0"
  input := .machine "descond"
  configuration := descond

/-! ## desweight: weighted random router policy

The random router uses a single pinned uniform draw over explicit weights,
with the same draw stream as other router randomness. -/

def desweight : RunConfiguration where
  modelName := "desweight"
  componentIds := #["src", "rt", "s1", "s2", "s3"]
  components := #[ Des.source { interarrival := .lit 0.25, entityType := "src", limit := some 8 }
            , Des.router { policy := .weightedRandom [1.0, 3.0, 2.0] }
            , Des.sink, Des.sink, Des.sink ]
  connections := #[ ⟨(0, "out"), (1, "in")⟩
            , ⟨(1, "out"), (2, "in")⟩
            , ⟨(1, "out"), (3, "in")⟩
            , ⟨(1, "out"), (4, "in")⟩ ]
  duration := 8.0
  seed := 23
  runMetadata := conformanceCaseMetadata

def desweightCase : ConformanceCase where
  id := "desweight"
  purpose := "Checks weighted random routing."
  module := "des@0.1.0"
  input := .machine "desweight"
  configuration := desweight

/-! ## desmodes -/

def desmodes : RunConfiguration where
  modelName := "desmodes"
  componentIds := #["src", "q", "srv", "dly", "rt", "s1", "s2"]
  components := #[
      Des.source { interarrival := .lit 0.1, entityType := "src", limit := some 6 }
    , Des.queue { discipline := .lifo }
    , Des.server { serviceTime := .lit 1.0, capacity := 2.0 }
    , Des.delay { duration := .lit 0.25 }
    , Des.router { policy := .roundRobin }
    , Des.sink
    , Des.sink ]
  connections := #[
      ⟨(0, "out"), (1, "in")⟩
    , ⟨(1, "out"), (2, "in")⟩
    , ⟨(2, "out"), (3, "in")⟩
    , ⟨(3, "out"), (4, "in")⟩
    , ⟨(4, "out"), (5, "in")⟩
    , ⟨(4, "out"), (6, "in")⟩ ]
  duration := 8.0
  seed := 29
  runMetadata := conformanceCaseMetadata

def desmodesCase : ConformanceCase where
  id := "desmodes"
  purpose := "Checks LIFO queueing, server capacity, delay, and round-robin routing."
  module := "des@0.1.0"
  input := .machine "desmodes"
  configuration := desmodes

/-- The DES-module conformance cases in catalogue order. -/
def des : List ConformanceCase :=
  [ despipeCase, desrouteCase, desstatsCase, desexpCase, despriCase
  , descondCase, desweightCase, desmodesCase ]

end Machine.ConformanceCases
