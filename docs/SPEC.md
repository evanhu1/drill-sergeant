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
| LLM | Ollama HTTP API at `http://127.0.0.1:11434`, default model `qwen3-vl:8b-instruct` |
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
    case angry     // caught off task; eyes follow cursor with angry brows; polls every 10s
    case happy     // shown for 5s after leaving angry; then idle
}
```

Transitions (Scheduler drives these):

| From | Event | To |
|---|---|---|
| idle | 30s before next check | watching |
| watching | capture + LLM done, decision `set_idle` | idle (next check in `intervalMinutes`) |
| watching | decision `set_angry` | angry |
| watching | decision `snooze(n)` | idle (next check in `n` minutes) |
| angry | 10s poll, decision `set_angry` | angry (stay) |
| angry | 10s poll or reply, decision `set_idle` | happy |
| angry | decision `snooze(n)` | happy (then idle, next check in `n` minutes) |
| happy | 5s elapsed | idle |
| any | user reply produces a decision | same rules as the row for the current state (idle/happy treated like watching) |
| any | "Check now" menu item | watching (no pre-roll), immediate capture |

Rules:
- `intervalMinutes` default 10. The timer always resets after a decision.
- Entering `happy` from `angry` also resets the timer to `intervalMinutes` (or the snooze length).
- The 30s pre-roll `watching` state is skipped when the remaining time is already under 30s.
- The angry poll: every 10s capture + LLM. It never enters `watching`; eyes already track the
  cursor. The timer starts when the previous decision lands, so with a ~4s model call the real
  cadence is ~14s.

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
    init(clock: Clock, intervalMinutes: Int = 10, preRollSeconds: TimeInterval = 30,
         angryPollSeconds: TimeInterval = 10, happySeconds: TimeInterval = 5)
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
    /// Overrides the close button's normal hide behavior while set.
    var onClose: (() -> Void)? { get set }
    var affordance: BubbleAffordance { get set }
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
    var model: String                   // key ds.model, default "qwen3-vl:8b-instruct"
    var intervalMinutes: Int            // key ds.intervalMinutes, default 10
    var onboardingStep: OnboardingStep  // key ds.onboardingStep, default .permission
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
         relaunch: @escaping () -> Void, quit: @escaping () -> Void,
         skip: @escaping () -> Void,
         runCheck: @escaping (CheckReason) async -> Decision?)
    var onFinished: (() -> Void)?
    func start()   // resumes from settings.onboardingStep
}
```

Steps:

1. **welcome → goal**: `ask("Drill Sergeant reporting. I watch your screen every 10 minutes and shout when you slack off. Everything runs on a local model. Nothing leaves this Mac. First: what are you working on today?")`. On reply: save `goal`, step = `.permission`.
2. **permission**: if `ScreenPermission.isGranted()` skip to step 4. Else `show("Now I need Screen Recording permission to see your screen. Click this bubble to grant it.", autoHide: false)` with `onTap` → `ScreenPermission.request()`; if that returns false and the OS prompt did not appear (second attempt), call `openSystemSettings()`. Poll `isGranted()` every 2s. When granted: step = `.relaunch`.
3. **relaunch**: `show("Permission granted. I have to restart to use it. Click here to restart.", autoHide: false)`, `onTap` → `relaunch()`. On next launch this step is skipped straight to `.test` because permission is granted (check `isGranted()` at start; if `.relaunch` and granted → `.test`).
4. **test**: first verify Ollama: if not reachable or model missing, `show("I can't reach Ollama or the model {model} is missing. Run install.sh again, or `ollama pull {model}`. I'll keep checking.", autoHide: false)` and retry every 10s. When ready: `show("Let's test it. Open YouTube. I'm watching.", autoHide: false)`, `scheduler.enterWatching()`. This is a display bubble: it has no reply or next action. Poll `ActiveWindowInspector.current().looksLikeYouTube` every 2s. On detection: `runCheck(.onboarding)` → scheduler.apply. Expect angry; the normal angry poll then takes over. When the scheduler reaches `.happy` (or `.idle` if the model was lenient), `show("That's how it works. Now back to: {goal}. Next check in {interval} minutes.", autoHide: true)`, step = `.done`, `onFinished?()`.

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

Nothing may be required in advance: no Xcode, no Homebrew, no compiler. The model download
must not block the terminal — the app fetches it and shows progress in the bubble.

Steps, each a spinner line that resolves to a tick:
1. Check `uname -m == arm64` and macOS ≥ 14, else exit with a clear message.
2. On a Mac with ≤ 8 GB, set the low-memory Ollama options with `launchctl setenv`.
3. Start a background job for Ollama so it overlaps the app download. If the port answers,
   do nothing. If `Ollama.app` or the `ollama` binary exists, start it. Otherwise download
   `https://ollama.com/download/Ollama-darwin.zip` and install it to `~/Applications`. Wait up
   to 30s for the port and report through a status file.
4. Download `DrillSergeant.zip` from the latest GitHub release. On 404 — or with
   `DS_FROM_SOURCE=1` — clone `~/.drill-sergeant/src` at `${DS_REF:-main}` and run
   `Scripts/bundle.sh`, which is the only path that needs the Command Line Tools.
5. Install to `~/Applications`, which never needs an administrator. Delete a copy left in
   `/Applications` by an older installer, quit any running instance, clear quarantine, and
   clear the Screen Recording grant when the code signature changed.
6. `open -n` the installed app.

Idempotent: safe to run twice, and a second run is an update.

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
visible while the bubble is showing. During onboarding, the close callback is overridden to call
the coordinator's normal `quit()` path, so X quits the app and clears pending permission markers.
On the visible YouTube test prompt only, X calls `skipOnboarding()` instead and starts normal
monitoring after hiding the test bubble.

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
- Sclera: ellipse 24 wide × 23 tall, fill `#E8EAEE`, a cool off-white, level. Wider than tall reads almond rather
  than egg, and any rotation drops an outer top corner, which reads as sadness. Gap between eyes 5pt. Pair centered horizontally, vertically centered
  in the tray with 4pt clearance to the tray's bottom edge.
- Pupil: a cat's vertical slit, ellipse 7 × 15, fill `#3E4A60`, slate, clipped to the sclera, centred.
- Pupil gaze travel: ±6pt x, ±2pt y. A tall slit in a short eye has almost no vertical room, so the
  gaze reads sideways, like a cat's.

Gaze (all states except happy and mid-blink):
- `CursorTracker` runs at 30Hz while the notch tray is extended and stops as soon as the tray
  begins retracting. It resumes when state, pinning, hover, or developer controls extend the tray,
  preserving live gaze whenever the eyes are visible without polling throughout hidden idle time.
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
- **happy**: the eye closes into a crescent by being cut with a copy of its own ellipse rising from
  below, so the arc's outer edge is the eye's silhouette and the smile is the same eye rather than a
  second shape. 6pt thick at the middle, dropped 7pt so it sits where the open eye's centre was.
  The pupil fades out over the first 60% of the close, since a pupil showing inside the arc reads as
  a stare. Bounce on entry (scale 1.15 → 1.0, 0.3s).
- Tray hidden: nothing visible (unchanged).

Renders (14.4): add `angry-gaze-left.png` (gaze (-0.8, 0.1)) and `idle-gaze-down.png`
(gaze (0.3, 0.9)) so lid clipping and travel limits can be checked.

## 16. Bubble affordances (amends 6.1, 6.2, 14.2)

Every bubble has exactly one `BubbleAffordance`: `.reply`, `.click`, or `.display`.

- `.reply` opens the reply field when its body is clicked. Its `reply ←` hint fades in on hover
  and disappears while the input is open. Submitting or pressing Esc closes the field.
- `.click` calls `onTap` when its body is clicked. Its `Next →` hint is always visible in dark
  ink and the body uses the pointing-hand cursor.
- `.display` presents text only. It has no action hint, reserves no hint gutter, uses the arrow
  cursor, and ignores body clicks.

The reply field is never shown by default, not even for `ask()`. Action hints sit in the bubble's
bottom-right margin as overlays that never affect layout. Reply and click bubbles keep a 22pt
bottom margin while closed; display bubbles use ordinary content padding; open reply bubbles use
12pt.

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

`OnboardingStep` becomes
`welcome, permission, relaunch, directCapturePermission, test, done`.

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
model: qwen3-vl:8b-instruct
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

`probe()` confirms that this process can enumerate shareable screen content. On a first run it is
also what raises the initial Screen Recording prompt. macOS can require a second consent before
`SCScreenshotManager` may capture directly without the system window picker; section 27 places
that request in its own explicit onboarding step.

The permission step is **always shown** and nothing is requested until the user taps the bubble.
On tap:

1. Probe. If shareable content is available, go straight to `.directCapturePermission`. No
   relaunch is needed, because this process can use the initial grant now.
2. Otherwise call `request()` to raise the prompt, and on a second tap with no grant recorded,
   open System Settings.
3. Then poll every `pollInterval`: probe true → `.directCapturePermission`; probe false but
   preflight true → the grant is recorded but unusable in this process, which is the case a
   relaunch fixes → `.relaunch`.

Resuming at `.relaunch` shows the restart bubble and probes once in the background, so an app that
was already restarted moves on without a second click.

`Scripts/bundle.sh` signs with `codesign --force --sign -`. `--deep` is a verification flag, and
Apple advises against signing with it.

## 23. Dev launch resets the screen-recording grant

`Scripts/run.sh` runs `tccutil reset ScreenCapture com.evanhu.drillsergeant` after building and
before launching. The ad-hoc signature's designated requirement is a bare cdhash, so every rebuild
invalidates the grant while System Settings still lists the app as allowed and capture fails
silently. Resetting turns that into a fresh prompt. A stable self-signed identity would remove the
need for this entirely.

## 24. Persistent user preferences

The model has a fourth structured action:

```swift
enum Tool: String, Codable { case set_idle, snooze, set_angry, save_user_preference }

struct Decision: Codable, Equatable {
    // Existing fields remain unchanged.
    let text: String?  // required when tool == .save_user_preference
}
```

Its tool description is:

```
save_user_preference(text): This tool writes a user preference to memory forever. Use it when a
user gives feedback or rules on what does or does not count as a distraction or work.
Call this sparingly. Negotiate with the user on preferences that seem like they could potentially
be excuses or overly generous.
```

Non-empty preferences are stored as a durable, de-duplicated `[String]` in `UserDefaults` under
`ds.userPreferences`. They survive app relaunches and onboarding resets. Saving a preference does
not itself reinterpret the current activity: from `angry`, the scheduler stays angry and polls
again; from any other state, it returns to the normal idle schedule.

`CheckContext` gains `let userPreferences: [String]`. Every screenshot-check prompt includes a
separate section, even when the list is empty:

```
User preferences (saved forever):
- YouTube tutorials count as work.
```

The reply prompt includes the same section so the model can avoid saving duplicate rules.
Successful check traces include the parsed `text` argument alongside the existing decision fields.

## 25. Permission relaunch continuity

Before invoking the system Screen Recording request, persist
`Settings.screenPermissionRequestPending` (`ds.screenPermissionRequestPending`). macOS can quit
the process directly from its permission UI, before the normal polling loop records `.relaunch`.

On the replacement launch, show `Checking Screen Recording permission…` immediately so the bubble
and pinned tray are visible while `ScreenPermission.probe()` resolves. Retry the probe five times
at the normal two-second polling interval so launch does not mistake TCC propagation latency for a
denial. A successful onboarding probe advances to `.directCapturePermission`; a successful
post-onboarding probe resumes the scheduler and briefly shows `Permission granted. I'm back on
watch.` A denied request returns to the permission prompt only after the retry window. If preflight
says the grant exists but the probe still fails, retain the restart action.

The `.test` step also presents `Getting the screen test ready…` before checking Ollama, so every
persisted onboarding state has visible UI synchronously at launch. Relaunches must not inherit the
one-shot `DS_RESET_ONBOARDING` override.

## 26. Tap-to-advance onboarding affordance

The welcome, Screen Recording permission, restart, and direct-capture permission bubbles use the
dedicated `BubbleAffordance.click` state. In that state, the bottom-right hint reads
`Next →`, is always visible, uses dark ink at 72% opacity, and does not lighten on hover. It remains active while
moving between tap-to-advance onboarding screens, and the whole bubble uses the macOS pointing-hand
cursor. Progress and waiting messages use `.display`; specifically, `Let's test it, open up
YouTube.` has neither a reply hint nor a next action, and its X skips the test and completes
onboarding. The standard `.reply` affordance returns when onboarding ends.

The permission message begins `Now I need Screen Recording permission…`; it does not begin with
`Good.` The state renderer includes `bubble-onboarding.png` for the dedicated welcome treatment.

## 27. Direct-capture permission before the YouTube test

macOS may separately ask whether Drill Sergeant can bypass the private window picker and directly
access screen and audio. Onboarding requests this before asking the user to open YouTube, rather
than letting the first accountability check trigger an unexplained system dialog.

After the initial Screen Recording permission works, persist `.directCapturePermission` and show:

```
One more permission: I need direct screen access so I can check your active window automatically without making you pick it every time. Click this bubble to grant it.
```

Nothing is requested until the user clicks the bubble. On click, persist
`Settings.directCapturePermissionRequestPending` (`ds.directCapturePermissionRequestPending`),
perform one normal `SCScreenshotManager` capture, and immediately discard the resulting screenshot.
This asks for the direct-capture consent at the same API boundary used by real checks without
running Ollama, writing a trace, or retaining the image. Drill Sergeant uses screenshot capture
only and never configures ScreenCaptureKit audio capture; the operating-system dialog's mention of
audio is generic to the broader direct-capture capability.

If capture succeeds, clear the pending marker and advance to `.test`. If it fails, remain at
`.directCapturePermission`, explain that access is still unavailable, and let the user click to
retry after approving the app in System Settings. If macOS terminates the app during the request,
the replacement process shows `Checking direct screen access…`, retries the explicitly initiated
capture once, and advances on success. A failed resumed capture clears the marker before showing
retry UI so a stale request cannot cause future ordinary quits to relaunch forever.
`DS_RESET_ONBOARDING=1` clears both permission-request markers so a reset can never initiate either
request without a fresh user click.

## 28. Permission-quit relaunch ownership and verification

The macOS permission UI can send Drill Sergeant a normal Quit AppleEvent when the user clicks
`Quit & Reopen`; the operating system does not reliably start the replacement process. While
either permission-request marker is true, `AppDelegate.applicationShouldTerminate` therefore asks
`AppCoordinator` to schedule its own replacement before accepting an external quit.

The replacement is launched by a detached helper. It waits until the current process ID no longer
exists, then invokes `/usr/bin/open` on the installed bundle. Waiting avoids the LaunchServices
race caused by attempting to open a second copy while the original app is still registered and
terminating. Do not force a new instance: if macOS also honors `Quit & Reopen`, normal opening
reuses that replacement instead of creating a duplicate. The helper gives up after 30 seconds
rather than living indefinitely. If the helper
cannot be started, cancel termination and keep the retry UI visible. Schedule at most one helper
per process, and strip `DS_RESET_ONBOARDING` from its environment.

An unresolved initial Screen Recording request retains
`Settings.screenPermissionRequestPending`; a single failed poll is not proof of denial because the
system sheet or System Settings may still be open. The marker is cleared only after capture works,
after a replacement process exhausts its resume probes, on an explicit in-app quit, or on an
onboarding reset. Apply the same rule to the direct-capture marker: a failed attempt presents retry
UI but keeps relaunch protection active.

Explicit `Quit Drill Sergeant` remains a real quit: it clears both pending markers and suppresses
automatic relaunch. Logout, shutdown, restart, and Quit All AppleEvents also never schedule a
replacement. The relaunch helper, external-quit policy, duplicate scheduling, launch failure,
session-ending exclusions, explicit quit, unresolved consent, and both resume paths require
automated coverage. Acceptance also requires an installed-app test that sends the same ordinary
Quit AppleEvent and observes a different live process ID plus a second `App started` log record.

## 29. Work hours

Automatic monitoring is active only during configured local work hours. The default is Monday
through Friday, 09:00 through 17:00. Store the setting under `ds.workHours`; onboarding resets do
not clear it.

The model has a fifth structured action:

```swift
enum Tool: String, Codable {
    case set_idle, snooze, set_angry, save_user_preference, set_work_hours
}

enum Weekday: String, Codable, CaseIterable {
    case monday, tuesday, wednesday, thursday, friday, saturday, sunday
}

struct WorkHours: Codable, Equatable {
    static let standard: WorkHours  // weekdays, 09:00-17:00
    static let always: WorkHours    // every day, 00:00-24:00
    let days: [Weekday]
    let startTime: String
    let endTime: String
}

struct Decision: Codable, Equatable {
    // Existing fields remain unchanged.
    let workHours: WorkHours? // required when tool == .set_work_hours
}
```

The JSON action is intentionally flat so a small model does not have to construct nested objects:

```json
{
  "tool": "set_work_hours",
  "days": ["monday", "tuesday", "wednesday", "thursday", "friday"],
  "start_time": "09:00",
  "end_time": "17:00",
  "message": "Weekdays, nine to five. Got it."
}
```

`days`, `start_time`, and `end_time` are all required for this action. Days are explicit lowercase
enum values; times use local 24-hour `HH:mm`. `24:00` is accepted only as an end time. The array is
the complete replacement schedule, not a patch. One contiguous window applies to all selected
days. When the end is earlier than the start, the window continues overnight and each selected day
names the day on which that window starts.

Add this tool guidance to the system prompt:

```
set_work_hours(days, start_time, end_time): Replace the complete weekly schedule when the user asks
to change when monitoring is active. List every active day using lowercase weekday names. Use local
24-hour HH:mm times. Always send the full schedule, repeating unchanged values.
```

Call it only in direct response to a user's schedule request, never from a screenshot check. The
coordinator ignores the action if a screenshot check emits it anyway.
`CheckContext` gains `let workHours: WorkHours`, and both check and reply prompts include
`Current work hours: Monday-Friday, 09:00-17:00 local time` so partial-change requests are safe.

`Settings` gains `var workHours: WorkHours`. `Scheduler.init` gains
`workHours: WorkHours = .standard` and `calendar: Calendar = .current`.

Scheduling rules:

- Automatic scheduled checks and angry polls run only inside the window. The end is exclusive.
- If the next interval would land outside work hours, `nextCheckAt` becomes the next window's exact
  start. Pre-roll never begins before a work window.
- At the end of a window, an angry poll stops and the companion returns to idle until the next
  window.
- Manual checks, onboarding checks, and the angry follow-up they initiate bypass work hours; an
  explicit user action should still work at night.
- Applying `set_work_hours` persists the setting immediately. If the new schedule excludes the
  current time, automatic monitoring returns to idle and waits for the next window.

## 30. Native Ollama tool calls (replaces 4.1 and amends 4.2, 4.3, 17.1, 19, 24, 29)

Use Ollama's native function-calling protocol. Do not simulate a tool call with structured output,
and do not put user-facing text inside tool arguments.

`POST /api/chat` sends `tools`, sets `think` to `"low"`, omits `format`, and does not set a
`num_predict` token cap. The assistant response supplies
`message.tool_calls`; normal assistant prose remains in `message.content` and is the only source of
bubble text.

Expose five function tools:

```text
set_idle()                         // working or plausibly working
set_angry()                        // clearly slacking
snooze(minutes: Int)               // clamp 1...120; default 10 if omitted
save_user_preference(text: String)
set_work_hours(days: [Weekday], start_time: String, end_time: String)
```

Each function has its own JSON Schema parameters object. Zero-argument tools use an empty
properties object. There is no `message` parameter on any tool.

```swift
struct OllamaToolArguments: Codable, Equatable {
    let minutes: Int?
    let text: String?
    let days: [Weekday]?
    let startTime: String?
    let endTime: String?
}

struct OllamaToolCall: Codable, Equatable {
    struct Function: Codable, Equatable {
        let index: Int?
        let name: String
        let arguments: OllamaToolArguments
    }
    let id: String?
    let type: String?
    let function: Function
}

struct OllamaMessage: Codable, Equatable {
    var role: String
    var content: String
    var images: [String]?
    var thinking: String?
    var toolCalls: [OllamaToolCall]?
    var toolName: String?
    var toolCallID: String?
}
```

Exactly one tool call is required for every decision. Unknown tools, multiple calls, missing calls,
and invalid arguments are bad responses. `Decision` remains the validated internal action value;
its `message` is populated from assistant content, never from function arguments.

When the tool-call response has non-empty `message.content`, use it directly. When content is empty
for `set_idle`, silence is intentional. When content is empty for any other tool, append the exact
assistant tool-call message and a `role: "tool"` success result, then make one follow-up `/api/chat`
request without `tools`; its `message.content` becomes the user-facing message. This is the standard
native tool-result loop while avoiding a second generation for the common silent `set_idle` case.

Store successful native exchanges in `Conversation`: assistant tool call, tool result, and optional
follow-up assistant text. Strip old images as before and never retain an orphaned leading tool
result after trimming.

The system prompt says to call exactly one provided tool. It no longer says to output JSON. It also
says user-facing words belong in assistant text, and that after a tool result the model should
return only the short final message without another tool call.

Check traces show assistant content and the native function name/arguments separately. Failed
traces preserve the raw HTTP response. The developer toolbar reports `tool_calls` or
`followup.content` as the decision source.

## 31. Check latency (amends 5.1)

The model call is the whole cost of a check: capture, encoding, and output processing together
run in about 10 ms, against seconds for the request. Two rules keep it down.

Use an `-instruct` model. The plain `qwen3-vl:8b` tag is the thinking build, which spends 300-600
output tokens per check on a monologue that is discarded — most of the latency, and the cause of
30-second checks. Send no `think` option; instruct builds reject the request with HTTP 400.

Send only the tools the call may use. A screenshot check offers `set_idle`, `set_angry`, and
`snooze` only. `save_user_preference` and `set_work_hours` answer a user reply, and a check
already discards `set_work_hours`, so offering them costs 285 prompt tokens for nothing.

Two things that look like optimizations and are not. Screenshot resolution below 1280 pixels does
not change prompt tokens — Ollama normalizes the image to a fixed budget, so 1280, 768, and 320
all cost the same; only exceeding 1280 costs more. And prefix caching, though worth 100x on a
repeated request, does not survive a changed image, so the system prompt and tool schemas are
re-prefilled on every check.

## 32. Eight-gigabyte memory mode (amends 4.2, 5.1, 17.1, and 24)

Keep `qwen3-vl:8b-instruct` as the default and only installed model. When
`ProcessInfo.processInfo.physicalMemory` is 8 GiB or less, automatically use a low-memory runtime
profile:

- Send `num_ctx: 4096` instead of 8192.
- Scale the longest screenshot edge to 960 pixels instead of 1280.
- Retain at most four conversation messages instead of twelve.
- Use `keep_alive: "30s"` for the initial native-tool request. If a text follow-up is needed, send
  `keep_alive: 0` on that final request; otherwise make a best-effort `/api/generate` request with
  `keep_alive: 0` after accepting the decision. A failed unload must not discard a valid decision.

The installer detects the same 8 GiB threshold and uses `launchctl setenv` to set
`OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_KV_CACHE_TYPE=q4_0`, `OLLAMA_NUM_PARALLEL=1`, and
`OLLAMA_MAX_LOADED_MODELS=1` before starting Ollama. If Ollama was already running, tell the user to
restart it once. These are global Ollama server settings for the current macOS login session.
