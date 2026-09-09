import AppKit
import AVFoundation
import Speech

@MainActor
enum SipPermissionRequester {
    static func checkPermissions(includeSpeechRecognition: Bool, onGranted: @escaping () -> Void = {}) {
        PermissionAssistantWindowController.present(
            steps: steps(includeSpeechRecognition: includeSpeechRecognition), onGranted: onGranted
        )
    }

    static func steps(includeSpeechRecognition: Bool) -> [PermissionStep] {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        let microphoneURL = base + "Privacy_Microphone"
        let speechURL = base + "Privacy_SpeechRecognition"
        var steps = [PermissionStep(
            title: "Mikrofon", settingsURLString: microphoneURL,
            isGranted: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
            needsRestartToTakeEffect: false,
            requestAccess: { completion in
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in
                        Task { @MainActor in completion() }
                    }
                } else {
                    openSettings(microphoneURL)
                    completion()
                }
            }
        )]
        if includeSpeechRecognition {
            steps.append(PermissionStep(
                title: "Spracherkennung", settingsURLString: speechURL,
                isGranted: { SFSpeechRecognizer.authorizationStatus() == .authorized },
                needsRestartToTakeEffect: false,
                requestAccess: { completion in
                    if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                        SFSpeechRecognizer.requestAuthorization { _ in
                            Task { @MainActor in completion() }
                        }
                    } else {
                        openSettings(speechURL)
                        completion()
                    }
                }
            ))
        }
        return steps
    }

    private static func openSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
