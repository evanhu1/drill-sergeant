#!/bin/bash
set -euo pipefail

readonly REPOSITORY_URL="https://github.com/evanhu1/drill-sergeant.git"
readonly MINIMUM_MACOS_VERSION="14.0"
readonly MINIMUM_OLLAMA_VERSION="0.12"

progress() {
    printf '==> %s\n' "$1"
}

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

ollama_version() {
    ollama --version 2>/dev/null \
        | grep -Eo '[0-9]+([.][0-9]+)+' \
        | head -n 1
}

ollama_is_running() {
    curl -fsS "http://127.0.0.1:11434/api/tags" >/dev/null 2>&1
}

checkout_path() {
    local script_source="${BASH_SOURCE[0]:-}"
    local script_dir=""

    if [[ -n "${script_source}" && -f "${script_source}" ]]; then
        script_dir="$(cd "$(dirname "${script_source}")" && pwd)"
    fi

    if [[ -n "${script_dir}" && -f "${script_dir}/Scripts/bundle.sh" ]]; then
        printf '%s\n' "${script_dir}"
    elif [[ -f "${PWD}/Scripts/bundle.sh" ]]; then
        printf '%s\n' "${PWD}"
    fi
}

main() {
    local architecture
    local macos_version
    local current_ollama_version
    local model
    local source_dir
    local local_checkout
    local install_root
    local app_source
    local ollama_ready=0
    local attempt

    progress "Checking Mac requirements"
    architecture="$(uname -m)"
    if [[ "${architecture}" != "arm64" ]]; then
        printf 'Drill Sergeant requires an Apple Silicon Mac (arm64).\n' >&2
        exit 1
    fi

    macos_version="$(sw_vers -productVersion)"
    if ! version_at_least "${macos_version}" "${MINIMUM_MACOS_VERSION}"; then
        printf 'Drill Sergeant requires macOS 14 or newer. Found macOS %s.\n' \
            "${macos_version}" >&2
        exit 1
    fi

    progress "Checking Xcode Command Line Tools"
    if ! xcode-select -p >/dev/null 2>&1; then
        xcode-select --install >/dev/null 2>&1 || true
        printf 'Install the Xcode Command Line Tools, then run this installer again.\n' >&2
        exit 1
    fi

    progress "Checking Homebrew"
    if ! command -v brew >/dev/null 2>&1; then
        printf '%s\n' 'Homebrew is required. Install it, then run this installer again:' >&2
        printf '%s\n' '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' >&2
        exit 1
    fi

    progress "Checking Ollama"
    if ! command -v ollama >/dev/null 2>&1; then
        brew install --cask ollama
        hash -r
    else
        current_ollama_version="$(ollama_version || true)"
        if [[ -z "${current_ollama_version}" ]] \
            || ! version_at_least "${current_ollama_version}" "${MINIMUM_OLLAMA_VERSION}"; then
            brew upgrade --cask ollama || brew upgrade ollama || true
            hash -r
            current_ollama_version="$(ollama_version || true)"
            if [[ -z "${current_ollama_version}" ]] \
                || ! version_at_least "${current_ollama_version}" "${MINIMUM_OLLAMA_VERSION}"; then
                printf '%s\n' 'Update Ollama from https://ollama.com/download' >&2
            fi
        fi
    fi

    progress "Starting Ollama"
    if ! ollama_is_running; then
        if [[ -d "/Applications/Ollama.app" || -d "${HOME}/Applications/Ollama.app" ]]; then
            open -a Ollama
        else
            nohup ollama serve >/dev/null 2>&1 &
        fi
    fi

    for ((attempt = 1; attempt <= 30; attempt += 1)); do
        if ollama_is_running; then
            ollama_ready=1
            break
        fi
        sleep 1
    done
    if [[ "${ollama_ready}" -ne 1 ]]; then
        printf 'Ollama did not start within 30 seconds. Start Ollama and rerun this installer.\n' >&2
        exit 1
    fi

    model="${DS_MODEL:-qwen3-vl:8b}"
    progress "Downloading local model ${model}"
    ollama pull "${model}"

    progress "Preparing Drill Sergeant source"
    local_checkout="$(checkout_path)"
    if [[ -n "${local_checkout}" ]]; then
        source_dir="${local_checkout}"
    else
        install_root="${HOME}/.drill-sergeant"
        source_dir="${install_root}/src"
        if [[ -d "${source_dir}/.git" ]]; then
            git -C "${source_dir}" pull --ff-only
        else
            mkdir -p "${install_root}"
            git clone "${REPOSITORY_URL}" "${source_dir}"
        fi
    fi

    progress "Building Drill Sergeant"
    "${source_dir}/Scripts/bundle.sh"

    progress "Installing Drill Sergeant in /Applications"
    app_source="${source_dir}/build/Drill Sergeant.app"
    rm -rf "/Applications/Drill Sergeant.app"
    cp -R "${app_source}" "/Applications/Drill Sergeant.app"

    progress "Launching Drill Sergeant"
    open -n "/Applications/Drill Sergeant.app"
    progress "Drill Sergeant is in your notch. Follow the chat bubble."
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
