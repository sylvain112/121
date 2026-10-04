import SwiftUI

@main
struct ZHFRLiveApp: App {
    @StateObject private var model = InterpreterViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}
