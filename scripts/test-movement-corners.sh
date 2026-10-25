#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$PROJECT_ROOT/.build"
swiftc -O -whole-module-optimization -D MOVEMENT_TESTS -module-cache-path "$PROJECT_ROOT/.build/ModuleCache" \
  "$PROJECT_ROOT"/Zomboys/Core/*.swift "$PROJECT_ROOT/Tests/MovementCornerTests.swift" \
  -o "$PROJECT_ROOT/.build/movement-corner-tests"
"$PROJECT_ROOT/.build/movement-corner-tests"
