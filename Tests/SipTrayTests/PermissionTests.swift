import AppKit

@main
@MainActor
struct PermissionTests {
    static func pump(for duration: TimeInterval = 0.65) {
        let end = Date().addingTimeInterval(duration)
        while Date() < end {
            RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.02)))
        }
    }

    static func main() {
        // Building the steps never asks macOS for consent.
        let required = SipPermissionRequester.steps(includeSpeechRecognition: false)
        precondition(required.map(\.title) == ["Mikrofon"])
        let apple = SipPermissionRequester.steps(includeSpeechRecognition: true)
        precondition(apple.map(\.title) == ["Mikrofon", "Spracherkennung"])
        precondition(apple.allSatisfy { $0.requestAccess != nil && !$0.needsRestartToTakeEffect })

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        var microphoneGranted = false
        var speechGranted = false
        var microphoneRequests = 0
        var speechRequests = 0
        var microphoneReply: (@MainActor @Sendable () -> Void)?
        var speechReply: (@MainActor @Sendable () -> Void)?
        var startupCompletions = 0
        var featureCompletions = 0
        let steps = [
            PermissionStep(title: "Test-Mikrofon", settingsURLString: "",
                           isGranted: { microphoneGranted }, needsRestartToTakeEffect: false,
                           requestAccess: { reply in microphoneRequests += 1; microphoneReply = reply }),
            PermissionStep(title: "Test-Spracherkennung", settingsURLString: "",
                           isGranted: { speechGranted }, needsRestartToTakeEffect: false,
                           requestAccess: { reply in speechRequests += 1; speechReply = reply })
        ]
        PermissionAssistantWindowController.present(steps: steps) { startupCompletions += 1 }
        pump()
        precondition(microphoneRequests == 1 && speechRequests == 0)
        let window = app.windows.first { $0.title == "Berechtigungen erteilen" }!
        precondition(window.isVisible)

        // A denied response stays on this step, without repeat prompts or early completion.
        microphoneReply?()
        pump()
        precondition(microphoneRequests == 1 && speechRequests == 0 && startupCompletions == 0)

        // Dismissing and reopening must retain the startup callback and current sequence.
        window.close()
        PermissionAssistantWindowController.present(steps: [steps[0]]) { featureCompletions += 1 }
        pump()
        precondition(window.isVisible && microphoneRequests == 1 && speechRequests == 0)
        microphoneGranted = true
        pump()
        precondition(speechRequests == 1 && startupCompletions == 0)

        // macOS can report the grant before its consent completion handler returns.
        speechGranted = true
        pump()
        precondition(startupCompletions == 0 && featureCompletions == 0 && window.isVisible)
        speechReply?()
        pump()
        precondition(startupCompletions == 1 && featureCompletions == 1 && !window.isVisible)
        pump()
        precondition(startupCompletions == 1 && featureCompletions == 1)

        // A new check queries grants again and skips all UI when already authorized.
        PermissionAssistantWindowController.present(steps: steps) { featureCompletions += 1 }
        precondition(featureCompletions == 2 && microphoneRequests == 1 && speechRequests == 1)
        print("Permission ordering, denial, dismissal/reopen, async serialization, completion and existing-grant checks passed; no macOS permission requests.")
    }
}
