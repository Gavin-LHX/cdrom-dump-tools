import SwiftUI

@main
@MainActor
struct CdromDumpToolsIOSApp: App {
    @StateObject private var model = IOSAppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
