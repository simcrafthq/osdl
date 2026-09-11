# Discrete-event component library

## Identity and support

This component library uses the namespace `des`. The `library.namespace` and `library.version` fields in [`des.library.json`](../des.library.json) are the source of the namespace and version. The current version is `0.1.0`.

DES support is optional. An implementation supports this library only when it declares support for namespace `des` and version `0.1.0`. An OSDL document does not select or require an implementation contract.

## Semantics

DES components use the shared simulation clock and the entity transfer rules in [`SPEC.md`](../../SPEC.md). The kernel holds each in-transfer entity in escrow. An accepted arrival moves custody to the receiver at the current simulation time. A blocked arrival stays in kernel escrow, and custody remains with the sender. When the receiver later reports readiness for the input port, the kernel redelivers that port's blocked transfers. No transfer can lose or duplicate an entity.

The library defines these component behaviors:

- `des.source` creates entities at configured intervals. It stops at its limit when a limit is present. It waits for acceptance before it schedules the next arrival.
- `des.queue` holds accepted entities. It applies FIFO, LIFO, or priority ordering. A bounded full queue blocks an arrival.
- `des.server` processes entities up to its current capacity. It samples service time per entity. It holds completed entities until downstream acceptance.
- `des.delay` holds each entity for its sampled duration. It allows concurrent entities.
- `des.router` selects one outgoing connection by random, weighted random, conditional, round-robin, or shortest-queue policy. It retains custody until the selected destination accepts the entity.
- `des.sink` accepts and disposes entities.

The component descriptions, ports, parameter schemas, and constraints are in [`des.library.json`](../des.library.json). This specification does not repeat the JSON parameter tables.

## Observable state and events

| Component | Observable state |
|---|---|
| `des.source` | `count`, `held` |
| `des.queue` | `length`, `waitTime` |
| `des.server` | `busy`, `utilization`, `held` |
| `des.delay` | `inTransit` |
| `des.router` | `count`, `held` |
| `des.sink` | `count` |

DES transfers produce the core `entity.created`, `entity.moved`, and `entity.disposed` events when the corresponding action occurs. Observable state publication can produce the `state.changed` telemetry event. Output recorders can produce the `metric.updated` telemetry event. This library declares no additional typed event.

## Conformance suite

The library suite path is `libraries/des/conformance/`. An implementation that declares support for `des@0.1.0` runs the core suite before this suite.

The Lean reference machine and existing DES cases provide supporting behavior and test provenance:

- [`machine/Machine/Des.lean`](../../machine/Machine/Des.lean) implements the standard DES component behavior.
- [`machine/Conformance.lean`](../../machine/Conformance.lean) defines the `despipe`, `desroute`, `desstats`, `desexp`, `despri`, `descond`, `desweight`, and `desmodes` cases.
- [`machine/Machine/Recorder.lean`](../../machine/Machine/Recorder.lean) implements summaries, time series, final values, and warmup behavior used by the DES cases.
