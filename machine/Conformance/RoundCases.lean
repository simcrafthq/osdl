import Conformance.Case
/-!
# Resolution-round conformance cases

Cases for module `reference-machine@0.1.0`: resolution-round reads,
ledger transactions, repetition, and participant failure. Each fixture is
followed by its catalogue record; `rounds` lists the records in catalogue
order.
-/

namespace Machine.ConformanceCases

open Machine

/-! ## roundtick: resolution rounds

The participants exercise frozen reads, ledger contention, withdrawal,
deposits, and interval scheduling. -/

/-- Reserve, deposit, and report up to `requested` units from `field.stock`.
The deposit target is `"{participantId}.stash"`. -/
def harvester (requested : Nat) : RoundBehavior Unit :=
  { round := fun s => do
      let granted ← RoundProgram.reserve "field.stock" requested
      let participantId ← RoundProgram.participantId
      RoundProgram.deposit s!"{participantId}.stash" granted
      RoundProgram.emit "round.harvest" (.obj [("granted", .nat granted)])
      pure s }

/-- Deposits `amount` into `field.stock` each round. -/
def rainmaker (amount : Nat) : RoundBehavior Unit :=
  { round := fun s => do
      RoundProgram.deposit "field.stock" amount
      pure s }

/-- Proposes a large deposit, then withdraws: nothing may commit. -/
def quitter : RoundBehavior Unit :=
  { round := fun s => do
      RoundProgram.deposit "field.stock" 100
      RoundProgram.emit "round.noise" .null
      RoundProgram.abort
      pure s }

/-- Emits the frozen value of `field.stock`: reads see the snapshot, never
this round's in-flight ledger. -/
def fieldReader : RoundBehavior Unit :=
  { round := fun s => do
      let v ← RoundProgram.readFrozenState "field.stock"
      let bonus ← RoundProgram.param "bonus"
      let time ← RoundProgram.now
      let balance ← RoundProgram.balance "field.stock"
      let random ← RoundProgram.rand
      let sampled ← RoundProgram.sampleWithScope
        (.uniform (.parameter "bonus") (.expression (Expr.parse! "bonus + local")))
        [("local", 3.0), ("bonus", 2.0)]
      RoundProgram.emit "round.read" (.obj [("value", match v with
        | some x => .float x
        | none => .null), ("bonus", match bonus with
        | some x => .float x
        | none => .null), ("time", .float time), ("balance", .nat balance)
        , ("random", .str (toString random)), ("sampled", .float sampled)])
      pure s }

def roundtick : RunConfiguration where
  modelName := "roundtick"
  componentIds := #[]
  components := #[]
  connections := #[]
  duration := 1.0
  seed := 3
  runMetadata := conformanceCaseMetadata
  rounds := #[
    { roundId := "tick"
      participants := #[ RoundParticipant.pack "reader" fieldReader ()
                , RoundParticipant.pack "rain" (rainmaker 4) ()
                , RoundParticipant.pack "harvest-a" (harvester 3) ()
                , RoundParticipant.pack "harvest-b" (harvester 4) ()
                , RoundParticipant.pack "quit" quitter () ]
      initialLedger := [("field.stock", 5)]
      parameters := [("bonus", 2.0)]
      interval := some 1.0 } ]

def roundtickCase : ConformanceCase where
  id := "roundtick"
  purpose := "Checks successful resolution-round reads, transactions, and repetition."
  module := "reference-machine@0.1.0"
  input := .machine "roundtick"
  configuration := roundtick

/-! ## rounderr -/

private def failingParticipant : RoundBehavior Unit :=
  { round := fun _ => RoundProgram.failRound "round participant failed" }

def rounderr : RunConfiguration where
  modelName := "rounderr"
  componentIds := #[]
  components := #[]
  connections := #[]
  duration := 1.0
  seed := 31
  runMetadata := conformanceCaseMetadata
  rounds := #[
    { roundId := "failure"
      participants := #[RoundParticipant.pack "failed" failingParticipant ()]
      interval := some 1.0 } ]

def rounderrCase : ConformanceCase where
  id := "rounderr"
  purpose := "Checks resolution-round participant failure."
  module := "reference-machine@0.1.0"
  input := .machine "rounderr"
  configuration := rounderr

/-- The resolution-round conformance cases in catalogue order. -/
def rounds : List ConformanceCase :=
  [ roundtickCase, rounderrCase ]

end Machine.ConformanceCases
