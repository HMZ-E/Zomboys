# V8 movement and animation application

Date: 25 October 2026, Africa/Casablanca. This applies the motion/readability findings in [ReferenceChannelStudy.md](ReferenceChannelStudy.md) to the native app. Public footage is the visual reference; the new motion and geometry remain original implementations.

## Applied changes

| Finding / visible problem | Applied behavior |
| --- | --- |
| Continuous, branching crowd streams | Nearby visible prey can still split a herd. Local alignment, spacing and mild pack cohesion now operate with a slower 5.6 m/s nominal cruise, individual variation and shared low-frequency surges. Forward acceleration is tracked separately from lateral movement. |
| Abrupt starts and sharp turning | Infected and civilian pace use bounded acceleration/braking. Infected reduce pace into bends; headings use a bounded short-arc turn. Sideways lane changes are limited. Existing road, building, wall and gate checks still apply. |
| Bodies stopping beside their destination | Personal lanes contract near the actual destination. A newly exposed Casablanca corner failure was fixed through convergence rather than relaxing its permanent-stall assertion. |
| Walk/run animation snapping | Idle, walking and running poses blend continuously with physical speed. Running lengthens the distance-driven gait cycle rather than simply accelerating a short walk. |
| Stiff or synchronized figures | Authored stance/swing phases ground the feet and lift/fold the knees during swing. Running arms pump with bent elbows; slower infected retain a reaching posture. Stable individual phase offsets desynchronize neighboring people. |
| Feet tilting through the ground | Lean is applied through the hips/torso while feet retain their ground clearance. Actual vertex checks cover all roles and gait phases. |
| Dense close-ups reverting entirely to dots | Near-camera people remain as bodies inside a shared 160-person budget, with stable retention and dots for the remaining crowd. The earlier all-or-nothing switch above 160 visible people is removed. |
| Waiting exterior masses appearing only as static markers | Visible staged members can occupy the same close-body budget and use individual idle phases. Far members remain batched dots. Activation inherits idle gait phase and actual position. |
| Planning information after slower movement | Arrival travel estimates use the same nominal infected cruise value as locomotion. Random preparation windows and finite exterior columns remain. |

Casablanca/Settat, 1,400 active infected, the separate 80-crew budget, native resolution, interpolation, kill income, gates, explosive collateral, progression and the AC-130/B-2/A-10 roster remain in place. No ambient loop or civilian/zombie voices were added.

## Verification

| Check | Result | Evidence |
| --- | --- | --- |
| Full gameplay regression | 327 passed | `.build/v8-core-verified.log` |
| Local perception, pursuit, movement and acceleration | 36 passed | `.build/v8-movement-release-verified.log` |
| Real street corners, including previously stuck bodies | 76 passed | `.build/v8-corners-final.log` |
| Gait continuity, physical acceleration and dense-detail selection | 1,668 property checks passed | `.build/v8-locomotion-verified.log` |
| Actual Metal and human geometry | Eight groups passed | `.build/v8-render-verified.log` |
| Native Simulator interaction | Both selected flows passed, 0 failures | `.build/v8-motion-ui.log`, `.build/V8MotionUIResults.xcresult` |
| Signed iPhone Release | Build, signature verification and installation succeeded; normal launch succeeded | `.build/v8-phone-verified-build.log`, `.build/v8-signature.log`, `.build/v8-phone-install.json`, `.build/v8-phone-normal-launch.json` |

The full paid Siege strategies saved **360/360 civilians in Settat**, with 4,071 kills at 336 simulated seconds, and **717/720 in Casablanca**, with 7,671 kills at 617 seconds. Replay rewards, civilian accounting, finite herds and ordinary paid orders passed. The suite took 612.52 wall seconds on the Mac while other development work ran; that is not an FPS or speedup benchmark.

The actual vertex tests cross idle/walk/run boundaries for civilians, infected, soldiers and snipers. Vertex topology stays consistent, including sniper scopes, and tiny speed changes keep the maximum coordinate change below 1.5 cm. Another check sweeps 16 gait phases at three speeds for all four roles and confirms that no body geometry falls below the street base. The 700-person detail fixture retains exactly 160 bodies, with more than 150 retained under a small camera change.

Native interaction flows cover the dense incoming herd, camera zoom, pause retaining poses, return to overhead dots, Humvee/squad/sniper street scale and visible moving crowds. See the [dense herd capture](../Screenshots/iPhone15ProSimulator-v8-dense-herd.png), [paused poses](../Screenshots/iPhone15ProSimulator-v8-paused-poses.png) and [overview](../Screenshots/iPhone15ProSimulator-v8-city-dots.png). These are Simulator captures.

## Visual evidence and limits

[Herd motion preview](../Screenshots/Zomboys-v8-herd-motion.mp4) and [dense staged herd](../Screenshots/Zomboys-v8-dense-herd.mp4) show actual native Simulator output. [Earlier movement](../Screenshots/Zomboys-v8-before-herd.mp4) was recorded from the pre-update app. These recordings support a qualitative review of gait, phase variation and crowd presentation; they are not synchronized reproductions of the same reference-game scene or proof of exact animation equivalence.

The final Release Simulator capture log recorded **27.81–40.26 render callbacks/s** in close herd views on this Intel Mac, with up to 160 bodies and mixed body/dot windows. Stutter remains in that Simulator workload; no 60-FPS result is claimed for this pass. The final recording was readable and frame extraction succeeded, although the recording command exceeded its initial shutdown wait. Simulator frame measurements reflect this Mac and presentation/workload conditions. The user chose to finish with previously collected phone measurements; **V7 phone FPS must not be presented as a fresh V8 measurement**. V8 close-up physical-phone FPS, sustained heat and battery drain are unmeasured. The iPhone app was installed and normally launched without running a further phone benchmark.

The pass applies the studied motion principles and addresses the specific rendering/animation defects above. A complete quantitative match to every reference sequence, proprietary steering weights or original animation data is not claimed.
