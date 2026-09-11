#!/usr/bin/env node
import {validateFiles} from "./lib/validate-osdl.mjs";

const paths = process.argv.slice(2);
if (paths.length === 0) {
  console.error("usage: node scripts/validate-osdl.mjs <document>...");
  process.exitCode = 2;
} else {
  try {
    const result = await validateFiles(paths);
    result.diagnostics.forEach(value => console.error(JSON.stringify(value)));
    process.exitCode = result.valid ? 0 : 1;
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 2;
  }
}
