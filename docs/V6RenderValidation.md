# V6 render validation

Validation updated 17 October 2026. The user has now explicitly authorized testing on the physical iPhone 15 Pro as well as the Simulator. Physical-device measurements and Simulator interaction checks are recorded below. The latest visual reference is the 29-second [Zombies Aren’t Real trailer](https://www.youtube.com/watch?v=ZggNoETNdpg), directly inspected at crowd/combat/loadout scenes.

## Implemented presentation

- Casablanca and Settat are the only selectable and generated operations. Legacy removed city IDs are filtered from completed-city progression while Moroccan-city records and upgrades survive.
- Default overhead presentation uses subdued roofs, dark streets, parks and compact round crowds. Tilted street view retains original articulated humans and landmark depth. Manual pan releases herd following; tracked camera focus advances with completed motion snapshots. Herd tracking anchors to one real member near the group center, retaining it across bends and staged-to-active transitions; this avoids looking at an empty centroid between separate roads.
- Flat opaque tactical panels remove per-frame backdrop blur. Compact map chips remove redundant headings/coordinates while retaining navigation and OSM attribution. Street Level reveals tilted close-up bodies and focuses a selected unit or support area. Pinching/panning cancels automatic herd following.
- Native screen resolution, analytic crowd-edge smoothing and a 60 FPS normal target replace the previous 1.5× surface and 20 FPS target. Low Power Mode/serious thermal pressure selects 30 FPS while keeping native resolution.
- AI uses fixed 50 ms simulated steps; accelerated steps are spread across display callbacks. At most two steps are admitted after a late callback, scaling the foreground-stall clamp with selected speed. Ordinary display timing preserves exact 1×/2×/3× elapsed intervals; sustained overload/system stalls can slow wall-time progress rather than accumulate a large catch-up burst. HUD publications run at 5 Hz. Crowd geometry blends three poses on the GPU, preserving forward walking/running cycles and shortest-angle turns. Active play explicitly enables continuous scene drawing so custom GPU motion receives frames between snapshots; explicit redraw requests are suppressed during continuous playback. Planning/pause use on-demand drawing. See [Apple continuous-rendering behavior](https://developer.apple.com/documentation/scenekit/scnview/renderscontinuously).
- CPU pose/index preparation and terrain baking run in background queues. A whole-city road mesh combines every original road triangle into four material draws; closer views switch to the original spatial chunks for culling. City quads now use four shared vertices with six indices, preserving both original triangles and their normals.
- Static landmarks deduplicate equivalent materials within each model and flatten their complete local geometry before applying geographical position and heading. Each retains a container with a flattened child for damage recoloring. Material sharing does not cross landmarks or vehicles. Empty district and rubble nodes stay detached until their geometry is needed; cached district nodes detach on eviction.
- Building damage updates the city-scale roof mesh as well as neighborhood geometry. Background overview rebuilds coalesce changes and reject stale city/damage revisions. Light/heavy damage retains the existing palette, destroyed roofs disappear above rubble, and retry restores intact roofs.
- The render callback owns crowd geometry submission and reusable Metal buffers; ordered GPU blits perform uploads inside SceneKit's renderer callbacks. A bounded staging-buffer pool recycles memory only after GPU completion, without waiting on the display thread. Clock locks never surround SceneKit property calls. Pooled projectile/effect/support nodes and bounded building detail avoid repeated scene creation.
- Active foreground gameplay disables idle Auto-Lock. Planning, pause and inactive states restore normal Auto-Lock behavior. Opt-in frame records include the system thermal state; this is diagnostic reporting, not a measurement of surface temperature or battery drain.
- Four single-use paid reserves implement the trailer's airborne squads, stun gas, incendiary areas and civilian mobilization. Existing requested AC-130/B-2/A-10 aircraft remain.

## Completed gameplay checks

The v6 gameplay run on 11 October passed 306 checks. Paid Settat strategy: 359/360 civilians, 4,072 kills, 437 simulation seconds. Paid Casablanca strategy: 717/720 civilians, 7,671 kills, 586 simulation seconds. Evidence: `.build/v6-core-final.log`.

116 fixed-clock, interpolation and render-group checks passed; 35 paid tactical-support checks passed. Evidence: `.build/v6-final-frame-tests.log` and `.build/v6-support-tests.log`.

18 terrain geometry checks passed on 17 October. They cover nonsequential building IDs, intact roof styles/positions, light/heavy damage materials, destroyed and mixed-damage roofs, exact repair/reset restoration, and agreement with neighborhood damage colors. Evidence: `scripts/test-terrain-mesh.sh`, `.build/v6-terrain-mesh-tests.log`.

At 1,400 live infected, optimized development-machine core benchmarks measured Settat median 4.269 ms/p95 5.387 ms, and Casablanca median 5.647 ms/p95 7.220 ms. These are core-only macOS measurements and exclude Simulator translation, drawing and audio. Evidence: `.build/v6-core-benchmark.log`.

## Renderer and simulator verification

Five native Metal output-check groups passed. They verify five evenly advancing interpolated positions at a million-second clock, preserved red/cyan role colors, zombie-only visibility, three reused meshes through population shrink/growth, safe pause, visible discs across street/city orthographic zoom at a camera height of 11,200 world units, and finite buffers for 160 ordinary/48 detailed people. Dots use four vertices and two triangles with a round fragment mask, one shared material and role color encoded per actor. Unused indices become zero-area triangles, preventing stale actors on SceneKit backends that cache draw ranges. Detailed people retain the three-pose body geometry. Evidence: `scripts/test-render.sh`, `.build/v6-redraw-render-tests.log` (final staging pool and timing diagnostics).

On 17 October, ten interaction flows passed with zero assertion failures in 351.048 seconds, covering Casablanca landmarks, drawn barricades, Humvee patrol/hold, landscape, paid reserves, planning/pause/speed/retry, Settat landmarks/herds/demolition, sound controls, street-scale troops/crowds and two-city saved upgrades. Evidence: `.build/V6PooledPhone15SimulatorResults.xcresult`, `.build/v6-final-pooled-ui-tests.log`. The suite as a whole returned an infrastructure failure because the Simulator runtime shut down during the aircraft flow, then Xcode rebooted it and completed the remaining ten. CoreSimulator logs identify the shutdown request; no Zomboys crash was established. The final redraw build then passed all four targeted flows in 164.701 seconds: aircraft weapons/live flybys, Casablanca landmarks/overview, paid reserves/paused gas/fire and Settat landmarks/herds/demolition. Evidence: `.build/V6FinalRedrawResults.xcresult`, `.build/v6-final-redraw-ui-tests.log`. All 11 distinct interaction flows have therefore passed across these runs; the initial interrupted suite is not represented as a clean full-suite result.

## Final physical-phone measurements

The signed Release build was installed and tested on the connected **iPhone 15 Pro, iOS 27.0.1**, on 17 October. Native 3× screen resolution, single-sample scene buffers, analytically smoothed discs and a requested 60 FPS were retained. Each profiling window lasts six seconds after a two-second warm-up. These operations use deterministic unsaved test state and no defense deployments: they measure crowded movement, not maximum simultaneous aircraft, explosions and audio. Visible counts exclude staged exterior actors; all terrain and landmarks remain enabled.

| Workload at 3× game speed | Active infected | Visible live actors | Measured seconds | Render callback FPS range | Update-start p95 range |
| --- | ---: | --- | ---: | --- | --- |
| Casablanca, whole city | 572 | 1,292 dots | 30.02 | 59.98–60.15 | 17.71–17.86 ms |
| Casablanca, whole city | 1,400 | 2,112–2,120 dots | 168.14 | 59.83–60.15 | 17.00–17.70 ms |
| Settat, following herd overhead | 648 | 95–156 dots | 30.00 | 59.99–60.14 | 17.20–17.43 ms |
| Settat, following herd overhead | 1,400 | 118–214 dots | 24.02 | 59.84–60.14 | 17.16–17.36 ms |
| Settat, tilted herd view | 648 | Up to 154 bodies, or dots as density changes | 30.00 | 59.83–60.16 | 17.87–18.79 ms |
| Settat, tilted herd view | 1,400 | Up to 119 bodies, or dots as density changes | 12.00 | 59.99 | 17.17–18.62 ms |

Evidence: `.build/v6-phone-final-casablanca-3x.log`, `.build/v6-phone-final-settat-3x.log`, `.build/v6-phone-final-settat-3d.log`, aggregated in `.build/v6-phone-final-profile-summary.json`. Every recorded window reported `thermalState=0` (nominal) and Low Power Mode off. The longest crowded Casablanca segment contains 28 windows, about 2.8 minutes. This is not a battery-drain or surface-temperature measurement; the phone was connected by cable.

### Actual screen presentation

Instruments Game Performance recorded the final build **after 1,400 infected were confirmed active**, with approximately 718 civilians visible across Casablanca at 3× speed. Hardware surface swaps and Zomboys-labelled Direct-to-Display intervals independently establish **59.99 displayed FPS** in the retained sample: 404 displayed frames across 6.718 seconds, 16.670 ms median/p95 frame gaps, and no retained gap over 25 ms. Five complete one-second bins each contain 60 displayed frames. CPU-to-display latency was 48.07 ms median/48.72 ms p95, indicating about three frames of queue delay. Evidence: `.build/V6FinalCasablancaPhone1400.trace`, `.build/v6-phone-final-1400-presentation-summary.json` and its exported XML tables.

The trace reports **lost events**. Its figures describe the retained short interval, not every moment of the recording, sustained presentation, battery drain or the worst combat workload. An earlier retained 7.55-second Casablanca sample also showed 59.99 displayed FPS; the final 1,400-infected sample is the stronger workload evidence.

### Interpreting callback timing

`didRenderScene` measures the end of CPU encoding, not display presentation. On the phone, its approximately 32 ms p95 intervals often alternate with intervals below 5 ms, even while `updateAtTime` starts and supplied scene-clock deltas remain near 16.67 ms. The raw historical fields named `hitchesOver25ms`/`hitchesOver50ms` count those completion intervals; they must not be read as displayed-frame drops. The independent hardware trace above resolves that distinction. Both callback timing series remain in the logs instead of replacing the earlier measurements.

### Simulator investigation

This Intel Mac/Intel UHD Graphics 630 produced variable whole-city rates during investigation. Early complete disc-renderer runs measured roughly 15–19 callback FPS; same-build runs after restarting the Simulator measured roughly 38–47 FPS. Ablations omitting crowds, landmarks or terrain were similarly host-sensitive and did not identify a single dominant cost. They are diagnostic omissions, not final game configurations. Final performance conclusions use the physical-phone evidence above; no stable 60 FPS Simulator claim is made.

The discarded one-vertex point prototype exposed an empty material-group bug and poor visible-herd timing. The investigation also uncovered on-demand rendering, which left custom GPU interpolation without intervening frames. Earlier point-prototype profiles do not validate the final renderer. The shipped triangle-disc path batches role colors in one draw, explicitly draws continuously during active play, and avoids redundant explicit redraws during that playback.

The app was finally relaunched on the phone without test/profile arguments, leaving Settat in planning mode. Test progression does not overwrite normal saved progress. Evidence: `.build/v6-phone-normal-final-launch.log`.

The trailer does not expose the source game's complete rules, assets or internal animation implementation, so exact parity across hidden mechanics cannot be established from that clip.
