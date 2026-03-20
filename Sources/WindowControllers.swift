import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(state: AppState) {
        let contentView = SettingsView(state: state)
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 640, height: 620))
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func present() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct AddFavoriteView: View {
    let initialNumber: String
    let onCancel: () -> Void
    let onSave: (_ name: String, _ number: String) -> Void

    @State private var name = ""
    @State private var number: String

    init(
        initialNumber: String,
        onCancel: @escaping () -> Void,
        onSave: @escaping (_ name: String, _ number: String) -> Void
    ) {
        self.initialNumber = initialNumber
        self.onCancel = onCancel
        self.onSave = onSave
        _number = State(initialValue: initialNumber)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Favorit hinzufügen")
                .font(.headline)

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            TextField("Rufnummer", text: $number)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Abbrechen", action: onCancel)
                Button("Speichern") {
                    onSave(name, number)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

@MainActor
final class AddFavoriteWindowController: NSWindowController {
    private let hostingController: NSHostingController<AddFavoriteView>

    init(initialNumber: String, onCancel: @escaping () -> Void, onSave: @escaping (_ name: String, _ number: String) -> Void) {
        let contentView = AddFavoriteView(
            initialNumber: initialNumber,
            onCancel: onCancel,
            onSave: onSave
        )
        hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Favorit"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.setContentSize(NSSize(width: 320, height: 170))
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func present() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class IncomingCallWindowController: NSWindowController {
    private let hostingController: NSHostingController<IncomingCallView>

    init(view: IncomingCallView) {
        hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 420, height: 280))
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(view: IncomingCallView) {
        hostingController.rootView = view
    }

    func presentCentered() {
        if let screenFrame = NSScreen.screens.first(where: { $0 == NSScreen.main })?.visibleFrame ?? NSScreen.main?.visibleFrame {
            let origin = NSPoint(
                x: screenFrame.midX - 210,
                y: screenFrame.midY - 140
            )
            window?.setFrameOrigin(origin)
        } else {
            window?.center()
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct TranscriptWindowView: View {
    let record: CallRecord
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(record.displayName)
                .font(.headline)
            Text(record.number)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let metadata = record.metadataSummary {
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(record.transcription ?? "Keine Transkription vorhanden.")
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Schließen", action: onClose)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 360)
    }
}

@MainActor
final class TranscriptWindowController: NSWindowController, NSWindowDelegate {
    private let hostingController: NSHostingController<TranscriptWindowView>
    private let onClose: () -> Void

    init(record: CallRecord, onClose: @escaping () -> Void) {
        self.onClose = onClose
        hostingController = NSHostingController(
            rootView: TranscriptWindowView(record: record, onClose: onClose)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Transkription"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 420))
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(record: CallRecord) {
        hostingController.rootView = TranscriptWindowView(record: record, onClose: onClose)
    }

    func present() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        onClose()
    }
}
