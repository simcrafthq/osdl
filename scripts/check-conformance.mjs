#!/usr/bin/env node
import {checkSuite} from "./lib/conformance-suite.mjs";

const [manifestPath, actualRoot, ...extra] = process.argv.slice(2);

if (!manifestPath || !actualRoot || extra.length > 0) {
  console.error("usage: node scripts/check-conformance.mjs <manifest> <actual-directory>");
  process.exitCode = 2;
} else {
  try {
    const report = await checkSuite(manifestPath, actualRoot);
    if (!report.valid) console.error(JSON.stringify(report));
    process.exitCode = report.valid ? 0 : 1;
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 2;
  }
}
