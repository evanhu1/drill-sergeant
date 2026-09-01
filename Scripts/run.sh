#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_PATH="${PROJECT_DIR}/build/Drill Sergeant.app"

"${SCRIPT_DIR}/bundle.sh"
if [[ "${1:-}" == "--reset" ]]; then
    open -n --env DS_RESET_ONBOARDING=1 "${APP_PATH}"
else
    open -n "${APP_PATH}"
fi
