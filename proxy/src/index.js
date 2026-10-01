const GOLEMIO = "https://api.golemio.cz/v2/vehiclepositions?limit=5000";
const TTL = 6; // seconds; one upstream fetch fans out to all clients within a window

// ISO-8601 truncated to whole seconds. `toISOString()` emits milliseconds, which
// a plain `ISO8601DateFormatter` (the app's parser) rejects — vehicles carrying
// this fallback stamp would then be dated with the client's own clock and never
// age out of its freshness filter.
export function isoSeconds(date) {
  return date.toISOString().replace(/\.\d+Z$/, "Z");
}

// Pure: Golemio GeoJSON -> compact wire object. Exported for unit tests.
// Metro (route_type 1) is intentionally kept.
export function transform(geojson, nowIso) {
  const vehicles = [];
  for (const f of geojson.features ?? []) {
    const p = f.properties ?? {};
    const g = (p.trip && p.trip.gtfs) || {};
    const lp = p.last_position || {};
    const c = f.geometry && f.geometry.coordinates;
    if (!c || c.length !== 2 || g.trip_id == null) continue;
    // Golemio sends these as strings since 2026-10-01; every shipped app build
    // decodes numbers, so normalize here rather than in the clients.
    const lat = Number(c[1]);
    const lng = Number(c[0]);
    if (!Number.isFinite(lat) || !Number.isFinite(lng)) continue;
    vehicles.push({
      id: g.trip_id,
      lat,
      lng,
      brng: typeof lp.bearing === "number" ? lp.bearing : null,
      line: g.route_short_name ?? "",
      rt: typeof g.route_type === "number" ? g.route_type : 3,
      ts: lp.origin_timestamp ?? nowIso,
      dest: g.trip_headsign ?? null,
    });
  }
  return { ts: nowIso, vehicles };
}

// The TTL is held in the isolate rather than in `caches.default`, which is a
// documented no-op on *.workers.dev — every poll used to miss and fan out to a
// fresh Golemio request, which the one embedded key cannot sustain. Each isolate
// now makes at most one upstream request per TTL window, and concurrent misses
// share the in-flight one. (On a custom domain the edge cache would front this,
// but that would be an extra layer, not a replacement.)
let cached = null; // { at: <ms>, body: <serialized payload> }
let inFlight = null; // { promise: Promise<body>, at: <ms> } — one fetch, many waiters

// Upper bound on one upstream fetch AND on any request's wait for it. Golemio
// normally answers in ~1 s. Env override for tests.
//
// Both halves matter (the 2026-10-01 outage). In Workers, I/O started by one
// request belongs to that request: when its client goes away the runtime cancels
// the fetch and its AbortSignal timer with it, so the shared promise can stay
// pending forever and nothing it owns will ever time it out. So every waiter
// enforces the deadline with its own timer, and a shared fetch older than the
// deadline is replaced rather than awaited.
const UPSTREAM_TIMEOUT_MS = 8000;

async function loadUpstream(env, timeoutMs) {
  const upstream = await fetch(GOLEMIO, {
    headers: { "X-Access-Token": env.GOLEMIO_TOKEN },
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!upstream.ok) throw new Error(`golemio responded ${upstream.status}`);
  const geo = await upstream.json();
  return JSON.stringify(transform(geo, isoSeconds(new Date())));
}

// Rejects after `ms` on a timer owned by the calling request.
function withDeadline(promise, ms) {
  let timer;
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error("upstream deadline")), ms);
  });
  return Promise.race([promise, deadline]).finally(() => clearTimeout(timer));
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname !== "/prague/vehicles") {
      return new Response("Not found", { status: 404 });
    }

    if (cached && Date.now() - cached.at < TTL * 1000) return body(cached.body);

    const timeoutMs = Number(env.UPSTREAM_TIMEOUT_MS) || UPSTREAM_TIMEOUT_MS;

    // Only a success updates `cached`, so a failed fetch is retried next request
    // rather than being served as an empty payload for the rest of the window.
    if (!inFlight || Date.now() - inFlight.at > timeoutMs) {
      const entry = { at: Date.now() };
      entry.promise = loadUpstream(env, timeoutMs)
        .then((fresh) => {
          cached = { at: Date.now(), body: fresh };
          return fresh;
        })
        .finally(() => {
          if (inFlight === entry) inFlight = null;   // a replacement may own the slot now
        });
      inFlight = entry;
      // Lets the fetch finish for the other waiters if this client leaves first.
      ctx?.waitUntil?.(entry.promise.catch(() => {}));
    }

    try {
      return body(await withDeadline(inFlight.promise, timeoutMs));
    } catch {
      return json({ ts: isoSeconds(new Date()), vehicles: [] }, 502);
    }
  },
};

function body(serialized) {
  return new Response(serialized, {
    status: 200,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
      "Cache-Control": `public, max-age=${TTL}`,
    },
  });
}

function json(obj, status = 200, extra = {}) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
      ...extra,
    },
  });
}
