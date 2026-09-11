#!/usr/bin/env node
import {spawnSync} from "node:child_process";
import {accessSync, constants} from "node:fs";
import {lstat, mkdir, readFile, writeFile} from "node:fs/promises";
import path from "node:path";
import {fileURLToPath} from "node:url";

import {portableEvents} from "./lib/conformance.mjs";
import {
  discoverManifestRegistry,
  loadSuite
} from "./lib/conformance-suite.mjs";
import {
  loadArtifacts
} from "./lib/validate-osdl.mjs";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const machineDirectory = path.join(repositoryRoot, "machine");
const adapterPath = path.join(
  repositoryRoot,
  "contracts/reference-machine/conformance/adapter.json"
);
const usage = [
  "usage: node scripts/update-conformance.mjs --output <directory>",
  "       node scripts/update-conformance.mjs --list"
].join("\n");

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

function diagnostics(errors) {
  return (errors ?? []).map(error => (
    `${error.path ?? error.instancePath ?? "/"} ${error.message}`
  )).join("; ");
}

async function readJson(filePath, description) {
  let source;
  try {
    source = await readFile(filePath, "utf8");
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`cannot read ${description}: ${filePath}: ${message}`);
  }

  try {
    return JSON.parse(source);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`invalid ${description}: ${filePath}: ${message}`);
  }
}

function resolveContainedPath(directory, sourcePath, description) {
  const resolvedPath = path.resolve(directory, sourcePath);
  const relativePath = path.relative(directory, resolvedPath);
  if (relativePath === ".." || relativePath.startsWith(`..${path.sep}`) || path.isAbsolute(relativePath)) {
    throw new Error(`${description} escapes ${directory}: ${sourcePath}`);
  }
  return resolvedPath;
}

function runLake(executable, arguments_, description) {
  const result = spawnSync(executable, arguments_, {
    cwd: machineDirectory,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024
  });
  if (result.error) throw new Error(`${description}: ${result.error.message}`);
  if (result.status !== 0) {
    throw new Error(`${description}: ${result.stderr.trim() || `exit status ${result.status}`}`);
  }
  return result.stdout;
}

function parseTrace(source, validateEvent, publicId) {
  const events = [];
  for (const [index, line] of source.split(/\r?\n/).entries()) {
    if (line.trim() === "") continue;
    let event;
    try {
      event = JSON.parse(line);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      throw new Error(`invalid raw trace for ${publicId} at line ${index + 1}: ${message}`);
    }
    if (!validateEvent(event)) {
      throw new Error(
        `invalid raw trace for ${publicId} at line ${index + 1}: ${diagnostics(validateEvent.errors)}`
      );
    }
    events.push(event);
  }
  if (events.length === 0) throw new Error(`empty raw trace for ${publicId}`);
  return events;
}

function ndjson(values) {
  return `${values.map(value => JSON.stringify(value)).join("\n")}\n`;
}

function json(value) {
  return `${JSON.stringify(value)}\n`;
}

async function validateOutputDirectory(sourcePath) {
  const outputDirectory = path.resolve(process.cwd(), sourcePath);
  let outputStats;
  try {
    outputStats = await lstat(outputDirectory);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`cannot access output directory: ${outputDirectory}: ${message}`);
  }
  if (outputStats.isSymbolicLink() || !outputStats.isDirectory()) {
    throw new Error(`output path is not a real directory: ${outputDirectory}`);
  }
  return outputDirectory;
}

function outputPath(outputDirectory, repositoryPath) {
  const relativePath = path.relative(repositoryRoot, repositoryPath);
  if (relativePath === "" || relativePath === ".." ||
      relativePath.startsWith(`..${path.sep}`) || path.isAbsolute(relativePath)) {
    throw new Error(`artifact path escapes repository root: ${repositoryPath}`);
  }
  return resolveContainedPath(outputDirectory, relativePath, "artifact path");
}

async function lstatIfPresent(filePath) {
  try {
    return await lstat(filePath);
  } catch (error) {
    if (error && typeof error === "object" && error.code === "ENOENT") return null;
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`cannot inspect generated artifact path: ${filePath}: ${message}`);
  }
}

async function prepareArtifactPath(outputDirectory, filePath) {
  const relativePath = path.relative(outputDirectory, filePath);
  if (relativePath === "" || relativePath === ".." ||
      relativePath.startsWith(`..${path.sep}`) || path.isAbsolute(relativePath)) {
    throw new Error(`artifact path escapes output directory: ${filePath}`);
  }

  const segments = relativePath.split(path.sep);
  let currentPath = outputDirectory;
  for (const segment of segments.slice(0, -1)) {
    currentPath = path.join(currentPath, segment);
    let currentStats = await lstatIfPresent(currentPath);
    if (currentStats === null) {
      try {
        await mkdir(currentPath);
      } catch (error) {
        if (!error || typeof error !== "object" || error.code !== "EEXIST") {
          const message = error instanceof Error ? error.message : String(error);
          throw new Error(`cannot create generated artifact directory: ${currentPath}: ${message}`);
        }
      }
      currentStats = await lstatIfPresent(currentPath);
    }
    if (currentStats?.isSymbolicLink()) {
      throw new Error(`generated artifact ancestor is a symbolic link: ${currentPath}`);
    }
    if (!currentStats?.isDirectory()) {
      throw new Error(`generated artifact ancestor is not a directory: ${currentPath}`);
    }
  }

  const leafStats = await lstatIfPresent(filePath);
  if (leafStats?.isSymbolicLink()) {
    throw new Error(`generated artifact leaf is a symbolic link: ${filePath}`);
  }
  if (leafStats?.isDirectory()) {
    throw new Error(`generated artifact leaf is a directory: ${filePath}`);
  }
  if (leafStats !== null && !leafStats.isFile()) {
    throw new Error(`generated artifact leaf is not a regular file: ${filePath}`);
  }
}

async function loadSourceData() {
  const adapter = await readJson(adapterPath, "reference-machine adapter");
  if (adapter === null || Array.isArray(adapter) || typeof adapter !== "object" ||
      Object.keys(adapter).length !== 2 || typeof adapter.manifest !== "string" ||
      adapter.cases === null || Array.isArray(adapter.cases) || typeof adapter.cases !== "object") {
    throw new Error("reference-machine adapter must select one manifest and define its cases");
  }
  const manifestPath = resolveContainedPath(
    repositoryRoot,
    path.resolve(path.dirname(adapterPath), adapter.manifest),
    "adapter manifest path"
  );
  const registry = await discoverManifestRegistry(repositoryRoot);
  const suite = await loadSuite(manifestPath, registry, {loadExpectedArtifacts: false});
  const selectedManifest = suite.manifests.at(-1);
  if (selectedManifest?.path !== manifestPath || selectedManifest.manifest.kind !== "contract") {
    throw new Error("reference-machine adapter must select an implementation contract manifest");
  }

  const publicCases = new Map(suite.cases.map(entry => [entry.id, entry]));
  const adapterKeys = Object.keys(adapter.cases);
  if (adapterKeys.length !== publicCases.size ||
      adapterKeys.some(publicId => !publicCases.has(publicId))) {
    throw new Error("reference-machine adapter keys must match its selected manifest graph");
  }
  if (Object.values(adapter.cases).some(target => typeof target !== "string")) {
    throw new Error("reference-machine adapter targets must be strings");
  }

  return {adapter: adapter.cases, publicCases, suite};
}

function validateCatalogue(catalogue, adapter, publicCases) {
  if (!Array.isArray(catalogue)) throw new Error("reference-machine catalogue must be an array");
  const catalogueById = new Map();
  for (const entry of catalogue) {
    if (entry === null || Array.isArray(entry) || typeof entry !== "object" ||
        typeof entry.id !== "string") {
      throw new Error("reference-machine catalogue contains an invalid entry");
    }
    if (catalogueById.has(entry.id)) {
      throw new Error(`duplicate reference-machine catalogue case: ${entry.id}`);
    }
    catalogueById.set(entry.id, entry);
  }

  for (const [publicId, leanId] of Object.entries(adapter)) {
    const catalogueCase = catalogueById.get(leanId);
    if (!catalogueCase) throw new Error(`adapter target is absent from catalogue: ${leanId}`);
    const source = publicCases.get(publicId);
    if (catalogueCase.module !== source.moduleKey) {
      throw new Error(`catalogue module mismatch for ${publicId}: ${catalogueCase.module}`);
    }

    if (source.input.format === "machine") {
      if (catalogueCase.input?.kind !== "machine" ||
          catalogueCase.input.behavior !== source.inputValue.behavior ||
          source.inputValue.behavior !== leanId) {
        throw new Error(`catalogue machine input mismatch for ${publicId}`);
      }
    } else {
      const repositoryInputPath = path.relative(repositoryRoot, source.inputPath).split(path.sep).join("/");
      if (catalogueCase.input?.kind !== "osdl" || catalogueCase.input.path !== repositoryInputPath) {
        throw new Error(`catalogue OSDL input mismatch for ${publicId}`);
      }
    }
  }
}

function addArtifact(artifacts, filePath, content) {
  const previous = artifacts.get(filePath);
  if (previous !== undefined && previous !== content) {
    throw new Error(`conflicting generated artifact: ${filePath}`);
  }
  artifacts.set(filePath, content);
}

async function generate(outputDirectory) {
  const artifacts = await loadArtifacts(repositoryRoot);
  const {adapter, publicCases} = await loadSourceData();
  const lake = lakePath();
  if (!lake) throw new Error("lake not found; install Lean 4 via elan");

  let catalogue;
  try {
    catalogue = JSON.parse(runLake(
      lake,
      ["exe", "osdl-reference-machine", "--catalog"],
      "cannot read reference-machine catalogue"
    ));
  } catch (error) {
    if (error instanceof SyntaxError) {
      throw new Error(`invalid reference-machine catalogue: ${error.message}`);
    }
    throw error;
  }
  validateCatalogue(catalogue, adapter, publicCases);

  const generated = new Map();
  for (const [publicId, leanId] of Object.entries(adapter)) {
    const source = publicCases.get(publicId);
    const trace = parseTrace(
      runLake(
        lake,
        ["exe", "osdl-reference-machine", leanId],
        `cannot generate trace for ${publicId}`
      ),
      artifacts.validateEvents,
      publicId
    );

    if (source.expected.events) {
      addArtifact(
        generated,
        outputPath(outputDirectory, source.expectedPaths.events),
        ndjson(portableEvents(trace))
      );
    }

    if (source.expected.trace) {
      addArtifact(
        generated,
        outputPath(outputDirectory, source.expectedPaths.trace),
        ndjson(trace)
      );
    }

    if (source.expected.results) {
      const resultSource = runLake(
        lake,
        ["exe", "osdl-reference-machine", leanId, "--results"],
        `cannot generate results for ${publicId}`
      ).trim();
      let results;
      try {
        results = JSON.parse(resultSource);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        throw new Error(`invalid results for ${publicId}: ${message}`);
      }
      const resultDiagnostics = artifacts.validateResults(results);
      if (resultDiagnostics.length > 0) {
        throw new Error(`invalid results for ${publicId}: ${diagnostics(resultDiagnostics)}`);
      }
      addArtifact(
        generated,
        outputPath(outputDirectory, source.expectedPaths.results),
        json(results)
      );
    }
  }

  const generatedEntries = [...generated.entries()].sort(([left], [right]) => (
    left.localeCompare(right)
  ));
  for (const [filePath] of generatedEntries) {
    await prepareArtifactPath(outputDirectory, filePath);
  }
  for (const [filePath, content] of generatedEntries) {
    await prepareArtifactPath(outputDirectory, filePath);
    await writeFile(filePath, content, "utf8");
  }
}

async function listArtifacts() {
  const {suite} = await loadSourceData();
  const paths = new Set();
  for (const entry of suite.cases) {
    for (const artifactPath of Object.values(entry.expectedPaths)) {
      paths.add(path.relative(repositoryRoot, artifactPath).split(path.sep).join("/"));
    }
  }
  return [...paths].sort();
}

const [option, outputArgument, ...extraArguments] = process.argv.slice(2);
if (option === "--list" && outputArgument === undefined && extraArguments.length === 0) {
  try {
    process.stdout.write(`${(await listArtifacts()).join("\n")}\n`);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
} else if (option !== "--output" || !outputArgument || extraArguments.length > 0) {
  console.error(usage);
  process.exit(2);
} else {
  try {
    const outputDirectory = await validateOutputDirectory(outputArgument);
    await generate(outputDirectory);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
