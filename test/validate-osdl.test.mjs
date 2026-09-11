import assert from "node:assert/strict";
import {spawnSync} from "node:child_process";
import {mkdtemp, mkdir, readFile, rm, writeFile} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {fileURLToPath} from "node:url";

import {
  loadArtifacts,
  validateDocument,
  validateFiles
} from "../scripts/lib/validate-osdl.mjs";

const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const fixtureDir = path.join(rootDir, "test/fixtures/validation");
const schemaFiles = [
  "osdl.schema.json",
  "osdl.library.schema.json",
  "osdl.events.schema.json",
  "osdl.results.schema.json",
  "osdl.conformance.schema.json",
  "osdl.machine-fixture.schema.json"
];

async function readJson(fileName) {
  return JSON.parse(await readFile(path.join(fixtureDir, fileName), "utf8"));
}

function documentWith(component) {
  return {
    osdl: "0.1",
    model: {
      name: "testModel",
      components: [component]
    }
  };
}

function libraryDefinition(namespace, components) {
  return {
    osdl: "0.1",
    library: {
      namespace,
      name: "Test Library",
      version: "0.1.0",
      description: "A library for validator tests.",
      components: components.map(component => ({
        description: "A test component.",
        ports: [],
        ...component
      }))
    }
  };
}

async function withArtifactRoot(libraries, action) {
  const artifactRoot = await mkdtemp(path.join(os.tmpdir(), "osdl-validation-"));

  try {
    await mkdir(path.join(artifactRoot, "schemas"));
    await mkdir(path.join(artifactRoot, "libraries"));
    await Promise.all(schemaFiles.map(async fileName => writeFile(
      path.join(artifactRoot, "schemas", fileName),
      await readFile(path.join(rootDir, "schemas", fileName))
    )));

    await Promise.all(libraries.map(async ({fileName, definition}) => {
      await writeFile(
        path.join(artifactRoot, "libraries", fileName),
        JSON.stringify(definition)
      );
    }));

    return await action(artifactRoot);
  } finally {
    await rm(artifactRoot, {recursive: true, force: true});
  }
}

function assertDiagnostic(actual, expected) {
  for (const [key, value] of Object.entries(expected)) {
    assert.deepEqual(actual[key], value);
  }
}

test("validates the three published examples", async () => {
  const artifacts = await loadArtifacts(rootDir);

  for (const fileName of [
    "clinic-hybrid.osdl.json",
    "mm1-queue.osdl.json",
    "sir-epidemic.osdl.json"
  ]) {
    const documentPath = path.join(rootDir, "examples", fileName);
    const document = JSON.parse(await readFile(documentPath, "utf8"));

    assert.deepEqual(validateDocument(document, artifacts, documentPath), []);
  }
});

test("stops after a phase-one document error", async () => {
  const artifacts = await loadArtifacts(rootDir);
  const document = {
    osdl: "0.1",
    model: {
      name: "invalid-model",
      components: [{id: "invalid", type: "des.source", params: []}]
    }
  };

  const diagnostics = validateDocument(document, artifacts);

  assert.ok(diagnostics.length > 0);
  assert.ok(diagnostics.every(({phase}) => phase === "document-schema"));
});

test("reports invalid component parameters with component context", async () => {
  const result = await validateFiles(
    [path.join(fixtureDir, "invalid-des-source.osdl.json")],
    {rootDir}
  );

  assert.equal(result.valid, false);
  assertDiagnostic(result.diagnostics[0], {
    phase: "component-params",
    path: "/model/components/0/params",
    componentId: "invalidSource",
    componentType: "des.source",
    library: "des"
  });
});

test("reports an unknown library", async () => {
  const result = await validateFiles(
    [path.join(fixtureDir, "unknown-library.osdl.json")],
    {rootDir}
  );

  assert.equal(result.valid, false);
  assertDiagnostic(result.diagnostics[0], {
    phase: "component-library",
    code: "unknown-library",
    componentId: "missingLibrary",
    componentType: "future.widget",
    library: "future"
  });
});

test("reports an unknown component type", async () => {
  const result = await validateFiles(
    [path.join(fixtureDir, "unknown-component.osdl.json")],
    {rootDir}
  );

  assert.equal(result.valid, false);
  assertDiagnostic(result.diagnostics[0], {
    phase: "component-library",
    code: "unknown-component",
    componentId: "missingType",
    componentType: "des.widget",
    library: "des"
  });
});

test("validates omitted params as an empty object", async () => {
  await withArtifactRoot([
    {
      fileName: "test.library.json",
      definition: libraryDefinition("test", [{
        name: "optional",
        params: {type: "object", additionalProperties: false}
      }])
    }
  ], async artifactRoot => {
    const artifacts = await loadArtifacts(artifactRoot);
    const diagnostics = validateDocument(
      documentWith({id: "optional", type: "test.optional"}),
      artifacts
    );

    assert.deepEqual(diagnostics, []);
  });
});

test("rejects duplicate library namespaces", async () => {
  await withArtifactRoot([
    {
      fileName: "first.library.json",
      definition: libraryDefinition("test", [{name: "first"}])
    },
    {
      fileName: "second.library.json",
      definition: libraryDefinition("test", [{name: "second"}])
    }
  ], async artifactRoot => {
    await assert.rejects(loadArtifacts(artifactRoot), /duplicate library namespace: test/);
  });
});

test("rejects duplicate component types in a library", async () => {
  await withArtifactRoot([
    {
      fileName: "test.library.json",
      definition: libraryDefinition("test", [
        {name: "item", params: {}},
        {name: "item", params: {}}
      ])
    }
  ], async artifactRoot => {
    await assert.rejects(loadArtifacts(artifactRoot), /duplicate component type: test.item/);
  });
});

test("rejects a structurally invalid library document", async () => {
  await withArtifactRoot([
    {
      fileName: "invalid.library.json",
      definition: {
        osdl: "0.1",
        library: {
          namespace: "test",
          name: "Test Library",
          version: "0.1.0",
          description: "A library with no components.",
          components: []
        }
      }
    }
  ], async artifactRoot => {
    await assert.rejects(loadArtifacts(artifactRoot), /invalid library document/);
  });
});

test("rejects an artifact root without the machine fixture schema", async () => {
  const artifactRoot = await mkdtemp(path.join(os.tmpdir(), "osdl-validation-missing-schema-"));

  try {
    await mkdir(path.join(artifactRoot, "schemas"));
    await mkdir(path.join(artifactRoot, "libraries"));
    await Promise.all(schemaFiles
      .filter(fileName => fileName !== "osdl.machine-fixture.schema.json")
      .map(async fileName => writeFile(
        path.join(artifactRoot, "schemas", fileName),
        await readFile(path.join(rootDir, "schemas", fileName))
      )));

    await assert.rejects(loadArtifacts(artifactRoot), /osdl\.machine-fixture\.schema\.json/);
  } finally {
    await rm(artifactRoot, {recursive: true, force: true});
  }
});

test("exits 1 and writes diagnostics for an invalid document", () => {
  const result = spawnSync(
    process.execPath,
    ["scripts/validate-osdl.mjs", "test/fixtures/validation/invalid-des-source.osdl.json"],
    {cwd: rootDir, encoding: "utf8", stdio: "pipe"}
  );

  assert.equal(result.status, 1);
  assert.match(result.stderr, /"phase":"component-params"/);
});

test("exits 2 for missing command arguments", () => {
  const result = spawnSync(process.execPath, ["scripts/validate-osdl.mjs"], {
    cwd: rootDir,
    encoding: "utf8",
    stdio: "pipe"
  });

  assert.equal(result.status, 2);
  assert.match(result.stderr, /usage: node scripts\/validate-osdl\.mjs <document>\.\.\./);
});

test("exits 2 for an unreadable input", async () => {
  const inputDir = await mkdtemp(path.join(os.tmpdir(), "osdl-validation-input-"));
  const missingInput = path.join(inputDir, "missing.osdl.json");

  try {
    const result = spawnSync(
      process.execPath,
      ["scripts/validate-osdl.mjs", missingInput],
      {cwd: rootDir, encoding: "utf8", stdio: "pipe"}
    );

    assert.equal(result.status, 2);
    assert.match(result.stderr, /ENOENT/);
  } finally {
    await rm(inputDir, {recursive: true, force: true});
  }
});
