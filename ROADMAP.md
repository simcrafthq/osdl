# OSDL roadmap

## Additive releases after 1.0

OSDL 1.0 will be the current executable surface, hardened and backed by conformance tests. Growth after 1.0 will use additive minor versions.

Planned additive minors include:

- Resource pools and seize/release for DES.
- Batching and matching.
- SD lookup tables and delays.
- Spatial ABM.
- Edge-triggered ABM condition transitions.
- Typed entity payload schemas.
- Model imports and library references across files.
- `core.composite`, when composition is executable.
- Structural schema slots for connection params.
- A third-party namespace registry.

From 1.0, minor versions will be additive. Patch versions will not change the results of valid seeded runs. Seeds will remain stable across minor and patch releases. A change that alters the results of a valid seeded run will require a major version.
