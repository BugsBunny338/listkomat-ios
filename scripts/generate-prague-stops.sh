#!/usr/bin/env bash
#
# Regenerate the bundled Prague stops file from the PID GTFS static feed
# (CC-BY 4.0, Operátor ICT / Golemio). Run occasionally to refresh; commit result.
#
#   scripts/generate-prague-stops.sh
#
# Downloads PID_GTFS.zip (~42 MB), extracts stops.txt, dedupes platform rows into
# ~physical stations (same-name platforms clustered within 300 m, coords averaged),
# trims to {id,name,lat,lng}, and writes Listkomat/Resources/prague-stops.json.
# Unlike Brno, no stop-names map is produced — Prague destinations come from the
# live feed's trip_headsign, not a numeric stop id.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="Listkomat/Resources/prague-stops.json"
URL="https://data.pid.cz/PID_GTFS.zip"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "downloading $URL ..."
curl -s --max-time 180 "$URL" -o "$TMP/gtfs.zip"
echo "extracting stops.txt ..."
unzip -o -q "$TMP/gtfs.zip" stops.txt -d "$TMP"

python3 - "$TMP/stops.txt" "$OUT" <<'PY'
import csv, json, sys, math

src, out = sys.argv[1], sys.argv[2]

by_name = {}
with open(src, newline='', encoding='utf-8-sig') as f:
    for row in csv.DictReader(f):
        try:
            lat = float(row['stop_lat']); lng = float(row['stop_lon'])
        except (KeyError, ValueError, TypeError):
            continue
        name = (row.get('stop_name') or '').strip() or (row.get('stop_id') or '')
        # PID ships a few unnamed nodes as the literal placeholder "(-)". They are
        # real coordinates with no station behind them, so they render as pins the
        # user cannot identify. Anything with no letter or digit is the same thing.
        if not name or not any(ch.isalnum() for ch in name):
            continue
        by_name.setdefault(name, []).append((lat, lng))

def dist_m(a, b):
    R = 6371000.0
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp = math.radians(b[0]-a[0]); dl = math.radians(b[1]-a[1])
    h = math.sin(dp/2)**2 + math.cos(p1)*math.cos(p2)*math.sin(dl/2)**2
    return 2*R*math.asin(math.sqrt(h))

# One pin per station: cluster same-name platforms within 300 m (merges the two
# poles / metro entrances) while keeping distant same-name stops separate.
stops = []
for name, pts in by_name.items():
    clusters = []
    for pt in pts:
        for cl in clusters:
            if dist_m(pt, cl[0]) <= 300:
                cl.append(pt); break
        else:
            clusters.append([pt])
    for cl in clusters:
        lat = round(sum(p[0] for p in cl)/len(cl), 6)
        lng = round(sum(p[1] for p in cl)/len(cl), 6)
        stops.append({'id': f"{name}@{lat},{lng}", 'name': name, 'lat': lat, 'lng': lng})

stops.sort(key=lambda s: s['name'])
json.dump(stops, open(out, 'w'), ensure_ascii=False, separators=(',', ':'))
print('stations:', len(stops), '->', out)
PY
echo "size: $(wc -c < "$OUT") bytes"
