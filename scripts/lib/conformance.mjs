/** Event types excluded from portable conformance comparison. */
export const TELEMETRY_TYPES = new Set([
  "sim.progress",
  "state.changed",
  "metric.updated"
]);

function pointer(path, segment) {
  const escaped = String(segment).replace(/~/g, "~0").replace(/\//g, "~1");
  return `${path}/${escaped}`;
}

function difference(path, message, expected, actual) {
  return {equal: false, path, message, expected, actual};
}

function isObject(value) {
  return value !== null && typeof value === "object";
}

function unequalTimeSeriesLength(value, path = "") {
  if (Array.isArray(value)) {
    for (let index = 0; index < value.length; index += 1) {
      const mismatch = unequalTimeSeriesLength(value[index], pointer(path, index));
      if (mismatch) return mismatch;
    }
    return null;
  }

  if (!isObject(value)) return null;

  if (Array.isArray(value.times) && Array.isArray(value.values) &&
      value.times.length !== value.values.length) {
    return difference(
      pointer(path, "values"),
      "time-series times and values have different lengths",
      value.times.length,
      value.values.length
    );
  }

  for (const key of Object.keys(value).sort()) {
    const mismatch = unequalTimeSeriesLength(value[key], pointer(path, key));
    if (mismatch) return mismatch;
  }
  return null;
}

function compareValue(expected, actual, path, floatMode) {
  if (typeof expected === "number" && typeof actual === "number") {
    const equal = floatMode === "number" ? expected === actual : Object.is(expected, actual);
    return equal ? {equal: true} : difference(path, "values differ", expected, actual);
  }

  if (Array.isArray(expected) || Array.isArray(actual)) {
    if (!Array.isArray(expected) || !Array.isArray(actual)) {
      return difference(path, "value types differ", expected, actual);
    }

    const sharedLength = Math.min(expected.length, actual.length);
    for (let index = 0; index < sharedLength; index += 1) {
      const comparison = compareValue(expected[index], actual[index], pointer(path, index), floatMode);
      if (!comparison.equal) return comparison;
    }
    if (expected.length !== actual.length) {
      return difference(pointer(path, sharedLength), "array lengths differ", expected.length, actual.length);
    }
    return {equal: true};
  }

  if (isObject(expected) || isObject(actual)) {
    if (!isObject(expected) || !isObject(actual)) {
      return difference(path, "value types differ", expected, actual);
    }

    const keys = new Set([...Object.keys(expected), ...Object.keys(actual)]);
    for (const key of [...keys].sort()) {
      const expectedHasKey = Object.hasOwn(expected, key);
      const actualHasKey = Object.hasOwn(actual, key);
      const keyPath = pointer(path, key);
      if (!expectedHasKey || !actualHasKey) {
        return difference(
          keyPath,
          "object members differ",
          expectedHasKey ? expected[key] : undefined,
          actualHasKey ? actual[key] : undefined
        );
      }

      const comparison = compareValue(expected[key], actual[key], keyPath, floatMode);
      if (!comparison.equal) return comparison;
    }
    return {equal: true};
  }

  return Object.is(expected, actual)
    ? {equal: true}
    : difference(path, "values differ", expected, actual);
}

/** Compare JSON values and return their first difference. */
export function compareJson(expected, actual, {floatMode = "bits"} = {}) {
  return compareValue(expected, actual, "", floatMode);
}

/** Compare recorded results and return their first difference. */
export function compareResults(expected, actual, {floatMode = "bits"} = {}) {
  const expectedTimeSeriesMismatch = unequalTimeSeriesLength(expected);
  if (expectedTimeSeriesMismatch) return expectedTimeSeriesMismatch;

  const actualTimeSeriesMismatch = unequalTimeSeriesLength(actual);
  if (actualTimeSeriesMismatch) return actualTimeSeriesMismatch;

  return compareJson(expected, actual, {floatMode});
}

function causalIdentity(event) {
  const payload = event.payload ?? {};
  if (typeof payload.entityId === "string") return `entity:${payload.entityId}`;
  if (typeof payload.agentId === "string") return `agent:${payload.agentId}`;
  if (typeof payload.messageId === "string") return `message:${payload.messageId}`;
  return null;
}

function portableEvent(event) {
  const {seq, wallTime, ...portable} = event;
  return portable;
}

/** Return portable event objects in reference emission order. */
export function portableEvents(events) {
  return events
    .filter(event => !TELEMETRY_TYPES.has(event.type))
    .map(portableEvent);
}

/** Project events into portable time and causal-identity sequences. */
export function projectPortableEvents(events) {
  const groupsByTime = new Map();

  for (const event of portableEvents(events)) {
    let group = groupsByTime.get(event.time);
    if (!group) {
      group = {time: event.time, global: [], segments: [{identities: {}}]};
      groupsByTime.set(event.time, group);
    }

    const identity = causalIdentity(event);
    if (identity === null) {
      group.global.push(event);
      group.segments.push({identities: {}});
    } else {
      const segment = group.segments.at(-1);
      segment.identities[identity] ??= [];
      segment.identities[identity].push(event);
    }
  }

  return [...groupsByTime.values()];
}

function compareIdentitySequences(expected, actual, path) {
  const identities = new Set([
    ...Object.keys(expected),
    ...Object.keys(actual)
  ]);
  for (const identity of [...identities].sort()) {
    const expectedEvents = expected[identity];
    const actualEvents = actual[identity];
    const identityPath = pointer(path, identity);
    if (expectedEvents === undefined || actualEvents === undefined) {
      return difference(
        identityPath,
        "causal identities differ",
        expectedEvents,
        actualEvents
      );
    }

    const comparison = compareValue(expectedEvents, actualEvents, identityPath, "bits");
    if (!comparison.equal) return comparison;
  }

  return {equal: true};
}

function compareEventGroups(expected, actual, path) {
  const timeComparison = compareValue(expected.time, actual.time, pointer(path, "time"), "bits");
  if (!timeComparison.equal) return timeComparison;

  const globalComparison = compareValue(
    expected.global,
    actual.global,
    pointer(path, "global"),
    "bits"
  );
  if (!globalComparison.equal) return globalComparison;

  const sharedLength = Math.min(expected.segments.length, actual.segments.length);
  for (let index = 0; index < sharedLength; index += 1) {
    const comparison = compareIdentitySequences(
      expected.segments[index].identities,
      actual.segments[index].identities,
      pointer(pointer(pointer(path, "segments"), index), "identities")
    );
    if (!comparison.equal) return comparison;
  }

  if (expected.segments.length !== actual.segments.length) {
    return difference(
      pointer(pointer(path, "segments"), sharedLength),
      "identified-event segment counts differ",
      expected.segments.length,
      actual.segments.length
    );
  }

  return {equal: true};
}

/** Compare portable event projections and return their first difference. */
export function comparePortableEvents(expected, actual) {
  const expectedProjection = projectPortableEvents(expected);
  const actualProjection = projectPortableEvents(actual);
  const sharedLength = Math.min(expectedProjection.length, actualProjection.length);

  for (let index = 0; index < sharedLength; index += 1) {
    const comparison = compareEventGroups(expectedProjection[index], actualProjection[index], pointer("", index));
    if (!comparison.equal) return comparison;
  }

  if (expectedProjection.length !== actualProjection.length) {
    return difference(
      pointer("", sharedLength),
      "simulation-time group counts differ",
      expectedProjection.length,
      actualProjection.length
    );
  }

  return {equal: true};
}
