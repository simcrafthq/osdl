import {readdir, readFile, realpath} from "node:fs/promises";
import path from "node:path";
import {fileURLToPath} from "node:url";

import {
  compareJson,
  comparePortableEvents,
  compareResults,
  TELEMETRY_TYPES
} from "./conformance.mjs";
import {
  loadArtifacts,
  validateDocument,
  validateManifest,
  validateResults
} from "./validate-osdl.mjs";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

function formatDiagnostics(diagnostics) {
  return diagnostics.map(({path: diagnosticPath, instancePath, message}) => {
    const location = diagnosticPath ?? instancePath;
    return location ? `${location} ${message}` : message;
  }).join("; ");
}

async function readJson(filePath, description) {
  try {
    return JSON.parse(await readFile(filePath, "utf8"));
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`cannot read ${description}: ${filePath}: ${message}`);
  }
}

function resolveContainedPath(directory, sourcePath) {
  const resolvedPath = path.resolve(directory, sourcePath);
  const relativePath = path.relative(directory, resolvedPath);
  if (relativePath === ".." || relativePath.startsWith(`..${path.sep}`) || path.isAbsolute(relativePath)) {
    throw new Error(`conformance path escapes manifest directory: ${sourcePath}`);
  }
  return resolvedPath;
}

async function resolveContainedReadPath(directory, sourcePath, description) {
  const resolvedPath = resolveContainedPath(directory, sourcePath);
  let realDirectory;
  let realSource;
  try {
    [realDirectory, realSource] = await Promise.all([
      realpath(directory),
      realpath(resolvedPath)
    ]);
  } catch (error) {
    if (error && typeof error === "object" && error.code === "ENOENT") {
      return resolvedPath;
    }
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`cannot resolve ${description}: ${sourcePath}: ${message}`);
  }

  const relativePath = path.relative(realDirectory, realSource);
  if (relativePath === ".." || relativePath.startsWith(`..${path.sep}`) ||
      path.isAbsolute(relativePath)) {
    throw new Error(`${description} resolves outside manifest directory: ${sourcePath}`);
  }
  return realSource;
}

async function readNdjsonEvents(filePath, validateEvents, caseId, {missing, invalid}) {
  let source;
  try {
    source = await readFile(filePath, "utf8");
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`${missing}: ${caseId}: ${message}`);
  }

  const events = [];
  for (const [index, line] of source.split(/\r?\n/).entries()) {
    if (line.trim() === "") continue;
    let event;
    try {
      event = JSON.parse(line);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      throw new Error(`${invalid}: ${caseId}: line ${index + 1}: ${message}`);
    }
    if (!validateEvents(event)) {
      throw new Error(
        `${invalid}: ${caseId}: line ${index + 1}: ${formatDiagnostics(validateEvents.errors ?? [])}`
      );
    }
    events.push(event);
  }
  return events;
}

async function readExpectedEvents(filePath, validateEvents, caseId) {
  const validatePortableEvent = event => {
    if (event !== null && typeof event === "object" && Object.hasOwn(event, "seq")) {
      validatePortableEvent.errors = [{message: "portable event must omit seq"}];
      return false;
    }
    if (event !== null && typeof event === "object" && Object.hasOwn(event, "wallTime")) {
      validatePortableEvent.errors = [{message: "portable event must omit wallTime"}];
      return false;
    }
    if (TELEMETRY_TYPES.has(event?.type)) {
      validatePortableEvent.errors = [{
        message: `portable event must omit telemetry type ${event.type}`
      }];
      return false;
    }

    const valid = validateEvents({...event, seq: 0});
    validatePortableEvent.errors = validateEvents.errors;
    return valid;
  };

  return readNdjsonEvents(filePath, validatePortableEvent, caseId, {
    missing: "missing expected events",
    invalid: "invalid expected event"
  });
}

async function readActualEvents(filePath, validateEvents, caseId) {
  return readNdjsonEvents(filePath, validateEvents, caseId, {
    missing: "missing actual events",
    invalid: "invalid actual event"
  });
}

async function readExpectedTrace(filePath, validateEvents, caseId) {
  return readNdjsonEvents(filePath, validateEvents, caseId, {
    missing: "missing expected trace",
    invalid: "invalid expected trace"
  });
}

async function readActualTrace(filePath, validateEvents, caseId) {
  return readNdjsonEvents(filePath, validateEvents, caseId, {
    missing: "missing actual trace",
    invalid: "invalid actual trace"
  });
}

function registryPath(registry, key) {
  const entry = registry instanceof Map ? registry.get(key) : registry?.[key];
  if (typeof entry === "string") return entry;
  if (entry && typeof entry.path === "string") return entry.path;
  if (entry && typeof entry.manifestPath === "string") return entry.manifestPath;
  return null;
}

export async function discoverManifestRegistry(directory) {
  const registry = new Map();

  async function visit(currentDirectory) {
    const entries = await readdir(currentDirectory, {withFileTypes: true});
    for (const entry of entries) {
      if (entry.isDirectory()) {
        if ([".git", ".worktrees", "node_modules"].includes(entry.name)) continue;
        await visit(path.join(currentDirectory, entry.name));
        continue;
      }
      if (!entry.isFile() || entry.name !== "manifest.json") continue;

      const manifestPath = path.join(currentDirectory, entry.name);
      const manifest = await readJson(manifestPath, "conformance manifest");
      if (typeof manifest.id !== "string" || typeof manifest.version !== "string") continue;
      const key = `${manifest.id}@${manifest.version}`;
      if (registry.has(key) && registry.get(key) !== manifestPath) {
        throw new Error(`duplicate conformance manifest: ${key}`);
      }
      registry.set(key, manifestPath);
    }
  }

  await visit(directory);
  return registry;
}

async function validateCaseArtifacts(
  caseEntry,
  manifestDirectory,
  artifacts,
  loadExpectedArtifacts
) {
  const inputPath = resolveContainedPath(manifestDirectory, caseEntry.input.path);
  const inputReadPath = await resolveContainedReadPath(
    manifestDirectory,
    caseEntry.input.path,
    "conformance input path"
  );
  let input;
  try {
    input = await readJson(inputReadPath, `case input for ${caseEntry.id}`);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (message.includes("ENOENT")) throw new Error(`missing case input: ${caseEntry.id}`);
    throw error;
  }

  if (caseEntry.input.format === "osdl") {
    const diagnostics = validateDocument(input, artifacts, inputPath);
    if (diagnostics.length > 0) {
      throw new Error(`invalid OSDL input: ${caseEntry.id}: ${formatDiagnostics(diagnostics)}`);
    }
  } else if (typeof artifacts.validateMachineFixture === "function") {
    const diagnostics = artifacts.validateMachineFixture(input);
    if (diagnostics.length > 0) {
      throw new Error(`invalid machine input: ${caseEntry.id}: ${formatDiagnostics(diagnostics)}`);
    }
  } else if (input === null || Array.isArray(input) || typeof input !== "object") {
    throw new Error(`invalid machine input: ${caseEntry.id}`);
  }

  const expectedPaths = {};
  const expectedValues = {};
  for (const [artifact, sourcePath] of Object.entries(caseEntry.expected)) {
    const artifactPath = resolveContainedPath(manifestDirectory, sourcePath);
    expectedPaths[artifact] = artifactPath;
    if (!loadExpectedArtifacts) continue;
    const artifactReadPath = await resolveContainedReadPath(
      manifestDirectory,
      sourcePath,
      `expected ${artifact} path`
    );
    if (artifact === "results") {
      let results;
      try {
        results = await readJson(artifactReadPath, `expected results for ${caseEntry.id}`);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        if (message.includes("ENOENT")) throw new Error(`missing expected results: ${caseEntry.id}`);
        throw error;
      }
      const diagnostics = validateResults(results);
      if (diagnostics.length > 0) {
        throw new Error(`invalid expected results: ${caseEntry.id}: ${formatDiagnostics(diagnostics)}`);
      }
      expectedValues.results = results;
    } else if (artifact === "events") {
      expectedValues.events = await readExpectedEvents(
        artifactReadPath,
        artifacts.validateEvents,
        caseEntry.id
      );
    } else if (artifact === "trace") {
      expectedValues.trace = await readExpectedTrace(
        artifactReadPath,
        artifacts.validateEvents,
        caseEntry.id
      );
    } else {
      try {
        expectedValues[artifact] = await readFile(artifactReadPath, "utf8");
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        if (message.includes("ENOENT")) throw new Error(`missing expected ${artifact}: ${caseEntry.id}`);
        throw new Error(`cannot read expected ${artifact}: ${caseEntry.id}: ${message}`);
      }
    }
  }

  return {inputValue: input, inputPath, expectedPaths, expectedValues};
}

async function loadAssertedArtifact(
  target,
  artifact,
  assertion,
  manifestDirectory,
  artifacts,
  loadExpectedArtifacts
) {
  if (assertion.path === undefined) {
    if (!target.expected[artifact]) {
      throw new Error(`missing asserted ${artifact}: ${target.id}`);
    }
    return;
  }
  if (target.expected[artifact]) {
    throw new Error(`duplicate conformance ${artifact} assertion: ${target.id}`);
  }

  const artifactPath = resolveContainedPath(manifestDirectory, assertion.path);
  target.expected[artifact] = assertion.path;
  target.expectedPaths[artifact] = artifactPath;
  if (!loadExpectedArtifacts) return;
  const artifactReadPath = await resolveContainedReadPath(
    manifestDirectory,
    assertion.path,
    `expected ${artifact} path`
  );
  if (artifact === "results") {
    let results;
    try {
      results = await readJson(artifactReadPath, `expected results for ${target.id}`);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (message.includes("ENOENT")) throw new Error(`missing expected results: ${target.id}`);
      throw error;
    }
    const diagnostics = validateResults(results);
    if (diagnostics.length > 0) {
      throw new Error(`invalid expected results: ${target.id}: ${formatDiagnostics(diagnostics)}`);
    }
    target.expectedValues.results = results;
  } else if (artifact === "events") {
    target.expectedValues.events = await readExpectedEvents(
      artifactReadPath,
      artifacts.validateEvents,
      target.id
    );
  } else {
    target.expectedValues.trace = await readExpectedTrace(
      artifactReadPath,
      artifacts.validateEvents,
      target.id
    );
  }
}

function applyResultComparisonPolicy(target, policy, manifestKey) {
  const current = target.comparisons.results;
  const source = target.comparisonSources.results;
  if (source?.manifestKey === manifestKey && source.explicit) {
    if (current.floatMode === policy.floatMode) {
      throw new Error(
        `duplicate result comparison policy assertion: ${target.id}: ${policy.floatMode}`
      );
    }
    throw new Error(
      `conflicting result comparison policy assertions for ${target.id}: ` +
      `${current.floatMode} and ${policy.floatMode}`
    );
  }
  if (current?.floatMode === "bits" && policy.floatMode === "number" &&
      source?.manifestKey !== manifestKey) {
    throw new Error(
      `result comparison policy weakening for ${target.id}: bits to number`
    );
  }

  target.comparisons.results = {...policy};
  target.comparisonSources.results = {manifestKey, explicit: true};
}

/** Load and validate a manifest graph with parents before children. */
export async function loadSuite(
  manifestPath,
  registry = new Map(),
  {loadExpectedArtifacts = true} = {}
) {
  const artifacts = await loadArtifacts(repositoryRoot);
  const manifests = [];
  const cases = [];
  const visiting = new Set();
  const visited = new Set();
  const stack = [];
  const caseIds = new Set();
  const casesById = new Map();

  async function visit(currentPath, referenceKey = null) {
    if (referenceKey && visiting.has(referenceKey)) {
      const cycleStart = stack.indexOf(referenceKey);
      const cycle = [...stack.slice(cycleStart), referenceKey].join(" -> ");
      throw new Error(`conformance extension cycle: ${cycle}`);
    }
    if (referenceKey && visited.has(referenceKey)) return;

    const manifest = await readJson(currentPath, "conformance manifest");
    const diagnostics = validateManifest(manifest);
    if (diagnostics.length > 0) {
      throw new Error(`invalid conformance manifest: ${currentPath}: ${formatDiagnostics(diagnostics)}`);
    }
    const key = `${manifest.id}@${manifest.version}`;
    if (referenceKey && referenceKey !== key) {
      throw new Error(`conformance registry key mismatch: expected ${referenceKey}, got ${key}`);
    }
    if (visiting.has(key)) {
      const cycleStart = stack.indexOf(key);
      const cycle = [...stack.slice(cycleStart), key].join(" -> ");
      throw new Error(`conformance extension cycle: ${cycle}`);
    }
    if (visited.has(key)) return;

    visiting.add(key);
    stack.push(key);
    for (const parentKey of manifest.extends ?? []) {
      const parentPath = registryPath(registry, parentKey);
      if (!parentPath) throw new Error(`missing conformance parent: ${parentKey}`);
      await visit(parentPath, parentKey);
    }

    const manifestDirectory = path.dirname(currentPath);
    const resolvedCases = [];
    for (const caseEntry of manifest.cases) {
      if (caseIds.has(caseEntry.id)) {
        throw new Error(`duplicate conformance case id: ${caseEntry.id}`);
      }
      const resolved = await validateCaseArtifacts(
        caseEntry,
        manifestDirectory,
        artifacts,
        loadExpectedArtifacts
      );
      caseIds.add(caseEntry.id);
      const resolvedCase = {
        ...caseEntry,
        expected: {...caseEntry.expected},
        manifestPath: currentPath,
        moduleKey: key,
        comparisons: caseEntry.expected.results ? {results: {floatMode: "bits"}} : {},
        comparisonSources: caseEntry.expected.results
          ? {results: {manifestKey: key, explicit: false}}
          : {},
        ...resolved
      };
      casesById.set(caseEntry.id, resolvedCase);
      resolvedCases.push(resolvedCase);
    }
    manifests.push({key, path: currentPath, manifest});
    cases.push(...resolvedCases);

    for (const assertion of manifest.assertions ?? []) {
      const target = casesById.get(assertion.case);
      if (!target) throw new Error(`conformance assertion targets unknown case: ${assertion.case}`);
      for (const artifact of ["results", "events", "trace"]) {
        if (!assertion[artifact]) continue;
        await loadAssertedArtifact(
          target,
          artifact,
          assertion[artifact],
          manifestDirectory,
          artifacts,
          loadExpectedArtifacts
        );
        if (artifact === "results") {
          applyResultComparisonPolicy(target, assertion.results.comparison, key);
        }
      }
    }
    stack.pop();
    visiting.delete(key);
    visited.add(key);
  }

  await visit(manifestPath);
  return {manifests, cases};
}

/** Compare actual conformance artifacts with the resolved expected suite. */
export async function checkSuite(manifestPath, actualRoot, registry = null) {
  const suite = await loadSuite(
    manifestPath,
    registry ?? await discoverManifestRegistry(repositoryRoot)
  );
  const artifacts = await loadArtifacts(repositoryRoot);
  let checked = 0;

  for (const entry of suite.cases) {
    if (entry.expected.results) {
      const actualPath = resolveContainedPath(actualRoot, `${entry.id}.results.json`);
      const actual = await readJson(actualPath, `actual results for ${entry.id}`);
      const diagnostics = validateResults(actual);
      if (diagnostics.length > 0) {
        throw new Error(`invalid actual results: ${entry.id}: ${formatDiagnostics(diagnostics)}`);
      }
      const comparison = compareResults(
        entry.expectedValues.results,
        actual,
        entry.comparisons.results
      );
      if (!comparison.equal) {
        return {valid: false, checked, caseId: entry.id, artifact: "results", comparison};
      }
    }

    if (entry.expected.events) {
      const actualPath = resolveContainedPath(actualRoot, `${entry.id}.events.ndjson`);
      const actual = await readActualEvents(actualPath, artifacts.validateEvents, entry.id);
      const comparison = comparePortableEvents(entry.expectedValues.events, actual);
      if (!comparison.equal) {
        return {valid: false, checked, caseId: entry.id, artifact: "events", comparison};
      }
    }

    if (entry.expected.trace) {
      const actualPath = resolveContainedPath(actualRoot, `${entry.id}.trace.ndjson`);
      const actual = await readActualTrace(actualPath, artifacts.validateEvents, entry.id);
      const comparison = compareJson(entry.expectedValues.trace, actual);
      if (!comparison.equal) {
        return {valid: false, checked, caseId: entry.id, artifact: "trace", comparison};
      }
    }

    checked += 1;
  }

  return {valid: true, checked};
}
