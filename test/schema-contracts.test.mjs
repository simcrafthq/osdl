import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import {fileURLToPath} from "node:url";

import * as validation from "../scripts/lib/validate-osdl.mjs";

const {validateManifest, validateResults} = validation;
const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

const results = {
  busy: {
    summary: {stats: {mean: 0.5, count: 4}},
    timeseries: {times: [0, 1], values: [0, 1]},
    final: {value: 1}
  }
};

const manifest = {
  osdl: "0.1",
  kind: "library",
  id: "des",
  version: "0.1.0",
  extends: ["core@0.1.0"],
  cases: [{
    id: "des.pipeline",
    input: {format: "osdl", path: "cases/pipeline.osdl.json"},
    expected: {results: "expected/pipeline.results.json"}
  }]
};

test("accepts recorded results", () => {
  assert.deepEqual(validateResults(results), []);
});

test("accepts recorded results with state-path output keys", () => {
  assert.deepEqual(validateResults({
    "q.length": {final: {value: 3}},
    "snk.count": {summary: {stats: {count: 3}}}
  }), []);
});

test("accepts boolean and string final recorder values", () => {
  assert.deepEqual(validateResults({
    active: {final: {value: true}},
    phase: {final: {value: "busy"}}
  }), []);
});

test("retains null as a valid final recorder value", () => {
  assert.deepEqual(validateResults({pending: {final: {value: null}}}), []);
});

test("rejects non-numeric summary statistics", () => {
  assert.ok(validateResults({
    active: {summary: {stats: {last: true}}}
  }).some(({code}) => code === "type"));
});

test("rejects non-numeric time-series values", () => {
  for (const value of [null, true, "busy", {phase: "busy"}, ["busy"]]) {
    assert.ok(validateResults({
      phase: {timeseries: {times: [0], values: [value]}}
    }).length > 0);
  }
});

test("accepts a conformance manifest", () => {
  assert.deepEqual(validateManifest(manifest), []);
});

test("accepts inherited artifact assertions with result comparison policy", () => {
  const asserted = structuredClone(manifest);
  asserted.assertions = [
    {
      case: "des.pipeline",
      results: {comparison: {floatMode: "bits"}}
    },
    {
      case: "core.pipeline",
      trace: {path: "expected/core.pipeline.trace.ndjson"}
    }
  ];

  assert.deepEqual(validateManifest(asserted), []);
});

test("rejects an unknown result comparison mode", () => {
  const invalid = structuredClone(manifest);
  invalid.assertions = [{
    case: "des.pipeline",
    results: {comparison: {floatMode: "approximate"}}
  }];

  assert.ok(validateManifest(invalid).some(({code}) => code === "enum"));
});

test("rejects unequal result time-series lengths", () => {
  const invalid = structuredClone(results);
  invalid.busy.timeseries.values = [0];

  assert.deepEqual(validateResults(invalid), [{
    phase: "results-schema",
    code: "timeseries-length",
    path: "/busy/timeseries/values",
    message: "times and values must have equal lengths",
    document: "<memory>",
    componentId: null,
    componentType: null,
    library: null
  }]);
});

test("rejects an unknown conformance manifest kind", () => {
  const invalid = structuredClone(manifest);
  invalid.kind = "plugin";

  assert.ok(validateManifest(invalid).some(({code}) => code === "enum"));
});

test("rejects duplicate conformance case IDs", () => {
  const invalid = structuredClone(manifest);
  invalid.cases.push(structuredClone(invalid.cases[0]));

  assert.deepEqual(validateManifest(invalid), [{
    phase: "manifest-schema",
    code: "duplicate-case-id",
    path: "/cases/1/id",
    message: "duplicate case id: des.pipeline",
    document: "<memory>",
    componentId: null,
    componentType: null,
    library: null
  }]);
});

test("rejects empty expected conformance data", () => {
  const invalid = structuredClone(manifest);
  invalid.cases[0].expected = {};

  assert.ok(validateManifest(invalid).some(({code}) => code === "minProperties"));
});

test("rejects extra conformance input fields", () => {
  const invalid = structuredClone(manifest);
  invalid.cases[0].input.extra = true;

  assert.ok(validateManifest(invalid).some(({code}) => code === "additionalProperties"));
});

test("defines the required conformance module graph", async () => {
  const manifests = await Promise.all([
    "conformance/core/manifest.json",
    "libraries/des/conformance/manifest.json",
    "libraries/abm/conformance/manifest.json",
    "libraries/sd/conformance/manifest.json",
    "contracts/reference-machine/manifest.json"
  ].map(async relativePath => JSON.parse(await readFile(path.join(rootDir, relativePath), "utf8"))));
  const [core, des, abm, sd, referenceMachine] = manifests;

  assert.deepEqual(
    manifests.map(({id, version, kind, extends: parents = []}) => ({id, version, kind, parents})),
    [
      {id: "core", version: "0.1.0", kind: "core", parents: []},
      {id: "des", version: "0.1.0", kind: "library", parents: ["core@0.1.0"]},
      {id: "abm", version: "0.1.0", kind: "library", parents: ["core@0.1.0"]},
      {id: "sd", version: "0.1.0", kind: "library", parents: ["core@0.1.0"]},
      {
        id: "reference-machine",
        version: "0.1.0",
        kind: "contract",
        parents: ["core@0.1.0", "des@0.1.0"]
      }
    ]
  );
  assert.deepEqual(core.cases.map(({id}) => id), [
    "timers.machine",
    "pipeline.machine",
    "backpressure.machine",
    "valuescope.machine",
    "paramoverride.machine",
    "paramoverridecascade.machine",
    "rngpair.machine",
    "stopper.machine",
    "threshold.machine",
    "exprerr.machine",
    "errsend.machine",
    "componenterr.machine"
  ]);
  assert.deepEqual(des.cases.map(({id}) => id), ["pipeline.osdl", "recorders.osdl"]);
  assert.deepEqual(abm.cases, []);
  assert.deepEqual(sd.cases, []);
  assert.deepEqual(
    referenceMachine.cases.map(({id}) => id),
    ["roundtick.contract", "rounderr.contract"]
  );
  assert.equal("status" in abm, false);
  assert.equal("status" in sd, false);
  for (const entry of manifests) assert.deepEqual(validateManifest(entry), []);
});

test("validates machine fixtures through bundled and loaded artifacts", async () => {
  const fixture = {
    format: "osdl-machine-fixture/0.1",
    behavior: "timers",
    behaviorContract: "../README.md#timers",
    arguments: {}
  };

  assert.equal(typeof validation.validateMachineFixture, "function");
  assert.deepEqual(validation.validateMachineFixture(fixture), []);

  const artifacts = await validation.loadArtifacts(rootDir);
  assert.equal(typeof artifacts.validateMachineFixture, "function");
  assert.deepEqual(artifacts.validateMachineFixture(fixture), []);
  const diagnostics = artifacts.validateMachineFixture({...fixture, extra: true});
  assert.ok(diagnostics.length > 0);
  assert.ok(diagnostics.every(({phase}) => phase === "machine-fixture"));
});

test("rejects malformed machine fixtures with machine-fixture diagnostics", () => {
  const fixture = {
    format: "osdl-machine-fixture/0.1",
    behavior: "timers",
    behaviorContract: "../README.md#timers",
    arguments: {}
  };
  const invalidFixtures = [
    {...fixture, format: "osdl-machine-fixture/0.2"},
    {...fixture, behavior: "Timer"},
    {...fixture, behaviorContract: ""},
    {...fixture, behaviorContract: []},
    {...fixture, arguments: []},
    {...fixture, extra: true},
    {format: fixture.format}
  ];

  for (const invalid of invalidFixtures) {
    const diagnostics = validation.validateMachineFixture(invalid);
    assert.ok(diagnostics.length > 0);
    assert.ok(diagnostics.every(({phase}) => phase === "machine-fixture"));
  }
});
