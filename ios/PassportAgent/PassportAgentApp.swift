import SwiftUI

@main
struct PassportAgentApp: App {
    @State private var session = AgentSession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(session)
        }
    }
}
