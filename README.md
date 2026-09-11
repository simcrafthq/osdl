<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-mark.svg">
    <img src="assets/logo-mark-dark.svg" alt="Simcraft" width="92">
  </picture>
</p>

# Open Simulation Definition Language

The Open Simulation Definition Language (OSDL) is a vendor-neutral JSON format
for discrete-event, agent-based, system dynamics, and hybrid simulation models.
This repository defines OSDL version `0.1`, which is a draft.

The repository contains the language specification, JSON Schemas, standard
component libraries, validated examples, and an executable Lean reference
machine.

## Repository contents

| Path | Contents |
|---|---|
| [`SPEC.md`](SPEC.md) | Document structure, value forms, execution semantics, event stream, and conformance rules. |
| [`schemas/osdl.schema.json`](schemas/osdl.schema.json) | JSON Schema draft 2020-12 model document schema. |
| [`schemas/osdl.library.schema.json`](schemas/osdl.library.schema.json) | Component library definition schema. |
| [`schemas/osdl.events.schema.json`](schemas/osdl.events.schema.json) | Typed simulation event schema. |
| [`schemas/osdl.results.schema.json`](schemas/osdl.results.schema.json) | Simulation results schema. |
| [`schemas/osdl.conformance.schema.json`](schemas/osdl.conformance.schema.json) | Conformance manifest schema. |
| [`schemas/osdl.machine-fixture.schema.json`](schemas/osdl.machine-fixture.schema.json) | Declarative machine fixture schema. |
| [`libraries/`](libraries/) | Standard `des`, `abm`, and `sd` component libraries. |
| [`examples/`](examples/) | Validated M/M/1, SIR, and hybrid clinic models. |
| [`conformance/`](conformance/) | Portable OSDL Core conformance cases. |
| [`machine/`](machine/) | Executable Lean reference machine. |
| [`STATUS.md`](STATUS.md) | Current repository status. |
| [`ROADMAP.md`](ROADMAP.md) | Planned future work. |
| [`contracts/`](contracts/) | Public implementation contracts. |

## Validation

Install Node.js 22 and the Lean 4 toolchain selected by
[`machine/lean-toolchain`](machine/lean-toolchain). Run the validator from the
repository root:

```sh
bash validate.sh
```

The command runs the Node contract tests. It then validates OSDL documents and
libraries with the Node validator. The validator compiles all six schemas and
checks each library document before it compiles component parameter schemas.
When `lake` is available, the command builds the Lean reference machine and
checks the conformance catalogue. `bash validate.sh` generates conformance
artifacts in a temporary directory and compares them with the committed
artifacts. It does not rewrite committed artifacts. The command also regenerates
the golden vectors and fails if they differ from
`machine/vectors/golden.txt`. It then runs the vector, resolution-round, and
safeguard checks.

Set `OSDL_REQUIRE_LEAN=1` to fail when `lake` is unavailable. Continuous
integration uses this mode:

```sh
OSDL_REQUIRE_LEAN=1 bash validate.sh
```

## Component parameter validation

Model validation has two phases. First it validates the complete document
against the model schema. Then it validates each component `params` object
against its library definition. `bash validate.sh` performs both phases.

## Conformance

Run a portable conformance suite against an implementation output directory:

```sh
npm run conformance -- <manifest> <actual-directory>
```

For example, run the OSDL Core suite against files under `path/to/actual`:

```sh
npm run conformance -- conformance/core/manifest.json path/to/actual
```

The command runs the parent suites before the selected suite. An implementation
selects component libraries and implementation contracts outside an OSDL model
document.

For each selected case, place actual outputs in `<actual-directory>`. Use the
exact names `<case-id>.results.json`, `<case-id>.events.ndjson`, and
`<case-id>.trace.ndjson` for the artifacts that the manifest declares.
Portable expected event files omit `seq` and `wallTime`. Actual event files
contain valid event envelopes. Portable comparison ignores their `seq` and
`wallTime` fields.

Run conformance commands in a trusted workspace. The runner rejects paths and
symbolic links that escape a manifest directory. It assumes that no untrusted
process replaces checked files or directories while the command runs.

Result assertions use `comparison.floatMode`. The default is `bits`. Mode
`bits` requires equal IEEE 754 binary64 values and distinguishes positive zero
from negative zero. Mode `number` uses numeric equality and treats both zero
signs as equal. A child conformance module can preserve an inherited policy or
strengthen `number` to `bits`. It cannot weaken `bits` to `number`.

Use this command only when the committed generated artifacts must change:

```sh
npm run conformance:update
```

This command rewrites the committed conformance artifacts. Review all generated
changes before submission. Repository validation uses a separate temporary
directory and only checks for drift.

## Status

Version `0.1` is a draft. Current OSDL `0.1` behavior is in
[`SPEC.md`](SPEC.md). Planned `1.0` and post-`1.0` work is in
[`ROADMAP.md`](ROADMAP.md).

## AI-assisted contributions

This project permits AI-assisted contributions. Contributors remain responsible
for submitted work. External contributors must follow the
[`AI usage policy`](AI_POLICY.md).

## License

OSDL is licensed under the Apache License 2.0. See [`LICENSE`](LICENSE).
