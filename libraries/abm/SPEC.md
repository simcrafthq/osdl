# Agent-based component library

## Identity and support

This component library uses the namespace `abm`. The `library.namespace` and `library.version` fields in [`abm.library.json`](../abm.library.json) are the source of the namespace and version. The current version is `0.1.0`.

ABM support is optional. An implementation supports this library only when it declares support for namespace `abm` and version `0.1.0`. An OSDL document does not select or require an implementation contract.

## Semantics

An `abm.population` owns agents that share one agent definition. Each resident agent owns its attribute values and current statechart state.

Triggers use the shared simulation clock:

- A `timeout` trigger schedules a transition after its delay and is cancelled when the agent leaves the source state.
- A `rate` trigger samples an exponential delay each time the agent enters the source state.
- A `condition` trigger is polled every `1.0` model time units and fires when its expression is nonzero.
- A `message` trigger fires when the agent receives its topic.
- An `arrive` trigger fires when a departed agent returns through the population input.

A transition runs source `onExit` actions, transition actions, and target `onEnter` actions in document order. A `depart` action transfers the agent as a DES entity. The entity retains the agent identity and attributes. The agent's timers are suspended while it is departed. A departed agent is excluded from resident population counts. Arrival restores the agent to the population.

The component description, ports, parameter schema, and statechart schema are in [`abm.library.json`](../abm.library.json). This specification does not repeat the JSON parameter tables.

## Observable state and events

`abm.population` publishes `count`, `held`, and one `inState.<stateId>` value for each statechart state.

The library uses `agent.transitioned` for completed transitions and `message.sent` for message sends. Agent departure and arrival can also produce core entity events. Observable state publication can produce the `state.changed` telemetry event.

## Conformance suite

The library suite path is `libraries/abm/conformance/`. An implementation that declares support for `abm@0.1.0` runs the core suite before this suite.
