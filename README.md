# Drill Sergeant

Drill sergeant that watches your screen and shouts at you when off task.

Drill Sergeant lives in your MacBook notch. It watches your screen and calls out slacking until
you get back to work.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/evanhu1/drill-sergeant/main/install.sh | bash
```

Follow the chat bubble after the app opens. The installer sets up Ollama and downloads the local
vision model.

## How it works

Every 10 minutes, Drill Sergeant captures the current screen and active window, then asks a local
Ollama vision model whether you're working or slacking off. Its notch eyes move between idle,
watching, angry, and happy states. When it catches a distraction, it checks again every 30 seconds
until the distraction is gone.

Nothing leaves your Mac. Screenshots and prompts are processed by Ollama on your machine.

On Macs with 8 GB of memory, the app keeps the same `qwen3-vl:8b` model but automatically uses a
4K context, 960-pixel screenshots, four-message history, and unloads the model after each complete
decision. The installer also enables Ollama Flash Attention, Q4 KV-cache quantization, one parallel
request, and one loaded model. If Ollama was already running during installation, restart it once
for those server settings to take effect. These Ollama settings are global for the current login
session.

## Requirements

- Apple Silicon Mac
- macOS 14 Sonoma or newer
- Xcode Command Line Tools
- Homebrew
- Ollama 0.12 or newer

## Development

```bash
Scripts/run.sh
swift test
```

Use `Scripts/run.sh --reset` to restart onboarding. Development overrides are `DS_MODEL`,
`DS_INTERVAL_MINUTES`, `DS_OLLAMA_URL`, and `DS_RESET_ONBOARDING=1`.

To apply the low-memory Ollama server settings manually, run the following and restart Ollama:

```bash
launchctl setenv OLLAMA_FLASH_ATTENTION 1
launchctl setenv OLLAMA_KV_CACHE_TYPE q4_0
launchctl setenv OLLAMA_NUM_PARALLEL 1
launchctl setenv OLLAMA_MAX_LOADED_MODELS 1
```

## Uninstall

Quit Drill Sergeant, then remove the app and its model:

```bash
rm -rf "/Applications/Drill Sergeant.app"
ollama rm qwen3-vl:8b
```
