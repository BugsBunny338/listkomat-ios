# listkomat-proxy

A tiny Cloudflare Worker that powers the Prague live map. It holds the Golemio API
key, fetches Prague vehicle positions once per ~6 s, trims Golemio's GeoJSON to a
compact JSON (~717 KB → ~87 KB measured), and fans that one cached fetch out to all
app users — so a single embedded key never blows Golemio's **20 req / 8 s** limit.

One endpoint:

```
GET /prague/vehicles  ->  { "ts": "...", "vehicles": [ {id,lat,lng,brng,line,rt,ts,dest}, ... ] }
```

`rt` is the GTFS `route_type` (0 tram, 1 metro, 2 rail, 3 bus, 11 trolleybus); the
app maps it to a `VehicleKind`.

## Develop / test locally

```bash
cd proxy
node --test                       # pure transform() unit tests, no network

# live smoke test against Golemio:
printf 'GOLEMIO_TOKEN=%s\n' "<your-golemio-token>" > .dev.vars   # gitignored
npx wrangler dev --port 8788
curl -s localhost:8788/prague/vehicles | head -c 300
```

## Deploy (needs a Cloudflare account; free tier is fine)

```bash
cd proxy
npm i -g wrangler                 # or use npx wrangler
wrangler login                    # opens a browser; authorize
wrangler secret put GOLEMIO_TOKEN # paste the Golemio token — NEVER commit it
wrangler deploy                   # prints https://listkomat-proxy.<subdomain>.workers.dev
```

Then set `PragueLiveSource.endpoint` in the app
(`Listkomat/Services/PragueVehicleSource.swift`) to the printed URL +
`/prague/vehicles`, and ship.

## Notes

- **Token safety:** the Golemio token lives only in `wrangler secret` (deployed) or
  `.dev.vars` (local, gitignored). It is never in the repo or the app binary.
- **Rate limit:** `Cache-Control: max-age=6` = one Golemio fetch per ~6 s at the
  edge. Exceeding 20 req/8 s would need >20 simultaneous cache misses in an 8 s
  window — implausible at hobby scale. If it ever matters, add a Durable Object
  single-flight. Not needed now (YAGNI).
- Get a Golemio token at https://api.golemio.cz/api-keys (free).
