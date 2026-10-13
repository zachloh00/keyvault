import SwiftUI

@main
struct KeyvaultApp: App {
    @StateObject private var model = VaultModel()

    var body: some Scene {
        WindowGroup {
            VaultWindow(model: model)
                .frame(minWidth: 720, minHeight: 520)
        }
        .windowResizability(.contentSize)
    }
}
