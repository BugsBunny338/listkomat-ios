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
    return reply(calls.length, init);
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

// Production wedge, 2026-10-01: one Golemio fetch that never settled left the
// shared in-flight promise pending forever, so every later request in that
// isolate hung on it (0 ms CPU, client-side cancel) until a redeploy.
test("a hung upstream times out to 502 and does not wedge later requests", { timeout: 5000 }, async () => {
  const worker = await freshWorker();
  const up = stubUpstream((call, init) =>
    call === 1
      ? new Promise((_, reject) =>   // never settles unless the caller aborts
          init?.signal?.addEventListener("abort", () => reject(init.signal.reason)))
      : Response.json(GEO),
  );
  const env = { ...ENV, UPSTREAM_TIMEOUT_MS: "50" };
  const getWith = () =>
    worker.fetch(new Request("https://proxy.test/prague/vehicles"), env, { waitUntil() {} });
  // Node's AbortSignal.timeout timer is unref'd, so with only a hung promise
  // pending the event loop would exit first; in Workers the open request keeps
  // the isolate alive. Stand in for that — finitely, so a regression fails
  // instead of hanging the run.
  const keepAlive = setTimeout(() => {}, 2000);
  try {
    const hung = await getWith();
    assert.equal(hung.status, 502);

    const next = await getWith();
    assert.equal(next.status, 200, "the timed-out fetch must release the in-flight slot");
    assert.equal(up.calls.length, 2);
  } finally {
    clearTimeout(keepAlive);
    up.restore();
  }
});

// The wedge that survived the abort timeout (2026-10-01, version 68c23509): in
// Workers, I/O started by one request belongs to it. When that client goes away
// the runtime cancels the fetch AND its AbortSignal timer, so the shared promise
// never settles and nothing it owns can time it out. Model that as a fetch that
// ignores its signal: every later waiter must still answer within its own
// deadline, and a stale shared fetch must be replaced, not awaited forever.
test("a shared fetch orphaned by its request never wedges later ones", { timeout: 5000 }, async () => {
  const worker = await freshWorker();
  const up = stubUpstream((call) =>
    call === 1 ? new Promise(() => {}) : Response.json(GEO),   // call 1: never settles
  );
  const env = { ...ENV, UPSTREAM_TIMEOUT_MS: "50" };
  const getWith = () =>
    worker.fetch(new Request("https://proxy.test/prague/vehicles"), env, { waitUntil() {} });
  try {
    const first = await getWith();
    assert.equal(first.status, 502, "the waiter's own deadline must fire");

    const second = await getWith();
    assert.equal(second.status, 200, "a stale shared fetch must be replaced");
    assert.equal(up.calls.length, 2);
  } finally {
    up.restore();
  }
});

// Pins the module's clock; returns a mover and a restore fn.
function fakeNow(start = 1_700_000_000_000) {
  const real = Date.now;
  let now = start;
  Date.now = () => now;
  return { advance: (ms) => { now += ms; }, restore: () => { Date.now = real; } };
}

const GEO2 = { features: [GEO.features[0], { ...GEO.features[0], properties: {
  ...GEO.features[0].properties, trip: { gtfs: { trip_id: "y", route_short_name: "22", route_type: 0 } } } }] };

// Peak-hour outage, 2026-10-19: parsing Golemio's payload exceeds the free
// plan's CPU budget, and Cloudflare killed the refreshing request with 1102.
// Serving the snapshot first keeps a killed refresh away from the client.
test("a stale snapshot is served at once and refreshed in the background", async () => {
  const worker = await freshWorker();
  const clock = fakeNow();
  let release;
  const gate = new Promise((r) => { release = r; });
  const up = stubUpstream(async (call) => {
    if (call === 1) return Response.json(GEO);
    await gate;                       // the refresh is slow; the client must not wait for it
    return Response.json(GEO2);
  });
  try {
    assert.equal((await (await get(worker)).json()).vehicles.length, 1);

    clock.advance(20_000);            // past the TTL, inside the stale window
    const stale = await get(worker);
    assert.equal(stale.status, 200);
    assert.equal((await stale.json()).vehicles.length, 1, "the old snapshot, immediately");
    assert.equal(up.calls.length, 2, "a background refresh was started");

    release();
    await new Promise((r) => setTimeout(r, 10));
    clock.advance(1);
    assert.equal((await (await get(worker)).json()).vehicles.length, 2, "the refresh landed");
    assert.equal(up.calls.length, 2, "and was not repeated");
  } finally {
    clock.restore();
    up.restore();
  }
});

test("a failing background refresh never reaches the client", async () => {
  const worker = await freshWorker();
  const clock = fakeNow();
  const up = stubUpstream((call) =>
    call === 1 ? Response.json(GEO) : new Response("killed", { status: 500 }),
  );
  try {
    await get(worker);
    clock.advance(20_000);
    const res = await get(worker);
    assert.equal(res.status, 200);
    assert.equal((await res.json()).vehicles.length, 1);
  } finally {
    clock.restore();
    up.restore();
  }
});

test("past the stale window the request waits for upstream again", async () => {
  const worker = await freshWorker();
  const clock = fakeNow();
  const up = stubUpstream((call) =>
    call === 1 ? Response.json(GEO) : new Response("down", { status: 500 }),
  );
  try {
    await get(worker);
    clock.advance(90_000);
    const res = await get(worker);
    assert.equal(res.status, 502, "a dead feed must surface, not frozen vehicles");
  } finally {
    clock.restore();
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
