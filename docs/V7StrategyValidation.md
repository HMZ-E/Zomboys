# V7 strategy and movement validation

Validation completed across 24–25 October 2026. The reference study was completed on 18 October and covers the 15 official uploads then available plus three developer walkthroughs. See [ReferenceChannelStudy.md](ReferenceChannelStudy.md) for evidence, timestamps and deliberate differences.

## Implemented behavior

Exterior Siege retains the original large, preassembled incoming columns. City Outbreak adds a concealed interior infection and three population catchments per city. A catchment describes initial population placement, not an invisible simulation boundary. Successful expansion retains surviving paid defenses with fresh IDs; a breached safe zone does not become intact merely because its missing walls were omitted during carryover.

Safe-zone planning buys actual cross-street walls atomically. Gates allow queued civilian passage while blocking infected. Gate destruction breaches its parent wall; a combat withdrawal cannot magically reseal that opening. Mines and C4 arm for two simulation seconds, have real collateral effects, and use ordinary money and kill income. Infantry can be bitten and converted; mobilized residents remain accounted for as civilians. Roof snipers use actual host height, variable deployment cost, descending visibility rays and valid roof positions. Host collapse removes the team.

Civilian and infected movement uses visible local threats/prey, personal lanes, spacing and road-constrained motion. The sharp-corner regression exposed a real failure: the nearest graph center could lie behind a projecting building tip. Recovery now takes a validated route around that tip before rejoining the shared path. It does not teleport a body or advance an invisible cursor through a footprint.

The debrief includes survival grades, finite incremental rewards, best results and a field review with bounded casualty/breach flags. One survivor outweighs the entire combat/time tie breaker. Planning allows free loadout reassignment while preserving a damaged defense’s health fraction. Repeated respec cycles cannot repair retained units for free.

Native-resolution rendering, GPU pose interpolation, bounded crowd detail, the 1,400 active-infected limit, and staged visible reserves are retained. White civilian/green infected role colors are shared by the actual Metal shader and materials. Safe-zone, catchment and history annotations use cached batched geometry. Gates cut actual gaps in wall meshes. The existing AC-130, B-2, A-10 and audio behavior remain.

## Completed focused checks

| Check | Result | Evidence |
| --- | --- | --- |
| Full production gameplay, finance and paid Siege victories | 327 passed on final cached Core | `.build/v7-core-cached-final.log` |
| Tactics, including raw touch projection on both maps | 126 passed | `.build/v7-tactics-snapped-touch-final.log` |
| Campaign, saved progression and respec | 81 passed | `.build/v7-campaign-finish.log` |
| Perception, contact and social movement | 30 passed | `.build/v7-movement-finish.log` |
| Actual occluded street turns | 76 passed | `.build/v7-corners-final.log` |
| Display clock and interpolation | 116 passed | `.build/v7-final-frame-tests.log` |
| Paid tactical reserves | 35 passed | `.build/v7-final-support-tests.log` |
| Native Metal crowd and gate geometry | 6 groups passed | `.build/v7-final-render.log` |
| Terrain damage and reset | 18 passed | `.build/v7-final-terrain.log` |

Corner checks cover 12 zombie routes and the same 12 civilian routes, movement bounds, road/footprint validity, permanent-stall detection and all four infected from the previously stuck Casablanca battle. Their recovered displacements were approximately 223–265 metres.

The unchanged ordinary paid City Outbreak strategy now completes both neighborhood operations through production gameplay. Settat saves **84/90**, with six casualties, 24 kills and $288 kill income, in 67.45 simulated seconds. Casablanca saves **174/180**, with six casualties, 24 kills and $288 kill income, in 92.85 seconds. Before the fix, that Casablanca strategy still had four stuck infected at 600 seconds. No fixture victory, free money or injected outcome was used. Evidence: `.build/v7-outbreak-play-final.log`.

## Integration checks

The signed Release iPhone build and Debug Simulator test build both succeeded. The development profile was renewed on 24 October and expires on **31 October 2026 at 13:30 Casablanca time**. The signed app includes both the C4 touch correction and the civilian reported-speed clamp described below.

All **13 distinct native interaction flows passed across runs**. The initial 13-flow run passed 12 and exposed a real charge-selection error: placement snapped an off-road finger point to the street, while inspection compared the unsnapped point. Charge inspection now uses the same road projection as placement. The corrected final run passed the affected City Outbreak/mine/C4 flow and the safe-zone and tactical-reserve flows, **3/3**, on the final Simulator build. Evidence: `.build/v7-final-ui-tests.log`, `.build/v7-verified-touch-ui.log`, `.build/V7VerifiedTouchResults.xcresult`.

C4 collateral now reports partial structural damage immediately, as well as destroyed structures and civilian casualties. The final UI capture shows five damaged structures and two civilian casualties after an ordinary paid detonation. Safe-zone capture shows 25 paid street closures, four sheltered residents and the actual blue district overlay. Captures: [safe zone](../Screenshots/iPhone15ProSimulator-v7-safe-zone.png), [C4 collateral](../Screenshots/iPhone15ProSimulator-v7-c4-collateral.png). These are Simulator captures, not phone photographs.

### Social regression

The old seeded street-corner test depended on one moving pair remaining in conversation range at 10.5 seconds. The updated street movement no longer produces a relay at that point; a 35-second diagnostic showed local sign discovery and following but no neighbor conversation in that particular setup. The replacement checks hold two residents on a real unobstructed street, one 60 metres from the EVAC and one 68 metres away. They call production knowledge updates without injecting learned IDs or timestamps. On both maps, signage takes sustained discovery, the second resident waits before following, then learns from the actual teacher after a further conversation delay. Closing the station clears both kinds of directions and stale leaders. **18 focused checks passed** (`.build/v7-social-fixture-final.log`). Existing whole-game checks still exercise moving civilians, local sign discovery, extraction and withdrawal.

The full regression also caught a reported walking speed about 4 × 10⁻¹² above its five-metres-per-second cap through floating-point roundoff. Published speed is clamped in both movement branches; the physical movement limit was already enforced. No gameplay balance was changed to satisfy that assertion.

### Visibility cost

Sampling the complete paid Casablanca battle exposed repeated allocations while rebuilding immutable landmark polygons during visibility checks. All 17 landmark outlines are now computed once per city map and reused by sight, contact and distance queries. Destroyed-landmark exclusions still apply at query time.

A before/after differential probe matched **565 output rows**, including all 17 exact polygons, **544 pairs of ordinary/destroyed-landmark visibility queries**, point-to-landmark distances and invalid-index handling. One million outline lookups took 0.418 → 0.016 seconds in Settat and 0.408 → 0.017 seconds in Casablanca on the Mac, with identical checksums. This measures outline lookup cost only; it does not establish a 25× game speedup or battery improvement. Evidence: `.build/v7-core-battle-sample.txt`, `.build/v7-visibility-before.log`, `.build/v7-visibility-after.log`, `.build/v7-visibility-cache-summary.json`.

Before the cache, the entire **327-check** core regression passed in 521.89 seconds, including paid Siege clears saving **360/360 in Settat** (4,071 kills, 320 simulated seconds) and **717/720 in Casablanca** (7,671 kills, 672 simulated seconds). The replay also completed without awarding specialization points again. The final cache build passed the same **327 checks in 410.83 seconds**, with the same two siege outcomes and a successful repeat-reward check (`.build/v7-core-cached-final.log`). These elapsed suite times are development-run observations, not a controlled frame-rate benchmark.

### Physical iPhone 15 Pro

Casablanca, **24 October**: 52 six-second profiling windows totalled 312.21 seconds. The 46 dense windows covered **276.18 seconds** with 1,400 active infected, 2,106–2,120 visible dots and over 6,200 staged members, at 3× game speed and native 3× render scale. Render/update callbacks measured **58.82–60.15 FPS**; update-start p95 was 16.72–16.83 ms. All recorded windows reported nominal thermal state and Low Power Mode off. This build preceded the final charge-touch correction, reported-speed roundoff clamp and immutable landmark cache; the main movement and renderer workload was already updated.

An independent **24 October hardware display trace** retained 498 attributed Zomboys frames over 8.285 seconds: **59.99 displayed FPS**, median/p95 frame spacing 16.670/16.670 ms and no retained gaps above 25 ms. Seven complete one-second bins each contained 60 frames. Instruments reported lost events, so this describes the retained sample only. CPU-to-display latency was 48.648 ms median and 48.917 ms p95; cadence is not an input-latency measurement. Evidence: `.build/V7CasablancaPhone1400.trace`, `.build/v7-phone-displayed-surfaces.xml`, `.build/v7-phone-hardware-summary.json`.

Settat, **25 October, signed app before the immutable landmark cache**: 13 windows totalled 78.07 seconds before the app exited normally. Six dense city-view windows covered 36.04 seconds with 1,400 active infected and 1,758–1,759 visible dots, at 3× speed/native 3× scale. Render/update callbacks were **58.51–59.99 FPS**, update-start p95 16.75–16.84 ms. Nominal thermal state and Low Power Mode off throughout. The final window was a district view with six visible dots and is excluded from the dense city-view figure. Evidence: `.build/v7-phone-settat-final.log`, `.build/v7-phone-profile-summary.json`.

The optimized Release build was compiled, signature-verified and installed successfully (`.build/v7-release-cache-final.log`, `.build/v7-cache-final-signature.log`, `.build/v7-cache-installed-final.json`). iOS then reported the phone locked when launching the additional close-up 3D profile, so no close-up performance measurement is claimed (`.build/v7-phone-cached-3d.log`). The overhead phone profiles above contained no articulated bodies. The user subsequently chose to finish with the collected measurements, closing the additional phone-test request.

Callbacks are not independent display measurements. Neither reproducible phone profile deployed defenses, and neither proves maximum simultaneous combat/effects/audio performance, long-session temperature or battery life. The Casablanca hardware trace is the independent presentation evidence; no equivalent final Settat hardware capture is claimed.

## Limits

A systematic visual comparison of swarm flow, gait style and animation transitions against the reference footage remains unfinished. The gameplay and rendering checks in this report do not establish the requested complete movement/animation match.

The source videos do not reveal proprietary steering algorithms or a complete numerical rule set. These are original implementations of observed design patterns with mobile-specific tuning. Casablanca and Settat remain the only maps. No passive income, civilian/zombie voices or continuous ambience were restored. The reference’s advertised desktop population is not a claim about simultaneous active AI on an iPhone.

The V6 measurements in [V6RenderValidation.md](V6RenderValidation.md) are historical evidence for that build. V7 measurements above are separate. Short wired profiling cannot establish sustained battery life or long-session temperature.
