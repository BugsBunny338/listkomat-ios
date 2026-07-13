import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { transform } from "../src/index.js";

const geo = JSON.parse(
  readFileSync(new URL("./golemio-sample.json", import.meta.url)),
);

test("transform maps every feature to the wire shape", () => {
  const out = transform(geo, "2026-07-13T22:10:20+02:00");
  assert.equal(out.vehicles.length, 5);
  assert.equal(out.ts, "2026-07-13T22:10:20+02:00");

  const metro = out.vehicles.find((v) => v.rt === 1);
  assert.equal(metro.line, "A");
  assert.equal(metro.dest, "Nemocnice Motol");
  assert.equal(metro.lat, 50.077774);
  assert.equal(metro.id, "991_11435_260202");

  // Every wire object has exactly the contract keys.
  for (const v of out.vehicles) {
    assert.deepEqual(
      Object.keys(v).sort(),
      ["brng", "dest", "id", "lat", "line", "lng", "rt", "ts"],
    );
  }
});

test("drops features missing coords or trip_id", () => {
  const out = transform(
    {
      features: [
        { geometry: null, properties: {} },
        { geometry: { coordinates: [14, 50] }, properties: { trip: { gtfs: {} } } },
      ],
    },
    "t",
  );
  assert.equal(out.vehicles.length, 0);
});

test("bearing coerces non-number to null", () => {
  const out = transform(
    {
      features: [
        {
          geometry: { coordinates: [14.4, 50.1] },
          properties: {
            trip: { gtfs: { trip_id: "x", route_short_name: "9", route_type: 0 } },
            last_position: { bearing: null, origin_timestamp: "t2" },
          },
        },
      ],
    },
    "t",
  );
  assert.equal(out.vehicles.length, 1);
  assert.equal(out.vehicles[0].brng, null);
});
