#!/usr/bin/env python3
"""Build a compact, offline Settat map from the Geofabrik Morocco OSM extract.

Uses the same topology-preserving extractor as Casablanca, with a smaller
city-and-approaches extent and widths in physical meters. No imagery is used.
Requires pyosmium, including the existing .build/map-tools environment.
"""
import argparse
import importlib.util
import json
import math
from pathlib import Path

spec = importlib.util.spec_from_file_location("city_extractor", Path(__file__).with_name("import-casablanca.py"))
extractor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(extractor)
extractor.WEST, extractor.SOUTH, extractor.EAST, extractor.NORTH = -7.668, 32.968, -7.576, 33.044
extractor.SCALE, extractor.WORLD = .35, 3_200
extractor.COS_LAT = math.cos(math.radians(33.006))

def project(lon, lat):
    return [round(100 + (lon - extractor.WEST) * extractor.METERS_DEGREE * extractor.COS_LAT * extractor.SCALE, 2),
            round(100 + (extractor.NORTH - lat) * extractor.METERS_DEGREE * extractor.SCALE, 2)]

extractor.project = project
extractor.ROAD_CLASSES = {key: meters * extractor.SCALE for key, meters in {
    'motorway': 22, 'motorway_link': 9, 'trunk': 18, 'trunk_link': 8,
    'primary': 15, 'primary_link': 8, 'secondary': 12, 'secondary_link': 7,
    'tertiary': 10, 'tertiary_link': 6, 'unclassified': 7, 'residential': 7,
    'living_street': 5, 'service': 5}.items()}

class SettatExtract(extractor.Extract):
    def __init__(self):
        super().__init__()
        self.places = []

    def node(self, node):
        super().node(node)
        if node.location.valid() and extractor.inside(node.location.lon, node.location.lat):
            tags = dict(node.tags)
            if tags.get('name') or tags.get('name:fr') or tags.get('name:en'):
                self.places.append({'type': 'node', 'id': node.id, 'lon': node.location.lon,
                                    'lat': node.location.lat, 'tags': tags})

    def way(self, way):
        tags = dict(way.tags)
        # A long regional road can cross this small city extract while distant
        # refs are outside the node cache. Keep its contiguous known sections
        # instead of silently discarding the entire N9/rural approach.
        refs = [node.ref for node in way.nodes]
        coordinates = [self.nodes.get(ref) for ref in refs]
        if tags.get('highway') in extractor.ROAD_CLASSES and tags.get('highway') != 'service' and tags.get('access') not in ('private', 'no') and any(point is None for point in coordinates):
            sections = []
            section = []
            for ref, coordinate in zip(refs, coordinates):
                if coordinate is None:
                    if len(section) > 1: sections.append(section)
                    section = []
                else:
                    section.append((ref, coordinate))
            if len(section) > 1: sections.append(section)
            for section in sections:
                if not any(extractor.inside(*point) for _, point in section): continue
                pts = [project(*point) for _, point in section]
                self.roads.append({'id': way.id, 'p': extractor.simplify(pts, .55),
                    'w': extractor.ROAD_CLASSES[tags['highway']], 'name': tags.get('name:en') or tags.get('name:fr') or tags.get('name', ''),
                    'bridge': tags.get('bridge') == 'yes', 'refs': [ref for ref, _ in section], 'raw': pts, 'class': tags['highway']})
        else:
            super().way(way)
        if not any(key in tags for key in ('name', 'name:fr', 'name:en')):
            return
        if not coordinates or any(point is None for point in coordinates):
            return
        lon = sum(point[0] for point in coordinates) / len(coordinates)
        lat = sum(point[1] for point in coordinates) / len(coordinates)
        if extractor.inside(lon, lat):
            self.places.append({'type': 'way', 'id': way.id, 'lon': lon, 'lat': lat, 'tags': tags})

def clipped_navigation_roads(roads):
    """Retain border-crossing road edges with shared synthetic boundary nodes.

    Dropping any edge whose far node is out of bounds truncates long straight
    rural approaches well before the map edge. Clip that edge precisely.
    """
    low, high = 10.001, extractor.WORLD - 10.001
    synthetic = {}
    output = []
    def clipped(a, b):
        dx, dy = b[0] - a[0], b[1] - a[1]
        lo, hi = 0., 1.
        for p, q in [(-dx, a[0] - low), (dx, high - a[0]), (-dy, a[1] - low), (dy, high - a[1])]:
            if abs(p) < 1e-9:
                if q < 0: return None
            elif p < 0: lo = max(lo, q / p)
            else: hi = min(hi, q / p)
            if lo > hi: return None
        return lo, hi
    def endpoint(a, b, t, ref):
        if t == 0: return a, ref
        if t == 1: return b, ref
        point = [round(a[0] + (b[0] - a[0]) * t, 3), round(a[1] + (b[1] - a[1]) * t, 3)]
        key = tuple(point)
        if key not in synthetic: synthetic[key] = -1 - len(synthetic)
        return point, synthetic[key]
    for road in roads:
        points, refs = [], []
        def flush():
            if len(points) > 1:
                output.append({**road, 'refs': refs.copy(), 'raw': points.copy()})
            points.clear(); refs.clear()
        for a, b, ar, br in zip(road['raw'], road['raw'][1:], road['refs'], road['refs'][1:]):
            span = clipped(a, b)
            if span is None: flush(); continue
            lo, hi = span
            start, sr = endpoint(a, b, lo, ar if lo == 0 else br)
            finish, fr = endpoint(a, b, hi, br if hi == 1 else ar)
            if points and refs[-1] != sr: flush()
            if not points: points.append(start); refs.append(sr)
            if fr != refs[-1]: points.append(finish); refs.append(fr)
            if hi < 1: flush()
        flush()
    return output

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('pbf')
    parser.add_argument('output')
    args = parser.parse_args()
    data = SettatExtract()
    data.apply_file(args.pbf, locations=False)
    nodes, edges, components = extractor.graph_for(clipped_navigation_roads(data.roads))
    reader = extractor.osmium.io.Reader(args.pbf)
    timestamp = reader.header().get('osmosis_replication_timestamp')
    reader.close()
    output = {'metadata': {
        'source': 'OpenStreetMap contributors / Geofabrik Morocco extract',
        'sourceURL': 'https://download.geofabrik.de/africa/morocco.html',
        'license': 'ODbL 1.0', 'licenseURL': 'https://opendatacommons.org/licenses/odbl/1-0/',
        'sourceDataTimestamp': timestamp, 'extractedDate': '2026-10-11',
        'geographicBounds': [extractor.SOUTH, extractor.WEST, extractor.NORTH, extractor.EAST],
        'worldSize': extractor.WORLD, 'metersToWorld': extractor.SCALE,
        'estimatedHeights': sum(building['estimatedHeight'] for building in data.buildings),
        'notes': 'Compact Settat city and rural road approaches. Real OSM footprints and centerlines; unsurveyed building heights are deterministic estimates. Largest connected public street graph is navigable. North up, equirectangular projection at 33.006 N; 100-world-unit margin. Custom landmark silhouettes are original authored approximations.'},
        'roads': [{key: value for key, value in road.items() if key not in ('refs', 'raw', 'class')} for road in data.roads],
        'buildings': data.buildings, 'coastline': [], 'parks': data.parks,
        'navigationNodes': nodes, 'navigationEdges': edges}
    Path(args.output).write_text(json.dumps(output, separators=(',', ':')))
    Path('.build/settat-osm-places.json').write_text(json.dumps(data.places, ensure_ascii=False))
    print(json.dumps({'roads': len(data.roads), 'buildings': len(data.buildings),
                      'parks': len(data.parks), 'nodes': len(nodes), 'edges': len(edges),
                      'components': components, 'fileBytes': Path(args.output).stat().st_size}))

if __name__ == '__main__':
    main()
