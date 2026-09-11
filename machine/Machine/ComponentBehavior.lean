import Machine.ComponentOperation
/-!
# Component behavior

The machine-side component runtime interface has four entry points expressed
as component programs. `σ` is the component's typed local state. Each entry
point consumes the current local state and returns the next; component-local
state changes only through reaction return values, never through kernel
commands. `RuntimeComponent` packs a behavior with its current state
existentially. The kernel never inspects `σ`.

`start` runs once after the complete topology is prepared. `handle` receives
ordinary typed runtime events. `receive` handles an entity arrival held in
kernel escrow and returns an immediate `ReceiveDecision`; the decision cannot
carry or substitute an entity, so a receiver can neither return nor replace
the arriving entity. `finish` runs only for normal completion and receives
the completion reason.

Re-entrancy is unrepresentable here: entry points run over an explicit state
value, so the engine's runtime "component re-entered" guard holds by
construction.

Universe note: `RuntimeComponent` packs `σ : Type` existentially, which lifts
`RuntimeComponent` and therefore the machine state to `Type 1`. The kernel
threads state manually instead of using `EStateM`. A closed `Value` type for
local state would collapse everything to `Type 0` and enable the standard
monad stack, but it would forfeit typed local state.
-/

namespace Machine

/-- A typed inbound runtime event dispatched to `handle`. -/
inductive RuntimeEvent where
  /-- A timer armed by this component fired. -/
  | timerFired (timer : TimerId)
  /-- An earlier `send` reached a new current or terminal outcome. -/
  | sendResult (transfer : TransferId) (outcome : SendOutcome)
  /-- A message payload arrived on a message input port. -/
  | messageReceived (port : String) (payload : JsonValue)
  /-- A connected value input changed. -/
  | inputValueChanged (port : String) (value : StateValue)
  /-- An admitted external input arrived on an external port. -/
  | externalInput (port : String) (payload : JsonValue)

/-- The component runtime interface: four entry points over typed local state. -/
structure ComponentBehavior (σ : Type) where
  /-- Begin the run after the complete topology is prepared. -/
  start : (state : σ) → ComponentProgram σ
  /-- React to one typed runtime event. -/
  handle : (state : σ) → (event : RuntimeEvent) → ComponentProgram σ :=
    fun state _ => ComponentProgram.pure state
  /-- Decide on an entity arrival held in kernel escrow. The entity value is
  a borrowed view: the decision carries no entity. -/
  receive : (state : σ) → (entity : Entity) → (port : String) →
      ComponentProgram (σ × ReceiveDecision) :=
    fun _ _ port => do
      let cid ← ComponentProgram.componentId
      ComponentProgram.failRun s!"{cid} has no entity input \"{port}\""
  /-- Complete the run normally with an explicit completion reason. -/
  finish : (state : σ) → (reason : CompletionReason) → ComponentProgram σ :=
    fun state _ => ComponentProgram.pure state

/-- A component instance: a behavior packed with its current local state. -/
structure RuntimeComponent : Type 1 where
  σ : Type
  componentType : String
  behavior : ComponentBehavior σ
  state : σ

instance : Inhabited RuntimeComponent :=
  ⟨{ σ := Unit
     componentType := "reference"
     behavior := { start := fun s => ComponentProgram.pure s }
     state := () }⟩

/-- Pack a behavior and initial state as a component. -/
def RuntimeComponent.pack {σ : Type} (behavior : ComponentBehavior σ) (state : σ)
    (componentType : String := "reference") : RuntimeComponent :=
  { σ, componentType, behavior, state }

end Machine
