#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$PROJECT_ROOT/.build"
TACTICS_SOURCES="$(mktemp -d "$PROJECT_ROOT/.build/tactics-sources.XXXXXX")"
trap 'rm -rf "$TACTICS_SOURCES"' EXIT
cp "$PROJECT_ROOT"/Zomboys/Core/*.swift "$TACTICS_SOURCES/"
swiftc -O -whole-module-optimization -D TACTICAL_TESTS \
  -module-cache-path "$PROJECT_ROOT/.build/ModuleCache" \
  "$TACTICS_SOURCES"/*.swift \
  "$PROJECT_ROOT/Tests/TacticalPlanningTests.swift" \
  -o "$PROJECT_ROOT/.build/tactical-tests"
"$PROJECT_ROOT/.build/tactical-tests"
