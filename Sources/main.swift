import SwiftUI

@main
struct SIPPhoneApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                state: coordinator.state,
                onOpenSettings: { coordinator.openSettings() },
                onOpenAddFavorite: { coordinator.openAddFavorite(prefilledNumber: $0) },
                onQuit: { coordinator.quit() }
            )
            .onOpenURL { url in
                coordinator.handleIncomingURL(url)
            }
        } label: {
            Label(coordinator.menuBarTitle, systemImage: coordinator.menuBarIconName)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(state: coordinator.state)
        }
    }
}
