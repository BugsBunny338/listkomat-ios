import { test } from "node:test";
import assert from "node:assert/strict";

// Each test gets a fresh module instance — the TTL cache lives in module scope,
// and a shared one would leak between tests. The query string busts Node's cache.
let n = 0;
const freshWorker = async () => (await import(`../src/index.js?t=${n++}`)).default;

const ENV = { GOLEMIO_TOKEN: "test-token" };
const GEO = {
  features: [
    {
      geometry: { coordinates: [14.4, 50.1] },
      properties: {
        trip: { gtfs: { trip_id: "x", route_short_name: "9", route_type: 0 } },
        last_position: { bearing: 12, origin_timestamp: "2026-07-13T22:10:15+02:00" },
      },
    },
  ],
};

// Swaps global fetch for a counting stub; returns the counter and a restore fn.
function stubUpstream(reply = () => Response.json(GEO)) {
  const real = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url, init });
    return reply(calls.length);
  };
  return { calls, restore: () => { globalThis.fetch = real; } };
}

const get = (worker, path = "/prague/vehicles") =>
  worker.fetch(new Request(`https://proxy.test${path}`), ENV, { waitUntil() {} });

test("unknown paths 404", async () => {
  const worker = await freshWorker();
  const res = await get(worker, "/nope");
  assert.equal(res.status, 404);
});

test("serves vehicles and sends the token upstream", async () => {
  const worker = await freshWorker();
  const up = stubUpstream();
  try {
    const res = await get(worker);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.vehicles.length, 1);
    assert.equal(up.calls[0].init.headers["X-Access-Token"], "test-token");
  } finally {
    up.restore();
  }
});

// The reason this file exists: `caches.default` is a no-op on *.workers.dev, so
// without an in-isolate TTL every client poll became a fresh Golemio request.
test("repeat requests inside the TTL make exactly one upstream request", async () => {
  const worker = await freshWorker();
  const up = stubUpstream();
  try {
    const bodies = [];
    for (let i = 0; i < 5; i++) bodies.push(await (await get(worker)).json());
    assert.equal(up.calls.length, 1, "should reuse the cached body");
    for (const b of bodies) assert.equal(b.vehicles.length, 1);
  } finally {
    up.restore();
  }
});

test("concurrent misses coalesce onto one upstream request", async () => {
  const worker = await freshWorker();
  let release;
  const gate = new Promise((r) => { release = r; });
  const up = stubUpstream(async () => { await gate; return Response.json(GEO); });
  try {
    const all = Promise.all([get(worker), get(worker), get(worker)]);
    release();
    const results = await all;
    assert.equal(up.calls.length, 1, "in-flight request should be shared");
    for (const res of results) assert.equal(res.status, 200);
  } finally {
    up.restore();
  }
});

test("upstream failure answers 502 and is not cached as success", async () => {
  const worker = await freshWorker();
  const up = stubUpstream((call) =>
    call === 1 ? new Response("nope", { status: 500 }) : Response.json(GEO),
  );
  try {
    const bad = await get(worker);
    assert.equal(bad.status, 502);
    assert.deepEqual((await bad.json()).vehicles, []);

    const good = await get(worker);
    assert.equal(good.status, 200, "a failure must not poison the cache");
    assert.equal((await good.json()).vehicles.length, 1);
  } finally {
    up.restore();
  }
});

test("a thrown upstream error answers 502", async () => {
  const worker = await freshWorker();
  const up = stubUpstream(() => { throw new Error("network down"); });
  try {
    const res = await get(worker);
    assert.equal(res.status, 502);
  } finally {
    up.restore();
  }
});
