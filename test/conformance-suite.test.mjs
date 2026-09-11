import assert from "node:assert/strict";
import {spawnSync} from "node:child_process";
import {mkdtemp, mkdir, rm, symlink, writeFile} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {fileURLToPath} from "node:url";

import {checkSuite, loadSuite} from "../scripts/lib/conformance-suite.mjs";

const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const fixtureDir = path.join(rootDir, "test/fixtures/conformance");

function manifest(id, {extends: parents = [], cases = [], assertions = []} = {}) {
  return {
    osdl: "0.1",
    kind: "core",
    id,
    version: "0.1.0",
    extends: parents,
    cases,
    ...(assertions.length > 0 ? {assertions} : {})
  };
}

function osdlCase(id, expected = {results: `expected/${id}.results.json`}) {
  return {
    id,
    input: {format: "osdl", path: `inputs/${id}.osdl.json`},
    expected
  };
}

function validDocument(name) {
  return {osdl: "0.1", model: {name, components: []}};
}

function validEvent(time = 0) {
  return {v: "0.1", seq: 0, time, type: "custom.event", source: "kernel"};
}

function portableEvent(time = 0) {
  const {seq, wallTime, ...portable} = validEvent(time);
  return portable;
}

async function writeJson(filePath, value) {
  await mkdir(path.dirname(filePath), {recursive: true});
  await writeFile(filePath, `${JSON.stringify(value)}\n`);
}

async function writeText(filePath, value) {
  await mkdir(path.dirname(filePath), {recursive: true});
  await writeFile(filePath, value);
}

async function writeCaseArtifacts(directory, entry) {
  await writeJson(path.join(directory, entry.input.path), validDocument(entry.id));
  if (entry.expected.results) {
    await writeJson(path.join(directory, entry.expected.results), {
      output: {final: {value: 1}}
    });
  }
  if (entry.expected.events) {
    const eventsPath = path.join(directory, entry.expected.events);
    await mkdir(path.dirname(eventsPath), {recursive: true});
    await writeFile(eventsPath, `${JSON.stringify(portableEvent())}\n`);
  }
  if (entry.expected.trace) {
    await writeText(
      path.join(directory, entry.expected.trace),
      `${JSON.stringify(validEvent())}\n`
    );
  }
}

async function withSuiteRoot(action) {
  const suiteRoot = await mkdtemp(path.join(os.tmpdir(), "osdl-conformance-"));
  try {
    return await action(suiteRoot);
  } finally {
    await rm(suiteRoot, {recursive: true, force: true});
  }
}

async function writeManifest(directory, value) {
  const manifestPath = path.join(directory, "manifest.json");
  await writeJson(manifestPath, value);
  return manifestPath;
}

test("loads parent manifests before child manifests", async () => {
  await withSuiteRoot(async suiteRoot => {
    const parentDir = path.join(suiteRoot, "parent");
    const childDir = path.join(suiteRoot, "child");
    const parentCase = osdlCase("parent-case");
    const childCase = osdlCase("child-case");
    const parentPath = await writeManifest(parentDir, manifest("parent", {cases: [parentCase]}));
    const childPath = await writeManifest(childDir, manifest("child", {
      extends: ["parent@0.1.0"],
      cases: [childCase]
    }));
    await Promise.all([
      writeCaseArtifacts(parentDir, parentCase),
      writeCaseArtifacts(childDir, childCase)
    ]);

    const suite = await loadSuite(childPath, new Map([
      ["parent@0.1.0", parentPath],
      ["child@0.1.0", childPath]
    ]));

    assert.deepEqual(suite.manifests.map(({key}) => key), [
      "parent@0.1.0",
      "child@0.1.0"
    ]);
    assert.deepEqual(suite.cases.map(({id}) => id), ["parent-case", "child-case"]);
  });
});

test("rejects an extension that is absent from the registry", async () => {
  await withSuiteRoot(async suiteRoot => {
    const childPath = await writeManifest(suiteRoot, manifest("child", {
      extends: ["missing@0.1.0"]
    }));

    await assert.rejects(
      loadSuite(childPath, new Map([["child@0.1.0", childPath]])),
      /missing conformance parent: missing@0\.1\.0/
    );
  });
});

test("reports the complete conformance extension cycle", async () => {
  const cycleA = path.join(fixtureDir, "cycle-a/manifest.json");
  const cycleB = path.join(fixtureDir, "cycle-b/manifest.json");

  await assert.rejects(
    loadSuite(cycleA, new Map([
      ["cycle-a@0.1.0", cycleA],
      ["cycle-b@0.1.0", cycleB]
    ])),
    /conformance extension cycle: cycle-a@0\.1\.0 -> cycle-b@0\.1\.0 -> cycle-a@0\.1\.0/
  );
});

test("rejects a case ID duplicated by a child manifest", async () => {
  await withSuiteRoot(async suiteRoot => {
    const parentDir = path.join(suiteRoot, "parent");
    const childDir = path.join(suiteRoot, "child");
    const entry = osdlCase("shared-case");
    const parentPath = await writeManifest(parentDir, manifest("parent", {cases: [entry]}));
    const childPath = await writeManifest(childDir, manifest("child", {
      extends: ["parent@0.1.0"],
      cases: [entry]
    }));
    await Promise.all([
      writeCaseArtifacts(parentDir, entry),
      writeCaseArtifacts(childDir, entry)
    ]);

    await assert.rejects(
      loadSuite(childPath, new Map([
        ["parent@0.1.0", parentPath],
        ["child@0.1.0", childPath]
      ])),
      /duplicate conformance case id: shared-case/
    );
  });
});

test("rejects a missing case input", async () => {
  await withSuiteRoot(async suiteRoot => {
    const entry = osdlCase("missing-input");
    const manifestPath = await writeManifest(suiteRoot, manifest("missing-input", {cases: [entry]}));
    await writeJson(path.join(suiteRoot, entry.expected.results), {output: {final: {value: 1}}});

    await assert.rejects(loadSuite(manifestPath, new Map()), /missing case input: missing-input/);
  });
});

test("rejects a malformed machine fixture input", async () => {
  await withSuiteRoot(async suiteRoot => {
    const entry = {
      id: "invalid-machine-fixture",
      input: {format: "machine", path: "inputs/invalid-machine-fixture.machine.json"},
      expected: {results: "expected/invalid-machine-fixture.results.json"}
    };
    const manifestPath = await writeManifest(
      suiteRoot,
      manifest("invalid-machine-fixture", {cases: [entry]})
    );
    await writeJson(path.join(suiteRoot, entry.input.path), {
      format: "osdl-machine-fixture/0.1",
      behavior: "timers",
      extra: true
    });
    await writeJson(path.join(suiteRoot, entry.expected.results), {
      output: {final: {value: 1}}
    });

    await assert.rejects(
      loadSuite(manifestPath),
      /invalid machine input: invalid-machine-fixture: .*must NOT have additional properties/
    );
  });
});

test("rejects a missing expected artifact", async () => {
  await withSuiteRoot(async suiteRoot => {
    const entry = osdlCase("missing-expected");
    const manifestPath = await writeManifest(suiteRoot, manifest("missing-expected", {cases: [entry]}));
    await writeJson(path.join(suiteRoot, entry.input.path), validDocument(entry.id));

    await assert.rejects(
      loadSuite(manifestPath, new Map()),
      /missing expected results: missing-expected/
    );
  });
});

test("resolves expected paths without existing artifacts for regeneration", async () => {
  await withSuiteRoot(async suiteRoot => {
    const entry = osdlCase("new-case");
    const manifestPath = await writeManifest(suiteRoot, manifest("new-case", {cases: [entry]}));
    await writeJson(path.join(suiteRoot, entry.input.path), validDocument(entry.id));

    const suite = await loadSuite(manifestPath, new Map(), {loadExpectedArtifacts: false});

    assert.equal(suite.cases.length, 1);
    assert.equal(
      suite.cases[0].expectedPaths.results,
      path.join(suiteRoot, entry.expected.results)
    );
    assert.deepEqual(suite.cases[0].expectedValues, {});
  });
});

test("rejects paths that escape a manifest directory", async () => {
  await withSuiteRoot(async suiteRoot => {
    const entry = {
      ...osdlCase("path-escape"),
      expected: {results: "../outside.results.json"}
    };
    const manifestPath = await writeManifest(suiteRoot, manifest("path-escape", {cases: [entry]}));
    await writeJson(path.join(suiteRoot, entry.input.path), validDocument(entry.id));

    await assert.rejects(
      loadSuite(manifestPath, new Map()),
      /conformance path escapes manifest directory: \.\.\/outside\.results\.json/
    );
  });
});

test("rejects an input symlink that resolves outside the manifest directory", async () => {
  await withSuiteRoot(async suiteRoot => {
    const manifestDir = path.join(suiteRoot, "suite");
    const entry = osdlCase("input-file-link");
    const manifestPath = await writeManifest(
      manifestDir,
      manifest("input-file-link", {cases: [entry]})
    );
    const outsideInput = path.join(suiteRoot, "outside.osdl.json");
    await writeJson(outsideInput, validDocument(entry.id));
    await mkdir(path.dirname(path.join(manifestDir, entry.input.path)), {recursive: true});
    await symlink(outsideInput, path.join(manifestDir, entry.input.path));
    await writeJson(path.join(manifestDir, entry.expected.results), {
      output: {final: {value: 1}}
    });

    await assert.rejects(
      loadSuite(manifestPath),
      /conformance input path resolves outside manifest directory: inputs\/input-file-link\.osdl\.json/
    );
  });
});

test("rejects an input below a symlinked directory outside the manifest directory", async () => {
  await withSuiteRoot(async suiteRoot => {
    const manifestDir = path.join(suiteRoot, "suite");
    const outsideDir = path.join(suiteRoot, "outside-inputs");
    const entry = osdlCase("input-directory-link");
    const manifestPath = await writeManifest(
      manifestDir,
      manifest("input-directory-link", {cases: [entry]})
    );
    await writeJson(path.join(outsideDir, `${entry.id}.osdl.json`), validDocument(entry.id));
    await symlink(outsideDir, path.join(manifestDir, "inputs"));
    await writeJson(path.join(manifestDir, entry.expected.results), {
      output: {final: {value: 1}}
    });

    await assert.rejects(
      loadSuite(manifestPath),
      /conformance input path resolves outside manifest directory: inputs\/input-directory-link\.osdl\.json/
    );
  });
});

test("rejects an expected artifact symlink outside the manifest directory", async () => {
  await withSuiteRoot(async suiteRoot => {
    const manifestDir = path.join(suiteRoot, "suite");
    const entry = osdlCase("expected-file-link");
    const manifestPath = await writeManifest(
      manifestDir,
      manifest("expected-file-link", {cases: [entry]})
    );
    await writeJson(path.join(manifestDir, entry.input.path), validDocument(entry.id));
    const outsideResults = path.join(suiteRoot, "outside.results.json");
    await writeJson(outsideResults, {output: {final: {value: 1}}});
    await mkdir(path.dirname(path.join(manifestDir, entry.expected.results)), {recursive: true});
    await symlink(outsideResults, path.join(manifestDir, entry.expected.results));

    await assert.rejects(
      loadSuite(manifestPath),
      /expected results path resolves outside manifest directory: expected\/expected-file-link\.results\.json/
    );
  });
});

test("rejects an expected artifact below a symlinked directory outside the manifest directory", async () => {
  await withSuiteRoot(async suiteRoot => {
    const manifestDir = path.join(suiteRoot, "suite");
    const outsideDir = path.join(suiteRoot, "outside-expected");
    const entry = osdlCase("expected-directory-link");
    const manifestPath = await writeManifest(
      manifestDir,
      manifest("expected-directory-link", {cases: [entry]})
    );
    await writeJson(path.join(manifestDir, entry.input.path), validDocument(entry.id));
    await writeJson(path.join(outsideDir, `${entry.id}.results.json`), {
      output: {final: {value: 1}}
    });
    await symlink(outsideDir, path.join(manifestDir, "expected"));

    await assert.rejects(
      loadSuite(manifestPath),
      /expected results path resolves outside manifest directory: expected\/expected-directory-link\.results\.json/
    );
  });
});

test("rejects an asserted artifact symlink outside the asserting manifest directory", async () => {
  await withSuiteRoot(async suiteRoot => {
    const parentDir = path.join(suiteRoot, "parent");
    const childDir = path.join(suiteRoot, "child");
    const entry = osdlCase("asserted-file-link");
    const parentPath = await writeManifest(parentDir, manifest("parent", {cases: [entry]}));
    const childPath = await writeManifest(childDir, manifest("child", {
      extends: ["parent@0.1.0"],
      assertions: [{
        case: entry.id,
        trace: {path: "expected/asserted-file-link.trace.ndjson"}
      }]
    }));
    await writeCaseArtifacts(parentDir, entry);
    const outsideTrace = path.join(suiteRoot, "outside.trace.ndjson");
    await writeText(outsideTrace, `${JSON.stringify(validEvent())}\n`);
    await mkdir(path.join(childDir, "expected"), {recursive: true});
    await symlink(
      outsideTrace,
      path.join(childDir, "expected/asserted-file-link.trace.ndjson")
    );

    await assert.rejects(
      loadSuite(childPath, new Map([
        ["parent@0.1.0", parentPath],
        ["child@0.1.0", childPath]
      ])),
      /expected trace path resolves outside manifest directory: expected\/asserted-file-link\.trace\.ndjson/
    );
  });
});

test("checks only the expected artifacts and returns a matching report", async () => {
  await withSuiteRoot(async suiteRoot => {
    const entry = osdlCase("results-only");
    const manifestPath = await writeManifest(suiteRoot, manifest("results-only", {cases: [entry]}));
    await writeCaseArtifacts(suiteRoot, entry);
    const actualRoot = path.join(suiteRoot, "actual");
    await writeJson(path.join(actualRoot, "results-only.results.json"), {
      output: {final: {value: 1}}
    });

    const report = await checkSuite(manifestPath, actualRoot);

    assert.equal(report.valid, true);
    assert.equal(report.checked, 1);
  });
});

test("checks inherited cases when given the manifest registry", async () => {
  await withSuiteRoot(async suiteRoot => {
    const parentDir = path.join(suiteRoot, "parent");
    const childDir = path.join(suiteRoot, "child");
    const parentCase = osdlCase("inherited");
    const childCase = osdlCase("local");
    const parentPath = await writeManifest(parentDir, manifest("parent", {cases: [parentCase]}));
    const childPath = await writeManifest(childDir, manifest("child", {
      extends: ["parent@0.1.0"],
      cases: [childCase]
    }));
    await Promise.all([
      writeCaseArtifacts(parentDir, parentCase),
      writeCaseArtifacts(childDir, childCase)
    ]);
    const actualRoot = path.join(suiteRoot, "actual");
    await Promise.all(["inherited", "local"].map(id => writeJson(
      path.join(actualRoot, `${id}.results.json`),
      {output: {final: {value: 1}}}
    )));

    const report = await checkSuite(childPath, actualRoot, new Map([
      ["parent@0.1.0", parentPath],
      ["child@0.1.0", childPath]
    ]));

    assert.deepEqual(report, {valid: true, checked: 2});
  });
});

test("strengthens an inherited case with a raw trace assertion", async () => {
  await withSuiteRoot(async suiteRoot => {
    const parentDir = path.join(suiteRoot, "parent");
    const childDir = path.join(suiteRoot, "child");
    const parentCase = osdlCase("inherited");
    const parentPath = await writeManifest(parentDir, manifest("parent", {cases: [parentCase]}));
    const childPath = await writeManifest(childDir, manifest("child", {
      extends: ["parent@0.1.0"],
      assertions: [{
        case: "inherited",
        trace: {path: "expected/inherited.trace.ndjson"}
      }]
    }));
    await writeCaseArtifacts(parentDir, parentCase);
    await writeText(
      path.join(childDir, "expected/inherited.trace.ndjson"),
      `${JSON.stringify(validEvent())}\n`
    );

    const suite = await loadSuite(childPath, new Map([
      ["parent@0.1.0", parentPath],
      ["child@0.1.0", childPath]
    ]));

    assert.equal(suite.cases.length, 1);
    assert.deepEqual(Object.keys(suite.cases[0].expected).sort(), ["results", "trace"]);
    assert.equal(suite.cases[0].expectedValues.trace.length, 1);
  });
});

test("passes an asserted result comparison policy to the comparator", async () => {
  await withSuiteRoot(async suiteRoot => {
    const entry = osdlCase("signed-zero");
    const manifestPath = await writeManifest(suiteRoot, manifest("signed-zero", {
      cases: [entry],
      assertions: [{
        case: "signed-zero",
        results: {comparison: {floatMode: "number"}}
      }]
    }));
    await writeCaseArtifacts(suiteRoot, entry);
    await writeText(
      path.join(suiteRoot, entry.expected.results),
      "{\"output\":{\"final\":{\"value\":-0}}}\n"
    );
    const actualRoot = path.join(suiteRoot, "actual");
    await writeJson(path.join(actualRoot, "signed-zero.results.json"), {
      output: {final: {value: 0}}
    });

    assert.deepEqual(await checkSuite(manifestPath, actualRoot), {valid: true, checked: 1});
  });
});

test("rejects a child result policy that weakens inherited bit comparison", async () => {
  await withSuiteRoot(async suiteRoot => {
    const parentDir = path.join(suiteRoot, "parent");
    const childDir = path.join(suiteRoot, "child");
    const entry = osdlCase("inherited-results");
    const parentPath = await writeManifest(parentDir, manifest("parent", {
      cases: [entry],
      assertions: [{
        case: entry.id,
        results: {comparison: {floatMode: "bits"}}
      }]
    }));
    const childPath = await writeManifest(childDir, manifest("child", {
      extends: ["parent@0.1.0"],
      assertions: [{
        case: entry.id,
        results: {comparison: {floatMode: "number"}}
      }]
    }));
    await writeCaseArtifacts(parentDir, entry);

    await assert.rejects(
      loadSuite(childPath, new Map([
        ["parent@0.1.0", parentPath],
        ["child@0.1.0", childPath]
      ])),
      /result comparison policy weakening for inherited-results: bits to number/
    );
  });
});

test("treats default bit comparison as an inherited result policy", async () => {
  await withSuiteRoot(async suiteRoot => {
    const parentDir = path.join(suiteRoot, "parent");
    const childDir = path.join(suiteRoot, "child");
    const entry = osdlCase("default-policy");
    const parentPath = await writeManifest(parentDir, manifest("parent", {cases: [entry]}));
    const childPath = await writeManifest(childDir, manifest("child", {
      extends: ["parent@0.1.0"],
      assertions: [{
        case: entry.id,
        results: {comparison: {floatMode: "number"}}
      }]
    }));
    await writeCaseArtifacts(parentDir, entry);

    await assert.rejects(
      loadSuite(childPath, new Map([
        ["parent@0.1.0", parentPath],
        ["child@0.1.0", childPath]
      ])),
      /result comparison policy weakening for default-policy: bits to number/
    );
  });
});

test("rejects a duplicate result policy assertion in one manifest", async () => {
  await withSuiteRoot(async suiteRoot => {
    const entry = osdlCase("duplicate-policy");
    const policy = {
      case: entry.id,
      results: {comparison: {floatMode: "bits"}}
    };
    const manifestPath = await writeManifest(suiteRoot, manifest("duplicate-policy", {
      cases: [entry],
      assertions: [policy, structuredClone(policy)]
    }));
    await writeCaseArtifacts(suiteRoot, entry);

    await assert.rejects(
      loadSuite(manifestPath),
      /duplicate result comparison policy assertion: duplicate-policy: bits/
    );
  });
});

test("rejects conflicting result policy assertions in one manifest", async () => {
  await withSuiteRoot(async suiteRoot => {
    const entry = osdlCase("conflicting-policy");
    const manifestPath = await writeManifest(suiteRoot, manifest("conflicting-policy", {
      cases: [entry],
      assertions: [
        {
          case: entry.id,
          results: {comparison: {floatMode: "number"}}
        },
        {
          case: entry.id,
          results: {comparison: {floatMode: "bits"}}
        }
      ]
    }));
    await writeCaseArtifacts(suiteRoot, entry);

    await assert.rejects(
      loadSuite(manifestPath),
      /conflicting result comparison policy assertions for conflicting-policy: number and bits/
    );
  });
});

test("allows child result policies to preserve or strengthen inherited comparison", async () => {
  await withSuiteRoot(async suiteRoot => {
    const parentDir = path.join(suiteRoot, "parent");
    const preservingDir = path.join(suiteRoot, "preserving");
    const strengtheningDir = path.join(suiteRoot, "strengthening");
    const entry = osdlCase("policy-order");
    const parentPath = await writeManifest(parentDir, manifest("parent", {
      cases: [entry],
      assertions: [{
        case: entry.id,
        results: {comparison: {floatMode: "number"}}
      }]
    }));
    const preservingPath = await writeManifest(preservingDir, manifest("preserving", {
      extends: ["parent@0.1.0"],
      assertions: [{
        case: entry.id,
        results: {comparison: {floatMode: "number"}}
      }]
    }));
    const strengtheningPath = await writeManifest(strengtheningDir, manifest("strengthening", {
      extends: ["parent@0.1.0"],
      assertions: [{
        case: entry.id,
        results: {comparison: {floatMode: "bits"}}
      }]
    }));
    await writeCaseArtifacts(parentDir, entry);
    const registry = new Map([
      ["parent@0.1.0", parentPath],
      ["preserving@0.1.0", preservingPath],
      ["strengthening@0.1.0", strengtheningPath]
    ]);

    const preserving = await loadSuite(preservingPath, registry);
    const strengthening = await loadSuite(strengtheningPath, registry);

    assert.equal(preserving.cases[0].comparisons.results.floatMode, "number");
    assert.equal(strengthening.cases[0].comparisons.results.floatMode, "bits");
  });
});

test("compares trace NDJSON regardless of object-key order or decimal spelling", async () => {
  await withSuiteRoot(async suiteRoot => {
    const entry = osdlCase("trace-match", {trace: "expected/trace-match.trace.ndjson"});
    const manifestPath = await writeManifest(suiteRoot, manifest("trace-match", {cases: [entry]}));
    await writeCaseArtifacts(suiteRoot, entry);
    const actualRoot = path.join(suiteRoot, "actual");
    await writeText(
      path.join(suiteRoot, entry.expected.trace),
      "{\"v\":\"0.1\",\"seq\":0,\"time\":1.0,\"type\":\"custom.event\",\"source\":\"kernel\",\"payload\":{\"first\":1.0,\"second\":2}}\n"
    );
    await writeText(
      path.join(actualRoot, "trace-match.trace.ndjson"),
      "{\"payload\":{\"second\":2.00,\"first\":1.000},\"source\":\"kernel\",\"type\":\"custom.event\",\"time\":1.00,\"seq\":0,\"v\":\"0.1\"}\n"
    );

    assert.deepEqual(await checkSuite(manifestPath, actualRoot), {valid: true, checked: 1});
  });
});

test("accepts a raw trace payload with unequal time and value lengths", async () => {
  await withSuiteRoot(async suiteRoot => {
    const entry = osdlCase("trace-opaque-payload", {
      trace: "expected/trace-opaque-payload.trace.ndjson"
    });
    const manifestPath = await writeManifest(suiteRoot, manifest("trace-opaque-payload", {cases: [entry]}));
    await writeCaseArtifacts(suiteRoot, entry);
    const trace = `${JSON.stringify({
      ...validEvent(), payload: {times: [0, 1], values: [1]}
    })}\n`;
    await writeText(path.join(suiteRoot, entry.expected.trace), trace);
    const actualRoot = path.join(suiteRoot, "actual");
    await writeText(path.join(actualRoot, "trace-opaque-payload.trace.ndjson"), trace);

    assert.deepEqual(await checkSuite(manifestPath, actualRoot), {valid: true, checked: 1});
  });
});

test("reports the first trace event mismatch", async () => {
  await withSuiteRoot(async suiteRoot => {
    const entry = osdlCase("trace-mismatch", {trace: "expected/trace-mismatch.trace.ndjson"});
    const manifestPath = await writeManifest(suiteRoot, manifest("trace-mismatch", {cases: [entry]}));
    await writeCaseArtifacts(suiteRoot, entry);
    const actualRoot = path.join(suiteRoot, "actual");
    await writeText(
      path.join(actualRoot, "trace-mismatch.trace.ndjson"),
      `${JSON.stringify(validEvent(1))}\n`
    );

    const report = await checkSuite(manifestPath, actualRoot);

    assert.deepEqual(report, {
      valid: false,
      checked: 0,
      caseId: "trace-mismatch",
      artifact: "trace",
      comparison: {
        equal: false,
        path: "/0/time",
        message: "values differ",
        expected: 0,
        actual: 1
      }
    });
  });
});

test("rejects a missing actual trace artifact", async () => {
  await withSuiteRoot(async suiteRoot => {
    const entry = osdlCase("trace-missing", {trace: "expected/trace-missing.trace.ndjson"});
    const manifestPath = await writeManifest(suiteRoot, manifest("trace-missing", {cases: [entry]}));
    await writeCaseArtifacts(suiteRoot, entry);

    await assert.rejects(
      checkSuite(manifestPath, path.join(suiteRoot, "actual")),
      /missing actual trace: trace-missing/
    );
  });
});

test("rejects an expected trace event that fails schema validation", async () => {
  await withSuiteRoot(async suiteRoot => {
    const entry = osdlCase("trace-invalid-expected", {trace: "expected/trace-invalid-expected.trace.ndjson"});
    const manifestPath = await writeManifest(suiteRoot, manifest("trace-invalid-expected", {cases: [entry]}));
    await writeCaseArtifacts(suiteRoot, entry);
    await writeText(path.join(suiteRoot, entry.expected.trace), "{}\n");

    await assert.rejects(
      loadSuite(manifestPath),
      /invalid expected trace: trace-invalid-expected: line 1:/
    );
  });
});

test("rejects an actual trace event that fails schema validation", async () => {
  await withSuiteRoot(async suiteRoot => {
    const entry = osdlCase("trace-invalid-actual", {trace: "expected/trace-invalid-actual.trace.ndjson"});
    const manifestPath = await writeManifest(suiteRoot, manifest("trace-invalid-actual", {cases: [entry]}));
    await writeCaseArtifacts(suiteRoot, entry);
    const actualRoot = path.join(suiteRoot, "actual");
    await writeText(path.join(actualRoot, "trace-invalid-actual.trace.ndjson"), "{}\n");

    await assert.rejects(
      checkSuite(manifestPath, actualRoot),
      /invalid actual trace: trace-invalid-actual: line 1:/
    );
  });
});

test("checks expected and actual NDJSON events with portable equality", async () => {
  await withSuiteRoot(async suiteRoot => {
    const entry = osdlCase("events-match", {events: "expected/events-match.events.ndjson"});
    const manifestPath = await writeManifest(suiteRoot, manifest("events-match", {cases: [entry]}));
    await writeCaseArtifacts(suiteRoot, entry);
    const actualRoot = path.join(suiteRoot, "actual");
    await writeText(path.join(actualRoot, "events-match.events.ndjson"), `${JSON.stringify({
      ...validEvent(), seq: 9, wallTime: 10
    })}\n`);

    assert.deepEqual(await checkSuite(manifestPath, actualRoot), {valid: true, checked: 1});
  });
});

test("accepts an expected portable event without sequence or wall-clock fields", async () => {
  await withSuiteRoot(async suiteRoot => {
    const entry = osdlCase("events-portable", {events: "expected/events-portable.events.ndjson"});
    const manifestPath = await writeManifest(suiteRoot, manifest("events-portable", {cases: [entry]}));
    await writeCaseArtifacts(suiteRoot, entry);

    const suite = await loadSuite(manifestPath);

    assert.deepEqual(suite.cases[0].expectedValues.events, [portableEvent()]);
  });
});

test("rejects seq in an expected portable event", async () => {
  await withSuiteRoot(async suiteRoot => {
    const entry = osdlCase("events-seq", {events: "expected/events-seq.events.ndjson"});
    const manifestPath = await writeManifest(suiteRoot, manifest("events-seq", {cases: [entry]}));
    await writeCaseArtifacts(suiteRoot, entry);
    await writeText(path.join(suiteRoot, entry.expected.events), `${JSON.stringify(validEvent())}\n`);

    await assert.rejects(
      loadSuite(manifestPath),
      /invalid expected event: events-seq: line 1: portable event must omit seq/
    );
  });
});

test("rejects wallTime in an expected portable event", async () => {
  await withSuiteRoot(async suiteRoot => {
    const entry = osdlCase("events-wall-time", {events: "expected/events-wall-time.events.ndjson"});
    const manifestPath = await writeManifest(suiteRoot, manifest("events-wall-time", {cases: [entry]}));
    await writeCaseArtifacts(suiteRoot, entry);
    await writeText(path.join(suiteRoot, entry.expected.events), `${JSON.stringify({
      ...portableEvent(), wallTime: 10
    })}\n`);

    await assert.rejects(
      loadSuite(manifestPath),
      /invalid expected event: events-wall-time: line 1: portable event must omit wallTime/
    );
  });
});

test("rejects telemetry in an expected portable event", async () => {
  await withSuiteRoot(async suiteRoot => {
    const entry = osdlCase("events-telemetry", {events: "expected/events-telemetry.events.ndjson"});
    const manifestPath = await writeManifest(suiteRoot, manifest("events-telemetry", {cases: [entry]}));
    await writeCaseArtifacts(suiteRoot, entry);
    await writeText(path.join(suiteRoot, entry.expected.events), `${JSON.stringify({
      ...portableEvent(), type: "sim.progress", payload: {progress: 0.5}
    })}\n`);

    await assert.rejects(
      loadSuite(manifestPath),
      /invalid expected event: events-telemetry: line 1: portable event must omit telemetry type sim\.progress/
    );
  });
});

test("rejects malformed expected portable event JSON", async () => {
  await withSuiteRoot(async suiteRoot => {
    const entry = osdlCase("events-malformed-expected", {
      events: "expected/events-malformed-expected.events.ndjson"
    });
    const manifestPath = await writeManifest(
      suiteRoot,
      manifest("events-malformed-expected", {cases: [entry]})
    );
    await writeCaseArtifacts(suiteRoot, entry);
    await writeText(path.join(suiteRoot, entry.expected.events), "not-json\n");

    await assert.rejects(
      loadSuite(manifestPath),
      /invalid expected event: events-malformed-expected: line 1:/
    );
  });
});

test("rejects invalid expected portable event content", async () => {
  await withSuiteRoot(async suiteRoot => {
    const entry = osdlCase("events-invalid-expected", {
      events: "expected/events-invalid-expected.events.ndjson"
    });
    const manifestPath = await writeManifest(
      suiteRoot,
      manifest("events-invalid-expected", {cases: [entry]})
    );
    await writeCaseArtifacts(suiteRoot, entry);
    await writeText(path.join(suiteRoot, entry.expected.events), `${JSON.stringify({
      ...portableEvent(), source: "invalid source"
    })}\n`);

    await assert.rejects(
      loadSuite(manifestPath),
      /invalid expected event: events-invalid-expected: line 1: .*must match pattern/
    );
  });
});

test("reports a portable NDJSON event mismatch", async () => {
  await withSuiteRoot(async suiteRoot => {
    const entry = osdlCase("events-mismatch", {events: "expected/events-mismatch.events.ndjson"});
    const manifestPath = await writeManifest(suiteRoot, manifest("events-mismatch", {cases: [entry]}));
    await writeCaseArtifacts(suiteRoot, entry);
    const actualRoot = path.join(suiteRoot, "actual");
    await writeText(path.join(actualRoot, "events-mismatch.events.ndjson"), `${JSON.stringify(validEvent(1))}\n`);

    const report = await checkSuite(manifestPath, actualRoot);

    assert.deepEqual(report, {
      valid: false,
      checked: 0,
      caseId: "events-mismatch",
      artifact: "events",
      comparison: {
        equal: false,
        path: "/0/time",
        message: "values differ",
        expected: 0,
        actual: 1
      }
    });
  });
});

test("rejects an actual NDJSON event that fails schema validation", async () => {
  await withSuiteRoot(async suiteRoot => {
    const entry = osdlCase("events-invalid", {events: "expected/events-invalid.events.ndjson"});
    const manifestPath = await writeManifest(suiteRoot, manifest("events-invalid", {cases: [entry]}));
    await writeCaseArtifacts(suiteRoot, entry);
    const actualRoot = path.join(suiteRoot, "actual");
    await writeText(path.join(actualRoot, "events-invalid.events.ndjson"), "{}\n");

    await assert.rejects(
      checkSuite(manifestPath, actualRoot),
      /invalid actual event: events-invalid: line 1:/
    );
  });
});

test("rejects a malformed actual NDJSON event line", async () => {
  await withSuiteRoot(async suiteRoot => {
    const entry = osdlCase("events-malformed", {events: "expected/events-malformed.events.ndjson"});
    const manifestPath = await writeManifest(suiteRoot, manifest("events-malformed", {cases: [entry]}));
    await writeCaseArtifacts(suiteRoot, entry);
    const actualRoot = path.join(suiteRoot, "actual");
    await writeText(path.join(actualRoot, "events-malformed.events.ndjson"), "not-json\n");

    await assert.rejects(
      checkSuite(manifestPath, actualRoot),
      /invalid actual event: events-malformed: line 1:/
    );
  });
});

test("stops at the first artifact mismatch", async () => {
  await withSuiteRoot(async suiteRoot => {
    const first = osdlCase("first");
    const second = osdlCase("second", {events: "expected/second.events.ndjson"});
    const manifestPath = await writeManifest(suiteRoot, manifest("runner", {
      cases: [first, second]
    }));
    await Promise.all([
      writeCaseArtifacts(suiteRoot, first),
      writeCaseArtifacts(suiteRoot, second)
    ]);
    const actualRoot = path.join(suiteRoot, "actual");
    await writeJson(path.join(actualRoot, "first.results.json"), {
      output: {final: {value: 2}}
    });

    const report = await checkSuite(manifestPath, actualRoot);

    assert.deepEqual(report, {
      valid: false,
      checked: 0,
      caseId: "first",
      artifact: "results",
      comparison: {
        equal: false,
        path: "/output/final/value",
        message: "values differ",
        expected: 1,
        actual: 2
      }
    });
  });
});

test("returns CLI status codes for match, mismatch, and invalid use", async () => {
  await withSuiteRoot(async suiteRoot => {
    const entry = osdlCase("cli-case");
    const manifestPath = await writeManifest(suiteRoot, manifest("cli", {cases: [entry]}));
    await writeCaseArtifacts(suiteRoot, entry);
    const actualRoot = path.join(suiteRoot, "actual");
    await writeJson(path.join(actualRoot, "cli-case.results.json"), {
      output: {final: {value: 1}}
    });
    const cliPath = path.join(rootDir, "scripts/check-conformance.mjs");

    assert.equal(spawnSync(process.execPath, [cliPath, manifestPath, actualRoot]).status, 0);
    await writeJson(path.join(actualRoot, "cli-case.results.json"), {
      output: {final: {value: 2}}
    });
    assert.equal(spawnSync(process.execPath, [cliPath, manifestPath, actualRoot]).status, 1);
    assert.equal(spawnSync(process.execPath, [cliPath]).status, 2);
  });
});
