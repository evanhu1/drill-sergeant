# Drill Sergeant — V1 Specification

> Tagline: **Drill sergeant that watches your screen and shouts at you when off task.**

A macOS menu-bar-less companion that lives in the MacBook notch. It has expressive eyes.
Every 10 minutes it screenshots the screen, reads the active window, and asks a **local**
vision LLM (Ollama) whether the user is on task. If not, it gets angry and shouts via a
message bubble until the user closes the distraction. Nothing leaves the machine.

This document is the single source of truth. Every module lists its **public interface**.
Implement exactly these signatures so that modules built in parallel fit together.

---

## 1. Platform and stack

| Item | Decision |
|---|---|
| OS | macOS 14.0+ (Sonoma), Apple Silicon |
| Language | Swift 5.9+ (`swift-tools-version: 5.9`), Swift Package Manager, **no third-party deps** |
| UI | AppKit windows (`NSPanel`) hosting SwiftUI views (`NSHostingView`) |
| Concurrency | Swift Concurrency (`async/await`, `@MainActor`) |
| LLM | Ollama HTTP API at `http://127.0.0.1:11434`, default model `qwen3-vl:8b` |
| Screenshot | ScreenCaptureKit (`SCScreenshotManager`) |
| Persistence | `UserDefaults` (suite: standard), key prefix `ds.` |
| Bundle ID | `com.evanhu.drillsergeant` |
| App name | `Drill Sergeant`, executable `DrillSergeant` |
| Dock icon | none (`LSUIElement = true`) |
| Tests | XCTest, target `DrillSergeantTests`, run with `swift test` |

Package layout:

```
Package.swift
Sources/DrillSergeant/
  App/            main.swift, AppDelegate.swift, AppCoordinator.swift
  Notch/          NotchGeometry.swift, NotchWindow.swift, EyesView.swift, CursorTracker.swift
  Companion/      CompanionState.swift, Scheduler.swift, Clock.swift
  Capture/        ScreenCapture.swift, ActiveWindowInfo.swift, ScreenPermission.swift
  LLM/            OllamaClient.swift, Decision.swift, PromptBuilder.swift, Conversation.swift
  Chat/           BubbleWindow.swift, BubbleView.swift, ChatPresenter.swift
  Onboarding/     OnboardingFlow.swift
  Settings/       Settings.swift
  Util/           Log.swift
Tests/DrillSergeantTests/
Scripts/          bundle.sh, Info.plist, run.sh
install.sh
README.md
docs/SPEC.md
```

Because the executable target contains all code, tests use `@testable import DrillSergeant`.
To make the executable target testable, keep `main.swift` minimal (it only calls
`AppMain.run()`), and keep all logic in other files.

---

## 2. Companion state machine

```swift
enum CompanionState: String, Codable, Equatable {
    case idle      // eyes relaxed, occasional blink
    case watching  // eyes follow the cursor; pre-roll before a check and during processing
    case angry     // caught off task; eyes follow cursor with angry brows; polls every 30s
    case happy     // shown for 30s after leaving angry; then idle
}
```

Transitions (Scheduler drives these):

| From | Event | To |
|---|---|---|
| idle | 60s before next check | watching |
| watching | capture + LLM done, decision `set_idle` | idle (next check in `intervalMinutes`) |
| watching | decision `set_angry` | angry |
| watching | decision `snooze(n)` | idle (next check in `n` minutes) |
| angry | 30s poll, decision `set_angry` | angry (stay) |
| angry | 30s poll or reply, decision `set_idle` | happy |
| angry | decision `snooze(n)` | happy (then idle, next check in `n` minutes) |
| happy | 30s elapsed | idle |
| any | user reply produces a decision | same rules as the row for the current state (idle/happy treated like watching) |
| any | "Check now" menu item | watching (no pre-roll), immediate capture |

Rules:
- `intervalMinutes` default 10. The timer always resets after a decision.
- Entering `happy` from `angry` also resets the timer to `intervalMinutes` (or the snooze length).
- The 60s pre-roll `watching` state is skipped when the remaining time is already under 60s.
- The angry poll: every 30s capture + LLM. It never enters `watching`; eyes already track the cursor.

### 2.1 Scheduler interface

Testable, injectable clock, no UI. Lives on the main actor.

```swift
protocol Clock {
    var now: Date { get }
    /// Schedule `block` after `seconds`. Returns a cancel token.
    func after(_ seconds: TimeInterval, _ block: @escaping @MainActor () -> Void) -> CancelToken
}
final class CancelToken { func cancel() }
final class SystemClock: Clock   // uses Timer/DispatchQueue.main
final class TestClock: Clock     // manual `advance(by:)`, used by tests

@MainActor
protocol SchedulerDelegate: AnyObject {
    /// Called on every state change.
    func scheduler(_ s: Scheduler, didChange state: CompanionState, from old: CompanionState)
    /// Ask the delegate to run a check (capture + LLM). The delegate calls `s.apply(decision)`.
    func schedulerRequestsCheck(_ s: Scheduler, reason: CheckReason)
}

enum CheckReason { case scheduled, angryPoll, manual, onboarding }

@MainActor
final class Scheduler {
    init(clock: Clock, intervalMinutes: Int = 10, preRollSeconds: TimeInterval = 60,
         angryPollSeconds: TimeInterval = 30, happySeconds: TimeInterval = 30)
    weak var delegate: SchedulerDelegate?
    private(set) var state: CompanionState          // starts .idle
    private(set) var previousState: CompanionState  // starts .idle
    private(set) var stateChangedAt: Date
    private(set) var nextCheckAt: Date?
    var intervalMinutes: Int { get set }            // setting it reschedules from now

    func start()                 // schedules the first check `intervalMinutes` from now
    func stop()                  // cancels all timers; state → idle
    func checkNow()              // manual: state → watching, immediate check
    func apply(_ decision: Decision) // applies the transition table above
    /// Onboarding uses this to force watching without a timer.
    func enterWatching()
}
```

A check is "in flight" from `schedulerRequestsCheck` until `apply`. If another trigger fires
while in flight, it is ignored.

---

## 3. Capture

### 3.1 ScreenPermission

```swift
enum ScreenPermission {
    static func isGranted() -> Bool          // CGPreflightScreenCaptureAccess()
    static func request() -> Bool            // CGRequestScreenCaptureAccess(); shows OS prompt only the first time
    static func openSystemSettings()         // x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture
}
```

Important macOS behavior: after the user grants Screen Recording, **the app must relaunch**
before capture works. See `AppCoordinator.relaunch()`.

### 3.2 ScreenCapture

```swift
struct Screenshot {
    let jpegData: Data       // downscaled, longest edge ≤ 1280px, JPEG quality 0.7
    let width: Int
    let height: Int
    let capturedAt: Date
    var base64: String { jpegData.base64EncodedString() }
}

enum ScreenCaptureError: Error { case permissionDenied, noDisplay, failed(String) }

enum ScreenCapture {
    /// Captures the display that currently contains the mouse cursor (fallback: main display).
    static func capture() async throws -> Screenshot
}
```

Use `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)`, pick the
`SCDisplay` under `NSEvent.mouseLocation`, build `SCContentFilter(display:excludingWindows:)`
excluding this app's own windows, and call `SCScreenshotManager.captureImage`. Set
`SCStreamConfiguration.width/height` to the downscaled size so we never hold a full-res image.

### 3.3 ActiveWindowInfo

```swift
struct ActiveWindowInfo: Equatable {
    let appName: String          // e.g. "Google Chrome"
    let bundleID: String?        // e.g. "com.google.Chrome"
    let windowTitle: String?     // e.g. "lofi hip hop radio - YouTube"
    var summary: String          // "Google Chrome — “lofi hip hop radio - YouTube”" (or app name only)
    var looksLikeYouTube: Bool   // title or bundle contains "youtube" (case-insensitive)
}

enum ActiveWindowInspector {
    static func current() -> ActiveWindowInfo
}
```

Use `NSWorkspace.shared.frontmostApplication` for app name/pid/bundle, then
`CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)`,
filter `kCGWindowOwnerPID == pid` and `kCGWindowLayer == 0`, take the first window with a
non-empty `kCGWindowName`. Titles are only visible with Screen Recording permission; if
absent, `windowTitle` is nil.

---

## 4. LLM

### 4.1 Decision (the tool call)

The model "calls a tool" by emitting one JSON object that matches this schema. Ollama's
structured output (`format` = JSON schema) enforces the shape.

```swift
enum Tool: String, Codable { case set_idle, snooze, set_angry }

struct Decision: Codable, Equatable {
    let tool: Tool
    let snoozeMinutes: Int?      // JSON key "snooze_minutes"; required when tool == .snooze; clamp 1...120
    let message: String          // what the sergeant says; "" means stay silent (no bubble)

    static let jsonSchema: [String: Any]   // see below
    static func parse(_ text: String) throws -> Decision   // tolerant: strips ``` fences, finds first {...}
}
```

JSON schema sent to Ollama:

```json
{
  "type": "object",
  "properties": {
    "tool": { "type": "string", "enum": ["set_idle", "snooze", "set_angry"] },
    "snooze_minutes": { "type": "integer", "minimum": 1, "maximum": 120 },
    "message": { "type": "string" }
  },
  "required": ["tool", "message"]
}
```

If `tool == snooze` and `snooze_minutes` is missing, default to 10.

### 4.2 OllamaClient

```swift
struct OllamaMessage: Codable {
    var role: String            // "system" | "user" | "assistant"
    var content: String
    var images: [String]?       // base64 JPEG, only on user messages
}

enum OllamaError: Error { case unreachable, modelMissing(String), badResponse(String), http(Int) }

actor OllamaClient {
    init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!, model: String)
    var model: String
    func isReachable() async -> Bool                     // GET /api/tags succeeds
    func hasModel() async throws -> Bool                 // model name in /api/tags (match with or without ":latest")
    /// POST /api/chat, stream:false, think:false, format: Decision.jsonSchema,
    /// options: {temperature: 0.2, num_ctx: 8192, num_predict: 200}, keep_alive: "30m"
    func decide(messages: [OllamaMessage]) async throws -> Decision
}
```

Timeout: 120s per request. `think:false` avoids long reasoning before the constrained JSON, and
`num_predict:200` caps runaway output. Decode both `message.content` and optional
`message.thinking`: use `content` when it contains `{`, otherwise parse `thinking` (some Ollama
model templates return the final JSON there when thinking is disabled). If neither produces a
valid decision, throw `badResponse`. Log request size, latency, the response field used, and
top-level `eval_count` / `done_reason` when present via `Log`.

### 4.3 Conversation

Keeps a bounded history so replies have context.

```swift
@MainActor
final class Conversation {
    init(maxTurns: Int = 12)
    private(set) var turns: [OllamaMessage]     // user/assistant only, images stripped from old turns
    func appendUser(_ text: String, image: String?)   // image kept only on the most recent user turn
    func appendAssistant(_ decision: Decision)  // stored as the raw JSON string
    var lastUserMessage: String?                // most recent *typed* reply by the human (not check prompts)
    func recordHumanReply(_ text: String)       // sets lastUserMessage and appends as a user turn
    func reset()
}
```

### 4.4 PromptBuilder

```swift
struct CheckContext {
    let goal: String
    let state: CompanionState
    let previousState: CompanionState
    let stateAge: TimeInterval           // seconds since state changed
    let window: ActiveWindowInfo
    let lastUserMessage: String?
    let now: Date
    let reason: CheckReason
}

enum PromptBuilder {
    static func systemPrompt(goal: String) -> String
    static func checkPrompt(_ ctx: CheckContext) -> String        // user turn text for a screenshot check
    static func replyPrompt(_ text: String, ctx: CheckContext) -> String  // user turn text for a typed reply (no screenshot)
}
```

System prompt (use this text, `{goal}` substituted):

```
You are Drill Sergeant, a no-nonsense accountability companion living in the user's Mac notch.
The user works alone and asked you to keep them on task. Their stated goal:
"{goal}"

Every few minutes you receive a screenshot of their screen plus the active window's title.
Decide whether they are ON TASK for that goal, then respond by calling exactly one tool:
- set_idle: they are on task (or the screen is ambiguous but plausibly work). Message may be "" to stay quiet, or a short nod.
- set_angry: they are clearly OFF TASK (YouTube, social media, news, shopping, games, idle scrolling, anything unrelated). Message is a short bark telling them to close it and get back to "{goal}".
- snooze: they gave a legitimate reason for a break or a different activity, or asked for time. Set snooze_minutes (1-120). Message acknowledges it briefly.

Rules:
- Be blunt, loud, and short: at most 2 sentences, under 160 characters. Drill sergeant tone. No slurs, no insults about the person, no profanity beyond "damn"/"hell".
- You are on their side. Tough love, never cruel.
- Reading docs, code, email, chat with coworkers, research related to the goal = on task.
- If the user replies with a reason, judge it fairly. Do not get talked into endless snoozes: after one snooze, be skeptical.
- When you are currently angry and the distraction is gone, call set_idle with a brief approving message.
- Output only the JSON tool call.
```

Check prompt (user turn):

```
Screenshot attached.
Time: {h:mm a}
Current state: {state} (for {stateAge, e.g. "2m 10s"})
Previous state: {previousState}
Active window: {window.summary}
Last thing the user said to you: {lastUserMessage or "(nothing yet)"}
Check reason: {scheduled | angry poll — is the distraction still open? | manual | onboarding test}
Decide now.
```

Reply prompt (user turn, no image):

```
The user replied to you: "{text}"
Time: {h:mm a}
Current state: {state}
Active window: {window.summary}
Respond with one tool call.
```

---

## 5. Notch UI

### 5.1 NotchGeometry

```swift
struct NotchGeometry: Equatable {
    let screenFrame: CGRect        // NSScreen.frame (AppKit coords, origin bottom-left)
    let notchRect: CGRect          // AppKit coords; the physical notch (or a synthetic one)
    let hasPhysicalNotch: Bool

    /// Rect for the eyes panel: same x/width as the notch, hangs below its bottom edge by `panelHeight`,
    /// PLUS covers the notch itself, so the panel is one continuous black shape.
    func panelFrame(panelHeight: CGFloat) -> CGRect

    static func detect(screen: NSScreen) -> NotchGeometry
}
```

Detection: if `screen.safeAreaInsets.top > 0`, notch = x from `screen.auxiliaryTopLeftArea!.maxX`
to `screen.auxiliaryTopRightArea!.minX`, y from `frame.maxY - safeAreaInsets.top` to `frame.maxY`.
Otherwise synthesize a notch 200pt wide × 32pt tall centered at the top (`hasPhysicalNotch = false`).

### 5.2 NotchWindow

- `NSPanel`, styleMask `[.borderless, .nonactivatingPanel]`, `level = .statusBar + 1`,
  `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`,
  `backgroundColor = .clear`, `isOpaque = false`, `hasShadow = false`, `hidesOnDeactivate = false`,
  `isMovable = false`, `ignoresMouseEvents = false`.
- Frame = `geometry.panelFrame(panelHeight: 34)`. Re-detect on `NSApplication.didChangeScreenParametersNotification`.
- Content: `NSHostingView(rootView: EyesView(model:))` on a black rounded shape:
  the notch part is a plain rectangle, the hanging part has bottom corners radius 14.
  On screens without a physical notch draw the whole shape black too.
- Right-click (or ctrl-click) anywhere shows an `NSMenu`: **Check now**, **Developer…**, separator, **Quit Drill Sergeant** (⌘Q).
- Hover over the eyes is a no-op in V1.

### 5.3 EyesView

```swift
@MainActor
final class EyesModel: ObservableObject {
    @Published var state: CompanionState = .idle
    @Published var gaze: CGPoint = .zero      // normalized (-1...1, -1...1), (0,0) = center
    @Published var isBlinking = false
}

struct EyesView: View { @ObservedObject var model: EyesModel }
```

Design: two white eyes on black, each ~14×18pt, 12pt apart, in the hanging part of the panel.
- **idle**: rounded-rect eyes, pupils centered (no pupils drawn; the eye itself is the shape).
  Blink every 3–6s (random): scale Y to 0.1 for 120ms. Slow 1px drift.
- **watching**: eyes narrow slightly (height ×0.85) and translate toward `gaze` by up to 4pt.
  A pupil is not required; move the whole eye. Optional: a small darker inner dot.
- **angry**: eyes tilt inward: add a black diagonal "brow" mask over the inner-top corner
  (rotate a black rectangle 20°). Eyes tinted `#FF5A5A`. Still follows gaze.
- **happy**: eyes become upward arcs (like `^ ^`): draw an arc stroke 3pt white, no fill. Slight
  bounce on entry.
- All transitions animated with `.easeInOut(duration: 0.25)`; use `withAnimation` in the model
  setters or `.animation(_, value:)` modifiers.

### 5.4 CursorTracker

```swift
@MainActor
final class CursorTracker {
    init(eyesModel: EyesModel, windowProvider: @escaping () -> NSWindow?)
    func start()   // 30Hz timer polling NSEvent.mouseLocation; sets eyesModel.gaze
    func stop()    // gaze animates back to .zero
}
```

Gaze = vector from the panel's center (screen coords) to the mouse, divided by
(screenWidth/2, screenHeight/2), clamped to -1...1. Start it when state is watching/angry,
stop otherwise.

---

## 6. Chat bubble

### 6.1 ChatPresenter (protocol; onboarding and coordinator talk to this)

```swift
@MainActor
protocol ChatPresenter: AnyObject {
    /// Show a message bubble under the notch. `autoHide`: hide after 10s (idle/happy) or stay (angry/onboarding).
    func show(_ text: String, autoHide: Bool)
    /// Show a message that expects a reply. The reply field opens only on click (see 16).
    func ask(_ text: String)
    func hide()
    /// Called when the user submits a reply.
    var onReply: ((String) -> Void)? { get set }
    /// Called when the user clicks the bubble body (used by onboarding for "click to grant permission").
    var onTap: (() -> Void)? { get set }
}
```

### 6.2 BubbleWindow / BubbleView

- `NSPanel`, same flags as NotchWindow but `level = .statusBar` and it **can** become key
  (needs keyboard for the text field): styleMask `[.borderless, .nonactivatingPanel]` and
  override `canBecomeKey` → true. Width 320pt, height fits content (max 4 lines + input).
- Position: horizontally centered under the notch panel, 8pt gap below the panel's bottom edge.
- Look: dark bubble `#1C1C1E` at 96% opacity, corner radius 16, 1pt border white@10%,
  white 13pt system text, small upward-pointing triangle tail toward the notch.
- Hover: a hint appears in the bubble's bottom margin, right side: `reply ←` (see 16).
- Click (anywhere on the bubble, not the input): if `onTap` is set, call it; otherwise open the
  reply input under the text: an `NSTextField`-style single-line input (SwiftUI `TextField`),
  placeholder "Talk back…", Return submits → `onReply(text)`, Esc closes the input.
- While input is open the bubble does not auto-hide.
- Depth comes from the window's own shadow (`hasShadow = true`, recomputed with `invalidateShadow()`
  whenever the bubble resizes). A SwiftUI `.shadow()` is clipped to its layer bounds when AppKit
  re-rasterizes the view a second or two after it appears, so it is used only for static renders.
- Appear/disappear animation: fade + 6pt slide from the notch, 0.2s.
- A new `show` while visible replaces the text (no stacking).

Implement `BubbleWindow: ChatPresenter`.

---

## 7. Settings

```swift
@MainActor
final class Settings {
    static let shared = Settings()
    var goal: String                    // key ds.goal, default ""
    var model: String                   // key ds.model, default "qwen3-vl:8b"
    var intervalMinutes: Int            // key ds.intervalMinutes, default 10
    var onboardingStep: OnboardingStep  // key ds.onboardingStep, default .welcome
    var ollamaBaseURL: URL              // key ds.ollamaBaseURL, default http://127.0.0.1:11434
}
```

Env overrides for development: `DS_MODEL`, `DS_INTERVAL_MINUTES`, `DS_OLLAMA_URL`,
`DS_RESET_ONBOARDING=1` (clears onboardingStep and goal at launch).

---

## 8. Onboarding

Runs through the bubble. Persist `Settings.onboardingStep` after each step so a relaunch
resumes where it left off.

```swift
enum OnboardingStep: String, Codable { case welcome, goal, permission, relaunch, test, done }

@MainActor
final class OnboardingFlow {
    init(chat: ChatPresenter, scheduler: Scheduler, settings: Settings, ollama: OllamaClient,
         relaunch: @escaping () -> Void, runCheck: @escaping (CheckReason) async -> Decision?)
    var onFinished: (() -> Void)?
    func start()   // resumes from settings.onboardingStep
}
```

Steps:

1. **welcome → goal**: `ask("Drill Sergeant reporting. I watch your screen every 10 minutes and shout when you slack off. Everything runs on a local model. Nothing leaves this Mac. First: what are you working on today?")`. On reply: save `goal`, step = `.permission`.
2. **permission**: if `ScreenPermission.isGranted()` skip to step 4. Else `show("Good. Now I need Screen Recording permission to see your screen. Click this bubble to grant it.", autoHide: false)` with `onTap` → `ScreenPermission.request()`; if that returns false and the OS prompt did not appear (second attempt), call `openSystemSettings()`. Poll `isGranted()` every 2s. When granted: step = `.relaunch`.
3. **relaunch**: `show("Permission granted. I have to restart to use it. Click here to restart.", autoHide: false)`, `onTap` → `relaunch()`. On next launch this step is skipped straight to `.test` because permission is granted (check `isGranted()` at start; if `.relaunch` and granted → `.test`).
4. **test**: first verify Ollama: if not reachable or model missing, `show("I can't reach Ollama or the model {model} is missing. Run install.sh again, or `ollama pull {model}`. I'll keep checking.", autoHide: false)` and retry every 10s. When ready: `show("Let's test it. Open YouTube. I'm watching.", autoHide: false)`, `scheduler.enterWatching()`. Poll `ActiveWindowInspector.current().looksLikeYouTube` every 2s (also accept the user replying "done"). On detection: `runCheck(.onboarding)` → scheduler.apply. Expect angry; the normal angry poll then takes over. When the scheduler reaches `.happy` (or `.idle` if the model was lenient), `show("That's how it works. Now back to: {goal}. Next check in {interval} minutes.", autoHide: true)`, step = `.done`, `onFinished?()`.

If the user never opens YouTube within 3 minutes, `show("Still waiting. Open YouTube so I can show you what happens.", autoHide: false)` and keep polling.

---

## 9. AppCoordinator (wiring)

```swift
@MainActor
final class AppCoordinator: SchedulerDelegate {
    init()
    func start()            // builds windows, starts onboarding or scheduler
    func relaunch()         // launches a fresh instance of the bundle (open -n) then terminates
    func checkNow()
    func promptForGoal()    // chat.ask("What are you working on?") → save goal, conversation.reset()
    func quit()
}
```

Behavior:
- `start()`: create `EyesModel`, `NotchWindow`, `BubbleWindow`, `Scheduler(clock: SystemClock())`,
  `OllamaClient(model: settings.model)`, `Conversation`. Hook the notch menu to `checkNow`,
  `showDeveloperToolbar`, and `quit`. If `settings.onboardingStep != .done` run `OnboardingFlow`; else
  `scheduler.start()`.
- `scheduler(didChange:)`: update `eyesModel.state`; start/stop `CursorTracker` for
  watching/angry; when state becomes idle after happy, hide the bubble if not in reply mode.
- `schedulerRequestsCheck(reason:)`: `Task { let d = await runCheck(reason); scheduler.apply(d) }`.
  `runCheck`: capture screenshot (on `permissionDenied` → show bubble asking to grant, return
  `set_idle` with ""), inspect window, build `CheckContext`, `conversation.appendUser(prompt, image:)`,
  `ollama.decide(messages: [system] + conversation.turns)`. On `OllamaError` → show
  "Can't reach Ollama…" bubble, return `Decision(tool: .set_idle, snoozeMinutes: nil, message: "")`.
  Log everything. After a decision: `conversation.appendAssistant(d)`; if `d.message` non-empty,
  `chat.show(d.message, autoHide: d.tool != .set_angry)`.
- `chat.onReply`: `conversation.recordHumanReply(text)`, build reply prompt, `ollama.decide`, apply
  the same post-decision handling. Replies do not capture a screenshot.
- Handle `applicationShouldTerminate` normally; `quit()` calls `NSApp.terminate(nil)`.

---

## 10. Packaging and install

### 10.1 `Scripts/Info.plist`

```xml
CFBundleIdentifier com.evanhu.drillsergeant
CFBundleName Drill Sergeant
CFBundleDisplayName Drill Sergeant
CFBundleExecutable DrillSergeant
CFBundlePackageType APPL
CFBundleShortVersionString 0.1.0
CFBundleVersion 1
LSMinimumSystemVersion 14.0
LSUIElement true
NSHighResolutionCapable true
NSScreenCaptureUsageDescription Drill Sergeant looks at your screen every 10 minutes to check you are on task. Screenshots are analyzed by a local model and never leave this Mac.
```

### 10.2 `Scripts/bundle.sh`

`swift build -c release --arch arm64`, assemble `build/Drill Sergeant.app/Contents/{MacOS,Resources}`,
copy binary and Info.plist, write `PkgInfo` (`APPL????`), `codesign --force --deep --sign - "build/Drill Sergeant.app"`.
Exit non-zero on any failure (`set -euo pipefail`). Print the final path.

### 10.3 `Scripts/run.sh`

Dev helper: `bundle.sh` then `open -n "build/Drill Sergeant.app"`; `--reset` passes `DS_RESET_ONBOARDING=1`
via `open --env`.

### 10.4 `install.sh`

Curl-able one-liner: `curl -fsSL https://raw.githubusercontent.com/evanhu/drill-sergeant/main/install.sh | bash`

Steps, each printed with a `==>` prefix:
1. Check `uname -m == arm64` and macOS ≥ 14, else exit with a clear message.
2. Check `xcode-select -p`; if missing run `xcode-select --install` and tell the user to rerun.
3. Check Homebrew; if missing, print the brew install command and exit.
4. Ollama: if `ollama` missing → `brew install --cask ollama`. If present but version < 0.12
   → `brew upgrade --cask ollama || brew upgrade ollama || true` and re-check; if still old, print
   "Update Ollama from https://ollama.com/download" and continue.
5. Start Ollama if `curl -s 127.0.0.1:11434` fails: `open -a Ollama` if the app exists, else
   `nohup ollama serve >/dev/null 2>&1 &`. Wait up to 30s for the port.
6. `ollama pull ${DS_MODEL:-qwen3-vl:8b}` (show progress).
7. Clone or update the repo into `~/.drill-sergeant/src` (`git clone` or `git pull`).
   If `install.sh` is run from inside a checkout (`Scripts/bundle.sh` exists next to it), use that checkout instead.
8. `Scripts/bundle.sh`, then `rm -rf "/Applications/Drill Sergeant.app"` and copy the new bundle there.
9. `open -n "/Applications/Drill Sergeant.app"` and print: "Drill Sergeant is in your notch. Follow the chat bubble."

Idempotent: safe to run twice.

---

## 11. Logging

`Log.info/warn/error(_ message: String)` → `os.Logger(subsystem: "com.evanhu.drillsergeant", category: "app")`
and also append to `~/Library/Logs/DrillSergeant/app.log` (rotate at 5 MB). Never log screenshot bytes.

---

## 12. Tests (minimum)

- `SchedulerTests`: with `TestClock`: start → watching at T-60s → check requested → apply set_idle → idle,
  next check +10m; apply set_angry → angry → poll at +30s; set_idle from angry → happy → idle at +30s;
  snooze(15) → next check at +15m; in-flight guard ignores double triggers; checkNow works from idle.
- `DecisionTests`: parse clean JSON, fenced JSON, JSON with prose around it, missing snooze_minutes → 10, clamp 500 → 120.
- `PromptBuilderTests`: system prompt contains goal; check prompt contains window summary, state, age formatting ("2m 10s").
- `ActiveWindowInfoTests`: `looksLikeYouTube` for title/bundle variants.
- `NotchGeometryTests`: synthetic fallback dims; `panelFrame` math.
- `ConversationTests`: image kept only on last user turn; maxTurns trimming.

---

## 13. Non-goals for V1

Multiple displays at once, browser URL extraction, menu bar icon, settings window, launch at login,
notarization, non-notch UI polish beyond the synthetic notch fallback, Intel Macs.

---

## 14. V1.1 amendments

### 14.1 Notch tray auto-hide (amends 5.2)

The hanging part of the notch panel (the "tray") has two positions:

- `extended`: as today, eyes visible below the notch.
- `hidden`: the tray is translated up by `panelHeight` so it sits inside the notch rect and is
  invisible. Content is clipped to the notch rect while hidden so nothing bleeds onto the menu bar.
  The notch rect's own bottom corners round out as the tray retracts (0 extended → 9pt hidden), so
  the hidden tray follows the hardware notch's curve instead of leaving square black corners beside
  it.
  On screens without a physical notch the synthetic notch stays drawn; only the tray moves.

Rules (owned by `NotchWindow`, which observes `EyesModel.state`):
- Tray is `extended` whenever state is `watching`, `angry`, or `happy`.
- When state becomes `idle`, start a 3s timer. If still idle when it fires, and the tray is not
  pinned and the mouse is not over the panel, slide to `hidden`.
- Any transition out of `idle` cancels the timer and extends immediately.
- Mouse hover over the panel frame extends the tray; leaving restarts the 3s timer if idle.
- `func setTrayPinned(_ pinned: Bool)`: while pinned (the chat bubble is visible), the tray stays
  extended. Unpinning restarts the 3s timer if idle.
- `func setTrayExtended(_ extended: Bool, animated: Bool = true)` for dev tools.
- Animation: ease-in-out over 0.5s, tweened frame by frame by `NotchWindow` rather than with a
  SwiftUI animation. The eyes re-render ~30 times a second to track the cursor, and each of those
  renders resolved their position to the animation's final value, so the eyes arrived at the
  extended position while the black background was still sliding. Setting the offset explicitly
  every frame keeps the whole tray in lockstep. The window frame does not change; only the content
  offset moves, so right-click still works on the notch area while hidden.

`BubbleWindow` gains `var onVisibilityChange: ((Bool) -> Void)?` fired when the bubble is shown or
fully hidden. `AppCoordinator` wires it to `notchWindow.setTrayPinned`.

### 14.2 Bubble close button (amends 6.2)

A small circular close button (14pt, `xmark` SF Symbol at 8pt, secondary label color at 60%,
100% on hover) sits in the bubble's top-right corner, 8pt inset. Clicking it calls `hide()`,
closes the reply input, cancels auto-hide, and does not change companion state. It is always
visible while the bubble is showing. The hover hint `reply ←` stays bottom-left.

### 14.3 Developer toolbar

Opened from the notch right-click menu item **Developer…** (always present in V1) or at launch with
`DS_DEV=1`. It is a standard titled floating `NSPanel` (`.utilityWindow`, `.titled`, `.closable`,
level `.floating`), 360pt wide, hosting a SwiftUI form. `App/DevToolbar.swift` +
`App/DevToolbarView.swift`. It talks to `AppCoordinator` through a small facade protocol so the
view is testable:

```swift
@MainActor
protocol DevActions: AnyObject {
    var statusText: String { get }             // "state=angry (12s) · next check 4:32 PM · goal=… · model=…"
    var lastDecisionText: String { get }       // "set_angry — 'Close X…' (8.4s, field=thinking)"
    func forceState(_ state: CompanionState)   // via Scheduler.debugTransition(to:)
    func showTestMessage(_ text: String, autoHide: Bool)  // chat.show
    func sendReply(_ text: String)             // real LLM reply flow (same as typing in the bubble)
    func runCheck()                            // real screenshot + LLM flow (scheduler.checkNow)
    func captureOnly() async -> String         // screenshot only; saves ~/Library/Logs/DrillSergeant/last-capture.jpg; returns "1280x827, 190 KB, Arc — “…”"
    func resetOnboarding()                     // step=.welcome, goal="", conversation.reset(), stop scheduler, start OnboardingFlow in place (no relaunch)
    func skipOnboarding()                      // step=.done, start scheduler
    func setTrayExtended(_ extended: Bool)
    func renderStates() async -> URL           // see 14.4; returns output folder, then opens it in Finder
}
```

Sections in the form, top to bottom:
1. **Status** — two lines, refreshed every second.
2. **State** — four buttons: Idle, Watching, Angry, Happy. Toggle: "Tray extended".
3. **Receive message** — text field (default "Close YouTube and get back to work."), toggle
   "auto-hide", button "Show".
4. **Send message** — text field (default "I'm researching for the essay, give me 10 min"),
   button "Send to model". Shows `…` in the bubble until the model answers (existing behavior).
5. **Screenshot flow** — buttons "Run check (screenshot + model)" and "Capture only"; the capture
   result string appears under the buttons.
6. **Onboarding** — buttons "Reset & start", "Skip".
7. **Renders** — button "Render all states" → opens the folder.

`Scheduler.debugTransition(to:)`: cancels timers, then: `.idle` → behaves like `apply(set_idle)`;
`.watching` → `enterWatching()`; `.angry` → behaves like `apply(set_angry)` (starts the 30s poll);
`.happy` → happy for 30s then idle, next check in `intervalMinutes`.

### 14.4 State renders

`DrillSergeant --render-states [outputDir]` (default `build/renders`) renders PNGs without showing
any window and exits 0. Also callable from the toolbar. Uses SwiftUI `ImageRenderer` at 3x scale
on the same view the notch window hosts (`NotchPanelContent`) with a fixed synthetic geometry
(notch 200×32, panel 34) so renders are deterministic:

| File | Content |
|---|---|
| `idle.png` | idle, eyes open |
| `idle-blink.png` | idle, mid-blink |
| `watching.png` | watching, gaze (0.6, -0.3) |
| `angry.png` | angry, gaze (-0.4, 0.2) |
| `happy.png` | happy |
| `tray-hidden.png` | idle with the tray hidden |
| `bubble.png` | the bubble view with a two-line message, hover hint visible, close button |
| `bubble-input.png` | the bubble with the reply input open |
| `sheet.png` | all of the above tiled in a grid on a mid-gray background with filename labels |

Render on a mid-gray (`#808080`) background behind the panel so the black shape's edges are visible.
The views must expose whatever static inputs they need (blink progress, gaze, hover) as plain
parameters or model fields so the renderer can set them without timers. Animations are not
started in render mode.

## 15. Eye design v2 (replaces 5.3 visuals)

Reference: creature.company "cat-smoothie" eyes. Two large cream ovals (sclera) each holding a big
periwinkle-blue pupil. The pupil is what expresses; there are no eyebrows in any state.

Geometry (points, in a tray of `panelHeight = 40`; update the NotchWindow, BubbleWindow default, and
renderer to 40):
- Sclera: ellipse 22 wide × 27 tall, fill `#FBEEE3`. Left eye rotated -8°, right eye +8° (tops lean
  outward, like the reference). Gap between eyes 5pt. Pair centered horizontally, vertically centered
  in the tray with 4pt clearance to the tray's bottom edge.
- Pupil: ellipse 11 × 13, fill `#6B78E6`, clipped to the sclera. Rest position is at the sclera
  center, offset 1pt downward.
- Pupil gaze travel: max offset so the pupil stays fully inside the sclera with a 1.5pt margin
  (≈ ±5pt x, ±6pt y).

Gaze (all states except happy and mid-blink):
- `CursorTracker` runs **always** while the app is alive (30Hz polling), not only in watching/angry.
- Mapping: vector from the panel center to the mouse in screen points, divided by (screenWidth/2,
  screenHeight/2) → v in [-1,1]². Apply `sign(v) * pow(|v|, 0.55)` per axis so mid-screen cursor
  positions already move the pupil most of the way, then multiply by max travel. Screen y is flipped
  (mouse below the notch → pupil looks down).
- Both pupils move together (no convergence). Movement is smoothed with `.interactiveSpring` or
  `.easeOut(duration: 0.12)` so it feels alive but not laggy.

States:
- **idle**: as above; blink every 3–6s. The blink is an eyelid sweeping down from the top of the
  eye, its edge a curve that dips ~13% of the eye height in the middle, never a straight slit or a
  vertical squash. It shuts in 70ms, holds 100ms, and opens over 130ms, because real lids open
  slower than they close.
- **watching**: sclera scales to 1.08, pupil shrinks to 0.85 (focused). Blinks less often (6–10s).
- **angry**: the top of each sclera is cut by a slanted lid: clip the sclera (and pupil) with a
  shape whose top edge runs from the **outer** top corner at 22% of the eye height down to the
  **inner** corner at 52% of the eye height (lids slant down toward the nose). Pupil scales to 0.9.
  No red tint, no brow, and no shake: the angry eyes hold still and stare.
- **happy**: sclera collapses into an upward arc: render a 3.5pt-thick cream arc (the top half of
  the sclera outline, ends slightly flared), no pupil. Bounce on entry (scale 1.15 → 1.0, 0.3s).
- Tray hidden: nothing visible (unchanged).

Renders (14.4): add `angry-gaze-left.png` (gaze (-0.8, 0.1)) and `idle-gaze-down.png`
(gaze (0.3, 0.9)) so lid clipping and travel limits can be checked.

## 16. Bubble reply affordance (amends 6.1, 6.2, 14.2)

The reply field is never shown by default, not even for `ask()`. Every bubble opens as text only.
Clicking the bubble body opens the field (unless `onTap` is set, which still takes precedence).
Submitting or pressing Esc closes it again.

The `reply ←` hint sits in the bubble's bottom margin at the right side, as an overlay that never
affects layout. It fades in on hover and is hidden whenever the input is open. The bubble keeps a
22pt bottom margin while the input is closed to hold it, and 12pt while the input is open.

## 17. No goals (removes the goal concept everywhere)

There is no goal. The user never states one, nothing stores one, and no prompt mentions one. The
sergeant judges the screen on its own terms: working, or slacking off. Remove `Settings.goal`, the
`goal` field on `CheckContext`, the `goal:` parameter on `PromptBuilder.systemPrompt`, the
`OnboardingStep.goal` case, `AppCoordinator.promptForGoal`, `NotchWindow.onSetGoal`, and the
"Set goal…" menu item. Delete the stored `ds.goal` default on launch so nothing stale is left
behind. The notch menu becomes: **Check now**, **Developer…**, separator, **Quit Drill Sergeant**.

### 17.1 System prompt (replaces 4.4)

```
You are Drill Sergeant, a no-nonsense accountability companion living in the user's Mac notch.
The user works alone and asked you to keep them working.

Every few minutes you receive a screenshot of their screen plus the active window's title.
Decide whether they are WORKING or SLACKING OFF, then respond by calling exactly one tool:
- set_idle: they are working, or the screen is ambiguous but plausibly work. Message may be "" to stay quiet, or a short nod.
- set_angry: they are clearly slacking off: YouTube, social media, news feeds, shopping, games, idle scrolling. Message is a short bark telling them to close it and get back to work.
- snooze: they gave a legitimate reason for a break, or asked for time. Set snooze_minutes (1-120). Message acknowledges it briefly.

Rules:
- Be blunt, loud, and short: at most 2 sentences, under 160 characters. Drill sergeant tone. No slurs, no insults about the person, no profanity beyond "damn"/"hell".
- You are on their side. Tough love, never cruel.
- Code, documents, email, design tools, terminals, chat with coworkers, and research all count as work.
- Judge the screen, not the app. A video is work if it is documentation or a talk they are studying. A browser is slacking if it is a feed.
- If the user replies with a reason, judge it fairly. Do not get talked into endless snoozes: after one snooze, be skeptical.
- When you are currently angry and the distraction is gone, call set_idle with a brief approving message.
- Output only the JSON tool call.
```

`checkPrompt` and `replyPrompt` are unchanged except that `CheckContext` no longer carries a goal.

### 17.2 Onboarding without a goal (replaces step 1 of section 8)

`OnboardingStep` becomes `welcome, permission, relaunch, test, done`.

Step **welcome** shows, and does not auto-hide:

```
Drill Sergeant reporting. I watch your screen and shout at you when you slack off. Everything runs on a local AI model, and your data never leaves your Mac.
```

Clicking the bubble (`onTap`) advances to `.permission`. Nothing is saved. The reply field is not
used in this step.

The final message of step **test** becomes:

```
That's how it works. Back to work — next check in {interval} minutes.
```

### 17.3 Dev toolbar

`DevActions.statusText` drops the goal segment: `state=angry (12s) · next check 4:32 PM · model=…`.

## 18. Capture the active window, not the whole screen (replaces 3.2, 3.3)

A screenshot of the whole display carries whatever else is open behind the app the user is
actually in. Capture just the frontmost window instead, so the model judges the work in front of
the user. The trade-off is accepted: a distraction sitting in a background window is no longer
visible to the sergeant.

### 18.1 Choosing the target window

Both `ScreenCapture` and `ActiveWindowInspector` pick the same window:

1. Frontmost application from `NSWorkspace.shared.frontmostApplication`, **skipping our own bundle
   identifier**. When Drill Sergeant is frontmost (the user clicked into the reply field), fall
   through to the next application in `NSWorkspace.shared.runningApplications` ordered by
   `isActive`, else the frontmost window of any other application on screen.
2. Its frontmost on-screen window: `kCGWindowLayer == 0`, non-empty bounds, ordered first in
   `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)`.
   Ignore windows smaller than 200×150 points (palettes, HUDs).

Factor this into one place, e.g. `ActiveWindowInspector.currentTarget() -> TargetWindow?` carrying
the window id, owning pid, app name, bundle id and title, and have `ActiveWindowInfo.current()`
build on it so both agree.

### 18.2 Capturing it

```swift
enum CaptureSource: Equatable { case window(String), display }   // associated value: app name
```

`Screenshot` gains `let source: CaptureSource`.

Use `SCContentFilter(desktopIndependentWindow:)` with the `SCWindow` whose `windowID` matches the
target. Set `SCStreamConfiguration.width/height` from the window's size scaled so the longest edge
is ≤ 1280, `showsCursor = false`, and an opaque `backgroundColor` (black) so transparent corners do
not encode as noise. This captures the window's own content even when another window overlaps it.

Fall back to the existing full-display capture (`source = .display`) when there is no target
window, when its `SCWindow` cannot be found, or when window capture throws. Never fall back
silently: `Log.info` which path was used.

`Log.info` after every capture: `Captured window "Arc" 1280x800 (190 KB)` or
`Captured display 1280x827 (190 KB)`.

### 18.3 Prompt copy (replaces the matching lines of 17.1)

Second paragraph becomes:

```
Every few minutes you receive a screenshot of the window the user is working in, plus that window's title.
```

The `set_idle` line becomes:

```
- set_idle: they are working, or the window is ambiguous but plausibly work. Message may be "" to stay quiet, or a short nod.
```

The judging rule becomes:

```
- Judge what is in the window, not which app it is. A video is work if it is documentation or a talk they are studying. A browser is slacking if it is a feed.
```

Everything else in the system prompt is unchanged.

## 19. Check traces

Every model call writes a folder so a human can see exactly what the sergeant saw, what was sent,
and what came back. On by default; `DS_TRACE=0` turns it off (`Settings.tracingEnabled`).

```
~/Library/Logs/DrillSergeant/checks/2026-09-02_04-21-05_scheduled/
    screenshot.jpg    the exact bytes sent to the model (absent for replies)
    prompt.txt        every message in the request, in order, in full
    response.txt      raw model output, parsed decision, timing
```

Folder name: `yyyy-MM-dd_HH-mm-ss` in local time, then `_` and the reason
(`scheduled`, `angryPoll`, `manual`, `onboarding`, `reply`). Add `-2`, `-3` … on collision.

`prompt.txt`:

```
check: scheduled
time: 2026-09-02 04:21:05
model: qwen3-vl:8b
state: watching (for 2s), previous idle
capture: window "Arc" 1280x803, 116 KB
active window: Arc — “Week of September 7, 2026”

--- message 1 · system
<the full system prompt>

--- message 2 · user · [image: screenshot.jpg]
<the full user turn>

--- message 3 · assistant
<the full assistant turn>
```

Images are never inlined as base64; the placeholder names the file instead. A reply trace says
`capture: none (reply)` and has no image placeholder.

`response.txt`:

```
latency: 4.12s
field: message.thinking
eval_count: 30
done_reason: stop

--- raw
{"tool": "set_angry", "message": "Close it and get back to work."}

--- parsed
tool: set_angry
snooze_minutes: none
message: Close it and get back to work.
```

When the call fails, `response.txt` holds `error: <description>` and whatever was received.

`OllamaDecisionResult` gains `rawContent: String` (the exact text the decision was parsed from),
`evalCount: Int?` and `doneReason: String?`, so the trace can record them.

Retention: after writing, delete the oldest folders so at most 100 remain. Never log base64 or
image bytes into `app.log`.

`DevActions` gains `func openTraceFolder()`, wired to a **Traces** section in the developer
toolbar with an "Open trace folder" button that reveals the directory in Finder.

## 20. Expressive eyes (adds to 15)

Seven behaviours layered on the section 15 design. All are driven from `EyesView` and `EyesModel`;
the coordinator only reports what the user is doing.

- **Saccades** (idle only): every 2–5s the pupils flick by up to ±0.35 x / ±0.2 y of gaze range
  for 120–200ms, then return. Skipped while glancing at the bubble.
- **Convergence**: `EyesModel.proximity` is 1 when the cursor is within 60pt of the panel centre,
  fading to 0 at 360pt. Each pupil shifts inward by `1.6pt × proximity`.
- **Glance at the bubble**: `EyesModel.attention` is `.bubble` when a message appears (eyes look
  down at it for 0.7s), `.typing` while the reply field is open (eyes stay on the field), and
  `.cursor` otherwise. `BubbleWindow.onInputStateChange` reports the field.
- **Head tilt**: the eye pair rotates by `gaze.x × 4°`.
- **Lean**: the eye pair offsets by `(gaze.x × 2pt, gaze.y × 1.5pt)`.

Static render inputs: `proximity` and `attention` on `EyesView` and `NotchPanelContent`.
New renders: `idle-near.png`, `glance-bubble.png`.

## 21. Auto-hide countdown ring

Bubbles that auto-hide show the time they have left as a ring around the close button: a 25pt
circle, 1.5pt stroke in the muted ink at 70%, starting at twelve o'clock and draining clockwise.

`BubbleModel.countdown` holds a `BubbleCountdown(start:duration:)` while an auto-hide is pending
and is cleared whenever the timer is cancelled, so the ring is absent on bubbles that stay up
(angry, onboarding, the thinking ellipsis, errors) and disappears the moment the reply field
opens. Showing a new message restarts the timer, which resets the ring to full.

The ring reads the clock through a `TimelineView`, never a SwiftUI animation: the bubble
re-renders on hover and on every keystroke, and an animated trim would snap to empty. `BubbleView`
takes a `staticCountdown` fraction for renders; `bubble-countdown.png` shows it at 0.65.

## 22. Permission is confirmed by doing, not by asking (amends 3.1, 8, 10.2)

`CGPreflightScreenCaptureAccess()` answers for the *responsible process*, not for this build. A
binary launched from a terminal inherits the terminal's grant, so preflight returns true for an app
that has never been granted anything, and the onboarding permission step used to delete itself.

```swift
enum ScreenPermission {
    static func isGranted() -> Bool        // preflight; a hint, not an answer
    static func probe() async -> Bool      // fetches shareable content and throws it away
    static func request() -> Bool
    static func openSystemSettings()
}
```

`probe()` is the trustworthy answer: it succeeds only when capture actually works in this process.
On a first run it is also what raises the system prompt.

The permission step is **always shown** and nothing is requested until the user taps the bubble.
On tap:

1. Probe. If capture already works, go straight to `.test`. No relaunch is needed, because a
   process that can capture now does not need restarting.
2. Otherwise call `request()` to raise the prompt, and on a second tap with no grant recorded,
   open System Settings.
3. Then poll every `pollInterval`: probe true → `.test`; probe false but preflight true → the grant
   is recorded but unusable in this process, which is the case a relaunch fixes → `.relaunch`.

Resuming at `.relaunch` shows the restart bubble and probes once in the background, so an app that
was already restarted moves on without a second click.

`Scripts/bundle.sh` signs with `codesign --force --sign -`. `--deep` is a verification flag, and
Apple advises against signing with it.
