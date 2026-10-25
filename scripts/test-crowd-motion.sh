#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$PROJECT_ROOT/.build"
swiftc -O "$PROJECT_ROOT/Zomboys/Core/CrowdMotion.swift" "$PROJECT_ROOT/Tests/CrowdMotionTests.swift" -o "$PROJECT_ROOT/.build/crowd-motion-tests"
"$PROJECT_ROOT/.build/crowd-motion-tests"
