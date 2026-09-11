import Machine.Kernel
import Machine.Samplers
/-!
# The des component library

These behaviors define the `des.*` standard library. They specify observable
state names and write order, blocking policies, escrow custody counts, and
failure messages.

With kernel escrow, a blocked transfer's entity never comes back to the
sender: it stays in kernel escrow under the persistent transfer identifier,
and the kernel redelivers it after the receiver reports readiness. Senders
track blocked transfers only to publish custody counts and to apply
backpressure to their own work.

Duration parameters take a `SampledValue`, which is a prepared value sampled
through the component operation interface. Expression-backed DES modes use
the same prepared-value evaluation interface.
-/

namespace Machine.Des

open Machine

/-- A numeric parameter sampled through the component's prepared-value interface. -/
abbrev SampledValue := PreparedValue

namespace SampledValue

def lit (value : Float) : SampledValue := PreparedValue.number value
def exponential (rate : Float) : SampledValue :=
  PreparedValue.exponential (PreparedValue.number rate)
def uniform (min max : Float) : SampledValue :=
  PreparedValue.uniform (PreparedValue.number min) (PreparedValue.number max)
def normal (mean std : Float) : SampledValue :=
  PreparedValue.normal (PreparedValue.number mean) (PreparedValue.number std)

def sample (value : SampledValue) : ComponentProgram Float :=
  ComponentProgram.sample value

end SampledValue

/-! ## des.source -/

structure SourceCfg where
  interarrival : SampledValue
  /-- Entity type created at each arrival. -/
  entityType : String
  limit : Option Nat := none

structure SourceSt where
  created : Nat := 0

private def scheduleNext (configuration : SourceCfg) (state : SourceSt) :
    ComponentProgram SourceSt := do
  if configuration.limit.any (state.created ≥ ·) then
    pure state
  else do
    let duration ← configuration.interarrival.sample
    -- Negative sampled durations are treated as 0.
    let _ ← ComponentProgram.scheduleAfter (max duration 0.0)
    pure state

def source (configuration : SourceCfg) : RuntimeComponent := RuntimeComponent.pack (σ := SourceSt)
  { start := fun s => do
      ComponentProgram.publishNumber "count" 0.0
      ComponentProgram.publishNumber "held" 0.0
      scheduleNext configuration s
    handle := fun s event =>
      match event with
      | .timerFired _ => do
        let s := { s with created := s.created + 1 }
        ComponentProgram.publishNumber "count" (Float.ofNat s.created)
        let entity ← ComponentProgram.createEntity configuration.entityType
        let _ ← ComponentProgram.sendUnique "out" entity
        -- The next arrival is scheduled once this one is delivered (a blocked
        -- entity pauses the arrival process: backpressure, not loss).
        pure s
      | .sendResult _ .delivered => do
        ComponentProgram.publishNumber "held" 0.0
        scheduleNext configuration s
      | .sendResult _ .blocked => do
        ComponentProgram.publishNumber "held" 1.0
        pure s
      | _ => pure s }
  {} (componentType := "des.source")

/-! ## des.queue -/

inductive Discipline where
  | fifo
  | lifo
  | priority (expr : Machine.Expr)

structure QueueCfg where
  discipline : Discipline := .fifo
  capacity : Option Nat := none

structure QueueSt where
  /-- `(entity, enqueue time, priority)`; priority is 0 outside priority discipline. -/
  items : List (Entity × Float × Float) := []
  /-- The sent head awaiting its transfer result. It is outside `items`, so
  same-time arrivals cannot reorder ahead of it. -/
  inFlight : Option (Entity × Float × Float) := none

private def qPublishLen (s : QueueSt) : ComponentProgram Unit :=
  ComponentProgram.publishNumber "length"
    (Float.ofNat (s.items.length + if s.inFlight.isSome then 1 else 0))

private def qInsertPriority
    (item : Entity × Float × Float) : List (Entity × Float × Float) →
    List (Entity × Float × Float)
  | [] => [item]
  | x :: xs =>
    let (_, _, p) := x
    let (_, _, prio) := item
    if p < prio then item :: x :: xs else x :: qInsertPriority item xs

private def qTryForward (s : QueueSt) : ComponentProgram QueueSt := do
  match s.inFlight with
  | some _ => pure s
  | none =>
    match s.items with
    | item :: rest => do
      let (entity, _, _) := item
      let _ ← ComponentProgram.sendUnique "out" entity
      pure { s with items := rest, inFlight := some item }
    | [] => pure s

def queue (configuration : QueueCfg) : RuntimeComponent := RuntimeComponent.pack (σ := QueueSt)
  { start := fun s => do
      ComponentProgram.publishNumber "length" 0.0
      pure s
    receive := fun s entity _ => do
      let occupied := s.items.length + if s.inFlight.isSome then 1 else 0
      if configuration.capacity.any (occupied ≥ ·) then
        pure (s, .block)  -- full: block until an item leaves
      else do
        let now ← ComponentProgram.now
        let prio ← match configuration.discipline with
          | .priority expr => ComponentProgram.evaluate (.expression expr)
          | _ => pure 0.0
        let item := (entity, now, prio)
        let s := { s with items :=
          match configuration.discipline with
          | .fifo => s.items ++ [item]
          | .lifo => item :: s.items
          | .priority _ => qInsertPriority item s.items }
        qPublishLen s
        let s ← qTryForward s
        pure (s, .accept)
    handle := fun s event =>
      match event with
      | .sendResult _ .delivered => do
        -- The in-flight head actually left the queue.
        let s ← match s.inFlight with
          | some (_, enqT, _) => do
            let now ← ComponentProgram.now
            ComponentProgram.publishNumber "waitTime" (now - enqT)
            pure { s with inFlight := none }
          | none => pure s
        qPublishLen s
        if configuration.capacity.isSome then
          ComponentProgram.reportReady "in"
        qTryForward s
      | .sendResult _ .blocked =>
        -- The head stays in escrow; the kernel redelivers when the receiver
        -- reports readiness.
        pure s
      | _ => pure s }
  {} (componentType := "des.queue")

/-! ## des.server -/

structure ServerCfg where
  serviceTime : SampledValue
  capacity : Float := 1.0

structure ServerSt where
  busy : Nat := 0
  inService : List (UInt64 × Entity) := []
  /-- Sent transfers whose result reported blocked, entity still in kernel
  escrow. Only blocked results enter this list, so a sent transfer awaiting
  its result is absent; `DelaySt.outstanding` counts pending and blocked
  alike. -/
  blockedOut : List UInt64 := []

private def srvCap (configuration : ServerCfg) : Nat :=
  ((max configuration.capacity.floor 1.0).toUInt64).toNat

private def srvPublishState (configuration : ServerCfg) (s : ServerSt) : ComponentProgram Unit := do
  let cap := srvCap configuration
  ComponentProgram.publishNumber "busy" (Float.ofNat s.busy)
  ComponentProgram.publishNumber "utilization" (min (Float.ofNat s.busy / Float.ofNat cap) 1.0)
  ComponentProgram.publishNumber "held" (Float.ofNat s.blockedOut.length)

def server (configuration : ServerCfg) : RuntimeComponent := RuntimeComponent.pack (σ := ServerSt)
  { start := fun s => do
      ComponentProgram.publishNumber "busy" 0.0
      ComponentProgram.publishNumber "utilization" 0.0
      ComponentProgram.publishNumber "held" 0.0
      pure s
    receive := fun s entity _ => do
      if s.busy ≥ srvCap configuration then
        pure (s, .block)
      else do
        let s := { s with busy := s.busy + 1 }
        let dt ← configuration.serviceTime.sample
        -- Negative sampled durations are treated as 0.
        let timer ← ComponentProgram.scheduleAfter (max dt 0.0)
        let s := { s with inService := s.inService ++ [(timer.value, entity)] }
        srvPublishState configuration s
        pure (s, .accept)
    handle := fun s event =>
      match event with
      | .timerFired timer => do
        match s.inService.partition (fun (t, _) => t == timer.value) with
        | ([(_, entity)], rest) => do
          let s := { s with inService := rest, busy := s.busy - 1 }
          let _ ← ComponentProgram.sendUnique "out" entity
          srvPublishState configuration s
          ComponentProgram.reportReady "in"
          pure s
        | _ => ComponentProgram.failRun "server timer for unknown service"
      | .sendResult transfer .blocked => do
        let s := { s with blockedOut := s.blockedOut ++ [transfer.value] }
        ComponentProgram.publishNumber "held" (Float.ofNat s.blockedOut.length)
        pure s
      | .sendResult transfer .delivered => do
        if s.blockedOut.contains transfer.value then
          let s := { s with blockedOut := s.blockedOut.filter (· != transfer.value) }
          ComponentProgram.publishNumber "held" (Float.ofNat s.blockedOut.length)
          pure s
        else pure s
      | _ => pure s }
  {} (componentType := "des.server")

/-! ## des.delay -/

structure DelayCfg where
  duration : SampledValue

structure DelaySt where
  holding : List (UInt64 × Entity) := []
  /-- Sent transfers whose result has not arrived yet: pending or blocked
  downstream, entity still in kernel escrow. -/
  outstanding : List UInt64 := []

private def dlyPublishState (s : DelaySt) : ComponentProgram Unit :=
  ComponentProgram.publishNumber "inTransit"
    (Float.ofNat (s.holding.length + s.outstanding.length))

def delay (configuration : DelayCfg) : RuntimeComponent := RuntimeComponent.pack (σ := DelaySt)
  { start := fun s => do
      ComponentProgram.publishNumber "inTransit" 0.0
      pure s
    receive := fun s entity _ => do
      let dt ← configuration.duration.sample
      -- Negative sampled durations are treated as 0.
      let timer ← ComponentProgram.scheduleAfter (max dt 0.0)
      let s := { s with holding := s.holding ++ [(timer.value, entity)] }
      dlyPublishState s
      pure (s, .accept)
    handle := fun s event =>
      match event with
      | .timerFired timer => do
        match s.holding.partition (fun (t, _) => t == timer.value) with
        | ([(_, entity)], rest) => do
          let s := { s with holding := rest }
          let transfer ← ComponentProgram.sendUnique "out" entity
          -- Count the in-flight transfer until its result arrives.
          let s := { s with outstanding := s.outstanding ++ [transfer.value] }
          dlyPublishState s
          pure s
        | _ => ComponentProgram.failRun "delay timer for unknown entity"
      | .sendResult transfer .delivered => do
        let s := { s with outstanding := s.outstanding.filter (· != transfer.value) }
        dlyPublishState s
        pure s
      | .sendResult _ .blocked => pure s
      | _ => pure s }
  {} (componentType := "des.delay")

/-! ## des.router -/

inductive Policy where
  /-- One pinned uniform index pick per routed entity. -/
  | random
  /-- One pinned uniform draw over explicit per-connection weights. -/
  | weightedRandom (weights : List Float)
  /-- Cycle through the out routes in order. -/
  | roundRobin
  /-- Route to the connection whose target publishes the smallest `length`. -/
  | shortestQueue
  /-- Evaluate conditions in route order; fall back to the last route. -/
  | conditional (conditions : List Machine.Expr)

structure RouterCfg where
  policy : Policy := .roundRobin
  /-- Target queue state paths resolved from the configured model. -/
  targetLengthPaths : List String := []

structure RouterSt where
  rrNext : Nat := 0
  buffer : List Entity := []
  inFlight : Bool := false
  routed : Nat := 0

private def minPositive : Float :=
  Float.ofBits 0x0010000000000000

private def weightedPickLoop : List Float → Nat → Nat → Float → Nat
  | [], _, chosen, _ => chosen
  | w :: ws, i, chosen, x =>
    if x < w then i else weightedPickLoop ws (i + 1) chosen (x - w)

private def rtChoose (configuration : RouterCfg) (s : RouterSt) :
    ComponentProgram (Route × RouterSt) := do
  let routes ← ComponentProgram.routes "out"
  if routes.isEmpty then do
    let cid ← ComponentProgram.componentId
    ComponentProgram.failRun s!"{cid} (des.router) has no outgoing routes"
  else
    match configuration.policy with
    | .random => do
      let bits ← ComponentProgram.randomBits
      let i := min (Samplers.u01Bits bits * Float.ofNat routes.length).toUInt64.toNat
        (routes.length - 1)
      pure (routes[i]!, s)
    | .weightedRandom weights => do
      if weights.length != routes.length then do
        let cid ← ComponentProgram.componentId
        ComponentProgram.failRun s!"{cid} (des.router) has {weights.length} weights for {routes.length} outgoing routes"
      else do
        let bits ← ComponentProgram.randomBits
        let total := weights.foldl (fun acc w => acc + w) 0.0
        let bound := max total minPositive
        let x := Samplers.uniformOfU 0.0 bound (Samplers.u01Bits bits)
        let i := weightedPickLoop weights 0 (routes.length - 1) x
        pure (routes[i]!, s)
    | .roundRobin =>
      let i := s.rrNext % routes.length
      pure (routes[i]!, { s with rrNext := s.rrNext + 1 })
    | .shortestQueue => do
      if configuration.targetLengthPaths.length != routes.length then do
        let cid ← ComponentProgram.componentId
        ComponentProgram.failRun
          s!"{cid} (des.router) has {configuration.targetLengthPaths.length} target paths for {routes.length} outgoing routes"
      let mut best := 0
      let mut bestLen := (1.0 : Float) / 0.0
      for i in [0:routes.length] do
        let len := (← ComponentProgram.observeNumber configuration.targetLengthPaths[i]!).getD 0.0
        if len < bestLen then
          bestLen := len
          best := i
      pure (routes[best]!, s)
    | .conditional conditions => do
      if conditions.length != routes.length then do
        let cid ← ComponentProgram.componentId
        ComponentProgram.failRun s!"{cid} (des.router) has {conditions.length} conditions for {routes.length} outgoing routes"
      else do
        let mut chosen := routes.length - 1
        let mut found := false
        for i in [0:conditions.length] do
          if !found then
            let conditionValue ← ComponentProgram.evaluate (.expression conditions[i]!)
            if conditionValue != 0.0 then
              chosen := i
              found := true
        pure (routes[chosen]!, s)

private def rtTryRoute (configuration : RouterCfg) (s : RouterSt) : ComponentProgram RouterSt := do
  if s.inFlight then pure s
  else
    match s.buffer.head? with
    | some entity => do
      let (route, s) ← rtChoose configuration s
      let _ ← ComponentProgram.send route entity
      pure { s with inFlight := true }
    | none => pure s

def router (configuration : RouterCfg) : RuntimeComponent := RuntimeComponent.pack (σ := RouterSt)
  { start := fun s => do
      ComponentProgram.publishNumber "count" 0.0
      ComponentProgram.publishNumber "held" 0.0
      pure s
    receive := fun s entity _ => do
      let s := { s with buffer := s.buffer ++ [entity] }
      ComponentProgram.publishNumber "held" (Float.ofNat s.buffer.length)
      let s ← rtTryRoute configuration s
      pure (s, .accept)
    handle := fun s event =>
      match event with
      | .sendResult _ .delivered => do
        let s := { s with inFlight := false, buffer := s.buffer.tail, routed := s.routed + 1 }
        ComponentProgram.publishNumber "count" (Float.ofNat s.routed)
        ComponentProgram.publishNumber "held" (Float.ofNat s.buffer.length)
        rtTryRoute configuration s
      | .sendResult _ .blocked =>
        -- The routed entity stays pinned to the chosen route in kernel
        -- escrow; the kernel redelivers on receiver readiness.
        pure s
      | _ => pure s }
  {} (componentType := "des.router")

/-! ## des.sink -/

def sink : RuntimeComponent := RuntimeComponent.pack (σ := Nat)
  { start := fun s => do
      ComponentProgram.publishNumber "count" 0.0
      pure s
    receive := fun s entity _ => do
      let s := s + 1
      ComponentProgram.publishNumber "count" (Float.ofNat s)
      ComponentProgram.disposeEntity entity
      pure (s, .accept) }
  0 (componentType := "des.sink")

end Machine.Des
