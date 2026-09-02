#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_PATH="${PROJECT_DIR}/build/Drill Sergeant.app"

BUNDLE_ID="com.evanhu.drillsergeant"

"${SCRIPT_DIR}/bundle.sh"

# Each rebuild changes the code hash, and the ad-hoc signature pins the Screen Recording grant to
# that hash, so the old grant no longer applies. Left alone macOS keeps showing the app as allowed
# while capture quietly fails. Clearing it means the prompt comes back instead.
tccutil reset ScreenCapture "${BUNDLE_ID}" >/dev/null 2>&1 || true

if [[ "${1:-}" == "--reset" ]]; then
    open -n --env DS_RESET_ONBOARDING=1 "${APP_PATH}"
else
    open -n "${APP_PATH}"
fi
