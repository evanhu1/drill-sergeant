# Drill Sergeant

Drill sergeant that watches your screen and shouts at you when you're off task.

Drill Sergeant lives in your MacBook notch. It watches your screen and calls out slacking until
you get back to work.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/evanhu1/drill-sergeant/main/install.sh | bash
```

He's in your notch in about fifteen seconds. Click the bubble once to grant Screen Recording,
and that's the whole setup. The 6 GB vision model downloads in the background while you do it,
and the bubble shows the progress.

You need nothing installed first — no Homebrew, no Xcode, no compiler. The installer downloads
a prebuilt app, installs Ollama if you don't have it, and starts everything.

Run the same command again to update.

## How it works

Every 10 minutes, Drill Sergeant captures the current screen and active window, then asks a local
Ollama vision model whether you're working or slacking off. Its notch eyes move between idle,
watching, angry, and happy states. When it catches a distraction, it checks again every 30 seconds
until the distraction is gone.

Nothing leaves your Mac. Screenshots and prompts are processed by Ollama on your machine.

Drill Sergeant opens at login once you finish setup.

On Macs with 8 GB of memory, the app keeps the same `qwen3-vl:8b-instruct` model but automatically uses a
4K context, 960-pixel screenshots, four-message history, and unloads the model after each complete
decision. The installer also enables Ollama Flash Attention, Q4 KV-cache quantization, one parallel
request, and one loaded model. If Ollama was already running during installation, restart it once
for those server settings to take effect. These Ollama settings are global for the current login
session.

## Requirements

- Apple Silicon Mac
- macOS 14 Sonoma or newer

## Development

```bash
Scripts/run.sh
swift test
```

Use `Scripts/run.sh --reset` to restart onboarding. Development overrides are `DS_MODEL`,
`DS_INTERVAL_MINUTES`, `DS_OLLAMA_URL`, and `DS_RESET_ONBOARDING=1`.

To measure how long a check takes, build the app and run it with `--benchmark [runs]`. It times
the real pipeline — capture, model call, output processing — and reports the prompt and output
token counts behind the model call. `--dump-payload` prints the exact system prompt and tool
schema, for experimenting against the real request outside the app.

```bash
Scripts/bundle.sh && "build/Drill Sergeant.app/Contents/MacOS/DrillSergeant" --benchmark 6
```

The model must be an `-instruct` build. The plain `qwen3-vl:8b` tag is the *thinking* build: it
spends hundreds of output tokens per check on reasoning nobody reads, which dominated latency and
produced 30-second checks. Ollama rejects a `think` option outright on instruct builds, so the app
sends none.

`install.sh` downloads the app from the latest GitHub release, which
`.github/workflows/release.yml` publishes on every push to `main`. Set `DS_FROM_SOURCE=1` to build
locally instead, and `DS_REF=<branch>` to pick the branch.

The app is signed ad hoc, so its Screen Recording grant is pinned to one exact build. The
installer clears a stale grant when the code changes; `Scripts/run.sh` does the same for local
rebuilds.

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
rm -rf ~/"Applications/Drill Sergeant.app"
ollama rm qwen3-vl:8b-instruct
```
