import Machine.Types
import Machine.Rng
import Machine.PreparedValue
/-!
# Resolution rounds

The kernel's second dispatch discipline: a round is one calendar entry whose
dispatch runs a set of participants against a frozen snapshot of the
store. Each participant proposes claims through the restricted operation set
below. It permits frozen reads and ledger reservations but no
sends, schedules, or state publications. Resolution is all-or-nothing per
participant: a completed program's ledger changes, emissions, and state stand;
an aborted program's proposal is discarded. After every participant has run,
the net ledger changes commit as ordinary pending store writes, then the
machine flushes pending changes once.
One calendar, one clock, one trace: a round is an entry, not a scheduler.

The ledger stores non-negative integer balances in sorted resource-key order.
`reserve` grants `min(requested, balance)` and subtracts immediately. Zero
balances are omitted. Resource keys become store paths at commit, so pool-style
levels are observable like component state.

Participant RNG streams derive from `(seed, participant id)`, the same
determinism-under-edit rule as components. A discarded (aborted) proposal
keeps its stream consumption because draws happen during the attempt.
-/

namespace Machine

/-- Per-resource non-negative balances, sorted by key with zero balances omitted. -/
abbrev Ledger := List (String × Nat)

namespace Ledger

def balance (ledger : Ledger) (resource : String) : Nat :=
  (ledger.lookup resource).getD 0

/-- Set a balance, keeping keys sorted and dropping zeros. -/
def set : (ledger : Ledger) → (resource : String) → (value : Nat) → Ledger
  | [], resource, value => if value == 0 then [] else [(resource, value)]
  | (key, balance) :: rest, resource, value =>
    if resource < key then
      if value == 0 then (key, balance) :: rest
      else (resource, value) :: (key, balance) :: rest
    else if resource == key then
      if value == 0 then rest else (resource, value) :: rest
    else (key, balance) :: set rest resource value

/-- Reserve up to `requested` and subtract the granted amount immediately.
The grant is `min(requested, balance)`. -/
def reserve (ledger : Ledger) (resource : String) (requested : Nat) : Nat × Ledger :=
  let granted := min requested (ledger.balance resource)
  (granted, ledger.set resource (ledger.balance resource - granted))

/-- Deposit an uncapped amount into a resource balance. -/
def deposit (ledger : Ledger) (resource : String) (amount : Nat) : Ledger :=
  ledger.set resource (ledger.balance resource + amount)

/-- `(key, after-balance)` for every key in either ledger: the round's
commit set, in sorted key order (both inputs are sorted). Keys dropped from
`after` commit as 0. The store's change-only dirty tracking makes unchanged
writes invisible, so committing the union is idempotent and makes initial
balances observable at the first dispatch. -/
def commits : Ledger → Ledger → List (String × Nat)
  | [], after => after
  | (k, _) :: before, [] => (k, 0) :: commits before []
  | (kb, vb) :: before, (ka, va) :: after =>
    if kb < ka then (kb, 0) :: commits before ((ka, va) :: after)
    else if ka < kb then (ka, va) :: commits ((kb, vb) :: before) after
    else (ka, va) :: commits before after

end Ledger

/-- One atomic operation available to a round participant (the participant
sub-signature of the plugin ABI). Deliberately absent: sends, schedules,
publishes, live store reads; confinement holds by construction. -/
inductive RoundOperation : Type → Type where
  /-- The round's time (dispatch time of the round entry). -/
  | now : RoundOperation Time
  /-- This participant's id. -/
  | participantId : RoundOperation String
  /-- Read the frozen snapshot (the store as of round start; never this
  round's in-flight operations). -/
  | readFrozenState (path : String) : RoundOperation (Option Float)
  /-- Read a resolved run parameter. Parameters are constant for the run. -/
  | param (name : String) : RoundOperation (Option Float)
  /-- Current ledger balance for a resource key. -/
  | balance (resource : String) : RoundOperation Nat
  /-- Reserve up to `requested` and subtract the granted amount immediately.
  The grant is `min(requested, balance)`. -/
  | reserve (resource : String) (requested : Nat) : RoundOperation Nat
  /-- Credit a resource key. -/
  | deposit (resource : String) (amount : Nat) : RoundOperation Unit
  /-- Next draw from this participant's RNG stream. -/
  | rand : RoundOperation UInt64
  /-- Evaluate or sample with local names and the participant's stream. -/
  | sampleWithScope (value : PreparedValue) (localScope : EvaluationScope) :
      RoundOperation Float
  /-- Emit a custom event (flushed at round commit; discarded on abort). -/
  | emit (eventType : String) (payload : JsonValue) : RoundOperation Unit
  /-- Withdraw this participant's whole proposal: ledger changes, emissions,
  and the state transition are discarded (stream consumption stands). -/
  | abort : RoundOperation Empty
  /-- Hard failure: aborts the run (a machine error, not a withdrawal). -/
  | failRound (message : String) : RoundOperation Empty

/-- A participant program: the free monad over `RoundOperation`. -/
inductive RoundProgram : Type → Type 1 where
  | pure {α : Type} (value : α) : RoundProgram α
  | bind {β α : Type} (operation : RoundOperation β)
      (continuation : β → RoundProgram α) : RoundProgram α

namespace RoundProgram

def bindProgram {α β : Type} :
    (program : RoundProgram α) →
    (continuation : α → RoundProgram β) →
    RoundProgram β
  | .pure value, continuation => continuation value
  | .bind operation firstContinuation, continuation =>
    .bind operation fun value => bindProgram (firstContinuation value) continuation

instance : Monad RoundProgram where
  pure := .pure
  bind := bindProgram

def now : RoundProgram Time := .bind .now .pure
def participantId : RoundProgram String := .bind .participantId .pure
def readFrozenState (path : String) : RoundProgram (Option Float) :=
  .bind (.readFrozenState path) .pure
def param (name : String) : RoundProgram (Option Float) := .bind (.param name) .pure
def balance (resource : String) : RoundProgram Nat := .bind (.balance resource) .pure
def reserve (resource : String) (requested : Nat) : RoundProgram Nat :=
  .bind (.reserve resource requested) .pure
def deposit (resource : String) (amount : Nat) : RoundProgram Unit :=
  .bind (.deposit resource amount) .pure
def rand : RoundProgram UInt64 := .bind .rand .pure
def sampleWithScope (value : PreparedValue) (localScope : EvaluationScope) :
    RoundProgram Float :=
  .bind (.sampleWithScope value localScope) .pure
def emit (eventType : String) (payload : JsonValue) : RoundProgram Unit :=
  .bind (.emit eventType payload) .pure
def abort : RoundProgram α := .bind .abort fun impossible => nomatch impossible
def failRound (message : String) : RoundProgram α :=
  .bind (.failRound message) fun impossible => nomatch impossible

end RoundProgram

/-- A participant's behavior: one hook, run once per round dispatch, over its
typed local state (the same packing discipline as `ComponentBehavior`/`RuntimeComponent`). -/
structure RoundBehavior (σ : Type) where
  round : (state : σ) → RoundProgram σ

/-- A participant instance: id, behavior, current local state. -/
structure RoundParticipant : Type 1 where
  participantId : String
  σ : Type
  behavior : RoundBehavior σ
  state : σ

instance : Inhabited RoundParticipant :=
  ⟨{ participantId := "", σ := Unit, behavior := { round := fun state => RoundProgram.pure state },
      state := () }⟩

/-- Pack a participant. -/
def RoundParticipant.pack {σ : Type} (participantId : String) (behavior : RoundBehavior σ)
    (state : σ) : RoundParticipant :=
  { participantId, σ, behavior, state }

/-- A round's configuration: participants in contention order (the round's
determinism discipline: document order, or a future seeded shuffle). -/
structure RoundConfiguration : Type 1 where
  roundId : String
  participants : Array RoundParticipant
  initialLedger : Ledger := []
  parameters : List (String × Float) := []
  /-- Re-arm the round this long after each dispatch (the tick-driver shape). -/
  interval : Option Time := none
  /-- First dispatch time. -/
  start : Time := 0.0

instance : Inhabited RoundConfiguration := ⟨{ roundId := "", participants := #[] }⟩

/-- A round's evolving state. -/
structure Round : Type 1 where
  roundId : String
  participants : Array RoundParticipant
  /-- Participant RNG streams, parallel to `participants`, derived from
  `(seed, participant id)`. -/
  randomStreams : Array Pcg64Mcg
  ledger : Ledger
  parameters : List (String × Float)
  interval : Option Time

instance : Inhabited Round :=
  ⟨{ roundId := "", participants := #[], randomStreams := #[], ledger := [], parameters := [],
      interval := none }⟩

def Round.fromConfiguration (seed : UInt64) (configuration : RoundConfiguration) : Round :=
  { roundId := configuration.roundId
    participants := configuration.participants
    randomStreams := configuration.participants.map
      (fun participant => stream seed participant.participantId)
    ledger := configuration.initialLedger
    parameters := configuration.parameters
    interval := configuration.interval }

/-- Outcome of one participant's program. -/
inductive RoundProgramOutcome (α : Type) where
  /-- Completed: value, ledger, stream, `(source, type, payload)` emissions. -/
  | ok (value : α) (ledger : Ledger) (randomStream : Pcg64Mcg)
      (emissions : Array (String × String × JsonValue))
  /-- Proposal withdrawn; only the stream consumption stands. -/
  | aborted (randomStream : Pcg64Mcg)
  /-- Machine error. -/
  | failed (message : String)

/-- Run one participant program against the frozen snapshot. Structural on
the program; participant programs are finite trees, so no fuel. -/
def runRoundProgram {α : Type} (snapshot : String → Option Float)
    (parameters : EvaluationScope) (time : Time) (participantId : String) :
    (program : RoundProgram α) →
    (ledger : Ledger) →
    (randomStream : Pcg64Mcg) →
    (emissions : Array (String × String × JsonValue)) →
      RoundProgramOutcome α
  | .pure value, ledger, randomStream, emissions =>
    .ok value ledger randomStream emissions
  | .bind operation continuation, ledger, randomStream, emissions =>
    match operation with
    | .now => runRoundProgram snapshot parameters time participantId
      (continuation time) ledger randomStream emissions
    | .participantId =>
      runRoundProgram snapshot parameters time participantId
        (continuation participantId) ledger randomStream emissions
    | .readFrozenState path =>
      runRoundProgram snapshot parameters time participantId
        (continuation (snapshot path)) ledger randomStream emissions
    | .param name =>
      runRoundProgram snapshot parameters time participantId
        (continuation (parameters.lookup name)) ledger randomStream emissions
    | .balance resource =>
      runRoundProgram snapshot parameters time participantId
        (continuation (ledger.balance resource)) ledger randomStream emissions
    | .reserve resource requested =>
      let (granted, ledger) := ledger.reserve resource requested
      runRoundProgram snapshot parameters time participantId
        (continuation granted) ledger randomStream emissions
    | .deposit resource amount =>
      runRoundProgram snapshot parameters time participantId
        (continuation ()) (ledger.deposit resource amount) randomStream emissions
    | .rand =>
      let (value, randomStream) := randomStream.next
      runRoundProgram snapshot parameters time participantId
        (continuation value) ledger randomStream emissions
    | .sampleWithScope value localScope =>
      match value.sample
          (fun path => localScope.lookup (String.intercalate "." path))
          time randomStream with
      | .ok (sampled, randomStream) =>
        runRoundProgram snapshot parameters time participantId
          (continuation sampled) ledger randomStream emissions
      | .error message => .failed message
    | .emit eventType payload =>
      runRoundProgram snapshot parameters time participantId
        (continuation ()) ledger randomStream
        (emissions.push (participantId, eventType, payload))
    | .abort => .aborted randomStream
    | .failRound message => .failed message

/-- Dispatch one round: run every participant in order (all-or-nothing per
participant), returning the advanced round and the buffered emissions. The
caller turns `Ledger.commits` into store writes and flushes pending changes. -/
def ResolutionRound.dispatch (round : Round) (snapshot : String → Option Float) (time : Time) :
    Except String (Round × Array (String × String × JsonValue)) :=
  go (List.range round.participants.size) round.participants round.randomStreams round.ledger #[]
where
  go : List Nat → Array RoundParticipant → Array Pcg64Mcg → Ledger →
      Array (String × String × JsonValue) →
      Except String (Round × Array (String × String × JsonValue))
    | [], participants, randomStreams, ledger, emissions =>
      .ok ({ round with participants, randomStreams, ledger }, emissions)
    | index :: remainingIndices, participants, randomStreams, ledger, emissions =>
      let participant := participants[index]!
      match runRoundProgram snapshot round.parameters time
          participant.participantId (participant.behavior.round participant.state) ledger
          randomStreams[index]! #[] with
      | .ok nextState nextLedger nextRandomStream participantEmissions =>
        go remainingIndices
          (participants.set! index { participant with state := nextState })
          (randomStreams.set! index nextRandomStream) nextLedger
          (emissions ++ participantEmissions)
      | .aborted nextRandomStream =>
        go remainingIndices participants (randomStreams.set! index nextRandomStream) ledger emissions
      | .failed message =>
        .error s!"resolution round \"{round.roundId}\" participant \"{participant.participantId}\" run at simulation time {displayTime time}: {message}"

end Machine
