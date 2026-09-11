# OSDL Core conformance

This manifest defines the OSDL Core conformance module. A runner selects modules outside an OSDL model document. A model remains compatible without declaring a conformance module.

The `abm@0.1.0` and `sd@0.1.0` modules are defined. Their case arrays are empty. Future module versions can extend these modules after cases exist.

## Machine behavior contracts

A machine fixture names a small behavior that does not have an OSDL document representation. Its `behaviorContract` field links to the definition in this file. An implementation can use any internal design that constructs the defined input and produces the portable events in the case's `expected` file.

Each behavior uses this common configuration unless its definition gives a different value:

- Run metadata is `experiment = "workload"`, `replication = 1`, and `scenario = 0`.
- `warmup` is absent.
- Recorded outputs are empty.
- Parameters, parameter overrides, and `stopWhen` are absent.
- Fixture `arguments` is `{}`.
- Components run `start` in their listed order at simulation time `0`.
- Fixture-local component type is `reference` unless the behavior specifies another type.
- An unspecified `receive` decision returns `accept`.
- Other unspecified reactions do nothing and keep the current local state.

A component reacts to runtime events in `handle` and decides each entity arrival in `receive`, returning `accept` or `block`. A send result is `delivered`, `blocked`, or `cancelled`, carries no entity value, and reports `blocked` to the sender once per transfer. The reactions below use these operations:

- `scheduleAfter(delay)` schedules a timer relative to the current simulation time and returns a timer id. A component's timer ids count up from `1` in scheduling order.
- `createEntity(type)` creates an entity of the given type at the current component.
- `send(port, entity)` starts an entity transfer through an output port. The kernel takes the exact entity into escrow and delivers it to the connected receiver.
- `disposeEntity(entity)` disposes an entity at the current component.
- `publishState(name, value)` publishes a value in the component's observable state.
- `emitEvent(type, payload)` emits a typed event.
- `reportReady(port)` reports readiness for an input port. The kernel then redelivers blocked transfers destined to that port, oldest first.
- `stopRun()` requests normal run completion with reason `requested`.
- `failRun(message)` ends the run with the given component error.

The behavior definitions specify fixture construction. The expected portable event file specifies the output comparison boundary. Telemetry and internal scheduling steps are not portable assertions.

### timers

Purpose: Checks timer ordering for equal and different event times.

Configuration: Model `timers`, duration `10`, and seed `42`.

Components and actions: Component `t0` starts with integer state `0`. During `start`, it calls `scheduleAfter(1)`, `scheduleAfter(1)`, and `scheduleAfter(2.5)` in that order; the timers receive ids `1`, `2`, and `3`. On each `timerFired`, it increments its state, calls `publishState("fired", state)`, calls `publishState("lastTimer", timerId)`, and emits `fixture.timerFired` with payload `{"timer":timerId,"count":state}`.

Connections: None.

Observable boundaries: At time `1`, the portable `fixture.timerFired` payloads are `{"timer":1,"count":1}` and then `{"timer":2,"count":2}`. At time `2.5`, the payload is `{"timer":3,"count":3}`. The portable event comparison is [`expected/timers.machine.events.ndjson`](expected/timers.machine.events.ndjson).

### pipeline

Purpose: Checks accepted entity delivery through a source and sink.

Configuration: Model `pipeline`, duration `5`, and seed `7`.

Components and actions: Component `src` starts with integer state `0`. During `start`, it creates a `job` entity, sends it through `out`, and changes its state to `1`. On a `delivered` send result, it creates and sends another `job` while its state is less than `3`, then increments its state. On a `blocked` send result, it calls `failRun("unexpected blocked transfer")`. Component `snk` starts with integer state `0`. In `receive` for an arrival on `in`, it increments its state, calls `publishState("count", state)`, disposes the arrival, and returns `accept`.

Connections: `src.out` connects to `snk.in`.

Observable boundaries: Three `job` entities are accepted and moved at time `0`. Each `entity.disposed` event occurs before the matching `entity.moved` event. The portable event comparison is [`expected/pipeline.machine.events.ndjson`](expected/pipeline.machine.events.ndjson).

### backpressure

Purpose: Checks escrow blocking, readiness, and kernel redelivery.

Configuration: Model `backpressure`, duration `5`, and seed `11`.

Components and actions: Component `src` starts with integer state `0`. During `start`, it creates a `job`, sends it through `out`, and increments its state. On a `delivered` send result, it creates and sends another `job` while its state is less than `2`, then increments its state. On a `blocked` send result, it does nothing: the entity waits in kernel escrow. Component `snk` starts with `busy = false` and count `0`. During `start`, it sets `busy = true` and calls `scheduleAfter(1)`. In `receive` while busy, it emits `fixture.blocked` with payload `{"entityId":entity.name,"inputPort":"in"}` and returns `block`. Otherwise, it increments the count, calls `publishState("count", count)`, and returns `accept`. On `timerFired`, it emits `fixture.ready` with payload `{"inputPort":"in"}`, calls `reportReady("in")`, and sets `busy = false`.

Connections: `src.out` connects to `snk.in`.

Observable boundaries: The first delivery emits `fixture.blocked` for `job#1` at time `0`; the sender learns `blocked` once and the exact entity stays in kernel escrow. At time `1`, `fixture.ready` occurs before the kernel redelivers `job#1`, which the sink accepts. The `delivered` send result creates the second entity, which the sink also accepts at time `1`. The portable event comparison is [`expected/backpressure.machine.events.ndjson`](expected/backpressure.machine.events.ndjson).

### valuescope

Purpose: Checks parameter, state, local expression, and sampling scopes.

Configuration: Model `valuescope`, duration `1`, seed `17`, and parameter `offset = 2`.

Components and actions: Component `v0` has no local control state. During `start`, it calls `publishState("base", 3)` and reads its component identifier. It then evaluates parameter `offset`, evaluates `local + offset + v0.base` with local scope `local = 7` and `offset = 5`, and samples `uniform(local, local + 1)` with local scope `local = 7`. After those operations, it calls `publishState("parameter", parameter)`, `publishState("evaluated", evaluated)`, and `publishState("sampled", sampled)` in that order. It emits `value.scope` with payload `{"componentId":componentId,"parameter":parameter,"evaluated":evaluated,"sampled":sampled}`.

Connections: None.

Observable boundaries: The portable `value.scope` payload is `{"componentId":"v0","parameter":2,"evaluated":15,"sampled":7.839622425333314}` at time `0`. The local `offset = 5` shadows the run parameter in the scoped expression. The sample uses the random stream for component `v0`. The portable event comparison is [`expected/valuescope.machine.events.ndjson`](expected/valuescope.machine.events.ndjson).

### paramoverride

Purpose: Checks one run-time parameter override at a dispatch boundary.

Configuration: Model `paramoverride`, duration `4`, seed `17`, parameter `offset = 2`, and override `(afterSeq = 6, name = "offset", value = 5)`.

Components and actions: Component `v0` has no local control state. During `start`, it calls `scheduleAfter(1)`. On each `timerFired`, it evaluates parameter `offset`, adds `1`, calls `publishState("value", result)`, emits `param.value` with payload `{"value":result}`, and calls `scheduleAfter(1)`.

Connections: None.

Observable boundaries: Timer dispatches occur at times `1`, `2`, `3`, and `4`. The override becomes visible after the timer dispatch at time `3` and before the timer dispatch at time `4`. The emitted values are `3`, `3`, `3`, and `6`. The portable event comparison is [`expected/paramoverride.machine.events.ndjson`](expected/paramoverride.machine.events.ndjson).

### paramoverridecascade

Purpose: Checks cascading parameter overrides at one dispatch boundary.

Configuration: Model `paramoverridecascade`, duration `4`, seed `17`, parameters `bonus = 2` and `offset = 2`, and overrides `(afterSeq = 7, name = "offset", value = 5)` and `(afterSeq = 8, name = "bonus", value = 9)` in that order.

Components and actions: Component `v0` uses the same actions as [`paramoverride`](#paramoverride). The component does not evaluate `bonus`.

Connections: None.

Observable boundaries: Timer dispatches occur at times `1`, `2`, `3`, and `4`. At the boundary after the time `3` dispatch, the first override produces the next sequence position and makes the second override due at the same boundary. `offset` changes before `bonus`. The emitted values are `3`, `3`, `3`, and `6`. The portable event comparison is [`expected/paramoverridecascade.machine.events.ndjson`](expected/paramoverridecascade.machine.events.ndjson).

### rngpair

Purpose: Checks deterministic random streams for two components.

Configuration: Model `rngpair`, duration `1`, and seed `20260702`.

Components and actions: Components `a` and `b` have no local control state and use the same behavior. During `start`, each component draws four unsigned 64-bit values from its component stream with `randomBits`. For draw `n`, it calls `publishState("d<n>", draw >> 11)` after exact conversion to binary64. It then emits `machine.draws` with the four full-width values as base-10 strings in payload `{"draws":[draw1,draw2,draw3,draw4]}`. Component `a` runs `start` before component `b`.

Connections: None.

Observable boundaries: Each component emits one `machine.draws` event at time `0`. Every `draws` member is a decimal string so JSON processing cannot round an unsigned 64-bit value. The seed and component identifier select each deterministic component stream. The portable event comparison is [`expected/rngpair.machine.events.ndjson`](expected/rngpair.machine.events.ndjson).

### stopper

Purpose: Checks a component-requested stop.

Configuration: Model `stopper`, duration `10`, and seed `1`.

Components and actions: Component `c0` has no local control state. During `start`, it calls `scheduleAfter(3)`. On `timerFired`, it calls `stopRun()`.

Connections: None.

Observable boundaries: The run completes at time `3` with reason `requested`. The portable event comparison is [`expected/stopper.machine.events.ndjson`](expected/stopper.machine.events.ndjson).

### threshold

Purpose: Checks expression-based stopping after a state change.

Configuration: Model `threshold`, duration `10`, seed `3`, and `stopWhen = "c0.count >= 3"`.

Components and actions: Component `c0` starts with integer state `0`. During `start`, it calls `scheduleAfter(1)`. On each `timerFired`, it increments its state, calls `publishState("count", state)`, and calls `scheduleAfter(1)`. During `finish`, it calls `publishState("done", 1)`.

Connections: None.

Observable boundaries: The stop expression is evaluated after each timer dispatch. It becomes true after `c0.count` changes to `3` at time `3`. `finish` runs at time `3`. The run completes with reason `condition`. The portable event comparison is [`expected/threshold.machine.events.ndjson`](expected/threshold.machine.events.ndjson).

### exprerr

Purpose: Checks expression failure during stop-condition evaluation.

Configuration: Model `exprerr`, duration `5`, seed `13`, and `stopWhen = "1 / c0.zero"`.

Components and actions: Component `c0` has no local control state. During `start`, it calls `publishState("zero", 0)` and `scheduleAfter(1)`. Its timer reaction does nothing.

Connections: None.

Observable boundaries: The stop expression is evaluated after the timer dispatch at time `1`. Evaluation ends the run with `division by zero in "1 / c0.zero"`. The portable event comparison is [`expected/exprerr.machine.events.ndjson`](expected/exprerr.machine.events.ndjson).

### errsend

Purpose: Checks the terminal error for a send without a route.

Configuration: Model `errsend`, duration `5`, and seed `9`.

Components and actions: Component `e0` has component type `test.err` and no local control state. During `start`, it creates a `job` entity and sends it through `out`.

Connections: None.

Observable boundaries: The send ends the run at time `0` with `component "e0" (test.err) start at simulation time 0: e0.out has no route to carry an entity`. The failed `start` does not publish the staged entity creation. The portable event comparison is [`expected/errsend.machine.events.ndjson`](expected/errsend.machine.events.ndjson).

### componenterr

Purpose: Checks a component-raised terminal error.

Configuration: Model `componenterr`, duration `1`, and seed `19`.

Components and actions: Component `e0` has component type `test.component_err` and no local control state. During `start`, it calls `failRun("component failed")`.

Connections: None.

Observable boundaries: `start` ends the run at time `0` with `component "e0" (test.component_err) start at simulation time 0: component failed`. The portable event comparison is [`expected/componenterr.machine.events.ndjson`](expected/componenterr.machine.events.ndjson).
