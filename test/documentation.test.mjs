import assert from "node:assert/strict";
import {existsSync} from "node:fs";
import {readFile} from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import {fileURLToPath} from "node:url";

const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const publicDocuments = [
  "SPEC.md",
  "STATUS.md",
  "ROADMAP.md",
  "libraries/des/SPEC.md",
  "libraries/abm/SPEC.md",
  "libraries/sd/SPEC.md",
  "contracts/reference-machine/CONTRACT.md",
  "conformance/core/README.md",
  "machine/README.md"
];

async function readDocument(relativePath) {
  return readFile(path.join(rootDir, relativePath), "utf8");
}

function collapseWhitespace(text) {
  return text.replace(/\s+/g, " ");
}

function headingAnchors(markdown) {
  return new Set(
    [...markdown.matchAll(/^#{1,6}\s+(.+)$/gm)].map(([, heading]) =>
      heading
        .toLowerCase()
        .replace(/[`*_~]/g, "")
        .replace(/[^\p{L}\p{N}\s-]/gu, "")
        .trim()
        .replace(/\s+/g, "-")
    )
  );
}

test("publishes every current specification module", () => {
  for (const relativePath of publicDocuments) {
    assert.ok(existsSync(path.join(rootDir, relativePath)), `${relativePath} is absent`);
  }
});

test("resolves local links in public documentation", async () => {
  for (const documentPath of publicDocuments) {
    if (!existsSync(path.join(rootDir, documentPath))) continue;

    const markdown = await readDocument(documentPath);
    for (const [, target] of markdown.matchAll(/\[[^\]]+\]\(([^)]+)\)/g)) {
      if (/^(?:https?:|mailto:|#)/.test(target)) continue;

      const [targetPath, fragment] = target.split("#", 2);
      const resolvedPath = path.resolve(rootDir, path.dirname(documentPath), targetPath);
      assert.ok(existsSync(resolvedPath), `${documentPath}: ${targetPath} does not exist`);

      if (fragment && path.extname(resolvedPath).toLowerCase() === ".md") {
        const targetMarkdown = await readFile(resolvedPath, "utf8");
        assert.ok(
          headingAnchors(targetMarkdown).has(fragment),
          `${documentPath}: #${fragment} does not exist in ${targetPath}`
        );
      }
    }
  }
});

test("lists every current typed event and no undefined event", async () => {
  const specification = await readDocument("SPEC.md");
  const eventSchema = JSON.parse(await readDocument("schemas/osdl.events.schema.json"));
  const section = specification.match(
    /^### 10\.1 Current typed events\s*$([\s\S]*?)(?=^### |^## )/m
  );
  assert.ok(section, "SPEC.md has no current typed event section");

  const documented = [...section[1].matchAll(/`([a-z][a-zA-Z0-9]*\.[a-z][a-zA-Z0-9]*)`/g)]
    .map(([, eventType]) => eventType)
    .sort();
  const typed = eventSchema.allOf
    .map(rule => rule.if?.properties?.type?.const)
    .filter(Boolean)
    .sort();

  assert.deepEqual([...new Set(documented)], typed);
});

test("keeps planned behavior out of the current specification", async () => {
  const specification = await readDocument("SPEC.md");
  assert.doesNotMatch(specification, /^##\s+\d+\.\s+.*roadmap.*$/im);
});

test("cites only paths that this repository contains", async () => {
  for (const documentPath of publicDocuments) {
    const markdown = await readDocument(documentPath);
    for (const [, cited] of markdown.matchAll(/`([^`]*\/[^`]*)`/g)) {
      if (!/^(?:crates|plugins|sdk|packages|docs)\//.test(cited)) continue;
      assert.fail(`${documentPath} cites ${cited}, which is outside this repository`);
    }
  }
});

test("documents portable conformance commands and drift validation", async () => {
  const readme = await readDocument("README.md");

  assert.match(readme, /npm run conformance -- <manifest> <actual-directory>/);
  assert.match(readme, /npm run conformance:update/);
  assert.match(
    readme,
    /`bash validate\.sh` generates conformance\s+artifacts in a temporary directory and compares them with the committed\s+artifacts\./
  );
  assert.match(readme, /component libraries and implementation contracts\s+outside an OSDL model\s+document/);
  assert.match(
    readme,
    /`<case-id>\.results\.json`, `<case-id>\.events\.ndjson`, and\s+`<case-id>\.trace\.ndjson`/
  );
  assert.match(readme, /Portable expected event files omit `seq` and `wallTime`\./);
});

test("reports the tested conformance module status", async () => {
  const status = await readDocument("STATUS.md");

  assert.match(status, /\| Core value, expression, experiment, and portable event behavior \|[^\n]+\| defined and tested \|/);
  assert.match(status, /\| DES component behavior \|[^\n]+\| defined and tested \|/);
  assert.match(status, /\| ABM component behavior \|[^\n]+\| defined \|/);
  assert.match(status, /\| SD component behavior \|[^\n]+\| defined \|/);
});

test("separates current status from planned work", async () => {
  const readme = await readDocument("README.md");
  const statusSection = readme.match(/^## Status\s*$([\s\S]*?)(?=^## )/m);

  assert.ok(statusSection, "README.md has no status section");
  assert.match(statusSection[1], /Current OSDL `0\.1` behavior is in\s+\[`SPEC\.md`\]\(SPEC\.md\)\./);
  assert.match(statusSection[1], /Planned `1\.0` and post-`1\.0` work is in\s+\[`ROADMAP\.md`\]\(ROADMAP\.md\)\./);
  assert.doesNotMatch(
    statusSection[1],
    /planned[\s\S]{0,160}(?:roadmap|work)[\s\S]{0,160}\[`SPEC\.md`\]\(SPEC\.md\)/i
  );
});

test("uses the catalogue and manifests for reference-machine case discovery", async () => {
  const machineReadme = await readDocument("machine/README.md");
  const normalized = collapseWhitespace(machineReadme);

  assert.match(machineReadme, /lake exe osdl-reference-machine --catalog/);
  assert.match(machineReadme, /\[OSDL Core manifest\]\(\.\.\/conformance\/core\/manifest\.json\)/);
  assert.match(machineReadme, /\[DES manifest\]\(\.\.\/libraries\/des\/conformance\/manifest\.json\)/);
  assert.match(machineReadme, /\[reference-machine manifest\]\(\.\.\/contracts\/reference-machine\/manifest\.json\)/);
  assert.match(normalized, /The reference-machine implementation contract is optional\./);
  assert.match(normalized, /Its contract artifacts test the implementation contract\./);
  assert.match(normalized, /`--results` emits the results JSON instead of the trace\./);
  assert.doesNotMatch(normalized, /The portable conformance cases cover these behavior groups:/);
  assert.doesNotMatch(normalized, /Every operation is exercised by a portable conformance case\./);
  assert.match(
    normalized,
    /All 22 operations are exercised by conformance catalogue cases\./
  );
  assert.match(normalized, /`ComponentOperation` defines 22 operations/);
  assert.match(
    normalized,
    /The catalogue-only cases are `desroute`, `desexp`, `despri`, `descond`, `desweight`, and `desmodes`\./
  );
  assert.match(
    normalized,
    /The kernel cases `timercancel`, `cancelxfer`, `quiesce`, and `msgvalue` are also catalogue-only in this draft\./
  );
});

test("documents the reference-machine validation boundaries and checks", async () => {
  const machineReadme = await readDocument("machine/README.md");
  const contract = await readDocument("contracts/reference-machine/CONTRACT.md");
  const runtimeModuleMap = machineReadme.match(
    /^### Runtime module map\s*$([\s\S]*?)(?=^### Check map\s*$)/m
  );
  const checkMap = machineReadme.match(
    /^### Check map\s*$([\s\S]*?)(?=^### Semantic operations\s*$)/m
  );
  const checkCommandBlock = machineReadme.match(
    /Run the reference-machine checks from `machine\/`:\n\n```sh\n([\s\S]*?)\n```/
  );

  assert.ok(runtimeModuleMap, "machine/README.md has no runtime module map");
  assert.ok(checkMap, "machine/README.md has no check map");
  assert.ok(checkCommandBlock, "machine/README.md has no reference-machine check block");

  for (const source of [
    "Machine/PreparedRun.lean",
    "Machine/Transfer.lean",
    "Machine/GoldenVectors.lean"
  ]) {
    assert.match(runtimeModuleMap[1], new RegExp(source.replaceAll(".", "\\.")));
  }
  for (const source of [
    "PreparationChecks.lean",
    "TransferChecks.lean",
    "VectorRoundTripChecks.lean"
  ]) {
    assert.match(checkMap[1], new RegExp(source.replaceAll(".", "\\.")));
  }
  assert.deepEqual(checkCommandBlock[1].split("\n"), [
    "lake build",
    "lake exe preparationcheck",
    "lake exe transfercheck",
    "lake exe vectorroundtripcheck",
    "lake exe cataloguecheck",
    "lake exe vectors",
    "lake exe roundcheck",
    "lake exe safeguardcheck"
  ]);

  assert.match(contract, /Preparation validates and normalizes raw configuration before `MachineState` exists\./);
  assert.match(contract, /Preparation failures are outside raw event traces\./);
  assert.match(contract, /An entity delivery calls the target's `receive` first\./);
  assert.match(contract, /Golden-vector round-trip and verification checks are reference-machine compatibility checks\./);
});

test("keeps reference-machine rules out of the OSDL Core status row", async () => {
  const status = await readDocument("STATUS.md");
  const contractStatus = status.split("\n").find(line =>
    line.includes("Optional Lean reference-machine")
  );
  const coreStatus = status.split("\n").find(line =>
    line.startsWith("| Core value, expression, experiment, and portable event behavior |")
  );
  assert.ok(contractStatus, "STATUS.md has no optional reference-machine row");
  assert.ok(coreStatus, "STATUS.md has no OSDL Core behavior row");
  for (const rule of [
    "`PreparedRun` validation",
    "escrowed transfer outcomes",
    "raw callback order",
    "golden-vector codec checks",
    "raw traces",
    "implementation policy"
  ]) {
    assert.match(contractStatus, new RegExp(rule, "i"));
    assert.doesNotMatch(coreStatus, new RegExp(rule, "i"));
  }
  assert.match(contractStatus, /implementation contract, defined and tested/i);
});

test("defines recorder eligibility and typed recorder values", async () => {
  const specification = await readFile(path.join(rootDir, "SPEC.md"), "utf8");

  assert.match(specification, /A `summary` recorder requires a numeric or integer observable\./);
  assert.match(specification, /A `timeseries` recorder requires a number or integer observable\./);
  assert.match(specification, /A `final` recorder accepts number, integer, boolean, and string observables\./);
  assert.match(specification, /A `final` result may use `null` when no final value is available\./);
  assert.match(specification, /`metric\.updated` uses the same value types as recorded results\./);
});

test("defines observable integration boundaries without requiring micro-step scheduling", async () => {
  const [specification, schema] = await Promise.all([
    readFile(path.join(rootDir, "SPEC.md"), "utf8"),
    readFile(path.join(rootDir, "schemas", "osdl.schema.json"), "utf8")
  ]);

  assert.doesNotMatch(specification, /schedules integration micro-steps/);
  assert.doesNotMatch(schema, /scheduled micro-steps/);
  assert.match(specification, /`time\.integration\.dt` defines observable integration boundaries/);
  assert.match(specification, /Discrete events at an integration boundary observe stock values from before the boundary update\./);
  assert.match(specification, /An implementation may use any internal integration design/);
});
