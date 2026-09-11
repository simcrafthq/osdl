import Ajv2020 from "ajv/dist/2020.js";
import {readdir, readFile} from "node:fs/promises";
import {createRequire} from "node:module";
import path from "node:path";

const require = createRequire(import.meta.url);
const bundledResultsSchema = require("../../schemas/osdl.results.schema.json");
const bundledManifestSchema = require("../../schemas/osdl.conformance.schema.json");
const bundledMachineFixtureSchema = require("../../schemas/osdl.machine-fixture.schema.json");

async function readJson(filePath) {
  return JSON.parse(await readFile(filePath, "utf8"));
}

function diagnostic({
  phase,
  code,
  path: instancePath,
  message,
  document,
  componentId = null,
  componentType = null,
  library = null
}) {
  return {
    phase,
    code,
    path: instancePath || "/",
    message,
    document,
    componentId,
    componentType,
    library
  };
}

function validationDiagnostics(errors, context) {
  return (errors ?? []).map(error => diagnostic({
    ...context,
    code: error.keyword,
    path: `${context.path}${error.instancePath}`,
    message: error.message ?? "schema validation failed"
  }));
}

function componentPath(index) {
  return `/model/components/${index}`;
}

function createContractValidators(resultsSchema, manifestSchema, machineFixtureSchema) {
  const ajv = new Ajv2020({allErrors: true, strict: false});
  ajv.addSchema(resultsSchema);
  ajv.addSchema(manifestSchema);
  ajv.addSchema(machineFixtureSchema);

  return {
    validateResults: ajv.getSchema(resultsSchema.$id),
    validateManifest: ajv.getSchema(manifestSchema.$id),
    validateMachineFixture: ajv.getSchema(machineFixtureSchema.$id)
  };
}

function contractDiagnostics(value, validator, phase) {
  if (validator(value)) {
    return [];
  }

  return validationDiagnostics(validator.errors, {
    phase,
    path: "",
    document: "<memory>"
  });
}

function validateResultsWith(value, validator) {
  const diagnostics = contractDiagnostics(value, validator, "results-schema");
  if (diagnostics.length > 0) {
    return diagnostics;
  }

  for (const [alias, output] of Object.entries(value)) {
    const timeseries = output.timeseries;
    if (timeseries && timeseries.times.length !== timeseries.values.length) {
      diagnostics.push(diagnostic({
        phase: "results-schema",
        code: "timeseries-length",
        path: `/${alias}/timeseries/values`,
        message: "times and values must have equal lengths",
        document: "<memory>"
      }));
    }
  }

  return diagnostics;
}

function validateManifestWith(value, validator) {
  const diagnostics = contractDiagnostics(value, validator, "manifest-schema");
  if (diagnostics.length > 0) {
    return diagnostics;
  }

  const caseIndexes = new Map();
  for (const [index, entry] of value.cases.entries()) {
    if (caseIndexes.has(entry.id)) {
      diagnostics.push(diagnostic({
        phase: "manifest-schema",
        code: "duplicate-case-id",
        path: `/cases/${index}/id`,
        message: `duplicate case id: ${entry.id}`,
        document: "<memory>"
      }));
      continue;
    }
    caseIndexes.set(entry.id, index);
  }

  return diagnostics;
}

function validateMachineFixtureWith(value, validator) {
  return contractDiagnostics(value, validator, "machine-fixture");
}

const bundledContractValidators = createContractValidators(
  bundledResultsSchema,
  bundledManifestSchema,
  bundledMachineFixtureSchema
);

export function validateResults(value) {
  return validateResultsWith(value, bundledContractValidators.validateResults);
}

export function validateManifest(value) {
  return validateManifestWith(value, bundledContractValidators.validateManifest);
}

export function validateMachineFixture(value) {
  return validateMachineFixtureWith(value, bundledContractValidators.validateMachineFixture);
}

export async function loadArtifacts(rootDir) {
  const ajv = new Ajv2020({allErrors: true, strict: false});
  const schemasDir = path.join(rootDir, "schemas");
  const [
    coreSchema,
    librarySchema,
    eventSchema,
    resultsSchema,
    manifestSchema,
    machineFixtureSchema
  ] = await Promise.all([
    "osdl.schema.json",
    "osdl.library.schema.json",
    "osdl.events.schema.json",
    "osdl.results.schema.json",
    "osdl.conformance.schema.json",
    "osdl.machine-fixture.schema.json"
  ].map(fileName => readJson(path.join(schemasDir, fileName))));

  const validateCore = ajv.compile(coreSchema);
  const validateLibrary = ajv.compile(librarySchema);
  const validateEvents = ajv.compile(eventSchema);
  const validateResultsSchema = ajv.compile(resultsSchema);
  const validateManifestSchema = ajv.compile(manifestSchema);
  const validateMachineFixtureSchema = ajv.compile(machineFixtureSchema);
  const libraries = new Map();
  const libraryDir = path.join(rootDir, "libraries");
  const libraryFiles = (await readdir(libraryDir))
    .filter(fileName => fileName.endsWith(".library.json"))
    .sort();

  for (const fileName of libraryFiles) {
    const definition = await readJson(path.join(libraryDir, fileName));
    if (!validateLibrary(definition)) {
      const errors = validateLibrary.errors
        .map(error => `${error.instancePath || "/"} ${error.message}`)
        .join("; ");
      throw new Error(`invalid library document: ${fileName}: ${errors}`);
    }

    const library = definition.library;
    const namespace = library.namespace;

    if (libraries.has(namespace)) {
      throw new Error(`duplicate library namespace: ${namespace}`);
    }

    const componentTypes = new Map();
    for (const component of library.components) {
      if (componentTypes.has(component.name)) {
        throw new Error(`duplicate component type: ${namespace}.${component.name}`);
      }

      componentTypes.set(component.name, ajv.compile(component.params ?? {}));
    }

    libraries.set(namespace, componentTypes);
  }

  return {
    validateCore,
    validateLibrary,
    validateEvents,
    validateResults: value => validateResultsWith(value, validateResultsSchema),
    validateManifest: value => validateManifestWith(value, validateManifestSchema),
    validateMachineFixture: value => validateMachineFixtureWith(value, validateMachineFixtureSchema),
    libraries
  };
}

export function validateDocument(document, artifacts, documentPath = "<memory>") {
  if (!artifacts.validateCore(document)) {
    return validationDiagnostics(artifacts.validateCore.errors, {
      phase: "document-schema",
      path: "",
      document: documentPath
    });
  }

  const diagnostics = [];
  for (const [index, component] of document.model.components.entries()) {
    const [namespace, typeName] = component.type.split(".", 2);
    const basePath = componentPath(index);
    const context = {
      document: documentPath,
      componentId: component.id,
      componentType: component.type,
      library: namespace
    };
    const library = artifacts.libraries.get(namespace);

    if (!library) {
      diagnostics.push(diagnostic({
        ...context,
        phase: "component-library",
        code: "unknown-library",
        path: basePath,
        message: `unknown component library: ${namespace}`
      }));
      continue;
    }

    const validateParams = library.get(typeName);
    if (!validateParams) {
      diagnostics.push(diagnostic({
        ...context,
        phase: "component-library",
        code: "unknown-component",
        path: basePath,
        message: `unknown component type: ${component.type}`
      }));
      continue;
    }

    if (!validateParams(component.params ?? {})) {
      diagnostics.push(...validationDiagnostics(validateParams.errors, {
        ...context,
        phase: "component-params",
        path: `${basePath}/params`
      }));
    }
  }

  return diagnostics;
}

export async function validateFiles(paths, {rootDir = process.cwd()} = {}) {
  const artifacts = await loadArtifacts(rootDir);
  const diagnostics = [];

  for (const documentPath of paths) {
    const document = await readJson(documentPath);
    diagnostics.push(...validateDocument(document, artifacts, documentPath));
  }

  return {valid: diagnostics.length === 0, diagnostics};
}
