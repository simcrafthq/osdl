# Contributing

Contributions must keep the specification, schemas, libraries, examples, and
reference machine consistent.

## Required check

Run the repository validator before submitting a change:

```sh
bash validate.sh
```

The command requires Node.js 22. Install the Lean 4 toolchain selected by
`machine/lean-toolchain` to include the reference-machine checks. Continuous
integration requires both the schema and Lean checks to pass.

## AI-assisted contributions

External contributors who use AI tools must follow the
[`AI usage policy`](AI_POLICY.md).
