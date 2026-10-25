# V5 device profile

On 11 October 2026, a signed Release build ran Settat on a physical iPhone 15 Pro (A17 Pro, iOS 27.0.1). The unsaved test operation started automatically at 3× speed with no deployed defenses. This covered moving civilians, exterior herds, crowd routing and the default district camera. It did not cover simultaneous artillery, aircraft and close-up combat effects.

The app console reported a 20 FPS target, a 1.5 render scale and thermal state 0 throughout this short run. It reached the 1,400 active-zombie cap while retaining additional herd members as staged dots. These console lines lack individual wall-clock timestamps, so they cannot establish the actor count at every Instruments sample.

## Retained Instruments measurements

The local evidence is `.build/V5PhoneSettatGame.trace`, recorded with Instruments 16.0's Game Performance template. Although the command requested 40 seconds, the trace metadata reports **10.000 seconds retained** with `Windowed (5 seconds)` recording. Results below describe that retained interval only.

| Measurement | Observed result |
| --- | --- |
| App CPU running time | 3.7139 core-seconds in the retained 10 seconds |
| App CPU, seconds 1–10 | 39.26% of one CPU core on average; individual one-second buckets 35.65–40.82% |
| App main-thread CPU, seconds 1–10 | 3.2809 core-seconds across those 9 seconds |
| Displayed surface swaps | 20 per second in each of nine complete one-second buckets; 8 in the initial partial bucket |
| Metal current allocation | 13.98–14.28 MiB; last observed 14.16 MiB |
| Thermal state | Nominal across the retained 10 seconds |
| Potential hangs | No rows in the table configured to include unresponsiveness over 100 ms |

CPU totals sum `Running` intervals for the Zomboys process in `cpu-state`, clipping intervals to the measurement window. The first second has incomplete initial attribution and display observations, so the stable CPU and display figures use seconds 1–10. **100% CPU here means one fully occupied CPU core**, not all six cores. Device-wide system-load values and unrelated processes are excluded.

The display figures come from `displayed-surfaces-per-second` and are consistent with the app's capped cadence. They count displayed surface swaps, rather than proving a unique new simulation frame or measuring touch latency for every swap. Metal allocation is graphics allocation only: `virtual-memory` contains VM events, not a reliable total-resident-memory series in this export. No total-memory or GPU-utilization percentage is claimed.

The XML exports are `.build/v5-profile-{cpu-state,thread-state,displayed-surfaces-per-second,displayed-surfaces-interval,metal-application-intervals,metal-current-allocated-size,device-thermal-state-intervals,potential-hangs,virtual-memory}.xml`. Calculated CPU metrics are in `.build/v5-device-profile-metrics.json`; the app console is `.build/v5-phone-profile-console-unlocked.log`.

## Limits

This is a short, instrumented smoke profile without a comparable V4 device baseline. It verifies that the new workload limits run on the target phone and that the retained interval remained nominal; it does not establish long-session temperature, energy use, battery life or a percentage improvement over V4. Simulator checks verify gameplay and layout separately and cannot measure a phone's battery or heat.

The phone's test run ended and the normal app returned to planning. Later layout-only changes to the camera controls and HUD spacing passed targeted iPhone 15 Pro and SE simulator checks. They do not alter the profiled physics, rendering quality policy or active-zombie cap.
