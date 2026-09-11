import assert from "node:assert/strict";
import {spawnSync} from "node:child_process";
import {accessSync, constants} from "node:fs";
import {mkdtemp, rm} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {fileURLToPath} from "node:url";

const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const leanSkipMessage = "lake not found; skipping reference-machine build (install elan to enable).";
const leanPhaseMessages = [
  "Reference machine builds.",
  "Preparation checks pass.",
  "Transfer checks pass.",
  "Vector round-trip checks pass.",
  "Conformance catalogue is valid.",
  "Conformance artifacts match committed files (31 files).",
  "Golden vectors match committed file.",
  "Golden vector checks pass.",
  "Resolution-round checks pass.",
  "Safeguard checks pass."
];

function isExecutable(filePath) {
  try {
    accessSync(filePath, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function hasLake(env) {
  const pathDirectories = (env.PATH ?? "")
    .split(path.delimiter)
    .map(directory => directory || ".");

  return pathDirectories.some(directory => isExecutable(path.join(directory, "lake"))) ||
    (typeof env.HOME === "string" && isExecutable(path.join(env.HOME, ".elan", "bin", "lake")));
}

function hasPathCommand(pathValue, command) {
  return pathValue
    .split(path.delimiter)
    .filter(Boolean)
    .some(directory => isExecutable(path.join(directory, command)));
}

function assertMessagesInOrder(output, messages) {
  let offset = 0;
  for (const message of messages) {
    const nextOffset = output.indexOf(message, offset);
    assert.notEqual(nextOffset, -1, `missing message: ${message}`);
    offset = nextOffset + message.length;
  }
}

function validationEnvironment(overrides = {}) {
  const {NODE_TEST_CONTEXT, ...environment} = process.env;
  return {...environment, ...overrides};
}

test("repository validation reports each completed phase in order", {
  skip: process.env.OSDL_SKIP_SELF_TEST === "1"
}, () => {
  const result = spawnSync("bash", ["validate.sh"], {
    cwd: rootDir,
    encoding: "utf8",
    env: validationEnvironment({OSDL_SKIP_SELF_TEST: "1"})
  });

  assert.equal(result.status, 0, result.stderr);
  assertMessagesInOrder(result.stdout, [
    "Node contract tests pass.",
    "OSDL documents and libraries are valid.",
    ...(hasLake(process.env) ? leanPhaseMessages : [leanSkipMessage]),
    "All OSDL specification artifacts are valid."
  ]);
});

test("repository validation succeeds without Lake", {
  skip: process.env.OSDL_SKIP_SELF_TEST === "1"
}, async () => {
  const noLakeHome = await mkdtemp(path.join(os.tmpdir(), "osdl-no-lake-"));
  const noLakePath = (process.env.PATH ?? "")
    .split(path.delimiter)
    .filter(directory => directory && !isExecutable(path.join(directory, "lake")))
    .join(path.delimiter);

  try {
    const environment = {
      ...validationEnvironment(),
      HOME: noLakeHome,
      OSDL_SKIP_SELF_TEST: "1",
      PATH: noLakePath
    };
    assert.ok(noLakePath, "PATH has no non-Lake executable directories");
    assert.equal(hasLake(environment), false);
    for (const command of ["bash", "npm", "node", "dirname", "mktemp", "rm"]) {
      assert.ok(hasPathCommand(noLakePath, command), `PATH has no ${command} command`);
    }

    const result = spawnSync("bash", ["validate.sh"], {
      cwd: rootDir,
      encoding: "utf8",
      env: environment
    });

    assert.equal(result.status, 0, result.stderr);
    assertMessagesInOrder(result.stdout, [
      "Node contract tests pass.",
      "OSDL documents and libraries are valid.",
      leanSkipMessage,
      "All OSDL specification artifacts are valid."
    ]);
    for (const message of leanPhaseMessages) {
      assert.doesNotMatch(result.stdout, new RegExp(message.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
    }
  } finally {
    await rm(noLakeHome, {recursive: true, force: true});
  }
});
