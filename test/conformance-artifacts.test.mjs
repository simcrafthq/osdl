import assert from "node:assert/strict";
import {accessSync, constants} from "node:fs";
import {
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rm,
  symlink,
  unlink
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {spawnSync} from "node:child_process";
import test from "node:test";
import {fileURLToPath} from "node:url";

import {loadSuite} from "../scripts/lib/conformance-suite.mjs";
import {TELEMETRY_TYPES} from "../scripts/lib/conformance.mjs";
import {
  loadArtifacts,
  validateDocument,
  validateManifest
} from "../scripts/lib/validate-osdl.mjs";

const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const generatorPath = path.join(rootDir, "scripts/update-conformance.mjs");
const manifestPaths = [
  "conformance/core/manifest.json",
  "libraries/des/conformance/manifest.json",
  "libraries/abm/conformance/manifest.json",
  "libraries/sd/conformance/manifest.json",
  "contracts/reference-machine/manifest.json"
];
const publicAdapter = {
  manifest: "../manifest.json",
  cases: {
    "timers.machine": "timers",
    "pipeline.machine": "pipeline",
    "backpressure.machine": "backpressure",
    "valuescope.machine": "valuescope",
    "paramoverride.machine": "paramoverride",
    "paramoverridecascade.machine": "paramoverridecascade",
    "rngpair.machine": "rngpair",
    "stopper.machine": "stopper",
    "threshold.machine": "threshold",
    "exprerr.machine": "exprerr",
    "errsend.machine": "errsend",
    "componenterr.machine": "componenterr",
    "pipeline.osdl": "despipe",
    "recorders.osdl": "desstats",
    "roundtick.contract": "roundtick",
    "rounderr.contract": "rounderr"
  }
};
const publicOwnership = {
  core: Object.keys(publicAdapter.cases).filter(id => id.endsWith(".machine")),
  des: ["pipeline.osdl", "recorders.osdl"],
  abm: [],
  sd: [],
  "reference-machine": ["roundtick.contract", "rounderr.contract"]
};
const desComponents = [
  {
    id: "src",
    type: "des.source",
    params: {interarrival: 1, entityType: "src", limit: 4}
  },
  {id: "q", type: "des.queue", params: {capacity: 2}},
  {id: "srv", type: "des.server", params: {serviceTime: 1.5}},
  {id: "snk", type: "des.sink"}
];
const desConnections = [
  {from: "src.out", to: "q.in"},
  {from: "q.out", to: "srv.in"},
  {from: "srv.out", to: "snk.in"}
];
const expectedDesFixtures = {
  "pipeline.osdl": {
    $schema: "https://osdl.dev/schemas/0.1/osdl.schema.json",
    osdl: "0.1",
    model: {name: "despipe", components: desComponents, connections: desConnections},
    experiments: [{name: "workload", duration: 12, seed: 5}]
  },
  "recorders.osdl": {
    $schema: "https://osdl.dev/schemas/0.1/osdl.schema.json",
    osdl: "0.1",
    model: {name: "desstats", components: desComponents, connections: desConnections},
    experiments: [{
      name: "workload",
      duration: 12,
      warmup: 2,
      seed: 5,
      outputs: [
        {
          path: "q.length",
          records: [{
            type: "summary",
            statistics: [
              "mean",
              "std",
              "min",
              "max",
              "median",
              "p5",
              "p25",
              "p75",
              "p90",
              "p95",
              "p99",
              "count",
              "sum",
              "last"
            ]
          }]
        },
        {
          path: "srv.busy",
          as: "busy",
          records: [
            {type: "timeseries"},
            {type: "summary", statistics: ["mean"]}
          ]
        },
        {
          path: "q.length",
          as: "qlen2",
          records: [
            {type: "timeseries", interval: 2},
            {type: "summary", statistics: ["mean"]}
          ]
        },
        {path: "snk.count", records: [{type: "final"}]}
      ]
    }]
  }
};
const coreMachinePurposes = {
  timers: "Checks timer ordering for equal and different event times.",
  pipeline: "Checks accepted entity delivery through a source and sink.",
  backpressure: "Checks escrow blocking, readiness, and kernel redelivery.",
  valuescope: "Checks parameter, state, local expression, and sampling scopes.",
  paramoverride: "Checks one run-time parameter override at a dispatch boundary.",
  paramoverridecascade: "Checks cascading parameter overrides at one dispatch boundary.",
  rngpair: "Checks deterministic random streams for two components.",
  stopper: "Checks a component-requested stop.",
  threshold: "Checks expression-based stopping after a state change.",
  exprerr: "Checks expression failure during stop-condition evaluation.",
  errsend: "Checks the terminal error for a send without a route.",
  componenterr: "Checks a component-raised terminal error."
};
const coreMachineContractSnapshots = {
  timers: {
    Configuration: "Model `timers`, duration `10`, and seed `42`.",
    "Components and actions": "Component `t0` starts with integer state `0`. During `start`, it calls `scheduleAfter(1)`, `scheduleAfter(1)`, and `scheduleAfter(2.5)` in that order; the timers receive ids `1`, `2`, and `3`. On each `timerFired`, it increments its state, calls `publishState(\"fired\", state)`, calls `publishState(\"lastTimer\", timerId)`, and emits `fixture.timerFired` with payload `{\"timer\":timerId,\"count\":state}`.",
    Connections: "None.",
    "Observable boundaries": "At time `1`, the portable `fixture.timerFired` payloads are `{\"timer\":1,\"count\":1}` and then `{\"timer\":2,\"count\":2}`. At time `2.5`, the payload is `{\"timer\":3,\"count\":3}`. The portable event comparison is [`expected/timers.machine.events.ndjson`](expected/timers.machine.events.ndjson)."
  },
  pipeline: {
    Configuration: "Model `pipeline`, duration `5`, and seed `7`.",
    "Components and actions": "Component `src` starts with integer state `0`. During `start`, it creates a `job` entity, sends it through `out`, and changes its state to `1`. On a `delivered` send result, it creates and sends another `job` while its state is less than `3`, then increments its state. On a `blocked` send result, it calls `failRun(\"unexpected blocked transfer\")`. Component `snk` starts with integer state `0`. In `receive` for an arrival on `in`, it increments its state, calls `publishState(\"count\", state)`, disposes the arrival, and returns `accept`.",
    Connections: "`src.out` connects to `snk.in`.",
    "Observable boundaries": "Three `job` entities are accepted and moved at time `0`. Each `entity.disposed` event occurs before the matching `entity.moved` event. The portable event comparison is [`expected/pipeline.machine.events.ndjson`](expected/pipeline.machine.events.ndjson)."
  },
  backpressure: {
    Configuration: "Model `backpressure`, duration `5`, and seed `11`.",
    "Components and actions": "Component `src` starts with integer state `0`. During `start`, it creates a `job`, sends it through `out`, and increments its state. On a `delivered` send result, it creates and sends another `job` while its state is less than `2`, then increments its state. On a `blocked` send result, it does nothing: the entity waits in kernel escrow. Component `snk` starts with `busy = false` and count `0`. During `start`, it sets `busy = true` and calls `scheduleAfter(1)`. In `receive` while busy, it emits `fixture.blocked` with payload `{\"entityId\":entity.name,\"inputPort\":\"in\"}` and returns `block`. Otherwise, it increments the count, calls `publishState(\"count\", count)`, and returns `accept`. On `timerFired`, it emits `fixture.ready` with payload `{\"inputPort\":\"in\"}`, calls `reportReady(\"in\")`, and sets `busy = false`.",
    Connections: "`src.out` connects to `snk.in`.",
    "Observable boundaries": "The first delivery emits `fixture.blocked` for `job#1` at time `0`; the sender learns `blocked` once and the exact entity stays in kernel escrow. At time `1`, `fixture.ready` occurs before the kernel redelivers `job#1`, which the sink accepts. The `delivered` send result creates the second entity, which the sink also accepts at time `1`. The portable event comparison is [`expected/backpressure.machine.events.ndjson`](expected/backpressure.machine.events.ndjson)."
  },
  valuescope: {
    Configuration: "Model `valuescope`, duration `1`, seed `17`, and parameter `offset = 2`.",
    "Components and actions": "Component `v0` has no local control state. During `start`, it calls `publishState(\"base\", 3)` and reads its component identifier. It then evaluates parameter `offset`, evaluates `local + offset + v0.base` with local scope `local = 7` and `offset = 5`, and samples `uniform(local, local + 1)` with local scope `local = 7`. After those operations, it calls `publishState(\"parameter\", parameter)`, `publishState(\"evaluated\", evaluated)`, and `publishState(\"sampled\", sampled)` in that order. It emits `value.scope` with payload `{\"componentId\":componentId,\"parameter\":parameter,\"evaluated\":evaluated,\"sampled\":sampled}`.",
    Connections: "None.",
    "Observable boundaries": "The portable `value.scope` payload is `{\"componentId\":\"v0\",\"parameter\":2,\"evaluated\":15,\"sampled\":7.839622425333314}` at time `0`. The local `offset = 5` shadows the run parameter in the scoped expression. The sample uses the random stream for component `v0`. The portable event comparison is [`expected/valuescope.machine.events.ndjson`](expected/valuescope.machine.events.ndjson)."
  },
  paramoverride: {
    Configuration: "Model `paramoverride`, duration `4`, seed `17`, parameter `offset = 2`, and override `(afterSeq = 6, name = \"offset\", value = 5)`.",
    "Components and actions": "Component `v0` has no local control state. During `start`, it calls `scheduleAfter(1)`. On each `timerFired`, it evaluates parameter `offset`, adds `1`, calls `publishState(\"value\", result)`, emits `param.value` with payload `{\"value\":result}`, and calls `scheduleAfter(1)`.",
    Connections: "None.",
    "Observable boundaries": "Timer dispatches occur at times `1`, `2`, `3`, and `4`. The override becomes visible after the timer dispatch at time `3` and before the timer dispatch at time `4`. The emitted values are `3`, `3`, `3`, and `6`. The portable event comparison is [`expected/paramoverride.machine.events.ndjson`](expected/paramoverride.machine.events.ndjson)."
  },
  paramoverridecascade: {
    Configuration: "Model `paramoverridecascade`, duration `4`, seed `17`, parameters `bonus = 2` and `offset = 2`, and overrides `(afterSeq = 7, name = \"offset\", value = 5)` and `(afterSeq = 8, name = \"bonus\", value = 9)` in that order.",
    "Components and actions": "Component `v0` uses the same actions as [`paramoverride`](#paramoverride). The component does not evaluate `bonus`.",
    Connections: "None.",
    "Observable boundaries": "Timer dispatches occur at times `1`, `2`, `3`, and `4`. At the boundary after the time `3` dispatch, the first override produces the next sequence position and makes the second override due at the same boundary. `offset` changes before `bonus`. The emitted values are `3`, `3`, `3`, and `6`. The portable event comparison is [`expected/paramoverridecascade.machine.events.ndjson`](expected/paramoverridecascade.machine.events.ndjson)."
  },
  rngpair: {
    Configuration: "Model `rngpair`, duration `1`, and seed `20260702`.",
    "Components and actions": "Components `a` and `b` have no local control state and use the same behavior. During `start`, each component draws four unsigned 64-bit values from its component stream with `randomBits`. For draw `n`, it calls `publishState(\"d<n>\", draw >> 11)` after exact conversion to binary64. It then emits `machine.draws` with the four full-width values as base-10 strings in payload `{\"draws\":[draw1,draw2,draw3,draw4]}`. Component `a` runs `start` before component `b`.",
    Connections: "None.",
    "Observable boundaries": "Each component emits one `machine.draws` event at time `0`. Every `draws` member is a decimal string so JSON processing cannot round an unsigned 64-bit value. The seed and component identifier select each deterministic component stream. The portable event comparison is [`expected/rngpair.machine.events.ndjson`](expected/rngpair.machine.events.ndjson)."
  },
  stopper: {
    Configuration: "Model `stopper`, duration `10`, and seed `1`.",
    "Components and actions": "Component `c0` has no local control state. During `start`, it calls `scheduleAfter(3)`. On `timerFired`, it calls `stopRun()`.",
    Connections: "None.",
    "Observable boundaries": "The run completes at time `3` with reason `requested`. The portable event comparison is [`expected/stopper.machine.events.ndjson`](expected/stopper.machine.events.ndjson)."
  },
  threshold: {
    Configuration: "Model `threshold`, duration `10`, seed `3`, and `stopWhen = \"c0.count >= 3\"`.",
    "Components and actions": "Component `c0` starts with integer state `0`. During `start`, it calls `scheduleAfter(1)`. On each `timerFired`, it increments its state, calls `publishState(\"count\", state)`, and calls `scheduleAfter(1)`. During `finish`, it calls `publishState(\"done\", 1)`.",
    Connections: "None.",
    "Observable boundaries": "The stop expression is evaluated after each timer dispatch. It becomes true after `c0.count` changes to `3` at time `3`. `finish` runs at time `3`. The run completes with reason `condition`. The portable event comparison is [`expected/threshold.machine.events.ndjson`](expected/threshold.machine.events.ndjson)."
  },
  exprerr: {
    Configuration: "Model `exprerr`, duration `5`, seed `13`, and `stopWhen = \"1 / c0.zero\"`.",
    "Components and actions": "Component `c0` has no local control state. During `start`, it calls `publishState(\"zero\", 0)` and `scheduleAfter(1)`. Its timer reaction does nothing.",
    Connections: "None.",
    "Observable boundaries": "The stop expression is evaluated after the timer dispatch at time `1`. Evaluation ends the run with `division by zero in \"1 / c0.zero\"`. The portable event comparison is [`expected/exprerr.machine.events.ndjson`](expected/exprerr.machine.events.ndjson)."
  },
  errsend: {
    Configuration: "Model `errsend`, duration `5`, and seed `9`.",
    "Components and actions": "Component `e0` has component type `test.err` and no local control state. During `start`, it creates a `job` entity and sends it through `out`.",
    Connections: "None.",
    "Observable boundaries": "The send ends the run at time `0` with `component \"e0\" (test.err) start at simulation time 0: e0.out has no route to carry an entity`. The failed `start` does not publish the staged entity creation. The portable event comparison is [`expected/errsend.machine.events.ndjson`](expected/errsend.machine.events.ndjson)."
  },
  componenterr: {
    Configuration: "Model `componenterr`, duration `1`, and seed `19`.",
    "Components and actions": "Component `e0` has component type `test.component_err` and no local control state. During `start`, it calls `failRun(\"component failed\")`.",
    Connections: "None.",
    "Observable boundaries": "`start` ends the run at time `0` with `component \"e0\" (test.component_err) start at simulation time 0: component failed`. The portable event comparison is [`expected/componenterr.machine.events.ndjson`](expected/componenterr.machine.events.ndjson)."
  }
};
const expectedPortableFixtureEvents = {
  timers: [
    {time: 1, type: "fixture.timerFired", source: "t0", payload: {timer: 1, count: 1}},
    {time: 1, type: "fixture.timerFired", source: "t0", payload: {timer: 2, count: 2}},
    {time: 2.5, type: "fixture.timerFired", source: "t0", payload: {timer: 3, count: 3}}
  ],
  backpressure: [
    {
      time: 0,
      type: "fixture.blocked",
      source: "snk",
      payload: {entityId: "job#1", inputPort: "in"}
    },
    {
      time: 1,
      type: "fixture.ready",
      source: "snk",
      payload: {inputPort: "in"}
    }
  ],
  valuescope: [{
    time: 0,
    type: "value.scope",
    source: "v0",
    payload: {
      componentId: "v0",
      parameter: 2,
      evaluated: 15,
      sampled: 7.839622425333314
    }
  }]
};

function isExecutable(filePath) {
  try {
    accessSync(filePath, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function lakePath(env = process.env) {
  const homeLake = typeof env.HOME === "string"
    ? path.join(env.HOME, ".elan/bin/lake")
    : null;
  if (homeLake && isExecutable(homeLake)) return homeLake;
  return (env.PATH ?? "")
    .split(path.delimiter)
    .map(directory => path.join(directory || ".", "lake"))
    .find(isExecutable) ?? null;
}

const lake = lakePath();

function runLake(...arguments_) {
  assert.notEqual(lake, null, "Lake is required for conformance artifact tests");
  return spawnSync(lake, arguments_, {
    cwd: path.join(rootDir, "machine"),
    encoding: "utf8"
  });
}

async function readJson(relativePath) {
  return JSON.parse(await readFile(path.join(rootDir, relativePath), "utf8"));
}

async function manifestsById() {
  const entries = await Promise.all(manifestPaths.map(async relativePath => {
    const absolutePath = path.join(rootDir, relativePath);
    const manifest = await readJson(relativePath);
    return [manifest.id, {absolutePath, manifest}];
  }));
  return new Map(entries);
}

async function readNdjson(filePath) {
  const source = await readFile(filePath, "utf8");
  return source.split(/\r?\n/).filter(Boolean).map(line => JSON.parse(line));
}

async function listFiles(directory, prefix = "") {
  const files = [];
  for (const entry of await readdir(directory, {withFileTypes: true})) {
    const relativePath = path.join(prefix, entry.name);
    if (entry.isDirectory()) {
      files.push(...await listFiles(path.join(directory, entry.name), relativePath));
    } else if (entry.isFile()) {
      files.push(relativePath);
    }
  }
  return files.sort();
}

function assertDesFixture(publicId, input) {
  assert.deepEqual(input, expectedDesFixtures[publicId], publicId);
}

function markdownSection(markdown, heading) {
  const escapedHeading = heading.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return markdown.match(new RegExp(
    `^### ${escapedHeading}\\s*$([\\s\\S]*?)(?=^### |^## |$(?![\\s\\S]))`,
    "m"
  ))?.[1] ?? null;
}

function contractSnapshot(section) {
  const entries = [...section.matchAll(
    /^(Purpose|Configuration|Components and actions|Connections|Observable boundaries): (.+)$/gm
  )];
  return Object.fromEntries(entries.map(([, field, value]) => [field, value]));
}

async function expectedGeneratedPaths(manifests) {
  const contract = manifests.get("reference-machine");
  const registry = new Map([...manifests.values()].map(({absolutePath, manifest}) => [
    `${manifest.id}@${manifest.version}`,
    absolutePath
  ]));
  const suite = await loadSuite(contract.absolutePath, registry);
  return [...new Set(suite.cases.flatMap(entry => (
    Object.values(entry.expectedPaths).map(artifactPath => path.relative(rootDir, artifactPath))
  )))].sort();
}

test("defines and validates the exact public conformance case graph", async () => {
  const manifests = await manifestsById();
  const registry = new Map([...manifests.values()].map(({absolutePath, manifest}) => [
    `${manifest.id}@${manifest.version}`,
    absolutePath
  ]));

  assert.deepEqual([...manifests.keys()], ["core", "des", "abm", "sd", "reference-machine"]);
  for (const [id, {absolutePath, manifest}] of manifests) {
    assert.deepEqual(validateManifest(manifest), [], id);
    assert.deepEqual(manifest.cases.map(({id: caseId}) => caseId), publicOwnership[id]);
    const suite = await loadSuite(absolutePath, registry);
    assert.equal(suite.cases.length >= manifest.cases.length, true);
  }

  const contract = manifests.get("reference-machine");
  const selectedSuite = await loadSuite(contract.absolutePath, registry);
  assert.deepEqual(selectedSuite.cases.map(({id}) => id), Object.keys(publicAdapter.cases));
});

test("defines the exact out-of-band adapter coverage", async () => {
  const adapter = await readJson("contracts/reference-machine/conformance/adapter.json");
  assert.deepEqual(adapter, publicAdapter);
  assert.deepEqual(Object.keys(adapter.cases), Object.keys(publicAdapter.cases));
  assert.equal(new Set(Object.keys(adapter.cases)).size, 16);
});

test("publishes reconstructable Core machine behavior contracts", async () => {
  const {absolutePath, manifest} = (await manifestsById()).get("core");
  const manifestDirectory = path.dirname(absolutePath);
  const readme = await readFile(path.join(manifestDirectory, "README.md"), "utf8");

  assert.deepEqual(
    manifest.cases.map(({id}) => id),
    Object.keys(coreMachinePurposes).map(behavior => `${behavior}.machine`)
  );

  for (const entry of manifest.cases) {
    const fixturePath = path.resolve(manifestDirectory, entry.input.path);
    const fixture = JSON.parse(await readFile(fixturePath, "utf8"));
    const behavior = entry.id.replace(/\.machine$/, "");

    assert.equal(entry.description, coreMachinePurposes[behavior], entry.id);
    assert.equal(fixture.behavior, behavior, `${entry.id} behavior`);
    assert.equal(
      fixture.behaviorContract,
      `../README.md#${behavior}`,
      `${entry.id} behavior contract`
    );

    const contractSection = markdownSection(readme, behavior);
    assert.notEqual(contractSection, null, `${entry.id} has no behavior contract`);
    const expectedSnapshot = {
      Purpose: coreMachinePurposes[behavior],
      ...coreMachineContractSnapshots[behavior]
    };
    assert.deepEqual(contractSnapshot(contractSection), expectedSnapshot, entry.id);
    assert.equal(
      contractSection.trim(),
      Object.entries(expectedSnapshot)
        .map(([field, value]) => `${field}: ${value}`)
        .join("\n\n"),
      `${entry.id} full contract snapshot`
    );
    assert.doesNotMatch(contractSection, /\b(?:TBD|TODO|FIXME)\b/i, entry.id);
  }
});

test("publishes exact observable fixture behavior events", async () => {
  for (const [behavior, expected] of Object.entries(expectedPortableFixtureEvents)) {
    const events = await readNdjson(path.join(
      rootDir,
      "conformance/core/expected",
      `${behavior}.machine.events.ndjson`
    ));
    const fixtureEvents = events
      .filter(({type}) => type === "value.scope" || type.startsWith("fixture."))
      .map(({time, type, source, payload}) => ({time, type, source, payload}));
    assert.deepEqual(fixtureEvents, expected, behavior);
  }
});

test("selects only the implementation contract manifest graph for regeneration", async () => {
  const listed = spawnSync(process.execPath, [generatorPath, "--list"], {
    cwd: rootDir,
    encoding: "utf8"
  });

  assert.equal(listed.status, 0, listed.stderr);
  const paths = listed.stdout.trim().split("\n");
  assert.equal(paths.length, 31);
  assert.equal(paths.some(filePath => filePath.startsWith("libraries/abm/")), false);
  assert.equal(paths.some(filePath => filePath.startsWith("libraries/sd/")), false);
});

test("makes every generated raw trace a contract assertion", async () => {
  const manifests = await manifestsById();
  const contract = manifests.get("reference-machine");
  const registry = new Map([...manifests.values()].map(({absolutePath, manifest}) => [
    `${manifest.id}@${manifest.version}`,
    absolutePath
  ]));
  const suite = await loadSuite(contract.absolutePath, registry);
  const tracedIds = suite.cases
    .filter(entry => entry.expected.trace)
    .map(({id}) => id);

  assert.deepEqual(tracedIds, Object.keys(publicAdapter.cases));
});

test("maps every public case to an existing Lean catalogue case", {skip: lake === null}, async () => {
  const adapter = await readJson("contracts/reference-machine/conformance/adapter.json");
  const catalogueResult = runLake("exe", "osdl-reference-machine", "--catalog");
  assert.equal(catalogueResult.status, 0, catalogueResult.stderr);
  const catalogue = JSON.parse(catalogueResult.stdout);
  const catalogueIds = new Set(catalogue.map(({id}) => id));

  assert.ok(Object.values(adapter.cases).every(id => catalogueIds.has(id)));
  assert.ok([
    "desroute", "desexp", "despri", "descond", "desweight", "desmodes",
    "timercancel", "cancelxfer", "quiesce", "msgvalue"
  ].every(id => catalogueIds.has(id) && !Object.values(adapter.cases).includes(id)));
});

test("stores the exact DES OSDL fixture shapes", async () => {
  const manifests = await manifestsById();
  const {absolutePath, manifest} = manifests.get("des");
  const manifestDirectory = path.dirname(absolutePath);

  for (const entry of manifest.cases) {
    const input = JSON.parse(await readFile(path.resolve(manifestDirectory, entry.input.path), "utf8"));
    assertDesFixture(entry.id, input);
  }
});

test("DES fixture equivalence rejects valid behavioral edits", async () => {
  const artifacts = await loadArtifacts(rootDir);
  const mutations = [
    ["pipeline.osdl", input => { input.model.components[1].params.capacity = 3; }],
    ["pipeline.osdl", input => { input.model.components[2].params.serviceTime = 2; }],
    ["pipeline.osdl", input => { input.experiments[0].duration = 13; }],
    ["recorders.osdl", input => { input.experiments[0].outputs[0].records[0].statistics.pop(); }]
  ];

  for (const [publicId, mutate] of mutations) {
    const input = structuredClone(expectedDesFixtures[publicId]);
    mutate(input);
    assert.deepEqual(validateDocument(input, artifacts), [], publicId);
    assert.throws(() => assertDesFixture(publicId, input), {code: "ERR_ASSERTION"});
  }
});

test("stores valid portable expected events and valid raw contract traces", async () => {
  const manifests = await manifestsById();
  const artifacts = await loadArtifacts(rootDir);
  const publicCases = [...manifests.values()].flatMap(({absolutePath, manifest}) => (
    manifest.cases.map(entry => ({entry, manifestDirectory: path.dirname(absolutePath)}))
  ));

  for (const {entry, manifestDirectory} of publicCases) {
    if (!entry.expected.events) continue;
    const events = await readNdjson(path.resolve(manifestDirectory, entry.expected.events));
    if (entry.input.format === "osdl") {
      const input = JSON.parse(await readFile(path.resolve(manifestDirectory, entry.input.path), "utf8"));
      const started = events.find(({type}) => type === "sim.started");
      assert.equal(started?.payload?.model, input.model.name, entry.id);
      assert.equal(started?.run?.experiment, input.experiments[0].name, entry.id);
    }
    for (const event of events) {
      assert.equal(Object.hasOwn(event, "seq"), false, entry.id);
      assert.equal(Object.hasOwn(event, "wallTime"), false, entry.id);
      assert.equal(TELEMETRY_TYPES.has(event.type), false, entry.id);
      assert.equal(artifacts.validateEvents({...event, seq: 0}), true, entry.id);
    }
  }

  for (const publicId of Object.keys(publicAdapter.cases)) {
    const tracePath = path.join(
      rootDir,
      "contracts/reference-machine/conformance/expected",
      `${publicId}.trace.ndjson`
    );
    const events = await readNdjson(tracePath);
    assert.ok(events.length > 0, publicId);
    for (const event of events) {
      assert.equal(artifacts.validateEvents(event), true, publicId);
      assert.equal(Number.isInteger(event.seq), true, publicId);
    }
  }
});

test("stores contiguous raw contract sequence numbers starting at one", async () => {
  for (const publicId of Object.keys(publicAdapter.cases)) {
    const tracePath = path.join(
      rootDir,
      "contracts/reference-machine/conformance/expected",
      `${publicId}.trace.ndjson`
    );
    const events = await readNdjson(tracePath);
    for (const [index, event] of events.entries()) {
      assert.equal(event.seq, index + 1, `${publicId} event ${index + 1}`);
    }
  }
});

test("refuses to generate without exactly one output directory", () => {
  const absent = spawnSync(process.execPath, [generatorPath], {encoding: "utf8"});
  const malformed = spawnSync(
    process.execPath,
    [generatorPath, "--output", ".", "extra"],
    {encoding: "utf8"}
  );

  assert.equal(absent.status, 2);
  assert.match(absent.stderr, /usage: node scripts\/update-conformance\.mjs --output <directory>/);
  assert.equal(malformed.status, 2);
  assert.match(malformed.stderr, /usage: node scripts\/update-conformance\.mjs --output <directory>/);
});

test("rejects a generated ancestor symlink without writing outside the output root", {
  skip: lake === null
}, async () => {
  const temporaryRoot = await mkdtemp(path.join(os.tmpdir(), "osdl-conformance-symlink-"));
  const resolvedTemporaryRoot = path.resolve(temporaryRoot);
  const outputDirectory = path.join(resolvedTemporaryRoot, "output");
  const outsideDirectory = path.join(resolvedTemporaryRoot, "outside");
  const generatedAncestor = path.join(outputDirectory, "conformance");
  let linkCreated = false;

  assert.equal(path.dirname(resolvedTemporaryRoot), path.resolve(os.tmpdir()));
  assert.match(path.basename(resolvedTemporaryRoot), /^osdl-conformance-symlink-/);

  try {
    await mkdir(outputDirectory);
    await mkdir(outsideDirectory);
    await symlink(outsideDirectory, generatedAncestor, "dir");
    linkCreated = true;

    const result = spawnSync(
      process.execPath,
      [generatorPath, "--output", outputDirectory],
      {cwd: rootDir, encoding: "utf8"}
    );

    assert.deepEqual(await listFiles(outsideDirectory), []);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /symbolic link/);
  } finally {
    if (linkCreated) {
      const linkStats = await lstat(generatedAncestor);
      assert.equal(linkStats.isSymbolicLink(), true);
      await unlink(generatedAncestor);
    }
    const temporaryStats = await lstat(resolvedTemporaryRoot);
    assert.equal(temporaryStats.isSymbolicLink(), false);
    assert.equal(temporaryStats.isDirectory(), true);
    await rm(resolvedTemporaryRoot, {recursive: true, force: true});
  }
});

test("regenerates the exact artifact set with byte-identical content", {skip: lake === null}, async () => {
  const temporaryDirectory = await mkdtemp(path.join(os.tmpdir(), "osdl-conformance-artifacts-"));
  const resolvedTemporaryDirectory = path.resolve(temporaryDirectory);
  assert.equal(path.dirname(resolvedTemporaryDirectory), path.resolve(os.tmpdir()));
  assert.match(path.basename(resolvedTemporaryDirectory), /^osdl-conformance-artifacts-/);

  try {
    const result = spawnSync(
      process.execPath,
      [generatorPath, "--output", resolvedTemporaryDirectory],
      {cwd: rootDir, encoding: "utf8"}
    );
    assert.equal(result.status, 0, result.stderr);

    const manifests = await manifestsById();
    const expectedPaths = await expectedGeneratedPaths(manifests);
    assert.equal(expectedPaths.length, 31);
    assert.deepEqual(await listFiles(resolvedTemporaryDirectory), expectedPaths);

    for (const relativePath of expectedPaths) {
      const [generated, committed] = await Promise.all([
        readFile(path.join(resolvedTemporaryDirectory, relativePath)),
        readFile(path.join(rootDir, relativePath))
      ]);
      assert.deepEqual(generated, committed, relativePath);
    }
  } finally {
    const temporaryStats = await lstat(resolvedTemporaryDirectory);
    assert.equal(temporaryStats.isSymbolicLink(), false);
    assert.equal(temporaryStats.isDirectory(), true);
    await rm(resolvedTemporaryDirectory, {recursive: true, force: true});
  }
});
