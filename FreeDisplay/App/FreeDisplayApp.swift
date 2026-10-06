import SwiftUI

@main
struct FreeDisplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            // Launch-time work lives in AppDelegate: this content is built lazily and its
            // .task/.onAppear run again every time the panel opens.
            MenuBarView()
                .environmentObject(appDelegate.displayManager)
        } label: {
            Image(systemName: "display")
        }
        .menuBarExtraStyle(.window)
        // Let the panel shrink back when sections collapse (min-only sizing never shrinks).
        .windowResizability(.contentSize)
    }
}
