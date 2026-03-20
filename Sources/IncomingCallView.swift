import SwiftUI

struct IncomingCallView: View {
    let call: IncomingCall
    let isSilenced: Bool
    let onAccept: () -> Void
    let onDecline: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "phone.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("Eingehender Anruf")
                .font(.title.bold())

            VStack(spacing: 6) {
                Text(call.displayName)
                    .font(.title2)
                Text(call.number)
                    .foregroundStyle(.secondary)
                if isSilenced {
                    Text("Klingeln für diesen Anruf beendet")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            HStack(spacing: 14) {
                Button("Schließen", action: onClose)
                Button("Abweisen", action: onDecline)
                Button("Annehmen", action: onAccept)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 420, height: 280)
    }
}
