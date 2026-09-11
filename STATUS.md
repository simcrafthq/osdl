# OSDL status

This table separates current public rules, implementation-specific rules, and planned work.

| Surface | Defined by | Conformance suite | Status |
|---|---|---|---|
| OSDL document structure and complete validation | [`SPEC.md`](SPEC.md) and [`schemas/osdl.schema.json`](schemas/osdl.schema.json) | [`test/validate-osdl.test.mjs`](test/validate-osdl.test.mjs) | defined and tested |
| Component library document structure | [`schemas/osdl.library.schema.json`](schemas/osdl.library.schema.json) | [`test/validate-osdl.test.mjs`](test/validate-osdl.test.mjs) | defined and tested |
| Recorded result structure | [`SPEC.md`](SPEC.md) and [`schemas/osdl.results.schema.json`](schemas/osdl.results.schema.json) | [`test/schema-contracts.test.mjs`](test/schema-contracts.test.mjs) | defined and tested |
| Typed event envelopes and payloads | [`SPEC.md`](SPEC.md) and [`schemas/osdl.events.schema.json`](schemas/osdl.events.schema.json) | [`test/events.test.mjs`](test/events.test.mjs) | defined and tested |
| Core value, expression, experiment, and portable event behavior | [`SPEC.md`](SPEC.md) | [`conformance/core/`](conformance/core/) | defined and tested |
| DES component behavior | [`libraries/des/SPEC.md`](libraries/des/SPEC.md) | [`libraries/des/conformance/`](libraries/des/conformance/) | defined and tested |
| ABM component behavior | [`libraries/abm/SPEC.md`](libraries/abm/SPEC.md) | [`libraries/abm/conformance/`](libraries/abm/conformance/) | defined |
| SD component behavior | [`libraries/sd/SPEC.md`](libraries/sd/SPEC.md) | [`libraries/sd/conformance/`](libraries/sd/conformance/) | defined |
| Optional Lean reference-machine `PreparedRun` validation, escrowed transfer outcomes, raw callback order, golden-vector codec checks, raw traces, and implementation policy | [`contracts/reference-machine/CONTRACT.md`](contracts/reference-machine/CONTRACT.md) | [`contracts/reference-machine/conformance/`](contracts/reference-machine/conformance/) | implementation contract, defined and tested |
| Additive behavior after 1.0 | [`ROADMAP.md`](ROADMAP.md) | none | planned |

The Core and DES manifests contain cases. The ABM and SD case arrays are empty.
