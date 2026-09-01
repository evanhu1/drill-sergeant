# Drill Sergeant — agent conventions

You are implementing part of a macOS app. The full product and technical spec is in `docs/SPEC.md`.
Read it fully before writing code. Follow its public interfaces **exactly** — other agents build
against them in parallel.

## Rules
- Swift 5.9+, SwiftPM only, **no third-party dependencies**, macOS 14.0+ deployment target.
- Keep `Sources/DrillSergeant/App/main.swift` to a single call (`AppMain.run()`) so the target stays testable.
- Mark UI/state classes `@MainActor`. Use `async/await`, never completion-handler spaghetti.
- No force unwraps except for literal URLs / obvious invariants. No `print`; use `Log`.
- Build with `swift build` and run `swift test` before you finish. Both must pass with zero errors.
  Warnings are OK but try to fix them.
- Do not touch files outside your assigned scope unless the build needs a one-line fix elsewhere;
  if you do, say so in your final message.
- Do not run the app (`open`, `run.sh`) — the human tests the UI.
- Do not commit. Leave the working tree for the human to review.
- Final message: list files created/changed, anything that deviates from the spec and why,
  and known gaps.

## Style
- Short functions, clear names, brief doc comments on public interfaces.
- Prefer `struct`/`enum` for data; `final class` only when identity or `ObservableObject` is needed.
