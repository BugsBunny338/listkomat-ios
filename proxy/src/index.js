const GOLEMIO = "https://api.golemio.cz/v2/vehiclepositions?limit=5000";
const TTL = 6; // seconds; one upstream fetch fans out to all clients within a window

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
    vehicles.push({
      id: g.trip_id,
      lat: c[1],
      lng: c[0],
      brng: typeof lp.bearing === "number" ? lp.bearing : null,
      line: g.route_short_name ?? "",
      rt: typeof g.route_type === "number" ? g.route_type : 3,
      ts: lp.origin_timestamp ?? nowIso,
      dest: g.trip_headsign ?? null,
    });
  }
  return { ts: nowIso, vehicles };
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname !== "/prague/vehicles") {
      return new Response("Not found", { status: 404 });
    }

    const cache = caches.default;
    const cacheKey = new Request(url.toString(), { method: "GET" });
    const hit = await cache.match(cacheKey);
    if (hit) return hit;

    let upstream;
    try {
      upstream = await fetch(GOLEMIO, {
        headers: { "X-Access-Token": env.GOLEMIO_TOKEN },
      });
    } catch {
      return json({ ts: new Date().toISOString(), vehicles: [] }, 502);
    }
    if (!upstream.ok) {
      return json({ ts: new Date().toISOString(), vehicles: [] }, 502);
    }

    const geo = await upstream.json();
    const body = transform(geo, new Date().toISOString());
    const res = json(body, 200, { "Cache-Control": `public, max-age=${TTL}` });
    ctx.waitUntil(cache.put(cacheKey, res.clone()));
    return res;
  },
};

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
