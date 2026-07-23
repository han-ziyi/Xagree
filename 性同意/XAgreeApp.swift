import SwiftUI

@main
struct XAgreeApp: App {
    @StateObject private var appState: AppState

    init() {
        UITestBootstrap.prepareIfNeeded()
        _appState = StateObject(wrappedValue: AppState())
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(appState)
        }
    }
}
