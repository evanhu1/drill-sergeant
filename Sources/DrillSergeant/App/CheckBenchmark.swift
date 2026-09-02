import AppKit
import Foundation

/// Times one whole check the way the app runs it: capture, model call, output processing.
///
/// Run it with `Drill Sergeant.app/Contents/MacOS/DrillSergeant --benchmark [runs]`. It uses
/// the production capture path and the production `OllamaClient`, so the numbers it prints
/// are the numbers a real check pays.
@MainActor
enum CheckBenchmark {
    private struct Sample {
        var capture: TimeInterval = 0
        var shareableContent: TimeInterval = 0
        var captureImage: TimeInterval = 0
        var encode: TimeInterval = 0
        var base64: TimeInterval = 0
        var activeWindow: TimeInterval = 0
        var promptBuild: TimeInterval = 0
        var model: TimeInterval = 0
        var prefill: TimeInterval = 0
        var decode: TimeInterval = 0
        var trace: TimeInterval = 0
        var output: TimeInterval = 0
        var promptTokens = 0
        var outputTokens = 0

        var total: TimeInterval {
            capture + base64 + activeWindow + promptBuild + model + trace + output
        }
    }

    static func run(runs: Int) async -> Never {
        let settings = Settings()
        let profile = RuntimeProfile.current
        let ollama = OllamaClient(baseURL: settings.ollamaBaseURL, model: settings.model)

        guard await ollama.isReachable() else {
            print("Ollama is not answering at \(settings.ollamaBaseURL).")
            exit(EXIT_FAILURE)
        }
        guard (try? await ollama.hasModel()) == true else {
            print("Model \(settings.model) is not installed. Run: ollama pull \(settings.model)")
            exit(EXIT_FAILURE)
        }

        print("")
        print("Check latency — \(runs) runs, \(settings.model)")
        print(
            "profile: ctx=\(profile.contextTokens) maxEdge=\(profile.screenshotMaxEdge) "
                + "turns=\(profile.conversationMaxTurns) keepAlive=\(profile.keepAlive) "
                + "unloadAfter=\(profile.unloadAfterDecision)"
        )
        print("")

        var samples: [Sample] = []
        var followUps = 0
        var failures = 0
        var jpegBytes = 0
        var base64Bytes = 0
        var dimensions = ""
        let traceWriter = CheckTrace()

        // One untimed warm-up so a cold model load is not charged to run 1.
        print("warming up…")
        _ = try? await ollama.decideWithTraceMetadata(
            messages: [
                OllamaMessage(role: "system", content: PromptBuilder.systemPrompt()),
                OllamaMessage(role: "user", content: "Warm up. Call set_idle."),
            ]
        )

        for run in 1...max(1, runs) {
            var sample = Sample()
            let conversation = Conversation()
            let scheduler = Scheduler(clock: SystemClock())

            var stages: [ScreenCapture.Stage: TimeInterval] = [:]
            ScreenCapture.stageObserver = { stage, elapsed in
                DispatchQueue.main.async { stages[stage] = elapsed }
            }

            let captureStart = now()
            let screenshot: Screenshot
            do {
                screenshot = try await ScreenCapture.capture()
            } catch {
                ScreenCapture.stageObserver = nil
                print("capture failed: \(error)")
                exit(EXIT_FAILURE)
            }
            sample.capture = since(captureStart)
            ScreenCapture.stageObserver = nil
            sample.shareableContent = stages[.shareableContent] ?? 0
            sample.captureImage = stages[.captureImage] ?? 0
            sample.encode = stages[.encode] ?? 0

            let base64Start = now()
            let encoded = screenshot.base64
            sample.base64 = since(base64Start)

            jpegBytes = screenshot.jpegData.count
            base64Bytes = encoded.utf8.count
            dimensions = "\(screenshot.width)x\(screenshot.height)"

            let windowStart = now()
            let window = ActiveWindowInspector.current()
            sample.activeWindow = since(windowStart)

            let promptStart = now()
            let context = CheckContext(
                state: scheduler.state,
                previousState: scheduler.previousState,
                stateAge: 0,
                window: window,
                lastUserMessage: nil,
                userPreferences: settings.userPreferences,
                workHours: settings.workHours,
                now: Date(),
                reason: .scheduled
            )
            conversation.appendUser(PromptBuilder.checkPrompt(context), image: encoded)
            let messages = [
                OllamaMessage(role: "system", content: PromptBuilder.systemPrompt()),
            ] + conversation.turns
            sample.promptBuild = since(promptStart)

            let modelStart = now()
            let result: OllamaDecisionResult
            do {
                result = try await ollama.decideWithTraceMetadata(
                    messages: messages,
                    tools: Decision.checkToolDefinitions
                )
            } catch let failure as OllamaDecisionFailure {
                failures += 1
                print(
                    String(
                        format: "  run %d: FAILED after %.0f ms — %@",
                        run,
                        since(modelStart) * 1_000,
                        String(describing: failure.error)
                    )
                )
                continue
            } catch {
                failures += 1
                print("  run \(run): FAILED — \(error)")
                continue
            }
            sample.model = since(modelStart)
            sample.prefill = result.timings.promptSeconds
            sample.decode = result.timings.outputSeconds
            sample.promptTokens = result.timings.promptTokens
            sample.outputTokens = result.timings.outputTokens
            if result.sourceField.hasPrefix("followup") {
                followUps += 1
            }

            let traceStart = now()
            _ = try? traceWriter.write(
                request: CheckTrace.Request(
                    reason: .scheduled,
                    time: context.now,
                    model: settings.model,
                    state: context.state,
                    previousState: context.previousState,
                    stateAge: context.stateAge,
                    capture: CheckTrace.capture(from: screenshot),
                    activeWindow: window,
                    messages: messages
                ),
                response: .success(result),
                screenshotData: screenshot.jpegData
            )
            sample.trace = since(traceStart)

            let outputStart = now()
            conversation.appendModelExchange(result.conversationMessages)
            scheduler.apply(result.decision)
            sample.output = since(outputStart)

            samples.append(sample)
            print(
                String(
                    format: "  run %d: %.0f ms  (%@ — \"%@\")",
                    run,
                    sample.total * 1_000,
                    result.decision.tool.rawValue,
                    result.decision.message.isEmpty ? "" : result.decision.message
                )
            )
        }

        print("")
        guard !samples.isEmpty else {
            print("  every run failed")
            exit(EXIT_FAILURE)
        }
        report(samples)
        print("")
        print(
            "  payload    \(dimensions), \(kilobytes(jpegBytes)) jpeg "
                + "-> \(kilobytes(base64Bytes)) base64"
        )
        print(
            "  tokens     \(median(samples.map(\.promptTokens))) prompt "
                + "-> \(median(samples.map(\.outputTokens))) output (median)"
        )
        print("  follow-up calls: \(followUps)/\(samples.count)")
        print("  failed runs: \(failures)")
        print("")
        exit(EXIT_SUCCESS)
    }

    /// Prints the exact system prompt and tool schema the app sends, so an external sweep
    /// can experiment against the real payload rather than a transcription of it.
    static func dumpPayload() -> Never {
        let payload: [String: Any] = [
            "system": PromptBuilder.systemPrompt(),
            "tools": Decision.toolDefinitions,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            exit(EXIT_FAILURE)
        }
        print(String(decoding: data, as: UTF8.self))
        exit(EXIT_SUCCESS)
    }

    // MARK: - Reporting

    private static func report(_ samples: [Sample]) {
        print("  " + "stage".padding(toLength: 26, withPad: " ", startingAt: 0)
            + "      min      med      max")
        row("screen capture", samples.map(\.capture))
        row("  ├ shareable content", samples.map(\.shareableContent))
        row("  ├ capture image", samples.map(\.captureImage))
        row("  └ jpeg encode", samples.map(\.encode))
        row("base64 encode", samples.map(\.base64))
        row("active window", samples.map(\.activeWindow))
        row("prompt build", samples.map(\.promptBuild))
        row("model call", samples.map(\.model))
        row("  ├ prefill (prompt)", samples.map(\.prefill))
        row("  └ decode (output)", samples.map(\.decode))
        row("trace write", samples.map(\.trace))
        row("output processing", samples.map(\.output))
        print("  " + String(repeating: "─", count: 51))
        row("total", samples.map(\.total))
    }

    private static func row(_ label: String, _ values: [TimeInterval]) {
        let sorted = values.sorted()
        guard let low = sorted.first, let high = sorted.last else { return }
        let median = sorted[sorted.count / 2]
        let name = label.count >= 26
            ? label
            : label + String(repeating: " ", count: 26 - label.count)
        print(
            name.withCString { _ in
                String(
                    format: "  %@%8.0f%9.0f%9.0f",
                    name as NSString, low * 1_000, median * 1_000, high * 1_000
                )
            }
        )
    }

    private static func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }

    private static func kilobytes(_ bytes: Int) -> String {
        String(format: "%.0f KB", Double(bytes) / 1_024)
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    private static func since(_ startedAt: UInt64) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds &- startedAt) / 1_000_000_000
    }
}
