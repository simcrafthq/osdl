import assert from "node:assert/strict";
import {spawnSync} from "node:child_process";
import {accessSync, constants} from "node:fs";
import {chmod, mkdir, mkdtemp, readFile, rm, writeFile} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {fileURLToPath} from "node:url";

import Ajv2020 from "ajv/dist/2020.js";

const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const generatorPath = path.join(rootDir, "scripts/update-conformance.mjs");
const eventSchema = JSON.parse(
  await readFile(path.join(rootDir, "schemas", "osdl.events.schema.json"), "utf8")
);
const validateEvent = new Ajv2020({allErrors: true, strict: false}).compile(eventSchema);

function isExecutable(filePath) {
  try {
    accessSync(filePath, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function lakePath(env = process.env) {
  const fromHome = typeof env.HOME === "string"
    ? path.join(env.HOME, ".elan", "bin", "lake")
    : null;
  if (fromHome && isExecutable(fromHome)) return fromHome;

  const pathDirectories = (env.PATH ?? "")
    .split(path.delimiter)
    .map(directory => directory || ".");
  const fromPath = pathDirectories
    .map(directory => path.join(directory, "lake"))
    .find(isExecutable);

  if (fromPath) return fromPath;
  return null;
}

const lake = lakePath();

function event(type, payload) {
  return {v: "0.1", seq: 1, time: 0, type, source: "kernel", payload};
}

function rngpairTrace() {
  const result = spawnSync(lake, ["exe", "osdl-reference-machine", "rngpair"], {
    cwd: path.join(rootDir, "machine"),
    encoding: "utf8"
  });

  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim().split("\n").map(line => JSON.parse(line));
}

function roundtickTrace() {
  const result = spawnSync(lake, ["exe", "osdl-reference-machine", "roundtick"], {
    cwd: path.join(rootDir, "machine"),
    encoding: "utf8"
  });

  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim().split("\n").map(line => JSON.parse(line));
}

function generatedArtifactPaths() {
  const result = spawnSync(process.execPath, [generatorPath, "--list"], {
    cwd: rootDir,
    encoding: "utf8"
  });

  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim().split("\n");
}

async function withLakeCandidates(action) {
  const temporaryDir = await mkdtemp(path.join(os.tmpdir(), "osdl-lake-path-"));
  const homeDir = path.join(temporaryDir, "home");
  const pathDir = path.join(temporaryDir, "path");
  const homeLake = path.join(homeDir, ".elan", "bin", "lake");
  const pathLake = path.join(pathDir, "lake");

  try {
    await mkdir(path.dirname(homeLake), {recursive: true});
    await mkdir(pathDir);
    await Promise.all([
      writeFile(homeLake, "#!/usr/bin/env bash\n"),
      writeFile(pathLake, "#!/usr/bin/env bash\n")
    ]);
    await Promise.all([chmod(homeLake, 0o755), chmod(pathLake, 0o755)]);
    await action({homeDir, homeLake, pathDir});
  } finally {
    await rm(temporaryDir, {recursive: true, force: true});
  }
}

test("accepts param.changed with a named scalar value", () => {
  assert.equal(validateEvent(event("param.changed", {name: "rate", value: 2})), true);
});

test("accepts telemetry for boolean and string recorder values", () => {
  assert.equal(validateEvent(event("metric.updated", {name: "active", value: true})), true);
  assert.equal(validateEvent(event("metric.updated", {name: "phase", value: "busy"})), true);
});

test("accepts null telemetry for an unavailable final value", () => {
  assert.equal(validateEvent(event("metric.updated", {name: "pending", value: null})), true);
});

test("rejects structured recorder telemetry values", () => {
  assert.equal(validateEvent(event("metric.updated", {
    name: "phase",
    value: {name: "busy"}
  })), false);
});

test("accepts param.changed with string and boolean values", () => {
  assert.equal(validateEvent(event("param.changed", {name: "phase", value: "warm"})), true);
  assert.equal(validateEvent(event("param.changed", {name: "active", value: true})), true);
});

test("rejects param.changed without a value", () => {
  assert.equal(validateEvent(event("param.changed", {name: "rate"})), false);
});

test("rejects param.changed with a malformed name", () => {
  assert.equal(validateEvent(event("param.changed", {name: "9rate", value: 2})), false);
});

test("accepts sim.aborted for both abort reasons", () => {
  assert.equal(validateEvent(event("sim.aborted", {reason: "budgetExceeded"})), true);
  assert.equal(validateEvent(event("sim.aborted", {reason: "cancelled"})), true);
});

test("rejects sim.aborted with an unknown reason", () => {
  assert.equal(validateEvent(event("sim.aborted", {reason: "timeout"})), false);
});

test("accepts value.changed with a typed scalar value", () => {
  assert.equal(validateEvent(event("value.changed", {port: "level", value: 3.5})), true);
  assert.equal(validateEvent(event("value.changed", {port: "open", value: false})), true);
});

test("rejects value.changed without a port", () => {
  assert.equal(validateEvent(event("value.changed", {value: 3.5})), false);
});

test("accepts both message.sent payload forms", () => {
  assert.equal(validateEvent(event("message.sent", {
    topic: "bid",
    fromAgent: "a1",
    toAgent: "a2",
    payload: {price: 10}
  })), true);
  assert.equal(validateEvent(event("message.sent", {
    from: "producer",
    to: "consumer",
    port: "in"
  })), true);
});

test("rejects an empty message.sent payload", () => {
  assert.equal(validateEvent(event("message.sent", {})), false);
});

test("rejects a message.sent payload mixing topic and port", () => {
  assert.equal(validateEvent(event("message.sent", {
    topic: "bid",
    port: "in",
    to: "consumer"
  })), false);
});

test("rejects array payloads", () => {
  assert.equal(validateEvent(event("param.changed", ["rate", 2])), false);
});

test("prefers the elan Lake executable over PATH", async () => {
  await withLakeCandidates(({homeDir, homeLake, pathDir}) => {
    assert.equal(lakePath({HOME: homeDir, PATH: pathDir}), homeLake);
  });
});

test("preserves exact rngpair UInt64 strings from Lean to the portable artifact", {
  skip: lake === null
}, async () => {
  const trace = rngpairTrace();
  const draws = trace.filter(({type}) => type === "machine.draws");
  const portable = (await readFile(path.join(
    rootDir,
    "conformance/core/expected/rngpair.machine.events.ndjson"
  ), "utf8"))
    .trim()
    .split("\n")
    .map(line => JSON.parse(line))
    .filter(({type}) => type === "machine.draws");
  const expected = [
    ["13783839991484394830", "11268918191723552664", "13386761933215218490", "11786999878893370076"],
    ["10524509612679504224", "17662094055660081926", "5819969002872036014", "11600577006935752814"]
  ];

  assert.equal(draws.length, 2);
  assert.deepEqual(draws.map(({payload}) => payload.draws), expected);
  assert.deepEqual(portable.map(({payload}) => payload.draws), expected);
  assert.ok(expected.flat().every(value => /^[0-9]+$/.test(value)));
  assert.ok(trace.every(eventEnvelope => validateEvent(eventEnvelope)), JSON.stringify(validateEvent.errors));
});

test("preserves exact roundtick UInt64 strings from Lean to the raw artifact", {
  skip: lake === null
}, async () => {
  const expected = ["2074134861973389515", "14051751459229557887"];
  const direct = roundtickTrace()
    .filter(({type}) => type === "round.read")
    .map(({payload}) => payload.random);
  const artifact = (await readFile(path.join(
    rootDir,
    "contracts/reference-machine/conformance/expected/roundtick.contract.trace.ndjson"
  ), "utf8"))
    .trim()
    .split("\n")
    .map(line => JSON.parse(line))
    .filter(({type}) => type === "round.read")
    .map(({payload}) => payload.random);

  assert.deepEqual(direct, expected);
  assert.deepEqual(artifact, expected);
});

test("stores no numeric fixture random-draw tokens in generated artifacts", async () => {
  for (const relativePath of generatedArtifactPaths()) {
    if (!/\.(?:json|ndjson)$/.test(relativePath)) continue;
    const source = await readFile(path.join(rootDir, relativePath), "utf8");
    assert.doesNotMatch(source, /"random"\s*:\s*-?\d/, relativePath);
    assert.doesNotMatch(source, /"draws"\s*:\s*\[\s*-?\d/, relativePath);
  }
});
