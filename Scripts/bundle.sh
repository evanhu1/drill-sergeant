#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_PATH="${PROJECT_DIR}/build/Drill Sergeant.app"
CONTENTS_PATH="${APP_PATH}/Contents"

cd "${PROJECT_DIR}"
swift build -c release --arch arm64 ${SWIFT_BUILD_FLAGS:-}

rm -rf "${APP_PATH}"
mkdir -p "${CONTENTS_PATH}/MacOS" "${CONTENTS_PATH}/Resources"
cp ".build/arm64-apple-macosx/release/DrillSergeant" "${CONTENTS_PATH}/MacOS/DrillSergeant"
cp "Scripts/Info.plist" "${CONTENTS_PATH}/Info.plist"
printf 'APPL????' > "${CONTENTS_PATH}/PkgInfo"
# --deep is a verification flag, not a signing one; Apple advises against signing with it.
codesign --force --sign - "${APP_PATH}"

printf '%s\n' "${APP_PATH}"
