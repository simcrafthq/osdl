# Reference machine implementation contract

## Scope and selection

This implementation contract defines additional rules for the reference machine implementation class. A runner, build configuration, or test harness selects this contract outside an OSDL document. Selecting this contract first requires conformance with OSDL Core and each declared component library.

Implementations that do not select this contract can use different calendars, storage, callbacks, safeguards, limits, and telemetry. They remain conformant when they preserve valid documents, recorded results, and portable events.

## Run preparation

Preparation validates and normalizes raw configuration before `MachineState` exists. It creates component-local connection indexes and normalizes values that the kernel consumes.

Preparation failures are outside raw event traces. Runtime semantic failures remain terminal `sim.error` events.

## Raw traces and sequence allocation

A contract comparison uses the complete raw trace. Event envelopes compare in emission order. Numeric trace values compare by binary64 bits. The Lean executable emits exact decimal forms so a correctly rounded binary64 parser recovers those bits.

Event envelope sequence numbers start at `1` and increase by one for every emitted envelope. They include lifecycle events, telemetry, parameter changes, state changes, metrics, and component events. Calendar insertion sequence numbers also start at `1` and increase for every calendar insertion. Event and calendar sequence numbers are independent.

## Telemetry

The reference machine emits `sim.progress` after a calendar event crosses a new 1 percent duration bucket. It emits no progress event when the duration is zero.

After a component callback, the machine processes changed state paths in write order. For each path, it emits recorder `metric.updated` events before the `state.changed` event. It then emits component events in their emission order. A write produces `state.changed` only when IEEE equality reports a changed value. NaN always counts as changed. A change from `-0.0` to `0.0` does not count as changed.

## Component runtime interface

A component type implements four entry points over an author-defined local state: `start` (once, after the complete topology, routes, parameters, prepared values, outputs, and state references are prepared), `handle` (for every ordinary typed runtime event), `receive` (for an entity arrival held in kernel escrow, returning `accept` or `block` over a borrowed entity view), and `finish` (only for normal completion, with the completion reason). Component-local state is the return value of a reaction; it never changes through kernel commands.

`RuntimeEvent` is a closed sum: `timerFired(TimerId)`, `sendResult(TransferId, delivered | blocked | cancelled)`, `messageReceived(port, payload)`, `inputValueChanged(port, value)`, and `externalInput(port, payload)`. Send results carry no entity value.

The immutable component context exposes the current time, the component identity, prepared routes, parameters, and read-only run metadata. The context reads `now`, `componentId`, `routes`, and `observe` are pure queries. Commands are the effectful operations a reaction issues: `scheduleAfter` and `scheduleAt` (returning a component-scoped `TimerId`), `cancelTimer`, `rescheduleTimer`, `send` (returning a component-scoped persistent `TransferId`), `cancelTransfer`, `reportReady`, `sendMessage`, `setOutput`, `publishState`, `evaluate`, `sample`, `emitEvent`, `createEntity`, `disposeEntity`, `randomBits`, `stopRun`, and `failRun`. `evaluate`, `sample`, and `randomBits` are commands because they consume random-stream state or can raise diagnostics. Prepared deterministic expressions and prepared distributions are distinct types. Labeled random streams have `(preparedFacetId, localLabel)` identity. Raw random bits (`randomBits`) are an explicitly advanced capability. `sendUnique` is a library convenience over `routes` and `send`.

Inside `receive`, the return value decides the arrival. `accept` moves the exact entity and passes custody to the receiver. `block` leaves the exact entity in kernel escrow with custody at the sender. The decision carries no entity value, so a receiver cannot return, replace, or substitute the arrival. A receiver that destroys an accepted arrival issues the `disposeEntity` command inside the same `receive` reaction. Disposal is not part of the decision, so a blocked arrival stays intact in escrow.

## Callback and dispatch order

The lifecycle order is `sim.started`, component `start` in component slot order, the calendar loop, end-time adjustment for `endTime` completion, component `finish` in slot order with the completion reason, and the terminal frame. A normally completed run terminates with `sim.completed {reason}`; a semantic failure terminates with `sim.error` carrying the structured diagnostic; an aborted run terminates with `sim.aborted {reason}` and does not run `finish`.

A timer dispatch calls `handle` with `timerFired` and then flushes pending changes. Cancelled and rescheduled timers leave no dispatch: their stale calendar entries are discarded without counting as calendar dispatches.

An entity delivery calls the target's `receive` first. Acceptance flushes the target changes, marks the transfer `delivered`, emits one `entity.moved`, calls the sender's `handle` with `sendResult delivered`, and flushes the sender changes. Blocking keeps the exact entity in kernel escrow, marks the transfer `blocked`, and calls the sender's `handle` with `sendResult blocked` exactly once for the transfer. After `reportReady(port)`, the kernel redelivers the oldest blocked transfer destined to that port; acceptance drains further blocked transfers through follow-up redeliveries, and a repeated block notifies nobody. A disposed arrival emits `entity.disposed` during the receive flush, before `entity.moved`.

After each calendar event, the machine applies due parameter overrides. One applied override can make another override due at the same envelope boundary. It then emits progress telemetry, evaluates `stopWhen` (completion reason `condition`), and checks a component stop request (completion reason `requested`). An empty calendar completes with reason `quiescent` at the last event time; a next event past the duration completes with reason `endTime` at the duration.

## Run control

The runner separates immutable preparation from run instances. A run instance exposes the run-control operations that [`SPEC.md`](../../SPEC.md) section 8.1 defines: `step`, `run`, `runThrough`, `nextEventTime`, external-input admission, and host cancellation. Non-terminal calls return active progress with the current and next event times. Every terminal path returns one run report. Execution budgets are configurable implementation policy; exhaustion aborts with `budgetExceeded`.

## Diagnostics

Diagnostics carry a stable code (`component.failure`, `kernel.runtime`, `expression.error`), a message, and, when known, the component id, the operation (`start`, `handle`, `receive`, `finish`), and the simulation time. Diagnostics, raw traces, adapter tests, and documentation use the same four operation names as the entry points. A component diagnostic also identifies the component type and cause when known. Runtime diagnostics identify the unavailable connection, capability, parameter, or limit when known. A semantic execution failure ends the raw trace with `sim.error`, and result output is null after that failure. Safeguard exhaustion reports executable failure instead of a semantic event.

## Provisional rules

These rules are provisional pending focused prototypes and must not be treated as frozen: the readiness correlation and targeted retry rule (`reportReady` plus oldest-first kernel redelivery is the interim behavior); the startup transaction (`start` dispatches in slot order with per-dispatch visibility); timer negative cases (idempotent cancellation, reschedule error when not pending); the optional whole-model library preparation seam and closed multi-facet dispatch capability; and the resource-flow deposit transaction order. Model drivers remain on a separate model-coordination seam; there is no public resolution-round interface and no portable round-completion event.

## Calendar insertion

Calendar entries compare by IEEE total order of simulation time and then by calendar insertion sequence. Equal-time entries run in insertion order. Timer schedules, entity deliveries and redeliveries, message and value deliveries, external inputs, recorder samples, warmup boundaries, and resolution rounds use this calendar.

The machine rejects non-finite or negative timer delays. It rejects a finite delay when adding it to the current time produces a non-finite time. Same-time sends and readiness redeliveries allocate new calendar entries at the current simulation time.

## Safeguards, capability checks, and limits

The Lean run loop has a private limit of `1000000` calendar dispatches. Exhaustion makes the reference executable fail. It does not emit a portable event trace. [`machine/SafeguardChecks.lean`](../../machine/SafeguardChecks.lean) checks this safeguard.

Run `lake exe safeguardcheck` from `machine/` to check the step safeguard.

Reference-compatible runtimes validate entity and connection capabilities before they use a runtime handle. They reject unsupported fan-out outside a component that owns fan-out selection. They enforce configured calendar, dispatch, entity, and output limits. These checks and limits are implementation policy. They do not change a core recorded result or portable event for a valid run within the limits.

## Golden-vector compatibility

Golden-vector round-trip and verification checks are reference-machine compatibility checks. They pin the shared parser, renderer, case catalogue, random streams, and sampler outputs.

## Supporting sources and tests

The Lean machine sources define the executable behavior for this contract:

- [`machine/Machine/PreparedRun.lean`](../../machine/Machine/PreparedRun.lean) defines pre-run validation and normalized configuration.
- [`machine/Machine/Transfer.lean`](../../machine/Machine/Transfer.lean) defines the escrow transfer types: the persistent `TransferId`, `TransferStatus`, the kernel custody record `TransferRecord`, and the component-facing send outcomes and receive decisions.
- [`machine/Machine/GoldenVectors.lean`](../../machine/Machine/GoldenVectors.lean) defines golden-vector parsing, rendering, cases, and evaluation.
- [`machine/Machine/MachineState.lean`](../../machine/Machine/MachineState.lean) defines calendar targets and entries, event and calendar sequence allocation, the observable store, and pending emission order.
- [`machine/Machine/Kernel.lean`](../../machine/Machine/Kernel.lean) defines callbacks, dispatch, telemetry, delivery, safeguards, and diagnostics.
- [`machine/README.md`](../../machine/README.md) describes the executable interface and implemented subset.

The supporting executable checks are
[`machine/PreparationChecks.lean`](../../machine/PreparationChecks.lean),
[`machine/TransferChecks.lean`](../../machine/TransferChecks.lean),
[`machine/VectorRoundTripChecks.lean`](../../machine/VectorRoundTripChecks.lean),
and [`machine/CatalogueChecks.lean`](../../machine/CatalogueChecks.lean).

The contract suite path is `contracts/reference-machine/conformance/`. It runs all extended core and library suites before contract-specific cases.
