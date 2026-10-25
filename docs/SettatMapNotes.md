# Settat offline map

Settat is the compact default operation. Its 3,200-unit square covers the
city center, Hassan I university area and connected rural approaches in an
approximately 8.5 km extent. Casablanca remains available in Operations.

The bundled `SettatMap.json` contains 1,928 OSM building footprints, 2,474
public road sections, 63 park parcels, and a connected navigation graph with 7,251
nodes and 9,805 edges. The database is 971,068 bytes (approximately 948 KiB), compared with the much
larger Casablanca extract. Custom landmarks replace their parcel meshes in
the runtime map, so they appear once and can be destroyed independently.

Roads and footprints come from the [Geofabrik Morocco OSM extract](https://download.geofabrik.de/africa/morocco.html),
downloaded on 2026-10-09, with OSM replication timestamp
`2026-10-09T20:21:04Z`. The extraction script is
`scripts/import-settat.py`; it shares Casablanca's topology-preserving OSM
parser. It preserves public road junctions and keeps the largest connected
street graph for routing. Long regional ways retain their known contiguous
sections when distant OSM node references fall outside the extract. Border-crossing
navigation segments are clipped at the playable boundary with shared boundary
nodes, so rural approaches reach the edge instead of ending at an earlier junction.
Roads outside the connected component remain visual.
Physical street widths are estimates by road class, ranging from 5 m for
living streets to 22 m for motorway carriageways.

Projection is north up, equirectangular at 33.006 N, 0.35 world units per
meter, with a 100-unit margin. The geographic extract spans
32.968–33.044 N and 7.668–7.576 W. This is a playable city-and-approaches
extract, rather than a legal municipal boundary. The gameplay urban envelope
spans 32.981–33.039 N and 7.649–7.592 W, including the northern university and
ISSS campus area. Five connected road approaches enter this envelope after
467.5–601.5 m of exterior road travel. Complete assembled herds start on those
rural approaches, outside the city envelope.

## Landmark sources

Landmark locations use the following primary OpenStreetMap records from
the same cached database. Models are original lightweight silhouettes;
footprint dimensions follow approximate OSM parcel bounds, and height
estimates are identified as visual approximations rather than surveys.

| Landmark | Primary OSM source | Latitude / longitude | Model dimensions |
| --- | --- | --- | --- |
| Kasbah Ismailia | [way 457963027](https://www.openstreetmap.org/way/457963027) | 33.0038013449, -7.6207871656 | 90 × 57 m; tagged 8 m height |
| Sidi Loghlimi Mosque | [way 449169811](https://www.openstreetmap.org/way/449169811) | 33.0040173246, -7.6201114001 | 34 × 29 m; approximate 34 m minaret silhouette |
| Place Mohamed V | [way 450945394](https://www.openstreetmap.org/way/450945394) | 33.0017790, -7.6187798 | 144 × 69 m; authored square and fountain |
| Settat Municipal Palace | [way 449104045](https://www.openstreetmap.org/way/449104045) | 33.0002455, -7.6192486 | 64 × 58 m; tagged 12 m height |
| Hassan I University presidency | [way 450193531](https://www.openstreetmap.org/way/450193531) | 33.0247473, -7.6162166 | 39 × 35 m; approximate 18 m campus silhouette |
| Settat Railway Station | [way 1026358531](https://www.openstreetmap.org/way/1026358531) | 32.9940142, -7.6233573 | 31 × 34 m; approximate 12 m station silhouette |

The Kasbah and mosque centers use their OSM footprint bounds, keeping their
solid models clear of neighboring street centerlines. The university's location on the Casablanca road is also supported by its
[official access page](https://www.uh1.ac.ma/vie-estudiantine/vie-pratique/le-plan-dacces-a-luniversite/).
The Kasbah is documented by the [Ministry of Culture's restoration notice](https://mjcc.gov.ma/wp-content/uploads/2022/03/Travaux-De-Restauration-De-La-Kasbah-Ismailia-A-Settat-.pdf)
and the [regional tourism board's Settat page](https://visitcasablanca.ma/ou-aller/settat/).

Building and landmark indices remain stable for a mission. Blast queries
measure distance to footprint walls, and line-of-sight queries accept the
destroyed building/landmark sets so ruins no longer block shots like intact
walls. The navigation graph stays on public streets. A native map integrity
check verified 73,989 samples along all navigation edges on road geometry,
all five exterior approaches, every building's footprint-distance query,
landmark line-of-sight exclusions, and no navigation edge crossing any solid
landmark rectangle.

`SettatPreview.json` is an approximately 200 KiB selector thumbnail created
with `scripts/create-map-preview.swift settat`; opening Operations does not
construct the city's navigation graph. The complete derived map database
and thumbnail are distributed under ODbL 1.0 with attribution in
`Zomboys/Resources/SettatMap-LICENSE.txt`.
