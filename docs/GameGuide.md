# Zomboys — Game & Development Guide

[← Back to the project](../README.md)

A native iPhone horde-defense strategy game built with SwiftUI and a SceneKit 3D world. Plan a defense, command ground forces, intercept incoming zombie herds, and rescue as many civilians as possible.

## Movement and animation update

The 25 October pass applies the reference study directly to crowd presentation: gradual acceleration, slower infected cruise, bend-aware pace, local pack flow, bounded turns and convergence at destinations. Original walk/run cycles now blend through speed changes, use grounded stance and lifted knees, lengthen the running stride and vary their phase between people. Dense street views retain nearby bodies inside the 160-person budget while other people remain dots; waiting exterior herds can show bodies too. See [V8MotionValidation.md](V8MotionValidation.md) and the [native motion preview](../Screenshots/Zomboys-v8-herd-motion.mp4).

## Reference study and strategy update

The 15 official uploads available on 18 October 2026 and three linked developer walkthroughs were studied through footage, available captions and primary descriptions. [ReferenceChannelStudy.md](ReferenceChannelStudy.md) records the inventory, timestamped mechanics, implementation choices and limits, including the new 18 October short whose transcript was unavailable. The game uses original code, models and tuned mobile rules; the videos do not disclose the source game’s steering algorithms or balance tables.

- **Two operation types:** Exterior Siege retains large preassembled outside-city columns and randomized arrival times. City Outbreak starts with an unknown interior infection and three expanding population catchments in each Moroccan city. People remain active when they move outside the marked catchment. Successful expansion carries surviving paid defenses into the next stage.
- **Safe zones and gates:** drag a rectangle to preview all required paid street closures. Civilians shelter inside intact zones. Walls block civilians too; paid gates allow single-file passage while keeping infected out. Queues, wall health and defended access routes matter.
- **Local crowd behavior:** individuals peel toward nearby visible prey, vary their street lanes, preserve personal space and queue before intact walls. Buildings and walls prevent bite transmission. Infantry can be bitten and converted; surviving team members retain their reduced fighting strength.
- **Position-dependent defenses:** roof snipers gain reach with building height and cost more on larger buildings. Descending visibility rays still respect intervening taller structures. Mines trigger near infected; C4 requires a manual order. Both have arming time and can cause civilian and building casualties.
- **Learn from a failed plan:** bounded red casualty/breach flags remain on the field, with a map review from the debrief. Score gives one additional survivor more weight than every combat/time tie breaker. Survival badges and finite incremental rewards recognize improved successful results. Loadout points can be reassigned for free during planning.
- **Clearer tactical presentation:** white civilian and bright green infected dots, blue safe-zone outlines, actual gate openings, original explosive models and elevated sniper crews. The native-resolution renderer, fixed simulation steps, GPU interpolation and bounded active AI remain in place.

Only **Casablanca and Settat** are included. Kill money, the emergency reserve, the AC-130/B-2/A-10 roster and the requested audio choices remain. There is no passive income or defeat grinding. The source’s advertised desktop-scale population is not a claim about this phone implementation.

## Run in Xcode

1. Open `Zomboys.xcodeproj` in Xcode 16.2 or later.
2. Select the **Zomboys** scheme and an iPhone simulator or connected iPhone.
3. Press **⌘R**.

The deployment target is iOS 17. There are no runtime packages, API keys, map downloads, or network requirements. For a physical iPhone, select your Apple development team in **Signing & Capabilities**, choose the phone, and run.

## Casablanca and Settat

**Settat is the compact default operation**, with 360 civilians and $2,000. Its real street-and-building extract spans approximately 8.5 km, including the city center, the Hassan I university area and connected rural approaches. The 3,200 × 3,200 unit world contains 1,928 OSM building footprints and 2,474 roads; the database is about 948 KiB. Six original 3D landmark interpretations represent Kasbah Ismailia, Sidi Loghlimi Mosque, Place Mohamed V, the Municipal Palace, Hassan I University and Settat Railway Station. Locations and approximate model dimensions are documented in [SettatMapNotes.md](SettatMapNotes.md).

Casablanca is the flagship scenario: an 8,000 × 8,000 unit citywide world using real georeferenced OpenStreetMap streets, building footprints, parks, and the Atlantic coastline. The offline extract covers the connected urban area from the Corniche and Ain Diab through Ain Sebaâ, Sidi Bernoussi, and Sidi Moumen, and south to Lissasfa and Sidi Maârouf. It spans approximately 33 km horizontally; this is an urban-area extract, not a legal administrative-boundary map of Greater Casablanca.

The map includes roughly **50,000 building footprints** and **34,000 road ways**. Custom 3D interpretations represent Hassan II Mosque, Twin Center, Morocco Mall, Sacré-Cœur, Place Mohammed V, the port, the Médina clock tower, El Hank lighthouse, Stade Mohammed V, Casa Voyageurs, and Casa Port. Buildings use OSM heights or floor counts where available and deterministic visual estimates elsewhere. Landmark shapes and dimensions are authored approximations.

The full-screen scene has depth-tested buildings with directional shading, roof details, windows, trees, ground units, aircraft, and projectile trails. Meshes are batched into spatial chunks; facade detail appears near the camera. A tilted camera gives depth, while the overhead toggle supports precise planning. Camera controls include pan, anchored pinch zoom, Street Level, whole-city overview, reset, landmarks, and herd tracking anchored to a stable member inside the selected group. Articulated people have distinct heads, shoulders, arms, knees and equipment with walking/running poses. Body and vehicle dimensions stay proportional to streets; distant crowds use small circular dots. Explosions scar buildings, collapse destroyed structures into persistent rubble, and open previously blocked sightlines. Landmark destruction survives camera detail changes and resets on retry.

The map starts in a crisp overhead view with neutral rooftops, dark streets, green parks and compact crowd markers. Toggle the tilted camera for landmark depth. **Casablanca and Settat are the only operations**; New York, Paris, Los Angeles and Venice have been removed, including their unused map generators. Valid Moroccan-city progression and purchased upgrades remain intact.

Presentation targets **60 FPS at native screen resolution**, with 30 FPS in Low Power Mode or serious thermal pressure. Street AI advances in fixed 50 ms simulation steps, distributed across display frames at accelerated speed; HUD updates run at 5 Hz. Crowd vertices interpolate previous, midpoint and current poses on the GPU, including forward gait cycles and turns. CPU crowd preparation and terrain meshing run off the main thread; reusable Metal meshes rotate between three buffers and upload through the renderer's command queue. Upload staging buffers return to a bounded pool only after GPU completion. Whole-city roads share one mesh; closer streets use spatial chunks. City quads share four indexed vertices while preserving their original triangles. Static landmarks combine their geometry after sharing equivalent materials locally. Empty district and rubble nodes remain detached until needed; coalesced background roof updates carry building damage through city overview and retry. Buildings use a bounded detail cache; effects, shells and support-area nodes are pooled.

The overhead camera uses round crowd dots at every zoom, with four vertices per disc, batched actor colors and smooth shader edges. Tilted street view shows up to 160 articulated people and 80 crew members, with dots for distant or densely packed crowds. Flat panels avoid repeated live-map blur, and compact map chips leave more visible street space. Late display callbacks admit at most two AI passes; overloaded or interrupted frames can slow simulation wall-time rather than move actors in long jumps. Active foreground play keeps the screen awake; pause and inactive states allow normal Auto-Lock. These are workload limits and a frame target. V7 physical iPhone 15 Pro tests measured about 60 FPS in crowded 3× city views on both maps. A separate hardware trace retained 498 attributed Casablanca frames over 8.285 seconds at **59.99 displayed FPS**, with 1,400 active infected. The signed Settat build measured **58.51–59.99 callback FPS** across 36.04 dense seconds. See [V7StrategyValidation.md](V7StrategyValidation.md) for workload, build scope, lost trace events and limits, including the later immutable landmark-cache optimization. Battery drain, long-session temperature and maximum simultaneous combat/effects/audio remain unmeasured.

Most Casablanca civilians begin in the central mission sector, with others distributed across the city. Incoming columns assemble on rural approach roads outside dense urban neighborhoods and march into the city. The navigation graph follows the largest connected public street network and uses spatial indexing and A* routing. Some isolated visual roads are not part of this connected routing network. Human and vehicle movement uses physical scale; weapon ranges and aircraft behavior are adapted for tactical play rather than a military simulation.

Map data is © OpenStreetMap contributors, licensed under ODbL 1.0. The complete derived databases are bundled in `Zomboys/Resources/SettatMap.json` and `CasablancaMap.json`; attribution, projection, coverage, and license links are in [SettatMap-LICENSE.txt](../Zomboys/Resources/SettatMap-LICENSE.txt) and [CasablancaMap-LICENSE.txt](../Zomboys/Resources/CasablancaMap-LICENSE.txt). No map imagery or satellite textures are bundled.

## Play

- Select a city from **Operations**. Settat starts with 360 civilians and $2,000; Casablanca remains available with 720 civilians and $2,400.
- Red approach markers show incoming herds and their city-entry ETA. Planning pauses the entire mission; press **Begin Containment** to start the countdown. Entire columns are already assembled across the width and length of exterior roads, visible as dense red dots before departure. Casablanca has six columns; Settat has four. Sizes grow from 560–660 to as many as 2,000 infected per herd. **Herd Approaches** tracks an active column or inspects its entry point. Routes, timing and sizes are seeded and randomized.
- Choose **Ground**, **Streets**, **Air Support**, or **Tactical**, then tap a street to deploy. Ground placements snap to navigable streets; sniper teams may occupy intact rooftops.
- Rifle squads contain five soldiers who spread into formation and fire individually. Infantry are cheap and deliberately less effective than heavy support, especially while moving. Squads, Humvees and sniper teams require clear sightlines; building footprints and solid landmark parcels block their shots. Mortars remain indirect fire.
- Select a Humvee and draw a **Patrol** route along streets, or use **Hold** to defend one intersection. The roof gun turns toward targets; intact barricades block vehicle patrols.
- Mortars launch visible shells with an arcing trail and travel time. Explosions damage buildings according to distance from their walls and structural resistance. They also kill civilians in the blast area; the HUD reports destroyed structures and total civilian casualties.
- Select **Barrier** and draw along a street. The preview shows the full cost; release to build. Walls cost $40 per 60-unit module, stop at 300 units, and have 320 health per paid module. Select a damaged barrier for a paid **Repair**, or remove it for the appropriate refund. A short tap builds one module.
- Civilians gradually discover an evacuation station within 65 meters with a clear view. They take time to share its location with nearby people, follow local leaders and spread evacuation knowledge through the crowd. They do not instantly know every station. Destroying or removing a station clears the obsolete destination. White marks living civilians; exposed civilians and incubating infected use amber, and active infected use bright green.
- Herds accelerate, follow shared street routes, compress under pressure and spread into open road space with uneven pace, lateral sway and separation. At most 1,400 infected run active AI; additional members remain visible in the assembled exterior tail and activate at their existing positions as room becomes available. Staged infected can be killed by explosive support and earn normal kill money; they cannot reappear later. Intact barricades stop active infected until their attacks break the wall. Infection requires 1.4 seconds of accumulated bite exposure. Exposure recedes when a civilian escapes contact, and new infected cannot infect others during their 2.5-second incubation.
- Each kill earns **$12**. There is no passive income. After 20 simulated seconds, one **$350 emergency reserve** unlocks when funds fall to $240 or less, casualties reach 18% of the population, or the active infected count reaches three times the first herd's size. Claiming it pauses combat to regroup.
- Aircraft respond after the initial 18-second mobilization window. Choose a strike center and attack heading. AC-130 support can switch between 30 mm and 105 mm modes and retarget its orbit. Every aircraft type has three sorties per operation; a new sortie costs its listed price. The AC-130 has a 46-second sortie followed by 50 seconds of rearming. B-2 and A-10 passes last 11 and 12 seconds respectively, each followed by 35 seconds of rearming. These clocks use simulation time, so pause and speed controls also affect them.
- Four paid **Tactical** reserves are available once per operation: paratroopers drop two squads after 3 seconds and seek the horde; gas stuns infected for 8 seconds without hurting civilians; fire creates three destructive impacts and 10-second burning areas; call to arms equips up to 12 nearby residents with clear sightlines. Armed residents remain living civilians for survival scoring; withdrawing them restores their civilian role. Fires can hurt civilians, friendly units and buildings.
- Pause to adapt, or use 1×/2×/3× simulation. **Retry** preserves the same outbreak seed; **New Outbreak** randomizes it.
- Eliminate all infected with at least one civilian survivor and, in Siege, survive the complete arrival schedule including every unreleased member. One survivor is worth 10,000 points; combined kills and containment-time bonuses are capped below 10,000.
- Invest specialization points in **Loadout**, or reassign them freely during planning. Each operation has at most three reward points: saving 90% earns the highest tier, meeting its survival objective the middle tier, and a smaller successful rescue the first tier. An improved result awards only the unpaid difference. Repeated results and defeats award none. Upgrades and best results persist locally. Previous turret, bomber, gunship and garrison upgrades migrate to their replacement forces; investments from the earliest removed sniper roster are refunded once.

## Forces

| Force | Cost | Role |
| --- | ---: | --- |
| Rifle squad | $90 | Five soldiers; mobile formation and light fire |
| Armed Humvee | $220 | Mobile roof gun; patrol or hold |
| Mortar team | $240 | Delayed arcing area fire with civilian risk |
| Sniper team | $280 | Slow precise long-range shots; buildings block sightlines |
| Barricade | $40 / module | Draw streets, finite durability, paid repairs |
| Safe zone | Per required wall | Draw a district; closes every street crossing |
| Civilian gate | $60 | Insert into a wall; single-file civilian passage |
| Mine | $75 | Arms, then detonates near infected with collateral risk |
| C4 | $95 | Arms, then waits for a manual detonation order |
| Evacuation station | $180 | Attract and extract civilians |
| AC-130 Ghostrider | $650 | Orbit with 180 ammunition credits; 30 mm uses 2 per burst, 105 mm uses 16 per shell |
| B-2 Spirit | $600 | Low cinematic flyby; four spaced bombs along the chosen heading |
| A-10 Thunderbolt II | $400 | Directional GAU-8 strafe; 540 modeled rounds and synchronized BRRRT |
| Paratroopers | $350 | One drop of two squads that seek infected |
| Gas bomb | $250 | One nonlethal 32 m stun cloud |
| Fire bomb | $450 | Three 22 m incendiary areas with collateral risk |
| Call to arms | $200 | Arm up to 12 visible nearby residents once |

Aircraft are gameplay interpretations. Their cinematic altitudes, damage, targeting, ammunition allowances, and response times are tuned for this game.

## Sound

Offline audio covers rifle and sniper fire, heavy gunfire, mortar launch and impact, aircraft engines and weapons, falling bombs, the A-10 GAU-8 burst, barricade damage, evacuation confirmation, alarms, and mission outcomes. Constant city ambience and zombie/civilian voices have been removed. Four rifle and four sniper reports vary between deployments and remain consistent for each team. Aircraft and vehicle engines only accompany those active units and fade in/out; bomb whistles merge into impact. The sound panel provides sound enable, weapons/explosions and aircraft/vehicles controls, plus an A-10 preview. Sounds use camera-relative stereo direction and distance attenuation with bounded playback.

The GAU-8 burst uses a real public-domain gun run with recorded decay, a gentle tail and a silent endpoint, now 3.08 seconds. Repeated preview taps and weapon voice pressure cannot restart or evict the burst. Pause lets already-fired reports finish; explicit mute/reset and retiring loops use short fades. The remaining effects and engines are original procedural game sound design. Full sources and processing details are in [Audio/SOURCES.md](../Zomboys/Resources/Audio/SOURCES.md). Large download intermediates remain under `.build` and are not included in the app.

## Project structure

- `Zomboys/Core/FrameInterpolation.swift`: fixed-step clock, shortest-angle turns and forward gait interpolation.
- `Zomboys/Core/TacticalSupport.swift`: paid reserve types and area state.
- `Zomboys/Core/TacticalPlanning.swift`: safe zones, loss markers and perimeter geometry.
- `Zomboys/Core/CampaignProgression.swift`: operation modes, district objectives, survivor grades and finite rewards.
- `Zomboys/UI/TacticalGameLoop.swift`: independent simulation, HUD and presentation clocks.
- `Zomboys/UI/TacticalAnimatedCrowd.swift`: cached original poses, background preparation and reusable GPU meshes.
- `Zomboys/UI/TacticalFrameMetrics.swift`: GPU upload ordering, Double-clock animation and opt-in frame measurements.
- `Zomboys/Core/GameEngine.swift`: herd arrivals, flock movement, combat, aircraft, projectiles, evacuation, money, and progression.
- `Zomboys/Core/CityMap.swift`: offline geometry, landmark locations, spatial queries, and A* routing.
- `Zomboys/Core/GameTypes.swift` and `CombatState.swift`: scenario, unit, aircraft, projectile, and audio state.
- `Zomboys/UI/CommandView.swift`: HUD, command tray, aircraft controls, and results.
- `Zomboys/UI/TacticalSceneView.swift`: native SceneKit scene, camera, and actor presentation.
- `Zomboys/UI/TacticalSceneGeometry.swift` and `TacticalLandmarkModels.swift`: batched city meshes and custom landmark geometry.
- `Zomboys/UI/TacticalHumanModels.swift`: articulated crowd, soldier and sniper silhouettes.
- `Zomboys/UI/TacticalMapView.swift`: gestures, drawing previews, map controls, and attribution.
- `Zomboys/UI/TacticalPerformance.swift`: render and simulation budgets plus thermal/Low Power Mode adaptation.
- `Zomboys/UI/OperationsView.swift`: city selection, loadout, and field manual.
- `Zomboys/Audio/GameAudioController.swift`: local stereo audio mixer.
- `Tests/CoreTests.swift`: executable gameplay checks.
- `ZomboysUITests`: iPhone simulator interaction tests.
- `scripts/import-casablanca.py`: reproducible OSM extraction; requires pyosmium only for development import, not app runtime.
- `scripts/import-settat.py`: compact Settat extraction using the same OSM parser.
- `scripts/create-map-preview.swift`: generates offline Settat/Casablanca thumbnails without loading navigation graphs in Operations.

## Verification

Run the gameplay suite, build, and simulator UI tests from the project directory:

```sh
./scripts/test-core.sh
./scripts/test-frame-interpolation.sh
./scripts/test-support.sh
./scripts/test-movement.sh
./scripts/test-crowd-motion.sh
./scripts/test-movement-corners.sh
./scripts/test-tactics.sh
./scripts/test-campaign.sh
./scripts/test-terrain-mesh.sh
./scripts/test-render.sh
./scripts/build.sh
xcodebuild test -project Zomboys.xcodeproj -scheme Zomboys \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

The `--uitesting` launch argument isolates test progression from normal saved upgrades. The expanded suite checks both OSM maps, preassembled exterior herds, bounded active AI, continuous street movement, building visibility, formations, patrols, barricades, delayed projectiles, aircraft inventory, structural and civilian blast damage, social evacuation, sound identities, kill income, civilian conservation and saved progression. It also completes ordinary paid strategies in Settat and Casablanca.

Current motion-pass checks (25 October 2026):

- **327 gameplay checks**, **36 local movement checks**, **76 real street-corner checks**, **1,668 locomotion/detail checks** and **eight actual render groups passed**. Both selected native interaction flows passed. The signed iPhone build was installed and normally launched. See [V8MotionValidation.md](V8MotionValidation.md) for exact scope; no new physical-phone FPS or battery result is claimed.

Earlier V7 checks (24–25 October 2026):

- **327 whole-game checks passed on the final geometry-cache build**, including paid exterior sieges saving **360/360 in Settat** and **717/720 in Casablanca**, and a replay that cannot farm specialization points.
- **126 tactical**, **81 campaign**, **30 movement** and **76 corner-navigation** checks passed, plus **18 controlled civilian-knowledge checks** on both maps. These cover real wall/gate transactions, explosive collateral, roof hosts, bites, district carryover, finite rewards, local perception and escape from previously permanent street-corner traps.
- **116 clock/interpolation**, **35 paid tactical-support**, **18 terrain** checks and **six native Metal render groups** passed.
- All **13 distinct native Simulator interaction flows passed across runs**. An initial C4 selection failure was corrected, then the affected flow and two related flows passed on the final test build. Drawn districts, charge arming, partial building damage, aircraft, patrols, sound controls, formations and both maps are exercised.
- Ordinary paid City Outbreak strategies saved **84/90 in Settat** and **174/180 in Casablanca**, clearing every infected through production gameplay with real kill income.
- The signed phone build and Simulator test build succeeded. Separate V7 phone profiles measured about 60 FPS in the documented crowded scenes, with a short independent Casablanca presentation trace. Detailed evidence and limits are in [V7StrategyValidation.md](V7StrategyValidation.md). The earlier [V6 validation](V6RenderValidation.md) is historical.


## Reference

The original visual/movement reference is the [Zombies Aren’t Real trailer](https://www.youtube.com/watch?v=ZggNoETNdpg), directly inspected at its crowd, combat and loadout scenes. It shows an overhead city, compact flowing crowds, subdued building colors and bright tactical effects. Its loadout identifies airborne squads, gas, fire and civilian mobilization; these now have playable implementations here. The requested AC-130, B-2 and A-10 remain the named aircraft. Art and behavior are original implementations guided by the visible trailer; the clip does not expose the reference game's full rules or internal animation system.

The earlier [video reference](https://www.youtube.com/watch?v=iRq-VQCKwG8) established the containment premise. Zomboys contains two offline Moroccan-city operations, incoming herd schedules, ground commands, destructive support and civilian evacuation.

The latest aircraft references and the original sound treatment are documented in [AircraftReferenceNotes.md](AircraftReferenceNotes.md). Dense crowd surges take inspiration from the requested World War Z behavior; all human geometry and animations are original procedural game assets.
