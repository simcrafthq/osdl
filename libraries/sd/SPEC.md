# System dynamics component library

## Identity and support

This component library uses the namespace `sd`. The `library.namespace` and `library.version` fields in [`sd.library.json`](../sd.library.json) are the source of the namespace and version. The current version is `0.1.0`.

SD support is optional. An implementation supports this library only when it declares support for namespace `sd` and version `0.1.0`. An OSDL document does not select or require an implementation contract.

## Semantics

The SD library advances on the shared simulation clock. `time.integration.method` selects Euler or RK4 integration. `time.integration.dt` defaults to `1.0` model time units.

Same-time discrete events observe stock values from before the integration tick. Each integration step evaluates all flow rates against pre-step values. It then updates stocks simultaneously and applies `min`, `max`, and `nonNegative` clamps. Discrete events between integration steps observe the most recent values.

The library defines these component behaviors:

- `sd.stock` accumulates connected inflows and outflows.
- `sd.flow` evaluates its rate at every integration step. An unconnected input is an unlimited source. An unconnected output is an unlimited sink. A negative rate reverses direction.
- `sd.auxiliary` evaluates an intermediate expression at every integration step and whenever another expression reads it.

The component descriptions, ports, parameter schemas, and constraints are in [`sd.library.json`](../sd.library.json). This specification does not repeat the JSON parameter tables.

## Observable state and events

`sd.stock` publishes `value`. `sd.flow` publishes `rate`. `sd.auxiliary` publishes `value`.

Observable state publication can produce the `state.changed` telemetry event. Output recorders can produce the `metric.updated` telemetry event. This library declares no additional typed event.

## Conformance suite

The library suite path is `libraries/sd/conformance/`. An implementation that declares support for `sd@0.1.0` runs the core suite before this suite.
