#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$PROJECT_ROOT/.build"
swiftc -O -whole-module-optimization -module-cache-path "$PROJECT_ROOT/.build/ModuleCache" \
  "$PROJECT_ROOT"/Zomboys/Core/*.swift \
  "$PROJECT_ROOT/Tests/SupportTests.swift" \
  -o "$PROJECT_ROOT/.build/support-tests"
"$PROJECT_ROOT/.build/support-tests"
