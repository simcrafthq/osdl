# OSDL: Open Simulation Definition Language

Version 0.1 (draft)

OSDL is a vendor-neutral, JSON-native format for describing simulation models across paradigms: discrete-event (DES), agent-based (ABM), system dynamics (SD), and hybrids of all three. An OSDL document is a complete, executable description of a model, its experiments, and its presentation. Visual editors, code SDKs, language models, and engines can read and write the document.

The OSDL artifacts divide the public contract by concern. This document defines OSDL Core. The JSON Schemas define exchange structures. Component library specifications define optional component behavior. Implementation contracts can add implementation-specific rules:

- [`schemas/osdl.schema.json`](schemas/osdl.schema.json): model documents
- [`schemas/osdl.library.schema.json`](schemas/osdl.library.schema.json): component library definitions
- [`schemas/osdl.events.schema.json`](schemas/osdl.events.schema.json): the simulation event stream
- [`schemas/osdl.results.schema.json`](schemas/osdl.results.schema.json): recorded results
- [`libraries/`](libraries/): optional component libraries
- [`contracts/reference-machine/CONTRACT.md`](contracts/reference-machine/CONTRACT.md): the optional component runtime and run-control implementation contract
- [`machine/`](machine/): the executable Lean reference machine
- [`machine/README.md`](machine/README.md): reference machine scope and use

The schemas define document, event, and result structure. This document defines current core behavior. A library specification defines behavior for its namespace and version. An implementation contract applies only when a runner selects it.

## 1. Conformance

The words must, must not, should, and may carry their RFC 2119 requirement force.

Every engine implements OSDL Core. Three conformance roles exist:

- A producer (editor, SDK, generator) emits OSDL documents. Producers must emit documents valid against the model schema.
- A consumer (renderer, linter, documentation tool) reads OSDL documents. Consumers must accept any valid document, and must ignore `metadata` content and `views` they do not understand.
- An engine executes OSDL documents. Engines must implement the core execution semantics. An engine must implement a component library only when it declares support for that library namespace and version. It must refuse a document that uses an unsupported component type.

Implementations compare recorded results and portable events on conformance cases. They may use different calendars, storage, callbacks, and telemetry. Those design choices are conformant when valid documents, recorded results, and portable events remain compatible.

A conformance module can extend another module. A child module may add cases and assertions or make a comparison stricter. It must not reinterpret a parent field, change a parent recorded result, replace a parent case, or weaken a parent requirement. A runner resolves the extension graph, rejects cycles, and runs parent suites before child suites.

An implementation contract adds rules for an implementation class. A runner, build configuration, or test harness selects the contract outside an OSDL document. An OSDL document does not select an implementation contract.

## 2. Document structure

A model document is a single JSON object:

| Field | Required | Purpose |
|---|---|---|
| `osdl` | yes | Spec version. Exactly `"0.1"` for this version. |
| `model` | yes | The model: parameters, components, connections (section 3). |
| `experiments` | no | Run configurations (section 9). |
| `views` | no | Presentation-only layout (section 11). |
| `metadata` | no | Free-form extension data (section 13). |

Documents should use the extension `.osdl.json`.

## 3. Names and references

- Identifiers (`id`, `name`, parameter names, state ids, port ids) match `^[A-Za-z_][A-Za-z0-9_-]*$`. Component ids must be unique within their model scope; parameter names must be unique within their model.
- Type names are namespaced: `des.queue`, `abm.population`. The namespace identifies the library that defines the type (section 12). The namespaces `core`, `des`, `abm`, and `sd` are reserved.
- Port references (`from`/`to` in connections) take the form `componentId.portId` and must refer to a sibling component in the same model scope.
- State paths address observable state: `componentId.stateId` (e.g. `teller.utilization`). Paths may have more segments where a library defines dynamic state (e.g. `patients.inState.sick`).

## 4. The model

### 4.1 Time

`model.time.unit` declares the unit of simulation time (default `ticks`). Every duration, delay, rate, and `dt` in the model is expressed in this unit. `time.start` may map t = 0 to a number or an ISO 8601 date-time; engines and tools may use it to display calendar time. `time.integration` configures continuous integration (section 8.4).

### 4.2 Parameters

`model.parameters` declares the model's tunable inputs: name, type (`number`, `integer`, `boolean`, `string`), default, optional bounds, choices, and unit. Parameters are referenced from value positions with `{"param": "name"}` and from expressions by bare name. Experiments override defaults (section 9). A parameter reference to an undeclared name is an error at load time.

## 5. Components

A component is an instance of a type defined in a library: `{"id": ..., "type": ..., "params": {...}}`. The library definition (section 12) determines what ports it exposes, what its `params` mean, what state it publishes, and what events it emits.

Validation has two phases:

1. The document is validated against the model schema. This checks structure but treats every `params` object as opaque.
2. Each component's `params` is validated against the params schema published in its type's library definition.

Both phases are mechanical JSON Schema validation; the second requires the relevant library definitions, with the core schema registered for `$ref` resolution.

## 6. Ports and connections

A connection joins an out port to an in port: `{"from": "a.out", "to": "b.in"}`. Direction is data/entity flow.

- A port accepts at most one connection unless its library definition sets `multiple: true`.
- Multiple connections on a `multiple` out port have library-defined fan-out semantics (e.g. `des.router` selects exactly one per entity). Multiple connections on a `multiple` in port merge (fan-in).
- Connections may carry `params` interpreted by the endpoint component types.
- A connection `id` is optional but required for the connection to be referenced from a view route.

### 6.1 Port kinds

A library definition declares each port's kind: `entity`, `message`, or `value`. The default is `entity`. A connection must join two ports of the same kind, out to in. Engines must reject a document whose connections violate declared direction, kind, or multiplicity before execution, and must resolve every connection to a stable prepared route before a run starts. Routing behavior must not depend on undocumented array positions.

- Entity ports carry entities under the escrow transfer protocol of section 6.2.
- Message ports deliver immutable payloads at the current simulation time with no custody: delivery is fire-and-forget and emits `message.sent`.
- Value ports carry typed scalar values. Publishing a value output delivers the value to every connected input at the current simulation time and emits `value.changed`; the receiving library's value-delivery contract defines how the component observes the change.

### 6.2 Entity transfer

Entity transfer uses kernel escrow with an explicit acceptance decision. When a sender sends an entity through a prepared route, the engine assigns the transfer a persistent transfer identity, takes the exact entity into escrow, and delivers it to the receiving component at the current simulation time. The receiver returns one of two decisions:

- `accept`: the entity moves atomically at the current simulation time and the engine emits `entity.moved`. The sender observes a `delivered` send result for the transfer.
- `block`: the exact entity remains in engine escrow, custody remains with the sender, and the sender observes a `blocked` send result carrying the transfer identity and no entity value. A full bounded queue is one reason to block.

One transfer identity persists through the pending and blocked states, and each transfer has exactly one current or terminal result: `delivered`, `blocked`, or `cancelled`. A sender may cancel its own transfer before acceptance; the transfer becomes `cancelled` and custody of the entity stays with the sender. A receiver cannot return, replace, or retain a blocked entity: the acceptance decision carries no entity value. Engines must not lose, duplicate, or substitute entities.

When a receiver later reports readiness for an input port, the engine redelivers blocked transfers destined to that port, oldest first. The exact readiness correlation, targeted retry operation, and multi-route retry order are provisional in this draft, pending an identity-based transfer prototype; the redelivery rule in the [reference machine contract](contracts/reference-machine/CONTRACT.md) is the interim behavior.

## 7. Values

Component params, trigger arguments, and action values use these value forms:

| Form | Example | Meaning |
|---|---|---|
| Literal | `0.9`, `"fifo"`, `true` | A constant. Plain strings are always literals. |
| Parameter reference | `{"param": "arrivalRate"}` | The current value of a model parameter. |
| Expression | `{"expr": "1 / treatmentTime"}` | Evaluated in the OSDL expression language (section 7.3). |
| Distribution | `{"dist": "exponential", "rate": 0.9}` | A random variate, re-sampled at each use (section 7.2). |

Schema positions narrow which forms are allowed: `scalarValue` excludes distributions; `numericValue` allows all numeric forms.

### 7.1 Sampling

A distribution in a param is sampled once per use as defined by the component (e.g. `des.source.interarrival` per creation, `des.server.serviceTime` per entity). Distribution arguments may themselves be parameter references or expressions, evaluated at sample time.

### 7.2 Distributions

`constant(value)`, `uniform(min, max)`, `exponential(rate)`, `normal(mean, std)`, `lognormal(mu, sigma)`, `triangular(min, mode, max)`, `weibull(shape, scale)`, `gamma(shape, scale)`, `beta(alpha, beta)`, `poisson(rate)`, `binomial(n, p)`, `bernoulli(p)`, `geometric(p)`, `discrete(values)`, `empirical(samples)`. Rates are per model time unit. Parameter names and semantics are fixed by the model schema.

Sampler algorithms are part of this specification. Determinism pins both the RNG in section 8.1 and the exact algorithm that turns uniform bits into variates. The algorithms are inverse-CDF for the closed-form univariates, Box-Muller (cosine branch) for the normal, and pinned compositions (Marsaglia-Tsang, gamma ratios, Knuth) for the rest. Each algorithm has a defined draw count. The executable definitions live in the Lean reference machine at [`machine/Machine/Samplers.lean`](machine/Machine/Samplers.lean). Fixed cases in [`machine/GenerateVectors.lean`](machine/GenerateVectors.lean) generate the committed per-distribution vectors. Adopting these samplers replaced the previously unspecified library algorithms in a one-time seed break. The determinism promise of section 8.1 is per OSDL version until 1.0.

### 7.3 Expressions

Expressions are strings in a small, total, side-effect-free language:

```ebnf
expr           = or ;
or             = and { "||" and } ;
and            = comparison { "&&" comparison } ;
comparison     = additive { ( "<" | "<=" | ">" | ">=" | "==" | "!=" ) additive } ;
additive       = multiplicative { ( "+" | "-" ) multiplicative } ;
multiplicative = unary { ( "*" | "/" | "%" ) unary } ;
unary          = [ "-" | "!" ] power ;
power          = primary [ "^" unary ] ;
primary        = number | "true" | "false" | reference | call | "(" expr ")" ;
reference      = identifier { "." identifier } ;
call           = identifier "(" [ expr { "," expr } ] ")" ;
```

Built-in functions: `abs`, `min`, `max`, `floor`, `ceil`, `round`, `sqrt`, `exp`, `ln`, `log10`, `pow(x, y)`, `sin`, `cos`, `tan`, `if(cond, a, b)`, `time()` (current simulation time). Constants: `pi`, `e`. Chained comparisons compare adjacent operands, so `a < b < c` is equivalent to `a < b && b < c`.

Reference resolution uses this order: agent attributes in agent scope, model parameters from the inner scope outward, then component state paths (`componentId.stateId`). An unresolvable reference is an error at load time. Numbers are IEEE 754 doubles. Booleans coerce to `1` or `0` in numeric positions. Division by zero and domain-invalid or non-finite math results are run-time errors.

## 8. Execution semantics

OSDL Core defines observable semantics: event ordering, entity escrow and custody, port behavior, state publication, run completion, recorded results, and portable events. It does not require a particular class hierarchy, callback layout, calendar representation, or programming language. Components react to typed events and issue commands; the concrete authoring interface for the reference machine is the component runtime contract in [`contracts/reference-machine/CONTRACT.md`](contracts/reference-machine/CONTRACT.md), which an implementation adopts explicitly.

### 8.1 The kernel

Execution uses one simulation clock per run. Scheduled work is ordered by `(time, insertion sequence)`. Ties in time execute in scheduling order. All paradigms share these observable scheduling semantics. There is no user-controlled event priority. An implementation may use a different internal calendar or scheduler when it preserves the defined results and portable events.

Timers have identity. A component schedules a timer at a relative delay or an absolute time and receives a timer identifier. A pending timer can be cancelled or rescheduled; a rescheduled timer receives a new insertion sequence. Engines must reject non-finite times, negative relative delays, absolute times in the past, and overflowed times. Cancelling a timer that is not pending is a no-op; rescheduling one is an error. The last two rules are provisional pending the timer negative-case prototype.

Observable component state is typed: a published state value is a number, integer, boolean, or string. Absence is an absent observation, never a published null. Numeric positions coerce integers by widening and booleans to `1`/`0`; strings do not coerce, and a numeric expression that reads a string observation is a run-time error. State publication is distinct from event emission and from value-port delivery.

An engine separates immutable model preparation from run instances. Preparation resolves and validates topology, ports, routes, parameters, expressions, distributions, outputs, and state references; one prepared model supports many runs. Each run exposes structured run control: `step` executes exactly one calendar-dispatch semantic unit; `run` is equivalent to repeated `step` until a terminal status; inclusive `runThrough` processes every scheduled event at or before a target time and stops before the first event after it; `nextEventTime` reports the next scheduled time. External input is admitted only through validated external ports at explicit simulation times, ordered by the same calendar mechanism as internal events; each admitted input becomes an immutable run-owned record with a deterministic admission ordinal, and input at a non-finite or past time is rejected without effect. A host may request cancellation; the request is observed between dispatch transactions.

Every terminal execution path produces one run report containing the run status, final time, recorded results, the complete available trace, and diagnostics. Run status is one of:

- Completed, with reason `endTime` (the next event lies past the configured duration), `condition` (a `stopWhen` expression became nonzero), `requested` (a component requested completion), or `quiescent` (the calendar is empty before the end time). Component finalization runs only for normal completion and receives the reason.
- Failed: a semantic model or component failure, carrying a structured diagnostic.
- Aborted, with reason `budgetExceeded` or `cancelled`. These are host or implementation-policy outcomes, not semantic failures; execution budgets are implementation policy and must not change portable outputs for valid runs.

Diagnostics are structured: a stable code, a message, and, when known, the component, the operation, the simulation time, and the document location. Tools must not need to parse human-readable messages.

A run is a pure function of `(document, experiment, parameters, seed, admitted external inputs)`. Within an engine version, replay of that tuple is bit-exact. This draft makes the determinism promise per OSDL version.

Cross-implementation conformance compares recorded results and portable events. It does not require exact raw trace equality. Runtime budgets, capability validation, telemetry cadence, callback layout, and other implementation policy are not core semantics. An implementation contract can define those rules for implementations that select it.

### 8.2 Discrete events (DES)

The optional [`des` library](libraries/des/SPEC.md) defines discrete-event component behavior. DES components react to entity arrivals, timer events, and send results, mutate their state, and send entities per the core transfer rules in section 6. State changes are visible immediately to subsequent events.

### 8.3 Agents (ABM)

The optional [`abm` library](libraries/abm/SPEC.md) defines agent-based component behavior. Agent transitions, messages, and entity transfers use the core clock, values, connections, and event envelopes. An engine has no ABM obligation unless it declares support for the `abm` namespace and version.

### 8.4 Continuous dynamics (SD)

The optional [`sd` library](libraries/sd/SPEC.md) defines system dynamics component behavior. `time.integration.dt` defines observable integration boundaries on the shared simulation clock. The boundaries occur at each `dt` interval from the run start. The value is `1.0` model time units when `dt` is omitted.

Discrete events at an integration boundary observe stock values from before the boundary update. The updated values become visible after all work at that simulation time is complete. An implementation may use any internal integration design that preserves these boundary values, recorded results, and portable events. An engine has no SD obligation unless it declares support for the `sd` namespace and version.

## 9. Experiments

An experiment names a run configuration: `duration` (required), `warmup` (excluded from outputs), `replications`, `seed`, fixed parameter overrides, an optional `sweep`, recorded `outputs`, and an optional `stopWhen` expression.

- A sweep runs the cross product of all entries' value lists; each point in the product runs `replications` times.
- Replication `r` of scenario `s` uses an RNG stream deterministically derived from `(seed, s, r)`.
- An output is an object with `path` and `records`. Each entry in `records` is a `summary`, `timeseries`, or `final` recorder. A `summary` recorder requires a numeric or integer observable. It computes time-weighted statistics over the post-warmup run. A `timeseries` recorder requires a number or integer observable. It records every `interval`, or on change when `interval` is omitted. A `final` recorder accepts number, integer, boolean, and string observables. It records the value at the end of the run. An engine must reject a recorder that does not support the observable's declared state type. An output can use `as` to select its result key. Otherwise, the state path is the result key.

For example, this output records a summary and final value for one path:

```json
{
  "path": "teller.utilization",
  "records": [
    {"type": "summary", "statistics": ["mean", "max"]},
    {"type": "final"}
  ]
}
```

### 9.1 Recorded result comparison

[`schemas/osdl.results.schema.json`](schemas/osdl.results.schema.json) defines the recorded result exchange format. Result keys use the output `as` value when present and the output `path` otherwise. Each key maps to an object whose `summary`, `timeseries`, and `final` members match the configured recorder types.

Recorded values use the observable's declared state type. JSON numbers represent both number and integer state. A `final` result may use `null` when no final value is available. Summary statistics are always numbers.

Cross-implementation result comparison applies these rules:

- The defined JSON structure must match.
- JSON object member order does not matter.
- Array order matters.
- Time-series point order matters.
- Numeric values use the precision rule declared by the conformance case.
- A case that pins deterministic sampler output uses bit-exact floating-point values.

## 10. Event stream

Engines must emit the typed event stream defined by [`osdl.events.schema.json`](schemas/osdl.events.schema.json). Every event carries the envelope `(v, seq, time, type, source)`. Event payloads, when present, must be JSON objects. `seq` orders emission within one raw stream. Transports are not specified. In-process callbacks, WebSocket frames, and newline-delimited JSON are conformant transports.

### 10.1 Current typed events

The current typed event types are `sim.started`, `sim.progress`, `sim.completed`, `sim.error`, `sim.aborted`, `entity.created`, `entity.moved`, `entity.disposed`, `state.changed`, `value.changed`, `param.changed`, `metric.updated`, `agent.transitioned`, and `message.sent`.

A run's raw trace terminates with exactly one terminal frame matching its status: `sim.completed {reason}` for normal completion, `sim.error` carrying the structured diagnostic for failure, or `sim.aborted {reason}` for host or policy abortion.

Libraries can declare additional types in their definitions. Models emit custom types through the `emit` action. Subscribers must ignore event types they do not understand.

`sim.progress`, `state.changed`, and `metric.updated` are telemetry events. They are valid event-envelope data, but portable event comparison excludes them. Implementations may use different telemetry cadence and content unless an implementation contract requires exact telemetry.

`state.changed` uses the observable's declared state type. `metric.updated` uses the same value types as recorded results. It can use `null` when no recorded value is available.

Engines should let subscribers filter by type and source. They may throttle high-frequency telemetry for remote transports. They must not drop completion, error, abortion, creation, disposal, parameter, agent, message, library, or model events.

### 10.2 Portable event comparison

Portable events represent required external behavior. They include lifecycle completion and errors, entity events, parameter changes, events defined by a supported library, and events declared by a model. Recorded results remain the primary cross-implementation output.

Portable event comparison applies these rules:

1. Remove telemetry events.
2. Remove `seq` and `wallTime` from each event.
3. Preserve event order within a causal identity, such as one entity or agent.
4. Allow independent events at the same simulation time to appear in a different order.
5. Preserve global order when no safe causal identity is available.

The full event stream remains a diagnostic artifact. An implementation contract can require exact raw trace equality.

## 11. Views

Views carry presentation only: canvas positions, sizes, and edge routes keyed by component and connection ids. Views must not affect simulation results. Engines must ignore them; editors should preserve views they do not understand. This separation keeps semantic diffs clean: a layout change touches `views`, a behaviour change touches `model`.

## 12. Library definitions

A component library is the contract between an engine plugin and every OSDL tool. Its definition document declares the library's `namespace`, `version`, and one entry per component type: ports (direction, kind, multiplicity), a JSON Schema for `params` (which may `$ref` the core schema's value definitions), observable `state` variables with their scalar types, emitted events, and a required prose `description`: the semantic contract, written for humans and language models alike.

From a library definition alone, with no engine present, a tool can render palettes, generate parameter forms, validate documents (phase two), power autocompletion, and prompt a language model with precise component semantics.

The standard `des`, `abm`, and `sd` libraries are optional conformance modules in [`libraries/`](libraries/). An implementation declares support for a library namespace and version outside an OSDL document. It must run that library's conformance suite when it claims support. Supporting one library does not require support for another library. Third-party libraries use their own namespaces.

## 13. Versioning and extensibility

- The `osdl` field pins the exact spec version. Tools must reject documents declaring versions they do not implement.
- v0.x versions make no compatibility promises. This draft remains versioned as `0.1`.
- `metadata` objects are the extension escape hatch, allowed on most objects. Keys should be reverse-DNS namespaced. Metadata must not affect simulation semantics; anything that does belongs in the schema, a library definition, or a spec proposal.
- Component libraries version independently of the specification by semantic versioning.

[`ROADMAP.md`](ROADMAP.md) records planned post-1.0 behavior and version policy.
