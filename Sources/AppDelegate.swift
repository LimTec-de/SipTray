import AppKit
import Combine
import SwiftUI

@MainActor
final class AppCoordinator: ObservableObject {
    let state = AppState()

    @Published private(set) var missedCallCount = 0
    @Published private(set) var menuBarIconName = "phone.fill"

    private var settingsWindowController: SettingsWindowController?
    private var addFavoriteWindowController: AddFavoriteWindowController?
    private var incomingCallWindowController: IncomingCallWindowController?
    private var transcriptWindowController: TranscriptWindowController?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(0x4755524C),
            andEventID: AEEventID(0x4755524C)
        )

        state.$missedCallCount
            .receive(on: RunLoop.main)
            .sink { [weak self] count in
                self?.missedCallCount = count
            }
            .store(in: &cancellables)

        state.$connectionStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.menuBarIconName = Self.iconName(for: status)
            }
            .store(in: &cancellables)

        state.$incomingCall
            .combineLatest(state.$isIncomingCallModalVisible, state.$isIncomingCallSilenced)
            .receive(on: RunLoop.main)
            .sink { [weak self] call, isVisible, isSilenced in
                self?.updateIncomingCallWindow(call: call, isVisible: isVisible, isSilenced: isSilenced)
            }
            .store(in: &cancellables)

        state.$selectedTranscriptCall
            .receive(on: RunLoop.main)
            .sink { [weak self] record in
                self?.updateTranscriptWindow(record: record)
            }
            .store(in: &cancellables)
    }

    var menuBarTitle: String {
        missedCallCount > 0 ? "SIP \(min(missedCallCount, 99))" : "SIP"
    }

    private static func iconName(for status: SIPConnectionStatus) -> String {
        switch status {
        case .connected:
            return "phone.fill"
        case .connecting, .reconnecting:
            return "phone.arrow.up.right.fill"
        case .networkUnavailable, .disconnected, .invalidConfiguration:
            return "phone.down.circle.fill"
        }
    }

    func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(state: state)
        }
        settingsWindowController?.present()
    }

    func openAddFavorite(prefilledNumber: String) {
        addFavoriteWindowController?.close()
        addFavoriteWindowController = AddFavoriteWindowController(
            initialNumber: prefilledNumber,
            onCancel: { [weak self] in
                self?.addFavoriteWindowController?.close()
                self?.addFavoriteWindowController = nil
            },
            onSave: { [weak self] name, number in
                self?.state.addFavorite(name: name, number: number)
                self?.addFavoriteWindowController?.close()
                self?.addFavoriteWindowController = nil
            }
        )
        addFavoriteWindowController?.present()
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func handleIncomingURL(_ url: URL) {
        guard url.scheme == "tel" else { return }
        let raw = url.absoluteString
            .replacingOccurrences(of: "tel:", with: "")
            .trimmingCharacters(in: CharacterSet.whitespaces)
        guard !raw.isEmpty else { return }
        state.dialedNumber = state.applyNumberRewrite(raw)
        openMenuBarPopover()
    }

    private func updateIncomingCallWindow(call: IncomingCall?, isVisible: Bool, isSilenced: Bool) {
        guard let call, isVisible else {
            incomingCallWindowController?.close()
            incomingCallWindowController = nil
            return
        }

        let view = IncomingCallView(
            call: call,
            isSilenced: isSilenced,
            onAccept: { [weak self] in self?.state.acceptIncomingCall() },
            onDecline: { [weak self] in self?.state.declineIncomingCall() },
            onClose: { [weak self] in self?.state.silenceIncomingCall() }
        )

        if incomingCallWindowController == nil {
            incomingCallWindowController = IncomingCallWindowController(view: view)
        } else {
            incomingCallWindowController?.update(view: view)
        }

        incomingCallWindowController?.presentCentered()
    }

    private func updateTranscriptWindow(record: CallRecord?) {
        guard let record else {
            transcriptWindowController?.close()
            transcriptWindowController = nil
            return
        }

        if transcriptWindowController == nil {
            transcriptWindowController = TranscriptWindowController(
                record: record,
                onClose: { [weak self] in
                    self?.state.dismissTranscript()
                }
            )
        } else {
            transcriptWindowController?.update(record: record)
        }

        transcriptWindowController?.present()
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(0x2D2D2D2D))?.stringValue,
              let url = URL(string: urlString) else { return }
        handleIncomingURL(url)
    }

    private func openMenuBarPopover() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
