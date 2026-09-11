# The Lean reference machine

The Lean reference machine is an executable Lean 4 model of a semantic subset
of OSDL. It consists of machine state, semantic operations available to
component reactions, a kernel that interprets those operations, and a
structured run-control interface. Component behaviors are pure programs over
the operation set. They can change machine state only through those
operations.

The JSON Schemas define document structure. The OSDL Core and library
specifications define portable behavior. Given a case and seed, the Lean
reference machine produces recorded results and a complete raw trace. A runner
can derive the portable event projection from that trace. Independent
implementations compare recorded results and portable events. The
reference-machine implementation contract is optional. Its contract artifacts
test the implementation contract. Implementations that select the
[`reference-machine` implementation contract](../contracts/reference-machine/CONTRACT.md)
also compare the complete raw trace. Component-library and implementation-contract
selection happens outside OSDL model documents.

## Machine modules

### Runtime module map

| Module | Contents |
|---|---|
| [`Machine/Time.lean`](Machine/Time.lean) | `Time := Float`, IEEE totalOrder, and exact-decimal float rendering. |
| [`Machine/Rng.lean`](Machine/Rng.lean) | FNV-1a labeling, PCG64-MCG, and per-component `stream (seed, id)`. |
| [`Machine/Samplers.lean`](Machine/Samplers.lean) | Pinned distribution samplers using inverse-CDF, Box-Muller, and pinned compositions. |
| [`Machine/Types.lean`](Machine/Types.lean) | Entities, connections, routes, typed identifiers, run statuses, structured diagnostics, and JSON. |
| [`Machine/Expr.lean`](Machine/Expr.lean) | The OSDL expression parser and total evaluator. |
| [`Machine/PreparedValue.lean`](Machine/PreparedValue.lean) | Prepared literals, parameter references, expressions, distributions, and evaluation scopes. |
| [`Machine/PreparedRun.lean`](Machine/PreparedRun.lean) | Pre-run validation, normalized configuration, and prepared connection indexes. |
| [`Machine/Transfer.lean`](Machine/Transfer.lean) | The escrow transfer types: `TransferId`, `TransferStatus`, the custody record `TransferRecord`, and the component-facing `SendOutcome` (`delivered`, `blocked`, `cancelled`) and `ReceiveDecision` (`accept`, `block`). |
| [`Machine/GoldenVectors.lean`](Machine/GoldenVectors.lean) | Golden-vector cases, parsing, rendering, and evaluation. |
| [`Machine/ComponentOperation.lean`](Machine/ComponentOperation.lean) | The semantic operation set and the free monad `ComponentProgram`. |
| [`Machine/ComponentBehavior.lean`](Machine/ComponentBehavior.lean) | The four component entry points (`start`, `handle`, `receive`, `finish`) as programs with typed local state. |
| [`Machine/MachineState.lean`](Machine/MachineState.lean) | Machine state, calendar targets and entries, observable store, transfer custody table, external-input transcript, RNG streams, counters, and trace. |
| [`Machine/Kernel.lean`](Machine/Kernel.lean) | Operation interpretation, dispatch and pending-change flushes, escrow delivery, and single-step dispatch. |
| [`Machine/RunControl.lean`](Machine/RunControl.lean) | Run instances, `step`, `run`, `runThrough`, `nextEventTime`, external-input admission, host cancellation, and `RunReport`. |
| [`Machine/Des.lean`](Machine/Des.lean) | Standard DES component behavior for literal and sampled parameters. |
| [`Machine/Recorder.lean`](Machine/Recorder.lean) | Time-weighted summaries, time series, and final values. |
| [`Machine/ResolutionRound.lean`](Machine/ResolutionRound.lean) | Resolution-round participants, ledger, and dispatch. |

### Check map

| Module | Contents |
|---|---|
| [`Conformance.lean`](Conformance.lean) | Portable conformance cases in a separate Lake target: the case record in [`Conformance/Case.lean`](Conformance/Case.lean) and one case module per catalogue module (`Conformance/CoreCases.lean`, `Conformance/DesCases.lean`, `Conformance/RoundCases.lean`). |
| [`TraceQueries.lean`](TraceQueries.lean) | Structured trace-envelope queries shared by the check executables. |
| [`PreparationChecks.lean`](PreparationChecks.lean) | Checks pre-run validation, normalization, and prepared lookups. |
| [`TransferChecks.lean`](TransferChecks.lean) | Checks transfer outcomes, callback order, entity identity, and custody. |
| [`VectorRoundTripChecks.lean`](VectorRoundTripChecks.lean) | Checks the golden-vector codec and shared catalogue. |
| [`CatalogueChecks.lean`](CatalogueChecks.lean) | Checks catalogue metadata, input locality, and configuration preparation. |
| [`RoundChecks.lean`](RoundChecks.lean) | Direct verification of the successful resolution-round invariants. |
| [`RunControlChecks.lean`](RunControlChecks.lean) | Step equivalence, `runThrough` boundaries, external input, and cancellation checks. |
| [`GenerateVectors.lean`](GenerateVectors.lean) | Fixed cases that generate the committed golden vectors. |
| [`Vectors.lean`](Vectors.lean) | Golden-vector verification for time, randomness, and samplers. |
| [`SafeguardChecks.lean`](SafeguardChecks.lean) | The dispatch-budget abort check. |

### Component entry points

`ComponentBehavior` has four entry points. Each runs over the component's
typed local state and returns the next state:

- `start` runs once, in slot order, after the complete topology is prepared.
- `handle` receives one typed `RuntimeEvent`: `timerFired`, `sendResult`,
  `messageReceived`, `inputValueChanged`, or `externalInput`.
- `receive` decides on an entity arrival held in kernel escrow. It returns
  `accept` or `block`; the decision cannot carry or substitute an entity.
- `finish` runs only for normal completion and receives the
  `CompletionReason`.

### Semantic operations

`ComponentOperation` defines 22 operations available to reference component
reactions: the context reads `now`, `componentId`, `routes`, and `observe`,
and the commands `scheduleAfter`, `scheduleAt`, `cancelTimer`,
`rescheduleTimer`, `send`, `cancelTransfer`, `reportReady`, `sendMessage`,
`setOutput`, `publishState`, `evaluate`, `sample`, `emitEvent`,
`createEntity`, `disposeEntity`, `randomBits`, `stopRun`, and `failRun`.

`scheduleAfter` and `scheduleAt` return a component-scoped `TimerId`. `send`
returns a component-scoped `TransferId` that persists through the pending and
blocked states of the transfer. `evaluate` and `sample` take an optional local
scope, so scoped and unscoped use are one operation each. `sendUnique` is a
library-level convenience over `routes` and `send`, not a kernel operation.

All 22 operations are exercised by conformance catalogue cases. `valuescope`
covers component identity, model parameters, local evaluation scope, and
scoped sampling. The DES cases cover ordinary evaluation, ordinary sampling,
route selection, absolute state reads, and disposal. `componenterr` covers a
component-raised terminal error. The catalogue-only
cases are `desroute`, `desexp`, `despri`, `descond`,
`desweight`, and `desmodes`. The kernel cases `timercancel`, `cancelxfer`,
`quiesce`, and `msgvalue` are also catalogue-only in this draft. These cases
do not have entries in the conformance manifests.

The free-monad encoding is machine-internal: OSDL Core defines the observable
semantics of the operations, not their representation. Model-driver
publication, silent staging, and runtime capability validation are outside
this interface.

### Transitions

| Transition | Semantics |
|---|---|
| preparation | Validate and normalize raw configuration before `MachineState` exists. Preparation failures are outside event traces. |
| lifecycle | `sim.started` → `start` in slot order → loop → end-time fixup → `finish` in slot order with the completion reason → `sim.completed {reason}` |
| `timer` | Dispatch `handle (timerFired timerId)`, then flush pending changes. Cancelled timers have no calendar entry. |
| `deliver` | Dispatch `receive`. `accept`: mark the transfer `delivered`, emit `entity.moved`, then dispatch the sender's `handle (sendResult delivered)`. `block`: keep the exact entity in kernel escrow, mark the transfer `blocked`, dispatch the sender's `handle (sendResult blocked)` with no entity value. |
| `redeliver` | After `reportReady(port)`: redeliver the oldest blocked transfer destined to that port. Acceptance drains further blocked transfers through follow-up `redeliver` entries; a repeated block notifies nobody. Provisional retry rule pending the identity-based transfer prototype. |
| `message` | Emit `message.sent`, then dispatch `handle (messageReceived port payload)` on the target. |
| `valueInput` | Dispatch `handle (inputValueChanged port value)` on the target. `setOutput` emitted `value.changed` and scheduled one entry per connection. |
| `external` | Dispatch `handle (externalInput port payload)` from the immutable admission transcript. |
| Pending-change flush | Emit observable-store writes as change-only `state.changed` events in write order, then emit component events in emission order. Only numerically coercible values reach the recorder. |
| Parameter override | Apply run-configuration overrides due at the current envelope sequence and emit `param.changed` for each. An applied override's envelope can make a later override due at the same boundary. |
| completion | `endTime` when the next event is past the duration, `condition` after `stopWhen` becomes nonzero, `requested` after `stopRun`, `quiescent` when the calendar is empty. |
| failure | A semantic diagnostic terminates the trace with `sim.error {code, message, source?, operation?, time}`. |
| abort | Host cancellation and dispatch-budget exhaustion terminate the trace with `sim.aborted {reason}`. `finish` does not run. |

Preparation failures stop a run before event tracing starts. Runtime semantic
failures remain terminal `sim.error` events.

Calendar entries are ordered by IEEE totalOrder time and insertion sequence.
A rescheduled timer receives a new insertion sequence. Envelope sequence
numbers are independent of calendar sequence numbers. Per-component RNG
streams derive from the run seed and component identifier. Adding a component
therefore does not perturb another component's draws.

### Run control

`RunControl` separates the immutable `RunConfiguration` from mutable run
instances. `createRun` performs startup. `step`, `run`, `runThrough`, and
`nextEventTime` implement the run-control semantics that `SPEC.md` section
8.1 defines. `injectExternal` admits validated external input into an
immutable run-owned transcript with a deterministic ordinal and a normal
calendar sequence. `cancel` requests idempotent host cancellation, observed
between dispatch transactions. `nextEventTime` is clamped to the run's end
time: a calendar whose least entry lies past the duration reads as `none`,
the same value quiescence reads as, because the run completes at the end time
before reaching that entry.

Every terminal path returns one `RunReport`. Its Lean field names are
`status`, `finalTime`, `results`, `trace`, and `diagnostics`. The
`RunStatus` constructors are `completed`, `failed`, and `aborted`; the
constructor names of `CompletionReason` and `AbortReason` match the wire
spellings. `lake exe runcontrolcheck` checks the run-control seam directly.

## Reference traces

Build the machine and emit one conformance case as newline-delimited JSON
envelopes:

```sh
lake build
lake exe osdl-reference-machine <conformance-case> [--seed <seed>] [--results]
```

`--seed` overrides the case's run seed. `--results` emits the results JSON
instead of the trace.

Print the conformance catalogue as one JSON array:

```sh
lake exe osdl-reference-machine --catalog
```

Each catalogue entry contains the case ID, purpose, module key, and input
metadata. OSDL inputs contain a repository-relative path. Machine inputs
contain a named behavior. The output does not contain the run configuration.

Use the catalogue command to list the current cases. These manifests assign
case ownership:

- [OSDL Core manifest](../conformance/core/manifest.json)
- [DES manifest](../libraries/des/conformance/manifest.json)
- [reference-machine manifest](../contracts/reference-machine/manifest.json)

`lake exe roundcheck` verifies the successful round invariants directly. The
command `lake exe osdl-reference-machine desstats --results` is an example that
emits recorded results instead of a trace.

Run the reference-machine checks from `machine/`:

```sh
lake build
lake exe preparationcheck
lake exe transfercheck
lake exe vectorroundtripcheck
lake exe cataloguecheck
lake exe vectors
lake exe roundcheck
lake exe safeguardcheck
```

Run `bash ../validate.sh` to run these checks with the document, conformance
artifact, and golden-vector drift checks in repository order.

An implementation can execute an equivalent conformance case and compare its
recorded results and portable events. Portable comparison removes telemetry,
event sequence numbers, and wall-clock fields. The reference-machine
implementation contract requires raw event envelopes in order. Under that
contract, float values
compare by binary64 bits. The Lean machine emits exact decimal forms so a
correctly rounded binary64 parser recovers those bits.

## Golden vectors

Generate the fixed vectors and check the committed file:

```sh
lake exe genvectors > /tmp/osdl-golden.txt
cmp /tmp/osdl-golden.txt vectors/golden.txt
lake exe vectors
```

The repository validator performs this comparison before running the vector
checker.

## Coverage rule

The machine represents a behavior when all three conditions hold:

1. A model can observe the behavior in a trace, result, state transition,
   ownership transition, random draw, or terminal error.
2. Independent engines must implement the same behavior.
3. A deterministic conformance case can exercise the behavior through the
   public authoring interface.

Library specifications define behavior outside OSDL Core. The reference-machine
implementation contract defines implementation policy. An implementation method
does not require a corresponding Lean constructor when it enforces contract
policy or serves a library outside the modeled subset.

## Modeled subset

The machine covers:

- Component lifecycle, the four entry points, and the portable component
  operation interface.
- Event-calendar ordering and all nine calendar target kinds.
- Timer identity, cancellation, and rescheduling.
- Entity escrow, acceptance, blocking, readiness redelivery,
  pre-acceptance cancellation, movement, creation, and disposal.
- Message and value port delivery.
- Typed published state, pending event flushes, stopping, progress, and
  structured terminal outcomes.
- Prepared values with model parameters and local evaluation scope.
- Run-time parameter overrides keyed on envelope sequence, with
  `param.changed` events.
- Pinned random streams and distribution samplers.
- Output summaries, time series, final values, and warmup.
- Structured run control: stepping, inclusive advancement, external-input
  admission, and host cancellation.
- Resolution-round snapshots, transactions, random streams, sampling,
  commit, discard, repetition, and failure.
- Every standard DES component mode.

The conformance cases exercise the modeled operation interfaces. Golden
vectors exercise every pinned sampler algorithm.

## Provisional rules

Ticket-gated decisions carry provisional machine behavior until their
focused prototypes select a contract:

- Readiness correlation and targeted retry: the machine redelivers the
  oldest blocked transfer to a port after `reportReady`, drains on
  acceptance, and notifies the sender of `blocked` only once.
- Startup transaction: `start` dispatches in slot order with per-dispatch
  flushes; whole-batch visibility and rollback are not modeled.
- Timer negative cases: `cancelTimer` is idempotent; `rescheduleTimer` of a
  timer that is not pending is a component failure.

## Implementation-specific behavior

The [reference-machine implementation contract](../contracts/reference-machine/CONTRACT.md)
defines raw trace equality, sequence allocation, telemetry order, callback
order, calendar insertion, safeguards, capability checks, limits, diagnostics,
and supporting test paths. The contract also records paths for supporting
artifacts that are not in this source tree.
