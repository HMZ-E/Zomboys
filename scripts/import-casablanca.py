#!/usr/bin/env python3
"""Extract a reproducible offline Casablanca map from a Geofabrik OSM PBF.
Requires pyosmium in the Python environment. Output is ODbL-derived map data.
The script keeps real OSM footprints and street topology; missing building
heights are deterministic visual estimates, not surveyed measurements.
"""
import argparse, json, math, sys
from collections import defaultdict, Counter
from pathlib import Path
try:
    import osmium
except ImportError:
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / '.build/map-tools'))
    import osmium

WEST, SOUTH, EAST, NORTH = -7.79, 33.47, -7.43, 33.67
SCALE = .235
COS_LAT = math.cos(math.radians(33.57))
METERS_DEGREE = 111_320
WORLD = 8_000

def project(lon, lat):
    return [round(75 + (lon - WEST) * METERS_DEGREE * COS_LAT * SCALE, 2),
            round(800 + (NORTH - lat) * METERS_DEGREE * SCALE, 2)]

def inside(lon, lat, margin=0):
    return WEST-margin <= lon <= EAST+margin and SOUTH-margin <= lat <= NORTH+margin

def area(points):
    return abs(sum(a[0]*b[1]-b[0]*a[1] for a,b in zip(points, points[1:]+points[:1]))) / 2

def length(points):
    return sum(math.dist(a,b) for a,b in zip(points,points[1:]))

def simplify(points, tolerance):
    if len(points) < 3: return points
    a,b=points[0],points[-1]
    dx,dy=b[0]-a[0],b[1]-a[1]
    den=dx*dx+dy*dy
    maximum=-1; at=0
    for i,p in enumerate(points[1:-1],1):
        t=max(0,min(1,((p[0]-a[0])*dx+(p[1]-a[1])*dy)/den)) if den else 0
        distance=math.dist(p,[a[0]+t*dx,a[1]+t*dy])
        if distance>maximum: maximum,at=distance,i
    if maximum<=tolerance: return [a,b]
    return simplify(points[:at+1],tolerance)[:-1]+simplify(points[at:],tolerance)

ROAD_CLASSES={'motorway':10,'motorway_link':7,'trunk':9,'trunk_link':6,'primary':8,'primary_link':6,
              'secondary':7,'secondary_link':5,'tertiary':6,'tertiary_link':5,'unclassified':4,
              'residential':4,'living_street':3,'service':3}

class Extract(osmium.SimpleHandler):
    def __init__(self):
        super().__init__();self.nodes={};self.roads=[];self.buildings=[];self.coasts=[];self.parks=[];self.named=[]
    def node(self,n):
        if n.location.valid() and inside(n.location.lon,n.location.lat,.025):
            self.nodes[n.id]=(n.location.lon,n.location.lat)
    def way(self,w):
        tags=dict(w.tags)
        relevant='building' in tags or tags.get('highway') in ROAD_CLASSES or tags.get('natural')=='coastline' or tags.get('leisure')=='park'
        if not relevant:return
        refs=[n.ref for n in w.nodes]
        coordinates=[self.nodes.get(n) for n in refs]
        if any(p is None for p in coordinates):return
        if not any(inside(*p) for p in coordinates):return
        pts=[project(*p) for p in coordinates]
        name=tags.get('name:en') or tags.get('name:fr') or tags.get('name','')
        if 'building' in tags and refs[0]==refs[-1] and len(pts)>=4:
            pts=pts[:-1]
            # Rendering height estimates use OSM levels where known.
            raw=tags.get('height','').replace(' m','').replace(',','.')
            levels=tags.get('building:levels','')
            try:height=float(raw)
            except ValueError:
                try:height=float(levels)*3.2
                except ValueError:
                    typ=tags.get('building','yes')
                    height={'house':7,'residential':15,'apartments':21,'industrial':9,'warehouse':8,'school':10,'retail':9,'mosque':18}.get(typ,12+(w.id%7)*2.8)
            if area(pts)<1.2:return
            self.buildings.append({'id':w.id,'p':pts,'h':round(max(1.5,min(65,height*SCALE)),2),'s':w.id%6,
                                   'estimatedHeight':not bool(raw or levels)})
            if name:self.named.append({'name':name,'id':w.id,'p':pts})
        elif tags.get('highway') in ROAD_CLASSES and tags.get('access') not in ('private','no'):
            # Service roads outside downtown add substantial noise and disconnected parking aisles.
            if tags['highway']=='service':return
            self.roads.append({'id':w.id,'p':simplify(pts,.55),'w':ROAD_CLASSES[tags['highway']],
                               'name':name,'bridge':tags.get('bridge')=='yes','refs':refs,'raw':pts,'class':tags['highway']})
        elif tags.get('natural')=='coastline':self.coasts.append({'id':w.id,'p':simplify(pts,.45),'refs':refs})
        elif tags.get('leisure')=='park' and refs[0]==refs[-1]:self.parks.append({'id':w.id,'p':pts[:-1],'name':name})

def graph_for(roads):
    # Keep every public street. Compress between junctions, retaining shape vertices
    # only where the direction changes materially. OSM node sharing preserves actual
    # connectivity while keeping grade-separated roads from falsely intersecting.
    usage=Counter(n for r in roads for n in set(r['refs']))
    nodes=[];lookup={};edges=[];seen=set()
    def index(ref,p):
        if ref not in lookup:lookup[ref]=len(nodes);nodes.append(p)
        return lookup[ref]
    for road in roads:
        refs,pts=road['refs'],road['raw']
        anchors=[0]+[i for i in range(1,len(refs)-1) if usage[refs[i]]>1]+[len(refs)-1]
        for first,last in zip(anchors,anchors[1:]):
            selected=simplify(pts[first:last+1],.5)
            # Original coordinates occur in simplified points; use index mapping.
            at=first
            ids=[]
            for p in selected:
                while at<last and pts[at]!=p:at+=1
                ids.append(index(refs[at],p))
            for a,b in zip(ids,ids[1:]):
                key=(min(a,b),max(a,b))
                if a!=b and key not in seen:seen.add(key);edges.append([a,b])
    neighbors=defaultdict(list)
    for a,b in edges:neighbors[a].append(b);neighbors[b].append(a)
    visited=set();components=[]
    for i in range(len(nodes)):
        if i in visited:continue
        stack=[i];component=[];visited.add(i)
        while stack:
            node=stack.pop();component.append(node)
            for n in neighbors[node]:
                if n not in visited:visited.add(n);stack.append(n)
        components.append(component)
    # Clip navigation to playable map bounds. Keep visual geometry crossing the
    # border so the coastline and boulevards still reach the edge naturally.
    allowed={i for i,(x,y) in enumerate(nodes) if 10<=x<=WORLD-10 and 10<=y<=WORLD-10}
    visited=set();components=[]
    for i in allowed:
        if i in visited:continue
        stack=[i];component=[];visited.add(i)
        while stack:
            node=stack.pop();component.append(node)
            for n in neighbors[node]:
                if n in allowed and n not in visited:visited.add(n);stack.append(n)
        components.append(component)
    main=set(max(components,key=len))
    remap={old:new for new,old in enumerate(sorted(main))}
    return [nodes[old] for old in sorted(main)],[[remap[a],remap[b]] for a,b in edges if a in main and b in main],len(components)


def main():
    args=argparse.ArgumentParser();args.add_argument('pbf');args.add_argument('output');opt=args.parse_args()
    data=Extract();data.apply_file(opt.pbf,locations=False)
    graphNodes,graphEdges,components=graph_for(data.roads)
    output={'metadata':{'source':'OpenStreetMap contributors / Geofabrik Morocco extract',
            'sourceURL':'https://download.geofabrik.de/africa/morocco.html','license':'ODbL 1.0',
            'licenseURL':'https://opendatacommons.org/licenses/odbl/1-0/',
            'downloadDate':'2026-10-09','geographicBounds':[SOUTH,WEST,NORTH,EAST],
            'worldSize':WORLD,'metersToWorld':SCALE,'estimatedHeights':sum(b['estimatedHeight'] for b in data.buildings),
            'notes':'Real georeferenced OSM street centerlines and building footprints. Unsurveyed heights are deterministic visual estimates. Only the largest connected public-street graph is navigable; secondary disconnected visual roads remain visible. Roads are simplified to approximately 2m tolerance. Navigation is clipped to the playable 8,000-unit square.'},
            'roads':[{k:v for k,v in r.items() if k not in ('refs','raw','class')} for r in data.roads],
            'buildings':data.buildings,'coastline':[r['p'] for r in data.coasts],
            'parks':data.parks,'navigationNodes':graphNodes,'navigationEdges':graphEdges}
    Path(opt.output).write_text(json.dumps(output,separators=(',',':')))
    Path('.build/casablanca-named-buildings.json').write_text(json.dumps(data.named,ensure_ascii=False))
    print(json.dumps({'roads':len(data.roads),'buildings':len(data.buildings),'coastlines':len(data.coasts),
                      'parks':len(data.parks),'nodes':len(graphNodes),'edges':len(graphEdges),'components':components,'fileBytes':Path(opt.output).stat().st_size}))
if __name__=='__main__':main()
