#!/usr/bin/env bash
#
# Regenerate the bundled Brno stops file from the keyless KORDIS ArcGIS stops
# layer (CC-BY 4.0, data.Brno). Run occasionally to refresh; commit the result.
#
#   scripts/generate-brno-stops.sh
#
# Pages through the layer (1000/req), dedupes platform-level rows into ~physical
# stations (by parent_station, else name), averages each station's coordinate,
# trims to {id,name,lat,lng}, and writes Listkomat/Resources/brno-stops.json.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="Listkomat/Resources/brno-stops.json"
BASE="https://services6.arcgis.com/fUWVlHWZNxUvTUh8/arcgis/rest/services/stops/FeatureServer/0/query"
TMP="$(mktemp -d)"
offset=0; page=0
while :; do
  f="$TMP/page_$page.json"
  curl -s --max-time 40 "$BASE?where=1%3D1&outFields=stop_id,stop_name,parent_station&resultOffset=$offset&resultRecordCount=1000&f=geojson" -o "$f"
  cnt=$(python3 -c "import json;print(len(json.load(open('$f')).get('features',[])))")
  echo "page $page: $cnt features (offset $offset)"
  [ "$cnt" -eq 0 ] && break
  offset=$((offset + 1000)); page=$((page + 1))
  [ "$page" -gt 40 ] && { echo "safety stop"; break; }
done

python3 - "$TMP" "$OUT" <<'PY'
import json, sys, glob, os, math, re
tmp, out = sys.argv[1], sys.argv[2]

# Collect platforms grouped by name; also build numeric-stop-id -> name so the
# live feed's FinalStopID can be shown as a destination ("U1286Z10" -> id 1286).
by_name = {}
id_names = {}
id_re = re.compile(r'^U(\d+)[ZN]')
for fp in sorted(glob.glob(os.path.join(tmp, 'page_*.json'))):
    for ft in json.load(open(fp)).get('features', []):
        p = ft.get('properties', {}); g = ft.get('geometry') or {}
        c = g.get('coordinates')
        if not c or len(c) != 2:
            continue
        lng, lat = c[0], c[1]
        name = (p.get('stop_name') or '').strip() or str(p.get('stop_id'))
        by_name.setdefault(name, []).append((lat, lng))
        m = id_re.match(str(p.get('stop_id') or ''))
        if m and name:
            id_names.setdefault(int(m.group(1)), name)

def dist_m(a, b):
    R = 6371000.0
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp = math.radians(b[0]-a[0]); dl = math.radians(b[1]-a[1])
    h = math.sin(dp/2)**2 + math.cos(p1)*math.cos(p2)*math.sin(dl/2)**2
    return 2*R*math.asin(math.sqrt(h))

# One pin per station: cluster same-name platforms within 300 m (merges the two
# poles of a stop) while keeping distant same-name stops (regional feed) separate.
stops = []
for name, pts in by_name.items():
    clusters = []   # each: list of points
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

names_out = os.path.join(os.path.dirname(out), 'brno-stop-names.json')
json.dump({str(k): v for k, v in sorted(id_names.items())},
          open(names_out, 'w'), ensure_ascii=False, separators=(',', ':'))
print('stop names:', len(id_names), '->', names_out)
PY
echo "size: $(wc -c < "$OUT") bytes"
