#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DESTINATION="${BUILD_DESTINATION:-generic/platform=iOS Simulator}"

xcodebuild \
  -project "$PROJECT_ROOT/Zomboys.xcodeproj" \
  -scheme Zomboys \
  -configuration Debug \
  -destination "$BUILD_DESTINATION" \
  -derivedDataPath "$PROJECT_ROOT/.build/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build
