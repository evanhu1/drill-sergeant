#!/bin/bash
# Drill Sergeant installer.
#
#   curl -fsSL https://raw.githubusercontent.com/evanhu1/drill-sergeant/main/install.sh | bash
#
# Downloads a prebuilt app, sets up Ollama, and opens Drill Sergeant. Nothing else is
# required: no Homebrew, no Xcode, no compiler. The 6 GB vision model is not downloaded
# here — the app fetches it in the background while you grant Screen Recording, so the
# notch fills in seconds instead of minutes.
#
#   DS_FROM_SOURCE=1   build from source instead of downloading a release
#   DS_REF=<git ref>   source branch or tag to build (default: main)

set -euo pipefail

readonly REPOSITORY="evanhu1/drill-sergeant"
readonly REPOSITORY_URL="https://github.com/${REPOSITORY}.git"
readonly RELEASE_ASSET_URL="https://github.com/${REPOSITORY}/releases/latest/download/DrillSergeant.zip"
readonly OLLAMA_DOWNLOAD_URL="https://ollama.com/download/Ollama-darwin.zip"
readonly BUNDLE_IDENTIFIER="com.evanhu.drillsergeant"
readonly APP_NAME="Drill Sergeant.app"
readonly MINIMUM_MACOS_VERSION="14.0"
readonly LOW_MEMORY_LIMIT_BYTES=8589934592

work_dir=""
spinner_pid=""

# ---------------------------------------------------------------- presentation

if [[ -t 1 ]]; then
    readonly DIM=$'\033[2m'
    readonly BOLD=$'\033[1m'
    readonly GREEN=$'\033[32m'
    readonly RED=$'\033[31m'
    readonly RESET=$'\033[0m'
    readonly HIDE_CURSOR=$'\033[?25l'
    readonly SHOW_CURSOR=$'\033[?25h'
    readonly IS_TTY=1
else
    readonly DIM="" BOLD="" GREEN="" RED="" RESET="" HIDE_CURSOR="" SHOW_CURSOR=""
    readonly IS_TTY=0
fi

spin() {
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local index=0
    while true; do
        printf '\r  %s%s%s  %s' "${DIM}" "${frames[index]}" "${RESET}" "$1"
        index=$(((index + 1) % ${#frames[@]}))
        sleep 0.08
    done
}

# Starts a line that stays until `done_step` or `fail_step` replaces it.
step() {
    if ((IS_TTY)); then
        printf '%s' "${HIDE_CURSOR}"
        spin "$1" &
        spinner_pid=$!
    else
        printf '  ... %s\n' "$1"
    fi
}

stop_spinner() {
    if [[ -n "${spinner_pid}" ]]; then
        kill "${spinner_pid}" 2>/dev/null || true
        wait "${spinner_pid}" 2>/dev/null || true
        spinner_pid=""
        printf '\r\033[2K%s' "${SHOW_CURSOR}"
    fi
}

# Replaces the running step with a tick and an optional grey detail.
done_step() {
    stop_spinner
    local detail="${2:-}"
    if [[ -n "${detail}" ]]; then
        printf '  %s✓%s  %-34s%s%s%s\n' \
            "${GREEN}" "${RESET}" "$1" "${DIM}" "${detail}" "${RESET}"
    else
        printf '  %s✓%s  %s\n' "${GREEN}" "${RESET}" "$1"
    fi
}

note() {
    printf '  %s%s%s\n' "${DIM}" "$1" "${RESET}"
}

fail() {
    stop_spinner
    printf '  %s✗%s  %s\n\n' "${RED}" "${RESET}" "$1" >&2
    shift || true
    if [[ $# -gt 0 ]]; then
        local line
        for line in "$@"; do
            printf '     %s\n' "${line}" >&2
        done
        printf '\n' >&2
    fi
    exit 1
}

cleanup() {
    stop_spinner
    [[ -n "${work_dir}" && -d "${work_dir}" ]] && rm -rf "${work_dir}"
    printf '%s' "${SHOW_CURSOR}"
}

# ---------------------------------------------------------------------- checks

version_at_least() {
    local current="${1#v}"
    local required="${2#v}"
    local current_part
    local required_part

    [[ "${current}" =~ ^[0-9]+([.][0-9]+)*$ ]] || return 1
    [[ "${required}" =~ ^[0-9]+([.][0-9]+)*$ ]] || return 1

    while [[ -n "${current}" || -n "${required}" ]]; do
        current_part="${current%%.*}"
        required_part="${required%%.*}"
        [[ -n "${current_part}" ]] || current_part=0
        [[ -n "${required_part}" ]] || required_part=0

        if ((10#${current_part} > 10#${required_part})); then
            return 0
        fi
        if ((10#${current_part} < 10#${required_part})); then
            return 1
        fi

        if [[ "${current}" == *.* ]]; then
            current="${current#*.}"
        else
            current=""
        fi
        if [[ "${required}" == *.* ]]; then
            required="${required#*.}"
        else
            required=""
        fi
    done

    return 0
}

ollama_is_running() {
    curl -fsS --max-time 2 "http://127.0.0.1:11434/api/tags" >/dev/null 2>&1
}

ollama_app_path() {
    local candidate
    for candidate in "/Applications/Ollama.app" "${HOME}/Applications/Ollama.app"; do
        if [[ -d "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

# ----------------------------------------------------------------------- setup

# Ollama's own download works without Homebrew, so nothing has to be installed first.
install_ollama() {
    local archive="${work_dir}/Ollama-darwin.zip"
    local staging="${work_dir}/ollama"
    local destination="/Applications"

    curl -fsL --retry 3 --retry-delay 1 -o "${archive}" "${OLLAMA_DOWNLOAD_URL}" \
        2>/dev/null || return 1
    mkdir -p "${staging}"
    ditto -x -k "${archive}" "${staging}" 2>/dev/null || return 1
    [[ -d "${staging}/Ollama.app" ]] || return 1

    [[ -w "${destination}" ]] || destination="${HOME}/Applications"
    mkdir -p "${destination}"
    rm -rf "${destination}/Ollama.app"
    ditto "${staging}/Ollama.app" "${destination}/Ollama.app" 2>/dev/null || return 1
    xattr -dr com.apple.quarantine "${destination}/Ollama.app" 2>/dev/null || true
}

start_ollama() {
    local app_path
    if app_path="$(ollama_app_path)"; then
        open -a "${app_path}" 2>/dev/null || true
    elif command -v ollama >/dev/null 2>&1; then
        nohup ollama serve >/dev/null 2>&1 &
    fi

    local attempt
    for ((attempt = 1; attempt <= 60; attempt += 1)); do
        ollama_is_running && return 0
        sleep 0.5
    done
    return 1
}

# Runs the whole Ollama path in one background job so it overlaps the app download.
prepare_ollama() {
    local status_file="$1"
    {
        if ollama_is_running; then
            printf 'running\n' >"${status_file}"
            exit 0
        fi
        if ollama_app_path >/dev/null || command -v ollama >/dev/null 2>&1; then
            if start_ollama; then
                printf 'started\n' >"${status_file}"
            else
                printf 'unreachable\n' >"${status_file}"
            fi
            exit 0
        fi
        if ! install_ollama; then
            printf 'install-failed\n' >"${status_file}"
            exit 0
        fi
        if start_ollama; then
            printf 'installed\n' >"${status_file}"
        else
            printf 'unreachable\n' >"${status_file}"
        fi
    } &
    printf '%s\n' "$!"
}

# 8 GB Macs need Flash Attention and a quantized KV cache to hold the model at all.
configure_low_memory_ollama() {
    launchctl setenv OLLAMA_FLASH_ATTENTION 1 2>/dev/null || return 1
    launchctl setenv OLLAMA_KV_CACHE_TYPE q4_0 2>/dev/null || return 1
    launchctl setenv OLLAMA_NUM_PARALLEL 1 2>/dev/null || return 1
    launchctl setenv OLLAMA_MAX_LOADED_MODELS 1 2>/dev/null || return 1
}

# ------------------------------------------------------------------------- app

download_release() {
    local archive="${work_dir}/DrillSergeant.zip"
    local staging="${work_dir}/app"

    curl -fsL --retry 2 --retry-delay 1 -o "${archive}" "${RELEASE_ASSET_URL}" 2>/dev/null \
        || return 1
    mkdir -p "${staging}"
    ditto -x -k "${archive}" "${staging}" 2>/dev/null || return 1
    [[ -d "${staging}/${APP_NAME}" ]] || return 1
    printf '%s\n' "${staging}/${APP_NAME}"
}

build_from_source() {
    if ! xcode-select -p >/dev/null 2>&1; then
        xcode-select --install >/dev/null 2>&1 || true
        fail "Building from source needs the Xcode Command Line Tools" \
            "A macOS installer window should have opened. Finish it, then run this again." \
            "Or skip the build: leave DS_FROM_SOURCE unset to download a prebuilt app."
    fi

    local source_dir="${HOME}/.drill-sergeant/src"
    local ref="${DS_REF:-main}"
    if [[ -d "${source_dir}/.git" ]]; then
        git -C "${source_dir}" fetch --depth 1 origin "${ref}" >/dev/null 2>&1
        git -C "${source_dir}" checkout --force FETCH_HEAD >/dev/null 2>&1
    else
        mkdir -p "$(dirname "${source_dir}")"
        git clone --depth 1 --branch "${ref}" "${REPOSITORY_URL}" "${source_dir}" \
            >/dev/null 2>&1
    fi
    # Quiet on success, loud on failure: a build log is only useful when it breaks.
    local build_log="${work_dir}/build.log"
    if ! "${source_dir}/Scripts/bundle.sh" >"${build_log}" 2>&1; then
        stop_spinner
        cat "${build_log}" >&2
        fail "The build failed"
    fi
    printf '%s\n' "${source_dir}/build/${APP_NAME}"
}

code_hash() {
    codesign -dvvv "$1" 2>&1 | awk -F'=' '/^CDHash=/ {print $2; exit}'
}

app_version() {
    defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null || printf '?\n'
}

# Each build carries a different ad-hoc signature, and macOS pins the Screen Recording
# grant to the signature. A stale grant reads as allowed while capture quietly fails, so
# clear it whenever the code actually changed and let the app ask again.
reset_stale_screen_grant() {
    local installed="$1"
    local incoming="$2"
    [[ -d "${installed}" ]] || return 0
    [[ "$(code_hash "${installed}")" == "$(code_hash "${incoming}")" ]] && return 0
    tccutil reset ScreenCapture "${BUNDLE_IDENTIFIER}" >/dev/null 2>&1 || true
}

install_app() {
    local source_app="$1"
    local destination="/Applications"
    [[ -w "${destination}" ]] || destination="${HOME}/Applications"
    mkdir -p "${destination}"

    local installed="${destination}/${APP_NAME}"
    reset_stale_screen_grant "${installed}" "${source_app}"

    pkill -f "${APP_NAME}/Contents/MacOS/DrillSergeant" 2>/dev/null || true
    rm -rf "${installed}"
    ditto "${source_app}" "${installed}" 2>/dev/null
    xattr -dr com.apple.quarantine "${installed}" 2>/dev/null || true
    printf '%s\n' "${installed}"
}

# ------------------------------------------------------------------------ main

main() {
    trap cleanup EXIT INT TERM
    work_dir="$(mktemp -d)"

    printf '\n  %sDrill Sergeant%s\n\n' "${BOLD}" "${RESET}"

    if [[ "$(uname -m)" != "arm64" ]]; then
        fail "Drill Sergeant needs an Apple Silicon Mac" \
            "The local vision model has no Intel build."
    fi
    local macos_version
    macos_version="$(sw_vers -productVersion)"
    if ! version_at_least "${macos_version}" "${MINIMUM_MACOS_VERSION}"; then
        fail "Drill Sergeant needs macOS 14 or newer (this Mac runs ${macos_version})"
    fi

    local memory_bytes
    local low_memory=0
    memory_bytes="$(sysctl -n hw.memsize 2>/dev/null || printf '0')"
    if [[ "${memory_bytes}" =~ ^[0-9]+$ ]] && ((memory_bytes <= LOW_MEMORY_LIMIT_BYTES)); then
        low_memory=1
    fi
    local memory_note
    memory_note="$(((memory_bytes + 1073741823) / 1073741824)) GB"
    done_step "Apple Silicon, macOS ${macos_version}" "${memory_note}"

    local ollama_was_running=0
    ollama_is_running && ollama_was_running=1
    ((low_memory)) && configure_low_memory_ollama || true

    # Ollama is ~200 MB. Fetch it while the app downloads rather than after.
    local ollama_status_file="${work_dir}/ollama.status"
    local ollama_pid
    ollama_pid="$(prepare_ollama "${ollama_status_file}")"

    local source_app=""
    if [[ "${DS_FROM_SOURCE:-0}" == "1" ]]; then
        step "Building Drill Sergeant from source"
        source_app="$(build_from_source)"
        done_step "Built Drill Sergeant" "$(app_version "${source_app}")"
    else
        step "Downloading Drill Sergeant"
        if source_app="$(download_release)"; then
            done_step "Downloaded Drill Sergeant" "$(app_version "${source_app}")"
        else
            stop_spinner
            step "No release yet — building from source"
            source_app="$(build_from_source)"
            done_step "Built Drill Sergeant" "$(app_version "${source_app}")"
        fi
    fi

    step "Installing"
    local installed_app
    installed_app="$(install_app "${source_app}")"
    done_step "Installed" "${installed_app/#${HOME}/~}"

    step "Setting up Ollama"
    wait "${ollama_pid}" 2>/dev/null || true
    local ollama_status
    ollama_status="$(cat "${ollama_status_file}" 2>/dev/null || printf 'unreachable')"
    case "${ollama_status}" in
        running) done_step "Ollama running" "already up" ;;
        started) done_step "Ollama running" "started for you" ;;
        installed) done_step "Ollama running" "installed and started" ;;
        install-failed)
            done_step "Ollama not installed"
            note "Install it from https://ollama.com/download — the app waits for it."
            ;;
        *)
            done_step "Ollama not responding"
            note "Open Ollama once; the app connects on its own."
            ;;
    esac

    open -n "${installed_app}"

    printf '\n  %sHe is in your notch.%s Follow the bubble.\n' "${BOLD}" "${RESET}"
    note "The 6 GB vision model downloads in the background while you grant permission."
    if ((low_memory && ollama_was_running)); then
        printf '\n'
        note "8 GB Mac: quit and reopen Ollama once to apply its low-memory settings."
    fi
    printf '\n'
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
