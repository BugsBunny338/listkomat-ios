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
import json, sys, glob, os
tmp, out = sys.argv[1], sys.argv[2]
groups = {}
for fp in sorted(glob.glob(os.path.join(tmp, 'page_*.json'))):
    for ft in json.load(open(fp)).get('features', []):
        p = ft.get('properties', {}); g = ft.get('geometry') or {}
        c = g.get('coordinates')
        if not c or len(c) != 2:
            continue
        lng, lat = c[0], c[1]
        name = (p.get('stop_name') or '').strip() or str(p.get('stop_id'))
        # One pin per station: group same-name platforms within ~100 m. Avoids the
        # feed's inconsistent parent_station while keeping distant same-name stops
        # (regional feed) separate.
        key = (name, round(lat, 3), round(lng, 3))
        d = groups.setdefault(key, {'name': name, 'lats': [], 'lngs': []})
        d['lats'].append(lat); d['lngs'].append(lng)

stops = []
for d in groups.values():
    if not d['lats']:
        continue
    lat = round(sum(d['lats']) / len(d['lats']), 6)
    lng = round(sum(d['lngs']) / len(d['lngs']), 6)
    stops.append({'id': f"{d['name']}@{lat},{lng}", 'name': d['name'], 'lat': lat, 'lng': lng})
stops.sort(key=lambda s: s['name'])
json.dump(stops, open(out, 'w'), ensure_ascii=False, separators=(',', ':'))
print('stations:', len(stops), '->', out)
PY
echo "size: $(wc -c < "$OUT") bytes"
