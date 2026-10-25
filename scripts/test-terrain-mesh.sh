#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$PROJECT_ROOT/.build"
python3 - "$PROJECT_ROOT" <<'PY'
from pathlib import Path
import re
import sys
root = Path(sys.argv[1])
# SceneKit vectors use CGFloat on macOS and Float on iOS. Compile the shipped
# value-only mesh builders with only those platform component conversions.
geometry = (root / 'Zomboys/UI/TacticalSceneGeometry.swift').read_text().split('@MainActor\nenum CityModels')[0]
geometry = re.sub(r'\bFloat\(', 'CGFloat(', geometry.replace('import UIKit', 'import AppKit'))
mesher = re.sub(r'\bFloat\(', 'CGFloat(', (root / 'Zomboys/UI/TacticalBuildingMesher.swift').read_text())
(root / '.build/TerrainPlatformGeometry.swift').write_text(geometry)
(root / '.build/TerrainPlatformMesher.swift').write_text(mesher)
PY
swiftc -O -whole-module-optimization -module-cache-path "$PROJECT_ROOT/.build/ModuleCache" \
  "$PROJECT_ROOT/Zomboys/Core/GameTypes.swift" \
  "$PROJECT_ROOT/Zomboys/Core/CityMap.swift" \
  "$PROJECT_ROOT/.build/TerrainPlatformGeometry.swift" \
  "$PROJECT_ROOT/.build/TerrainPlatformMesher.swift" \
  "$PROJECT_ROOT/Tests/TerrainMeshTests.swift" \
  -o "$PROJECT_ROOT/.build/terrain-mesh-tests"
"$PROJECT_ROOT/.build/terrain-mesh-tests"
