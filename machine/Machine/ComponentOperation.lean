import Machine.PreparedValue
import Machine.Transfer
/-!
# Semantic operations

`ComponentOperation` is the Lean reference machine's set of semantic
operations available to component reactions. A component reaction is a
`ComponentProgram`, which is a free-monad program over `ComponentOperation`.
It can change machine state only through these constructors.

The free-monad representation is machine-internal. OSDL Core defines the
observable semantics of these operations, not their encoding. The
implementation contract represents the same operations as an immutable
component context (`now`, `componentId`, `routes`, `observe`) plus an ordered
command batch (everything else). The machine interleaves reads and commands in
one program; the observable effects are identical because context reads do not
change machine state.

The set contains the portable effects exposed to ordinary component behavior.
Model-driver publication, silent staging, and runtime capability validation
are outside this interface.
-/

namespace Machine

/-- One atomic kernel operation available to component reactions. -/
inductive ComponentOperation : Type → Type where
  /-- Context read: current simulation time. -/
  | now : ComponentOperation Time
  /-- Context read: this component's id. -/
  | componentId : ComponentOperation String
  /-- Context read: prepared routes leaving `port` of this component, in
  connection order. -/
  | routes (port : String) : ComponentOperation (List Route)
  /-- Arm a timer `delay` from now. Strict: non-finite or negative delays are
  machine errors; calendar entries are finite and never in the past. -/
  | scheduleAfter (delay : Time) : ComponentOperation TimerId
  /-- Arm a timer at an absolute time. Strict: non-finite times and times in
  the past are machine errors. -/
  | scheduleAt (time : Time) : ComponentOperation TimerId
  /-- Cancel a pending timer. Idempotent: cancelling a timer that already
  fired, was cancelled, or was never issued is a no-op. Provisional rule
  pending the timer negative-case prototype. -/
  | cancelTimer (timer : TimerId) : ComponentOperation Unit
  /-- Move a pending timer to a new absolute time. The rescheduled entry
  receives a new insertion sequence. Rescheduling a timer that is not pending
  is a machine error. Provisional rule pending the timer negative-case
  prototype. -/
  | rescheduleTimer (timer : TimerId) (time : Time) : ComponentOperation TimerId
  /-- Send an entity through a prepared route. The kernel takes the entity
  into escrow and delivers it at the current time. Returns the persistent
  transfer identifier. -/
  | send (route : Route) (entity : Entity) : ComponentOperation TransferId
  /-- Cancel one of this component's transfers before acceptance. The
  terminal transfer status becomes `Cancelled`; custody of the entity returns
  to the sender. Cancelling a transfer that is already terminal is a machine
  error. -/
  | cancelTransfer (transfer : TransferId) : ComponentOperation Unit
  /-- Report that this component is ready to receive on `port` again. The
  kernel redelivers blocked transfers destined to that port, oldest first.
  Provisional retry rule pending the identity-based transfer prototype. -/
  | reportReady (port : String) : ComponentOperation Unit
  /-- Send an immutable message payload through a prepared route on a message
  port. No custody: delivery is fire-and-forget at the current time. -/
  | sendMessage (route : Route) (payload : JsonValue) : ComponentOperation Unit
  /-- Publish a typed scalar on a value output port. Every connection from
  the port delivers an `InputValueChanged` event at the current time. -/
  | setOutput (port : String) (value : StateValue) : ComponentOperation Unit
  /-- Publish observable state under `{componentId}.{stateVariable}`. -/
  | publishState (stateVariable : String) (value : StateValue) : ComponentOperation Unit
  /-- Observe published state. Absent state is an absent observation. -/
  | observe (path : String) : ComponentOperation (Option StateValue)
  /-- Evaluate a prepared deterministic value. `locals` layers local names
  over model parameters and observable state; it defaults to empty.
  Evaluation never consumes random state. -/
  | evaluate (value : PreparedValue) (locals : EvaluationScope) : ComponentOperation Float
  /-- Sample a prepared value with this component's labeled random stream.
  `locals` layers local names over the base scope; it defaults to empty. -/
  | sample (value : PreparedValue) (locals : EvaluationScope) : ComponentOperation Float
  /-- Emit a declared custom event into the trace (flushed at end of dispatch). -/
  | emitEvent (eventType : String) (payload : JsonValue) : ComponentOperation Unit
  /-- Mint a fresh entity (emits `entity.created`). -/
  | createEntity (entityType : String) (agent : Option UInt32) : ComponentOperation Entity
  /-- Consume an entity and emit `entity.disposed` atomically. -/
  | disposeEntity (entity : Entity) : ComponentOperation Unit
  /-- Advanced capability: next raw draw from this component's random stream.
  Standard component libraries use prepared distributions. -/
  | randomBits : ComponentOperation UInt64
  /-- Request normal completion after the current dispatch
  (completion reason `Requested`). -/
  | stopRun : ComponentOperation Unit
  /-- Abort the run with a semantic component failure. -/
  | failRun (message : String) : ComponentOperation Empty

/-- A component program: the free monad over `ComponentOperation`. -/
inductive ComponentProgram : Type → Type 1 where
  | pure {α : Type} (value : α) : ComponentProgram α
  | bind {β α : Type} (operation : ComponentOperation β)
      (continuation : β → ComponentProgram α) : ComponentProgram α

namespace ComponentProgram

def bindProgram {α β : Type} :
    (program : ComponentProgram α) →
    (continuation : α → ComponentProgram β) →
    ComponentProgram β
  | .pure value, continuation => continuation value
  | .bind operation firstContinuation, continuation =>
    .bind operation fun value => bindProgram (firstContinuation value) continuation

instance : Monad ComponentProgram where
  pure := .pure
  bind := bindProgram

/-! Operation helpers, so behaviors read as straight-line do-notation. -/

def now : ComponentProgram Time := .bind .now .pure
def componentId : ComponentProgram String := .bind .componentId .pure
def routes (port : String) : ComponentProgram (List Route) := .bind (.routes port) .pure
def scheduleAfter (delay : Time) : ComponentProgram TimerId :=
  .bind (.scheduleAfter delay) .pure
def scheduleAt (time : Time) : ComponentProgram TimerId :=
  .bind (.scheduleAt time) .pure
def cancelTimer (timer : TimerId) : ComponentProgram Unit :=
  .bind (.cancelTimer timer) .pure
def rescheduleTimer (timer : TimerId) (time : Time) : ComponentProgram TimerId :=
  .bind (.rescheduleTimer timer time) .pure
def send (route : Route) (entity : Entity) : ComponentProgram TransferId :=
  .bind (.send route entity) .pure
def cancelTransfer (transfer : TransferId) : ComponentProgram Unit :=
  .bind (.cancelTransfer transfer) .pure
def reportReady (port : String) : ComponentProgram Unit :=
  .bind (.reportReady port) .pure
def sendMessage (route : Route) (payload : JsonValue) : ComponentProgram Unit :=
  .bind (.sendMessage route payload) .pure
def setOutput (port : String) (value : StateValue) : ComponentProgram Unit :=
  .bind (.setOutput port value) .pure
def publishState (stateVariable : String) (value : StateValue) : ComponentProgram Unit :=
  .bind (.publishState stateVariable value) .pure
/-- Publish a numeric observable state value. -/
def publishNumber (stateVariable : String) (value : Float) : ComponentProgram Unit :=
  publishState stateVariable (.number value)
def observe (path : String) : ComponentProgram (Option StateValue) :=
  .bind (.observe path) .pure
/-- Observe published state coerced to a number (integers widen, booleans
coerce to `1`/`0`, strings and absent state observe as `none`). -/
def observeNumber (path : String) : ComponentProgram (Option Float) := do
  pure ((← observe path).bind StateValue.asFloat)
def evaluate (value : PreparedValue) (locals : EvaluationScope := []) :
    ComponentProgram Float :=
  .bind (.evaluate value locals) .pure
def sample (value : PreparedValue) (locals : EvaluationScope := []) :
    ComponentProgram Float :=
  .bind (.sample value locals) .pure
def emitEvent (eventType : String) (payload : JsonValue) : ComponentProgram Unit :=
  .bind (.emitEvent eventType payload) .pure
def createEntity (entityType : String) (agent : Option UInt32 := none) : ComponentProgram Entity :=
  .bind (.createEntity entityType agent) .pure
def disposeEntity (entity : Entity) : ComponentProgram Unit :=
  .bind (.disposeEntity entity) .pure
def randomBits : ComponentProgram UInt64 := .bind .randomBits .pure
def stopRun : ComponentProgram Unit := .bind .stopRun .pure
def failRun (message : String) : ComponentProgram α :=
  .bind (.failRun message) fun impossible => nomatch impossible

/-- Library convenience: send through the single route on `port`. Zero or
multiple routes is a component failure. -/
def sendUnique (port : String) (entity : Entity) : ComponentProgram TransferId := do
  match (← routes port) with
  | [route] => send route entity
  | [] => do
    let cid ← componentId
    failRun s!"{cid}.{port} has no route to carry an entity"
  | _ => do
    let cid ← componentId
    failRun s!"{cid}.{port} has multiple routes; select one explicitly"

end ComponentProgram

end Machine
