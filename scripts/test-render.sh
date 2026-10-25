#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$PROJECT_ROOT/.build"
python3 - "$PROJECT_ROOT" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
geometry=(root/'Zomboys/UI/TacticalSceneGeometry.swift').read_text().split('@MainActor\nenum CityModels')[0].replace('import UIKit','import AppKit').replace('Float(', 'CGFloat(')
shim='''@MainActor enum CityModels {
static func material(_ hex:UInt32,emission:UInt32?=nil,alpha:CGFloat=1) -> SCNMaterial {
let material=SCNMaterial(); material.diffuse.contents=NSColor(deviceRed:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255,alpha:alpha); return material
}
}\n'''
# SceneKit uses CGFloat vector components on macOS and Float on iOS.
# Only these platform component conversions differ from the shipped sources.
humans=(root/'Zomboys/UI/TacticalHumanModels.swift').read_text().replace('import UIKit','import AppKit').replace('Float(', 'CGFloat(')
for vector in ['b','c']:
    for component in ['x','y','z']:
        humans=humans.replace(f'{vector}.{component}-a.{component}',f'Float({vector}.{component}-a.{component})')
crowd=(root/'Zomboys/UI/TacticalAnimatedCrowd.swift').read_text().replace('*fraction','*CGFloat(fraction)').replace('*blend','*CGFloat(blend)')
for vector in ['point','normal']:
    for component in ['x','y','z']:
        crowd=crowd.replace(f'{vector}.{component}',f'Float({vector}.{component})')
(root/'.build/CrowdPlatformBuffers.swift').write_text(crowd)
(root/'.build/CrowdPlatformSupport.swift').write_text(geometry+shim+humans)
PY
swiftc -O -whole-module-optimization -parse-as-library -module-cache-path "$PROJECT_ROOT/.build/ModuleCache" \
 "$PROJECT_ROOT/.build/CrowdPlatformSupport.swift" \
 "$PROJECT_ROOT/Zomboys/Core/CrowdMotion.swift" \
 "$PROJECT_ROOT/Zomboys/Core/FrameInterpolation.swift" \
 "$PROJECT_ROOT/.build/CrowdPlatformBuffers.swift" \
 "$PROJECT_ROOT/Zomboys/UI/TacticalFrameMetrics.swift" \
 "$PROJECT_ROOT/Tests/CrowdRenderChecks.swift" -o "$PROJECT_ROOT/.build/crowd-render-checks"
cd "$PROJECT_ROOT"
"$PROJECT_ROOT/.build/crowd-render-checks"
