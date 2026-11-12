import SwiftUI

struct RootView: View {
    @StateObject private var store = AppStore.shared

    var body: some View {
        Group {
            switch store.authState {
            case .loggedOut:
                LoginView()
            case .connecting:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Připojování…")
                        .foregroundStyle(.secondary)
                }
            case .connected:
                MainView()
            }
        }
        .frame(minWidth: 460, minHeight: 540)
    }
}
