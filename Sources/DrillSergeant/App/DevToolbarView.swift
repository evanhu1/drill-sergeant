import SwiftUI

@MainActor
struct DevToolbarView: View {
    let actions: DevActions

    @State private var statusText = ""
    @State private var lastDecisionText = ""
    @State private var trayExtended = true
    @State private var receivedMessage = "Close YouTube and get back to work."
    @State private var autoHide = true
    @State private var reply = "I'm researching for the essay, give me 10 min"
    @State private var captureResult = ""
    @State private var isCapturing = false
    @State private var isRendering = false

    var body: some View {
        Form {
            Section("Status") {
                Text(statusText)
                    .textSelection(.enabled)
                Text(lastDecisionText)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("State") {
                HStack {
                    stateButton("Idle", .idle)
                    stateButton("Watching", .watching)
                    stateButton("Angry", .angry)
                    stateButton("Happy", .happy)
                }
                Toggle("Tray extended", isOn: $trayExtended)
                    .onChange(of: trayExtended) { _, extended in
                        actions.setTrayExtended(extended)
                    }
            }

            Section("Receive message") {
                TextField("Message", text: $receivedMessage)
                HStack {
                    Toggle("auto-hide", isOn: $autoHide)
                    Spacer()
                    Button("Show") {
                        actions.showTestMessage(receivedMessage, autoHide: autoHide)
                    }
                }
            }

            Section("Send message") {
                TextField("Reply", text: $reply)
                Button("Send to model") {
                    actions.sendReply(reply)
                }
            }

            Section("Screenshot flow") {
                HStack {
                    Button("Run check (screenshot + model)") {
                        actions.runCheck()
                    }
                    Button(isCapturing ? "Capturing…" : "Capture only") {
                        capture()
                    }
                    .disabled(isCapturing)
                }
                if !captureResult.isEmpty {
                    Text(captureResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Onboarding") {
                HStack {
                    Button("Reset & start") { actions.resetOnboarding() }
                    Button("Skip") { actions.skipOnboarding() }
                }
            }

            Section("Renders") {
                Button(isRendering ? "Rendering…" : "Render all states") {
                    renderAllStates()
                }
                .disabled(isRendering)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .task {
            while !Task.isCancelled {
                refreshStatus()
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func stateButton(_ title: String, _ state: CompanionState) -> some View {
        Button(title) { actions.forceState(state) }
    }

    private func refreshStatus() {
        statusText = actions.statusText
        lastDecisionText = actions.lastDecisionText
    }

    private func capture() {
        isCapturing = true
        Task { @MainActor in
            captureResult = await actions.captureOnly()
            isCapturing = false
        }
    }

    private func renderAllStates() {
        isRendering = true
        Task { @MainActor in
            _ = await actions.renderStates()
            isRendering = false
        }
    }
}
