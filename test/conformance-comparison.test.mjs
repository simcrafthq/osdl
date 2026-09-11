import assert from "node:assert/strict";
import test from "node:test";

import {
  comparePortableEvents,
  compareResults,
  portableEvents,
  projectPortableEvents
} from "../scripts/lib/conformance.mjs";

function event(type, time, payload = {}, extra = {}) {
  return {
    v: "0.1",
    seq: 1,
    time,
    type,
    source: "kernel",
    payload,
    ...extra
  };
}

test("compares result objects without considering member order", () => {
  assert.equal(compareResults(
    {queue: {final: {value: 1}, summary: {stats: {count: 1}}}},
    {queue: {summary: {stats: {count: 1}}, final: {value: 1}}}
  ).equal, true);
});

test("reports the first result array mismatch as a JSON Pointer", () => {
  const comparison = compareResults(
    {queue: {timeseries: {times: [0, 1], values: [2, 3]}}},
    {queue: {timeseries: {times: [0, 1], values: [2, 4]}}}
  );

  assert.deepEqual(comparison, {
    equal: false,
    path: "/queue/timeseries/values/1",
    message: "values differ",
    expected: 3,
    actual: 4
  });
});

test("preserves ordinary array order", () => {
  const comparison = compareResults(
    {queue: {samples: [1, 2]}},
    {queue: {samples: [2, 1]}}
  );

  assert.equal(comparison.equal, false);
  assert.equal(comparison.path, "/queue/samples/0");
});

test("reports missing and extra object members", () => {
  const expected = {queue: {summary: {stats: {count: 1, mean: 1}}}};
  const actual = {queue: {summary: {stats: {count: 1, median: 1}}}};

  assert.equal(
    compareResults(expected, actual).path,
    "/queue/summary/stats/mean"
  );
  assert.equal(
    compareResults(actual, expected).path,
    "/queue/summary/stats/mean"
  );
});

test("preserves time-series point order", () => {
  assert.equal(compareResults(
    {queue: {timeseries: {times: [0, 1], values: [2, 3]}}},
    {queue: {timeseries: {times: [1, 0], values: [3, 2]}}}
  ).equal, false);
});

test("uses bit-exact numbers by default", () => {
  assert.equal(compareResults(
    {queue: {final: {value: -0}}},
    {queue: {final: {value: 0}}}
  ).equal, false);
});

test("can compare numbers without distinguishing signed zero", () => {
  assert.equal(compareResults(
    {queue: {final: {value: -0}}},
    {queue: {final: {value: 0}}},
    {floatMode: "number"}
  ).equal, true);
});

test("rejects a result time series with unequal time and value counts", () => {
  const comparison = compareResults(
    {queue: {timeseries: {times: [0, 1], values: [2]}}},
    {queue: {timeseries: {times: [0, 1], values: [2]}}}
  );

  assert.deepEqual(comparison, {
    equal: false,
    path: "/queue/timeseries/values",
    message: "time-series times and values have different lengths",
    expected: 2,
    actual: 1
  });
});

test("projects portable events without telemetry or envelope sequencing", () => {
  const projection = projectPortableEvents([
    event("sim.progress", 0, {progress: 0.5}, {wallTime: 100}),
    event("entity.created", 0, {entityId: "customer", at: "source"}, {
      seq: 2,
      wallTime: 101
    })
  ]);

  assert.deepEqual(projection, [{
    time: 0,
    global: [],
    segments: [{
      identities: {
        "entity:customer": [{
          v: "0.1",
          time: 0,
          type: "entity.created",
          source: "kernel",
          payload: {entityId: "customer", at: "source"}
        }]
      }
    }]
  }]);
});

test("projects flat portable events in reference emission order", () => {
  const events = [
    event("sim.started", 0, {model: "pipeline"}, {wallTime: 100}),
    event("sim.progress", 1, {progress: 0.5}, {seq: 2}),
    event("entity.created", 1, {entityId: "one", at: "src"}, {seq: 3}),
    event("state.changed", 1, {path: "q.length", value: 1}, {seq: 4}),
    event("entity.created", 1, {entityId: "two", at: "src"}, {
      seq: 5,
      wallTime: 101
    }),
    event("metric.updated", 1, {name: "q.length", value: 1}, {seq: 6})
  ];

  assert.deepEqual(portableEvents(events), [
    {
      v: "0.1",
      time: 0,
      type: "sim.started",
      source: "kernel",
      payload: {model: "pipeline"}
    },
    {
      v: "0.1",
      time: 1,
      type: "entity.created",
      source: "kernel",
      payload: {entityId: "one", at: "src"}
    },
    {
      v: "0.1",
      time: 1,
      type: "entity.created",
      source: "kernel",
      payload: {entityId: "two", at: "src"}
    }
  ]);
  assert.equal(Object.hasOwn(events[0], "seq"), true);
  assert.equal(Object.hasOwn(events[0], "wallTime"), true);
});

test("excludes all telemetry types and ignores envelope sequencing", () => {
  const expected = [
    event("sim.progress", 0, {progress: 0.5}, {wallTime: 100}),
    event("state.changed", 0, {path: "queue.length", value: 1}, {seq: 2}),
    event("metric.updated", 0, {name: "queueLength", value: 1}, {seq: 3}),
    event("entity.created", 0, {entityId: "customer", at: "source"}, {
      seq: 4,
      wallTime: 101
    })
  ];
  const actual = [event("entity.created", 0, {entityId: "customer", at: "source"}, {
    seq: 99,
    wallTime: 999
  })];

  assert.equal(comparePortableEvents(expected, actual).equal, true);
});

test("retains order for events with one causal identity", () => {
  const expected = [
    event("entity.created", 0, {entityId: "customer", at: "source"}),
    event("entity.moved", 0, {entityId: "customer", to: "queue"})
  ];
  const actual = [...expected].reverse();
  const comparison = comparePortableEvents(expected, actual);

  assert.equal(comparison.equal, false);
  assert.equal(comparison.path, "/0/segments/0/identities/entity:customer/0/payload/at");
});

test("permits same-time reordering across causal identities", () => {
  const expected = [
    event("entity.created", 0, {entityId: "first", at: "source"}),
    event("entity.created", 0, {entityId: "second", at: "source"})
  ];

  assert.equal(comparePortableEvents(expected, [...expected].reverse()).equal, true);
});

test("retains global order for events without a safe identity", () => {
  const expected = [
    event("param.changed", 0, {name: "rate", value: 1}),
    event("param.changed", 0, {name: "rate", value: 2})
  ];
  const actual = [...expected].reverse();
  const comparison = comparePortableEvents(expected, actual);

  assert.equal(comparison.equal, false);
  assert.equal(comparison.path, "/0/global/0/payload/value");
});

test("uses identity-free events as same-time ordering barriers", () => {
  const expected = [
    event("param.changed", 0, {name: "rate", value: 1}),
    event("entity.created", 0, {entityId: "customer", at: "source"})
  ];
  const actual = [...expected].reverse();
  const comparison = comparePortableEvents(expected, actual);

  assert.equal(comparison.equal, false);
  assert.equal(comparison.path, "/0/segments/0/identities/entity:customer");
});

test("preserves simulation-time group order", () => {
  const expected = [
    event("entity.created", 0, {entityId: "customer", at: "source"}),
    event("entity.moved", 1, {entityId: "customer", to: "queue"})
  ];

  const comparison = comparePortableEvents(expected, [...expected].reverse());

  assert.equal(comparison.equal, false);
  assert.equal(comparison.path, "/0/time");
});

test("prefers entity identity over agent and message identities", () => {
  const projection = projectPortableEvents([event("entity.created", 0, {
    entityId: "customer",
    agentId: "agent",
    messageId: "message",
    at: "source"
  })]);

  assert.deepEqual(Object.keys(projection[0].segments[0].identities), ["entity:customer"]);
});

test("does not mutate events during portable projection", () => {
  const events = [event("entity.created", 0, {entityId: "customer", at: "source"}, {
    wallTime: 100
  })];
  const original = structuredClone(events);

  projectPortableEvents(events);

  assert.deepEqual(events, original);
});
